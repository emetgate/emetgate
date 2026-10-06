const std = @import("std");
const builtin = @import("builtin");
const symbol = @import("emetgate").symbol;
const handlers = @import("emetgate").handlers;
const telemetry = @import("emetgate").telemetry;
const tsserver = @import("emetgate").tsserver;
const memory = @import("emetgate").memory;
const Policy = @import("emetgate").server.Policy;
const Runtime = @import("emetgate").runtime.Runtime;
const fixture = @import("ts_fixture.zig");
const support = @import("runner_support.zig");
const rename_case = @import("rename_tool.zig");
const move_case = @import("move_tool.zig");
const move_file_case = @import("move_file_tool.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const TsRepo = fixture.TsRepo;

pub const green = "cmd /c exit 0";
pub const red = "cmd /c exit 1";
pub const ignore: fixture.File = .{ .rel = ".gitignore", .text = ".emetgate/\nnode_modules/\n" };
pub const message = "refactor: one change, one commit";

pub fn toValue(arena: Allocator, given: anytype) !Value {
    const T = @TypeOf(given);
    if (T == Value) return given;
    if (T == bool) return .{ .bool = given };
    switch (@typeInfo(T)) {
        .pointer => return .{ .string = given },
        .@"struct" => |info| {
            if (info.is_tuple) {
                var list = std.json.Array.init(arena);
                inline for (given) |item| try list.append(try toValue(arena, item));
                return .{ .array = list };
            }
            var map: std.json.ObjectMap = .empty;
            inline for (info.fields) |field| try map.put(arena, field.name, try toValue(arena, @field(given, field.name)));
            return .{ .object = map };
        },
        else => @compileError("unsupported argument type " ++ @typeName(T)),
    }
}

pub const Reply = struct {
    text: []const u8,
    is_error: bool,

    pub fn field(self: Reply, arena: Allocator, name: []const u8) !?Value {
        const parsed = try std.json.parseFromSliceLeaky(Value, arena, self.text, .{});
        return parsed.object.get(name);
    }
};

pub const Env = struct {
    arena_state: std.heap.ArenaAllocator,
    repo: *TsRepo,
    runtime: *Runtime,
    session: ?*tsserver.Session = null,

    pub fn init(repo: *TsRepo, runtime: *Runtime, session: ?*tsserver.Session) Env {
        return .{ .arena_state = std.heap.ArenaAllocator.init(testing.allocator), .repo = repo, .runtime = runtime, .session = session };
    }

    pub fn deinit(self: *Env) void {
        self.arena_state.deinit();
    }

    pub fn arena(self: *Env) Allocator {
        return self.arena_state.allocator();
    }

    pub fn git(self: *Env, argv: []const []const u8) ![]const u8 {
        var full: std.ArrayList([]const u8) = .empty;
        try full.append(self.arena(), "git");
        try full.appendSlice(self.arena(), argv);
        const result = try std.process.run(self.arena(), testing.io, .{ .argv = full.items, .cwd = .{ .path = self.repo.root_abs } });
        switch (result.term) {
            .exited => |code| if (code != 0) {
                std.debug.print("git {s}: {s}\n", .{ argv[0], result.stderr });
                return error.GitCommandFailed;
            },
            else => return error.GitCommandFailed,
        }
        return std.mem.trim(u8, result.stdout, " \r\n");
    }

    pub fn head(self: *Env) ![]const u8 {
        return self.git(&.{ "rev-parse", "HEAD" });
    }

    pub fn abs(self: *Env, rel: []const u8) ![]const u8 {
        return self.repo.abs(self.arena(), rel);
    }

    pub fn read(self: *Env, rel: []const u8) ![]const u8 {
        const text = try self.repo.read(rel);
        defer testing.allocator.free(text);
        return self.arena().dupe(u8, text);
    }

    pub fn hashOf(self: *Env, rel: []const u8, ref_text: []const u8) ![]const u8 {
        const hash = try support.hashOfRef(testing.allocator, testing.io, self.runtime, try self.abs(rel), ref_text);
        return self.arena().dupe(u8, &symbol.formatHash(hash));
    }

    pub fn fileHash(self: *Env, rel: []const u8) ![]const u8 {
        return self.arena().dupe(u8, &symbol.formatHash(symbol.fileHash(try self.read(rel))));
    }

    pub fn call(self: *Env, tool: []const u8, args: anytype, test_command: []const u8, commit: bool) !Reply {
        var event: telemetry.Event = .{ .tool = tool };
        const policy: Policy = .{ .root = self.repo.root_abs, .test_command = test_command, .commit = commit, .language_service = self.session };
        const result = try handlers.callTool(testing.allocator, testing.io, self.runtime, tool, try toValue(self.arena(), args), &event, policy);
        defer testing.allocator.free(result.text);
        return .{ .text = try self.arena().dupe(u8, result.text), .is_error = result.is_error };
    }

    pub fn expectOneCommit(self: *Env, reply: Reply, before: []const u8, changed: []const u8, receipted: []const []const u8) !void {
        errdefer std.debug.print("{s}\n", .{reply.text});
        try testing.expect(!reply.is_error);
        const commit = (try reply.field(self.arena(), "commit")).?.string;
        try testing.expect((try reply.field(self.arena(), "receipt_attach_error")) == null);
        try testing.expectEqualStrings(commit, try self.head());
        try testing.expectEqualStrings(before, try self.git(&.{ "rev-parse", "HEAD^" }));
        try testing.expectEqualStrings(message, try self.git(&.{ "log", "-1", "--format=%B" }));
        try testing.expectEqualStrings(changed, try self.git(&.{ "diff", "--no-renames", "--name-status", "HEAD^", "HEAD" }));
        try testing.expectEqualStrings("", try self.git(&.{ "status", "--porcelain", "--untracked-files=all" }));
        const note = try self.git(&.{ "notes", "--ref=emetgate", "show", "HEAD" });
        for (receipted) |path| {
            errdefer std.debug.print("{s} is not in the note: {s}\n", .{ path, note });
            try testing.expect(std.mem.indexOf(u8, note, path) != null);
        }
    }

    pub fn expectUntouched(self: *Env, reply: Reply, before: []const u8, reason: []const u8) !void {
        errdefer std.debug.print("{s}\n", .{reply.text});
        try testing.expect(reply.is_error);
        try testing.expect(std.mem.indexOf(u8, reply.text, reason) != null);
        try testing.expectEqualStrings(before, try self.head());
        try testing.expectEqualStrings("", try self.git(&.{ "status", "--porcelain", "--untracked-files=all" }));
    }

    pub fn expectHandEditKept(self: *Env, reply: Reply, before: []const u8, rel: []const u8, edited: []const u8) !void {
        errdefer std.debug.print("{s}\n", .{reply.text});
        try testing.expect(reply.is_error);
        try testing.expect(std.mem.indexOf(u8, reply.text, "TargetHasUncommittedChanges") != null);
        try testing.expectEqualStrings(before, try self.head());
        const status = try std.fmt.allocPrint(self.arena(), "M {s}", .{rel});
        try testing.expectEqualStrings(status, try self.git(&.{ "status", "--porcelain", "--untracked-files=all" }));
        try testing.expectEqualStrings(edited, try self.read(rel));
    }
};

const a_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\nexport function keep(x: number): number {\n  return x;\n}\n";
const old_src = "export const unused = 1;\n";
const notes_src = "# Notes\n\n## Setup\n\nold\n\n## Other\n\nkept\n";
const setup_old = "## Setup\n\nold\n\n";
const setup_new = "## Setup\n\nnew\n\n";
const fresh_body = "export function fresh(): number {\n  return 1;\n}\n";

pub const Plain = struct {
    repo: TsRepo,
    runtime: *Runtime,
    env: Env,

    pub fn init(self: *Plain, files: []const fixture.File) !void {
        self.repo = try TsRepo.init(files);
        errdefer self.repo.deinit();
        self.runtime = try Runtime.create(testing.allocator);
        self.env = Env.init(&self.repo, self.runtime, null);
    }

    pub fn deinit(self: *Plain) void {
        self.env.deinit();
        self.runtime.destroy() catch @panic("live snapshots");
        self.repo.deinit();
    }
};

const batch_files = [_]fixture.File{
    .{ .rel = "src/a.ts", .text = a_src },
    .{ .rel = "src/old.ts", .text = old_src },
    .{ .rel = "notes.md", .text = notes_src },
    ignore,
};

fn batchCall(env: *Env, with_message: bool, test_command: []const u8) !Reply {
    const edits = .{
        .{ .file = try env.abs("src/a.ts"), .symbol = "add", .hash = try env.hashOf("src/a.ts", "add"), .body = "{\n  return b + a;\n}" },
        .{ .file = try env.abs("src/fresh.ts"), .symbol = "fresh", .hash = "absent", .body = fresh_body },
        .{ .file = try env.abs("src/old.ts"), .op = "delete", .hash = try env.fileHash("src/old.ts") },
        .{ .file = try env.abs("notes.md"), .kind = "doc", .heading = "Setup", .hash = try env.arena().dupe(u8, &symbol.formatHash(symbol.hashOf(setup_old))), .content = setup_new },
    };
    if (with_message) return env.call("emetgate_try_batch", .{ .edits = edits, .message = message }, test_command, true);
    return env.call("emetgate_try_batch", .{ .edits = edits }, test_command, true);
}

test "commit batch: try_batch that edits, creates, deletes and rewrites a doc is one commit of exactly those files" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Plain = undefined;
    try case.init(&batch_files);
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    const reply = try batchCall(env, true, green);
    try env.expectOneCommit(reply, before, "M\tnotes.md\nM\tsrc/a.ts\nA\tsrc/fresh.ts\nD\tsrc/old.ts", &.{ "src/a.ts", "src/fresh.ts", "src/old.ts" });
    try testing.expect(!case.repo.exists("src/old.ts"));
    try testing.expectEqualStrings(std.mem.trim(u8, fresh_body, "\n"), try env.git(&.{ "show", "HEAD:src/fresh.ts" }));
    try testing.expect(std.mem.indexOf(u8, try env.git(&.{ "show", "HEAD:notes.md" }), "new") != null);
}

