const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const emetgate = @import("emetgate");
const user_rules = emetgate.user_rules;
const memory = emetgate.memory;
const rules = emetgate.rules;
const rule_command = emetgate.rule_command;
const rule_catalog = emetgate.rule_catalog;
const scan_command = emetgate.scan_command;
const cache_command = emetgate.cache_command;
const uninstall = emetgate.uninstall;
const doctor = emetgate.doctor;
const wire = emetgate.wire;
const shadow = emetgate.shadow;
const exe_path = emetgate.exe_path;
const bounded_run = emetgate.bounded_run;
const Runtime = emetgate.runtime.Runtime;

const testing = std.testing;
const gpa = testing.allocator;
const Allocating = std.Io.Writer.Allocating;

const with_eval = "export function run(code: string) {\n  return eval(code);\n}\n";

const Global = struct {
    tmp: testing.TmpDir,
    data_abs: [:0]u8,
    dir_abs: []u8,
    saved: ?[]const u8,

    fn init() !Global {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "data");
        const data_abs = try tmp.dir.realPathFileAlloc(testing.io, "data", gpa);
        errdefer gpa.free(data_abs);
        const dir_abs = try user_rules.dirIn(gpa, data_abs);
        const saved = user_rules.dir_override;
        user_rules.dir_override = dir_abs;
        return .{ .tmp = tmp, .data_abs = data_abs, .dir_abs = dir_abs, .saved = saved };
    }

    fn deinit(self: *Global) void {
        user_rules.dir_override = self.saved;
        gpa.free(self.dir_abs);
        gpa.free(self.data_abs);
        self.tmp.cleanup();
    }

    fn ledger(self: *Global) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, "data/rules/" ++ memory.ledger_name, gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => try gpa.dupe(u8, ""),
            else => return err,
        };
    }

    fn writeLedger(self: *Global, bytes: []const u8) !void {
        try self.tmp.dir.createDirPath(testing.io, "data/rules");
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "data/rules/" ++ memory.ledger_name, .data = bytes });
    }

    fn add(self: *Global, args: []const [:0]const u8) ![:0]u8 {
        _ = self;
        return addIn(error.NotInRepo, args);
    }
};

const File = struct { path: []const u8, data: []const u8 };

const Repo = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,

    fn init(files: []const File) !Repo {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo");
        for (files) |file| try write(tmp.dir, file);
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
        errdefer gpa.free(root_abs);
        try git_fixture.initRepo(root_abs);
        try git_fixture.commitInit(root_abs, true);
        return .{ .tmp = tmp, .root_abs = root_abs };
    }

    fn write(dir: std.Io.Dir, file: File) !void {
        const sub = try std.fmt.allocPrint(gpa, "repo/{s}", .{file.path});
        defer gpa.free(sub);
        if (std.fs.path.dirname(sub)) |parent| try dir.createDirPath(testing.io, parent);
        try dir.writeFile(testing.io, .{ .sub_path = sub, .data = file.data });
    }

    fn deinit(self: *Repo) void {
        gpa.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn ledger(self: *Repo) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, "repo/.emetgate/ledger.ndjson", gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => try gpa.dupe(u8, ""),
            else => return err,
        };
    }

    fn writeLedger(self: *Repo, bytes: []const u8) !void {
        try write(self.tmp.dir, .{ .path = ".emetgate/ledger.ndjson", .data = bytes });
    }

    fn git(self: *Repo, args: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, try git_fixture.git());
        try argv.appendSlice(gpa, args);
        const result = try bounded_run.run(gpa, testing.io, .{ .argv = argv.items, .cwd = .{ .path = self.root_abs } });
        gpa.free(result.stdout);
        gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitFailed,
            else => return error.GitFailed,
        }
    }

    fn commitLedger(self: *Repo) !void {
        try self.git(&.{ "add", "-f", "--", ".emetgate/ledger.ndjson" });
        try self.git(&.{ "commit", "-q", "-m", "ship a ledger" });
    }

    fn add(self: *Repo, args: []const [:0]const u8) ![:0]u8 {
        return addIn(self.root_abs, args);
    }
};

const Ran = struct {
    out: []u8,
    err_out: []u8,
    failure: ?anyerror,

    fn deinit(self: Ran) void {
        gpa.free(self.out);
        gpa.free(self.err_out);
    }
};

fn runRule(root: anyerror![]const u8, args: []const [:0]const u8) !Ran {
    const request = rule_command.parse(args) orelse return error.UsageRefused;
    var out: Allocating = .init(gpa);
    defer out.deinit();
    var err_out: Allocating = .init(gpa);
    defer err_out.deinit();
    var failure: ?anyerror = null;
    rule_command.run(gpa, testing.io, root, request, &out.writer, &err_out.writer) catch |err| {
        failure = err;
    };
    const printed = try gpa.dupe(u8, out.written());
    errdefer gpa.free(printed);
    return .{ .out = printed, .err_out = try gpa.dupe(u8, err_out.written()), .failure = failure };
}

fn addIn(root: anyerror![]const u8, args: []const [:0]const u8) ![:0]u8 {
    const ran = try runRule(root, args);
    defer ran.deinit();
    if (ran.failure) |err| return err;
    if (ran.out.len < 2) return error.NoIdPrinted;
    return gpa.dupeZ(u8, std.mem.trimEnd(u8, ran.out, "\n"));
}

const Scanned = struct {
    code: u8,
    out: []u8,
    err: []u8,

    fn deinit(self: Scanned) void {
        gpa.free(self.out);
        gpa.free(self.err);
    }

    fn has(self: Scanned, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.out, needle) != null or std.mem.indexOf(u8, self.err, needle) != null;
    }
};

