const std = @import("std");
const jcs = @import("jcs.zig");
const receipt = @import("receipt.zig");
const symbol = @import("../engine/symbol.zig");
const alpha = @import("../engine/alpha.zig");
const registry = @import("../engine/lang/registry.zig");
const Snapshot = @import("../engine/loader.zig").Snapshot;
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Receipt = receipt.Receipt;
const Hash = receipt.Hash;

pub const Verdict = enum {
    verified,
    merged,
    unverified,
    mismatch,

    fn worse(self: Verdict, other: Verdict) bool {
        return @intFromEnum(other) > @intFromEnum(self);
    }
};

pub const Text = union(enum) {
    stored,
    driver: []const u8,
    unavailable,
};

pub const not_checked_out = "the checked-out form of a filtered file is not available";

pub const Source = struct {
    context: *anyopaque,
    changed: []const []const u8,
    before: *const fn (context: *anyopaque, path: []const u8) anyerror!?[]const u8,
    after: *const fn (context: *anyopaque, path: []const u8) anyerror!?[]const u8,
    mentioned: *const fn (context: *anyopaque, name: []const u8, except: []const u8) anyerror!bool,
    check: *const fn (context: *anyopaque, kind: receipt.CheckKind, digest: Hash) ?bool,
    rule: *const fn (context: *anyopaque, id: []const u8) ?Hash,
    before_text: ?*const fn (context: *anyopaque, path: []const u8) anyerror!Text = null,
    after_text: ?*const fn (context: *anyopaque, path: []const u8) anyerror!Text = null,
};

const Form = struct {
    bytes: ?[]const u8 = null,
    driven: bool = false,
    available: bool = true,
};

pub const Outcome = struct {
    verdict: Verdict = .verified,
    reason: []const u8 = "",

    fn raise(self: *Outcome, verdict: Verdict, reason: []const u8) void {
        if (self.verdict.worse(verdict)) {
            self.verdict = verdict;
            self.reason = reason;
        }
    }
};

pub const FileResult = struct {
    path: []const u8,
    outcome: Outcome,
};

pub const ReceiptResult = struct {
    id: [64]u8,
    batch: []const u8,
    operation: []const u8,
    outcome: Outcome,
};

pub const Report = struct {
    files: []const FileResult,
    receipts: []const ReceiptResult,
    verdict: Verdict,
    reason: []const u8 = "",
};

const State = struct {
    digest: ?Hash,
    bytes: ?[]const u8,
    known: bool,
    form: Form = .{},
    from_parent: bool = false,
};

const Files = struct {
    arena: Allocator,
    list: std.ArrayList(FileResult) = .empty,

    fn raise(self: *Files, path: []const u8, verdict: Verdict, reason: []const u8) !void {
        for (self.list.items) |*f| {
            if (std.mem.eql(u8, f.path, path)) {
                f.outcome.raise(verdict, reason);
                return;
            }
        }
        var outcome: Outcome = .{};
        outcome.raise(verdict, reason);
        try self.list.append(self.arena, .{ .path = path, .outcome = outcome });
    }
};

fn digestOf(bytes: ?[]const u8) ?Hash {
    const b = bytes orelse return null;
    return receipt.blake3(b);
}

fn eqlOptional(a: ?Hash, b: ?Hash) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, &a.?, &b.?);
}

