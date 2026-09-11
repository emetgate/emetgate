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
            .exited => |code| code == 0,
            .timed_out, .output_limit => false,
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

const read_reserve = 4096;
const exit_poll_ns = 50 * std.time.ns_per_ms;

pub fn run(gpa: Allocator, io: std.Io, command: Command) !Report {
    if (builtin.os.tag != .windows) return error.SandboxUnsupported;

    const job = try Job.create();
    defer job.close();

    const started = std.Io.Timestamp.now(io, .awake);
    var child = try std.process.spawn(io, .{
        .argv = command.argv,
        .cwd = .{ .path = command.cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .start_suspended = true,
        .create_no_window = true,
    });
    defer child.kill(io);
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
                if (!killed_leftovers and hasExited(child.id.?)) {
                    job.terminate();
                    killed_leftovers = true;
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
    if (stopped != null) job.terminate() else try reader.checkAnyError();

    const exit_code = try waitExitCode(child.id.?);
    _ = try child.wait(io);
    const duration_ns: u64 = @intCast(started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);

    var truncated = false;
    const stdout = try takeStream(gpa, &reader, 0, limit, &truncated);
    errdefer gpa.free(stdout);
    const stderr = try takeStream(gpa, &reader, 1, limit, &truncated);

    return .{
        .outcome = stopped orelse .{ .exited = exit_code },
        .duration_ns = duration_ns,
        .stdout = stdout,
        .stderr = stderr,
        .truncated = truncated,
        .killed_leftovers = killed_leftovers,
    };
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

const win = struct {
    const windows = std.os.windows;
    const job_object_extended_limit_information: c_int = 9;
    const limit_kill_on_job_close: u32 = 0x00002000;
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

    extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn SetInformationJobObject(job: windows.HANDLE, class: c_int, info: *const anyopaque, length: windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn AssignProcessToJobObject(job: windows.HANDLE, process: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn TerminateJobObject(job: windows.HANDLE, exit_code: windows.UINT) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, milliseconds: windows.DWORD) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn GetExitCodeProcess(process: windows.HANDLE, code: *windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn OpenProcess(access: windows.DWORD, inherit: windows.BOOL, pid: windows.DWORD) callconv(.winapi) ?windows.HANDLE;
};

const Job = struct {
    handle: std.os.windows.HANDLE,

    fn create() !Job {
        const handle = win.CreateJobObjectW(null, null) orelse return error.JobCreationFailed;
        errdefer std.os.windows.CloseHandle(handle);
        var info = std.mem.zeroes(win.ExtendedLimitInformation);
        info.basic.limit_flags = win.limit_kill_on_job_close;
        if (win.SetInformationJobObject(handle, win.job_object_extended_limit_information, &info, @sizeOf(win.ExtendedLimitInformation)) == .FALSE) {
            return error.JobConfigurationFailed;
        }
        return .{ .handle = handle };
    }

    fn assign(self: Job, process: std.os.windows.HANDLE) !void {
        if (win.AssignProcessToJobObject(self.handle, process) == .FALSE) return error.JobAssignmentFailed;
    }

    fn terminate(self: Job) void {
        _ = win.TerminateJobObject(self.handle, win.terminated_exit_code);
    }

    fn close(self: Job) void {
        std.os.windows.CloseHandle(self.handle);
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

test "a clean exit passes and both streams are captured separately" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const report = try probe(&.{"both"}, .{ .timeout_ms = 10_000 });
    defer report.deinit(testing.allocator);

    try testing.expect(report.passed());
    try testing.expectEqual(Outcome{ .exited = 0 }, report.outcome);
    try testing.expectEqualStrings("to stdout\n", report.stdout);
    try testing.expectEqualStrings("to stderr\n", report.stderr);
    try testing.expect(!report.truncated);
}

test "exit codes are reported as full 32-bit values, so 256 never reads as success" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const codes = [_]struct { arg: []const u8, value: u32 }{
        .{ .arg = "3", .value = 3 },
        .{ .arg = "256", .value = 256 },
        .{ .arg = "3221225477", .value = 0xC0000005 },
    };
    for (codes) |code| {
        errdefer std.debug.print("exit code {s} misreported\n", .{code.arg});
        const report = try probe(&.{ "exit", code.arg }, .{ .timeout_ms = 10_000 });
        defer report.deinit(testing.allocator);
        try testing.expectEqual(Outcome{ .exited = code.value }, report.outcome);
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

test "a command that exits but leaves a background process is reported by its own exit code" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const report = try probe(&.{"orphan"}, .{ .timeout_ms = 20_000 });
    defer report.deinit(testing.allocator);

    try testing.expectEqual(Outcome{ .exited = 0 }, report.outcome);
    try testing.expect(report.passed());
    try testing.expect(report.killed_leftovers);
    try testing.expect(report.duration_ns < 5 * std.time.ns_per_s);
    const pid = try std.fmt.parseInt(u32, std.mem.trim(u8, report.stdout, " \r\n"), 10);
    try testing.expect(processIsGone(pid));
}

test "a program that does not exist is an error, not a hang" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try testing.expectError(error.FileNotFound, run(testing.allocator, testing.io, .{
        .argv = &.{"synapse-definitely-missing-program"},
        .cwd = ".",
        .limits = .{ .timeout_ms = 1000 },
    }));
}
