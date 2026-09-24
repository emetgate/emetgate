const std = @import("std");
const changes = @import("../tools/mutate/changes.zig");

const testing = std.testing;
const Range = changes.Range;

const diff =
    \\diff --git a/src/a.zig b/src/a.zig
    \\index 1111111..2222222 100644
    \\--- a/src/a.zig
    \\+++ b/src/a.zig
    \\@@ -3 +3 @@ fn x() void {
    \\-    old();
    \\+    new();
    \\@@ -10,2 +10,0 @@ fn y() void {
    \\-    gone();
    \\-    gone();
    \\@@ -20,0 +19,3 @@ fn z() void {
    \\+    a();
    \\+    b();
    \\+    c();
    \\diff --git a/tests/b.zig b/tests/b.zig
    \\deleted file mode 100644
    \\index 3333333..0000000
    \\--- a/tests/b.zig
    \\+++ /dev/null
    \\@@ -1,2 +0,0 @@
    \\-test "b" {}
    \\-const x = 1;
    \\diff --git a/tests/c.json b/tests/c.json
    \\new file mode 100644
    \\index 0000000..4444444
    \\--- /dev/null
    \\+++ b/tests/c.json
    \\@@ -0,0 +1,4 @@
    \\+{
    \\+  "a": 1
    \\+}
    \\+
    \\
;

test "changes: a unified=0 diff gives the changed lines of every file that still exists, a deletion included" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const files = try changes.parseDiff(arena_state.allocator(), diff);
    try testing.expectEqual(@as(usize, 2), files.len);
    try testing.expectEqualStrings("src/a.zig", files[0].path);
    try testing.expectEqualSlices(Range, &.{ .{ .first = 3, .last = 3 }, .{ .first = 10, .last = 11 }, .{ .first = 19, .last = 21 } }, files[0].ranges);
    try testing.expectEqualStrings("tests/c.json", files[1].path);
    try testing.expectEqualSlices(Range, &.{.{ .first = 1, .last = 4 }}, files[1].ranges);
    try testing.expect(changes.rangesOf(files, "tests/b.zig") == null);
}

test "changes: a from text is touched when one of its lines meets a changed line, and stale when it is gone" {
    const source = "line one\nline two\nline three\nline four\n";
    try testing.expectEqual(changes.FromState.touched, changes.fromState(source, "two\nline three", &.{.{ .first = 3, .last = 3 }}));
    try testing.expectEqual(changes.FromState.touched, changes.fromState(source, "line two", &.{.{ .first = 1, .last = 2 }}));
    try testing.expectEqual(changes.FromState.untouched, changes.fromState(source, "line two", &.{ .{ .first = 1, .last = 1 }, .{ .first = 3, .last = 4 } }));
    try testing.expectEqual(changes.FromState.untouched, changes.fromState(source, "line four\n", &.{.{ .first = 5, .last = 6 }}));
    try testing.expectEqual(changes.FromState.stale, changes.fromState(source, "line five", &.{}));
    try testing.expectEqual(changes.FromState.stale, changes.fromState(source, "", &.{}));
    try testing.expectEqual(Range{ .first = 2, .last = 3 }, changes.lineRange(source, 9, 18));
}

test "changes: a test whose lines changed is named, an untouched one is not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source =
        \\const std = @import("std");
        \\
        \\test "first \x41" {
        \\    try std.testing.expect(true);
        \\}
        \\
        \\test named_decl {
        \\    try std.testing.expect(true);
        \\}
        \\
        \\test "third" {}
        \\
    ;
    const names = try changes.changedTests(arena_state.allocator(), source, &.{ .{ .first = 4, .last = 4 }, .{ .first = 8, .last = 8 } });
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("first A", names[0]);
    try testing.expectEqualStrings("named_decl", names[1]);
    const none = try changes.changedTests(arena_state.allocator(), source, &.{.{ .first = 1, .last = 2 }});
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "changes: a kill or a filter that names a changed test selects the mutant" {
    const changed = [_][]const u8{ "memory: RT6 an append is refused", "scan: a call budget" };
    try testing.expectEqualStrings("scan: a call budget", changes.namesATest(&changed, &.{"scan: a call budget"}, &.{}).?);
    try testing.expectEqualStrings("memory: RT6 an append is refused", changes.namesATest(&changed, &.{}, &.{"memory: "}).?);
    try testing.expect(changes.namesATest(&changed, &.{"scan: a call"}, &.{"rule: "}) == null);
}

test "changes: an entry that is new or differs from the one at the ref counts as changed" {
    try testing.expect(changes.entryChanged(null, "{\"id\":\"A\"}"));
    try testing.expect(changes.entryChanged("{\"id\":\"A\",\"to\":\"x\"}", "{\"id\":\"A\",\"to\":\"y\"}"));
    try testing.expect(!changes.entryChanged("{\"id\":\"A\"}", "{\"id\":\"A\"}"));
}
