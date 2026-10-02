const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Writer = std.Io.Writer;
const Stringify = std.json.Stringify;

pub const Digest = [Sha256.digest_length]u8;
pub const digest_algorithm = "sha256";
pub const tree_algorithm = "rfc9162";
pub const short_root_bytes = 2;

pub fn contentDigest(bytes: []const u8) Digest {
    var out: Digest = undefined;
    Sha256.hash(bytes, &out, .{});
    return out;
}

pub fn emptyRoot() Digest {
    return contentDigest("");
}

pub fn leafHash(data: []const u8) Digest {
    var hasher = Sha256.init(.{});
    hasher.update(&.{0x00});
    hasher.update(data);
    var out: Digest = undefined;
    hasher.final(&out);
    return out;
}

pub fn nodeHash(left: Digest, right: Digest) Digest {
    var hasher = Sha256.init(.{});
    hasher.update(&.{0x01});
    hasher.update(&left);
    hasher.update(&right);
    var out: Digest = undefined;
    hasher.final(&out);
    return out;
}

fn splitPoint(count: usize) usize {
    var k: usize = 1;
    while (k * 2 < count) k *= 2;
    return k;
}

pub fn treeHash(comptime Item: type, items: []const Item, comptime hashItem: fn (Item) Digest) Digest {
    if (items.len == 0) return emptyRoot();
    if (items.len == 1) return hashItem(items[0]);
    const k = splitPoint(items.len);
    return nodeHash(treeHash(Item, items[0..k], hashItem), treeHash(Item, items[k..], hashItem));
}

fn sameDigest(digest: Digest) Digest {
    return digest;
}

pub fn rootOfLeafHashes(hashes: []const Digest) Digest {
    return treeHash(Digest, hashes, sameDigest);
}

pub const Leaf = struct {
    path: []const u8,
    digest: Digest,
};

pub fn pathLeafHash(leaf: Leaf) Digest {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(leaf.path.len), .little);
    var hasher = Sha256.init(.{});
    hasher.update(&.{0x00});
    hasher.update(&length);
    hasher.update(leaf.path);
    hasher.update(&leaf.digest);
    var out: Digest = undefined;
    hasher.final(&out);
    return out;
}

pub fn merkleRoot(leaves: []const Leaf) error{UnsortedLeaves}!Digest {
    var i: usize = 1;
    while (i < leaves.len) : (i += 1) {
        if (std.mem.order(u8, leaves[i - 1].path, leaves[i].path) != .lt) return error.UnsortedLeaves;
    }
    return treeHash(Leaf, leaves, pathLeafHash);
}

pub const Snapshot = struct {
    barrier: u64,
    root: Digest,
};

pub const Basis = enum { tracked };

pub const Rule = enum { binary, internal, too_large };

pub const Exclusions = std.EnumArray(Rule, u32);

pub fn covers(prefix: []const u8, path: []const u8) bool {
    if (prefix.len == 0) return true;
    if (path.len < prefix.len) return false;
    for (prefix, path[0..prefix.len]) |a, b| {
        if (foldPathByte(a) != foldPathByte(b)) return false;
    }
    if (path.len == prefix.len) return true;
    return path[prefix.len] == '/' or path[prefix.len] == '\\';
}

fn foldPathByte(byte: u8) u8 {
    return if (byte == '\\') '/' else std.ascii.toLower(byte);
}

pub const Scope = struct {
    basis: Basis = .tracked,
    prefix: []const u8 = "",
    listed: u32,
    excluded: Exclusions = .initFill(0),
    evaluated: u32,

    pub fn excludedTotal(self: Scope) u64 {
        var total: u64 = 0;
        for (self.excluded.values) |count| total += count;
        return total;
    }

    pub fn inScope(self: Scope) ?u32 {
        const excluded = self.excludedTotal();
        if (excluded > self.listed) return null;
        return @intCast(self.listed - excluded);
    }
};

pub const Limit = enum { file_bytes, matches, steps };

pub const Budget = struct {
    limit: Limit,
    max: u64,
    used: u64,
};

