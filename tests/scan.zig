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
    try testing.expect(outcome.has("0 violation(s) in 0 file(s), 1 rule(s)\n1 tracked file(s): 1 scanned, 0 outside rule scope, 0 without a language profile, 0 unreadable\n"));
    try testing.expect(!outcome.has("parse errors"));
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
    try testing.expect(outcome.has("2 violation(s) in 1 file(s), 1 rule(s)\n1 tracked file(s): 1 scanned,"));
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
    try testing.expect(outcome.has("3 violation(s) in 2 file(s), 1 rule(s)\n3 tracked file(s): 3 scanned,"));
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
    try testing.expect(outcome.has("1 violation(s) in 1 file(s), 1 rule(s)\n1 tracked file(s): 1 scanned,"));

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
    try testing.expect(ledger_mode.has("0 violation(s) in 0 file(s), 0 rule(s)\n1 tracked file(s): 1 scanned,"));

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
    try testing.expect(outcome.has("2 violation(s) in 2 file(s), 1 rule(s)\n2 tracked file(s): 2 scanned, 0 outside rule scope, 0 without a language profile, 0 unreadable\n1 of the 2 scanned file(s) had parse errors; tree-based checks there may be incomplete\n"));
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
    try testing.expect(outcome.has("1 violation(s) in 1 file(s), 1 rule(s)\n2 tracked file(s): 1 scanned, 0 outside rule scope, 0 without a language profile, 1 unreadable\n"));
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
    try testing.expect(outcome.has("0 violation(s) in 0 file(s), 1 rule(s)\n3 tracked file(s): 1 scanned, 0 outside rule scope, 2 without a language profile, 0 unreadable\n"));
}

test "summary: violations are counted once and the files holding them once each" {
    try skipOffWindows();
    var repo = try Repo.init(&.{
        .{ .path = "a.ts", .data = "networkidle;\nnetworkidle;\n" },
        .{ .path = "b.ts", .data = "networkidle;\n" },
        .{ .path = "c.ts", .data = "export const c = 1;\n" },
    });
    defer repo.deinit();

    const outcome = try runScan(&repo, &.{ "--check", "forbid:networkidle" });
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 10), outcome.code);
    try testing.expect(outcome.has("\n3 violation(s) in 2 file(s), 1 rule(s)\n"));
}

test "summary: with two rules the files holding violations are still counted once each" {
    try skipOffWindows();
    var repo = try Repo.init(&.{
        .{ .path = "a.ts", .data = "networkidle;\nTODO;\n" },
        .{ .path = "b.ts", .data = "networkidle;\nTODO;\n" },
    });
    defer repo.deinit();
    try repo.putLedger(enforced_forbid ++ "{\"id\":\"mt\",\"scope\":\"project\",\"text\":\"no TODO\",\"enforce\":true,\"check\":\"forbid:TODO\",\"status\":\"active\",\"supersedes\":null,\"ts\":2}\n");

    const outcome = try runScan(&repo, &.{});
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 10), outcome.code);
    try testing.expect(outcome.has("\n4 violation(s) in 2 file(s), 2 rule(s)\n"));
}

test "summary: the tracked total is the sum of scanned, outside scope, without a profile and unreadable" {
    try skipOffWindows();
    var repo = try Repo.init(&.{
        .{ .path = "src/a.ts", .data = "export const a = 1;\n" },
        .{ .path = "src/gone.ts", .data = "export const g = 1;\n" },
        .{ .path = "src/notes.txt", .data = "text\n" },
        .{ .path = "lib/b.ts", .data = "export const b = 1;\n" },
        .{ .path = "lib/c.ts", .data = "export const c = 1;\n" },
    });
    defer repo.deinit();
    try repo.remove("repo/src/gone.ts");

    const outcome = try runScan(&repo, &.{ "--check", "forbid:networkidle", "--in", "src/" });
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 0), outcome.code);
    try testing.expect(outcome.has("\n5 tracked file(s): 1 scanned, 2 outside rule scope, 1 without a language profile, 1 unreadable\n"));
}

