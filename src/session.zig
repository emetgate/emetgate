const std = @import("std");
const builtin = @import("builtin");
const symbol = @import("symbol.zig");
const cas = @import("cas.zig");
const alloc_bridge = @import("alloc_bridge.zig");
const Runtime = @import("runtime.zig").Runtime;
const Snapshot = @import("loader.zig").Snapshot;
const test_util = @import("test_util.zig");

const Allocator = std.mem.Allocator;

pub const Checkpoint = struct {
    index: u32,
    id: u64,
};

const Entry = struct {
    snapshot: *Snapshot,
    id: u64,
};

pub const Session = struct {
    runtime: *Runtime,
    stack: std.ArrayList(Entry),

    pub const CreateError = error{SourceHasErrors} || Snapshot.CreateError;
    pub const LoadError = error{SourceHasErrors} || Snapshot.LoadError;
    pub const HashError = symbol.Table.BuildError || symbol.Table.ResolveError;

    pub fn create(runtime: *Runtime, source: []u8) CreateError!*Session {
        return adopt(runtime, try Snapshot.fromSource(runtime, source));
    }

    pub fn load(runtime: *Runtime, io: std.Io, dir: std.Io.Dir, path: []const u8) LoadError!*Session {
        return adopt(runtime, try Snapshot.load(runtime, io, dir, path));
    }

    fn adopt(runtime: *Runtime, base: *Snapshot) (error{SourceHasErrors} || Allocator.Error)!*Session {
        errdefer base.destroy();
        if (base.tree.root().hasError()) return error.SourceHasErrors;
        const self = try runtime.gpa.create(Session);
        errdefer runtime.gpa.destroy(self);
        self.* = .{ .runtime = runtime, .stack = .empty };
        try self.stack.append(runtime.gpa, .{ .snapshot = base, .id = runtime.nextCheckpointId() });
        return self;
    }

    pub fn destroy(self: *Session) void {
        const gpa = self.runtime.gpa;
        while (self.stack.pop()) |entry| entry.snapshot.destroy();
        self.stack.deinit(gpa);
        self.* = undefined;
        gpa.destroy(self);
    }

    pub fn depth(self: *const Session) u32 {
        return @intCast(self.stack.items.len - 1);
    }

    pub fn baseHash(self: *const Session) symbol.Hash {
        return symbol.hashOf(self.stack.items[0].snapshot.source);
    }

    pub fn isDirty(self: *const Session) bool {
        const base = self.stack.items[0].snapshot.source;
        const top_source = self.stack.items[self.stack.items.len - 1].snapshot.source;
        return !std.mem.eql(u8, base, top_source);
    }

    pub fn checkpoint(self: *const Session) Checkpoint {
        const index = self.stack.items.len - 1;
        return .{ .index = @intCast(index), .id = self.stack.items[index].id };
    }

    pub fn apply(self: *Session, mutation: cas.Mutation) cas.Error!symbol.Hash {
        try self.stack.ensureUnusedCapacity(self.runtime.gpa, 1);
        const applied = try cas.apply(self.top(), mutation);
        self.stack.appendAssumeCapacity(.{ .snapshot = applied.snapshot, .id = self.runtime.nextCheckpointId() });
        return applied.hash;
    }

    pub fn rollbackTo(self: *Session, target: Checkpoint) error{StaleCheckpoint}!void {
        if (target.index >= self.stack.items.len) return error.StaleCheckpoint;
        if (self.stack.items[target.index].id != target.id) return error.StaleCheckpoint;
        while (self.stack.items.len > target.index + 1) self.stack.pop().?.snapshot.destroy();
    }

    pub fn symbolHash(self: *Session, ref: symbol.Ref) HashError!symbol.Hash {
        const table = try self.top().symbols();
        return (try table.resolve(ref)).hash;
    }

    pub fn writeSource(self: *const Session, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.stack.items[self.stack.items.len - 1].snapshot.source);
    }

    fn top(self: *Session) *Snapshot {
        return self.stack.items[self.stack.items.len - 1].snapshot;
    }
};

const testing = std.testing;

fn sourceOf(session: *const Session, buffer: []u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try session.writeSource(&writer);
    return writer.buffered();
}

fn applyText(session: *Session, ref_text: []const u8, body: []const u8) !symbol.Hash {
    const ref = try symbol.Ref.parse(testing.allocator, ref_text);
    defer ref.deinit(testing.allocator);
    const expected = try session.symbolHash(ref);
    return session.apply(.{ .ref = ref, .expected_hash = expected, .new_body = body });
}

fn hashText(session: *Session, ref_text: []const u8) !symbol.Hash {
    const ref = try symbol.Ref.parse(testing.allocator, ref_text);
    defer ref.deinit(testing.allocator);
    return session.symbolHash(ref);
}

