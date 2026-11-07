const std = @import("std");
const memory = @import("memory.zig");
const shadow = @import("shadow.zig");

pub const rule_id = "gate-config";
pub const rule_text = "under lockdown emetgate's own configuration (.mcp.json, the project Claude settings and agents, the rules ledger, the git hooks and git config) is changed by hand by the user";

pub const ledger_dir = shadow.workspace_dir;
pub const ledger_name = memory.ledger_name;
pub const ledger = ledger_dir ++ "/" ++ ledger_name;
pub const git_dir = ".git";
pub const git_config = git_dir ++ "/config";
pub const git_hooks = git_dir ++ "/hooks";
pub const agents = ".claude/agents";

pub const tracked_files = [_][]const u8{ ".mcp.json", ".claude/settings.json" };
pub const tracked_dirs = [_][]const u8{agents};
pub const files = tracked_files ++ [_][]const u8{git_config};
pub const dirs = tracked_dirs ++ [_][]const u8{git_hooks};

const any_key_sections = [_][]const u8{ "branch", "user", "init" };
const remote_keys = [_][]const u8{ "url", "pushurl", "fetch", "push", "mirror", "tagopt", "prune", "prunetags", "skipdefaultupdate", "skipfetchall", "promisor", "partialclonefilter" };
const submodule_keys = [_][]const u8{ "url", "active", "branch" };
const submodule_updates = [_][]const u8{ "checkout", "rebase", "merge", "none" };
const core_keys = [_][]const u8{ "sparsecheckout", "sparsecheckoutcone", "repositoryformatversion", "bare", "logallrefupdates", "ignorecase", "precomposeunicode", "filemode", "symlinks" };
const SafeKey = struct { section: []const u8, name: []const u8 };
const safe_keys = [_]SafeKey{
    .{ .section = "extensions", .name = "worktreeconfig" },
    .{ .section = "pull", .name = "rebase" },
    .{ .section = "push", .name = "default" },
    .{ .section = "fetch", .name = "prune" },
};

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

pub fn safeConfigEntry(key: []const u8, value: []const u8) bool {
    const first = std.mem.indexOfScalar(u8, key, '.') orelse return false;
    const last = std.mem.lastIndexOfScalar(u8, key, '.') orelse return false;
    const section = key[0..first];
    const name = key[last + 1 ..];
    const nested = last != first;
    if (anyOf(section, &any_key_sections)) return true;
    if (std.ascii.eqlIgnoreCase(section, "remote")) return !nested or anyOf(name, &remote_keys);
    if (std.ascii.eqlIgnoreCase(section, "submodule")) {
        if (!nested) return false;
        if (anyOf(name, &submodule_keys)) return true;
        return std.ascii.eqlIgnoreCase(name, "update") and anyOf(value, &submodule_updates);
    }
    if (std.ascii.eqlIgnoreCase(section, "gc")) return std.ascii.indexOfIgnoreCase(name, "hook") == null;
    if (nested) return false;
    if (std.ascii.eqlIgnoreCase(section, "core")) return anyOf(name, &core_keys);
    for (safe_keys) |safe| {
        if (std.ascii.eqlIgnoreCase(section, safe.section) and std.ascii.eqlIgnoreCase(name, safe.name)) return true;
    }
    return false;
}

fn anyOf(text: []const u8, list: []const []const u8) bool {
    for (list) |item| {
        if (std.ascii.eqlIgnoreCase(text, item)) return true;
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
    for ([_][]const u8{ ".mcp.json", ".MCP.JSON", ".claude/settings.json", ".claude\\Settings.json", ".claude/agents/a.md", ".claude/agents/deep/b.md", ".emetgate/ledger.ndjson", ".emetgate/LEDGER.ndjson.emetgate-0123.bak", ".git/config", ".git/hooks/pre-commit" }) |path| {
        try std.testing.expect(covers(path));
    }
    for ([_][]const u8{ "a.mcp.json", ".claude/settings.local.json", ".claude/agents", ".claude/commands/rule.md", ".claude/settings.json.bak", ".git/index", ".emetgate/journal", ".emetgate/frozen-hold/1/0", ".emetgate/ledger.ndjson/x", "src/.mcp.json" }) |path| {
        try std.testing.expect(!covers(path));
    }
}

test "gate config: the git config keeps branch, remote, user, submodule, sparse and worktree keys, and puts back hook paths, fsmonitor, aliases and includes" {
    const Entry = struct { []const u8, []const u8 };
    for ([_]Entry{
        .{ "branch.main.remote", "origin" },
        .{ "branch.Feature.merge", "refs/heads/Feature" },
        .{ "branch.autosetupmerge", "always" },
        .{ "remote.origin.url", "https://example.com/r.git" },
        .{ "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*" },
        .{ "user.email", "a@b.c" },
        .{ "submodule.lib.url", "../lib.git" },
        .{ "submodule.lib.active", "true" },
        .{ "submodule.lib.update", "rebase" },
        .{ "extensions.worktreeconfig", "true" },
        .{ "core.sparsecheckout", "true" },
        .{ "core.sparsecheckoutcone", "true" },
        .{ "core.repositoryformatversion", "1" },
        .{ "init.defaultbranch", "main" },
        .{ "pull.rebase", "true" },
        .{ "gc.auto", "0" },
    }) |entry| try std.testing.expect(safeConfigEntry(entry[0], entry[1]));
    for ([_]Entry{
        .{ "core.hookspath", "elsewhere" },
        .{ "core.fsmonitor", "evil" },
        .{ "core.sshcommand", "evil" },
        .{ "core.editor", "evil" },
        .{ "alias.st", "!evil" },
        .{ "include.path", "evil" },
        .{ "includeif.gitdir:/x/.path", "evil" },
        .{ "remote.origin.uploadpack", "evil" },
        .{ "submodule.lib.update", "!evil" },
        .{ "submodule.lib.update", "custom" },
        .{ "url.evil.insteadof", "https://example.com/" },
        .{ "credential.helper", "evil" },
        .{ "filter.lfs.smudge", "evil" },
        .{ "diff.x.textconv", "evil" },
        .{ "gc.prunehook", "evil" },
        .{ "unknown.key", "x" },
    }) |entry| try std.testing.expect(!safeConfigEntry(entry[0], entry[1]));
}