fn scan(repo: *Repo, args: []const [:0]const u8) !Scanned {
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch |err| std.debug.panic("runtime closed with live allocations: {t}", .{err});
    var out: Allocating = .init(gpa);
    defer out.deinit();
    var err: Allocating = .init(gpa);
    defer err.deinit();
    const options = scan_command.Options.parse(args) orelse return error.UsageRefused;
    const code = try scan_command.run(gpa, testing.io, runtime, repo.root_abs, options, &out.writer, &err.writer);
    const out_bytes = try gpa.dupe(u8, out.written());
    errdefer gpa.free(out_bytes);
    return .{ .code = code, .out = out_bytes, .err = try gpa.dupe(u8, err.written()) };
}

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

fn fieldOf(line: []const u8, index: usize) []const u8 {
    var it = std.mem.splitScalar(u8, line, '\t');
    var i: usize = 0;
    while (it.next()) |field| : (i += 1) {
        if (i == index) return field;
    }
    return "";
}

fn rowOf(listing: []const u8, id: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, listing, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, fieldOf(line, 0), id)) return line;
    }
    return null;
}

fn globalRuleRow(id: []const u8, check: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{{\"id\":\"{s}\",\"scope\":\"global\",\"text\":\"hand written\",\"enforce\":true,\"check\":\"{s}\",\"status\":\"active\",\"supersedes\":null,\"ts\":1}}\n", .{ id, check });
}

test "global rules: rule add --global writes the global ledger with a g id and leaves the repository ledger alone" {
    try skipOffWindows();
    var global = try Global.init();
    defer global.deinit();
    var repo = try Repo.init(&.{});
    defer repo.deinit();

    const id = try addIn(repo.root_abs, &.{ "add", "no eval", "--check", "forbid:eval", "--enforce", "--global" });
    defer gpa.free(id);
    try testing.expect(memory.isUserId(id));
    try testing.expect(std.mem.startsWith(u8, id, memory.user_id_prefix));

    const repo_ledger = try repo.ledger();
    defer gpa.free(repo_ledger);
    try testing.expectEqualStrings("", repo_ledger);
    const global_ledger = try global.ledger();
    defer gpa.free(global_ledger);
    try testing.expect(std.mem.indexOf(u8, global_ledger, id) != null);
    try testing.expect(std.mem.indexOf(u8, global_ledger, "\"check\":\"forbid:eval\"") != null);

    const repo_id = try repo.add(&.{ "add", "repo rule" });
    defer gpa.free(repo_id);
    try testing.expect(std.mem.startsWith(u8, repo_id, memory.repo_id_prefix));
    try testing.expect(!memory.isUserId(repo_id));
}

test "global rules: rule add, pick and list with --global need no repository" {
    try skipOffWindows();
    var global = try Global.init();
    defer global.deinit();

    const id = try global.add(&.{ "add", "no eval", "--check", "forbid:eval", "--enforce", "--global" });
    defer gpa.free(id);
    try testing.expectError(error.NotInRepo, global.add(&.{ "add", "repo only" }));

    var out: Allocating = .init(gpa);
    defer out.deinit();
    var err_out: Allocating = .init(gpa);
    defer err_out.deinit();
    try rule_catalog.pick(gpa, testing.io, error.NotInRepo, &.{ "2", "26", "--global" }, "emetgate rule ", &out.writer, &err_out.writer);
    try testing.expectEqualStrings("", err_out.written());
    try testing.expectEqualStrings("enforcing 2 global rules: 2 no debugger, 26 no Co-authored-by\n", out.written());
    try testing.expectError(error.NotInRepo, rule_catalog.pick(gpa, testing.io, error.NotInRepo, &.{"2"}, "emetgate rule ", &out.writer, &err_out.writer));

    const listed = try runRule(error.NotInRepo, &.{ "list", "--global" });
    defer listed.deinit();
    try testing.expect(listed.failure == null);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, listed.out, "\n"), '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        try testing.expectEqualStrings("global", fieldOf(line, 2));
        try testing.expect(memory.isUserId(fieldOf(line, 0)));
    }
    try testing.expectEqual(@as(usize, 3), count);
    const unscoped = rowOf(listed.out, id).?;
    try testing.expectEqualStrings("active", fieldOf(unscoped, 1));
    try testing.expectEqualStrings("enforce", fieldOf(unscoped, 3));
    try testing.expectEqualStrings("forbid:eval", fieldOf(unscoped, 4));
}

