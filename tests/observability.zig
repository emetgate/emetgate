const std = @import("std");
const builtin = @import("builtin");
const symbol = @import("../src/engine/symbol.zig");
const runner = @import("../src/platform/runner.zig");
const server = @import("../src/protocol/server.zig");
const telemetry = @import("../src/protocol/telemetry.zig");
const Runtime = @import("../src/engine/runtime.zig").Runtime;
const Snapshot = @import("../src/engine/loader.zig").Snapshot;

const testing = std.testing;
const Allocating = std.Io.Writer.Allocating;

const source = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const committed_source = "export function add(a: number, b: number): number {\n  return a - b;\n}\n";

const Repo = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,

    fn init() !Repo {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/math.ts", .data = source });
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
        errdefer testing.allocator.free(root_abs);
        try run(root_abs, &.{ "git", "init", "-q" });
        try run(root_abs, &.{ "git", "config", "user.email", "t@t" });
        try run(root_abs, &.{ "git", "config", "user.name", "t" });
        try run(root_abs, &.{ "git", "add", "." });
        try run(root_abs, &.{ "git", "commit", "-q", "-m", "init" });
        return .{ .tmp = tmp, .root_abs = root_abs };
    }

    fn deinit(self: *Repo) void {
        testing.allocator.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn under(self: *Repo, sub: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, "{s}\\{s}", .{ self.root_abs, sub });
    }

    fn onDisk(self: *Repo) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, "repo/src/math.ts", testing.allocator, .unlimited);
    }
};

fn run(cwd: []const u8, argv: []const []const u8) !void {
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = argv, .cwd = .{ .path = cwd } });
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn hashOfAdd(runtime: *Runtime, file: []const u8) !symbol.Hash {
    return hashOfRef(runtime, file, "add");
}

fn hashOfRef(runtime: *Runtime, file: []const u8, name: []const u8) !symbol.Hash {
    const snapshot = try Snapshot.load(runtime, testing.io, .cwd(), file);
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    const ref = try symbol.Ref.parse(testing.allocator, name);
    defer ref.deinit(testing.allocator);
    return (try table.resolve(ref)).hash;
}

fn writeCall(w: *std.Io.Writer, tool: []const u8, file: []const u8, hash_hex: ?[]const u8, body: ?[]const u8) !void {
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("jsonrpc");
    try js.write("2.0");
    try js.objectField("id");
    try js.write(1);
    try js.objectField("method");
    try js.write("tools/call");
    try js.objectField("params");
    try js.beginObject();
    try js.objectField("name");
    try js.write(tool);
    try js.objectField("arguments");
    try js.beginObject();
    try js.objectField("file");
    try js.write(file);
    if (hash_hex) |h| {
        try js.objectField("symbol");
        try js.write("add");
        try js.objectField("hash");
        try js.write(h);
    }
    if (body) |b| {
        try js.objectField("body");
        try js.write(b);
    }
    try js.endObject();
    try js.endObject();
    try js.endObject();
}

fn call(runtime: *Runtime, line: []const u8, observer: ?*telemetry.Observer, policy: server.Policy) ![]u8 {
    var buffer: Allocating = .init(testing.allocator);
    defer buffer.deinit();
    _ = try server.handleMessageObserved(testing.allocator, testing.io, runtime, line, &buffer.writer, observer, policy);
    return testing.allocator.dupe(u8, buffer.written());
}

const Step = struct { body: []const u8, cmd: []const u8, stale: bool };

const steps = [_]Step{
    .{ .body = "{\n  return a - b;\n}", .cmd = "cmd /c exit 1", .stale = false },
    .{ .body = "{\n  return a - b;\n}", .cmd = "cmd /c exit 0", .stale = false },
    .{ .body = "{\n  return a * b;\n}", .cmd = "cmd /c exit 0", .stale = true },
};