pub const Reason = enum {
    too_large,
    unreadable,
    vanished,
    budget,
    match_limit,
    unclassified,
    unresolved,
    deleted,
    changed_since_snapshot,

    pub fn fileLevel(self: Reason) bool {
        return self != .unresolved;
    }

    pub fn limit(self: Reason) ?Limit {
        return switch (self) {
            .too_large => .file_bytes,
            .budget => .steps,
            .match_limit => .matches,
            .unreadable, .vanished, .unclassified, .unresolved, .deleted, .changed_since_snapshot => null,
        };
    }
};

pub const Missing = struct {
    path: ?[]const u8,
    reason: Reason,
    line: u32 = 0,
    files: u32 = 1,
};

pub const Kind = enum { code, comment, string };

pub const Kinds = std.EnumSet(Kind);

pub const Mode = enum { literal, regex };

pub const Case = enum { sensitive, insensitive };

pub const Text = struct {
    pattern: []const u8,
    mode: Mode = .literal,
    case: Case = .sensitive,
    kinds: Kinds = .initFull(),
    filtered: u32 = 0,
};

pub const Facts = struct {
    relation: []const u8,
    subject: []const u8,
    resolved: u32,
    unresolved: u32,
};

pub const Semantics = union(enum) {
    text: Text,
    listing,
    facts: Facts,
};

pub const Certificate = struct {
    snapshot: Snapshot,
    scope: Scope,
    semantics: Semantics,
    budgets: []const Budget = &.{},
};

pub const Refusal = struct {
    code: anyerror,
    detail: []const u8 = "",
};

pub const Status = enum { complete, partial, refused };

