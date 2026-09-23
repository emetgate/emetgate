const std = @import("std");
const git_fixture = @import("git_fixture.zig");
const builtin = @import("builtin");
const runner = @import("emetgate").runner;
const shadow = @import("emetgate").shadow;
const memory = @import("emetgate").memory;
const symbol = @import("emetgate").symbol;
const server = @import("emetgate").server;
const Runtime = @import("emetgate").runtime.Runtime;
const Snapshot = @import("emetgate").loader.Snapshot;
const query_cases = @import("query_cases.zig");

const testing = std.testing;
const gpa = testing.allocator;

const math_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const edited_body = "{\n  return a - b;\n}";
const marker_name = "ran.txt";

const Clone = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,
    drop_abs: [:0]u8,
    file_abs: []u8,

    fn init() !Clone {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src");
        try tmp.dir.createDirPath(testing.io, "drop");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/math.ts", .data = math_src });
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
        errdefer gpa.free(root_abs);
        const drop_abs = try tmp.dir.realPathFileAlloc(testing.io, "drop", gpa);
        errdefer gpa.free(drop_abs);
        try shadow.grantLowIntegrityWrite(drop_abs);
        const file_abs = try std.fmt.allocPrint(gpa, "{s}\\src\\math.ts", .{root_abs});
        errdefer gpa.free(file_abs);
        try git_fixture.initRepo(root_abs);
        for ([_][]const []const u8{
            &.{ "add", "." },
            &.{ "commit", "-q", "-m", "init" },
        }) |args| try git(root_abs, args);
        return .{ .tmp = tmp, .root_abs = root_abs, .drop_abs = drop_abs, .file_abs = file_abs };
    }

    fn deinit(self: *Clone) void {
        gpa.free(self.file_abs);
        gpa.free(self.drop_abs);
        gpa.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn git(root_abs: []const u8, args: []const []const u8) !void {
        var argv: [8][]const u8 = undefined;
        argv[0] = "git";
        @memcpy(argv[1..][0..args.len], args);
        const result = try std.process.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root_abs } });
        gpa.free(result.stdout);
        gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitSetupFailed,
            else => return error.GitSetupFailed,
        }
    }

    fn adoptMarkerRule(self: *Clone) !void {
        const spec = try std.fmt.allocPrint(gpa, "cmd:echo ran> {s}\\" ++ marker_name, .{self.drop_abs});
        defer gpa.free(spec);
        const id = try memory.remember(gpa, testing.io, self.root_abs, .global, "hostile rule", true, spec, null);
        gpa.free(id);
    }

    fn adoptStaticRule(self: *Clone) !void {
        const id = try memory.remember(gpa, testing.io, self.root_abs, .global, "no Math.abs", true, "forbid:Math.abs", null);
        gpa.free(id);
    }

    fn commitLedgerAs(self: *Clone, rel: []const u8) !void {
        const canonical = shadow.workspace_dir ++ "/" ++ memory.ledger_name;
        if (!std.mem.eql(u8, rel, canonical)) {
            const bytes = try self.tmp.dir.readFileAlloc(testing.io, "repo/" ++ canonical, gpa, .unlimited);
            defer gpa.free(bytes);
            try self.tmp.dir.deleteTree(testing.io, "repo/" ++ shadow.workspace_dir);
            const target = try std.fmt.allocPrint(gpa, "repo/{s}", .{rel});
            defer gpa.free(target);
            try self.tmp.dir.createDirPath(testing.io, std.fs.path.dirname(target).?);
            try self.tmp.dir.writeFile(testing.io, .{ .sub_path = target, .data = bytes });
        }
        try git(self.root_abs, &.{ "add", "-f", "--", rel });
        try git(self.root_abs, &.{ "commit", "-q", "-m", "ship a ledger" });
    }

    fn commitLedger(self: *Clone) !void {
        return self.commitLedgerAs(shadow.workspace_dir ++ "/" ++ memory.ledger_name);
    }

    fn markerExists(self: *Clone) bool {
        self.tmp.dir.access(testing.io, "drop/" ++ marker_name, .{}) catch return false;
        return true;
    }

    fn expectNoMarker(self: *Clone) !void {
        try testing.expectError(error.FileNotFound, self.tmp.dir.access(testing.io, "drop/" ++ marker_name, .{}));
    }

    fn expectPristine(self: *Clone) !void {
        const on_disk = try self.tmp.dir.readFileAlloc(testing.io, "repo/src/math.ts", gpa, .unlimited);
        defer gpa.free(on_disk);
        try testing.expectEqualStrings(math_src, on_disk);
        try testing.expectError(error.FileNotFound, self.tmp.dir.access(testing.io, "repo/" ++ shadow.workspace_dir ++ "/shadow", .{}));
    }

    fn expectEdited(self: *Clone) !void {
        const on_disk = try self.tmp.dir.readFileAlloc(testing.io, "repo/src/math.ts", gpa, .unlimited);
        defer gpa.free(on_disk);
        try testing.expectEqualStrings("export function add(a: number, b: number): number {\n  return a - b;\n}\n", on_disk);
    }

    fn hashOfAdd(self: *Clone, runtime: *Runtime) !symbol.Hash {
        const snapshot = try Snapshot.load(runtime, testing.io, .cwd(), self.file_abs);
        defer snapshot.destroy();
        const ref = try symbol.Ref.parse(gpa, "add");
        defer ref.deinit(gpa);
        return (try (try snapshot.symbols()).resolve(ref)).hash;
    }

    fn propose(self: *Clone, runtime: *Runtime, body: []const u8, allow_repo_memory: bool) !runner.Result {
        return runner.tryMutate(gpa, testing.io, runtime, .{
            .file_abs = self.file_abs,
            .ref_text = "add",
            .expected_hash = .{ .present = try self.hashOfAdd(runtime) },
            .new_body = body,
            .test_command = "cmd /c exit 0",
            .allow_repo_memory = allow_repo_memory,
        });
    }

    fn proposeBatch(self: *Clone, runtime: *Runtime, allow_repo_memory: bool) !runner.BatchResult {
        const edits = [_]runner.Edit{.{ .file_abs = self.file_abs, .ref_text = "add", .expected_hash = try self.hashOfAdd(runtime), .new_body = edited_body }};
        return runner.tryMutateBatch(gpa, testing.io, runtime, .{
            .edits = &edits,
            .test_command = "cmd /c exit 0",
            .allow_repo_memory = allow_repo_memory,
        });
    }
};

