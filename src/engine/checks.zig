const std = @import("std");
const ts = @import("tree_sitter.zig");
const traversal = @import("traversal.zig");
const symbol = @import("symbol.zig");
const profile_mod = @import("lang/profile.zig");
const Profile = profile_mod.Profile;
const isOneOf = @import("functions.zig").isOneOf;
const query = @import("query.zig");
const lang = @import("lang/registry.zig");
const text_checks = @import("text_checks.zig");
const regex = @import("regex.zig");

const Allocator = std.mem.Allocator;
const Span = symbol.Span;

pub const Violation = struct {
    check: []const u8,
    span: Span,
};

pub const Unrunnable = error{ QueryMalformed, QueryNotForLanguage } || query.RunError;

pub const CollectError = Unrunnable || Allocator.Error;

pub const Collect = *const fn (gpa: Allocator, profile: *const Profile, tree: ts.Tree, span: Span, arg: ?[]const u8, limits: query.Limits, out: *std.ArrayList(Violation)) CollectError!void;

pub const Check = struct {
    name: []const u8,
    collect: Collect,
    takes_argument: bool = false,
};

pub const registry = [_]Check{
    .{ .name = "no_comment", .collect = noComment },
    .{ .name = "forbid", .collect = forbid, .takes_argument = true },
    .{ .name = "no_literal", .collect = noLiteral, .takes_argument = true },
    .{ .name = query_name, .collect = queryCheck, .takes_argument = true },
    .{ .name = "forbid_regex", .collect = forbidRegex, .takes_argument = true },
    .{ .name = "require", .collect = require, .takes_argument = true },
    .{ .name = "require_comment", .collect = requireComment },
    .{ .name = "no_todo", .collect = noTodo },
    .{ .name = "max_function_lines", .collect = maxFunctionLines, .takes_argument = true },
    .{ .name = "forbid_import", .collect = forbidImport, .takes_argument = true },
};

/// Markers that `no_todo` forbids anywhere in the changed content (case-insensitive).
const todo_markers = [_][]const u8{ "TODO", "FIXME", "XXX" };

pub const query_name = "q";

pub const Error = error{ UnknownCheck, UnexpectedCheckArgument, MissingCheckArgument, EmptyCheckArgument, EmptyCommandCheck, CommandCheckTooLong, CommandCheckNotStatic } || query.CompileError || Unrunnable || Allocator.Error;

pub const command_prefix = "cmd:";
pub const max_command_bytes = 4 * 1024 - command_prefix.len;
const command_whitespace = " \t\r\n";

pub fn commandOf(spec: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, spec, command_prefix)) return null;
    return spec[command_prefix.len..];
}

pub fn messageCommandOf(spec: []const u8) ?[]const u8 {
    return commandOf(text_checks.of(spec) orelse return null);
}

pub fn validateCommand(command: []const u8) Error!void {
    if (std.mem.trim(u8, command, command_whitespace).len == 0) return error.EmptyCommandCheck;
    if (command.len > max_command_bytes) return error.CommandCheckTooLong;
}

pub const Invocation = struct {
    name: []const u8,
    arg: ?[]const u8,
};

pub fn parse(spec: []const u8) Invocation {
    const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return .{ .name = spec, .arg = null };
    return .{ .name = spec[0..colon], .arg = spec[colon + 1 ..] };
}

fn resolve(checks: []const Check, spec: []const u8) Error!struct { check: Check, arg: ?[]const u8 } {
    const invocation = parse(spec);
    const check = find(checks, invocation.name) orelse return error.UnknownCheck;
    if (check.takes_argument) {
        const arg = invocation.arg orelse return error.MissingCheckArgument;
        if (arg.len == 0) return error.EmptyCheckArgument;
    } else if (invocation.arg != null) {
        return error.UnexpectedCheckArgument;
    }
    return .{ .check = check, .arg = invocation.arg };
}

pub const added_prefix = "added:";
pub const frozen_name = "frozen";

pub fn isFrozen(spec: []const u8) bool {
    return std.mem.eql(u8, parse(spec).name, frozen_name);
}

pub fn addedOf(spec: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, spec, added_prefix)) return null;
    return spec[added_prefix.len..];
}

pub fn innerOf(spec: []const u8) []const u8 {
    return addedOf(spec) orelse spec;
}

pub fn validate(gpa: Allocator, spec: []const u8) Error!void {
    if (commandOf(spec)) |command| return validateCommand(command);
    return validateStatic(gpa, spec);
}

pub fn validateStatic(gpa: Allocator, spec: []const u8) Error!void {
    if (commandOf(spec) != null) return error.CommandCheckNotStatic;
    if (messageCommandOf(spec)) |command| return validateCommand(command);
    if (text_checks.of(spec)) |inner| return text_checks.validate(inner);
    if (addedOf(spec)) |inner| {
        if (commandOf(inner) != null) return error.CommandCheckNotStatic;
        if (addedOf(inner) != null) return error.UnknownCheck;
        if (text_checks.of(inner) != null) return error.UnknownCheck;
        if (isFrozen(inner)) return error.UnknownCheck;
        return validateStatic(gpa, inner);
    }
    if (isFrozen(spec)) {
        if (parse(spec).arg != null) return error.UnexpectedCheckArgument;
        return;
    }
    const resolved = try resolve(&registry, spec);
    if (std.mem.eql(u8, resolved.check.name, query_name)) {
        var results: [lang.profiles.len]Compiled = undefined;
        try compileEverywhere(gpa, resolved.arg.?, &results);
        try usable(&results);
    }
}

pub const Compiled = struct {
    profile: *const Profile,
    err: ?query.CompileError = null,
    diag: query.Diagnostic = .{},
};

pub fn compileEverywhere(gpa: Allocator, text: []const u8, results: *[lang.profiles.len]Compiled) Allocator.Error!void {
    for (lang.profiles, results) |profile, *result| {
        result.* = .{ .profile = profile };
        var compiled = query.compile(gpa, profile.grammar(), text, &result.diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => |e| {
                result.err = e;
                continue;
            },
        };
        compiled.deinit();
    }
}

pub fn usable(results: []const Compiled) query.CompileError!void {
    var any = false;
    for (results) |result| {
        const err = result.err orelse {
            any = true;
            continue;
        };
        if (!query.dependsOnLanguage(err)) return err;
    }
    if (!any) return results[0].err.?;
}

pub fn find(checks: []const Check, name: []const u8) ?Check {
    for (checks) |check| {
        if (std.mem.eql(u8, check.name, name)) return check;
    }
    return null;
}

pub fn run(gpa: Allocator, profile: *const Profile, tree: ts.Tree, span: Span, names: []const []const u8) Error![]Violation {
    return runWith(gpa, &registry, profile, tree, span, names, .{});
}

pub fn runLimited(gpa: Allocator, profile: *const Profile, tree: ts.Tree, span: Span, names: []const []const u8, limits: query.Limits) Error![]Violation {
    return runWith(gpa, &registry, profile, tree, span, names, limits);
}

pub fn runWith(gpa: Allocator, checks: []const Check, profile: *const Profile, tree: ts.Tree, span: Span, names: []const []const u8, limits: query.Limits) Error![]Violation {
    for (names) |name| _ = try resolve(checks, name);
    var out: std.ArrayList(Violation) = .empty;
    errdefer out.deinit(gpa);
    for (names) |name| {
        const resolved = try resolve(checks, name);
        try resolved.check.collect(gpa, profile, tree, span, resolved.arg, limits, &out);
    }
    return out.toOwnedSlice(gpa);
}

fn forbid(gpa: Allocator, profile: *const Profile, tree: ts.Tree, span: Span, arg: ?[]const u8, _: query.Limits, out: *std.ArrayList(Violation)) CollectError!void {
    _ = profile;
    const needle = arg orelse return;
    const body = tree.source[span.start..span.end];
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, body, from, needle)) |at| : (from = at + needle.len) {
        const start: u32 = span.start + @as(u32, @intCast(at));
        try out.append(gpa, .{ .check = "forbid", .span = .{ .start = start, .end = start + @as(u32, @intCast(needle.len)) } });
    }
}

fn noComment(gpa: Allocator, profile: *const Profile, tree: ts.Tree, span: Span, arg: ?[]const u8, _: query.Limits, out: *std.ArrayList(Violation)) CollectError!void {
    _ = arg;
    var walker = traversal.Walker.init(tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        if (node.endByte() <= span.start or node.startByte() >= span.end) {
            walker.skipChildren();
            continue;
        }
        if (isShebang(tree, node)) continue;
        if (profile.isComment(node.kind()) or isProseStatement(profile, tree, node)) {
            try out.append(gpa, .{ .check = "no_comment", .span = .{ .start = node.startByte(), .end = node.endByte() } });
        }
    }
}

