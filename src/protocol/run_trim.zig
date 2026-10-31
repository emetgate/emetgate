const std = @import("std");
const command_danger = @import("../platform/command_danger.zig");

const Allocator = std.mem.Allocator;

pub const general_budget = 4 * 1024;
pub const file_budget = 16 * 1024;
pub const raw_cap = 64 * 1024;
pub const stderr_mark = "[stderr]";
pub const raw_hint = "raw:true returns all";

pub const Shape = struct {
    git: bool = false,
    test_run: bool = false,
    file_dump: bool = false,

    pub fn budget(self: Shape) usize {
        return if (self.file_dump) file_budget else general_budget;
    }
};

const dumpers = [_][]const u8{ "cat", "sed", "head", "tail", "type", "more", "less", "get-content", "gc", "nl", "bat", "tac", "xxd", "od", "hexdump", "awk", "jq", "yq" };
const test_runners = [_][]const u8{ "pytest", "py.test", "jest", "vitest", "mocha", "ava", "tap", "ctest", "tox", "nox", "phpunit", "rspec", "nextest", "karma", "playwright", "cypress", "bats" };
const test_hosts = [_][]const u8{ "npm", "pnpm", "yarn", "bun", "deno", "cargo", "go", "zig", "dotnet", "mvn", "mvnw", "gradle", "gradlew", "make", "mix", "swift", "flutter", "dart", "rake", "bundle", "sbt", "lein", "stack", "cabal", "npx", "pnpx", "bunx" };
const test_words = [_][]const u8{ "test", "tests", "unittest", "pytest", "test:unit", "test:all", "nextest", "jest", "vitest", "mocha" };

pub fn shapeOf(arena: Allocator, command: []const u8, test_command: ?[]const u8) !Shape {
    var shape: Shape = .{};
    if (test_command) |configured| {
        if (configured.len != 0 and std.mem.eql(u8, std.mem.trim(u8, configured, " \t"), std.mem.trim(u8, command, " \t"))) shape.test_run = true;
    }
    const segments = try command_danger.parse(arena, command);
    var last: []const []const u8 = &.{};
    for (segments) |segment| {
        const words = command_danger.unwrap(segment.words.items);
        if (words.len == 0) continue;
        last = words;
        if (command_danger.is(words[0], &.{"git"})) shape.git = true;
        if (isTestRun(words)) shape.test_run = true;
    }
    if (last.len != 0 and command_danger.is(last[0], &dumpers)) shape.file_dump = true;
    return shape;
}

fn isTestRun(words: []const []const u8) bool {
    if (command_danger.is(words[0], &test_runners)) return true;
    if (command_danger.is(words[0], &.{ "python", "python3", "py" })) {
        var k: usize = 1;
        while (k + 1 < words.len) : (k += 1) {
            if (std.mem.eql(u8, words[k], "-m")) return eqlAny(words[k + 1], &.{ "pytest", "unittest", "nose2", "tox", "nox" });
        }
        return false;
    }
    if (!command_danger.is(words[0], &test_hosts)) return false;
    for (words[1..@min(words.len, 4)]) |word| {
        if (eqlAny(word, &test_words)) return true;
        if (command_danger.is(word, &test_runners)) return true;
    }
    return false;
}

fn eqlAny(word: []const u8, options: []const []const u8) bool {
    for (options) |option| {
        if (std.ascii.eqlIgnoreCase(word, option)) return true;
    }
    return false;
}

const git_progress = [_][]const u8{ "Enumerating objects:", "Counting objects:", "Compressing objects:", "Writing objects:", "Receiving objects:", "Resolving deltas:", "Unpacking objects:", "Delta compression using", "Total ", "Updating files:", "Checking out files:", "Filtering content:", "Updating index flags:", "Refreshing index:" };

pub fn isGitNoise(line: []const u8) bool {
    const text = std.mem.trim(u8, line, " \t\r");
    if (std.mem.startsWith(u8, text, "hint:")) return true;
    if (std.mem.startsWith(u8, text, "warning:") and (std.mem.indexOf(u8, text, "CRLF") != null or std.mem.indexOf(u8, text, " LF will be replaced") != null)) return true;
    var body = text;
    if (std.mem.startsWith(u8, body, "remote:")) {
        body = std.mem.trim(u8, body["remote:".len..], " \t");
        if (body.len == 0) return true;
    }
    for (git_progress) |start| {
        if (std.mem.startsWith(u8, body, start)) return true;
    }
    return false;
}