test "redteam ledger: a cmd rule in a committed ledger never runs without --allow-repo-memory" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var clone = try Clone.init();
    defer clone.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    try clone.adoptMarkerRule();
    try clone.commitLedger();

    try testing.expectError(error.UntrustedRepoMemory, clone.propose(runtime, edited_body, false));
    try clone.expectNoMarker();
    try clone.expectPristine();

    try testing.expectError(error.UntrustedRepoMemory, clone.proposeBatch(runtime, false));
    try clone.expectNoMarker();
    try clone.expectPristine();
}

test "redteam ledger: a committed ledger spelled in another case is still untrusted" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var clone = try Clone.init();
    defer clone.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    try clone.adoptMarkerRule();
    try clone.commitLedgerAs(".EMETGATE/Ledger.NDJSON");

    try testing.expectError(error.UntrustedRepoMemory, clone.propose(runtime, edited_body, false));
    try clone.expectNoMarker();
    try clone.expectPristine();
}

test "redteam ledger: --allow-repo-memory lets a committed ledger's cmd rule run" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var clone = try Clone.init();
    defer clone.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    try clone.adoptMarkerRule();
    try clone.commitLedger();

    const result = try clone.propose(runtime, edited_body, true);
    defer result.deinit(gpa);
    try testing.expect(result == .committed);
    try testing.expect(clone.markerExists());
    try clone.expectEdited();
}

test "redteam ledger: --allow-repo-memory lets a committed ledger's cmd rule run in a batch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var clone = try Clone.init();
    defer clone.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    try clone.adoptMarkerRule();
    try clone.commitLedger();

    const result = try clone.proposeBatch(runtime, true);
    defer result.deinit(gpa);
    try testing.expect(result == .committed);
    try testing.expect(clone.markerExists());
    try clone.expectEdited();
}

test "redteam ledger: an untracked local ledger runs its cmd rule without the flag" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var clone = try Clone.init();
    defer clone.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    try clone.adoptMarkerRule();

    const result = try clone.propose(runtime, edited_body, false);
    defer result.deinit(gpa);
    try testing.expect(result == .committed);
    try testing.expect(clone.markerExists());
    try clone.expectEdited();
}

test "redteam ledger: static rules in a committed ledger still enforce without the flag, since they run nothing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var clone = try Clone.init();
    defer clone.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    try clone.adoptStaticRule();
    try clone.commitLedger();

    const blocked = try clone.propose(runtime, "{\n  return Math.abs(a - b);\n}", false);
    defer blocked.deinit(gpa);
    try testing.expect(blocked == .rule_violation);
    try clone.expectPristine();

    const clean = try clone.propose(runtime, edited_body, false);
    defer clean.deinit(gpa);
    try testing.expect(clean == .committed);
}

fn adoptQueryRule(clone: *Clone, check: []const u8) !void {
    const id = try memory.remember(gpa, testing.io, clone.root_abs, .global, "query rule", true, check, null);
    gpa.free(id);
}

test "redteam ledger: a q: rule in a committed ledger never runs without --allow-repo-memory" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var clone = try Clone.init();
    defer clone.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    try adoptQueryRule(&clone, "q:((statement_block" ++ " (_) @violation ." ** 7 ++ " (_) @violation) (#eq? @violation \"never\"))");
    try clone.commitLedger();

    const started = std.Io.Timestamp.now(testing.io, .awake);
    try testing.expectError(error.UntrustedRepoMemory, clone.propose(runtime, query_cases.wide_body, false));
    const elapsed_ms = started.durationTo(std.Io.Timestamp.now(testing.io, .awake)).toMilliseconds();
    try testing.expect(elapsed_ms < 10_000);
    try clone.expectPristine();
    try testing.expectError(error.UntrustedRepoMemory, clone.proposeBatch(runtime, false));
    try clone.expectPristine();
}