test "commit batch: try_batch that fails its tests or carries no message leaves no file, no commit and no index change" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Plain = undefined;
    try case.init(&batch_files);
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    try env.expectUntouched(try batchCall(env, true, red), before, "rejected");
    try env.expectUntouched(try batchCall(env, false, green), before, "MissingCommitMessage");
    try testing.expect(!case.repo.exists("src/fresh.ts"));
    try testing.expect(case.repo.exists("src/old.ts"));
}

test "commit batch: try_batch with a message that breaks a message rule is refused before anything is written" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Plain = undefined;
    try case.init(&batch_files);
    defer case.deinit();
    const env = &case.env;
    const id = try memory.remember(testing.allocator, testing.io, case.repo.root_abs, .project, "no refactor commits", true, "message:forbid:refactor", null);
    defer testing.allocator.free(id);
    const before = try env.head();
    const reply = try batchCall(env, true, green);
    try env.expectUntouched(reply, before, "rule_violation");
    try testing.expect(std.mem.indexOf(u8, reply.text, id) != null);
    try testing.expect(!case.repo.exists("src/fresh.ts"));
}

test "commit batch: try_batch refuses a code target edited by hand and keeps the hand edit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Plain = undefined;
    try case.init(&batch_files);
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    const edited = try std.mem.replaceOwned(u8, env.arena(), a_src, "return x;", "return x + 0;");
    try case.repo.write("src/a.ts", edited);
    try env.expectHandEditKept(try batchCall(env, true, green), before, "src/a.ts", edited);
    try testing.expect(!case.repo.exists("src/fresh.ts"));
}

