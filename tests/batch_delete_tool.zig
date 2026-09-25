const std = @import("std");
const builtin = @import("builtin");
const diagnostics = @import("diagnostics.zig");
const runner = @import("emetgate").runner;
const disk = @import("emetgate").disk;
const symbol = @import("emetgate").symbol;
const Runtime = @import("emetgate").runtime.Runtime;

const support = @import("runner_support.zig");
const TwoFile = support.TwoFile;
const hashOfRef = support.hashOfRef;

const testing = std.testing;

const new_a = "export function add(a: number, b: number): number { return a - b; }\n";
const before_record = 4;
const after_record = [_]usize{ 5, 6, 7, 8, 9 };

const StopAt = struct {
    target: usize,
    seen: usize = 0,

    fn reached(context: *anyopaque) bool {
        const self: *StopAt = @ptrCast(@alignCast(context));
        self.seen += 1;
        return self.seen == self.target;
    }
};

fn tracked(root: []const u8, rel: []const u8) !bool {
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "git", "ls-files", "--", rel }, .cwd = .{ .path = root } });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    return std.mem.trim(u8, result.stdout, " \r\n").len != 0;
}

const Fixture = struct {
    repo: TwoFile,
    runtime: *Runtime,
    buf_a: [std.fs.max_path_bytes]u8 = undefined,
    buf_b: [std.fs.max_path_bytes]u8 = undefined,
    file_a: []const u8 = "",
    file_b: []const u8 = "",

    fn init(self: *Fixture) !void {
        self.repo = try TwoFile.init();
        errdefer self.repo.deinit();
        self.runtime = try Runtime.create(testing.allocator);
        self.file_a = try self.repo.pathA(&self.buf_a);
        self.file_b = try self.repo.pathB(&self.buf_b);
    }

    fn deinit(self: *Fixture) void {
        self.runtime.destroy() catch @panic("live snapshots");
        self.repo.deinit();
    }

    fn modifyA(self: *Fixture, body: []const u8) !runner.Edit {
        return .{ .file_abs = self.file_a, .ref_text = "add", .expected_hash = .{ .present = try hashOfRef(testing.allocator, testing.io, self.runtime, self.file_a, "add") }, .new_body = body };
    }

    fn deleteB(self: *Fixture) runner.Edit {
        return .{ .file_abs = self.file_b, .ref_text = "", .expected_hash = .{ .present = symbol.fileHash(TwoFile.b_src) }, .op = .delete };
    }

    fn run(self: *Fixture, edits: []const runner.Edit, step: ?*const disk.Step) !runner.BatchResult {
        return runner.tryMutateBatch(testing.allocator, testing.io, self.runtime, .{ .edits = edits, .test_command = "cmd /c exit 0", .commit_step = step });
    }

    fn b(self: *Fixture) !?[]u8 {
        return self.repo.tmp.dir.readFileAlloc(testing.io, "repo/src/b.ts", testing.allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |e| e,
        };
    }

    fn expectA(self: *Fixture, expected: []const u8) !void {
        const a = try self.repo.readA();
        defer testing.allocator.free(a);
        try testing.expectEqualStrings(expected, a);
    }

    fn expectOld(self: *Fixture) !void {
        try self.expectA(TwoFile.a_src);
        const b_now = (try self.b()) orelse return error.FileMissing;
        defer testing.allocator.free(b_now);
        try testing.expectEqualStrings(TwoFile.b_src, b_now);
        if (!try tracked(self.repo.root_abs, "src/b.ts")) return error.NotIndexed;
    }

    fn expectNew(self: *Fixture) !void {
        try self.expectA(new_a);
        if (try self.b()) |left| {
            testing.allocator.free(left);
            return error.FileLeft;
        }
        if (try tracked(self.repo.root_abs, "src/b.ts")) return error.StillIndexed;
    }
};