test "redteam ledger: --allow-repo-memory lets a committed ledger's q: rule run" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var clone = try Clone.init();
    defer clone.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    try adoptQueryRule(&clone, "q:((binary_expression operator: \"-\") @violation)");
    try clone.commitLedger();

    const single = try clone.propose(runtime, edited_body, true);
    defer single.deinit(gpa);
    try testing.expect(single == .rule_violation);
    const batch = try clone.proposeBatch(runtime, true);
    defer batch.deinit(gpa);
    try testing.expect(batch == .rule_violation);
    try clone.expectPristine();
}

test "redteam ledger: a q: rule in an untracked local ledger runs without the flag" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var clone = try Clone.init();
    defer clone.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    try adoptQueryRule(&clone, "q:((binary_expression operator: \"-\") @violation)");

    const blocked = try clone.propose(runtime, edited_body, false);
    defer blocked.deinit(gpa);
    try testing.expect(blocked == .rule_violation);
    try clone.expectPristine();
}

fn jsonEscaped(text: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, gpa, text, "\\", "\\\\");
}

fn toolCallLine(tool: []const u8, file: []const u8, hash_hex: []const u8, extra: []const u8) ![]u8 {
    const escaped = try jsonEscaped(file);
    defer gpa.free(escaped);
    if (std.mem.eql(u8, tool, "emetgate_try_batch")) {
        return std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"emetgate_try_batch\",\"arguments\":{{\"edits\":[{{\"file\":\"{s}\",\"symbol\":\"add\",\"hash\":\"{s}\",\"body\":\"{{ return a - b; }}\"}}]{s}}}}}}}", .{ escaped, hash_hex, extra });
    }
    return std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"emetgate_try\",\"arguments\":{{\"file\":\"{s}\",\"symbol\":\"add\",\"hash\":\"{s}\",\"body\":\"{{ return a - b; }}\"{s}}}}}}}", .{ escaped, hash_hex, extra });
}

fn respondWith(runtime: *Runtime, line: []const u8, policy: server.Policy) ![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    _ = try server.handleMessageObserved(gpa, testing.io, runtime, line, &buffer.writer, null, policy);
    return gpa.dupe(u8, buffer.written());
}

test "redteam ledger: the model cannot pass allow_repo_memory, and nothing runs when it tries" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var clone = try Clone.init();
    defer clone.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    try clone.adoptMarkerRule();
    try clone.commitLedger();
    const hex = symbol.formatHash(try clone.hashOfAdd(runtime));

    const policies = [_]server.Policy{
        .{ .test_command = "cmd /c exit 0", .root = clone.root_abs },
        .{ .test_command = "cmd /c exit 0", .allow_repo_memory = true, .root = clone.root_abs },
    };
    for ([_][]const u8{ "emetgate_try", "emetgate_try_batch" }) |tool| {
        for (policies) |policy| {
            for ([_][]const u8{ ",\"allow_repo_memory\":true", ",\"allow_repo_memory\":false" }) |extra| {
                const line = try toolCallLine(tool, clone.file_abs, hex[0..], extra);
                defer gpa.free(line);
                const response = try respondWith(runtime, line, policy);
                defer gpa.free(response);
                errdefer std.debug.print("{s} {s}: {s}\n", .{ tool, extra, response });
                try testing.expect(std.mem.indexOf(u8, response, "ModelSuppliedTestPolicy") != null);
                try testing.expect(std.mem.indexOf(u8, response, "\"isError\":true") != null);
                try clone.expectNoMarker();
                try clone.expectPristine();
            }
        }
    }
}

test "redteam ledger: over mcp only the flag emetgate was started with trusts a committed ledger" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    for ([_][]const u8{ "emetgate_try", "emetgate_try_batch" }) |tool| {
        var clone = try Clone.init();
        defer clone.deinit();
        try clone.adoptMarkerRule();
        try clone.commitLedger();
        const hex = symbol.formatHash(try clone.hashOfAdd(runtime));
        const line = try toolCallLine(tool, clone.file_abs, hex[0..], "");
        defer gpa.free(line);

        const refused = try respondWith(runtime, line, .{ .test_command = "cmd /c exit 0", .root = clone.root_abs });
        defer gpa.free(refused);
        errdefer std.debug.print("{s}: {s}\n", .{ tool, refused });
        try testing.expect(std.mem.indexOf(u8, refused, "UntrustedRepoMemory") != null);
        try testing.expect(std.mem.indexOf(u8, refused, "\"isError\":true") != null);
        try clone.expectNoMarker();
        try clone.expectPristine();

        const trusted = try respondWith(runtime, line, .{ .test_command = "cmd /c exit 0", .allow_repo_memory = true, .root = clone.root_abs });
        defer gpa.free(trusted);
        errdefer std.debug.print("{s}: {s}\n", .{ tool, trusted });
        try testing.expect(std.mem.indexOf(u8, trusted, "\\\"status\\\":\\\"committed\\\"") != null);
        try testing.expect(clone.markerExists());
    }
}
