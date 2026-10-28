const std = @import("std");
const ts = @import("tree_sitter.zig");
const symbol = @import("symbol.zig");
const Snapshot = @import("loader.zig").Snapshot;
const Profile = @import("lang/profile.zig").Profile;
const Runtime = @import("runtime.zig").Runtime;
const test_util = @import("test_util.zig");
const traversal = @import("traversal.zig");
const doc_fold = @import("doc_fold.zig");

const Allocator = std.mem.Allocator;
const Span = symbol.Span;

pub const Error = error{
    SourceHasErrors,
    SymbolNotFound,
    AmbiguousSymbol,
    HashMismatch,
    MutationSyntaxInvalid,
    BodyEscape,
    PlaceholderBody,
    SymbolExists,
    MissingTrailingNewline,
    NoTopLevelSymbol,
    MultipleTopLevelSymbols,
    ExtraTopLevelCode,
    SymbolNameMismatch,
} || Allocator.Error || ts.Error;

pub const Insertion = struct {
    ref: symbol.Ref,
    new_body: []const u8,
};

pub const Mutation = struct {
    ref: symbol.Ref,
    expected_hash: symbol.Hash,
    new_body: []const u8,
};

pub const Applied = struct {
    snapshot: *Snapshot,
    hash: symbol.Hash,
    body: Span,
    hole: symbol.Hole,
};

const utf8_bom = "\xEF\xBB\xBF";

pub fn normalizeBody(body: []const u8) []const u8 {
    const without_bom = if (std.mem.startsWith(u8, body, utf8_bom)) body[utf8_bom.len..] else body;
    return std.mem.trim(u8, without_bom, " \t\r\n");
}

fn crlfOf(source: []const u8) ?[]const u8 {
    const at = std.mem.indexOfScalar(u8, source, '\n') orelse return null;
    return if (at > 0 and source[at - 1] == '\r') "\r\n" else null;
}

fn followLineEnding(gpa: Allocator, body: []const u8, eol: ?[]const u8) Allocator.Error![]u8 {
    const ending = eol orelse return gpa.dupe(u8, body);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] == '\r' and i + 1 < body.len and body[i + 1] == '\n') {
            try out.appendSlice(gpa, ending);
            i += 1;
        } else if (body[i] == '\n') {
            try out.appendSlice(gpa, ending);
        } else try out.append(gpa, body[i]);
    }
    return out.toOwnedSlice(gpa);
}

pub fn apply(base: *Snapshot, mutation: Mutation) Error!Applied {
    const before = try base.symbols();
    const target = before.resolve(mutation.ref) catch |err| switch (err) {
        error.SymbolNotFound => return replaceItem(base, mutation),
        error.AmbiguousSymbol => return err,
    };
    return applyBody(base, mutation, target) catch |err| switch (err) {
        error.MutationSyntaxInvalid, error.BodyEscape => replaceItem(base, mutation) catch return err,
        else => return err,
    };
}

fn unfoldDocs(base: *Snapshot, cut: Span, body: []const u8) Allocator.Error!?[]u8 {
    return doc_fold.restore(base.runtime.gpa, base.profile, base.tree, cut.start, cut.end, body);
}

fn applyBody(base: *Snapshot, mutation: Mutation, target: *const symbol.Symbol) Error!Applied {
    const unfolded = try unfoldDocs(base, .{ .start = target.body.startByte(), .end = target.body.endByte() }, normalizeBody(mutation.new_body));
    defer if (unfolded) |text| base.runtime.gpa.free(text);
    const new_body = try followLineEnding(base.runtime.gpa, unfolded orelse normalizeBody(mutation.new_body), crlfOf(base.source));
    defer base.runtime.gpa.free(new_body);
    const before = try base.symbols();
    if (!std.mem.eql(u8, &target.hash, &mutation.expected_hash)) return error.HashMismatch;

    const cut: Span = .{ .start = target.body.startByte(), .end = target.body.endByte() };
    const source = try std.mem.concat(base.runtime.gpa, u8, &.{ base.source[0..cut.start], new_body, base.source[cut.end..] });
    const next = try Snapshot.fromSource(base.runtime, base.profile, source);
    errdefer next.destroy();
    if (next.tree.root().hasError()) return error.MutationSyntaxInvalid;

    const after = next.symbols() catch |err| switch (err) {
        error.SourceHasErrors => return error.MutationSyntaxInvalid,
        error.OutOfMemory => return error.OutOfMemory,
    };

    const slot: Span = .{ .start = cut.start, .end = cut.start + @as(u32, @intCast(new_body.len)) };
    const patched_target = after.resolve(mutation.ref) catch return error.BodyEscape;
    try expectExactSlot(base.profile, patched_target.body, slot);
    try rejectPlaceholder(base.profile, patched_target.body);
    try expectUntouchedOutside(before.*, after.*, cut, slot);

    return .{ .snapshot = next, .hash = patched_target.hash, .body = slot, .hole = .{ .old = cut, .new = slot } };
}

fn replaceItem(base: *Snapshot, mutation: Mutation) Error!Applied {
    const before = try base.symbols();
    const target = try before.item(mutation.ref);
    if (!std.mem.eql(u8, &mutation.expected_hash, &target.hash)) return error.HashMismatch;
    const gpa = base.runtime.gpa;
    const crlf = crlfOf(base.source);
    const unfolded = try unfoldDocs(base, target.span, normalizeBody(mutation.new_body));
    defer if (unfolded) |text| gpa.free(text);
    const body = try followLineEnding(gpa, unfolded orelse normalizeBody(mutation.new_body), crlf);
    defer gpa.free(body);
    const text = try shapeText(gpa, base, target.span, body);
    defer gpa.free(text);
    return spliceItem(base, mutation.ref, target.span, target.span, text) catch |err| {
        if (target.role != .property) return err;
        const value = target.node.childByField(base.profile.declarations.items.pair_value) orelse return err;
        const value_span: Span = .{ .start = value.startByte(), .end = value.endByte() };
        return spliceItem(base, mutation.ref, target.span, value_span, text) catch return err;
    };
}

fn spliceItem(base: *Snapshot, ref: symbol.Ref, old: Span, cut: Span, text: []const u8) Error!Applied {
    const before = try base.symbols();
    const next = try reparse(base, cut, text);
    errdefer next.destroy();
    const after = next.symbols() catch |err| switch (err) {
        error.SourceHasErrors => return error.MutationSyntaxInvalid,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const slot: Span = .{ .start = cut.start, .end = cut.start + @as(u32, @intCast(text.len)) };
    const grown: Span = .{ .start = old.start, .end = old.end - (cut.end - cut.start) + slot.end - slot.start };
    const placed = after.item(ref) catch return error.BodyEscape;
    if (placed.span.start != grown.start or placed.span.end != grown.end) return error.BodyEscape;
    if (placed.body) |body| try rejectPlaceholder(base.profile, body);
    try expectSameShape(base.tree, next.tree, cut, slot);
    try expectUntouchedOutside(before.*, after.*, old, grown);
    return .{ .snapshot = next, .hash = placed.hash, .hole = .{ .old = cut, .new = slot }, .body = slot };
}

fn reparse(base: *Snapshot, cut: Span, text: []const u8) Error!*Snapshot {
    const head = base.source[0..cut.start];
    const tail = base.source[cut.end..];
    const next = try Snapshot.fromSource(base.runtime, base.profile, try std.mem.concat(base.runtime.gpa, u8, &.{ head, text, tail }));
    errdefer next.destroy();
    const broken = next.tree.root().hasError();
    if (broken) return error.MutationSyntaxInvalid;
    return next;
}

fn shapeText(gpa: Allocator, base: *Snapshot, span: Span, body: []const u8) Allocator.Error![]u8 {
    var text = body;
    if (text.len > 0 and (text[text.len - 1] == ',' or text[text.len - 1] == ';') and span.end < base.source.len and base.source[span.end] == text[text.len - 1]) text = text[0 .. text.len - 1];
    const prefix = exportPrefix(base, span, text);
    const indent = lineIndent(base.source, span.start);
    const joined = try std.mem.concat(gpa, u8, &.{ prefix, text });
    defer gpa.free(joined);
    return reindent(gpa, joined, indent);
}

fn exportPrefix(base: *Snapshot, span: Span, text: []const u8) []const u8 {
    const root = base.tree.root();
    var i: u32 = 0;
    while (root.namedChild(i)) |node| : (i += 1) {
        if (node.startByte() != span.start or node.endByte() != span.end) continue;
        if (!isOneOf(node.kind(), base.profile.export_wrappers)) return "";
        const keyword = node.child(0) orelse return "";
        if (std.mem.startsWith(u8, text, base.tree.text(keyword))) return "";
        var j: u32 = 0;
        while (node.namedChild(j)) |inner| : (j += 1) {
            if (base.profile.isComment(inner.kind()) or std.mem.eql(u8, inner.kind(), base.profile.decorator)) continue;
            return base.source[span.start..inner.startByte()];
        }
        return "";
    }
    return "";
}

fn isOneOf(kind: []const u8, kinds: []const []const u8) bool {
    for (kinds) |candidate| {
        if (std.mem.eql(u8, candidate, kind)) return true;
    }
    return false;
}

fn lineStart(source: []const u8, at: u32) u32 {
    var start = at;
    while (start > 0 and source[start - 1] != '\n') start -= 1;
    return start;
}

fn lineIndent(source: []const u8, at: u32) []const u8 {
    const start = lineStart(source, at);
    const lead = source[start..at];
    for (lead) |c| {
        if (c != ' ' and c != '\t') return "";
    }
    return lead;
}

fn leadingSpace(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and (line[n] == ' ' or line[n] == '\t')) n += 1;
    return n;
}