fn missingLess(_: void, a: Missing, b: Missing) bool {
    if (a.path == null or b.path == null) {
        if (a.path != null) return true;
        if (b.path != null) return false;
    } else switch (std.mem.order(u8, a.path.?, b.path.?)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (a.line != b.line) return a.line < b.line;
    return @intFromEnum(a.reason) < @intFromEnum(b.reason);
}

fn sameFile(a: Missing, b: Missing) bool {
    if (a.path == null or b.path == null) return false;
    return std.mem.eql(u8, a.path.?, b.path.?);
}

fn declares(budgets: []const Budget, limit: Limit) bool {
    for (budgets) |budget| {
        if (budget.limit == limit) return true;
    }
    return false;
}

pub fn inconsistency(cert: Certificate, missing: []const Missing) ?[]const u8 {
    const in_scope = cert.scope.inScope() orelse return "excluded files outnumber listed files";
    for (cert.budgets, 0..) |budget, i| {
        if (budget.used > budget.max) return "a budget was overspent";
        for (cert.budgets[0..i]) |earlier| {
            if (earlier.limit == budget.limit) return "a limit is declared twice";
        }
    }
    var accounted: u64 = cert.scope.evaluated;
    var unresolved: u64 = 0;
    for (missing, 0..) |entry, i| {
        if (entry.files == 0) return "a missing entry covers no file";
        if (entry.path != null and entry.files != 1) return "a missing path covers more than one file";
        if (entry.reason.limit()) |limit| {
            if (!declares(cert.budgets, limit)) return "a missing reason names an undeclared limit";
        }
        if (entry.reason.fileLevel()) {
            if (entry.line != 0) return "a missing file names a line";
            accounted += entry.files;
        } else {
            if (entry.path == null or entry.line == 0) return "an unresolved reference has no place";
            unresolved += 1;
        }
        if (i != 0 and sameFile(missing[i - 1], entry) and missing[i - 1].reason.fileLevel()) {
            if (entry.reason.fileLevel()) return "a file is reported missing twice";
            return "an unresolved reference sits in a file that was not evaluated";
        }
    }
    if (accounted != in_scope) return "evaluated and missing files do not add up to the scope";
    switch (cert.semantics) {
        .text => |text| {
            if (text.kinds.eql(.initFull()) and text.filtered != 0) return "hits were filtered without a kinds filter";
            if (unresolved != 0) return "unresolved references outside fact semantics";
        },
        .listing => if (unresolved != 0) return "unresolved references outside fact semantics",
        .facts => |facts| if (facts.unresolved != unresolved) return "unresolved references are not all listed",
    }
    return null;
}

pub fn Answer(comptime T: type) type {
    return union(Status) {
        complete: Complete,
        partial: Partial,
        refused: Refusal,

        const Self = @This();

        pub const Complete = struct {
            value: T,
            cert: Certificate,
        };

        pub const Partial = struct {
            value: T,
            cert: Certificate,
            missing: []const Missing,
        };

        pub fn finish(value: T, cert: Certificate, missing: []Missing) Self {
            std.mem.sort(Missing, missing, {}, missingLess);
            if (inconsistency(cert, missing)) |problem| {
                return .{ .refused = .{ .code = error.InconsistentCertificate, .detail = problem } };
            }
            if (missing.len == 0) return .{ .complete = .{ .value = value, .cert = cert } };
            return .{ .partial = .{ .value = value, .cert = cert, .missing = missing } };
        }

        pub fn refuse(code: anyerror, detail: []const u8) Self {
            return .{ .refused = .{ .code = code, .detail = detail } };
        }

        pub fn status(self: Self) Status {
            return self;
        }

        pub fn certificate(self: Self) ?Certificate {
            return switch (self) {
                .complete => |c| c.cert,
                .partial => |p| p.cert,
                .refused => null,
            };
        }

        pub fn missingList(self: Self) []const Missing {
            return switch (self) {
                .partial => |p| p.missing,
                .complete, .refused => &.{},
            };
        }

        pub fn writeStatus(self: Self, w: *Writer, count: usize, noun: []const u8) Writer.Error!void {
            switch (self) {
                .refused => |r| {
                    try w.print("refused: {s}", .{@errorName(r.code)});
                    if (r.detail.len != 0) try w.print(" ({s})", .{r.detail});
                },
                .complete => |c| {
                    try w.print("\u{2713} {d} {s} in ", .{ count, noun });
                    try writeFiles(w, c.cert.scope.evaluated);
                    try writeRoot(w, c.cert.snapshot.root);
                    try writeNotes(w, c.cert);
                },
                .partial => |p| {
                    try w.print("partial: {d} {s} in {d} of ", .{ count, noun, p.cert.scope.evaluated });
                    try writeFiles(w, p.cert.scope.inScope() orelse 0);
                    try writeRoot(w, p.cert.snapshot.root);
                    try writeMissingSummary(w, p.missing);
                    try writeNotes(w, p.cert);
                },
            }
        }

        pub fn writeCertificate(self: Self, js: *Stringify) Writer.Error!void {
            try js.beginObject();
            try js.objectField("answer");
            try js.write(@tagName(self.status()));
            switch (self) {
                .refused => |r| {
                    try js.objectField("code");
                    try js.write(@errorName(r.code));
                    try js.objectField("detail");
                    try js.write(r.detail);
                },
                .complete => |c| try writeCertificateBody(js, c.cert, &.{}),
                .partial => |p| try writeCertificateBody(js, p.cert, p.missing),
            }
            try js.endObject();
        }
    };
}

fn writeFiles(w: *Writer, count: u64) Writer.Error!void {
    try w.print("{d} {s}", .{ count, if (count == 1) "file" else "files" });
}

fn writeRoot(w: *Writer, root: Digest) Writer.Error!void {
    const hex = std.fmt.bytesToHex(root[0..short_root_bytes].*, .lower);
    try w.print(" @{s}", .{&hex});
}

fn writeMissingSummary(w: *Writer, missing: []const Missing) Writer.Error!void {
    var counts = std.EnumArray(Reason, u64).initFill(0);
    for (missing) |entry| {
        const weight: u64 = if (entry.reason.fileLevel()) entry.files else 1;
        counts.set(entry.reason, counts.get(entry.reason) + weight);
    }
    var first = true;
    for (std.enums.values(Reason)) |reason| {
        const count = counts.get(reason);
        if (count == 0) continue;
        try w.print("{s} {d} {s}", .{ if (first) "; missing" else ",", count, @tagName(reason) });
        first = false;
    }
}

fn writeNotes(w: *Writer, cert: Certificate) Writer.Error!void {
    switch (cert.semantics) {
        .text => |text| if (text.filtered != 0) try w.print("; {d} hidden by kinds", .{text.filtered}),
        .listing, .facts => {},
    }
    for (std.enums.values(Rule)) |rule| {
        const count = cert.scope.excluded.get(rule);
        if (count != 0) try w.print("; skipped {d} {s}", .{ count, @tagName(rule) });
    }
}

fn writeCertificateBody(js: *Stringify, cert: Certificate, missing: []const Missing) Writer.Error!void {
    try js.objectField("snapshot");
    try js.beginObject();
    try js.objectField("barrier");
    try js.write(cert.snapshot.barrier);
    try js.objectField("root");
    const root_hex = std.fmt.bytesToHex(cert.snapshot.root, .lower);
    try js.write(root_hex[0..]);
    try js.objectField("digest");
    try js.write(digest_algorithm);
    try js.objectField("tree");
    try js.write(tree_algorithm);
    try js.endObject();

    try js.objectField("scope");
    try js.beginObject();
    try js.objectField("basis");
    try js.write(@tagName(cert.scope.basis));
    try js.objectField("prefix");
    try js.write(cert.scope.prefix);
    try js.objectField("listed");
    try js.write(cert.scope.listed);
    try js.objectField("excluded");
    try js.beginObject();
    for (std.enums.values(Rule)) |rule| {
        try js.objectField(@tagName(rule));
        try js.write(cert.scope.excluded.get(rule));
    }
    try js.endObject();
    try js.objectField("evaluated");
    try js.write(cert.scope.evaluated);
    try js.objectField("in_scope");
    try js.write(cert.scope.inScope() orelse 0);
    try js.endObject();

    try js.objectField("semantics");
    try writeSemantics(js, cert.semantics);

    try js.objectField("budgets");
    try js.beginArray();
    for (std.enums.values(Limit)) |limit| {
        for (cert.budgets) |budget| {
            if (budget.limit != limit) continue;
            try js.beginObject();
            try js.objectField("limit");
            try js.write(@tagName(budget.limit));
            try js.objectField("max");
            try js.write(budget.max);
            try js.objectField("used");
            try js.write(budget.used);
            try js.endObject();
        }
    }
    try js.endArray();

    try js.objectField("missing");
    try js.beginArray();
    for (missing) |entry| {
        try js.beginObject();
        try js.objectField("path");
        try js.write(entry.path);
        try js.objectField("line");
        try js.write(entry.line);
        try js.objectField("reason");
        try js.write(@tagName(entry.reason));
        try js.objectField("files");
        try js.write(entry.files);
        try js.endObject();
    }
    try js.endArray();
}

fn writeSemantics(js: *Stringify, semantics: Semantics) Writer.Error!void {
    try js.beginObject();
    try js.objectField(@tagName(semantics));
    try js.beginObject();
    switch (semantics) {
        .text => |text| {
            try js.objectField("pattern");
            try js.write(text.pattern);
            try js.objectField("mode");
            try js.write(@tagName(text.mode));
            try js.objectField("case");
            try js.write(@tagName(text.case));
            try js.objectField("kinds");
            try js.beginArray();
            for (std.enums.values(Kind)) |kind| {
                if (text.kinds.contains(kind)) try js.write(@tagName(kind));
            }
            try js.endArray();
            try js.objectField("filtered");
            try js.write(text.filtered);
        },
        .listing => {},
        .facts => |facts| {
            try js.objectField("relation");
            try js.write(facts.relation);
            try js.objectField("subject");
            try js.write(facts.subject);
            try js.objectField("resolved");
            try js.write(facts.resolved);
            try js.objectField("unresolved");
            try js.write(facts.unresolved);
        },
    }
    try js.endObject();
    try js.endObject();
}

const testing = std.testing;

fn hexDigest(text: *const [64]u8) !Digest {
    var out: Digest = undefined;
    _ = try std.fmt.hexToBytes(&out, text);
    return out;
}

fn sameBytes(item: []const u8) Digest {
    return leafHash(item);
}

test "the merkle root matches the RFC 6962 reference vectors for zero to eight leaves" {
    const inputs = [_][]const u8{ "", "\x00", "\x10", "\x20\x21", "\x30\x31", "\x40\x41\x42\x43", "\x50\x51\x52\x53\x54\x55\x56\x57", "\x60\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6a\x6b\x6c\x6d\x6e\x6f" };
    const roots = [_]*const [64]u8{
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d",
        "fac54203e7cc696cf0dfcb42c92a1d9dbaf70ad9e621f4bd8d98662f00e3c125",
        "aeb6bcfe274b70a14fb067a5e5578264db0fa9b51af5e0ba159158f329e06e77",
        "d37ee418976dd95753c1c73862b9398fa2a2cf9b4ff0fdfe8b30cd95209614b7",
        "4e3bbb1f7b478dcfe71fb631631519a3bca12c9aefca1612bfce4c13a86264d4",
        "76e67dadbcdf1e10e1b74ddc608abd2f98dfb16fbce75277b5232a127f2087ef",
        "ddb89be403809e325750d3d263cd78929c2942b7942a34b77e122c9594a74c8c",
        "5dc9da79a70659a9ad559cb701ded9a2ab9d823aad2f4960cfe370eff4604328",
    };
    for (roots, 0..) |expected, n| {
        const got = treeHash([]const u8, inputs[0..n], sameBytes);
        try testing.expectEqualSlices(u8, &(try hexDigest(expected)), &got);
    }
}

fn bottomUpRoot(gpa: std.mem.Allocator, hashes: []const Digest) !Digest {
    if (hashes.len == 0) return emptyRoot();
    var level = try gpa.dupe(Digest, hashes);
    defer gpa.free(level);
    var len = level.len;
    while (len > 1) {
        var out: usize = 0;
        var i: usize = 0;
        while (i < len) : (i += 2) {
            level[out] = if (i + 1 < len) nodeHash(level[i], level[i + 1]) else level[i];
            out += 1;
        }
        len = out;
    }
    return level[0];
}

test "the merkle root of leaf hashes equals an independent bottom-up construction for every size up to 70" {
    var hashes: [70]Digest = undefined;
    for (&hashes, 0..) |*h, i| h.* = leafHash(&.{@as(u8, @intCast(i))});
    for (0..hashes.len + 1) |n| {
        const expected = try bottomUpRoot(testing.allocator, hashes[0..n]);
        try testing.expectEqualSlices(u8, &expected, &rootOfLeafHashes(hashes[0..n]));
    }
}

test "the merkle root binds every path and every content digest" {
    const a = contentDigest("one");
    const b = contentDigest("two");
    const base = try merkleRoot(&.{ .{ .path = "a.ts", .digest = a }, .{ .path = "b.ts", .digest = b } });
    const renamed = try merkleRoot(&.{ .{ .path = "a.ts", .digest = a }, .{ .path = "c.ts", .digest = b } });
    const edited = try merkleRoot(&.{ .{ .path = "a.ts", .digest = a }, .{ .path = "b.ts", .digest = a } });
    const dropped = try merkleRoot(&.{.{ .path = "a.ts", .digest = a }});
    try testing.expect(!std.mem.eql(u8, &base, &renamed));
    try testing.expect(!std.mem.eql(u8, &base, &edited));
    try testing.expect(!std.mem.eql(u8, &base, &dropped));
    const shifted = try merkleRoot(&.{ .{ .path = "a.t", .digest = a }, .{ .path = "sb.ts", .digest = b } });
    try testing.expect(!std.mem.eql(u8, &base, &shifted));
}

test "leaves out of path order or repeated are refused instead of hashed" {
    const d = contentDigest("x");
    try testing.expectError(error.UnsortedLeaves, merkleRoot(&.{ .{ .path = "b.ts", .digest = d }, .{ .path = "a.ts", .digest = d } }));
    try testing.expectError(error.UnsortedLeaves, merkleRoot(&.{ .{ .path = "a.ts", .digest = d }, .{ .path = "a.ts", .digest = d } }));
    _ = try merkleRoot(&.{ .{ .path = "a-b.ts", .digest = d }, .{ .path = "a/b.ts", .digest = d } });
}

test "a scope prefix covers itself and the paths below it and nothing beside it" {
    try testing.expect(covers("", "src/a.ts"));
    try testing.expect(covers("src", "src/a.ts"));
    try testing.expect(covers("SRC", "src\\a.ts"));
    try testing.expect(covers("src/a.ts", "src/a.ts"));
    try testing.expect(!covers("src", "srcx/a.ts"));
    try testing.expect(!covers("src/a.ts", "src/a.tsx"));
    try testing.expect(!covers("src/lib", "src"));
}

const Hits = []const u32;

fn textCert(evaluated: u32, listed: u32) Certificate {
    return .{
        .snapshot = .{ .barrier = 7, .root = contentDigest("root") },
        .scope = .{ .listed = listed, .evaluated = evaluated },
        .semantics = .{ .text = .{ .pattern = "needle" } },
        .budgets = &.{
            .{ .limit = .file_bytes, .max = 1024, .used = 10 },
            .{ .limit = .matches, .max = 200, .used = 0 },
            .{ .limit = .steps, .max = 1000, .used = 3 },
        },
    };
}

test "an answer with nothing missing over the whole scope is complete" {
    const answer = Answer(Hits).finish(&.{}, textCert(3, 3), &.{});
    try testing.expectEqual(Status.complete, answer.status());
}

test "a missing file makes the answer partial and never complete" {
    var missing = [_]Missing{.{ .path = "big.ts", .reason = .too_large }};
    const answer = Answer(Hits).finish(&.{}, textCert(2, 3), &missing);
    try testing.expectEqual(Status.partial, answer.status());
    try testing.expectEqual(@as(usize, 1), answer.missingList().len);
}

test "an answer whose evaluated and missing files do not add up to the scope is refused" {
    const silent_skip = Answer(Hits).finish(&.{}, textCert(2, 3), &.{});
    try testing.expectEqual(Status.refused, silent_skip.status());
    try testing.expectEqual(error.InconsistentCertificate, silent_skip.refused.code);
    var double = [_]Missing{.{ .path = "a.ts", .reason = .unreadable }};
    const counted_twice = Answer(Hits).finish(&.{}, textCert(3, 3), &double);
    try testing.expectEqual(Status.refused, counted_twice.status());
}

test "excluded files are taken out of the scope before the files are counted" {
    var cert = textCert(2, 3);
    cert.scope.excluded.set(.binary, 1);
    try testing.expectEqual(Status.complete, Answer(Hits).finish(&.{}, cert, &.{}).status());
    cert.scope.excluded.set(.binary, 4);
    try testing.expectEqual(Status.refused, Answer(Hits).finish(&.{}, cert, &.{}).status());
}

test "a budget used beyond its declared maximum is refused" {
    var cert = textCert(1, 1);
    cert.budgets = &.{.{ .limit = .steps, .max = 10, .used = 11 }};
    try testing.expectEqual(Status.refused, Answer(Hits).finish(&.{}, cert, &.{}).status());
    cert.budgets = &.{ .{ .limit = .steps, .max = 10, .used = 1 }, .{ .limit = .steps, .max = 20, .used = 1 } };
    try testing.expectEqual(Status.refused, Answer(Hits).finish(&.{}, cert, &.{}).status());
}

test "a missing reason that names a limit needs that limit declared with its value" {
    var cert = textCert(0, 1);
    cert.budgets = &.{};
    var missing = [_]Missing{.{ .path = "big.ts", .reason = .too_large }};
    const answer = Answer(Hits).finish(&.{}, cert, &missing);
    try testing.expectEqual(Status.refused, answer.status());
    try testing.expectEqualStrings("a missing reason names an undeclared limit", answer.refused.detail);
}

test "a missing entry must cover at least one file and a named path exactly one" {
    var none = [_]Missing{.{ .path = null, .reason = .match_limit, .files = 0 }};
    try testing.expectEqual(Status.refused, Answer(Hits).finish(&.{}, textCert(1, 1), &none).status());
    var wide = [_]Missing{.{ .path = "a.ts", .reason = .unreadable, .files = 2 }};
    try testing.expectEqual(Status.refused, Answer(Hits).finish(&.{}, textCert(0, 2), &wide).status());
    var rest = [_]Missing{.{ .path = null, .reason = .match_limit, .files = 5 }};
    try testing.expectEqual(Status.partial, Answer(Hits).finish(&.{}, textCert(2, 7), &rest).status());
}

test "the same file reported missing twice is refused" {
    var twice = [_]Missing{ .{ .path = "a.ts", .reason = .unreadable }, .{ .path = "a.ts", .reason = .too_large } };
    const answer = Answer(Hits).finish(&.{}, textCert(0, 2), &twice);
    try testing.expectEqual(Status.refused, answer.status());
    try testing.expectEqualStrings("a file is reported missing twice", answer.refused.detail);
}

fn factsCert(resolved: u32, unresolved: u32) Certificate {
    return .{
        .snapshot = .{ .barrier = 1, .root = contentDigest("facts") },
        .scope = .{ .listed = 4, .evaluated = 4 },
        .semantics = .{ .facts = .{ .relation = "callers", .subject = "Store.load", .resolved = resolved, .unresolved = unresolved } },
    };
}

test "callers with an unresolved reference in scope are partial and every unresolved reference is listed" {
    var listed = [_]Missing{.{ .path = "a.ts", .line = 12, .reason = .unresolved }};
    const answer = Answer(Hits).finish(&.{}, factsCert(3, 1), &listed);
    try testing.expectEqual(Status.partial, answer.status());
    const unlisted = Answer(Hits).finish(&.{}, factsCert(3, 1), &.{});
    try testing.expectEqual(Status.refused, unlisted.status());
    try testing.expectEqual(Status.complete, Answer(Hits).finish(&.{}, factsCert(3, 0), &.{}).status());
    var placeless = [_]Missing{.{ .path = "a.ts", .reason = .unresolved }};
    try testing.expectEqual(Status.refused, Answer(Hits).finish(&.{}, factsCert(3, 1), &placeless).status());
    var unevaluated = [_]Missing{ .{ .path = "a.ts", .line = 3, .reason = .unresolved }, .{ .path = "a.ts", .reason = .unreadable } };
    const contradiction = Answer(Hits).finish(&.{}, factsCert(3, 1), &unevaluated);
    try testing.expectEqualStrings("an unresolved reference sits in a file that was not evaluated", contradiction.refused.detail);
}

test "hits counted as filtered without a kinds filter are refused" {
    var cert = textCert(1, 1);
    cert.semantics.text.filtered = 2;
    try testing.expectEqual(Status.refused, Answer(Hits).finish(&.{}, cert, &.{}).status());
    cert.semantics.text.kinds = .initOne(.code);
    try testing.expectEqual(Status.complete, Answer(Hits).finish(&.{}, cert, &.{}).status());
}

fn statusText(answer: Answer(Hits), count: usize) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try answer.writeStatus(&out.writer, count, "matches");
    return out.toOwnedSlice();
}