fn newSession(runtime: *Runtime, source: []const u8) !*Session {
    return Session.create(runtime, try runtime.gpa.dupe(u8, source));
}

const bodies = [_][]const u8{ "{\n  return a - b;\n}", "{\n  return a * b;\n}" };

fn loadFixtureSession(runtime: *Runtime) !*Session {
    return Session.load(runtime, testing.io, .cwd(), test_util.fixture_dir ++ "functions.ts");
}

test "apply pushes a state and rollbackTo restores an earlier one byte for byte" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const session = try newSession(runtime, "function f() { return 1; }\n");
    defer session.destroy();

    var buf: [256]u8 = undefined;
    const base = session.checkpoint();
    const h2 = try applyText(session, "f", "{ return 2; }");
    const after_two = session.checkpoint();
    _ = try applyText(session, "f", "{ return 3; }");
    try testing.expectEqual(@as(u32, 2), session.depth());
    try testing.expectEqualStrings("function f() { return 3; }\n", try sourceOf(session, &buf));

    try session.rollbackTo(after_two);
    try testing.expectEqual(@as(u32, 1), session.depth());
    try testing.expectEqualStrings("function f() { return 2; }\n", try sourceOf(session, &buf));
    try testing.expectEqual(h2, try hashText(session, "f"));

    try session.rollbackTo(base);
    try testing.expectEqual(@as(u32, 0), session.depth());
    try testing.expectEqualStrings("function f() { return 1; }\n", try sourceOf(session, &buf));
    try testing.expectEqual(@as(usize, 1), runtime.live_snapshots);
}

test "a failed apply leaves the stack, the source and the snapshot count untouched" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const session = try newSession(runtime, "function f() { return 1; }\nfunction g() { return 2; }\n");
    defer session.destroy();
    _ = try applyText(session, "f", "{ return 10; }");

    var before_buf: [256]u8 = undefined;
    var after_buf: [256]u8 = undefined;
    const before = try sourceOf(session, &before_buf);
    const cp = session.checkpoint();

    const ref = try symbol.Ref.parse(testing.allocator, "f");
    defer ref.deinit(testing.allocator);
    const stale = symbol.hashOf("stale view");
    const current = try session.symbolHash(ref);

    try testing.expectError(error.HashMismatch, session.apply(.{ .ref = ref, .expected_hash = stale, .new_body = "{}" }));
    try testing.expectError(error.MutationSyntaxInvalid, session.apply(.{ .ref = ref, .expected_hash = current, .new_body = "{ return (; }" }));
    try testing.expectError(error.BodyEscape, session.apply(.{ .ref = ref, .expected_hash = current, .new_body = "{ } function evil() {}" }));
    try testing.expectError(error.SymbolNotFound, session.apply(.{ .ref = .{ .name = "nope" }, .expected_hash = current, .new_body = "{}" }));

    try testing.expectEqual(cp, session.checkpoint());
    try testing.expectEqual(@as(usize, 2), runtime.live_snapshots);
    try testing.expectEqualStrings(before, try sourceOf(session, &after_buf));
}

test "a stale checkpoint is refused even when the depth matches again (ABA)" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const session = try newSession(runtime, "function f() { return 1; }\n");
    defer session.destroy();

    const base = session.checkpoint();
    _ = try applyText(session, "f", "{ return 2; }");
    const first_branch = session.checkpoint();
    try session.rollbackTo(base);
    _ = try applyText(session, "f", "{ return 3; }");
    try testing.expectEqual(first_branch.index, session.checkpoint().index);

    var buf: [256]u8 = undefined;
    try testing.expectError(error.StaleCheckpoint, session.rollbackTo(first_branch));
    try testing.expectError(error.StaleCheckpoint, session.rollbackTo(.{ .index = 7, .id = 0 }));
    try testing.expectEqualStrings("function f() { return 3; }\n", try sourceOf(session, &buf));
    try testing.expectEqual(@as(u32, 1), session.depth());
}

test "a session never starts from a broken source" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);

    try testing.expectError(error.SourceHasErrors, newSession(runtime, "function f( {\n"));
    try testing.expectEqual(@as(usize, 0), runtime.live_snapshots);
}

test "a checkpoint from another session is refused" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const a = try newSession(runtime, "function f() { return 1; }\n");
    defer a.destroy();
    const b = try newSession(runtime, "function g() { return 1; }\n");
    defer b.destroy();

    const b_base = b.checkpoint();
    _ = try applyText(a, "f", "{ return 2; }");
    _ = try applyText(a, "f", "{ return 3; }");
    _ = try applyText(b, "g", "{ return 2; }");
    const b_top = b.checkpoint();

    try testing.expectError(error.StaleCheckpoint, a.rollbackTo(b_top));
    try testing.expectError(error.StaleCheckpoint, a.rollbackTo(b_base));
    try testing.expectEqual(@as(u32, 2), a.depth());
    try b.rollbackTo(b_base);
    try testing.expectEqual(@as(u32, 0), b.depth());
}

