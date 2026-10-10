const std = @import("std");
const emetgate = @import("emetgate");
const server = emetgate.server;
const map_tools = emetgate.map_tools;
const fact_store = emetgate.fact_store;
const fact_file = emetgate.fact_file;
const io_seam = emetgate.io_seam;
const test_util = emetgate.test_util;
const Runtime = emetgate.runtime.Runtime;
const git_fixture = @import("git_fixture.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const large_files = 30;
const large_functions = 24;
const small_files = 4;
const small_functions = 3;
const gate_patience_ns = 3 * std.time.ns_per_s;
const first_reply_limit_ns = 2 * std.time.ns_per_s;
const build_to_reply_ratio = 4;

fn now() i96 {
    return std.Io.Clock.awake.now(testing.io).nanoseconds;
}

fn pause(ms: i64) void {
    testing.io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

fn git(root: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argv.append(testing.allocator, "git");
    try argv.appendSlice(testing.allocator, args);
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = argv.items, .cwd = .{ .path = root } });
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
}

const Repo = struct {
    runtime: *Runtime,
    tmp: testing.TmpDir,
    base: [:0]u8,
    root: []u8,
    store_path: []u8,
    files: usize,

    fn make(files: usize, functions: usize) !Repo {
        const runtime = try test_util.openRuntime();
        var tmp = testing.tmpDir(.{});
        try tmp.dir.createDirPath(testing.io, "repo/src");
        var text: std.Io.Writer.Allocating = .init(testing.allocator);
        defer text.deinit();
        for (0..files) |f| {
            text.clearRetainingCapacity();
            for (0..functions) |k| {
                try text.writer.print("export function step{d}x{d}(input: number): number {{\n  const scaled = input * {d};\n  return scaled + {d};\n}}\n\n", .{ f, k, k + 2, f });
            }
            const sub = try std.fmt.allocPrint(testing.allocator, "repo/src/part{d}.ts", .{f});
            defer testing.allocator.free(sub);
            try tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = text.written() });
        }
        const base = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        const root = try std.fmt.allocPrint(testing.allocator, "{s}\\repo", .{base});
        try git_fixture.initRepo(root);
        try git(root, &.{ "add", "." });
        const store_path = try std.fmt.allocPrint(testing.allocator, "{s}\\store\\facts.v{d}", .{ base, fact_file.version });
        return .{ .runtime = runtime, .tmp = tmp, .base = base, .root = root, .store_path = store_path, .files = files };
    }

    fn close(self: *Repo) void {
        testing.allocator.free(self.store_path);
        testing.allocator.free(self.root);
        testing.allocator.free(self.base);
        self.tmp.cleanup();
        test_util.closeRuntime(self.runtime);
    }

    fn storeWritten(self: *const Repo) bool {
        std.Io.Dir.cwd().access(testing.io, self.store_path, .{}) catch return false;
        return true;
    }
};

const Gate = struct {
    inner: io_seam.Fs,
    entered: std.atomic.Value(bool) = .init(false),
    open: std.atomic.Value(bool) = .init(false),
    released_by: ?*const std.atomic.Value(bool) = null,
    gave_up: std.atomic.Value(bool) = .init(false),
    fail_listing: bool = false,
    source_reads: std.atomic.Value(usize) = .init(0),
    creates: std.atomic.Value(usize) = .init(0),
    cancel_at_read: usize = 0,
    cancel: ?*std.atomic.Value(bool) = null,

    fn seam(self: *Gate, base: io_seam.Seam) io_seam.Seam {
        self.inner = base.fs;
        var wrapped = base;
        wrapped.fs = .{ .context = self, .vtable = &vtable };
        return wrapped;
    }

    fn waitEntered(self: *Gate) !void {
        const deadline = now() + gate_patience_ns;
        while (!self.entered.load(.acquire)) {
            if (now() > deadline) return error.BuildNeverStarted;
            pause(1);
        }
    }

    const vtable: io_seam.Fs.VTable = .{
        .readFile = readFile,
        .stat = stat,
        .list = list,
        .realPath = realPath,
        .tracked = tracked,
        .createFile = createFile,
        .renameReplace = renameReplace,
        .deleteFile = deleteFile,
        .makePath = makePath,
    };

    fn of(context: *anyopaque) *Gate {
        return @ptrCast(@alignCast(context));
    }

    fn released(self: *Gate) bool {
        if (self.open.load(.acquire)) return true;
        const other = self.released_by orelse return false;
        return other.load(.acquire);
    }

    fn tracked(context: *anyopaque, root: []const u8, gpa: Allocator) io_seam.TrackedError![][]u8 {
        const self = of(context);
        self.entered.store(true, .release);
        const deadline = now() + gate_patience_ns;
        while (!self.released()) {
            if (now() > deadline) {
                self.gave_up.store(true, .release);
                break;
            }
            pause(1);
        }
        if (self.fail_listing) return error.GitFailed;
        return self.inner.tracked(root, gpa);
    }

    fn readFile(context: *anyopaque, path: []const u8, gpa: Allocator, limit: usize) io_seam.ReadError![]u8 {
        const self = of(context);
        if (std.mem.endsWith(u8, path, ".ts")) {
            const nth = self.source_reads.fetchAdd(1, .acq_rel) + 1;
            if (nth == self.cancel_at_read) self.cancel.?.store(true, .release);
        }
        return self.inner.readFile(path, gpa, limit);
    }

    fn createFile(context: *anyopaque, path: []const u8, bytes: []const u8, options: io_seam.CreateOptions) io_seam.WriteError!void {
        const self = of(context);
        _ = self.creates.fetchAdd(1, .acq_rel);
        return self.inner.createFile(path, bytes, options);
    }

    fn stat(context: *anyopaque, path: []const u8, follow: io_seam.Follow) io_seam.StatError!io_seam.Stat {
        return of(context).inner.stat(path, follow);
    }

    fn list(context: *anyopaque, dir: []const u8, visitor: io_seam.Visitor) io_seam.ListError!void {
        return of(context).inner.list(dir, visitor);
    }

    fn realPath(context: *anyopaque, path: []const u8, gpa: Allocator) io_seam.PathError![:0]u8 {
        return of(context).inner.realPath(path, gpa);
    }

    fn renameReplace(context: *anyopaque, from: []const u8, to: []const u8) io_seam.WriteError!void {
        return of(context).inner.renameReplace(from, to);
    }

    fn deleteFile(context: *anyopaque, path: []const u8) io_seam.WriteError!void {
        return of(context).inner.deleteFile(path);
    }

    fn makePath(context: *anyopaque, path: []const u8) io_seam.WriteError!void {
        return of(context).inner.makePath(path);
    }
};