fn noLiteral(gpa: Allocator, profile: *const Profile, tree: ts.Tree, span: Span, arg: ?[]const u8, _: query.Limits, out: *std.ArrayList(Violation)) CollectError!void {
    const name = arg orelse return;
    const shape = profile.literal_values;
    if (shape.pair.len == 0) return error.QueryNotForLanguage;
    var walker = traversal.Walker.init(tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        if (node.startByte() < span.start or node.endByte() > span.end) continue;
        if (isOneOf(node.kind(), shape.equals_pairs)) {
            try equalsPairs(gpa, shape, tree, node, name, out);
            continue;
        }
        const pair = literalPair(shape, node) orelse continue;
        if (!pair.bare_key and !isKind(pair.key, shape.quoted_key)) continue;
        if (!std.mem.eql(u8, keyName(shape, tree, pair.key), name)) continue;
        if (!isLiteral(shape, tree, pair.value)) continue;
        try out.append(gpa, .{ .check = "no_literal", .span = .{ .start = node.startByte(), .end = node.endByte() } });
    }
}

fn equalsPairs(gpa: Allocator, shape: profile_mod.LiteralValues, tree: ts.Tree, node: ts.Node, name: []const u8, out: *std.ArrayList(Violation)) CollectError!void {
    var i: u32 = 0;
    while (node.child(i)) |equals| : (i += 1) {
        if (equals.isNamed() or !isKind(equals, "=")) continue;
        const key = equals.prevNamedSibling() orelse continue;
        var at = i + 1;
        const value = while (node.child(at)) |next| : (at += 1) {
            if (next.isNamed()) break next;
        } else continue;
        if (!std.mem.eql(u8, tree.text(key), name) or !isLiteral(shape, tree, value)) continue;
        try out.append(gpa, .{ .check = "no_literal", .span = .{ .start = key.startByte(), .end = value.endByte() } });
    }
}

fn queryCheck(gpa: Allocator, profile: *const Profile, tree: ts.Tree, span: Span, arg: ?[]const u8, limits: query.Limits, out: *std.ArrayList(Violation)) CollectError!void {
    const text = arg orelse return;
    var compiled = query.compile(gpa, profile.grammar(), text, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| return if (query.dependsOnLanguage(e)) error.QueryNotForLanguage else error.QueryMalformed,
    };
    defer compiled.deinit();
    var found: std.ArrayList(Span) = .empty;
    defer found.deinit(gpa);
    try query.run(gpa, &compiled, tree, span, limits, &found);
    try out.ensureUnusedCapacity(gpa, found.items.len);
    for (found.items) |s| out.appendAssumeCapacity(.{ .check = query_name, .span = s });
}


// forbid_regex: the regex form of forbid. A match of the pattern anywhere in the
// changed span is a single violation spanning that span. Language-agnostic.
fn forbidRegex(gpa: Allocator, profile: *const Profile, tree: ts.Tree, span: Span, arg: ?[]const u8, limits: query.Limits, out: *std.ArrayList(Violation)) CollectError!void {
    _ = profile;
    const pattern = arg orelse return;
    const re = regex.Regex.compile(gpa, pattern, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A malformed or unsupported pattern cannot run against this input.
        error.RegexSyntax, error.RegexUnsupported => return error.QueryMalformed,
    };
    defer re.deinit(gpa);
    const body = tree.source[span.start..span.end];
    var budget: u64 = limits.operations;
    const hit = re.isMatch(gpa, body, &budget) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BudgetExceeded => return error.QueryBudgetExceeded,
    };
    if (hit) try out.append(gpa, .{ .check = "forbid_regex", .span = span });
}

// require: the changed span must contain the literal text. Its absence is one
// violation at the start of the span. The inverse of forbid. Language-agnostic.
fn require(gpa: Allocator, profile: *const Profile, tree: ts.Tree, span: Span, arg: ?[]const u8, _: query.Limits, out: *std.ArrayList(Violation)) CollectError!void {
    _ = profile;
    const needle = arg orelse return;
    const body = tree.source[span.start..span.end];
    if (std.mem.indexOf(u8, body, needle) == null) {
        try out.append(gpa, .{ .check = "require", .span = .{ .start = span.start, .end = span.start } });
    }
}

// no_todo: TODO / FIXME / XXX markers (case-insensitive) are forbidden in the
// changed content. Each occurrence is its own violation. Language-agnostic.
fn noTodo(gpa: Allocator, profile: *const Profile, tree: ts.Tree, span: Span, arg: ?[]const u8, _: query.Limits, out: *std.ArrayList(Violation)) CollectError!void {
    _ = profile;
    _ = arg;
    const body = tree.source[span.start..span.end];
    for (todo_markers) |marker| {
        var from: usize = 0;
        while (std.ascii.indexOfIgnoreCasePos(body, from, marker)) |at| : (from = at + marker.len) {
            const start: u32 = span.start + @as(u32, @intCast(at));
            try out.append(gpa, .{ .check = "no_todo", .span = .{ .start = start, .end = start + @as(u32, @intCast(marker.len)) } });
        }
    }
}

// require_comment: every named definition (function / method / class) in the
// scope must be immediately preceded by a comment. One without is a violation.
// Needs tree-sitter definition nodes: works for TS/JS/TSX (and any profile whose
// function/container node kinds are populated); never silently passes.
fn requireComment(gpa: Allocator, profile: *const Profile, tree: ts.Tree, span: Span, arg: ?[]const u8, _: query.Limits, out: *std.ArrayList(Violation)) CollectError!void {
    _ = arg;
    var walker = traversal.Walker.init(tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        if (node.endByte() <= span.start or node.startByte() >= span.end) {
            walker.skipChildren();
            continue;
        }
        if (node.startByte() < span.start or node.endByte() > span.end) continue;
        if (!isNamedDefinition(profile, node)) continue;
        if (precededByComment(profile, node) or hasDocstring(profile, node)) continue;
        try out.append(gpa, .{ .check = "require_comment", .span = .{ .start = node.startByte(), .end = node.endByte() } });
    }
}

// A named function/generator/method with a name, or a class declaration with one.
fn isNamedDefinition(profile: *const Profile, node: ts.Node) bool {
    if (isOneOf(node.kind(), profile.uncommented_definitions)) return false;
    if (isOneOf(node.kind(), profile.commented_definitions)) return node.childByField("name") != null;
    if (profile.functionKind(node.kind())) |kind| {
        switch (kind) {
            .declaration, .generator_declaration => return node.childByField("name") != null,
            .method => return node.childByField("name") != null or profile.functionName(node.kind()) != null,
            else => return false,
        }
    }
    // A class declaration is a container named from a field (not an object literal,
    // which is named from its binding).
    if (profile.containerName(node.kind())) |source| {
        if (source == .binding or profile.commented_definitions.len != 0) return false;
        if (std.mem.indexOf(u8, node.kind(), "class") == null) return false;
        return node.childByField("name") != null;
    }
    return false;
}

// Does a comment sit immediately before this definition (or its export wrapper)?
fn precededByComment(profile: *const Profile, node: ts.Node) bool {
    var anchor = node;
    if (anchor.prevNamedSibling()) |own| {
        if (profile.isComment(own.kind())) return true;
    }
    if (anchor.parent()) |parent| {
        if (isOneOf(parent.kind(), profile.export_wrappers) or isOneOf(parent.kind(), profile.definition_wrappers)) anchor = parent;
    }
    if (anchor.prevNamedSibling()) |previous| return profile.isComment(previous.kind());
    if (!profile.docstrings) return false;
    const block = anchor.parent() orelse return false;
    if (!isKind(block, profile.block)) return false;
    const before = block.prevNamedSibling() orelse return false;
    return profile.isComment(before.kind());
}

fn hasDocstring(profile: *const Profile, node: ts.Node) bool {
    if (!profile.docstrings) return false;
    const body = node.childByField("body") orelse return false;
    var i: u32 = 0;
    while (body.namedChild(i)) |statement| : (i += 1) {
        if (profile.isComment(statement.kind())) continue;
        return isStringStatement(profile, statement);
    }
    return false;
}

