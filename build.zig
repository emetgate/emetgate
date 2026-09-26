const std = @import("std");

const ts_core_root = "vendor/tree-sitter/lib";

const Grammar = struct {
    root: []const u8,
    sources: []const []const u8,
};

const grammars = [_]Grammar{
    .{ .root = "vendor/tree-sitter-typescript/typescript/src", .sources = &.{ "parser.c", "scanner.c" } },
    .{ .root = "vendor/tree-sitter-typescript/tsx/src", .sources = &.{ "parser.c", "scanner.c" } },
    .{ .root = "vendor/tree-sitter-javascript/src", .sources = &.{ "parser.c", "scanner.c" } },
    .{ .root = "vendor/tree-sitter-zig/src", .sources = &.{"parser.c"} },
    .{ .root = "vendor/tree-sitter-json/src", .sources = &.{"parser.c"} },
    .{ .root = "vendor/tree-sitter-markdown/src", .sources = &.{ "parser.c", "scanner.c" } },
};

const c_flags: []const []const u8 = &.{"-std=c11"};
const grammar_c_flags: []const []const u8 = &.{"-std=c23"};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tree_sitter = buildTreeSitter(b, target, optimize);

    const c_api = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    c_api.addIncludePath(b.path(ts_core_root ++ "/include"));

    const c_module = c_api.createModule();
    const emetgate = b.addModule("emetgate", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = c_module }},
    });
    emetgate.linkLibrary(tree_sitter);

    const probe = b.addExecutable(.{
        .name = "sandbox-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/probe/probe.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const common: TestModuleOptions = .{ .target = target, .optimize = optimize, .c_module = c_module, .tree_sitter = tree_sitter, .probe = probe };
    const src_bench = srcModule(b, common, true);

    const exe = b.addExecutable(.{
        .name = "emetgate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "emetgate", .module = emetgate }},
        }),
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| run_exe.addArgs(args);
    b.step("run", "Run the emetgate CLI").dependOn(&run_exe.step);

    const test_filters = b.option([]const []const u8, "test-filter", "Only run tests whose name contains one of these strings; skips the CLI e2e cases") orelse &.{};
    const test_jobs = b.option(usize, "test-jobs", "Number of processes that split the tests of the one test binary") orelse 4;
    const run_slow = b.option(bool, "slow", "Also run the tests marked slow") orelse false;
    if (test_jobs == 0) @panic("-Dtest-jobs must be at least 1");
    const selection: TestSelection = .{ .filters = test_filters, .slow = run_slow };

    const test_all = b.addTest(.{
        .name = "test-all",
        .root_module = testModule(b, common),
        .test_runner = .{ .path = b.path("tools/test_runner.zig"), .mode = .simple },
    });
    b.step("test-bin", "Build the test binary into zig-out/bin/test-all").dependOn(&b.addInstallArtifact(test_all, .{}).step);

    const test_step = b.step("test", "Run every test from one binary in parallel shards, then the CLI end-to-end tests");
    test_step.dependOn(&testRun(b, test_all, selection, &.{ "--jobs", b.fmt("{d}", .{test_jobs}) }).step);

    const fast_step = b.step("test-fast", "Run the engine unit tests only: no git, no sandbox, no child process");
    fast_step.dependOn(&testRun(b, test_all, .{ .filters = &.{"src.engine."} }, &.{}).step);

    const timing_step = b.step("test-timing", "Run every test one by one in one process and print the slowest tests and per-file totals");
    const timing = testRun(b, test_all, selection, &.{"--timing"});
    if (b.args) |args| timing.addArgs(args);
    timing_step.dependOn(&timing.step);

    const bench_tests = b.addTest(.{ .name = "bench-tests", .root_module = src_bench, .filters = &.{ "apply/rollback cycles", "rollback latency" } });
    const run_bench = b.addRunArtifact(bench_tests);
    run_bench.setCwd(b.path("."));
    run_bench.has_side_effects = true;
    b.step("bench", "Run the session benchmarks at full size (1000 cycles), which the test step runs at 10").dependOn(&run_bench.step);

    const e2e_step = b.step("e2e", "Run CLI end-to-end tests");
    addEndToEndTests(b, exe, e2e_step);
    if (test_filters.len == 0) test_step.dependOn(e2e_step);

    const mutate_tool = b.addExecutable(.{
        .name = "emetgate-mutate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mutate/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_mutate = b.addInstallArtifact(mutate_tool, .{});
    b.step("mutate-tool", "Build the mutation harness into zig-out/bin/emetgate-mutate").dependOn(&install_mutate.step);

    const fuzz_tool = b.addExecutable(.{
        .name = "emetgate-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fuzz/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "emetgate", .module = emetgate }},
        }),
    });
    const install_fuzz = b.addInstallArtifact(fuzz_tool, .{});
    b.step("fuzz-tool", "Build the time-boxed random mutation fuzzer into zig-out/bin/emetgate-fuzz").dependOn(&install_fuzz.step);

    const lockdown_check = b.addExecutable(.{
        .name = "lockdown-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/e2e/lockdown_check.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_lockdown = b.addRunArtifact(lockdown_check);
    run_lockdown.setCwd(b.path("."));
    run_lockdown.has_side_effects = true;
    run_lockdown.addFileArg(exe.getEmittedBin());
    if (b.args) |args| run_lockdown.addArgs(args);
    run_lockdown.step.dependOn(b.getInstallStep());
    b.step("e2e-lockdown", "Launch a real claude through emetgate lockdown and check its tool list (spends tokens)").dependOn(&run_lockdown.step);
}

const TestModuleOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    c_module: *std.Build.Module,
    tree_sitter: *std.Build.Step.Compile,
    probe: *std.Build.Step.Compile,
};

fn buildOptions(b: *std.Build, options: TestModuleOptions, bench: bool) *std.Build.Module {
    const values = b.addOptions();
    values.addOptionPath("probe_path", options.probe.getEmittedBin());
    values.addOption(bool, "bench", bench);
    return values.createModule();
}

fn srcModule(b: *std.Build, options: TestModuleOptions, bench: bool) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = options.c_module },
            .{ .name = "build_options", .module = buildOptions(b, options, bench) },
        },
    });
    module.linkLibrary(options.tree_sitter);
    return module;
}

