const std = @import("std");
const tool_result = @import("tool_result.zig");
const mirror_mod = @import("mirror.zig");
const tree_cache_mod = @import("../engine/tree_cache.zig");
const tsserver = @import("../platform/tsserver.zig");
const run_command = @import("../platform/run_command.zig");
const commit_message = @import("../platform/commit_message.zig");
const commit_plan = @import("../platform/commit_plan.zig");
const search_session_mod = @import("../platform/search_session.zig");
const read_budget_mod = @import("read_budget.zig");
const map_tools = @import("map_tools.zig");

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
    commit: bool = false,

    pub fn allowedRuns(self: *const Policy) []const []const u8 {
        return self.allow_run[0..self.allow_run_len];
    }
};

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
        } else if (std.mem.eql(u8, arg, "--commit")) {
            if (policy.commit) return null;
            policy.commit = true;
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
        } else return null;
    }
    return policy;
}

pub const model_policy_fields = [_][]const u8{ "test_cmd", "typecheck_cmd", "allow_repo_config", "allow_repo_memory", "shadow_root", "allow_run" };

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

pub const CommitError = error{ CommitNotEnabled, MissingCommitMessage } || commit_message.Error;

pub fn commitMessage(args: ?Value, policy: Policy) CommitError!?[]const u8 {
    const given: ?Value = if (args) |a| tool_result.getField(a, "message") else null;
    if (!policy.commit) {
        if (given != null) return error.CommitNotEnabled;
        return null;
    }
    const value = given orelse return error.MissingCommitMessage;
    if (value != .string) return error.MissingCommitMessage;
    try commit_message.check(value.string);
    return value.string;
}

pub fn commitRequest(args: ?Value, policy: Policy) CommitError!?commit_plan.Request {
    const message = (try commitMessage(args, policy)) orelse return null;
    return .{ .message = message };
}

pub fn refuseWithoutCommit(policy: Policy) error{CommitNotSupportedByTool}!void {
    if (policy.commit) return error.CommitNotSupportedByTool;
}

const testing = std.testing;

fn parsedArgs(text: []const u8) !std.json.Parsed(Value) {
    return std.json.parseFromSlice(Value, testing.allocator, text, .{});
}

test "commit policy: --commit turns commits on, and giving it twice is refused" {
    const one = [_][]const u8{"--commit"};
    try testing.expect(parsePolicy(&one).?.commit);
    const none = [_][]const u8{ "--test", "npm test" };
    try testing.expect(!parsePolicy(&none).?.commit);
    const two = [_][]const u8{ "--commit", "--commit" };
    try testing.expect(parsePolicy(&two) == null);
    try refuseWithoutCommit(.{});
    try testing.expectError(error.CommitNotSupportedByTool, refuseWithoutCommit(.{ .commit = true }));
}

test "commit policy: with commits off a call without a message passes and a call with one is refused" {
    const plain = try parsedArgs("{\"file\":\"a.ts\"}");
    defer plain.deinit();
    try testing.expectEqual(@as(?[]const u8, null), try commitMessage(plain.value, .{}));
    try testing.expectEqual(@as(?[]const u8, null), try commitMessage(null, .{}));
    const with = try parsedArgs("{\"file\":\"a.ts\",\"message\":\"fix: one\"}");
    defer with.deinit();
    try testing.expectError(error.CommitNotEnabled, commitMessage(with.value, .{}));
}

test "commit policy: with commits on every call needs a message, and the message is checked" {
    const on: Policy = .{ .commit = true };
    const plain = try parsedArgs("{\"file\":\"a.ts\"}");
    defer plain.deinit();
    try testing.expectError(error.MissingCommitMessage, commitMessage(plain.value, on));
    try testing.expectError(error.MissingCommitMessage, commitMessage(null, on));
    const number = try parsedArgs("{\"message\":7}");
    defer number.deinit();
    try testing.expectError(error.MissingCommitMessage, commitMessage(number.value, on));
    const blank = try parsedArgs("{\"message\":\"  \"}");
    defer blank.deinit();
    try testing.expectError(error.CommitMessageEmpty, commitMessage(blank.value, on));
    const good = try parsedArgs("{\"message\":\"fix: one\"}");
    defer good.deinit();
    try testing.expectEqualStrings("fix: one", (try commitMessage(good.value, on)).?);
}