test "only a complete answer is rendered with a check mark" {
    const complete = try statusText(Answer(Hits).finish(&.{}, textCert(3, 3), &.{}), 4);
    defer testing.allocator.free(complete);
    try testing.expect(std.mem.startsWith(u8, complete, "\u{2713} 4 matches in 3 files @"));
    var missing = [_]Missing{.{ .path = "big.ts", .reason = .too_large }};
    const partial = try statusText(Answer(Hits).finish(&.{}, textCert(2, 3), &missing), 4);
    defer testing.allocator.free(partial);
    try testing.expect(std.mem.indexOf(u8, partial, "\u{2713}") == null);
    try testing.expect(std.mem.startsWith(u8, partial, "partial: 4 matches in 2 of 3 files @"));
    try testing.expect(std.mem.endsWith(u8, partial, "; missing 1 too_large"));
    const refused = try statusText(Answer(Hits).refuse(error.InvalidArgument, "stats: expected boolean"), 0);
    defer testing.allocator.free(refused);
    try testing.expectEqualStrings("refused: InvalidArgument (stats: expected boolean)", refused);
}

test "a complete answer with no results still states the scope and snapshot" {
    const text = try statusText(Answer(Hits).finish(&.{}, textCert(157, 157), &.{}), 0);
    defer testing.allocator.free(text);
    const hex = std.fmt.bytesToHex(contentDigest("root")[0..2].*, .lower);
    const expected = try std.fmt.allocPrint(testing.allocator, "\u{2713} 0 matches in 157 files @{s}", .{&hex});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, text);
}