fn reindent(gpa: Allocator, text: []const u8, indent: []const u8) Allocator.Error![]u8 {
    const last_break = std.mem.lastIndexOfScalar(u8, text, '\n');
    const shift = if (last_break) |at| leadingSpace(text[at + 1 ..]) < indent.len else false;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        if (index != 0) try out.append(gpa, '\n');
        if (index != 0 and shift and std.mem.trim(u8, line, " \t\r").len != 0) try out.appendSlice(gpa, indent);
        try out.appendSlice(gpa, line);
    }
    return out.toOwnedSlice(gpa);
}

fn outsideOf(node: ts.Node, region: Span) bool {
    const start = node.startByte();
    const end = node.endByte();
    return end <= region.start or start >= region.end or (start <= region.start and end >= region.end);
}

fn mapped(at: u32, cut: Span, slot: Span) u32 {
    return if (at <= cut.start) at else at - cut.end + slot.end;
}

fn mappedStart(at: u32, cut: Span, slot: Span) u32 {
    return if (at < cut.end) at else at - cut.end + slot.end;
}

fn nextOutside(walker: *traversal.Walker, region: Span) ?ts.Node {
    while (walker.next()) |entry| {
        if (entry.depth == 0) continue;
        if (outsideOf(entry.node, region)) return entry.node;
        walker.skipChildren();
    }
    return null;
}

pub fn expectSameShape(old: ts.Tree, new: ts.Tree, cut: Span, slot: Span) error{BodyEscape}!void {
    var a = traversal.Walker.init(old.root());
    defer a.deinit();
    var b = traversal.Walker.init(new.root());
    defer b.deinit();
    while (true) {
        const x = nextOutside(&a, cut);
        const y = nextOutside(&b, slot);
        if (x == null and y == null) return;
        const p = x orelse return error.BodyEscape;
        const q = y orelse return error.BodyEscape;
        if (!std.mem.eql(u8, p.kind(), q.kind())) return error.BodyEscape;
        if (mappedStart(p.startByte(), cut, slot) != q.startByte() or mapped(p.endByte(), cut, slot) != q.endByte()) return error.BodyEscape;
    }
}

pub fn propose(base: *Snapshot, ref: symbol.Ref, expected: symbol.Expected, new_body: []const u8) Error!Applied {
    return switch (expected) {
        .present => |hash| apply(base, .{ .ref = ref, .expected_hash = hash, .new_body = new_body }),
        .absent => insert(base, .{ .ref = ref, .new_body = new_body }),
    };
}

pub fn insert(base: *Snapshot, insertion: Insertion) Error!Applied {
    const before = try base.symbols();
    if (before.item(insertion.ref)) |_| return error.SymbolExists else |err| if (err == error.AmbiguousSymbol) return error.SymbolExists;

    const eol = try lineEnding(base.source);
    const new_body = try followLineEnding(base.runtime.gpa, normalizeBody(insertion.new_body), crlfOf(eol));
    defer base.runtime.gpa.free(new_body);
    if (classHolding(before.*, insertion.ref)) |class| return insertMember(base, insertion.ref, class, new_body, eol);
    const place = try placeTopLevel(base, new_body, eol);
    const gpa = base.runtime.gpa;
    const text = try std.mem.concat(gpa, u8, &.{ place.lead, new_body, eol });
    defer gpa.free(text);
    const start: u32 = place.cut.start + @as(u32, @intCast(place.lead.len));
    const source = try std.mem.concat(gpa, u8, &.{ base.source[0..place.cut.start], text, base.source[place.cut.end..] });
    const next = try Snapshot.fromSource(base.runtime, base.profile, source);
    errdefer next.destroy();
    const after = next.symbols() catch |err| switch (err) {
        error.SourceHasErrors => return error.MutationSyntaxInvalid,
        error.OutOfMemory => return error.OutOfMemory,
    };

    const slot: Span = .{ .start = start, .end = start + @as(u32, @intCast(new_body.len)) };
    const declared = try expectSoleDeclaration(base.profile, next.tree.root(), after.*, slot, insertion.ref);
    const end = place.cut;
    const region: Span = .{ .start = end.start, .end = end.start + @as(u32, @intCast(text.len)) };
    try expectSameShape(base.tree, next.tree, end, region);
    try expectUntouchedOutside(before.*, after.*, end, slot);

    return .{ .snapshot = next, .hash = declared.hash, .body = slot, .hole = .{ .old = end, .new = region } };
}

const Place = struct {
    cut: Span,
    lead: []const u8,
};

fn placeTopLevel(base: *Snapshot, new_body: []const u8, eol: []const u8) Error!Place {
    const probe = try Snapshot.fromSource(base.runtime, base.profile, try base.runtime.gpa.dupe(u8, new_body));
    defer probe.destroy();
    const first = firstStatement(base.profile, probe.tree.root());
    const root = base.tree.root();
    if (first) |node| if (importLike(base.profile, probe.tree, node)) {
        var last: ?ts.Node = null;
        var i: u32 = 0;
        while (root.namedChild(i)) |child| : (i += 1) {
            if (importLike(base.profile, base.tree, child)) last = child;
        }
        if (last) |anchor| {
            const at = nextLineStart(base.source, anchor.endByte());
            return .{ .cut = .{ .start = at, .end = at }, .lead = "" };
        }
    };
    var content: usize = base.source.len;
    while (content > 0 and std.mem.indexOfScalar(u8, " \t\r\n", base.source[content - 1]) != null) content -= 1;
    if (content == 0) return .{ .cut = .{ .start = 0, .end = @intCast(base.source.len) }, .lead = "" };
    const kept = nextLineStart(base.source, @intCast(content));
    const previous = lastStatement(base.profile, root);
    const grouped = if (first != null and previous != null) sameGroup(base.profile, base.tree, previous.?, probe.tree, first.?) else false;
    return .{ .cut = .{ .start = kept, .end = @intCast(base.source.len) }, .lead = if (grouped) "" else eol };
}

fn nextLineStart(source: []const u8, at: u32) u32 {
    const newline = std.mem.indexOfScalarPos(u8, source, at, '\n') orelse return @intCast(source.len);
    return @intCast(newline + 1);
}

