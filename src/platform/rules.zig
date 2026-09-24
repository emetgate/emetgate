const std = @import("std");
const ts = @import("../engine/tree_sitter.zig");
const symbol = @import("../engine/symbol.zig");
const checks = @import("../engine/checks.zig");
const Profile = @import("../engine/lang/profile.zig").Profile;
const memory = @import("memory.zig");
const shadow = @import("shadow.zig");
const sandbox = @import("sandbox.zig");
const where_mod = @import("where.zig");
const repo = @import("repo.zig");

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
    end_line: u32,
    end_col: u32,
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

pub fn gate(gpa: Allocator, io: std.Io, root_abs: []const u8, file: []const u8, ref: symbol.Ref, profile: *const Profile, tree: ts.Tree, span: Span, allow_repo_memory: bool) !Gate {
    const enforced = try load(gpa, io, root_abs);
    defer enforced.deinit();
    const applicable = try applicableTo(gpa, enforced.rules, file, ref);
    defer gpa.free(applicable);
    if (!allow_repo_memory and anyQuery(applicable)) {
        if (try ledgerTracked(gpa, io, root_abs)) return error.UntrustedRepoMemory;
    }
    return evaluate(gpa, file, profile, tree, span, applicable);
}

pub fn isCommand(rule: Rule) bool {
    return checks.commandOf(rule.check) != null;
}

pub fn isQuery(rule: Rule) bool {
    return std.mem.eql(u8, checks.parse(rule.check).name, checks.query_name);
}

fn anyQuery(list: []const Rule) bool {
    for (list) |rule| {
        if (isQuery(rule)) return true;
    }
    return false;
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

pub fn evaluate(gpa: Allocator, file: []const u8, profile: *const Profile, tree: ts.Tree, span: Span, rules: []const Rule) checks.Error!Gate {
    var list: std.ArrayList(Violation) = .empty;
    defer list.deinit(gpa);
    defer for (list.items) |v| freeViolation(gpa, v);
    var lines: ?Lines = null;
    defer if (lines) |l| l.deinit(gpa);

    for (rules) |rule| {
        const found = checks.run(gpa, profile, tree, span, &.{rule.check}) catch |err| switch (err) {
            error.QueryMalformed, error.QueryNotForLanguage, error.QueryBudgetExceeded, error.QueryMatchLimitExceeded => |e| return failedGate(gpa, rule, file, unrunnableDetail(e), profile.name),
            else => |e| return e,
        };
        defer gpa.free(found);
        if (found.len > 0 and lines == null) lines = try Lines.init(gpa, tree.source);
        for (found) |hit| {
            const start = lines.?.position(hit.span.start);
            const end = lines.?.position(hit.span.end);
            const owned = try ownViolation(gpa, rule, file, start, end, shown(tree.source[hit.span.start..hit.span.end]));
            list.append(gpa, owned) catch |err| {
                freeViolation(gpa, owned);
                return err;
            };
        }
    }

    if (list.items.len == 0) return .ok;
    const owned = try list.toOwnedSlice(gpa);
    return .{ .violated = .{ .violations = owned } };
}

pub fn unrunnableDetail(err: checks.Unrunnable) []const u8 {
    return switch (err) {
        error.QueryMalformed => "query_malformed",
        error.QueryNotForLanguage => "query_not_for_language",
        error.QueryBudgetExceeded => "query_budget_exceeded",
        error.QueryMatchLimitExceeded => "query_match_limit_exceeded",
    };
}

pub const max_violation_text = 256;

fn shown(text: []const u8) []const u8 {
    if (text.len <= max_violation_text) return text;
    var len: usize = max_violation_text;
    while (len > 0 and text[len] & 0xC0 == 0x80) len -= 1;
    return text[0..len];
}

const Position = struct { line: u32, col: u32 };

const Lines = struct {
    starts: []u32,

    fn init(gpa: Allocator, source: []const u8) Allocator.Error!Lines {
        var starts: std.ArrayList(u32) = .empty;
        errdefer starts.deinit(gpa);
        try starts.append(gpa, 0);
        for (source, 0..) |byte, i| {
            if (byte == '\n') try starts.append(gpa, @intCast(i + 1));
        }
        return .{ .starts = try starts.toOwnedSlice(gpa) };
    }

    fn deinit(self: Lines, gpa: Allocator) void {
        gpa.free(self.starts);
    }

    fn position(self: Lines, offset: u32) Position {
        var lo: usize = 0;
        var hi: usize = self.starts.len;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (self.starts[mid] <= offset) lo = mid else hi = mid;
        }
        return .{ .line = @intCast(lo + 1), .col = offset - self.starts[lo] + 1 };
    }
};

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

