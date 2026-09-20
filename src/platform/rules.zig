const std = @import("std");
const ts = @import("../engine/tree_sitter.zig");
const symbol = @import("../engine/symbol.zig");
const checks = @import("../engine/checks.zig");
const Profile = @import("../engine/lang/profile.zig").Profile;
const memory = @import("memory.zig");
const shadow = @import("shadow.zig");
const sandbox = @import("sandbox.zig");
const where_mod = @import("where.zig");

const Allocator = std.mem.Allocator;
const Span = symbol.Span;

pub const Rule = struct {
    id: []const u8,
    check: []const u8,
    where: ?[]const u8 = null,
};

pub const Enforced = struct {
    gpa: Allocator,
    recall: ?memory.Recall,
    rules: []const Rule,

    pub fn deinit(self: Enforced) void {
        self.gpa.free(self.rules);
        if (self.recall) |r| r.deinit();
    }
};

pub const Violation = struct {
    rule: []u8,
    check: []u8,
    file: []u8,
    line: u32,
    col: u32,
    text: []u8,
};

pub const Report = struct {
    violations: []Violation,

    pub fn deinit(self: Report, gpa: Allocator) void {
        self.deinitItems(gpa);
        gpa.free(self.violations);
    }

    pub fn deinitItems(self: Report, gpa: Allocator) void {
        for (self.violations) |v| freeViolation(gpa, v);
    }
};

pub fn load(gpa: Allocator, io: std.Io, root_abs: []const u8) !Enforced {
    return enforcedFrom(gpa, try memory.recall(gpa, io, root_abs));
}

pub fn peek(gpa: Allocator, io: std.Io, root_abs: []const u8) !Enforced {
    return enforcedFrom(gpa, try memory.peek(gpa, io, root_abs));
}

fn enforcedFrom(gpa: Allocator, recall: memory.Recall) !Enforced {
    errdefer recall.deinit();
    var list: std.ArrayList(Rule) = .empty;
    errdefer list.deinit(gpa);
    for (recall.decisions) |decision| {
        if (decision.status != .active or !decision.enforce) continue;
        const check = decision.check orelse continue;
        try list.append(gpa, .{ .id = decision.id, .check = check, .where = decision.where });
    }
    return .{ .gpa = gpa, .recall = recall, .rules = try list.toOwnedSlice(gpa) };
}

pub fn gate(gpa: Allocator, io: std.Io, root_abs: []const u8, file: []const u8, ref: symbol.Ref, profile: *const Profile, tree: ts.Tree, span: Span) !?Report {
    const enforced = try load(gpa, io, root_abs);
    defer enforced.deinit();
    const applicable = try applicableTo(gpa, enforced.rules, file, ref);
    defer gpa.free(applicable);
    return evaluate(gpa, file, profile, tree, span, applicable);
}

pub fn isCommand(rule: Rule) bool {
    return checks.commandOf(rule.check) != null;
}

pub fn covers(rule: Rule, file: []const u8, ref: symbol.Ref) !bool {
    const text = rule.where orelse return true;
    const scope = try where_mod.parse(text);
    return scope.coversSymbol(file, ref);
}

pub fn applicableTo(gpa: Allocator, all: []const Rule, file: []const u8, ref: symbol.Ref) ![]Rule {
    var list: std.ArrayList(Rule) = .empty;
    errdefer list.deinit(gpa);
    for (all) |rule| {
        if (isCommand(rule)) continue;
        if (try covers(rule, file, ref)) try list.append(gpa, rule);
    }
    return list.toOwnedSlice(gpa);
}

pub fn evaluate(gpa: Allocator, file: []const u8, profile: *const Profile, tree: ts.Tree, span: Span, rules: []const Rule) checks.Error!?Report {
    var list: std.ArrayList(Violation) = .empty;
    defer list.deinit(gpa);
    errdefer for (list.items) |v| freeViolation(gpa, v);

    for (rules) |rule| {
        const found = try checks.run(gpa, profile, tree, span, &.{rule.check});
        defer gpa.free(found);
        for (found) |hit| {
            const at = position(tree.source, hit.span.start);
            const owned = try ownViolation(gpa, rule, file, at, tree.source[hit.span.start..hit.span.end]);
            list.append(gpa, owned) catch |err| {
                freeViolation(gpa, owned);
                return err;
            };
        }
    }

    if (list.items.len == 0) return null;
    return .{ .violations = try list.toOwnedSlice(gpa) };
}

