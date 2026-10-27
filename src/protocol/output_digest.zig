const std = @import("std");
const sandbox = @import("../platform/sandbox.zig");
const shadow = @import("../platform/shadow.zig");
const run_command = @import("../platform/run_command.zig");
const test_outcome = @import("../platform/test_outcome.zig");

const Allocator = std.mem.Allocator;

pub const cap: usize = 2048;
pub const verbatim_under: usize = 512;
const max_line: usize = 240;
const max_summaries = 3;
const footer_reserve: usize = 360;
pub const log_dir = "logs";
pub const log_prefix = "log ";
const id_len = 8;
pub const max_log_lines = 200;
pub const max_log_bytes = 16 * 1024;

pub const Digest = struct {
    text: []u8,
    dropped_lines: usize,
    more_failures: usize,
};

const Kind = enum { drop, frame, summary, keep };

const Entry = struct {
    text: []const u8,
    key: []const u8,
    count: usize,
    head: bool,
};

const pass_starts = [_][]const u8{ "\u{2713}", "\u{2714}", "\u{221a}", "ok ", "PASS ", "PASSED", "--- PASS", "=== RUN", "=== PAUSE", "=== CONT", "Passed ", "[PASS]", "[ OK ]", "[ RUN" };
const pass_ends = [_][]const u8{ " ok", " ... ok", " PASSED", " passed", " (cached)" };
const noise_starts = [_][]const u8{ "Time:", "Duration", "Ran ", "Snapshots:", "Finished ", "collected ", "short test summary", "test session starts", "Compiling ", "Downloading ", "Downloaded ", "Fresh ", "Running ", "Restore complete", "Determining projects", "Build started", "Microsoft (R)", "Copyright (C)", "Starting test execution", "A total of ", "Test run for ", "VSTest version", "npm ERR!", "npm error", "npm warn", "Test Suites:", "rootdir:", "platform ", "cachedir:", "plugins:", "configfile:", "collecting", "Blocking waiting", "Updating crates", "Locking ", "Waiting for", "Done in", "info ", "RUN ", "Doc-tests", "running ", "note: run with `RUST_BACKTRACE" };
const frame_starts = [_][]const u8{ "at ", "File \"", "from " };
const vendor_marks = [_][]const u8{ "node_modules", "node:internal", "internal/", "internal\\", "site-packages", "dist-packages", "<frozen", "/rustc/", "\\rustc\\", "/usr/lib", "lib/std/", "lib\\std\\", "lib/python", "\\Lib\\", "System.", "Microsoft.", "Xunit.", "NUnit.", "new Promise", "processTicksAndRejections", "/runtime/", "\\runtime\\", "testing.go", "<anonymous>)", "(native)" };
const head_starts = [_][]const u8{ "\u{25cf} ", "\u{2715}", "\u{2717}", "\u{00d7} ", "FAIL", "--- FAIL", "not ok", "Failed ", "FAILED", "failed ", "thread '", "---- ", "panic:", "Traceback", "AssertionError", "assert" };

fn startsAny(text: []const u8, marks: []const []const u8) bool {
    for (marks) |mark| {
        if (std.mem.startsWith(u8, text, mark)) return true;
    }
    return false;
}

fn containsAny(text: []const u8, marks: []const []const u8) bool {
    for (marks) |mark| {
        if (std.mem.indexOf(u8, text, mark) != null) return true;
    }
    return false;
}

fn endsAny(text: []const u8, marks: []const []const u8) bool {
    for (marks) |mark| {
        if (std.mem.endsWith(u8, text, mark)) return true;
    }
    return false;
}

fn stripAnsi(arena: Allocator, raw: []const u8) ![]const u8 {
    var line = std.mem.trimEnd(u8, raw, "\r");
    if (std.mem.lastIndexOfScalar(u8, line, '\r')) |cr| {
        const after = line[cr + 1 ..];
        line = if (std.mem.trim(u8, after, " \t").len != 0) after else line[0..cr];
    }
    if (std.mem.indexOfScalar(u8, line, 0x1b) == null) return std.mem.trimEnd(u8, line, " \t");
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            var j = i + 2;
            while (j < line.len and (line[j] < 0x40 or line[j] > 0x7e)) j += 1;
            i = j + 1;
            continue;
        }
        if (line[i] == 0x1b) {
            i += 2;
            continue;
        }
        try out.append(arena, line[i]);
        i += 1;
    }
    return std.mem.trimEnd(u8, out.items, " \t");
}

