const std = @import("std");
const emetgate = @import("emetgate");

const ts = emetgate.tree_sitter;
const skeleton = emetgate.skeleton;
const symbol = emetgate.symbol;
const cas = emetgate.cas;
const stdio = emetgate.stdio;
const runner = emetgate.runner;
const wire = emetgate.wire;
const server = emetgate.server;
const disk = emetgate.disk;
const shadow = emetgate.shadow;
const lockdown = emetgate.lockdown;
const scan_command = emetgate.scan_command;
const Runtime = emetgate.runtime.Runtime;
const Snapshot = emetgate.loader.Snapshot;

const usage =
    \\usage: emetgate skeleton <file.ts>
    \\       emetgate symbols <file.ts> [--json]
    \\       emetgate stats <file.ts>...
    \\       emetgate mutate <file.ts> --symbol <ref> --hash (<hex> | absent) (--body <code> | --body-file <path>) [--json]
    \\       emetgate try <file.ts> --symbol <ref> --hash (<hex> | absent) (--body <code> | --body-file <path>) [--test <command>] [--typecheck <command>] [--allow-repo-config] [--json]
    \\       emetgate mcp [--test <command>] [--typecheck <command>] [--allow-repo-config]
    \\       emetgate scan [--check <spec> [--in <where>]] [--json]
    \\       emetgate recover
    \\       emetgate lockdown [<claude args>...]
    \\
    \\lockdown starts claude with only ToolSearch and the .mcp.json servers
    \\(--tools ToolSearch --mcp-config .mcp.json --strict-mcp-config).
    \\The lock is per launch: a claude started without emetgate lockdown is unlocked.
    \\
;

const max_body_len = std.math.maxInt(u32);

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) exitWithUsage();

    var buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .initStreaming(stdio.stdout(), init.io, &buffer);
    const out = &stdout_writer.interface;

    const runtime = try Runtime.create(init.gpa);
    defer runtime.destroy() catch |err| std.debug.panic("runtime closed with live allocations: {t}", .{err});

    const status = dispatch(init, runtime, args, out) catch |err| return fail(err);
    out.flush() catch |err| return fail(err);
    return status;
}

fn dispatch(init: std.process.Init, runtime: *Runtime, args: []const [:0]const u8, out: *std.Io.Writer) !u8 {
    const command = args[1];
    if (std.mem.eql(u8, command, "skeleton") and args.len == 3) {
        try printSkeleton(init, runtime, args[2], out);
        return 0;
    }
    if (std.mem.eql(u8, command, "symbols")) {
        if (args.len == 3) {
            try printSymbols(init, runtime, args[2], out);
            return 0;
        }
        if (args.len == 4 and std.mem.eql(u8, args[3], "--json")) {
            return symbolsJson(init, runtime, args[2], out);
        }
        exitWithUsage();
    }
    if (std.mem.eql(u8, command, "stats")) {
        const skipped = try printStats(init, runtime, args[2..], out);
        return if (skipped == 0) 0 else 1;
    }
    if (std.mem.eql(u8, command, "mutate")) {
        const parsed = extractFlags(init, args[2..]);
        const request = MutateRequest.parse(parsed.rest) orelse exitWithUsage();
        if (parsed.json) return mutateJson(init, runtime, request, out);
        try mutate(init, runtime, request, out);
        return 0;
    }
    if (std.mem.eql(u8, command, "try")) {
        const parsed = extractFlags(init, args[2..]);
        const request = TryRequest.parse(parsed.rest) orelse exitWithUsage();
        if (parsed.json) return tryRunJson(init, runtime, request, out, parsed.allow_repo_config);
        return tryRun(init, runtime, request, out, parsed.allow_repo_config);
    }
    if (std.mem.eql(u8, command, "mcp") or std.mem.eql(u8, command, "serve")) {
        const policy = server.parsePolicy(args[2..]) orelse exitWithUsage();
        try server.serve(runtime.gpa, init.io, runtime, out, policy);
        return 0;
    }
    if (std.mem.eql(u8, command, "scan")) {
        const options = scan_command.Options.parse(args[2..]) orelse exitWithUsage();
        return scanCmd(init, runtime, options, out);
    }
    if (std.mem.eql(u8, command, "recover") and args.len == 2) {
        return recoverCmd(init, runtime);
    }
    if (std.mem.eql(u8, command, "lockdown")) {
        const passthrough = try init.arena.allocator().alloc([]const u8, args.len - 2);
        for (args[2..], 0..) |arg, i| passthrough[i] = arg;
        return lockdown.launch(runtime.gpa, init.io, passthrough);
    }
    exitWithUsage();
}

