const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const ts = @import("../engine/tree_sitter.zig");
const scope = @import("../engine/scope.zig");
const modules = @import("../engine/modules.zig");
const rename = @import("../engine/rename.zig");
const registry = @import("../engine/lang/registry.zig");
const repo = @import("repo.zig");
const tsserver = @import("tsserver.zig");
const paths = @import("module_paths.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const Snapshot = @import("../engine/loader.zig").Snapshot;

const Allocator = std.mem.Allocator;
const Import = modules.Import;
const Named = modules.Named;

pub const Existing = paths.Existing;

pub const TextEdit = struct {
    start: u32,
    end: u32,
    text: []const u8,
};

pub const Cx = struct {
    arena: Allocator,
    io: std.Io,
    runtime: *Runtime,
    root: []const u8,
};

const keywords = std.StaticStringMap(void).initComptime(.{
    .{"False"},  .{"None"},   .{"True"},    .{"and"},    .{"as"},   .{"assert"}, .{"async"},
    .{"await"},  .{"break"},  .{"class"},   .{"continue"}, .{"def"},  .{"del"},    .{"elif"},
    .{"else"},   .{"except"}, .{"finally"}, .{"for"},    .{"from"}, .{"global"}, .{"if"},
    .{"import"}, .{"in"},     .{"is"},      .{"lambda"}, .{"nonlocal"}, .{"not"},  .{"or"},
    .{"pass"},   .{"raise"},  .{"return"},  .{"try"},    .{"while"}, .{"with"},  .{"yield"},
});

pub fn isIdentifier(text: []const u8) bool {
    if (text.len == 0 or keywords.has(text)) return false;
    for (text, 0..) |byte, i| {
        if (byte >= 0x80 or byte == '_' or std.ascii.isAlphabetic(byte)) continue;
        if (i != 0 and std.ascii.isDigit(byte)) continue;
        return false;
    }
    return true;
}

pub fn firstSegment(dotted: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, dotted, '.') orelse return dotted;
    return dotted[0..dot];
}

pub fn joinSpec(arena: Allocator, spec: []const u8, name: []const u8) ![]const u8 {
    if (spec.len == 0) return arena.dupe(u8, name);
    if (name.len == 0) return arena.dupe(u8, spec);
    if (spec[spec.len - 1] == '.') return std.fmt.allocPrint(arena, "{s}{s}", .{ spec, name });
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ spec, name });
}

pub fn sameOptional(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return tsserver.sameFile(a.?, b.?);
}

fn extensionless(path: []const u8) []const u8 {
    return path[0 .. path.len - std.fs.path.extension(path).len];
}

pub fn moduleLogical(path: []const u8) []const u8 {
    const bare = extensionless(path);
    if (std.ascii.eqlIgnoreCase(std.fs.path.basename(bare), "__init__")) return std.fs.path.dirname(bare) orelse bare;
    return bare;
}

pub fn isPackageInit(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.basename(extensionless(path)), "__init__");
}

pub fn hasInit(existing: Existing, arena: Allocator, dir: []const u8) !bool {
    for ([_][]const u8{ "__init__.py", "__init__.pyi" }) |name| {
        if (existing.has(try std.fmt.allocPrint(arena, "{s}\\{s}", .{ dir, name }))) return true;
    }
    return false;
}

fn underRoot(root: []const u8, path: []const u8) ?[]const u8 {
    if (path.len < root.len or !std.ascii.eqlIgnoreCase(path[0..root.len], root)) return null;
    if (path.len == root.len) return "";
    if (path[root.len] != '\\' and path[root.len] != '/') return null;
    return path[root.len + 1 ..];
}

fn dottedOf(arena: Allocator, relative_path: []const u8) !?[]const u8 {
    if (relative_path.len == 0) return null;
    const dotted = try arena.dupe(u8, relative_path);
    std.mem.replaceScalar(u8, dotted, '\\', '.');
    std.mem.replaceScalar(u8, dotted, '/', '.');
    var segments = std.mem.splitScalar(u8, dotted, '.');
    while (segments.next()) |segment| if (!isIdentifier(segment)) return null;
    return dotted;
}

pub fn dotCount(spec: []const u8) usize {
    var dots: usize = 0;
    while (dots < spec.len and spec[dots] == '.') dots += 1;
    return dots;
}

