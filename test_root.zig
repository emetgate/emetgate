const src = @import("src/root.zig");

pub const tree_sitter = src.tree_sitter;
pub const alloc_bridge = src.alloc_bridge;
pub const traversal = src.traversal;
pub const runtime = src.runtime;
pub const loader = src.loader;
pub const tree_cache = src.tree_cache;
pub const symbol = src.symbol;
pub const line_range = src.line_range;
pub const skeleton = src.skeleton;
pub const cas = src.cas;
pub const boundedness = src.boundedness;
pub const symmetry = src.symmetry;
pub const removal = src.removal;
pub const rename = src.rename;
pub const scope = src.scope;
pub const declarations = src.declarations;
pub const modules = src.modules;
pub const coverage = src.coverage;
pub const checks = src.checks;
pub const regex = src.regex;
pub const query = src.query;
pub const lang_registry = src.lang_registry;
pub const lang_profile = src.lang_profile;
pub const test_util = src.test_util;
pub const session = src.session;
pub const shadow = src.shadow;
pub const link_tree = src.link_tree;
pub const shadow_root = src.shadow_root;
pub const sandbox = src.sandbox;
pub const tsserver = src.tsserver;
pub const rename_batch = src.rename_batch;
pub const move_batch = src.move_batch;
pub const module_paths = src.module_paths;
pub const disk = src.disk;
pub const runner = src.runner;
pub const rules = src.rules;
pub const scan = src.scan;
pub const stdio = src.stdio;
pub const lockdown = src.lockdown;
pub const memory = src.memory;
pub const journal = src.journal;
pub const where = src.where;
pub const wire = src.wire;
pub const scan_command = src.scan_command;
pub const rule_command = src.rule_command;
pub const diagnostics = src.diagnostics;
pub const server = src.server;
pub const telemetry = src.telemetry;
pub const handlers = src.handlers;
pub const read_tools = src.read_tools;
pub const mirror = src.mirror;
pub const json_pointer = src.json_pointer;
pub const markdown_heading = src.markdown_heading;

comptime {
    for (@typeInfo(src).@"struct".decls) |decl| {
        if (!@hasDecl(@This(), decl.name) or @field(@This(), decl.name) != @field(src, decl.name)) {
            @compileError("test_root.zig must re-export src/root.zig's " ++ decl.name);
        }
    }
}

test {
    _ = @import("tests/runner.zig");
    _ = @import("tests/runner_rules.zig");
    _ = @import("tests/scan.zig");
    _ = @import("tests/scan_tool.zig");
    _ = @import("tests/redteam_memory.zig");
    _ = @import("tests/redteam_ledger.zig");
    _ = @import("tests/redteam_sandbox.zig");
    _ = @import("tests/redteam_link_tree.zig");
    _ = @import("tests/redteam_git.zig");
    _ = @import("tests/purple.zig");
    _ = @import("tests/batch_crash.zig");
    _ = @import("tests/batch_crash_tool.zig");
    _ = @import("tests/batch_create_crash.zig");
    _ = @import("tests/batch_delete_crash.zig");
    _ = @import("tests/batch_create_tool.zig");
    _ = @import("tests/redteam_batch_create.zig");
    _ = @import("tests/batch_delete_tool.zig");
    _ = @import("tests/redteam_batch_delete.zig");
    _ = @import("tests/tsserver.zig");
    _ = @import("tests/declarations.zig");
    _ = @import("tests/delete_references.zig");
    _ = @import("tests/rename_tool.zig");
    _ = @import("tests/redteam_rename.zig");
    _ = @import("tests/rename_crash.zig");
    _ = @import("tests/rename_typescript.zig");
    _ = @import("tests/rename_kinds.zig");
    _ = @import("tests/move_tool.zig");
    _ = @import("tests/create_kinds.zig");
    _ = @import("tests/query.zig");
    _ = @import("tests/rule.zig");
    _ = @import("tests/observability.zig");
    _ = @import("tests/readtools.zig");
    _ = @import("tests/git_tools.zig");
    _ = @import("tests/server.zig");
    _ = @import("tests/lockdown.zig");
    _ = @import("tests/symbol.zig");
    _ = @import("tests/mutate_harness.zig");
    _ = @import("tests/mutate_schema.zig");
    _ = @import("tests/mutate_changes.zig");
    _ = @import("tests/memory.zig");
    _ = @import("tests/fuzz_regex.zig");
    _ = @import("tests/fuzz_protocol.zig");
    _ = @import("tests/fuzz_ledger.zig");
    _ = @import("tests/fuzz_cas.zig");
    _ = @import("tests/fuzz_journal.zig");
    _ = @import("tests/lang/conformance.zig");
    _ = @import("tests/lang/jsx_compat.zig");
    _ = @import("tests/lang/zig/compat.zig");
    _ = @import("tests/git_fixture_test.zig");
    _ = @import("tests/test_runner_harness.zig");
    _ = @import("tests/suites.zig");
}
