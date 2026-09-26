const std = @import("std");
const builtin = @import("builtin");
const runner = @import("emetgate").runner;
const Runtime = @import("emetgate").runtime.Runtime;
const support = @import("runner_support.zig");

const testing = std.testing;

test "create kinds: a batch adds an exported const and a new file with an interface, both classified as symmetry" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try support.TwoFile.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var buf_a: [std.fs.max_path_bytes]u8 = undefined;
    const file_a = try repo.pathA(&buf_a);
    var buf_c: [std.fs.max_path_bytes]u8 = undefined;
    const file_c = try std.fmt.bufPrint(&buf_c, "{s}\\src\\c.ts", .{repo.root_abs});
    const edits = [_]runner.Edit{
        .{ .file_abs = file_a, .ref_text = "limit", .expected_hash = .absent, .new_body = "export const limit = 2;" },
        .{ .file_abs = file_c, .ref_text = "Shape", .expected_hash = .absent, .new_body = "export interface Shape {\n  area: number;\n}" },
    };
    const result = try runner.tryMutateBatch(testing.allocator, testing.io, runtime, .{ .edits = &edits, .test_command = "cmd /c exit 0" });
    defer result.deinit(testing.allocator);
    try testing.expect(result == .committed);
    for (result.committed) |c| try testing.expect(c.evidence.?.symmetric());
    const a = try repo.readA();
    defer testing.allocator.free(a);
    try testing.expectEqualStrings(support.TwoFile.a_src ++ "\nexport const limit = 2;\n", a);
    const c = try repo.tmp.dir.readFileAlloc(testing.io, "repo/src/c.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("export interface Shape {\n  area: number;\n}\n", c);
}