pub fn scriptRoot(cx: Cx, existing: Existing, importer: []const u8) ![]const u8 {
    var dir = std.fs.path.dirname(importer) orelse return cx.root;
    while (dir.len > cx.root.len and try hasInit(existing, cx.arena, dir)) dir = std.fs.path.dirname(dir) orelse return cx.root;
    return dir;
}

pub fn rootsOf(cx: Cx, existing: Existing, importer: []const u8) ![3][]const u8 {
    return .{ try scriptRoot(cx, existing, importer), cx.root, try std.fmt.allocPrint(cx.arena, "{s}\\src", .{cx.root}) };
}

pub fn logicalOf(cx: Cx, importer: []const u8, spec: []const u8) !?[]const u8 {
    const dots = dotCount(spec);
    var dir = std.fs.path.dirname(importer) orelse return null;
    var up = dots - 1;
    while (up != 0) : (up -= 1) dir = std.fs.path.dirname(dir) orelse return null;
    if (underRoot(cx.root, dir) == null) return null;
    if (dots == spec.len) return dir;
    const rest = try cx.arena.dupe(u8, spec[dots..]);
    std.mem.replaceScalar(u8, rest, '.', '\\');
    return try std.fmt.allocPrint(cx.arena, "{s}\\{s}", .{ dir, rest });
}

pub fn resolve(cx: Cx, existing: Existing, importer: []const u8, spec: []const u8) !?[]const u8 {
    if (spec.len == 0) return null;
    if (spec[0] == '.') {
        const joined = (try logicalOf(cx, importer, spec)) orelse return null;
        return paths.resolveJoinedPython(cx.arena, existing, joined, '\\');
    }
    const rest = try cx.arena.dupe(u8, spec);
    std.mem.replaceScalar(u8, rest, '.', '\\');
    for (try rootsOf(cx, existing, importer)) |base| {
        const joined = try std.fmt.allocPrint(cx.arena, "{s}\\{s}", .{ base, rest });
        if (try paths.resolveJoinedPython(cx.arena, existing, joined, '\\')) |hit| return hit;
    }
    return null;
}

pub fn ambiguous(cx: Cx, existing: Existing, importer: []const u8, spec: []const u8) !bool {
    if (spec.len == 0 or spec[0] == '.') return false;
    const rest = try cx.arena.dupe(u8, spec);
    std.mem.replaceScalar(u8, rest, '.', '\\');
    var first: ?[]const u8 = null;
    for (try rootsOf(cx, existing, importer)) |base| {
        const joined = try std.fmt.allocPrint(cx.arena, "{s}\\{s}", .{ base, rest });
        const hit = (try paths.resolveJoinedPython(cx.arena, existing, joined, '\\')) orelse continue;
        if (first) |seen| {
            if (!tsserver.sameFile(seen, hit)) return true;
        } else first = hit;
    }
    return false;
}

pub fn absoluteOf(cx: Cx, existing: Existing, importer: []const u8, target: []const u8) !?[]const u8 {
    for (try rootsOf(cx, existing, importer)) |base| {
        const relative_path = underRoot(base, moduleLogical(target)) orelse continue;
        const dotted = (try dottedOf(cx.arena, relative_path)) orelse continue;
        if (sameOptional(try resolve(cx, existing, importer, dotted), target)) return dotted;
    }
    return null;
}

pub fn absoluteOfDir(cx: Cx, existing: Existing, importer: []const u8, dir: []const u8) !?[]const u8 {
    for (try rootsOf(cx, existing, importer)) |base| {
        const relative_path = underRoot(base, dir) orelse continue;
        if (try dottedOf(cx.arena, relative_path)) |dotted| return dotted;
    }
    return null;
}

pub fn packageDepth(cx: Cx, existing: Existing, importer: []const u8) !usize {
    var depth: usize = 0;
    var dir = std.fs.path.dirname(importer) orelse return 0;
    while (dir.len > cx.root.len and try hasInit(existing, cx.arena, dir)) {
        depth += 1;
        dir = std.fs.path.dirname(dir) orelse break;
    }
    return depth;
}

