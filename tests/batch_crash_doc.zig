const std = @import("std");
const builtin = @import("builtin");
const symbol = @import("emetgate").symbol;
const disk = @import("emetgate").disk;
const shadow = @import("emetgate").shadow;
const batch_plan = @import("emetgate").batch_plan;

const testing = std.testing;
const gpa = testing.allocator;

const StopAt = struct {
    target: usize,
    seen: usize = 0,

    fn reached(context: *anyopaque) bool {
        const self: *StopAt = @ptrCast(@alignCast(context));
        self.seen += 1;
        return self.seen == self.target;
    }
};

const code_old = "export const a = 1;\n";
const code_new = "export const a = 2;\n";
const doc_old = "# Title\n\n## Setup\n\nold\n";
const doc_new = "# Title\n\n## Setup\n\nnew\n";

const Repo = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    journal_dir: []u8,

    fn init() !Repo {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = code_old });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.md", .data = doc_old });
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
        errdefer gpa.free(root);
        const journal_dir = try std.fmt.allocPrint(gpa, "{s}\\{s}\\journal", .{ root, shadow.workspace_dir });
        return .{ .tmp = tmp, .root = root, .journal_dir = journal_dir };
    }

    fn deinit(self: *Repo) void {
        gpa.free(self.journal_dir);
        gpa.free(self.root);
        self.tmp.cleanup();
    }

    fn content(self: *const Repo, name: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, name, gpa, .unlimited);
    }

    fn expectAllOldOrAllNew(self: *const Repo) !void {
        const code = try self.content("a.ts");
        defer gpa.free(code);
        const doc = try self.content("notes.md");
        defer gpa.free(doc);
        const code_is_old = std.mem.eql(u8, code, code_old);
        const doc_is_old = std.mem.eql(u8, doc, doc_old);
        if (code_is_old != doc_is_old) {
            std.debug.print("mixed batch: code old={}, doc old={}\n", .{ code_is_old, doc_is_old });
            return error.MixedBatch;
        }
    }

    fn expectNoDebris(self: *const Repo) !void {
        var journal = self.tmp.dir.openDir(testing.io, shadow.workspace_dir ++ "\\journal", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => |e| return e,
        };
        defer journal.close(testing.io);
        var entries = journal.iterate();
        if (try entries.next(testing.io)) |entry| {
            std.debug.print("journal debris: {s}\n", .{entry.name});
            return error.Debris;
        }
    }

    fn recover(self: *const Repo) !disk.RecoverReport {
        return disk.recover(gpa, testing.io, self.root);
    }
};

fn preparePendings(repo: *const Repo, pendings: *[2]disk.Pending) !batch_plan.Prepared {
    var code_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const code_path = try std.fmt.bufPrint(&code_path_buf, "{s}\\a.ts", .{repo.root});
    var doc_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const doc_path = try std.fmt.bufPrint(&doc_path_buf, "{s}\\notes.md", .{repo.root});

    pendings[0] = try disk.prepare(gpa, testing.io, code_path, code_new, symbol.hashOf(code_old));

    const doc_edit: batch_plan.DocEdit = .{
        .file_abs = doc_path,
        .selector = .{ .heading = "Setup" },
        .expected_hash = symbol.hashOf("## Setup\n\nold\n"),
        .new_text = "## Setup\n\nnew\n",
    };
    const doc_planned = try batch_plan.planDoc(gpa, testing.io, doc_edit, try gpa.dupe(u8, "notes.md"));
    errdefer doc_planned.deinit(gpa);
    pendings[1] = try disk.prepare(gpa, testing.io, doc_path, doc_planned.source(), doc_planned.base_hash.?);
    return doc_planned;
}

test "mixed batch crash: a code edit and a doc edit commit atomically" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var repo = try Repo.init();
    defer repo.deinit();
    var pendings: [2]disk.Pending = undefined;
    const doc_planned = try preparePendings(&repo, &pendings);
    defer doc_planned.deinit(gpa);
    const batch = disk.Batch.init(gpa, testing.io, repo.journal_dir);
    try disk.commitBatch(&pendings, null, null, &batch, null);

    const code = try repo.content("a.ts");
    defer gpa.free(code);
    const doc = try repo.content("notes.md");
    defer gpa.free(doc);
    try testing.expectEqualStrings(code_new, code);
    try testing.expectEqualStrings(doc_new, doc);
    try repo.expectNoDebris();
}

