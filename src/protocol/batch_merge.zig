const std = @import("std");
const tool_names = @import("../engine/tool_names.zig");
const symbol = @import("../engine/symbol.zig");
const ts = @import("../engine/tree_sitter.zig");
const batch_plan = @import("../platform/batch_plan.zig");
const file_edit = @import("../platform/file_edit.zig");
const wire = @import("wire.zig");

const Allocator = std.mem.Allocator;

pub const Part = struct {
    index: usize,
    expected: symbol.Expected,
    text: batch_plan.Text,
};

pub const Merged = struct {
    expected: symbol.Expected,
    content: []u8,
};

fn lineStart(part: Part) ?u32 {
    return switch (part.text) {
        .region => |r| switch (r.selector) {
            .line_range => |range| range.start,
            else => null,
        },
        else => null,
    };
}

fn lineEnd(part: Part) u32 {
    return part.text.region.selector.line_range.end;
}

fn laterFirst(parts: []const Part, a: usize, b: usize) bool {
    return lineStart(parts[a]).? > lineStart(parts[b]).?;
}

pub fn merge(gpa: Allocator, base: ?[]const u8, file: []const u8, parts: []const Part) !Merged {
    for (parts, 0..) |part, k| {
        if (part.text != .whole) continue;
        const other = if (k == 0) parts[1].index else parts[0].index;
        wire.setFix("edits[{d}] replaces all of {s} and edits[{d}] edits it too; send that file once with its final content, or only as old_string/new_string and line-range items", .{ part.index, file, other });
        return error.ConflictingBatchEdits;
    }
    const original = base orelse {
        wire.setFix("{s} does not exist; create it with one item holding the whole content and hash \"absent\", then edit it in a later call", .{file});
        return error.FileNotFound;
    };
    var current = try gpa.dupe(u8, original);
    errdefer gpa.free(current);

    var ranged: std.ArrayList(usize) = .empty;
    defer ranged.deinit(gpa);
    for (parts, 0..) |part, k| if (lineStart(part) != null) try ranged.append(gpa, k);
    std.mem.sort(usize, ranged.items, parts, laterFirst);
    for (ranged.items[0..ranged.items.len -| 1], ranged.items[@min(1, ranged.items.len)..]) |upper, lower| {
        if (lineEnd(parts[lower]) < lineStart(parts[upper]).?) continue;
        wire.setFix("edits[{d}] and edits[{d}] change overlapping lines of {s}; merge them into one line_start..line_end item", .{ parts[lower].index, parts[upper].index, file });
        return error.OverlappingLineRanges;
    }
    if (ranged.items.len != 0) {
        const parser = ts.Parser.create();
        defer parser.deinit();
        for (ranged.items) |k| {
            const part = parts[k];
            const checked = batch_plan.textAfter(gpa, original, part.expected, part.text) catch |err| return labeled(err, part.index, file);
            gpa.free(checked);
            const next = batch_plan.regionUnderFileHash(gpa, parser, current, part.text.region.selector, part.text.region.new_text) catch |err| return labeled(err, part.index, file);
            gpa.free(current);
            current = next;
        }
    }
    for (parts) |part| {
        if (lineStart(part) != null) continue;
        const next = switch (part.text) {
            .replace => |r| replaced: {
                var matches: usize = 0;
                break :replaced file_edit.replaceUnique(gpa, current, r.old, r.new, r.all, &matches) catch |err| return replaceFailed(err, part.index, file, matches);
            },
            else => batch_plan.textAfter(gpa, current, part.expected, part.text) catch |err| return labeled(err, part.index, file),
        };
        gpa.free(current);
        current = next;
    }
    return .{ .expected = .{ .present = symbol.fileHash(original) }, .content = current };
}

fn replaceFailed(err: anyerror, index: usize, file: []const u8, matches: usize) anyerror {
    switch (err) {
        error.OldStringNotFound => wire.setFix("edits[{d}].old_string is not in {s} once the earlier items for that file are applied (items for one file apply in order, line ranges first); copy it from the text as it reads after them", .{ index, file }),
        error.OldStringNotUnique => wire.setFix("edits[{d}].old_string matches {d} places in {s}; add surrounding lines so it matches once, or pass replace_all:true", .{ index, matches, file }),
        error.NoChange => wire.setFix("edits[{d}]: old_string equals new_string; drop that item", .{index}),
        error.EmptyOldString => wire.setFix("edits[{d}].old_string is empty; give the exact text to replace", .{index}),
        else => return labeled(err, index, file),
    }
    return err;
}

fn labeled(err: anyerror, index: usize, file: []const u8) anyerror {
    if (err == error.OutOfMemory) return err;
    const hint = wire.fixFor(@errorName(err)) orelse "read the file again and resend the items for it";
    var buffer: [1024]u8 = undefined;
    var qualified: std.Io.Writer = .fixed(&buffer);
    tool_names.write(&qualified, hint) catch {};
    wire.setFix("edits[{d}] on {s}: {s}", .{ index, file, qualified.buffered() });
    return err;
}