fn runScenario(runtime: *Runtime, repo: *Repo, observer: ?*telemetry.Observer) ![steps.len][]u8 {
    var out: [steps.len][]u8 = undefined;
    var produced: usize = 0;
    errdefer for (out[0..produced]) |r| testing.allocator.free(r);
    const file = try repo.under("src\\math.ts");
    defer testing.allocator.free(file);
    for (steps, 0..) |step, i| {
        const hash = if (step.stale) symbol.hashOf("stale") else try hashOfAdd(runtime, file);
        const hex = symbol.formatHash(hash);
        var line: Allocating = .init(testing.allocator);
        defer line.deinit();
        try writeCall(&line.writer, "emetgate_try", file, hex[0..], step.body);
        out[i] = try call(runtime, line.written(), observer, .{ .test_command = step.cmd, .root = repo.root_abs });
        produced = i + 1;
    }
    return out;
}

fn freeAll(responses: [steps.len][]u8) void {
    for (responses) |r| testing.allocator.free(r);
}

fn stripFooter(response: []const u8) ![]u8 {
    const start = std.mem.indexOf(u8, response, "\\nemetgate ") orelse return error.NoFooter;
    const end = std.mem.indexOfPos(u8, response, start, "\"}],\"isError\"") orelse return error.NoFooter;
    return std.mem.concat(testing.allocator, u8, &.{ response[0..start], response[end..] });
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected \"{s}\" in \"{s}\"\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

test "fail-soft: a broken event log never changes a tool result or what reaches disk" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var plain = try Repo.init();
    defer plain.deinit();
    var healthy = try Repo.init();
    defer healthy.deinit();
    var dir_sabotage = try Repo.init();
    defer dir_sabotage.deinit();
    var file_sabotage = try Repo.init();
    defer file_sabotage.deinit();

    try dir_sabotage.tmp.dir.createDirPath(testing.io, "repo/.emetgate/events.ndjson");
    try file_sabotage.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/blocker", .data = "x" });

    const healthy_ws = try healthy.under(".emetgate");
    defer testing.allocator.free(healthy_ws);
    const dir_ws = try dir_sabotage.under(".emetgate");
    defer testing.allocator.free(dir_ws);
    const file_ws = try file_sabotage.under("blocker\\.emetgate");
    defer testing.allocator.free(file_ws);

    var healthy_obs: telemetry.Observer = .{ .workspace_abs = healthy_ws };
    var dir_obs: telemetry.Observer = .{ .workspace_abs = dir_ws };
    var file_obs: telemetry.Observer = .{ .workspace_abs = file_ws };

    const plain_out = try runScenario(runtime, &plain, null);
    defer freeAll(plain_out);
    const healthy_out = try runScenario(runtime, &healthy, &healthy_obs);
    defer freeAll(healthy_out);
    const dir_out = try runScenario(runtime, &dir_sabotage, &dir_obs);
    defer freeAll(dir_out);
    const file_out = try runScenario(runtime, &file_sabotage, &file_obs);
    defer freeAll(file_out);

    for (0..steps.len) |i| {
        try testing.expectEqualStrings(healthy_out[i], dir_out[i]);
        try testing.expectEqualStrings(healthy_out[i], file_out[i]);
        const stripped = try stripFooter(healthy_out[i]);
        defer testing.allocator.free(stripped);
        try testing.expectEqualStrings(plain_out[i], stripped);
    }

    try expectContains(healthy_out[0], "emetgate ✗ rejected · tests_failed · UNBOUNDED · gate full · disk untouched · session 0 edits");
    try expectContains(healthy_out[1], "emetgate ✓ committed · UNBOUNDED · gate full · sent ");
    try expectContains(healthy_out[1], " / file ");
    try expectContains(healthy_out[1], " chars · session 1 edits");
    try expectContains(healthy_out[2], "emetgate ✗ HashMismatch · disk untouched · session 1 edits");

    for ([_]*Repo{ &plain, &healthy, &dir_sabotage, &file_sabotage }) |repo| {
        const on_disk = try repo.onDisk();
        defer testing.allocator.free(on_disk);
        try testing.expectEqualStrings(committed_source, on_disk);
    }

    const events = try healthy.tmp.dir.readFileAlloc(testing.io, "repo/.emetgate/events.ndjson", testing.allocator, .unlimited);
    defer testing.allocator.free(events);
    try testing.expectEqual(@as(usize, steps.len), std.mem.count(u8, events, "\n"));
    try expectContains(events, "\"result\":\"rejected\"");
    try expectContains(events, "\"result\":\"committed\"");
    try expectContains(events, "\"result\":\"HashMismatch\"");
    try expectContains(events, "\"gate\":\"full\"");
    try expectContains(events, "\"confidence\":\"unbounded\"");

    const ignore = try healthy.tmp.dir.readFileAlloc(testing.io, "repo/.emetgate/.gitignore", testing.allocator, .unlimited);
    defer testing.allocator.free(ignore);
    try testing.expectEqualStrings("*\n", ignore);
    const status = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "git", "status", "--porcelain", "--untracked-files=all" }, .cwd = .{ .path = healthy.root_abs } });
    defer testing.allocator.free(status.stdout);
    defer testing.allocator.free(status.stderr);
    if (std.mem.indexOf(u8, status.stdout, ".emetgate") != null) return error.TestEmetgateVisibleToGit;

    var still_dir = try dir_sabotage.tmp.dir.openDir(testing.io, "repo/.emetgate/events.ndjson", .{});
    still_dir.close(testing.io);
    const blocker = try file_sabotage.tmp.dir.readFileAlloc(testing.io, "repo/blocker", testing.allocator, .unlimited);
    defer testing.allocator.free(blocker);
    try testing.expectEqualStrings("x", blocker);
}