// max_function_lines:<n>: a function whose body spans more than n lines is a
// violation. Detects function nodes from the language profile (TS/JS/TSX; any
// profile with function node kinds). The body is the "body" field when present,
// otherwise the whole function node.
fn maxFunctionLines(gpa: Allocator, profile: *const Profile, tree: ts.Tree, span: Span, arg: ?[]const u8, _: query.Limits, out: *std.ArrayList(Violation)) CollectError!void {
    const text = arg orelse return;
    const limit = std.fmt.parseInt(usize, text, 10) catch return error.QueryMalformed;
    if (limit == 0) return error.QueryMalformed;
    var walker = traversal.Walker.init(tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        if (node.endByte() <= span.start or node.startByte() >= span.end) {
            walker.skipChildren();
            continue;
        }
        if (node.startByte() < span.start or node.endByte() > span.end) continue;
        if (profile.functionKind(node.kind()) == null) continue;
        const body = node.childByField("body") orelse node;
        const lines = std.mem.count(u8, tree.source[body.startByte()..body.endByte()], "\n") + 1;
        if (lines > limit) try out.append(gpa, .{ .check = "max_function_lines", .span = .{ .start = node.startByte(), .end = node.endByte() } });
    }
}

// forbid_import:<module>: importing the named module/package is a violation.
// Catches `import ... from 'module'`, bare `import 'module'`, `require('module')`
// and dynamic `import('module')`. Needs module syntax from the profile: works for
// TS/JS/TSX. A language without module support (e.g. Zig) is refused, not silently
// passed.
fn forbidImport(gpa: Allocator, profile: *const Profile, tree: ts.Tree, span: Span, arg: ?[]const u8, _: query.Limits, out: *std.ArrayList(Violation)) CollectError!void {
    const module = arg orelse return;
    const m = profile.modules orelse return error.QueryNotForLanguage;
    var walker = traversal.Walker.init(tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        if (node.endByte() <= span.start or node.startByte() >= span.end) {
            walker.skipChildren();
            continue;
        }
        if (node.startByte() < span.start or node.endByte() > span.end) continue;
        if (isKind(node, profile.import_forms.directive)) {
            if (directiveImportsModule(profile, tree, node, module)) {
                try out.append(gpa, .{ .check = "forbid_import", .span = .{ .start = node.startByte(), .end = node.endByte() } });
            }
        } else if (isKind(node, profile.call.node)) {
            if (callImportsModule(profile, tree, node, module)) {
                try out.append(gpa, .{ .check = "forbid_import", .span = .{ .start = node.startByte(), .end = node.endByte() } });
            }
        } else if (m.from_statement) |from_statement| {
            if (dottedImportNames(m, from_statement, tree, node, module)) {
                try out.append(gpa, .{ .check = "forbid_import", .span = .{ .start = node.startByte(), .end = node.endByte() } });
            }
        } else if (isKind(node, m.import_statement)) {
            const source = node.childByField(m.source_field) orelse continue;
            if (std.mem.eql(u8, unquote(tree.text(source)), module)) {
                try out.append(gpa, .{ .check = "forbid_import", .span = .{ .start = node.startByte(), .end = node.endByte() } });
            }
        }
    }
}

fn callImportsModule(profile: *const Profile, tree: ts.Tree, node: ts.Node, module: []const u8) bool {
    const callee = node.childByField(profile.call.function_field) orelse return false;
    if (!profile_mod.calleeIsOneOf(tree.text(callee), profile.import_forms.calls)) return false;
    const arguments = node.childByField(profile.call.arguments_field) orelse return false;
    const shape = profile.literal_values;
    var i: u32 = 0;
    while (arguments.namedChild(i)) |argument| : (i += 1) {
        if (profile.isComment(argument.kind())) continue;
        const named = isOneOf(argument.kind(), shape.named_arguments);
        const value = if (named) argumentValue(shape, argument) orelse continue else argument;
        if (namesModule(profile, tree, value, module)) return true;
        if (!named or argument.childByField(shape.named_argument_name_field) == null) return false;
    }
    return false;
}

fn argumentValue(shape: profile_mod.LiteralValues, argument: ts.Node) ?ts.Node {
    if (shape.named_argument_value_field.len != 0) return argument.childByField(shape.named_argument_value_field);
    const count = argument.namedChildCount();
    if (count == 0) return null;
    return argument.namedChild(count - 1);
}

fn namesModule(profile: *const Profile, tree: ts.Tree, value: ts.Node, module: []const u8) bool {
    if (!isOneOf(value.kind(), profile.strings) or hasStringHole(profile, value)) return false;
    const text = plainString(tree.text(value));
    if (!profile.import_forms.dotted) return std.mem.eql(u8, text, module);
    const end = std.mem.indexOfScalar(u8, text, ',') orelse text.len;
    return importsModule(std.mem.trim(u8, text[0..end], " "), module);
}

fn plainString(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len and (std.ascii.isAlphabetic(text[start]) or text[start] == '@' or text[start] == '$')) start += 1;
    const body = text[start..];
    if (body.len < 2) return body;
    const quote = body[0];
    if (quote != '"' and quote != '\'' and quote != '`') return text;
    return std.mem.trim(u8, body, body[0..1]);
}

fn hasStringHole(profile: *const Profile, value: ts.Node) bool {
    var i: u32 = 0;
    while (value.namedChild(i)) |part| : (i += 1) {
        if (isOneOf(part.kind(), profile.string_holes)) return true;
        if (isOneOf(part.kind(), profile.prose_strings) and hasStringHole(profile, part)) return true;
    }
    return false;
}

fn directiveImportsModule(profile: *const Profile, tree: ts.Tree, node: ts.Node, module: []const u8) bool {
    var i = node.namedChildCount();
    const target = while (i > 0) : (i -= 1) {
        const child = node.namedChild(i - 1) orelse continue;
        if (!profile.isComment(child.kind())) break child;
    } else return false;
    var text = tree.text(target);
    if (std.mem.indexOf(u8, text, "::")) |at| text = text[at + 2..];
    if (std.mem.indexOfScalar(u8, text, '<')) |at| text = text[0..at];
    return importsModule(std.mem.trim(u8, text, " "), module);
}

fn dottedImportNames(m: *const profile_mod.Modules, from_statement: []const u8, tree: ts.Tree, node: ts.Node, module: []const u8) bool {
    if (isKind(node, from_statement)) {
        const source = node.childByField(m.module_name_field) orelse return false;
        return importsModule(tree.text(source), module);
    }
    if (!isKind(node, m.import_statement)) return false;
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        const name = if (isKind(child, m.aliased_import)) child.childByField(m.name_field) orelse continue else child;
        if (isKind(name, m.dotted_name) and importsModule(tree.text(name), module)) return true;
    }
    return false;
}

fn importsModule(dotted: []const u8, module: []const u8) bool {
    if (!std.mem.startsWith(u8, dotted, module)) return false;
    return dotted.len == module.len or dotted[module.len] == '.';
}

fn unquote(text: []const u8) []const u8 {
    if (text.len < 2) return text;
    const quote = text[0];
    if ((quote == '"' or quote == '\'' or quote == '`') and text[text.len - 1] == quote) return text[1 .. text.len - 1];
    return text;
}

const LiteralPair = struct { key: ts.Node, value: ts.Node, bare_key: bool };

fn literalPair(shape: profile_mod.LiteralValues, node: ts.Node) ?LiteralPair {
    if (isKind(node, shape.pair)) {
        if (shape.pair_parent.len != 0 and !isKind(node.parent() orelse return null, shape.pair_parent)) return null;
        return .{ .key = node.childByField(shape.key_field) orelse return null, .value = node.childByField(shape.value_field) orelse return null, .bare_key = shape.bare_pair_key };
    }
    if (isOneOf(node.kind(), shape.named_arguments)) {
        return .{ .key = node.childByField(shape.named_argument_name_field) orelse return null, .value = argumentValue(shape, node) orelse return null, .bare_key = true };
    }
    if (shape.entry_pair.len != 0 and isKind(node, shape.entry_pair) and node.namedChildCount() == 2 and isKind(node.parent() orelse return null, shape.entry_pair)) {
        return .{ .key = node.namedChild(0).?, .value = node.namedChild(1).?, .bare_key = false };
    }
    return null;
}

fn keyName(shape: profile_mod.LiteralValues, tree: ts.Tree, indexed: ts.Node) []const u8 {
    var key = indexed;
    if (isKind(key, shape.indexed_key)) {
        while (!isKind(key, shape.quoted_key)) {
            if (key.namedChildCount() != 1) return "";
            key = key.namedChild(0).?;
        }
    }
    if (!isKind(key, shape.quoted_key)) return tree.text(key);
    if (shape.quoted_key_content.len != 0) return quotedContent(shape, tree, key);
    if (key.namedChildCount() != 1) return "";
    return tree.text(key.namedChild(0).?);
}