test "global rules: rule list shows each rule's origin in text, in the table and in json" {
    try skipOffWindows();
    var global = try Global.init();
    defer global.deinit();
    var repo = try Repo.init(&.{});
    defer repo.deinit();

    const global_id = try repo.add(&.{ "add", "no eval", "--check", "forbid:eval", "--in", "src/", "--enforce", "--global" });
    defer gpa.free(global_id);
    const repo_id = try repo.add(&.{ "add", "no debugger", "--check", "forbid:debugger", "--enforce" });
    defer gpa.free(repo_id);

    const text = try runRule(repo.root_abs, &.{"list"});
    defer text.deinit();
    try testing.expectEqualStrings("repo", fieldOf(rowOf(text.out, repo_id).?, 2));
    const global_row = rowOf(text.out, global_id).?;
    try testing.expectEqualStrings("global", fieldOf(global_row, 2));
    try testing.expectEqualStrings("src/", fieldOf(global_row, 5));
    try testing.expectEqualStrings("no eval", fieldOf(global_row, 6));

    const json = try runRule(repo.root_abs, &.{ "list", "--json" });
    defer json.deinit();
    var seen: usize = 0;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, json.out, "\n"), '\n');
    while (it.next()) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        defer parsed.deinit();
        const id = parsed.value.object.get("id").?.string;
        const origin = parsed.value.object.get("origin").?.string;
        try testing.expectEqualStrings(if (std.mem.eql(u8, id, global_id)) "global" else "repo", origin);
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 2), seen);

    const only = try runRule(repo.root_abs, &.{ "list", "--global" });
    defer only.deinit();
    try testing.expect(rowOf(only.out, repo_id) == null);
    try testing.expect(rowOf(only.out, global_id) != null);

    const request = rule_command.parse(&.{"list"}).?;
    var spoken: Allocating = .init(gpa);
    defer spoken.deinit();
    var spoken_err: Allocating = .init(gpa);
    defer spoken_err.deinit();
    try rule_command.runAs(.spoken, gpa, testing.io, repo.root_abs, request, &spoken.writer, &spoken_err.writer);
    try testing.expect(std.mem.startsWith(u8, spoken.written(), "id"));
    try testing.expect(std.mem.indexOf(u8, spoken.written(), "  origin  ") != null);
    try testing.expect(std.mem.indexOf(u8, spoken.written(), "  global  ") != null);
    try testing.expect(std.mem.indexOf(u8, spoken.written(), "  repo    ") != null);
}

test "global rules: an enforced global rule is enforced in every repository" {
    try skipOffWindows();
    var global = try Global.init();
    defer global.deinit();
    var first = try Repo.init(&.{.{ .path = "src/run.ts", .data = with_eval }});
    defer first.deinit();
    var second = try Repo.init(&.{.{ .path = "lib/run.ts", .data = with_eval }});
    defer second.deinit();

    const id = try global.add(&.{ "add", "no eval", "--check", "forbid:eval", "--enforce", "--global" });
    defer gpa.free(id);

    for ([_]*Repo{ &first, &second }) |repo| {
        const scanned = try scan(repo, &.{});
        defer scanned.deinit();
        try testing.expectEqual(scan_command.violations_exit_code, scanned.code);
        try testing.expect(scanned.has(id));
        try testing.expect(scanned.has("(forbid:eval): eval"));

        const enforced = try rules.load(gpa, testing.io, repo.root_abs);
        defer enforced.deinit();
        try testing.expectEqual(@as(usize, 1), enforced.rules.len);
        try testing.expectEqual(rules.Origin.global, enforced.rules[0].origin);
        try testing.expectEqualStrings(id, enforced.rules[0].id);
    }

    const forgotten = try runRule(error.NotInRepo, &.{ "forget", id, "--global" });
    defer forgotten.deinit();
    try testing.expect(forgotten.failure == null);
    const after = try scan(&first, &.{});
    defer after.deinit();
    try testing.expectEqual(@as(u8, 0), after.code);
}

test "global rules: a scope in a global rule is relative to each repository root, and a repository without it is not refused" {
    try skipOffWindows();
    var global = try Global.init();
    defer global.deinit();
    var with_src = try Repo.init(&.{ .{ .path = "src/run.ts", .data = with_eval }, .{ .path = "tools/run.ts", .data = with_eval } });
    defer with_src.deinit();
    var without_src = try Repo.init(&.{.{ .path = "lib/run.ts", .data = with_eval }});
    defer without_src.deinit();

    const id = try global.add(&.{ "add", "no eval in src", "--check", "forbid:eval", "--in", "src/", "--enforce", "--global" });
    defer gpa.free(id);

    const scoped = try scan(&with_src, &.{});
    defer scoped.deinit();
    try testing.expectEqual(scan_command.violations_exit_code, scoped.code);
    try testing.expect(scoped.has("src/run.ts:2:"));
    try testing.expect(!scoped.has("tools/run.ts"));

    const elsewhere = try scan(&without_src, &.{});
    defer elsewhere.deinit();
    try testing.expectEqual(@as(u8, 0), elsewhere.code);
    try testing.expect(!elsewhere.has("ScopeUnresolved"));
    try testing.expect(!elsewhere.has("NothingInScope"));
    try testing.expect(elsewhere.has("0 violation(s) in 0 file(s), 0 rule(s)\n"));
}

