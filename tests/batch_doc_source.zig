const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const telemetry = @import("emetgate").telemetry;
const memory = @import("emetgate").memory;
const symbol = @import("emetgate").symbol;
const batch_plan = @import("emetgate").batch_plan;
const Runtime = @import("emetgate").runtime.Runtime;
const Snapshot = @import("emetgate").loader.Snapshot;

const testing = std.testing;
const gpa = testing.allocator;
const Value = std.json.Value;

const cart_ts = "export class Cart {\n  taxCents(): number {\n    return 1;\n  }\n}\n";
const math_ts = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const notes_md = "# Notes\n\n## Setup\n\nold\n";
const method_line = "  taxCents(): number {\n";
const commented_lines = "  // comment one\n  // comment two\n  taxCents(): number {\n";

const Reply = struct {
    parsed: std.json.Parsed(Value),
    is_error: bool,
    text: []const u8,

    fn deinit(self: *Reply) void {
        self.parsed.deinit();
    }

    fn expectError(self: *Reply, name: []const u8) !void {
        errdefer std.debug.print("reply: {s}\n", .{self.text});
        try testing.expect(self.is_error);
        const end = std.mem.indexOfScalar(u8, self.text, '\n') orelse self.text.len;
        const body = try std.json.parseFromSlice(Value, gpa, self.text[0..end], .{});
        defer body.deinit();
        try testing.expectEqualStrings("error", body.value.object.get("status").?.string);
        try testing.expectEqualStrings(name, body.value.object.get("error").?.string);
    }

    fn expectCommitted(self: *Reply) !void {
        errdefer std.debug.print("reply: {s}\n", .{self.text});
        try testing.expect(!self.is_error);
        try testing.expect(std.mem.indexOf(u8, self.text, "\"status\":\"committed\"") != null);
    }
};

fn git(root_abs: []const u8, args: []const []const u8) !void {
    var argv: [8][]const u8 = undefined;
    argv[0] = "git";
    @memcpy(argv[1..][0..args.len], args);
    const result = try std.process.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root_abs } });
    gpa.free(result.stdout);
    gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitSetupFailed,
        else => return error.GitSetupFailed,
    }
}

const Repo = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,
    workspace_abs: []u8,
    runtime: *Runtime,

    fn init() !Repo {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/cart.ts", .data = cart_ts });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/math.ts", .data = math_ts });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/notes.md", .data = notes_md });
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
        errdefer gpa.free(root_abs);
        try git_fixture.initRepo(root_abs);
        try git(root_abs, &.{ "add", "." });
        try git(root_abs, &.{ "commit", "-q", "-m", "init" });
        const workspace_abs = try std.fmt.allocPrint(gpa, "{s}\\.emetgate", .{root_abs});
        errdefer gpa.free(workspace_abs);
        return .{ .tmp = tmp, .root_abs = root_abs, .workspace_abs = workspace_abs, .runtime = try Runtime.create(gpa) };
    }

    fn deinit(self: *Repo) void {
        self.runtime.destroy() catch @panic("live snapshots");
        gpa.free(self.workspace_abs);
        gpa.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn path(self: *Repo, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}\\{s}", .{ self.root_abs, rel });
    }

    fn rule(self: *Repo, text: []const u8, enforce: bool, check: []const u8) !void {
        const id = try memory.remember(gpa, testing.io, self.root_abs, .global, text, enforce, check, null);
        gpa.free(id);
    }

    fn call(self: *Repo, tool: []const u8, args: anytype) !Reply {
        var line: std.Io.Writer.Allocating = .init(gpa);
        defer line.deinit();
        var js: std.json.Stringify = .{ .writer = &line.writer };
        try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = tool, .arguments = args } });
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var observer: telemetry.Observer = .{ .workspace_abs = self.workspace_abs };
        _ = try server.handleMessageObserved(gpa, testing.io, self.runtime, line.written(), &out.writer, &observer, .{ .root = self.root_abs, .test_command = "cmd /c exit 0" });
        const parsed = try std.json.parseFromSlice(Value, gpa, out.written(), .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        const result = parsed.value.object.get("result") orelse return error.NotAToolResult;
        const content = result.object.get("content").?.array.items[0];
        return .{ .parsed = parsed, .is_error = result.object.get("isError").?.bool, .text = content.object.get("text").?.string };
    }

    fn expectFile(self: *Repo, rel: []const u8, expected: []const u8) !void {
        const sub = try std.fmt.allocPrint(gpa, "repo/{s}", .{rel});
        defer gpa.free(sub);
        const on_disk = try self.tmp.dir.readFileAlloc(testing.io, sub, gpa, .unlimited);
        defer gpa.free(on_disk);
        try testing.expectEqualStrings(expected, on_disk);
    }

    fn expectLastEvent(self: *Repo, tool: []const u8, result: []const u8) !void {
        const events = try self.tmp.dir.readFileAlloc(testing.io, "repo/.emetgate/events.ndjson", gpa, .unlimited);
        defer gpa.free(events);
        errdefer std.debug.print("events: {s}\n", .{events});
        const trimmed = std.mem.trimEnd(u8, events, "\r\n");
        const start = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |at| at + 1 else 0;
        const parsed = try std.json.parseFromSlice(Value, gpa, trimmed[start..], .{});
        defer parsed.deinit();
        try testing.expectEqualStrings(tool, parsed.value.object.get("tool").?.string);
        try testing.expectEqualStrings(result, parsed.value.object.get("result").?.string);
    }

    fn receiptCount(self: *Repo) !usize {
        var dir = self.tmp.dir.openDir(testing.io, "repo/.emetgate/receipts", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => |e| return e,
        };
        defer dir.close(testing.io);
        var count: usize = 0;
        var it = dir.iterate();
        while (try it.next(testing.io)) |entry| {
            if (entry.kind == .file) count += 1;
        }
        return count;
    }

    fn addHash(self: *Repo, file: []const u8) !symbol.Hash {
        const snapshot = try Snapshot.load(self.runtime, testing.io, .cwd(), file);
        defer snapshot.destroy();
        const ref = try symbol.Ref.parse(gpa, "add");
        defer ref.deinit(gpa);
        return (try (try snapshot.symbols()).resolve(ref)).hash;
    }
};