pub const Filtered = struct { text: []u8, dropped: usize };

pub fn dropGitNoise(gpa: Allocator, text: []const u8) !Filtered {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var dropped: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = lastProgressFrame(raw);
        if (isGitNoise(line) and std.mem.trim(u8, line, " \t\r").len != 0) {
            dropped += 1;
            continue;
        }
        if (!first) try out.append(gpa, '\n');
        first = false;
        try out.appendSlice(gpa, line);
    }
    return .{ .text = try out.toOwnedSlice(gpa), .dropped = dropped };
}

fn lastProgressFrame(line: []const u8) []const u8 {
    const body = std.mem.trimEnd(u8, line, "\r");
    const cut = std.mem.lastIndexOfScalar(u8, body, '\r') orelse return line;
    return body[cut + 1 ..];
}

pub fn joined(gpa: Allocator, stdout: []const u8, stderr: []const u8) ![]u8 {
    if (stderr.len == 0) return gpa.dupe(u8, stdout);
    const gap: []const u8 = if (stdout.len == 0) "" else if (stdout[stdout.len - 1] == '\n') "" else "\n";
    return std.mem.concat(gpa, u8, &.{ stdout, gap, stderr_mark, "\n", stderr });
}

pub const Cut = struct { text: []u8, lines_cut: usize };

pub fn headTail(gpa: Allocator, text: []const u8, budget: usize, label: []const u8) !Cut {
    if (text.len <= budget) return .{ .text = try gpa.dupe(u8, text), .lines_cut = 0 };
    const half = budget / 2;
    var head_end = if (std.mem.lastIndexOfScalar(u8, text[0..half], '\n')) |nl| nl + 1 else half;
    head_end = charStart(text, head_end);
    const tail_from = text.len - half;
    var tail_start = if (std.mem.indexOfScalarPos(u8, text, tail_from, '\n')) |nl| nl + 1 else tail_from;
    if (tail_start >= text.len) tail_start = tail_from;
    tail_start = charStart(text, tail_start);
    if (tail_start < head_end) tail_start = head_end;
    const middle = text[head_end..tail_start];
    var lines = std.mem.count(u8, middle, "\n");
    if (middle.len != 0 and middle[middle.len - 1] != '\n') lines += 1;
    const note = try std.fmt.allocPrint(gpa, "[emetgate: {d} lines ({d} bytes) cut; {s}]\n", .{ lines, middle.len, label });
    defer gpa.free(note);
    const lead: []const u8 = if (head_end != 0 and text[head_end - 1] != '\n') "\n" else "";
    return .{ .text = try std.mem.concat(gpa, u8, &.{ text[0..head_end], lead, note, text[tail_start..] }), .lines_cut = lines };
}

fn charStart(text: []const u8, index: usize) usize {
    var i = index;
    while (i > 0 and i < text.len and text[i] & 0xC0 == 0x80) i -= 1;
    return i;
}

const testing = std.testing;

test "run trim: git noise lines go and the rest stays in order" {
    const stderr =
        "warning: in the working copy of 'a.txt', LF will be replaced by CRLF the next time Git touches it\n" ++
        "Enumerating objects: 5, done.\n" ++
        "Counting objects:  50% (2/4)\rCounting objects: 100% (4/4), done.\n" ++
        "Writing objects: 100% (3/3), 300 bytes | 300.00 KiB/s, done.\n" ++
        "Total 3 (delta 1), reused 0 (delta 0), pack-reused 0\n" ++
        "remote: Resolving deltas: 100% (1/1), completed with 1 local object.\n" ++
        "remote: \n" ++
        "remote: Create a pull request for 'feat' on GitHub by visiting:\n" ++
        "hint: Updates were rejected because the tip of your current branch is behind\n" ++
        "To github.com:o/r.git\n" ++
        "   1234567..89abcde  main -> main";
    const got = try dropGitNoise(testing.allocator, stderr);
    defer testing.allocator.free(got.text);
    try testing.expectEqual(@as(usize, 8), got.dropped);
    try testing.expectEqualStrings("remote: Create a pull request for 'feat' on GitHub by visiting:\nTo github.com:o/r.git\n   1234567..89abcde  main -> main", got.text);
}

