const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const search_index = @import("emetgate").search_index;
const search_session = @import("emetgate").search_session;
const rg_search = @import("emetgate").rg_search;
const exe_path = @import("emetgate").exe_path;
const Runtime = @import("emetgate").runtime.Runtime;

const testing = std.testing;
const gpa = testing.allocator;

const Repo = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,

    fn init(files: []const [2][]const u8) !Repo {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        for (files) |f| {
            if (std.fs.path.dirname(f[0])) |dir| try tmp.dir.createDirPath(testing.io, dir);
            try tmp.dir.writeFile(testing.io, .{ .sub_path = f[0], .data = f[1] });
        }
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
        errdefer gpa.free(root);
        try git_fixture.initRepo(root);
        try git(root, &.{ "add", "." });
        try git(root, &.{ "commit", "-q", "-m", "init" });
        return .{ .tmp = tmp, .root = root };
    }

    fn deinit(self: *Repo) void {
        if (search_index.indexDir(gpa, self.root)) |dir| {
            std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
            gpa.free(dir);
        } else |_| {}
        gpa.free(self.root);
        self.tmp.cleanup();
    }
};

fn git(root: []const u8, args: []const []const u8) !void {
    var argv: [8][]const u8 = undefined;
    argv[0] = try exe_path.git(gpa, root);
    defer gpa.free(argv[0]);
    @memcpy(argv[1..][0..args.len], args);
    const result = try std.process.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root } });
    gpa.free(result.stdout);
    gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitSetupFailed,
        else => return error.GitSetupFailed,
    }
}

const Reply = struct {
    text: []u8,
    is_error: bool,

    fn deinit(self: Reply) void {
        gpa.free(self.text);
    }

    fn status(self: Reply) []const u8 {
        const at = std.mem.lastIndexOfScalar(u8, self.text, '\n') orelse return self.text;
        return self.text[at + 1 ..];
    }
};

fn search(runtime: *Runtime, session: ?*search_session.Session, root: []const u8, args: anytype) !Reply {
    return searchServed(runtime, session, root, &.{}, args);
}

fn searchServed(runtime: *Runtime, session: ?*search_session.Session, root: []const u8, flags: []const []const u8, args: anytype) !Reply {
    var policy = server.parsePolicy(flags) orelse return error.RefusedFlags;
    policy.root = root;
    policy.search_session = session;
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = "emetgate_search", .arguments = args } });
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try server.handleMessageObserved(gpa, testing.io, runtime, line.written(), &out.writer, null, policy);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.written(), .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.NotAToolResult;
    const text = result.object.get("content").?.array.items[0].object.get("text").?.string;
    return .{ .text = try gpa.dupe(u8, text), .is_error = result.object.get("isError").?.bool };
}

const Spot = struct {
    file: []const u8,
    line: u32,

    fn less(_: void, a: Spot, b: Spot) bool {
        return switch (std.mem.order(u8, a.file, b.file)) {
            .lt => true,
            .gt => false,
            .eq => a.line < b.line,
        };
    }
};

fn spotsOf(arena: std.mem.Allocator, text: []const u8) ![]Spot {
    var out: std.ArrayList(Spot) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var file: []const u8 = "";
    var pending: ?[]const u8 = lines.next();
    while (pending) |l| {
        pending = lines.next();
        if (pending == null) break;
        if (l.len == 0 or l[0] == '|') continue;
        var i: usize = 0;
        while (i < l.len and std.ascii.isDigit(l[i])) i += 1;
        if (i != 0 and i < l.len and (l[i] == ':' or l[i] == '|' or l[i] == '*')) {
            try out.append(arena, .{ .file = file, .line = try std.fmt.parseInt(u32, l[0..i], 10) });
        } else {
            file = l;
        }
    }
    return out.toOwnedSlice(arena);
}

fn rgSpots(arena: std.mem.Allocator, root: []const u8, pattern: []const u8) ![]Spot {
    const rg = rg_search.find(gpa, root) catch |err| switch (err) {
        error.RgNotFound => return error.SkipZigTest,
        else => |e| return e,
    };
    defer gpa.free(rg);
    const result = try std.process.run(arena, testing.io, .{
        .argv = &.{ rg, "-n", "--no-heading", "--with-filename", "--hidden", "--no-config", "--crlf", "--path-separator", "/", "-g", "!.git", "-e", pattern, "." },
        .cwd = .{ .path = root },
    });
    var out: std.ArrayList(Spot) = .empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |l| {
        const first = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        const second = std.mem.indexOfScalarPos(u8, l, first + 1, ':') orelse continue;
        var file = l[0..first];
        if (std.mem.startsWith(u8, file, "./")) file = file[2..];
        try out.append(arena, .{ .file = file, .line = try std.fmt.parseInt(u32, l[first + 1 .. second], 10) });
    }
    return out.toOwnedSlice(arena);
}