fn testModule(b: *std.Build, options: TestModuleOptions) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("test_root.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = options.c_module },
            .{ .name = "build_options", .module = buildOptions(b, options, false) },
        },
    });
    module.addImport("emetgate", module);
    module.linkLibrary(options.tree_sitter);
    return module;
}

const TestSelection = struct {
    filters: []const []const u8 = &.{},
    slow: bool = false,
};

fn testRun(b: *std.Build, compiled: *std.Build.Step.Compile, selection: TestSelection, extra: []const []const u8) *std.Build.Step.Run {
    const run = b.addRunArtifact(compiled);
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    for (selection.filters) |filter| run.addArgs(&.{ "--filter", filter });
    if (selection.slow) run.addArg("--slow");
    run.addArgs(extra);
    return run;
}

const e2e_fixture = "tests/fixtures/functions.ts";
const e2e_add_hash = "35b462b8e42e39e0fe66ae0dae747ab7";
const e2e_zero_hash = "00000000000000000000000000000000";
const e2e_patched_add_hash = "357b8d531c0c7045e5af084156e66186";

const CliCase = struct {
    name: []const u8,
    args: []const []const u8,
    exit_code: u8,
    stdout: ?[]const u8 = null,
    stdout_contains: ?[]const u8 = null,
    stderr_contains: ?[]const u8 = null,
};

