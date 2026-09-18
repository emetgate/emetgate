const std = @import("std");
const builtin = @import("builtin");
const scan = @import("../src/platform/scan.zig");
const scan_command = @import("../src/protocol/scan_command.zig");
const Runtime = @import("../src/engine/runtime.zig").Runtime;

const testing = std.testing;
const Allocating = std.Io.Writer.Allocating;

const enforced_forbid = "{\"id\":\"mf\",\"scope\":\"project\",\"text\":\"no networkidle\",\"enforce\":true,\"check\":\"forbid:networkidle\",\"status\":\"active\",\"supersedes\":null,\"ts\":1}\n";
const advisory_comment = "{\"id\":\"mc\",\"scope\":\"project\",\"text\":\"no comments\",\"enforce\":false,\"check\":\"no_comment\",\"status\":\"active\",\"supersedes\":null,\"ts\":2}\n";
const malformed_rule = "{\"id\":\"mbad\",\"scope\":\"project\",\"text\":\"typo\",\"enforce\":true,\"check\":\"frbid:x\",\"status\":\"active\",\"supersedes\":null,\"ts\":3}\n";
const torn_row = "{\"id\":\"mt\",\"scope\":\"proj";

const File = struct { path: []const u8, data: []const u8 };

const Repo = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,

    fn init(files: []const File) !Repo {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo");
        for (files) |file| {
            if (std.fs.path.dirname(file.path)) |dir| {
                const sub = try std.fmt.allocPrint(testing.allocator, "repo/{s}", .{dir});
                defer testing.allocator.free(sub);
                try tmp.dir.createDirPath(testing.io, sub);
            }
            const sub = try std.fmt.allocPrint(testing.allocator, "repo/{s}", .{file.path});
            defer testing.allocator.free(sub);
            try tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = file.data });
        }
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
        errdefer testing.allocator.free(root_abs);
        try git(root_abs, &.{ "init", "-q" });
        try git(root_abs, &.{ "config", "user.email", "t@t" });
        try git(root_abs, &.{ "config", "user.name", "t" });
        try git(root_abs, &.{ "add", "." });
        try git(root_abs, &.{ "commit", "-q", "--allow-empty", "-m", "init" });
        return .{ .tmp = tmp, .root_abs = root_abs };
    }

    fn deinit(self: *Repo) void {
        testing.allocator.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn putLedger(self: *Repo, bytes: []const u8) !void {
        try self.tmp.dir.createDirPath(testing.io, "repo/.emetgate");
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.emetgate/ledger.ndjson", .data = bytes });
    }

    fn ledger(self: *Repo) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, "repo/.emetgate/ledger.ndjson", testing.allocator, .unlimited);
    }

    fn exists(self: *Repo, sub: []const u8) bool {
        self.tmp.dir.access(testing.io, sub, .{}) catch return false;
        return true;
    }

    fn workspaceEntries(self: *Repo) !usize {
        var dir = try self.tmp.dir.openDir(testing.io, "repo/.emetgate", .{ .iterate = true });
        defer dir.close(testing.io);
        var count: usize = 0;
        var it = dir.iterate();
        while (try it.next(testing.io)) |_| count += 1;
        return count;
    }

    fn remove(self: *Repo, sub: []const u8) !void {
        try self.tmp.dir.deleteFile(testing.io, sub);
    }
};

fn git(cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argv.append(testing.allocator, "git");
    try argv.appendSlice(testing.allocator, args);
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = argv.items, .cwd = .{ .path = cwd } });
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

const Outcome = struct {
    code: u8,
    out: []u8,
    err: []u8,

    fn deinit(self: Outcome) void {
        testing.allocator.free(self.out);
        testing.allocator.free(self.err);
    }

    fn has(self: Outcome, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.out, needle) != null;
    }
};

fn runScan(repo: *Repo, args: []const [:0]const u8) !Outcome {
    return runScanWith(repo, scan_command.Options.parse(args) orelse return error.UsageRefused);
}

fn runScanWith(repo: *Repo, options: scan_command.Options) !Outcome {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch |err| std.debug.panic("runtime closed with live allocations: {t}", .{err});
    var out: Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Allocating = .init(testing.allocator);
    defer err.deinit();
    const code = try scan_command.run(testing.allocator, testing.io, runtime, repo.root_abs, options, &out.writer, &err.writer);
    const out_bytes = try testing.allocator.dupe(u8, out.written());
    errdefer testing.allocator.free(out_bytes);
    return .{ .code = code, .out = out_bytes, .err = try testing.allocator.dupe(u8, err.written()) };
}

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

