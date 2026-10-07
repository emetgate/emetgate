const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const repo_mod = @import("emetgate").repo;
const exe_path = @import("emetgate").exe_path;
const Runtime = @import("emetgate").runtime.Runtime;

const testing = std.testing;
const Value = std.json.Value;

extern "kernel32" fn GetShortPathNameW(long: [*:0]const u16, short: [*]u16, len: u32) callconv(.winapi) u32;

const repo_dir = "repository-with-a-long-name";
const source_rel = "source-directory-long/math.ts";
const note_rel = "note-with-a-long-name.txt";
const source_text = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const note_text = "a note in the served repository\n";
const secret_text = "kept outside the reach of every tool\n";

fn shortOf(path: []const u8) ![]u8 {
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(testing.allocator, path);
    defer testing.allocator.free(wide);
    var buf: [std.fs.max_path_bytes]u16 = undefined;
    const len = GetShortPathNameW(wide, &buf, buf.len);
    if (len == 0 or len >= buf.len) return error.SkipZigTest;
    const short = try std.unicode.wtf16LeToWtf8Alloc(testing.allocator, buf[0..len]);
    errdefer testing.allocator.free(short);
    if (std.mem.eql(u8, short, path)) return error.SkipZigTest;
    return short;
}

fn join(base: []const u8, rel: []const u8) ![]u8 {
    const joined = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}", .{ base, rel });
    std.mem.replaceScalar(u8, joined, '/', '\\');
    return joined;
}

fn run(cwd: []const u8, argv: []const []const u8) !void {
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = argv, .cwd = .{ .path = cwd } });
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.SetupFailed,
        else => return error.SetupFailed,
    }
}

const Served = struct {
    tmp: testing.TmpDir,
    top: [:0]u8,
    long: []u8,
    short: []u8,

    fn init() !Served {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, repo_dir ++ "/source-directory-long");
        try tmp.dir.createDirPath(testing.io, "outside-directory-long");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = repo_dir ++ "/" ++ source_rel, .data = source_text });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = repo_dir ++ "/" ++ note_rel, .data = note_text });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside-directory-long/secret-file-long.txt", .data = secret_text });
        const top = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(top);
        const long = try join(top, repo_dir);
        errdefer testing.allocator.free(long);
        try git_fixture.initRepo(long);
        try run(long, &.{ "git", "add", "." });
        try run(long, &.{ "git", "commit", "-q", "-m", "init" });
        try tmp.dir.createDirPath(testing.io, repo_dir ++ "/.emetgate");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = repo_dir ++ "/.emetgate/secret-file-long.txt", .data = secret_text });
        try tmp.dir.createDirPath(testing.io, repo_dir ++ "/nested-repository-long");
        const nested = try join(long, "nested-repository-long");
        defer testing.allocator.free(nested);
        try git_fixture.initRepo(nested);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = repo_dir ++ "/nested-repository-long/inner-file-long.txt", .data = secret_text });
        const short = try shortOf(long);
        errdefer testing.allocator.free(short);
        if (std.mem.indexOfScalar(u8, std.fs.path.basename(short), '~') == null) return error.SkipZigTest;
        return .{ .tmp = tmp, .top = top, .long = long, .short = short };
    }

    fn deinit(self: *Served) void {
        testing.allocator.free(self.short);
        testing.allocator.free(self.long);
        testing.allocator.free(self.top);
        self.tmp.cleanup();
    }

    fn shortFile(self: Served, rel: []const u8) ![]u8 {
        const long = try join(self.long, rel);
        defer testing.allocator.free(long);
        return shortOf(long);
    }
};

const Reply = struct {
    parsed: std.json.Parsed(Value),
    body: std.json.Parsed(Value),
    is_error: bool,
    text: []const u8,

    fn deinit(self: *Reply) void {
        self.body.deinit();
        self.parsed.deinit();
    }

    fn field(self: Reply, name: []const u8) ?Value {
        return self.body.value.object.get(name);
    }
};