test "summary: the parse error line appears only when a scanned file had parse errors" {
    try skipOffWindows();
    var clean = try Repo.init(&.{
        .{ .path = "a.ts", .data = "export const a = 1;\n" },
        .{ .path = "b.ts", .data = "export const b = 1;\n" },
    });
    defer clean.deinit();
    const without = try runScan(&clean, &.{ "--check", "forbid:networkidle" });
    defer without.deinit();
    try testing.expect(without.has("2 tracked file(s): 2 scanned,"));
    try testing.expect(!without.has("parse error"));

    var broken = try Repo.init(&.{
        .{ .path = "a.ts", .data = "function (\n" },
        .{ .path = "b.ts", .data = "export const b = 1;\n" },
        .{ .path = "notes.txt", .data = "text\n" },
    });
    defer broken.deinit();
    const with = try runScan(&broken, &.{ "--check", "forbid:networkidle" });
    defer with.deinit();
    try testing.expect(with.has("\n1 of the 2 scanned file(s) had parse errors; tree-based checks there may be incomplete\n"));
}

const JsonViolation = struct { rule: []const u8, check: []const u8, file: []const u8, line: u32, col: u32, end_line: u32, end_col: u32, text: []const u8 };
const JsonFailure = struct { rule: []const u8, check: []const u8, file: []const u8, detail: []const u8, output: []const u8 };
const JsonUnreadable = struct { file: []const u8, @"error": []const u8 };
const JsonScan = struct {
    status: []const u8,
    rules: usize,
    scanned: usize,
    out_of_scope: usize,
    unsupported: usize,
    unreadable: []const JsonUnreadable,
    parse_errors: []const []const u8,
    check_failures: []const JsonFailure,
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
    try testing.expectEqual(@as(u32, 2), first.end_line);
    try testing.expectEqual(@as(u32, 14), first.end_col);
    try testing.expectEqualStrings("networkidle", first.text);
    try testing.expectEqualStrings("b.js", report.violations[1].file);
    try testing.expectEqual(@as(u32, 7), report.violations[1].col);

    var clean = try Repo.init(&.{.{ .path = "a.ts", .data = "export const a = 1;\n" }});
    defer clean.deinit();
    const clean_outcome = try runScan(&clean, &.{ "--check", "forbid:networkidle", "--json" });
    defer clean_outcome.deinit();
    try testing.expectEqual(@as(u8, 0), clean_outcome.code);
    try testing.expectEqualStrings("{\"status\":\"clean\",\"rules\":1,\"scanned\":1,\"out_of_scope\":0,\"unsupported\":0,\"unreadable\":[],\"parse_errors\":[],\"check_failures\":[],\"violations\":[]}\n", clean_outcome.out);
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
    try testing.expectEqualStrings("no_comment", scan_command.Options.parse(&.{ "--check", "no_comment" }).?.source.check.spec);
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
    try testing.expect(outcome.has("1 violation(s) in 1 file(s), 1 rule(s)\n1 tracked file(s): 1 scanned,"));

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

fn scopedRow(comptime id: []const u8, comptime check: []const u8, comptime where: []const u8) []const u8 {
    return "{\"id\":\"" ++ id ++ "\",\"scope\":\"file\",\"text\":\"scoped\",\"enforce\":true,\"check\":\"" ++ check ++ "\",\"status\":\"active\",\"supersedes\":null,\"ts\":5,\"where\":\"" ++ where ++ "\"}\n";
}

const scrape_everywhere = "resolveAndScrape(a);\n" ** 17;

const queue_repo = [_]File{
    .{ .path = "src/queue.js", .data = "export function enqueue(job) {\n  return jobs.push(job);\n}\n" },
    .{ .path = "src/scrape.js", .data = scrape_everywhere },
    .{ .path = "extension/content.js", .data = "export function read() {\n  return document.title;\n}\n" },
    .{ .path = "extension/background.js", .data = "export function pull() {\n  return fetch(url);\n}\n" },
    .{ .path = "src/net.js", .data = "fetch(a);\nfetch(b);\nfetch(c);\n" },
};

test "scope: a rule scoped to src/queue.js reports nothing although the text occurs 17 times elsewhere" {
    try skipOffWindows();
    var repo = try Repo.init(&queue_repo);
    defer repo.deinit();
    try repo.putLedger(scopedRow("mq", "forbid:resolveAndScrape", "src/queue.js"));

    const outcome = try runScan(&repo, &.{});
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 0), outcome.code);
    try testing.expect(outcome.has("0 violation(s) in 0 file(s), 1 rule(s)\n5 tracked file(s): 1 scanned, 4 outside rule scope, 0 without a language profile, 0 unreadable\n"));

    const unscoped = try runScan(&repo, &.{ "--check", "forbid:resolveAndScrape" });
    defer unscoped.deinit();
    try testing.expect(unscoped.has("17 violation(s) in 1 file(s), 1 rule(s)\n5 tracked file(s): 5 scanned, 0 outside rule scope,"));
}