const Extracted = struct { json: bool, allow_repo_config: bool, rest: []const [:0]const u8 };

fn isBoolFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "--allow-repo-config");
}

fn extractFlags(init: std.process.Init, args: []const [:0]const u8) Extracted {
    var json = false;
    var allow_repo_config = false;
    var count: usize = 0;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) json = true;
        if (std.mem.eql(u8, arg, "--allow-repo-config")) allow_repo_config = true;
        if (!isBoolFlag(arg)) count += 1;
    }
    if (count == args.len) return .{ .json = false, .allow_repo_config = false, .rest = args };

    const rest = init.arena.allocator().alloc([:0]const u8, count) catch exitWithUsage();
    var i: usize = 0;
    for (args) |arg| {
        if (isBoolFlag(arg)) continue;
        rest[i] = arg;
        i += 1;
    }
    return .{ .json = json, .allow_repo_config = allow_repo_config, .rest = rest };
}

fn fail(err: anyerror) u8 {
    std.debug.print("error: {t}\n", .{err});
    return exitCodeFor(err);
}

fn exitWithUsage() noreturn {
    std.debug.print("{s}", .{usage});
    std.process.exit(2);
}

const exitCodeFor = wire.exitCode;

const rejected_exit_code: u8 = 10;

const try_flags = [_][]const u8{ "--symbol", "--hash", "--body", "--body-file", "--test", "--typecheck" };

const TryRequest = struct {
    path: []const u8,
    symbol: []const u8,
    hash: []const u8,
    body: union(enum) { inline_text: []const u8, file: []const u8 },
    test_command: []const u8,
    typecheck_command: []const u8,

    fn parse(args: []const [:0]const u8) ?TryRequest {
        if (args.len == 0 or args.len % 2 == 0) return null;
        var values: [try_flags.len]?[]const u8 = @splat(null);

        var i: usize = 1;
        while (i < args.len) : (i += 2) {
            const slot = flagIndex(&try_flags, args[i]) orelse return null;
            if (values[slot] != null or flagIndex(&try_flags, args[i + 1]) != null) return null;
            values[slot] = args[i + 1];
        }

        const inline_body = values[2];
        const body_file = values[3];
        if ((inline_body == null) == (body_file == null)) return null;
        return .{
            .path = args[0],
            .symbol = values[0] orelse return null,
            .hash = values[1] orelse return null,
            .body = if (inline_body) |text| .{ .inline_text = text } else .{ .file = body_file.? },
            .test_command = values[4] orelse "",
            .typecheck_command = values[5] orelse "",
        };
    }
};