const testing = std.testing;

fn take() []const u8 {
    return wire.takeFixForTest();
}

test "two old_string items for one file apply in order against the result of the first" {
    const parts = [_]Part{
        .{ .index = 0, .expected = .absent, .text = .{ .replace = .{ .old = "alpha", .new = "beta" } } },
        .{ .index = 1, .expected = .absent, .text = .{ .replace = .{ .old = "beta gamma", .new = "delta" } } },
    };
    const merged = try merge(testing.allocator, "alpha gamma\n", "a.txt", &parts);
    defer testing.allocator.free(merged.content);
    try testing.expectEqualStrings("delta\n", merged.content);
    try testing.expectEqual(symbol.fileHash("alpha gamma\n"), merged.expected.present);
}

test "replace_all items for one file rename every occurrence" {
    const parts = [_]Part{
        .{ .index = 0, .expected = .absent, .text = .{ .replace = .{ .old = "foo", .new = "bar", .all = true } } },
        .{ .index = 1, .expected = .absent, .text = .{ .replace = .{ .old = "x = 1", .new = "x = 2" } } },
    };
    const merged = try merge(testing.allocator, "foo(foo)\nx = 1\n", "a.ts", &parts);
    defer testing.allocator.free(merged.content);
    try testing.expectEqualStrings("bar(bar)\nx = 2\n", merged.content);
}

test "a missing old_string names the item index" {
    const parts = [_]Part{
        .{ .index = 2, .expected = .absent, .text = .{ .replace = .{ .old = "a", .new = "b" } } },
        .{ .index = 5, .expected = .absent, .text = .{ .replace = .{ .old = "a", .new = "c" } } },
    };
    try testing.expectError(error.OldStringNotFound, merge(testing.allocator, "a\n", "f.txt", &parts));
    try testing.expect(std.mem.startsWith(u8, take(), "edits[5].old_string"));
}

test "an ambiguous old_string names the item index and the match count" {
    const parts = [_]Part{
        .{ .index = 0, .expected = .absent, .text = .{ .replace = .{ .old = "q", .new = "r" } } },
        .{ .index = 1, .expected = .absent, .text = .{ .replace = .{ .old = "z", .new = "y" } } },
    };
    try testing.expectError(error.OldStringNotUnique, merge(testing.allocator, "q z z\n", "f.txt", &parts));
    try testing.expect(std.mem.indexOf(u8, take(), "matches 2 places") != null);
}

test "a whole-file item next to another item for the same file is refused with a fix" {
    const parts = [_]Part{
        .{ .index = 0, .expected = .absent, .text = .{ .whole = "new\n" } },
        .{ .index = 1, .expected = .absent, .text = .{ .replace = .{ .old = "a", .new = "b" } } },
    };
    try testing.expectError(error.ConflictingBatchEdits, merge(testing.allocator, "a\n", "f.txt", &parts));
    try testing.expect(std.mem.startsWith(u8, take(), "edits[0] replaces all of f.txt"));
}

test "line ranges for one file apply bottom-up against the lines as read, then old_string items" {
    const base = "one\ntwo\nthree\nfour\n";
    const hash = symbol.fileHash(base);
    const parts = [_]Part{
        .{ .index = 0, .expected = .{ .present = hash }, .text = .{ .region = .{ .selector = .{ .line_range = .{ .start = 1, .end = 1 } }, .new_text = "ONE\nONE-B\n" } } },
        .{ .index = 1, .expected = .{ .present = hash }, .text = .{ .region = .{ .selector = .{ .line_range = .{ .start = 3, .end = 3 } }, .new_text = "THREE\n" } } },
        .{ .index = 2, .expected = .absent, .text = .{ .replace = .{ .old = "four", .new = "FOUR" } } },
    };
    const merged = try merge(testing.allocator, base, "f.txt", &parts);
    defer testing.allocator.free(merged.content);
    try testing.expectEqualStrings("ONE\nONE-B\ntwo\nTHREE\nFOUR\n", merged.content);
}

test "overlapping line ranges for one file are refused with both indexes" {
    const base = "a\nb\nc\n";
    const hash = symbol.fileHash(base);
    const parts = [_]Part{
        .{ .index = 0, .expected = .{ .present = hash }, .text = .{ .region = .{ .selector = .{ .line_range = .{ .start = 1, .end = 2 } }, .new_text = "x\n" } } },
        .{ .index = 1, .expected = .{ .present = hash }, .text = .{ .region = .{ .selector = .{ .line_range = .{ .start = 2, .end = 3 } }, .new_text = "y\n" } } },
    };
    try testing.expectError(error.OverlappingLineRanges, merge(testing.allocator, base, "f.txt", &parts));
    try testing.expect(std.mem.indexOf(u8, take(), "overlapping lines") != null);
}
