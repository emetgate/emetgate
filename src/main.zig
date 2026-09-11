const std = @import("std");
const synapse = @import("synapse");

const ts = synapse.tree_sitter;
const skeleton = synapse.skeleton;
const Document = synapse.loader.Document;

const usage =
    \\usage: synapse skeleton <file.ts>
    \\       synapse stats <file.ts>...
    \\
;

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
    if (std.mem.eql(u8, command, "stats")) {
        const skipped = try printStats(init, parser, args[2..], out);
        return if (skipped == 0) 0 else 1;
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
