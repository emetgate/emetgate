const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const max_threads = 8;

pub const Task = *const fn (ctx: *anyopaque) void;

pub const Pool = struct {
    threads: [max_threads]std.Thread = undefined,
    go: [max_threads]windows.HANDLE = undefined,
    done: ?windows.HANDLE = null,
    count: usize = 0,
    pending: std.atomic.Value(usize) = .init(0),
    task: ?Task = null,
    ctx: *anyopaque = undefined,
    stop: bool = false,

    pub fn start(self: *Pool, wanted: usize) void {
        self.* = .{};
        if (builtin.os.tag != .windows) return;
        const cpus = std.Thread.getCpuCount() catch 1;
        const extra = @min(@min(wanted, max_threads), cpus) -| 1;
        self.done = win.CreateEventW(null, .FALSE, .FALSE, null) orelse return;
        var i: usize = 0;
        while (i < extra) : (i += 1) {
            self.go[i] = win.CreateEventW(null, .FALSE, .FALSE, null) orelse break;
            self.threads[i] = std.Thread.spawn(.{}, loop, .{ self, i }) catch {
                windows.CloseHandle(self.go[i]);
                break;
            };
        }
        self.count = i;
    }

    pub fn deinit(self: *Pool) void {
        _ = self.release();
    }

    pub fn release(self: *Pool) usize {
        if (builtin.os.tag != .windows) return 0;
        const done = self.done orelse return 0;
        self.stop = true;
        for (0..self.count) |i| _ = win.SetEvent(self.go[i]);
        for (self.threads[0..self.count]) |t| t.join();
        var unclosed: usize = 0;
        for (0..self.count) |i| unclosed += @intFromBool(win.CloseHandle(self.go[i]) == .FALSE);
        unclosed += @intFromBool(win.CloseHandle(done) == .FALSE);
        self.done = null;
        self.count = 0;
        return unclosed;
    }

    pub fn helpers(self: *const Pool) usize {
        return self.count;
    }

    pub fn run(self: *Pool, use: usize, task: Task, ctx: *anyopaque) void {
        const n = @min(use, self.count);
        if (n == 0) {
            task(ctx);
            return;
        }
        self.task = task;
        self.ctx = ctx;
        self.pending.store(n, .release);
        for (0..n) |i| _ = win.SetEvent(self.go[i]);
        task(ctx);
        _ = win.WaitForSingleObject(self.done.?, win.infinite);
        self.task = null;
    }

    fn loop(self: *Pool, i: usize) void {
        while (true) {
            _ = win.WaitForSingleObject(self.go[i], win.infinite);
            if (self.stop) return;
            if (self.task) |task| task(self.ctx);
            if (self.pending.fetchSub(1, .acq_rel) == 1) _ = win.SetEvent(self.done.?);
        }
    }
};

const win = struct {
    const infinite: windows.DWORD = 0xFFFFFFFF;
    extern "kernel32" fn CreateEventW(security: ?*anyopaque, manual: windows.BOOL, initial: windows.BOOL, name: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn SetEvent(event: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, milliseconds: windows.DWORD) callconv(.winapi) windows.DWORD;
};

const testing = std.testing;

const Counter = struct {
    next: std.atomic.Value(usize) = .init(0),
    seen: [1000]std.atomic.Value(u8) = [_]std.atomic.Value(u8){.init(0)} ** 1000,

    fn work(ctx: *anyopaque) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        while (true) {
            const i = self.next.fetchAdd(1, .monotonic);
            if (i >= self.seen.len) return;
            _ = self.seen[i].fetchAdd(1, .monotonic);
        }
    }
};

test "a pool runs a task on its helpers and the caller, and every item is done exactly once, round after round" {
    var pool: Pool = undefined;
    pool.start(4);
    defer pool.deinit();
    for (0..50) |_| {
        var counter: Counter = .{};
        pool.run(4, Counter.work, &counter);
        for (&counter.seen) |*s| try testing.expectEqual(@as(u8, 1), s.load(.monotonic));
    }
}

test "a pool that was never started, and one torn down twice, closes no handle it does not hold" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var idle: Pool = .{};
    try testing.expectEqual(@as(usize, 0), idle.release());
    idle.deinit();

    var pool: Pool = undefined;
    pool.start(4);
    var counter: Counter = .{};
    pool.run(4, Counter.work, &counter);
    try testing.expectEqual(@as(usize, 0), pool.release());
    try testing.expectEqual(@as(usize, 0), pool.release());
    try testing.expectEqual(@as(usize, 0), pool.helpers());
}
