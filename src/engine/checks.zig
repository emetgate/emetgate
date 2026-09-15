const std = @import("std");
const ts = @import("tree_sitter.zig");
const traversal = @import("traversal.zig");
const symbol = @import("symbol.zig");
const Profile = @import("lang/profile.zig").Profile;
const isOneOf = @import("functions.zig").isOneOf;

const Allocator = std.mem.Allocator;
const Span = symbol.Span;

pub const Violation = struct {
    check: []const u8,
    span: Span,
};

pub const Collect = *const fn (gpa: Allocator, profile: *const Profile, tree: ts.Tree, span: Span, out: *std.ArrayList(Violation)) Allocator.Error!void;

pub const Check = struct {
    name: []const u8,
    collect: Collect,
};

pub const registry = [_]Check{
    .{ .name = "no_comment", .collect = noComment },
};

pub const Error = error{UnknownCheck} || Allocator.Error;

pub fn find(checks: []const Check, name: []const u8) ?Check {
    for (checks) |check| {
        if (std.mem.eql(u8, check.name, name)) return check;
    }
    return null;
}

pub fn run(gpa: Allocator, profile: *const Profile, tree: ts.Tree, span: Span, names: []const []const u8) Error![]Violation {
    return runWith(gpa, &registry, profile, tree, span, names);
}

pub fn runWith(gpa: Allocator, checks: []const Check, profile: *const Profile, tree: ts.Tree, span: Span, names: []const []const u8) Error![]Violation {
    for (names) |name| {
        if (find(checks, name) == null) return error.UnknownCheck;
    }
    var out: std.ArrayList(Violation) = .empty;
    errdefer out.deinit(gpa);
    for (names) |name| {
        if (find(checks, name)) |check| try check.collect(gpa, profile, tree, span, &out);
    }
    return out.toOwnedSlice(gpa);
}

fn noComment(gpa: Allocator, profile: *const Profile, tree: ts.Tree, span: Span, out: *std.ArrayList(Violation)) Allocator.Error!void {
    var walker = traversal.Walker.init(tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        if (node.endByte() <= span.start or node.startByte() >= span.end) {
            walker.skipChildren();
            continue;
        }
        if (profile.isComment(node.kind()) or isProseStatement(profile, tree, node)) {
            try out.append(gpa, .{ .check = "no_comment", .span = .{ .start = node.startByte(), .end = node.endByte() } });
        }
    }
}

fn isProseStatement(profile: *const Profile, tree: ts.Tree, node: ts.Node) bool {
    if (!isStringStatement(profile, node)) return false;
    return !isDirective(profile, tree, node);
}

fn isStringStatement(profile: *const Profile, node: ts.Node) bool {
    if (!isKind(node, profile.expression_statement) or node.namedChildCount() != 1) return false;
    const expression = node.namedChild(0).?;
    return isOneOf(expression.kind(), profile.prose_strings);
}

fn isDirective(profile: *const Profile, tree: ts.Tree, node: ts.Node) bool {
    const literal = tree.text(node.namedChild(0).?);
    if (!isOneOf(literal, profile.directives)) return false;
    const parent = node.parent() orelse return false;
    if (!isKind(parent, profile.block) and !isKind(parent, profile.root)) return false;
    var previous = node.prevNamedSibling();
    while (previous) |sibling| : (previous = sibling.prevNamedSibling()) {
        if (!isStringStatement(profile, sibling)) return false;
    }
    return true;
}

fn isKind(node: ts.Node, kind: []const u8) bool {
    return std.mem.eql(u8, node.kind(), kind);
}

const testing = std.testing;
const alloc_bridge = @import("alloc_bridge.zig");
const test_util = @import("test_util.zig");

fn wholeSource(source: []const u8) Span {
    return .{ .start = 0, .end = @intCast(source.len) };
}

fn spanOf(source: []const u8, needle: []const u8) !Span {
    const at = std.mem.indexOf(u8, source, needle) orelse return error.TestNeedleMissing;
    return .{ .start = @intCast(at), .end = @intCast(at + needle.len) };
}

fn collectTexts(source: []const u8, span: Span, names: []const []const u8) ![][]const u8 {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const t = try test_util.TestTree.init(source);
    defer t.deinit();
    const violations = try run(testing.allocator, test_util.language, t.tree, span, names);
    defer testing.allocator.free(violations);
    const texts = try testing.allocator.alloc([]const u8, violations.len);
    for (violations, texts) |v, *text| {
        try testing.expectEqualStrings("no_comment", v.check);
        text.* = source[v.span.start..v.span.end];
    }
    return texts;
}

fn expectFlagged(source: []const u8, span: Span, expected: []const []const u8) !void {
    const texts = try collectTexts(source, span, &.{"no_comment"});
    defer testing.allocator.free(texts);
    errdefer for (texts) |text| std.debug.print("flagged: {s}\n", .{text});
    try testing.expectEqual(expected.len, texts.len);
    for (expected, texts) |want, got| try testing.expectEqualStrings(want, got);
}

test "no_comment flags line and block comments inside the span" {
    const source = "function f() {\n  // explain\n  const x = 1; /* why */\n  return x;\n}\n";
    try expectFlagged(source, wholeSource(source), &.{ "// explain", "/* why */" });
}

