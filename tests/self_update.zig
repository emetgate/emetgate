const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const update = emetgate.self_update;
const test_util = emetgate.test_util;

const testing = std.testing;
const Ed25519 = std.crypto.sign.Ed25519;
const Allocator = std.mem.Allocator;

const old_image = "old image";
const new_image = "new image 0.9.0";

const Served = struct { suffix: []const u8, body: []const u8 = "", err: ?anyerror = null };

const FakeFetch = struct {
    served: []const Served,
    calls: usize = 0,
    deadlines: [8]u32 = .{0} ** 8,

    fn fetch(self: *FakeFetch) update.Fetch {
        return .{ .context = self, .getFn = get };
    }

    fn get(context: ?*anyopaque, gpa: Allocator, url: []const u8, limit: usize, deadline_ms: u32) anyerror![]u8 {
        const self: *FakeFetch = @ptrCast(@alignCast(context.?));
        if (self.calls < self.deadlines.len) self.deadlines[self.calls] = deadline_ms;
        self.calls += 1;
        for (self.served) |served| {
            if (!std.mem.endsWith(u8, url, served.suffix)) continue;
            if (served.err) |err| return err;
            if (served.body.len > limit) return error.ResponseTooLarge;
            return gpa.dupe(u8, served.body);
        }
        return error.HttpStatus;
    }
};

const Faulty = struct {
    disk: update.Disk = .{ .io = testing.io },
    failing_renames: []const usize = &.{},
    renames: usize = 0,
    reported: []const u8 = "emetgate 0.9.0\r\n",

    fn system(self: *Faulty) update.System {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable: update.System.VTable = .{ .read = read, .write = write, .rename = rename, .delete = delete, .reportVersion = reportVersion };

    fn of(context: *anyopaque) *Faulty {
        return @ptrCast(@alignCast(context));
    }

    fn read(context: *anyopaque, gpa: Allocator, path: []const u8, limit: usize) anyerror![]u8 {
        return of(context).disk.system().read(gpa, path, limit);
    }

    fn write(context: *anyopaque, path: []const u8, data: []const u8) anyerror!void {
        return of(context).disk.system().write(path, data);
    }

    fn rename(context: *anyopaque, from: []const u8, to: []const u8) anyerror!void {
        const self = of(context);
        self.renames += 1;
        for (self.failing_renames) |n| if (n == self.renames) return error.AccessDenied;
        return self.disk.system().rename(from, to);
    }

    fn delete(context: *anyopaque, path: []const u8) anyerror!void {
        return of(context).disk.system().delete(path);
    }

    fn reportVersion(context: *anyopaque, gpa: Allocator, exe: []const u8) anyerror![]u8 {
        _ = exe;
        return gpa.dupe(u8, of(context).reported);
    }
};

const Signed = struct {
    key: [32]u8,
    signature: [88]u8,
};

fn keyPair(seed_byte: u8) !Ed25519.KeyPair {
    return Ed25519.KeyPair.generateDeterministic([_]u8{seed_byte} ** 32);
}

fn signWith(seed_byte: u8, bytes: []const u8) !Signed {
    const pair = try keyPair(seed_byte);
    const signature = try pair.sign(bytes, null);
    var text: [88]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&text, &signature.toBytes());
    return .{ .key = pair.public_key.toBytes(), .signature = text };
}

const latest_090 = "{\"tag_name\":\"v0.9.0\",\"name\":\"emetgate 0.9.0\",\"draft\":false,\"prerelease\":false,\"assets\":[]}";

const Folder = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    exe: []u8,
    data: []u8,

    fn init() !Folder {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "emetgate.exe", .data = old_image });
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(root);
        const exe = try std.fs.path.join(testing.allocator, &.{ root, "emetgate.exe" });
        errdefer testing.allocator.free(exe);
        const data = try std.fs.path.join(testing.allocator, &.{ root, "data" });
        return .{ .tmp = tmp, .root = root, .exe = exe, .data = data };
    }

    fn deinit(self: *Folder) void {
        testing.allocator.free(self.data);
        testing.allocator.free(self.exe);
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn content(self: *Folder, name: []const u8) !?[]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, name, testing.allocator, .limited(64 << 20)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }

    fn expectContent(self: *Folder, name: []const u8, expected: ?[]const u8) !void {
        const actual = try self.content(name);
        defer if (actual) |bytes| testing.allocator.free(bytes);
        if (expected) |bytes| {
            try testing.expect(actual != null);
            try testing.expectEqualStrings(bytes, actual.?);
        } else {
            try testing.expect(actual == null);
        }
    }

    fn updater(self: *Folder, fetch: *FakeFetch, faulty: *Faulty, key: ?[32]u8) update.Updater {
        return .{
            .gpa = testing.allocator,
            .fetch = fetch.fetch(),
            .system = faulty.system(),
            .exe_path = self.exe,
            .current = "0.8.0",
            .key = key,
        };
    }
};

