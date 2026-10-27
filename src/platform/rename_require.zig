const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const rename = @import("../engine/rename.zig");
const ts = @import("../engine/tree_sitter.zig");
const traversal = @import("../engine/traversal.zig");
const tsserver = @import("tsserver.zig");
const Snapshot = @import("../engine/loader.zig").Snapshot;

const Allocator = std.mem.Allocator;
const Span = symbol.Span;

pub const Site = struct { span: Span, keep: rename.Keep };

const extensions = [_][]const u8{ "", ".js", ".cjs", ".mjs", ".ts", ".tsx", ".jsx", "/index.js", "/index.ts" };

pub fn exportsAsProperty(gpa: Allocator, declaring: *const Snapshot, old: []const u8, renamed: []const Span) !bool {
    const leaves = try rename.leavesNamed(gpa, declaring, old);
    defer gpa.free(leaves);
    var property = false;
    for (leaves) |leaf| {
        if (!covered(renamed, leaf.span)) return false;
        if (leaf.shorthand or (!leaf.free and !leaf.binder)) property = true;
    }
    return property;
}

fn covered(spans: []const Span, span: Span) bool {
    for (spans) |s| {
        if (s.start == span.start and s.end == span.end) return true;
    }
    return false;
}

fn textOf(snapshot: *const Snapshot, node: ts.Node) []const u8 {
    return snapshot.source[node.startByte()..node.endByte()];
}

fn spanOf(node: ts.Node) Span {
    return .{ .start = node.startByte(), .end = node.endByte() };
}

fn unquote(text: []const u8) ?[]const u8 {
    if (text.len < 2) return null;
    const q = text[0];
    if ((q != '"' and q != '\'' and q != '`') or text[text.len - 1] != q) return null;
    return text[1 .. text.len - 1];
}

fn resolves(gpa: Allocator, from_dir: []const u8, spec: []const u8, declaring_abs: []const u8) !bool {
    if (!std.mem.startsWith(u8, spec, "./") and !std.mem.startsWith(u8, spec, "../")) return false;
    for (extensions) |ext| {
        const joined = try std.fmt.allocPrint(gpa, "{s}{s}", .{ spec, ext });
        defer gpa.free(joined);
        const full = try std.fs.path.resolve(gpa, &.{ from_dir, joined });
        defer gpa.free(full);
        if (tsserver.sameFile(full, declaring_abs)) return true;
    }
    return false;
}

fn requireSpec(snapshot: *const Snapshot, value: ts.Node) ?[]const u8 {
    if (!std.mem.eql(u8, value.kind(), "call_expression")) return null;
    const callee = value.childByField("function") orelse return null;
    if (!std.mem.eql(u8, textOf(snapshot, callee), "require")) return null;
    const args = value.childByField("arguments") orelse return null;
    if (args.namedChildCount() != 1) return null;
    const arg = args.namedChild(0) orelse return null;
    if (!std.mem.eql(u8, arg.kind(), "string")) return null;
    return unquote(textOf(snapshot, arg));
}

fn importBinder(clause: ts.Node) ?ts.Node {
    var i: u32 = 0;
    while (clause.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), "identifier")) return child;
        if (std.mem.eql(u8, child.kind(), "namespace_import")) {
            var j: u32 = 0;
            while (child.namedChild(j)) |inner| : (j += 1) {
                if (std.mem.eql(u8, inner.kind(), "identifier")) return inner;
            }
        }
    }
    return null;
}

const Module = struct { binders: std.ArrayList([]const u8) = .empty, patterns: std.ArrayList(ts.Node) = .empty };

fn modulesOf(gpa: Allocator, snapshot: *const Snapshot, from_dir: []const u8, declaring_abs: []const u8) !Module {
    var module: Module = .{};
    errdefer {
        module.binders.deinit(gpa);
        module.patterns.deinit(gpa);
    }
    var walker = traversal.Walker.init(snapshot.tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        const kind = node.kind();
        if (std.mem.eql(u8, kind, "variable_declarator")) {
            const value = node.childByField("value") orelse continue;
            const spec = requireSpec(snapshot, value) orelse continue;
            if (!try resolves(gpa, from_dir, spec, declaring_abs)) continue;
            const name = node.childByField("name") orelse continue;
            if (std.mem.eql(u8, name.kind(), "identifier")) try module.binders.append(gpa, textOf(snapshot, name));
            if (std.mem.eql(u8, name.kind(), "object_pattern")) try module.patterns.append(gpa, name);
        } else if (std.mem.eql(u8, kind, "import_statement")) {
            const source = node.childByField("source") orelse continue;
            const spec = unquote(textOf(snapshot, source)) orelse continue;
            if (!try resolves(gpa, from_dir, spec, declaring_abs)) continue;
            var i: u32 = 0;
            while (node.namedChild(i)) |child| : (i += 1) {
                if (!std.mem.eql(u8, child.kind(), "import_clause")) continue;
                if (importBinder(child)) |binder| try module.binders.append(gpa, textOf(snapshot, binder));
            }
        }
    }
    return module;
}

fn oneBinder(gpa: Allocator, snapshot: *const Snapshot, name: []const u8) !bool {
    return try rename.binderCount(gpa, snapshot, name) == 1;
}