fn crashThenRecover(stop: usize) !void {
    errdefer std.debug.print("crash after step {d}\n", .{stop});
    var f: Fixture = .{ .repo = undefined, .runtime = undefined };
    try f.init();
    defer f.deinit();

    var at: StopAt = .{ .target = stop };
    const step: disk.Step = .{ .context = &at, .reached = StopAt.reached };
    const edits = [_]runner.Edit{ try f.modifyA("{ return a - b; }"), f.deleteB() };
    if (f.run(&edits, &step)) |result| {
        defer result.deinit(testing.allocator);
        diagnostics.printResult(result);
        return error.NoCrash;
    } else |err| try testing.expectEqual(error.Crashed, err);

    const report = try disk.recover(testing.allocator, testing.io, f.repo.root_abs);
    try testing.expectEqual(@as(usize, 0), report.failed);
    try testing.expectEqual(@as(usize, 0), report.not_indexed);
    if (stop <= before_record) try f.expectOld() else try f.expectNew();
}

test "batch delete through the tool: a crash before the commit record keeps the deleted file and its index entry" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    for (1..before_record + 1) |stop| try crashThenRecover(stop);
}

test "batch delete through the tool: a crash after the commit record removes the file from disk and index" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    for (after_record) |stop| try crashThenRecover(stop);
}

test "batch delete through the tool: a batch that modifies one file and deletes another commits both" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f: Fixture = .{ .repo = undefined, .runtime = undefined };
    try f.init();
    defer f.deinit();
    const edits = [_]runner.Edit{ try f.modifyA("{ return a - b; }"), f.deleteB() };
    const result = try f.run(&edits, null);
    defer result.deinit(testing.allocator);
    errdefer diagnostics.printResult(result);
    try testing.expect(result == .committed);
    try testing.expect(result.committed[1].deleted);
    try f.expectNew();
}

test "batch delete through the tool: an unreferenced symbol is removed and the rest of its file is kept" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f: Fixture = .{ .repo = undefined, .runtime = undefined };
    try f.init();
    defer f.deinit();
    const twice = try hashOfRef(testing.allocator, testing.io, f.runtime, f.file_b, "twice");
    const add = try hashOfRef(testing.allocator, testing.io, f.runtime, f.file_a, "add");
    const edits = [_]runner.Edit{
        .{ .file_abs = f.file_b, .ref_text = "twice", .expected_hash = .{ .present = twice }, .new_body = "{ return x * 2; }" },
        .{ .file_abs = f.file_a, .ref_text = "add", .expected_hash = .{ .present = add }, .op = .delete },
    };
    const result = try f.run(&edits, null);
    defer result.deinit(testing.allocator);
    errdefer diagnostics.printResult(result);
    try testing.expect(result == .committed);
    try testing.expect(result.committed[1].deleted);
    try f.expectA("");
    const b_now = (try f.b()) orelse return error.FileMissing;
    defer testing.allocator.free(b_now);
    try testing.expectEqualStrings("export function twice(x: number): number { return x * 2; }\n", b_now);
}

test "batch delete through the tool: a symbol that another edit of the batch calls cannot be deleted" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f: Fixture = .{ .repo = undefined, .runtime = undefined };
    try f.init();
    defer f.deinit();
    const twice = try hashOfRef(testing.allocator, testing.io, f.runtime, f.file_b, "twice");
    const edits = [_]runner.Edit{ try f.modifyA("{ return twice(a) + b; }"), .{ .file_abs = f.file_b, .ref_text = "twice", .expected_hash = .{ .present = twice }, .op = .delete } };
    try testing.expectError(error.SymbolReferenced, f.run(&edits, null));
    try f.expectOld();
}

test "batch delete through the tool: a file delete without the whole-file hash is refused and the file stays" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f: Fixture = .{ .repo = undefined, .runtime = undefined };
    try f.init();
    defer f.deinit();
    const edits = [_]runner.Edit{.{ .file_abs = f.file_b, .ref_text = "", .expected_hash = .absent, .op = .delete }};
    try testing.expectError(error.MissingFileHash, f.run(&edits, null));
    try f.expectOld();
}

test "batch delete through the tool: a file that changed after its hash was read is refused with HashMismatch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f: Fixture = .{ .repo = undefined, .runtime = undefined };
    try f.init();
    defer f.deinit();
    const edits = [_]runner.Edit{f.deleteB()};
    const edited = "export function twice(x: number): number {\n  return 2 * x;\n}\n";
    try f.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/b.ts", .data = edited });
    try testing.expectError(error.HashMismatch, f.run(&edits, null));
    const b_now = (try f.b()) orelse return error.FileMissing;
    defer testing.allocator.free(b_now);
    try testing.expectEqualStrings(edited, b_now);
}
