const std = @import("std");
const runner = @import("runner.zig");
const shadow = @import("shadow.zig");
const gate_tree = @import("gate_tree.zig");
const shadow_root = @import("shadow_root.zig");
const sandbox = @import("sandbox.zig");
const test_command = @import("test_command.zig");
const toolchain = @import("toolchain.zig");
const receipts = @import("receipts.zig");
const receipt = @import("../verify/receipt.zig");

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
    blocked: ?*gate_tree.Report = null,
    linked: []const []const u8 = &shadow.dependency_dirs,
    limits: sandbox.Limits = .{},
};

pub fn runInShadow(gpa: Allocator, io: std.Io, options: Options) !sandbox.Report {
    validateEntry(options.command) catch return error.RunCommandRefused;
    const lock = try shadow.Lock.acquire(io, options.root_abs);
    defer lock.release();
    const location = try shadow_root.locate(gpa, options.root_abs, options.shadow_root);
    defer location.deinit(gpa);

    const files = try shadow.workingFiles(gpa, io, options.root_abs);
    defer gpa.free(files);
    defer shadow.freeFileList(gpa, files);

    var trace: runner.Trace = .{};
    defer if (options.blocked) |blocked| {
        blocked.* = trace.blocked;
    };
    var workspace = try runner.prepareShadow(gpa, io, options.root_abs, location, location.shadow, files, options.linked, options.gate_tree, &trace, null);
    if (options.used) |used| workspace.reportTo(used);
    defer workspace.finish();
    return switch (try runner.runStages(gpa, io, location.shadow, null, options.command, options.limits)) {
        .tests => |report| report,
        .typecheck => |report| report,
        .rule_violation, .rule_check_failed => unreachable,
    };
}

pub const toolchain_limits: sandbox.Limits = .{ .timeout_ms = 600_000, .max_output_bytes = 4 * 1024 * 1024 };

pub fn isToolchain(command: []const u8) bool {
    if (hasShellMetacharacter(command) or command.len > max_entry_bytes or argumentsEscape(command)) return false;
    return toolchain.classify(command) != null;
}

const separators = " \t\"";
const path_separators = "\\/";
const project_interpreters = [_][]const u8{ "python", "python3", "pytest", "mypy", "ruff", "pip", "pip3" };

pub fn isToolchainIn(io: std.Io, root_abs: []const u8, command: []const u8) bool {
    if (hasShellMetacharacter(command) or command.len > max_entry_bytes or argumentsEscape(command)) return false;
    var tokens = std.mem.tokenizeAny(u8, command, separators);
    const first = tokens.next() orelse return false;
    if (std.mem.indexOfAny(u8, first, path_separators) == null) return toolchain.classify(command) != null;
    if (!projectInterpreter(io, root_abs, first)) return false;
    var buffer: [max_entry_bytes]u8 = undefined;
    const tool = toolName(first);
    const rest = command[tokens.index..];
    if (tool.len + rest.len > buffer.len) return false;
    @memcpy(buffer[0..tool.len], tool);
    @memcpy(buffer[tool.len..][0..rest.len], rest);
    return toolchain.classify(buffer[0 .. tool.len + rest.len]) != null;
}

