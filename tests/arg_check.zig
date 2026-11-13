const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const git_fixture = @import("git_fixture.zig");
const server = emetgate.server;
const arg_check = emetgate.arg_check;
const Runtime = emetgate.runtime.Runtime;

const testing = std.testing;
const gpa = testing.allocator;
const Value = std.json.Value;
const Policy = server.Policy;

const policies = [_]Policy{
    .{ .legacy_tools = true },
    .{ .legacy_tools = true, .commit = true, .open_run = true, .nested_roots = &.{"sub"}, .search_internals = false },
};

fn respond(runtime: *Runtime, policy: Policy, line: []const u8) !std.json.Parsed(Value) {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try server.handleMessageObserved(gpa, testing.io, runtime, line, &out.writer, null, policy);
    return std.json.parseFromSlice(Value, gpa, out.written(), .{ .allocate = .alloc_always });
}

fn callLine(tool: []const u8, args: anytype) ![]u8 {
    var line: std.Io.Writer.Allocating = .init(gpa);
    errdefer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = tool, .arguments = args } });
    return line.toOwnedSlice();
}

/// A value of the declared JSON type, and one of another type.
fn sample(arena: std.mem.Allocator, ty: []const u8, right: bool) !Value {
    if (std.mem.eql(u8, ty, "boolean")) return if (right) .{ .bool = true } else .{ .string = "yes" };
    if (std.mem.eql(u8, ty, "integer")) return if (right) .{ .integer = 3 } else .{ .string = "3" };
    if (std.mem.eql(u8, ty, "array")) return if (right) .{ .array = .init(arena) } else .{ .bool = true };
    return if (right) .{ .string = "x" } else .{ .bool = true };
}

fn errorOf(reply: []const u8) !std.json.Parsed(Value) {
    return std.json.parseFromSlice(Value, gpa, reply, .{ .allocate = .alloc_always });
}

test "arg check: every served tool refuses an unknown key with a fix naming its parameters, and accepts each declared one" {
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    for (policies) |policy| {
        var listed = try respond(runtime, policy, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}");
        defer listed.deinit();
        const tools = listed.value.object.get("result").?.object.get("tools").?.array.items;
        try testing.expect(tools.len >= server.tool_defs.len - 1);
        for (tools) |tool| {
            const name = tool.object.get("name").?.string;
            const props = tool.object.get("inputSchema").?.object.get("properties").?.object;
            errdefer std.debug.print("tool {s}\n", .{name});

            // Unknown key, through the real tools/call path: refused before the tool runs.
            const line = try callLine(name, .{ .bogus_key = 1 });
            defer gpa.free(line);
            var parsed = try respond(runtime, policy, line);
            defer parsed.deinit();
            const result = parsed.value.object.get("result").?.object;
            try testing.expect(result.get("isError").?.bool);
            const text = result.get("content").?.array.items[0].object.get("text").?.string;
            var reply = try errorOf(text);
            defer reply.deinit();
            try testing.expectEqualStrings("UnknownArgument", reply.value.object.get("error").?.string);
            const fix = reply.value.object.get("fix").?.string;
            try testing.expect(std.mem.indexOf(u8, fix, "bogus_key") != null);
            var it = props.iterator();
            while (it.next()) |entry| {
                errdefer std.debug.print("fix lacks {s}: {s}\n", .{ entry.key_ptr.*, fix });
                try testing.expect(std.mem.indexOf(u8, fix, entry.key_ptr.*) != null);
            }

            // Each declared prop with a value of its type is accepted; another type is refused.
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            it = props.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const ty = entry.value_ptr.object.get("type").?.string;
                errdefer std.debug.print("prop {s} ({s})\n", .{ key, ty });
                var good: std.json.ObjectMap = .empty;
                try good.put(arena, key, try sample(arena, ty, true));
                try testing.expect(try arg_check.check(gpa, name, .{ .object = good }, policy) == null);
                var bad: std.json.ObjectMap = .empty;
                try bad.put(arena, key, try sample(arena, ty, false));
                if (arg_check.check(gpa, name, .{ .object = bad }, policy)) |accepted| {
                    // git takes args as a string too.
                    try testing.expect(accepted == null);
                    try testing.expectEqualStrings("args", key);
                } else |err| {
                    try testing.expectEqual(error.MissingArgument, err);
                }
            }
        }
    }
}

