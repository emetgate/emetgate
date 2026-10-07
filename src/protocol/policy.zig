const std = @import("std");
const tool_result = @import("tool_result.zig");
const mirror_mod = @import("mirror.zig");
const tree_cache_mod = @import("../engine/tree_cache.zig");
const tsserver = @import("../platform/tsserver.zig");
const run_command = @import("../platform/run_command.zig");
const search_session_mod = @import("../platform/search_session.zig");
const read_budget_mod = @import("read_budget.zig");
const map_tools = @import("map_tools.zig");
const shadow = @import("../platform/shadow.zig");

const Value = std.json.Value;

pub const Policy = struct {
    test_command: ?[]const u8 = null,
    typecheck_command: ?[]const u8 = null,
    allow_repo_config: bool = false,
    allow_repo_memory: bool = false,
    shadow_root: ?[]const u8 = null,
    root: ?[]const u8 = null,
    mirror_enabled: bool = false,
    read_budget: usize = read_budget_mod.default_budget,
    read_budget_set: bool = false,
    mirror: ?*mirror_mod.Mirror = null,
    tree_cache: ?*tree_cache_mod.TreeCache = null,
    search_session: ?*search_session_mod.Session = null,
    language_service: ?*tsserver.Session = null,
    map_session: ?*map_tools.Session = null,
    allow_run: [run_command.max_entries][]const u8 = undefined,
    allow_run_len: usize = 0,
    shadow_tree: ?shadow.TreeMode = null,
    shadow_private: [max_private][]const u8 = undefined,
    shadow_private_len: usize = 0,

    pub fn treeChoice(self: *const Policy) shadow.Choice {
        return .{ .tree = self.shadow_tree orelse shadow.default_tree, .private = self.shadow_private[0..self.shadow_private_len] };
    }

    pub fn allowedRuns(self: *const Policy) []const []const u8 {
        return self.allow_run[0..self.allow_run_len];
    }
};

pub const max_private = 32;

pub fn parseTree(text: []const u8) ?shadow.TreeMode {
    if (std.mem.eql(u8, text, "kept")) return .kept;
    if (std.mem.eql(u8, text, "copy")) return .full_copy;
    return null;
}

pub const RunRefusal = struct { entry: []const u8, reason: run_command.EntryError };

pub fn refusedRunEntry(args: anytype) ?RunRefusal {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (!std.mem.eql(u8, arg, "--allow-run")) continue;
        const entry: []const u8 = args[i + 1];
        run_command.validateEntry(entry) catch |err| return .{ .entry = entry, .reason = err };
        i += 1;
    }
    return null;
}

pub fn parsePolicy(args: anytype) ?Policy {
    var policy: Policy = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--allow-repo-config")) {
            if (policy.allow_repo_config) return null;
            policy.allow_repo_config = true;
        } else if (std.mem.eql(u8, arg, "--allow-repo-memory")) {
            if (policy.allow_repo_memory) return null;
            policy.allow_repo_memory = true;
        } else if (std.mem.eql(u8, arg, "--test")) {
            if (policy.test_command != null or i + 1 >= args.len) return null;
            i += 1;
            const command: []const u8 = args[i];
            if (command.len == 0) return null;
            policy.test_command = command;
        } else if (std.mem.eql(u8, arg, "--allow-run")) {
            if (i + 1 >= args.len or policy.allow_run_len == run_command.max_entries) return null;
            i += 1;
            const command: []const u8 = args[i];
            run_command.validateEntry(command) catch return null;
            if (run_command.match(policy.allowedRuns(), command) == null) {
                policy.allow_run[policy.allow_run_len] = command;
                policy.allow_run_len += 1;
            }
        } else if (std.mem.eql(u8, arg, "--mirror")) {
            if (policy.mirror_enabled) return null;
            policy.mirror_enabled = true;
        } else if (std.mem.eql(u8, arg, "--typecheck")) {
            if (policy.typecheck_command != null or i + 1 >= args.len) return null;
            i += 1;
            const command: []const u8 = args[i];
            if (command.len == 0) return null;
            policy.typecheck_command = command;
        } else if (std.mem.eql(u8, arg, "--read-budget")) {
            if (policy.read_budget_set or i + 1 >= args.len) return null;
            i += 1;
            const text: []const u8 = args[i];
            const value = std.fmt.parseInt(usize, text, 10) catch return null;
            if (value == 0) return null;
            policy.read_budget = value;
            policy.read_budget_set = true;
        } else if (std.mem.eql(u8, arg, "--shadow-root")) {
            if (policy.shadow_root != null or i + 1 >= args.len) return null;
            i += 1;
            const dir: []const u8 = args[i];
            if (dir.len == 0) return null;
            policy.shadow_root = dir;
        } else if (std.mem.eql(u8, arg, "--shadow-tree")) {
            if (policy.shadow_tree != null or i + 1 >= args.len) return null;
            i += 1;
            policy.shadow_tree = parseTree(args[i]) orelse return null;
        } else if (std.mem.eql(u8, arg, "--shadow-private")) {
            if (policy.shadow_private_len == max_private or i + 1 >= args.len) return null;
            i += 1;
            const prefix: []const u8 = args[i];
            shadow.validateRelative(prefix) catch return null;
            policy.shadow_private[policy.shadow_private_len] = prefix;
            policy.shadow_private_len += 1;
        } else return null;
    }
    return policy;
}

