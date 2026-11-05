const std = @import("std");
const ts = @import("../../tree_sitter.zig");
const scope = @import("../../scope.zig");
const symmetry = @import("../../symmetry.zig");
const rename = @import("../../rename.zig");
const Snapshot = @import("../../loader.zig").Snapshot;

pub fn isInert(snapshot: *const Snapshot, statement: ts.Node) bool {
    if (!symmetry.statementHasEffect(snapshot.profile, statement)) return true;
    const kind = statement.kind();
    if (eql(kind, "if_statement")) return inertIf(snapshot, statement);
    if (eql(kind, "try_statement")) return inertTry(snapshot, statement);
    if (eql(kind, "class_definition")) return inertClass(snapshot, statement);
    if (eql(kind, "decorated_definition")) {
        const definition = statement.childByField("definition") orelse return false;
        if (!eql(definition.kind(), "class_definition")) return false;
        return allDecorators(snapshot, statement, isDataclass) and inertClass(snapshot, definition);
    }
    return false;
}

fn inertIf(snapshot: *const Snapshot, statement: ts.Node) bool {
    const condition = statement.childByField("condition") orelse return false;
    if (isMainGuard(snapshot, condition)) return statement.childByField("alternative") == null;
    if (!isProvenCondition(snapshot, condition)) return false;
    if (!inertBlock(snapshot, statement.childByField("consequence"))) return false;
    var i: u32 = 0;
    while (statement.child(i)) |child| : (i += 1) {
        if (!eql(statement.fieldNameForChild(i) orelse "", "alternative")) continue;
        if (eql(child.kind(), "elif_clause")) {
            const clause = child.childByField("condition") orelse return false;
            if (!isProvenCondition(snapshot, clause)) return false;
            if (!inertBlock(snapshot, child.childByField("consequence"))) return false;
        } else if (!inertBlock(snapshot, child.childByField("body"))) return false;
    }
    return true;
}

fn isMainGuard(snapshot: *const Snapshot, condition: ts.Node) bool {
    if (!eql(condition.kind(), "comparison_operator") or condition.namedChildCount() != 2) return false;
    const left = condition.namedChild(0) orelse return false;
    const right = condition.namedChild(1) orelse return false;
    const op = condition.child(1) orelse return false;
    if (!eql(op.kind(), "==")) return false;
    if (!eql(left.kind(), "identifier") or !eql(textOf(snapshot, left), "__name__")) return false;
    const value = textOf(snapshot, right);
    if (!eql(value, "\"__main__\"") and !eql(value, "'__main__'")) return false;
    return isUnbound(snapshot, "__name__");
}

fn isProvenCondition(snapshot: *const Snapshot, condition: ts.Node) bool {
    const kind = condition.kind();
    if (eql(kind, "not_operator")) {
        const argument = condition.childByField("argument") orelse return false;
        return isProvenCondition(snapshot, argument);
    }
    if (eql(kind, "identifier")) return eql(textOf(snapshot, condition), "TYPE_CHECKING") and isFromImport(snapshot, "TYPE_CHECKING", "typing");
    if (eql(kind, "attribute")) return isModuleAttribute(snapshot, condition, "typing", "TYPE_CHECKING");
    if (!eql(kind, "comparison_operator") or condition.namedChildCount() != 2) return false;
    const left = condition.namedChild(0) orelse return false;
    const right = condition.namedChild(1) orelse return false;
    if (isModuleAttribute(snapshot, left, "sys", "version_info")) return isVersion(right);
    if (isModuleAttribute(snapshot, left, "sys", "platform")) return eql(right.kind(), "string") and !symmetry.hasEffect(snapshot.profile, right) and !hasKind(right, "interpolation");
    return false;
}

fn isVersion(node: ts.Node) bool {
    if (!eql(node.kind(), "tuple")) return false;
    var i: u32 = 0;
    while (node.namedChild(i)) |item| : (i += 1) {
        if (!eql(item.kind(), "integer")) return false;
    }
    return true;
}

fn inertTry(snapshot: *const Snapshot, statement: ts.Node) bool {
    var i: u32 = 0;
    while (statement.namedChild(i)) |child| : (i += 1) {
        const kind = child.kind();
        if (eql(kind, "block")) {
            if (!inertBlock(snapshot, child)) return false;
        } else if (eql(kind, "else_clause")) {
            if (!inertBlock(snapshot, child.childByField("body"))) return false;
        } else if (!inertClause(snapshot, child)) return false;
    }
    return true;
}

fn inertClause(snapshot: *const Snapshot, clause: ts.Node) bool {
    var i: u32 = 0;
    while (clause.namedChild(i)) |child| : (i += 1) {
        if (eql(child.kind(), "block")) {
            if (!inertBlock(snapshot, child)) return false;
        } else if (symmetry.hasEffect(snapshot.profile, child)) return false;
    }
    return true;
}

fn inertBlock(snapshot: *const Snapshot, block: ?ts.Node) bool {
    const body = block orelse return false;
    var i: u32 = 0;
    while (body.namedChild(i)) |statement| : (i += 1) {
        if (!isInert(snapshot, statement)) return false;
    }
    return true;
}