const Checker = struct {
    arena: Allocator,
    runtime: *Runtime,
    source: Source,
    states: std.StringHashMapUnmanaged(State) = .empty,
    files: Files,

    fn state(self: *Checker, path: []const u8) !*State {
        const slot = try self.states.getOrPut(self.arena, path);
        if (!slot.found_existing) {
            const bytes = try self.source.before(self.source.context, path);
            slot.value_ptr.* = .{ .digest = digestOf(bytes), .bytes = bytes, .known = true, .form = try self.formOf(self.source.before_text, path, bytes), .from_parent = true };
        }
        return slot.value_ptr;
    }

    fn formOf(self: *Checker, read: ?*const fn (context: *anyopaque, path: []const u8) anyerror!Text, path: []const u8, bytes: ?[]const u8) !Form {
        if (bytes == null) return .{};
        const ask = read orelse return .{ .bytes = bytes };
        return switch (try ask(self.source.context, path)) {
            .stored => .{ .bytes = bytes },
            .driver => |text| .{ .bytes = text, .driven = true },
            .unavailable => .{ .driven = true, .available = false },
        };
    }

    fn parse(self: *Checker, path: []const u8, bytes: []const u8) !?*Snapshot {
        const profile = registry.forPath(path) orelse return null;
        const snapshot = try Snapshot.fromSource(self.runtime, profile, try self.runtime.gpa.dupe(u8, bytes));
        if (snapshot.tree.root().hasError()) {
            snapshot.destroy();
            return null;
        }
        return snapshot;
    }

    fn symbolHash(self: *Checker, path: []const u8, bytes: []const u8, ref_text: []const u8) !?Hash {
        const snapshot = (try self.parse(path, bytes)) orelse return error.Unparsable;
        defer snapshot.destroy();
        const table = try snapshot.symbols();
        const ref = symbol.Ref.parse(self.arena, ref_text) catch return error.Unparsable;
        if (table.resolve(ref)) |found| return found.hash else |_| {}
        for (table.declarations) |d| {
            if (d.ref.eql(ref)) return d.hash;
        }
        return null;
    }

    fn hashes(self: *Checker, path: []const u8, bytes: ?[]const u8, out: *std.ArrayList(Hash)) !bool {
        const b = bytes orelse return true;
        const snapshot = (try self.parse(path, b)) orelse return false;
        defer snapshot.destroy();
        const table = try snapshot.symbols();
        for (table.symbols) |s| try out.append(self.arena, s.hash);
        for (table.declarations) |d| try out.append(self.arena, d.hash);
        return true;
    }

    fn alphaEqual(self: *Checker, path: []const u8, before: []const u8, after: []const u8) !bool {
        const a = (try self.parse(path, before)) orelse return false;
        defer a.destroy();
        const b = (try self.parse(path, after)) orelse return false;
        defer b.destroy();
        const ra = a.tree.root();
        const rb = b.tree.root();
        if (ra.childCount() != rb.childCount()) return false;
        var i: u32 = 0;
        while (ra.child(i)) |x| : (i += 1) {
            const y = rb.child(i).?;
            const hx = alpha.hash(self.arena, a, .{ .start = x.startByte(), .end = x.endByte() }) catch return false;
            const hy = alpha.hash(self.arena, b, .{ .start = y.startByte(), .end = y.endByte() }) catch return false;
            if (!std.mem.eql(u8, &hx, &hy)) return false;
        }
        return true;
    }
};

pub fn symbolHashIn(arena: Allocator, runtime: *Runtime, path: []const u8, bytes: []const u8, ref_text: []const u8) !?Hash {
    var c: Checker = .{ .arena = arena, .runtime = runtime, .source = undefined, .files = .{ .arena = arena } };
    return c.symbolHash(path, bytes, ref_text) catch |err| switch (err) {
        error.Unparsable => null,
        else => |e| e,
    };
}

const Known = struct {
    path: []const u8,
    before: ?[]const u8,
    after: ?[]const u8,
    before_known: bool,
    after_known: bool,
    before_form: Form = .{},
    after_form: Form = .{},
};

fn lessHash(_: void, a: Hash, b: Hash) bool {
    return std.mem.order(u8, &a, &b) == .lt;
}

fn sameMultiset(a: []Hash, b: []Hash) bool {
    if (a.len != b.len) return false;
    std.mem.sort(Hash, a, {}, lessHash);
    std.mem.sort(Hash, b, {}, lessHash);
    for (a, b) |x, y| if (!std.mem.eql(u8, &x, &y)) return false;
    return true;
}

fn removeOne(list: *std.ArrayList(Hash), hash: Hash) bool {
    for (list.items, 0..) |h, i| {
        if (std.mem.eql(u8, &h, &hash)) {
            _ = list.swapRemove(i);
            return true;
        }
    }
    return false;
}

fn nameOf(ref_text: []const u8) []const u8 {
    var end = ref_text.len;
    if (std.mem.indexOfScalar(u8, ref_text, '@')) |at| end = at;
    const head = ref_text[0..end];
    const dot = std.mem.lastIndexOfScalar(u8, head, '.') orelse return head;
    return head[dot + 1 ..];
}

