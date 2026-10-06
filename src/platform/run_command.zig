const std = @import("std");
const runner = @import("runner.zig");
const shadow = @import("shadow.zig");
const shadow_root = @import("shadow_root.zig");
const sandbox = @import("sandbox.zig");
const test_command = @import("test_command.zig");

const Allocator = std.mem.Allocator;

pub const max_entries = 32;
pub const max_entry_bytes = 512;

pub const EntryError = error{ RunCommandEmpty, RunCommandTooLong, RunCommandShellMetacharacter, RunCommandOutOfScope };

pub const shell_metacharacters = "&|<>^%!;`$()\r\n\x00";

pub fn hasShellMetacharacter(command: []const u8) bool {
    return std.mem.indexOfAny(u8, command, shell_metacharacters) != null;
}

const Forbidden = struct { tool: []const u8, subcommands: []const []const u8, bare: bool = false };

const install_subcommands = [_][]const u8{
    "install", "i",      "in",            "ins",    "inst",          "insta",           "instal", "isnt",         "isnta", "isntal", "isntall",
    "add",     "ci",     "clean-install", "ic",     "install-clean", "install-ci-test", "cit",    "install-test", "it",    "update", "up",
    "upgrade", "udpate", "uninstall",     "unlink", "remove",        "rm",              "r",      "un",           "link",  "ln",     "publish",
    "exec",    "x",      "rebuild",       "rb",     "dedupe",        "ddp",             "prune",  "import",       "fetch", "dlx",    "a",
};

pub const out_of_scope = [_]Forbidden{
    .{ .tool = "npm", .subcommands = &install_subcommands },
    .{ .tool = "pnpm", .subcommands = &install_subcommands },
    .{ .tool = "yarn", .subcommands = &install_subcommands, .bare = true },
    .{ .tool = "bun", .subcommands = &install_subcommands },
    .{ .tool = "pip", .subcommands = &.{ "install", "uninstall", "download" } },
    .{ .tool = "pip3", .subcommands = &.{ "install", "uninstall", "download" } },
    .{ .tool = "git", .subcommands = &.{ "commit", "push" } },
};

fn toolName(token: []const u8) []const u8 {
    var name = std.fs.path.basenameWindows(token);
    for ([_][]const u8{ ".cmd", ".exe", ".bat", ".ps1" }) |suffix| {
        if (std.ascii.endsWithIgnoreCase(name, suffix)) {
            name = name[0 .. name.len - suffix.len];
            break;
        }
    }
    return name;
}

const script_boundaries = [_][]const u8{ "run", "run-script", "rum", "urn", "test", "t", "tst", "--" };

fn isScriptBoundary(token: []const u8) bool {
    for (script_boundaries) |boundary| {
        if (std.ascii.eqlIgnoreCase(token, boundary)) return true;
    }
    return false;
}

pub fn isOutOfScope(command: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, command, " \t\"");
    const first = tokens.next() orelse return false;
    const tool = toolName(first);
    for (out_of_scope) |rule| {
        if (!std.ascii.eqlIgnoreCase(tool, rule.tool)) continue;
        var rest = tokens;
        if (rule.bare and rest.peek() == null) return true;
        while (rest.next()) |token| {
            if (isScriptBoundary(token)) break;
            for (rule.subcommands) |sub| {
                if (std.ascii.eqlIgnoreCase(token, sub)) return true;
            }
        }
    }
    return false;
}

pub fn validateEntry(command: []const u8) EntryError!void {
    if (std.mem.trim(u8, command, " \t").len == 0) return error.RunCommandEmpty;
    if (command.len > max_entry_bytes) return error.RunCommandTooLong;
    if (hasShellMetacharacter(command)) return error.RunCommandShellMetacharacter;
    if (isOutOfScope(command)) return error.RunCommandOutOfScope;
}

pub fn match(allowed: []const []const u8, requested: []const u8) ?[]const u8 {
    for (allowed) |entry| {
        if (std.mem.eql(u8, entry, requested)) return entry;
    }
    return null;
}

