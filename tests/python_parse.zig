const std = @import("std");
const atomic = @import("change_atomic.zig");
const python_indent = @import("emetgate").python_indent;

const testing = std.testing;
const gpa = testing.allocator;
const Repo = atomic.Repo;

const p_py = "def clean(s):\n    s = s.strip()\n    return s\n";
const green = "cmd /c exit 0";

fn expectRefused(new_string: []const u8, reason: []const u8) !void {
    var repo = try Repo.init(&.{.{ "p.py", p_py }});
    defer repo.deinit();
    const file = try repo.path("p.py");
    defer gpa.free(file);
    var reply = try repo.call(.{ .edits = .{
        .{ .file = file, .old_string = "    return s\n", .new_string = new_string },
    } }, green);
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(reply.has("SyntaxCheckFailed"));
    try testing.expect(reply.has("p.py line 3"));
    try testing.expect(reply.has(reason));
    try testing.expect(reply.has("disk untouched"));
    try repo.expectFile("p.py", p_py);
}

test "python parse: an edit that leaves an unindent matching no outer level is refused and nothing is written" {
    try expectRefused("   return s\n", "unindent does not match any outer indentation level");
}

test "python parse: an edit that indents a line no block opened is refused" {
    try expectRefused("        return s\n", "unexpected indent");
}

test "python parse: an edit that indents with a tab where the block used spaces is refused as a TabError" {
    try expectRefused("\treturn s\n", "TabError");
}

test "python parse: a valid edit is written and the reply says the language check verified it" {
    var repo = try Repo.init(&.{.{ "p.py", p_py }});
    defer repo.deinit();
    const file = try repo.path("p.py");
    defer gpa.free(file);
    var reply = try repo.call(.{ .edits = .{
        .{ .file = file, .old_string = "    return s\n", .new_string = "    if not s:\n        return None\n    return s.lower()\n" },
    } }, green);
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expect(reply.has("\"parse\":\"verified"));
    try repo.expectFile("p.py", "def clean(s):\n    s = s.strip()\n    if not s:\n        return None\n    return s.lower()\n");
}

test "python parse: a new Python file that fails the check is refused" {
    var repo = try Repo.init(&.{});
    defer repo.deinit();
    const file = try repo.path("q.py");
    defer gpa.free(file);
    var reply = try repo.call(.{ .edits = .{
        .{ .file = file, .content = "x = 1\n  y = 2\n" },
    } }, green);
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(reply.has("unexpected indent"));
}

test "python parse: a file that already failed the check can still be edited elsewhere" {
    const broken = "def f():\n    a = 1\n   b = 2\nx = 1\n";
    var repo = try Repo.init(&.{.{ "b.py", broken }});
    defer repo.deinit();
    const file = try repo.path("b.py");
    defer gpa.free(file);
    var reply = try repo.call(.{ .edits = .{
        .{ .file = file, .old_string = "x = 1\n", .new_string = "x = 2\n" },
    } }, green);
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
}

test "python parse: the indentation check follows CPython on blocks, continuations, strings and tabs" {
    try testing.expect(python_indent.check("def f(a,\n  b):\n    return [a,\n b]\n") == null);
    try testing.expect(python_indent.check("s = '''\n  x\n'''\ny = 1\n") == null);
    try testing.expect(python_indent.check("if a:\n\tb = 1\nelse:\n\tb = 2\n") == null);
    try testing.expectEqualStrings(python_indent.inconsistent_dedent, python_indent.check("if a:\n    b = 1\n  c = 2\n").?.reason);
}
