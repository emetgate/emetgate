const std = @import("std");

const Value = std.json.Value;

const work_dir = ".zig-cache/e2e-lockdown";
const max_stdout = 16 * 1024 * 1024;
const fresh_build_tool = "mcp__emetgate__emetgate_read_file";
const probe_args = [_][]const u8{ "-p", "Reply with the single word ok.", "--output-format", "stream-json", "--verbose", "--max-turns", "1" };

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: lockdown_check <emetgate.exe> [--direct]\n", .{});
        return 2;
    }
    const direct = args.len == 3 and std.mem.eql(u8, args[2], "--direct");

    const exe_abs = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], arena);
    const exe_json = try arena.dupe(u8, exe_abs);
    std.mem.replaceScalar(u8, exe_json, '\\', '/');

    try std.Io.Dir.cwd().createDirPath(io, work_dir);
    const config = try std.fmt.allocPrint(arena, "{{\"mcpServers\":{{\"emetgate\":{{\"command\":\"{s}\",\"args\":[\"mcp\"]}}}}}}", .{exe_json});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = work_dir ++ "/.mcp.json", .data = config });

    var failures: usize = 0;

    const launch_argv = if (direct)
        try concat(arena, &.{"claude"}, &probe_args)
    else
        try concat(arena, &.{ exe_abs, "lockdown" }, &probe_args);
    const tools = try initTools(arena, io, launch_argv);
    std.debug.print("init tools ({d}): ", .{tools.len});
    for (tools) |t| std.debug.print("{s} ", .{t});
    std.debug.print("\n", .{});

    var has_fresh_tool = false;
    for (tools) |t| {
        if (std.mem.eql(u8, t, fresh_build_tool)) has_fresh_tool = true;
        if (!std.mem.eql(u8, t, "ToolSearch") and !std.mem.startsWith(u8, t, "mcp__emetgate__")) {
            std.debug.print("FAIL: tool outside the lockdown allow-list: {s}\n", .{t});
            failures += 1;
        }
    }
    if (tools.len == 0) {
        std.debug.print("FAIL: no init tool list was reported\n", .{});
        failures += 1;
    }
    if (!has_fresh_tool) {
        std.debug.print("FAIL: {s} missing; the emetgate binary under test is stale or not connected\n", .{fresh_build_tool});
        failures += 1;
    }

    if (!direct) {
        const override_argv = try concat(arena, &.{ exe_abs, "lockdown", "--tools", "default" }, &probe_args);
        const refused = try std.process.run(arena, io, .{ .argv = override_argv, .cwd = .{ .path = work_dir }, .stdout_limit = .limited(max_stdout) });
        const exited_nonzero = switch (refused.term) {
            .exited => |code| code != 0,
            else => true,
        };
        if (!exited_nonzero or std.mem.indexOf(u8, refused.stdout, "\"subtype\":\"init\"") != null) {
            std.debug.print("FAIL: a passthrough --tools override was not refused before launching claude\n", .{});
            failures += 1;
        } else {
            std.debug.print("ok: passthrough --tools override refused\n", .{});
        }
    }

    if (failures != 0) {
        std.debug.print("e2e-lockdown: {d} failure(s)\n", .{failures});
        return 1;
    }
    std.debug.print("e2e-lockdown: passed\n", .{});
    return 0;
}

fn concat(arena: std.mem.Allocator, head: []const []const u8, tail: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, head.len + tail.len);
    @memcpy(out[0..head.len], head);
    @memcpy(out[head.len..], tail);
    return out;
}

fn initTools(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]const []const u8 {
    const result = try std.process.run(arena, io, .{ .argv = argv, .cwd = .{ .path = work_dir }, .stdout_limit = .limited(max_stdout) });
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSliceLeaky(Value, arena, line, .{}) catch continue;
        if (parsed != .object) continue;
        const kind = parsed.object.get("type") orelse continue;
        const subtype = parsed.object.get("subtype") orelse continue;
        if (kind != .string or subtype != .string) continue;
        if (!std.mem.eql(u8, kind.string, "system") or !std.mem.eql(u8, subtype.string, "init")) continue;
        const list = parsed.object.get("tools") orelse return &.{};
        if (list != .array) return &.{};
        const names = try arena.alloc([]const u8, list.array.items.len);
        for (list.array.items, 0..) |item, i| names[i] = if (item == .string) item.string else "";
        return names;
    }
    std.debug.print("no init message; stderr:\n{s}\n", .{result.stderr});
    return &.{};
}