fn firstStatement(profile: *const Profile, root: ts.Node) ?ts.Node {
    var i: u32 = 0;
    while (root.namedChild(i)) |child| : (i += 1) {
        if (!profile.isComment(child.kind())) return child;
    }
    return null;
}

fn lastStatement(profile: *const Profile, root: ts.Node) ?ts.Node {
    var i = root.namedChildCount();
    while (i > 0) {
        i -= 1;
        const child = root.namedChild(i).?;
        if (!profile.isComment(child.kind())) return child;
    }
    return null;
}

pub fn importLike(profile: *const Profile, tree: ts.Tree, node: ts.Node) bool {
    const items = profile.declarations.items;
    if (isOneOf(node.kind(), items.imports)) return true;
    const require = items.require orelse return false;
    if (!isOneOf(node.kind(), profile.declarations.variable_statements)) return false;
    var i: u32 = 0;
    while (node.namedChild(i)) |declarator| : (i += 1) {
        const value = declarator.childByField(profile.declarations.value_field) orelse continue;
        if (!std.mem.eql(u8, value.kind(), profile.call.node)) return false;
        const callee = value.childByField(profile.call.function_field) orelse return false;
        return std.mem.eql(u8, tree.text(callee), require);
    }
    return false;
}

fn sameGroup(profile: *const Profile, old: ts.Tree, previous: ts.Node, new: ts.Tree, first: ts.Node) bool {
    if (std.mem.indexOfScalar(u8, old.text(previous), '\n') != null or std.mem.indexOfScalar(u8, new.text(first), '\n') != null) return false;
    if (!std.mem.eql(u8, previous.kind(), first.kind())) return false;
    return isOneOf(first.kind(), profile.declarations.variable_statements) or isOneOf(first.kind(), profile.declarations.items.imports) or std.mem.eql(u8, first.kind(), profile.expression_statement);
}

fn classHolding(table: symbol.Table, ref: symbol.Ref) ?ts.Node {
    if (ref.container.len == 0) return null;
    const owner: symbol.Ref = .{ .container = ref.container[0 .. ref.container.len - 1], .name = ref.container[ref.container.len - 1] };
    for (table.declarations) |declaration| {
        if (declaration.kind == .class and !declaration.ambiguous and declaration.ref.eql(owner)) return declaration.node;
    }
    return null;
}

fn insertMember(base: *Snapshot, ref: symbol.Ref, class: ts.Node, new_body: []const u8, eol: []const u8) Error!Applied {
    const gpa = base.runtime.gpa;
    const before = try base.symbols();
    const body = class.childByField("body") orelse return error.SymbolNameMismatch;
    const close = body.child(body.childCount() - 1) orelse return error.SymbolNameMismatch;
    const open = body.child(0) orelse return error.SymbolNameMismatch;
    var last: ?ts.Node = null;
    var i: u32 = 0;
    while (body.namedChild(i)) |member| : (i += 1) {
        if (!base.profile.isComment(member.kind())) last = member;
    }
    const close_line = lineStart(base.source, close.startByte());
    if (lineIndent(base.source, close.startByte()).len != close.startByte() - close_line) {
        const cut: Span = .{ .start = close.startByte(), .end = close.startByte() };
        const text = try std.mem.concat(gpa, u8, &.{ new_body, " " });
        return finishMember(base, before.*, ref, cut, text, .{ .start = cut.start, .end = cut.start + @as(u32, @intCast(new_body.len)) });
    }
    var indent_buf: [256]u8 = undefined;
    const indent = if (last) |member| lineIndent(base.source, member.startByte()) else std.fmt.bufPrint(&indent_buf, "{s}  ", .{lineIndent(base.source, close.startByte())}) catch "  ";
    const anchor = if (last) |member| member.endByte() else open.endByte();
    const cut: Span = .{ .start = nextLineStart(base.source, anchor), .end = close_line };
    const blank = last != null and (std.mem.indexOfScalar(u8, base.tree.text(last.?), '\n') != null or std.mem.indexOfScalar(u8, new_body, '\n') != null);
    const lead: []const u8 = if (blank) eol else "";
    const shaped = try reindent(gpa, new_body, indent);
    defer gpa.free(shaped);
    const text = try std.mem.concat(gpa, u8, &.{ lead, indent, shaped, eol });
    const body_start = cut.start + @as(u32, @intCast(lead.len + indent.len));
    return finishMember(base, before.*, ref, cut, text, .{ .start = body_start, .end = body_start + @as(u32, @intCast(shaped.len)) });
}