test "arg check: dry_run is refused on emetgate_change and emetgate_git_write, at the top and inside an edit" {
    const policy: Policy = .{};
    inline for (.{
        .{ "emetgate_change", "{\"edits\":[{\"file\":\"a.js\",\"old_string\":\"a\",\"new_string\":\"b\"}],\"dry_run\":true}", "dry_run" },
        .{ "emetgate_change", "{\"edits\":[{\"file\":\"a.js\",\"old_string\":\"a\",\"new_string\":\"b\",\"dry_run\":true}]}", "edits[0] has no field dry_run" },
        .{ "emetgate_try_batch", "{\"edits\":[{\"file\":\"a.js\",\"content\":\"b\",\"preview\":true}]}", "edits[0] has no field preview" },
        .{ "emetgate_git_write", "{\"args\":[\"switch\",\"-c\",\"t\"],\"dry_run\":true}", "dry_run" },
        .{ "emetgate_read_file", "{\"files\":[\"a.md\",{\"file\":\"b.md\",\"lines\":3}]}", "files[1] has no field lines" },
    }) |case| {
        var args = try std.json.parseFromSlice(Value, gpa, case[1], .{});
        defer args.deinit();
        const refused = (try arg_check.check(gpa, case[0], args.value, policy)) orelse return error.NotRefused;
        defer gpa.free(refused);
        errdefer std.debug.print("{s}\n", .{refused});
        try testing.expect(std.mem.indexOf(u8, refused, "\"error\":\"UnknownArgument\"") != null);
        try testing.expect(std.mem.indexOf(u8, refused, case[2]) != null);
        try testing.expect(std.mem.indexOf(u8, refused, "\"fix\":") != null);
    }
}

test "arg check: search kinds outside code, comment and string is refused once with the kinds fix" {
    const policy: Policy = .{};
    for ([_][]const u8{ "{\"pattern\":\"a\",\"kinds\":[\"bogus\"]}", "{\"pattern\":\"a\",\"kinds\":[\"code\",7]}" }) |text| {
        var args = try std.json.parseFromSlice(Value, gpa, text, .{});
        defer args.deinit();
        const refused = (try arg_check.check(gpa, "emetgate_search", args.value, policy)) orelse return error.NotRefused;
        defer gpa.free(refused);
        errdefer std.debug.print("{s}\n", .{refused});
        var reply = try errorOf(refused);
        defer reply.deinit();
        try testing.expectEqualStrings("UnknownKind", reply.value.object.get("error").?.string);
        const fix = reply.value.object.get("fix").?.string;
        inline for (.{ "code", "comment", "string" }) |kind| try testing.expect(std.mem.indexOf(u8, fix, kind) != null);
    }
    var bogus = try std.json.parseFromSlice(Value, gpa, "{\"pattern\":\"a\",\"kinds\":[\"bogus\"]}", .{});
    defer bogus.deinit();
    const named = (try arg_check.check(gpa, "emetgate_search", bogus.value, policy)).?;
    defer gpa.free(named);
    try testing.expect(std.mem.indexOf(u8, named, "bogus") != null);
    var good = try std.json.parseFromSlice(Value, gpa, "{\"pattern\":\"a\",\"kinds\":[\"code\",\"comment\",\"string\"]}", .{});
    defer good.deinit();
    try testing.expect(try arg_check.check(gpa, "emetgate_search", good.value, policy) == null);
    var empty = try std.json.parseFromSlice(Value, gpa, "{\"pattern\":\"\"}", .{});
    defer empty.deinit();
    const no_pattern = (try arg_check.check(gpa, "emetgate_search", empty.value, policy)) orelse return error.NotRefused;
    defer gpa.free(no_pattern);
    var empty_reply = try errorOf(no_pattern);
    defer empty_reply.deinit();
    try testing.expectEqualStrings("EmptyPattern", empty_reply.value.object.get("error").?.string);
    try testing.expect(empty_reply.value.object.get("fix") != null);
}