fn isRule(text: []const u8) bool {
    for (text) |c| {
        if (std.mem.indexOfScalar(u8, "=-_*~#+ |^", c) == null) return false;
    }
    return true;
}

fn isProgress(text: []const u8) bool {
    if (std.mem.endsWith(u8, text, "%]") or std.mem.endsWith(u8, text, "%)")) return true;
    if (std.mem.indexOf(u8, text, "\u{2588}") != null or std.mem.indexOf(u8, text, "\u{2501}") != null) return true;
    return std.mem.indexOf(u8, text, "[====") != null or std.mem.indexOf(u8, text, "[####") != null;
}

fn isCodeContext(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    if (i == 0) return text.len != 0 and text[0] == '|';
    while (i < text.len and text[i] == ' ') i += 1;
    return i < text.len and text[i] == '|';
}

fn isNpmEcho(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "> ")) return false;
    const word = text[2..];
    const space = std.mem.indexOfScalar(u8, word, ' ') orelse word.len;
    return std.mem.indexOfScalar(u8, word[0..space], '@') != null;
}

pub fn isPass(text: []const u8) bool {
    if (startsAny(text, &pass_starts)) return true;
    if (std.mem.startsWith(u8, text, "test ") and endsAny(text, &.{ " ok", " ignored" })) return true;
    return endsAny(text, &pass_ends) and !hasDigitWord(text);
}

fn hasDigitWord(text: []const u8) bool {
    for (text) |c| {
        if (std.ascii.isDigit(c)) return true;
    }
    return false;
}

pub fn isVendorFrame(text: []const u8) bool {
    return containsAny(text, &vendor_marks);
}

fn isFrame(text: []const u8) bool {
    if (startsAny(text, &frame_starts)) return true;
    var i: usize = 0;
    while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    return i != 0 and i + 1 < text.len and text[i] == ':' and text[i + 1] == ' ' and std.mem.indexOf(u8, text, "::") != null;
}

fn isHead(text: []const u8) bool {
    if (startsAny(text, &head_starts)) return true;
    if (text.len > 2 and std.ascii.isDigit(text[0])) {
        var i: usize = 0;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        if (i < text.len and text[i] == ')') return true;
    }
    return std.ascii.indexOfIgnoreCase(text, "error") != null or std.mem.indexOf(u8, text, "panicked") != null;
}

fn classify(text: []const u8) Kind {
    if (text.len == 0) return .drop;
    if (isRule(text)) return .drop;
    if (isProgress(text)) return .drop;
    if (isCodeContext(text)) return .drop;
    if (isNpmEcho(text)) return .drop;
    if (isFrame(text)) return .frame;
    if (test_outcome.isSummaryLine(text)) return .summary;
    if (isPass(text)) return .drop;
    if (startsAny(text, &noise_starts)) return .drop;
    return .keep;
}

fn warningKey(text: []const u8) ?[]const u8 {
    const at = std.ascii.indexOfIgnoreCase(text, "warning") orelse return null;
    if (std.ascii.indexOfIgnoreCase(text, "error") != null) return null;
    return text[at..];
}

fn unrule(text: []const u8) []const u8 {
    const inner = std.mem.trim(u8, text, "=-_*~ ");
    return if (inner.len != 0 and inner.len < text.len) inner else text;
}

fn clip(text: []const u8) []const u8 {
    if (text.len <= max_line) return text;
    var end = max_line;
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return text[0..end];
}

const Collected = struct {
    entries: std.ArrayList(Entry) = .empty,
    summaries: std.ArrayList([]const u8) = .empty,
    dropped: usize = 0,
    warnings: usize = 0,
};