const Call = struct {
    session: *map_tools.Session,
    evidence: bool = false,
    done: std.atomic.Value(bool) = .init(false),
    text: ?[]u8 = null,
    is_error: bool = false,

    fn run(self: *Call) void {
        defer self.done.store(true, .release);
        const arguments = if (self.evidence)
            \\{"names":["step0x1"]}
        else
            \\{"question":"which step scales the input","names":["step0x1"]}
        ;
        const parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, arguments, .{}) catch return;
        defer parsed.deinit();
        const result = (if (self.evidence) self.session.evidenceTool(testing.allocator, parsed.value) else self.session.explore(testing.allocator, parsed.value)) catch return;
        self.text = result.text;
        self.is_error = result.is_error;
    }

    fn free(self: *Call) void {
        if (self.text) |t| testing.allocator.free(t);
    }
};

fn gated(repo: *const Repo, gate: *Gate) !*map_tools.Session {
    const session = try map_tools.Session.create(testing.allocator, testing.io, repo.runtime, repo.root);
    session.store_override = repo.store_path;
    session.seam_override = gate.seam(session.real.seam());
    return session;
}

fn reply(served: *server.Served, runtime: *Runtime, line: []const u8) ![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    try testing.expect(try served.handle(runtime, line, &buffer.writer));
    return testing.allocator.dupe(u8, buffer.written());
}

test "first reply: initialize and tools/list are answered while the fact store of the repository is still being built" {
    var repo = try Repo.make(large_files, large_functions);
    defer repo.close();

    var served: server.Served = undefined;
    const began = now();
    served.open(testing.allocator, testing.io, repo.runtime, .{}, .{ .root = repo.root, .fact_store = repo.store_path });
    defer served.close();
    const initialized = try reply(&served, repo.runtime,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
    );
    defer testing.allocator.free(initialized);
    const listed = try reply(&served, repo.runtime,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    );
    defer testing.allocator.free(listed);
    const replied = now();

    const session = served.map_session.?;
    const phase_at_reply = session.phase.load(.acquire);
    _ = session.settle();
    const built = now();

    try testing.expect(std.mem.indexOf(u8, initialized, "\"serverInfo\"") != null);
    try testing.expect(std.mem.indexOf(u8, listed, "\"emetgate_explore\"") != null);
    try testing.expectEqual(map_tools.Phase.building, phase_at_reply);
    try testing.expectEqual(map_tools.Phase.ready, session.phase.load(.acquire));
    try testing.expect(repo.storeWritten());
    errdefer std.debug.print("first reply after {d} ms, store built after {d} ms\n", .{ @divTrunc(replied - began, std.time.ns_per_ms), @divTrunc(built - began, std.time.ns_per_ms) });
    try testing.expect(replied - began < first_reply_limit_ns);
    try testing.expect((replied - began) * build_to_reply_ratio < built - began);
}