fn finishMember(base: *Snapshot, before: symbol.Table, ref: symbol.Ref, cut: Span, text: []u8, slot: Span) Error!Applied {
    const gpa = base.runtime.gpa;
    defer gpa.free(text);
    const next = try reparse(base, cut, text);
    errdefer next.destroy();
    const after = next.symbols() catch |err| switch (err) {
        error.SourceHasErrors => return error.MutationSyntaxInvalid,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const placed = after.item(ref) catch |err| return if (err == error.AmbiguousSymbol) error.SymbolExists else error.SymbolNameMismatch;
    if (placed.span.start != slot.start or placed.span.end != slot.end) return error.BodyEscape;
    if (placed.body) |body| try rejectPlaceholder(base.profile, body);
    const region: Span = .{ .start = cut.start, .end = cut.start + @as(u32, @intCast(text.len)) };
    try expectSameShape(base.tree, next.tree, cut, region);
    try expectUntouchedOutside(before, after.*, cut, slot);
    return .{ .snapshot = next, .hash = placed.hash, .body = slot, .hole = .{ .old = cut, .new = region } };
}

pub fn create(runtime: *Runtime, profile: *const Profile, insertion: Insertion) Error!Applied {
    const new_body = normalizeBody(insertion.new_body);
    const source = try std.mem.concat(runtime.gpa, u8, &.{ new_body, "\n" });
    const next = try Snapshot.fromSource(runtime, profile, source);
    errdefer next.destroy();
    const after = next.symbols() catch |err| switch (err) {
        error.SourceHasErrors => return error.MutationSyntaxInvalid,
        error.OutOfMemory => return error.OutOfMemory,
    };

    const slot: Span = .{ .start = 0, .end = @intCast(new_body.len) };
    const declared = try expectSoleDeclaration(profile, next.tree.root(), after.*, slot, insertion.ref);
    const none: Span = .{ .start = 0, .end = 0 };

    return .{ .snapshot = next, .hash = declared.hash, .body = slot, .hole = .{ .old = none, .new = .{ .start = 0, .end = @intCast(source.len) } } };
}

const Declared = struct {
    ref: symbol.Ref,
    hash: symbol.Hash,
    body: ?ts.Node,
};

fn expectSoleDeclaration(profile: *const Profile, root: ts.Node, table: symbol.Table, slot: Span, ref: symbol.Ref) Error!Declared {
    const statements = try topLevelStatementsIn(profile, root, slot);
    const declared = try soleTopLevelSymbol(table, slot, ref);
    if (statements != holdersIn(profile, root, table, slot)) return error.ExtraTopLevelCode;
    if (!declared.ref.eql(ref)) return error.SymbolNameMismatch;
    if (declared.body) |body| try rejectPlaceholder(profile, body);
    return declared;
}

fn lineEnding(source: []const u8) error{MissingTrailingNewline}![]const u8 {
    if (std.mem.endsWith(u8, source, "\r\n")) return "\r\n";
    if (std.mem.endsWith(u8, source, "\n")) return "\n";
    return error.MissingTrailingNewline;
}

fn topLevelStatementsIn(profile: *const Profile, root: ts.Node, slot: Span) error{BodyEscape}!usize {
    var count: usize = 0;
    var i: u32 = 0;
    while (root.child(i)) |node| : (i += 1) {
        if (node.startByte() < slot.start and node.endByte() > slot.start) return error.BodyEscape;
        if (node.startByte() < slot.start or node.startByte() >= slot.end) continue;
        if (node.endByte() > slot.end) return error.BodyEscape;
        if (!node.isNamed() or profile.isComment(node.kind())) continue;
        count += 1;
    }
    return count;
}

fn within(span: Span, region: Span) bool {
    return span.start >= region.start and span.start < region.end;
}

fn holds(table: symbol.Table, own: Span) bool {
    inline for (.{ table.symbols, table.declarations, table.statements }) |entries| {
        for (entries) |candidate| {
            if (within(candidate.declaration, own)) return true;
        }
    }
    return false;
}

fn holdersIn(profile: *const Profile, root: ts.Node, table: symbol.Table, slot: Span) usize {
    var count: usize = 0;
    var i: u32 = 0;
    while (root.child(i)) |node| : (i += 1) {
        if (node.startByte() < slot.start or node.startByte() >= slot.end) continue;
        if (!node.isNamed()) continue;
        if (profile.isComment(node.kind())) continue;
        if (holds(table, .{ .start = node.startByte(), .end = node.endByte() })) count += 1;
    }
    return count;
}

fn soleTopLevelSymbol(table: symbol.Table, slot: Span, ref: symbol.Ref) error{ NoTopLevelSymbol, SymbolExists }!Declared {
    var first: ?Declared = null;
    var named: ?Declared = null;
    inline for (.{ table.symbols, table.declarations, table.statements }) |list| {
        for (list) |candidate| {
            if (!within(candidate.declaration, slot)) continue;
            if (candidate.ambiguous) return error.SymbolExists;
            const found: Declared = .{ .ref = candidate.ref, .hash = candidate.hash, .body = if (@hasField(@TypeOf(candidate), "body")) candidate.body else null };
            if (first == null) first = found;
            if (candidate.ref.eql(ref)) {
                if (named != null) return error.SymbolExists;
                named = found;
            }
        }
    }
    return named orelse first orelse error.NoTopLevelSymbol;
}

fn expectExactSlot(profile: *const Profile, body: ts.Node, slot: Span) error{BodyEscape}!void {
    if (body.startByte() != slot.start or body.endByte() != slot.end) return error.BodyEscape;
    if (profile.isComment(edgeToken(body, .first).kind()) or profile.isComment(edgeToken(body, .last).kind())) return error.BodyEscape;
}

fn edgeToken(node: ts.Node, comptime side: enum { first, last }) ts.Node {
    var current = node;
    while (current.childCount() > 0) {
        current = current.child(if (side == .first) 0 else current.childCount() - 1).?;
    }
    return current;
}

pub fn rejectPlaceholder(profile: *const Profile, body: ts.Node) error{PlaceholderBody}!void {
    if (!std.mem.eql(u8, profile.block, body.kind())) return;
    var has_statement = false;
    var has_comment = false;
    var i: u32 = 0;
    while (body.child(i)) |node| : (i += 1) {
        if (profile.isComment(node.kind())) {
            has_comment = true;
        } else if (node.isNamed()) {
            has_statement = true;
        }
    }
    if (has_comment and !has_statement) return error.PlaceholderBody;
}

fn expectUntouchedOutside(before: symbol.Table, after: symbol.Table, cut: Span, slot: Span) error{BodyEscape}!void {
    var outside_before: usize = 0;
    for (before.symbols) |old| {
        if (!isOutside(old.declaration, cut)) continue;
        outside_before += 1;
        if (!hasTwinOutside(after, old, slot)) return error.BodyEscape;
    }
    var outside_after: usize = 0;
    for (after.symbols) |new| {
        if (isOutside(new.declaration, slot)) outside_after += 1;
    }
    if (outside_before != outside_after) return error.BodyEscape;
}

fn hasTwinOutside(table: symbol.Table, wanted: symbol.Symbol, slot: Span) bool {
    for (table.symbols) |candidate| {
        if (!isOutside(candidate.declaration, slot)) continue;
        if (candidate.ref.eql(wanted.ref) and std.mem.eql(u8, &candidate.hash, &wanted.hash)) return true;
    }
    return false;
}

fn isOutside(span: Span, region: Span) bool {
    return span.end <= region.start or span.start >= region.end;
}

const testing = std.testing;

const HashSource = enum { current, stale };

fn currentHash(snapshot: *Snapshot, ref: symbol.Ref) !symbol.Hash {
    return (try (try snapshot.symbols()).item(ref)).hash;
}

fn mutate(base: *Snapshot, ref_text: []const u8, new_body: []const u8, hash: HashSource) !Applied {
    const ref = try symbol.Ref.parse(testing.allocator, ref_text);
    defer ref.deinit(testing.allocator);
    const expected = switch (hash) {
        .current => currentHash(base, ref) catch std.mem.zeroes(symbol.Hash),
        .stale => symbol.hashOf("stale view"),
    };
    return apply(base, .{ .ref = ref, .expected_hash = expected, .new_body = new_body });
}

fn hashOfRef(snapshot: *Snapshot, ref_text: []const u8) !symbol.Hash {
    const ref = try symbol.Ref.parse(testing.allocator, ref_text);
    defer ref.deinit(testing.allocator);
    return currentHash(snapshot, ref);
}

test "replaces exactly one body in memory and leaves the file on disk untouched" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const doc = try test_util.loadFixture(runtime,"functions.ts");
    defer doc.destroy();

    const old_body = "{\n  return a + b;\n}";
    const new_body = "{\n  return a - b;\n}";
    const patched = try mutate(doc, "add", new_body, .current);
    defer patched.snapshot.destroy();
    const out = patched.snapshot.source;

    const at = std.mem.indexOf(u8, doc.source, old_body) orelse return error.FixtureChanged;
    try testing.expectEqualStrings(doc.source[0..at], out[0..at]);
    try testing.expectEqualStrings(new_body, out[at..][0..new_body.len]);
    try testing.expectEqualStrings(doc.source[at + old_body.len ..], out[at + new_body.len ..]);
    try testing.expect(!patched.snapshot.tree.root().hasError());
    try testing.expectEqual(try hashOfRef(patched.snapshot, "add"), patched.hash);

    const on_disk = try std.Io.Dir.cwd().readFileAlloc(testing.io, test_util.fixture_dir ++ "functions.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(doc.source, on_disk);
}

test "a source with syntax errors is refused before resolution" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const doc = try test_util.loadFixture(runtime,"broken.ts");
    defer doc.destroy();

    try testing.expectError(error.SourceHasErrors, mutate(doc, "broken", "{ return a; }", .current));

    const broken_sources = [_][]const u8{
        "export function broken(a: number {\n  return a;\n}\nfunction ok() { return 1; }\n",
        "function ok() { return 1; }\nfunction open() {\n  return 2;\n",
        "function ok() { return 1; }\nconst s = `unterminated ${ok()}\n",
        "function ok() { return (1; }\n",
        "function ok() { return 1; }}\n",
    };
    for (broken_sources) |source| {
        errdefer std.debug.print("accepted broken source: \"{s}\"\n", .{source});
        const base = try test_util.snapshotOf(runtime,source);
        defer base.destroy();
        try testing.expectError(error.SourceHasErrors, mutate(base, "ok", "{ return 2; }", .current));
    }
}

test "error precedence: each check wins over every later one" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const broken = try test_util.snapshotOf(runtime,"function ok() { return 1; }\nfunction bad( {\n");
    defer broken.destroy();
    const valid = try test_util.snapshotOf(runtime,"function dup() {}\nfunction dup() {}\nfunction f() { return 1; }\nfunction g() { return 2; }\n");
    defer valid.destroy();

    try testing.expectError(error.SourceHasErrors, mutate(broken, "missing", "{ oops", .stale));
    try testing.expectError(error.SymbolNotFound, mutate(valid, "missing", "{ oops", .stale));
    try testing.expectError(error.AmbiguousSymbol, mutate(valid, "dup", "{ oops", .stale));
    try testing.expectError(error.HashMismatch, mutate(valid, "f", "{ oops", .stale));
    try testing.expectError(error.MutationSyntaxInvalid, mutate(valid, "f", "{ } function evil() { oops", .current));
    try testing.expectError(error.BodyEscape, mutate(valid, "f", "{ } function evil() {}", .current));
}