fn tryRun(init: std.process.Init, runtime: *Runtime, request: TryRequest, out: *std.Io.Writer, allow_repo_config: bool) !u8 {
    const gpa = runtime.gpa;
    const expected = try symbol.parseExpected(request.hash);
    const target = try newFileTarget(init, gpa, request.path, expected);
    defer if (target) |place| place.deinit(gpa);
    const file_abs: [:0]const u8 = if (target) |place| try gpa.dupeZ(u8, place.abs) else try std.Io.Dir.cwd().realPathFileAlloc(init.io, request.path, gpa);
    defer gpa.free(file_abs);

    const body_from_file: ?[]u8 = switch (request.body) {
        .file => |path| try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(max_body_len)),
        .inline_text => null,
    };
    defer if (body_from_file) |bytes| gpa.free(bytes);
    const body = body_from_file orelse request.body.inline_text;

    const test_command = try runner.resolveTestCommand(gpa, init.io, file_abs, request.test_command, allow_repo_config);
    defer gpa.free(test_command);
    const typecheck_command = try runner.resolveTypecheckCommand(gpa, init.io, file_abs, request.typecheck_command, allow_repo_config);
    defer if (typecheck_command) |command| gpa.free(command);

    const result = runner.tryMutate(gpa, init.io, runtime, .{
        .file_abs = file_abs,
        .ref_text = request.symbol,
        .expected_hash = expected,
        .new_body = body,
        .test_command = test_command,
        .typecheck_command = typecheck_command,
    }) catch |err| {
        if (err == error.WrittenButNotIndexed) std.debug.print("error: WrittenButNotIndexed: {s}: {s}\nrun: git add -- {s}\n", .{ request.path, wire.not_indexed_message, request.path });
        return err;
    };
    defer result.deinit(gpa);

    _ = out;
    switch (result) {
        .committed => |new_hash| {
            var old_buf: [symbol.hash_hex_len]u8 = undefined;
            std.debug.print("committed {s}  {s} -> {s}\n", .{ request.symbol, expected.text(&old_buf), &symbol.formatHash(new_hash) });
            return 0;
        },
        .rule_violation => |report| {
            for (report.violations) |v| std.debug.print("rejected: rule {s} ({s}) at {s}:{d}:{d}: {s}\n", .{ v.rule, v.check, v.file, v.line, v.col, v.text });
            return rejected_exit_code;
        },
        .typecheck_failed => |report| {
            std.debug.print("rejected: typecheck did not pass ({t})\n", .{report.outcome});
            if (report.stdout.len != 0) std.debug.print("--- stdout ---\n{s}\n", .{report.stdout});
            if (report.stderr.len != 0) std.debug.print("--- stderr ---\n{s}\n", .{report.stderr});
            return rejected_exit_code;
        },
        .rejected => |report| {
            std.debug.print("rejected: tests did not pass ({t})\n", .{report.outcome});
            if (report.stdout.len != 0) std.debug.print("--- stdout ---\n{s}\n", .{report.stdout});
            if (report.stderr.len != 0) std.debug.print("--- stderr ---\n{s}\n", .{report.stderr});
            return rejected_exit_code;
        },
    }
}

fn tryRunJson(init: std.process.Init, runtime: *Runtime, request: TryRequest, out: *std.Io.Writer, allow_repo_config: bool) u8 {
    return emitTryJson(init, runtime, request, out, allow_repo_config) catch |err| {
        if (err == error.WrittenButNotIndexed) {
            wire.writeNotIndexed(out, request.path) catch {};
        } else {
            wire.writeError(out, @errorName(err), exitCodeFor(err)) catch {};
        }
        return exitCodeFor(err);
    };
}

fn newFileTarget(init: std.process.Init, gpa: std.mem.Allocator, path: []const u8, expected: symbol.Expected) !?runner.Jailed {
    if (expected != .absent) return null;
    std.Io.Dir.cwd().access(init.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return try runner.jailNew(gpa, init.io, null, path),
        else => |e| return e,
    };
    return null;
}