const Position = struct { line: u32, col: u32 };

fn position(source: []const u8, offset: u32) Position {
    var line: u32 = 1;
    var line_start: usize = 0;
    for (source[0..offset], 0..) |byte, i| {
        if (byte == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ .line = line, .col = @intCast(offset - line_start + 1) };
}

fn ownViolation(gpa: Allocator, rule: Rule, file: []const u8, at: Position, text: []const u8) Allocator.Error!Violation {
    const rule_id = try gpa.dupe(u8, rule.id);
    errdefer gpa.free(rule_id);
    const check = try gpa.dupe(u8, rule.check);
    errdefer gpa.free(check);
    const file_owned = try gpa.dupe(u8, file);
    errdefer gpa.free(file_owned);
    const text_owned = try gpa.dupe(u8, text);
    return .{ .rule = rule_id, .check = check, .file = file_owned, .line = at.line, .col = at.col, .text = text_owned };
}

fn freeViolation(gpa: Allocator, v: Violation) void {
    gpa.free(v.rule);
    gpa.free(v.check);
    gpa.free(v.file);
    gpa.free(v.text);
}

pub const Verdict = enum { passed, violated, crashed };

pub const Failure = struct {
    rule: []u8,
    check: []u8,
    file: []u8,
    detail: []const u8,
    text: []u8,

    pub fn deinit(self: Failure, gpa: Allocator) void {
        gpa.free(self.rule);
        gpa.free(self.check);
        gpa.free(self.file);
        gpa.free(self.text);
    }
};

pub const CommandGate = union(enum) {
    ok,
    violated: Report,
    failed: Failure,

    pub fn deinit(self: CommandGate, gpa: Allocator) void {
        switch (self) {
            .ok => {},
            .violated => |report| report.deinit(gpa),
            .failed => |failure| failure.deinit(gpa),
        }
    }
};

pub const Target = struct {
    file: []const u8,
    ref: symbol.Ref,
};

pub const CommandOptions = struct {
    shadow_abs: []const u8,
    limits: sandbox.Limits = .{},
};

pub fn verdictOf(report: sandbox.Report) Verdict {
    if (report.killed_leftovers) return .crashed;
    return switch (report.outcome) {
        .exited => |code| if (code == 0) .passed else .violated,
        .crashed, .timed_out, .output_limit => .crashed,
    };
}

pub fn failureDetail(report: sandbox.Report) []const u8 {
    if (report.killed_leftovers) return "leftover_processes";
    return switch (report.outcome) {
        .exited => "exited",
        .crashed => "crashed",
        .timed_out => "timed_out",
        .output_limit => "output_limit",
    };
}

const cmd_builtins = [_][]const u8{
    "assoc", "break",  "call",     "cd",    "chdir",    "cls",    "color", "copy",
    "date",  "del",    "dir",      "echo",  "endlocal", "erase",  "exit",  "for",
    "ftype", "goto",   "if",       "md",    "mkdir",    "mklink", "move",  "path",
    "pause", "popd",   "prompt",   "pushd", "rd",       "rem",    "ren",   "rename",
    "rmdir", "set",    "setlocal", "shift", "start",    "time",   "title", "type",
    "ver",   "verify", "vol",
};

const default_pathext = ".COM;.EXE;.BAT;.CMD";
const head_terminators = " \t&|<>";

pub fn commandHead(command: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, command, " \t");
    if (trimmed.len != 0 and trimmed[0] == '"') {
        const end = std.mem.indexOfScalarPos(u8, trimmed, 1, '"') orelse return trimmed[1..];
        return trimmed[1..end];
    }
    const end = std.mem.indexOfAny(u8, trimmed, head_terminators) orelse trimmed.len;
    return trimmed[0..end];
}

fn isBuiltin(head: []const u8) bool {
    for (cmd_builtins) |name| {
        if (std.ascii.eqlIgnoreCase(name, head)) return true;
    }
    return false;
}

fn hasSeparator(head: []const u8) bool {
    return std.mem.indexOfAny(u8, head, "\\/:") != null;
}

fn baseHasExtension(head: []const u8) bool {
    const base = std.fs.path.basename(head);
    return std.mem.lastIndexOfScalar(u8, base, '.') != null;
}

