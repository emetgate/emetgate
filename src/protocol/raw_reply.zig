const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Writer = std.Io.Writer;

const top_fields = [_][]const u8{ "content", "body", "skeleton", "nodes", "outline" };
const entry_fields = [_][]const u8{ "body", "nodes", "text" };

pub const separator = "== ";

fn codeField(object: std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        const value = object.get(name) orelse continue;
        if (value == .string) return name;
    }
    return null;
}

fn entriesWithCode(object: std.json.ObjectMap) ?[]const Value {
    const symbols = object.get("symbols") orelse return null;
    if (symbols != .array) return null;
    for (symbols.array.items) |item| {
        if (item == .object and codeField(item.object, &entry_fields) != null) return symbols.array.items;
    }
    return null;
}

fn writeHeader(w: *Writer, object: std.json.ObjectMap, skip: []const u8) !void {
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    var it = object.iterator();
    while (it.next()) |field| {
        if (std.mem.eql(u8, field.key_ptr.*, skip)) continue;
        try js.objectField(field.key_ptr.*);
        try js.write(field.value_ptr.*);
    }
    try js.endObject();
    try w.writeByte('\n');
}

fn writeCode(w: *Writer, code: []const u8) !void {
    try w.writeAll(code);
    if (code.len != 0 and code[code.len - 1] != '\n') try w.writeByte('\n');
}

pub fn convert(gpa: Allocator, text: []const u8) !?[]u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const parsed = std.json.parseFromSlice(Value, gpa, text[0..end], .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const object = parsed.value.object;

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    if (codeField(object, &top_fields)) |name| {
        try writeHeader(&out.writer, object, name);
        try writeCode(&out.writer, object.get(name).?.string);
    } else if (entriesWithCode(object)) |entries| {
        try writeHeader(&out.writer, object, "symbols");
        for (entries) |item| {
            try out.writer.writeAll(separator);
            if (item != .object) {
                try out.writer.writeAll("{}\n");
                continue;
            }
            const name = codeField(item.object, &entry_fields) orelse "";
            try writeHeader(&out.writer, item.object, name);
            if (name.len != 0) try writeCode(&out.writer, item.object.get(name).?.string);
        }
    } else {
        out.deinit();
        return null;
    }
    if (end < text.len) try out.writer.writeAll(text[end + 1 ..]);
    return try out.toOwnedSlice();
}

const testing = std.testing;

fn expectConverted(text: []const u8, expected: ?[]const u8) !void {
    const got = try convert(testing.allocator, text);
    defer if (got) |g| testing.allocator.free(g);
    if (expected) |e| try testing.expectEqualStrings(e, got.?) else try testing.expect(got == null);
}

test "a code field leaves the JSON header and follows it verbatim, with no escapes" {
    try expectConverted(
        "{\"file\":\"a.ts\",\"start_line\":2,\"content\":\"\\tx = \\\"y\\\";\\n\",\"hash\":\"ab\"}",
        "{\"file\":\"a.ts\",\"start_line\":2,\"hash\":\"ab\"}\n\tx = \"y\";\n",
    );
    try expectConverted(
        "{\"file\":\"a.ts\",\"symbol\":\"f\",\"body\":\"{ }\"}\nfooter",
        "{\"file\":\"a.ts\",\"symbol\":\"f\"}\n{ }\nfooter",
    );
}

test "each symbol entry gets its own header line and raw code" {
    try expectConverted(
        "{\"file\":\"a.ts\",\"symbols\":[{\"symbol\":\"f\",\"hash\":\"1\",\"body\":\"{\\n}\"},{\"symbol\":\"g\",\"status\":\"unchanged\"}]}",
        "{\"file\":\"a.ts\"}\n== {\"symbol\":\"f\",\"hash\":\"1\"}\n{\n}\n== {\"symbol\":\"g\",\"status\":\"unchanged\"}\n",
    );
}

test "replies without code, and text that is not a JSON object, stay as they are" {
    try expectConverted("{\"status\":\"unchanged\",\"file\":\"a.ts\"}", null);
    try expectConverted("{\"file\":\"a.ts\",\"content\":null}", null);
    try expectConverted("{\"file\":\"a.ts\",\"symbols\":[{\"symbol\":\"f\"}]}", null);
    try expectConverted("not json", null);
    try expectConverted("[1]", null);
}
