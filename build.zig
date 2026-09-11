const std = @import("std");

const ts_core_root = "vendor/tree-sitter/lib";
const ts_typescript_root = "vendor/tree-sitter-typescript/typescript/src";

const c_flags: []const []const u8 = &.{"-std=c11"};

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

    const synapse = b.addModule("synapse", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = c_api.createModule() }},
    });
    synapse.linkLibrary(tree_sitter);

    const exe = b.addExecutable(.{
        .name = "synapse",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "synapse", .module = synapse }},
        }),
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| run_exe.addArgs(args);
    b.step("run", "Run the synapse CLI").dependOn(&run_exe.step);

    const tests = b.addTest(.{ .root_module = synapse });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));
    const test_step = b.step("test", "Run unit and end-to-end tests");
    test_step.dependOn(&run_tests.step);

    const e2e_step = b.step("e2e", "Run CLI end-to-end tests");
    addEndToEndTests(b, exe, e2e_step);
    test_step.dependOn(e2e_step);
}

const e2e_fixture = "tests/fixtures/functions.ts";
const e2e_add_hash = "35b462b8e42e39e0fe66ae0dae747ab7";
const e2e_zero_hash = "00000000000000000000000000000000";

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
        .stderr_contains = "mutated add  " ++ e2e_add_hash ++ " -> ",
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
        if (case.stdout) |bytes| run.expectStdOutEqual(bytes);
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
    module.addIncludePath(b.path(ts_typescript_root));

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
    module.addCSourceFiles(.{
        .root = b.path(ts_typescript_root),
        .files = &.{ "parser.c", "scanner.c" },
        .flags = c_flags,
    });

    return b.addLibrary(.{
        .name = "tree-sitter-typescript",
        .root_module = module,
    });
}
