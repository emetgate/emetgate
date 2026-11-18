const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const SOCKET = usize;
pub const invalid_socket: SOCKET = std.math.maxInt(usize);
const socket_error: c_int = -1;
const af_inet: c_int = 2;
const af_inet6: c_int = 23;
const sock_stream: c_int = 1;
const ipproto_tcp: c_int = 6;
const sol_socket: c_int = 0xffff;
const so_rcvtimeo: c_int = 0x1006;
const so_sndtimeo: c_int = 0x1005;
const so_error: c_int = 0x1007;
const so_keepalive: c_int = 0x0008;
const tcp_nodelay: c_int = 1;
const fionbio: c_long = @bitCast(@as(c_ulong, 0x8004667E));
const wsaewouldblock: c_int = 10035;
const wsaetimedout: c_int = 10060;

pub const AddrInfo = extern struct {
    flags: c_int,
    family: c_int,
    socktype: c_int,
    protocol: c_int,
    addrlen: usize,
    canonname: ?[*:0]u8,
    addr: ?*anyopaque,
    next: ?*AddrInfo,
};

pub const SockAddrIn = extern struct {
    family: u16,
    port: u16,
    addr: [4]u8,
    zero: [8]u8 = @splat(0),
};

const FdSet = extern struct {
    count: u32,
    array: [64]SOCKET,
};

const TimeVal = extern struct {
    sec: c_long,
    usec: c_long,
};

