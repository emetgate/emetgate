const std = @import("std");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const Runtime = @import("emetgate").runtime.Runtime;

const testing = std.testing;
const gpa = testing.allocator;
const Value = std.json.Value;

const Reply = struct {
    parsed: std.json.Parsed(Value),
    is_error: bool,
    text: []const u8,

    fn deinit(self: *Reply) void {
        self.parsed.deinit();
    }

    fn payload(self: *Reply) !std.json.Parsed(Value) {
        const end = std.mem.indexOfScalar(u8, self.text, '\n') orelse self.text.len;
        return std.json.parseFromSlice(Value, gpa, self.text[0..end], .{});
    }
};

const Repo = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,

    fn init() !Repo {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside.txt", .data = "not part of the repo\n" });
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
        errdefer gpa.free(root_abs);
        try git_fixture.initRepo(root_abs);
        return .{ .tmp = tmp, .root_abs = root_abs };
    }

    fn deinit(self: *Repo) void {
        gpa.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn writeFile(self: *Repo, rel: []const u8, data: []const u8) !void {
        const target = try std.fmt.allocPrint(gpa, "repo/{s}", .{rel});
        defer gpa.free(target);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = target, .data = data });
    }

    fn git(self: *Repo, args: []const []const u8) !void {
        var argv: [8][]const u8 = undefined;
        argv[0] = "git";
        @memcpy(argv[1..][0..args.len], args);
        const result = try std.process.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = self.root_abs } });
        gpa.free(result.stdout);
        gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitSetupFailed,
            else => return error.GitSetupFailed,
        }
    }

    fn commitAll(self: *Repo, message: []const u8) !void {
        try self.git(&.{ "add", "." });
        try self.git(&.{ "commit", "-q", "-m", message });
    }
};

fn callTool(runtime: *Runtime, root_abs: []const u8, args: anytype) !Reply {
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = "emetgate_git", .arguments = args } });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try server.handleMessageObserved(gpa, testing.io, runtime, line.written(), &out.writer, null, .{ .root = root_abs });

    const parsed = try std.json.parseFromSlice(Value, gpa, out.written(), .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.NotAToolResult;
    const content = result.object.get("content").?.array.items[0];
    return .{ .parsed = parsed, .is_error = result.object.get("isError").?.bool, .text = content.object.get("text").?.string };
}

fn expectError(runtime: *Runtime, root_abs: []const u8, args: anytype, name: []const u8) !void {
    var reply = try callTool(runtime, root_abs, args);
    defer reply.deinit();
    try testing.expect(reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings(name, body.value.object.get("error").?.string);
}

test "git status lists an untracked file" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "one\n");

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callTool(runtime, repo.root_abs, .{ .sub = "status", .path = repo.root_abs });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expect(!body.value.object.get("clean").?.bool);
    const untracked = body.value.object.get("untracked").?.object;
    try testing.expectEqual(@as(i64, 1), untracked.get("count").?.integer);
    try testing.expectEqualStrings("a.txt", untracked.get("files").?.array.items[0].string);

    var full = try callTool(runtime, repo.root_abs, .{ .sub = "status", .path = repo.root_abs, .detail = "full" });
    defer full.deinit();
    var full_body = try full.payload();
    defer full_body.deinit();
    try testing.expect(std.mem.indexOf(u8, full_body.value.object.get("output").?.string, "a.txt") != null);
}

test "git status groups entries and collapses an untracked directory" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("tracked.txt", "one\n");
    try repo.commitAll("seed");
    try repo.writeFile("tracked.txt", "two\n");
    try repo.git(&.{ "add", "tracked.txt" });
    try repo.writeFile("tracked.txt", "three\n");
    try repo.tmp.dir.createDirPath(testing.io, "repo/logs");
    try repo.writeFile("logs/a.log", "x\n");
    try repo.writeFile("logs/b.log", "y\n");
    try repo.writeFile("root.tmp", "z\n");

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callTool(runtime, repo.root_abs, .{ .sub = "status", .path = repo.root_abs });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expect(body.value.object.get("staged").?.object.get("count").?.integer == 1);
    try testing.expect(body.value.object.get("unstaged").?.object.get("count").?.integer == 1);
    const untracked = body.value.object.get("untracked").?.object;
    try testing.expectEqual(@as(i64, 2), untracked.get("count").?.integer);
    try testing.expectEqual(@as(usize, 1), untracked.get("files").?.array.items.len);
    const dirs = untracked.get("dirs").?.array;
    try testing.expectEqual(@as(usize, 1), dirs.items.len);
    try testing.expectEqualStrings("logs", dirs.items[0].object.get("dir").?.string);
    try testing.expectEqual(@as(i64, 2), dirs.items[0].object.get("count").?.integer);
}

