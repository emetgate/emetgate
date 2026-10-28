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
    test_command.path_override = "";
    defer test_command.path_override = null;
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
    try expectDetected("python -m pytest", &.{.{ "pyproject.toml", "[tool.pytest.ini_options]\n" }});
    try expectDetected("python -m pytest", &.{.{ "pytest.ini", "" }});
    try expectDetected("python -m pytest", &.{.{ "tox.ini", "[pytest]\n" }});
    try expectDetected("python -m pytest", &.{.{ "setup.cfg", "[tool:pytest]\n" }});
    try expectDetected("python -m pytest", &.{.{ "setup.py", "setup(tests_require=[\"pytest\"])\n" }});
    try expectDetected("python -m unittest discover", &.{.{ "pyproject.toml", "" }});
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

    var detect_policy = run_fixture.policyWith(repo.root_abs, &.{"npm run lint"});
    detect_policy.detect_test = true;
    var detected = try run_fixture.call(detect_policy, .{});
    defer detected.deinit();
    const found = (try detected.field("commands")).?.array.items;
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("zig build test", found[1].string);

    var plain = try run_fixture.call(run_fixture.policyWith(repo.root_abs, &.{}), .{});
    defer plain.deinit();
    try testing.expectEqual(@as(usize, 0), (try plain.field("commands")).?.array.items.len);
}

test "test detection: a project venv interpreter runs the Python tests, and a requirements-only project gets pytest or unittest" {
    try expectDetected(".venv\\Scripts\\python -m pytest", &.{ .{ "pyproject.toml", "[project.optional-dependencies]\ntest = [\"pytest>=8\"]\n" }, .{ ".venv/Scripts/python.exe", "" } });
    try expectDetected("venv\\Scripts\\python -m pytest", &.{ .{ "setup.py", "" }, .{ "venv/Scripts/python.exe", "" }, .{ "venv/Lib/site-packages/pytest/__init__.py", "" } });
    try expectDetected("python -m pytest", &.{ .{ "requirements.txt", "requests\npytest>=8\n" }, .{ "tests/test_a.py", "" } });
    try expectDetected("python -m unittest discover", &.{ .{ "requirements.txt", "requests\npytest-cov\n" }, .{ "test_a.py", "" } });
    try expectDetected(".venv\\Scripts\\python -m pytest", &.{ .{ "requirements.txt", "requests\n" }, .{ "tests/test_a.py", "" }, .{ ".venv/Scripts/python.exe", "" }, .{ ".venv/Lib/site-packages/pytest/__init__.py", "" } });
    try expectDetected(".venv\\Scripts\\python -m unittest discover -s tests", &.{ .{ "requirements.txt", "requests\n" }, .{ "tests/test_a.py", "" }, .{ ".venv/Scripts/python.exe", "" } });
    try expectDetected(null, &.{.{ "requirements.txt", "pytest\n" }});
    try testing.expect(test_command.requiresPytest("  pytest\n"));
    try testing.expect(test_command.requiresPytest("pytest[testing]==8.0"));
    try testing.expect(!test_command.requiresPytest("pytest-cov\n# pytest\n"));
}

test "test detection: a unittest project picks unittest discover with the right start dir, venv or not" {
    try expectDetected(".venv\\Scripts\\python -m unittest discover", &.{ .{ "pyproject.toml", "[project]\nname = \"wordstat\"\n" }, .{ ".venv/Scripts/python.exe", "" }, .{ "src/wordstat/__init__.py", "" }, .{ "tests/__init__.py", "" }, .{ "tests/test_core.py", "" } });
    try expectDetected("python -m unittest discover -s tests", &.{ .{ "pyproject.toml", "" }, .{ "tests/test_core.py", "" } });
    try expectDetected("python -m unittest discover -s test", &.{ .{ "setup.cfg", "[metadata]\nname = x\n" }, .{ "test/test_core.py", "" } });
    try testing.expect(test_command.mentionsPytest("dev = [\"pytest>=8\", \"ruff\"]"));
    try testing.expect(test_command.mentionsPytest("[tool.pytest.ini_options]"));
    try testing.expect(test_command.mentionsPytest("commands = pytest -q"));
    try testing.expect(!test_command.mentionsPytest("dev = [\"pytest-cov\"]\n# pytest\n; pytest\n"));
    try testing.expect(!test_command.mentionsPytest("[tool.ruff]\nname = \"pytestish\"\n"));
}

const Interpreters = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,

    fn init(files: []const [2][]const u8) !Interpreters {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        for (files) |file| {
            if (std.fs.path.dirnamePosix(file[0])) |parent| try tmp.dir.createDirPath(testing.io, parent);
            try tmp.dir.writeFile(testing.io, .{ .sub_path = file[0], .data = file[1] });
        }
        return .{ .tmp = tmp, .root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa) };
    }

    fn deinit(self: *Interpreters) void {
        gpa.free(self.root);
        self.tmp.cleanup();
    }

    fn write(self: *Interpreters, rel: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = data });
    }

    fn detect(self: *Interpreters, path: []const []const u8) !?[]const u8 {
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(gpa);
        for (path) |dir| try joined.print(gpa, "{s}\\{s};", .{ self.root, dir });
        const project = try std.fmt.allocPrint(gpa, "{s}\\proj", .{self.root});
        defer gpa.free(project);
        test_command.path_override = joined.items;
        defer test_command.path_override = null;
        return test_command.detectIn(gpa, testing.io, project);
    }
};