fn emitTryJson(init: std.process.Init, runtime: *Runtime, request: TryRequest, out: *std.Io.Writer, allow_repo_config: bool) !u8 {
    const gpa = runtime.gpa;
    const expected = try symbol.parseExpected(request.hash);
    const target = try newFileTarget(init, gpa, request.path, expected);
    defer if (target) |place| place.deinit(gpa);
    const file_abs: [:0]const u8 = if (target) |place| try gpa.dupeZ(u8, place.abs) else try std.Io.Dir.cwd().realPathFileAlloc(init.io, request.path, gpa);
    defer gpa.free(file_abs);

    const body_from_file: ?[]u8 = switch (request.body) {
        .file => |path| try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(max_body_len)),
        .inline_text => null,
    };
    defer if (body_from_file) |bytes| gpa.free(bytes);
    const body = body_from_file orelse request.body.inline_text;

    const test_command = try runner.resolveTestCommand(gpa, init.io, file_abs, request.test_command, allow_repo_config);
    defer gpa.free(test_command);
    const typecheck_command = try runner.resolveTypecheckCommand(gpa, init.io, file_abs, request.typecheck_command, allow_repo_config);
    defer if (typecheck_command) |command| gpa.free(command);

    const result = try runner.tryMutate(gpa, init.io, runtime, .{
        .file_abs = file_abs,
        .ref_text = request.symbol,
        .expected_hash = expected,
        .new_body = body,
        .test_command = test_command,
        .typecheck_command = typecheck_command,
    });
    defer result.deinit(gpa);

    switch (result) {
        .committed => |new_hash| {
            try wire.writeCommitted(out, request.symbol, expected, new_hash);
            return 0;
        },
        .rejected => |report| {
            try wire.writeRejected(gpa, out, test_command, report);
            return rejected_exit_code;
        },
        .typecheck_failed => |report| {
            try wire.writeTypecheckRejected(gpa, out, typecheck_command.?, report);
            return rejected_exit_code;
        },
        .rule_violation => |report| {
            try wire.writeRuleViolation(out, report);
            return rejected_exit_code;
        },
    }
}

fn mutateJson(init: std.process.Init, runtime: *Runtime, request: MutateRequest, out: *std.Io.Writer) u8 {
    emitMutateJson(init, runtime, request, out) catch |err| {
        wire.writeError(out, @errorName(err), exitCodeFor(err)) catch {};
        return exitCodeFor(err);
    };
    return 0;
}

fn emitMutateJson(init: std.process.Init, runtime: *Runtime, request: MutateRequest, out: *std.Io.Writer) !void {
    const gpa = runtime.gpa;
    const ref = try symbol.Ref.parse(gpa, request.symbol);
    defer ref.deinit(gpa);
    const expected = try symbol.parseExpected(request.hash);
    const target = try newFileTarget(init, gpa, request.path, expected);
    defer if (target) |place| place.deinit(gpa);

    const base: ?*Snapshot = if (target == null) try Snapshot.load(runtime, init.io, .cwd(), request.path) else null;
    defer if (base) |snapshot| snapshot.destroy();
    if (base) |snapshot| if (snapshot.tree.root().hasError()) return error.SourceHasErrors;

    const body_from_file: ?[]u8 = switch (request.body) {
        .file => |path| try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(max_body_len)),
        .inline_text => null,
    };
    defer if (body_from_file) |bytes| gpa.free(bytes);
    const body = body_from_file orelse request.body.inline_text;

    const applied = if (target) |place|
        try runner.prepareCreate(gpa, init.io, runtime, place.root, place.abs, place.rel, ref, body)
    else
        try cas.propose(base.?, ref, expected, body);
    defer applied.snapshot.destroy();

    try wire.writeMutated(out, request.symbol, expected, applied.hash, applied.snapshot.source);
}

fn scanCmd(init: std.process.Init, runtime: *Runtime, options: scan_command.Options, out: *std.Io.Writer) !u8 {
    const gpa = runtime.gpa;
    const root = runner.repoRoot(gpa, init.io) catch |err| {
        if (options.json) {
            try wire.writeError(out, @errorName(err), exitCodeFor(err));
            return exitCodeFor(err);
        }
        return err;
    };
    defer gpa.free(root);
    var buffer: [4096]u8 = undefined;
    var stderr_writer: std.Io.File.Writer = .initStreaming(std.Io.File.stderr(), init.io, &buffer);
    const code = try scan_command.run(gpa, init.io, runtime, root, options, out, &stderr_writer.interface);
    try stderr_writer.interface.flush();
    return code;
}