test "arg check: documented aliases, item shapes, null and policy fields" {
    const policy: Policy = .{};
    inline for (.{
        .{ "emetgate_edit", "{\"path\":\"a.js\",\"old_str\":\"a\",\"new_str\":\"b\"}" },
        .{ "emetgate_write", "{\"file_path\":\"a.js\",\"text\":\"a\"}" },
        .{ "emetgate_rename", "{\"file\":\"a.js\",\"old_name\":\"a\",\"hash\":\"h\",\"to\":\"b\"}" },
        .{ "emetgate_move_file", "{\"source\":\"a.js\",\"dest\":\"b.js\",\"file_hash\":\"h\"}" },
        .{ "emetgate_change", "{\"edits\":[{\"path\":\"a.js\",\"old_str\":\"a\",\"new_str\":\"b\"},{\"file\":\"a.md\",\"hash\":\"h\",\"heading\":\"A\",\"content\":\"x\"},{\"file\":\"a.js\",\"symbol\":\"f\",\"hash\":null,\"body\":\"x\"}]}" },
        .{ "emetgate_try_batch", "{\"file\":\"a.js\",\"content\":\"x\",\"retry\":\"r\",\"detail\":\"full\"}" },
        .{ "emetgate_read_file", "{\"files\":[\"a.md\",{\"file\":\"b.json\",\"pointer\":\"/a\"}],\"raw\":null}" },
        .{ "emetgate_git_write", "{\"args\":\"switch -c t\"}" },
        .{ "emetgate_symbols", "{\"file\":\"a.js\",\"within\":\"A\"}" },
        .{ "emetgate_search", "{\"pattern\":\"a\",\"format\":\"json\"}" },
        .{ "emetgate_no_such_tool", "{\"anything\":1}" },
    }) |case| {
        var args = try std.json.parseFromSlice(Value, gpa, case[1], .{});
        defer args.deinit();
        const refused = try arg_check.check(gpa, case[0], args.value, policy);
        defer if (refused) |r| gpa.free(r);
        if (refused) |r| std.debug.print("{s}: {s}\n", .{ case[0], r });
        try testing.expect(refused == null);
    }
    inline for (.{
        .{ "emetgate_search", "{\"pattern\":\"a\",\"format\":\"json\"}", "UnknownArgument" },
        .{ "emetgate_change", "{\"edits\":[],\"detail\":\"full\"}", "UnknownArgument" },
        .{ "emetgate_list", "{\"dir\":\"src\",\"limit\":100}", "UnknownArgument" },
        .{ "emetgate_read_symbol", "{\"file\":\"a.js\",\"test_cmd\":\"x\"}", "ModelSuppliedTestPolicy" },
    }) |case| {
        var args = try std.json.parseFromSlice(Value, gpa, case[1], .{});
        defer args.deinit();
        const refused = (try arg_check.check(gpa, case[0], args.value, .{ .search_internals = false })) orelse return error.NotRefused;
        defer gpa.free(refused);
        errdefer std.debug.print("{s}\n", .{refused});
        try testing.expect(std.mem.indexOf(u8, refused, case[2]) != null);
    }
}

test "arg check: arguments that select two different things, or a selector the file type has none of, are refused with a fix" {
    const policy: Policy = .{};
    inline for (.{
        .{ "emetgate_read_file", "{\"file\":\"data/big.json\",\"heading\":\"Root\"}", "ConflictingArguments", "heading applies only to .md files", "with pointer" },
        .{ "emetgate_read_file", "{\"file\":\"notes.md\",\"pointer\":\"/a\"}", "ConflictingArguments", "pointer applies only to .json files", "with heading" },
        .{ "emetgate_read_file", "{\"file\":\"src/app.ts\",\"heading\":\"A\"}", "ConflictingArguments", "heading applies only", "line_start and line_end" },
        .{ "emetgate_read_file", "{\"files\":[\"a.md\",{\"file\":\"b.json\",\"heading\":\"A\"}]}", "ConflictingArguments", "files[1].heading", "with pointer" },
        .{ "emetgate_read_symbol", "{\"file\":\"src/app.ts\",\"symbol\":\"Cart.add\",\"symbols\":[\"Cart.total\"]}", "ConflictingArguments", "symbol cannot be combined with symbols", "symbols: [" },
        .{ "emetgate_read_symbol", "{\"file\":\"src/app.ts\",\"symbols\":[\"A\"],\"line_start\":1,\"line_end\":2}", "ConflictingArguments", "symbols cannot be combined with line_start", "line_start/line_end alone" },
        .{ "emetgate_write_doc", "{\"file\":\"config.json\",\"hash\":\"h\",\"pointer\":\"/n\",\"heading\":\"Usage\",\"content\":\"4\"}", "ConflictingArguments", "pointer cannot be combined with heading", "keep pointer" },
        .{ "emetgate_change", "{\"edits\":[{\"file\":\"notes.txt\",\"old_string\":\"a\",\"new_string\":\"b\",\"content\":\"whole\",\"hash\":\"h\"}]}", "ConflictingArguments", "edits[0].old_string cannot be combined with edits[0].content", "own item of edits" },
        .{ "emetgate_change", "{\"edits\":[{\"path\":\"a.js\",\"old_str\":\"a\",\"new_str\":\"b\",\"body\":\"x\"}]}", "ConflictingArguments", "old_str cannot be combined with edits[0].body", "own item of edits" },
        .{ "emetgate_change", "{\"edits\":[{\"file\":\"a.md\",\"hash\":\"h\",\"heading\":\"A\",\"line_start\":1,\"content\":\"x\"}]}", "ConflictingArguments", "heading cannot be combined with edits[0].line_start", "keep pointer" },
        .{ "emetgate_find", "{\"pattern\":\"\"}", "EmptyPattern", "pattern of emetgate_find is empty", "literal text" },
    }) |case| {
        var args = try std.json.parseFromSlice(Value, gpa, case[1], .{});
        defer args.deinit();
        const refused = (try arg_check.check(gpa, case[0], args.value, policy)) orelse return error.NotRefused;
        defer gpa.free(refused);
        errdefer std.debug.print("{s}\n", .{refused});
        var reply = try errorOf(refused);
        defer reply.deinit();
        try testing.expectEqualStrings(case[2], reply.value.object.get("error").?.string);
        try testing.expect(std.mem.indexOf(u8, reply.value.object.get("message").?.string, case[3]) != null);
        try testing.expect(std.mem.indexOf(u8, reply.value.object.get("fix").?.string, case[4]) != null);
    }
    inline for (.{
        .{ "emetgate_read_file", "{\"file\":\"data/big.json\",\"pointer\":\"/a\"}" },
        .{ "emetgate_read_file", "{\"file\":\"README.MD\",\"heading\":\"Usage\"}" },
        .{ "emetgate_read_file", "{\"files\":[{\"file\":\"a.md\",\"heading\":\"A\"},{\"file\":\"b.json\",\"pointer\":\"/a\"}]}" },
        .{ "emetgate_read_symbol", "{\"file\":\"a.ts\",\"symbols\":[\"A\",\"B\"]}" },
        .{ "emetgate_write_doc", "{\"file\":\"config.json\",\"hash\":\"h\",\"pointer\":\"/n\",\"content\":\"4\"}" },
        .{ "emetgate_change", "{\"edits\":[{\"file\":\"a.js\",\"symbol\":\"f\",\"hash\":\"h\",\"content\":\"x\"},{\"file\":\"a.md\",\"hash\":\"h\",\"line_start\":1,\"line_end\":2,\"content\":\"x\"}]}" },
        .{ "emetgate_find", "{\"pattern\":\"needle\"}" },
    }) |case| {
        var args = try std.json.parseFromSlice(Value, gpa, case[1], .{});
        defer args.deinit();
        const refused = try arg_check.check(gpa, case[0], args.value, policy);
        defer if (refused) |r| gpa.free(r);
        if (refused) |r| std.debug.print("{s}: {s}\n", .{ case[0], r });
        try testing.expect(refused == null);
    }
}

