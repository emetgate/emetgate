const std = @import("std");
const synapse = @import("synapse");

const ts = synapse.tree_sitter;
const skeleton = synapse.skeleton;
const symbol = synapse.symbol;
const cas = synapse.cas;
const stdio = synapse.stdio;
const runner = synapse.runner;
const wire = synapse.wire;
const server = synapse.server;
const Runtime = synapse.runtime.Runtime;
const Snapshot = synapse.loader.Snapshot;

const usage =
    \\usage: synapse skeleton <file.ts>
    \\       synapse symbols <file.ts> [--json]
    \\       synapse stats <file.ts>...
    \\       synapse mutate <file.ts> --symbol <ref> --hash <hex> (--body <code> | --body-file <path>) [--json]
    \\       synapse try <file.ts> --symbol <ref> --hash <hex> (--body <code> | --body-file <path>) --test <command> [--json]
    \\       synapse mcp
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
        const parsed = extractJson(init, args[2..]);
        const request = MutateRequest.parse(parsed.rest) orelse exitWithUsage();
        if (parsed.json) return mutateJson(init, runtime, request, out);
        try mutate(init, runtime, request, out);
        return 0;
    }
    if (std.mem.eql(u8, command, "try")) {
        const parsed = extractJson(init, args[2..]);
        const request = TryRequest.parse(parsed.rest) orelse exitWithUsage();
        if (parsed.json) return tryRunJson(init, runtime, request, out);
        return tryRun(init, runtime, request, out);
    }
    if ((std.mem.eql(u8, command, "mcp") or std.mem.eql(u8, command, "serve")) and args.len == 2) {
        try server.serve(runtime.gpa, init.io, runtime, out);
        return 0;
    }
    exitWithUsage();
}

const Extracted = struct { json: bool, rest: []const [:0]const u8 };

fn extractJson(init: std.process.Init, args: []const [:0]const u8) Extracted {
    var count: usize = 0;
    for (args) |arg| {
        if (!std.mem.eql(u8, arg, "--json")) count += 1;
    }
    if (count == args.len) return .{ .json = false, .rest = args };

    const rest = init.arena.allocator().alloc([:0]const u8, count) catch exitWithUsage();
    var i: usize = 0;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) continue;
        rest[i] = arg;
        i += 1;
    }
    return .{ .json = true, .rest = rest };
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

const try_flags = [_][]const u8{ "--symbol", "--hash", "--body", "--body-file", "--test" };

const TryRequest = struct {
    path: []const u8,
    symbol: []const u8,
    hash: []const u8,
    body: union(enum) { inline_text: []const u8, file: []const u8 },
    test_command: []const u8,

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
            .test_command = values[4] orelse return null,
        };
    }
};

fn tryRun(init: std.process.Init, runtime: *Runtime, request: TryRequest, out: *std.Io.Writer) !u8 {
    const gpa = runtime.gpa;
    const file_abs = try std.Io.Dir.cwd().realPathFileAlloc(init.io, request.path, gpa);
    defer gpa.free(file_abs);
    const expected = try symbol.parseHash(request.hash);

    const body_from_file: ?[]u8 = switch (request.body) {
        .file => |path| try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(max_body_len)),
        .inline_text => null,
    };
    defer if (body_from_file) |bytes| gpa.free(bytes);
    const body = body_from_file orelse request.body.inline_text;

    const result = try runner.tryMutate(gpa, init.io, runtime, .{
        .file_abs = file_abs,
        .ref_text = request.symbol,
        .expected_hash = expected,
        .new_body = body,
        .test_command = request.test_command,
    });
    defer result.deinit(gpa);

    _ = out;
    switch (result) {
        .committed => |new_hash| {
            std.debug.print("committed {s}  {s} -> {s}\n", .{ request.symbol, &symbol.formatHash(expected), &symbol.formatHash(new_hash) });
            return 0;
        },
        .rejected => |report| {
            std.debug.print("rejected: tests did not pass ({t})\n", .{report.outcome});
            if (report.stdout.len != 0) std.debug.print("--- stdout ---\n{s}\n", .{report.stdout});
            if (report.stderr.len != 0) std.debug.print("--- stderr ---\n{s}\n", .{report.stderr});
            return rejected_exit_code;
        },
    }
}