const cli_cases = [_]CliCase{
    .{
        .name = "mutate from a body file",
        .args = &.{ "mutate", e2e_fixture, "--symbol", "add", "--hash", e2e_add_hash, "--body-file", "tests/e2e/add.body" },
        .exit_code = 0,
        .stdout = @embedFile("tests/e2e/functions.add.expected.ts"),
        .stderr_contains = "mutated add  " ++ e2e_add_hash ++ " -> " ++ e2e_patched_add_hash ++ "\n",
    },
    .{
        .name = "the reported hash is what symbols sees in the patched text",
        .args = &.{ "symbols", "tests/e2e/functions.add.expected.ts" },
        .exit_code = 0,
        .stdout_contains = e2e_patched_add_hash ++ "  L9:8  function  add\n",
    },
    .{
        .name = "body file with a BOM and a trailing newline",
        .args = &.{ "mutate", e2e_fixture, "--symbol", "add", "--hash", e2e_add_hash, "--body-file", "tests/e2e/add.bom-newline.body" },
        .exit_code = 0,
        .stdout = @embedFile("tests/e2e/functions.add.expected.ts"),
        .stderr_contains = "-> " ++ e2e_patched_add_hash ++ "\n",
    },
    .{
        .name = "symbols json emits one line with typed fields",
        .args = &.{ "symbols", e2e_fixture, "--json" },
        .exit_code = 0,
        .stdout_contains = "\"hash\":\"" ++ e2e_add_hash ++ "\",\"kind\":\"function\",\"ref\":\"add\",\"line\":9,\"col\":8,\"ambiguous\":false",
    },
    .{
        .name = "symbols json on a broken source is a typed error payload",
        .args = &.{ "symbols", "tests/fixtures/broken.ts", "--json" },
        .exit_code = 3,
        .stdout = "{\"status\":\"error\",\"error\":\"SourceHasErrors\",\"exit_code\":3}\n",
    },
    .{
        .name = "mutate json emits the transformed source and both hashes on one line",
        .args = &.{ "mutate", e2e_fixture, "--symbol", "add", "--hash", e2e_add_hash, "--body", "{ return 0; }", "--json" },
        .exit_code = 0,
        .stdout_contains = "\"status\":\"mutated\",\"symbol\":\"add\",\"old_hash\":\"" ++ e2e_add_hash ++ "\",\"new_hash\":\"65fda373e6c418a2e3dd2126c05fd44c\",\"source\":\"",
    },
    .{
        .name = "mutate json on a stale hash is a typed error payload",
        .args = &.{ "mutate", e2e_fixture, "--symbol", "add", "--hash", e2e_zero_hash, "--body", "{ return 0; }", "--json" },
        .exit_code = 6,
        .stdout = "{\"status\":\"error\",\"error\":\"HashMismatch\",\"exit_code\":6}\n",
    },
    .{
        .name = "output larger than the stdout buffer",
        .args = &.{ "symbols", "tests/e2e/many.ts" },
        .exit_code = 0,
        .stdout_contains = "  L3000:1  function  fn_3000\n",
    },
    .{
        .name = "symbols on a source with syntax errors",
        .args = &.{ "symbols", "tests/fixtures/broken.ts" },
        .exit_code = 3,
        .stdout = "",
        .stderr_contains = "error: SourceHasErrors",
    },
    .{
        .name = "flag given where a value belongs",
        .args = &.{ "mutate", e2e_fixture, "--symbol", "--body", "--hash", e2e_add_hash, "--body-file", "tests/e2e/add.body" },
        .exit_code = 2,
        .stdout = "",
        .stderr_contains = "usage:",
    },
    .{
        .name = "missing body file on a broken source reports the source first",
        .args = &.{ "mutate", "tests/fixtures/broken.ts", "--symbol", "broken", "--hash", e2e_zero_hash, "--body-file", "tests/e2e/missing.body" },
        .exit_code = 3,
        .stdout = "",
        .stderr_contains = "error: SourceHasErrors",
    },
    .{
        .name = "mutate with hash absent appends a new top-level symbol after one blank line",
        .args = &.{ "mutate", e2e_fixture, "--symbol", "extra", "--hash", "absent", "--body", "function extra() { return 1; }" },
        .exit_code = 0,
        .stdout_contains = "  return greeting;\n}\n\nfunction extra() { return 1; }\n",
        .stderr_contains = "mutated extra  absent -> ",
    },
    .{
        .name = "mutate json with hash absent reports absent as the old hash",
        .args = &.{ "mutate", e2e_fixture, "--symbol", "extra", "--hash", "absent", "--body", "function extra() { return 1; }", "--json" },
        .exit_code = 0,
        .stdout_contains = "\"status\":\"mutated\",\"symbol\":\"extra\",\"old_hash\":\"absent\",\"new_hash\":\"",
    },
    .{
        .name = "mutate with hash absent on an existing symbol",
        .args = &.{ "mutate", e2e_fixture, "--symbol", "add", "--hash", "absent", "--body", "export function add(a: number, b: number): number { return 0; }" },
        .exit_code = 20,
        .stderr_contains = "error: SymbolExists",
    },
    .{
        .name = "mutate json with hash absent and a mismatched name",
        .args = &.{ "mutate", e2e_fixture, "--symbol", "extra", "--hash", "absent", "--body", "function other() { return 1; }", "--json" },
        .exit_code = 25,
        .stdout = "{\"status\":\"error\",\"error\":\"SymbolNameMismatch\",\"exit_code\":25}\n",
    },
    .{
        .name = "mutate with an inline body",
        .args = &.{ "mutate", e2e_fixture, "--symbol", "add", "--hash", e2e_add_hash, "--body", "{ return 0; }" },
        .exit_code = 0,
        .stdout_contains = "export function add(a: number, b: number): number { return 0; }\n",
        .stderr_contains = "mutated add  " ++ e2e_add_hash ++ " -> ",
    },
    .{
        .name = "invalid ref",
        .args = &.{ "mutate", e2e_fixture, "--symbol", "a..b", "--hash", e2e_add_hash, "--body", "{}" },
        .exit_code = 2,
        .stderr_contains = "error: InvalidRef",
    },
    .{
        .name = "invalid hash",
        .args = &.{ "mutate", e2e_fixture, "--symbol", "add", "--hash", "xyz", "--body", "{}" },
        .exit_code = 2,
        .stderr_contains = "error: InvalidHash",
    },
    .{
        .name = "source with syntax errors",
        .args = &.{ "mutate", "tests/fixtures/broken.ts", "--symbol", "broken", "--hash", e2e_zero_hash, "--body", "{}" },
        .exit_code = 3,
        .stderr_contains = "error: SourceHasErrors",
    },
    .{
        .name = "unknown symbol",
        .args = &.{ "mutate", e2e_fixture, "--symbol", "nope", "--hash", e2e_zero_hash, "--body", "{}" },
        .exit_code = 4,
        .stderr_contains = "error: SymbolNotFound",
    },
    .{
        .name = "ambiguous symbol",
        .args = &.{ "mutate", "tests/e2e/dup.ts", "--symbol", "dup", "--hash", e2e_zero_hash, "--body", "{}" },
        .exit_code = 5,
        .stderr_contains = "error: AmbiguousSymbol",
    },
    .{
        .name = "stale hash",
        .args = &.{ "mutate", e2e_fixture, "--symbol", "add", "--hash", e2e_zero_hash, "--body", "{ return 0; }" },
        .exit_code = 6,
        .stderr_contains = "error: HashMismatch",
    },
    .{
        .name = "broken replacement body",
        .args = &.{ "mutate", e2e_fixture, "--symbol", "add", "--hash", e2e_add_hash, "--body-file", "tests/e2e/broken.body" },
        .exit_code = 7,
        .stderr_contains = "error: MutationSyntaxInvalid",
    },
    .{
        .name = "escaping replacement body",
        .args = &.{ "mutate", e2e_fixture, "--symbol", "add", "--hash", e2e_add_hash, "--body-file", "tests/e2e/escape.body" },
        .exit_code = 8,
        .stderr_contains = "error: BodyEscape",
    },
    .{
        .name = "missing flags",
        .args = &.{ "mutate", e2e_fixture, "--symbol", "add" },
        .exit_code = 2,
        .stderr_contains = "usage:",
    },
    .{
        .name = "duplicate flag",
        .args = &.{ "mutate", e2e_fixture, "--symbol", "add", "--symbol", "add", "--hash", e2e_add_hash },
        .exit_code = 2,
        .stderr_contains = "usage:",
    },
    .{
        .name = "both body sources",
        .args = &.{ "mutate", e2e_fixture, "--symbol", "add", "--hash", e2e_add_hash, "--body", "{}", "--body-file", "tests/e2e/add.body" },
        .exit_code = 2,
        .stderr_contains = "usage:",
    },
};