test "unknown, under-qualified and ambiguous targets are refused" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime,
        \\function dup() {}
        \\function dup() {}
        \\class Box { get size(): number { return 1; } set size(v: number) {} }
    );
    defer base.destroy();

    try testing.expectError(error.AmbiguousSymbol, mutate(base, "dup", "{ return 1; }", .current));
    try testing.expectError(error.SymbolNotFound, mutate(base, "nope", "{}", .current));
    try testing.expectError(error.SymbolNotFound, mutate(base, "Box.size", "{ return 2; }", .current));
    try testing.expectError(error.SymbolNotFound, mutate(base, "Box.size@static@get", "{ return 2; }", .current));
}

test "a stale hash is refused, an unrelated edit elsewhere is not" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const original = try test_util.snapshotOf(runtime,"function f() { return 1; }\nfunction g() { return 2; }\n");
    defer original.destroy();
    const elsewhere = try test_util.snapshotOf(runtime,"function f() { return 1; }\nfunction g() { return 20; }\n");
    defer elsewhere.destroy();

    try testing.expectError(error.HashMismatch, mutate(original, "f", "{ return 3; }", .stale));

    const ref = try symbol.Ref.parse(testing.allocator, "f");
    defer ref.deinit(testing.allocator);
    const seen = try currentHash(original, ref);
    const patched = try apply(elsewhere, .{ .ref = ref, .expected_hash = seen, .new_body = "{ return 3; }" });
    defer patched.snapshot.destroy();
    try testing.expectEqualStrings("function f() { return 3; }\nfunction g() { return 20; }\n", patched.snapshot.source);
}

test "broken replacement bodies are refused and never spliced" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const doc = try test_util.loadFixture(runtime,"functions.ts");
    defer doc.destroy();

    const broken_bodies = [_][]const u8{
        "{ return a + ; }",
        "{\n  return a;\n",
        "return a;",
        "{ return a; }}",
        "{ return (a; }",
    };
    for (broken_bodies) |body| {
        errdefer std.debug.print("accepted broken body: \"{s}\"\n", .{body});
        try testing.expectError(error.MutationSyntaxInvalid, mutate(doc, "add", body, .current));
    }
}

test "a body that is only a placeholder comment is refused, but a real empty block is allowed" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const doc = try test_util.loadFixture(runtime, "functions.ts");
    defer doc.destroy();

    const placeholders = [_][]const u8{
        "{\n  // ...existing code...\n}",
        "{ /* keep the rest */ }",
        "{\n  // TODO\n  /* and more */\n}",
    };
    for (placeholders) |body| {
        errdefer std.debug.print("accepted placeholder body: \"{s}\"\n", .{body});
        try testing.expectError(error.PlaceholderBody, mutate(doc, "add", body, .current));
    }

    const empty = try mutate(doc, "add", "{}", .current);
    defer empty.snapshot.destroy();
    try testing.expect(std.mem.indexOf(u8, empty.snapshot.source, "): number {}") != null);

    const with_comment = try mutate(doc, "add", "{ return a + b; // keep\n}", .current);
    defer with_comment.snapshot.destroy();
    try testing.expect(std.mem.indexOf(u8, with_comment.snapshot.source, "return a + b; // keep") != null);
}

test "a body that parses but spills outside its slot is a BodyEscape" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime,"function f() { return 1; }\nfunction g() { return 2; }\n");
    defer base.destroy();

    const escapes = [_][]const u8{
        "{ } function evil() { return 0; }",
        "{ return 1; } // trailing",
        "{ return 1; } /* trailing */",
        "/* leading */ { return 1; }",
        "{ return 1; }\nfunction f() { return 3; }",
        "",
    };
    for (escapes) |body| {
        errdefer std.debug.print("accepted escaping body: \"{s}\"\n", .{body});
        try testing.expectError(error.BodyEscape, mutate(base, "f", body, .current));
    }
}

test "only the addressed accessor changes when getter and setter share a name" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const doc = try test_util.loadFixture(runtime,"functions.ts");
    defer doc.destroy();

    const getter_before = try hashOfRef(doc, "Repository.label@get");
    const setter_before = try hashOfRef(doc, "Repository.label@set");

    const patched = try mutate(doc, "Repository.label@set", "{\n    console.info(value);\n  }", .current);
    defer patched.snapshot.destroy();

    try testing.expectEqual(getter_before, try hashOfRef(patched.snapshot, "Repository.label@get"));
    try testing.expect(!std.mem.eql(u8, &setter_before, &patched.hash));
    try testing.expect(std.mem.indexOf(u8, patched.snapshot.source, "set label(value: string) {\n    console.info(value);\n  }") != null);
}

test "an expression-bodied arrow accepts an expression or a block" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime,"export const square = (n: number) => n * n;\n");
    defer base.destroy();

    const as_expression = try mutate(base, "square", "n ** 2", .current);
    defer as_expression.snapshot.destroy();
    try testing.expectEqualStrings("export const square = (n: number) => n ** 2;\n", as_expression.snapshot.source);

    const as_block = try mutate(base, "square", "{ return n * n; }", .current);
    defer as_block.snapshot.destroy();
    try testing.expectEqualStrings("export const square = (n: number) => { return n * n; };\n", as_block.snapshot.source);
}

test "outside-symbol lock rejects a renamed, re-hashed, added or removed neighbour" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const before_snapshot = try test_util.snapshotOf(runtime,"function f() { return 1; }\nfunction g() { return 2; }\n");
    defer before_snapshot.destroy();
    const before = try before_snapshot.symbols();
    const f_body = (try before.resolve(.{ .name = "f" })).body;
    const cut: Span = .{ .start = f_body.startByte(), .end = f_body.endByte() };

    const same_shape = [_][]const u8{
        "function f() { return 1; }\nfunction h() { return 2; }\n",
        "function f() { return 1; }\nfunction g() { return 3; }\n",
        "function f() { return 1; }\nfunction g() { return 2; }\nfunction extra() {}\n",
        "function f() { return 1; }\n",
    };
    for (same_shape) |source| {
        errdefer std.debug.print("lock accepted: \"{s}\"\n", .{source});
        const after_snapshot = try test_util.snapshotOf(runtime,source);
        defer after_snapshot.destroy();
        try testing.expectError(error.BodyEscape, expectUntouchedOutside(before.*, (try after_snapshot.symbols()).*, cut, cut));
    }

    try expectUntouchedOutside(before.*, before.*, cut, cut);
}

test "regression: attacks from the adversarial review stay refused" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);

    const Attack = struct {
        name: []const u8,
        source: []const u8,
        ref: []const u8,
        body: []const u8,
        expected: anyerror,
    };
    const arrow_source = "export const square = (n: number) => n * n;\nafter();\n";
    const class_source = "class C {\n  a() { return 1; }\n  b() { return 2; }\n}\n";
    const object_source = "const o = {\n  m() { return 1; },\n  n() { return 2; },\n};\n";
    const attacks = [_]Attack{
        .{ .name = "static injection into the next member", .source = class_source, .ref = "C.a", .body = "{ } static", .expected = error.BodyEscape },
        .{ .name = "extra property injected into an object literal", .source = object_source, .ref = "o.m", .body = "{ return 1; }, z() { return 3; }", .expected = error.BodyEscape },
        .{ .name = "statement smuggled after an arrow expression", .source = arrow_source, .ref = "square", .body = "n; evil()", .expected = error.BodyEscape },
        .{ .name = "comma expression appended to an arrow body", .source = arrow_source, .ref = "square", .body = "n * n, sideEffect()", .expected = error.MutationSyntaxInvalid },
        .{ .name = "U+2028 line separator after an arrow body", .source = arrow_source, .ref = "square", .body = "n * n\u{2028}", .expected = error.BodyEscape },
        .{ .name = "U+2029 paragraph separator after an arrow body", .source = arrow_source, .ref = "square", .body = "n * n\u{2029}", .expected = error.BodyEscape },
        .{ .name = "trailing block comment on an arrow body", .source = arrow_source, .ref = "square", .body = "n * n /* c */", .expected = error.BodyEscape },
        .{ .name = "NUL byte inside a block body", .source = class_source, .ref = "C.a", .body = "{ return 1;\x00 }", .expected = error.MutationSyntaxInvalid },
        .{ .name = "NUL byte after an arrow body", .source = arrow_source, .ref = "square", .body = "n * n\x00", .expected = error.MutationSyntaxInvalid },
    };
    for (attacks) |attack| {
        errdefer std.debug.print("attack not refused as expected: {s}\n", .{attack.name});
        const base = try test_util.snapshotOf(runtime,attack.source);
        defer base.destroy();
        try testing.expectError(attack.expected, mutate(base, attack.ref, attack.body, .current));
    }
}

