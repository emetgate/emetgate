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

pub const Verdict = union(enum) {
    pass,
    ask: []const u8,
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
    const found = (try command_danger.classify(arena, command.string)) orelse return .pass;
    return .{ .ask = try std.fmt.allocPrint(arena, "emetgate: this command {s}: {s}", .{ found.reason, found.fragment }) };
}

pub fn isRunTool(name: []const u8) bool {
    if (std.mem.eql(u8, name, run_tool)) return true;
    if (!std.mem.startsWith(u8, name, "mcp__") or !std.mem.endsWith(u8, name, "__" ++ run_tool)) return false;
    return name.len > "mcp__".len + "__".len + run_tool.len;
}

pub fn write(verdict: Verdict, out: *Writer) !void {
    const reason = switch (verdict) {
        .pass => return,
        .ask => |text| text,
    };
    var js: std.json.Stringify = .{ .writer = out, .options = .{ .escape_unicode = true } };
    try js.beginObject();
    try js.objectField("hookSpecificOutput");
    try js.beginObject();
    try js.objectField("hookEventName");
    try js.write(hook_event);
    try js.objectField("permissionDecision");
    try js.write("ask");
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