test "isDirty reports whether the top differs from the base, not how deep the stack is" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const session = try newSession(runtime, "function f() { return 1; }\n");
    defer session.destroy();
    const base = session.checkpoint();

    try testing.expect(!session.isDirty());
    _ = try applyText(session, "f", "{ return 1; }");
    try testing.expectEqual(@as(u32, 1), session.depth());
    try testing.expect(!session.isDirty());
    _ = try applyText(session, "f", "{ return 2; }");
    try testing.expect(session.isDirty());
    _ = try applyText(session, "f", "{ return 1; }");
    try testing.expect(!session.isDirty());
    try session.rollbackTo(base);
    try testing.expect(!session.isDirty());
}

test "baseHash is the hash of the bytes on disk at load time and survives applies and rollbacks" {
    const disk = @import("disk.zig");
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const session = try loadFixtureSession(runtime);
    defer session.destroy();
    const base = session.checkpoint();

    const on_disk = try disk.hashFile(testing.allocator, testing.io, test_util.fixture_dir ++ "functions.ts");
    try testing.expectEqual(on_disk, session.baseHash());
    _ = try applyText(session, "add", bodies[0]);
    try testing.expectEqual(on_disk, session.baseHash());
    try session.rollbackTo(base);
    try testing.expectEqual(on_disk, session.baseHash());
}

const cycles = 1000;
const deep_depth = 64;
const deep_repeats = 20;

test "1000 apply/rollback cycles keep the bridge at its steady state and reach zero on close" {
    const runtime = try test_util.openRuntime();
    var runtime_open = true;
    defer if (runtime_open) test_util.closeRuntime(runtime);
    const session = try loadFixtureSession(runtime);
    var session_open = true;
    defer if (session_open) session.destroy();

    const base = session.checkpoint();
    _ = try applyText(session, "add", bodies[0]);
    try session.rollbackTo(base);
    const steady = alloc_bridge.stats();

    for (0..cycles) |i| {
        _ = try applyText(session, "add", bodies[i % 2]);
        try session.rollbackTo(base);
        try testing.expectEqual(steady, alloc_bridge.stats());
    }
    for (0..deep_depth) |i| _ = try applyText(session, "add", bodies[i % 2]);
    try testing.expectEqual(@as(usize, deep_depth + 1), runtime.live_snapshots);
    try session.rollbackTo(base);
    try testing.expectEqual(steady, alloc_bridge.stats());

    session.destroy();
    session_open = false;
    try testing.expectEqual(@as(usize, 0), runtime.live_snapshots);
    try runtime.destroy();
    runtime_open = false;
    try testing.expectEqual(alloc_bridge.Stats{ .blocks = 0, .bytes = 0 }, alloc_bridge.stats());
}

fn elapsedNs(from: std.Io.Timestamp) u64 {
    return @intCast(from.durationTo(std.Io.Timestamp.now(testing.io, .awake)).nanoseconds);
}

fn percentile(sorted: []const u64, per_mille: usize) u64 {
    return sorted[@min(sorted.len - 1, sorted.len * per_mille / 1000)];
}

test "rollback latency under a production allocator" {
    const runtime = try Runtime.create(std.heap.smp_allocator);
    defer test_util.closeRuntime(runtime);
    const session = try loadFixtureSession(runtime);
    defer session.destroy();
    const base = session.checkpoint();

    var shallow: [cycles]u64 = undefined;
    for (&shallow, 0..) |*sample, i| {
        _ = try applyText(session, "add", bodies[i % 2]);
        const started = std.Io.Timestamp.now(testing.io, .awake);
        try session.rollbackTo(base);
        sample.* = elapsedNs(started);
    }
    std.mem.sort(u64, &shallow, {}, std.sort.asc(u64));

    var deep: [deep_repeats]u64 = undefined;
    for (&deep) |*sample| {
        for (0..deep_depth) |i| _ = try applyText(session, "add", bodies[i % 2]);
        const started = std.Io.Timestamp.now(testing.io, .awake);
        try session.rollbackTo(base);
        sample.* = elapsedNs(started);
    }
    std.mem.sort(u64, &deep, {}, std.sort.asc(u64));

    std.debug.print(
        "\n[session:{t}] rollback 1 -> 0 x{d}: median {d} ns, p99 {d} ns, max {d} ns | rollback {d} -> 0 x{d}: median {d} ns, max {d} ns\n",
        .{
            builtin.mode,             cycles,     percentile(&shallow, 500), percentile(&shallow, 990), shallow[shallow.len - 1],
            deep_depth,               deep_repeats, percentile(&deep, 500),  deep[deep.len - 1],
        },
    );
    if (builtin.mode != .Debug) try testing.expect(percentile(&shallow, 500) < std.time.ns_per_ms);
}
