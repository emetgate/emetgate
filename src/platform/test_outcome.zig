const std = @import("std");
const sandbox = @import("sandbox.zig");

pub const max_summary = 200;
const tail_lines = 15;
const max_summary_lines = 3;
const separator = " | ";

pub const Summary = struct {
    buf: [max_summary]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Summary) []const u8 {
        return self.buf[0..self.len];
    }

    fn add(self: *Summary, line: []const u8) void {
        if (self.len != 0) self.put(separator);
        self.put(line);
    }

    fn put(self: *Summary, bytes: []const u8) void {
        const take = @min(bytes.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..take], bytes[0..take]);
        self.len += take;
    }
};

const summary_words = [_][]const u8{ "passing", "failing", "pending", "passed", "failed", "skipped", "# pass", "# fail", "# tests", "tests:", "test suites:", "tests run", " ok ", "ran " };

fn hasCount(line: []const u8) bool {
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        if (line[index] == 0x1b) {
            const end = std.mem.indexOfScalarPos(u8, line, index, 'm') orelse return false;
            index = end;
            continue;
        }
        if (std.ascii.isDigit(line[index])) return true;
    }
    return false;
}

pub fn isSummaryLine(line: []const u8) bool {
    if (!hasCount(line)) return false;
    for (summary_words) |word| {
        if (std.ascii.indexOfIgnoreCase(line, word) != null) return true;
    }
    return false;
}

const Lines = struct {
    items: [tail_lines][]const u8 = undefined,
    count: usize = 0,

    fn fromTail(bytes: []const u8) Lines {
        var lines: Lines = .{};
        var end = bytes.len;
        while (end > 0 and lines.count < tail_lines) {
            const start = if (std.mem.lastIndexOfScalar(u8, bytes[0..end], '\n')) |nl| nl + 1 else 0;
            const line = clean(bytes[start..end]);
            if (line.len != 0) {
                lines.items[lines.count] = line;
                lines.count += 1;
            }
            end = if (start == 0) 0 else start - 1;
        }
        return lines;
    }
};

fn clean(line: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, line, " \t\r");
    while (trimmed.len >= 3 and trimmed[0] == 0x1b and trimmed[1] == '[') {
        const end = std.mem.indexOfScalarPos(u8, trimmed, 2, 'm') orelse break;
        trimmed = std.mem.trimStart(u8, trimmed[end + 1 ..], " \t");
    }
    return trimmed;
}

pub fn summarize(report: sandbox.Report) Summary {
    var summary: Summary = .{};
    if (report.no_tests) summary.add(no_tests_note);
    var picked: [max_summary_lines][]const u8 = undefined;
    var count: usize = 0;
    for ([_][]const u8{ report.stdout, report.stderr }) |stream| {
        const lines = Lines.fromTail(stream);
        for (lines.items[0..lines.count]) |line| {
            if (count == picked.len) break;
            if (isSummaryLine(line)) {
                picked[count] = line;
                count += 1;
            }
        }
        if (count != 0) break;
    }
    if (count == 0) {
        if (countLines(report.stdout, &summary)) return summary;
        const lines = Lines.fromTail(if (std.mem.trim(u8, report.stdout, " \t\r\n").len != 0) report.stdout else report.stderr);
        if (lines.count != 0) summary.add(lines.items[0]);
        return summary;
    }
    var index = count;
    while (index > 0) {
        index -= 1;
        summary.add(picked[index]);
    }
    return summary;
}

fn isCountLine(line: []const u8) bool {
    var digits: usize = 0;
    while (digits < line.len and std.ascii.isDigit(line[digits])) digits += 1;
    if (digits == 0 or digits >= line.len or line[digits] != ' ') return false;
    const rest = line[digits + 1 ..];
    for ([_][]const u8{ "passing", "failing", "pending" }) |word| {
        if (std.mem.startsWith(u8, rest, word)) return true;
    }
    return false;
}

fn countLines(stream: []const u8, summary: *Summary) bool {
    var found = false;
    var lines = std.mem.splitScalar(u8, stream, '\n');
    while (lines.next()) |raw| {
        const line = clean(raw);
        if (!isCountLine(line)) continue;
        summary.add(line);
        found = true;
    }
    return found;
}

pub const no_tests_note = "no tests collected; treated as passing";

const pytest_no_tests: u32 = 5;

const no_tests_signs = [_][]const u8{
    "No tests found",
    "No test files found",
    "No test is available",
    "no test files",
};

const pytest_no_tests_signs = [_][]const u8{ "no tests ran", "collected 0 items" };

const failure_signs = [_][]const u8{ "failing", "FAILED", "Failed!", " failed", "error CS", "Build FAILED", "Traceback", "SyntaxError" };

