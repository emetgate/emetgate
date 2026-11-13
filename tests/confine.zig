//! Path confinement: a junction inside the repository that leads outside it is
//! not followed by find or list, and the skipped folder is named in the reply;
//! a junction that stays inside the repository and plain paths still work.
const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const emetgate = @import("emetgate");
const confine = emetgate.confine;
const shadow = emetgate.shadow;
const find_tools = emetgate.find_tools;
const telemetry = emetgate.telemetry;

const testing = std.testing;
const gpa = testing.allocator;

const secret = "OUTSIDE SECRET marker\n";
const app_js = "export function total(a, b) {\n  return a + b;\n}\n";

const Fixture = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,
    outside_abs: [:0]u8,

    fn init() !Fixture {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src");
        try tmp.dir.createDirPath(testing.io, "outside");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/app.js", .data = app_js });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.gitignore", .data = ".emetgate/\n" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside/secret.txt", .data = secret });
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
        errdefer gpa.free(root_abs);
        const outside_abs = try tmp.dir.realPathFileAlloc(testing.io, "outside", gpa);
        errdefer gpa.free(outside_abs);
        try git_fixture.initRepo(root_abs);
        try git_fixture.commitInit(root_abs, false);
        try junction(root_abs, "junc_out", outside_abs);
        const src_abs = try std.fmt.allocPrint(gpa, "{s}\\src", .{root_abs});
        defer gpa.free(src_abs);
        try junction(root_abs, "junc_in", src_abs);
        return .{ .tmp = tmp, .root_abs = root_abs, .outside_abs = outside_abs };
    }

    fn deinit(self: *Fixture) void {
        if (find_tools.indexDir(gpa, self.root_abs)) |dir| {
            defer gpa.free(dir);
            std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
        } else |_| {}
        // Remove the junctions first so cleanup never walks into the outside folder twice.
        for ([_][]const u8{ "junc_out", "junc_in" }) |name| {
            const link = std.fmt.allocPrint(gpa, "{s}\\{s}", .{ self.root_abs, name }) catch continue;
            defer gpa.free(link);
            std.Io.Dir.cwd().deleteDir(testing.io, link) catch {};
        }
        gpa.free(self.outside_abs);
        gpa.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn path(self: *const Fixture, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}\\{s}", .{ self.root_abs, rel });
    }
};

fn junction(root_abs: []const u8, name: []const u8, target_abs: []const u8) !void {
    const link = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root_abs, name });
    defer gpa.free(link);
    try shadow.createJunction(testing.io, link, target_abs);
}

fn find(session: *find_tools.Session, pattern: []const u8) ![]u8 {
    var args: std.json.ObjectMap = .empty;
    defer args.deinit(gpa);
    try args.put(gpa, "pattern", .{ .string = pattern });
    var event: telemetry.Event = .{ .tool = "emetgate_find" };
    const result = try find_tools.callFind(gpa, .{ .object = args }, &event, session);
    errdefer gpa.free(result.text);
    if (result.is_error) {
        std.debug.print("find {s} failed: {s}\n", .{ pattern, result.text });
        return error.FindFailed;
    }
    return result.text;
}

test "confine: within resolves junctions; a plain path and an inside junction stay inside" {
    var f = try Fixture.init();
    defer f.deinit();
    const plain = try f.path("src\\app.js");
    defer gpa.free(plain);
    const via_in = try f.path("junc_in\\app.js");
    defer gpa.free(via_in);
    const via_out = try f.path("junc_out\\secret.txt");
    defer gpa.free(via_out);
    try testing.expect(try confine.within(gpa, f.root_abs, plain));
    try testing.expect(try confine.within(gpa, f.root_abs, via_in));
    try testing.expect(!try confine.within(gpa, f.root_abs, via_out));

    var c = try confine.Confine.init(gpa, f.root_abs);
    defer c.deinit();
    try testing.expect(try c.keeps("src/app.js"));
    try testing.expect(try c.keeps("junc_in/app.js"));
    try testing.expect(!try c.keeps("junc_out/secret.txt"));
    try testing.expect(!try c.keeps("junc_out/deeper/other.txt"));
    try testing.expectEqual(@as(usize, 1), c.outside.items.len);
    try testing.expectEqualStrings("junc_out/", c.outside.items[0]);
}

