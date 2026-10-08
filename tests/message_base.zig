const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const fixture = @import("ts_fixture.zig");
const common = @import("commit_batch.zig");

const memory = emetgate.memory;

const testing = std.testing;
const Plain = common.Plain;
const Env = common.Env;
const Reply = common.Reply;

const util_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const allowing_src = "export const allowwip = 0;\nexport function add(a: number, b: number): number {\n  return a + b;\n}\n";
const loosening_body = "{\n  const allowwip = 0;\n  return a + b + allowwip;\n}";
const reads_the_code = "message:cmd:findstr allowwip src\\util.ts";
const message = "wip: loosen";

fn adopt(case: *Plain) !void {
    const id = try memory.remember(testing.allocator, testing.io, case.repo.root_abs, .project, "the code must allow it", true, reads_the_code, null);
    testing.allocator.free(id);
}

fn single(env: *Env) !Reply {
    return env.call("emetgate_try", .{ .file = try env.abs("src/util.ts"), .symbol = "add", .hash = try env.hashOf("src/util.ts", "add"), .body = loosening_body, .message = message }, common.green, true);
}

fn batch(env: *Env) !Reply {
    const edits = .{.{ .file = try env.abs("src/util.ts"), .symbol = "add", .hash = try env.hashOf("src/util.ts", "add"), .body = loosening_body }};
    return env.call("emetgate_try_batch", .{ .edits = edits, .message = message }, common.green, true);
}

fn expectRefused(env: *Env, reply: Reply, before: []const u8) !void {
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(std.mem.indexOf(u8, reply.text, "rule_violation") != null);
    try testing.expectEqualStrings(before, try env.head());
    try testing.expectEqualStrings(util_src, try env.read("src/util.ts"));
}

test "message base: a symbol edit cannot add to the file its message command reads what that command looks for" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/util.ts", .text = util_src }, common.ignore });
    defer case.deinit();
    try adopt(&case);
    const before = try case.env.head();
    try expectRefused(&case.env, try single(&case.env), before);
}

test "message base: a batch cannot add to the file its message command reads what that command looks for" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/util.ts", .text = util_src }, common.ignore });
    defer case.deinit();
    try adopt(&case);
    const before = try case.env.head();
    try expectRefused(&case.env, try batch(&case.env), before);
}

test "message base: the same calls are accepted when the file allowed the message before them, as a control" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    inline for (.{ single, batch }) |call| {
        var case: Plain = undefined;
        try case.init(&.{ .{ .rel = "src/util.ts", .text = allowing_src }, common.ignore });
        defer case.deinit();
        try adopt(&case);
        const before = try case.env.head();
        const reply = try call(&case.env);
        errdefer std.debug.print("{s}\n", .{reply.text});
        try testing.expect(!reply.is_error);
        try testing.expectEqualStrings(before, try case.env.git(&.{ "rev-parse", "HEAD^" }));
    }
}