fn call(runtime: *Runtime, root: []const u8, tool: []const u8, args: anytype) !Reply {
    var line: std.Io.Writer.Allocating = .init(testing.allocator);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = tool, .arguments = args } });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = try server.handleMessageObserved(testing.allocator, testing.io, runtime, line.written(), &out.writer, null, .{ .root = root, .test_command = "cmd /c exit 0" });
    const parsed = try std.json.parseFromSlice(Value, testing.allocator, out.written(), .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.NotAToolResult;
    const text = result.object.get("content").?.array.items[0].object.get("text").?.string;
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const body = try std.json.parseFromSlice(Value, testing.allocator, text[0..end], .{});
    return .{ .parsed = parsed, .body = body, .is_error = result.object.get("isError").?.bool, .text = text };
}

fn expectRefused(runtime: *Runtime, root: []const u8, tool: []const u8, args: anytype, name: []const u8) !void {
    var reply = try call(runtime, root, tool, args);
    defer reply.deinit();
    errdefer std.debug.print("{s}: {s}\n", .{ tool, reply.text });
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings(name, reply.field("error").?.string);
    try testing.expect(std.mem.indexOf(u8, reply.text, "outside the reach") == null);
}

fn expectGated(runtime: *Runtime, served: *Served, root: []const u8, file: []const u8, body: []const u8) !void {
    var symbols = try call(runtime, root, "emetgate_symbols", .{ .file = file });
    defer symbols.deinit();
    errdefer std.debug.print("symbols: {s}\n", .{symbols.text});
    try testing.expect(!symbols.is_error);
    const hash = symbols.field("symbols").?.array.items[0].object.get("hash").?.string;

    var tried = try call(runtime, root, "emetgate_try", .{ .file = file, .symbol = "add", .hash = hash, .body = body });
    defer tried.deinit();
    errdefer std.debug.print("try: {s}\n", .{tried.text});
    try testing.expect(!tried.is_error);
    try testing.expectEqualStrings("committed", tried.field("status").?.string);
    const on_disk = try served.tmp.dir.readFileAlloc(testing.io, repo_dir ++ "/" ++ source_rel, testing.allocator, .unlimited);
    defer testing.allocator.free(on_disk);
    try testing.expect(std.mem.indexOf(u8, on_disk, body) != null);
}

fn expectRead(runtime: *Runtime, root: []const u8, file: []const u8) !void {
    var reply = try call(runtime, root, "emetgate_read_file", .{ .file = file });
    defer reply.deinit();
    errdefer std.debug.print("read_file: {s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings(note_text, reply.field("content").?.string);
}

fn expectListed(runtime: *Runtime, root: []const u8, dir: []const u8) !void {
    var reply = try call(runtime, root, "emetgate_list", .{ .dir = dir });
    defer reply.deinit();
    errdefer std.debug.print("list: {s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    var seen: usize = 0;
    for (reply.field("files").?.array.items) |item| {
        if (std.mem.eql(u8, item.string, note_rel) or std.mem.eql(u8, item.string, source_rel)) seen += 1;
    }
    try testing.expectEqual(@as(usize, 2), seen);
}

test "a repository reached through its 8.3 short path is read, listed and gated like the same repository by its long path" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var served = try Served.init();
    defer served.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const note_short = try served.shortFile(note_rel);
    defer testing.allocator.free(note_short);
    const source_short = try served.shortFile(source_rel);
    defer testing.allocator.free(source_short);
    try expectRead(runtime, served.long, note_short);
    try expectListed(runtime, served.long, served.short);
    try expectGated(runtime, &served, served.long, source_short, "{ return a - b; }");

    const prefixed = try join(served.short, source_rel);
    defer testing.allocator.free(prefixed);
    try expectGated(runtime, &served, served.long, prefixed, "{ return a * b; }");
}

test "a served root given by its 8.3 short path serves the files of that repository given by their long path" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var served = try Served.init();
    defer served.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const note_long = try join(served.long, note_rel);
    defer testing.allocator.free(note_long);
    const source_long = try join(served.long, source_rel);
    defer testing.allocator.free(source_long);
    try expectRead(runtime, served.short, note_long);
    try expectListed(runtime, served.short, served.long);
    try expectGated(runtime, &served, served.short, source_long, "{ return b - a; }");
}

