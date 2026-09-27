const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const sandbox = @import("emetgate").sandbox;
const appcontainer = @import("emetgate").appcontainer;

const testing = std.testing;
const gpa = testing.allocator;

const marker = "emetgate-redteam-marker\n";

const Fixture = struct {
    tmp: testing.TmpDir,
    profile: appcontainer.Profile,
    probe_abs: [:0]u8,
    shadow_abs: [:0]u8,
    fake_dir_abs: [:0]u8,
    secret_abs: []u8,

    fn init(lpac: bool) !Fixture {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "shadow");
        try tmp.dir.createDirPath(testing.io, "secret/fake-profile");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "secret/fake-profile/secret.txt", .data = marker });

        const probe_abs = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, build_options.probe_path, gpa);
        errdefer gpa.free(probe_abs);
        const shadow_abs = try tmp.dir.realPathFileAlloc(testing.io, "shadow", gpa);
        errdefer gpa.free(shadow_abs);
        const fake_dir_abs = try tmp.dir.realPathFileAlloc(testing.io, "secret/fake-profile", gpa);
        errdefer gpa.free(fake_dir_abs);
        const secret_abs = try std.fmt.allocPrint(gpa, "{s}\\secret.txt", .{fake_dir_abs});
        errdefer gpa.free(secret_abs);

        var profile = try appcontainer.Profile.create(lpac);
        errdefer profile.deinit();
        try profile.allowWrite(shadow_abs);
        try profile.allowReadFile(probe_abs);

        return .{ .tmp = tmp, .profile = profile, .probe_abs = probe_abs, .shadow_abs = shadow_abs, .fake_dir_abs = fake_dir_abs, .secret_abs = secret_abs };
    }

    fn deinit(self: *Fixture) void {
        self.profile.deinit();
        gpa.free(self.secret_abs);
        gpa.free(self.fake_dir_abs);
        gpa.free(self.shadow_abs);
        gpa.free(self.probe_abs);
        self.tmp.cleanup();
    }

    fn run(self: *Fixture, args: []const []const u8) !sandbox.Report {
        return runWith(&self.profile, self.probe_abs, self.shadow_abs, args);
    }
};

fn runWith(profile: *const appcontainer.Profile, probe: []const u8, cwd: []const u8, args: []const []const u8) !sandbox.Report {
    var argv_buf: [8][]const u8 = undefined;
    argv_buf[0] = probe;
    @memcpy(argv_buf[1..][0..args.len], args);
    return sandbox.run(gpa, testing.io, .{
        .argv = argv_buf[0 .. args.len + 1],
        .cwd = cwd,
        .limits = .{ .timeout_ms = 20_000 },
        .backend = .{ .app_container = profile },
    });
}

fn runLow(probe: []const u8, cwd: []const u8, args: []const []const u8) !sandbox.Report {
    var argv_buf: [8][]const u8 = undefined;
    argv_buf[0] = probe;
    @memcpy(argv_buf[1..][0..args.len], args);
    return sandbox.run(gpa, testing.io, .{
        .argv = argv_buf[0 .. args.len + 1],
        .cwd = cwd,
        .limits = .{ .timeout_ms = 20_000 },
        .backend = .low_integrity,
    });
}

fn exists(abs: []const u8) bool {
    std.Io.Dir.cwd().access(testing.io, abs, .{}) catch return false;
    return true;
}

test "redteam appcontainer: a granted directory is writable, a non-granted directory is not" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init(false);
    defer fx.deinit();

    const granted_file = try std.fmt.allocPrint(gpa, "{s}\\out.txt", .{fx.shadow_abs});
    defer gpa.free(granted_file);
    const denied_file = try std.fmt.allocPrint(gpa, "{s}\\planted.txt", .{fx.fake_dir_abs});
    defer gpa.free(denied_file);

    const granted = try fx.run(&.{ "writefile", granted_file });
    defer granted.deinit(gpa);
    errdefer std.debug.print("granted write outcome {any}, stderr {s}\n", .{ granted.outcome, granted.stderr });
    try testing.expectEqual(sandbox.Outcome{ .exited = 0 }, granted.outcome);
    try testing.expect(exists(granted_file));

    const denied = try fx.run(&.{ "writefile", denied_file });
    defer denied.deinit(gpa);
    try testing.expect(!denied.passed());
    try testing.expect(!exists(denied_file));
}

test "redteam appcontainer: a non-granted secret is unreadable, and granting it proves the check is real" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init(false);
    defer fx.deinit();

    const blocked = try fx.run(&.{ "readfile", fx.secret_abs });
    defer blocked.deinit(gpa);
    errdefer std.debug.print("read outcome {any}\n", .{blocked.outcome});
    try testing.expect(!blocked.passed());

    try fx.profile.allowRead(fx.fake_dir_abs);
    const allowed = try fx.run(&.{ "readfile", fx.secret_abs });
    defer allowed.deinit(gpa);
    try testing.expectEqual(sandbox.Outcome{ .exited = 0 }, allowed.outcome);
}