test "scope: a rule scoped to extension/content.js reports no fetch( from other files" {
    try skipOffWindows();
    var repo = try Repo.init(&queue_repo);
    defer repo.deinit();
    try repo.putLedger(scopedRow("mf", "forbid:fetch(", "extension/content.js"));

    const outcome = try runScan(&repo, &.{});
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 0), outcome.code);
    try testing.expect(outcome.has("0 violation(s) in 0 file(s), 1 rule(s)\n5 tracked file(s): 1 scanned, 4 outside rule scope,"));
}

test "scope: a directory scope reports only the violations under that directory" {
    try skipOffWindows();
    var repo = try Repo.init(&queue_repo);
    defer repo.deinit();
    try repo.putLedger(scopedRow("md", "forbid:fetch(", "extension/"));

    const outcome = try runScan(&repo, &.{});
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 10), outcome.code);
    try testing.expect(outcome.has("extension/background.js:2:10: md (forbid:fetch(): fetch(\n"));
    try testing.expect(!outcome.has("src/net.js"));
    try testing.expect(outcome.has("1 violation(s) in 1 file(s), 1 rule(s)\n5 tracked file(s): 2 scanned, 3 outside rule scope,"));
}

test "scope: a symbol scope ignores the same text in another symbol of the same file" {
    try skipOffWindows();
    var repo = try Repo.init(&.{.{ .path = "src/x.js", .data = "export function f() {\n  return 1;\n}\nexport function g() {\n  return fetch(u);\n}\n" }});
    defer repo.deinit();
    try repo.putLedger(scopedRow("ms", "forbid:fetch(", "src/x.js#f"));

    const clean = try runScan(&repo, &.{});
    defer clean.deinit();
    try testing.expectEqual(@as(u8, 0), clean.code);
    try testing.expect(clean.has("0 violation(s) in 0 file(s), 1 rule(s)\n1 tracked file(s): 1 scanned,"));

    const inside = try runScan(&repo, &.{ "--check", "forbid:fetch(", "--in", "src/x.js#g" });
    defer inside.deinit();
    try testing.expectEqual(@as(u8, 10), inside.code);
    try testing.expect(inside.has("src/x.js:5:10: forbid:fetch(: fetch(\n"));
}

fn expectUnresolved(repo: *Repo, args: []const [:0]const u8, needle: []const u8) !void {
    const outcome = try runScan(repo, args);
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 31), outcome.code);
    try testing.expectEqual(@as(usize, 0), outcome.out.len);
    try testing.expect(std.mem.indexOf(u8, outcome.err, needle) != null);
}

test "scope: a ledger rule whose where names a deleted file stops the scan with ScopeUnresolved" {
    try skipOffWindows();
    var repo = try Repo.init(&queue_repo);
    defer repo.deinit();
    try git(repo.root_abs, &.{ "rm", "-q", "src/queue.js" });
    try repo.putLedger(comptime scopedRow("mq", "forbid:resolveAndScrape", "src/queue.js"));
    try expectUnresolved(&repo, &.{}, "error: ScopeUnresolved: rule mq has scope \"src/queue.js\": FileNotTracked\n");
}