test "hits hidden by a kinds filter and skipped binary files are counted in the status" {
    var cert = textCert(2, 3);
    cert.semantics.text.kinds = .initOne(.comment);
    cert.semantics.text.filtered = 7;
    cert.scope.excluded.set(.binary, 1);
    const text = try statusText(Answer(Hits).finish(&.{}, cert, &.{}), 0);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.endsWith(u8, text, "; 7 hidden by kinds; skipped 1 binary"));
}

fn certificateText(answer: Answer(Hits)) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    var js: Stringify = .{ .writer = &out.writer };
    try answer.writeCertificate(&js);
    return out.toOwnedSlice();
}

test "the certificate bytes do not depend on the order missing files were reported" {
    var first = [_]Missing{
        .{ .path = "b.ts", .reason = .unreadable },
        .{ .path = null, .reason = .match_limit, .files = 2 },
        .{ .path = "a.ts", .reason = .too_large },
    };
    var second = [_]Missing{
        .{ .path = "a.ts", .reason = .too_large },
        .{ .path = "b.ts", .reason = .unreadable },
        .{ .path = null, .reason = .match_limit, .files = 2 },
    };
    var cert = textCert(1, 5);
    cert.budgets = &.{ .{ .limit = .steps, .max = 9, .used = 1 }, .{ .limit = .matches, .max = 200, .used = 200 }, .{ .limit = .file_bytes, .max = 1024, .used = 3 } };
    const one = try certificateText(Answer(Hits).finish(&.{}, cert, &first));
    defer testing.allocator.free(one);
    const two = try certificateText(Answer(Hits).finish(&.{}, cert, &second));
    defer testing.allocator.free(two);
    try testing.expectEqualStrings(one, two);
    try testing.expect(std.mem.indexOf(u8, one, "\"missing\":[{\"path\":\"a.ts\"") != null);
    try testing.expect(std.mem.indexOf(u8, one, "\"budgets\":[{\"limit\":\"file_bytes\"") != null);
}