test "test detection: pytest is chosen only when the interpreter that runs the tests can import it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Interpreters.init(&.{
        .{ "proj/pyproject.toml", "[project]\nname = \"x\"\n" },
        .{ "proj/tests/__init__.py", "" },
        .{ "with/python.exe", "" },
        .{ "with/Lib/site-packages/pytest/__init__.py", "" },
        .{ "bare/python.exe", "" },
        .{ "shim/python.bat", "" },
    });
    defer fx.deinit();
    try testing.expectEqualStrings("python -m pytest", (try fx.detect(&.{"with"})).?);
    try testing.expectEqualStrings("python -m unittest discover", (try fx.detect(&.{ "bare", "with" })).?);
    try testing.expectEqualStrings("python -m unittest discover", (try fx.detect(&.{ "shim", "with" })).?);
    try testing.expectEqualStrings("python -m pytest", (try fx.detect(&.{ "missing", "with" })).?);

    try fx.tmp.dir.createDirPath(testing.io, "proj/.venv/Scripts");
    try fx.write("proj/.venv/Scripts/python.exe", "");
    const shared = try std.fmt.allocPrint(gpa, "home = {s}\\with\ninclude-system-site-packages = true\n", .{fx.root});
    defer gpa.free(shared);
    try fx.write("proj/.venv/pyvenv.cfg", shared);
    try testing.expectEqualStrings(".venv\\Scripts\\python -m pytest", (try fx.detect(&.{})).?);
    const isolated = try std.fmt.allocPrint(gpa, "home = {s}\\with\ninclude-system-site-packages = false\n", .{fx.root});
    defer gpa.free(isolated);
    try fx.write("proj/.venv/pyvenv.cfg", isolated);
    try testing.expectEqualStrings(".venv\\Scripts\\python -m unittest discover", (try fx.detect(&.{"with"})).?);
}

test "test detection: a src layout is put on PYTHONPATH for the gated run, and nothing else is" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var layout = try Interpreters.init(&.{ .{ "src/wordstat/__init__.py", "" }, .{ "web/src/app.ts", "" }, .{ "flat/src/tool.py", "" } });
    defer layout.deinit();
    const found = (try test_command.pythonPath(arena, testing.io, layout.root)).?;
    try testing.expectEqualStrings("PYTHONPATH", found.name);
    const want = try std.fmt.allocPrint(arena, "{s}\\src", .{layout.root});
    try testing.expect(std.mem.startsWith(u8, found.value, want));
    try testing.expect(found.value.len == want.len or found.value[want.len] == ';');
    const web = try std.fmt.allocPrint(arena, "{s}\\web", .{layout.root});
    try testing.expect((try test_command.pythonPath(arena, testing.io, web)) == null);
    const flat = try std.fmt.allocPrint(arena, "{s}\\flat", .{layout.root});
    try testing.expect((try test_command.pythonPath(arena, testing.io, flat)) != null);
    const none = try std.fmt.allocPrint(arena, "{s}\\src\\wordstat", .{layout.root});
    try testing.expect((try test_command.pythonPath(arena, testing.io, none)) == null);
}

test "test detection: a test command that cannot start is reported unverified, never as a failing baseline" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.TsRepo.init(&.{.{ .rel = "a.txt", .text = "x\n" }});
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try create(&repo, runtime, "fresh.ts", fresh_body, .{ .test_command = "echo ModuleNotFoundError: No module named 'emetgate_absent' 1>&2& exit /b 1" });
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expect(reply.value.object.get("baseline_failing") == null);
    const reason = reply.value.object.get("unverified").?.string;
    try testing.expect(std.mem.indexOf(u8, reason, "No module named 'emetgate_absent'") != null);
    try testing.expect(std.mem.startsWith(u8, reason, "the test command could not run"));
}

fn createBatch(repo: *fixture.TsRepo, runtime: *Runtime, files: []const [2][]const u8) !Call {
    var call: Call = .{ .arena_state = std.heap.ArenaAllocator.init(gpa) };
    errdefer call.deinit();
    const arena = call.arena_state.allocator();
    var edits = std.json.Array.init(arena);
    for (files) |file| {
        var item: std.json.ObjectMap = .empty;
        try item.put(arena, "file", .{ .string = try repo.abs(arena, file[0]) });
        try item.put(arena, "hash", .{ .string = "absent" });
        try item.put(arena, "content", .{ .string = file[1] });
        try edits.append(.{ .object = item });
    }
    var map: std.json.ObjectMap = .empty;
    try map.put(arena, "edits", .{ .array = edits });
    var event: telemetry.Event = .{ .tool = "emetgate_try_batch" };
    const policy: Policy = .{ .detect_test = true, .root = repo.root_abs };
    const result = try handlers.callTool(gpa, testing.io, runtime, "emetgate_try_batch", .{ .object = map }, &event, policy);
    defer gpa.free(result.text);
    call.text = try arena.dupe(u8, result.text);
    call.is_error = result.is_error;
    call.value = try std.json.parseFromSliceLeaky(Value, arena, call.text, .{});
    return call;
}

test "test detection: a batch that creates the project file runs the test command it names" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.TsRepo.init(&.{.{ .rel = "a.txt", .text = "x\n" }});
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try createBatch(&repo, runtime, &.{ .{ "pytest.ini", "" }, .{ "test_ok.py", "def test_ok():\n    assert True\n" } });
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings("written", reply.status());
    try testing.expect(std.mem.indexOf(u8, reply.text, "passed") != null);
    try testing.expect(!test_command.takeUnverified());
}

test "test detection: a batch that creates the project file with a failing test is rejected and writes nothing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.TsRepo.init(&.{.{ .rel = "a.txt", .text = "x\n" }});
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try createBatch(&repo, runtime, &.{ .{ "pytest.ini", "" }, .{ "test_bad.py", "def test_bad():\n    assert False\n" } });
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings("python -m pytest", reply.value.object.get("test_cmd").?.string);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, try repo.abs(reply.arena_state.allocator(), "test_bad.py"), .{}));
}