fn collect(arena: Allocator, streams: []const []const u8) !Collected {
    var c: Collected = .{};
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    for (streams) |stream| {
        var frame_kept = false;
        var in_frames = false;
        var source_of: ?bool = null;
        var lines = std.mem.splitScalar(u8, stream, '\n');
        while (lines.next()) |raw| {
            const stripped = try stripAnsi(arena, raw);
            const text = unrule(std.mem.trimStart(u8, stripped, " \t"));
            const kind = classify(text);
            const after_frame = source_of;
            source_of = null;
            if (kind == .keep and after_frame != null) {
                if (!after_frame.?) {
                    c.dropped += 1;
                    continue;
                }
            } else if (kind != .frame) in_frames = false;
            switch (kind) {
                .drop => {
                    if (text.len != 0) c.dropped += 1;
                    continue;
                },
                .summary => {
                    c.dropped += 1;
                    for (c.summaries.items) |s| {
                        if (std.mem.eql(u8, s, text)) break;
                    } else try c.summaries.append(arena, clip(text));
                    continue;
                },
                .frame => {
                    if (!in_frames) frame_kept = false;
                    in_frames = true;
                    const python = std.mem.startsWith(u8, text, "File \"");
                    if ((frame_kept and !python) or isVendorFrame(text)) {
                        if (python) source_of = false;
                        c.dropped += 1;
                        continue;
                    }
                    if (python) source_of = true;
                    frame_kept = true;
                },
                .keep => {},
            }
            const warn = warningKey(text);
            if (warn != null) c.warnings += 1;
            const key = warn orelse text;
            const gop = try index.getOrPut(arena, key);
            if (gop.found_existing) {
                c.entries.items[gop.value_ptr.*].count += 1;
                c.dropped += 1;
                continue;
            }
            gop.value_ptr.* = c.entries.items.len;
            try c.entries.append(arena, .{ .text = clip(text), .key = key, .count = 1, .head = kind == .keep and isHead(text) });
        }
    }
    return c;
}

pub fn failureKeys(gpa: Allocator, stdout: []const u8, stderr: []const u8) ![]u64 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const c = try collect(arena_state.allocator(), &.{ stdout, stderr });
    var keys: std.ArrayList(u64) = .empty;
    errdefer keys.deinit(gpa);
    for (c.entries.items) |entry| {
        if (warningKey(entry.text) != null or test_outcome.isSummaryLine(entry.text)) continue;
        try keys.append(gpa, failureKey(entry.text));
    }
    std.mem.sort(u64, keys.items, {}, std.sort.asc(u64));
    return keys.toOwnedSlice(gpa);
}

fn failureKey(text: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    var digits = false;
    for (text) |byte| {
        if (std.ascii.isDigit(byte)) {
            if (!digits) hasher.update("#");
            digits = true;
            continue;
        }
        digits = false;
        hasher.update(&.{byte});
    }
    return hasher.final();
}

pub fn digest(gpa: Allocator, stdout: []const u8, stderr: []const u8) !Digest {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const c = try collect(arena, &.{ stdout, stderr });
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var shown: usize = 0;
    var dropped = c.dropped;
    for (c.entries.items) |entry| {
        const need = entry.text.len + 8;
        if (out.items.len + need > cap - footer_reserve) break;
        if (out.items.len != 0) try out.append(gpa, '\n');
        if (!entry.head) try out.appendSlice(gpa, "  ");
        try out.appendSlice(gpa, entry.text);
        if (entry.count > 1) try out.print(gpa, " \u{00d7}{d}", .{entry.count});
        shown += 1;
    }
    var more: usize = 0;
    var rest: usize = 0;
    for (c.entries.items[shown..]) |entry| {
        rest += entry.count;
        if (entry.head) more += 1;
    }
    dropped += rest;
    if (rest != 0) {
        if (out.items.len != 0) try out.append(gpa, '\n');
        if (more != 0) try out.print(gpa, "+{d} more failures", .{more}) else try out.print(gpa, "+{d} more lines", .{rest});
    }
    for (c.summaries.items[0..@min(c.summaries.items.len, max_summaries)]) |summary| {
        if (out.items.len + summary.len + 1 > cap) break;
        if (out.items.len != 0) try out.append(gpa, '\n');
        try out.appendSlice(gpa, summary);
    }
    return .{ .text = try out.toOwnedSlice(gpa), .dropped_lines = dropped, .more_failures = more };
}

