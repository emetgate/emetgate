const std = @import("std");
const builtin = @import("builtin");
const diagnostics = @import("diagnostics.zig");
const runner = @import("emetgate").runner;
const shadow = @import("emetgate").shadow;
const disk = @import("emetgate").disk;
const Runtime = @import("emetgate").runtime.Runtime;

const support = @import("runner_support.zig");
const TwoFile = support.TwoFile;
const hashOfRef = support.hashOfRef;
const tracked = @import("batch_create_crash.zig").tracked;

const testing = std.testing;

const new_a = "export function add(a: number, b: number): number { return a - b; }\n";
const helper_body = "export function helper(x: number): number { return x + 1; }";
const helper_file = helper_body ++ "\n";
const calling_body = "{ return helper(a) + b; }";

const swap_steps = 7;
const later_steps = [_]usize{ 8, 9, 10, 11 };

const StopAt = struct {
    target: usize,
    seen: usize = 0,

    fn reached(context: *anyopaque) bool {
        const self: *StopAt = @ptrCast(@alignCast(context));
        self.seen += 1;
        return self.seen == self.target;
    }
};

const Fixture = struct {
    repo: TwoFile,
    runtime: *Runtime,
    buf_a: [std.fs.max_path_bytes]u8 = undefined,
    buf_c: [std.fs.max_path_bytes]u8 = undefined,
    file_a: []const u8 = "",
    file_c: []const u8 = "",

    fn init(self: *Fixture) !void {
        self.repo = try TwoFile.init();
        errdefer self.repo.deinit();
        self.runtime = try Runtime.create(testing.allocator);
        self.file_a = try self.repo.pathA(&self.buf_a);
        self.file_c = try std.fmt.bufPrint(&self.buf_c, "{s}\\src\\c.ts", .{self.repo.root_abs});
    }

    fn deinit(self: *Fixture) void {
        self.runtime.destroy() catch @panic("live snapshots");
        self.repo.deinit();
    }

    fn run(self: *Fixture, a_body: []const u8, step: ?*const disk.Step) !runner.BatchResult {
        const edits = [_]runner.Edit{
            .{ .file_abs = self.file_a, .ref_text = "add", .expected_hash = .{ .present = try hashOfRef(testing.allocator, testing.io, self.runtime, self.file_a, "add") }, .new_body = a_body },
            .{ .file_abs = self.file_c, .ref_text = "helper", .expected_hash = .absent, .new_body = helper_body },
        };
        return runner.tryMutateBatch(testing.allocator, testing.io, self.runtime, .{ .edits = &edits, .test_command = "cmd /c exit 0", .commit_step = step });
    }

    fn created(self: *Fixture) !?[]u8 {
        return self.repo.tmp.dir.readFileAlloc(testing.io, "repo/src/c.ts", testing.allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |e| e,
        };
    }

    fn expectOld(self: *Fixture) !void {
        const a = try self.repo.readA();
        defer testing.allocator.free(a);
        try testing.expectEqualStrings(TwoFile.a_src, a);
        if (try self.created()) |c| {
            testing.allocator.free(c);
            return error.CreatedFileLeft;
        }
    }

    fn expectNew(self: *Fixture) !void {
        const a = try self.repo.readA();
        defer testing.allocator.free(a);
        try testing.expectEqualStrings(new_a, a);
        const c = (try self.created()) orelse return error.FileMissing;
        defer testing.allocator.free(c);
        try testing.expectEqualStrings(helper_file, c);
        if (!try tracked(self.repo.root_abs, "src/c.ts")) return error.CreatedFileNotIndexed;
    }
};

fn crashThenRecover(stop: usize) !void {
    errdefer std.debug.print("crash after step {d}\n", .{stop});
    var f: Fixture = .{ .repo = undefined, .runtime = undefined };
    try f.init();
    defer f.deinit();

    var at: StopAt = .{ .target = stop };
    const step: disk.Step = .{ .context = &at, .reached = StopAt.reached };
    if (f.run("{ return a - b; }", &step)) |result| {
        defer result.deinit(testing.allocator);
        diagnostics.printResult(result);
        return error.NoCrash;
    } else |err| try testing.expectEqual(error.Crashed, err);

    const report = try disk.recover(testing.allocator, testing.io, f.repo.root_abs);
    try testing.expectEqual(@as(usize, 0), report.failed);
    try testing.expectEqual(@as(usize, 0), report.not_indexed);
    if (stop <= swap_steps) try f.expectOld() else try f.expectNew();
}

test "batch create through the tool: a crash during the swaps recovers with the new file gone" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    for (1..swap_steps + 1) |stop| try crashThenRecover(stop);
}

test "batch create through the tool: a crash after the commit record recovers with the new file present and indexed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    for (later_steps) |stop| try crashThenRecover(stop);
}

test "batch create through the tool: a batch that modifies one file and creates another commits both and indexes the new file" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f: Fixture = .{ .repo = undefined, .runtime = undefined };
    try f.init();
    defer f.deinit();

    const result = try f.run("{ return a - b; }", null);
    defer result.deinit(testing.allocator);
    errdefer diagnostics.printResult(result);
    try testing.expect(result == .committed);
    try f.expectNew();
    try testing.expect(result.committed[0].evidence == null);
    const evidence = result.committed[1].evidence orelse return error.NoEvidence;
    try testing.expect(evidence.symmetric());
}

