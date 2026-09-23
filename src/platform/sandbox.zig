const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const MultiReader = std.Io.File.MultiReader;

pub const Limits = struct {
    timeout_ms: u64 = 60_000,
    max_output_bytes: usize = 1024 * 1024,
};

pub const Outcome = union(enum) {
    exited: u32,
    crashed: u32,
    timed_out,
    output_limit,
};

pub const Report = struct {
    outcome: Outcome,
    duration_ns: u64,
    stdout: []u8,
    stderr: []u8,
    truncated: bool,
    killed_leftovers: bool,

    pub fn passed(self: Report) bool {
        return switch (self.outcome) {
            .exited => |code| code == 0 and !self.killed_leftovers,
            .crashed, .timed_out, .output_limit => false,
        };
    }

    pub fn deinit(self: Report, gpa: Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

pub const Command = struct {
    argv: []const []const u8,
    cwd: []const u8,
    limits: Limits = .{},
};

const ntstatus_error_floor: u32 = 0xC0000000;

fn exitOutcome(code: u32) Outcome {
    return if (code >= ntstatus_error_floor) .{ .crashed = code } else .{ .exited = code };
}

const read_reserve = 4096;
const exit_poll_ns = 50 * std.time.ns_per_ms;
const leftover_grace_ns = 2 * std.time.ns_per_s;

var running: std.atomic.Value(bool) = .init(false);

pub fn run(gpa: Allocator, io: std.Io, command: Command) !Report {
    if (builtin.os.tag != .windows) return error.SandboxUnsupported;
    if (running.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.SandboxBusy;
    defer running.store(false, .release);

    const job = try Job.create();
    defer job.close();

    const token = try LowToken.create();
    defer token.close();

    const started = std.Io.Timestamp.now(io, .awake);
    var child = try spawnRestricted(gpa, token, command);
    defer child.kill(io);
    try requireLowIntegrity(child.id.?);
    try job.assign(child.id.?);
    try resumeMainThread(child.thread_handle);

    var streams: MultiReader.Buffer(2) = undefined;
    var reader: MultiReader = undefined;
    reader.init(gpa, io, streams.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();

    const limit = command.limits.max_output_bytes;
    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = .{ .nanoseconds = @as(i96, command.limits.timeout_ms) * std.time.ns_per_ms },
        .clock = .awake,
    } };
    const deadline = timeout.toDeadline(io).deadline;
    const poll: std.Io.Clock.Duration = .{ .raw = .{ .nanoseconds = exit_poll_ns }, .clock = .awake };

    var stopped: ?Outcome = null;
    var killed_leftovers = false;
    var drain_end: ?std.Io.Clock.Timestamp = null;
    while (true) {
        const now = std.Io.Clock.Timestamp.now(io, .awake);
        if (now.compare(.gte, deadline)) {
            stopped = .timed_out;
            break;
        }
        const next_poll = now.addDuration(poll);
        const slice_end = if (next_poll.compare(.lt, deadline)) next_poll else deadline;
        reader.fill(read_reserve, .{ .deadline = slice_end }) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => {
                if (killed_leftovers) continue;
                if (drain_end) |end| {
                    if (std.Io.Clock.Timestamp.now(io, .awake).compare(.gte, end)) {
                        job.terminate();
                        killed_leftovers = true;
                    }
                } else if (hasExited(child.id.?)) {
                    drain_end = graceEnd(io, deadline);
                }
                continue;
            },
            else => |e| return e,
        };
        if (reader.reader(0).buffered().len > limit or reader.reader(1).buffered().len > limit) {
            stopped = .output_limit;
            break;
        }
    }
    if (stopped == null and !exitsBefore(io, child.id.?, deadline)) stopped = .timed_out;
    var exit_code: u32 = win.terminated_exit_code;
    var reaped = false;
    if (stopped == null) {
        exit_code = try waitExitCode(child.id.?);
        const console_host = consoleHost(child.id.?);
        _ = try child.wait(io);
        reaped = true;
        if (!killed_leftovers and job.outlasts(console_host, millisUntil(io, graceEnd(io, deadline)))) killed_leftovers = true;
        job.stop();
        if (!killed_leftovers) try reader.checkAnyError();
    } else {
        job.stop();
        exit_code = try waitExitCode(child.id.?);
    }
    if (!reaped) _ = try child.wait(io);
    const duration_ns: u64 = @intCast(started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);

    var truncated = false;
    const stdout = try takeStream(gpa, &reader, 0, limit, &truncated);
    errdefer gpa.free(stdout);
    const stderr = try takeStream(gpa, &reader, 1, limit, &truncated);

    return .{
        .outcome = stopped orelse exitOutcome(exit_code),
        .duration_ns = duration_ns,
        .stdout = stdout,
        .stderr = stderr,
        .truncated = truncated,
        .killed_leftovers = killed_leftovers,
    };
}

fn millisUntil(io: std.Io, deadline: std.Io.Clock.Timestamp) std.os.windows.DWORD {
    const remaining = std.Io.Clock.Timestamp.now(io, .awake).durationTo(deadline).raw.nanoseconds;
    return if (remaining <= 0) 0 else @intCast(@min(@divTrunc(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms), win.infinite - 1));
}

fn graceEnd(io: std.Io, deadline: std.Io.Clock.Timestamp) std.Io.Clock.Timestamp {
    const grace: std.Io.Clock.Duration = .{ .raw = .{ .nanoseconds = leftover_grace_ns }, .clock = .awake };
    const end = std.Io.Clock.Timestamp.now(io, .awake).addDuration(grace);
    return if (end.compare(.lt, deadline)) end else deadline;
}

fn exitsBefore(io: std.Io, process: std.os.windows.HANDLE, deadline: std.Io.Clock.Timestamp) bool {
    return win.WaitForSingleObject(process, millisUntil(io, deadline)) == win.wait_object_0;
}

fn consoleHost(process: std.os.windows.HANDLE) ?usize {
    var value: usize = 0;
    if (win.NtQueryInformationProcess(process, win.process_console_host_process, &value, @sizeOf(usize), null) != .SUCCESS) return null;
    const pid = value & ~@as(usize, 3);
    return if (pid == 0) null else pid;
}

pub fn leftoverCount(pids: []const usize, console_host: ?usize) usize {
    var count: usize = 0;
    for (pids) |pid| {
        if (console_host != null and pid == console_host.?) continue;
        count += 1;
    }
    return count;
}

fn hasExited(process: std.os.windows.HANDLE) bool {
    return win.WaitForSingleObject(process, 0) == win.wait_object_0;
}

fn takeStream(gpa: Allocator, reader: *MultiReader, index: usize, limit: usize, truncated: *bool) ![]u8 {
    const bytes = try reader.toOwnedSlice(index);
    if (bytes.len <= limit) return bytes;
    truncated.* = true;
    return gpa.realloc(bytes, limit) catch |err| {
        gpa.free(bytes);
        return err;
    };
}

pub const low_integrity_rid: u32 = 0x1000;

pub const TokenStep = enum { open, restrict, label, spawn_as_user, verify };
pub var injected_fault: ?TokenStep = null;
var last_stop_emptied: ?bool = null;

fn faulted(step: TokenStep) bool {
    return builtin.is_test and injected_fault == step;
}

const LowToken = struct {
    handle: std.os.windows.HANDLE,

    fn create() error{SandboxUnavailable}!LowToken {
        var process_token: std.os.windows.HANDLE = undefined;
        if (faulted(.open) or win.OpenProcessToken(win.GetCurrentProcess(), win.token_access, &process_token) == .FALSE) return error.SandboxUnavailable;
        defer std.os.windows.CloseHandle(process_token);

        var restricted: std.os.windows.HANDLE = undefined;
        if (faulted(.restrict) or win.CreateRestrictedToken(process_token, win.disable_max_privilege, 0, null, 0, null, 0, null, &restricted) == .FALSE) return error.SandboxUnavailable;
        errdefer std.os.windows.CloseHandle(restricted);

        var sid = win.low_integrity_sid;
        const label: win.TokenMandatoryLabel = .{ .label = .{ .sid = &sid, .attributes = win.se_group_integrity } };
        if (faulted(.label) or win.SetTokenInformation(restricted, win.token_integrity_level, &label, @sizeOf(win.TokenMandatoryLabel) + @sizeOf(win.Sid)) == .FALSE) return error.SandboxUnavailable;
        if ((integrityRid(restricted) catch return error.SandboxUnavailable) != low_integrity_rid) return error.SandboxUnavailable;
        return .{ .handle = restricted };
    }

    fn close(self: LowToken) void {
        std.os.windows.CloseHandle(self.handle);
    }
};

fn integrityRid(token: std.os.windows.HANDLE) !u32 {
    var buf: [64]u8 align(@alignOf(win.TokenMandatoryLabel)) = undefined;
    var returned: std.os.windows.DWORD = 0;
    if (win.GetTokenInformation(token, win.token_integrity_level, &buf, buf.len, &returned) == .FALSE) return error.SandboxUnavailable;
    const label: *const win.TokenMandatoryLabel = @ptrCast(&buf);
    const count = win.GetSidSubAuthorityCount(label.label.sid).*;
    if (count == 0) return error.SandboxUnavailable;
    return win.GetSidSubAuthority(label.label.sid, count - 1).*;
}

fn requireLowIntegrity(process: std.os.windows.HANDLE) error{SandboxUnavailable}!void {
    var token: std.os.windows.HANDLE = undefined;
    if (win.OpenProcessToken(process, win.token_query, &token) == .FALSE) return error.SandboxUnavailable;
    defer std.os.windows.CloseHandle(token);
    const rid = integrityRid(token) catch return error.SandboxUnavailable;
    if (faulted(.verify) or rid > low_integrity_rid) return error.SandboxUnavailable;
}

const Pipe = struct {
    read: std.os.windows.HANDLE,
    write: std.os.windows.HANDLE,

    var serial: std.atomic.Value(u32) = .init(0);

    fn create() !Pipe {
        var name_buf: [96]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "\\\\.\\pipe\\emetgate-sandbox-{d}-{d}-{d}", .{
            win.GetCurrentProcessId(),
            serial.fetchAdd(1, .monotonic),
            win.GetTickCount64(),
        });
        var name_w: [96:0]u16 = undefined;
        const len = try std.unicode.wtf8ToWtf16Le(&name_w, name);
        name_w[len] = 0;

        const read = win.CreateNamedPipeW(
            &name_w,
            win.pipe_access_inbound | win.file_flag_overlapped | win.file_flag_first_pipe_instance,
            win.pipe_type_byte | win.pipe_wait | win.pipe_reject_remote_clients,
            1,
            0,
            64 * 1024,
            0,
            null,
        );
        if (read == std.os.windows.INVALID_HANDLE_VALUE) return error.PipeCreationFailed;
        errdefer std.os.windows.CloseHandle(read);

        var inherit: win.SecurityAttributes = .{ .length = @sizeOf(win.SecurityAttributes), .descriptor = null, .inherit = .TRUE };
        const write = win.CreateFileW(&name_w, win.generic_write | win.file_read_attributes, 0, &inherit, win.open_existing, 0, null);
        if (write == std.os.windows.INVALID_HANDLE_VALUE) return error.PipeCreationFailed;
        return .{ .read = read, .write = write };
    }
};