pub const Refusal = enum { not_allowed, shell_metacharacter, out_of_scope, invalid_entry };

pub const Checked = union(enum) {
    allowed: []const u8,
    refused: Refusal,
};

pub fn check(allowed: []const []const u8, requested: []const u8) Checked {
    if (hasShellMetacharacter(requested)) return .{ .refused = .shell_metacharacter };
    const entry = match(allowed, requested) orelse return .{ .refused = .not_allowed };
    validateEntry(entry) catch |err| return .{ .refused = switch (err) {
        error.RunCommandOutOfScope => .out_of_scope,
        error.RunCommandShellMetacharacter => .shell_metacharacter,
        error.RunCommandEmpty, error.RunCommandTooLong => .invalid_entry,
    } };
    return .{ .allowed = entry };
}

const RepoConfig = struct { run: []const []const u8 = &.{} };

pub const RepoRuns = struct {
    parsed: ?std.json.Parsed(RepoConfig),

    pub fn entries(self: RepoRuns) []const []const u8 {
        const parsed = self.parsed orelse return &.{};
        return parsed.value.run;
    }

    pub fn deinit(self: RepoRuns) void {
        if (self.parsed) |parsed| parsed.deinit();
    }
};

pub fn repoConfigRuns(gpa: Allocator, io: std.Io, root_abs: []const u8) !RepoRuns {
    const path = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root_abs, test_command.config_file });
    defer gpa.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{ .parsed = null },
        else => return err,
    };
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice(RepoConfig, gpa, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.InvalidConfig;
    return .{ .parsed = parsed };
}

pub const Options = struct {
    root_abs: []const u8,
    command: []const u8,
    shadow_root: ?[]const u8 = null,
    gate_tree: shadow.Choice = .{},
    used: ?*shadow.TreeUse = null,
    linked: []const []const u8 = &.{"node_modules"},
    limits: sandbox.Limits = .{},
};

pub fn runInShadow(gpa: Allocator, io: std.Io, options: Options) !sandbox.Report {
    validateEntry(options.command) catch return error.RunCommandRefused;
    const lock = try shadow.Lock.acquire(io, options.root_abs);
    defer lock.release();
    const location = try shadow_root.locate(gpa, options.root_abs, options.shadow_root);
    defer location.deinit(gpa);

    const files = try shadow.trackedFiles(gpa, io, options.root_abs);
    defer gpa.free(files);
    defer shadow.freeFileList(gpa, files);

    var workspace = try runner.prepareShadow(gpa, io, options.root_abs, location, files, options.linked, options.gate_tree, null);
    if (options.used) |used| used.* = workspace.use;
    defer workspace.finish();
    return switch (try runner.runStages(gpa, io, location.shadow, null, options.command, options.limits)) {
        .tests => |report| report,
        .typecheck => |report| report,
        .rule_violation, .rule_check_failed => unreachable,
    };
}

pub const Tail = struct {
    text: []const u8,
    omitted_lines: usize,
};

pub fn tail(bytes: []const u8, max_lines: usize, max_bytes: usize) Tail {
    var start: usize = if (bytes.len > max_bytes) bytes.len - max_bytes else 0;
    if (start > 0 and bytes[start - 1] != '\n') {
        if (std.mem.indexOfScalarPos(u8, bytes, start, '\n')) |nl| start = nl + 1;
    }
    const body_end = if (bytes.len > 0 and bytes[bytes.len - 1] == '\n') bytes.len - 1 else bytes.len;
    var lines: usize = 0;
    var i: usize = body_end;
    while (i > start) : (i -= 1) {
        if (bytes[i - 1] != '\n') continue;
        lines += 1;
        if (lines == max_lines) {
            start = i;
            break;
        }
    }
    return .{ .text = bytes[start..], .omitted_lines = std.mem.count(u8, bytes[0..start], "\n") };
}

const testing = std.testing;

