//! The sent ledger: per session, which bytes of which file the model has been
//! shown, and in what form. It lets a reply skip code the model already holds
//! unchanged, resend code that changed since the model saw it, and forget all
//! of it when the client compacts its context. Pure and allocator based: it
//! reads no files, the caller hands it the bytes.
const std = @import("std");
const symbol = @import("symbol.zig");

const Allocator = std.mem.Allocator;

pub const Hash = symbol.Hash;
pub const default_cap = 4096;

/// How the bytes were shown. Only `.exact` counts as seen for editing: a dense
/// view (folded, outlined, annotated) does not give the model the bytes an
/// edit has to match.
pub const Form = enum { exact, dense };

/// A half-open byte range [start, end) of the file.
pub const Span = struct {
    start: u32,
    end: u32,
};

pub const Entry = struct {
    /// Repo-relative, '/' separated. Owned by the ledger.
    path: []const u8,
    span: Span,
    /// symbol.hashOf of exactly the file bytes in `span` when they were shown.
    hash: Hash,
    form: Form,
};

/// The hash recorded for a span: the hash of exactly those bytes.
pub fn spanHash(bytes: []const u8) Hash {
    return symbol.hashOf(bytes);
}

pub const Ledger = struct {
    gpa: Allocator,
    cap: usize,
    /// Oldest first.
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(gpa: Allocator) Ledger {
        return initCap(gpa, default_cap);
    }

    pub fn initCap(gpa: Allocator, cap: usize) Ledger {
        return .{ .gpa = gpa, .cap = @max(cap, 1) };
    }

    pub fn deinit(self: *Ledger) void {
        self.reset();
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn len(self: *const Ledger) usize {
        return self.entries.items.len;
    }

    /// Forget everything, as after the client compacted its context.
    pub fn reset(self: *Ledger) void {
        for (self.entries.items) |entry| self.gpa.free(entry.path);
        self.entries.clearRetainingCapacity();
    }

    /// Note that `span` of `path` was shown with content hash `hash` in `form`.
    /// A newer showing of the same span replaces the older one; past the cap
    /// the oldest entry is dropped.
    pub fn record(self: *Ledger, path: []const u8, span: Span, hash: Hash, form: Form) Allocator.Error!void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = self.entries.items[i];
            if (samePath(entry.path, path) and entry.span.start == span.start and entry.span.end == span.end) {
                self.gpa.free(entry.path);
                _ = self.entries.orderedRemove(i);
            } else i += 1;
        }
        const owned = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(owned);
        std.mem.replaceScalar(u8, owned, '\\', '/');
        if (self.entries.items.len >= self.cap) {
            self.gpa.free(self.entries.items[0].path);
            _ = self.entries.orderedRemove(0);
        }
        try self.entries.append(self.gpa, .{ .path = owned, .span = span, .hash = hash, .form = form });
    }

    /// Record `bytes[span]` of `path`, hashing the shown bytes.
    pub fn recordBytes(self: *Ledger, path: []const u8, bytes: []const u8, span: Span, form: Form) Allocator.Error!void {
        if (span.start > span.end or span.end > bytes.len) return;
        return self.record(path, span, spanHash(bytes[span.start..span.end]), form);
    }

    /// True only if content with `span_hash` from `path` was shown in exact
    /// form. Dense showings do not count.
    pub fn seenUnchanged(self: *const Ledger, path: []const u8, span_hash: Hash) bool {
        for (self.entries.items) |entry| {
            if (entry.form == .exact and samePath(entry.path, path) and std.mem.eql(u8, &entry.hash, &span_hash)) return true;
        }
        return false;
    }

    /// The entries of `path` whose recorded bytes no longer match
    /// `current_file_bytes`: the model holds an outdated view of them. The
    /// returned slice is owned by the caller (free with `gpa`); its paths
    /// borrow from the ledger and live until the next record or reset.
    pub fn staleFor(self: *const Ledger, gpa: Allocator, path: []const u8, current_file_bytes: []const u8) Allocator.Error![]Entry {
        var stale: std.ArrayList(Entry) = .empty;
        errdefer stale.deinit(gpa);
        for (self.entries.items) |entry| {
            if (!samePath(entry.path, path)) continue;
            const fits = entry.span.start <= entry.span.end and entry.span.end <= current_file_bytes.len;
            if (fits and std.mem.eql(u8, &entry.hash, &spanHash(current_file_bytes[entry.span.start..entry.span.end]))) continue;
            try stale.append(gpa, entry);
        }
        return stale.toOwnedSlice(gpa);
    }
};

/// Paths compare with either separator and without case, as Windows does.
fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const nx: u8 = if (x == '\\') '/' else std.ascii.toLower(x);
        const ny: u8 = if (y == '\\') '/' else std.ascii.toLower(y);
        if (nx != ny) return false;
    }
    return true;
}