fn ownViolation(gpa: Allocator, rule: Rule, file: []const u8, at: Position, end: Position, text: []const u8) Allocator.Error!Violation {
    const rule_id = try gpa.dupe(u8, rule.id);
    errdefer gpa.free(rule_id);
    const check = try gpa.dupe(u8, rule.check);
    errdefer gpa.free(check);
    const file_owned = try gpa.dupe(u8, file);
    errdefer gpa.free(file_owned);
    const text_owned = try gpa.dupe(u8, text);
    return .{ .rule = rule_id, .check = check, .file = file_owned, .line = at.line, .col = at.col, .end_line = end.line, .end_col = end.col, .text = text_owned };
}

fn freeViolation(gpa: Allocator, v: Violation) void {
    gpa.free(v.rule);
    gpa.free(v.check);
    gpa.free(v.file);
    gpa.free(v.text);
}

pub const Adopted = struct {
    id: []const u8,
    text: []const u8,
    mode: []const u8,
    check: ?[]const u8 = null,
    where: ?[]const u8 = null,
};

pub const AdoptedList = struct {
    gpa: Allocator,
    recall: memory.Recall,
    items: []const Adopted,

    pub fn deinit(self: AdoptedList) void {
        self.gpa.free(self.items);
        self.recall.deinit();
    }
};

pub fn adoptedFor(gpa: Allocator, io: std.Io, root_abs: []const u8, rel: []const u8) !AdoptedList {
    const recall = try memory.peek(gpa, io, root_abs);
    errdefer recall.deinit();
    var list: std.ArrayList(Adopted) = .empty;
    errdefer list.deinit(gpa);
    for (recall.decisions) |decision| {
        if (decision.status != .active) continue;
        if (decision.where) |text| {
            const scope = try where_mod.parse(text);
            if (!scope.coversFile(rel)) continue;
        }
        try list.append(gpa, .{
            .id = decision.id,
            .text = decision.text,
            .mode = if (decision.enforce) "enforce" else "advisory",
            .check = decision.check,
            .where = decision.where,
        });
    }
    return .{ .gpa = gpa, .recall = recall, .items = try list.toOwnedSlice(gpa) };
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

pub const Gate = union(enum) {
    ok,
    violated: Report,
    failed: Failure,

    pub fn deinit(self: Gate, gpa: Allocator) void {
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
    allow_repo_memory: bool = false,
};

pub const ledger_pathspec = ":(icase,literal)" ++ shadow.workspace_dir;
const ledger_rel = shadow.workspace_dir ++ "/" ++ memory.ledger_name;

pub fn listsLedger(listing: []const u8) bool {
    var entries = std.mem.tokenizeScalar(u8, listing, 0);
    while (entries.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry, shadow.workspace_dir) or std.ascii.eqlIgnoreCase(entry, ledger_rel)) return true;
    }
    return false;
}

pub fn ledgerTracked(gpa: Allocator, io: std.Io, root_abs: []const u8) !bool {
    const listing = try repo.trackedListing(gpa, io, root_abs, ledger_pathspec);
    defer gpa.free(listing);
    return listsLedger(listing);
}

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

