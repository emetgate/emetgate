const std = @import("std");
const cas = @import("../../src/engine/cas.zig");
const symbol = @import("../../src/engine/symbol.zig");
const skeleton = @import("../../src/engine/skeleton.zig");
const boundedness = @import("../../src/engine/boundedness.zig");
const registry = @import("../../src/engine/lang/registry.zig");
const Profile = @import("../../src/engine/lang/profile.zig").Profile;
const Runtime = @import("../../src/engine/runtime.zig").Runtime;
const Snapshot = @import("../../src/engine/loader.zig").Snapshot;
const cases_mod = @import("cases.zig");

const Cases = cases_mod.Cases;
const testing = std.testing;

fn casesFor(profile: *const Profile) ?Cases {
    for (cases_mod.all) |entry| {
        if (std.mem.eql(u8, entry.language, profile.name)) return entry.cases;
    }
    return null;
}

const Language = struct {
    runtime: *Runtime,
    profile: *const Profile,
    cases: Cases,
    base: *Snapshot,

    fn open(profile: *const Profile) !Language {
        const cases = casesFor(profile) orelse return error.MissingConformanceCases;
        const runtime = try Runtime.create(testing.allocator);
        errdefer runtime.destroy() catch {};
        const base = try Snapshot.fromSource(runtime, profile, try testing.allocator.dupe(u8, cases.source));
        return .{ .runtime = runtime, .profile = profile, .cases = cases, .base = base };
    }

    fn close(self: Language) void {
        self.base.destroy();
        self.runtime.destroy() catch @panic("live snapshots");
    }

    fn resolve(snapshot: *Snapshot, ref_text: []const u8) !*const symbol.Symbol {
        const ref = try symbol.Ref.parse(testing.allocator, ref_text);
        defer ref.deinit(testing.allocator);
        return (try snapshot.symbols()).resolve(ref);
    }

    fn apply(self: Language, ref_text: []const u8, expected_hash: symbol.Hash, body: []const u8) !cas.Applied {
        const ref = try symbol.Ref.parse(testing.allocator, ref_text);
        defer ref.deinit(testing.allocator);
        return cas.apply(self.base, .{ .ref = ref, .expected_hash = expected_hash, .new_body = body });
    }

    fn targetHash(self: Language) !symbol.Hash {
        return (try resolve(self.base, self.cases.target_ref)).hash;
    }

    fn analyze(self: Language, ref_text: []const u8) !boundedness.FrameReport {
        const ref = try symbol.Ref.parse(testing.allocator, ref_text);
        defer ref.deinit(testing.allocator);
        const target = try resolve(self.base, ref_text);
        return boundedness.analyze(testing.allocator, self.base, ref, .{ .start = target.body.startByte(), .end = target.body.endByte() });
    }
};

test "every registered language has conformance cases" {
    for (registry.profiles) |profile| {
        errdefer std.debug.print("no conformance cases for {s}\n", .{profile.name});
        try testing.expect(casesFor(profile) != null);
    }
}

test "conformance: an edit replaces only the addressed body and keeps the neighbour hash" {
    for (registry.profiles) |profile| {
        errdefer std.debug.print("language: {s}\n", .{profile.name});
        const lang = try Language.open(profile);
        defer lang.close();

        const neighbour_before = (try Language.resolve(lang.base, lang.cases.neighbour_ref)).hash;
        const applied = try lang.apply(lang.cases.target_ref, try lang.targetHash(), lang.cases.valid_body);
        defer applied.snapshot.destroy();

        try testing.expect(std.mem.indexOf(u8, applied.snapshot.source, cas.normalizeBody(lang.cases.valid_body)) != null);
        try testing.expectEqual(neighbour_before, (try Language.resolve(applied.snapshot, lang.cases.neighbour_ref)).hash);
        try testing.expectEqual(applied.hash, (try Language.resolve(applied.snapshot, lang.cases.target_ref)).hash);
    }
}