test "global rules: a repository cannot forget or supersede a global rule, from the command line or from its ledger" {
    try skipOffWindows();
    var global = try Global.init();
    defer global.deinit();
    var repo = try Repo.init(&.{.{ .path = "src/run.ts", .data = with_eval }});
    defer repo.deinit();
    const id = try global.add(&.{ "add", "no eval", "--check", "forbid:eval", "--enforce", "--global" });
    defer gpa.free(id);
    const before = try global.ledger();
    defer gpa.free(before);

    const forget = try runRule(repo.root_abs, &.{ "forget", id });
    defer forget.deinit();
    try testing.expectEqual(@as(?anyerror, error.RuleIsGlobal), forget.failure);
    const supersede = try runRule(repo.root_abs, &.{ "supersede", id, "eval is fine" });
    defer supersede.deinit();
    try testing.expectEqual(@as(?anyerror, error.RuleIsGlobal), supersede.failure);
    const unchanged = try global.ledger();
    defer gpa.free(unchanged);
    try testing.expectEqualStrings(before, unchanged);
    const repo_ledger = try repo.ledger();
    defer gpa.free(repo_ledger);
    try testing.expectEqualStrings("", repo_ledger);

    const tombstone = try std.fmt.allocPrint(gpa, "{{\"id\":\"{s}\",\"scope\":\"global\",\"text\":\"no eval\",\"enforce\":true,\"check\":\"forbid:eval\",\"status\":\"superseded\",\"supersedes\":null,\"ts\":9}}\n", .{id});
    defer gpa.free(tombstone);
    const successor = try std.fmt.allocPrint(gpa, "{{\"id\":\"mrepo000000000001\",\"scope\":\"project\",\"text\":\"eval is fine\",\"enforce\":false,\"check\":null,\"status\":\"active\",\"supersedes\":\"{s}\",\"ts\":9}}\n", .{id});
    defer gpa.free(successor);
    const shadowing = try globalRuleRow(id, "forbid:nothing_at_all");
    defer gpa.free(shadowing);
    const Attempt = struct { bytes: []const u8, err: anyerror };
    for ([_]Attempt{
        .{ .bytes = tombstone, .err = error.LedgerCorrupt },
        .{ .bytes = successor, .err = error.LedgerCorrupt },
        .{ .bytes = shadowing, .err = error.GlobalRuleIdInRepo },
    }) |attempt| {
        try repo.writeLedger(attempt.bytes);
        try testing.expectError(attempt.err, rules.load(gpa, testing.io, repo.root_abs));
        try testing.expectError(attempt.err, rules.peek(gpa, testing.io, repo.root_abs));
        const scanned = try scan(&repo, &.{});
        defer scanned.deinit();
        try testing.expect(scanned.code != 0);
        try testing.expect(scanned.has(@errorName(attempt.err)));
    }
    try testing.expectError(error.GlobalRuleIdInRepo, rules.adoptedFor(gpa, testing.io, repo.root_abs, "src/run.ts"));
}

test "global rules: a repository rule with the same check never replaces the global one" {
    try skipOffWindows();
    var global = try Global.init();
    defer global.deinit();
    var repo = try Repo.init(&.{.{ .path = "src/run.ts", .data = with_eval }});
    defer repo.deinit();
    const query = "q:((identifier) @violation (#eq? @violation \"eval\"))";
    const id = try global.add(&.{ "add", "no eval", "--check", query, "--enforce", "--global" });
    defer gpa.free(id);
    const repo_id = try repo.add(&.{ "add", "no eval", "--check", query, "--enforce" });
    defer gpa.free(repo_id);
    try repo.commitLedger();

    const scanned = try scan(&repo, &.{});
    defer scanned.deinit();
    try testing.expectEqual(scan_command.violations_exit_code, scanned.code);
    try testing.expect(scanned.has(id));
    const untrusted = try std.fmt.allocPrint(gpa, "warning: rule {s} ", .{repo_id});
    defer gpa.free(untrusted);
    try testing.expect(scanned.has(untrusted));
    const global_untrusted = try std.fmt.allocPrint(gpa, "warning: rule {s} ", .{id});
    defer gpa.free(global_untrusted);
    try testing.expect(!scanned.has(global_untrusted));

    const enforced = try rules.load(gpa, testing.io, repo.root_abs);
    defer enforced.deinit();
    var global_rules: usize = 0;
    for (enforced.rules) |rule| {
        if (rule.origin == .global) global_rules += 1;
    }
    try testing.expectEqual(@as(usize, 1), global_rules);
}

test "global rules: a global cmd: rule runs without --allow-repo-memory beside a committed ledger, a repository one does not" {
    try skipOffWindows();
    var global = try Global.init();
    defer global.deinit();
    var repo = try Repo.init(&.{.{ .path = "src/run.ts", .data = with_eval }});
    defer repo.deinit();
    const static_id = try repo.add(&.{ "add", "no debugger", "--check", "forbid:debugger", "--enforce" });
    defer gpa.free(static_id);
    try repo.commitLedger();
    const id = try global.add(&.{ "add", "always fails", "--check", "cmd:exit 3", "--enforce", "--global" });
    defer gpa.free(id);

    const gated = try rules.commandGate(gpa, testing.io, repo.root_abs, &.{"src/run.ts"}, .{ .shadow_abs = repo.root_abs });
    defer gated.deinit(gpa);
    try testing.expect(gated == .violated);
    try testing.expectEqualStrings(id, gated.violated.violations[0].rule);

    const repo_cmd = try repo.add(&.{ "add", "repo command", "--check", "cmd:exit 0", "--enforce" });
    defer gpa.free(repo_cmd);
    try repo.commitLedger();
    try testing.expectError(error.UntrustedRepoMemory, rules.commandGate(gpa, testing.io, repo.root_abs, &.{"src/run.ts"}, .{ .shadow_abs = repo.root_abs }));
}

fn proposeAdd(repo: *Repo, runtime: *Runtime, body: []const u8) !emetgate.runner.Result {
    const file_abs = try std.fmt.allocPrint(gpa, "{s}\\src\\math.ts", .{repo.root_abs});
    defer gpa.free(file_abs);
    const snapshot = try emetgate.loader.Snapshot.load(runtime, testing.io, .cwd(), file_abs);
    const hash = blk: {
        defer snapshot.destroy();
        const ref = try emetgate.symbol.Ref.parse(gpa, "add");
        defer ref.deinit(gpa);
        break :blk (try (try snapshot.symbols()).resolve(ref)).hash;
    };
    return emetgate.runner.tryMutate(gpa, testing.io, runtime, .{
        .file_abs = file_abs,
        .ref_text = "add",
        .expected_hash = .{ .present = hash },
        .new_body = body,
        .test_command = "cmd /c exit 0",
        .allow_repo_memory = false,
    });
}

