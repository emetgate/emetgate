const std = @import("std");
const boundedness = @import("../engine/boundedness.zig");
const run_command = @import("run_command.zig");

const Allocator = std.mem.Allocator;

pub const Gate = enum { full, scoped };

pub const file_placeholder = "{file}";
pub const stem_placeholder = "{stem}";

pub fn chooseGate(confidence: boundedness.Confidence, has_scoped: bool) Gate {
    if (confidence == .bounded and has_scoped) return .scoped;
    return .full;
}

pub fn safeInCommand(rel: []const u8) bool {
    if (rel.len == 0) return false;
    if (run_command.hasShellMetacharacter(rel)) return false;
    return std.mem.indexOfScalar(u8, rel, '"') == null;
}

pub fn stemOf(rel: []const u8) []const u8 {
    return std.fs.path.stem(std.fs.path.basenameWindows(rel));
}

pub fn substituteFile(gpa: Allocator, template: []const u8, rel: []const u8) ![]u8 {
    const stem = stemOf(rel);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < template.len) {
        const rest = template[i..];
        if (std.mem.startsWith(u8, rest, file_placeholder)) {
            try out.appendSlice(gpa, rel);
            i += file_placeholder.len;
        } else if (std.mem.startsWith(u8, rest, stem_placeholder)) {
            try out.appendSlice(gpa, stem);
            i += stem_placeholder.len;
        } else {
            try out.append(gpa, template[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

test "a scoped command gets the file in place of {file} and its name without folder or extension in place of {stem}" {
    const made = try substituteFile(testing.allocator, "zig build test -Dtest-filter={stem} -- {file} {stem}", "src/platform/read_budget.zig");
    defer testing.allocator.free(made);
    try testing.expectEqualStrings("zig build test -Dtest-filter=read_budget -- src/platform/read_budget.zig read_budget", made);
}

test "a scoped command without a placeholder is used as written" {
    const made = try substituteFile(testing.allocator, "npm test", "src/a.ts");
    defer testing.allocator.free(made);
    try testing.expectEqualStrings("npm test", made);
}

test "a placeholder inside the file name is not expanded a second time" {
    const made = try substituteFile(testing.allocator, "run {file}", "src/{stem}.ts");
    defer testing.allocator.free(made);
    try testing.expectEqualStrings("run src/{stem}.ts", made);
}

test "the stem of a backslash path drops the folder and only the last extension" {
    try testing.expectEqualStrings("auth.service", stemOf("src\\auth\\auth.service.ts"));
    try testing.expectEqualStrings("Makefile", stemOf("Makefile"));
}

test "a path with a shell metacharacter or a quote is not put into a command" {
    try testing.expect(safeInCommand("src/auth/login.ts"));
    try testing.expect(safeInCommand("src/my file.ts"));
    try testing.expect(!safeInCommand("src/a&calc.ts"));
    try testing.expect(!safeInCommand("src/a%PATH%.ts"));
    try testing.expect(!safeInCommand("src/a\".ts"));
    try testing.expect(!safeInCommand(""));
}

test "only a bounded change with a scoped command takes the scoped gate" {
    try testing.expectEqual(Gate.scoped, chooseGate(.bounded, true));
    try testing.expectEqual(Gate.full, chooseGate(.bounded, false));
    try testing.expectEqual(Gate.full, chooseGate(.unbounded, true));
    try testing.expectEqual(Gate.full, chooseGate(.unbounded, false));
}