pub fn passLine(gpa: Allocator, report: sandbox.Report) !?[]u8 {
    if (!report.passed()) return null;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const c = try collect(arena, &.{ report.stdout, report.stderr });
    if (c.summaries.items.len == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "ok: ");
    for (c.summaries.items[0..@min(c.summaries.items.len, max_summaries)], 0..) |summary, i| {
        if (i != 0) try out.appendSlice(gpa, " | ");
        try out.appendSlice(gpa, summary);
    }
    const ms = report.duration_ns / std.time.ns_per_ms;
    try out.print(gpa, ", {d}.{d}s", .{ ms / 1000, (ms % 1000) / 100 });
    if (c.warnings != 0) try out.print(gpa, ", {d} warnings", .{c.warnings});
    return try out.toOwnedSlice(gpa);
}

pub fn logId(stdout: []const u8, stderr: []const u8) [id_len]u8 {
    var h = std.hash.Wyhash.init(0);
    h.update(stdout);
    h.update(&.{0});
    h.update(stderr);
    var id: [id_len]u8 = undefined;
    _ = std.fmt.bufPrint(&id, "{x:0>8}", .{@as(u32, @truncate(h.final()))}) catch unreachable;
    return id;
}

pub fn logRequest(command: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, command, log_prefix)) return null;
    const id = std.mem.trim(u8, command[log_prefix.len..], " ");
    if (id.len != id_len) return null;
    for (id) |ch| {
        if (!std.ascii.isHex(ch)) return null;
    }
    return id;
}

fn logPath(gpa: Allocator, root_abs: []const u8, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}\\{s}\\{s}\\{s}.log", .{ root_abs, shadow.workspace_dir, log_dir, id });
}

pub fn storeLog(gpa: Allocator, io: std.Io, root_abs: []const u8, report: sandbox.Report) !?[id_len]u8 {
    const id = logId(report.stdout, report.stderr);
    const path = try logPath(gpa, root_abs, &id);
    defer gpa.free(path);
    const body = try std.mem.concat(gpa, u8, &.{ report.stdout, if (report.stderr.len != 0 and report.stdout.len != 0) "\n" else "", report.stderr });
    defer gpa.free(body);
    std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?) catch return null;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body }) catch return null;
    return id;
}

pub fn writeLog(gpa: Allocator, io: std.Io, root_abs: []const u8, id: []const u8, w: *std.Io.Writer) !bool {
    const path = try logPath(gpa, root_abs, id);
    defer gpa.free(path);
    var js: std.json.Stringify = .{ .writer = w };
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 * 1024 * 1024)) catch {
        try js.beginObject();
        try js.objectField("status");
        try js.write("refused");
        try js.objectField("reason");
        try js.write("log_not_found");
        try js.objectField("log");
        try js.write(id);
        try js.endObject();
        try w.writeByte('\n');
        return true;
    };
    defer gpa.free(bytes);
    const cut = run_command.tail(bytes, max_log_lines, max_log_bytes);
    try js.beginObject();
    try js.objectField("status");
    try js.write("log");
    try js.objectField("log");
    try js.write(id);
    try js.objectField("text");
    try js.write(cut.text);
    try js.objectField("omitted_lines");
    try js.write(cut.omitted_lines);
    try js.endObject();
    try w.writeByte('\n');
    return false;
}