test "commit batch: try_batch refuses a doc target edited by hand outside the rewritten section" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Plain = undefined;
    try case.init(&batch_files);
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    const edited = try std.mem.replaceOwned(u8, env.arena(), notes_src, "kept", "kept by hand");
    try case.repo.write("notes.md", edited);
    try env.expectHandEditKept(try batchCall(env, true, green), before, "notes.md", edited);
    try testing.expectEqualStrings(a_src, try env.read("src/a.ts"));
}

test "commit batch: an index another process holds locked refuses the batch, and the lock, the branch and the files stay as they were" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Plain = undefined;
    try case.init(&batch_files);
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    const status_before = try env.git(&.{ "status", "--porcelain", "--untracked-files=all" });
    try case.repo.write(".git/index.lock", "held by someone else");
    const reply = try batchCall(env, true, green);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(std.mem.indexOf(u8, reply.text, "IndexLocked") != null);
    try testing.expectEqualStrings(before, try env.head());
    try testing.expectEqualStrings("held by someone else", try env.read(".git/index.lock"));
    try testing.expect(!case.repo.exists("src/fresh.ts"));
    try testing.expect(case.repo.exists("src/old.ts"));
    try case.repo.tmp.dir.deleteFile(testing.io, "repo/.git/index.lock");
    try testing.expectEqualStrings(status_before, try env.git(&.{ "status", "--porcelain", "--untracked-files=all" }));
}