fn projectInterpreter(io: std.Io, root_abs: []const u8, token: []const u8) bool {
    var listed = false;
    for (project_interpreters) |name| {
        if (std.ascii.eqlIgnoreCase(name, toolName(token))) listed = true;
    }
    if (!listed) return false;
    var storage: [4 * std.fs.max_path_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const a = fixed.allocator();
    const real = realInRoot(io, a, root_abs, token, &.{ "", ".exe" }) orelse return false;
    return inVenv(io, a, real);
}

fn realInRoot(io: std.Io, a: Allocator, root_abs: []const u8, token: []const u8, suffixes: []const []const u8) ?[]const u8 {
    const real_root = std.Io.Dir.cwd().realPathFileAlloc(io, root_abs, a) catch return null;
    for (suffixes) |suffix| {
        const joined = std.fmt.allocPrint(a, "{s}\\{s}{s}", .{ root_abs, token, suffix }) catch return null;
        std.mem.replaceScalar(u8, joined, '/', '\\');
        const real = std.Io.Dir.cwd().realPathFileAlloc(io, joined, a) catch continue;
        if (real.len <= real_root.len or !std.ascii.startsWithIgnoreCase(real, real_root) or real[real_root.len] != '\\') return null;
        return real;
    }
    return null;
}

const script_runners = [_][]const u8{ "npm", "pnpm", "yarn" };
const tool_suffixes = [_][]const u8{ "", ".exe", ".cmd" };

pub fn isProjectCommand(gpa: Allocator, io: std.Io, root_abs: []const u8, command: []const u8) bool {
    validateEntry(command) catch return false;
    if (argumentsEscape(command)) return false;
    var tokens = std.mem.tokenizeAny(u8, command, separators);
    const first = tokens.next() orelse return false;
    if (std.mem.indexOfAny(u8, first, path_separators) != null) return projectTool(io, root_abs, first);
    var listed = false;
    for (script_runners) |name| {
        if (std.ascii.eqlIgnoreCase(name, toolName(first))) listed = true;
    }
    if (!listed) return false;
    const verb = tokens.next() orelse return false;
    if (!std.mem.eql(u8, verb, "run") and !std.mem.eql(u8, verb, "run-script")) return false;
    const script = tokens.next() orelse return false;
    return packageScript(gpa, io, root_abs, script) catch false;
}

fn projectTool(io: std.Io, root_abs: []const u8, token: []const u8) bool {
    var storage: [4 * std.fs.max_path_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const a = fixed.allocator();
    const real = realInRoot(io, a, root_abs, token, &tool_suffixes) orelse return false;
    const dir = std.fs.path.dirnameWindows(real) orelse return false;
    const parent = std.fs.path.dirnameWindows(dir) orelse return false;
    const dir_name = std.fs.path.basenameWindows(dir);
    if (std.ascii.eqlIgnoreCase(dir_name, ".bin")) return std.ascii.eqlIgnoreCase(std.fs.path.basenameWindows(parent), "node_modules");
    if (std.ascii.eqlIgnoreCase(dir_name, "Scripts") or std.ascii.eqlIgnoreCase(dir_name, "bin")) return inVenv(io, a, real);
    return false;
}

fn packageScript(gpa: Allocator, io: std.Io, root_abs: []const u8, script: []const u8) !bool {
    const path = try std.fmt.allocPrint(gpa, "{s}\\package.json", .{root_abs});
    defer gpa.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024));
    defer gpa.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const scripts = parsed.value.object.get("scripts") orelse return false;
    if (scripts != .object) return false;
    return scripts.object.get(script) != null;
}

pub fn argumentsEscape(command: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, command, separators);
    _ = tokens.next() orelse return false;
    while (tokens.next()) |token| {
        if (argumentEscapes(token)) return true;
    }
    return false;
}

fn argumentEscapes(token: []const u8) bool {
    if (token.len > 1 and token[0] == '/') {
        const colon = std.mem.indexOfScalar(u8, token, ':') orelse return true;
        if (!isSwitchName(token[1..colon])) return true;
        return argumentEscapes(token[colon + 1 ..]);
    }
    if (pathEscapes(token)) return true;
    if (std.mem.indexOfScalar(u8, token, '=')) |eq| {
        if (argumentEscapes(token[eq + 1 ..])) return true;
    }
    return token.len > 2 and token[0] == '-' and token[1] != '-' and pathEscapes(token[2..]);
}

fn isSwitchName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    }
    return true;
}

fn pathEscapes(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value[0] == '\\' or value[0] == '/' or value[0] == '~') return true;
    if (value.len >= 2 and value[1] == ':') return true;
    var depth: usize = 0;
    var parts = std.mem.tokenizeAny(u8, value, path_separators);
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) {
            if (depth == 0) return true;
            depth -= 1;
        } else if (!std.mem.eql(u8, part, ".")) depth += 1;
    }
    return false;
}

fn inVenv(io: std.Io, a: Allocator, exe_abs: []const u8) bool {
    const scripts = std.fs.path.dirnameWindows(exe_abs) orelse return false;
    const venv = std.fs.path.dirnameWindows(scripts) orelse return false;
    const config = std.fmt.allocPrint(a, "{s}\\pyvenv.cfg", .{venv}) catch return false;
    std.Io.Dir.cwd().access(io, config, .{}) catch return false;
    return true;
}