fn expectSameSpots(arena: std.mem.Allocator, want: []Spot, got: []Spot) !void {
    std.mem.sort(Spot, want, {}, Spot.less);
    std.mem.sort(Spot, got, {}, Spot.less);
    errdefer {
        for (want) |s| std.debug.print("want {s}:{d}\n", .{ s.file, s.line });
        for (got) |s| std.debug.print("got  {s}:{d}\n", .{ s.file, s.line });
    }
    _ = arena;
    try testing.expectEqual(want.len, got.len);
    for (want, got) |a, b| {
        try testing.expectEqualStrings(a.file, b.file);
        try testing.expectEqual(a.line, b.line);
    }
}

fn rgChars(root: []const u8, pattern: []const u8) !usize {
    const rg = rg_search.find(gpa, root) catch |err| switch (err) {
        error.RgNotFound => return error.SkipZigTest,
        else => |e| return e,
    };
    defer gpa.free(rg);
    const result = try std.process.run(gpa, testing.io, .{
        .argv = &.{ rg, "-n", "--no-heading", "--with-filename", "--hidden", "--no-config", "--path-separator", "/", "-g", "!.git", "-e", pattern, "." },
        .cwd = .{ .path = root },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return std.unicode.utf8CountCodepoints(result.stdout) catch result.stdout.len;
}

const golden_files = [_][2][]const u8{
    .{ "src/greet.ts", "export function greet(name: string) {\n  return 'hello ' + name;\n}\n" },
    .{ "src/app.ts", "import { greet } from './greet';\nimport { log } from './log';\nexport function main() {\n  greet('main');\n  log('done');\n}\n" },
    .{ "src/other.ts", "import { greet } from './greet';\nimport { log } from './log';\nexport const other = () => greet('other');\n" },
    .{ "docs/notes.md", "# Notes\n\nCall greet to say hello.\n" },
};

test "search text: a reply lists each file once, its lines as line:text, a starred definition, a legend for repeated lines and a check mark" {
    var repo = try Repo.init(&golden_files);
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    const reply = try search(runtime, null, repo.root, .{ .pattern = "greet", .dir = repo.root });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings(
        "|1 import { greet } from './greet';\n" ++
            "src/greet.ts\n1*:export function greet(name: string) {\n" ++
            "src/app.ts\n1|1\n4:greet('main');\n" ++
            "src/other.ts\n1|1\n3:export const other = () => greet('other');\n" ++
            "docs/notes.md\n3:Call greet to say hello.\n" ++
            "\u{2713}",
        reply.text,
    );

    const none = try search(runtime, null, repo.root, .{ .pattern = "absent_word", .dir = repo.root });
    defer none.deinit();
    try testing.expectEqualStrings("\u{2713} no match in 4 file(s)", none.text);
}

test "search text: every reply of the fixture queries is shorter than ripgrep's own output for the same pattern" {
    var repo = try Repo.init(&golden_files);
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    for ([_][]const u8{ "greet", "import", "log", "export" }) |pattern| {
        const reply = try search(runtime, null, repo.root, .{ .pattern = pattern, .dir = repo.root });
        defer reply.deinit();
        const ours = try std.unicode.utf8CountCodepoints(reply.text);
        const theirs = try rgChars(repo.root, pattern);
        errdefer std.debug.print("{s}: {d} against rg {d}\n{s}\n", .{ pattern, ours, theirs, reply.text });
        try testing.expect(ours <= theirs);
    }
}

test "search text: a line over 120 characters shows the match inside a window cut with an ellipsis" {
    const long = "var a=1;" ** 40 ++ "windowneedle();" ++ "var b=2;" ** 40;
    var repo = try Repo.init(&.{.{ "min.js", long ++ "\n" }});
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    const reply = try search(runtime, null, repo.root, .{ .pattern = "windowneedle", .dir = repo.root });
    defer reply.deinit();
    var lines = std.mem.splitScalar(u8, reply.text, '\n');
    try testing.expectEqualStrings("min.js", lines.next().?);
    const hit = lines.next().?;
    try testing.expect(std.mem.startsWith(u8, hit, "1:\u{2026}"));
    try testing.expect(std.mem.endsWith(u8, hit, "\u{2026}"));
    try testing.expect(std.mem.indexOf(u8, hit, "windowneedle();") != null);
    try testing.expect(std.unicode.utf8CountCodepoints(hit) catch unreachable <= 2 + 120 + 2);
    try testing.expectEqualStrings("\u{2713}", lines.next().?);
}

test "search text: pages carry the exact total and the next offset, and together they hold every match once" {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var names: [3][2][]const u8 = undefined;
    var storage: [3][]u8 = undefined;
    for (0..3) |f| {
        body.clearRetainingCapacity();
        for (0..100) |i| try body.print(gpa, "pagedneedle number {d} in file {d}\n", .{ i, f });
        storage[f] = try gpa.dupe(u8, body.items);
        names[f] = .{ switch (f) {
            0 => "a.txt",
            1 => "b.txt",
            else => "c.txt",
        }, storage[f] };
    }
    defer for (storage) |b| gpa.free(b);
    var repo = try Repo.init(&names);
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    var session = search_session.Session.init(gpa, testing.io, repo.root, .{});
    defer session.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var all: std.ArrayList(Spot) = .empty;
    var offset: usize = 0;
    var pages: usize = 0;
    while (true) : (pages += 1) {
        try testing.expect(pages < 20);
        const reply = try search(runtime, &session, repo.root, .{ .pattern = "pagedneedle", .dir = repo.root, .offset = offset });
        defer reply.deinit();
        const spots = try spotsOf(arena, try arena.dupe(u8, reply.text));
        try all.appendSlice(arena, spots);
        const status = reply.status();
        const next = std.mem.indexOf(u8, status, "next offset:") orelse {
            try testing.expect(pages != 0);
            try testing.expect(std.mem.indexOf(u8, status, " of 300") != null);
            break;
        };
        var buf: [64]u8 = undefined;
        const want = try std.fmt.bufPrint(&buf, "partial: matches {d}-{d} of 300;", .{ offset + 1, offset + spots.len });
        errdefer std.debug.print("{s}\n", .{status});
        try testing.expect(std.mem.startsWith(u8, status, want));
        offset = try std.fmt.parseInt(usize, status[next + "next offset:".len ..], 10);
        try testing.expectEqual(all.items.len, offset);
    }
    try testing.expectEqual(@as(usize, 300), all.items.len);
    std.mem.sort(Spot, all.items, {}, Spot.less);
    for (all.items[1..], all.items[0 .. all.items.len - 1]) |b, a| {
        try testing.expect(!(std.mem.eql(u8, a.file, b.file) and a.line == b.line));
    }
}

test "search text: a regex the index cannot run is searched by ripgrep with the same hits rg finds and says so" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init(&.{
        .{ "src/a.js", "forget(1);\nforgetful(2);\nnever forget\nsess.id = 1;\nPath.join();\ntrailing whitespace\ntrail\n" },
        .{ "src/b.js", "bodyParser(x);\nnotbodyParser(y);\r\nthe trailingness\r\n" },
    });
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "\\bforget\\b", "\\bbodyParser\\(", "(?:sess|Path)\\.", "trailing\\w{2,}" }) |pattern| {
        const reply = try search(runtime, null, repo.root, .{ .pattern = pattern, .regex = true, .dir = repo.root });
        defer reply.deinit();
        errdefer std.debug.print("{s}:\n{s}\n", .{ pattern, reply.text });
        try testing.expect(!reply.is_error);
        try testing.expect(std.mem.endsWith(u8, reply.text, "; delegated to rg"));
        const ours = try spotsOf(arena, try arena.dupe(u8, reply.text));
        const theirs = try rgSpots(arena, repo.root, pattern);
        try testing.expect(theirs.len != 0);
        try expectSameSpots(arena, theirs, ours);
    }

    const broken = try search(runtime, null, repo.root, .{ .pattern = "(?:unclosed", .regex = true, .dir = repo.root });
    defer broken.deinit();
    try testing.expect(broken.is_error);
    try testing.expect(std.mem.startsWith(u8, broken.text, "error: InvalidRegex: "));
}

extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: std.os.windows.DWORD, share: std.os.windows.DWORD, security: ?*anyopaque, disposition: std.os.windows.DWORD, flags: std.os.windows.DWORD, template: ?std.os.windows.HANDLE) callconv(.winapi) std.os.windows.HANDLE;

fn holdWithoutSharing(path: []const u8) !std.os.windows.HANDLE {
    var wide: [std.os.windows.PATH_MAX_WIDE:0]u16 = undefined;
    const len = try std.unicode.wtf8ToWtf16Le(&wide, path);
    wide[len] = 0;
    for (0..200) |_| {
        const handle = CreateFileW(&wide, 0x80000000, 0, null, 3, 0x80, null);
        if (handle != std.os.windows.INVALID_HANDLE_VALUE) return handle;
        try std.Io.sleep(testing.io, .fromMilliseconds(5), .awake);
    }
    return error.HoldFailed;
}

test "search text: a file another handle holds without sharing turns the check mark into partial with its name" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init(&.{
        .{ "src/held.ts", "export const a = 1;\n" },
        .{ "src/open.ts", "export const heldneedle = 2;\n" },
    });
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    var session = search_session.Session.init(gpa, testing.io, repo.root, .{});
    defer session.deinit();
    const warm = try search(runtime, &session, repo.root, .{ .pattern = "heldneedle", .dir = repo.root });
    warm.deinit();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "src/held.ts", .data = "export const heldneedle = 3;\n" });
    const held = try std.fmt.allocPrint(gpa, "{s}\\src\\held.ts", .{repo.root});
    defer gpa.free(held);
    const holder = try holdWithoutSharing(held);
    defer std.os.windows.CloseHandle(holder);
    const reply = try search(runtime, &session, repo.root, .{ .pattern = "heldneedle", .dir = repo.root });
    defer reply.deinit();
    try testing.expectEqualStrings("src/open.ts\n1:export const heldneedle = 2;\npartial: src/held.ts unreadable", reply.text);
}

