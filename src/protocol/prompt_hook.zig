const std = @import("std");
const rule_command = @import("rule_command.zig");
const prompt_words = @import("prompt_words.zig");
const lockdown_slash = @import("../platform/lockdown_slash.zig");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

pub const command = "/" ++ lockdown_slash.command_name;
pub const usage = rule_command.usage(command ++ " ");
pub const prompt_field = "prompt";
pub const done = "ok";
pub const blocking_exit_code: u8 = 2;
pub const max_input_bytes = 4 * 1024 * 1024;

const whitespace = " \t\r\n";
const byte_order_mark = "\xef\xbb\xbf";

pub fn ruleText(arena: Allocator, input: []const u8) error{ HookInputInvalid, OutOfMemory }!?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, input, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.HookInputInvalid,
    };
    if (parsed != .object) return error.HookInputInvalid;
    const prompt = parsed.object.get(prompt_field) orelse return error.HookInputInvalid;
    if (prompt != .string) return error.HookInputInvalid;
    return argumentsOf(prompt.string);
}

pub fn argumentsOf(prompt: []const u8) ?[]const u8 {
    const typed = withoutLead(prompt);
    if (!std.mem.startsWith(u8, typed, command)) return null;
    const rest = typed[command.len..];
    if (rest.len != 0 and std.mem.indexOfScalar(u8, whitespace, rest[0]) == null) return null;
    return rest;
}

fn withoutLead(prompt: []const u8) []const u8 {
    var rest = std.mem.trimStart(u8, prompt, whitespace);
    if (std.mem.startsWith(u8, rest, byte_order_mark)) rest = rest[byte_order_mark.len..];
    return std.mem.trimStart(u8, rest, whitespace);
}

pub fn respond(gpa: Allocator, io: std.Io, root: anyerror![]const u8, text: []const u8, out: *Writer) !void {
    var reason: Writer.Allocating = .init(gpa);
    defer reason.deinit();
    answer(gpa, io, root, text, &reason.writer) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => return err,
        else => try reason.writer.print("error: {t}\n", .{err}),
    };
    const said = std.mem.trimEnd(u8, reason.written(), whitespace);
    var js: std.json.Stringify = .{ .writer = out, .options = .{ .escape_unicode = true } };
    try js.beginObject();
    try js.objectField("decision");
    try js.write("block");
    try js.objectField("reason");
    try js.write(if (said.len == 0) done else said);
    try js.endObject();
    try out.writeByte('\n');
}

fn answer(gpa: Allocator, io: std.Io, root: anyerror![]const u8, text: []const u8, reason: *Writer) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const words = prompt_words.split(arena_state.allocator(), text) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.UnterminatedQuote => return reason.writeAll(usage),
    };
    const request = rule_command.parse(words) orelse return reason.writeAll(usage);
    try rule_command.runAs(.spoken, gpa, io, try root, request, reason, reason);
}
