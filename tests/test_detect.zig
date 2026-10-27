const std = @import("std");
const builtin = @import("builtin");
const test_command = @import("emetgate").test_command;
const server = @import("emetgate").server;
const handlers = @import("emetgate").handlers;
const telemetry = @import("emetgate").telemetry;
const Runtime = @import("emetgate").runtime.Runtime;
const fixture = @import("ts_fixture.zig");
const run_fixture = @import("run_fixture.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Policy = server.Policy;
const Value = std.json.Value;

fn detectedWith(files: []const [2][]const u8) !?[]const u8 {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for (files) |file| {
        if (std.fs.path.dirnamePosix(file[0])) |parent| try tmp.dir.createDirPath(testing.io, parent);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = file[0], .data = file[1] });
    }
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    return test_command.detectIn(gpa, testing.io, root);
}

fn expectDetected(want: ?[]const u8, files: []const [2][]const u8) !void {
    const got = try detectedWith(files);
    if (want) |command| {
        try testing.expectEqualStrings(command, got orelse return error.TestExpectedCommand);
    } else try testing.expect(got == null);
}

test "test detection: each project marker names its test command" {
    try expectDetected("npm test", &.{.{ "package.json", "{\"scripts\":{\"test\":\"node --test\"}}" }});
    try expectDetected("zig build test", &.{.{ "build.zig", "" }});
    try expectDetected("cargo test", &.{.{ "Cargo.toml", "" }});
    try expectDetected("go test ./...", &.{.{ "go.mod", "" }});
    try expectDetected("python -m pytest", &.{.{ "pyproject.toml", "" }});
    try expectDetected("python -m pytest", &.{.{ "pytest.ini", "" }});
    try expectDetected("dotnet test", &.{.{ "app.csproj", "" }});
    try expectDetected("dotnet test", &.{.{ "App.SLN", "" }});
}

test "test detection: an empty folder, npm's placeholder script and a package without scripts name no test command" {
    try expectDetected(null, &.{});
    try expectDetected(null, &.{.{ "package.json", "{\"scripts\":{\"test\":\"echo \\\"Error: no test specified\\\" && exit 1\"}}" }});
    try expectDetected(null, &.{.{ "package.json", "{\"name\":\"x\"}" }});
    try expectDetected(null, &.{.{ "package.json", "{\"scripts\":{\"test\":\"\"}}" }});
    try expectDetected(null, &.{.{ "package.json", "not json" }});
    try expectDetected(null, &.{.{ "README.md", "" }});
}

test "test detection: a dotnet solution, or the one test project in a subfolder, names its test command" {
    try expectDetected("dotnet test", &.{.{ "App.slnx", "" }});
    try expectDetected("dotnet test", &.{.{ "App.fsproj", "" }});
    try expectDetected("dotnet test \"App.Tests\\App.Tests.csproj\"", &.{ .{ "App/App.csproj", "" }, .{ "App.Tests/App.Tests.csproj", "" } });
    try expectDetected("dotnet test \"tests\\Calc.Tests\\Calc.Tests.csproj\"",&.{ .{ "src/Calc/Calc.csproj", "" }, .{ "tests/Calc.Tests/Calc.Tests.csproj", "" } });
    try expectDetected(null, &.{.{ "App/App.csproj", "" }});
    try expectDetected(null, &.{ .{ "A.Tests/A.Tests.csproj", "" }, .{ "B.Tests/B.Tests.csproj", "" } });
    try expectDetected(null, &.{.{ "App/bin/Debug/X.Tests.csproj", "" }});
    try expectDetected(null, &.{.{ "a/b/c/Deep.Tests.csproj", "" }});
}

test "test detection: a package test script wins over the other markers" {
    try expectDetected("npm test", &.{ .{ "build.zig", "" }, .{ "package.json", "{\"scripts\":{\"test\":\"node --test\"}}" } });
}

test "test detection: detect mode resolves per write, falls back to an unverified pass, and reports it once" {
    var repo = try fixture.TsRepo.init(&.{.{ .rel = "a.txt", .text = "x\n" }});
    defer repo.deinit();
    const file = try repo.abs(gpa, "src/new.js");
    defer gpa.free(file);

    _ = test_command.takeUnverified();
    const none = try test_command.resolveTestCommand(gpa, testing.io, file, test_command.detect, false);
    defer gpa.free(none);
    try testing.expectEqualStrings(test_command.unverified_command, none);
    try testing.expect(test_command.takeUnverified());
    try testing.expect(!test_command.takeUnverified());

    try repo.write("package.json", "{\"scripts\":{\"test\":\"node --test\"}}");
    const found = try test_command.resolveTestCommand(gpa, testing.io, file, test_command.detect, false);
    defer gpa.free(found);
    try testing.expectEqualStrings("npm test", found);
    try testing.expect(!test_command.takeUnverified());

    try testing.expectError(error.NoTestCommand, test_command.resolveTestCommand(gpa, testing.io, file, "", false));
    try testing.expect(!test_command.takeUnverified());
}