fn existsIn(io: std.Io, dir: []const u8, name: []const u8, exts: []const u8) !bool {
    if (baseHasExtension(name) and try pathExists(io, dir, name, "")) return true;
    var it = std.mem.tokenizeScalar(u8, exts, ';');
    while (it.next()) |ext| {
        if (try pathExists(io, dir, name, ext)) return true;
    }
    return false;
}

fn pathExists(io: std.Io, dir: []const u8, name: []const u8, ext: []const u8) !bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const joined = if (std.fs.path.isAbsolute(name))
        std.fmt.bufPrint(&buf, "{s}{s}", .{ name, ext }) catch return false
    else
        std.fmt.bufPrint(&buf, "{s}\\{s}{s}", .{ dir, name, ext }) catch return false;
    std.Io.Dir.cwd().access(io, joined, .{}) catch return false;
    return true;
}

pub fn resolvable(gpa: Allocator, io: std.Io, cwd: []const u8, head: []const u8) !bool {
    if (head.len == 0) return false;
    if (isBuiltin(head)) return true;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const exts = (try sandbox.environmentValue(arena, std.unicode.utf8ToUtf16LeStringLiteral("PATHEXT"))) orelse default_pathext;
    if (try existsIn(io, cwd, head, exts)) return true;
    if (hasSeparator(head)) return false;

    const path = (try sandbox.environmentValue(arena, std.unicode.utf8ToUtf16LeStringLiteral("PATH"))) orelse return false;
    var it = std.mem.tokenizeScalar(u8, path, ';');
    while (it.next()) |raw| {
        const dir = std.mem.trimEnd(u8, std.mem.trim(u8, raw, " \""), "\\/");
        if (dir.len == 0 or !std.fs.path.isAbsolute(dir)) continue;
        if (try existsIn(io, dir, head, exts)) return true;
    }
    return false;
}

pub fn commandGate(gpa: Allocator, io: std.Io, root_abs: []const u8, targets: []const Target, options: CommandOptions) !CommandGate {
    const enforced = try load(gpa, io, root_abs);
    defer enforced.deinit();
    for (enforced.rules) |rule| {
        if (!isCommand(rule)) continue;
        const scoped = try firstCovered(rule, targets) orelse continue;
        const gated = try runCommandRule(gpa, io, rule, scoped, options);
        if (gated != .ok) return gated;
    }
    return .ok;
}

fn firstCovered(rule: Rule, targets: []const Target) !?[]const u8 {
    for (targets) |target| {
        if (try covers(rule, target.file, target.ref)) return target.file;
    }
    return null;
}

fn runCommandRule(gpa: Allocator, io: std.Io, rule: Rule, file: []const u8, options: CommandOptions) !CommandGate {
    const command = checks.commandOf(rule.check).?;
    checks.validateCommand(command) catch return failedGate(gpa, rule, file, "malformed", "");

    const head = commandHead(command);
    if (!try resolvable(gpa, io, options.shadow_abs, head)) return failedGate(gpa, rule, file, "command_not_found", head);

    const argv = [_][]const u8{ "cmd.exe", "/d", "/c", command };
    const report = sandbox.run(gpa, io, .{
        .argv = &argv,
        .cwd = options.shadow_abs,
        .limits = options.limits,
    }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failedGate(gpa, rule, file, "sandbox_unavailable", @errorName(err));
    };
    defer report.deinit(gpa);

    switch (verdictOf(report)) {
        .passed => return .ok,
        .crashed => {
            const said = try saidBy(gpa, report);
            defer gpa.free(said);
            return failedGate(gpa, rule, file, failureDetail(report), said);
        },
        .violated => {
            const said = try saidBy(gpa, report);
            defer gpa.free(said);
            return violatedGate(gpa, rule, file, said);
        },
    }
}

fn saidBy(gpa: Allocator, report: sandbox.Report) ![]u8 {
    const out = std.mem.trimEnd(u8, report.stdout, "\r\n");
    const err = std.mem.trimEnd(u8, report.stderr, "\r\n");
    if (out.len == 0) return gpa.dupe(u8, err);
    if (err.len == 0) return gpa.dupe(u8, out);
    return std.fmt.allocPrint(gpa, "{s}\n{s}", .{ out, err });
}

