const std = @import("std");
const ts = @import("../engine/tree_sitter.zig");
const symbol = @import("../engine/symbol.zig");
const checks = @import("../engine/checks.zig");
const Profile = @import("../engine/lang/profile.zig").Profile;
const memory = @import("memory.zig");
const shadow = @import("shadow.zig");

const Allocator = std.mem.Allocator;
const Span = symbol.Span;

pub const Rule = struct {
    id: []const u8,
    check: []const u8,
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
        try list.append(gpa, .{ .id = decision.id, .check = check });
    }
    return .{ .gpa = gpa, .recall = recall, .rules = try list.toOwnedSlice(gpa) };
}

pub fn gate(gpa: Allocator, io: std.Io, root_abs: []const u8, file: []const u8, profile: *const Profile, tree: ts.Tree, span: Span) !?Report {
    const enforced = try load(gpa, io, root_abs);
    defer enforced.deinit();
    return evaluate(gpa, file, profile, tree, span, enforced.rules);
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