test "first reply: an explore call that arrives while the fact store is being built waits for it and answers from the whole store" {
    var repo = try Repo.make(small_files, small_functions);
    defer repo.close();
    var gate: Gate = .{ .inner = undefined };
    const session = try gated(&repo, &gate);
    defer session.destroy();

    session.start();
    try gate.waitEntered();
    var call: Call = .{ .session = session };
    defer call.free();
    const caller = try std.Thread.spawn(.{}, Call.run, .{&call});
    pause(50);
    const answered_early = call.done.load(.acquire);
    const phase_while_waiting = session.phase.load(.acquire);
    gate.open.store(true, .release);
    caller.join();

    try testing.expect(!answered_early);
    try testing.expectEqual(map_tools.Phase.building, phase_while_waiting);
    try testing.expect(!gate.gave_up.load(.acquire));
    try testing.expect(!call.is_error);
    try testing.expect(std.mem.indexOf(u8, call.text.?, "src/part0.ts:6 step0x1") != null);
    try testing.expect(std.mem.indexOf(u8, call.text.?, "const scaled = input * 3;") != null);
    try testing.expectEqualStrings(map_tools.waited_note, session.takeNote().?);
    try testing.expect(session.takeNote() == null);
}

test "first reply: an evidence call that arrives while the fact store is being built waits for it and answers from the whole store" {
    var repo = try Repo.make(small_files, small_functions);
    defer repo.close();
    var gate: Gate = .{ .inner = undefined };
    const session = try gated(&repo, &gate);
    defer session.destroy();

    session.start();
    try gate.waitEntered();
    var call: Call = .{ .session = session, .evidence = true };
    defer call.free();
    const caller = try std.Thread.spawn(.{}, Call.run, .{&call});
    pause(50);
    const answered_early = call.done.load(.acquire);
    gate.open.store(true, .release);
    caller.join();

    try testing.expect(!answered_early);
    try testing.expect(!call.is_error);
    try testing.expect(std.mem.indexOf(u8, call.text.?, "const scaled = input * 3;") != null);
}

test "first reply: a fact store build that fails leaves explore and evidence refused instead of answered from the part that was read" {
    var repo = try Repo.make(small_files, small_functions);
    defer repo.close();
    var gate: Gate = .{ .inner = undefined, .fail_listing = true };
    gate.open.store(true, .release);
    const session = try gated(&repo, &gate);
    defer session.destroy();

    session.start();
    var explore: Call = .{ .session = session };
    defer explore.free();
    explore.run();
    var evidence: Call = .{ .session = session, .evidence = true };
    defer evidence.free();
    evidence.run();

    try testing.expectEqual(map_tools.Phase.failed, session.phase.load(.acquire));
    try testing.expect(explore.is_error);
    try testing.expectEqualStrings("explore is unavailable: the repository could not be read", explore.text.?);
    try testing.expect(evidence.is_error);
    try testing.expectEqualStrings("evidence is unavailable: the repository could not be read", evidence.text.?);
    try testing.expectEqualStrings("GitFailed", session.takeNote().?);
    try testing.expect(!repo.storeWritten());
}

test "first reply: closing the session while the fact store is being built stops the build and writes no store" {
    var repo = try Repo.make(small_files, small_functions);
    defer repo.close();
    var gate: Gate = .{ .inner = undefined };
    const session = try gated(&repo, &gate);
    gate.released_by = &session.cancel;

    session.start();
    try gate.waitEntered();
    session.destroy();

    try testing.expect(!gate.gave_up.load(.acquire));
    try testing.expectEqual(@as(usize, 0), gate.source_reads.load(.acquire));
    try testing.expectEqual(@as(usize, 0), gate.creates.load(.acquire));
    try testing.expect(!repo.storeWritten());
}

fn canceledRefresh(repo: *const Repo, cancel_at_read: usize) !Gate {
    var real = io_seam.Real.init(testing.allocator, testing.io);
    defer real.deinit();
    var cancel: std.atomic.Value(bool) = .init(false);
    var gate: Gate = .{ .inner = undefined, .cancel = &cancel, .cancel_at_read = cancel_at_read };
    gate.open.store(true, .release);
    const store = try fact_store.Repo.open(testing.allocator, gate.seam(real.seam()), repo.runtime, .{ .root_abs = repo.root, .store_path = repo.store_path, .threads = 1, .cancel = &cancel });
    defer store.deinit();
    try testing.expectError(error.Canceled, store.refresh());
    gate.cancel = null;
    return gate;
}

test "first reply: a refresh canceled while it reads the files stops before the next file" {
    var repo = try Repo.make(small_files, small_functions);
    defer repo.close();
    const gate = try canceledRefresh(&repo, 1);

    try testing.expectEqual(@as(usize, 1), gate.source_reads.load(.acquire));
    try testing.expectEqual(@as(usize, 0), gate.creates.load(.acquire));
    try testing.expect(!repo.storeWritten());
}

test "first reply: a refresh canceled after the last file is read does not write the store" {
    var repo = try Repo.make(small_files, small_functions);
    defer repo.close();
    const gate = try canceledRefresh(&repo, small_files);

    try testing.expectEqual(@as(usize, small_files), gate.source_reads.load(.acquire));
    try testing.expectEqual(@as(usize, 0), gate.creates.load(.acquire));
    try testing.expect(!repo.storeWritten());
}