fn addEndToEndTests(b: *std.Build, exe: *std.Build.Step.Compile, step: *std.Build.Step) void {
    const disk_check = cliRun(b, exe, "file on disk is untouched after every mutate run", &.{ "symbols", e2e_fixture });
    disk_check.expectExitCode(0);
    disk_check.expectStdOutMatch(e2e_add_hash ++ "  L9:8  function  add\n");
    step.dependOn(&disk_check.step);

    for (cli_cases) |case| {
        const run = cliRun(b, exe, case.name, case.args);
        run.expectExitCode(case.exit_code);
        if (case.stdout) |bytes| {
            run.expectStdOutEqual(bytes);
        } else if (case.exit_code != 0) {
            run.expectStdOutEqual("");
        }
        if (case.stdout_contains) |bytes| run.expectStdOutMatch(bytes);
        if (case.stderr_contains) |bytes| run.expectStdErrMatch(bytes);
        disk_check.step.dependOn(&run.step);
    }
}

fn cliRun(b: *std.Build, exe: *std.Build.Step.Compile, name: []const u8, args: []const []const u8) *std.Build.Step.Run {
    const run = b.addRunArtifact(exe);
    run.step.name = b.fmt("e2e: {s}", .{name});
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    run.addArgs(args);
    return run;
}

fn buildTreeSitter(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    module.addIncludePath(b.path(ts_core_root ++ "/include"));
    module.addIncludePath(b.path(ts_core_root ++ "/src"));

    module.addCMacro("_POSIX_C_SOURCE", "200112L");
    module.addCMacro("_DEFAULT_SOURCE", "");
    module.addCMacro("_BSD_SOURCE", "");
    module.addCMacro("_DARWIN_C_SOURCE", "");
    module.addCMacro("TREE_SITTER_REUSE_ALLOCATOR", "");

    module.addCSourceFiles(.{
        .root = b.path(ts_core_root ++ "/src"),
        .files = &.{"lib.c"},
        .flags = c_flags,
    });
    for (grammars) |grammar| {
        const include = b.fmt("-I{s}", .{b.pathFromRoot(grammar.root)});
        module.addCSourceFiles(.{
            .root = b.path(grammar.root),
            .files = grammar.sources,
            .flags = std.mem.concat(b.allocator, []const u8, &.{ grammar_c_flags, &.{include} }) catch @panic("OOM"),
        });
    }

    return b.addLibrary(.{
        .name = "tree-sitter-grammars",
        .root_module = module,
    });
}