const math_src =
    \\const limit = 10;
    \\export function clamp(x: number): number {
    \\  if (x > limit) {
    \\    return limit;
    \\  }
    \\  return x;
    \\}
    \\export function twice(x: number): number {
    \\  return x * 2;
    \\}
    \\
;
const node_files = [_]fixture.File{ .{ .rel = "src/math.ts", .text = math_src }, ignore };

fn nodeAddress(env: *Env, symbol_ref: []const u8, line: []const u8) ![]const u8 {
    const reply = try env.call("emetgate_read_symbol", .{ .file = try env.abs("src/math.ts"), .symbol = symbol_ref, .nodes = true }, green, false);
    try testing.expect(!reply.is_error);
    const text = (try reply.field(env.arena(), "nodes")).?.string;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |candidate| {
        const bar = std.mem.indexOfScalar(u8, candidate, '|') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, candidate[bar + 1 ..], " "), line)) return candidate[0..bar];
    }
    return error.NoAddress;
}

fn nodeCall(env: *Env, with_message: bool, test_command: []const u8) !Reply {
    const file = try env.abs("src/math.ts");
    const address = try nodeAddress(env, "clamp", "return x;");
    if (with_message) return env.call("emetgate_try", .{ .file = file, .node = address, .text = "return Math.max(x, 0);", .message = message }, test_command, true);
    return env.call("emetgate_try", .{ .file = file, .node = address, .text = "return Math.max(x, 0);" }, test_command, true);
}

test "commit batch: a node try is one commit of the edited file" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Plain = undefined;
    try case.init(&node_files);
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    try env.expectOneCommit(try nodeCall(env, true, green), before, "M\tsrc/math.ts", &.{"src/math.ts"});
    try testing.expect(std.mem.indexOf(u8, try env.git(&.{ "show", "HEAD:src/math.ts" }), "return Math.max(x, 0);") != null);
}

test "commit batch: a node try that fails its tests or carries no message leaves nothing behind" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Plain = undefined;
    try case.init(&node_files);
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    try env.expectUntouched(try nodeCall(env, true, red), before, "rejected");
    try env.expectUntouched(try nodeCall(env, false, green), before, "MissingCommitMessage");
}

test "commit batch: a node try refuses a file edited by hand and keeps the hand edit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Plain = undefined;
    try case.init(&node_files);
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    const edited = try std.mem.replaceOwned(u8, env.arena(), math_src, "return x * 2;", "return x * 2 + 0;");
    try case.repo.write("src/math.ts", edited);
    try env.expectHandEditKept(try nodeCall(env, true, green), before, "src/math.ts", edited);
}

const Served = struct {
    case: rename_case.Case,
    env: Env,

    fn deinit(self: *Served) void {
        self.env.deinit();
        self.case.deinit();
    }
};

fn renameInit(served: *Served) !void {
    try served.case.init(&.{ .{ .rel = "src/a.ts", .text = rename_case.a_src }, .{ .rel = "src/b.ts", .text = rename_case.b_src }, .{ .rel = "src/c.ts", .text = rename_case.c_src }, ignore }, true);
    served.env = Env.init(&served.case.repo, served.case.runtime, &served.case.session);
}

