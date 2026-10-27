//! Column ③ — Provable history chain.
//!
//! Walks the commits in `base..head` (oldest first), replays every commit's
//! receipt verification through the existing single-commit `verify_run.run`,
//! and binds the per-commit certificates into a tamper-evident hash chain:
//! each link's certificate hash folds in its parent link's certificate, so
//! rewriting any commit or its receipt note changes every later hash.
//!
//! Fail-closed: a commit with no receipt, or one that fails to verify, is
//! reported honestly as `partial`/`broken`. There is no fabricated green.

const std = @import("std");
const receipt = @import("../verify/receipt.zig");
const checker = @import("../verify/checker.zig");
const receipts = @import("receipts.zig");
const verify_run = @import("verify_run.zig");
const sandbox = @import("sandbox.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Hash = receipt.Hash;

const max_commits = 1000;

pub const Options = struct {
    /// Exclusive lower bound (a ref or oid). Empty means the whole history.
    base: []const u8 = "",
    /// Inclusive upper bound.
    head: []const u8 = "HEAD",
    test_command: ?[]const u8 = null,
    typecheck_command: ?[]const u8 = null,
    skip_tests: bool = false,
    limits: sandbox.Limits = .{},
};

/// Overall verdict for the range.
pub const BranchVerdict = enum {
    verified, // every commit carried a receipt and verified
    partial, // at least one commit has no receipt or is only unverified
    broken, // at least one commit's receipt actively mismatched
    empty,

    pub fn worse(self: BranchVerdict, other: BranchVerdict) BranchVerdict {
        return if (@intFromEnum(other) > @intFromEnum(self)) other else self;
    }
};

pub const Link = struct {
    commit: []const u8,
    parent: ?[]const u8,
    verdict: checker.Verdict,
    has_receipt: bool,
    /// Hash-chain certificate: folds in the parent link's certificate.
    cert: Hash,
    report: verify_run.Result,
};

pub const Result = struct {
    links: []Link,
    verdict: BranchVerdict,
    /// Certificate of the tip link — the root of trust for the whole range.
    tip: Hash,
    count: usize,
};

/// `spec` is either `base..head` or a bare `base` (meaning `base..HEAD`).
pub fn parseRange(spec: []const u8) Options {
    if (std.mem.indexOf(u8, spec, "..")) |at| {
        return .{ .base = spec[0..at], .head = spec[at + 2 ..] };
    }
    return .{ .base = spec, .head = "HEAD" };
}

fn revList(arena: Allocator, io: std.Io, root: []const u8, base: []const u8, head: []const u8) ![]const []const u8 {
    const range = if (base.len == 0)
        try arena.dupe(u8, head)
    else
        try std.fmt.allocPrint(arena, "{s}..{s}", .{ base, head });
    const out = (try receipts.git(arena, io, root, &.{ "rev-list", "--reverse", range })) orelse return error.UnknownRange;
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, out, " \r\n");
    while (it.next()) |oid| try list.append(arena, oid);
    if (list.items.len > max_commits) return error.RangeTooLong;
    return list.items;
}

/// cert_i = blake3( parent_cert ‖ oid ‖ 0x00 ‖ verdict-tag ‖ 0x00 ‖ note-bytes )
/// The genesis parent_cert is all-zero.
fn certify(arena: Allocator, parent: Hash, oid: []const u8, verdict: checker.Verdict, note: ?[]const u8) !Hash {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, &parent);
    try buf.appendSlice(arena, oid);
    try buf.append(arena, 0);
    try buf.appendSlice(arena, @tagName(verdict));
    try buf.append(arena, 0);
    if (note) |bytes| try buf.appendSlice(arena, bytes);
    return receipt.blake3(buf.items);
}