test "test detection: --detect-test is parsed once" {
    const policy = server.parsePolicy(&[_][]const u8{"--detect-test"}) orelse return error.TestExpectedPolicy;
    try testing.expect(policy.detect_test);
    try testing.expect(!(server.parsePolicy(&[_][]const u8{}) orelse return error.TestExpectedPolicy).detect_test);
    try testing.expect(server.parsePolicy(&[_][]const u8{ "--detect-test", "--detect-test" }) == null);
}

const Call = struct {
    arena_state: std.heap.ArenaAllocator,
    value: Value = undefined,
    is_error: bool = false,
    text: []const u8 = "",

    fn deinit(self: *Call) void {
        self.arena_state.deinit();
    }

    fn status(self: *Call) []const u8 {
        return self.value.object.get("status").?.string;
    }
};

fn create(repo: *fixture.TsRepo, runtime: *Runtime, rel: []const u8, body: []const u8, policy: Policy) !Call {
    var call: Call = .{ .arena_state = std.heap.ArenaAllocator.init(gpa) };
    errdefer call.deinit();
    const arena = call.arena_state.allocator();
    var map: std.json.ObjectMap = .empty;
    try map.put(arena, "file", .{ .string = try repo.abs(arena, rel) });
    try map.put(arena, "symbol", .{ .string = "fresh" });
    try map.put(arena, "hash", .{ .string = "absent" });
    try map.put(arena, "body", .{ .string = body });
    var event: telemetry.Event = .{ .tool = "emetgate_try" };
    var with_root = policy;
    with_root.root = repo.root_abs;
    const result = try handlers.callTool(gpa, testing.io, runtime, "emetgate_try", .{ .object = map }, &event, with_root);
    defer gpa.free(result.text);
    call.text = try arena.dupe(u8, result.text);
    call.is_error = result.is_error;
    call.value = try std.json.parseFromSliceLeaky(Value, arena, call.text, .{});
    return call;
}

const fresh_body = "export function fresh(): number {\n  return 1;\n}\n";

test "test detection: a write in a project with no test command lands as unverified_no_tests and says why" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.TsRepo.init(&.{.{ .rel = "a.txt", .text = "x\n" }});
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try create(&repo, runtime, "fresh.ts", fresh_body, .{ .detect_test = true });
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings(test_command.unverified_status, reply.status());
    try testing.expect(std.mem.startsWith(u8, reply.value.object.get("tests").?.string, "none"));
    try testing.expect(reply.text.len < 600);
    try testing.expect(std.mem.indexOfScalar(u8, std.mem.trimEnd(u8, reply.text, "\n"), '\n') == null);
    try testing.expect(reply.value.object.get("symbols") == null);
    try testing.expect(reply.value.object.get("files").?.array.items.len == 1);
    const on_disk = try repo.read("fresh.ts");
    defer gpa.free(on_disk);
    try testing.expectEqualStrings(fresh_body, on_disk);
    try testing.expect(!test_command.takeUnverified());
}

test "test detection: a write that ran a test without a commit says written, not committed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.TsRepo.init(&.{.{ .rel = "a.txt", .text = "x\n" }});
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try create(&repo, runtime, "fresh.ts", fresh_body, .{ .test_command = "cmd /c exit 0" });
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings("written", reply.status());
    try testing.expect(reply.value.object.get("tests") == null);
}

test "test detection: a server with no test command and no detection refuses the write with the fix for the user" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.TsRepo.init(&.{.{ .rel = "a.txt", .text = "x\n" }});
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try create(&repo, runtime, "fresh.ts", fresh_body, .{});
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings("NoTestCommand", reply.value.object.get("error").?.string);
    try testing.expect(std.mem.indexOf(u8, reply.value.object.get("fix").?.string, "--detect-test") != null);
}

test "test detection: a failing detected test still rejects the write" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.TsRepo.init(&.{ .{ .rel = "pytest.ini", .text = "" }, .{ .rel = "test_fails.py", .text = "import os\n\ndef test_fails():\n    assert not os.path.exists(\"fresh.ts\")\n" } });
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try create(&repo, runtime, "fresh.ts", fresh_body, .{ .detect_test = true });
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(!std.mem.eql(u8, test_command.unverified_status, reply.status()));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, try repo.abs(reply.arena_state.allocator(), "fresh.ts"), .{}));
}

test "test detection: the run allowlist carries the given or detected test command" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try run_fixture.Repo.init(&.{.{ .name = "build.zig", .body = "" }});
    defer repo.deinit();

    var given_policy = run_fixture.policyWith(repo.root_abs, &.{"npm run lint"});
    given_policy.test_command = "npm test";
    var given = try run_fixture.call(given_policy, .{});
    defer given.deinit();
    const listed = (try given.field("commands")).?.array.items;
    try testing.expectEqual(@as(usize, 2), listed.len);
    try testing.expectEqualStrings("npm test", listed[1].string);

    var detect_policy = run_fixture.policyWith(repo.root_abs, &.{});
    detect_policy.detect_test = true;
    var detected = try run_fixture.call(detect_policy, .{});
    defer detected.deinit();
    const found = (try detected.field("commands")).?.array.items;
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("zig build test", found[0].string);

    var plain = try run_fixture.call(run_fixture.policyWith(repo.root_abs, &.{}), .{});
    defer plain.deinit();
    try testing.expectEqual(@as(usize, 0), (try plain.field("commands")).?.array.items.len);
}