fn tryRunJson(init: std.process.Init, runtime: *Runtime, request: TryRequest, out: *std.Io.Writer) u8 {
    return emitTryJson(init, runtime, request, out) catch |err| {
        wire.writeError(out, @errorName(err), exitCodeFor(err)) catch {};
        return exitCodeFor(err);
    };
}

fn emitTryJson(init: std.process.Init, runtime: *Runtime, request: TryRequest, out: *std.Io.Writer) !u8 {
    const gpa = runtime.gpa;
    const file_abs = try std.Io.Dir.cwd().realPathFileAlloc(init.io, request.path, gpa);
    defer gpa.free(file_abs);
    const expected = try symbol.parseHash(request.hash);

    const body_from_file: ?[]u8 = switch (request.body) {
        .file => |path| try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(max_body_len)),
        .inline_text => null,
    };
    defer if (body_from_file) |bytes| gpa.free(bytes);
    const body = body_from_file orelse request.body.inline_text;

    const result = try runner.tryMutate(gpa, init.io, runtime, .{
        .file_abs = file_abs,
        .ref_text = request.symbol,
        .expected_hash = expected,
        .new_body = body,
        .test_command = request.test_command,
    });
    defer result.deinit(gpa);

    switch (result) {
        .committed => |new_hash| {
            try wire.writeCommitted(out, request.symbol, expected, new_hash);
            return 0;
        },
        .rejected => |report| {
            try wire.writeRejected(out, request.test_command, report);
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
    const expected = try symbol.parseHash(request.hash);

    const base = try Snapshot.load(runtime, init.io, .cwd(), request.path);
    defer base.destroy();
    if (base.tree.root().hasError()) return error.SourceHasErrors;

    const body_from_file: ?[]u8 = switch (request.body) {
        .file => |path| try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(max_body_len)),
        .inline_text => null,
    };
    defer if (body_from_file) |bytes| gpa.free(bytes);
    const body = body_from_file orelse request.body.inline_text;

    const applied = try cas.apply(base, .{ .ref = ref, .expected_hash = expected, .new_body = body });
    defer applied.snapshot.destroy();

    try wire.writeMutated(out, request.symbol, expected, applied.hash, applied.snapshot.source);
}

fn printSkeleton(init: std.process.Init, runtime: *Runtime, path: []const u8, out: *std.Io.Writer) !void {
    const snapshot = try Snapshot.load(runtime, init.io, .cwd(), path);
    defer snapshot.destroy();
    const text = try skeleton.skeletonize(runtime.gpa, runtime.parser, snapshot.tree);
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
    const expected = try symbol.parseHash(request.hash);

    const base = try Snapshot.load(runtime, init.io, .cwd(), request.path);
    defer base.destroy();
    if (base.tree.root().hasError()) return error.SourceHasErrors;

    const body_from_file: ?[]u8 = switch (request.body) {
        .file => |path| try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(max_body_len)),
        .inline_text => null,
    };
    defer if (body_from_file) |bytes| gpa.free(bytes);
    const body = body_from_file orelse request.body.inline_text;

    const applied = try cas.apply(base, .{ .ref = ref, .expected_hash = expected, .new_body = body });
    defer applied.snapshot.destroy();

    try out.writeAll(applied.snapshot.source);
    try out.flush();
    std.debug.print("mutated {f}  {s} -> {s}\n", .{ ref, &symbol.formatHash(expected), &symbol.formatHash(applied.hash) });
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

        const text = skeleton.skeletonize(runtime.gpa, runtime.parser, snapshot.tree) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try out.print("{s}  skipped: {t}\n", .{ path, err });
                totals.skipped += 1;
                continue;
            },
        };
        defer runtime.gpa.free(text);
        const reparsed = try runtime.parser.parse(text);
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