fn renameCall(served: *Served, with_message: bool, test_command: []const u8) !Reply {
    const env = &served.env;
    try served.case.plan(&rename_case.all_locations);
    const file = try env.abs("src/a.ts");
    const hash = try env.hashOf("src/a.ts", "add");
    if (with_message) return env.call("emetgate_rename", .{ .file = file, .symbol = "add", .hash = hash, .new_name = "sum", .interface_change = true, .message = message }, test_command, true);
    return env.call("emetgate_rename", .{ .file = file, .symbol = "add", .hash = hash, .new_name = "sum", .interface_change = true }, test_command, true);
}

test "commit batch: a rename across three files is one commit of the three files" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var served: Served = undefined;
    try renameInit(&served);
    defer served.deinit();
    const env = &served.env;
    const before = try env.head();
    try env.expectOneCommit(try renameCall(&served, true, green), before, "M\tsrc/a.ts\nM\tsrc/b.ts\nM\tsrc/c.ts", &.{ "src/a.ts", "src/b.ts", "src/c.ts" });
    try testing.expectEqualStrings(std.mem.trim(u8, rename_case.c_new, "\n"), try env.git(&.{ "show", "HEAD:src/c.ts" }));
}

test "commit batch: a rename that fails its tests or carries no message leaves nothing behind" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var served: Served = undefined;
    try renameInit(&served);
    defer served.deinit();
    const env = &served.env;
    const before = try env.head();
    try env.expectUntouched(try renameCall(&served, true, red), before, "rejected");
    try env.expectUntouched(try renameCall(&served, false, green), before, "MissingCommitMessage");
}

test "commit batch: a rename refuses when a file it would rewrite was edited by hand" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var served: Served = undefined;
    try renameInit(&served);
    defer served.deinit();
    const env = &served.env;
    const before = try env.head();
    const edited = rename_case.c_src ++ "export const by_hand = 1;\n";
    try served.case.repo.write("src/c.ts", edited);
    try env.expectHandEditKept(try renameCall(&served, true, green), before, "src/c.ts", edited);
    try testing.expectEqualStrings(rename_case.a_src, try env.read("src/a.ts"));
}

fn moveInit(served: *Served) !void {
    try move_case.initMath(&served.case, move_case.math_src, move_case.app_src, &.{ignore}, true);
    served.env = Env.init(&served.case.repo, served.case.runtime, &served.case.session);
}

fn moveCall(served: *Served, with_message: bool, test_command: []const u8) !Reply {
    const env = &served.env;
    try move_case.plan(&served.case, &move_case.area_refs);
    const file = try env.abs("src/math.ts");
    const target = try env.abs("src/shapes.ts");
    const hash = try env.hashOf("src/math.ts", "area");
    if (with_message) return env.call("emetgate_move", .{ .file = file, .symbol = "area", .hash = hash, .target_file = target, .interface_change = true, .message = message }, test_command, true);
    return env.call("emetgate_move", .{ .file = file, .symbol = "area", .hash = hash, .target_file = target, .interface_change = true }, test_command, true);
}

test "commit batch: a move into a new file is one commit of the source, the new file and the user" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var served: Served = undefined;
    try moveInit(&served);
    defer served.deinit();
    const env = &served.env;
    const before = try env.head();
    try env.expectOneCommit(try moveCall(&served, true, green), before, "M\tsrc/app.ts\nM\tsrc/math.ts\nA\tsrc/shapes.ts", &.{ "src/app.ts", "src/math.ts", "src/shapes.ts" });
    try testing.expectEqualStrings(std.mem.trim(u8, move_case.shapes_new, "\n"), try env.git(&.{ "show", "HEAD:src/shapes.ts" }));
}

test "commit batch: a move that fails its tests or carries no message leaves nothing behind" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var served: Served = undefined;
    try moveInit(&served);
    defer served.deinit();
    const env = &served.env;
    const before = try env.head();
    try env.expectUntouched(try moveCall(&served, true, red), before, "rejected");
    try env.expectUntouched(try moveCall(&served, false, green), before, "MissingCommitMessage");
    try testing.expect(!served.case.repo.exists("src/shapes.ts"));
}