fn containsAny(report: sandbox.Report, signs: []const []const u8) bool {
    for ([_][]const u8{ report.stdout, report.stderr }) |stream| {
        for (signs) |sign| {
            if (std.mem.indexOf(u8, stream, sign) != null) return true;
        }
    }
    return false;
}

pub fn noTests(report: sandbox.Report) bool {
    const code = switch (report.outcome) {
        .exited => |code| code,
        else => return false,
    };
    if (code == 0 or report.killed_leftovers) return false;
    if (containsAny(report, &failure_signs)) return false;
    if (code == pytest_no_tests and containsAny(report, &pytest_no_tests_signs)) return true;
    return containsAny(report, &no_tests_signs);
}

const env_signs = [_][]const u8{
    "is not recognized as an internal or external command",
    "command not found",
    "The system cannot find the path specified",
    "Cannot find module",
    "Cannot find package",
    "ERR_MODULE_NOT_FOUND",
    "ModuleNotFoundError",
    "No module named",
};

const cmd_not_found: u32 = 9009;

pub fn envError(report: sandbox.Report) ?[]const u8 {
    const code = switch (report.outcome) {
        .exited => |code| code,
        else => return null,
    };
    if (code == 0) return null;
    for ([_][]const u8{ report.stderr, report.stdout }) |stream| {
        var lines = std.mem.splitScalar(u8, stream, '\n');
        while (lines.next()) |raw| {
            const line = clean(raw);
            for (env_signs) |sign| {
                if (std.mem.indexOf(u8, line, sign) == null) continue;
                if (relativeModule(line)) break;
                return line[0..@min(line.len, max_summary)];
            }
        }
    }
    if (code == cmd_not_found) return firstLine(report.stderr) orelse "the test command was not found";
    return null;
}

fn relativeModule(line: []const u8) bool {
    const quote = std.mem.indexOfAny(u8, line, "'\"") orelse return false;
    const name = line[quote + 1 ..];
    return std.mem.startsWith(u8, name, "./") or std.mem.startsWith(u8, name, "../") or std.mem.startsWith(u8, name, ".\\") or std.mem.startsWith(u8, name, "..\\");
}

fn firstLine(bytes: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = clean(raw);
        if (line.len != 0) return line[0..@min(line.len, max_summary)];
    }
    return null;
}

pub const output_budget: usize = 1500;
const frames_per_stack = 3;
const head_share = 4;

pub const Condensed = struct {
    text: []u8,
    dropped_lines: usize,
};

const pass_marks = [_][]const u8{ "\u{2714} ", "\u{2713} ", "\u{221a} ", "ok " };

fn isPassLine(body: []const u8) bool {
    for (pass_marks) |mark| {
        if (std.mem.startsWith(u8, body, mark)) return true;
    }
    return false;
}

fn isFrame(line: []const u8) bool {
    return std.mem.startsWith(u8, clean(line), "at ");
}

pub fn condense(gpa: std.mem.Allocator, output: []const u8, budget: usize) !Condensed {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var kept: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var dropped: usize = 0;
    var frames: usize = 0;
    var blank_run = false;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, output, "\r\n"), '\n');
    while (lines.next()) |line| {
        if (isFrame(line)) {
            frames += 1;
            if (frames > frames_per_stack) {
                dropped += 1;
                continue;
            }
        } else frames = 0;
        const body = clean(line);
        if (isPassLine(body)) {
            dropped += 1;
            continue;
        }
        if (body.len == 0) {
            if (blank_run) {
                dropped += 1;
                continue;
            }
            blank_run = true;
        } else blank_run = false;
        if (frames != 0 and (try seen.getOrPut(arena, body)).found_existing) {
            dropped += 1;
            continue;
        }
        try kept.append(arena, line);
    }

    var total: usize = 0;
    for (kept.items) |line| total += line.len + 1;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (total <= budget) {
        for (kept.items, 0..) |line, index| {
            if (index != 0) try out.append(gpa, '\n');
            try out.appendSlice(gpa, line);
        }
        return .{ .text = try out.toOwnedSlice(gpa), .dropped_lines = dropped };
    }

    const head_budget = budget / head_share;
    var head: usize = 0;
    var head_used: usize = 0;
    while (head < kept.items.len and head_used + kept.items[head].len + 1 <= head_budget) : (head += 1) head_used += kept.items[head].len + 1;
    var tail = kept.items.len;
    var tail_used: usize = 0;
    while (tail > head and tail_used + kept.items[tail - 1].len + 1 <= budget - head_used) : (tail -= 1) tail_used += kept.items[tail - 1].len + 1;
    const skipped = tail - head;
    dropped += skipped;
    for (kept.items[0..head]) |line| {
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    try out.print(gpa, "... {d} lines dropped ...", .{skipped});
    if (tail == kept.items.len and skipped != 0) {
        const last = kept.items[kept.items.len - 1];
        try out.append(gpa, '\n');
        try out.appendSlice(gpa, last[last.len - @min(last.len, budget - head_used) ..]);
    }
    for (kept.items[tail..]) |line| {
        try out.append(gpa, '\n');
        try out.appendSlice(gpa, line);
    }
    return .{ .text = try out.toOwnedSlice(gpa), .dropped_lines = dropped };
}