pub fn writeRunOutput(gpa: Allocator, io: std.Io, root_abs: []const u8, report: sandbox.Report, js: *std.json.Stringify) !void {
    const raw = report.stdout.len + report.stderr.len;
    const line = try passLine(gpa, report);
    defer if (line) |l| gpa.free(l);
    if (line == null and raw <= verbatim_under and !report.truncated) {
        try js.objectField("stdout");
        try js.write(report.stdout);
        try js.objectField("stderr");
        try js.write(report.stderr);
        return;
    }
    if (line) |l| {
        try js.objectField("output");
        try js.write(l);
    } else {
        const d = try digest(gpa, report.stdout, report.stderr);
        defer gpa.free(d.text);
        try js.objectField("output");
        try js.write(d.text);
        try js.objectField("output_dropped_lines");
        try js.write(d.dropped_lines);
    }
    try js.objectField("output_bytes");
    try js.write(raw);
    if (raw > verbatim_under) {
        if (try storeLog(gpa, io, root_abs, report)) |id| {
            var buf: [64]u8 = undefined;
            try js.objectField("full_log");
            try js.write(try std.fmt.bufPrint(&buf, "emetgate_run command=\"{s}{s}\"", .{ log_prefix, &id }));
        }
    }
}

const testing = std.testing;

fn reportOf(code: u32, stdout: []const u8, stderr: []const u8) sandbox.Report {
    return .{ .outcome = .{ .exited = code }, .duration_ns = 3_140 * std.time.ns_per_ms, .stdout = @constCast(stdout), .stderr = @constCast(stderr), .truncated = false, .killed_leftovers = false };
}

pub const jest_failure =
    \\> app@1.0.0 test
    \\> jest
    \\
    \\ FAIL  src/math.test.js
    \\  math
    \\    ✓ subtracts (2 ms)
    \\    ✕ adds (4 ms)
    \\
    \\  ● math › adds
    \\
    \\    expect(received).toBe(expected) // Object.is equality
    \\
    \\    Expected: 4
    \\    Received: 3
    \\
    \\      3 | test('adds', () => {
    \\    > 4 |   expect(add(1, 2)).toBe(4);
    \\        |                     ^
    \\      5 | });
    \\
    \\      at Object.toBe (src/math.test.js:4:21)
    \\      at helper (src/helpers.js:9:3)
    \\      at Promise.then.completed (node_modules/jest-circus/build/utils.js:298:28)
    \\      at new Promise (<anonymous>)
    \\      at callAsyncCircusFn (node_modules/jest-circus/build/utils.js:231:10)
    \\
    \\Test Suites: 1 failed, 1 total
    \\Tests:       1 failed, 1 passed, 2 total
    \\Snapshots:   0 total
    \\Time:        0.512 s
    \\Ran all test suites.
    \\
;

pub const pytest_failure =
    \\============================= test session starts =============================
    \\platform win32 -- Python 3.12.1, pytest-8.0.0, pluggy-1.4.0
    \\rootdir: C:\w\app
    \\collected 3 items
    \\
    \\tests/test_math.py ..F                                                   [100%]
    \\
    \\================================== FAILURES ===================================
    \\__________________________________ test_add ___________________________________
    \\
    \\    def test_add():
    \\>       assert add(1, 2) == 4
    \\E       assert 3 == 4
    \\E        +  where 3 = add(1, 2)
    \\
    \\tests/test_math.py:9: AssertionError
    \\=========================== short test summary info ===========================
    \\FAILED tests/test_math.py::test_add - assert 3 == 4
    \\========================= 1 failed, 2 passed in 0.05s =========================
    \\
;

test "a jest failure keeps the test name, expected and received and the first project frame, drops passes, vendor frames and timing" {
    const d = try digest(testing.allocator, jest_failure, "");
    defer testing.allocator.free(d.text);
    errdefer std.debug.print("{s}\n", .{d.text});
    try testing.expect(std.mem.indexOf(u8, d.text, "\u{25cf} math \u{203a} adds") != null);
    try testing.expect(std.mem.indexOf(u8, d.text, "Expected: 4") != null);
    try testing.expect(std.mem.indexOf(u8, d.text, "Received: 3") != null);
    try testing.expect(std.mem.indexOf(u8, d.text, "at Object.toBe (src/math.test.js:4:21)") != null);
    try testing.expect(std.mem.indexOf(u8, d.text, "node_modules") == null);
    try testing.expect(std.mem.indexOf(u8, d.text, "src/helpers.js") == null);
    try testing.expect(std.mem.indexOf(u8, d.text, "subtracts") == null);
    try testing.expect(std.mem.indexOf(u8, d.text, "Time:") == null);
    try testing.expect(std.mem.indexOf(u8, d.text, "3 | test(") == null);
    try testing.expect(std.mem.indexOf(u8, d.text, "app@1.0.0") == null);
    try testing.expect(std.mem.indexOf(u8, d.text, "Tests:       1 failed, 1 passed, 2 total") != null);
    try testing.expect(d.text.len * 2 < jest_failure.len);
}

