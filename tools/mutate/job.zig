const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const windows = std.os.windows;

pub fn run(gpa: Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8, output_limit: usize, timeout_s: u64) !std.process.RunResult {
    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = .{ .nanoseconds = @as(i96, timeout_s) * std.time.ns_per_s },
        .clock = .awake,
    } };
    if (builtin.os.tag != .windows) {
        return std.process.run(gpa, io, .{
            .argv = argv,
            .cwd = if (cwd) |path| .{ .path = path } else .inherit,
            .stdout_limit = .limited(output_limit),
            .stderr_limit = .limited(output_limit),
            .timeout = timeout,
        });
    }

    const job = try Job.create();
    defer job.close();

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
        .start_suspended = true,
    });
    defer child.kill(io);
    try job.assign(child.id.?);
    if (windows.ntdll.NtResumeThread(child.thread_handle, null) != .SUCCESS) return error.ResumeFailed;

    var streams: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(gpa, io, streams.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();

    const deadline = timeout.toDeadline(io);
    while (reader.fill(64, deadline)) |_| {
        if (reader.reader(0).buffered().len > output_limit or reader.reader(1).buffered().len > output_limit) {
            try job.stop();
            return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => {
            try job.stop();
            return error.Timeout;
        },
        else => |e| return e,
    }
    try reader.checkAnyError();
    const term = try child.wait(io);
    try job.stop();

    const stdout = try reader.toOwnedSlice(0);
    errdefer gpa.free(stdout);
    const stderr = try reader.toOwnedSlice(1);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

const Job = struct {
    handle: windows.HANDLE,

    fn create() !Job {
        const handle = win.CreateJobObjectW(null, null) orelse return error.JobCreationFailed;
        errdefer windows.CloseHandle(handle);
        var info = std.mem.zeroes(win.ExtendedLimitInformation);
        info.basic.limit_flags = win.limit_kill_on_job_close;
        if (win.SetInformationJobObject(handle, win.extended_limit_information, &info, @sizeOf(win.ExtendedLimitInformation)) == .FALSE) {
            return error.JobConfigurationFailed;
        }
        return .{ .handle = handle };
    }

    fn assign(self: Job, process: windows.HANDLE) !void {
        if (win.AssignProcessToJobObject(self.handle, process) == .FALSE) return error.JobAssignmentFailed;
    }

    fn stop(self: Job) !void {
        _ = win.TerminateJobObject(self.handle, win.terminated_exit_code);
        var waited: u32 = 0;
        while (try self.activeProcesses() != 0) : (waited += win.poll_ms) {
            if (waited >= win.drain_limit_ms) return error.JobDidNotEmpty;
            win.Sleep(win.poll_ms);
        }
    }

    fn activeProcesses(self: Job) !u32 {
        var info: win.BasicAccountingInformation = undefined;
        if (win.QueryInformationJobObject(self.handle, win.basic_accounting_information, &info, @sizeOf(win.BasicAccountingInformation), null) == .FALSE) {
            return error.JobQueryFailed;
        }
        return info.active_processes;
    }

    fn close(self: Job) void {
        windows.CloseHandle(self.handle);
    }
};

const win = struct {
    const basic_accounting_information: c_int = 1;
    const extended_limit_information: c_int = 9;
    const limit_kill_on_job_close: u32 = 0x00002000;
    const terminated_exit_code: windows.UINT = 0xDEAD;
    const poll_ms: u32 = 10;
    const drain_limit_ms: u32 = 30_000;

    const BasicAccountingInformation = extern struct {
        total_user_time: i64,
        total_kernel_time: i64,
        this_period_total_user_time: i64,
        this_period_total_kernel_time: i64,
        total_page_fault_count: u32,
        total_processes: u32,
        active_processes: u32,
        total_terminated_processes: u32,
    };

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

    extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn SetInformationJobObject(job: windows.HANDLE, class: c_int, info: *const anyopaque, length: windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn QueryInformationJobObject(job: windows.HANDLE, class: c_int, info: *anyopaque, length: windows.DWORD, returned: ?*windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn AssignProcessToJobObject(job: windows.HANDLE, process: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn TerminateJobObject(job: windows.HANDLE, exit_code: windows.UINT) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn Sleep(milliseconds: windows.DWORD) callconv(.winapi) void;
};