fn openNul() !std.os.windows.HANDLE {
    var inherit: win.SecurityAttributes = .{ .length = @sizeOf(win.SecurityAttributes), .descriptor = null, .inherit = .TRUE };
    const name = std.unicode.utf8ToUtf16LeStringLiteral("NUL");
    const handle = win.CreateFileW(name, win.generic_read, win.file_share_read | win.file_share_write, &inherit, win.open_existing, 0, null);
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.NulUnavailable;
    return handle;
}

fn spawnRestricted(gpa: Allocator, token: LowToken, command: Command) !std.process.Child {
    if (command.argv.len == 0) return error.FileNotFound;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const program = try resolveProgram(arena, command.cwd, command.argv[0]);
    const command_line = try commandLine(arena, command.argv);
    const cwd = try std.unicode.wtf8ToWtf16LeAllocZ(arena, command.cwd);

    const nul = try openNul();
    defer std.os.windows.CloseHandle(nul);
    const stdout_pipe = try Pipe.create();
    errdefer std.os.windows.CloseHandle(stdout_pipe.read);
    defer std.os.windows.CloseHandle(stdout_pipe.write);
    const stderr_pipe = try Pipe.create();
    errdefer std.os.windows.CloseHandle(stderr_pipe.read);
    defer std.os.windows.CloseHandle(stderr_pipe.write);

    var inherited = [_]std.os.windows.HANDLE{ nul, stdout_pipe.write, stderr_pipe.write };
    var list_size: usize = 0;
    _ = win.InitializeProcThreadAttributeList(null, 1, 0, &list_size);
    const list = try arena.alignedAlloc(u8, .of(usize), list_size);
    if (win.InitializeProcThreadAttributeList(list.ptr, 1, 0, &list_size) == .FALSE) return error.SandboxUnavailable;
    defer win.DeleteProcThreadAttributeList(list.ptr);
    if (win.UpdateProcThreadAttribute(list.ptr, 0, win.proc_thread_attribute_handle_list, &inherited, @sizeOf(@TypeOf(inherited)), null, null) == .FALSE) return error.SandboxUnavailable;

    var startup: win.StartupInfoEx = .{
        .info = std.mem.zeroes(std.os.windows.STARTUPINFOW),
        .attribute_list = list.ptr,
    };
    startup.info.cb = @sizeOf(win.StartupInfoEx);
    startup.info.dwFlags = std.os.windows.STARTF_USESTDHANDLES;
    startup.info.hStdInput = nul;
    startup.info.hStdOutput = stdout_pipe.write;
    startup.info.hStdError = stderr_pipe.write;

    var info: std.os.windows.PROCESS.INFORMATION = undefined;
    const flags = win.create_suspended | win.create_unicode_environment | win.create_no_window | win.extended_startupinfo_present;
    if (faulted(.spawn_as_user) or win.CreateProcessAsUserW(token.handle, program, command_line, null, null, .TRUE, flags, null, cwd, &startup, &info) == .FALSE) {
        if (faulted(.spawn_as_user)) return error.SandboxUnavailable;
        return switch (win.GetLastError()) {
            win.error_file_not_found, win.error_path_not_found, win.error_directory => error.FileNotFound,
            win.error_bad_exe_format => error.InvalidExe,
            else => error.SandboxUnavailable,
        };
    }

    return .{
        .id = info.hProcess,
        .thread_handle = info.hThread,
        .stdin = null,
        .stdout = .{ .handle = stdout_pipe.read, .flags = .{ .nonblocking = true } },
        .stderr = .{ .handle = stderr_pipe.read, .flags = .{ .nonblocking = true } },
        .request_resource_usage_statistics = false,
    };
}