test "scope: a ledger rule whose where names a missing symbol stops the scan with ScopeUnresolved" {
    try skipOffWindows();
    var repo = try Repo.init(&.{.{ .path = "src/x.js", .data = "export function f() {\n  return fetch(u);\n}\n" }});
    defer repo.deinit();
    try repo.putLedger(comptime scopedRow("ms", "forbid:fetch(", "src/x.js#gone"));
    try expectUnresolved(&repo, &.{}, "error: ScopeUnresolved: rule ms has scope \"src/x.js#gone\": SymbolNotFound\n");
}

test "scope: an empty directory scope or an unparsable symbol file stops the scan with ScopeUnresolved" {
    try skipOffWindows();
    var repo = try Repo.init(&.{
        .{ .path = "src/x.js", .data = "export function f() {\n  return 1;\n}\n" },
        .{ .path = "src/broken.js", .data = "function (\n" },
    });
    defer repo.deinit();
    try expectUnresolved(&repo, &.{ "--check", "forbid:fetch(", "--in", "lib/" }, "NoTrackedFileUnder");
    try expectUnresolved(&repo, &.{ "--check", "forbid:fetch(", "--in", "src/broken.js#f" }, "SourceHasErrors");
    try expectUnresolved(&repo, &.{ "--check", "forbid:fetch(", "--in", "src/x.js#f@get" }, "SymbolNotFound");
}

test "scope: an unresolved scope is reported as one json error line naming rule and where" {
    try skipOffWindows();
    var repo = try Repo.init(&queue_repo);
    defer repo.deinit();
    const outcome = try runScan(&repo, &.{ "--json", "--check", "forbid:fetch(", "--in", "src/gone.js" });
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 31), outcome.code);
    try testing.expectEqualStrings("{\"status\":\"error\",\"error\":\"ScopeUnresolved\",\"exit_code\":31,\"rule\":\"forbid:fetch(\",\"where\":\"src/gone.js\",\"reason\":\"FileNotTracked\"}\n", outcome.out);
}

test "scope: the scanner itself refuses an unresolved scope" {
    try skipOffWindows();
    var repo = try Repo.init(&queue_repo);
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch |err| std.debug.panic("runtime closed with live allocations: {t}", .{err});
    try testing.expectError(error.ScopeUnresolved, scan.scan(testing.allocator, testing.io, runtime, repo.root_abs, &.{.{ .id = "r", .check = "forbid:x", .where = "src/gone.js" }}));
}

test "scope: a rule without where scans the whole repository as before" {
    try skipOffWindows();
    var repo = try Repo.init(&queue_repo);
    defer repo.deinit();
    try repo.putLedger("{\"id\":\"mn\",\"scope\":\"project\",\"text\":\"no fetch\",\"enforce\":true,\"check\":\"forbid:fetch(\",\"status\":\"active\",\"supersedes\":null,\"ts\":1}\n");

    const outcome = try runScan(&repo, &.{});
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 10), outcome.code);
    try testing.expect(outcome.has("4 violation(s) in 2 file(s), 1 rule(s)\n5 tracked file(s): 5 scanned, 0 outside rule scope,"));
}

test "scope: --in narrows an ad-hoc check and the json report counts files outside it" {
    try skipOffWindows();
    var repo = try Repo.init(&queue_repo);
    defer repo.deinit();

    const outcome = try runScan(&repo, &.{ "--json", "--check", "forbid:fetch(", "--in", "src/net.js" });
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 10), outcome.code);
    const parsed = try std.json.parseFromSlice(JsonScan, testing.allocator, outcome.out, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.scanned);
    try testing.expectEqual(@as(usize, 4), parsed.value.out_of_scope);
    try testing.expectEqual(@as(usize, 3), parsed.value.violations.len);
}