test "global rules: a global q: rule judges a write without --allow-repo-memory beside a committed ledger" {
    try skipOffWindows();
    var global = try Global.init();
    defer global.deinit();
    var repo = try Repo.init(&.{.{ .path = "src/math.ts", .data = "export function add(a: number, b: number): number {\n  return a + b;\n}\n" }});
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    const static_id = try repo.add(&.{ "add", "no debugger", "--check", "forbid:debugger", "--enforce" });
    defer gpa.free(static_id);
    try repo.commitLedger();
    const id = try global.add(&.{ "add", "no minus_marker", "--check", "q:((identifier) @violation (#eq? @violation \"minus_marker\"))", "--enforce", "--global" });
    defer gpa.free(id);

    const refused = try proposeAdd(&repo, runtime, "{\n  const minus_marker = a - b;\n  return minus_marker;\n}");
    defer refused.deinit(gpa);
    try testing.expect(refused == .rule_violation);
    try testing.expectEqualStrings(id, refused.rule_violation.violations[0].rule);

    const passed = try proposeAdd(&repo, runtime, "{\n  return a - b;\n}");
    defer passed.deinit(gpa);
    try testing.expect(passed == .committed);
}

test "global rules: a global cmd: rule never runs a program the repository planted next to it" {
    try skipOffWindows();
    var global = try Global.init();
    defer global.deinit();
    var repo = try Repo.init(&.{ .{ .path = "src/run.ts", .data = with_eval }, .{ .path = "planted-gate-check.cmd", .data = "@exit 0\r\n" } });
    defer repo.deinit();
    try testing.expect(try rules.resolvable(gpa, testing.io, repo.root_abs, "planted-gate-check"));
    try testing.expect(!try rules.resolvableOutsideRepo(gpa, testing.io, "planted-gate-check"));
    try testing.expect(!try rules.resolvableOutsideRepo(gpa, testing.io, ".\\planted-gate-check.cmd"));
    try testing.expect(try rules.resolvableOutsideRepo(gpa, testing.io, "exit"));

    const id = try global.add(&.{ "add", "planted", "--check", "cmd:planted-gate-check", "--enforce", "--global" });
    defer gpa.free(id);
    const gated = try rules.commandGate(gpa, testing.io, repo.root_abs, &.{"src/run.ts"}, .{ .shadow_abs = repo.root_abs });
    defer gated.deinit(gpa);
    try testing.expect(gated == .failed);
    try testing.expectEqualStrings("command_not_found", gated.failed.detail);
    try testing.expectEqualStrings(id, gated.failed.rule);

    const repo_id = try repo.add(&.{ "add", "planted", "--check", "cmd:planted-gate-check", "--enforce" });
    defer gpa.free(repo_id);
    const forgotten = try runRule(error.NotInRepo, &.{ "forget", id, "--global" });
    defer forgotten.deinit();
    const repo_gate = try rules.commandGate(gpa, testing.io, repo.root_abs, &.{"src/run.ts"}, .{ .shadow_abs = repo.root_abs, .allow_repo_memory = true });
    defer repo_gate.deinit(gpa);
    errdefer if (repo_gate == .failed) std.debug.print("repo rule: {s} {s}\n", .{ repo_gate.failed.detail, repo_gate.failed.text });
    try testing.expect(repo_gate != .failed or !std.mem.eql(u8, repo_gate.failed.detail, "command_not_found"));
}

test "global rules: a malformed global ledger fails every gate closed and names the global ledger" {
    try skipOffWindows();
    var global = try Global.init();
    defer global.deinit();
    var repo = try Repo.init(&.{.{ .path = "src/run.ts", .data = with_eval }});
    defer repo.deinit();
    try global.writeLedger("{\"id\":\"g0000000000000001\",\"text\":\"broken\"}\n");

    try testing.expectError(error.UserLedgerCorrupt, rules.load(gpa, testing.io, repo.root_abs));
    try testing.expectError(error.UserLedgerCorrupt, rules.peek(gpa, testing.io, repo.root_abs));
    try testing.expectError(error.UserLedgerCorrupt, rules.adoptedFor(gpa, testing.io, repo.root_abs, "src/run.ts"));
    try testing.expectError(error.UserLedgerCorrupt, rules.messageGate(gpa, testing.io, repo.root_abs, "subject\n"));
    try testing.expectError(error.UserLedgerCorrupt, rules.frozenGate(gpa, testing.io, repo.root_abs, &.{"src/run.ts"}, false));

    const scanned = try scan(&repo, &.{});
    defer scanned.deinit();
    try testing.expectEqual(wire.exitCode(error.UserLedgerCorrupt), scanned.code);
    try testing.expect(scanned.has("UserLedgerCorrupt"));
    const fix = wire.fixFor("UserLedgerCorrupt").?;
    try testing.expect(std.mem.indexOf(u8, fix, "global rule ledger") != null);
    try testing.expect(std.mem.indexOf(u8, fix, "emetgate\\rules\\ledger.ndjson") != null);
    try testing.expect(std.mem.indexOf(u8, doctor.hint(error.UserLedgerCorrupt).?, "global rule ledger") != null);

    const repaired = try runRule(repo.root_abs, &.{ "list", "--global" });
    defer repaired.deinit();
    try testing.expect(repaired.failure == null);
    var moved = false;
    var dir = try global.tmp.dir.openDir(testing.io, "data/rules", .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, memory.torn_prefix)) moved = true;
    }
    try testing.expect(moved);
    const enforced = try rules.load(gpa, testing.io, repo.root_abs);
    enforced.deinit();

    const valid = try globalRuleRow("g00000000000000aa", "forbid:eval");
    defer gpa.free(valid);
    const damaged = try std.mem.concat(gpa, u8, &.{ "not json\n", valid });
    defer gpa.free(damaged);
    try global.writeLedger(damaged);
    try testing.expectError(error.UserLedgerCorrupt, rules.load(gpa, testing.io, repo.root_abs));
    const listed = try runRule(repo.root_abs, &.{"list"});
    defer listed.deinit();
    try testing.expectEqual(@as(?anyerror, error.UserLedgerCorrupt), listed.failure);
    const added = runRule(repo.root_abs, &.{ "add", "x", "--global" });
    defer if (added) |ran| ran.deinit() else |_| {};
    try testing.expectEqual(@as(?anyerror, error.UserLedgerCorrupt), (try added).failure);
}

