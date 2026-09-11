const std = @import("std");
const synapse = @import("synapse");

const ts = synapse.tree_sitter;
const skeleton = synapse.skeleton;
const symbol = synapse.symbol;
const cas = synapse.cas;
const Document = synapse.loader.Document;

const usage =
    \\usage: synapse skeleton <file.ts>
    \\       synapse symbols <file.ts>
    \\       synapse stats <file.ts>...
    \\       synapse mutate <file.ts> --symbol <ref> --hash <hex> (--body <code> | --body-file <path>)
    \\
;

const max_body_len = std.math.maxInt(u32);

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) exitWithUsage();

    var buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    synapse.alloc_bridge.install(init.gpa);
    defer synapse.alloc_bridge.uninstall();
    const parser = try ts.Parser.init(ts.typescript());
    defer parser.deinit();

    const command = args[1];
    if (std.mem.eql(u8, command, "skeleton") and args.len == 3) {
        try printSkeleton(init, parser, args[2], out);
        return 0;
    }
    if (std.mem.eql(u8, command, "symbols") and args.len == 3) {
        try printSymbols(init, parser, args[2], out);
        return 0;
    }
    if (std.mem.eql(u8, command, "stats")) {
        const skipped = try printStats(init, parser, args[2..], out);
        return if (skipped == 0) 0 else 1;
    }
    if (std.mem.eql(u8, command, "mutate")) {
        const request = MutateRequest.parse(args[2..]) orelse exitWithUsage();
        mutate(init, parser, request, out) catch |err| {
            std.debug.print("error: {t}\n", .{err});
            return exitCodeFor(err);
        };
        return 0;
    }
    exitWithUsage();
}

fn exitWithUsage() noreturn {
    std.debug.print("{s}", .{usage});
    std.process.exit(2);
}

fn printSkeleton(init: std.process.Init, parser: ts.Parser, path: []const u8, out: *std.Io.Writer) !void {
    const doc = try Document.open(init.gpa, init.io, .cwd(), path, parser);
    defer doc.deinit();
    const text = try skeleton.skeletonize(init.gpa, parser, doc.tree);
    defer init.gpa.free(text);
    try out.writeAll(text);
}

fn printSymbols(init: std.process.Init, parser: ts.Parser, path: []const u8, out: *std.Io.Writer) !void {
    const doc = try Document.open(init.gpa, init.io, .cwd(), path, parser);
    defer doc.deinit();
    const table = try symbol.Table.build(init.gpa, doc.tree);
    defer table.deinit();

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

const MutateRequest = struct {
    path: []const u8,
    symbol: []const u8,
    hash: []const u8,
    body: union(enum) { inline_text: []const u8, file: []const u8 },

    fn parse(args: []const [:0]const u8) ?MutateRequest {
        if (args.len == 0 or args.len % 2 == 0) return null;
        var symbol_arg: ?[]const u8 = null;
        var hash_arg: ?[]const u8 = null;
        var body_arg: ?[]const u8 = null;
        var body_file_arg: ?[]const u8 = null;

        var i: usize = 1;
        while (i < args.len) : (i += 2) {
            const slot = flagSlot(args[i], &symbol_arg, &hash_arg, &body_arg, &body_file_arg) orelse return null;
            if (slot.* != null) return null;
            slot.* = args[i + 1];
        }

        const body: @FieldType(MutateRequest, "body") = if (body_arg) |text|
            if (body_file_arg == null) .{ .inline_text = text } else return null
        else
            .{ .file = body_file_arg orelse return null };
        return .{
            .path = args[0],
            .symbol = symbol_arg orelse return null,
            .hash = hash_arg orelse return null,
            .body = body,
        };
    }

    fn flagSlot(
        flag: []const u8,
        symbol_arg: *?[]const u8,
        hash_arg: *?[]const u8,
        body_arg: *?[]const u8,
        body_file_arg: *?[]const u8,
    ) ?*?[]const u8 {
        if (std.mem.eql(u8, flag, "--symbol")) return symbol_arg;
        if (std.mem.eql(u8, flag, "--hash")) return hash_arg;
        if (std.mem.eql(u8, flag, "--body")) return body_arg;
        if (std.mem.eql(u8, flag, "--body-file")) return body_file_arg;
        return null;
    }
};

fn mutate(init: std.process.Init, parser: ts.Parser, request: MutateRequest, out: *std.Io.Writer) !void {
    const gpa = init.gpa;
    const ref = try symbol.Ref.parse(gpa, request.symbol);
    defer ref.deinit(gpa);
    const expected = try symbol.parseHash(request.hash);

    const body_from_file: ?[]u8 = switch (request.body) {
        .file => |path| try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(max_body_len)),
        .inline_text => null,
    };
    defer if (body_from_file) |bytes| gpa.free(bytes);
    const body = body_from_file orelse request.body.inline_text;

    const doc = try Document.open(gpa, init.io, .cwd(), request.path, parser);
    defer doc.deinit();
    const patched = try cas.apply(gpa, parser, doc.tree, .{ .ref = ref, .expected_hash = expected, .new_body = body });
    defer patched.deinit();

    try out.writeAll(patched.source);
    std.debug.print("mutated {f}  {s} -> {s}\n", .{ ref, &symbol.formatHash(expected), &symbol.formatHash(patched.hash) });
}

fn exitCodeFor(err: anyerror) u8 {
    return switch (err) {
        error.InvalidRef, error.InvalidHash => 2,
        error.SourceHasErrors => 3,
        error.SymbolNotFound => 4,
        error.AmbiguousSymbol => 5,
        error.HashMismatch => 6,
        error.MutationSyntaxInvalid => 7,
        error.BodyEscape => 8,
        else => 1,
    };
}

const Totals = struct {
    before: skeleton.Metrics = .{ .bytes = 0, .tokens = 0 },
    after: skeleton.Metrics = .{ .bytes = 0, .tokens = 0 },
    files: usize = 0,
    skipped: usize = 0,
};

fn printStats(init: std.process.Init, parser: ts.Parser, paths: []const [:0]const u8, out: *std.Io.Writer) !usize {
    var totals: Totals = .{};
    for (paths) |path| {
        const doc = Document.open(init.gpa, init.io, .cwd(), path, parser) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try out.print("{s}  skipped: {t}\n", .{ path, err });
                totals.skipped += 1;
                continue;
            },
        };
        defer doc.deinit();

        const text = skeleton.skeletonize(init.gpa, parser, doc.tree) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try out.print("{s}  skipped: {t}\n", .{ path, err });
                totals.skipped += 1;
                continue;
            },
        };
        defer init.gpa.free(text);
        const reparsed = try parser.parse(text);
        defer reparsed.deinit();

        const before = skeleton.measure(doc.tree);
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