test "scan: a clean repo reports no violations and exits 0" {
    try skipOffWindows();
    var repo = try Repo.init(&.{.{ .path = "src/a.ts", .data = "export function a() {\n  return 1;\n}\n" }});
    defer repo.deinit();
    try repo.putLedger(enforced_forbid);

    const outcome = try runScan(&repo, &.{});
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 0), outcome.code);
    try testing.expect(outcome.has("1 rule(s), 1 file(s) scanned, 0 violation(s); 0 skipped without a language profile, 0 unreadable, 0 with parse errors\n"));
    try testing.expectEqual(@as(usize, 1), try repo.workspaceEntries());
}

test "scan: one violation names its file, line, column, rule and text, and exits 10" {
    try skipOffWindows();
    var repo = try Repo.init(&.{.{ .path = "src/a.ts", .data = "networkidle;\nexport function a() {\n  wait(\"networkidle\");\n}\n" }});
    defer repo.deinit();
    try repo.putLedger(enforced_forbid ++ advisory_comment);

    const outcome = try runScan(&repo, &.{});
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 10), outcome.code);
    try testing.expect(outcome.has("src/a.ts:1:1: mf (forbid:networkidle): networkidle\n"));
    try testing.expect(outcome.has("src/a.ts:3:9: mf (forbid:networkidle): networkidle\n"));
    try testing.expect(outcome.has("1 rule(s), 1 file(s) scanned, 2 violation(s);"));
}

test "scan: violations in several files are all reported" {
    try skipOffWindows();
    var repo = try Repo.init(&.{
        .{ .path = "a.ts", .data = "const x = \"networkidle\";\n" },
        .{ .path = "lib/b.js", .data = "function b() {\n  return 1;\n}\nb(networkidle, networkidle);\n" },
        .{ .path = "lib/c.ts", .data = "export const c = 1;\n" },
    });
    defer repo.deinit();
    try repo.putLedger(enforced_forbid);

    const outcome = try runScan(&repo, &.{});
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 10), outcome.code);
    try testing.expect(outcome.has("a.ts:1:12: mf (forbid:networkidle): networkidle\n"));
    try testing.expect(outcome.has("lib/b.js:4:3: mf (forbid:networkidle): networkidle\n"));
    try testing.expect(outcome.has("lib/b.js:4:16: mf (forbid:networkidle): networkidle\n"));
    try testing.expect(outcome.has("1 rule(s), 3 file(s) scanned, 3 violation(s);"));
}

test "scan: --check scans a spec absent from the ledger and leaves the ledger untouched" {
    try skipOffWindows();
    var repo = try Repo.init(&.{.{ .path = "a.ts", .data = "// TODO\nexport const a = 1;\n" }});
    defer repo.deinit();
    try repo.putLedger(enforced_forbid);
    const before = try repo.ledger();
    defer testing.allocator.free(before);

    const outcome = try runScan(&repo, &.{ "--check", "forbid:TODO" });
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 10), outcome.code);
    try testing.expect(outcome.has("a.ts:1:4: forbid:TODO: TODO\n"));
    try testing.expect(outcome.has("1 rule(s), 1 file(s) scanned, 1 violation(s);"));

    const after = try repo.ledger();
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    try testing.expectEqual(@as(usize, 1), try repo.workspaceEntries());
}

test "scan: with no ledger there are zero rules and no workspace is created" {
    try skipOffWindows();
    var repo = try Repo.init(&.{.{ .path = "a.ts", .data = "export const a = 1;\n" }});
    defer repo.deinit();

    const ledger_mode = try runScan(&repo, &.{});
    defer ledger_mode.deinit();
    try testing.expectEqual(@as(u8, 0), ledger_mode.code);
    try testing.expect(ledger_mode.has("0 rule(s), 1 file(s) scanned, 0 violation(s);"));

    const check_mode = try runScan(&repo, &.{ "--check", "no_comment" });
    defer check_mode.deinit();
    try testing.expectEqual(@as(u8, 0), check_mode.code);
    try testing.expect(!repo.exists("repo/.emetgate"));
}