pub fn sitesIn(gpa: Allocator, snapshot: *const Snapshot, from_dir: []const u8, declaring_abs: []const u8, old: []const u8, out: *std.ArrayList(Site)) !void {
    var module = try modulesOf(gpa, snapshot, from_dir, declaring_abs);
    defer {
        module.binders.deinit(gpa);
        module.patterns.deinit(gpa);
    }
    for (module.patterns.items) |pattern| {
        var i: u32 = 0;
        while (pattern.namedChild(i)) |child| : (i += 1) {
            const kind = child.kind();
            if (std.mem.eql(u8, kind, "shorthand_property_identifier_pattern") and std.mem.eql(u8, textOf(snapshot, child), old)) {
                try out.append(gpa, .{ .span = spanOf(child), .keep = .value });
            } else if (std.mem.eql(u8, kind, "pair_pattern")) {
                const key = child.childByField("key") orelse continue;
                if (std.mem.eql(u8, textOf(snapshot, key), old)) try out.append(gpa, .{ .span = spanOf(key), .keep = .none });
            }
        }
    }
    var binders: std.ArrayList([]const u8) = .empty;
    defer binders.deinit(gpa);
    for (module.binders.items) |binder| {
        if (try oneBinder(gpa, snapshot, binder)) try binders.append(gpa, binder);
    }
    if (binders.items.len == 0) return;
    var walker = traversal.Walker.init(snapshot.tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        if (!std.mem.eql(u8, node.kind(), "member_expression")) continue;
        const property = node.childByField("property") orelse continue;
        if (!std.mem.eql(u8, textOf(snapshot, property), old)) continue;
        const object = node.childByField("object") orelse continue;
        if (!std.mem.eql(u8, object.kind(), "identifier")) continue;
        for (binders.items) |binder| {
            if (!std.mem.eql(u8, textOf(snapshot, object), binder)) continue;
            try out.append(gpa, .{ .span = spanOf(property), .keep = .none });
            break;
        }
    }
}

const testing = std.testing;
const test_util = @import("../engine/test_util.zig");

test "a member read through a required or imported module binding is a rename site, other objects and modules are not" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const source =
        \\const utils = require("./utils/ast-utils");
        \\const other = require("./other");
        \\const { isOld, keep: alias } = require("./utils/ast-utils.js");
        \\const { isOld: renamedLocal } = require("../lib/utils/ast-utils");
        \\import * as ns from "./utils/ast-utils";
        \\const a = utils.isOld(x) && other.isOld(y) && ns.isOld(z);
        \\const b = node.isOld;
        \\
    ;
    const snapshot = try test_util.snapshotOf(runtime, source);
    defer snapshot.destroy();
    var sites: std.ArrayList(Site) = .empty;
    defer sites.deinit(testing.allocator);
    try sitesIn(testing.allocator, snapshot, "C:\\repo\\lib", "C:\\repo\\lib\\utils\\ast-utils.js", "isOld", &sites);
    var texts: std.ArrayList(u8) = .empty;
    defer texts.deinit(testing.allocator);
    for (sites.items) |site| try texts.print(testing.allocator, "{d}:{s}:{t} ", .{ std.mem.count(u8, source[0..site.span.start], "\n") + 1, source[site.span.start..site.span.end], site.keep });
    errdefer std.debug.print("{s}\n", .{texts.items});
    try testing.expectEqual(@as(usize, 4), sites.items.len);
    try testing.expectEqualStrings("3:isOld:value 4:isOld:none 6:isOld:none 6:isOld:none ", texts.items);
}

test "a local rebinding of the module name stops member sites from being renamed" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const source =
        \\const utils = require("./ast-utils");
        \\function f(utils) { return utils.isOld(1); }
        \\
    ;
    const snapshot = try test_util.snapshotOf(runtime, source);
    defer snapshot.destroy();
    var sites: std.ArrayList(Site) = .empty;
    defer sites.deinit(testing.allocator);
    try sitesIn(testing.allocator, snapshot, "C:\\repo", "C:\\repo\\ast-utils.js", "isOld", &sites);
    try testing.expectEqual(@as(usize, 0), sites.items.len);
}

test "a declaring file exports the name as a property only when every occurrence is renamed and one is a key" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const source = "function isOld() { return 1; }\nmodule.exports = { isOld };\n";
    const snapshot = try test_util.snapshotOf(runtime, source);
    defer snapshot.destroy();
    const leaves = try rename.leavesNamed(testing.allocator, snapshot, "isOld");
    defer testing.allocator.free(leaves);
    var all: std.ArrayList(Span) = .empty;
    defer all.deinit(testing.allocator);
    for (leaves) |leaf| try all.append(testing.allocator, leaf.span);
    try testing.expect(try exportsAsProperty(testing.allocator, snapshot, "isOld", all.items));
    try testing.expect(!try exportsAsProperty(testing.allocator, snapshot, "isOld", all.items[0..1]));

    const local = try test_util.snapshotOf(runtime, "function isOld() { return 1; }\nisOld();\n");
    defer local.destroy();
    const local_leaves = try rename.leavesNamed(testing.allocator, local, "isOld");
    defer testing.allocator.free(local_leaves);
    var local_all: std.ArrayList(Span) = .empty;
    defer local_all.deinit(testing.allocator);
    for (local_leaves) |leaf| try local_all.append(testing.allocator, leaf.span);
    try testing.expect(!try exportsAsProperty(testing.allocator, local, "isOld", local_all.items));
}