test "replacement bodies are normalised: a BOM and surrounding whitespace are ignored" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime,"function f() { return 1; }\n");
    defer base.destroy();

    const bodies = [_][]const u8{
        "{ return 2; }\n",
        "\xEF\xBB\xBF{ return 2; }\r\n",
        "\n\t { return 2; }  \n\n",
    };
    for (bodies) |body| {
        errdefer std.debug.print("body not normalised: \"{s}\"\n", .{body});
        const patched = try mutate(base, "f", body, .current);
        defer patched.snapshot.destroy();
        try testing.expectEqualStrings("function f() { return 2; }\n", patched.snapshot.source);
    }
    try testing.expectError(error.BodyEscape, mutate(base, "f", " \r\n\t", .current));
}

test "a replacement body spliced into a CRLF file takes CRLF line endings, an LF file keeps the body as sent" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const crlf = try test_util.snapshotOf(runtime, "function f() {\r\n  return 1;\r\n}\r\n");
    defer crlf.destroy();
    const into_crlf = try mutate(crlf, "f", "{\n  return 2;\r\n}", .current);
    defer into_crlf.snapshot.destroy();
    try testing.expectEqualStrings("function f() {\r\n  return 2;\r\n}\r\n", into_crlf.snapshot.source);
    try testing.expectEqual(@as(u32, "{\r\n  return 2;\r\n}".len), into_crlf.body.end - into_crlf.body.start);

    const lf = try test_util.snapshotOf(runtime, "function f() {\n  return 1;\n}\n");
    defer lf.destroy();
    const into_lf = try mutate(lf, "f", "{\r\n  return 2;\n}", .current);
    defer into_lf.snapshot.destroy();
    try testing.expectEqualStrings("function f() {\r\n  return 2;\n}\n", into_lf.snapshot.source);
}

test "an inserted symbol follows a CRLF file's line ending inside its body too" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const applied = try insertInto(runtime, "function add() {\r\n  return 1;\r\n}\r\n", "f", "function f() {\n  return 1;\n}");
    defer applied.snapshot.destroy();
    try testing.expectEqualStrings("function add() {\r\n  return 1;\r\n}\r\n\r\nfunction f() {\r\n  return 1;\r\n}\r\n", applied.snapshot.source);
    try testing.expectEqualStrings("function f() {\r\n  return 1;\r\n}", applied.snapshot.source[applied.body.start..applied.body.end]);
    try testing.expectEqual(try hashOfRef(applied.snapshot, "f"), applied.hash);
}

test "mutating one declarator leaves a sibling declarator's hash intact" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime,"export const a = () => 1, b = () => 2;\n");
    defer base.destroy();

    const b_before = try hashOfRef(base, "b");
    const patched = try mutate(base, "a", "10", .current);
    defer patched.snapshot.destroy();
    try testing.expectEqualStrings("export const a = () => 10, b = () => 2;\n", patched.snapshot.source);
    try testing.expectEqual(b_before, try hashOfRef(patched.snapshot, "b"));
}

test "chained mutations: the returned hash is the next expected hash" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime,"function f() { return 1; }\n");
    defer base.destroy();

    const first = try mutate(base, "f", "{ return 2; }", .current);
    defer first.snapshot.destroy();

    const ref = try symbol.Ref.parse(testing.allocator, "f");
    defer ref.deinit(testing.allocator);
    const second = try apply(first.snapshot, .{ .ref = ref, .expected_hash = first.hash, .new_body = "{ return 3; }" });
    defer second.snapshot.destroy();
    try testing.expectEqualStrings("function f() { return 3; }\n", second.snapshot.source);

    try testing.expectError(error.HashMismatch, apply(second.snapshot, .{ .ref = ref, .expected_hash = first.hash, .new_body = "{ return 4; }" }));
}

test "ownership: every failed apply leaves exactly the base alive, a success adds one snapshot" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime,"function dup() {}\nfunction dup() {}\nfunction f() { return 1; }\n");
    defer base.destroy();

    const Failure = struct { ref: []const u8, body: []const u8, hash: HashSource };
    const failures = [_]Failure{
        .{ .ref = "nope", .body = "{}", .hash = .current },
        .{ .ref = "dup", .body = "{}", .hash = .current },
        .{ .ref = "f", .body = "{ return 2; }", .hash = .stale },
        .{ .ref = "f", .body = "{ return (2; }", .hash = .current },
        .{ .ref = "f", .body = "{ } function evil() {}", .hash = .current },
    };
    for (failures) |failure| {
        errdefer std.debug.print("leaked or freed a snapshot on: {s} {s}\n", .{ failure.ref, failure.body });
        try testing.expect(std.meta.isError(mutate(base, failure.ref, failure.body, failure.hash)));
        try testing.expectEqual(@as(usize, 1), runtime.live_snapshots);
    }

    const patched = try mutate(base, "f", "{ return 2; }", .current);
    try testing.expectEqual(@as(usize, 2), runtime.live_snapshots);
    patched.snapshot.destroy();
    try testing.expectEqual(@as(usize, 1), runtime.live_snapshots);
}

test "ownership: a patched snapshot owns its memory and outlives the base it came from" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime,"function f() { return 1; }\nfunction g() { return 2; }\n");
    const patched = try mutate(base, "f", "{ return 10; }", .current);
    base.destroy();
    defer patched.snapshot.destroy();

    try testing.expectEqualStrings("function f() { return 10; }\nfunction g() { return 2; }\n", patched.snapshot.source);
    try testing.expectEqual(patched.hash, try hashOfRef(patched.snapshot, "f"));
    const second = try mutate(patched.snapshot, "g", "{ return 20; }", .current);
    defer second.snapshot.destroy();
    try testing.expectEqualStrings("function f() { return 10; }\nfunction g() { return 20; }\n", second.snapshot.source);
}

fn insertInto(runtime: anytype, source: []const u8, ref_text: []const u8, body: []const u8) !Applied {
    const base = try test_util.snapshotOf(runtime, source);
    defer base.destroy();
    const ref = try symbol.Ref.parse(testing.allocator, ref_text);
    defer ref.deinit(testing.allocator);
    return insert(base, .{ .ref = ref, .new_body = body });
}

fn expectInserted(runtime: anytype, source: []const u8, ref_text: []const u8, body: []const u8, expected: []const u8) !void {
    const applied = try insertInto(runtime, source, ref_text, body);
    defer applied.snapshot.destroy();
    try testing.expectEqualStrings(expected, applied.snapshot.source);
    try testing.expectEqualStrings(normalizeBody(body), applied.snapshot.source[applied.body.start..applied.body.end]);
    try testing.expectEqual(try hashOfRef(applied.snapshot, ref_text), applied.hash);
}