fn searchProperties(runtime: *Runtime) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try server.handleMessage(gpa, testing.io, runtime, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}", &out.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.written(), .{});
    defer parsed.deinit();
    var names: std.Io.Writer.Allocating = .init(gpa);
    defer names.deinit();
    for (parsed.value.object.get("result").?.object.get("tools").?.array.items) |tool| {
        if (!std.mem.eql(u8, tool.object.get("name").?.string, "emetgate_search")) continue;
        for (tool.object.get("inputSchema").?.object.get("properties").?.object.keys()) |key| try names.writer.print("{s} ", .{key});
    }
    return names.toOwnedSlice();
}

test "search text: the model's tool offers and obeys no format, certificate or stats, and only --search-internals turns them on" {
    var repo = try Repo.init(&golden_files);
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    const offered = try searchProperties(runtime);
    defer gpa.free(offered);
    try testing.expectEqualStrings("pattern dir regex kinds offset detail ", offered);

    const served = server.parsePolicy(&[_][]const u8{}).?;
    try testing.expect(served.search_text and !served.search_internals);
    try testing.expect(server.parsePolicy(&[_][]const u8{"--search-internals"}).?.search_internals);
    try testing.expect(server.parsePolicy(&[_][]const u8{ "--search-internals", "--search-internals" }) == null);

    const plain = try search(runtime, null, repo.root, .{ .pattern = "greet", .dir = repo.root });
    defer plain.deinit();
    try testing.expect(!plain.is_error);
    try testing.expect(std.mem.endsWith(u8, plain.text, "\n\u{2713}"));
    inline for (.{
        .{ .pattern = "greet", .dir = repo.root, .format = "json" },
        .{ .pattern = "greet", .dir = repo.root, .format = "xml" },
        .{ .pattern = "greet", .dir = repo.root, .certificate = true },
        .{ .pattern = "greet", .dir = repo.root, .stats = true },
    }) |args| {
        const asked = try search(runtime, null, repo.root, args);
        defer asked.deinit();
        try testing.expect(!asked.is_error);
        try testing.expectEqualStrings(plain.text, asked.text);
    }

    const internals = &[_][]const u8{"--search-internals"};
    const same = try searchServed(runtime, null, repo.root, internals, .{ .pattern = "greet", .dir = repo.root });
    defer same.deinit();
    try testing.expectEqualStrings(plain.text, same.text);
    const bad = try searchServed(runtime, null, repo.root, internals, .{ .pattern = "greet", .dir = repo.root, .format = "xml" });
    defer bad.deinit();
    try testing.expect(bad.is_error);
    try testing.expectEqualStrings("error: UnknownFormat", bad.text);
    const certified = try searchServed(runtime, null, repo.root, internals, .{ .pattern = "greet", .dir = repo.root, .certificate = true });
    defer certified.deinit();
    try testing.expect(std.mem.startsWith(u8, certified.text, "{\"answer\":"));
    try testing.expect(std.mem.indexOf(u8, certified.text, "\"certificate\":") != null);
    const json = try searchServed(runtime, null, repo.root, internals, .{ .pattern = "greet", .dir = repo.root, .format = "json" });
    defer json.deinit();
    try testing.expect(std.mem.indexOf(u8, json.text, "\"total\":6") != null);
    const timed = try searchServed(runtime, null, repo.root, internals, .{ .pattern = "greet", .dir = repo.root, .stats = true });
    defer timed.deinit();
    try testing.expect(std.mem.indexOf(u8, timed.text, "\"stats\":") != null);
}