test "gate-consistency: the footer shows exactly the gate the runner chose" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var repo = try Repo.init();
    defer repo.deinit();
    const exported = try repo.under("src\\math.ts");
    defer testing.allocator.free(exported);
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/private.ts", .data = "function add(a: number, b: number): number {\n  return a + b;\n}\nadd(1, 2);\n" });
    const private = try repo.under("src\\private.ts");
    defer testing.allocator.free(private);

    const Case = struct { file: []const u8, scoped: ?[]const u8, expected: runner.Gate, body: []const u8, label: []const u8 };
    const cases = [_]Case{
        .{ .file = exported, .scoped = null, .expected = .full, .body = "{\n  return a - b;\n}", .label = " · gate full" },
        .{ .file = exported, .scoped = "cmd /c exit 0", .expected = .full, .body = "{\n  return a * b;\n}", .label = " · gate full" },
        .{ .file = private, .scoped = "cmd /c exit 0", .expected = .scoped, .body = "{\n  return a * b;\n}", .label = " · gate scoped" },
    };
    for (cases) |c| {
        var trace: runner.Trace = .{};
        const result = try runner.tryMutate(testing.allocator, testing.io, runtime, .{
            .file_abs = c.file,
            .ref_text = "add",
            .expected_hash = try hashOfAdd(runtime, c.file),
            .new_body = c.body,
            .test_command = "cmd /c exit 0",
            .test_scoped_cmd = c.scoped,
            .trace = &trace,
        });
        defer result.deinit(testing.allocator);
        try testing.expect(result == .committed);
        try testing.expectEqual(runner.chooseGate(trace.confidence.?, c.scoped != null), trace.gate.?);
        try testing.expectEqual(c.expected, trace.gate.?);

        var buffer: Allocating = .init(testing.allocator);
        defer buffer.deinit();
        try telemetry.renderFooter(&buffer.writer, .{ .tool = "emetgate_try", .outcome = .committed, .mutating = true, .edits = 1, .trace = trace }, .{});
        try expectContains(buffer.written(), c.label);
    }
}