const testing = std.testing;

test "test output keeps its failure lines, drops repeated stacks and frames past the third, and fits the budget" {
    const stack = "    at Context.<anonymous> (tests/a.js:10:5)\n    at callFn (node_modules/mocha/lib/runnable.js:366:21)\n    at Test.Runnable.run (node_modules/mocha/lib/runnable.js:354:5)\n    at Runner.runTest (node_modules/mocha/lib/runner.js:666:10)\n    at next (node_modules/mocha/lib/runner.js:500:14)\n";
    const failure = "  AssertionError [ERR_ASSERTION]: Should have no errors but had 1\n" ++ stack;
    const output = "  no-alert\n    \u{2714} foo.alert(foo) (78ms)\n    ok 4 - foo.confirm(foo)\n  1) no-alert valid window.alert\n" ++ failure ++ "\n\n\n  2) no-alert valid self.alert\n" ++ failure ++ "  3) no-alert invalid alert\n" ++ failure;
    const condensed = try condense(testing.allocator, output, output_budget);
    defer testing.allocator.free(condensed.text);
    errdefer std.debug.print("{s}\n", .{condensed.text});
    try testing.expect(std.mem.indexOf(u8, condensed.text, "1) no-alert valid window.alert") != null);
    try testing.expect(std.mem.indexOf(u8, condensed.text, "2) no-alert valid self.alert") != null);
    try testing.expect(std.mem.indexOf(u8, condensed.text, "3) no-alert invalid alert") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, condensed.text, "at Context.<anonymous>"));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, condensed.text, "at Runner.runTest"));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, condensed.text, "AssertionError"));
    try testing.expect(std.mem.indexOf(u8, condensed.text, "foo.alert(foo)") == null);
    try testing.expect(std.mem.indexOf(u8, condensed.text, "foo.confirm(foo)") == null);
    try testing.expectEqual(@as(usize, 2 * 5 + 2 + 2 + 2), condensed.dropped_lines);

    const flood = "line of noise number one two\n" ** 3 ++ "x" ** 120 ++ "\n";
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    for (0..200) |index| try big.print(testing.allocator, "row {d} of the flood with some padding text\n", .{index});
    try big.appendSlice(testing.allocator, "  5 failing\n");
    const capped = try condense(testing.allocator, big.items, output_budget);
    defer testing.allocator.free(capped.text);
    try testing.expect(capped.text.len <= output_budget + 40);
    try testing.expect(std.mem.startsWith(u8, capped.text, "row 0 "));
    try testing.expect(std.mem.endsWith(u8, capped.text, "  5 failing"));
    try testing.expect(std.mem.indexOf(u8, capped.text, " lines dropped ...") != null);
    try testing.expect(capped.dropped_lines > 100);

    const short = try condense(testing.allocator, flood, output_budget);
    defer testing.allocator.free(short.text);
    try testing.expectEqual(@as(usize, 0), short.dropped_lines);

    const one = try condense(testing.allocator, "y" ** 4000, output_budget);
    defer testing.allocator.free(one.text);
    try testing.expect(one.text.len <= output_budget + 40);
    try testing.expect(std.mem.endsWith(u8, one.text, "yyyy"));
}

fn reportOf(code: u32, stdout: []const u8, stderr: []const u8) sandbox.Report {
    return .{ .outcome = .{ .exited = code }, .duration_ns = 0, .stdout = @constCast(stdout), .stderr = @constCast(stderr), .truncated = false, .killed_leftovers = false };
}