pub fn environmentValue(arena: Allocator, name: [:0]const u16) !?[]u8 {
    const needed = win.GetEnvironmentVariableW(name.ptr, null, 0);
    if (needed == 0) return null;
    const value_w = try arena.alloc(u16, needed);
    const written = win.GetEnvironmentVariableW(name.ptr, value_w.ptr, needed);
    if (written == 0 or written >= needed) return null;
    return try std.unicode.wtf16LeToWtf8Alloc(arena, value_w[0..written]);
}

fn resolveProgram(arena: Allocator, cwd: []const u8, name: []const u8) ![:0]u16 {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) return error.FileNotFound;
    const base = std.fs.path.basename(name);
    const has_extension = std.mem.indexOfScalar(u8, base, '.') != null;
    if (has_extension and !std.ascii.endsWithIgnoreCase(base, ".exe")) return error.InvalidExe;
    const suffix: []const u8 = if (has_extension) "" else ".exe";

    if (std.mem.indexOfAny(u8, name, "\\/:") != null) {
        const candidate = if (std.fs.path.isAbsolute(name))
            try std.fmt.allocPrint(arena, "{s}{s}", .{ name, suffix })
        else
            try std.fmt.allocPrint(arena, "{s}\\{s}{s}", .{ cwd, name, suffix });
        return existingFile(arena, candidate) orelse error.FileNotFound;
    }

    const variable = std.unicode.utf8ToUtf16LeStringLiteral("PATH");
    const needed = win.GetEnvironmentVariableW(variable, null, 0);
    if (needed == 0) return error.FileNotFound;
    const path_w = try arena.alloc(u16, needed);
    const written = win.GetEnvironmentVariableW(variable, path_w.ptr, needed);
    if (written == 0 or written >= needed) return error.FileNotFound;
    const path = try std.unicode.wtf16LeToWtf8Alloc(arena, path_w[0..written]);

    var entries = std.mem.tokenizeScalar(u8, path, ';');
    while (entries.next()) |raw| {
        const dir = std.mem.trim(u8, raw, " \"");
        if (dir.len == 0 or !std.fs.path.isAbsolute(dir)) continue;
        const candidate = try std.fmt.allocPrint(arena, "{s}\\{s}{s}", .{ std.mem.trimEnd(u8, dir, "\\/"), name, suffix });
        if (existingFile(arena, candidate)) |found| return found;
    }
    return error.FileNotFound;
}

