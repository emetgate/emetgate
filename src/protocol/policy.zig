const std = @import("std");
const tool_result = @import("tool_result.zig");

const Value = std.json.Value;

pub const Policy = struct {
    test_command: ?[]const u8 = null,
    allow_repo_config: bool = false,
};

pub fn parsePolicy(args: anytype) ?Policy {
    var policy: Policy = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--allow-repo-config")) {
            if (policy.allow_repo_config) return null;
            policy.allow_repo_config = true;
        } else if (std.mem.eql(u8, arg, "--test")) {
            if (policy.test_command != null or i + 1 >= args.len) return null;
            i += 1;
            const command: []const u8 = args[i];
            if (command.len == 0) return null;
            policy.test_command = command;
        } else return null;
    }
    return policy;
}

pub fn trustedTestCommand(args: ?Value, policy: Policy) error{ModelSuppliedTestPolicy}![]const u8 {
    if (args) |a| {
        if (tool_result.getField(a, "test_cmd") != null or tool_result.getField(a, "allow_repo_config") != null) return error.ModelSuppliedTestPolicy;
    }
    return policy.test_command orelse "";
}