test "commit batch: a move refuses when the user file it would rewrite was edited by hand" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var served: Served = undefined;
    try moveInit(&served);
    defer served.deinit();
    const env = &served.env;
    const before = try env.head();
    const edited = move_case.app_src ++ "export const by_hand = 1;\n";
    try served.case.repo.write("src/app.ts", edited);
    try env.expectHandEditKept(try moveCall(&served, true, green), before, "src/app.ts", edited);
    try testing.expect(!served.case.repo.exists("src/shapes.ts"));
}

fn moveFileInit(served: *Served) !void {
    try move_file_case.initFiles(&served.case, &.{ignore}, true);
    served.env = Env.init(&served.case.repo, served.case.runtime, &served.case.session);
}

fn moveFileCall(served: *Served, with_message: bool, test_command: []const u8) !Reply {
    const env = &served.env;
    try move_file_case.plan(&served.case, &move_file_case.changes);
    const from = try env.abs("src/util.ts");
    const to = try env.abs("src/core/tools/util.ts");
    const hash = try env.fileHash("src/util.ts");
    if (with_message) return env.call("emetgate_move_file", .{ .from = from, .to = to, .from_hash = hash, .message = message }, test_command, true);
    return env.call("emetgate_move_file", .{ .from = from, .to = to, .from_hash = hash }, test_command, true);
}

test "commit batch: a file move is one commit that removes the old path, adds the new one and rewrites the importers" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var served: Served = undefined;
    try moveFileInit(&served);
    defer served.deinit();
    const env = &served.env;
    const before = try env.head();
    try env.expectOneCommit(try moveFileCall(&served, true, green), before, "M\tsrc/app.ts\nA\tsrc/core/tools/util.ts\nM\tsrc/lib/lib.ts\nD\tsrc/util.ts", &.{ "src/app.ts", "src/core/tools/util.ts", "src/lib/lib.ts", "src/util.ts" });
    try testing.expectEqualStrings(std.mem.trim(u8, move_file_case.util_new, "\n"), try env.git(&.{ "show", "HEAD:src/core/tools/util.ts" }));
}

test "commit batch: a file move that fails its tests or carries no message leaves nothing behind" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var served: Served = undefined;
    try moveFileInit(&served);
    defer served.deinit();
    const env = &served.env;
    const before = try env.head();
    try env.expectUntouched(try moveFileCall(&served, true, red), before, "rejected");
    try env.expectUntouched(try moveFileCall(&served, false, green), before, "MissingCommitMessage");
    try testing.expect(!served.case.repo.exists("src/core"));
}

test "commit batch: a file move refuses when the file to move was edited by hand" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var served: Served = undefined;
    try moveFileInit(&served);
    defer served.deinit();
    const env = &served.env;
    const before = try env.head();
    const edited = move_file_case.util_src ++ "export const by_hand = 1;\n";
    try served.case.repo.write("src/util.ts", edited);
    try env.expectHandEditKept(try moveFileCall(&served, true, green), before, "src/util.ts", edited);
    try testing.expect(!served.case.repo.exists("src/core"));
}

const refusing_command = "message:cmd:findstr /b fix: .emetgate\\COMMIT_EDITMSG";
const accepting_command = "message:cmd:findstr /b refactor: .emetgate\\COMMIT_EDITMSG";

fn expectMessageCommandRefuses(env: *Env, reply: Reply, before: []const u8, id: []const u8) !void {
    try env.expectUntouched(reply, before, "rule_violation");
    try testing.expect(std.mem.indexOf(u8, reply.text, id) != null);
}