test "arg check: a value of the wrong type is the invalid-params error naming it and its type" {
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    inline for (.{
        .{ "emetgate_read_file", "{\"file\":\"a.md\",\"raw\":\"yes\"}", "raw (boolean)" },
        .{ "emetgate_read_file", "{\"files\":[{\"file\":\"a.md\",\"line_start\":\"3\"}]}", "files[0].line_start (integer)" },
        .{ "emetgate_change", "{\"edits\":[{\"file\":\"a.js\",\"old_string\":\"a\",\"new_string\":\"b\",\"replace_all\":\"yes\"}]}", "edits[0].replace_all (boolean)" },
    }) |case| {
        const line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"" ++ case[0] ++ "\",\"arguments\":" ++ case[1] ++ "}}";
        var parsed = try respond(runtime, .{}, line);
        defer parsed.deinit();
        const err = parsed.value.object.get("error").?.object;
        try testing.expectEqual(@as(i64, -32602), err.get("code").?.integer);
        try testing.expectEqualStrings("Missing or invalid argument: " ++ case[2], err.get("message").?.string);
    }
}

test "arg check: emetgate_change with dry_run writes nothing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const original = "export function total(a, b) {\n  return a + b;\n}\n";
    try tmp.dir.createDirPath(testing.io, "repo/src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/app.js", .data = original });
    const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
    defer gpa.free(root_abs);
    try git_fixture.initRepo(root_abs);
    try git_fixture.commitInit(root_abs, false);
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    const file = try std.fmt.allocPrint(gpa, "{s}\\src\\app.js", .{root_abs});
    defer gpa.free(file);
    const policy: Policy = .{ .root = root_abs, .test_command = "cmd /c exit 0" };
    for ([_]bool{ false, true }) |inside| {
        const line = if (inside)
            try callLine("emetgate_change", .{ .edits = .{.{ .file = file, .old_string = "a + b", .new_string = "a - b", .dry_run = true }} })
        else
            try callLine("emetgate_change", .{ .edits = .{.{ .file = file, .old_string = "a + b", .new_string = "a - b" }}, .dry_run = true });
        defer gpa.free(line);
        var parsed = try respond(runtime, policy, line);
        defer parsed.deinit();
        const result = parsed.value.object.get("result").?.object;
        try testing.expect(result.get("isError").?.bool);
        const text = result.get("content").?.array.items[0].object.get("text").?.string;
        try testing.expect(std.mem.indexOf(u8, text, "UnknownArgument") != null);
        const on_disk = try tmp.dir.readFileAlloc(testing.io, "repo/src/app.js", gpa, .unlimited);
        defer gpa.free(on_disk);
        try testing.expectEqualStrings(original, on_disk);
    }
}