test "global rules: a row still being appended is not read, and the rows before it still apply" {
    try skipOffWindows();
    var global = try Global.init();
    defer global.deinit();
    var repo = try Repo.init(&.{});
    defer repo.deinit();
    const row = try globalRuleRow("g00000000000000aa", "forbid:eval");
    defer gpa.free(row);
    const half = try std.mem.concat(gpa, u8, &.{ row, "{\"id\":\"g00000000000000bb\",\"sco" });
    defer gpa.free(half);
    try global.writeLedger(half);

    const enforced = try rules.peek(gpa, testing.io, repo.root_abs);
    defer enforced.deinit();
    try testing.expectEqual(@as(usize, 1), enforced.rules.len);
    try testing.expectEqualStrings("g00000000000000aa", enforced.rules[0].id);
    try testing.expectEqualStrings("", memory.settledRows("{\"id\""));
    try testing.expectEqualStrings("a\n", memory.settledRows("a\nb"));
}

test "global rules: a held lock refuses a second writer and leaves the global ledger as it was" {
    try skipOffWindows();
    var global = try Global.init();
    defer global.deinit();
    const id = try global.add(&.{ "add", "no eval", "--check", "forbid:eval", "--enforce", "--global" });
    defer gpa.free(id);
    const before = try global.ledger();
    defer gpa.free(before);

    const lock_path = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ global.dir_abs, memory.lock_name });
    defer gpa.free(lock_path);
    const lock = try shadow.FileLock.acquire(lock_path);
    try testing.expectError(error.MemoryBusy, global.add(&.{ "add", "second", "--global" }));
    try testing.expectError(error.MemoryBusy, global.add(&.{ "forget", id, "--global" }));
    const listed = try runRule(error.NotInRepo, &.{ "list", "--global" });
    defer listed.deinit();
    try testing.expect(listed.failure == null);
    try testing.expect(rowOf(listed.out, id) != null);
    lock.release();
    const after = try global.ledger();
    defer gpa.free(after);
    try testing.expectEqualStrings(before, after);

    const second = try global.add(&.{ "add", "second", "--global" });
    defer gpa.free(second);
}

const read_share = struct {
    const windows = std.os.windows;
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: windows.DWORD, share: windows.DWORD, security: ?*anyopaque, disposition: windows.DWORD, flags: windows.DWORD, template: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;

    fn open(path: []const u8) !windows.HANDLE {
        const wide = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, path);
        defer gpa.free(wide);
        const handle = CreateFileW(wide.ptr, 0x80000000, 0x00000001, null, 3, 0x02000000, null);
        if (handle == windows.INVALID_HANDLE_VALUE) return error.OpenFailed;
        return handle;
    }
};

test "global rules: reading the global rules asks for no write access, so a session that may only read them still applies them" {
    try skipOffWindows();
    var global = try Global.init();
    defer global.deinit();
    const id = try global.add(&.{ "add", "no eval", "--check", "forbid:eval", "--enforce", "--global" });
    defer gpa.free(id);

    const readers_only = try read_share.open(global.dir_abs);
    defer std.os.windows.CloseHandle(readers_only);
    const recalled = try user_rules.peek(gpa, testing.io);
    defer recalled.deinit();
    try testing.expectEqual(@as(usize, 1), recalled.decisions.len);
    try testing.expectEqualStrings(id, recalled.decisions[0].id);
    try testing.expectError(error.MemoryBusy, global.add(&.{ "add", "second", "--global" }));
    for ([_][]const [:0]const u8{ &.{ "list", "--global" }, &.{ "list", "--global", "--all" } }) |args| {
        const listed = try runRule(error.NotInRepo, args);
        defer listed.deinit();
        try testing.expect(listed.failure == null);
        try testing.expect(rowOf(listed.out, id) != null);
    }
}

fn junction(link_abs: []const u8, target_abs: []const u8) !void {
    const cmd = try exe_path.system(gpa, "cmd.exe");
    defer gpa.free(cmd);
    const result = try bounded_run.run(gpa, testing.io, .{ .argv = &.{ cmd, "/d", "/c", "mklink", "/J", link_abs, target_abs } });
    gpa.free(result.stdout);
    gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }
}