fn refusedSourceDocBatch(check: []const u8, enforce: bool, content: []const u8) !void {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.rule("a rule", enforce, check);
    const cart = try repo.path("src\\cart.ts");
    defer gpa.free(cart);
    const hash = symbol.formatHash(symbol.hashOf(method_line));

    var reply = try repo.call("emetgate_try_batch", .{ .edits = .{
        .{ .kind = "doc", .file = cart, .hash = hash[0..], .line_start = @as(i64, 2), .line_end = @as(i64, 2), .content = content },
    } });
    defer reply.deinit();
    try reply.expectError("UseSymbolToolsForSource");
    try repo.expectFile("src/cart.ts", cart_ts);
    try repo.expectLastEvent("emetgate_try_batch", "UseSymbolToolsForSource");
}

test "batch doc on source: a line range that adds comments under an enforced no_comment rule is refused, nothing is written and the call is logged" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try refusedSourceDocBatch("no_comment", true, commented_lines);
}

test "batch doc on source: the same edit is refused under an enforced forbid rule and under an advisory rule" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try refusedSourceDocBatch("forbid:Math.abs", true, "  taxCents(): number {\n    Math.abs(1);\n");
    try refusedSourceDocBatch("no_comment", false, commented_lines);
}

test "write_doc on source: a line range of a source file is refused like the batch, and nothing is written" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.rule("no comments", true, "no_comment");
    const cart = try repo.path("src\\cart.ts");
    defer gpa.free(cart);
    const hash = symbol.formatHash(symbol.hashOf(method_line));

    var reply = try repo.call("emetgate_write_doc", .{ .file = cart, .hash = hash[0..], .line_start = @as(i64, 2), .line_end = @as(i64, 2), .content = commented_lines });
    defer reply.deinit();
    try reply.expectError("UseSymbolToolsForSource");
    try repo.expectFile("src/cart.ts", cart_ts);
    try repo.expectLastEvent("emetgate_write_doc", "UseSymbolToolsForSource");
}

test "batch doc on a document: a batch of one Markdown edit commits, answers, is logged and leaves no receipt" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.rule("no comments", true, "no_comment");
    const notes = try repo.path("notes.md");
    defer gpa.free(notes);
    const hash = symbol.formatHash(symbol.hashOf("## Setup\n\nold\n"));

    var reply = try repo.call("emetgate_try_batch", .{ .detail = "full", .edits = .{
        .{ .kind = "doc", .file = notes, .hash = hash[0..], .heading = "Setup", .content = "## Setup\n\nnew\n" },
    } });
    defer reply.deinit();
    try reply.expectCommitted();
    try testing.expect(std.mem.indexOf(u8, reply.text, "receipt") == null);
    try repo.expectFile("notes.md", "# Notes\n\n## Setup\n\nnew\n");
    try repo.expectLastEvent("emetgate_try_batch", "committed");
    try testing.expectEqual(@as(usize, 0), try repo.receiptCount());
}