test "git log reports commits newest first and n clamps the count" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "one\n");
    try repo.commitAll("first");
    try repo.writeFile("a.txt", "two\n");
    try repo.commitAll("second");

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callTool(runtime, repo.root_abs, .{ .sub = "log", .n = 1, .path = repo.root_abs });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    const commits = body.value.object.get("commits").?.array;
    try testing.expectEqual(@as(usize, 1), commits.items.len);
    try testing.expectEqualStrings("second", commits.items[0].object.get("subject").?.string);
    try testing.expectEqual(@as(i64, 1), body.value.object.get("commits_shown").?.integer);
    try testing.expect(body.value.object.get("next_cursor") != null);
}

test "git log pages from a cursor to older commits" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "one\n");
    try repo.commitAll("first");
    try repo.writeFile("a.txt", "two\n");
    try repo.commitAll("second");
    try repo.writeFile("a.txt", "three\n");
    try repo.commitAll("third");

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var page1 = try callTool(runtime, repo.root_abs, .{ .sub = "log", .n = 1, .path = repo.root_abs });
    defer page1.deinit();
    var b1 = try page1.payload();
    defer b1.deinit();
    try testing.expectEqualStrings("third", b1.value.object.get("commits").?.array.items[0].object.get("subject").?.string);
    const cursor = b1.value.object.get("next_cursor").?.string;

    var page2 = try callTool(runtime, repo.root_abs, .{ .sub = "log", .n = 1, .cursor = cursor, .path = repo.root_abs });
    defer page2.deinit();
    var b2 = try page2.payload();
    defer b2.deinit();
    try testing.expectEqualStrings("second", b2.value.object.get("commits").?.array.items[0].object.get("subject").?.string);
}

test "git diff shows a working tree change, cached shows a staged one" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "one\n");
    try repo.commitAll("first");
    try repo.writeFile("a.txt", "two\n");

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var working = try callTool(runtime, repo.root_abs, .{ .sub = "diff", .path = repo.root_abs });
    defer working.deinit();
    try testing.expect(!working.is_error);
    var working_body = try working.payload();
    defer working_body.deinit();
    try testing.expect(std.mem.indexOf(u8, working_body.value.object.get("output").?.string, "-one") != null);

    try repo.git(&.{ "add", "a.txt" });
    var staged = try callTool(runtime, repo.root_abs, .{ .sub = "diff", .staged = true, .path = repo.root_abs });
    defer staged.deinit();
    var staged_body = try staged.payload();
    defer staged_body.deinit();
    try testing.expect(std.mem.indexOf(u8, staged_body.value.object.get("output").?.string, "+two") != null);
}

test "git show returns one commit and refuses a malformed commit id" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "one\n");
    try repo.commitAll("first");

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callTool(runtime, repo.root_abs, .{ .sub = "show", .commit = "HEAD", .path = repo.root_abs });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expect(std.mem.startsWith(u8, body.value.object.get("output").?.string, "commit "));

    try expectError(runtime, repo.root_abs, .{ .sub = "show", .commit = "; whoami", .path = repo.root_abs }, "InvalidCommit");
    try expectError(runtime, repo.root_abs, .{ .sub = "show", .path = repo.root_abs }, "MissingCommit");
}

test "git refuses an unknown subcommand and a path outside the repo" {
    var repo = try Repo.init();
    defer repo.deinit();

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    try expectError(runtime, repo.root_abs, .{ .sub = "clone", .path = repo.root_abs }, "UnknownGitSubcommand");

    const outside = try std.fmt.allocPrint(gpa, "{s}\\..\\outside.txt", .{repo.root_abs});
    defer gpa.free(outside);
    try expectError(runtime, repo.root_abs, .{ .sub = "log", .path = outside }, "FileOutsideRepo");
}