pub fn relativeOf(cx: Cx, existing: Existing, importer: []const u8, logical: []const u8, strict: bool) !?[]const u8 {
    const dir = std.fs.path.dirname(importer) orelse return null;
    const from_rel = underRoot(cx.root, dir) orelse return null;
    const to_rel = underRoot(cx.root, logical) orelse return null;
    var from_parts: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.tokenizeAny(u8, from_rel, "\\/");
    while (parts.next()) |part| try from_parts.append(cx.arena, part);
    var to_parts: std.ArrayList([]const u8) = .empty;
    parts = std.mem.tokenizeAny(u8, to_rel, "\\/");
    while (parts.next()) |part| try to_parts.append(cx.arena, part);
    var common: usize = 0;
    while (common < from_parts.items.len and common < to_parts.items.len and std.ascii.eqlIgnoreCase(from_parts.items[common], to_parts.items[common])) common += 1;
    const dots = from_parts.items.len - common + 1;
    if (strict and dots > try packageDepth(cx, existing, importer)) return null;
    var out: std.ArrayList(u8) = .empty;
    try out.appendNTimes(cx.arena, '.', dots);
    for (to_parts.items[common..], 0..) |part, i| {
        if (!isIdentifier(part)) return null;
        if (i != 0) try out.append(cx.arena, '.');
        try out.appendSlice(cx.arena, part);
    }
    return out.items;
}

pub fn isFromStatement(source: []const u8, entry: Import) bool {
    return std.mem.startsWith(u8, source[entry.statement.start..entry.statement.end], "from");
}

pub fn specSpan(source: []const u8, spec: []const u8) symbol.Span {
    const at: u32 = @intCast(@intFromPtr(spec.ptr) - @intFromPtr(source.ptr));
    return .{ .start = at, .end = at + @as(u32, @intCast(spec.len)) };
}

pub fn isAliased(source: []const u8, entry: Import) bool {
    return entry.namespace_start != specSpan(source, entry.spec).start;
}

pub fn load(cx: Cx, abs: []const u8, text: ?[]const u8) !*Snapshot {
    const profile = registry.forPath(abs) orelse return error.UnsupportedLanguage;
    const source = if (text) |t| try cx.runtime.gpa.dupe(u8, t) else try std.Io.Dir.cwd().readFileAlloc(cx.io, abs, cx.runtime.gpa, .limited(64 * 1024 * 1024));
    return Snapshot.fromSource(cx.runtime, profile, source);
}

pub fn trackedPython(cx: Cx) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "*.py", "*.pyi" }) |pathspec| {
        const listing = try repo.trackedListing(cx.arena, cx.io, cx.root, pathspec);
        var files = std.mem.tokenizeScalar(u8, listing, 0);
        while (files.next()) |rel| {
            const abs = try std.fmt.allocPrint(cx.arena, "{s}\\{s}", .{ cx.root, rel });
            std.mem.replaceScalar(u8, abs, '/', '\\');
            try out.append(cx.arena, abs);
        }
    }
    return out.items;
}

pub const Binding = struct {
    local: []const u8,
    dotted: []const u8,
    entry: Import,
    item: ?Named,
    plain: bool,
};

pub fn bindingsOf(cx: Cx, source: []const u8, entries: []const Import) ![]Binding {
    var out: std.ArrayList(Binding) = .empty;
    for (entries) |entry| {
        if (isFromStatement(source, entry)) {
            for (entry.named) |item| {
                try out.append(cx.arena, .{ .local = item.local(), .dotted = try joinSpec(cx.arena, entry.spec, item.name), .entry = entry, .item = item, .plain = false });
            }
        } else if (entry.namespace) |local| {
            const aliased = isAliased(source, entry);
            try out.append(cx.arena, .{ .local = local, .dotted = if (aliased) entry.spec else firstSegment(entry.spec), .entry = entry, .item = null, .plain = !aliased });
        }
    }
    return out.items;
}

pub fn segmentsAfter(arena: Allocator, chain: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (chain) |byte| {
        if (!std.ascii.isWhitespace(byte)) try out.append(arena, byte);
    }
    return out.items;
}