test "scan: a torn ledger stops the ledger scan by name, --check still runs, and nothing is written" {
    try skipOffWindows();
    var repo = try Repo.init(&.{.{ .path = "a.ts", .data = "networkidle;\n" }});
    defer repo.deinit();
    try repo.putLedger(enforced_forbid ++ torn_row);
    const before = try repo.ledger();
    defer testing.allocator.free(before);

    const ledger_mode = try runScan(&repo, &.{});
    defer ledger_mode.deinit();
    try testing.expectEqual(@as(u8, 1), ledger_mode.code);
    try testing.expect(std.mem.indexOf(u8, ledger_mode.err, "error: LedgerNeedsRepair: ") != null);
    try testing.expectEqualStrings("", ledger_mode.out);

    const json_mode = try runScan(&repo, &.{"--json"});
    defer json_mode.deinit();
    try testing.expect(json_mode.has("\"error\":\"LedgerNeedsRepair\""));

    const check_mode = try runScan(&repo, &.{ "--check", "forbid:networkidle" });
    defer check_mode.deinit();
    try testing.expectEqual(@as(u8, 10), check_mode.code);
    try testing.expect(check_mode.has("a.ts:1:1: forbid:networkidle: networkidle\n"));

    const after = try repo.ledger();
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    try testing.expectEqual(@as(usize, 1), try repo.workspaceEntries());
}

test "scan: a file with parse errors is still scanned, flagged, and does not stop the scan" {
    try skipOffWindows();
    var repo = try Repo.init(&.{
        .{ .path = "a.ts", .data = "function (\n  networkidle\n" },
        .{ .path = "b.ts", .data = "export const b = \"networkidle\";\n" },
    });
    defer repo.deinit();

    const outcome = try runScan(&repo, &.{ "--check", "forbid:networkidle" });
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 10), outcome.code);
    try testing.expect(outcome.has("a.ts:2:3: forbid:networkidle: networkidle\n"));
    try testing.expect(outcome.has("b.ts:1:19: forbid:networkidle: networkidle\n"));
    try testing.expect(outcome.has("warning: a.ts: parse error; tree-based checks may be incomplete\n"));
    try testing.expect(outcome.has("1 rule(s), 2 file(s) scanned, 2 violation(s); 0 skipped without a language profile, 0 unreadable, 1 with parse errors\n"));
}

test "scan: an unreadable tracked file is warned about, counted, and does not stop the scan" {
    try skipOffWindows();
    var repo = try Repo.init(&.{
        .{ .path = "a.ts", .data = "export const a = 1;\n" },
        .{ .path = "b.ts", .data = "networkidle;\n" },
    });
    defer repo.deinit();
    try repo.remove("repo/a.ts");

    const outcome = try runScan(&repo, &.{ "--check", "forbid:networkidle" });
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 10), outcome.code);
    try testing.expect(outcome.has("warning: a.ts: not scanned: FileNotFound\n"));
    try testing.expect(outcome.has("b.ts:1:1: forbid:networkidle: networkidle\n"));
    try testing.expect(outcome.has("1 rule(s), 1 file(s) scanned, 1 violation(s); 0 skipped without a language profile, 1 unreadable, 0 with parse errors\n"));
}

test "scan: a file with no language profile is skipped and counted" {
    try skipOffWindows();
    var repo = try Repo.init(&.{
        .{ .path = "README.txt", .data = "networkidle\n" },
        .{ .path = "Makefile", .data = "networkidle:\n" },
        .{ .path = "a.ts", .data = "export const a = 1;\n" },
    });
    defer repo.deinit();

    const outcome = try runScan(&repo, &.{ "--check", "forbid:networkidle" });
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 0), outcome.code);
    try testing.expect(outcome.has("1 rule(s), 1 file(s) scanned, 0 violation(s); 2 skipped without a language profile, 0 unreadable, 0 with parse errors\n"));
}

const JsonViolation = struct { rule: []const u8, check: []const u8, file: []const u8, line: u32, col: u32, text: []const u8 };
const JsonUnreadable = struct { file: []const u8, @"error": []const u8 };
const JsonScan = struct {
    status: []const u8,
    rules: usize,
    scanned: usize,
    unsupported: usize,
    unreadable: []const JsonUnreadable,
    parse_errors: []const []const u8,
    violations: []const JsonViolation,
};