fn existingFile(arena: Allocator, path: []const u8) ?[:0]u16 {
    const wide = std.unicode.wtf8ToWtf16LeAllocZ(arena, path) catch return null;
    const attributes = win.GetFileAttributesW(wide);
    if (attributes == win.invalid_file_attributes or attributes & win.file_attribute_directory != 0) return null;
    return wide;
}

fn commandLine(arena: Allocator, argv: []const []const u8) ![:0]u16 {
    var buf: std.ArrayList(u8) = .empty;
    const arg0 = argv[0];
    var needs_quotes = arg0.len == 0;
    for (arg0) |c| {
        if (c <= ' ') needs_quotes = true else if (c == '"') return error.FileNotFound;
    }
    if (needs_quotes) try buf.append(arena, '"');
    try buf.appendSlice(arena, arg0);
    if (needs_quotes) try buf.append(arena, '"');

    for (argv[1..]) |arg| {
        try buf.append(arena, ' ');
        needs_quotes = for (arg) |c| {
            if (c <= ' ' or c == '"') break true;
        } else arg.len == 0;
        if (!needs_quotes) {
            try buf.appendSlice(arena, arg);
            continue;
        }
        try buf.append(arena, '"');
        var backslashes: usize = 0;
        for (arg) |byte| switch (byte) {
            '\\' => backslashes += 1,
            '"' => {
                try buf.appendNTimes(arena, '\\', backslashes * 2 + 1);
                try buf.append(arena, '"');
                backslashes = 0;
            },
            else => {
                try buf.appendNTimes(arena, '\\', backslashes);
                try buf.append(arena, byte);
                backslashes = 0;
            },
        };
        try buf.appendNTimes(arena, '\\', backslashes * 2);
        try buf.append(arena, '"');
    }
    return std.unicode.wtf8ToWtf16LeAllocZ(arena, buf.items);
}