const recover_failed_exit_code: u8 = 16;

fn recoverCmd(init: std.process.Init, runtime: *Runtime) !u8 {
    const gpa = runtime.gpa;
    const root = try runner.repoRoot(gpa, init.io);
    defer gpa.free(root);
    const lock = try shadow.Lock.acquire(init.io, root);
    defer lock.release();

    const report = try disk.recover(gpa, init.io, root);
    const shadow_abs = try std.fmt.allocPrint(gpa, "{s}\\{s}\\shadow", .{ root, shadow.workspace_dir });
    defer gpa.free(shadow_abs);
    shadow.remove(init.io, root, shadow_abs) catch {};

    std.debug.print("recovered {d} file(s), removed {d} orphaned temp file(s), skipped {d}, failed {d}\n", .{ report.restored, report.removed_temps, report.skipped, report.failed });
    return if (report.failed > 0) recover_failed_exit_code else 0;
}

fn printSkeleton(init: std.process.Init, runtime: *Runtime, path: []const u8, out: *std.Io.Writer) !void {
    const snapshot = try Snapshot.load(runtime, init.io, .cwd(), path);
    defer snapshot.destroy();
    const text = try skeleton.skeletonize(runtime.gpa, runtime.parser, snapshot.profile, snapshot.tree);
    defer runtime.gpa.free(text);
    try out.writeAll(text);
}

fn symbolsJson(init: std.process.Init, runtime: *Runtime, path: []const u8, out: *std.Io.Writer) u8 {
    emitSymbolsJson(init, runtime, path, out) catch |err| {
        wire.writeError(out, @errorName(err), exitCodeFor(err)) catch {};
        return exitCodeFor(err);
    };
    return 0;
}

fn emitSymbolsJson(init: std.process.Init, runtime: *Runtime, path: []const u8, out: *std.Io.Writer) !void {
    const snapshot = try Snapshot.load(runtime, init.io, .cwd(), path);
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    try wire.writeSymbols(runtime.gpa, out, path, table.*);
}

fn printSymbols(init: std.process.Init, runtime: *Runtime, path: []const u8, out: *std.Io.Writer) !void {
    const snapshot = try Snapshot.load(runtime, init.io, .cwd(), path);
    defer snapshot.destroy();
    const table = try snapshot.symbols();

    for (table.symbols) |entry| {
        const point = entry.node.startPoint();
        try out.print("{s}  L{d}:{d}  {t}  {f}{s}\n", .{
            &symbol.formatHash(entry.hash),
            point.row + 1,
            point.column + 1,
            entry.kind,
            entry.ref,
            if (entry.ambiguous) "  (ambiguous)" else "",
        });
    }
}

const flags = [_][]const u8{ "--symbol", "--hash", "--body", "--body-file" };

const MutateRequest = struct {
    path: []const u8,
    symbol: []const u8,
    hash: []const u8,
    body: union(enum) { inline_text: []const u8, file: []const u8 },

    fn parse(args: []const [:0]const u8) ?MutateRequest {
        if (args.len == 0 or args.len % 2 == 0) return null;
        var values: [flags.len]?[]const u8 = @splat(null);

        var i: usize = 1;
        while (i < args.len) : (i += 2) {
            const slot = flagIndex(&flags, args[i]) orelse return null;
            if (values[slot] != null or flagIndex(&flags, args[i + 1]) != null) return null;
            values[slot] = args[i + 1];
        }

        const inline_body = values[2];
        const body_file = values[3];
        if ((inline_body == null) == (body_file == null)) return null;
        return .{
            .path = args[0],
            .symbol = values[0] orelse return null,
            .hash = values[1] orelse return null,
            .body = if (inline_body) |text| .{ .inline_text = text } else .{ .file = body_file.? },
        };
    }
};

fn flagIndex(list: []const []const u8, arg: []const u8) ?usize {
    for (list, 0..) |flag, index| {
        if (std.mem.eql(u8, flag, arg)) return index;
    }
    return null;
}