test "scan: --json is one parseable line carrying the same report" {
    try skipOffWindows();
    var repo = try Repo.init(&.{
        .{ .path = "a.ts", .data = "function (\n  networkidle\n" },
        .{ .path = "gone.ts", .data = "export const g = 1;\n" },
        .{ .path = "notes.txt", .data = "networkidle\n" },
        .{ .path = "b.js", .data = "wait(\"networkidle\");\n" },
    });
    defer repo.deinit();
    try repo.putLedger(enforced_forbid ++ advisory_comment);
    try repo.remove("repo/gone.ts");

    const outcome = try runScan(&repo, &.{"--json"});
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 10), outcome.code);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, outcome.out, "\n"));

    const parsed = try std.json.parseFromSlice(JsonScan, testing.allocator, outcome.out, .{});
    defer parsed.deinit();
    const report = parsed.value;
    try testing.expectEqualStrings("violations", report.status);
    try testing.expectEqual(@as(usize, 1), report.rules);
    try testing.expectEqual(@as(usize, 2), report.scanned);
    try testing.expectEqual(@as(usize, 1), report.unsupported);
    try testing.expectEqual(@as(usize, 1), report.unreadable.len);
    try testing.expectEqualStrings("gone.ts", report.unreadable[0].file);
    try testing.expectEqualStrings("FileNotFound", report.unreadable[0].@"error");
    try testing.expectEqual(@as(usize, 1), report.parse_errors.len);
    try testing.expectEqualStrings("a.ts", report.parse_errors[0]);
    try testing.expectEqual(@as(usize, 2), report.violations.len);
    const first = report.violations[0];
    try testing.expectEqualStrings("mf", first.rule);
    try testing.expectEqualStrings("forbid:networkidle", first.check);
    try testing.expectEqualStrings("a.ts", first.file);
    try testing.expectEqual(@as(u32, 2), first.line);
    try testing.expectEqual(@as(u32, 3), first.col);
    try testing.expectEqualStrings("networkidle", first.text);
    try testing.expectEqualStrings("b.js", report.violations[1].file);
    try testing.expectEqual(@as(u32, 7), report.violations[1].col);

    var clean = try Repo.init(&.{.{ .path = "a.ts", .data = "export const a = 1;\n" }});
    defer clean.deinit();
    const clean_outcome = try runScan(&clean, &.{ "--check", "forbid:networkidle", "--json" });
    defer clean_outcome.deinit();
    try testing.expectEqual(@as(u8, 0), clean_outcome.code);
    try testing.expectEqualStrings("{\"status\":\"clean\",\"rules\":1,\"scanned\":1,\"unsupported\":0,\"unreadable\":[],\"parse_errors\":[],\"violations\":[]}\n", clean_outcome.out);
}

test "scan: a malformed ledger rule stops the scan before any file and names the rule" {
    try skipOffWindows();
    var repo = try Repo.init(&.{.{ .path = "a.ts", .data = "networkidle;\n" }});
    defer repo.deinit();
    try repo.putLedger(enforced_forbid ++ malformed_rule);

    const outcome = try runScan(&repo, &.{});
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 19), outcome.code);
    try testing.expectEqualStrings("", outcome.out);
    try testing.expect(std.mem.indexOf(u8, outcome.err, "error: UnknownCheck: rule mbad has check \"frbid:x\"\n") != null);

    const json = try runScan(&repo, &.{"--json"});
    defer json.deinit();
    try testing.expectEqualStrings("{\"status\":\"error\",\"error\":\"UnknownCheck\",\"exit_code\":19,\"rule\":\"mbad\",\"check\":\"frbid:x\"}\n", json.out);
}

test "scan: every malformed --check spec exits with the malformed-check code" {
    try skipOffWindows();
    var repo = try Repo.init(&.{.{ .path = "a.ts", .data = "networkidle;\n" }});
    defer repo.deinit();

    const specs = [_][:0]const u8{ "frbid:x", "forbid", "forbid:", "no_comment:x" };
    for (specs) |spec| {
        errdefer std.debug.print("spec: {s}\n", .{spec});
        const outcome = try runScan(&repo, &.{ "--check", spec });
        defer outcome.deinit();
        try testing.expectEqual(@as(u8, 19), outcome.code);
        try testing.expectEqualStrings("", outcome.out);
    }
}

