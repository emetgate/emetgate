const std = @import("std");
const builtin = @import("builtin");
const bson = @import("bson.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const tls = std.crypto.tls;

pub const op_msg: i32 = 2013;
pub const header_len = 16;
pub const max_message_bytes: usize = 48 * 1000 * 1000;
pub const flag_checksum: u32 = 1 << 0;
pub const flag_more_to_come: u32 = 1 << 1;
pub const flag_exhaust_allowed: u32 = 1 << 16;

pub const WireError = error{ BadReply, ReplyTooLarge, ChecksumMismatch, OutOfMemory };

pub fn frame(gpa: Allocator, request_id: i32, body: []const u8) ![]u8 {
    const total = header_len + 4 + 1 + body.len;
    if (total > max_message_bytes) return error.ReplyTooLarge;
    const out = try gpa.alloc(u8, total);
    std.mem.writeInt(i32, out[0..4], @intCast(total), .little);
    std.mem.writeInt(i32, out[4..8], request_id, .little);
    std.mem.writeInt(i32, out[8..12], 0, .little);
    std.mem.writeInt(i32, out[12..16], op_msg, .little);
    std.mem.writeInt(u32, out[16..20], 0, .little);
    out[20] = 0;
    @memcpy(out[21..], body);
    return out;
}

pub const Header = struct {
    length: usize,
    request_id: i32,
    response_to: i32,
    op_code: i32,

    pub fn parse(bytes: *const [header_len]u8) WireError!Header {
        const length = std.mem.readInt(i32, bytes[0..4], .little);
        if (length < header_len + 5) return error.BadReply;
        if (@as(usize, @intCast(length)) > max_message_bytes + header_len) return error.ReplyTooLarge;
        return .{
            .length = @intCast(length),
            .request_id = std.mem.readInt(i32, bytes[4..8], .little),
            .response_to = std.mem.readInt(i32, bytes[8..12], .little),
            .op_code = std.mem.readInt(i32, bytes[12..16], .little),
        };
    }
};

pub fn bodyOf(payload: []const u8) WireError!bson.Doc {
    if (payload.len < 5) return error.BadReply;
    const flags = std.mem.readInt(u32, payload[0..4], .little);
    if (flags & 0xFFFF & ~(flag_checksum | flag_more_to_come) != 0) return error.BadReply;
    if (flags & flag_more_to_come != 0) return error.BadReply;
    var sections = payload[4..];
    if (flags & flag_checksum != 0) {
        if (sections.len < 4) return error.BadReply;
        sections = sections[0 .. sections.len - 4];
    }
    var body: ?bson.Doc = null;
    var at: usize = 0;
    while (at < sections.len) {
        const kind = sections[at];
        at += 1;
        const rest = sections[at..];
        switch (kind) {
            0 => {
                if (body != null) return error.BadReply;
                const doc = bson.Doc.prefix(rest) catch return error.BadReply;
                body = doc;
                at += doc.bytes.len;
            },
            1 => {
                if (rest.len < 4) return error.BadReply;
                const size = std.mem.readInt(i32, rest[0..4], .little);
                if (size < 4 or @as(usize, @intCast(size)) > rest.len) return error.BadReply;
                at += @intCast(size);
            },
            else => return error.BadReply,
        }
    }
    const doc = body orelse return error.BadReply;
    doc.validate() catch return error.BadReply;
    return doc;
}

pub fn checksumOk(header: []const u8, payload: []const u8) bool {
    const flags = std.mem.readInt(u32, payload[0..4], .little);
    if (flags & flag_checksum == 0) return true;
    if (payload.len < 8) return false;
    var crc = std.hash.crc.Crc32Iscsi.init();
    crc.update(header);
    crc.update(payload[0 .. payload.len - 4]);
    return crc.final() == std.mem.readInt(u32, payload[payload.len - 4 ..][0..4], .little);
}

pub const SOCKET = usize;
pub const invalid_socket: SOCKET = ~@as(usize, 0);
const af_inet: i32 = 2;
const af_inet6: i32 = 23;
const sock_stream: i32 = 1;
const ipproto_tcp: i32 = 6;
const sol_socket: i32 = 0xFFFF;
const so_sndtimeo: i32 = 0x1005;
const so_rcvtimeo: i32 = 0x1006;
const so_error: i32 = 0x1007;
const tcp_nodelay: i32 = 1;
const fionbio: i32 = @bitCast(@as(u32, 0x8004667E));
const wsae_would_block: i32 = 10035;
const wsae_timed_out: i32 = 10060;

pub const AddrInfo = extern struct {
    flags: i32,
    family: i32,
    socktype: i32,
    protocol: i32,
    addrlen: usize,
    canonname: ?[*:0]u8,
    addr: ?*anyopaque,
    next: ?*AddrInfo,
};

const FdSet = extern struct {
    count: u32,
    array: [64]SOCKET,
};

const TimeVal = extern struct {
    sec: i32,
    usec: i32,
};

extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.winapi) i32;
extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;
pub extern "ws2_32" fn socket(af: i32, kind: i32, protocol: i32) callconv(.winapi) SOCKET;
pub extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
extern "ws2_32" fn connect(s: SOCKET, name: *const anyopaque, len: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn setsockopt(s: SOCKET, level: i32, name: i32, value: [*]const u8, len: i32) callconv(.winapi) i32;
extern "ws2_32" fn getsockopt(s: SOCKET, level: i32, name: i32, value: [*]u8, len: *i32) callconv(.winapi) i32;
extern "ws2_32" fn ioctlsocket(s: SOCKET, cmd: i32, arg: *u32) callconv(.winapi) i32;
extern "ws2_32" fn select(n: i32, r: ?*FdSet, w: ?*FdSet, e: ?*FdSet, timeout: ?*const TimeVal) callconv(.winapi) i32;
extern "ws2_32" fn getaddrinfo(node: [*:0]const u8, service: ?[*:0]const u8, hints: ?*const AddrInfo, result: *?*AddrInfo) callconv(.winapi) i32;
extern "ws2_32" fn freeaddrinfo(info: *AddrInfo) callconv(.winapi) void;
pub extern "ws2_32" fn bind(s: SOCKET, name: *const anyopaque, len: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn listen(s: SOCKET, backlog: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn accept(s: SOCKET, addr: ?*anyopaque, len: ?*i32) callconv(.winapi) SOCKET;
pub extern "ws2_32" fn getsockname(s: SOCKET, name: *anyopaque, len: *i32) callconv(.winapi) i32;

var started = std.atomic.Value(bool).init(false);

pub fn startup() void {
    if (started.swap(true, .acq_rel)) return;
    var data: [512]u8 align(8) = undefined;
    _ = WSAStartup(0x0202, &data);
}

pub fn setTimeouts(s: SOCKET, ms: u32) void {
    const value: u32 = ms;
    _ = setsockopt(s, sol_socket, so_rcvtimeo, std.mem.asBytes(&value), 4);
    _ = setsockopt(s, sol_socket, so_sndtimeo, std.mem.asBytes(&value), 4);
}

pub const ConnectError = error{ HostNotFound, ConnectFailed, ConnectTimeout, OutOfMemory };

pub fn connectHost(gpa: Allocator, host: []const u8, port: u16, timeout_ms: u32) ConnectError!SOCKET {
    startup();
    const host_z = try gpa.dupeZ(u8, host);
    defer gpa.free(host_z);
    var port_buf: [8]u8 = undefined;
    const port_z = std.fmt.bufPrintZ(&port_buf, "{d}", .{port}) catch unreachable;
    const hints: AddrInfo = .{ .flags = 0, .family = 0, .socktype = sock_stream, .protocol = ipproto_tcp, .addrlen = 0, .canonname = null, .addr = null, .next = null };
    var list: ?*AddrInfo = null;
    if (getaddrinfo(host_z.ptr, port_z.ptr, &hints, &list) != 0) return error.HostNotFound;
    defer if (list) |l| freeaddrinfo(l);
    var timed_out = false;
    var node = list;
    while (node) |info| : (node = info.next) {
        const s = socket(info.family, sock_stream, ipproto_tcp);
        if (s == invalid_socket) continue;
        if (connectWithin(s, info, timeout_ms)) |_| {
            const on: u32 = 1;
            _ = setsockopt(s, ipproto_tcp, tcp_nodelay, std.mem.asBytes(&on), 4);
            return s;
        } else |err| {
            if (err == error.ConnectTimeout) timed_out = true;
            _ = closesocket(s);
        }
    }
    return if (timed_out) error.ConnectTimeout else error.ConnectFailed;
}

fn connectWithin(s: SOCKET, info: *const AddrInfo, timeout_ms: u32) error{ ConnectFailed, ConnectTimeout }!void {
    var nonblocking: u32 = 1;
    if (ioctlsocket(s, fionbio, &nonblocking) != 0) return error.ConnectFailed;
    const rc = connect(s, info.addr orelse return error.ConnectFailed, @intCast(info.addrlen));
    if (rc != 0 and WSAGetLastError() != wsae_would_block) return error.ConnectFailed;
    if (rc != 0) {
        var writable: FdSet = .{ .count = 1, .array = undefined };
        writable.array[0] = s;
        var failed: FdSet = .{ .count = 1, .array = undefined };
        failed.array[0] = s;
        const wait: TimeVal = .{ .sec = @intCast(timeout_ms / 1000), .usec = @intCast((timeout_ms % 1000) * 1000) };
        const n = select(0, null, &writable, &failed, &wait);
        if (n == 0) return error.ConnectTimeout;
        if (n < 0 or failed.count != 0) return error.ConnectFailed;
        var err_value: i32 = 0;
        var len: i32 = 4;
        if (getsockopt(s, sol_socket, so_error, std.mem.asBytes(&err_value), &len) != 0 or err_value != 0) return error.ConnectFailed;
    }
    nonblocking = 0;
    if (ioctlsocket(s, fionbio, &nonblocking) != 0) return error.ConnectFailed;
}

pub const SocketReader = struct {
    interface: Io.Reader,
    sock: SOCKET,
    timed_out: bool = false,

    pub fn init(sock: SOCKET, buffer: []u8) SocketReader {
        return .{ .sock = sock, .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 } };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *SocketReader = @alignCast(@fieldParentPtr("interface", r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const want: i32 = @intCast(@min(dest.len, 1 << 20));
        const n = recv(self.sock, dest.ptr, want, 0);
        if (n == 0) return error.EndOfStream;
        if (n < 0) {
            if (WSAGetLastError() == wsae_timed_out) self.timed_out = true;
            return error.ReadFailed;
        }
        w.advance(@intCast(n));
        return @intCast(n);
    }
};

pub const SocketWriter = struct {
    interface: Io.Writer,
    sock: SOCKET,
    timed_out: bool = false,

    pub fn init(sock: SOCKET, buffer: []u8) SocketWriter {
        return .{ .sock = sock, .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    fn sendAll(self: *SocketWriter, bytes: []const u8) Io.Writer.Error!void {
        var rest = bytes;
        while (rest.len != 0) {
            const n = send(self.sock, rest.ptr, @intCast(@min(rest.len, 1 << 20)), 0);
            if (n <= 0) {
                if (WSAGetLastError() == wsae_timed_out) self.timed_out = true;
                return error.WriteFailed;
            }
            rest = rest[@intCast(n)..];
        }
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *SocketWriter = @alignCast(@fieldParentPtr("interface", w));
        try self.sendAll(w.buffer[0..w.end]);
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |part| {
            try self.sendAll(part);
            n += part.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try self.sendAll(last);
        return n + last.len * splat;
    }
};

pub const TlsOptions = struct {
    host: []const u8,
    verify_certificate: bool = true,
    verify_host: bool = true,
};

pub const Transport = struct {
    gpa: Allocator,
    io: Io,
    sock: SOCKET,
    raw_read_buf: []u8,
    raw_write_buf: []u8,
    raw_reader: SocketReader,
    raw_writer: SocketWriter,
    tls_state: ?*TlsState = null,
    next_id: i32 = 1,

    const TlsState = struct {
        client: tls.Client,
        read_buf: []u8,
        write_buf: []u8,
        bundle: std.crypto.Certificate.Bundle = .empty,
        lock: Io.RwLock = .init,
    };

    pub fn open(gpa: Allocator, io: Io, sock: SOCKET, tls_options: ?TlsOptions, socket_timeout_ms: u32) !*Transport {
        const self = try gpa.create(Transport);
        errdefer gpa.destroy(self);
        const raw_read_buf = try gpa.alloc(u8, tls.Client.min_buffer_len);
        errdefer gpa.free(raw_read_buf);
        const raw_write_buf = try gpa.alloc(u8, tls.Client.min_buffer_len);
        errdefer gpa.free(raw_write_buf);
        setTimeouts(sock, socket_timeout_ms);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .sock = sock,
            .raw_read_buf = raw_read_buf,
            .raw_write_buf = raw_write_buf,
            .raw_reader = .init(sock, raw_read_buf),
            .raw_writer = .init(sock, raw_write_buf),
        };
        if (tls_options) |options| try self.startTls(options);
        return self;
    }

    fn startTls(self: *Transport, options: TlsOptions) !void {
        const state = try self.gpa.create(TlsState);
        errdefer self.gpa.destroy(state);
        state.* = .{ .client = undefined, .read_buf = try self.gpa.alloc(u8, tls.Client.min_buffer_len), .write_buf = undefined };
        errdefer self.gpa.free(state.read_buf);
        state.write_buf = try self.gpa.alloc(u8, tls.Client.min_buffer_len);
        errdefer self.gpa.free(state.write_buf);
        errdefer state.bundle.deinit(self.gpa);
        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        self.io.random(&entropy);
        state.client = try tls.Client.init(&self.raw_reader.interface, &self.raw_writer.interface, .{
            .host = if (options.verify_host) .{ .explicit = options.host } else .no_verification,
            .ca = if (options.verify_certificate) .{ .bundle = .{ .gpa = self.gpa, .io = self.io, .lock = &state.lock, .bundle = &state.bundle } } else .no_verification,
            .read_buffer = state.read_buf,
            .write_buffer = state.write_buf,
            .entropy = &entropy,
            .realtime_now = Io.Timestamp.now(self.io, .real),
        });
        self.tls_state = state;
    }

    pub fn close(self: *Transport) void {
        if (self.tls_state) |state| {
            state.client.end() catch {};
            self.raw_writer.interface.flush() catch {};
            state.bundle.deinit(self.gpa);
            self.gpa.free(state.read_buf);
            self.gpa.free(state.write_buf);
            self.gpa.destroy(state);
        }
        _ = closesocket(self.sock);
        self.gpa.free(self.raw_read_buf);
        self.gpa.free(self.raw_write_buf);
        self.gpa.destroy(self);
    }

    fn reader(self: *Transport) *Io.Reader {
        if (self.tls_state) |state| return &state.client.reader;
        return &self.raw_reader.interface;
    }

    fn writer(self: *Transport) *Io.Writer {
        if (self.tls_state) |state| return &state.client.writer;
        return &self.raw_writer.interface;
    }

    pub fn timedOut(self: *const Transport) bool {
        return self.raw_reader.timed_out or self.raw_writer.timed_out;
    }

    pub fn roundTrip(self: *Transport, arena: Allocator, body: []const u8) !bson.Doc {
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id <= 0) self.next_id = 1;
        const message = try frame(self.gpa, id, body);
        defer self.gpa.free(message);
        const w = self.writer();
        try w.writeAll(message);
        try w.flush();
        if (self.tls_state != null) try self.raw_writer.interface.flush();
        const r = self.reader();
        var head: [header_len]u8 = undefined;
        try r.readSliceAll(&head);
        const header = try Header.parse(&head);
        if (header.op_code != op_msg or header.response_to != id) return error.BadReply;
        const payload = try arena.alloc(u8, header.length - header_len);
        try r.readSliceAll(payload);
        if (!checksumOk(&head, payload)) return error.ChecksumMismatch;
        return bodyOf(payload);
    }
};

const testing = std.testing;

test "db mongo wire: an OP_MSG frame carries the length, the request id, opcode 2013 and one body section" {
    const body = [_]u8{ 5, 0, 0, 0, 0 };
    const framed = try frame(testing.allocator, 42, &body);
    defer testing.allocator.free(framed);
    try testing.expectEqual(@as(usize, 26), framed.len);
    const header = try Header.parse(framed[0..header_len]);
    try testing.expectEqual(@as(usize, 26), header.length);
    try testing.expectEqual(@as(i32, 42), header.request_id);
    try testing.expectEqual(op_msg, header.op_code);
    try testing.expectEqual(@as(u8, 0), framed[20]);
    const doc = try bodyOf(framed[header_len..]);
    try testing.expectEqual(@as(usize, 5), doc.bytes.len);
}

test "db mongo wire: a reply with two bodies, an unknown section, moreToCome, a bad checksum or a lying length is refused" {
    const one = [_]u8{ 0, 0, 0, 0, 0, 5, 0, 0, 0, 0 };
    _ = try bodyOf(&one);
    const two = [_]u8{ 0, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0 };
    try testing.expectError(error.BadReply, bodyOf(&two));
    const unknown = [_]u8{ 0, 0, 0, 0, 7, 5, 0, 0, 0, 0 };
    try testing.expectError(error.BadReply, bodyOf(&unknown));
    const more = [_]u8{ 2, 0, 0, 0, 0, 5, 0, 0, 0, 0 };
    try testing.expectError(error.BadReply, bodyOf(&more));
    const short = [_]u8{ 0, 0, 0, 0, 0, 9, 0, 0, 0, 0 };
    try testing.expectError(error.BadReply, bodyOf(&short));
    var head: [header_len]u8 = undefined;
    std.mem.writeInt(i32, head[0..4], 0x7fffffff, .little);
    try testing.expectError(error.ReplyTooLarge, Header.parse(&head));
    std.mem.writeInt(i32, head[0..4], 3, .little);
    try testing.expectError(error.BadReply, Header.parse(&head));
    var sum = [_]u8{ 1, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0 };
    var hdr = [_]u8{0} ** header_len;
    try testing.expect(!checksumOk(&hdr, &sum));
    var crc = std.hash.crc.Crc32Iscsi.init();
    crc.update(&hdr);
    crc.update(sum[0 .. sum.len - 4]);
    std.mem.writeInt(u32, sum[sum.len - 4 ..][0..4], crc.final(), .little);
    try testing.expect(checksumOk(&hdr, &sum));
    _ = try bodyOf(&sum);
}
