const std = @import("std");
const registry = @import("emetgate").lang_registry;
const Profile = @import("emetgate").lang_profile.Profile;
const symbol = @import("emetgate").symbol;
const cas = @import("emetgate").cas;
const skeleton = @import("emetgate").skeleton;
const boundedness = @import("emetgate").boundedness;
const Runtime = @import("emetgate").runtime.Runtime;
const Snapshot = @import("emetgate").loader.Snapshot;

const testing = std.testing;

fn zigProfile() *const Profile {
    for (registry.profiles) |profile| {
        if (std.mem.eql(u8, profile.name, "zig")) return profile;
    }
    @panic("zig profile not registered");
}

const Case = struct {
    runtime: *Runtime,
    snapshot: *Snapshot,

    fn init(src: []const u8) !Case {
        const runtime = try Runtime.create(testing.allocator);
        errdefer runtime.destroy() catch {};
        const owned = try testing.allocator.dupe(u8, src);
        const snapshot = try Snapshot.fromSource(runtime, zigProfile(), owned);
        return .{ .runtime = runtime, .snapshot = snapshot };
    }

    fn deinit(self: *Case) void {
        self.snapshot.destroy();
        self.runtime.destroy() catch @panic("live snapshots");
    }

    fn resolve(self: *Case, ref_text: []const u8) !*const symbol.Symbol {
        const ref = try symbol.Ref.parse(testing.allocator, ref_text);
        defer ref.deinit(testing.allocator);
        return (try self.snapshot.symbols()).resolve(ref);
    }

    fn analyze(self: *Case, ref_text: []const u8) !boundedness.FrameReport {
        const ref = try symbol.Ref.parse(testing.allocator, ref_text);
        defer ref.deinit(testing.allocator);
        const target = try self.resolve(ref_text);
        return boundedness.analyze(testing.allocator, self.snapshot, ref, .{ .start = target.body.startByte(), .end = target.body.endByte() });
    }
};

test "zig: a pub top-level function is unbounded, a private one called in-file is bounded" {
    var case = try Case.init(
        \\pub fn api() i32 {
        \\  return helper();
        \\}
        \\fn helper() i32 {
        \\  return 1;
        \\}
        \\
    );
    defer case.deinit();

    const exported = try case.analyze("api");
    defer exported.deinit();
    try testing.expectEqual(boundedness.Confidence.unbounded, exported.confidence);
    try testing.expectEqual(boundedness.Provenance.exported_escape, exported.provenance.?);

    const private = try case.analyze("helper");
    defer private.deinit();
    try testing.expectEqual(boundedness.Confidence.bounded, private.confidence);
    try testing.expectEqual(@as(usize, 1), private.same_file_refs.len);
}

test "zig: a stale hash, a placeholder and an escaping body are refused, the neighbour hash is untouched" {
    var case = try Case.init(
        \\fn target(a: i32) i32 {
        \\  return a + 1;
        \\}
        \\fn neighbour() i32 {
        \\  return target(1);
        \\}
        \\
    );
    defer case.deinit();

    const before = try case.resolve("target");
    const hash = before.hash;
    const neighbour_before = (try case.resolve("neighbour")).hash;

    try testing.expectError(error.HashMismatch, cas.apply(case.snapshot, .{
        .ref = try symbol.Ref.parse(testing.allocator, "target"),
        .expected_hash = symbol.hashOf("stale view"),
        .new_body = "{ return a + 2; }",
    }));
    try testing.expectError(error.PlaceholderBody, cas.apply(case.snapshot, .{
        .ref = try symbol.Ref.parse(testing.allocator, "target"),
        .expected_hash = hash,
        .new_body = "{\n  // TODO\n}",
    }));
    try testing.expectError(error.BodyEscape, cas.apply(case.snapshot, .{
        .ref = try symbol.Ref.parse(testing.allocator, "target"),
        .expected_hash = hash,
        .new_body = "{ return 1; } fn evil() void {}",
    }));

    const applied = try cas.apply(case.snapshot, .{
        .ref = try symbol.Ref.parse(testing.allocator, "target"),
        .expected_hash = hash,
        .new_body = "{ return a + 2; }",
    });
    defer applied.snapshot.destroy();
    try testing.expect(std.mem.indexOf(u8, applied.snapshot.source, "return a + 2;") != null);

    const ref = try symbol.Ref.parse(testing.allocator, "neighbour");
    defer ref.deinit(testing.allocator);
    const neighbour_after = try (try applied.snapshot.symbols()).resolve(ref);
    try testing.expectEqual(neighbour_before, neighbour_after.hash);
}