test "no_comment ignores comments outside the span" {
    const source = "// header\nfunction f() {\n  return 1;\n}\n// footer\n";
    try expectFlagged(source, try spanOf(source, "{\n  return 1;\n}"), &.{});
}

test "no_comment flags a comment inside the span even when others sit outside it" {
    const source = "// header\nfunction f() {\n  // inside\n  return 1;\n}\n";
    try expectFlagged(source, try spanOf(source, "{\n  // inside\n  return 1;\n}"), &.{"// inside"});
}

test "no_comment flags prose smuggled in as a string or template statement" {
    const source = "function f() {\n  \"explain the next line\";\n  `and this`;\n  return 1;\n}\n";
    try expectFlagged(source, wholeSource(source), &.{ "\"explain the next line\";", "`and this`;" });
}

test "no_comment allows a use strict directive only in the directive prologue" {
    const allowed = "function f() {\n  'use strict';\n  \"use strict\";\n  return 1;\n}\n";
    try expectFlagged(allowed, wholeSource(allowed), &.{});

    const late = "function f() {\n  const x = 1;\n  \"use strict\";\n  return x;\n}\n";
    try expectFlagged(late, wholeSource(late), &.{"\"use strict\";"});

    const nested = "function f() {\n  if (x) { \"use strict\"; }\n}\n";
    try expectFlagged(nested, wholeSource(nested), &.{});

    const imitation = "function f() {\n  \"use strict \";\n  return 1;\n}\n";
    try expectFlagged(imitation, wholeSource(imitation), &.{"\"use strict \";"});
}

test "no_comment leaves strings that are real values alone" {
    const source = "function f() {\n  const s = \"text\";\n  log(\"text\");\n  return `t${s}`;\n}\nconst g = () => \"value\";\n";
    try expectFlagged(source, wholeSource(source), &.{});
}

test "no violations for an empty check list, and every registry name is unique and findable" {
    const texts = try collectTexts("function f() { /* c */ }\n", wholeSource("function f() { /* c */ }\n"), &.{});
    defer testing.allocator.free(texts);
    try testing.expectEqual(@as(usize, 0), texts.len);

    for (registry, 0..) |check, i| {
        try testing.expect(find(&registry, check.name) != null);
        for (registry[i + 1 ..]) |other| try testing.expect(!std.mem.eql(u8, check.name, other.name));
    }
}

test "an unknown check name is refused before any check runs" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const t = try test_util.TestTree.init("function f() { /* c */ }\n");
    defer t.deinit();
    const span = wholeSource("function f() { /* c */ }\n");

    try testing.expectError(error.UnknownCheck, run(testing.allocator, test_util.language, t.tree, span, &.{"no_such_check"}));
    try testing.expectError(error.UnknownCheck, run(testing.allocator, test_util.language, t.tree, span, &.{ "no_comment", "no_such_check" }));

    const Probe = struct {
        var ran: usize = 0;
        fn collect(gpa: Allocator, profile: *const Profile, tree: ts.Tree, s: Span, out: *std.ArrayList(Violation)) Allocator.Error!void {
            _ = gpa;
            _ = profile;
            _ = tree;
            _ = s;
            _ = out;
            ran += 1;
        }
    };
    const checks = [_]Check{.{ .name = "probe", .collect = Probe.collect }};
    try testing.expectError(error.UnknownCheck, runWith(testing.allocator, &checks, test_util.language, t.tree, span, &.{ "probe", "missing" }));
    try testing.expectEqual(@as(usize, 0), Probe.ran);
}

test "a new check joins by registration alone and runs in the requested order" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const source = "function f() { eval(\"1\"); /* c */ }\n";
    const t = try test_util.TestTree.init(source);
    defer t.deinit();

    const NoEval = struct {
        fn collect(gpa: Allocator, profile: *const Profile, tree: ts.Tree, span: Span, out: *std.ArrayList(Violation)) Allocator.Error!void {
            var walker = traversal.Walker.init(tree.root());
            defer walker.deinit();
            while (walker.next()) |entry| {
                const node = entry.node;
                if (node.startByte() < span.start or node.endByte() > span.end) continue;
                if (isKind(node, profile.identifier) and std.mem.eql(u8, tree.text(node), "eval")) {
                    try out.append(gpa, .{ .check = "no_eval", .span = .{ .start = node.startByte(), .end = node.endByte() } });
                }
            }
        }
    };
    const checks = registry ++ [_]Check{.{ .name = "no_eval", .collect = NoEval.collect }};
    const violations = try runWith(testing.allocator, &checks, test_util.language, t.tree, wholeSource(source), &.{ "no_eval", "no_comment" });
    defer testing.allocator.free(violations);

    try testing.expectEqual(@as(usize, 2), violations.len);
    try testing.expectEqualStrings("no_eval", violations[0].check);
    try testing.expectEqualStrings("eval", source[violations[0].span.start..violations[0].span.end]);
    try testing.expectEqualStrings("no_comment", violations[1].check);
    try testing.expectEqualStrings("/* c */", source[violations[1].span.start..violations[1].span.end]);
}