test "a pytest failure keeps the assertion and the location, drops the session header, rules and progress" {
    const d = try digest(testing.allocator, pytest_failure, "");
    defer testing.allocator.free(d.text);
    errdefer std.debug.print("{s}\n", .{d.text});
    try testing.expect(std.mem.indexOf(u8, d.text, "E       assert 3 == 4") != null);
    try testing.expect(std.mem.indexOf(u8, d.text, "tests/test_math.py:9: AssertionError") != null);
    try testing.expect(std.mem.indexOf(u8, d.text, "FAILED tests/test_math.py::test_add") != null);
    try testing.expect(std.mem.indexOf(u8, d.text, "1 failed, 2 passed in 0.05s") != null);
    try testing.expect(std.mem.indexOf(u8, d.text, "=====") == null);
    try testing.expect(std.mem.indexOf(u8, d.text, "platform win32") == null);
    try testing.expect(std.mem.indexOf(u8, d.text, "[100%]") == null);
}

test "identical compiler errors and repeated warnings collapse to one line with a count, ANSI codes are stripped" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    for (0..12) |i| try out.print(testing.allocator, "src/f{d}.ts:1:1 - warning: unused import\n", .{i});
    for (0..5) |_| try out.appendSlice(testing.allocator, "\x1b[31msrc/a.ts(3,5): error TS2322: Type 'string' is not assignable to type 'number'.\x1b[0m\n");
    const d = try digest(testing.allocator, out.items, "");
    defer testing.allocator.free(d.text);
    errdefer std.debug.print("{s}\n", .{d.text});
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, d.text, "warning: unused import"));
    try testing.expect(std.mem.indexOf(u8, d.text, "warning: unused import \u{00d7}12") != null);
    try testing.expect(std.mem.indexOf(u8, d.text, "error TS2322: Type 'string' is not assignable to type 'number'. \u{00d7}5") != null);
    try testing.expect(std.mem.indexOfScalar(u8, d.text, 0x1b) == null);
}

test "a flood of distinct failures stays under the cap and counts the failures it left out" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    for (0..300) |i| try out.print(testing.allocator, "--- FAIL: TestCase{d} (0.00s)\n    case_test.go:{d}: expected {d}, got 0\n", .{ i, i + 10, i });
    try out.appendSlice(testing.allocator, "FAIL\texample.com/m\t0.012s\n");
    const d = try digest(testing.allocator, out.items, "");
    defer testing.allocator.free(d.text);
    errdefer std.debug.print("{s}\n", .{d.text});
    try testing.expect(d.text.len <= cap);
    try testing.expect(std.mem.indexOf(u8, d.text, "--- FAIL: TestCase0 (0.00s)") != null);
    try testing.expect(std.mem.indexOf(u8, d.text, "case_test.go:10: expected 0, got 0") != null);
    try testing.expect(d.more_failures > 200);
    var buf: [64]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, d.text, try std.fmt.bufPrint(&buf, "+{d} more failures", .{d.more_failures})) != null);
}

test "a passing run with a count line is one line with its duration, a run without one is not" {
    const line = (try passLine(testing.allocator, reportOf(0, "PASS src/a.test.js\n" ++ "  \u{2713} a\n" ** 40 ++ "Tests:       42 passed, 42 total\nTime:        3.1 s\n", ""))).?;
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("ok: Tests:       42 passed, 42 total, 3.1s", line);
    try testing.expect((try passLine(testing.allocator, reportOf(0, "hello\n", ""))) == null);
    try testing.expect((try passLine(testing.allocator, reportOf(1, "Tests: 1 failed, 1 total\n", ""))) == null);
}

