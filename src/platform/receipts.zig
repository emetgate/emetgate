const std = @import("std");
const receipt = @import("../verify/receipt.zig");
const checker = @import("../verify/checker.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const jcs = @import("../verify/jcs.zig");
const disk = @import("disk.zig");
const rules = @import("rules.zig");
const sandbox = @import("sandbox.zig");
const shadow = @import("shadow.zig");
const exe_path = @import("exe_path.zig");
const own_dir = @import("own_dir.zig");

const Allocator = std.mem.Allocator;
const Hash = receipt.Hash;

pub const receipts_dir = "receipts";
pub const notes_ref = "emetgate";
const max_git_output = 64 * 1024 * 1024;

pub const FileChange = struct {
    rel: []const u8,
    before: ?Hash,
    after_abs: ?[]const u8,
};

pub const Record = struct {
    operation: receipt.Operation,
    class: receipt.Class,
    evidence: []const u8,
    resolver: ?[]const u8 = null,
    files: []const FileChange,
    symbols: []const receipt.SymbolEntry = &.{},
    test_command: []const u8,
    typecheck_command: ?[]const u8 = null,
    test_ms: ?u64 = null,
    limits: sandbox.Limits = .{},
    version: []const u8,
    commit: ?Commit = null,
};

pub const Commit = struct {
    base: []const u8,
    oid: []const u8,
    runtime: ?*Runtime = null,
};

fn storedSymbol(arena: Allocator, io: std.Io, root: []const u8, made: Commit, rev: []const u8, path: []const u8, ref: []const u8, claimed: ?Hash) !?Hash {
    if (claimed == null) return null;
    const runtime = made.runtime orelse return claimed;
    const bytes = (try blob(arena, io, root, rev, path)) orelse return claimed;
    return (try checker.symbolHashIn(arena, runtime, path, bytes, ref)) orelse claimed;
}

fn blob(arena: Allocator, io: std.Io, root: []const u8, rev: []const u8, path: []const u8) !?[]u8 {
    const spec = try std.fmt.allocPrint(arena, "{s}:{s}", .{ rev, path });
    return git(arena, io, root, &.{ "cat-file", "blob", spec });
}

pub fn slashed(arena: Allocator, rel: []const u8) ![]u8 {
    const out = try arena.dupe(u8, rel);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

pub fn build(arena: Allocator, io: std.Io, root: []const u8, record: Record) !receipt.Receipt {
    var random: [8]u8 = undefined;
    io.random(&random);
    const batch = try arena.dupe(u8, &std.fmt.bytesToHex(random, .lower));
    var files: std.ArrayList(receipt.FileEntry) = .empty;
    var subjects: std.ArrayList(receipt.Subject) = .empty;
    var rule_list: std.ArrayList(receipt.Rule) = .empty;
    for (record.files) |f| {
        const path = try slashed(arena, f.rel);
        var after: ?Hash = null;
        var before: ?Hash = f.before;
        if (record.commit) |made| {
            before = if (try blob(arena, io, root, made.base, path)) |bytes| receipt.blake3(bytes) else null;
        }
        if (f.after_abs) |abs| {
            const bytes = if (record.commit) |made|
                (try blob(arena, io, root, made.oid, path)) orelse return error.ReceiptFileNotInCommit
            else
                try std.Io.Dir.cwd().readFileAlloc(io, abs, arena, .unlimited);
            after = receipt.blake3(bytes);
            try subjects.append(arena, .{ .path = path, .blake3 = after.?, .sha256 = receipt.sha256(bytes) });
        }
        try files.append(arena, .{ .path = path, .before = before, .after = after });
        const adopted = rules.adoptedFor(arena, io, root, f.rel) catch continue;
        for (adopted.items) |rule| {
            var seen = false;
            for (rule_list.items) |r| if (std.mem.eql(u8, r.id, rule.id)) {
                seen = true;
            };
            if (seen) continue;
            try rule_list.append(arena, .{ .id = try arena.dupe(u8, rule.id), .digest = try receipt.ruleDigest(arena, rule.id, rule.text, rule.mode, rule.check, rule.where) });
        }
    }
    var symbols: std.ArrayList(receipt.SymbolEntry) = .empty;
    for (record.symbols) |s| {
        const path = try slashed(arena, s.path);
        var entry: receipt.SymbolEntry = .{ .path = path, .ref = s.ref, .before = s.before, .after = s.after };
        if (record.commit) |made| {
            entry.before = try storedSymbol(arena, io, root, made, made.base, path, s.ref, s.before);
            entry.after = try storedSymbol(arena, io, root, made, made.oid, path, s.ref, s.after);
        }
        try symbols.append(arena, entry);
    }
    var checks: std.ArrayList(receipt.Check) = .empty;
    if (record.typecheck_command) |command| if (command.len != 0) {
        try checks.append(arena, .{ .kind = .typecheck, .command = command, .command_digest = receipt.blake3(command), .exit_code = 0, .duration_ms = null });
    };
    try checks.append(arena, .{ .kind = .@"test", .command = record.test_command, .command_digest = receipt.blake3(record.test_command), .exit_code = 0, .duration_ms = if (record.test_ms) |ms| @intCast(ms) else null });
    return .{
        .batch = batch,
        .operation = record.operation,
        .class = record.class,
        .evidence = record.evidence,
        .resolver = record.resolver,
        .subjects = subjects.items,
        .files = files.items,
        .symbols = symbols.items,
        .checks = checks.items,
        .rules = rule_list.items,
        .sandbox = .{
            .integrity = "low",
            .job_memory_bytes = @intCast(sandbox.job_memory_bytes),
            .active_process_limit = sandbox.active_process_limit,
            .timeout_ms = @intCast(record.limits.timeout_ms),
            .output_limit_bytes = @intCast(record.limits.max_output_bytes),
        },
        .version = record.version,
    };
}

pub const Written = struct {
    id: [64]u8,
    batch: []const u8,
};

pub fn write(gpa: Allocator, io: std.Io, root: []const u8, record: Record) !Written {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = try build(arena, io, root, record);
    const bytes = try receipt.encode(arena, r);
    const dir = try std.fmt.allocPrint(arena, "{s}\\{s}\\{s}", .{ root, shadow.workspace_dir, receipts_dir });
    const held = (try own_dir.hold(io, dir, .create)).?;
    defer held.close();
    const now = std.Io.Timestamp.now(io, .real).nanoseconds;
    const path = try std.fmt.allocPrint(arena, "{s}\\{d:0>20}-{s}.json", .{ dir, @as(u128, @intCast(now)), r.batch });
    try disk.writeDurably(io, path, bytes);
    var batch: [16]u8 = undefined;
    @memcpy(&batch, r.batch);
    return .{ .id = std.fmt.bytesToHex(receipt.sha256(bytes), .lower), .batch = try gpa.dupe(u8, &batch) };
}

pub fn git(arena: Allocator, io: std.Io, root: []const u8, argv: []const []const u8) !?[]u8 {
    var full: std.ArrayList([]const u8) = .empty;
    try full.appendSlice(arena, &.{ try exe_path.git(arena, root), "-c", "core.longpaths=true" });
    try full.appendSlice(arena, argv);
    const result = std.process.run(arena, io, .{ .argv = full.items, .cwd = .{ .path = root }, .stdout_limit = .limited(max_git_output) }) catch return error.GitFailed;
    return switch (result.term) {
        .exited => |code| if (code == 0) result.stdout else null,
        else => error.GitFailed,
    };
}

pub fn resolveCommit(arena: Allocator, io: std.Io, root: []const u8, commit: []const u8) ![]const u8 {
    const spec = try std.fmt.allocPrint(arena, "{s}^{{commit}}", .{commit});
    const out = (try git(arena, io, root, &.{ "rev-parse", "--verify", "--quiet", spec })) orelse return error.UnknownCommit;
    return std.mem.trim(u8, out, " \r\n");
}

pub fn changedPaths(arena: Allocator, io: std.Io, root: []const u8, commit: []const u8) ![]const []const u8 {
    const out = (try git(arena, io, root, &.{ "diff-tree", "--no-commit-id", "--root", "-r", "--name-only", "-z", commit })) orelse return error.GitFailed;
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, out, 0);
    while (it.next()) |p| try list.append(arena, p);
    return list.items;
}

pub fn readNote(arena: Allocator, io: std.Io, root: []const u8, commit: []const u8) !?[]u8 {
    return git(arena, io, root, &.{ "notes", "--ref=" ++ notes_ref, "show", commit });
}

fn trimNote(bytes: []u8) []u8 {
    var end = bytes.len;
    while (end > 0 and (bytes[end - 1] == '\n' or bytes[end - 1] == '\r')) end -= 1;
    return bytes[0..end];
}

pub fn noteBytes(arena: Allocator, io: std.Io, root: []const u8, commit: []const u8) !?[]u8 {
    const raw = (try readNote(arena, io, root, commit)) orelse return null;
    return trimNote(raw);
}

pub const Attached = struct {
    count: usize,
};

pub fn attach(gpa: Allocator, io: std.Io, root: []const u8, commit: []const u8) !Attached {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rev = try resolveCommit(arena, io, root, commit);
    const changed = try changedPaths(arena, io, root, rev);
    const dir_abs = try std.fmt.allocPrint(arena, "{s}\\{s}\\{s}", .{ root, shadow.workspace_dir, receipts_dir });
    var names: std.ArrayList([]const u8) = .empty;
    const held = (try own_dir.hold(io, dir_abs, .existing)) orelse return .{ .count = 0 };
    defer held.close();
    {
        var it = held.dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, lessString);

    var items = std.json.Array.init(arena);
    if (try noteBytes(arena, io, root, rev)) |existing| {
        const parsed = try jcs.parse(arena, existing);
        if (parsed.value != .array) return error.CorruptNote;
        try items.appendSlice(parsed.value.array.items);
    }
    var taken: std.ArrayList([]const u8) = .empty;
    for (names.items) |name| {
        const bytes = try held.dir.readFileAlloc(io, name, arena, .limited(16 * 1024 * 1024));
        const parsed = jcs.parse(arena, bytes) catch continue;
        const r = receipt.fromValue(arena, parsed.value) catch continue;
        var covered = true;
        for (r.files) |f| {
            var found = false;
            for (changed) |c| if (std.mem.eql(u8, c, f.path)) {
                found = true;
            };
            if (!found) covered = false;
        }
        if (!covered) continue;
        try items.append(parsed.value);
        try taken.append(arena, name);
    }
    if (taken.items.len == 0) return .{ .count = 0 };
    try store(arena, io, root, rev, dir_abs, items, taken.items);
    return .{ .count = taken.items.len };
}

pub fn attachOne(gpa: Allocator, io: std.Io, root: []const u8, commit: []const u8, batch: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rev = try resolveCommit(arena, io, root, commit);
    const dir_abs = try std.fmt.allocPrint(arena, "{s}\\{s}\\{s}", .{ root, shadow.workspace_dir, receipts_dir });
    const suffix = try std.fmt.allocPrint(arena, "-{s}.json", .{batch});
    var name: ?[]const u8 = null;
    const held = (try own_dir.hold(io, dir_abs, .existing)) orelse return error.ReceiptNotFound;
    defer held.close();
    {
        var it = held.dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, suffix)) continue;
            name = try arena.dupe(u8, entry.name);
        }
    }
    const found = name orelse return error.ReceiptNotFound;
    var items = std.json.Array.init(arena);
    if (try noteBytes(arena, io, root, rev)) |existing| {
        const parsed = try jcs.parse(arena, existing);
        if (parsed.value != .array) return error.CorruptNote;
        try items.appendSlice(parsed.value.array.items);
    }
    const bytes = try held.dir.readFileAlloc(io, found, arena, .limited(16 * 1024 * 1024));
    try items.append((try jcs.parse(arena, bytes)).value);
    try store(arena, io, root, rev, dir_abs, items, &.{found});
}

fn store(arena: Allocator, io: std.Io, root: []const u8, rev: []const u8, dir_abs: []const u8, items: std.json.Array, taken: []const []const u8) !void {
    const note = try jcs.canonicalize(arena, .{ .array = items });
    const staged = try std.fmt.allocPrint(arena, "{s}\\note-{s}.tmp", .{ dir_abs, rev[0..@min(rev.len, 16)] });
    std.Io.Dir.deleteFileAbsolute(io, staged) catch {};
    try disk.writeDurably(io, staged, note);
    defer std.Io.Dir.deleteFileAbsolute(io, staged) catch {};
    _ = (try git(arena, io, root, &.{ "notes", "--ref=" ++ notes_ref, "add", "-f", "-F", staged, rev })) orelse return error.GitFailed;
    const attached_dir = try std.fmt.allocPrint(arena, "{s}\\attached", .{dir_abs});
    const attached = (try own_dir.hold(io, attached_dir, .create)).?;
    defer attached.close();
    for (taken) |name| {
        const from = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ dir_abs, name });
        const to = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ attached_dir, name });
        std.Io.Dir.renameAbsolute(from, to, io) catch {};
    }
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
