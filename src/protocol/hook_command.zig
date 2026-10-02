const std = @import("std");
const repo_mod = @import("../platform/repo.zig");
const stdio = @import("../platform/stdio.zig");
const map_tools = @import("map_tools.zig");
const tool_result = @import("tool_result.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const max_input_bytes = 4 * 1024 * 1024;

pub fn prompt(gpa: Allocator, io: std.Io, runtime: *Runtime, out: *Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const buffer = try arena.alloc(u8, 64 * 1024);
    var reader = std.Io.File.Reader.init(stdio.stdin(), io, buffer);
    const input = reader.interface.allocRemaining(arena, .limited(max_input_bytes)) catch return 0;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, input, .{}) catch return 0;
    const question = tool_result.getString(parsed, "prompt") orelse return 0;
    if (std.mem.trim(u8, question, " \t\r\n").len == 0) return 0;
    const root = blk: {
        if (tool_result.getString(parsed, "cwd")) |cwd| {
            if (repo_mod.gitToplevel(gpa, io, cwd)) |r| break :blk r else |_| {}
        }
        break :blk repo_mod.repoRoot(gpa, io) catch return 0;
    };
    defer gpa.free(root);
    const session = map_tools.Session.create(gpa, io, runtime, root) catch return 0;
    defer session.destroy();
    session.with_index = false;
    session.build() catch return 0;
    const text = session.slice(arena, question) catch return 0;
    try out.writeAll(text);
    return 0;
}