const win = struct {
    const windows = std.os.windows;
    const token_query: windows.DWORD = 0x0008;
    const token_access: windows.DWORD = 0x0001 | 0x0002 | 0x0008 | 0x0080;
    const disable_max_privilege: windows.DWORD = 0x1;
    const token_integrity_level: c_int = 25;
    const se_group_integrity: windows.DWORD = 0x00000020;
    const pipe_access_inbound: windows.DWORD = 0x00000001;
    const file_flag_overlapped: windows.DWORD = 0x40000000;
    const file_flag_first_pipe_instance: windows.DWORD = 0x00080000;
    const pipe_type_byte: windows.DWORD = 0;
    const pipe_wait: windows.DWORD = 0;
    const pipe_reject_remote_clients: windows.DWORD = 0x00000008;
    const generic_read: windows.DWORD = 0x80000000;
    const generic_write: windows.DWORD = 0x40000000;
    const file_read_attributes: windows.DWORD = 0x0080;
    const file_share_read: windows.DWORD = 0x1;
    const file_share_write: windows.DWORD = 0x2;
    const open_existing: windows.DWORD = 3;
    const create_suspended: windows.DWORD = 0x00000004;
    const create_unicode_environment: windows.DWORD = 0x00000400;
    const extended_startupinfo_present: windows.DWORD = 0x00080000;
    const create_no_window: windows.DWORD = 0x08000000;
    const proc_thread_attribute_handle_list: usize = 0x00020002;
    const invalid_file_attributes: windows.DWORD = 0xFFFFFFFF;
    const file_attribute_directory: windows.DWORD = 0x10;
    const error_file_not_found: windows.DWORD = 2;
    const error_path_not_found: windows.DWORD = 3;
    const error_bad_exe_format: windows.DWORD = 193;
    const error_directory: windows.DWORD = 267;

    const Sid = extern struct {
        revision: u8,
        sub_authority_count: u8,
        authority: [6]u8,
        sub_authority: [1]u32,
    };

    const low_integrity_sid: Sid = .{
        .revision = 1,
        .sub_authority_count = 1,
        .authority = .{ 0, 0, 0, 0, 0, 16 },
        .sub_authority = .{low_integrity_rid},
    };

    const SidAndAttributes = extern struct {
        sid: *anyopaque,
        attributes: windows.DWORD,
    };

    const TokenMandatoryLabel = extern struct {
        label: SidAndAttributes,
    };

    const SecurityAttributes = extern struct {
        length: windows.DWORD,
        descriptor: ?*anyopaque,
        inherit: windows.BOOL,
    };

    const StartupInfoEx = extern struct {
        info: windows.STARTUPINFOW,
        attribute_list: ?*anyopaque,
    };

    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) windows.DWORD;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
    extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;
    extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buffer: ?[*]u16, size: windows.DWORD) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn CreateNamedPipeW(name: [*:0]const u16, open_mode: windows.DWORD, pipe_mode: windows.DWORD, max_instances: windows.DWORD, out_size: windows.DWORD, in_size: windows.DWORD, timeout: windows.DWORD, security: ?*SecurityAttributes) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: windows.DWORD, share: windows.DWORD, security: ?*SecurityAttributes, disposition: windows.DWORD, flags: windows.DWORD, template: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: windows.DWORD, flags: windows.DWORD, size: *usize) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn UpdateProcThreadAttribute(list: *anyopaque, flags: windows.DWORD, attribute: usize, value: *anyopaque, size: usize, previous: ?*anyopaque, returned: ?*usize) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(.winapi) void;
    extern "advapi32" fn OpenProcessToken(process: windows.HANDLE, access: windows.DWORD, token: *windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn CreateRestrictedToken(existing: windows.HANDLE, flags: windows.DWORD, disable_count: windows.DWORD, disable: ?*anyopaque, delete_count: windows.DWORD, delete: ?*anyopaque, restrict_count: windows.DWORD, restrict: ?*anyopaque, new_token: *windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn SetTokenInformation(token: windows.HANDLE, class: c_int, info: *const anyopaque, length: windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn GetTokenInformation(token: windows.HANDLE, class: c_int, info: *anyopaque, length: windows.DWORD, returned: *windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn GetSidSubAuthorityCount(sid: *anyopaque) callconv(.winapi) *u8;
    extern "advapi32" fn GetSidSubAuthority(sid: *anyopaque, index: windows.DWORD) callconv(.winapi) *u32;
    extern "advapi32" fn CreateProcessAsUserW(token: ?windows.HANDLE, application: ?[*:0]const u16, command_line: ?[*:0]u16, process_attributes: ?*anyopaque, thread_attributes: ?*anyopaque, inherit_handles: windows.BOOL, flags: windows.DWORD, environment: ?*anyopaque, cwd: ?[*:0]const u16, startup: *StartupInfoEx, info: *windows.PROCESS.INFORMATION) callconv(.winapi) windows.BOOL;

    const job_object_basic_process_id_list: c_int = 3;
    const job_object_extended_limit_information: c_int = 9;
    const limit_kill_on_job_close: u32 = 0x00002000;
    const limit_active_process: u32 = 0x00000008;
    const limit_die_on_unhandled_exception: u32 = 0x00000400;
    const limit_job_memory: u32 = 0x00000200;
    const active_process_cap: u32 = 512;
    const job_memory_cap: usize = 2 * 1024 * 1024 * 1024;
    const job_object_associate_completion_port_information: c_int = 7;
    const job_object_msg_active_process_zero: windows.DWORD = 4;
    const process_console_host_process: c_int = 49;
    const stop_wait_ms: windows.DWORD = 5000;
    const infinite: windows.DWORD = 0xFFFFFFFF;
    const wait_object_0: windows.DWORD = 0;
    const synchronize: windows.DWORD = 0x00100000;
    const terminated_exit_code: windows.UINT = 0xDEAD;

    const BasicLimitInformation = extern struct {
        per_process_user_time_limit: i64,
        per_job_user_time_limit: i64,
        limit_flags: u32,
        minimum_working_set_size: usize,
        maximum_working_set_size: usize,
        active_process_limit: u32,
        affinity: usize,
        priority_class: u32,
        scheduling_class: u32,
    };

    const IoCounters = extern struct {
        read_operation_count: u64,
        write_operation_count: u64,
        other_operation_count: u64,
        read_transfer_count: u64,
        write_transfer_count: u64,
        other_transfer_count: u64,
    };

    const ExtendedLimitInformation = extern struct {
        basic: BasicLimitInformation,
        io: IoCounters,
        process_memory_limit: usize,
        job_memory_limit: usize,
        peak_process_memory_used: usize,
        peak_job_memory_used: usize,
    };

    comptime {
        if (builtin.cpu.arch == .x86_64) std.debug.assert(@sizeOf(ExtendedLimitInformation) == 144);
    }

    const AssociateCompletionPort = extern struct {
        key: ?*anyopaque,
        port: windows.HANDLE,
    };

    extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn SetInformationJobObject(job: windows.HANDLE, class: c_int, info: *const anyopaque, length: windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn QueryInformationJobObject(job: windows.HANDLE, class: c_int, info: *anyopaque, length: windows.DWORD, returned: ?*windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn AssignProcessToJobObject(job: windows.HANDLE, process: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn TerminateJobObject(job: windows.HANDLE, exit_code: windows.UINT) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, milliseconds: windows.DWORD) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn GetExitCodeProcess(process: windows.HANDLE, code: *windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn OpenProcess(access: windows.DWORD, inherit: windows.BOOL, pid: windows.DWORD) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn GetProcessId(process: windows.HANDLE) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn CreateIoCompletionPort(file: windows.HANDLE, existing: ?windows.HANDLE, key: usize, threads: windows.DWORD) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn GetQueuedCompletionStatus(port: windows.HANDLE, bytes: *windows.DWORD, key: *usize, overlapped: *?*anyopaque, milliseconds: windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "ntdll" fn NtQueryInformationProcess(process: windows.HANDLE, class: c_int, info: *anyopaque, length: windows.ULONG, returned: ?*windows.ULONG) callconv(.winapi) windows.NTSTATUS;
};

const Job = struct {
    handle: std.os.windows.HANDLE,
    port: std.os.windows.HANDLE,

    fn create() !Job {
        const handle = win.CreateJobObjectW(null, null) orelse return error.JobCreationFailed;
        errdefer std.os.windows.CloseHandle(handle);
        var info = std.mem.zeroes(win.ExtendedLimitInformation);
        info.basic.limit_flags = win.limit_kill_on_job_close | win.limit_active_process | win.limit_die_on_unhandled_exception | win.limit_job_memory;
        info.basic.active_process_limit = win.active_process_cap;
        info.job_memory_limit = win.job_memory_cap;
        if (win.SetInformationJobObject(handle, win.job_object_extended_limit_information, &info, @sizeOf(win.ExtendedLimitInformation)) == .FALSE) {
            return error.JobConfigurationFailed;
        }
        const port = win.CreateIoCompletionPort(std.os.windows.INVALID_HANDLE_VALUE, null, 0, 1) orelse return error.JobConfigurationFailed;
        errdefer std.os.windows.CloseHandle(port);
        const association: win.AssociateCompletionPort = .{ .key = null, .port = port };
        if (win.SetInformationJobObject(handle, win.job_object_associate_completion_port_information, &association, @sizeOf(win.AssociateCompletionPort)) == .FALSE) {
            return error.JobConfigurationFailed;
        }
        return .{ .handle = handle, .port = port };
    }

    fn leftovers(self: Job, console_host: ?usize) !usize {
        var buf: [2 * @sizeOf(u32) + win.active_process_cap * @sizeOf(usize)]u8 align(@alignOf(usize)) = undefined;
        if (win.QueryInformationJobObject(self.handle, win.job_object_basic_process_id_list, &buf, buf.len, null) == .FALSE) {
            return error.JobQueryFailed;
        }
        const listed = std.mem.readInt(u32, buf[4..8], .little);
        const pids = std.mem.bytesAsSlice(usize, buf[8..][0 .. listed * @sizeOf(usize)]);
        return leftoverCount(@alignCast(pids), console_host);
    }

    fn outlasts(self: Job, console_host: ?usize, wait_ms: std.os.windows.DWORD) bool {
        const until = win.GetTickCount64() + wait_ms;
        while (true) {
            if ((self.leftovers(console_host) catch return true) == 0) return false;
            const now = win.GetTickCount64();
            if (now >= until) return true;
            var message: std.os.windows.DWORD = 0;
            var key: usize = 0;
            var overlapped: ?*anyopaque = null;
            if (win.GetQueuedCompletionStatus(self.port, &message, &key, &overlapped, @intCast(until - now)) == .FALSE) continue;
            if (message == win.job_object_msg_active_process_zero) return false;
        }
    }

    fn assign(self: Job, process: std.os.windows.HANDLE) !void {
        if (win.AssignProcessToJobObject(self.handle, process) == .FALSE) return error.JobAssignmentFailed;
    }

    fn terminate(self: Job) void {
        _ = win.TerminateJobObject(self.handle, win.terminated_exit_code);
    }

    fn stop(self: Job) void {
        self.terminate();
        const emptied = !self.outlasts(null, win.stop_wait_ms);
        if (builtin.is_test) last_stop_emptied = emptied;
    }

    fn close(self: Job) void {
        std.os.windows.CloseHandle(self.handle);
        std.os.windows.CloseHandle(self.port);
    }
};

fn resumeMainThread(thread: std.os.windows.HANDLE) !void {
    switch (std.os.windows.ntdll.NtResumeThread(thread, null)) {
        .SUCCESS => {},
        else => return error.ResumeFailed,
    }
}

fn waitExitCode(process: std.os.windows.HANDLE) !u32 {
    if (win.WaitForSingleObject(process, win.infinite) != win.wait_object_0) return error.WaitFailed;
    var code: std.os.windows.DWORD = 0;
    if (win.GetExitCodeProcess(process, &code) == .FALSE) return error.WaitFailed;
    return code;
}

const testing = std.testing;
const build_options = @import("build_options");

fn probe(args: []const []const u8, limits: Limits) !Report {
    var argv_buf: [8][]const u8 = undefined;
    argv_buf[0] = build_options.probe_path;
    @memcpy(argv_buf[1..][0..args.len], args);
    return run(testing.allocator, testing.io, .{ .argv = argv_buf[0 .. args.len + 1], .cwd = ".", .limits = limits });
}

fn processIsGone(pid: u32) bool {
    const handle = win.OpenProcess(win.synchronize, .FALSE, pid) orelse return true;
    defer std.os.windows.CloseHandle(handle);
    return win.WaitForSingleObject(handle, 5000) == win.wait_object_0;
}

test "the job actually carries every limit we claim to set" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const job = try Job.create();
    defer job.close();

    var info: win.ExtendedLimitInformation = undefined;
    var returned: std.os.windows.DWORD = 0;
    try testing.expect(win.QueryInformationJobObject(
        job.handle,
        win.job_object_extended_limit_information,
        &info,
        @sizeOf(win.ExtendedLimitInformation),
        &returned,
    ) != .FALSE);

    try testing.expect(info.basic.limit_flags & win.limit_kill_on_job_close != 0);
    try testing.expect(info.basic.limit_flags & win.limit_active_process != 0);
    try testing.expect(info.basic.limit_flags & win.limit_die_on_unhandled_exception != 0);
    try testing.expect(info.basic.limit_flags & win.limit_job_memory != 0);
    try testing.expectEqual(win.active_process_cap, info.basic.active_process_limit);
    try testing.expectEqual(@as(usize, 2 * 1024 * 1024 * 1024), info.job_memory_limit);
}

fn printReport(report: Report) void {
    std.debug.print("outcome {any}, killed_leftovers {any}, duration {d} ms, stderr: {s}\n", .{ report.outcome, report.killed_leftovers, report.duration_ns / std.time.ns_per_ms, report.stderr });
}

test "a clean exit passes and both streams are captured separately" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const report = try probe(&.{"both"}, .{ .timeout_ms = 10_000 });
    defer report.deinit(testing.allocator);
    errdefer printReport(report);

    try testing.expect(report.passed());
    try testing.expectEqual(Outcome{ .exited = 0 }, report.outcome);
    try testing.expectEqualStrings("to stdout\n", report.stdout);
    try testing.expectEqualStrings("to stderr\n", report.stderr);
    try testing.expect(!report.truncated);
}

test "exit codes are reported as full 32-bit values, so 256 never reads as success" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const codes = [_]struct { arg: []const u8, expected: Outcome }{
        .{ .arg = "3", .expected = .{ .exited = 3 } },
        .{ .arg = "256", .expected = .{ .exited = 256 } },
        .{ .arg = "3221225477", .expected = .{ .crashed = 0xC0000005 } },
    };
    for (codes) |code| {
        errdefer std.debug.print("exit code {s} misreported\n", .{code.arg});
        const report = try probe(&.{ "exit", code.arg }, .{ .timeout_ms = 10_000 });
        defer report.deinit(testing.allocator);
        try testing.expectEqual(code.expected, report.outcome);
        try testing.expect(!report.passed());
    }
}

test "an NTSTATUS error exit is a crash, not a verdict, and ordinary codes stay exits" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const cases = [_]struct { command: []const u8, expected: Outcome }{
        .{ .command = "exit -1073741502", .expected = .{ .crashed = 0xC0000142 } },
        .{ .command = "exit -1073741824", .expected = .{ .crashed = 0xC0000000 } },
        .{ .command = "exit 2", .expected = .{ .exited = 2 } },
        .{ .command = "exit 57005", .expected = .{ .exited = 0xDEAD } },
    };
    for (cases) |c| {
        errdefer std.debug.print("command {s} misclassified\n", .{c.command});
        const argv = [_][]const u8{ "cmd.exe", "/d", "/c", c.command };
        const report = try run(testing.allocator, testing.io, .{ .argv = &argv, .cwd = ".", .limits = .{ .timeout_ms = 10_000 } });
        defer report.deinit(testing.allocator);
        try testing.expectEqual(c.expected, report.outcome);
        try testing.expect(!report.passed());
    }
}

test "an infinite loop is killed at the deadline" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const report = try probe(&.{"spin"}, .{ .timeout_ms = 300 });
    defer report.deinit(testing.allocator);

    try testing.expectEqual(Outcome.timed_out, report.outcome);
    try testing.expect(!report.passed());
    try testing.expect(report.duration_ns >= 300 * std.time.ns_per_ms);
    try testing.expect(report.duration_ns < 10 * std.time.ns_per_s);
}

test "an output flood is cut at the byte limit and marked truncated" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const limit = 64 * 1024;
    const report = try probe(&.{"flood"}, .{ .timeout_ms = 10_000, .max_output_bytes = limit });
    defer report.deinit(testing.allocator);

    try testing.expectEqual(Outcome.output_limit, report.outcome);
    try testing.expect(!report.passed());
    try testing.expect(report.truncated);
    try testing.expectEqual(@as(usize, limit), report.stdout.len);
    try testing.expect(std.mem.startsWith(u8, report.stdout, "flood flood"));
}

test "grandchild processes die with the job when the command times out" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const report = try probe(&.{"grandchild"}, .{ .timeout_ms = 1500 });
    defer report.deinit(testing.allocator);

    try testing.expectEqual(Outcome.timed_out, report.outcome);
    const pid = try std.fmt.parseInt(u32, std.mem.trim(u8, report.stdout, " \r\n"), 10);
    try testing.expect(processIsGone(pid));
}