test "conformance: a stale hash, a placeholder, an escaping body and a broken body are refused" {
    for (registry.profiles) |profile| {
        errdefer std.debug.print("language: {s}\n", .{profile.name});
        const lang = try Language.open(profile);
        defer lang.close();
        const hash = try lang.targetHash();

        try testing.expectError(error.HashMismatch, lang.apply(lang.cases.target_ref, symbol.hashOf("stale view"), lang.cases.valid_body));
        try testing.expectError(error.PlaceholderBody, lang.apply(lang.cases.target_ref, hash, lang.cases.placeholder_body));
        try testing.expectError(error.BodyEscape, lang.apply(lang.cases.target_ref, hash, lang.cases.escaping_body));
        try testing.expectError(error.MutationSyntaxInvalid, lang.apply(lang.cases.target_ref, hash, lang.cases.broken_body));
        try testing.expectEqual(@as(usize, 1), lang.runtime.live_snapshots);
    }
}

test "conformance: an exported symbol is unbounded and a private one called in the file is bounded" {
    for (registry.profiles) |profile| {
        errdefer std.debug.print("language: {s}\n", .{profile.name});
        const lang = try Language.open(profile);
        defer lang.close();

        const exported = try lang.analyze(lang.cases.exported_ref);
        defer exported.deinit();
        try testing.expectEqual(boundedness.Confidence.unbounded, exported.confidence);
        try testing.expectEqual(boundedness.Provenance.exported_escape, exported.provenance.?);

        const private = try lang.analyze(lang.cases.target_ref);
        defer private.deinit();
        try testing.expectEqual(boundedness.Confidence.bounded, private.confidence);
        try testing.expectEqual(@as(usize, 1), private.same_file_refs.len);
    }
}

test "conformance: an optional call is not a plain call, so the callee is unbounded" {
    for (registry.profiles) |profile| {
        errdefer std.debug.print("language: {s}\n", .{profile.name});
        const cases = casesFor(profile) orelse return error.MissingConformanceCases;
        const runtime = try Runtime.create(testing.allocator);
        defer runtime.destroy() catch @panic("live snapshots");
        const snapshot = try Snapshot.fromSource(runtime, profile, try testing.allocator.dupe(u8, cases.optional_call_source));
        defer snapshot.destroy();
        try testing.expect(!snapshot.tree.root().hasError());

        const ref = try symbol.Ref.parse(testing.allocator, cases.target_ref);
        defer ref.deinit(testing.allocator);
        const target = try (try snapshot.symbols()).resolve(ref);
        const report = boundedness.analyze(testing.allocator, snapshot, ref, .{ .start = target.body.startByte(), .end = target.body.endByte() });
        defer report.deinit();
        try testing.expectEqual(boundedness.Confidence.unbounded, report.confidence);
    }
}

test "conformance: the skeleton is valid, smaller and a fixed point" {
    for (registry.profiles) |profile| {
        errdefer std.debug.print("language: {s}\n", .{profile.name});
        const lang = try Language.open(profile);
        defer lang.close();

        const first = try skeleton.skeletonize(testing.allocator, lang.runtime.parser, profile, lang.base.tree);
        defer testing.allocator.free(first);
        try testing.expect(first.len < lang.base.source.len);

        const reparsed = try Snapshot.fromSource(lang.runtime, profile, try testing.allocator.dupe(u8, first));
        defer reparsed.destroy();
        try testing.expect(!reparsed.tree.root().hasError());
        const second = try skeleton.skeletonize(testing.allocator, lang.runtime.parser, profile, reparsed.tree);
        defer testing.allocator.free(second);
        try testing.expectEqualStrings(first, second);
    }
}

test "conformance: every symbol resolves back to itself through its canonical ref" {
    for (registry.profiles) |profile| {
        errdefer std.debug.print("language: {s}\n", .{profile.name});
        const lang = try Language.open(profile);
        defer lang.close();

        const table = try lang.base.symbols();
        try testing.expect(table.symbols.len >= 3);
        var buf: [256]u8 = undefined;
        for (table.symbols) |*entry| {
            try testing.expect(!entry.ambiguous);
            const text = try std.fmt.bufPrint(&buf, "{f}", .{entry.ref});
            try testing.expectEqual(entry, try Language.resolve(lang.base, text));
        }
    }
}