test "commit batch: a message command judges the message of a try_batch, refuses one and accepts another" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    {
        var case: Plain = undefined;
        try case.init(&batch_files);
        defer case.deinit();
        const env = &case.env;
        const id = try memory.remember(testing.allocator, testing.io, case.repo.root_abs, .project, "starts with fix", true, refusing_command, null);
        defer testing.allocator.free(id);
        const before = try env.head();
        try expectMessageCommandRefuses(env, try batchCall(env, true, green), before, id);
        try testing.expect(!case.repo.exists("src/fresh.ts"));
    }
    {
        var case: Plain = undefined;
        try case.init(&batch_files);
        defer case.deinit();
        const env = &case.env;
        const id = try memory.remember(testing.allocator, testing.io, case.repo.root_abs, .project, "starts with refactor", true, accepting_command, null);
        defer testing.allocator.free(id);
        const before = try env.head();
        try env.expectOneCommit(try batchCall(env, true, green), before, "M\tnotes.md\nM\tsrc/a.ts\nA\tsrc/fresh.ts\nD\tsrc/old.ts", &.{"src/a.ts"});
    }
}

test "commit batch: a message command judges the message of a node try" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Plain = undefined;
    try case.init(&node_files);
    defer case.deinit();
    const env = &case.env;
    const id = try memory.remember(testing.allocator, testing.io, case.repo.root_abs, .project, "starts with fix", true, refusing_command, null);
    defer testing.allocator.free(id);
    const before = try env.head();
    try expectMessageCommandRefuses(env, try nodeCall(env, true, green), before, id);
}

test "commit batch: a message command judges the message of a rename, a move and a file move" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    {
        var served: Served = undefined;
        try renameInit(&served);
        defer served.deinit();
        const id = try memory.remember(testing.allocator, testing.io, served.case.repo.root_abs, .project, "starts with fix", true, refusing_command, null);
        defer testing.allocator.free(id);
        const before = try served.env.head();
        try expectMessageCommandRefuses(&served.env, try renameCall(&served, true, green), before, id);
    }
    {
        var served: Served = undefined;
        try moveInit(&served);
        defer served.deinit();
        const id = try memory.remember(testing.allocator, testing.io, served.case.repo.root_abs, .project, "starts with fix", true, refusing_command, null);
        defer testing.allocator.free(id);
        const before = try served.env.head();
        try expectMessageCommandRefuses(&served.env, try moveCall(&served, true, green), before, id);
    }
    {
        var served: Served = undefined;
        try moveFileInit(&served);
        defer served.deinit();
        const id = try memory.remember(testing.allocator, testing.io, served.case.repo.root_abs, .project, "starts with fix", true, refusing_command, null);
        defer testing.allocator.free(id);
        const before = try served.env.head();
        try expectMessageCommandRefuses(&served.env, try moveFileCall(&served, true, green), before, id);
    }
}

test "commit batch: a moved file keeps its executable bit at the new path" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var served: Served = undefined;
    try moveFileInit(&served);
    defer served.deinit();
    const env = &served.env;
    _ = try env.git(&.{ "update-index", "--chmod=+x", "src/util.ts" });
    _ = try env.git(&.{ "commit", "-q", "-m", "chore: mode" });
    const reply = try moveFileCall(&served, true, green);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expect(std.mem.startsWith(u8, try env.git(&.{ "ls-tree", "HEAD", "src/core/tools/util.ts" }), "100755 "));
    try testing.expectEqualStrings("", try env.git(&.{ "status", "--porcelain", "--untracked-files=all" }));
}

test "commit batch: design limit: a try_batch receipt does not list a rewritten doc, and verify calls that commit unverified" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Plain = undefined;
    try case.init(&batch_files);
    defer case.deinit();
    const env = &case.env;
    const reply = try batchCall(env, true, green);
    try testing.expect(!reply.is_error);
    const result = try @import("emetgate").verify_run.run(testing.allocator, env.arena(), testing.io, case.runtime, case.repo.root_abs, .{ .commit = "HEAD", .test_command = green });
    for (result.report.files) |f| {
        const is_doc = std.mem.eql(u8, f.path, "notes.md");
        try testing.expectEqual(if (is_doc) @import("emetgate").checker.Verdict.unverified else @import("emetgate").checker.Verdict.verified, f.outcome.verdict);
    }
    try testing.expectEqual(@import("emetgate").checker.Verdict.unverified, result.report.verdict);
}