fn processIsGoneNow(pid: u32) bool {
    const handle = win.OpenProcess(win.synchronize, .FALSE, pid) orelse return true;
    defer std.os.windows.CloseHandle(handle);
    return win.WaitForSingleObject(handle, 0) == win.wait_object_0;
}

test "a timed out run returns only after every process in its job has exited" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    last_stop_emptied = null;
    const report = try probe(&.{"grandchild"}, .{ .timeout_ms = 1500 });
    defer report.deinit(testing.allocator);
    errdefer printReport(report);

    try testing.expectEqual(Outcome.timed_out, report.outcome);
    try testing.expectEqual(@as(?bool, true), last_stop_emptied);
    const pid = try std.fmt.parseInt(u32, std.mem.trim(u8, report.stdout, " \r\n"), 10);
    try testing.expect(processIsGoneNow(pid));
}

test "a command that exits but leaves a background process is reported by its own exit code" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const report = try probe(&.{"orphan"}, .{ .timeout_ms = 20_000 });
    defer report.deinit(testing.allocator);
    errdefer printReport(report);

    try testing.expectEqual(Outcome{ .exited = 0 }, report.outcome);
    try testing.expect(report.killed_leftovers);
    try testing.expect(!report.passed());
    try testing.expect(report.duration_ns < 5 * std.time.ns_per_s);
    const pid = try std.fmt.parseInt(u32, std.mem.trim(u8, report.stdout, " \r\n"), 10);
    try testing.expect(processIsGone(pid));
}