test "scope: --in is refused without --check, twice, or without a value" {
    try testing.expect(scan_command.Options.parse(&.{ "--in", "src/a.ts" }) == null);
    try testing.expect(scan_command.Options.parse(&.{ "--json", "--in", "src/a.ts" }) == null);
    try testing.expect(scan_command.Options.parse(&.{ "--check", "no_comment", "--in", "a", "--in", "b" }) == null);
    try testing.expect(scan_command.Options.parse(&.{ "--check", "no_comment", "--in" }) == null);
    const options = scan_command.Options.parse(&.{ "--in", "extension/", "--check", "no_comment" }).?;
    try testing.expectEqualStrings("extension/", options.source.check.where.?);
}

test "scope: an invalid --in is refused by name before anything is scanned" {
    try skipOffWindows();
    var repo = try Repo.init(&queue_repo);
    defer repo.deinit();
    for ([_][:0]const u8{ "src/*.js", "../x.js", "C:/x.js", ".git/config" }, [_][]const u8{ "WhereGlob", "WhereParentSegment", "WhereAbsolute", "WhereInternal" }) |bad, name| {
        const outcome = try runScan(&repo, &.{ "--check", "forbid:fetch(", "--in", bad });
        defer outcome.deinit();
        try testing.expectEqual(@as(u8, 2), outcome.code);
        try testing.expect(std.mem.indexOf(u8, outcome.err, name) != null);
        try testing.expectEqual(@as(usize, 0), outcome.out.len);
    }
}

test "scope: each rule in one scan keeps its own where" {
    try skipOffWindows();
    var repo = try Repo.init(&.{
        .{ .path = "src/queue.js", .data = "fetch(a);\n" },
        .{ .path = "src/net.js", .data = "resolveAndScrape(b);\n" },
        .{ .path = "src/other.js", .data = "fetch(c);\nresolveAndScrape(d);\n" },
    });
    defer repo.deinit();
    try repo.putLedger(comptime scopedRow("mq", "forbid:resolveAndScrape", "src/queue.js") ++ scopedRow("mn", "forbid:fetch(", "src/net.js"));

    const outcome = try runScan(&repo, &.{});
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 0), outcome.code);
    try testing.expect(outcome.has("0 violation(s) in 0 file(s), 2 rule(s)\n3 tracked file(s): 2 scanned, 1 outside rule scope,"));
}

test "scope: a no_literal rule scoped to one symbol reports only its literal options" {
    try skipOffWindows();
    var repo = try Repo.init(&.{
        .{ .path = "src/nav.js", .data = "export async function open(page) {\n  await page.goto(u, { timeout: 30000 });\n  await page.goto(u, { timeout: budget(ms) });\n}\nexport async function other(page) {\n  await page.goto(u, { timeout: 5 });\n}\n" },
        .{ .path = "src/wait.js", .data = "wait({ timeout: 1 });\n" },
    });
    defer repo.deinit();
    try repo.putLedger(scopedRow("ml", "no_literal:timeout", "src/nav.js#open"));

    const outcome = try runScan(&repo, &.{});
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 10), outcome.code);
    try testing.expect(outcome.has("src/nav.js:2:24: ml (no_literal:timeout): timeout: 30000\n"));
    try testing.expect(!outcome.has("timeout: 5"));
    try testing.expect(!outcome.has("src/wait.js:"));
    try testing.expect(outcome.has("1 violation(s) in 1 file(s), 1 rule(s)\n2 tracked file(s): 1 scanned, 1 outside rule scope,"));
}