test "batch create through the tool: a new symbol that another edit of the batch calls is not classed as symmetry" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f: Fixture = .{ .repo = undefined, .runtime = undefined };
    try f.init();
    defer f.deinit();

    const result = try f.run(calling_body, null);
    defer result.deinit(testing.allocator);
    errdefer diagnostics.printResult(result);
    try testing.expect(result == .committed);
    const evidence = result.committed[1].evidence orelse return error.NoEvidence;
    try testing.expect(evidence.parses);
    try testing.expect(!evidence.unreferenced);
    try testing.expect(!evidence.symmetric());
}

test "batch create through the tool: a failing test rejects the batch and creates nothing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f: Fixture = .{ .repo = undefined, .runtime = undefined };
    try f.init();
    defer f.deinit();

    const edits = [_]runner.Edit{
        .{ .file_abs = f.file_c, .ref_text = "helper", .expected_hash = .absent, .new_body = helper_body },
    };
    const result = try runner.tryMutateBatch(testing.allocator, testing.io, f.runtime, .{ .edits = &edits, .test_command = "cmd /c exit 1" });
    defer result.deinit(testing.allocator);
    try testing.expect(result == .rejected);
    try f.expectOld();
}

test "batch create through the tool: the gate test sees an untracked project file of the working tree" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f: Fixture = .{ .repo = undefined, .runtime = undefined };
    try f.init();
    defer f.deinit();
    try f.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/Untracked.sln", .data = "solution\n" });

    const edits = [_]runner.Edit{
        .{ .file_abs = f.file_c, .ref_text = "helper", .expected_hash = .absent, .new_body = helper_body },
    };
    const result = try runner.tryMutateBatch(testing.allocator, testing.io, f.runtime, .{ .edits = &edits, .test_command = "cmd /c type Untracked.sln" });
    defer result.deinit(testing.allocator);
    errdefer diagnostics.printResult(result);
    try testing.expect(result == .committed);
}

test "batch create through the tool: the working tree listing keeps untracked files and skips ignored, build output and workspace files" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f: Fixture = .{ .repo = undefined, .runtime = undefined };
    try f.init();
    defer f.deinit();
    try f.repo.tmp.dir.createDirPath(testing.io, "repo/bin");
    try f.repo.tmp.dir.createDirPath(testing.io, "repo/obj");
    try f.repo.tmp.dir.createDirPath(testing.io, "repo/.emetgate");
    try f.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.gitignore", .data = "*.log\n" });
    try f.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/Untracked.sln", .data = "solution\n" });
    try f.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/run.log", .data = "log\n" });
    try f.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/bin/app.dll", .data = "dll\n" });
    try f.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/obj/app.json", .data = "{}\n" });
    try f.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.emetgate/state", .data = "s\n" });

    const files = try shadow.workingFiles(testing.allocator, testing.io, f.repo.root_abs);
    defer {
        shadow.freeFileList(testing.allocator, files);
        testing.allocator.free(files);
    }
    var seen_sln = false;
    var seen_a = false;
    for (files) |file| {
        if (std.mem.eql(u8, file, "Untracked.sln")) seen_sln = true;
        if (std.mem.eql(u8, file, "src/a.ts")) seen_a = true;
        if (std.mem.eql(u8, file, "run.log")) return error.IgnoredFileListed;
        if (std.mem.startsWith(u8, file, "bin/") or std.mem.startsWith(u8, file, "obj/")) return error.BuildOutputListed;
        if (std.mem.startsWith(u8, file, ".emetgate/")) return error.WorkspaceListed;
    }
    try testing.expect(seen_sln);
    try testing.expect(seen_a);
}

const ExternalSave = struct {
    fixture: *Fixture,
    target: usize,
    seen: usize = 0,

    fn reached(context: *anyopaque) bool {
        const self: *ExternalSave = @ptrCast(@alignCast(context));
        self.seen += 1;
        if (self.seen == self.target) self.fixture.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/c.ts", .data = external }) catch {};
        return false;
    }
};

const external = "export const saved = 'by another tool';\n";

test "batch create through the tool: a file that appears at the create target during commit is kept and the batch is refused with Conflict" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f: Fixture = .{ .repo = undefined, .runtime = undefined };
    try f.init();
    defer f.deinit();

    var save: ExternalSave = .{ .fixture = &f, .target = 6 };
    const step: disk.Step = .{ .context = &save, .reached = ExternalSave.reached };
    try testing.expectError(error.Conflict, f.run("{ return a - b; }", &step));

    const a = try f.repo.readA();
    defer testing.allocator.free(a);
    try testing.expectEqualStrings(TwoFile.a_src, a);
    const c = (try f.created()) orelse return error.FileMissing;
    defer testing.allocator.free(c);
    try testing.expectEqualStrings(external, c);
}

test "batch create through the tool: when git add fails the batch stays committed on disk and the error is WrittenButNotIndexed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var f: Fixture = .{ .repo = undefined, .runtime = undefined };
    try f.init();
    defer f.deinit();
    try f.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.git/index.lock", .data = "" });
    defer f.repo.tmp.dir.deleteFile(testing.io, "repo/.git/index.lock") catch {};

    try testing.expectError(error.WrittenButNotIndexed, f.run("{ return a - b; }", null));
    const a = try f.repo.readA();
    defer testing.allocator.free(a);
    try testing.expectEqualStrings(new_a, a);
    const c = (try f.created()) orelse return error.FileMissing;
    defer testing.allocator.free(c);
    try testing.expectEqualStrings(helper_file, c);
}