fn quotedContent(shape: profile_mod.LiteralValues, tree: ts.Tree, key: ts.Node) []const u8 {
    var found: ?ts.Node = null;
    var i: u32 = 0;
    while (key.namedChild(i)) |part| : (i += 1) {
        if (isKind(part, shape.substitution)) return "";
        if (isKind(part, shape.quoted_key_content)) found = part;
    }
    const content = found orelse return "";
    return tree.text(content);
}

fn isNegatedLiteral(shape: profile_mod.LiteralValues, tree: ts.Tree, value: ts.Node) bool {
    if (shape.negation_unary.len != 0) {
        if (!isKind(value, shape.negation_unary)) return false;
        const sign = value.child(0) orelse return false;
        const operand = value.namedChild(0) orelse return false;
        return std.mem.eql(u8, tree.text(sign), shape.negation_operator) and isOneOf(operand.kind(), shape.negatable);
    }
    const operator = value.childByField(shape.negation_operator_field) orelse return false;
    const argument = value.childByField(shape.negation_argument_field) orelse return false;
    return std.mem.eql(u8, tree.text(operator), shape.negation_operator) and isOneOf(argument.kind(), shape.negatable);
}

fn isLiteral(shape: profile_mod.LiteralValues, tree: ts.Tree, value: ts.Node) bool {
    if (isOneOf(value.kind(), shape.literals)) return true;
    if (isNegatedLiteral(shape, tree, value)) return true;
    if (!isKind(value, shape.template)) return false;
    var i: u32 = 0;
    while (value.namedChild(i)) |part| : (i += 1) {
        if (isKind(part, shape.substitution)) return false;
    }
    return true;
}

fn isShebang(tree: ts.Tree, node: ts.Node) bool {
    return node.startByte() == 0 and std.mem.startsWith(u8, tree.source, "#!") and node.endByte() <= (std.mem.indexOfScalar(u8, tree.source, '\n') orelse tree.source.len);
}

fn isProseStatement(profile: *const Profile, tree: ts.Tree, node: ts.Node) bool {
    if (!isStringStatement(profile, node)) return false;
    if (profile.docstrings and hasStringHole(profile, node)) return false;
    return !isDirective(profile, tree, node) and !isDocstring(profile, tree, node);
}

fn isDocstring(profile: *const Profile, tree: ts.Tree, statement: ts.Node) bool {
    if (!profile.docstrings) return false;
    const opening = tree.text(statement);
    if (opening.len != 0 and std.mem.indexOfScalar(u8, "fFbB", opening[0]) != null) return false;
    const parent = statement.parent() orelse return false;
    if (!isKind(parent, profile.root)) {
        if (!isKind(parent, profile.block)) return false;
        const owner = parent.parent() orelse return false;
        if (profile.functionKind(owner.kind()) == null and profile.containerName(owner.kind()) == null) return false;
    }
    var previous = statement.prevNamedSibling();
    while (previous) |sibling| : (previous = sibling.prevNamedSibling()) {
        if (!profile.isComment(sibling.kind())) return false;
    }
    return true;
}

fn isStringStatement(profile: *const Profile, node: ts.Node) bool {
    if (isOneOf(node.kind(), profile.prose_strings)) {
        const parent = node.parent() orelse return false;
        return isKind(parent, profile.block) or isKind(parent, profile.root);
    }
    if (!isKind(node, profile.expression_statement) or node.namedChildCount() != 1) return false;
    const expression = node.namedChild(0).?;
    return isOneOf(expression.kind(), profile.prose_strings);
}

fn isDirective(profile: *const Profile, tree: ts.Tree, node: ts.Node) bool {
    if (profile.directives.len == 0) return false;
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
        fn collect(gpa: Allocator, profile: *const Profile, tree: ts.Tree, s: Span, arg: ?[]const u8, _: query.Limits, out: *std.ArrayList(Violation)) CollectError!void {
            _ = arg;
            _ = gpa;
            _ = profile;
            _ = tree;
            _ = s;
            _ = out;
            ran += 1;
        }
    };
    const checks = [_]Check{.{ .name = "probe", .collect = Probe.collect }};
    try testing.expectError(error.UnknownCheck, runWith(testing.allocator, &checks, test_util.language, t.tree, span, &.{ "probe", "missing" }, .{}));
    try testing.expectEqual(@as(usize, 0), Probe.ran);
}