pub fn localCommand(gpa: Allocator, command: []const u8) ![]u8 {
    const owned = try gpa.dupe(u8, command);
    const start = std.mem.indexOfNone(u8, owned, separators) orelse return owned;
    const end = std.mem.indexOfAnyPos(u8, owned, start, separators) orelse owned.len;
    std.mem.replaceScalar(u8, owned[start..end], '/', '\\');
    return owned;
}

pub const RepoRun = struct {
    report: sandbox.Report,
    changed: usize = 0,
    receipt: ?[64]u8 = null,
    receipt_error: ?anyerror = null,
};

pub fn runInRepo(gpa: Allocator, io: std.Io, root_abs: []const u8, command: []const u8, limits: sandbox.Limits, version: []const u8) !RepoRun {
    if (!isToolchainIn(io, root_abs, command)) return error.RunCommandRefused;
    const local = try localCommand(gpa, command);
    defer gpa.free(local);
    const lock = try shadow.Lock.acquire(io, root_abs);
    defer lock.release();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = try snapshot(arena, gpa, io, root_abs);
    var ran: RepoRun = .{ .report = try runner.runToolchain(gpa, io, root_abs, local, limits) };
    const clean = switch (ran.report.outcome) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!clean) return ran;
    const changes = changedSince(arena, gpa, io, root_abs, &before) catch |err| {
        ran.receipt_error = err;
        return ran;
    };
    ran.changed = changes.len;
    if (changes.len == 0) return ran;
    const written = receipts.write(gpa, io, root_abs, .{
        .operation = .run,
        .class = .spending,
        .evidence = "run",
        .files = changes,
        .test_command = command,
        .check_kind = .run,
        .test_ms = ran.report.duration_ns / std.time.ns_per_ms,
        .limits = limits,
        .integrity = "user",
        .version = version,
    }) catch |err| {
        ran.receipt_error = err;
        return ran;
    };
    gpa.free(written.batch);
    ran.receipt = written.id;
    return ran;
}

const Seen = std.StringArrayHashMapUnmanaged(receipt.Hash);

fn snapshot(arena: Allocator, gpa: Allocator, io: std.Io, root_abs: []const u8) !Seen {
    var seen: Seen = .empty;
    for (try shadow.workingFiles(arena, io, root_abs)) |rel| {
        const hash = hashAt(gpa, io, root_abs, rel) orelse continue;
        try seen.put(arena, rel, hash);
    }
    return seen;
}

fn changedSince(arena: Allocator, gpa: Allocator, io: std.Io, root_abs: []const u8, before: *const Seen) ![]receipts.FileChange {
    var changes: std.ArrayList(receipts.FileChange) = .empty;
    var present: std.StringHashMapUnmanaged(void) = .empty;
    for (try shadow.workingFiles(arena, io, root_abs)) |rel| {
        try present.put(arena, rel, {});
        const now = hashAt(gpa, io, root_abs, rel) orelse continue;
        const was = before.get(rel);
        if (was) |hash| if (std.mem.eql(u8, &hash, &now)) continue;
        try changes.append(arena, .{ .rel = rel, .before = was, .after_abs = try absOf(arena, root_abs, rel) });
    }
    for (before.keys(), before.values()) |rel, hash| {
        if (present.contains(rel)) continue;
        if (std.Io.Dir.cwd().access(io, try absOf(arena, root_abs, rel), .{})) |_| continue else |_| {}
        try changes.append(arena, .{ .rel = rel, .before = hash, .after_abs = null });
    }
    return changes.items;
}

fn absOf(arena: Allocator, root_abs: []const u8, rel: []const u8) ![]u8 {
    const abs = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ root_abs, rel });
    std.mem.replaceScalar(u8, abs, '/', '\\');
    return abs;
}

fn hashAt(gpa: Allocator, io: std.Io, root_abs: []const u8, rel: []const u8) ?receipt.Hash {
    var buffer: [2 * std.fs.max_path_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const abs = absOf(fixed.allocator(), root_abs, rel) catch return null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, abs, gpa, .limited(max_hashed_bytes)) catch return null;
    defer gpa.free(bytes);
    return receipt.blake3(bytes);
}

