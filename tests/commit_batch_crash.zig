const std = @import("std");
const builtin = @import("builtin");
const symbol = @import("emetgate").symbol;
const runner = @import("emetgate").runner;
const disk = @import("emetgate").disk;
const file_move = @import("emetgate").file_move;
const commit_plan = @import("emetgate").commit_plan;
const fixture = @import("ts_fixture.zig");
const rename_case = @import("rename_tool.zig");
const move_file_case = @import("move_file_tool.zig");
const common = @import("commit_batch.zig");
const Snapshots = @import("crash_snapshot.zig").Snapshots;

const testing = std.testing;
const Env = common.Env;

const a_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const old_src = "export const unused = 1;\n";
const notes_src = "# Notes\n\n## Setup\n\nold\n";
const setup_old = "## Setup\n\nold\n";
const setup_new = "## Setup\n\nnew\n";
const hand_src = "export const hand = 1;\n";
const hand_edited = "export const hand = 2;\n";
const hand: fixture.File = .{ .rel = "src/hand.ts", .text = hand_src };

const Kind = enum { batch, move_file };

const World = struct {
    kind: Kind,
    plain: common.Plain = undefined,
    served: rename_case.Case = undefined,
    env: Env = undefined,

    fn init(self: *World, kind: Kind) !void {
        self.kind = kind;
        switch (kind) {
            .batch => {
                try self.plain.init(&.{ .{ .rel = "src/a.ts", .text = a_src }, .{ .rel = "src/old.ts", .text = old_src }, .{ .rel = "notes.md", .text = notes_src }, hand, common.ignore });
                self.env = Env.init(&self.plain.repo, self.plain.runtime, null);
            },
            .move_file => {
                try move_file_case.initFiles(&self.served, &.{ hand, common.ignore }, true);
                self.env = Env.init(&self.served.repo, self.served.runtime, &self.served.session);
                try move_file_case.plan(&self.served, &move_file_case.changes);
            },
        }
        try self.env.repo.write("src/hand.ts", hand_edited);
    }

    fn deinit(self: *World) void {
        self.env.deinit();
        switch (self.kind) {
            .batch => self.plain.deinit(),
            .move_file => self.served.deinit(),
        }
    }

    fn settle(self: *World) void {
        if (self.kind == .move_file) self.served.session.deinit();
    }

    fn run(self: *World, step: *const disk.Step, request: *commit_plan.Request) !bool {
        const env = &self.env;
        switch (self.kind) {
            .batch => {
                const file_a = try env.abs("src/a.ts");
                const edits = [_]runner.Edit{
                    .{ .file_abs = file_a, .ref_text = "add", .expected_hash = .{ .present = try symbol.parseHash(try env.hashOf("src/a.ts", "add")) }, .new_body = "{\n  return b + a;\n}" },
                    .{ .file_abs = try env.abs("src/fresh.ts"), .ref_text = "fresh", .expected_hash = .absent, .new_body = "export function fresh(): number {\n  return 1;\n}\n" },
                    .{ .file_abs = try env.abs("src/old.ts"), .ref_text = "", .expected_hash = .{ .present = symbol.fileHash(old_src) }, .op = .delete },
                };
                const doc_edits = [_]runner.DocEdit{.{ .file_abs = try env.abs("notes.md"), .selector = .{ .heading = "Setup" }, .expected_hash = symbol.hashOf(setup_old), .new_text = setup_new }};
                const result = runner.tryMutateBatch(testing.allocator, testing.io, env.runtime, .{ .edits = &edits, .doc_edits = &doc_edits, .test_command = common.green, .commit_step = step, .commit = request }) catch |err| switch (err) {
                    error.Crashed => return true,
                    else => |e| return e,
                };
                defer result.deinit(testing.allocator);
                try testing.expect(result == .committed);
                return false;
            },
            .move_file => {
                const outcome = file_move.tryMoveFile(testing.allocator, testing.io, env.runtime, .{
                    .request = .{ .from_abs = try env.abs("src/util.ts"), .to_abs = try env.abs("src/core/tools/util.ts"), .from_hash = symbol.fileHash(move_file_case.util_src), .interface_change = false },
                    .test_command = common.green,
                    .commit_step = step,
                    .language_service = env.session,
                    .commit = request,
                }) catch |err| switch (err) {
                    error.Crashed => return true,
                    else => |e| return e,
                };
                defer outcome.deinit(testing.allocator);
                try testing.expect(outcome.result == .committed);
                return false;
            },
        }
    }
};

const dirty_hand = "M src/hand.ts";

fn expectInvariants(env: *Env, before: []const u8, report: ?disk.RecoverReport) !bool {
    if (report) |r| {
        try testing.expectEqual(@as(usize, 0), r.failed);
        try testing.expectEqual(@as(usize, 0), r.not_indexed);
    }
    try testing.expectEqualStrings(hand_edited, try env.read("src/hand.ts"));
    const head = try env.head();
    const moved = !std.mem.eql(u8, head, before);
    if (moved) {
        try testing.expectEqualStrings(before, try env.git(&.{ "rev-parse", "HEAD^" }));
        try testing.expectEqualStrings(common.message, try env.git(&.{ "log", "-1", "--format=%B" }));
        try testing.expect(std.mem.indexOf(u8, try env.git(&.{ "diff", "--no-renames", "--name-only", "HEAD^", "HEAD" }), "hand.ts") == null);
    }
    try testing.expectEqualStrings(dirty_hand, try env.git(&.{ "status", "--porcelain", "--untracked-files=all" }));
    return moved;
}

fn crashAtEverySnapshot(kind: Kind) !void {
    var world: World = .{ .kind = kind };
    try world.init(kind);
    defer world.deinit();
    const env = &world.env;
    const before = try env.head();
    var snapshots = try Snapshots.init(env.repo.root_abs);
    defer snapshots.deinit();
    const step = snapshots.step();
    var request: commit_plan.Request = .{ .message = common.message };
    defer request.deinit(testing.allocator);
    try testing.expect(!try world.run(&step, &request));
    const steps = try snapshots.taken();
    try testing.expect(try expectInvariants(env, before, null));
    try testing.expectEqualStrings(request.oid.?, try env.head());
    world.settle();
    var broken: usize = 0;
    for (1..steps + 1) |stop| {
        try snapshots.restore(stop);
        const report = try disk.recover(testing.allocator, testing.io, env.repo.root_abs);
        const moved = expectInvariants(env, before, report) catch |err| {
            broken += 1;
            std.debug.print("{t}: a crash after step {d} breaks the invariants ({t}); status after recover:\n{s}\nhead moved: {}\n", .{ kind, stop, err, try env.git(&.{ "status", "--porcelain", "--untracked-files=all" }), !std.mem.eql(u8, before, try env.head()) });
            continue;
        };
        std.debug.print("{t}: a crash after step {d} recovers to {s}\n", .{ kind, stop, if (moved) "the commit" else "the old tree" });
    }
    try testing.expectEqual(@as(usize, 0), broken);
}

test "commit batch crash: a crash after any step of a committing try_batch recovers to no write or to the whole commit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try crashAtEverySnapshot(.batch);
}

test "commit batch crash: a crash after any step of a committing file move recovers to no write or to the whole commit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try crashAtEverySnapshot(.move_file);
}