test "confine: find does not index a file behind a junction to outside the repository and names the skipped folder" {
    var f = try Fixture.init();
    defer f.deinit();
    const session = try find_tools.Session.create(gpa, testing.io, f.root_abs);
    defer session.destroy();
    try session.prepare(.build);

    const hidden = try find(session, "OUTSIDE SECRET");
    defer gpa.free(hidden);
    errdefer std.debug.print("find OUTSIDE SECRET: {s}\n", .{hidden});
    try testing.expect(std.mem.startsWith(u8, hidden, "0 hits"));
    try testing.expect(std.mem.indexOf(u8, hidden, "secret.txt") == null);
    try testing.expect(std.mem.indexOf(u8, hidden, "outside the repository") != null);
    try testing.expect(std.mem.indexOf(u8, hidden, "junc_out/") != null);

    const shown = try find(session, "total");
    defer gpa.free(shown);
    errdefer std.debug.print("find total: {s}\n", .{shown});
    try testing.expect(std.mem.indexOf(u8, shown, "src/app.js") != null);
    try testing.expect(std.mem.indexOf(u8, shown, "junc_in/app.js") != null);
}

test "confine: the working listing leaves out a junction to outside the repository and reports it" {
    var f = try Fixture.init();
    defer f.deinit();
    var outside: std.ArrayList([]u8) = .empty;
    defer {
        for (outside.items) |p| gpa.free(p);
        outside.deinit(gpa);
    }
    const files = try shadow.workingListing(gpa, testing.io, f.root_abs, &outside);
    defer {
        shadow.freeFileList(gpa, files);
        gpa.free(files);
    }
    var saw_src = false;
    var saw_in = false;
    for (files) |p| {
        try testing.expect(!std.mem.startsWith(u8, p, "junc_out/"));
        if (std.mem.eql(u8, p, "src/app.js")) saw_src = true;
        if (std.mem.eql(u8, p, "junc_in/app.js")) saw_in = true;
    }
    try testing.expect(saw_src);
    try testing.expect(saw_in);
    try testing.expectEqual(@as(usize, 1), outside.items.len);
    try testing.expectEqualStrings("junc_out/", outside.items[0]);
}

test "confine: list names the folder under dir that leads outside the repository in skipped_outside" {
    var f = try Fixture.init();
    defer f.deinit();
    var args: std.json.ObjectMap = .empty;
    defer args.deinit(gpa);
    try args.put(gpa, "dir", .{ .string = f.root_abs });
    var event: telemetry.Event = .{ .tool = "emetgate_list" };
    const result = try emetgate.read_tools.callList(gpa, testing.io, .{ .object = args }, &event, f.root_abs);
    defer gpa.free(result.text);
    errdefer std.debug.print("list: {s}\n", .{result.text});
    try testing.expect(!result.is_error);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, result.text, .{});
    defer parsed.deinit();
    const skipped = parsed.value.object.get("skipped_outside") orelse return error.NoSkippedOutside;
    try testing.expectEqual(@as(usize, 1), skipped.array.items.len);
    try testing.expect(std.mem.endsWith(u8, skipped.array.items[0].string, "junc_out/"));
    try testing.expect(std.mem.indexOf(u8, result.text, "secret.txt") == null);
}

test "confine: find does not index a file link to outside the repository and names it" {
    var f = try Fixture.init();
    defer f.deinit();
    const target = try std.fmt.allocPrint(gpa, "{s}\\secret.txt", .{f.outside_abs});
    defer gpa.free(target);
    f.tmp.dir.symLink(testing.io, target, "repo/link_secret.txt", .{}) catch return error.SkipZigTest;
    const session = try find_tools.Session.create(gpa, testing.io, f.root_abs);
    defer session.destroy();
    try session.prepare(.build);

    const hidden = try find(session, "OUTSIDE SECRET");
    defer gpa.free(hidden);
    errdefer std.debug.print("find: {s}\n", .{hidden});
    try testing.expect(std.mem.startsWith(u8, hidden, "0 hits"));
    try testing.expect(std.mem.indexOf(u8, hidden, "link_secret.txt") != null);
}

test "confine: a stamp is not taken through a file link to outside the repository, and the link is reported" {
    var f = try Fixture.init();
    defer f.deinit();
    const target = try std.fmt.allocPrint(gpa, "{s}\\secret.txt", .{f.outside_abs});
    defer gpa.free(target);
    f.tmp.dir.symLink(testing.io, target, "repo/link_secret.txt", .{}) catch return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var links_out: std.ArrayList([]const u8) = .empty;
    const paths = [_][]const u8{ "src/app.js", "link_secret.txt" };
    const stamps = try emetgate.emet_file.stampEach(testing.io, arena, f.root_abs, &paths, &links_out);
    try testing.expect(stamps[0] != null);
    try testing.expect(stamps[1] == null);
    try testing.expectEqual(@as(usize, 1), links_out.items.len);
    try testing.expectEqualStrings("link_secret.txt", links_out.items[0]);
}
