const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Diagnostic = struct {
    file: []const u8,
    line: u32,
    col: u32,
    message: []const u8,
};

pub const max_diagnostics = 100;

pub fn parse(gpa: Allocator, text: []const u8) ![]Diagnostic {
    var list: std.ArrayList(Diagnostic) = .empty;
    errdefer list.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (list.items.len >= max_diagnostics) break;
        const d = parseLine(trimCr(raw)) orelse continue;
        if (!listed(list.items, d)) try list.append(gpa, d);
    }
    return list.toOwnedSlice(gpa);
}

fn listed(found: []const Diagnostic, d: Diagnostic) bool {
    for (found) |other| {
        if (other.line == d.line and other.col == d.col and std.mem.eql(u8, other.file, d.file) and std.mem.eql(u8, other.message, d.message)) return true;
    }
    return false;
}

pub fn withoutDir(gpa: Allocator, text: []const u8, dir: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, text.len);
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        if (startsWithDir(text[i..], dir)) {
            i += dir.len + 1;
            continue;
        }
        out.appendAssumeCapacity(text[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn startsWithDir(text: []const u8, dir: []const u8) bool {
    if (dir.len == 0 or text.len <= dir.len or !isSeparator(text[dir.len])) return false;
    for (text[0..dir.len], dir) |a, b| {
        if (isSeparator(a) and isSeparator(b)) continue;
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

fn isSeparator(byte: u8) bool {
    return byte == '\\' or byte == '/';
}

fn trimCr(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

fn parseLine(raw: []const u8) ?Diagnostic {
    const line = std.mem.trimStart(u8, raw, " \t");
    const found = parseParenthesized(line) orelse parseColons(line) orelse parseProjectLevel(line) orelse return null;
    if (std.mem.startsWith(u8, found.message, "warning ")) return null;
    return .{ .file = found.file, .line = found.line, .col = found.col, .message = withoutProject(found.message) };
}

fn withoutProject(message: []const u8) []const u8 {
    if (message.len == 0 or message[message.len - 1] != ']') return message;
    const open = std.mem.lastIndexOf(u8, message, " [") orelse return message;
    const named = message[open + 2 .. message.len - 1];
    for ([_][]const u8{ "proj", ".sln", ".slnx" }) |tail| {
        if (std.mem.endsWith(u8, named, tail)) return std.mem.trimEnd(u8, message[0..open], " ");
    }
    return message;
}

fn parseColons(line: []const u8) ?Diagnostic {
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, line, at, ':')) |colon| : (at = colon + 1) {
        if (colon == 0) continue;
        var end = colon + 1;
        const line_no = number(line, &end) orelse continue;
        var col_no: u32 = 0;
        if (end < line.len and line[end] == ':') {
            var after = end + 1;
            if (number(line, &after)) |col| {
                col_no = col;
                end = after;
            }
        }
        for ([_][]const u8{ ": error", " - error" }) |mark| {
            if (!std.mem.startsWith(u8, line[end..], mark)) continue;
            const message = std.mem.trim(u8, line[end + mark.len - "error".len ..], " ");
            return .{ .file = line[0..colon], .line = line_no, .col = col_no, .message = message };
        }
    }
    return null;
}

fn number(line: []const u8, at: *usize) ?u32 {
    const start = at.*;
    var end = start;
    while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
    if (end == start) return null;
    at.* = end;
    return std.fmt.parseInt(u32, line[start..end], 10) catch null;
}

fn parseProjectLevel(line: []const u8) ?Diagnostic {
    const mark = " : error ";
    const at = std.mem.indexOf(u8, line, mark) orelse return null;
    if (at == 0) return null;
    return .{ .file = line[0..at], .line = 0, .col = 0, .message = std.mem.trim(u8, line[at + " : ".len ..], " ") };
}

fn parseParenthesized(line: []const u8) ?Diagnostic {
    const open = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    if (open == 0) return null;
    const rest = line[open + 1 ..];
    const close = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
    const inside = rest[0..close];
    const comma = std.mem.indexOfScalar(u8, inside, ',') orelse return null;
    const line_no = std.fmt.parseInt(u32, inside[0..comma], 10) catch return null;
    const col_no = std.fmt.parseInt(u32, inside[comma + 1 ..], 10) catch return null;
    const after = rest[close + 1 ..];
    if (!std.mem.startsWith(u8, after, ": ")) return null;
    const message = std.mem.trim(u8, after[2..], " ");
    if (message.len == 0) return null;
    return .{ .file = line[0..open], .line = line_no, .col = col_no, .message = message };
}

const testing = std.testing;

test "parses the lines mypy prints and leaves its notes and summary out" {
    const out =
        "pkg\\a.py:2: error: Incompatible return value type (got \"int\", expected \"str\")  [return-value]\n" ++
        "pkg\\a.py:6: note: By default the bodies of untyped functions are not checked  [annotation-unchecked]\n" ++
        "pkg\\a.py:9:3: error: Argument 1 to \"f\" has incompatible type \"str\"; expected \"int\"  [arg-type]\n" ++
        "Found 2 errors in 1 file (checked 1 source file)\n";
    const diags = try parse(testing.allocator, out);
    defer testing.allocator.free(diags);
    try testing.expectEqual(@as(usize, 2), diags.len);
    try testing.expectEqualStrings("pkg\\a.py", diags[0].file);
    try testing.expectEqual(@as(u32, 2), diags[0].line);
    try testing.expectEqual(@as(u32, 0), diags[0].col);
    try testing.expectEqualStrings("error: Incompatible return value type (got \"int\", expected \"str\")  [return-value]", diags[0].message);
    try testing.expectEqual(@as(u32, 9), diags[1].line);
    try testing.expectEqual(@as(u32, 3), diags[1].col);
}

test "parses the lines pyright prints under a drive path and leaves out its warnings and summary" {
    const out =
        "c:\\work\\pkg\\a.py\n" ++
        "  c:\\work\\pkg\\a.py:2:12 - error: Type \"int\" is not assignable to return type \"str\"\n" ++
        "    \"int\" is not assignable to \"str\" (reportReturnType)\n" ++
        "  c:\\work\\pkg\\a.py:3:1 - warning: Code is unreachable\n" ++
        "  c:\\work\\pkg\\a.py:10:8 - error: Import \"nosuchmod\" could not be resolved (reportMissingImports)\n" ++
        "2 errors, 1 warning, 0 informations\n";
    const diags = try parse(testing.allocator, out);
    defer testing.allocator.free(diags);
    try testing.expectEqual(@as(usize, 2), diags.len);
    try testing.expectEqualStrings("c:\\work\\pkg\\a.py", diags[0].file);
    try testing.expectEqual(@as(u32, 2), diags[0].line);
    try testing.expectEqual(@as(u32, 12), diags[0].col);
    try testing.expectEqualStrings("error: Type \"int\" is not assignable to return type \"str\"", diags[0].message);
    try testing.expectEqualStrings("error: Import \"nosuchmod\" could not be resolved (reportMissingImports)", diags[1].message);
}

test "MSBuild prints each diagnostic twice with its project: one error comes out, without the project or the warnings" {
    const line = "src\\Cart.cs(22,25): error CS0103: The name 'x' does not exist [fx.csproj]\n";
    const warning = "src\\Cart.cs(22,17): warning CS0219: The variable 'k' is assigned [fx.csproj]\n";
    const project = "CSC : error CS5001: Program does not contain a static 'Main' method [C:\\work\\fx.csproj]\n";
    const out = warning ++ line ++ warning ++ line ++ project ++ project;
    const diags = try parse(testing.allocator, out);
    defer testing.allocator.free(diags);
    try testing.expectEqual(@as(usize, 2), diags.len);
    try testing.expectEqualStrings("src\\Cart.cs", diags[0].file);
    try testing.expectEqualStrings("error CS0103: The name 'x' does not exist", diags[0].message);
    try testing.expectEqualStrings("CSC", diags[1].file);
    try testing.expectEqual(@as(u32, 0), diags[1].line);
    try testing.expectEqualStrings("error CS5001: Program does not contain a static 'Main' method", diags[1].message);
}

test "a test's own failure line and a bracket that names no project stay out of the new forms" {
    const out = "tests/test_a.py:3: AssertionError\n" ++
        "src/a.ts(1,2): error TS1: wrong [1, 2]\n";
    const diags = try parse(testing.allocator, out);
    defer testing.allocator.free(diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("error TS1: wrong [1, 2]", diags[0].message);
}

test "the gate's own directory leaves the output in any case and separator, a longer name that starts with it stays" {
    const dir = "C:\\Local\\shadow\\k\\shadow";
    const text = "C:\\Local\\shadow\\k\\shadow\\src\\a.cs(1,2): x [c:\\local\\SHADOW\\k\\shadow\\fx.csproj] C:/Local/shadow/k/shadow/b.py C:\\Local\\shadow\\k\\shadow-cache\\c";
    const out = try withoutDir(testing.allocator, text, dir);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("src\\a.cs(1,2): x [fx.csproj] b.py C:\\Local\\shadow\\k\\shadow-cache\\c", out);
}

test "parses tsc diagnostics into file, line, col and message" {
    const out =
        "src/orders.ts(12,3): error TS2322: Type 'string' is not assignable to type 'number'.\n" ++
        "some unrelated build noise\n" ++
        "src/util.ts(4,10): error TS2554: Expected 1 arguments, but got 2.\n";
    const diags = try parse(testing.allocator, out);
    defer testing.allocator.free(diags);

    try testing.expectEqual(@as(usize, 2), diags.len);
    try testing.expectEqualStrings("src/orders.ts", diags[0].file);
    try testing.expectEqual(@as(u32, 12), diags[0].line);
    try testing.expectEqual(@as(u32, 3), diags[0].col);
    try testing.expectEqualStrings("error TS2322: Type 'string' is not assignable to type 'number'.", diags[0].message);
    try testing.expectEqualStrings("src/util.ts", diags[1].file);
    try testing.expectEqual(@as(u32, 4), diags[1].line);
}

test "output without the tsc shape yields no diagnostics" {
    const diags = try parse(testing.allocator, "npm ERR! something failed\nexit 1\n");
    defer testing.allocator.free(diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "a flood of diagnostics is capped" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    var i: usize = 0;
    while (i < max_diagnostics + 50) : (i += 1) {
        try buffer.writer.print("f.ts({d},1): error TS1: boom\n", .{i + 1});
    }
    const diags = try parse(testing.allocator, buffer.written());
    defer testing.allocator.free(diags);
    try testing.expectEqual(max_diagnostics, diags.len);
}
