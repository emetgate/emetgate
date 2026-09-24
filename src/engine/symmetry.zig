const std = @import("std");
const ts = @import("tree_sitter.zig");
const symbol = @import("symbol.zig");
const Snapshot = @import("loader.zig").Snapshot;
const Profile = @import("lang/profile.zig").Profile;
const test_util = @import("test_util.zig");

const Span = symbol.Span;

pub const Evidence = struct {
    parses: bool,
    unreferenced: bool,
    no_top_level_effect: bool,
    module_unobserved: bool,

    pub fn symmetric(self: Evidence) bool {
        return self.parses and self.unreferenced and self.no_top_level_effect and self.module_unobserved;
    }
};

pub const Local = struct {
    parses: bool,
    no_top_level_effect: bool,
    exported: bool,
};

const effect_kinds = [_][]const u8{
    "new_expression",
    "await_expression",
    "assignment_expression",
    "augmented_assignment_expression",
    "update_expression",
    "yield_expression",
};

pub fn inspect(snapshot: *const Snapshot, slot: Span) Local {
    const root = snapshot.tree.root();
    const statement = statementAt(snapshot.profile, root, slot) orelse return .{ .parses = !root.hasError(), .no_top_level_effect = false, .exported = false };
    return .{
        .parses = !root.hasError(),
        .no_top_level_effect = !std.mem.eql(u8, statement.kind(), snapshot.profile.expression_statement) and !hasEffect(snapshot.profile, statement),
        .exported = isExportWrapper(snapshot.profile, statement.kind()),
    };
}

fn statementAt(profile: *const Profile, root: ts.Node, slot: Span) ?ts.Node {
    var i: u32 = 0;
    while (root.child(i)) |node| : (i += 1) {
        if (node.startByte() < slot.start or !node.isNamed() or profile.isComment(node.kind())) continue;
        return node;
    }
    return null;
}

fn isExportWrapper(profile: *const Profile, kind: []const u8) bool {
    for (profile.export_wrappers) |wrapper| {
        if (std.mem.eql(u8, wrapper, kind)) return true;
    }
    return false;
}

fn isEffect(profile: *const Profile, kind: []const u8) bool {
    if (std.mem.eql(u8, kind, profile.call.node) or std.mem.eql(u8, kind, profile.decorator)) return true;
    for (profile.dynamic_constructors) |constructor| {
        if (std.mem.eql(u8, kind, constructor.node)) return true;
    }
    for (effect_kinds) |effect| {
        if (std.mem.eql(u8, kind, effect)) return true;
    }
    return false;
}

fn deferred(profile: *const Profile, kind: []const u8) bool {
    const function = profile.functionKind(kind) orelse return false;
    return function != .static_block;
}

fn hasEffect(profile: *const Profile, node: ts.Node) bool {
    if (isEffect(profile, node.kind())) return true;
    var i: u32 = 0;
    while (node.child(i)) |child| : (i += 1) {
        if (deferred(profile, child.kind())) continue;
        if (hasEffect(profile, child)) return true;
    }
    return false;
}

pub fn mentions(source: []const u8, word: []const u8, skip: ?Span) bool {
    if (word.len == 0) return false;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, source, from, word)) |at| : (from = at + 1) {
        const end = at + word.len;
        if (skip) |s| if (at >= s.start and end <= s.end) continue;
        if (at > 0 and isWordByte(source[at - 1])) continue;
        if (end < source.len and isWordByte(source[end])) continue;
        return true;
    }
    return false;
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c >= 0x80;
}

const testing = std.testing;

fn inspectSource(source: []const u8, slot_start: u32) !Local {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const snapshot = try test_util.snapshotOf(runtime, source);
    defer snapshot.destroy();
    return inspect(snapshot, .{ .start = slot_start, .end = @intCast(source.len) });
}

test "symmetry: a plain function declaration has no top-level effect" {
    const local = try inspectSource("export function helper(a: number): number { return g(a); }\n", 0);
    try testing.expect(local.parses);
    try testing.expect(local.no_top_level_effect);
    try testing.expect(local.exported);
}

test "symmetry: a call, a new or an assignment in a top-level initializer is an effect" {
    try testing.expect(!(try inspectSource("const x = start();\n", 0)).no_top_level_effect);
    try testing.expect(!(try inspectSource("const x = new Map();\n", 0)).no_top_level_effect);
    try testing.expect(!(try inspectSource("let y = 0;\nconst x = (y = 3);\n", 11)).no_top_level_effect);
    try testing.expect((try inspectSource("const x = () => start();\n", 0)).no_top_level_effect);
}

test "symmetry: a static initializer that calls is an effect, a method that calls is not" {
    try testing.expect(!(try inspectSource("class C { static x = start(); }\n", 0)).no_top_level_effect);
    try testing.expect((try inspectSource("class C { m() { return start(); } }\n", 0)).no_top_level_effect);
}

test "symmetry: mentions matches whole words only and honours the skipped span" {
    try testing.expect(mentions("call(helper);", "helper", null));
    try testing.expect(!mentions("call(helpers); my_helper;", "helper", null));
    try testing.expect(!mentions("function helper() {}", "helper", .{ .start = 0, .end = 20 }));
    try testing.expect(mentions("helper(); function helper() {}", "helper", .{ .start = 10, .end = 30 }));
}