test "scan: the scanner itself refuses a malformed rule even when no file would run it" {
    try skipOffWindows();
    var repo = try Repo.init(&.{.{ .path = "notes.txt", .data = "x\n" }});
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch |err| std.debug.panic("runtime closed with live allocations: {t}", .{err});

    try testing.expectError(error.MissingCheckArgument, scan.scan(testing.allocator, testing.io, runtime, repo.root_abs, &.{.{ .id = "r", .check = "forbid" }}));
}

test "scan: usage accepts only --json and one --check with a value" {
    try testing.expect(scan_command.Options.parse(&.{}) != null);
    try testing.expect(scan_command.Options.parse(&.{ "--json", "--check", "no_comment" }).?.json);
    try testing.expectEqualStrings("no_comment", scan_command.Options.parse(&.{ "--check", "no_comment" }).?.source.check);
    try testing.expect(scan_command.Options.parse(&.{"--check"}) == null);
    try testing.expect(scan_command.Options.parse(&.{ "--check", "a", "--check", "b" }) == null);
    try testing.expect(scan_command.Options.parse(&.{ "--json", "--json" }) == null);
    try testing.expect(scan_command.Options.parse(&.{"src/a.ts"}) == null);
}

const Repair = struct {
    repo: *Repo,
    bytes: ?[]const u8,
    pauses: usize = 0,

    fn call(context: ?*anyopaque, io: std.Io) void {
        _ = io;
        const self: *Repair = @ptrCast(@alignCast(context.?));
        self.pauses += 1;
        if (self.bytes) |bytes| self.repo.putLedger(bytes) catch |err| std.debug.panic("repair failed: {t}", .{err});
    }
};

test "scan: a ledger torn on the first read but whole on the second is scanned after one re-read" {
    try skipOffWindows();
    var repo = try Repo.init(&.{.{ .path = "a.ts", .data = "networkidle;\n" }});
    defer repo.deinit();
    try repo.putLedger(enforced_forbid ++ torn_row);

    var repair: Repair = .{ .repo = &repo, .bytes = enforced_forbid };
    const outcome = try runScanWith(&repo, .{ .source = .ledger, .json = false, .pause = .{ .context = &repair, .call = Repair.call } });
    defer outcome.deinit();
    try testing.expectEqual(@as(usize, 1), repair.pauses);
    try testing.expectEqual(@as(u8, 10), outcome.code);
    try testing.expect(outcome.has("a.ts:1:1: mf (forbid:networkidle): networkidle\n"));
    try testing.expect(outcome.has("1 rule(s), 1 file(s) scanned, 1 violation(s);"));

    const after = try repo.ledger();
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(enforced_forbid, after);
    try testing.expectEqual(@as(usize, 1), try repo.workspaceEntries());
}

test "scan: a ledger torn on both reads stops with LedgerNeedsRepair after exactly one re-read" {
    try skipOffWindows();
    var repo = try Repo.init(&.{.{ .path = "a.ts", .data = "networkidle;\n" }});
    defer repo.deinit();
    try repo.putLedger(enforced_forbid ++ torn_row);

    var repair: Repair = .{ .repo = &repo, .bytes = null };
    const outcome = try runScanWith(&repo, .{ .source = .ledger, .json = false, .pause = .{ .context = &repair, .call = Repair.call } });
    defer outcome.deinit();
    try testing.expectEqual(@as(usize, 1), repair.pauses);
    try testing.expectEqual(@as(u8, 1), outcome.code);
    try testing.expect(std.mem.indexOf(u8, outcome.err, "error: LedgerNeedsRepair: ") != null);

    const after = try repo.ledger();
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(enforced_forbid ++ torn_row, after);
    try testing.expectEqual(@as(usize, 1), try repo.workspaceEntries());
}

test "scan: a whole ledger is read once without pausing" {
    try skipOffWindows();
    var repo = try Repo.init(&.{.{ .path = "a.ts", .data = "export const a = 1;\n" }});
    defer repo.deinit();
    try repo.putLedger(enforced_forbid);

    var repair: Repair = .{ .repo = &repo, .bytes = null };
    const outcome = try runScanWith(&repo, .{ .source = .ledger, .json = false, .pause = .{ .context = &repair, .call = Repair.call } });
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 0), outcome.code);
    try testing.expectEqual(@as(usize, 0), repair.pauses);
}