fn fold(branch: BranchVerdict, link_verdict: checker.Verdict, has_receipt: bool) BranchVerdict {
    const contribution: BranchVerdict = switch (link_verdict) {
        .verified, .merged => .verified,
        .mismatch => .broken,
        .unverified => .partial,
    };
    // A missing receipt can never be better than partial, even if nothing else
    // flagged the commit.
    const floored = if (!has_receipt) contribution.worse(.partial) else contribution;
    return branch.worse(floored);
}

pub fn run(gpa: Allocator, arena: Allocator, io: std.Io, runtime: *Runtime, root: []const u8, options: Options) !Result {
    _ = gpa;
    const oids = try revList(arena, io, root, options.base, options.head);
    var links: std.ArrayList(Link) = .empty;
    var branch: BranchVerdict = .verified;
    var prev: Hash = @splat(0);
    for (oids) |oid| {
        const result = try verify_run.run(undefined, arena, io, runtime, root, .{
            .commit = oid,
            .test_command = options.test_command,
            .typecheck_command = options.typecheck_command,
            .skip_tests = options.skip_tests,
            .limits = options.limits,
        });
        const note = receipts.noteBytes(arena, io, root, oid) catch null;
        const has_receipt = note != null and result.report.receipts.len != 0;
        const cert = try certify(arena, prev, oid, result.report.verdict, note);
        prev = cert;
        branch = fold(branch, result.report.verdict, has_receipt);
        try links.append(arena, .{
            .commit = oid,
            .parent = result.parent,
            .verdict = result.report.verdict,
            .has_receipt = has_receipt,
            .cert = cert,
            .report = result,
        });
    }
    if (links.items.len == 0) branch = .empty;
    return .{ .links = links.items, .verdict = branch, .tip = prev, .count = links.items.len };
}

pub fn exitCode(verdict: BranchVerdict) u8 {
    return switch (verdict) {
        .verified => 0,
        .partial, .empty => 53,
        .broken => 54,
    };
}

fn reasonFor(link: Link) []const u8 {
    if (!link.has_receipt) return "no receipt";
    return switch (link.verdict) {
        .verified => "",
        .merged => "merge",
        .unverified => "unverified",
        .mismatch => link.report.report.reason,
    };
}

pub fn writeText(w: *std.Io.Writer, result: Result) !void {
    try w.print("branch {t}: {d} commit(s)\n", .{ result.verdict, result.count });
    if (result.verdict == .empty) try w.writeAll("  the range holds no commit, so nothing was verified\n");
    for (result.links) |link| {
        const mark: []const u8 = switch (link.verdict) {
            .verified => "verified",
            .merged => "merged",
            .unverified => "unverified",
            .mismatch => "MISMATCH",
        };
        try w.print("  {s} {s: <10}", .{ link.commit[0..@min(link.commit.len, 12)], mark });
        const reason = reasonFor(link);
        if (reason.len != 0) try w.print(" ({s})", .{reason});
        try w.print("  cert {s}\n", .{&std.fmt.bytesToHex(link.cert, .lower)});
    }
    try w.print("chain tip {s}\n", .{&std.fmt.bytesToHex(result.tip, .lower)});
}

pub fn writeJson(w: *std.Io.Writer, result: Result) !void {
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("verdict");
    try js.write(@tagName(result.verdict));
    try js.objectField("count");
    try js.write(result.count);
    try js.objectField("tip");
    try js.write(&std.fmt.bytesToHex(result.tip, .lower));
    try js.objectField("commits");
    try js.beginArray();
    for (result.links) |link| {
        try js.beginObject();
        try js.objectField("commit");
        try js.write(link.commit);
        try js.objectField("verdict");
        try js.write(@tagName(link.verdict));
        try js.objectField("has_receipt");
        try js.write(link.has_receipt);
        try js.objectField("cert");
        try js.write(&std.fmt.bytesToHex(link.cert, .lower));
        const reason = reasonFor(link);
        if (reason.len != 0) {
            try js.objectField("reason");
            try js.write(reason);
        }
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    try w.writeByte('\n');
}