fn checkReceipt(c: *Checker, r: Receipt, last: *const std.StringHashMapUnmanaged(usize), index: usize) !Outcome {
    var outcome: Outcome = .{};
    for (r.subjects) |s| {
        var found = false;
        for (r.files) |f| {
            if (std.mem.eql(u8, f.path, s.path) and f.after != null and std.mem.eql(u8, &f.after.?, &s.blake3)) found = true;
        }
        if (!found) outcome.raise(.mismatch, "a subject does not match the files of the predicate");
    }
    for (r.files) |f| {
        if (f.after == null) continue;
        var found = false;
        for (r.subjects) |s| if (std.mem.eql(u8, s.path, f.path)) {
            found = true;
        };
        if (!found) outcome.raise(.mismatch, "a written file is not a subject");
    }

    const stored = r.form == .stored;
    var known: std.ArrayList(Known) = .empty;
    for (r.files) |f| {
        const st = try c.state(f.path);
        var entry: Known = .{ .path = f.path, .before = st.bytes, .after = null, .before_known = st.known, .after_known = false, .before_form = st.form };
        const checked_out = st.from_parent and !stored;
        const before_digest: ?Hash = if (checked_out) digestOf(st.form.bytes) else st.digest;
        if (checked_out and st.form.driven and (!st.form.available or !eqlOptional(before_digest, f.before))) {
            entry.before_known = false;
            outcome.raise(.unverified, not_checked_out);
        } else if (!eqlOptional(before_digest, f.before)) outcome.raise(.mismatch, "the before digest does not match the parent commit or the previous receipt");
        if (last.get(f.path).? == index) {
            const bytes = try c.source.after(c.source.context, f.path);
            const form = try c.formOf(c.source.after_text, f.path, bytes);
            const judged: ?[]const u8 = if (stored) bytes else form.bytes;
            if (!stored and !form.available) {
                outcome.raise(.unverified, not_checked_out);
                try c.files.raise(f.path, .unverified, not_checked_out);
            } else if (eqlOptional(digestOf(judged), f.after)) {
                entry.after = bytes;
                entry.after_known = true;
                entry.after_form = form;
                for (r.subjects) |s| {
                    if (std.mem.eql(u8, s.path, f.path) and !std.mem.eql(u8, &receipt.sha256(judged.?), &s.sha256)) outcome.raise(.mismatch, "a subject's sha256 does not match the commit");
                }
            } else {
                try c.files.raise(f.path, .unverified, "the file changed after the receipt, outside the gate");
            }
        }
        st.* = .{ .digest = f.after, .bytes = entry.after, .known = entry.after_known, .form = entry.after_form };
        try known.append(c.arena, entry);
    }

    for (r.symbols) |s| {
        const k = for (known.items) |k| {
            if (std.mem.eql(u8, k.path, s.path)) break k;
        } else unreachable;
        inline for (.{ .{ "before", "the symbol hash before the change does not match" }, .{ "after", "the symbol hash after the change does not match" } }) |side| {
            const is_known = @field(k, side[0] ++ "_known");
            const form: Form = @field(k, side[0] ++ "_form");
            const bytes = form.bytes;
            const claimed = @field(s, side[0]);
            if (!is_known) {
                outcome.raise(.unverified, "an intermediate state inside the commit is not available");
            } else if (!form.available) {
                outcome.raise(.unverified, not_checked_out);
            } else if (bytes) |b| {
                const actual = c.symbolHash(s.path, b, s.ref) catch |err| switch (err) {
                    error.Unparsable => blk: {
                        if (form.driven) outcome.raise(.unverified, not_checked_out) else outcome.raise(.mismatch, "a file does not parse");
                        break :blk claimed;
                    },
                    else => |e| return e,
                };
                if (!eqlOptional(actual, claimed)) outcome.raise(.mismatch, side[1]);
            } else if (claimed != null) outcome.raise(.mismatch, side[1]);
        }
    }

    for (r.rules) |rule| {
        const now = c.source.rule(c.source.context, rule.id) orelse {
            outcome.raise(.unverified, "a rule the receipt names is not in the ledger");
            continue;
        };
        if (!std.mem.eql(u8, &now, &rule.digest)) outcome.raise(.mismatch, "a rule the receipt names has changed");
    }

    switch (r.class) {
        .spending => {
            if (r.checks.len == 0) outcome.raise(.unverified, "a spending receipt without a check");
            for (r.checks) |one| {
                if (!std.mem.eql(u8, &receipt.blake3(one.command), &one.command_digest)) {
                    outcome.raise(.mismatch, "a check's command does not match its digest");
                    continue;
                }
                if (one.exit_code != 0) outcome.raise(.mismatch, "the receipt records a failing check");
                const passed = c.source.check(c.source.context, one.kind, one.command_digest) orelse {
                    outcome.raise(.unverified, "the check was not rerun with the same trusted command");
                    continue;
                };
                if (!passed) outcome.raise(.mismatch, "the check fails at this commit");
            }
        },
        .symmetry => try checkSymmetry(c, r, known.items, &outcome),
    }
    return outcome;
}

fn allKnown(known: []const Known) bool {
    for (known) |k| if (!k.before_known or !k.after_known) return false;
    return true;
}