fn failedGate(gpa: Allocator, rule: Rule, file: []const u8, detail: []const u8, text: []const u8) !CommandGate {
    const rule_id = try gpa.dupe(u8, rule.id);
    errdefer gpa.free(rule_id);
    const check = try gpa.dupe(u8, rule.check);
    errdefer gpa.free(check);
    const file_owned = try gpa.dupe(u8, file);
    errdefer gpa.free(file_owned);
    return .{ .failed = .{
        .rule = rule_id,
        .check = check,
        .file = file_owned,
        .detail = detail,
        .text = try gpa.dupe(u8, text),
    } };
}

fn violatedGate(gpa: Allocator, rule: Rule, file: []const u8, text: []const u8) !CommandGate {
    const owned = try ownViolation(gpa, rule, file, .{ .line = 0, .col = 0 }, text);
    errdefer freeViolation(gpa, owned);
    const list = try gpa.alloc(Violation, 1);
    list[0] = owned;
    return .{ .violated = .{ .violations = list } };
}

const builtin = @import("builtin");
const testing = std.testing;
const alloc_bridge = @import("../engine/alloc_bridge.zig");
const test_util = @import("../engine/test_util.zig");

fn evaluateSource(source: []const u8, span: Span, rules: []const Rule) !?Report {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const t = try test_util.TestTree.init(source);
    defer t.deinit();
    return evaluate(testing.allocator, "src/a.ts", test_util.language, t.tree, span, rules);
}

test "every violation names its rule, check, file, line, column and offending text" {
    const source = "function f() {\n  // one\n  return 1; /* two */\n}\n";
    const report = (try evaluateSource(source, .{ .start = 13, .end = @intCast(source.len - 1) }, &.{.{ .id = "r7", .check = "no_comment" }})).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), report.violations.len);
    const first = report.violations[0];
    try testing.expectEqualStrings("r7", first.rule);
    try testing.expectEqualStrings("no_comment", first.check);
    try testing.expectEqualStrings("src/a.ts", first.file);
    try testing.expectEqualStrings("// one", first.text);
    try testing.expectEqual(@as(u32, 2), first.line);
    try testing.expectEqual(@as(u32, 3), first.col);
    try testing.expectEqualStrings("/* two */", report.violations[1].text);
    try testing.expectEqual(@as(u32, 3), report.violations[1].line);
    try testing.expectEqual(@as(u32, 13), report.violations[1].col);
}

test "a clean span and an empty rule list both report nothing" {
    const source = "function f() {\n  return 1;\n}\n";
    const span: Span = .{ .start = 13, .end = @intCast(source.len - 1) };
    try testing.expect((try evaluateSource(source, span, &.{.{ .id = "r1", .check = "no_comment" }})) == null);
    try testing.expect((try evaluateSource("function f() { /* c */ }\n", .{ .start = 0, .end = 24 }, &.{})) == null);
}

test "an unknown check in any rule fails closed even when an earlier rule would pass" {
    const source = "function f() { return 1; }\n";
    try testing.expectError(error.UnknownCheck, evaluateSource(source, .{ .start = 0, .end = 26 }, &.{
        .{ .id = "r1", .check = "no_comment" },
        .{ .id = "r2", .check = "no_such_check" },
    }));
}

test "each rule tags its own violations when two rules share a check" {
    const source = "function f() { /* c */ }\n";
    const report = (try evaluateSource(source, .{ .start = 0, .end = 24 }, &.{
        .{ .id = "first", .check = "no_comment" },
        .{ .id = "second", .check = "no_comment" },
    })).?;
    defer report.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), report.violations.len);
    try testing.expectEqualStrings("first", report.violations[0].rule);
    try testing.expectEqualStrings("second", report.violations[1].rule);
}

fn reportWith(outcome: sandbox.Outcome, killed_leftovers: bool) sandbox.Report {
    return .{
        .outcome = outcome,
        .duration_ns = 0,
        .stdout = &.{},
        .stderr = &.{},
        .truncated = false,
        .killed_leftovers = killed_leftovers,
    };
}