test "a new check joins by registration alone and runs in the requested order" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const source = "function f() { eval(\"1\"); /* c */ }\n";
    const t = try test_util.TestTree.init(source);
    defer t.deinit();

    const NoEval = struct {
        fn collect(gpa: Allocator, profile: *const Profile, tree: ts.Tree, span: Span, arg: ?[]const u8, _: query.Limits, out: *std.ArrayList(Violation)) CollectError!void {
            _ = arg;
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
    const violations = try runWith(testing.allocator, &checks, test_util.language, t.tree, wholeSource(source), &.{ "no_eval", "no_comment" }, .{});
    defer testing.allocator.free(violations);

    try testing.expectEqual(@as(usize, 2), violations.len);
    try testing.expectEqualStrings("no_eval", violations[0].check);
    try testing.expectEqualStrings("eval", source[violations[0].span.start..violations[0].span.end]);
    try testing.expectEqualStrings("no_comment", violations[1].check);
    try testing.expectEqualStrings("/* c */", source[violations[1].span.start..violations[1].span.end]);
}

fn runSpecs(source: []const u8, span: Span, specs: []const []const u8) ![]Violation {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const t = try test_util.TestTree.init(source);
    defer t.deinit();
    return run(testing.allocator, test_util.language, t.tree, span, specs);
}

fn expectForbidden(source: []const u8, span: Span, spec: []const u8, expected_starts: []const u32) !void {
    const violations = try runSpecs(source, span, &.{spec});
    defer testing.allocator.free(violations);
    const needle = parse(spec).arg.?;
    try testing.expectEqual(expected_starts.len, violations.len);
    for (violations, expected_starts) |v, start| {
        try testing.expectEqualStrings("forbid", v.check);
        try testing.expectEqual(start, v.span.start);
        try testing.expectEqual(start + @as(u32, @intCast(needle.len)), v.span.end);
        try testing.expectEqualStrings(needle, source[v.span.start..v.span.end]);
    }
}

test "a check spec splits at the first colon, and the argument may itself contain colons" {
    const bare = parse("no_comment");
    try testing.expectEqualStrings("no_comment", bare.name);
    try testing.expect(bare.arg == null);

    const with_arg = parse("forbid:console.log");
    try testing.expectEqualStrings("forbid", with_arg.name);
    try testing.expectEqualStrings("console.log", with_arg.arg.?);

    const colons = parse("forbid:a::b:");
    try testing.expectEqualStrings("forbid", colons.name);
    try testing.expectEqualStrings("a::b:", colons.arg.?);

    const empty = parse("forbid:");
    try testing.expectEqualStrings("forbid", empty.name);
    try testing.expectEqualStrings("", empty.arg.?);
}

test "argument misuse is refused with its own error before any check runs" {
    const source = "function f() { /* c */ }\n";
    const span = wholeSource(source);
    try testing.expectError(error.UnexpectedCheckArgument, runSpecs(source, span, &.{"no_comment:x"}));
    try testing.expectError(error.UnexpectedCheckArgument, runSpecs(source, span, &.{"no_comment:"}));
    try testing.expectError(error.MissingCheckArgument, runSpecs(source, span, &.{"forbid"}));
    try testing.expectError(error.EmptyCheckArgument, runSpecs(source, span, &.{"forbid:"}));
    try testing.expectError(error.UnknownCheck, runSpecs(source, span, &.{"no_such_check:x"}));
    try testing.expectError(error.MissingCheckArgument, runSpecs(source, span, &.{ "no_comment", "forbid" }));
}

test "forbid reports nothing when the text is absent or differs only in case" {
    const source = "function f() { return Eval(1); }\n";
    try expectForbidden(source, wholeSource(source), "forbid:eval", &.{});
    try expectForbidden(source, wholeSource(source), "forbid:TODO", &.{});
}

test "forbid reports one violation spanning exactly the matched text" {
    const source = "function f() { return eval(1); }\n";
    try expectForbidden(source, wholeSource(source), "forbid:eval", &.{22});
}

test "forbid reports every occurrence inside the span and none outside it" {
    const source = "const TODO = 1;\nfunction f() {\n  TODO(); x.TODO; // TODO\n}\nTODO;\n";
    const span = try spanOf(source, "{\n  TODO(); x.TODO; // TODO\n}");
    const first: u32 = @intCast(std.mem.indexOf(u8, source, "TODO();").?);
    const second: u32 = @intCast(std.mem.indexOf(u8, source, "TODO;").?);
    const third: u32 = @intCast(std.mem.indexOf(u8, source, "TODO\n}").?);
    try expectForbidden(source, span, "forbid:TODO", &.{ first, second, third });
}

test "forbid deliberately does not count overlapping occurrences: aaa holds one aa" {
    const source = "function f() { aaa; }\n";
    const first: u32 = @intCast(std.mem.indexOf(u8, source, "aaa").?);
    try expectForbidden(source, wholeSource(source), "forbid:aa", &.{first});
}

test "forbid matches an argument that contains colons" {
    const source = "function f() { return a ? b::c : d; }\n";
    try expectForbidden(source, wholeSource(source), "forbid:b::c", &.{@intCast(std.mem.indexOf(u8, source, "b::c").?)});
}

fn literalTexts(source: []const u8, span: Span, spec: []const u8) ![][]const u8 {
    const violations = try runSpecs(source, span, &.{spec});
    defer testing.allocator.free(violations);
    const texts = try testing.allocator.alloc([]const u8, violations.len);
    for (violations, texts) |v, *text| {
        try testing.expectEqualStrings("no_literal", v.check);
        text.* = source[v.span.start..v.span.end];
    }
    return texts;
}

fn expectLiterals(source: []const u8, expected: []const []const u8) !void {
    const texts = try literalTexts(source, wholeSource(source), "no_literal:timeout");
    defer testing.allocator.free(texts);
    errdefer for (texts) |text| std.debug.print("flagged: {s}\n", .{text});
    try testing.expectEqual(expected.len, texts.len);
    for (expected, texts) |want, got| try testing.expectEqualStrings(want, got);
}

test "no_literal flags a number, a string and a plain template passed as the named option" {
    try expectLiterals("page.goto(u, { timeout: 30000 });\n", &.{"timeout: 30000"});
    try expectLiterals("run({ timeout: \"30s\" });\n", &.{"timeout: \"30s\""});
    try expectLiterals("run({ timeout: `30s` });\n", &.{"timeout: `30s`"});
}

test "no_literal matches a quoted key but not a computed one" {
    try expectLiterals("run({ \"timeout\": 30000, 'timeout': 5 });\n", &.{ "\"timeout\": 30000", "'timeout': 5" });
    try expectLiterals("run({ [timeout]: 5, \"timeouts\": 5, \"\": 5, \"timeout\\n\": 5 });\n", &.{});
}

test "no_literal counts a negated number as a literal but not other unary values" {
    try expectLiterals("run({ timeout: -5 });\n", &.{"timeout: -5"});
    try expectLiterals("run({ timeout: +5, timeout: -ms, timeout: -\"5\", timeout: !0 });\n", &.{});
}

test "no_literal leaves budgeted, named, computed and shorthand values alone" {
    try expectLiterals("page.goto(u, { timeout: budget(timeoutMs) });\n", &.{});
    try expectLiterals("page.goto(u, { timeout: budget(p, { reserveMs: R }) });\n", &.{});
    try expectLiterals("page.goto(u, { timeout: navTimeout });\n", &.{});
    try expectLiterals("wait({ timeout: Math.max(2, Math.round(x)) });\n", &.{});
    try expectLiterals("wait({ timeout: cfg.timeout, other: a + 1 });\n", &.{});
    try expectLiterals("wait({ timeout: `${ms}ms` });\n", &.{});
    try expectLiterals("wait({ timeout });\n", &.{});
    try expectLiterals("wait({ timeout: true, timeout2: 5, delay: 5 });\n", &.{});
}

test "no_literal finds the option inside a nested object and spans exactly the pair" {
    const source = "run({ a: { timeout: 5 } });\n";
    const violations = try runSpecs(source, wholeSource(source), &.{"no_literal:timeout"});
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    const start: u32 = @intCast(std.mem.indexOf(u8, source, "timeout").?);
    try testing.expectEqual(start, violations[0].span.start);
    try testing.expectEqual(start + @as(u32, @intCast("timeout: 5".len)), violations[0].span.end);
}

test "no_literal reports only pairs inside the span" {
    const source = "run({ timeout: 1 });\nfunction f() {\n  run({ timeout: 2 });\n}\n";
    const texts = try literalTexts(source, try spanOf(source, "{\n  run({ timeout: 2 });\n}"), "no_literal:timeout");
    defer testing.allocator.free(texts);
    try testing.expectEqual(@as(usize, 1), texts.len);
    try testing.expectEqualStrings("timeout: 2", texts[0]);

    const cut = try literalTexts(source, try spanOf(source, "1 });\nfunction"), "no_literal:timeout");
    defer testing.allocator.free(cut);
    try testing.expectEqual(@as(usize, 0), cut.len);
}

test "no_literal refuses a missing or empty argument" {
    const source = "run({ timeout: 1 });\n";
    try testing.expectError(error.MissingCheckArgument, runSpecs(source, wholeSource(source), &.{"no_literal"}));
    try testing.expectError(error.EmptyCheckArgument, runSpecs(source, wholeSource(source), &.{"no_literal:"}));
}

test "only a cmd: prefix names a command predicate, and every other spec stays a registry lookup" {
    try testing.expect(commandOf("cmd:npx eslint --rule no-console") != null);
    try testing.expectEqualStrings("npx eslint --rule no-console", commandOf("cmd:npx eslint --rule no-console").?);
    try testing.expectEqualStrings(" ", commandOf("cmd: ").?);
    try testing.expect(commandOf("no_comment") == null);
    try testing.expect(commandOf("forbid:cmd:x") == null);
    try testing.expect(commandOf("Cmd:x") == null);
    try testing.expect(commandOf("cmd") == null);
    try testing.expect(commandOf("xcmd:x") == null);
}

test "a message command is a command behind the message prefix, validated for shape and never looked up as a text check" {
    try testing.expectEqualStrings("npx commitlint", messageCommandOf("message:cmd:npx commitlint").?);
    try testing.expect(messageCommandOf("cmd:npx commitlint") == null);
    try testing.expect(messageCommandOf("message:forbid:cmd:x") == null);
    try testing.expect(messageCommandOf("added:message:cmd:x") == null);
    try validate(testing.allocator, "message:cmd:npx commitlint");
    try validateStatic(testing.allocator, "message:cmd:npx commitlint");
    try testing.expectError(error.EmptyCommandCheck, validate(testing.allocator, "message:cmd: "));
    try testing.expectError(error.CommandCheckTooLong, validate(testing.allocator, "message:cmd:" ++ "a" ** (max_command_bytes + 1)));
    try testing.expectError(error.UnknownCheck, validate(testing.allocator, "added:message:cmd:x"));
}

test "an unknown check name is still refused instead of being run as a command" {
    try testing.expectError(error.UnknownCheck, validate(testing.allocator, "npx eslint"));
    try testing.expectError(error.UnknownCheck, validate(testing.allocator, "eslint:--rule"));
    try testing.expectError(error.UnknownCheck, validate(testing.allocator, "frbid:x"));
}

test "a command check is validated for shape without being run, and the ast path refuses it outright" {
    try validate(testing.allocator, "cmd:npx eslint --rule no-console");
    try validate(testing.allocator, "cmd:./scripts/no-raw-sql.sh");
    try testing.expectError(error.EmptyCommandCheck, validate(testing.allocator, "cmd:"));
    try testing.expectError(error.EmptyCommandCheck, validate(testing.allocator, "cmd:   "));
    try testing.expectError(error.EmptyCommandCheck, validate(testing.allocator, "cmd:\t\r\n"));

    const long = "cmd:" ++ ("x" ** (max_command_bytes + 1));
    try testing.expectError(error.CommandCheckTooLong, validate(testing.allocator, long));
    const at_limit = "cmd:" ++ ("x" ** max_command_bytes);
    try validate(testing.allocator, at_limit);

    const source = "function f() { /* c */ }\n";
    try testing.expectError(error.UnknownCheck, runSpecs(source, wholeSource(source), &.{"cmd:exit 0"}));
    try testing.expectError(error.UnknownCheck, runSpecs(source, wholeSource(source), &.{ "no_comment", "cmd:exit 0" }));
}

test "a static-only caller refuses a command check by its own name" {
    try validateStatic(testing.allocator, "no_comment");
    try validateStatic(testing.allocator, "forbid:x");
    try testing.expectError(error.CommandCheckNotStatic, validateStatic(testing.allocator, "cmd:exit 0"));
    try testing.expectError(error.CommandCheckNotStatic, validateStatic(testing.allocator, "cmd:"));
    try testing.expectError(error.UnknownCheck, validateStatic(testing.allocator, "frbid:x"));
    try validateStatic(testing.allocator, "added:no_comment");
    try validateStatic(testing.allocator, "added:forbid:x");
    try testing.expectError(error.CommandCheckNotStatic, validateStatic(testing.allocator, "added:cmd:exit 0"));
    try testing.expectError(error.UnknownCheck, validateStatic(testing.allocator, "added:added:no_comment"));
    try testing.expectError(error.UnknownCheck, validateStatic(testing.allocator, "added:frbid:x"));
    try testing.expectEqualStrings("forbid:x", innerOf("added:forbid:x"));
    try testing.expectEqualStrings("forbid:x", innerOf("forbid:x"));
}

fn expectCheck(v: []const Violation, name: []const u8) !void {
    for (v) |hit| try testing.expectEqualStrings(name, hit.check);
}

test "forbid_regex flags a span that matches the pattern and passes one that does not" {
    const dirty = "function f() { const n = 1234; }\n";
    const v = try runSpecs(dirty, wholeSource(dirty), &.{"forbid_regex:[0-9]+"});
    defer testing.allocator.free(v);
    try testing.expectEqual(@as(usize, 1), v.len);
    try expectCheck(v, "forbid_regex");
    try testing.expectEqual(@as(u32, 0), v[0].span.start);
    try testing.expectEqual(@as(u32, dirty.len), v[0].span.end);

    const clean = "function f() { const s = x; }\n";
    const c = try runSpecs(clean, wholeSource(clean), &.{"forbid_regex:[0-9]+"});
    defer testing.allocator.free(c);
    try testing.expectEqual(@as(usize, 0), c.len);
}

test "forbid_regex scans only the changed span and refuses a malformed pattern" {
    const source = "const n = 99;\nfunction f() { return x; }\n";
    const v = try runSpecs(source, try spanOf(source, "{ return x; }"), &.{"forbid_regex:[0-9]+"});
    defer testing.allocator.free(v);
    try testing.expectEqual(@as(usize, 0), v.len);

    try testing.expectError(error.QueryMalformed, runSpecs("const x = 1;\n", wholeSource("const x = 1;\n"), &.{"forbid_regex:(unclosed"}));
}

test "require flags a span missing the literal and passes one that holds it" {
    const lacks = "function f() { return 1; }\n";
    const v = try runSpecs(lacks, wholeSource(lacks), &.{"require:Copyright"});
    defer testing.allocator.free(v);
    try testing.expectEqual(@as(usize, 1), v.len);
    try expectCheck(v, "require");
    try testing.expectEqual(@as(u32, 0), v[0].span.start);
    try testing.expectEqual(@as(u32, 0), v[0].span.end);

    const has = "// Copyright ACME\nfunction f() { return 1; }\n";
    const c = try runSpecs(has, wholeSource(has), &.{"require:Copyright"});
    defer testing.allocator.free(c);
    try testing.expectEqual(@as(usize, 0), c.len);
}

test "no_todo flags TODO, FIXME and XXX in any case and passes clean content" {
    const dirty = "function f() {\n  // todo later\n  g(); // FIXME\n  return 1; // XXX\n}\n";
    const v = try runSpecs(dirty, wholeSource(dirty), &.{"no_todo"});
    defer testing.allocator.free(v);
    try testing.expectEqual(@as(usize, 3), v.len);
    try expectCheck(v, "no_todo");

    const clean = "function f() { return 1; }\n";
    const c = try runSpecs(clean, wholeSource(clean), &.{"no_todo"});
    defer testing.allocator.free(c);
    try testing.expectEqual(@as(usize, 0), c.len);
}

test "require_comment flags an undocumented definition and passes a documented one" {
    const bare = "function f() { return 1; }\n";
    const v = try runSpecs(bare, wholeSource(bare), &.{"require_comment"});
    defer testing.allocator.free(v);
    try testing.expectEqual(@as(usize, 1), v.len);
    try expectCheck(v, "require_comment");

    const doc = "// does a thing\nfunction f() { return 1; }\n";
    const d = try runSpecs(doc, wholeSource(doc), &.{"require_comment"});
    defer testing.allocator.free(d);
    try testing.expectEqual(@as(usize, 0), d.len);
}

test "require_comment sees through an export wrapper and judges methods and classes" {
    const exported = "// c\nexport function f() { return 1; }\n";
    const e = try runSpecs(exported, wholeSource(exported), &.{"require_comment"});
    defer testing.allocator.free(e);
    try testing.expectEqual(@as(usize, 0), e.len);

    // The class has no comment (one violation); its method does (no violation).
    const mixed = "class C {\n  // m\n  m() { return 1; }\n}\n";
    const v = try runSpecs(mixed, wholeSource(mixed), &.{"require_comment"});
    defer testing.allocator.free(v);
    try testing.expectEqual(@as(usize, 1), v.len);
    try testing.expectEqualStrings("class", mixed[v[0].span.start .. v[0].span.start + 5]);
}

test "max_function_lines flags a body over the limit and passes one within it" {
    const long = "function f() {\n  a;\n  b;\n  c;\n}\n";
    const v = try runSpecs(long, wholeSource(long), &.{"max_function_lines:3"});
    defer testing.allocator.free(v);
    try testing.expectEqual(@as(usize, 1), v.len);
    try expectCheck(v, "max_function_lines");

    const short = "function f() {\n  a;\n}\n";
    const s = try runSpecs(short, wholeSource(short), &.{"max_function_lines:3"});
    defer testing.allocator.free(s);
    try testing.expectEqual(@as(usize, 0), s.len);
}

test "max_function_lines refuses a non-numeric or zero limit" {
    const source = "function f() { return 1; }\n";
    try testing.expectError(error.QueryMalformed, runSpecs(source, wholeSource(source), &.{"max_function_lines:x"}));
    try testing.expectError(error.QueryMalformed, runSpecs(source, wholeSource(source), &.{"max_function_lines:0"}));
}

test "forbid_import flags an import, a require and a dynamic import of the named module" {
    const es = "import { x } from \"lodash\";\n";
    const a = try runSpecs(es, wholeSource(es), &.{"forbid_import:lodash"});
    defer testing.allocator.free(a);
    try testing.expectEqual(@as(usize, 1), a.len);
    try expectCheck(a, "forbid_import");

    const req = "const x = require(\"lodash\");\n";
    const b = try runSpecs(req, wholeSource(req), &.{"forbid_import:lodash"});
    defer testing.allocator.free(b);
    try testing.expectEqual(@as(usize, 1), b.len);

    const dyn = "async function f() { await import(\"lodash\"); }\n";
    const c = try runSpecs(dyn, wholeSource(dyn), &.{"forbid_import:lodash"});
    defer testing.allocator.free(c);
    try testing.expectEqual(@as(usize, 1), c.len);
}

test "forbid_import ignores a different module and a bare matching string" {
    const other = "import { x } from \"ramda\";\nconst s = \"lodash\";\n";
    const v = try runSpecs(other, wholeSource(other), &.{"forbid_import:lodash"});
    defer testing.allocator.free(v);
    try testing.expectEqual(@as(usize, 0), v.len);
}

fn runPython(source: []const u8, specs: []const []const u8) ![]Violation {
    return runIn(&@import("lang/python/profile.zig").profile, source, specs);
}

fn runIn(profile: *const Profile, source: []const u8, specs: []const []const u8) ![]Violation {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try ts.Parser.init(profile.grammar());
    defer parser.deinit();
    const tree = try parser.parse(source);
    defer tree.deinit();
    return run(testing.allocator, profile, tree, .{ .start = 0, .end = @intCast(source.len) }, specs);
}

test "python: no_comment flags a # comment, forbid flags a print call, require_comment and max_function_lines apply to defs" {
    const documented = "# a greeter\ndef greet(name):\n    print(name)\n";
    const nc = try runPython(documented, &.{"no_comment"});
    defer testing.allocator.free(nc);
    try testing.expectEqual(@as(usize, 1), nc.len);
    try testing.expectEqualStrings("no_comment", nc[0].check);
    try testing.expectEqualStrings("# a greeter", documented[nc[0].span.start..nc[0].span.end]);

    const fb = try runPython(documented, &.{"forbid:print"});
    defer testing.allocator.free(fb);
    try testing.expectEqual(@as(usize, 1), fb.len);
    try testing.expectEqualStrings("print", documented[fb[0].span.start..fb[0].span.end]);

    const rc_ok = try runPython(documented, &.{"require_comment"});
    defer testing.allocator.free(rc_ok);
    try testing.expectEqual(@as(usize, 0), rc_ok.len);

    const bare = "def greet(name):\n    print(name)\n";
    const rc_bad = try runPython(bare, &.{"require_comment"});
    defer testing.allocator.free(rc_bad);
    try testing.expectEqual(@as(usize, 1), rc_bad.len);
    try testing.expectEqualStrings("require_comment", rc_bad[0].check);

    const long = "def f():\n    a = 1\n    b = 2\n    c = 3\n    return a\n";
    const mfl = try runPython(long, &.{"max_function_lines:2"});
    defer testing.allocator.free(mfl);
    try testing.expectEqual(@as(usize, 1), mfl.len);
    try testing.expectEqualStrings("max_function_lines", mfl[0].check);

    const mfl_ok = try runPython(long, &.{"max_function_lines:10"});
    defer testing.allocator.free(mfl_ok);
    try testing.expectEqual(@as(usize, 0), mfl_ok.len);
}

fn expectPythonLiterals(source: []const u8, expected: []const []const u8) !void {
    const violations = try runPython(source, &.{"no_literal:timeout"});
    defer testing.allocator.free(violations);
    errdefer for (violations) |v| std.debug.print("flagged: {s}\n", .{source[v.span.start..v.span.end]});
    try testing.expectEqual(expected.len, violations.len);
    for (expected, violations) |want, got| {
        try testing.expectEqualStrings("no_literal", got.check);
        try testing.expectEqualStrings(want, source[got.span.start..got.span.end]);
    }
}

test "python: no_literal flags a literal keyword argument and a literal dict entry of the named option" {
    try expectPythonLiterals("requests.get(u, timeout=30)\n", &.{"timeout=30"});
    try expectPythonLiterals("run(timeout=1.5, other=2)\n", &.{"timeout=1.5"});
    try expectPythonLiterals("run(timeout=-5)\n", &.{"timeout=-5"});
    try expectPythonLiterals("run(timeout=\"30s\")\n", &.{"timeout=\"30s\""});
    try expectPythonLiterals("cfg = {\"timeout\": 30, 'timeout': 5}\n", &.{ "\"timeout\": 30", "'timeout': 5" });
}

test "python: no_literal leaves computed, named, interpolated and differently named values alone" {
    try expectPythonLiterals("run(timeout=budget(ms))\n", &.{});
    try expectPythonLiterals("run(timeout=ms)\n", &.{});
    try expectPythonLiterals("run(timeout=f\"{ms}s\")\n", &.{});
    try expectPythonLiterals("run(timeout=-ms, timeout2=5, delay=5)\n", &.{});
    try expectPythonLiterals("run(timeout=True, timeout=None)\n", &.{});
    try expectPythonLiterals("cfg = {timeout: 5, \"timeouts\": 5, \"\": 5, f\"{timeout}\": 5, f\"timeout{x}\": 5}\n", &.{});
}

test "no_literal refuses a language with no literal option shape instead of reporting it clean" {
    const zig_profile = &@import("lang/zig/profile.zig").profile;
    try testing.expectError(error.QueryNotForLanguage, runIn(zig_profile, "const x = .{ .timeout = 5 };\n", &.{"no_literal:timeout"}));
}

const functions = @import("functions.zig");
const python_profile = &@import("lang/python/profile.zig").profile;
const csharp_profile = &@import("lang/csharp/profile.zig").profile;

fn flaggedIn(profile: *const Profile, source: []const u8, spec: []const u8) !usize {
    const violations = try runIn(profile, source, &.{spec});
    defer testing.allocator.free(violations);
    return violations.len;
}

fn expectFlaggedTexts(profile: *const Profile, source: []const u8, spec: []const u8, expected: []const []const u8) !void {
    const violations = try runIn(profile, source, &.{spec});
    defer testing.allocator.free(violations);
    errdefer for (violations) |v| std.debug.print("flagged: {s}\n", .{source[v.span.start..v.span.end]});
    try testing.expectEqual(expected.len, violations.len);
    for (expected, violations) |want, got| try testing.expectEqualStrings(want, source[got.span.start..got.span.end]);
}

test "python: forbid_import catches importlib and __import__ by name, alias and dotted prefix" {
    try testing.expectEqual(@as(usize, 1), try flaggedIn(python_profile, "import importlib\nm = importlib.import_module(\"pickle\")\n", "forbid_import:pickle"));
    try testing.expectEqual(@as(usize, 1), try flaggedIn(python_profile, "import importlib as il\nm = il.import_module(\"pickle.x\", \"pkg\")\n", "forbid_import:pickle"));
    try testing.expectEqual(@as(usize, 1), try flaggedIn(python_profile, "from importlib import import_module\nm = import_module(name=\"pickle\")\n", "forbid_import:pickle"));
    try testing.expectEqual(@as(usize, 1), try flaggedIn(python_profile, "m = __import__(\"pickle\", globals())\n", "forbid_import:pickle"));
    try testing.expectEqual(@as(usize, 1), try flaggedIn(python_profile, "m = __import__(r'pickle')\n", "forbid_import:pickle"));
    try testing.expectEqual(@as(usize, 2), try flaggedIn(python_profile, "import pickle\nfrom pickle.x import y\n", "forbid_import:pickle"));
}

test "python: forbid_import leaves another module, a computed name and an unrelated call alone" {
    try testing.expectEqual(@as(usize, 0), try flaggedIn(python_profile, "m = __import__(\"pickletools\")\n", "forbid_import:pickle"));
    try testing.expectEqual(@as(usize, 0), try flaggedIn(python_profile, "m = __import__(f\"pickle{x}\")\n", "forbid_import:pickle"));
    try testing.expectEqual(@as(usize, 0), try flaggedIn(python_profile, "m = __import__(name)\n", "forbid_import:pickle"));
    try testing.expectEqual(@as(usize, 0), try flaggedIn(python_profile, "m = load(\"pickle\")\n", "forbid_import:pickle"));
    try testing.expectEqual(@as(usize, 0), try flaggedIn(python_profile, "m = __import__(other, \"pickle\")\n", "forbid_import:pickle"));
}

test "c#: forbid_import catches every using form and a load by name" {
    try testing.expectEqual(@as(usize, 1), try flaggedIn(csharp_profile, "using System.Net;\nclass C {}\n", "forbid_import:System.Net"));
    try testing.expectEqual(@as(usize, 1), try flaggedIn(csharp_profile, "using System.Net.Http;\nclass C {}\n", "forbid_import:System.Net"));
    try testing.expectEqual(@as(usize, 1), try flaggedIn(csharp_profile, "global using System.Net;\nclass C {}\n", "forbid_import:System.Net"));
    try testing.expectEqual(@as(usize, 1), try flaggedIn(csharp_profile, "using static System.Net.Dns;\nclass C {}\n", "forbid_import:System.Net"));
    try testing.expectEqual(@as(usize, 1), try flaggedIn(csharp_profile, "using D = System.Net.Dns;\nclass C {}\n", "forbid_import:System.Net"));
    try testing.expectEqual(@as(usize, 1), try flaggedIn(csharp_profile, "using L = System.Net.Items<int>;\nclass C {}\n", "forbid_import:System.Net"));
    try testing.expectEqual(@as(usize, 1), try flaggedIn(csharp_profile, "using global::System.Net;\nclass C {}\n", "forbid_import:System.Net"));
    try testing.expectEqual(@as(usize, 1), try flaggedIn(csharp_profile, "namespace N { using System.Net; }\n", "forbid_import:System.Net"));
    try testing.expectEqual(@as(usize, 1), try flaggedIn(csharp_profile, "class C { object A = Assembly.Load(\"System.Net, Version=4.0.0.0\"); }\n", "forbid_import:System.Net"));
    try testing.expectEqual(@as(usize, 1), try flaggedIn(csharp_profile, "class C { object T = System.Type.GetType(\"System.Net.Dns\"); }\n", "forbid_import:System.Net"));
}

test "c#: forbid_import leaves another namespace, an alias name and a using statement alone" {
    try testing.expectEqual(@as(usize, 0), try flaggedIn(csharp_profile, "using System.Network;\nclass C {}\n", "forbid_import:System.Net"));
    try testing.expectEqual(@as(usize, 0), try flaggedIn(csharp_profile, "using Net = System.IO;\nclass C {}\n", "forbid_import:Net"));
    try testing.expectEqual(@as(usize, 0), try flaggedIn(csharp_profile, "class C { void M() { using (var Net = Open()) { } } }\n", "forbid_import:Net"));
    try testing.expectEqual(@as(usize, 0), try flaggedIn(csharp_profile, "class C { object A = Assembly.Load(name); }\n", "forbid_import:System.Net"));
}

test "c#: no_literal flags named arguments, attributes, initializers, anonymous objects and with" {
    try expectFlaggedTexts(csharp_profile, "class C { void M() { Run(timeout: 5); } }\n", "no_literal:timeout", &.{"timeout: 5"});
    try expectFlaggedTexts(csharp_profile, "class C { void M() { Run(timeout: -5); } }\n", "no_literal:timeout", &.{"timeout: -5"});
    try expectFlaggedTexts(csharp_profile, "[Retry(timeout = 5)]\nclass C {}\n", "no_literal:timeout", &.{"timeout = 5"});
    try expectFlaggedTexts(csharp_profile, "class C { object O = new Opts { timeout = \"x\" }; }\n", "no_literal:timeout", &.{"timeout = \"x\""});
    try expectFlaggedTexts(csharp_profile, "class C { object O = new { timeout = 1.5, other = 2 }; }\n", "no_literal:timeout", &.{"timeout = 1.5"});
    try expectFlaggedTexts(csharp_profile, "class C { void M(R r) { r = r with { timeout = 5 }; } }\n", "no_literal:timeout", &.{"timeout = 5"});
    try expectFlaggedTexts(csharp_profile, "class C { object O = new D { [\"timeout\"] = 5 }; }\n", "no_literal:timeout", &.{"[\"timeout\"] = 5"});
    try expectFlaggedTexts(csharp_profile, "class C { object O = new D { { \"timeout\", 5 } }; }\n", "no_literal:timeout", &.{"{ \"timeout\", 5 }"});
    try expectFlaggedTexts(csharp_profile, "class C { void M() { Run(timeout: $\"plain\"); } }\n", "no_literal:timeout", &.{"timeout: $\"plain\""});
}

test "c#: no_literal leaves computed, named, interpolated, positional and plain assigned values alone" {
    const clean = [_][]const u8{
        "class C { void M() { Run(timeout: limit); } }\n",
        "class C { void M() { Run(timeout: -limit); } }\n",
        "class C { void M() { Run(timeout: $\"{x}s\"); } }\n",
        "class C { void M() { Run(other: 5); } }\n",
        "class C { void M() { Run(5); } }\n",
        "class C { void M() { timeout = 5; } }\n",
        "class C { object O = new Opts { timeout = limit }; }\n",
        "class C { object O = new D { [timeout] = 5 }; }\n",
        "class C { object O = new { timeout = limit }; }\n",
    };
    for (clean) |source| try testing.expectEqual(@as(usize, 0), try flaggedIn(csharp_profile, source, "no_literal:timeout"));
}

test "python: require_comment takes a comment above the decorators, a docstring and a comment on a first member" {
    const documented = [_][]const u8{
        "# c\n@dec\ndef f():\n    return 1\n",
        "@dec\n# c\ndef f():\n    return 1\n",
        "@dec\ndef f():\n    \"\"\"Doc.\"\"\"\n    return 1\n",
        "def f():\n    # note\n    \"\"\"Doc.\"\"\"\n    return 1\n",
        "class A:\n    \"\"\"Doc.\"\"\"\n",
        "# c\n@dec\nclass A:\n    x = 1\n",
        "# c\nclass A:\n    # m\n    def f(self):\n        return 1\n",
        "# c\nclass A:\n    # m\n    @dec\n    def f(self):\n        return 1\n",
    };
    for (documented) |source| {
        errdefer std.debug.print("source: {s}\n", .{source});
        try testing.expectEqual(@as(usize, 0), try flaggedIn(python_profile, source, "require_comment"));
    }
}

test "python: require_comment still flags a decorated definition without a comment and a string that is not a docstring" {
    try testing.expectEqual(@as(usize, 1), try flaggedIn(python_profile, "@dec\ndef f():\n    return 1\n", "require_comment"));
    try testing.expectEqual(@as(usize, 1), try flaggedIn(python_profile, "def f():\n    x = 1\n    \"\"\"Late.\"\"\"\n", "require_comment"));
    try testing.expectEqual(@as(usize, 1), try flaggedIn(python_profile, "def f():\n    # only a note\n    return 1\n", "require_comment"));
    try testing.expectEqual(@as(usize, 1), try flaggedIn(python_profile, "x = 1\n\n@dec\nclass A:\n    y = 2\n", "require_comment"));
}

test "c#: require_comment judges types and members but not property accessors" {
    try testing.expectEqual(@as(usize, 0), try flaggedIn(csharp_profile, "/// <summary>c</summary>\nclass C {\n    public int X { get; set; }\n}\n", "require_comment"));
    try testing.expectEqual(@as(usize, 0), try flaggedIn(csharp_profile, "// c\n[Attr]\nclass C {\n    // m\n    [Attr]\n    public int M() { return 1; }\n}\n", "require_comment"));
    const bare = [_][]const u8{
        "class C {}\n",
        "struct S {}\n",
        "record R(int A);\n",
        "interface I {}\n",
        "enum E { A }\n",
        "delegate void D();\n",
        "namespace N { struct S {} }\n",
    };
    for (bare) |source| try testing.expectEqual(@as(usize, 1), try flaggedIn(csharp_profile, source, "require_comment"));
    try testing.expectEqual(@as(usize, 1), try flaggedIn(csharp_profile, "// c\nclass C {\n    public int M() { return 1; }\n}\n", "require_comment"));
    try testing.expectEqual(@as(usize, 1), try flaggedIn(csharp_profile, "// c\nclass C {\n    public static C operator +(C a, C b) { return a; }\n}\n", "require_comment"));
    try testing.expectEqual(@as(usize, 0), try flaggedIn(csharp_profile, "namespace N { }\n", "require_comment"));
}

test "python: no_comment flags comments and loose strings, not docstrings or a shebang" {
    try expectFlaggedTexts(python_profile, "#!/usr/bin/env python\n\"\"\"Module.\"\"\"\nx = 1\n# note\n\"loose\"\n", "no_comment", &.{ "# note", "\"loose\"" });
    try expectFlaggedTexts(python_profile, "# first\n\"\"\"Module.\"\"\"\n", "no_comment", &.{"# first"});
    try expectFlaggedTexts(python_profile, "class A:\n    \"\"\"Doc.\"\"\"\n    def f(self):\n        'Doc.'\n        return 1\n", "no_comment", &.{});
    try expectFlaggedTexts(python_profile, "def f():\n    \"\"\"Doc.\"\"\"\n    \"\"\"Second.\"\"\"\n", "no_comment", &.{"\"\"\"Second.\"\"\""});
    try expectFlaggedTexts(python_profile, "if x:\n    \"\"\"Not a doc.\"\"\"\n", "no_comment", &.{"\"\"\"Not a doc.\"\"\""});
    try expectFlaggedTexts(python_profile, "def f():\n    \"a\" \"b\"\n    \"c\" \"d\"\n", "no_comment", &.{"\"c\" \"d\""});
    try expectFlaggedTexts(python_profile, "def f():\n    b\"bytes\"\n", "no_comment", &.{"b\"bytes\""});
    try expectFlaggedTexts(python_profile, "f\"{run()}\"\nx = \"value\"\ncall(\"arg\")\n", "no_comment", &.{});
}

test "c#: bindings name a lambda after its variable, field or property and keep the whole statement" {
    const source = "class C {\n    Func<int> Field = () => 1;\n    Func<int> Prop { get; } = () => 2;\n    void M() {\n        Func<int> local = () => 3;\n    }\n}\n";
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try ts.Parser.init(csharp_profile.grammar());
    defer parser.deinit();
    const tree = try parser.parse(source);
    defer tree.deinit();
    const found = try functions.collectFunctions(testing.allocator, csharp_profile, tree);
    defer testing.allocator.free(found);
    var names: [8][]const u8 = undefined;
    var named: usize = 0;
    for (found) |function| {
        if (!std.mem.eql(u8, function.node.kind(), "lambda_expression")) continue;
        names[named] = tree.text(functions.bindingName(csharp_profile, function.node).?);
        named += 1;
    }
    try testing.expectEqualSlices(u8, "Field", names[0]);
    try testing.expectEqualSlices(u8, "Prop", names[1]);
    try testing.expectEqualSlices(u8, "local", names[2]);
    try testing.expectEqual(@as(usize, 3), named);
}