fn mutate(init: std.process.Init, runtime: *Runtime, request: MutateRequest, out: *std.Io.Writer) !void {
    const gpa = runtime.gpa;
    const ref = try symbol.Ref.parse(gpa, request.symbol);
    defer ref.deinit(gpa);
    const expected = try symbol.parseExpected(request.hash);
    const target = try newFileTarget(init, gpa, request.path, expected);
    defer if (target) |place| place.deinit(gpa);

    const base: ?*Snapshot = if (target == null) try Snapshot.load(runtime, init.io, .cwd(), request.path) else null;
    defer if (base) |snapshot| snapshot.destroy();
    if (base) |snapshot| if (snapshot.tree.root().hasError()) return error.SourceHasErrors;

    const body_from_file: ?[]u8 = switch (request.body) {
        .file => |path| try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(max_body_len)),
        .inline_text => null,
    };
    defer if (body_from_file) |bytes| gpa.free(bytes);
    const body = body_from_file orelse request.body.inline_text;

    const applied = if (target) |place|
        try runner.prepareCreate(gpa, init.io, runtime, place.root, place.abs, place.rel, ref, body)
    else
        try cas.propose(base.?, ref, expected, body);
    defer applied.snapshot.destroy();

    try out.writeAll(applied.snapshot.source);
    try out.flush();
    var old_buf: [symbol.hash_hex_len]u8 = undefined;
    std.debug.print("mutated {f}  {s} -> {s}\n", .{ ref, expected.text(&old_buf), &symbol.formatHash(applied.hash) });
}

const Totals = struct {
    before: skeleton.Metrics = .{ .bytes = 0, .tokens = 0 },
    after: skeleton.Metrics = .{ .bytes = 0, .tokens = 0 },
    files: usize = 0,
    skipped: usize = 0,
};

fn printStats(init: std.process.Init, runtime: *Runtime, paths: []const [:0]const u8, out: *std.Io.Writer) !usize {
    var totals: Totals = .{};
    for (paths) |path| {
        const snapshot = Snapshot.load(runtime, init.io, .cwd(), path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try out.print("{s}  skipped: {t}\n", .{ path, err });
                totals.skipped += 1;
                continue;
            },
        };
        defer snapshot.destroy();

        const text = skeleton.skeletonize(runtime.gpa, runtime.parser, snapshot.profile, snapshot.tree) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try out.print("{s}  skipped: {t}\n", .{ path, err });
                totals.skipped += 1;
                continue;
            },
        };
        defer runtime.gpa.free(text);
        const reparsed = try runtime.parser.parseIn(snapshot.tree.language(), text);
        defer reparsed.deinit();

        const before = skeleton.measure(snapshot.tree);
        const after = skeleton.measure(reparsed);
        try printRow(out, path, before, after);
        totals.before.bytes += before.bytes;
        totals.before.tokens += before.tokens;
        totals.after.bytes += after.bytes;
        totals.after.tokens += after.tokens;
        totals.files += 1;
    }
    try out.print("\n{d} files, {d} skipped\n", .{ totals.files, totals.skipped });
    try printRow(out, "TOTAL", totals.before, totals.after);
    return totals.skipped;
}

fn printRow(out: *std.Io.Writer, label: []const u8, before: skeleton.Metrics, after: skeleton.Metrics) !void {
    try out.print("{s}  bytes {d} -> {d} (-{d:.1}%)  tokens {d} -> {d} (-{d:.1}%)\n", .{
        label,
        before.bytes,
        after.bytes,
        reduction(before.bytes, after.bytes),
        before.tokens,
        after.tokens,
        reduction(before.tokens, after.tokens),
    });
}

fn reduction(before: usize, after: usize) f64 {
    if (before == 0) return 0;
    const b: f64 = @floatFromInt(before);
    const a: f64 = @floatFromInt(after);
    return (b - a) / b * 100;
}