test "redteam appcontainer: the sandboxed process runs inside an app container, a low-integrity run does not" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init(false);
    defer fx.deinit();

    const inside = try fx.run(&.{"appcontainer"});
    defer inside.deinit(gpa);
    errdefer std.debug.print("appcontainer probe outcome {any}, stderr {s}\n", .{ inside.outcome, inside.stderr });
    try testing.expectEqual(sandbox.Outcome{ .exited = 0 }, inside.outcome);

    const low = try runLow(fx.probe_abs, fx.shadow_abs, &.{"appcontainer"});
    defer low.deinit(gpa);
    try testing.expectEqual(sandbox.Outcome{ .exited = 1 }, low.outcome);
}

test "redteam appcontainer: an lpac profile opts out of the all-packages group, a regular one does not" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var regular = try Fixture.init(false);
    defer regular.deinit();
    const open = try regular.run(&.{"wsa"});
    defer open.deinit(gpa);
    errdefer std.debug.print("regular wsa outcome {any}\n", .{open.outcome});
    try testing.expectEqual(sandbox.Outcome{ .exited = 0 }, open.outcome);

    var lpac = try Fixture.init(true);
    defer lpac.deinit();
    const inside = try lpac.run(&.{"appcontainer"});
    defer inside.deinit(gpa);
    try testing.expectEqual(sandbox.Outcome{ .exited = 0 }, inside.outcome);
    const closed = try lpac.run(&.{"wsa"});
    defer closed.deinit(gpa);
    try testing.expectEqual(sandbox.Outcome{ .exited = 1 }, closed.outcome);
}

test "redteam appcontainer: a loopback connection is refused inside the container but reachable from a low-integrity run" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init(false);
    defer fx.deinit();

    var data: net.WsaData = undefined;
    if (net.WSAStartup(0x0202, &data) != 0) return error.TestUnexpectedResult;
    defer _ = net.WSACleanup();
    const listener = net.socket(net.af_inet, net.sock_stream, 0);
    if (listener == net.invalid_socket) return error.TestUnexpectedResult;
    defer _ = net.closesocket(listener);
    var addr: net.SockaddrIn = .{ .family = net.af_inet, .port = 0, .addr = 0x0100007f, .zero = [_]u8{0} ** 8 };
    if (net.bind(listener, @ptrCast(&addr), @sizeOf(net.SockaddrIn)) != 0) return error.TestUnexpectedResult;
    if (net.listen(listener, 8) != 0) return error.TestUnexpectedResult;
    var out: net.SockaddrIn = undefined;
    var out_len: c_int = @sizeOf(net.SockaddrIn);
    if (net.getsockname(listener, @ptrCast(&out), &out_len) != 0) return error.TestUnexpectedResult;
    const port = std.mem.bigToNative(u16, out.port);

    var port_buf: [8]u8 = undefined;
    const port_arg = try std.fmt.bufPrint(&port_buf, "{d}", .{port});

    const blocked = try fx.run(&.{ "connect", port_arg });
    defer blocked.deinit(gpa);
    errdefer std.debug.print("connect outcome {any}\n", .{blocked.outcome});
    try testing.expect(!blocked.passed());

    const reached = try runLow(fx.probe_abs, fx.shadow_abs, &.{ "connect", port_arg });
    defer reached.deinit(gpa);
    try testing.expectEqual(sandbox.Outcome{ .exited = 0 }, reached.outcome);
}

const net = struct {
    const windows = std.os.windows;
    const af_inet: c_int = 2;
    const sock_stream: c_int = 1;
    const invalid_socket: usize = std.math.maxInt(usize);

    const WsaData = extern struct {
        version: u16,
        high_version: u16,
        description: [257]u8,
        system_status: [129]u8,
        max_sockets: u16,
        max_udp_dg: u16,
        vendor_info: ?*u8,
    };

    const SockaddrIn = extern struct {
        family: u16,
        port: u16,
        addr: u32,
        zero: [8]u8,
    };

    extern "ws2_32" fn WSAStartup(version: u16, data: *WsaData) callconv(.winapi) c_int;
    extern "ws2_32" fn WSACleanup() callconv(.winapi) c_int;
    extern "ws2_32" fn socket(family: c_int, kind: c_int, protocol: c_int) callconv(.winapi) usize;
    extern "ws2_32" fn bind(sock: usize, addr: *const anyopaque, len: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn listen(sock: usize, backlog: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn getsockname(sock: usize, addr: *anyopaque, len: *c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn closesocket(sock: usize) callconv(.winapi) c_int;
};