test "zig: a function referenced only through @call's identifier argument is unbounded (first-class escape)" {
    var case = try Case.init(
        \\fn process(x: i32) i32 {
        \\  return x;
        \\}
        \\const dispatched = @call(.auto, process, .{1});
        \\
    );
    defer case.deinit();

    const report = try case.analyze("process");
    defer report.deinit();
    try testing.expectEqual(boundedness.Confidence.unbounded, report.confidence);
}

test "zig: a function named by string inside @hasDecl is unbounded (string-key escape)" {
    var case = try Case.init(
        \\fn process(x: i32) i32 {
        \\  return x;
        \\}
        \\const has_it = @hasDecl(@This(), "process");
        \\
    );
    defer case.deinit();

    const report = try case.analyze("process");
    defer report.deinit();
    try testing.expectEqual(boundedness.Confidence.unbounded, report.confidence);
    try testing.expectEqual(boundedness.Provenance.string_key_escape, report.provenance.?);
}

test "zig: a test block does not disturb a neighbouring function's symbol or hash" {
    var case = try Case.init(
        \\fn target(a: i32) i32 {
        \\  return a + 1;
        \\}
        \\test "target adds one" {
        \\  const std = @import("std");
        \\  try std.testing.expectEqual(@as(i32, 2), target(1));
        \\}
        \\
    );
    defer case.deinit();

    const found = try case.resolve("target");
    try testing.expectEqual(symbol.Kind.function, found.kind);

    const applied = try cas.apply(case.snapshot, .{
        .ref = try symbol.Ref.parse(testing.allocator, "target"),
        .expected_hash = found.hash,
        .new_body = "{ return a + 2; }",
    });
    defer applied.snapshot.destroy();
    try testing.expect(std.mem.indexOf(u8, applied.snapshot.source, "test \"target adds one\"") != null);
}

test "zig: a function nested in a struct literal is still CAS-addressable by its bare name" {
    var case = try Case.init(
        \\const Box = struct {
        \\  fn make() i32 {
        \\    return 1;
        \\  }
        \\};
        \\fn caller() i32 {
        \\  return Box.make();
        \\}
        \\
    );
    defer case.deinit();

    const found = try case.resolve("make");
    try testing.expectEqual(symbol.Kind.function, found.kind);

    const applied = try cas.apply(case.snapshot, .{
        .ref = try symbol.Ref.parse(testing.allocator, "make"),
        .expected_hash = found.hash,
        .new_body = "{ return 2; }",
    });
    defer applied.snapshot.destroy();
    try testing.expect(std.mem.indexOf(u8, applied.snapshot.source, "return 2;") != null);
}

test "zig: the skeleton hides bodies as bodyless declarations and is a fixed point" {
    var case = try Case.init(
        \\pub fn api(a: i32) i32 {
        \\  return a + helper(a);
        \\}
        \\fn helper(a: i32) i32 {
        \\  return a * 2;
        \\}
        \\
    );
    defer case.deinit();

    const first = try skeleton.skeletonize(testing.allocator, case.runtime.parser, zigProfile(), case.snapshot.tree);
    defer testing.allocator.free(first);
    try testing.expect(first.len < case.snapshot.source.len);
    try testing.expect(std.mem.indexOf(u8, first, "pub fn api(a: i32) i32;") != null);

    const reparsed = try Snapshot.fromSource(case.runtime, zigProfile(), try testing.allocator.dupe(u8, first));
    defer reparsed.destroy();
    try testing.expect(!reparsed.tree.root().hasError());
    const second = try skeleton.skeletonize(testing.allocator, case.runtime.parser, zigProfile(), reparsed.tree);
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(first, second);
}