pub fn commandGate(gpa: Allocator, io: std.Io, root_abs: []const u8, targets: []const Target, options: CommandOptions) !Gate {
    const enforced = try load(gpa, io, root_abs);
    defer enforced.deinit();
    var trusted = options.allow_repo_memory;
    for (enforced.rules) |rule| {
        if (!isCommand(rule)) continue;
        const scoped = try firstCovered(rule, targets) orelse continue;
        if (!trusted) {
            if (try ledgerTracked(gpa, io, root_abs)) return error.UntrustedRepoMemory;
            trusted = true;
        }
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

fn runCommandRule(gpa: Allocator, io: std.Io, rule: Rule, file: []const u8, options: CommandOptions) !Gate {
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

fn failedGate(gpa: Allocator, rule: Rule, file: []const u8, detail: []const u8, text: []const u8) !Gate {
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

fn violatedGate(gpa: Allocator, rule: Rule, file: []const u8, text: []const u8) !Gate {
    const owned = try ownViolation(gpa, rule, file, .{ .line = 0, .col = 0 }, .{ .line = 0, .col = 0 }, text);
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
    return reportOf(try evaluate(testing.allocator, "src/a.ts", test_util.language, t.tree, span, rules));
}

test "a violation's text is cut to 256 bytes on a character boundary, its position still spans the node" {
    const long = "x" ** 255 ++ "ş" ++ "y" ** 100;
    const source = "export function f() {\n  return \"" ++ long ++ "\";\n}\n";
    const start: u32 = @intCast(std.mem.indexOf(u8, source, "{").?);
    const report = (try evaluateSource(source, .{ .start = start, .end = @intCast(source.len) }, &.{.{ .id = "r", .check = "q:(string) @violation" }})) orelse return error.TestExpectedViolation;
    defer report.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), report.violations.len);
    const v = report.violations[0];
    try testing.expectEqualStrings("\"" ++ "x" ** 255, v.text);
    try testing.expectEqual(@as(u32, 2), v.line);
    try testing.expectEqual(@as(u32, 2), v.end_line);
    try testing.expectEqual(@as(u32, 10 + long.len + 2), v.end_col);
    try testing.expectEqualStrings(shown(long), "x" ** 255);
    try testing.expectEqualStrings(shown("short"), "short");
    try testing.expectEqualStrings(shown("a" ** 254 ++ "ş"), "a" ** 254 ++ "ş");
}

const Spot = struct { text: []const u8, line: u32, col: u32, end_line: u32, end_col: u32 };

fn expectSpots(source: []const u8, check: []const u8, expected: []const Spot) !void {
    errdefer std.debug.print("source \"{s}\" check {s}\n", .{ source, check });
    const report = (try evaluateSource(source, .{ .start = 0, .end = @intCast(source.len) }, &.{.{ .id = "r", .check = check }})) orelse return error.TestExpectedViolation;
    defer report.deinit(testing.allocator);
    errdefer for (report.violations) |v| std.debug.print("  {s} {d}:{d}-{d}:{d}\n", .{ v.text, v.line, v.col, v.end_line, v.end_col });
    try testing.expectEqual(expected.len, report.violations.len);
    for (expected, report.violations) |want, got| {
        try testing.expectEqualStrings(want.text, got.text);
        try testing.expectEqual(want.line, got.line);
        try testing.expectEqual(want.col, got.col);
        try testing.expectEqual(want.end_line, got.end_line);
        try testing.expectEqual(want.end_col, got.end_col);
    }
}

test "violation positions hold at the edges: first and last line, empty lines, CRLF, multibyte columns, multiline nodes" {
    try expectSpots("a;\n\nb;", "q:(identifier) @violation", &.{
        .{ .text = "a", .line = 1, .col = 1, .end_line = 1, .end_col = 2 },
        .{ .text = "b", .line = 3, .col = 1, .end_line = 3, .end_col = 2 },
    });
    try expectSpots("a;\n\nb;\n", "q:(identifier) @violation", &.{
        .{ .text = "a", .line = 1, .col = 1, .end_line = 1, .end_col = 2 },
        .{ .text = "b", .line = 3, .col = 1, .end_line = 3, .end_col = 2 },
    });
    try expectSpots("x;\n\n\n  yy;", "q:(identifier) @violation", &.{
        .{ .text = "x", .line = 1, .col = 1, .end_line = 1, .end_col = 2 },
        .{ .text = "yy", .line = 4, .col = 3, .end_line = 4, .end_col = 5 },
    });
    try expectSpots("a;\r\nbb;\r\n", "q:(identifier) @violation", &.{
        .{ .text = "a", .line = 1, .col = 1, .end_line = 1, .end_col = 2 },
        .{ .text = "bb", .line = 2, .col = 1, .end_line = 2, .end_col = 3 },
    });
    try expectSpots("const ş = 1; x;\n", "q:(identifier) @violation", &.{
        .{ .text = "ş", .line = 1, .col = 7, .end_line = 1, .end_col = 9 },
        .{ .text = "x", .line = 1, .col = 15, .end_line = 1, .end_col = 16 },
    });
    try expectSpots("f(\n  a,\n  b);", "q:(arguments) @violation", &.{
        .{ .text = "(\n  a,\n  b)", .line = 1, .col = 2, .end_line = 3, .end_col = 5 },
    });
}

test "the line index gives the same line and column as a scan from the start, at every offset" {
    for ([_][]const u8{ "", "\n", "a", "ab\ncd\n\nef", "x\r\ny\r\n", "şğ\nü\n" }) |source| {
        const lines = try Lines.init(testing.allocator, source);
        defer lines.deinit(testing.allocator);
        var offset: u32 = 0;
        while (offset <= source.len) : (offset += 1) {
            errdefer std.debug.print("source \"{s}\" offset {d}\n", .{ source, offset });
            try testing.expectEqual(position(source, offset), lines.position(offset));
        }
    }
}

pub fn reportOf(gated: Gate) !?Report {
    return switch (gated) {
        .ok => null,
        .violated => |report| report,
        .failed => |failure| {
            std.debug.print("check could not run: {s}\n", .{failure.detail});
            failure.deinit(testing.allocator);
            return error.TestUnexpectedCheckFailure;
        },
    };
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

test "a tracked ledger, under any spelling or as a tracked workspace entry, is recognized; anything else is not" {
    try testing.expect(listsLedger(".emetgate/ledger.ndjson\x00"));
    try testing.expect(listsLedger(".EMETGATE/Ledger.NDJSON\x00"));
    try testing.expect(listsLedger(".emetgate/notes.md\x00.emetgate/ledger.ndjson\x00"));
    try testing.expect(listsLedger(".emetgate\x00"));
    try testing.expect(listsLedger(".Emetgate\x00"));

    try testing.expect(!listsLedger(""));
    try testing.expect(!listsLedger(".emetgate/notes.md\x00"));
    try testing.expect(!listsLedger(".emetgate/ledger.ndjson.emetgate-0123.bak\x00"));
    try testing.expect(!listsLedger("src/.emetgate/ledger.ndjson\x00"));
    try testing.expect(!listsLedger(".emetgate/ledger.ndjson.old\x00"));
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