pub const api = struct {
    pub extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.winapi) c_int;
    pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
    pub extern "ws2_32" fn getaddrinfo(node: [*:0]const u8, service: ?[*:0]const u8, hints: *const AddrInfo, result: *?*AddrInfo) callconv(.winapi) c_int;
    pub extern "ws2_32" fn freeaddrinfo(info: *AddrInfo) callconv(.winapi) void;
    pub extern "ws2_32" fn socket(af: c_int, kind: c_int, protocol: c_int) callconv(.winapi) SOCKET;
    pub extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) c_int;
    pub extern "ws2_32" fn connect(s: SOCKET, name: *const anyopaque, len: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn ioctlsocket(s: SOCKET, cmd: c_long, arg: *c_ulong) callconv(.winapi) c_int;
    pub extern "ws2_32" fn select(nfds: c_int, read: ?*FdSet, write: ?*FdSet, except: ?*FdSet, timeout: ?*const TimeVal) callconv(.winapi) c_int;
    pub extern "ws2_32" fn getsockopt(s: SOCKET, level: c_int, name: c_int, value: [*]u8, len: *c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn setsockopt(s: SOCKET, level: c_int, name: c_int, value: [*]const u8, len: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn bind(s: SOCKET, name: *const anyopaque, len: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn listen(s: SOCKET, backlog: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn accept(s: SOCKET, addr: ?*anyopaque, len: ?*c_int) callconv(.winapi) SOCKET;
    pub extern "ws2_32" fn getsockname(s: SOCKET, name: *anyopaque, len: *c_int) callconv(.winapi) c_int;
};

pub const Error = error{ NetworkUnavailable, HostNotFound, ConnectFailed, ConnectTimeout, NetTimeout, ConnectionClosed, NetFailed };

var started = std.atomic.Value(bool).init(false);

pub fn startup() Error!void {
    if (builtin.os.tag != .windows) return error.NetworkUnavailable;
    if (started.load(.acquire)) return;
    var data: [512]u8 align(8) = undefined;
    if (api.WSAStartup(0x0202, &data) != 0) return error.NetworkUnavailable;
    started.store(true, .release);
}

fn setSockTimeout(s: SOCKET, name: c_int, ms: u32) void {
    const value: u32 = ms;
    _ = api.setsockopt(s, sol_socket, name, std.mem.asBytes(&value), @sizeOf(u32));
}

fn setFlag(s: SOCKET, level: c_int, name: c_int) void {
    const value: u32 = 1;
    _ = api.setsockopt(s, level, name, std.mem.asBytes(&value), @sizeOf(u32));
}

fn connectOne(info: *const AddrInfo, timeout_ms: u32) Error!SOCKET {
    const s = api.socket(info.family, sock_stream, ipproto_tcp);
    if (s == invalid_socket) return error.ConnectFailed;
    errdefer _ = api.closesocket(s);
    var on: c_ulong = 1;
    if (api.ioctlsocket(s, fionbio, &on) != 0) return error.ConnectFailed;
    const addr = info.addr orelse return error.ConnectFailed;
    if (api.connect(s, addr, @intCast(info.addrlen)) == socket_error) {
        if (api.WSAGetLastError() != wsaewouldblock) return error.ConnectFailed;
        var writable: FdSet = .{ .count = 1, .array = undefined };
        writable.array[0] = s;
        var failed: FdSet = .{ .count = 1, .array = undefined };
        failed.array[0] = s;
        const tv: TimeVal = .{ .sec = @intCast(timeout_ms / 1000), .usec = @intCast((timeout_ms % 1000) * 1000) };
        const ready = api.select(0, null, &writable, &failed, &tv);
        if (ready == 0) return error.ConnectTimeout;
        if (ready < 0 or failed.count != 0) return error.ConnectFailed;
        var code: c_int = 0;
        var len: c_int = @sizeOf(c_int);
        if (api.getsockopt(s, sol_socket, so_error, std.mem.asBytes(&code), &len) != 0 or code != 0) return error.ConnectFailed;
    }
    var off: c_ulong = 0;
    if (api.ioctlsocket(s, fionbio, &off) != 0) return error.ConnectFailed;
    return s;
}

pub fn dial(host: []const u8, port: u16, connect_ms: u32) Error!SOCKET {
    try startup();
    var host_buf: [256]u8 = undefined;
    if (host.len == 0 or host.len >= host_buf.len) return error.HostNotFound;
    @memcpy(host_buf[0..host.len], host);
    host_buf[host.len] = 0;
    var port_buf: [8]u8 = undefined;
    const port_text = std.fmt.bufPrintZ(&port_buf, "{d}", .{port}) catch unreachable;
    const hints: AddrInfo = .{ .flags = 0, .family = 0, .socktype = sock_stream, .protocol = ipproto_tcp, .addrlen = 0, .canonname = null, .addr = null, .next = null };
    var result: ?*AddrInfo = null;
    if (api.getaddrinfo(host_buf[0..host.len :0].ptr, port_text.ptr, &hints, &result) != 0) return error.HostNotFound;
    const list = result orelse return error.HostNotFound;
    defer api.freeaddrinfo(list);
    var last: Error = error.ConnectFailed;
    var it: ?*AddrInfo = list;
    while (it) |info| : (it = info.next) {
        if (info.family != af_inet and info.family != af_inet6) continue;
        const s = connectOne(info, connect_ms) catch |err| {
            last = err;
            continue;
        };
        setFlag(s, ipproto_tcp, tcp_nodelay);
        setFlag(s, sol_socket, so_keepalive);
        return s;
    }
    return last;
}

pub const Socket = struct {
    handle: SOCKET,
    reader: Io.Reader,
    writer: Io.Writer,
    err: ?Error = null,

    pub fn init(self: *Socket, handle: SOCKET, read_buf: []u8, write_buf: []u8, timeout_ms: u32) void {
        self.* = .{
            .handle = handle,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = read_buf, .seek = 0, .end = 0 },
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = write_buf },
        };
        self.setTimeout(timeout_ms);
    }

    pub fn setTimeout(self: *Socket, ms: u32) void {
        setSockTimeout(self.handle, so_rcvtimeo, ms);
        setSockTimeout(self.handle, so_sndtimeo, ms);
    }

    pub fn close(self: *Socket) void {
        if (self.handle != invalid_socket) _ = api.closesocket(self.handle);
        self.handle = invalid_socket;
    }

    fn failure(self: *Socket) void {
        const code = api.WSAGetLastError();
        self.err = if (code == wsaetimedout) error.NetTimeout else error.NetFailed;
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *Socket = @alignCast(@fieldParentPtr("reader", r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        if (dest.len == 0) return 0;
        const want: c_int = @intCast(@min(dest.len, std.math.maxInt(c_int)));
        const n = api.recv(self.handle, dest.ptr, want, 0);
        if (n == 0) {
            self.err = error.ConnectionClosed;
            return error.EndOfStream;
        }
        if (n < 0) {
            self.failure();
            return error.ReadFailed;
        }
        const got: usize = @intCast(n);
        w.advance(got);
        return got;
    }

    fn sendAll(self: *Socket, bytes: []const u8) Io.Writer.Error!void {
        var rest = bytes;
        while (rest.len != 0) {
            const chunk: c_int = @intCast(@min(rest.len, 1 << 20));
            const n = api.send(self.handle, rest.ptr, chunk, 0);
            if (n <= 0) {
                self.failure();
                return error.WriteFailed;
            }
            rest = rest[@intCast(n)..];
        }
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *Socket = @alignCast(@fieldParentPtr("writer", w));
        const buffered = w.buffered();
        try self.sendAll(buffered);
        var total: usize = buffered.len;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.sendAll(bytes);
            total += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            try self.sendAll(last);
            total += last.len;
        }
        return w.consume(total);
    }
};

pub const Listener = struct {
    handle: SOCKET,
    port: u16,

    pub fn open() Error!Listener {
        try startup();
        const s = api.socket(af_inet, sock_stream, ipproto_tcp);
        if (s == invalid_socket) return error.NetFailed;
        errdefer _ = api.closesocket(s);
        var addr: SockAddrIn = .{ .family = af_inet, .port = 0, .addr = .{ 127, 0, 0, 1 } };
        if (api.bind(s, &addr, @sizeOf(SockAddrIn)) != 0) return error.NetFailed;
        if (api.listen(s, 4) != 0) return error.NetFailed;
        var len: c_int = @sizeOf(SockAddrIn);
        if (api.getsockname(s, &addr, &len) != 0) return error.NetFailed;
        return .{ .handle = s, .port = std.mem.bigToNative(u16, addr.port) };
    }

    pub fn accept(self: *Listener) Error!SOCKET {
        const s = api.accept(self.handle, null, null);
        if (s == invalid_socket) return error.NetFailed;
        return s;
    }

    pub fn close(self: *Listener) void {
        _ = api.closesocket(self.handle);
    }
};

pub fn closeHandle(s: SOCKET) void {
    _ = api.closesocket(s);
}