const exclusion_repo = [_]File{
    .{ .path = "src/server.ts", .data = "export const a = x as any;\n" },
    .{ .path = "src/a/__tests__/x.ts", .data = "const t = y as any;\n" },
    .{ .path = "src/b/c/__tests__/y.ts", .data = "const u = z as any;\n" },
    .{ .path = "packages/core/parse.ts", .data = "JSON.parse(s);\n" },
    .{ .path = "packages/core/parse.test.ts", .data = "JSON.parse(t);\n" },
    .{ .path = "packages/core/__fixtures__/data.ts", .data = "JSON.parse(f);\n" },
    .{ .path = "packages/types/infer.ts", .data = "// @ts-expect-error\nconst n: number = s;\n" },
    .{ .path = "packages/types/infer.test-d.ts", .data = "// @ts-expect-error\nconst m: number = s;\n" },
    .{ .path = "packages/gen/out.ts", .data = "JSON.parse(g);\n" },
    .{ .path = "packages/core/gen/in.ts", .data = "JSON.parse(h);\n" },
    .{ .path = "docs/readme.md", .data = "as any\n" },
};

test "exclusion: src/ !__tests__/ drops the test directories and keeps production code" {
    try skipOffWindows();
    var repo = try Repo.init(&exclusion_repo);
    defer repo.deinit();

    const all = try runScan(&repo, &.{ "--check", "forbid:as any", "--in", "src/" });
    defer all.deinit();
    try testing.expect(all.has("3 violation(s) in 3 file(s), 1 rule(s)\n11 tracked file(s): 3 scanned,"));

    const production = try runScan(&repo, &.{ "--check", "forbid:as any", "--in", "src/ !__tests__/" });
    defer production.deinit();
    try testing.expectEqual(@as(u8, 10), production.code);
    try testing.expect(production.has("src/server.ts:1:20: forbid:as any: as any\n"));
    try testing.expect(!production.has("__tests__"));
    try testing.expect(production.has("1 violation(s) in 1 file(s), 1 rule(s)\n11 tracked file(s): 1 scanned, 10 outside rule scope,"));
}

test "exclusion: a directory name is excluded at any depth" {
    try skipOffWindows();
    var repo = try Repo.init(&exclusion_repo);
    defer repo.deinit();
    const shallow = try runScan(&repo, &.{ "--check", "forbid:as any", "--in", "src/ !__tests__/" });
    defer shallow.deinit();
    try testing.expect(!shallow.has("src/a/__tests__/x.ts"));
    try testing.expect(!shallow.has("src/b/c/__tests__/y.ts"));
    try testing.expect(shallow.has("10 outside rule scope,"));
}

test "exclusion: two exclusions apply together" {
    try skipOffWindows();
    var repo = try Repo.init(&exclusion_repo);
    defer repo.deinit();
    const outcome = try runScan(&repo, &.{ "--check", "forbid:JSON.parse", "--in", "packages/ !*.test.ts !__fixtures__/" });
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 10), outcome.code);
    try testing.expect(outcome.has("packages/core/parse.ts:1:1:"));
    try testing.expect(outcome.has("packages/gen/out.ts:1:1:"));
    try testing.expect(outcome.has("packages/core/gen/in.ts:1:1:"));
    try testing.expect(!outcome.has("parse.test.ts"));
    try testing.expect(!outcome.has("__fixtures__"));
    try testing.expect(outcome.has("\n3 violation(s) in 3 file(s), 1 rule(s)\n"));
}

test "exclusion: a suffix exclusion drops negative type tests" {
    try skipOffWindows();
    var repo = try Repo.init(&exclusion_repo);
    defer repo.deinit();
    const outcome = try runScan(&repo, &.{ "--check", "forbid:@ts-expect-error", "--in", "packages/ !*.test-d.ts" });
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 10), outcome.code);
    try testing.expect(outcome.has("packages/types/infer.ts:1:4:"));
    try testing.expect(!outcome.has("infer.test-d.ts"));
    try testing.expect(outcome.has("\n1 violation(s) in 1 file(s), 1 rule(s)\n"));
}

test "exclusion: a slashed exclusion is a prefix and leaves a same-named segment elsewhere" {
    try skipOffWindows();
    var repo = try Repo.init(&exclusion_repo);
    defer repo.deinit();
    const outcome = try runScan(&repo, &.{ "--check", "forbid:JSON.parse", "--in", "packages/ !packages/gen/" });
    defer outcome.deinit();
    try testing.expect(!outcome.has("packages/gen/out.ts"));
    try testing.expect(outcome.has("packages/core/gen/in.ts:1:1:"));
}