fn servedRelease(signature: []const u8) [3]Served {
    return .{
        .{ .suffix = "/releases/latest", .body = latest_090 },
        .{ .suffix = "/download/v0.9.0/emetgate.exe", .body = new_image },
        .{ .suffix = "/download/v0.9.0/emetgate.exe.sig", .body = signature },
    };
}

test "self update: versions compare as X.Y.Z numbers and only a strictly newer release is installed" {
    const v = update.Version.parse;
    try testing.expectEqual(std.math.Order.gt, v("v0.10.0").?.order(v("0.9.9").?));
    try testing.expectEqual(std.math.Order.lt, v("1.2.3").?.order(v("1.3.0").?));
    try testing.expectEqual(std.math.Order.eq, v("v2.0.0").?.order(v("2.0.0").?));
    for ([_][]const u8{ "", "v", "1.2", "1.2.3.4", "01.2.3", "1.2.x", "1.2.3-rc.1", "1..3", "v1.2.3 " }) |text| {
        errdefer std.debug.print("accepted version {s}\n", .{text});
        try testing.expect(v(text) == null);
    }

    for ([_][]const u8{ "{\"tag_name\":\"v0.8.0\"}", "{\"tag_name\":\"v0.7.9\"}" }) |body| {
        var folder = try Folder.init();
        defer folder.deinit();
        const served = [_]Served{.{ .suffix = "/releases/latest", .body = body }};
        var fetch: FakeFetch = .{ .served = &served };
        var faulty: Faulty = .{};
        const outcome = folder.updater(&fetch, &faulty, (try signWith(1, new_image)).key).run();
        try testing.expect(outcome == .up_to_date);
        try testing.expectEqual(@as(usize, 1), fetch.calls);
        try folder.expectContent("emetgate.exe", old_image);
    }
}

test "self update: the automatic check runs at most once per 24 hours and records the time before it reaches the network" {
    const day = update.check_interval_s;
    try testing.expect(update.due(null, 1_000));
    try testing.expect(!update.due(1_000, 1_000 + day - 1));
    try testing.expect(update.due(1_000, 1_000 + day));
    try testing.expect(update.due(5_000, 1_000));

    var folder = try Folder.init();
    defer folder.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    const served = [_]Served{.{ .suffix = "/releases/latest", .err = error.ConnectFailed }};
    var fetch: FakeFetch = .{ .served = &served };
    var faulty: Faulty = .{};
    const key = (try signWith(1, new_image)).key;
    const start: i64 = 1_700_000_000;

    try testing.expect(update.autoCheck(folder.updater(&fetch, &faulty, key), &env, true, folder.data, start) != null);
    try testing.expectEqual(@as(usize, 1), fetch.calls);
    try folder.expectContent("data\\update\\last-check", "1700000000");
    try testing.expect(update.autoCheck(folder.updater(&fetch, &faulty, key), &env, true, folder.data, start + day - 1) == null);
    try testing.expectEqual(@as(usize, 1), fetch.calls);
    try testing.expect(update.autoCheck(folder.updater(&fetch, &faulty, key), &env, true, folder.data, start + day) != null);
    try testing.expectEqual(@as(usize, 2), fetch.calls);
    try testing.expectEqual(update.check_deadline_ms, fetch.deadlines[0]);
    try testing.expectEqual(@as(u32, 2_000), update.check_deadline_ms);
}

test "self update: a release signed by the release key replaces the exe and keeps the old one as emetgate.old.exe" {
    var folder = try Folder.init();
    defer folder.deinit();
    const signed = try signWith(1, new_image);
    const served = servedRelease(&signed.signature);
    var fetch: FakeFetch = .{ .served = &served };
    var faulty: Faulty = .{};
    const outcome = folder.updater(&fetch, &faulty, signed.key).run();
    try testing.expect(outcome == .updated);
    try testing.expectEqual(std.math.Order.eq, outcome.updated.order(update.Version.parse("0.9.0").?));
    try folder.expectContent("emetgate.exe", new_image);
    try folder.expectContent(update.old_name, old_image);
    try folder.expectContent(update.new_name, null);
    try testing.expectEqual(@as(usize, 3), fetch.calls);

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try outcome.write(&writer, "0.8.0", update.arrowFor(65001));
    try testing.expectEqualStrings("emetgate 0.8.0 \u{2192} 0.9.0 updated\n", writer.buffered());
    try testing.expect(outcome.shownWhenAuto());
    try testing.expectEqual(@as(u8, 0), outcome.exitCode());
    try testing.expectEqualStrings("->", update.arrowFor(437));
}