test "propose replaces a body for a hex hash and inserts a symbol for absent" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime, "function add() { return 1; }\n");
    defer base.destroy();
    const add = try symbol.Ref.parse(testing.allocator, "add");
    defer add.deinit(testing.allocator);
    const sub = try symbol.Ref.parse(testing.allocator, "sub");
    defer sub.deinit(testing.allocator);
    const current = try currentHash(base, add);

    const replaced = try propose(base, add, .{ .present = current }, "{ return 2; }");
    defer replaced.snapshot.destroy();
    try testing.expectEqualStrings("function add() { return 2; }\n", replaced.snapshot.source);

    const inserted = try propose(base, sub, .absent, "function sub() { return 3; }");
    defer inserted.snapshot.destroy();
    try testing.expectEqualStrings("function add() { return 1; }\n\nfunction sub() { return 3; }\n", inserted.snapshot.source);

    try testing.expectError(error.SymbolExists, propose(base, add, .absent, "function add() { return 4; }"));
    try testing.expectError(error.SymbolNotFound, propose(base, sub, .{ .present = current }, "{ return 5; }"));
    try testing.expectError(error.HashMismatch, propose(base, add, .{ .present = symbol.hashOf("stale") }, "{ return 6; }"));
}

test "insert names the one top-level symbol the body declares, whatever its declaration form" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
    const cases = [_]struct { ref: []const u8, body: []const u8 }{
        .{ .ref = "sub", .body = "export function sub(a: number, b: number): number {\n  return a - b;\n}" },
        .{ .ref = "twice", .body = "function twice(x: number) { return x * 2; }" },
        .{ .ref = "neg", .body = "export const neg = (x: number) => -x;" },
        .{ .ref = "outer", .body = "function outer() {\n  function inner() { return 1; }\n  return inner();\n}" },
    };
    for (cases) |case| {
        errdefer std.debug.print("case {s}\n", .{case.ref});
        const expected = try std.mem.concat(testing.allocator, u8, &.{ base, "\n", case.body, "\n" });
        defer testing.allocator.free(expected);
        try expectInserted(runtime, base, case.ref, case.body, expected);
    }
}

test "insert refuses a body that declares no top-level symbol" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = "function add() { return 1; }\n";
    for ([_][]const u8{ "1 + 2;", "if (x) { y(); }" }) |body| {
        errdefer std.debug.print("accepted body: {s}\n", .{body});
        try testing.expectError(error.NoTopLevelSymbol, insertInto(runtime, base, "x", body));
    }
    try testing.expectError(error.SymbolNameMismatch, insertInto(runtime, base, "x", "foo();"));
}

test "insert and create accept a variable, class, interface, type alias or enum as the one new declaration" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = "function add() { return 1; }\n";
    const cases = [_]struct { ref: []const u8, body: []const u8 }{
        .{ .ref = "b", .body = "export const b = 2;" },
        .{ .ref = "C", .body = "class C {\n  m() { return 1; }\n}" },
        .{ .ref = "o", .body = "const o = { f() { return 1; } };" },
        .{ .ref = "Shape", .body = "export interface Shape {\n  area: number;\n}" },
        .{ .ref = "Id", .body = "type Id = string;" },
        .{ .ref = "Level", .body = "enum Level {\n  Low,\n}" },
    };
    for (cases) |case| {
        errdefer std.debug.print("refused body: {s}\n", .{case.body});
        const applied = try insertInto(runtime, base, case.ref, case.body);
        defer applied.snapshot.destroy();
        const table = try applied.snapshot.symbols();
        const ref = try symbol.Ref.parse(testing.allocator, case.ref);
        defer ref.deinit(testing.allocator);
        try testing.expect(table.declarationMatching(ref, applied.hash) != null);
        const created = try createWith(runtime, case.ref, case.body);
        created.snapshot.destroy();
    }
    try testing.expectError(error.SymbolExists, insertInto(runtime, "const b = 1;\n", "b", "const b = 2;"));
    const pair = try insertInto(runtime, base, "a", "const a = 1, b = 2;");
    pair.snapshot.destroy();
    try testing.expectError(error.SymbolNameMismatch, insertInto(runtime, base, "x", "const y = 1;"));
}

test "insert accepts a body of several top-level statements and hashes the one it names" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = "function add() { return 1; }\n";
    for ([_][]const u8{ "function a() { return 1; }\nfunction b() { return 2; }", "const a = () => 1, b = () => 2;", "const x = 1;\nfunction a() { return x; }" }) |body| {
        errdefer std.debug.print("refused body: {s}\n", .{body});
        const applied = try insertInto(runtime, base, "a", body);
        defer applied.snapshot.destroy();
        try testing.expectEqual(try hashOfRef(applied.snapshot, "a"), applied.hash);
    }
    try testing.expectError(error.SymbolExists, insertInto(runtime, base, "a", "function a() { return 1; }\nfunction add() { return 2; }"));
    try testing.expectError(error.SymbolExists, insertInto(runtime, base, "a", "function a() { return 1; }\nfunction a() { return 2; }"));
}

test "insert refuses top-level code beside the one symbol" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = "function add() { return 1; }\n";
    for ([_][]const u8{ "function f() { return 1; }\n1 + 2;", "function f() { return 1; };" }) |body| {
        errdefer std.debug.print("accepted body: {s}\n", .{body});
        try testing.expectError(error.ExtraTopLevelCode, insertInto(runtime, base, "f", body));
    }
    const applied = try insertInto(runtime, base, "f", "// helper\nfunction f() { return 1; }");
    applied.snapshot.destroy();
}

test "insert refuses a name that differs from the one the body declares" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = "function add() { return 1; }\n";
    try testing.expectError(error.SymbolNameMismatch, insertInto(runtime, base, "sub", "function subtract() { return 1; }"));
    try testing.expectError(error.SymbolNameMismatch, insertInto(runtime, base, "Math.sub", "function sub() { return 1; }"));
}

test "insert refuses a symbol that already exists, even as a duplicate" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    try testing.expectError(error.SymbolExists, insertInto(runtime, "function add() { return 1; }\n", "add", "function add() { return 2; }"));
    try testing.expectError(error.SymbolExists, insertInto(runtime, "function d() {}\nfunction d() {}\n", "d", "function d() { return 3; }"));
    try testing.expectError(error.SymbolExists, insertInto(runtime, "const v = 1;\n", "v", "function v() { return 2; }"));
    try testing.expectError(error.SymbolExists, insertInto(runtime, "let w = 1;\nlet w = 2;\n", "w", "function w() { return 3; }"));
}

test "insert refuses a file without a trailing newline and a body that does not parse" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    try testing.expectError(error.MissingTrailingNewline, insertInto(runtime, "function add() { return 1; }", "f", "function f() { return 1; }"));
    try testing.expectError(error.MissingTrailingNewline, insertInto(runtime, "", "f", "function f() { return 1; }"));
    try testing.expectError(error.MutationSyntaxInvalid, insertInto(runtime, "function add() { return 1; }\n", "f", "function f( { return 1; }"));
    try testing.expectError(error.PlaceholderBody, insertInto(runtime, "function add() { return 1; }\n", "f", "function f() {\n  // TODO\n}"));
}

test "insert refuses a body that fuses with the last statement of the file" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    try testing.expectError(error.BodyEscape, insertInto(runtime, "function add() { return 1; }\nconst g = add\n", "f", "(function f() { return 1; })"));
}

test "insert appends after the last newline with exactly one blank line added only when none is there" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const body = "function f() { return 1; }";
    try expectInserted(runtime, "function add() { return 1; }\n", "f", body, "function add() { return 1; }\n\nfunction f() { return 1; }\n");
    try expectInserted(runtime, "function add() { return 1; }\n\n", "f", body, "function add() { return 1; }\n\nfunction f() { return 1; }\n");
    try expectInserted(runtime, "function add() { return 1; }\n\n\n", "f", body, "function add() { return 1; }\n\nfunction f() { return 1; }\n");
    try expectInserted(runtime, "const a = 1;\n", "b", "const b = 2;", "const a = 1;\nconst b = 2;\n");
    try expectInserted(runtime, "import { a } from './a';\n\nfunction f() { return a; }\n", "b", "import { b } from './b';", "import { a } from './a';\nimport { b } from './b';\n\nfunction f() { return a; }\n");
}

