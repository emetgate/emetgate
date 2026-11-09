const std = @import("std");
const windows = std.os.windows;

const Allocator = std.mem.Allocator;

pub const user_agent = "emetgate-update";

pub const Url = struct {
    host: []const u8,
    path: []const u8,

    pub fn parse(url: []const u8) ?Url {
        const scheme = "https://";
        if (!std.mem.startsWith(u8, url, scheme)) return null;
        const rest = url[scheme.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        if (slash == 0) return null;
        const host = rest[0..slash];
        for (host) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-')) return null;
        return .{ .host = host, .path = rest[slash..] };
    }
};

pub fn get(gpa: Allocator, url: []const u8, limit: usize, deadline_ms: u32) ![]u8 {
    const job = try Job.create(url, limit, deadline_ms);
    const thread = std.Thread.spawn(.{}, Job.work, .{job}) catch |err| {
        job.release();
        job.release();
        return err;
    };
    thread.detach();
    const waited = win.WaitForSingleObject(job.done, deadline_ms);
    defer job.release();
    if (waited != win.wait_object_0) return error.Timeout;
    if (job.failure) |err| return err;
    return gpa.dupe(u8, job.body.items);
}

const Job = struct {
    url: []u8,
    limit: usize,
    deadline_ms: u32,
    body: std.ArrayList(u8) = .empty,
    failure: ?anyerror = null,
    done: windows.HANDLE,
    refs: std.atomic.Value(u8) = .init(2),

    const backing = std.heap.page_allocator;

    fn create(url: []const u8, limit: usize, deadline_ms: u32) !*Job {
        const done = win.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.EventUnavailable;
        errdefer _ = win.CloseHandle(done);
        const owned = try backing.dupe(u8, url);
        errdefer backing.free(owned);
        const job = try backing.create(Job);
        job.* = .{ .url = owned, .limit = limit, .deadline_ms = deadline_ms, .done = done };
        return job;
    }

    fn release(job: *Job) void {
        if (job.refs.fetchSub(1, .acq_rel) != 1) return;
        job.body.deinit(backing);
        backing.free(job.url);
        _ = win.CloseHandle(job.done);
        backing.destroy(job);
    }

    fn work(job: *Job) void {
        fetch(job) catch |err| {
            job.failure = err;
        };
        _ = win.SetEvent(job.done);
        job.release();
    }

    fn fetch(job: *Job) !void {
        const url = Url.parse(job.url) orelse return error.UnsupportedUrl;
        var arena_state = std.heap.ArenaAllocator.init(backing);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const agent = try std.unicode.wtf8ToWtf16LeAllocZ(arena, user_agent);
        const host = try std.unicode.wtf8ToWtf16LeAllocZ(arena, url.host);
        const path = try std.unicode.wtf8ToWtf16LeAllocZ(arena, url.path);
        const verb = try std.unicode.wtf8ToWtf16LeAllocZ(arena, "GET");

        const session = win.WinHttpOpen(agent, win.access_type_automatic_proxy, null, null, 0) orelse return error.HttpUnavailable;
        defer _ = win.WinHttpCloseHandle(session);
        const timeout: c_int = @intCast(@min(job.deadline_ms, std.math.maxInt(c_int)));
        if (win.WinHttpSetTimeouts(session, timeout, timeout, timeout, timeout) == .FALSE) return error.HttpUnavailable;
        const connection = win.WinHttpConnect(session, host, 443, 0) orelse return error.ConnectFailed;
        defer _ = win.WinHttpCloseHandle(connection);
        const request = win.WinHttpOpenRequest(connection, verb, path, null, null, null, win.flag_secure) orelse return error.RequestFailed;
        defer _ = win.WinHttpCloseHandle(request);
        if (win.WinHttpSendRequest(request, null, 0, null, 0, 0, 0) == .FALSE) return error.SendFailed;
        if (win.WinHttpReceiveResponse(request, null) == .FALSE) return error.ReceiveFailed;

        var status: u32 = 0;
        var status_len: u32 = @sizeOf(u32);
        if (win.WinHttpQueryHeaders(request, win.query_status_code | win.query_flag_number, null, &status, &status_len, null) == .FALSE) return error.ReceiveFailed;
        if (status != 200) return error.HttpStatus;

        var chunk: [64 * 1024]u8 = undefined;
        while (true) {
            var read: u32 = 0;
            if (win.WinHttpReadData(request, &chunk, chunk.len, &read) == .FALSE) return error.ReceiveFailed;
            if (read == 0) return;
            if (job.body.items.len + read > job.limit) return error.ResponseTooLarge;
            try job.body.appendSlice(backing, chunk[0..read]);
        }
    }
};

const win = struct {
    const wait_object_0: windows.DWORD = 0;
    const access_type_automatic_proxy: u32 = 4;
    const flag_secure: u32 = 0x00800000;
    const query_status_code: u32 = 19;
    const query_flag_number: u32 = 0x20000000;

    extern "kernel32" fn CreateEventW(security: ?*anyopaque, manual: windows.BOOL, initial: windows.BOOL, name: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn SetEvent(event: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, milliseconds: windows.DWORD) callconv(.winapi) windows.DWORD;

    extern "winhttp" fn WinHttpOpen(agent: ?[*:0]const u16, access_type: u32, proxy: ?[*:0]const u16, bypass: ?[*:0]const u16, flags: u32) callconv(.winapi) ?*anyopaque;
    extern "winhttp" fn WinHttpSetTimeouts(handle: *anyopaque, resolve: c_int, connect: c_int, send: c_int, receive: c_int) callconv(.winapi) windows.BOOL;
    extern "winhttp" fn WinHttpConnect(session: *anyopaque, server: [*:0]const u16, port: u16, reserved: u32) callconv(.winapi) ?*anyopaque;
    extern "winhttp" fn WinHttpOpenRequest(connection: *anyopaque, verb: [*:0]const u16, object: [*:0]const u16, version: ?[*:0]const u16, referrer: ?[*:0]const u16, accept_types: ?*const ?[*:0]const u16, flags: u32) callconv(.winapi) ?*anyopaque;
    extern "winhttp" fn WinHttpSendRequest(request: *anyopaque, headers: ?[*]const u16, headers_len: u32, optional: ?*anyopaque, optional_len: u32, total_len: u32, context: usize) callconv(.winapi) windows.BOOL;
    extern "winhttp" fn WinHttpReceiveResponse(request: *anyopaque, reserved: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "winhttp" fn WinHttpQueryHeaders(request: *anyopaque, info_level: u32, name: ?[*:0]const u16, buffer: ?*anyopaque, buffer_len: *u32, index: ?*u32) callconv(.winapi) windows.BOOL;
    extern "winhttp" fn WinHttpReadData(request: *anyopaque, buffer: [*]u8, to_read: u32, read: *u32) callconv(.winapi) windows.BOOL;
    extern "winhttp" fn WinHttpCloseHandle(handle: *anyopaque) callconv(.winapi) windows.BOOL;
};