test "exclusion: a ledger rule with exclusions is honored by the ledger scan" {
    try skipOffWindows();
    var repo = try Repo.init(&exclusion_repo);
    defer repo.deinit();
    try repo.putLedger(scopedRow("mx", "forbid:as any", "src/ !__tests__/"));
    const outcome = try runScan(&repo, &.{});
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 10), outcome.code);
    try testing.expect(outcome.has("1 violation(s) in 1 file(s), 1 rule(s)\n11 tracked file(s): 1 scanned,"));
}

test "nothing in scope: a scope whose every file is excluded is not reported clean" {
    try skipOffWindows();
    var repo = try Repo.init(&exclusion_repo);
    defer repo.deinit();
    const outcome = try runScan(&repo, &.{ "--check", "forbid:as any", "--in", "src/a/ !__tests__/" });
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 32), outcome.code);
    try testing.expect(outcome.has("0 violation(s) in 0 file(s), 1 rule(s)\n11 tracked file(s): 0 scanned,"));
    try testing.expect(outcome.has("NothingInScope: "));

    const json = try runScan(&repo, &.{ "--json", "--check", "forbid:as any", "--in", "src/a/ !__tests__/" });
    defer json.deinit();
    try testing.expectEqual(@as(u8, 32), json.code);
    const parsed = try std.json.parseFromSlice(JsonScan, testing.allocator, json.out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("nothing_in_scope", parsed.value.status);
    try testing.expectEqual(@as(usize, 0), parsed.value.scanned);
}

test "nothing in scope: a directory with no language profile is not reported clean" {
    try skipOffWindows();
    var repo = try Repo.init(&exclusion_repo);
    defer repo.deinit();
    const outcome = try runScan(&repo, &.{ "--check", "forbid:as any", "--in", "docs/" });
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 32), outcome.code);
    try testing.expect(outcome.has("0 violation(s) in 0 file(s), 1 rule(s)\n11 tracked file(s): 0 scanned,"));
    try testing.expect(outcome.has("1 without a language profile"));
}

test "nothing in scope: a scope excluding its only file resolves, so it is not ScopeUnresolved" {
    try skipOffWindows();
    var repo = try Repo.init(&exclusion_repo);
    defer repo.deinit();
    const outcome = try runScan(&repo, &.{ "--check", "forbid:x", "--in", "src/server.ts !src/server.ts" });
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 32), outcome.code);
    try testing.expectEqual(@as(usize, 0), outcome.err.len);
}

test "exclusion: an invalid exclusion in --in is refused by name before anything is scanned" {
    try skipOffWindows();
    var repo = try Repo.init(&exclusion_repo);
    defer repo.deinit();
    const outcome = try runScan(&repo, &.{ "--check", "forbid:x", "--in", "src/ !*.test.*" });
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 2), outcome.code);
    try testing.expect(std.mem.indexOf(u8, outcome.err, "WhereExclusionGlob") != null);
    try testing.expectEqual(@as(usize, 0), outcome.out.len);
}

test "nothing in scope: with no rules and no scannable file the scan stays clean and exits 0" {
    try skipOffWindows();
    var repo = try Repo.init(&.{.{ .path = "docs/readme.md", .data = "text\n" }});
    defer repo.deinit();
    const outcome = try runScan(&repo, &.{});
    defer outcome.deinit();
    try testing.expectEqual(@as(u8, 0), outcome.code);
    try testing.expect(outcome.has("0 violation(s) in 0 file(s), 0 rule(s)\n1 tracked file(s): 0 scanned,"));
    try testing.expect(!outcome.has("NothingInScope"));

    const json = try runScan(&repo, &.{"--json"});
    defer json.deinit();
    try testing.expectEqual(@as(u8, 0), json.code);
    const parsed = try std.json.parseFromSlice(JsonScan, testing.allocator, json.out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("clean", parsed.value.status);
}