test "global rules: a junction in place of the global rule folder is refused, never followed" {
    try skipOffWindows();
    var global = try Global.init();
    defer global.deinit();
    var repo = try Repo.init(&.{.{ .path = "src/run.ts", .data = with_eval }});
    defer repo.deinit();
    try global.tmp.dir.createDirPath(testing.io, "elsewhere");
    try global.tmp.dir.writeFile(testing.io, .{ .sub_path = "elsewhere/" ++ memory.ledger_name, .data = "" });
    const elsewhere = try global.tmp.dir.realPathFileAlloc(testing.io, "elsewhere", gpa);
    defer gpa.free(elsewhere);
    try junction(global.dir_abs, elsewhere);

    try testing.expectError(error.UserRulesDirIsLink, user_rules.peek(gpa, testing.io));
    try testing.expectError(error.UserRulesDirIsLink, rules.load(gpa, testing.io, repo.root_abs));
    try testing.expectError(error.UserRulesDirIsLink, global.add(&.{ "add", "no eval", "--check", "forbid:eval", "--enforce", "--global" }));
    const untouched = try global.tmp.dir.readFileAlloc(testing.io, "elsewhere/" ++ memory.ledger_name, gpa, .unlimited);
    defer gpa.free(untouched);
    try testing.expectEqualStrings("", untouched);
    try testing.expect(std.mem.indexOf(u8, wire.fixFor("UserRulesDirIsLink").?, "junction") != null);
}

test "global rules: a nested repository applies a global rule once, scoped to its own root" {
    try skipOffWindows();
    var global = try Global.init();
    defer global.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "outer/inner");
    const outer = try tmp.dir.realPathFileAlloc(testing.io, "outer", gpa);
    defer gpa.free(outer);
    const inner = try tmp.dir.realPathFileAlloc(testing.io, "outer/inner", gpa);
    defer gpa.free(inner);
    const outer_id = try memory.remember(gpa, testing.io, outer, .project, "no debugger", true, "forbid:debugger", null);
    defer gpa.free(outer_id);
    const id = try global.add(&.{ "add", "no eval in src", "--check", "forbid:eval", "--in", "src/", "--enforce", "--global" });
    defer gpa.free(id);

    const saved = rules.outer_root;
    rules.outer_root = outer;
    defer rules.outer_root = saved;
    const enforced = try rules.load(gpa, testing.io, inner);
    defer enforced.deinit();
    var held: usize = 0;
    for (enforced.rules) |rule| {
        if (rule.origin != .global) continue;
        held += 1;
        try testing.expectEqualStrings(id, rule.id);
        try testing.expectEqualStrings("src/", rule.where.?);
    }
    try testing.expectEqual(@as(usize, 1), held);
    try testing.expectEqual(@as(usize, 2), enforced.rules.len);
}

test "global rules: the rules a file reads name a global rule by its origin" {
    try skipOffWindows();
    var global = try Global.init();
    defer global.deinit();
    var repo = try Repo.init(&.{.{ .path = "src/run.ts", .data = with_eval }});
    defer repo.deinit();
    const id = try global.add(&.{ "add", "prefer small functions", "--global" });
    defer gpa.free(id);
    const repo_id = try repo.add(&.{ "add", "no debugger", "--check", "forbid:debugger", "--enforce" });
    defer gpa.free(repo_id);

    const adopted = try rules.adoptedFor(gpa, testing.io, repo.root_abs, "src/run.ts");
    defer adopted.deinit();
    try testing.expectEqual(@as(usize, 2), adopted.items.len);
    for (adopted.items) |rule| {
        const want: rules.Origin = if (std.mem.eql(u8, rule.id, id)) .global else .repo;
        try testing.expectEqual(want, rule.origin);
    }

    var buffer: Allocating = .init(gpa);
    defer buffer.deinit();
    try wire.writeSkeleton(&buffer.writer, "src/run.ts", emetgate.symbol.hashOf(""), .skeleton, "", adopted.items, &.{});
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, buffer.written(), "\"origin\":\"global\""));
}

test "global rules: cache prune --all leaves the global rules where they are" {
    try skipOffWindows();
    var global = try Global.init();
    defer global.deinit();
    const id = try global.add(&.{ "add", "no eval", "--check", "forbid:eval", "--enforce", "--global" });
    defer gpa.free(id);
    const before = try global.ledger();
    defer gpa.free(before);
    try global.tmp.dir.createDirPath(testing.io, "data/run-tmp/x");
    try global.tmp.dir.writeFile(testing.io, .{ .sub_path = "data/run-tmp/x/f", .data = "temp" });

    var out: Allocating = .init(gpa);
    defer out.deinit();
    const options = cache_command.parse(&.{ "prune", "--all" }).?;
    _ = try cache_command.runIn(gpa, testing.io, global.data_abs, std.Io.Clock.real.now(testing.io).nanoseconds, options, &.{}, &out.writer);
    try testing.expectError(error.FileNotFound, global.tmp.dir.access(testing.io, "data/run-tmp/x/f", .{}));
    const after = try global.ledger();
    defer gpa.free(after);
    try testing.expectEqualStrings(before, after);
    const still = try user_rules.peek(gpa, testing.io);
    defer still.deinit();
    try testing.expectEqual(@as(usize, 1), still.decisions.len);
}