test "insert follows a CRLF file's line ending and never rewrites the bytes already there" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const body = "function f() { return 1; }";
    try expectInserted(runtime, "function add() {\r\n  return 1;\r\n}\r\n", "f", body, "function add() {\r\n  return 1;\r\n}\r\n\r\nfunction f() { return 1; }\r\n");
    try expectInserted(runtime, "function add() {\r\n  return 1;\r\n}\r\n\r\n", "f", body, "function add() {\r\n  return 1;\r\n}\r\n\r\nfunction f() { return 1; }\r\n");
}

fn createWith(runtime: *Runtime, ref_text: []const u8, body: []const u8) !Applied {
    const ref = try symbol.Ref.parse(testing.allocator, ref_text);
    defer ref.deinit(testing.allocator);
    return create(runtime, test_util.language, .{ .ref = ref, .new_body = body });
}

test "create builds a file of exactly one top-level symbol and one trailing newline" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const created = try createWith(runtime, "mul", "\n  export function mul(a: number, b: number): number {\n  return a * b;\n}\n\n");
    defer created.snapshot.destroy();
    try testing.expectEqualStrings("export function mul(a: number, b: number): number {\n  return a * b;\n}\n", created.snapshot.source);
    try testing.expectEqual(try hashOfRef(created.snapshot, "mul"), created.hash);
    try testing.expectEqualStrings(normalizeBody("export function mul(a: number, b: number): number {\n  return a * b;\n}"), created.snapshot.source[created.body.start..created.body.end]);
}

test "create applies the same body rules as insert" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    try testing.expectError(error.NoTopLevelSymbol, createWith(runtime, "x", "1 + 2;"));
    try testing.expectError(error.SymbolExists, createWith(runtime, "a", "function a() { return 1; }\nfunction a() { return 2; }"));
    try testing.expectError(error.ExtraTopLevelCode, createWith(runtime, "f", "function f() { return 1; }\n1 + 2;"));
    try testing.expectError(error.SymbolNameMismatch, createWith(runtime, "g", "function f() { return 1; }"));
    try testing.expectError(error.PlaceholderBody, createWith(runtime, "f", "function f() {\n  // TODO\n}"));
    try testing.expectError(error.MutationSyntaxInvalid, createWith(runtime, "f", "function f( { return 1; }"));
}

fn replaceIn(runtime: anytype, source: []const u8, ext: []const u8, ref_text: []const u8, body: []const u8) ![]u8 {
    const base = try test_util.snapshotIn(runtime, source, ext);
    defer base.destroy();
    const applied = try mutate(base, ref_text, body, .current);
    defer applied.snapshot.destroy();
    try testing.expectEqual(try hashOfRef(applied.snapshot, ref_text), applied.hash);
    return testing.allocator.dupe(u8, applied.snapshot.source);
}

fn expectReplaced(runtime: anytype, source: []const u8, ext: []const u8, ref_text: []const u8, body: []const u8, expected: []const u8) !void {
    const got = try replaceIn(runtime, source, ext, ref_text, body);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "a whole top-level statement, binding, method or property is replaced by its ref without resending its neighbours" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const lib = "const { join } = require('path');\n\nclass Cart {\n  size() {\n    return 0;\n  }\n}\n\nmodule.exports = { Cart };\n";
    try expectReplaced(runtime, lib, ".js", "module.exports", "module.exports = { Cart, join };", "const { join } = require('path');\n\nclass Cart {\n  size() {\n    return 0;\n  }\n}\n\nmodule.exports = { Cart, join };\n");
    try expectReplaced(runtime, lib, ".js", "join", "const { join, resolve } = require('path');", "const { join, resolve } = require('path');\n\nclass Cart {\n  size() {\n    return 0;\n  }\n}\n\nmodule.exports = { Cart };\n");
    try expectReplaced(runtime, lib, ".js", "Cart.size", "size() {\n  return 1;\n}", "const { join } = require('path');\n\nclass Cart {\n  size() {\n    return 1;\n  }\n}\n\nmodule.exports = { Cart };\n");
    const rule = "module.exports = {\n  meta: {\n    type: 'problem',\n    schema: [],\n  },\n  create(context) {\n    return {};\n  },\n};\n";
    try expectReplaced(runtime, rule, ".js", "module.exports.meta.schema", "schema: [{ type: 'object' }],", "module.exports = {\n  meta: {\n    type: 'problem',\n    schema: [{ type: 'object' }],\n  },\n  create(context) {\n    return {};\n  },\n};\n");
    try expectReplaced(runtime, rule, ".js", "module.exports.create", "{\n    return { Program() {} };\n  }", "module.exports = {\n  meta: {\n    type: 'problem',\n    schema: [],\n  },\n  create(context) {\n    return { Program() {} };\n  },\n};\n");
    try expectReplaced(runtime, "export function f(): number { return 1; }\n", ".ts", "f", "function f(): number { return 2; }", "export function f(): number { return 2; }\n");
}

test "a replaced item that grows into its neighbour or changes its name is refused" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotIn(runtime, "module.exports = { a: 1 };\nfoo();\n", ".js");
    defer base.destroy();
    try testing.expectError(error.BodyEscape, mutate(base, "module.exports", "module.exports = { a: 2 };\nbar();", .current));
    try testing.expectError(error.BodyEscape, mutate(base, "module.exports", "exports.b = 1;", .current));
    try testing.expectError(error.HashMismatch, mutate(base, "module.exports", "module.exports = { a: 2 };", .stale));
}

test "a member is inserted after the last member of its class and nested properties keep their blank lines" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const source = "class Cart {\n  size() {\n    return 0;\n  }\n}\n";
    const base = try test_util.snapshotIn(runtime, source, ".js");
    defer base.destroy();
    const ref = try symbol.Ref.parse(testing.allocator, "Cart.clear");
    defer ref.deinit(testing.allocator);
    const applied = try insert(base, .{ .ref = ref, .new_body = "clear() {\n  return 1;\n}" });
    defer applied.snapshot.destroy();
    try testing.expectEqualStrings("class Cart {\n  size() {\n    return 0;\n  }\n\n  clear() {\n    return 1;\n  }\n}\n", applied.snapshot.source);
    try testing.expectEqual(try hashOfRef(applied.snapshot, "Cart.clear"), applied.hash);
    const inline_base = try test_util.snapshotIn(runtime, "class C { m() { return 1; } }\n", ".js");
    defer inline_base.destroy();
    const member = try symbol.Ref.parse(testing.allocator, "C.n");
    defer member.deinit(testing.allocator);
    const placed = try insert(inline_base, .{ .ref = member, .new_body = "n() { return 2; }" });
    defer placed.snapshot.destroy();
    try testing.expectEqualStrings("class C { m() { return 1; } n() { return 2; } }\n", placed.snapshot.source);
    const taken = try symbol.Ref.parse(testing.allocator, "Cart.size");
    defer taken.deinit(testing.allocator);
    try testing.expectError(error.SymbolExists, insert(base, .{ .ref = taken, .new_body = "size() { return 2; }" }));
}

test "a body sent back with its docs folded as read keeps the full docs, a dropped doc stays dropped" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const doc_text = "/**\n   * Inner helper. Returns one.\n   * @returns one\n   */";
    const source = "function outer() {\n  " ++ doc_text ++ "\n  function inner() { return 1; }\n  return inner();\n}\n";
    const doc = try test_util.snapshotOf(runtime, source);
    defer doc.destroy();
    const patched = try mutate(doc, "outer", "{\n  /** Inner helper. */\n  function inner() { return 1; }\n  return inner() + 1;\n}", .current);
    defer patched.snapshot.destroy();
    try testing.expectEqualStrings("function outer() {\n  " ++ doc_text ++ "\n  function inner() { return 1; }\n  return inner() + 1;\n}\n", patched.snapshot.source);
    const dropped = try mutate(doc, "outer", "{\n  function inner() { return 1; }\n  return inner();\n}", .current);
    defer dropped.snapshot.destroy();
    try testing.expect(std.mem.indexOf(u8, dropped.snapshot.source, "Inner helper") == null);
}