test "a detached worker that holds no pipe is still caught by job accounting, not passed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const report = try probe(&.{"detached"}, .{ .timeout_ms = 20_000 });
    defer report.deinit(testing.allocator);
    errdefer printReport(report);

    try testing.expectEqual(Outcome{ .exited = 0 }, report.outcome);
    try testing.expect(report.killed_leftovers);
    try testing.expect(!report.passed());
    try testing.expect(report.duration_ns < 5 * std.time.ns_per_s);
    const pid = try std.fmt.parseInt(u32, std.mem.trim(u8, report.stdout, " \r\n"), 10);
    try testing.expect(processIsGone(pid));
}

test "a worker that holds the pipe and ends within the grace is waited for, not reported as a leftover" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const report = try probe(&.{ "linger", "700" }, .{ .timeout_ms = 20_000 });
    defer report.deinit(testing.allocator);
    errdefer printReport(report);

    try testing.expect(!report.killed_leftovers);
    try testing.expect(report.passed());
    try testing.expect(report.duration_ns >= 700 * std.time.ns_per_ms);
}

test "a detached worker that ends within the grace is waited for through the job, not reported as a leftover" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const report = try probe(&.{ "drift", "700" }, .{ .timeout_ms = 20_000 });
    defer report.deinit(testing.allocator);
    errdefer printReport(report);

    try testing.expect(!report.killed_leftovers);
    try testing.expect(report.passed());
    try testing.expect(report.duration_ns >= 700 * std.time.ns_per_ms);
}