test "global rules: uninstall says whether the global rules go with the data folder or stay" {
    try skipOffWindows();
    var global = try Global.init();
    defer global.deinit();
    const id = try global.add(&.{ "add", "no eval", "--check", "forbid:eval", "--enforce", "--global" });
    defer gpa.free(id);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = (try uninstall.globalRulesIn(arena, testing.io, global.data_abs)).?;
    try testing.expectEqual(@as(?usize, 1), found.count);
    try testing.expect(std.mem.endsWith(u8, found.path, "\\rules\\" ++ memory.ledger_name));

    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    for ([_]bool{ false, true }) |keep| {
        const facts: uninstall.Facts = .{
            .local_app_data = "C:\\Users\\u\\AppData\\Local",
            .self_exe = "C:\\Users\\u\\AppData\\Local\\Programs\\emetgate\\emetgate.exe",
            .user_path = null,
            .program_entries = &.{"emetgate.exe"},
            .data_present = true,
            .data_bytes = 4096,
            .others = &.{},
            .keep_cache = keep,
            .global_rules = found,
        };
        const p = try uninstall.plan(arena, facts, &env);
        var buffer: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try uninstall.writePlan(&writer, p, false);
        const text = writer.buffered();
        const line = try std.fmt.allocPrint(arena, "  rules    {s} (your 1 global rule, applied in every repository; ", .{found.path});
        try testing.expect(std.mem.indexOf(u8, text, line) != null);
        const said = if (keep) "kept with the data folder)" else "removed with the data folder, --keep-cache keeps them)";
        try testing.expect(std.mem.indexOf(u8, text, said) != null);
        if (keep) try testing.expect(std.mem.indexOf(u8, text, "Kept:\n") != null);
    }

    var empty_tmp = testing.tmpDir(.{});
    defer empty_tmp.cleanup();
    const empty = try empty_tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(empty);
    try testing.expect((try uninstall.globalRulesIn(arena, testing.io, empty)) == null);

    try global.writeLedger("broken\n");
    const unreadable = (try uninstall.globalRulesIn(arena, testing.io, global.data_abs)).?;
    try testing.expect(unreadable.count == null);
}

test "global rules: doctor names the global ledger and how many rules it holds, and fails on one it cannot read" {
    try skipOffWindows();
    var global = try Global.init();
    defer global.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const resolved = try user_rules.ledgerPath(arena, global.dir_abs);

    const none = try doctor.rulesCheck(arena, testing.io);
    try testing.expectEqual(doctor.Status.ok, none.status);
    try testing.expectEqualStrings("rules", none.name);
    try testing.expect(std.mem.startsWith(u8, none.detail, "0 global rules (0 enforced) in "));
    try testing.expect(std.mem.indexOf(u8, none.detail, resolved) != null);

    const row = try globalRuleRow("g00000000000000aa", "forbid:eval");
    defer gpa.free(row);
    try global.writeLedger(row);
    const one = try doctor.rulesCheck(arena, testing.io);
    try testing.expectEqual(doctor.Status.ok, one.status);
    try testing.expect(std.mem.startsWith(u8, one.detail, "1 global rule (1 enforced) in "));

    try global.writeLedger("broken\n");
    const bad = try doctor.rulesCheck(arena, testing.io);
    try testing.expectEqual(doctor.Status.fail, bad.status);
    try testing.expect(std.mem.indexOf(u8, bad.detail, "UserLedgerCorrupt") != null);
    try testing.expect(bad.fix.len != 0);
}

const process_env = struct {
    extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) std.os.windows.BOOL;

    fn set(name: [:0]const u16, value: ?[]const u8) !void {
        const wide = if (value) |text| try std.unicode.wtf8ToWtf16LeAllocZ(gpa, text) else null;
        defer if (wide) |owned| gpa.free(owned);
        if (SetEnvironmentVariableW(name.ptr, if (wide) |owned| owned.ptr else null) == .FALSE) return error.SetEnvFailed;
    }
};

test "global rules: the global rules folder comes from the user profile, so an environment a repository sets cannot move it" {
    try skipOffWindows();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = try user_rules.profileDataDir(gpa);
    defer gpa.free(before);
    try testing.expect(std.mem.endsWith(u8, before, "\\" ++ emetgate.cache_lease.data_dir_name));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const planted = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(planted);
    const names = [_][:0]const u16{
        std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"),
        std.unicode.utf8ToUtf16LeStringLiteral("USERPROFILE"),
        std.unicode.utf8ToUtf16LeStringLiteral("APPDATA"),
        std.unicode.utf8ToUtf16LeStringLiteral("HOMEDRIVE"),
        std.unicode.utf8ToUtf16LeStringLiteral("HOMEPATH"),
    };
    var saved: [names.len]?[]u8 = undefined;
    for (names, &saved) |name, *slot| slot.* = try emetgate.sandbox.environmentValue(arena, name);
    defer for (names, saved) |name, value| process_env.set(name, value) catch {};
    for (names) |name| try process_env.set(name, planted);

    const moved = try emetgate.sandbox.environmentValue(arena, names[0]);
    try testing.expectEqualStrings(planted, moved.?);
    const after = try user_rules.profileDataDir(gpa);
    defer gpa.free(after);
    try testing.expectEqualStrings(before, after);
    try testing.expect(!std.ascii.startsWithIgnoreCase(after, planted));
}

test "global rules: the usage names --global on every verb that writes or lists, and the grammar takes it once" {
    const text = rule_command.usage("emetgate rule ");
    for ([_][]const u8{ "add <text>", "list [", "supersede <id>", "forget <id>", "pick [" }) |verb| {
        const at = std.mem.indexOf(u8, text, verb).?;
        const end = std.mem.indexOfScalarPos(u8, text, at, '\n').?;
        try testing.expect(std.mem.indexOf(u8, text[at..end], "[--global]") != null);
    }
    try testing.expect(rule_command.parse(&.{ "add", "t", "--global" }).?.global());
    try testing.expect(!rule_command.parse(&.{ "add", "t" }).?.global());
    try testing.expect(rule_command.parse(&.{ "add", "t", "--global", "--global" }) == null);
    try testing.expect(rule_command.parse(&.{ "forget", "g1", "--global" }).?.global());
    try testing.expect(rule_command.parse(&.{ "forget", "g1", "--json" }) == null);
    try testing.expect(rule_command.parse(&.{ "list", "--global", "--json", "--all" }).?.global());
    try testing.expect(rule_command.parse(&.{ "supersede", "g1", "t", "--global" }).?.global());
}
