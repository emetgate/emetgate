const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const MultiReader = std.Io.File.MultiReader;

pub const default_timeout_ms: u64 = 120_000;

pub fn timeoutMs(ms: u64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms }, .clock = .awake } };
}

pub fn run(gpa: Allocator, io: std.Io, options: std.process.RunOptions) !std.process.RunResult {
    return runWith(gpa, io, options, null);
}

pub fn runFed(gpa: Allocator, io: std.Io, options: std.process.RunOptions, input: []const u8) !std.process.RunResult {
    return runWith(gpa, io, options, input);
}

fn runWith(gpa: Allocator, io: std.Io, options: std.process.RunOptions, input: ?[]const u8) !std.process.RunResult {
    const timeout: std.Io.Timeout = if (options.timeout == .none) timeoutMs(default_timeout_ms) else options.timeout;
    if (builtin.os.tag != .windows and input == null) {
        var bounded = options;
        bounded.timeout = timeout;
        return std.process.run(gpa, io, bounded);
    }
    const job = Job.create();
    defer if (job) |j| j.close();
    var child = try std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .expand_arg0 = options.expand_arg0,
        .create_no_window = options.create_no_window,
        .stdin = if (input == null) .ignore else .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .start_suspended = builtin.os.tag == .windows,
    });
    defer child.kill(io);
    if (builtin.os.tag == .windows) {
        if (job) |j| j.assign(child.id.?);
        switch (std.os.windows.ntdll.NtResumeThread(child.thread_handle, null)) {
            .SUCCESS => {},
            else => return error.ResumeFailed,
        }
    }
    if (input) |bytes| {
        const stdin = child.stdin.?;
        child.stdin = null;
        defer stdin.close(io);
        try stdin.writeStreamingAll(io, bytes);
    }

    var streams: MultiReader.Buffer(2) = undefined;
    var reader: MultiReader = undefined;
    reader.init(gpa, io, streams.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer {
        if (job) |j| j.terminate();
        child.kill(io);
        reader.deinit();
    }

    const deadline = timeout.toDeadline(io);
    while (reader.fill(options.reserve_amount, deadline)) |_| {
        if (options.stdout_limit.toInt()) |limit| if (reader.reader(0).buffered().len > limit) return error.StreamTooLong;
        if (options.stderr_limit.toInt()) |limit| if (reader.reader(1).buffered().len > limit) return error.StreamTooLong;
        if (deadline.toDurationFromNow(io)) |left| if (left.raw.nanoseconds <= 0) return error.Timeout;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try reader.checkAnyError();
    const term = try child.wait(io);
    const stdout = try reader.toOwnedSlice(0);
    errdefer gpa.free(stdout);
    const stderr = try reader.toOwnedSlice(1);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

pub const Guard = struct {
    job: ?Job,

    pub fn adopt(child: *const std.process.Child) Guard {
        if (builtin.os.tag != .windows) return .{ .job = null };
        const job = Job.create();
        if (job) |j| j.assign(child.id.?);
        return .{ .job = job };
    }

    pub fn wait(self: Guard, io: std.Io, child: *std.process.Child, ms: u64) !std.process.Child.Term {
        if (builtin.os.tag == .windows) {
            const limit: u32 = @intCast(@min(ms, std.math.maxInt(u32) - 1));
            if (win.WaitForSingleObject(child.id.?, limit) != 0) {
                if (self.job) |j| j.terminate();
                child.kill(io);
                return error.Timeout;
            }
        }
        return child.wait(io);
    }

    pub fn release(self: Guard) void {
        if (self.job) |j| {
            j.terminate();
            j.close();
        }
    }
};

const Job = struct {
    handle: std.os.windows.HANDLE,

    fn create() ?Job {
        const handle = win.CreateJobObjectW(null, null) orelse return null;
        var info = std.mem.zeroes(win.ExtendedLimitInformation);
        info.basic.limit_flags = win.limit_kill_on_job_close;
        if (win.SetInformationJobObject(handle, win.job_object_extended_limit_information, &info, @sizeOf(win.ExtendedLimitInformation)) == .FALSE) {
            std.os.windows.CloseHandle(handle);
            return null;
        }
        return .{ .handle = handle };
    }

    fn assign(self: Job, process: std.os.windows.HANDLE) void {
        _ = win.AssignProcessToJobObject(self.handle, process);
    }

    fn terminate(self: Job) void {
        _ = win.TerminateJobObject(self.handle, 1);
    }

    fn close(self: Job) void {
        std.os.windows.CloseHandle(self.handle);
    }
};

const win = struct {
    const windows = std.os.windows;
    const limit_kill_on_job_close: u32 = 0x2000;
    const job_object_extended_limit_information: c_int = 9;

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

    const ExtendedLimitInformation = extern struct {
        basic: BasicLimitInformation,
        io: [6]u64,
        process_memory_limit: usize,
        job_memory_limit: usize,
        peak_process_memory_used: usize,
        peak_job_memory_used: usize,
    };

    extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn SetInformationJobObject(job: windows.HANDLE, class: c_int, info: *const anyopaque, length: windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn AssignProcessToJobObject(job: windows.HANDLE, process: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn TerminateJobObject(job: windows.HANDLE, exit_code: windows.UINT) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, ms: windows.DWORD) callconv(.winapi) windows.DWORD;
};

test "a child that outlives its timeout is killed and the call returns" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const started = std.Io.Timestamp.now(std.testing.io, .awake);
    const result = run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "powershell.exe", "-NoProfile", "-Command", "Start-Sleep -Seconds 30" },
        .timeout = timeoutMs(500),
    });
    try std.testing.expectError(error.Timeout, result);
    const elapsed = started.durationTo(std.Io.Timestamp.now(std.testing.io, .awake)).nanoseconds;
    try std.testing.expect(elapsed < 10 * std.time.ns_per_s);
}

test "a child that floods its output with no limit is still stopped at its timeout" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const started = std.Io.Timestamp.now(std.testing.io, .awake);
    const result = run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "powershell.exe", "-NoProfile", "-Command", "while ($true) { [Console]::Out.Write(('x' * 65536)) }" },
        .stdout_limit = .unlimited,
        .timeout = timeoutMs(500),
    });
    try std.testing.expectError(error.Timeout, result);
    const elapsed = started.durationTo(std.Io.Timestamp.now(std.testing.io, .awake)).nanoseconds;
    try std.testing.expect(elapsed < 15 * std.time.ns_per_s);
}

test "output over the limit stops the child instead of hanging" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const started = std.Io.Timestamp.now(std.testing.io, .awake);
    const result = run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "powershell.exe", "-NoProfile", "-Command", "while ($true) { [Console]::Out.Write(('x' * 65536)) }" },
        .stdout_limit = .limited(1024 * 1024),
        .timeout = timeoutMs(5_000),
    });
    try std.testing.expectError(error.StreamTooLong, result);
    const elapsed = started.durationTo(std.Io.Timestamp.now(std.testing.io, .awake)).nanoseconds;
    try std.testing.expect(elapsed < 15 * std.time.ns_per_s);
}