test "a command verdict has three outcomes: pass, violation, and no verdict at all" {
    try testing.expectEqual(Verdict.passed, verdictOf(reportWith(.{ .exited = 0 }, false)));
    try testing.expectEqual(Verdict.violated, verdictOf(reportWith(.{ .exited = 1 }, false)));
    try testing.expectEqual(Verdict.violated, verdictOf(reportWith(.{ .exited = 3 }, false)));
    try testing.expectEqual(Verdict.violated, verdictOf(reportWith(.{ .exited = 0xBFFFFFFF }, false)));
    try testing.expectEqual(Verdict.crashed, verdictOf(reportWith(.{ .crashed = 0xC0000005 }, false)));
    try testing.expectEqual(Verdict.crashed, verdictOf(reportWith(.timed_out, false)));
    try testing.expectEqual(Verdict.crashed, verdictOf(reportWith(.output_limit, false)));
    try testing.expectEqual(Verdict.crashed, verdictOf(reportWith(.{ .exited = 0 }, true)));
    try testing.expectEqual(Verdict.crashed, verdictOf(reportWith(.{ .exited = 1 }, true)));

    try testing.expectEqualStrings("exited", failureDetail(reportWith(.{ .exited = 1 }, false)));
    try testing.expectEqualStrings("crashed", failureDetail(reportWith(.{ .crashed = 0xC0000142 }, false)));
    try testing.expectEqualStrings("timed_out", failureDetail(reportWith(.timed_out, false)));
    try testing.expectEqualStrings("output_limit", failureDetail(reportWith(.output_limit, false)));
    try testing.expectEqualStrings("leftover_processes", failureDetail(reportWith(.{ .exited = 0 }, true)));
}

test "the head of a command is the program, quoted or not, and stops at the first operator" {
    try testing.expectEqualStrings("npx", commandHead("npx eslint --rule no-console"));
    try testing.expectEqualStrings("npx", commandHead("   npx eslint"));
    try testing.expectEqualStrings("./scripts/no-raw-sql.sh", commandHead("./scripts/no-raw-sql.sh"));
    try testing.expectEqualStrings("C:\\Program Files\\t\\t.exe", commandHead("\"C:\\Program Files\\t\\t.exe\" --flag"));
    try testing.expectEqualStrings("echo", commandHead("echo x& exit 1"));
    try testing.expectEqualStrings("a", commandHead("a|b"));
    try testing.expectEqualStrings("a", commandHead("a>out.txt"));
    try testing.expectEqualStrings("", commandHead(""));
    try testing.expectEqualStrings("", commandHead("   "));
}

test "a program is resolvable through builtins, the working directory and PATH, and otherwise is not" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(cwd);

    try testing.expect(try resolvable(testing.allocator, testing.io, cwd, "echo"));
    try testing.expect(try resolvable(testing.allocator, testing.io, cwd, "EXIT"));
    try testing.expect(try resolvable(testing.allocator, testing.io, cwd, "cmd"));
    try testing.expect(try resolvable(testing.allocator, testing.io, cwd, "ping"));

    try testing.expect(!try resolvable(testing.allocator, testing.io, cwd, ""));
    try testing.expect(!try resolvable(testing.allocator, testing.io, cwd, "emetgate-no-such-binary-xyz"));
    try testing.expect(!try resolvable(testing.allocator, testing.io, cwd, ".\\scripts\\missing.cmd"));

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "check.cmd", .data = "@exit 0\r\n" });
    try testing.expect(try resolvable(testing.allocator, testing.io, cwd, "check"));
    try testing.expect(try resolvable(testing.allocator, testing.io, cwd, "check.cmd"));
    try testing.expect(try resolvable(testing.allocator, testing.io, cwd, ".\\check.cmd"));
}

test "a command rule is kept out of the ast gate, which would otherwise fail closed on it" {
    const all = [_]Rule{
        .{ .id = "static", .check = "no_comment" },
        .{ .id = "command", .check = "cmd:exit 0" },
    };
    try testing.expect(isCommand(all[1]));
    try testing.expect(!isCommand(all[0]));

    const ref = try symbol.Ref.parse(testing.allocator, "add");
    defer ref.deinit(testing.allocator);
    const applicable = try applicableTo(testing.allocator, &all, "src/a.ts", ref);
    defer testing.allocator.free(applicable);
    try testing.expectEqual(@as(usize, 1), applicable.len);
    try testing.expectEqualStrings("static", applicable[0].id);

    const scoped = [_]Rule{.{ .id = "command", .check = "cmd:exit 0", .where = "src/other.ts" }};
    try testing.expect(!try covers(scoped[0], "src/a.ts", ref));
    try testing.expect(try covers(.{ .id = "command", .check = "cmd:exit 0" }, "src/a.ts", ref));
}