test "a new file is created through a short-spelled parent directory, and not inside the workspace by its short name" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var served = try Served.init();
    defer served.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const fresh = "export function mul(a: number, b: number): number { return a * b; }";

    const parent_short = try served.shortFile("source-directory-long");
    defer testing.allocator.free(parent_short);
    const file = try join(parent_short, "mul.ts");
    defer testing.allocator.free(file);
    var created = try call(runtime, served.long, "emetgate_try", .{ .file = file, .symbol = "mul", .hash = "absent", .body = fresh });
    defer created.deinit();
    errdefer std.debug.print("try: {s}\n", .{created.text});
    try testing.expect(!created.is_error);
    try testing.expectEqualStrings("committed", created.field("status").?.string);
    try served.tmp.dir.access(testing.io, repo_dir ++ "/source-directory-long/mul.ts", .{});

    const workspace_short = try served.shortFile(".emetgate");
    defer testing.allocator.free(workspace_short);
    const inside = try join(workspace_short, "mul.ts");
    defer testing.allocator.free(inside);
    try expectRefused(runtime, served.long, "emetgate_try", .{ .file = inside, .symbol = "mul", .hash = "absent", .body = fresh }, "InternalPath");
    try testing.expectError(error.FileNotFound, served.tmp.dir.access(testing.io, repo_dir ++ "/.emetgate/mul.ts", .{}));
}

test "through a short-spelled root a path outside, a junction, a nested repository, .git and the workspace are still refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var served = try Served.init();
    defer served.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const outside_long = try join(served.top, "outside-directory-long");
    defer testing.allocator.free(outside_long);
    const link = try join(served.long, "linked-directory-long");
    defer testing.allocator.free(link);
    const cmd = try exe_path.system(testing.allocator, "cmd.exe");
    defer testing.allocator.free(cmd);
    try run(served.long, &.{ cmd, "/d", "/c", "mklink", "/J", link, outside_long });

    const outside_short = try shortOf(outside_long);
    defer testing.allocator.free(outside_short);
    const outside_file = try join(outside_short, "secret-file-long.txt");
    defer testing.allocator.free(outside_file);
    const climbed = try join(served.short, "..\\outside-directory-long\\secret-file-long.txt");
    defer testing.allocator.free(climbed);
    const through_link = try join(served.short, "linked-directory-long\\secret-file-long.txt");
    defer testing.allocator.free(through_link);
    const link_short = try served.shortFile("linked-directory-long");
    defer testing.allocator.free(link_short);
    const through_short_link = try join(link_short, "secret-file-long.txt");
    defer testing.allocator.free(through_short_link);
    const nested = try served.shortFile("nested-repository-long/inner-file-long.txt");
    defer testing.allocator.free(nested);
    const nested_prefixed = try join(served.short, "nested-repository-long\\inner-file-long.txt");
    defer testing.allocator.free(nested_prefixed);
    for ([_][]const u8{ outside_file, climbed, through_link, through_short_link, nested, nested_prefixed }) |file| {
        errdefer std.debug.print("not refused: {s}\n", .{file});
        for ([_][]const u8{ served.long, served.short }) |root| {
            try expectRefused(runtime, root, "emetgate_read_file", .{ .file = file }, "FileOutsideRepo");
            try expectRefused(runtime, root, "emetgate_try", .{ .file = file, .symbol = "add", .hash = "absent", .body = "export const add = 1;" }, "FileOutsideRepo");
        }
    }
    try expectRefused(runtime, served.long, "emetgate_list", .{ .dir = outside_short }, "FileOutsideRepo");

    const git_prefixed = try join(served.short, ".git\\HEAD");
    defer testing.allocator.free(git_prefixed);
    const git_short = try served.shortFile(".git/HEAD");
    defer testing.allocator.free(git_short);
    const git_dir_short = try served.shortFile(".git");
    defer testing.allocator.free(git_dir_short);
    const workspace_prefixed = try join(served.short, ".emetgate\\secret-file-long.txt");
    defer testing.allocator.free(workspace_prefixed);
    const workspace_short = try served.shortFile(".emetgate/secret-file-long.txt");
    defer testing.allocator.free(workspace_short);
    const workspace_dir_short = try served.shortFile(".emetgate");
    defer testing.allocator.free(workspace_dir_short);
    const workspace_by_alias = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}\\secret-file-long.txt", .{ served.long, std.fs.path.basename(workspace_dir_short) });
    defer testing.allocator.free(workspace_by_alias);
    const git_by_alias = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}\\HEAD", .{ served.long, std.fs.path.basename(git_dir_short) });
    defer testing.allocator.free(git_by_alias);
    for ([_][]const u8{ git_prefixed, git_short, git_by_alias, workspace_prefixed, workspace_short, workspace_by_alias }) |file| {
        errdefer std.debug.print("not refused: {s}\n", .{file});
        for ([_][]const u8{ served.long, served.short }) |root| {
            try expectRefused(runtime, root, "emetgate_read_file", .{ .file = file }, "InternalPath");
        }
    }
    try expectRefused(runtime, served.long, "emetgate_list", .{ .dir = git_dir_short }, "InternalPath");
}