fn inertClass(snapshot: *const Snapshot, class: ts.Node) bool {
    if (class.childByField("superclasses")) |bases| {
        if (symmetry.hasEffect(snapshot.profile, bases)) return false;
    }
    const body = class.childByField("body") orelse return false;
    var i: u32 = 0;
    while (body.namedChild(i)) |member| : (i += 1) {
        const definition = if (eql(member.kind(), "decorated_definition")) member.childByField("definition") orelse return false else null;
        if (definition != null and eql(definition.?.kind(), "function_definition")) {
            if (symmetry.statementHasEffect(snapshot.profile, definition.?)) return false;
            if (!allDecorators(snapshot, member, isMethodDecorator)) return false;
        } else if (!isInert(snapshot, member)) return false;
    }
    return true;
}

fn allDecorators(snapshot: *const Snapshot, decorated: ts.Node, accepted: *const fn (*const Snapshot, ts.Node, ts.Node) bool) bool {
    var i: u32 = 0;
    while (decorated.namedChild(i)) |child| : (i += 1) {
        if (!eql(child.kind(), "decorator")) continue;
        const expression = child.namedChild(0) orelse return false;
        if (!accepted(snapshot, decorated, expression)) return false;
    }
    return true;
}

fn isDataclass(snapshot: *const Snapshot, decorated: ts.Node, expression: ts.Node) bool {
    _ = decorated;
    var callee = expression;
    if (eql(expression.kind(), "call")) {
        callee = expression.childByField("function") orelse return false;
        const arguments = expression.childByField("arguments") orelse return false;
        if (symmetry.hasEffect(snapshot.profile, arguments)) return false;
    }
    if (eql(callee.kind(), "identifier")) return eql(textOf(snapshot, callee), "dataclass") and isFromImport(snapshot, "dataclass", "dataclasses");
    return isModuleAttribute(snapshot, callee, "dataclasses", "dataclass");
}

fn isMethodDecorator(snapshot: *const Snapshot, decorated: ts.Node, expression: ts.Node) bool {
    if (eql(expression.kind(), "identifier")) {
        const name = textOf(snapshot, expression);
        if (!eql(name, "property") and !eql(name, "staticmethod") and !eql(name, "classmethod")) return false;
        return isUnbound(snapshot, name);
    }
    if (!eql(expression.kind(), "attribute")) return false;
    const object = expression.childByField("object") orelse return false;
    const attribute = expression.childByField("attribute") orelse return false;
    if (!eql(object.kind(), "identifier")) return false;
    const accessor = textOf(snapshot, attribute);
    if (!eql(accessor, "setter") and !eql(accessor, "getter") and !eql(accessor, "deleter")) return false;
    return followsProperty(snapshot, decorated, textOf(snapshot, object));
}

fn followsProperty(snapshot: *const Snapshot, decorated: ts.Node, name: []const u8) bool {
    var at = decorated.prevNamedSibling();
    while (at) |member| : (at = member.prevNamedSibling()) {
        if (!eql(member.kind(), "decorated_definition")) continue;
        const definition = member.childByField("definition") orelse continue;
        const own = definition.childByField("name") orelse continue;
        if (!eql(textOf(snapshot, own), name)) continue;
        var i: u32 = 0;
        while (member.namedChild(i)) |child| : (i += 1) {
            if (!eql(child.kind(), "decorator")) continue;
            const expression = child.namedChild(0) orelse continue;
            if (eql(expression.kind(), "identifier") and eql(textOf(snapshot, expression), "property")) return true;
        }
    }
    return false;
}

fn isModuleAttribute(snapshot: *const Snapshot, node: ts.Node, module: []const u8, name: []const u8) bool {
    if (!eql(node.kind(), "attribute")) return false;
    const object = node.childByField("object") orelse return false;
    const attribute = node.childByField("attribute") orelse return false;
    if (!eql(object.kind(), "identifier") or !eql(textOf(snapshot, object), module)) return false;
    if (!eql(textOf(snapshot, attribute), name)) return false;
    const leaf = soleBinder(snapshot, module) orelse return false;
    const dotted = leaf.parent() orelse return false;
    if (!eql(dotted.kind(), "dotted_name") or dotted.namedChildCount() != 1) return false;
    const statement = dotted.parent() orelse return false;
    return eql(statement.kind(), "import_statement");
}

fn isFromImport(snapshot: *const Snapshot, name: []const u8, module: []const u8) bool {
    const leaf = soleBinder(snapshot, name) orelse return false;
    const dotted = leaf.parent() orelse return false;
    if (!eql(dotted.kind(), "dotted_name")) return false;
    const statement = dotted.parent() orelse return false;
    const from = statement.childByField("module_name") orelse return false;
    return eql(textOf(snapshot, from), module);
}

fn soleBinder(snapshot: *const Snapshot, name: []const u8) ?ts.Node {
    const root = snapshot.tree.root();
    if (hasKind(root, "wildcard_import")) return null;
    const resolution = scope.resolveName(snapshot.runtime.gpa, snapshot, name) catch return null;
    defer resolution.deinit(snapshot.runtime.gpa);
    if (resolution.binders.len != 1) return null;
    return rename.leafAt(root, resolution.binders[0].span);
}

fn isUnbound(snapshot: *const Snapshot, name: []const u8) bool {
    if (hasKind(snapshot.tree.root(), "wildcard_import")) return false;
    const resolution = scope.resolveName(snapshot.runtime.gpa, snapshot, name) catch return false;
    defer resolution.deinit(snapshot.runtime.gpa);
    return resolution.binders.len == 0;
}

fn hasKind(node: ts.Node, kind: []const u8) bool {
    if (eql(node.kind(), kind)) return true;
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        if (hasKind(child, kind)) return true;
    }
    return false;
}

fn textOf(snapshot: *const Snapshot, node: ts.Node) []const u8 {
    return snapshot.source[node.startByte()..node.endByte()];
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