pub fn climb(leaf: ts.Node, source: []const u8, tail: []const u8) ?ts.Node {
    var node = leaf;
    var parts = std.mem.tokenizeScalar(u8, tail, '.');
    while (parts.next()) |part| {
        const parent = node.parent() orelse return null;
        if (!std.mem.eql(u8, parent.kind(), "attribute")) return null;
        const object = parent.childByField("object") orelse return null;
        if (!object.eql(node)) return null;
        const attribute = parent.childByField("attribute") orelse return null;
        if (!std.mem.eql(u8, source[attribute.startByte()..attribute.endByte()], part)) return null;
        node = parent;
    }
    return node;
}

pub fn lineIndent(source: []const u8, at: u32) ?[]const u8 {
    var start: usize = at;
    while (start > 0 and source[start - 1] != '\n') start -= 1;
    const indent = source[start..at];
    if (std.mem.trim(u8, indent, " \t").len != 0) return null;
    return indent;
}

pub fn newlineOf(source: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, source, "\r\n") != null) "\r\n" else "\n";
}

pub fn endsStatementLine(source: []const u8, end: u32) bool {
    var at: usize = end;
    while (at < source.len and (source[at] == ' ' or source[at] == '\t')) at += 1;
    return at >= source.len or source[at] == '\n' or source[at] == '\r' or source[at] == '#';
}

pub fn stringBody(text: []const u8) []const u8 {
    var at: usize = 0;
    while (at < text.len and text[at] != '"' and text[at] != '\'') at += 1;
    if (at == text.len) return text;
    const quote = text[at];
    var width: usize = 1;
    if (at + 2 < text.len and text[at + 1] == quote and text[at + 2] == quote) width = 3;
    if (text.len < at + 2 * width) return text;
    return text[at + width .. text.len - width];
}

fn identifierByte(byte: u8) bool {
    return byte >= 0x80 or byte == '_' or std.ascii.isAlphanumeric(byte);
}

pub fn namesDotted(body: []const u8, dotted: []const u8) bool {
    if (std.mem.indexOfScalar(u8, dotted, '.') == null) {
        return std.mem.eql(u8, body, dotted) or (body.len > dotted.len and std.mem.startsWith(u8, body, dotted) and body[dotted.len] == '.');
    }
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, body, from, dotted)) |at| {
        from = at + 1;
        const before_ok = at == 0 or (!identifierByte(body[at - 1]) and body[at - 1] != '.');
        const after = at + dotted.len;
        const after_ok = after == body.len or !identifierByte(body[after]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

pub fn stringNaming(snapshot: *const Snapshot, arena: Allocator, dotted: []const []const u8, exact: ?[]const u8) !bool {
    var stack: std.ArrayList(ts.Node) = .empty;
    try stack.append(arena, snapshot.tree.root());
    while (stack.pop()) |node| {
        var is_string = false;
        for (snapshot.profile.strings) |kind| {
            if (std.mem.eql(u8, kind, node.kind())) is_string = true;
        }
        if (is_string) {
            const parent = node.parent();
            if (parent != null and std.mem.eql(u8, parent.?.kind(), "expression_statement")) continue;
            const body = stringBody(snapshot.tree.text(node));
            for (dotted) |name| if (namesDotted(body, name)) return true;
            if (exact) |word| if (std.mem.eql(u8, body, word)) return true;
            continue;
        }
        var i: u32 = 0;
        while (node.child(i)) |child| : (i += 1) try stack.append(arena, child);
    }
    return false;
}

pub fn initBindsOther(cx: Cx, init_abs: []const u8, init_snapshot: *const Snapshot, name: []const u8, sub: []const u8, existing: Existing) !bool {
    const resolution = try scope.resolveName(cx.arena, init_snapshot, name);
    const root = init_snapshot.tree.root();
    var bound = false;
    for (resolution.binders) |binder| {
        if (binder.scope.start != root.startByte() or binder.scope.end != root.endByte()) continue;
        bound = true;
        if (!binder.import) return true;
    }
    if (!bound) return false;
    for (try bindingsOf(cx, init_snapshot.source, try modules.imports(cx.arena, init_snapshot))) |binding| {
        if (!std.mem.eql(u8, binding.local, name)) continue;
        if (binding.plain) continue;
        const target = try resolve(cx, existing, init_abs, binding.dotted);
        if (!sameOptional(target, sub)) return true;
    }
    return false;
}