test "mixed batch crash: a crash right after the journal is written recovers to all old, whether the pending is code or doc" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var repo = try Repo.init();
    defer repo.deinit();
    var pendings: [2]disk.Pending = undefined;
    const doc_planned = try preparePendings(&repo, &pendings);
    defer doc_planned.deinit(gpa);

    const batch = disk.Batch.init(gpa, testing.io, repo.journal_dir);
    var at: StopAt = .{ .target = 1 };
    const step: disk.Step = .{ .context = &at, .reached = StopAt.reached };
    try testing.expectError(error.Crashed, disk.commitBatch(&pendings, null, null, &batch, &step));

    const report = try repo.recover();
    try testing.expectEqual(@as(usize, 0), report.failed);
    try repo.expectAllOldOrAllNew();
    const code = try repo.content("a.ts");
    defer gpa.free(code);
    const doc = try repo.content("notes.md");
    defer gpa.free(doc);
    try testing.expectEqualStrings(code_old, code);
    try testing.expectEqualStrings(doc_old, doc);
    try repo.expectNoDebris();
}

test "mixed batch crash: a crash after both files swap but before the commit record recovers forward to all new" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var repo = try Repo.init();
    defer repo.deinit();
    var pendings: [2]disk.Pending = undefined;
    const doc_planned = try preparePendings(&repo, &pendings);
    defer doc_planned.deinit(gpa);

    const swap_steps = 1 + 3 * 2;
    const batch = disk.Batch.init(gpa, testing.io, repo.journal_dir);
    var at: StopAt = .{ .target = swap_steps };
    const step: disk.Step = .{ .context = &at, .reached = StopAt.reached };
    try testing.expectError(error.Crashed, disk.commitBatch(&pendings, null, null, &batch, &step));

    const report = try repo.recover();
    try testing.expectEqual(@as(usize, 0), report.failed);
    try repo.expectAllOldOrAllNew();
    try repo.expectNoDebris();
}

const windows = std.os.windows;

extern "kernel32" fn GetCurrentProcess() callconv(.winapi) windows.HANDLE;
extern "kernel32" fn GetProcessHandleCount(process: windows.HANDLE, count: *windows.DWORD) callconv(.winapi) windows.BOOL;

fn currentHandleCount() u32 {
    var count: windows.DWORD = 0;
    _ = GetProcessHandleCount(GetCurrentProcess(), &count);
    return count;
}

test "mixed batch crash: a crash after any step recovers to all old or all new, and the process handle count does not grow across iterations" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const steps = 1 + 3 * 2 + 1 + 2 + 1;
    var first_handles: ?u32 = null;
    var stop: usize = 1;
    while (true) : (stop += 1) {
        var repo = try Repo.init();
        defer repo.deinit();

        var pendings: [2]disk.Pending = undefined;
        const doc_planned = try preparePendings(&repo, &pendings);
        defer doc_planned.deinit(gpa);

        const batch = disk.Batch.init(gpa, testing.io, repo.journal_dir);
        var at: StopAt = .{ .target = stop };
        const step: disk.Step = .{ .context = &at, .reached = StopAt.reached };
        disk.commitBatch(&pendings, null, null, &batch, &step) catch |err| {
            errdefer std.debug.print("crash after step {d} of {d}\n", .{ stop, steps });
            try testing.expectEqual(error.Crashed, err);
            const report = try repo.recover();
            try testing.expectEqual(@as(usize, 0), report.failed);
            try repo.expectAllOldOrAllNew();
            try repo.expectNoDebris();
            const handles = currentHandleCount();
            if (first_handles == null) {
                first_handles = handles;
            } else if (handles > first_handles.? + 20) {
                std.debug.print("handle count grew from {d} to {d} by step {d}\n", .{ first_handles.?, handles, stop });
                return error.HandleLeak;
            }
            continue;
        };
        try testing.expectEqual(steps + 1, stop);
        const code = try repo.content("a.ts");
        defer gpa.free(code);
        const doc = try repo.content("notes.md");
        defer gpa.free(doc);
        try testing.expectEqualStrings(code_new, code);
        try testing.expectEqualStrings(doc_new, doc);
        try repo.expectNoDebris();
        break;
    }
}