test "fail-soft: events never follow a .emetgate junction out of the repo" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var repo = try Repo.init();
    defer repo.deinit();

    try repo.tmp.dir.createDirPath(testing.io, "victim");
    const victim = try repo.tmp.dir.realPathFileAlloc(testing.io, "victim", testing.allocator);
    defer testing.allocator.free(victim);
    const link = try repo.under(".emetgate");
    defer testing.allocator.free(link);
    try run(repo.root_abs, &.{ "cmd", "/c", "mklink", "/J", link, victim });
    defer std.Io.Dir.cwd().deleteDir(testing.io, link) catch {};

    var observer: telemetry.Observer = .{ .workspace_abs = link };
    const file = try repo.under("src\\math.ts");
    defer testing.allocator.free(file);
    const hex = symbol.formatHash(try hashOfAdd(runtime, file));
    var line: Allocating = .init(testing.allocator);
    defer line.deinit();
    try writeCall(&line.writer, "emetgate_try", file, hex[0..], "{\n  return a - b;\n}");

    const response = try call(runtime, line.written(), &observer, .{ .test_command = "cmd /c exit 0", .root = repo.root_abs });
    defer testing.allocator.free(response);
    try expectContains(response, "emetgate ");
    try testing.expectError(error.FileNotFound, repo.tmp.dir.access(testing.io, "victim/events.ndjson", .{}));
}

fn writeBatchEdit(js: *std.json.Stringify, file: []const u8, name: []const u8, hash_hex: []const u8, body: []const u8) !void {
    try js.beginObject();
    try js.objectField("file");
    try js.write(file);
    try js.objectField("symbol");
    try js.write(name);
    try js.objectField("hash");
    try js.write(hash_hex);
    try js.objectField("body");
    try js.write(body);
    try js.endObject();
}

test "a committed batch counts every edit in the footer and logs the full gate" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/twice.ts", .data = "export function twice(x: number): number {\n  return x + x;\n}\n" });
    try run(repo.root_abs, &.{ "git", "add", "." });
    try run(repo.root_abs, &.{ "git", "commit", "-q", "-m", "twice" });

    const ws = try repo.under(".emetgate");
    defer testing.allocator.free(ws);
    var observer: telemetry.Observer = .{ .workspace_abs = ws };
    const math = try repo.under("src\\math.ts");
    defer testing.allocator.free(math);
    const twice = try repo.under("src\\twice.ts");
    defer testing.allocator.free(twice);
    const math_hex = symbol.formatHash(try hashOfRef(runtime, math, "add"));
    const twice_hex = symbol.formatHash(try hashOfRef(runtime, twice, "twice"));

    var line: Allocating = .init(testing.allocator);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.beginObject();
    try js.objectField("jsonrpc");
    try js.write("2.0");
    try js.objectField("id");
    try js.write(1);
    try js.objectField("method");
    try js.write("tools/call");
    try js.objectField("params");
    try js.beginObject();
    try js.objectField("name");
    try js.write("emetgate_try_batch");
    try js.objectField("arguments");
    try js.beginObject();
    try js.objectField("edits");
    try js.beginArray();
    try writeBatchEdit(&js, math, "add", math_hex[0..], "{\n  return a - b;\n}");
    try writeBatchEdit(&js, twice, "twice", twice_hex[0..], "{\n  return x * 2;\n}");
    try js.endArray();
    try js.endObject();
    try js.endObject();
    try js.endObject();

    const response = try call(runtime, line.written(), &observer, .{ .test_command = "cmd /c exit 0", .root = repo.root_abs });
    defer testing.allocator.free(response);
    try expectContains(response, "emetgate ✓ committed · gate full · sent ");
    try expectContains(response, " chars · session 2 edits");

    const events = try repo.tmp.dir.readFileAlloc(testing.io, "repo/.emetgate/events.ndjson", testing.allocator, .unlimited);
    defer testing.allocator.free(events);
    try expectContains(events, "\"tool\":\"emetgate_try_batch\"");
    try expectContains(events, "\"result\":\"committed\"");
    try expectContains(events, "\"gate\":\"full\"");
    try expectContains(events, "\"confidence\":null");
}

