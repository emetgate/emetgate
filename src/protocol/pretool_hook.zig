const std = @import("std");
const command_danger = @import("../platform/command_danger.zig");
const json_input = @import("json_input.zig");
const lockdown_slash = @import("../platform/lockdown_slash.zig");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

pub const hook_args = lockdown_slash.pretool_args;
pub const hook_event = lockdown_slash.pretool_event;
pub const run_tool = lockdown_slash.run_tool;
pub const max_input_bytes = 4 * 1024 * 1024;
pub const unreadable_reason = "emetgate could not read this tool call, so it cannot say what the command does";
pub const delete_tool = "emetgate_delete";
const max_named = 8;
const max_examples = 3;

pub const Verdict = union(enum) {
    pass,
    ask: []const u8,
    deny: []const u8,
};

pub fn judge(arena: Allocator, input: []const u8) error{OutOfMemory}!Verdict {
    const parsed = json_input.parseLeaky(std.json.Value, arena, input, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .ask = unreadable_reason },
    };
    if (parsed != .object) return .{ .ask = unreadable_reason };
    const tool = parsed.object.get("tool_name") orelse return .{ .ask = unreadable_reason };
    if (tool != .string) return .{ .ask = unreadable_reason };
    if (!isRunTool(tool.string)) return .pass;
    const tool_input = parsed.object.get("tool_input") orelse return .pass;
    if (tool_input != .object) return .{ .ask = unreadable_reason };
    const command = tool_input.object.get("command") orelse return .pass;
    if (command == .null) return .pass;
    if (command != .string) return .{ .ask = unreadable_reason };
    const as_user = switch (tool_input.object.get("as_user") orelse std.json.Value.null) {
        .null => false,
        .bool => |flag| flag,
        else => return .{ .ask = unreadable_reason },
    };
    const cwd: ?[]const u8 = switch (parsed.object.get("cwd") orelse std.json.Value.null) {
        .string => |text| if (text.len != 0) text else null,
        else => null,
    };
    if (try command_danger.plainDelete(arena, command.string, .{ .cwd = cwd })) |found| return .{ .deny = try deleteReason(arena, found, toolPrefix(tool.string)) };
    if (as_user) return .{ .ask = try std.fmt.allocPrint(arena, "emetgate: this command runs with the user's full rights outside the low-integrity sandbox (as_user): {s}", .{command.string}) };
    const found = (try command_danger.classify(arena, command.string)) orelse return .pass;
    return .{ .ask = try std.fmt.allocPrint(arena, "emetgate: this command {s}: {s}", .{ found.reason, found.fragment }) };
}

pub fn isRunTool(name: []const u8) bool {
    if (std.mem.eql(u8, name, run_tool)) return true;
    if (!std.mem.startsWith(u8, name, "mcp__") or !std.mem.endsWith(u8, name, "__" ++ run_tool)) return false;
    return name.len > "mcp__".len + "__".len + run_tool.len;
}

fn toolPrefix(name: []const u8) []const u8 {
    return name[0 .. name.len - run_tool.len];
}

pub fn deleteReason(arena: Allocator, found: command_danger.Deletion, prefix: []const u8) error{OutOfMemory}![]const u8 {
    const what = if (found.folders) "removes a folder" else "deletes files";
    return std.fmt.allocPrint(arena, "emetgate: this command {s} outside the gate ({s}): no rule check, no hash check and no receipt. fix: {s}", .{ what, found.fragment, try deleteFix(arena, found, prefix) });
}

pub fn deleteFix(arena: Allocator, found: command_danger.Deletion, prefix: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    writeFix(&out.writer, found, prefix) catch return error.OutOfMemory;
    return out.written();
}

fn writeFix(w: *Writer, found: command_danger.Deletion, prefix: []const u8) Writer.Error!void {
    try w.writeAll("delete ");
    for (found.files[0..@min(found.files.len, max_named)], 0..) |file, i| {
        if (i != 0) try w.writeAll(", ");
        try w.writeAll(file);
    }
    if (found.files.len > max_named) try w.print(" and {d} more", .{found.files.len - max_named});
    try w.print(" with {s}{s} instead: files [", .{ prefix, delete_tool });
    for (found.files[0..@min(found.files.len, max_examples)], 0..) |file, i| {
        if (i != 0) try w.writeAll(", ");
        try w.writeAll("{\"file\":");
        try std.json.Stringify.encodeJsonString(file, .{}, w);
        try w.writeAll(if (found.folders) "}" else ",\"file_hash\":\"...\"}");
    }
    if (found.folders) {
        try w.print("]; it deletes an empty folder, and a folder with files goes when its last file is deleted, so send those files, each with the file_hash {s}emetgate_read_file shows.", .{prefix});
    } else try w.print("], each file_hash as {s}emetgate_read_file shows it (a file this session wrote needs none); it checks the rules and the tests first and takes each file out of the git index too.", .{prefix});
    for (found.files) |file| {
        if (std.mem.indexOfAny(u8, file, "*?") == null) continue;
        try w.print(" Name each file a pattern matches; {s}emetgate_list shows them.", .{prefix});
        break;
    }
    try w.writeAll(" Run the rest of the command without the delete.");
}

pub fn write(verdict: Verdict, out: *Writer) !void {
    const decision: []const u8, const reason: []const u8 = switch (verdict) {
        .pass => return,
        .ask => |text| .{ "ask", text },
        .deny => |text| .{ "deny", text },
    };
    var js: std.json.Stringify = .{ .writer = out, .options = .{ .escape_unicode = true } };
    try js.beginObject();
    try js.objectField("hookSpecificOutput");
    try js.beginObject();
    try js.objectField("hookEventName");
    try js.write(hook_event);
    try js.objectField("permissionDecision");
    try js.write(decision);
    try js.objectField("permissionDecisionReason");
    try js.write(reason);
    try js.endObject();
    try js.endObject();
    try out.writeByte('\n');
}

pub fn respond(gpa: Allocator, input: []const u8, out: *Writer) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try write(try judge(arena_state.allocator(), input), out);
}