fn freeDrive() !u8 {
    var letter: u8 = 'Z';
    while (letter >= 'H') : (letter -= 1) {
        const drive = [_]u8{ letter, ':', '\\' };
        std.Io.Dir.cwd().access(testing.io, &drive, .{}) catch |err| switch (err) {
            error.FileNotFound => return letter,
            else => continue,
        };
    }
    return error.SkipZigTest;
}

test "a subst drive onto a directory outside is refused, and .git stays refused through a subst drive onto the short-spelled root" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var served = try Served.init();
    defer served.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const subst = exe_path.system(testing.allocator, "subst.exe") catch return error.SkipZigTest;
    defer testing.allocator.free(subst);
    const outside_long = try join(served.top, "outside-directory-long");
    defer testing.allocator.free(outside_long);
    const outside_short = try shortOf(outside_long);
    defer testing.allocator.free(outside_short);

    const letter = try freeDrive();
    const drive = [_]u8{ letter, ':' };
    for ([_][]const u8{ outside_short, served.short }, [_][]const u8{ "secret-file-long.txt", ".git\\HEAD" }, [_][]const u8{ "FileOutsideRepo", "InternalPath" }) |target, rel, refusal| {
        run(served.top, &.{ subst, &drive, target }) catch return error.SkipZigTest;
        defer run(served.top, &.{ subst, &drive, "/D" }) catch {};
        const file = try join(&drive, rel);
        defer testing.allocator.free(file);
        std.Io.Dir.cwd().access(testing.io, file, .{}) catch return error.SkipZigTest;
        for ([_][]const u8{ served.long, served.short }) |root| {
            try expectRefused(runtime, root, "emetgate_read_file", .{ .file = file }, refusal);
        }
    }
}

test "a path whose final name cannot be read is refused instead of being compared as spelled" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const top = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(top);
    const missing = try join(top, "no-such-directory\\file.txt");
    defer testing.allocator.free(missing);
    try testing.expectError(error.FileOutsideRepo, repo_mod.finalOf(testing.allocator, missing));
    try testing.expectError(error.FileOutsideRepo, repo_mod.servedRoot(testing.allocator, testing.io, missing));
    const final = try repo_mod.finalOf(testing.allocator, top);
    defer testing.allocator.free(final);
    try testing.expect(std.ascii.endsWithIgnoreCase(final, std.fs.path.basename(top)));
}