test "mixed batch: a symbol edit of one file and a doc edit of another source file are refused together" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.rule("no comments", true, "no_comment");
    const cart = try repo.path("src\\cart.ts");
    defer gpa.free(cart);
    const math = try repo.path("src\\math.ts");
    defer gpa.free(math);
    const line_hash = symbol.formatHash(symbol.hashOf(method_line));
    const add_hash = symbol.formatHash(try repo.addHash(math));

    var reply = try repo.call("emetgate_try_batch", .{ .edits = .{
        .{ .file = math, .symbol = "add", .hash = add_hash[0..], .body = "{\n  return b + a;\n}" },
        .{ .kind = "doc", .file = cart, .hash = line_hash[0..], .line_start = @as(i64, 2), .line_end = @as(i64, 2), .content = commented_lines },
    } });
    defer reply.deinit();
    try reply.expectError("UseSymbolToolsForSource");
    try repo.expectFile("src/cart.ts", cart_ts);
    try repo.expectFile("src/math.ts", math_ts);
    try repo.expectLastEvent("emetgate_try_batch", "UseSymbolToolsForSource");
}

test "mixed batch: a symbol edit and a doc edit of the same source file are refused as a source doc edit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const math = try repo.path("src\\math.ts");
    defer gpa.free(math);
    const line_hash = symbol.formatHash(symbol.hashOf("  return a + b;\n"));
    const add_hash = symbol.formatHash(try repo.addHash(math));

    var reply = try repo.call("emetgate_try_batch", .{ .edits = .{
        .{ .file = math, .symbol = "add", .hash = add_hash[0..], .body = "{\n  return b + a;\n}" },
        .{ .kind = "doc", .file = math, .hash = line_hash[0..], .line_start = @as(i64, 2), .line_end = @as(i64, 2), .content = "  // note\n  return a + b;\n" },
    } });
    defer reply.deinit();
    try reply.expectError("UseSymbolToolsForSource");
    try repo.expectFile("src/math.ts", math_ts);
}

test "mixed batch: a symbol edit and a Markdown edit commit together, are logged, and the receipt covers the source file" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.rule("no comments", true, "no_comment");
    const notes = try repo.path("notes.md");
    defer gpa.free(notes);
    const math = try repo.path("src\\math.ts");
    defer gpa.free(math);
    const doc_hash = symbol.formatHash(symbol.hashOf("## Setup\n\nold\n"));
    const add_hash = symbol.formatHash(try repo.addHash(math));

    var reply = try repo.call("emetgate_try_batch", .{ .detail = "full", .edits = .{
        .{ .kind = "doc", .file = notes, .hash = doc_hash[0..], .heading = "Setup", .content = "## Setup\n\nnew\n" },
        .{ .file = math, .symbol = "add", .hash = add_hash[0..], .body = "{\n  return b + a;\n}" },
    } });
    defer reply.deinit();
    try reply.expectCommitted();
    try testing.expect(std.mem.indexOf(u8, reply.text, "\"receipt\":\"") != null);
    try repo.expectFile("notes.md", "# Notes\n\n## Setup\n\nnew\n");
    try repo.expectFile("src/math.ts", "export function add(a: number, b: number): number {\n  return b + a;\n}\n");
    try repo.expectLastEvent("emetgate_try_batch", "committed");
    try testing.expectEqual(@as(usize, 1), try repo.receiptCount());
}

test "mixed batch: a symbol edit that breaks an enforced rule next to a Markdown edit is rejected and neither file is written" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.rule("no comments", true, "no_comment");
    const notes = try repo.path("notes.md");
    defer gpa.free(notes);
    const math = try repo.path("src\\math.ts");
    defer gpa.free(math);
    const doc_hash = symbol.formatHash(symbol.hashOf("## Setup\n\nold\n"));
    const add_hash = symbol.formatHash(try repo.addHash(math));

    var reply = try repo.call("emetgate_try_batch", .{ .edits = .{
        .{ .kind = "doc", .file = notes, .hash = doc_hash[0..], .heading = "Setup", .content = "## Setup\n\nnew\n" },
        .{ .file = math, .symbol = "add", .hash = add_hash[0..], .body = "{\n  // why\n  return b + a;\n}" },
    } });
    defer reply.deinit();
    try testing.expect(reply.is_error);
    try testing.expect(std.mem.indexOf(u8, reply.text, "\"reason\":\"rule_violation\"") != null);
    try repo.expectFile("notes.md", notes_md);
    try repo.expectFile("src/math.ts", math_ts);
    try repo.expectLastEvent("emetgate_try_batch", "rejected");
}

test "planDoc refuses a file of a registered language before it reads it" {
    const edit: batch_plan.DocEdit = .{
        .file_abs = "C:\\no-such-directory\\src\\cart.TS",
        .selector = .{ .line_range = .{ .start = 1, .end = 1 } },
        .expected_hash = symbol.hashOf("x\n"),
        .new_text = "y\n",
    };
    const rel = try gpa.dupe(u8, "src/cart.TS");
    defer gpa.free(rel);
    try testing.expectError(error.UseSymbolToolsForSource, batch_plan.planDoc(gpa, testing.io, edit, rel));
}