const max_hashed_bytes = 256 * 1024 * 1024;

pub const Tail = struct {
    text: []const u8,
    omitted_lines: usize,
};

pub fn tail(bytes: []const u8, max_lines: usize, max_bytes: usize) Tail {
    var start: usize = if (bytes.len > max_bytes) bytes.len - max_bytes else 0;
    if (start > 0 and bytes[start - 1] != '\n') {
        if (std.mem.indexOfScalarPos(u8, bytes, start, '\n')) |nl| start = nl + 1;
    }
    while (start < bytes.len and bytes[start] & 0xC0 == 0x80) start += 1;
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

test "output cut by bytes never starts inside a multi-byte character" {
    const cut = tail("\u{e7}\u{e7}\u{e7}", 100, 3);
    try testing.expectEqualStrings("\u{e7}", cut.text);
    try testing.expect(std.unicode.utf8ValidateSlice(cut.text));
}

test "toolchain commands are accepted for the repo run while shells, git and metacharacters are not" {
    for ([_][]const u8{ "npm install", "npx tsc --noEmit", "dotnet restore", "python -m pip install -r requirements.txt", "pytest -q", "pip wheel . --no-deps -w dist", "dotnet build /p:Configuration=Release", "go test ./...", "pip install -e src\\..\\lib", "pip install --index-url=https://pypi.org/simple x" }) |command| {
        errdefer std.debug.print("refused: {s}\n", .{command});
        try testing.expect(isToolchain(command));
    }
    for ([_][]const u8{ "npm install & del x", "npm install | more", "git push", "cmd /c npm install", "npx tsc %x%", "a" ** (max_entry_bytes + 1), "pip wheel . -w C:\\out", "pip download -d ..\\out x", "pip install --target=\\\\host\\share x", "dotnet build -o../out", "dotnet build /p:OutDir=D:\\x", "dotnet build /out", "npm init -y ~", "pip install src\\..\\..\\x" }) |command| {
        errdefer std.debug.print("accepted: {s}\n", .{command});
        try testing.expect(!isToolchain(command));
    }
}

fn makeFile(dir: std.Io.Dir, sub_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| try dir.createDirPath(testing.io, parent);
    try dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
}

test "package scripts and project tools inside the root run as project commands, other commands do not" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "repo/package.json", "{\"scripts\":{\"build\":\"vite build\",\"lint\":\"eslint .\"}}");
    try makeFile(tmp.dir, "repo/.venv/pyvenv.cfg", "home = x\n");
    try makeFile(tmp.dir, "repo/.venv/Scripts/wordstat.exe", "x");
    try makeFile(tmp.dir, "repo/node_modules/.bin/vite.cmd", "x");
    try makeFile(tmp.dir, "repo/tools/run.exe", "x");
    try makeFile(tmp.dir, "repo/lib/Scripts/x.exe", "x");
    try makeFile(tmp.dir, "outside/.venv/pyvenv.cfg", "home = x\n");
    try makeFile(tmp.dir, "outside/.venv/Scripts/evil.exe", "x");
    const root = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
    defer testing.allocator.free(root);
    for ([_][]const u8{ "npm run build", "pnpm run lint -- --max-warnings 0", "yarn run-script build", ".venv\\Scripts\\wordstat --top 3 README.md", ".venv/Scripts/wordstat", "node_modules\\.bin\\vite build" }) |command| {
        errdefer std.debug.print("refused: {s}\n", .{command});
        try testing.expect(isProjectCommand(testing.allocator, testing.io, root, command));
    }
    for ([_][]const u8{ "npm run deploy", "npm run", "npm exec build", "bun run build", "npm run build & del x", "npm run build -- --outDir C:\\x", "npm run build -- --outDir=..\\x", "tools\\run.exe", "lib\\Scripts\\x", "..\\outside\\.venv\\Scripts\\evil", ".venv\\Scripts\\pip install x", "node_modules\\.bin\\missing" }) |command| {
        errdefer std.debug.print("accepted: {s}\n", .{command});
        try testing.expect(!isProjectCommand(testing.allocator, testing.io, root, command));
    }
}