test "run trim: a warning that is not about line endings stays" {
    try testing.expect(!isGitNoise("warning: refname 'x' is ambiguous."));
    try testing.expect(!isGitNoise("error: failed to push some refs"));
    try testing.expect(!isGitNoise("remote: error: GH006: Protected branch update failed"));
    try testing.expect(isGitNoise("warning: CRLF will be replaced by LF in x."));
}

test "run trim: long output keeps head and tail with a labeled cut" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..1000) |i| try text.print(testing.allocator, "line {d}\n", .{i});
    const cut = try headTail(testing.allocator, text.items, general_budget, raw_hint);
    defer testing.allocator.free(cut.text);
    try testing.expect(cut.text.len < general_budget + 100);
    try testing.expect(std.mem.startsWith(u8, cut.text, "line 0\nline 1\n"));
    try testing.expect(std.mem.endsWith(u8, cut.text, "line 999\n"));
    const note_at = std.mem.indexOf(u8, cut.text, "[emetgate: ").?;
    try testing.expect(note_at > 0 and cut.text[note_at - 1] == '\n');
    var kept: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, cut.text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "line ")) kept += 1;
    }
    try testing.expectEqual(@as(usize, 1000), kept + cut.lines_cut);
    const label = try std.fmt.allocPrint(testing.allocator, "[emetgate: {d} lines", .{cut.lines_cut});
    defer testing.allocator.free(label);
    try testing.expect(std.mem.indexOf(u8, cut.text, label) != null);
    try testing.expect(std.mem.indexOf(u8, cut.text, "raw:true returns all]") != null);
}

test "run trim: short output is returned whole" {
    const cut = try headTail(testing.allocator, "a\nb\n", general_budget, raw_hint);
    defer testing.allocator.free(cut.text);
    try testing.expectEqualStrings("a\nb\n", cut.text);
    try testing.expectEqual(@as(usize, 0), cut.lines_cut);
}

test "run trim: one huge line is cut on a character boundary" {
    const text = try testing.allocator.alloc(u8, 3 * 9000);
    defer testing.allocator.free(text);
    for (0..9000) |i| @memcpy(text[i * 3 ..][0..3], "\u{20ac}");
    const cut = try headTail(testing.allocator, text, general_budget, raw_hint);
    defer testing.allocator.free(cut.text);
    try testing.expect(std.unicode.utf8ValidateSlice(cut.text));
    try testing.expectEqual(@as(usize, 1), cut.lines_cut);
}

test "run trim: stderr follows stdout under a mark" {
    const both = try joined(testing.allocator, "out", "err\n");
    defer testing.allocator.free(both);
    try testing.expectEqualStrings("out\n[stderr]\nerr\n", both);
    const only = try joined(testing.allocator, "out\n", "");
    defer testing.allocator.free(only);
    try testing.expectEqualStrings("out\n", only);
}

test "run trim: the shape follows the programs in the command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try shapeOf(a, "git push origin main", null)).git);
    try testing.expect((try shapeOf(a, "cd sub && git status", null)).git);
    try testing.expect(!(try shapeOf(a, "echo git", null)).git);
    try testing.expect((try shapeOf(a, "cat src/main.zig", null)).file_dump);
    try testing.expect((try shapeOf(a, "sed -n '1,400p' a.zig", null)).file_dump);
    try testing.expect(!(try shapeOf(a, "cat a.zig | grep x", null)).file_dump);
    try testing.expectEqual(file_budget, (try shapeOf(a, "head -n 500 a", null)).budget());
    try testing.expectEqual(general_budget, (try shapeOf(a, "ls -R", null)).budget());
    for ([_][]const u8{ "npm test", "npm run test", "pnpm test -- --watch=false", "cargo test", "go test ./...", "zig build test", "python -m pytest -q", "pytest tests/x.py", "npx vitest run", "dotnet test", "FOO=1 npm test" }) |command| {
        if (!(try shapeOf(a, command, null)).test_run) {
            std.debug.print("not a test run: {s}\n", .{command});
            return error.TestExpectedTestRun;
        }
    }
    for ([_][]const u8{ "npm install", "cargo build", "go vet ./...", "ls test", "cat test.txt", "python script.py test" }) |command| {
        if ((try shapeOf(a, command, null)).test_run) {
            std.debug.print("a test run: {s}\n", .{command});
            return error.TestUnexpectedTestRun;
        }
    }
    try testing.expect((try shapeOf(a, "./run-all.sh", "./run-all.sh")).test_run);
}
