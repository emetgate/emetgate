const std = @import("std");
const emetgate = @import("emetgate");
const cas = emetgate.cas;
const symbol = emetgate.symbol;
const test_util = emetgate.test_util;

const testing = std.testing;

const base_source = "function f() { return 1; }\nfunction g() { return 2; }\n";

const seed_corpus = [_][]const u8{
    "",
    "{ return 3; }",
    "{ return 1;",
    "{ return 1; } function evil() {}",
    "{ } function evil() { return 0; }",
    "{ return 1; } // trailing",
    "\x00",
    "\xff\xfe\xfd",
    "{ return 1;\x00 }",
    "{" ++ "a;" ** 200 ++ "}",
    "function f() { return 9; }\nfunction g() { return 2; }\n",
};

fn testOne(_: void, smith: *testing.Smith) anyerror!void {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime, base_source);
    defer base.destroy();

    const ref: symbol.Ref = .{ .name = "f" };
    const table = base.symbols() catch return;
    const target = table.resolve(ref) catch return;
    const cut_start = target.body.startByte();
    const cut_end = target.body.endByte();

    const result = cas.apply(base, .{ .ref = ref, .expected_hash = target.hash, .new_body = smith.in.? }) catch return;
    defer result.snapshot.destroy();

    const out = result.snapshot.source;
    try testing.expectEqualStrings(base_source[0..cut_start], out[0..cut_start]);
    const tail_len = base_source.len - cut_end;
    try testing.expectEqualStrings(base_source[cut_end..], out[out.len - tail_len ..]);
}

test "fuzz: cas.apply on a fixed base and hash either refuses or leaves everything outside the slot byte-identical" {
    try testing.fuzz({}, testOne, .{ .corpus = &seed_corpus });
}