test "git diff folds a big diff under the budget and names the elided span" {
    var repo = try Repo.init();
    defer repo.deinit();
    var big_before: std.Io.Writer.Allocating = .init(gpa);
    defer big_before.deinit();
    for (0..1500) |i| try big_before.writer.print("line {d}\n", .{i});
    try repo.writeFile("big.txt", big_before.written());
    try repo.commitAll("big file");

    var big_after: std.Io.Writer.Allocating = .init(gpa);
    defer big_after.deinit();
    for (0..1500) |i| try big_after.writer.print("changed {d}\n", .{i});
    try repo.writeFile("big.txt", big_after.written());

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callTool(runtime, repo.root_abs, .{ .sub = "diff", .path = repo.root_abs });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings("compact", body.value.object.get("view").?.string);
    const shown = body.value.object.get("lines_shown").?.integer;
    const totalc = body.value.object.get("lines_total").?.integer;
    try testing.expect(shown < totalc);
    const elided = body.value.object.get("elided").?.array;
    try testing.expectEqual(@as(usize, 1), elided.items.len);
    try testing.expect(std.mem.indexOf(u8, body.value.object.get("output").?.string, "elided") != null);
    try testing.expect(body.value.object.get("output").?.string.len <= 8 * 1024 + 512);

    var full = try callTool(runtime, repo.root_abs, .{ .sub = "diff", .path = repo.root_abs, .detail = "full" });
    defer full.deinit();
    var full_body = try full.payload();
    defer full_body.deinit();
    try testing.expectEqualStrings("full", full_body.value.object.get("view").?.string);
    try testing.expect(full_body.value.object.get("output").?.string.len > body.value.object.get("output").?.string.len);

    var so = try callTool(runtime, repo.root_abs, .{ .sub = "diff", .path = repo.root_abs, .symbols_only = true });
    defer so.deinit();
    var so_body = try so.payload();
    defer so_body.deinit();
    try testing.expect(so_body.value.object.get("output") == null);
    try testing.expect(so_body.value.object.get("symbol_changes") != null);
}

test "git diff full caps raw output at the line limit and marks it truncated" {
    var repo = try Repo.init();
    defer repo.deinit();
    var big_before: std.Io.Writer.Allocating = .init(gpa);
    defer big_before.deinit();
    for (0..1500) |i| try big_before.writer.print("line {d}\n", .{i});
    try repo.writeFile("big.txt", big_before.written());
    try repo.commitAll("big file");

    var big_after: std.Io.Writer.Allocating = .init(gpa);
    defer big_after.deinit();
    for (0..1500) |i| try big_after.writer.print("changed {d}\n", .{i});
    try repo.writeFile("big.txt", big_after.written());

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callTool(runtime, repo.root_abs, .{ .sub = "diff", .path = repo.root_abs, .detail = "full" });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expect(body.value.object.get("truncated").?.bool);
    try testing.expectEqual(@as(i64, 800), body.value.object.get("lines_shown").?.integer);
    try testing.expect(body.value.object.get("lines_shown").?.integer < body.value.object.get("lines_total").?.integer);
}

// --- symbol-level diff / show / blame --------------------------------------

fn findChange(body: Value, ref: []const u8) ?[]const u8 {
    const files = body.object.get("symbol_changes") orelse return null;
    for (files.array.items) |file| {
        const syms = file.object.get("symbols") orelse continue;
        for (syms.array.items) |sym| {
            if (std.mem.eql(u8, sym.object.get("ref").?.string, ref)) {
                return sym.object.get("change").?.string;
            }
        }
    }
    return null;
}

test "symbol diff reports a changed function body at the symbol level" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("x.ts", "export function foo(): number {\n  return 1;\n}\n");
    try repo.commitAll("add foo");
    try repo.writeFile("x.ts", "export function foo(): number {\n  return 2;\n}\n");

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callTool(runtime, repo.root_abs, .{ .sub = "diff", .path = repo.root_abs });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings("changed", findChange(body.value, "foo").?);
}

test "symbol diff reports an added function and an added type" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("x.ts", "export function foo(): number {\n  return 1;\n}\n");
    try repo.commitAll("add foo");
    try repo.writeFile("x.ts", "export function foo(): number {\n  return 1;\n}\nexport function bar(): void {}\nexport type Baz = string;\n");

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callTool(runtime, repo.root_abs, .{ .sub = "diff", .path = repo.root_abs });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings("added", findChange(body.value, "bar").?);
    try testing.expectEqualStrings("added", findChange(body.value, "Baz").?);
    // foo was untouched, so it is not listed.
    try testing.expect(findChange(body.value, "foo") == null);
}

test "symbol diff flags a comment-only change as a non-symbol change" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("x.ts", "export function foo(): number {\n  return 1;\n}\n");
    try repo.commitAll("add foo");
    try repo.writeFile("x.ts", "// a leading comment\nexport function foo(): number {\n  return 1;\n}\n");

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callTool(runtime, repo.root_abs, .{ .sub = "diff", .path = repo.root_abs });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expect(findChange(body.value, "foo") == null);
    const files = body.value.object.get("symbol_changes").?.array;
    try testing.expect(files.items.len == 1);
    try testing.expect(files.items[0].object.get("non_symbol_change").?.bool);
    try testing.expect(files.items[0].object.get("mapped") == null);
    try testing.expect(files.items[0].object.get("symbol_changes_truncated") == null);
}