test "self update: a signature from another key, over other bytes or not base64 installs nothing" {
    const other_key = try signWith(2, new_image);
    const other_bytes = try signWith(1, "something else");
    const release = try signWith(1, new_image);
    const cases = [_]struct { key: [32]u8, signature: []const u8 }{
        .{ .key = release.key, .signature = &other_key.signature },
        .{ .key = release.key, .signature = &other_bytes.signature },
        .{ .key = release.key, .signature = "not a signature" },
        .{ .key = release.key, .signature = "" },
        .{ .key = other_key.key, .signature = &release.signature },
    };
    for (cases) |case| {
        var folder = try Folder.init();
        defer folder.deinit();
        const served = servedRelease(case.signature);
        var fetch: FakeFetch = .{ .served = &served };
        var faulty: Faulty = .{};
        const outcome = folder.updater(&fetch, &faulty, case.key).run();
        try testing.expect(outcome == .bad_signature);
        try testing.expect(outcome.shownWhenAuto());
        try folder.expectContent("emetgate.exe", old_image);
        try folder.expectContent(update.old_name, null);
        try folder.expectContent(update.new_name, null);
        try testing.expectEqual(@as(usize, 0), faulty.renames);

        var buffer: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try outcome.write(&writer, "0.8.0", "->");
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, writer.buffered(), "\n"));
        try testing.expect(std.mem.startsWith(u8, writer.buffered(), "warning: "));
    }
    try update.verify(release.key, new_image, &release.signature);
}

test "self update: a failed swap puts the old exe back, and a failed rollback says how to fix it" {
    const signed = try signWith(1, new_image);
    const cases = [_]struct { failing: []const usize, rolled_back: bool }{
        .{ .failing = &.{1}, .rolled_back = true },
        .{ .failing = &.{2}, .rolled_back = true },
        .{ .failing = &.{ 2, 3 }, .rolled_back = false },
    };
    for (cases) |case| {
        var folder = try Folder.init();
        defer folder.deinit();
        const served = servedRelease(&signed.signature);
        var fetch: FakeFetch = .{ .served = &served };
        var faulty: Faulty = .{ .failing_renames = case.failing };
        const outcome = folder.updater(&fetch, &faulty, signed.key).run();
        try testing.expect(outcome.shownWhenAuto());
        try testing.expectEqual(@as(u8, 1), outcome.exitCode());
        if (case.rolled_back) {
            try testing.expect(outcome == .apply_failed);
            try folder.expectContent("emetgate.exe", old_image);
            try folder.expectContent(update.old_name, null);
        } else {
            try testing.expect(outcome == .rollback_failed);
            try folder.expectContent(update.old_name, old_image);
            var buffer: [256]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            try outcome.write(&writer, "0.8.0", "->");
            try testing.expect(std.mem.indexOf(u8, writer.buffered(), "rename emetgate.old.exe to emetgate.exe") != null);
        }
        try folder.expectContent(update.new_name, null);
    }
}

test "self update: a downloaded exe that does not report the release version is not installed" {
    const signed = try signWith(1, new_image);
    for ([_][]const u8{ "emetgate 0.8.0\n", "emetgate 0.9.1\n", "", "0.9.0\n" }) |reported| {
        var folder = try Folder.init();
        defer folder.deinit();
        const served = servedRelease(&signed.signature);
        var fetch: FakeFetch = .{ .served = &served };
        var faulty: Faulty = .{ .reported = reported };
        const outcome = folder.updater(&fetch, &faulty, signed.key).run();
        try testing.expect(outcome == .wrong_version);
        try folder.expectContent("emetgate.exe", old_image);
        try folder.expectContent(update.new_name, null);
        try testing.expectEqual(@as(usize, 0), faulty.renames);
    }
}

