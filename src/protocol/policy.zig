const std = @import("std");
const tool_result = @import("tool_result.zig");
const mirror_mod = @import("mirror.zig");
const tree_cache_mod = @import("../engine/tree_cache.zig");
const tsserver = @import("../platform/tsserver.zig");

const Value = std.json.Value;

pub const Policy = struct {
    test_command: ?[]const u8 = null,
    typecheck_command: ?[]const u8 = null,
    allow_repo_config: bool = false,
    allow_repo_memory: bool = false,
    shadow_root: ?[]const u8 = null,
    root: ?[]const u8 = null,
    mirror_enabled: bool = false,
    mirror: ?*mirror_mod.Mirror = null,
    tree_cache: ?*tree_cache_mod.TreeCache = null,
    language_service: ?*tsserver.Session = null,
};

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
        } else if (std.mem.eql(u8, arg, "--mirror")) {
            if (policy.mirror_enabled) return null;
            policy.mirror_enabled = true;
        } else if (std.mem.eql(u8, arg, "--typecheck")) {
            if (policy.typecheck_command != null or i + 1 >= args.len) return null;
            i += 1;
            const command: []const u8 = args[i];
            if (command.len == 0) return null;
            policy.typecheck_command = command;
        } else if (std.mem.eql(u8, arg, "--shadow-root")) {
            if (policy.shadow_root != null or i + 1 >= args.len) return null;
            i += 1;
            const dir: []const u8 = args[i];
            if (dir.len == 0) return null;
            policy.shadow_root = dir;
        } else return null;
    }
    return policy;
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