test "the leftover wait ends at the command's deadline, not after the full grace" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const report = try probe(&.{ "drift", "20000" }, .{ .timeout_ms = 300 });
    defer report.deinit(testing.allocator);
    errdefer printReport(report);

    try testing.expect(report.killed_leftovers);
    try testing.expect(!report.passed());
    try testing.expect(report.duration_ns < 1800 * std.time.ns_per_ms);
}

test "the exited command's own console host is not a leftover, any other process in the job is" {
    try testing.expectEqual(@as(usize, 0), leftoverCount(&.{}, null));
    try testing.expectEqual(@as(usize, 0), leftoverCount(&.{9488}, 9488));
    try testing.expectEqual(@as(usize, 1), leftoverCount(&.{ 9488, 7020 }, 9488));
    try testing.expectEqual(@as(usize, 1), leftoverCount(&.{9488}, null));
    try testing.expectEqual(@as(usize, 2), leftoverCount(&.{ 9488, 7020 }, 4100));
}

test "a process that closes its output and keeps running is killed at the deadline" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const report = try probe(&.{"closeout"}, .{ .timeout_ms = 1000 });
    defer report.deinit(testing.allocator);

    try testing.expectEqual(Outcome.timed_out, report.outcome);
    try testing.expect(!report.passed());
    try testing.expect(report.duration_ns >= 1000 * std.time.ns_per_ms);
    try testing.expect(report.duration_ns < 10 * std.time.ns_per_s);
}

test "a second concurrent run is refused instead of sharing inherited pipes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    running.store(true, .release);
    defer running.store(false, .release);
    try testing.expectError(error.SandboxBusy, probe(&.{"both"}, .{ .timeout_ms = 1000 }));
}

test "a program that does not exist is an error, not a hang" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try testing.expectError(error.FileNotFound, run(testing.allocator, testing.io, .{
        .argv = &.{"emetgate-definitely-missing-program"},
        .cwd = ".",
        .limits = .{ .timeout_ms = 1000 },
    }));
}