test "self update: the swap renames a running exe, and the leftover emetgate.old.exe goes at the next start once it stopped" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var folder = try Folder.init();
    defer folder.deinit();
    try std.Io.Dir.cwd().copyFile(test_util.probePath(), folder.tmp.dir, "emetgate.exe", testing.io, .{});
    const old = try std.fs.path.join(testing.allocator, &.{ folder.root, update.old_name });
    defer testing.allocator.free(old);
    const new = try std.fs.path.join(testing.allocator, &.{ folder.root, update.new_name });
    defer testing.allocator.free(new);
    try folder.tmp.dir.writeFile(testing.io, .{ .sub_path = update.new_name, .data = new_image });

    var child = try std.process.spawn(testing.io, .{ .argv = &.{ folder.exe, "sleep" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    var running = true;
    defer if (running) child.kill(testing.io);

    var disk: update.Disk = .{ .io = testing.io };
    try update.swap(disk.system(), folder.exe, old, new);
    try folder.expectContent("emetgate.exe", new_image);
    try folder.expectContent(update.new_name, null);

    update.removeLeftover(testing.allocator, disk.system(), folder.exe);
    const kept = try folder.content(update.old_name);
    try testing.expect(kept != null);
    testing.allocator.free(kept.?);

    child.kill(testing.io);
    running = false;
    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        update.removeLeftover(testing.allocator, disk.system(), folder.exe);
        const left = try folder.content(update.old_name);
        if (left == null) break;
        testing.allocator.free(left.?);
        testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
    }
    try folder.expectContent(update.old_name, null);
    try folder.expectContent("emetgate.exe", new_image);
}

test "self update: CI or EMETGATE_NO_UPDATE turns the automatic check off, and emetgate update still verifies and installs" {
    const cases = [_]struct { name: []const u8, value: []const u8, off: bool }{
        .{ .name = "CI", .value = "true", .off = true },
        .{ .name = "CI", .value = "", .off = true },
        .{ .name = "EMETGATE_NO_UPDATE", .value = "1", .off = true },
        .{ .name = "EMETGATE_NO_UPDATE", .value = "0", .off = false },
        .{ .name = "EMETGATE_NO_UPDATE", .value = "", .off = false },
        .{ .name = "OTHER", .value = "1", .off = false },
    };
    const signed = try signWith(1, new_image);
    for (cases) |case| {
        errdefer std.debug.print("{s}={s}\n", .{ case.name, case.value });
        var env = std.process.Environ.Map.init(testing.allocator);
        defer env.deinit();
        try env.put(case.name, case.value);
        try testing.expectEqual(case.off, update.autoDisabled(&env, true));
        try testing.expect(update.autoDisabled(&env, false));
        if (!case.off) continue;

        var folder = try Folder.init();
        defer folder.deinit();
        const served = servedRelease(&signed.signature);
        var fetch: FakeFetch = .{ .served = &served };
        var faulty: Faulty = .{};
        try testing.expect(update.autoCheck(folder.updater(&fetch, &faulty, signed.key), &env, true, folder.data, 1_700_000_000) == null);
        try testing.expectEqual(@as(usize, 0), fetch.calls);
        try folder.expectContent("data\\update\\last-check", null);

        const manual = folder.updater(&fetch, &faulty, signed.key).run();
        try testing.expect(manual == .updated);
        try folder.expectContent("emetgate.exe", new_image);
    }

    var folder = try Folder.init();
    defer folder.deinit();
    const forged = try signWith(2, new_image);
    const served = servedRelease(&forged.signature);
    var fetch: FakeFetch = .{ .served = &served };
    var faulty: Faulty = .{};
    try testing.expect(folder.updater(&fetch, &faulty, signed.key).run() == .bad_signature);
    try folder.expectContent("emetgate.exe", old_image);
}

test "self update: offline, a timeout or a failed download is silent and changes nothing" {
    const signed = try signWith(1, new_image);
    const cases = [_][3]Served{
        .{ .{ .suffix = "/releases/latest", .err = error.Timeout }, .{ .suffix = "/none" }, .{ .suffix = "/none" } },
        .{ .{ .suffix = "/releases/latest", .err = error.ConnectFailed }, .{ .suffix = "/none" }, .{ .suffix = "/none" } },
        .{ .{ .suffix = "/releases/latest", .body = latest_090 }, .{ .suffix = "/emetgate.exe", .err = error.Timeout }, .{ .suffix = "/emetgate.exe.sig", .body = &signed.signature } },
        .{ .{ .suffix = "/releases/latest", .body = latest_090 }, .{ .suffix = "/emetgate.exe", .body = new_image }, .{ .suffix = "/emetgate.exe.sig", .err = error.HttpStatus } },
        .{ .{ .suffix = "/releases/latest", .body = "<html>rate limited</html>" }, .{ .suffix = "/none" }, .{ .suffix = "/none" } },
    };
    for (cases) |served| {
        var folder = try Folder.init();
        defer folder.deinit();
        var env = std.process.Environ.Map.init(testing.allocator);
        defer env.deinit();
        var fetch: FakeFetch = .{ .served = &served };
        var faulty: Faulty = .{};
        const outcome = update.autoCheck(folder.updater(&fetch, &faulty, signed.key), &env, true, folder.data, 1_700_000_000) orelse return error.TestExpectedCheck;
        try testing.expect(!outcome.shownWhenAuto());
        try testing.expectEqual(@as(u8, 1), outcome.exitCode());
        try folder.expectContent("emetgate.exe", old_image);
        try folder.expectContent(update.new_name, null);
        try testing.expectEqual(@as(usize, 0), faulty.renames);
    }
}

test "self update: a prerelease or a draft is skipped without a download" {
    const bodies = [_][]const u8{
        "{\"tag_name\":\"v0.9.0\",\"prerelease\":true,\"draft\":false}",
        "{\"tag_name\":\"v0.9.0\",\"prerelease\":false,\"draft\":true}",
        "{\"tag_name\":\"v0.9.0-rc.1\",\"prerelease\":false,\"draft\":false}",
        "{\"tag_name\":\"v0.9.0+build.5\"}",
    };
    const signed = try signWith(1, new_image);
    for (bodies) |body| {
        try testing.expect(update.parseLatest(testing.allocator, body) == .prerelease);
        var folder = try Folder.init();
        defer folder.deinit();
        const served = [_]Served{ .{ .suffix = "/releases/latest", .body = body }, .{ .suffix = "/emetgate.exe", .body = new_image }, .{ .suffix = "/emetgate.exe.sig", .body = &signed.signature } };
        var fetch: FakeFetch = .{ .served = &served };
        var faulty: Faulty = .{};
        const outcome = folder.updater(&fetch, &faulty, signed.key).run();
        try testing.expect(outcome == .prerelease);
        try testing.expectEqual(@as(usize, 1), fetch.calls);
        try folder.expectContent("emetgate.exe", old_image);
    }
    try testing.expect(update.parseLatest(testing.allocator, latest_090) == .release);
}

test "self update: a build without a release key never downloads, and the placeholder key file is no key" {
    var folder = try Folder.init();
    defer folder.deinit();
    const served = servedRelease("");
    var fetch: FakeFetch = .{ .served = &served };
    var faulty: Faulty = .{};
    try testing.expect(folder.updater(&fetch, &faulty, null).run() == .no_release_key);
    try testing.expectEqual(@as(usize, 0), fetch.calls);

    try testing.expect(update.parseKey("PLACEHOLDER replace this line with the public key\n") == null);
    try testing.expect(update.parseKey("") == null);
    const pair = try keyPair(3);
    var text: [44]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&text, &pair.public_key.toBytes());
    const parsed = update.parseKey(&text) orelse return error.TestExpectedKey;
    try testing.expectEqualSlices(u8, &pair.public_key.toBytes(), &parsed);

    var other: Folder = try Folder.init();
    defer other.deinit();
    const updater: update.Updater = .{ .gpa = testing.allocator, .fetch = fetch.fetch(), .system = faulty.system(), .exe_path = other.exe, .current = "0.9.0-dev", .key = parsed };
    try testing.expect(updater.run() == .not_a_release_build);
    try testing.expectEqual(@as(usize, 0), fetch.calls);
}

test "self update: the transport accepts only https URLs with a plain host" {
    const url = update.winhttp.Url.parse("https://api.github.com/repos/emetgate/emetgate/releases/latest") orelse return error.TestExpectedUrl;
    try testing.expectEqualStrings("api.github.com", url.host);
    try testing.expectEqualStrings("/repos/emetgate/emetgate/releases/latest", url.path);
    for ([_][]const u8{ "http://github.com/x", "https://github.com", "https:///x", "https://user@github.com/x", "https://github.com:8443/x", "file:///c:/x" }) |text| {
        errdefer std.debug.print("accepted {s}\n", .{text});
        try testing.expect(update.winhttp.Url.parse(text) == null);
    }
}