test "the certificate names the scope, the semantics and the snapshot algorithm" {
    var cert = textCert(3, 4);
    cert.scope.prefix = "src";
    cert.scope.excluded.set(.internal, 1);
    const text = try certificateText(Answer(Hits).finish(&.{}, cert, &.{}));
    defer testing.allocator.free(text);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqualStrings("complete", root.get("answer").?.string);
    const snapshot = root.get("snapshot").?.object;
    try testing.expectEqualStrings("sha256", snapshot.get("digest").?.string);
    try testing.expectEqualStrings("rfc9162", snapshot.get("tree").?.string);
    try testing.expectEqual(@as(i64, 7), snapshot.get("barrier").?.integer);
    const scope = root.get("scope").?.object;
    try testing.expectEqualStrings("src", scope.get("prefix").?.string);
    try testing.expectEqual(@as(i64, 3), scope.get("in_scope").?.integer);
    try testing.expectEqual(@as(i64, 1), scope.get("excluded").?.object.get("internal").?.integer);
    const text_semantics = root.get("semantics").?.object.get("text").?.object;
    try testing.expectEqualStrings("needle", text_semantics.get("pattern").?.string);
    try testing.expectEqual(@as(usize, 3), text_semantics.get("kinds").?.array.items.len);
}

test "a refused answer carries its reason and no certificate" {
    const answer = Answer(Hits).refuse(error.UnknownArgument, "ignoreCase");
    try testing.expect(answer.certificate() == null);
    const text = try certificateText(answer);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("{\"answer\":\"refused\",\"code\":\"UnknownArgument\",\"detail\":\"ignoreCase\"}", text);
}