test "a failure after the commit began is reported as commit phase, never disk untouched" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var repo = try Repo.init();
    defer repo.deinit();
    const ws = try repo.under(".emetgate");
    defer testing.allocator.free(ws);
    var observer: telemetry.Observer = .{ .workspace_abs = ws };
    const file = try repo.under("src\\math.ts");
    defer testing.allocator.free(file);

    const racing_cmd = try std.fmt.allocPrint(testing.allocator, "cmd /c echo // external>>{s}", .{file});
    defer testing.allocator.free(racing_cmd);
    const hex = symbol.formatHash(try hashOfAdd(runtime, file));
    var line: Allocating = .init(testing.allocator);
    defer line.deinit();
    try writeCall(&line.writer, "emetgate_try", file, hex[0..], "{\n  return a - b;\n}");

    const response = try call(runtime, line.written(), &observer, .{ .test_command = racing_cmd, .root = repo.root_abs });
    defer testing.allocator.free(response);
    try expectContains(response, "\"isError\":true");
    try expectContains(response, "failed in commit phase, run emetgate recover");
    if (std.mem.indexOf(u8, response, "disk untouched") != null) return error.TestClaimedDiskUntouched;

    const on_disk = try repo.onDisk();
    defer testing.allocator.free(on_disk);
    try testing.expect(!std.mem.eql(u8, committed_source, on_disk));
}

test "fail-soft: an events file symlinked outside the repo is never written through" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var repo = try Repo.init();
    defer repo.deinit();

    const outside = "export const SECRET = 1;\n";
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "outside.txt", .data = outside });
    try repo.tmp.dir.createDirPath(testing.io, "repo/.emetgate");
    const target = try repo.tmp.dir.realPathFileAlloc(testing.io, "outside.txt", testing.allocator);
    defer testing.allocator.free(target);
    repo.tmp.dir.symLink(testing.io, target, "repo/.emetgate/events.ndjson", .{}) catch return error.SkipZigTest;

    const ws = try repo.under(".emetgate");
    defer testing.allocator.free(ws);
    var observer: telemetry.Observer = .{ .workspace_abs = ws };
    const file = try repo.under("src\\math.ts");
    defer testing.allocator.free(file);
    const hex = symbol.formatHash(try hashOfAdd(runtime, file));
    var line: Allocating = .init(testing.allocator);
    defer line.deinit();
    try writeCall(&line.writer, "emetgate_try", file, hex[0..], "{\n  return a - b;\n}");

    const response = try call(runtime, line.written(), &observer, .{ .test_command = "cmd /c exit 0", .root = repo.root_abs });
    defer testing.allocator.free(response);
    try expectContains(response, "emetgate ✓ committed");

    const after = try repo.tmp.dir.readFileAlloc(testing.io, "outside.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(outside, after);
}

test "a read tool logs the chars it can compute and leaves the rest null" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(ws);
    var observer: telemetry.Observer = .{ .workspace_abs = ws };
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".gitignore", .data = "keep-mine\n" });

    const fixture = "tests/fixtures/functions.ts";
    const fixture_bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, fixture, testing.allocator, .unlimited);
    defer testing.allocator.free(fixture_bytes);

    var line: Allocating = .init(testing.allocator);
    defer line.deinit();
    try writeCall(&line.writer, "emetgate_skeleton", fixture, null, null);
    const response = try call(runtime, line.written(), &observer, .{});
    defer testing.allocator.free(response);
    try expectContains(response, "emetgate ✓ skeleton · read ");
    try expectContains(response, " chars · session 0 edits");

    const ignore = try tmp.dir.readFileAlloc(testing.io, ".gitignore", testing.allocator, .unlimited);
    defer testing.allocator.free(ignore);
    try testing.expectEqualStrings("keep-mine\n", ignore);

    const events = try tmp.dir.readFileAlloc(testing.io, telemetry.events_file, testing.allocator, .unlimited);
    defer testing.allocator.free(events);
    try expectContains(events, "\"tool\":\"emetgate_skeleton\"");
    try expectContains(events, "\"chars_sr\":null");
    try expectContains(events, "\"gate\":null");
    const full = try std.fmt.allocPrint(testing.allocator, "\"chars_fullfile\":{d}", .{fixture_bytes.len});
    defer testing.allocator.free(full);
    try expectContains(events, full);
}