test "a passing run is summed up by its count lines, oldest first and under the size cap" {
    const mocha = reportOf(0, "\n  no-alert\n    valid\n      \x1b[32m✓\x1b[0m window.alert passed through\n\n\n  37 passing (120ms)\n  2 pending\n\n", "");
    var summary = summarize(mocha);
    try testing.expectEqualStrings("37 passing (120ms) | 2 pending", summary.text());

    const jest = reportOf(0, "", "PASS src/a.test.js\nTests:       5 passed, 5 total\nTime:        1.2 s\n");
    summary = summarize(jest);
    try testing.expectEqualStrings("Tests:       5 passed, 5 total", summary.text());

    const quiet = reportOf(0, "build ok\nall good\n\n", "");
    summary = summarize(quiet);
    try testing.expectEqualStrings("all good", summary.text());

    const long = reportOf(0, "x" ** 500 ++ " passing\n", "");
    summary = summarize(long);
    try testing.expectEqual(@as(usize, max_summary), summary.text().len);

    summary = summarize(reportOf(0, "", ""));
    try testing.expectEqualStrings("", summary.text());
}

test "a failing run whose count lines sit above a long failure list is summed up by them, not by a stack frame" {
    const failing = reportOf(1, "  1) rule\n       valid\n         a:\n\n  3 passing (1s)\n  516 failing\n\n  1) rule\n     TypeError: x is not a function\n" ++ "      at f (lib/a.js:1:1)\n" ** 20, "");
    const summary = summarize(failing);
    try testing.expectEqualStrings("3 passing (1s) | 516 failing", summary.text());
}

test "a missing command or module is an environment error, a failing test or a relative import is not" {
    try testing.expectEqualStrings("Error: Cannot find module 'C:\\s\\node_modules\\mocha\\bin\\mocha.js'", envError(reportOf(1, "", "node:internal/modules/cjs/loader:1228\n  throw err;\n\nError: Cannot find module 'C:\\s\\node_modules\\mocha\\bin\\mocha.js'\n    at Module._resolveFilename\n")).?);
    try testing.expectEqualStrings("'mocha' is not recognized as an internal or external command,", envError(reportOf(9009, "", "'mocha' is not recognized as an internal or external command,\r\noperable program or batch file.\r\n")).?);
    try testing.expectEqualStrings("boom", envError(reportOf(9009, "", "\nboom\n")).?);
    try testing.expectEqualStrings("ModuleNotFoundError: No module named 'pytest'", envError(reportOf(1, "", "ModuleNotFoundError: No module named 'pytest'\n")).?);
    try testing.expect(envError(reportOf(1, "  1 failing\n  AssertionError: expected 1 to equal 2\n", "")) == null);
    try testing.expect(envError(reportOf(1, "", "Error: Cannot find module './helpers'\n")) == null);
    try testing.expect(envError(reportOf(0, "", "Error: Cannot find module 'x'\n")) == null);
    try testing.expect(envError(.{ .outcome = .timed_out, .duration_ns = 0, .stdout = @constCast(""), .stderr = @constCast("Cannot find module 'x'"), .truncated = false, .killed_leftovers = false }) == null);
}

test "a run that collected no tests counts as passing with a note, a failing or crashing run does not" {
    for ([_]sandbox.Report{
        reportOf(5, "============ test session starts ============\ncollected 0 items\n\n=========== no tests ran in 0.01s ===========\n", ""),
        reportOf(1, "", "No tests found, exiting with code 1\nRun with `--passWithNoTests` to exit with code 0\n"),
        reportOf(1, "", "No test files found, exiting with code 1\n"),
        reportOf(1, "No test is available in C:/w/bin/Debug/net8.0/App.dll.\n", ""),
        reportOf(1, "", "Error: No test files found: \"test\"\n"),
    }) |report| {
        errdefer std.debug.print("not treated as empty: {s}{s}\n", .{ report.stdout, report.stderr });
        try std.testing.expect(noTests(report));
        var empty = report;
        empty.no_tests = true;
        try std.testing.expect(empty.passed());
        const summary = summarize(empty);
        try std.testing.expect(std.mem.startsWith(u8, summary.text(), no_tests_note));
    }
    for ([_]sandbox.Report{
        reportOf(5, "something else entirely\n", ""),
        reportOf(1, "  1 failing\n", "No tests found\n"),
        reportOf(1, "FAILED tests/test_a.py::test_x\n", ""),
        reportOf(2, "collected 0 items / 1 error\nTraceback (most recent call last):\n", ""),
        reportOf(1, "", "Cannot find module 'jest'\n"),
        reportOf(0, "no tests ran\n", ""),
    }) |report| {
        errdefer std.debug.print("treated as empty: {s}{s}\n", .{ report.stdout, report.stderr });
        try std.testing.expect(!noTests(report));
    }
    var crashed = reportOf(5, "no tests ran\n", "");
    crashed.outcome = .{ .crashed = 0xC0000005 };
    try std.testing.expect(!noTests(crashed));
    var leftovers = reportOf(5, "no tests ran\n", "");
    leftovers.killed_leftovers = true;
    try std.testing.expect(!noTests(leftovers));
}