pub const model_policy_fields = [_][]const u8{ "test_cmd", "typecheck_cmd", "allow_repo_config", "allow_repo_memory", "shadow_root", "allow_run", "shadow_tree", "shadow_private" };

pub fn refuseModelPolicy(args: ?Value) error{ModelSuppliedTestPolicy}!void {
    const a = args orelse return;
    for (model_policy_fields) |field| {
        if (tool_result.getField(a, field) != null) return error.ModelSuppliedTestPolicy;
    }
}

pub fn trustedTestCommand(args: ?Value, policy: Policy) error{ModelSuppliedTestPolicy}![]const u8 {
    if (args) |a| {
        if (tool_result.getField(a, "test_cmd") != null or tool_result.getField(a, "typecheck_cmd") != null or tool_result.getField(a, "allow_repo_config") != null or tool_result.getField(a, "allow_repo_memory") != null or tool_result.getField(a, "shadow_root") != null) return error.ModelSuppliedTestPolicy;
    }
    return policy.test_command orelse "";
}

pub fn trustedTypecheckCommand(policy: Policy) []const u8 {
    return policy.typecheck_command orelse "";
}

test "the tree choice comes from the operator's flags: kept by default, copy on request, private prefixes in order" {
    const none = parsePolicy(&[_][]const u8{}).?;
    try std.testing.expectEqual(shadow.default_tree, none.treeChoice().tree);
    try std.testing.expectEqual(@as(usize, 0), none.treeChoice().private.len);

    const copy = parsePolicy(&[_][]const u8{ "--shadow-tree", "copy" }).?;
    try std.testing.expectEqual(shadow.TreeMode.full_copy, copy.treeChoice().tree);
    const kept = parsePolicy(&[_][]const u8{ "--shadow-tree", "kept", "--shadow-private", "src/__snapshots__", "--shadow-private", "gen" }).?;
    try std.testing.expectEqual(shadow.TreeMode.kept, kept.treeChoice().tree);
    try std.testing.expectEqual(@as(usize, 2), kept.treeChoice().private.len);
    try std.testing.expectEqualStrings("src/__snapshots__", kept.treeChoice().private[0]);
    try std.testing.expectEqualStrings("gen", kept.treeChoice().private[1]);

    for ([_][]const []const u8{
        &.{ "--shadow-tree", "fresh" },
        &.{"--shadow-tree"},
        &.{ "--shadow-tree", "kept", "--shadow-tree", "copy" },
        &.{"--shadow-private"},
        &.{ "--shadow-private", "../outside" },
        &.{ "--shadow-private", "C:\\abs" },
        &.{ "--shadow-private", "" },
    }) |bad| try std.testing.expect(parsePolicy(bad) == null);
}

test "a tool call that names the tree choice is refused like one that names a test command" {
    for ([_][]const u8{ "shadow_tree", "shadow_private" }) |field| {
        var found = false;
        for (model_policy_fields) |known| {
            if (std.mem.eql(u8, known, field)) found = true;
        }
        try std.testing.expect(found);
    }
}