fn checkSymmetry(c: *Checker, r: Receipt, known: []const Known, outcome: *Outcome) !void {
    if (!allKnown(known)) return outcome.raise(.unverified, "an intermediate state inside the commit is not available");
    for (known) |k| {
        for ([_]Form{ k.before_form, k.after_form }) |form| {
            if (!form.available) return outcome.raise(.unverified, not_checked_out);
            if (!form.driven) continue;
            const snapshot = (try c.parse(k.path, form.bytes orelse continue)) orelse return outcome.raise(.unverified, not_checked_out);
            snapshot.destroy();
        }
    }
    switch (r.operation) {
        .rename => {
            for (known) |k| {
                const before = k.before_form.bytes orelse return outcome.raise(.mismatch, "a rename created or deleted a file");
                const after = k.after_form.bytes orelse return outcome.raise(.mismatch, "a rename created or deleted a file");
                if (!try c.alphaEqual(k.path, before, after)) outcome.raise(.mismatch, "a statement's alpha hash changed");
            }
        },
        .move, .move_file => {
            var a: std.ArrayList(Hash) = .empty;
            var b: std.ArrayList(Hash) = .empty;
            for (known) |k| {
                if (!try c.hashes(k.path, k.before_form.bytes, &a) or !try c.hashes(k.path, k.after_form.bytes, &b)) return outcome.raise(.mismatch, "a file does not parse");
            }
            if (!sameMultiset(a.items, b.items)) outcome.raise(.mismatch, "the symbol and declaration hashes before and after the move differ");
        },
        .@"try", .try_batch => {
            for (known) |k| {
                var a: std.ArrayList(Hash) = .empty;
                var b: std.ArrayList(Hash) = .empty;
                if (!try c.hashes(k.path, k.before_form.bytes, &a) or !try c.hashes(k.path, k.after_form.bytes, &b)) return outcome.raise(.mismatch, "a file does not parse");
                for (r.symbols) |s| {
                    if (!std.mem.eql(u8, s.path, k.path)) continue;
                    if (s.before != null and s.after != null) return outcome.raise(.mismatch, "a symmetry receipt changes a symbol body");
                    if (s.before) |h| if (!removeOne(&a, h)) return outcome.raise(.mismatch, "a deleted symbol was not in the file");
                    if (s.after) |h| if (!removeOne(&b, h)) return outcome.raise(.mismatch, "a created symbol is not in the file");
                    if (try c.source.mentioned(c.source.context, nameOf(s.ref), s.path)) outcome.raise(.mismatch, "a created or deleted name is still referenced elsewhere");
                }
                if (!sameMultiset(a.items, b.items)) outcome.raise(.mismatch, "a symbol besides the created or deleted ones changed");
            }
        },
    }
}

pub fn check(arena: Allocator, runtime: *Runtime, note: ?[]const u8, source: Source) !Report {
    var c: Checker = .{ .arena = arena, .runtime = runtime, .source = source, .files = .{ .arena = arena } };
    var results: std.ArrayList(ReceiptResult) = .empty;
    var receipts: std.ArrayList(Receipt) = .empty;
    var failed_note = false;
    if (note) |bytes| {
        if (jcs.parse(arena, bytes)) |parsed| {
            const canonical = jcs.canonicalize(arena, parsed.value) catch null;
            if (parsed.value != .array or canonical == null or !std.mem.eql(u8, canonical.?, bytes)) {
                failed_note = true;
            } else {
                for (parsed.value.array.items) |item| {
                    const one = try jcs.canonicalize(arena, item);
                    const id = std.fmt.bytesToHex(receipt.sha256(one), .lower);
                    if (receipt.fromValue(arena, item)) |r| {
                        try receipts.append(arena, r);
                        try results.append(arena, .{ .id = id, .batch = r.batch, .operation = @tagName(r.operation), .outcome = .{} });
                    } else |_| {
                        var outcome: Outcome = .{};
                        outcome.raise(.mismatch, "the receipt does not follow the format");
                        try results.append(arena, .{ .id = id, .batch = "", .operation = "", .outcome = outcome });
                    }
                }
            }
        } else |_| failed_note = true;
    }

    var last: std.StringHashMapUnmanaged(usize) = .empty;
    for (receipts.items, 0..) |r, i| for (r.files) |f| try last.put(arena, f.path, i);
    var valid: usize = 0;
    for (results.items) |*result| {
        if (result.outcome.verdict == .mismatch) continue;
        const r = receipts.items[valid];
        result.outcome = try checkReceipt(&c, r, &last, valid);
        for (r.files) |f| try c.files.raise(f.path, result.outcome.verdict, result.outcome.reason);
        valid += 1;
    }
    for (source.changed) |path| {
        if (last.get(path) == null) try c.files.raise(path, .unverified, "no receipt covers this change");
    }
    var verdict: Verdict = .verified;
    for (c.files.list.items) |f| if (verdict.worse(f.outcome.verdict)) {
        verdict = f.outcome.verdict;
    };
    for (results.items) |r| if (verdict.worse(r.outcome.verdict)) {
        verdict = r.outcome.verdict;
    };
    if (failed_note) {
        verdict = .mismatch;
        for (source.changed) |path| try c.files.raise(path, .mismatch, "the receipt note is not canonical JSON");
    }
    return .{ .files = c.files.list.items, .receipts = results.items, .verdict = verdict };
}