test "an allowlist entry with a shell metacharacter is refused" {
    for ([_][]const u8{ "npm test & del x", "npm test && del x", "npm test | more", "npm test; del x", "npm test `x`", "npm test $(x)", "echo %PATH%", "npm test\ndel x", "npm test\rdel x", "npm test > out.txt", "npm test ^& x", "echo !x!" }) |entry| {
        errdefer std.debug.print("accepted: {s}\n", .{entry});
        try testing.expectError(error.RunCommandShellMetacharacter, validateEntry(entry));
    }
    try validateEntry("npm test");
    try validateEntry("npm run lint");
    try validateEntry("zig build test \"-Dtest-filter=a b\"");
}

test "installing dependencies and git commit or push are out of scope for the allowlist" {
    for ([_][]const u8{ "npm install", "npm i", "npm ci", "npm.cmd install left-pad", "C:\\nodejs\\npm.cmd ci", "pnpm i", "pnpm add x", "yarn", "yarn install", "yarn add x", "bun install", "npm update", "npm uninstall x", "pip install x", "git commit -m x", "git push", "GIT PUSH origin main", "npm --prefix . install" }) |entry| {
        errdefer std.debug.print("accepted: {s}\n", .{entry});
        try testing.expectError(error.RunCommandOutOfScope, validateEntry(entry));
    }
    for ([_][]const u8{ "npm test", "npm run lint", "npm run r", "npm test -- --grep install", "yarn test", "yarn run add-headers", "pnpm test", "git status", "zig build", "npx tsc --noEmit" }) |entry| {
        errdefer std.debug.print("refused: {s}\n", .{entry});
        try validateEntry(entry);
    }
}

test "an empty or oversized allowlist entry is refused" {
    try testing.expectError(error.RunCommandEmpty, validateEntry(""));
    try testing.expectError(error.RunCommandEmpty, validateEntry("  \t"));
    try testing.expectError(error.RunCommandTooLong, validateEntry("a" ** (max_entry_bytes + 1)));
}

test "a request runs only the allowlist entry it equals byte for byte" {
    const allowed = [_][]const u8{ "npm test", "npm run lint" };
    try testing.expectEqualStrings("npm test", check(&allowed, "npm test").allowed);
    try testing.expectEqual(Checked{ .refused = .not_allowed }, check(&allowed, "npm test --watch"));
    try testing.expectEqual(Checked{ .refused = .not_allowed }, check(&allowed, "npm  test"));
    try testing.expectEqual(Checked{ .refused = .not_allowed }, check(&allowed, "NPM TEST"));
    try testing.expectEqual(Checked{ .refused = .not_allowed }, check(&allowed, "npm"));
    try testing.expectEqual(Checked{ .refused = .shell_metacharacter }, check(&allowed, "npm test & del x"));
    try testing.expectEqual(Checked{ .refused = .not_allowed }, check(&.{}, "npm test"));
}

test "an allowlist entry that slipped past startup validation is still refused at call time" {
    const allowed = [_][]const u8{ "npm test & del x", "npm install" };
    try testing.expectEqual(Checked{ .refused = .shell_metacharacter }, check(&allowed, "npm test & del x"));
    try testing.expectEqual(Checked{ .refused = .out_of_scope }, check(&allowed, "npm install"));
}

test "output is cut to its last lines with a count of the lines left out" {
    const cut = tail("a\nb\nc\nd\n", 2, 1024);
    try testing.expectEqualStrings("c\nd\n", cut.text);
    try testing.expectEqual(@as(usize, 2), cut.omitted_lines);
    const whole = tail("a\nb\n", 5, 1024);
    try testing.expectEqualStrings("a\nb\n", whole.text);
    try testing.expectEqual(@as(usize, 0), whole.omitted_lines);
    const by_bytes = tail("aaaa\nbbbb\ncccc\n", 100, 7);
    try testing.expectEqualStrings("cccc\n", by_bytes.text);
    try testing.expectEqual(@as(usize, 2), by_bytes.omitted_lines);
    const no_newline = tail("x\ny", 1, 1024);
    try testing.expectEqualStrings("y", no_newline.text);
    try testing.expectEqual(@as(usize, 1), no_newline.omitted_lines);
}
