const std = @import("std");
const memory = @import("memory.zig");
const shadow = @import("shadow.zig");

pub const rule_id = "gate-config";
pub const rule_text = "emetgate's own configuration (.mcp.json, the Claude settings and agents, the rules ledger, the git hooks and git config) is changed by hand by the user";

pub const ledger_dir = shadow.workspace_dir;
pub const ledger_name = memory.ledger_name;
pub const ledger = ledger_dir ++ "/" ++ ledger_name;
pub const git_dir = ".git";
pub const git_config = git_dir ++ "/config";
pub const git_hooks = git_dir ++ "/hooks";
pub const agents = ".claude/agents";

pub const tracked_files = [_][]const u8{ ".mcp.json", ".claude/settings.json", ".claude/settings.local.json" };
pub const tracked_dirs = [_][]const u8{agents};
pub const files = tracked_files ++ [_][]const u8{git_config};
pub const dirs = tracked_dirs ++ [_][]const u8{git_hooks};

const kept_config_sections = [_][]const u8{ "branch", "remote" };
const kept_config_keys = [_][]const u8{ "remote", "merge", "pushremote", "rebase", "description", "url", "pushurl", "fetch", "push" };

pub fn covers(path: []const u8) bool {
    for (files) |file| {
        if (samePath(path, file)) return true;
    }
    for (dirs) |dir| {
        if (path.len > dir.len and samePath(path[0..dir.len], dir) and isSlash(path[dir.len])) return true;
    }
    return isLedger(path);
}

pub fn isLedger(path: []const u8) bool {
    if (path.len < ledger.len or !samePath(path[0..ledger.len], ledger)) return false;
    return std.mem.indexOfAny(u8, path[ledger.len..], "/\\") == null;
}

pub fn isLedgerName(name: []const u8) bool {
    return name.len >= ledger_name.len and std.ascii.eqlIgnoreCase(name[0..ledger_name.len], ledger_name);
}

pub fn isGitConfig(path: []const u8) bool {
    return samePath(path, git_config);
}

pub fn inGitDir(path: []const u8) ?[]const u8 {
    if (samePath(path, git_dir)) return "";
    if (path.len > git_dir.len and samePath(path[0..git_dir.len], git_dir) and isSlash(path[git_dir.len])) return path[git_dir.len + 1 ..];
    return null;
}

pub fn keptConfigKey(key: []const u8) bool {
    const first = std.mem.indexOfScalar(u8, key, '.') orelse return false;
    const last = std.mem.lastIndexOfScalar(u8, key, '.') orelse return false;
    if (last == first) return false;
    const section = key[0..first];
    const name = key[last + 1 ..];
    for (kept_config_sections) |kept| {
        if (!std.ascii.eqlIgnoreCase(section, kept)) continue;
        for (kept_config_keys) |allowed| {
            if (std.ascii.eqlIgnoreCase(name, allowed)) return true;
        }
    }
    return false;
}

fn isSlash(c: u8) bool {
    return c == '/' or c == '\\';
}

fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const nx = if (x == '\\') '/' else std.ascii.toLower(x);
        const ny = if (y == '\\') '/' else std.ascii.toLower(y);
        if (nx != ny) return false;
    }
    return true;
}

test "gate config: the gate's own files and folders are covered, case and slashes aside, and nothing else is" {
    for ([_][]const u8{ ".mcp.json", ".MCP.JSON", ".claude/settings.json", ".claude\\settings.local.json", ".claude/agents/a.md", ".claude/agents/deep/b.md", ".emetgate/ledger.ndjson", ".emetgate/LEDGER.ndjson.emetgate-0123.bak", ".git/config", ".git/hooks/pre-commit" }) |path| {
        try std.testing.expect(covers(path));
    }
    for ([_][]const u8{ "a.mcp.json", ".claude/agents", ".claude/commands/rule.md", ".claude/settings.json.bak", ".git/index", ".emetgate/journal", ".emetgate/frozen-hold/1/0", ".emetgate/ledger.ndjson/x", "src/.mcp.json" }) |path| {
        try std.testing.expect(!covers(path));
    }
}

test "gate config: branch tracking and remote urls are kept in the git config, hook paths and the rest are not" {
    for ([_][]const u8{ "branch.main.remote", "branch.Feature.merge", "remote.origin.url", "remote.origin.fetch" }) |key| try std.testing.expect(keptConfigKey(key));
    for ([_][]const u8{ "core.hookspath", "core.fsmonitor", "remote.origin.uploadpack", "branch.autosetupmerge", "include.path", "alias.st" }) |key| try std.testing.expect(!keptConfigKey(key));
}