test "a cargo panic keeps the panic location and left and right, drops passing tests and the backtrace note" {
    const cargo =
        \\   Compiling demo v0.1.0 (C:\w\demo)
        \\    Finished test [unoptimized + debuginfo] target(s) in 0.41s
        \\     Running unittests src/lib.rs (target\debug\deps\demo-1)
        \\
        \\running 2 tests
        \\test tests::it_subtracts ... ok
        \\test tests::it_adds ... FAILED
        \\
        \\failures:
        \\
        \\---- tests::it_adds stdout ----
        \\thread 'tests::it_adds' panicked at src/lib.rs:10:9:
        \\assertion `left == right` failed
        \\  left: 3
        \\ right: 4
        \\note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
        \\
        \\test result: FAILED. 1 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
        \\
    ;
    const d = try digest(testing.allocator, cargo, "");
    defer testing.allocator.free(d.text);
    errdefer std.debug.print("{s}\n", .{d.text});
    try testing.expect(std.mem.indexOf(u8, d.text, "panicked at src/lib.rs:10:9:") != null);
    try testing.expect(std.mem.indexOf(u8, d.text, "left: 3") != null);
    try testing.expect(std.mem.indexOf(u8, d.text, "right: 4") != null);
    try testing.expect(std.mem.indexOf(u8, d.text, "it_subtracts") == null);
    try testing.expect(std.mem.indexOf(u8, d.text, "RUST_BACKTRACE") == null);
    try testing.expect(std.mem.indexOf(u8, d.text, "Compiling demo") == null);
    try testing.expect(std.mem.indexOf(u8, d.text, "test result: FAILED. 1 passed; 1 failed") != null);
}

test "a traceback that starts in library code keeps the first project frame and its source line, not the library ones" {
    const traceback =
        \\Traceback (most recent call last):
        \\  File "C:\Python312\Lib\unittest\case.py", line 58, in testPartExecutor
        \\    yield
        \\  File "C:\w\app\tests\test_math.py", line 9, in test_add
        \\    self.assertEqual(add(1, 2), 4)
        \\  File "C:\w\app\src\math.py", line 2, in add
        \\    return a - b
        \\AssertionError: 3 != 4
        \\
    ;
    const d = try digest(testing.allocator, "", traceback);
    defer testing.allocator.free(d.text);
    errdefer std.debug.print("{s}\n", .{d.text});
    try testing.expect(std.mem.indexOf(u8, d.text, "test_math.py\", line 9, in test_add") != null);
    try testing.expect(std.mem.indexOf(u8, d.text, "self.assertEqual(add(1, 2), 4)") != null);
    try testing.expect(std.mem.indexOf(u8, d.text, "AssertionError: 3 != 4") != null);
    try testing.expect(std.mem.indexOf(u8, d.text, "math.py\", line 2, in add") != null);
    try testing.expect(std.mem.indexOf(u8, d.text, "case.py") == null);
    try testing.expect(std.mem.indexOf(u8, d.text, "yield") == null);
}

test "a log request names eight hex digits after log and nothing else" {
    try testing.expectEqualStrings("0a1b2c3d", logRequest("log 0a1b2c3d").?);
    try testing.expect(logRequest("log 0a1b2c3") == null);
    try testing.expect(logRequest("log 0a1b2c3z") == null);
    try testing.expect(logRequest("npm test") == null);
    const a = logId("x", "y");
    const b = logId("xy", "");
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "failure keys ignore numbers and summary lines, so the same failures in another run compare equal" {
    const before = try failureKeys(std.testing.allocator, "FAIL src/a.test.ts > adds (12 ms)\nTests: 1 failed, 4 passed\n", "");
    defer std.testing.allocator.free(before);
    const after = try failureKeys(std.testing.allocator, "FAIL src/a.test.ts > adds (31 ms)\nTests: 1 failed, 5 passed\n", "");
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualSlices(u64, before, after);
    try std.testing.expect(after.len != 0);
}
