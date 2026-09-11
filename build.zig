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

    const tests = b.addTest(.{ .root_module = synapse });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
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

    const lib = b.addLibrary(.{
        .name = "tree-sitter-typescript",
        .root_module = module,
    });
    b.installArtifact(lib);
    return lib;
}