test "symbol blame maps a symbol to the commit that last changed it" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("x.ts", "export function foo(): number {\n  return 1;\n}\n");
    try repo.commitAll("add foo");

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    const file_abs = try std.fmt.allocPrint(gpa, "{s}/x.ts", .{repo.root_abs});
    defer gpa.free(file_abs);
    var reply = try callTool(runtime, repo.root_abs, .{ .sub = "blame", .path = file_abs });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    const blame = body.value.object.get("symbol_blame").?;
    try testing.expect(blame.object.get("mapped").?.bool);
    try testing.expect(body.value.object.get("output") == null);
    const syms = blame.object.get("symbols").?.array;
    var found = false;
    for (syms.items) |sym| {
        if (std.mem.eql(u8, sym.object.get("ref").?.string, "foo")) {
            found = true;
            try testing.expectEqualStrings("add foo", sym.object.get("summary").?.string);
        }
    }
    try testing.expect(found);

    var full = try callTool(runtime, repo.root_abs, .{ .sub = "blame", .path = file_abs, .detail = "full" });
    defer full.deinit();
    var full_body = try full.payload();
    defer full_body.deinit();
    try testing.expect(full_body.value.object.get("output") != null);
}

test "symbol blame of a line window in a file whose whole blame is huge stays mapped and returns" {
    var repo = try Repo.init();
    defer repo.deinit();
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    for (0..1800) |_| {
        try text.writer.writeAll("# ");
        try text.writer.splatByteAll('x', 1200);
        try text.writer.writeByte('\n');
    }
    try text.writer.writeAll("def tail():\n    return 1\n");
    try repo.writeFile("big.py", text.written());
    try repo.commitAll("add big");

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    const file_abs = try std.fmt.allocPrint(gpa, "{s}/big.py", .{repo.root_abs});
    defer gpa.free(file_abs);
    var reply = try callTool(runtime, repo.root_abs, .{ .sub = "blame", .path = file_abs, .line_start = 1801, .line_end = 1801 });
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    const blame = body.value.object.get("symbol_blame") orelse return error.TestNoSymbolBlame;
    try testing.expect(blame.object.get("mapped").?.bool);
    try testing.expectEqualStrings("tail", blame.object.get("symbols").?.array.items[0].object.get("ref").?.string);
}

test "cross-language symbol_changes populate for python and c#" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("m.py", "def foo():\n    return 1\n");
    try repo.writeFile("P.cs", "class C {\n  int Foo() { return 1; }\n}\n");
    try repo.commitAll("seed py and cs");
    try repo.writeFile("m.py", "def foo():\n    return 2\n");
    try repo.writeFile("P.cs", "class C {\n  int Foo() { return 2; }\n}\n");

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callTool(runtime, repo.root_abs, .{ .sub = "diff", .path = repo.root_abs });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expect(fileHasChangedSymbol(body.value, "m.py"));
    try testing.expect(fileHasChangedSymbol(body.value, "P.cs"));
}

fn fileHasChangedSymbol(body: Value, path_suffix: []const u8) bool {
    const files = body.object.get("symbol_changes") orelse return false;
    for (files.array.items) |file| {
        if (!std.mem.endsWith(u8, file.object.get("path").?.string, path_suffix)) continue;
        const syms = file.object.get("symbols") orelse return false;
        for (syms.array.items) |sym| {
            if (std.mem.eql(u8, sym.object.get("change").?.string, "changed")) return true;
        }
    }
    return false;
}

test "symbol diff tolerates a binary file change without crashing" {
    var repo = try Repo.init();
    defer repo.deinit();
    // A file with NUL bytes is binary to git: its diff is a "Binary files
    // differ" line with no --- / +++ hunks, so neither path is set. This must
    // not crash the symbol mapper; the raw diff stays the answer.
    try repo.writeFile("blob.bin", &[_]u8{ 0, 1, 2, 3, 4 });
    try repo.commitAll("add blob");
    try repo.writeFile("blob.bin", &[_]u8{ 0, 9, 8, 7, 6, 5 });

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callTool(runtime, repo.root_abs, .{ .sub = "diff", .path = repo.root_abs });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    // The binary file is reported benignly: mapped, a note, and no symbols.
    const files = body.value.object.get("symbol_changes").?.array;
    try testing.expect(files.items.len == 1);
    const f = files.items[0];
    try testing.expect(f.object.get("mapped") == null);
    try testing.expect(f.object.get("note") != null);
    try testing.expect(f.object.get("symbols") == null);
}

test "symbol blame requires a file path" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("x.ts", "export function foo(): number {\n  return 1;\n}\n");
    try repo.commitAll("add foo");

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    try expectError(runtime, repo.root_abs, .{ .sub = "blame", .path = repo.root_abs }, "MissingPath");
}
