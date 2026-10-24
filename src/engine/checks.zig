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
        if (profile.isComment(node.kind()) or isProseStatement(profile, tree, node)) {
            try out.append(gpa, .{ .check = "no_comment", .span = .{ .start = node.startByte(), .end = node.endByte() } });
        }
    }
}

fn noLiteral(gpa: Allocator, profile: *const Profile, tree: ts.Tree, span: Span, arg: ?[]const u8, _: query.Limits, out: *std.ArrayList(Violation)) CollectError!void {
    const name = arg orelse return;
    const shape = profile.literal_values;
    var walker = traversal.Walker.init(tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        if (node.startByte() < span.start or node.endByte() > span.end) continue;
        if (!isKind(node, shape.pair)) continue;
        const key = node.childByField(shape.key_field) orelse continue;
        const value = node.childByField(shape.value_field) orelse continue;
        if (!std.mem.eql(u8, keyName(shape, tree, key), name)) continue;
        if (!isLiteral(shape, tree, value)) continue;
        try out.append(gpa, .{ .check = "no_literal", .span = .{ .start = node.startByte(), .end = node.endByte() } });
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
        if (precededByComment(profile, node)) continue;
        try out.append(gpa, .{ .check = "require_comment", .span = .{ .start = node.startByte(), .end = node.endByte() } });
    }
}

// A named function/generator/method with a name, or a class declaration with one.
fn isNamedDefinition(profile: *const Profile, node: ts.Node) bool {
    if (profile.functionKind(node.kind())) |kind| {
        switch (kind) {
            .declaration, .generator_declaration, .method => return node.childByField("name") != null,
            else => return false,
        }
    }
    // A class declaration is a container named from a field (not an object literal,
    // which is named from its binding).
    if (profile.containerName(node.kind())) |source| {
        if (source == .binding) return false;
        if (std.mem.indexOf(u8, node.kind(), "class") == null) return false;
        return node.childByField("name") != null;
    }
    return false;
}

// Does a comment sit immediately before this definition (or its export wrapper)?
fn precededByComment(profile: *const Profile, node: ts.Node) bool {
    var anchor = node;
    if (anchor.parent()) |parent| {
        if (isOneOf(parent.kind(), profile.export_wrappers)) anchor = parent;
    }
    const previous = anchor.prevNamedSibling() orelse return false;
    return profile.isComment(previous.kind());
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
        if (isKind(node, m.import_statement)) {
            const source = node.childByField(m.source_field) orelse continue;
            if (std.mem.eql(u8, unquote(tree.text(source)), module)) {
                try out.append(gpa, .{ .check = "forbid_import", .span = .{ .start = node.startByte(), .end = node.endByte() } });
            }
        } else if (isKind(node, profile.call.node)) {
            if (callImportsModule(profile, tree, node, module)) {
                try out.append(gpa, .{ .check = "forbid_import", .span = .{ .start = node.startByte(), .end = node.endByte() } });
            }
        }
    }
}

// A `require("module")` or dynamic `import("module")` call for the named module.
fn callImportsModule(profile: *const Profile, tree: ts.Tree, node: ts.Node, module: []const u8) bool {
    const callee = node.childByField(profile.call.function_field) orelse return false;
    const name = tree.text(callee);
    if (!std.mem.eql(u8, name, "require") and !std.mem.eql(u8, name, "import")) return false;
    const arguments = node.childByField(profile.call.arguments_field) orelse return false;
    if (arguments.namedChildCount() != 1) return false;
    const first = arguments.namedChild(0) orelse return false;
    if (!isOneOf(first.kind(), profile.strings)) return false;
    return std.mem.eql(u8, unquote(tree.text(first)), module);
}

fn unquote(text: []const u8) []const u8 {
    if (text.len < 2) return text;
    const quote = text[0];
    if ((quote == '"' or quote == '\'' or quote == '`') and text[text.len - 1] == quote) return text[1 .. text.len - 1];
    return text;
}

fn keyName(shape: profile_mod.LiteralValues, tree: ts.Tree, key: ts.Node) []const u8 {
    if (!isKind(key, shape.quoted_key)) return tree.text(key);
    if (key.namedChildCount() != 1) return "";
    return tree.text(key.namedChild(0).?);
}

fn isNegatedLiteral(shape: profile_mod.LiteralValues, tree: ts.Tree, value: ts.Node) bool {
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
