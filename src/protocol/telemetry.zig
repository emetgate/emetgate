const std = @import("std");
const builtin = @import("builtin");
const symbol = @import("../engine/symbol.zig");
const runner = @import("../platform/runner.zig");
const shadow = @import("../platform/shadow.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const events_file = "events.ndjson";

pub const Outcome = enum { ok, committed, rejected, failed };

pub const Event = struct {
    tool: []const u8,
    label: []const u8 = "ok",
    file: ?[]const u8 = null,
    symbol: ?[]const u8 = null,
    outcome: Outcome = .ok,
    result: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    hash: ?symbol.Hash = null,
    trace: runner.Trace = .{},
    mutating: bool = false,
    edits: usize = 0,
    chars_synapse: ?usize = null,
    chars_fullfile: ?usize = null,
    chars_sr: ?usize = null,

    pub fn fail(self: *Event, name: []const u8) void {
        self.outcome = .failed;
        self.result = name;
    }

    fn resultName(self: Event) []const u8 {
        return switch (self.outcome) {
            .ok => "ok",
            .committed => "committed",
            .rejected => "rejected",
            .failed => self.result orelse "error",
        };
    }
};

pub const Session = struct {
    edits: u64 = 0,
    sent_chars: u64 = 0,
    fullfile_chars: u64 = 0,

    pub fn tally(self: *Session, event: Event) void {
        if (event.outcome != .committed) return;
        self.edits += event.edits;
        const sent = event.chars_synapse orelse return;
        const full = event.chars_fullfile orelse return;
        self.sent_chars += sent;
        self.fullfile_chars += full;
    }
};

pub const Observer = struct {
    workspace_abs: []const u8,
    session: Session = .{},

    pub fn record(self: *Observer, gpa: Allocator, io: std.Io, event: Event) void {
        self.append(gpa, io, event) catch {};
    }

    fn append(self: *Observer, gpa: Allocator, io: std.Io, event: Event) !void {
        try std.Io.Dir.cwd().createDirPath(io, self.workspace_abs);
        ensureIgnored(gpa, io, self.workspace_abs);
        const path = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ self.workspace_abs, events_file });
        defer gpa.free(path);
        if (builtin.os.tag == .windows and try shadow.isReparsePoint(path)) return error.EventsFileIsLink;

        var line: Writer.Allocating = .init(gpa);
        defer line.deinit();
        try writeEvent(&line.writer, std.Io.Timestamp.now(io, .real).toMilliseconds(), event);
        try line.writer.writeByte('\n');

        const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .read = true, .truncate = false, .lock = .exclusive, .lock_nonblocking = true });
        defer file.close(io);
        try file.writePositionalAll(io, line.written(), try file.length(io));
    }
};

fn ensureIgnored(gpa: Allocator, io: std.Io, workspace_abs: []const u8) void {
    const path = std.fmt.allocPrint(gpa, "{s}\\.gitignore", .{workspace_abs}) catch return;
    defer gpa.free(path);
    const file = std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true }) catch return;
    defer file.close(io);
    file.writeStreamingAll(io, "*\n") catch {};
}

pub fn observe(gpa: Allocator, io: std.Io, observer: *Observer, event: Event, text: []const u8) ?[]u8 {
    observer.session.tally(event);
    observer.record(gpa, io, event);
    var buffer: Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    buffer.writer.writeAll(text) catch return null;
    buffer.writer.writeByte('\n') catch return null;
    renderFooter(&buffer.writer, event, observer.session) catch return null;
    return buffer.toOwnedSlice() catch null;
}

pub fn writeEvent(w: *Writer, ts_ms: i64, event: Event) !void {
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("ts");
    try js.write(ts_ms);
    try js.objectField("tool");
    try js.write(event.tool);
    try js.objectField("file");
    try js.write(event.file);
    try js.objectField("symbol");
    try js.write(event.symbol);
    try js.objectField("class");
    try js.write(event.trace.class);
    try js.objectField("confidence");
    try js.write(event.trace.confidence);
    try js.objectField("provenance");
    try js.write(event.trace.provenance);
    try js.objectField("gate");
    try js.write(event.trace.gate);
    try js.objectField("result");
    try js.write(event.resultName());
    try js.objectField("reason");
    try js.write(event.reason);
    try js.objectField("hash");
    if (event.hash) |h| {
        const hex = symbol.formatHash(h);
        try js.write(hex[0..]);
    } else try js.write(null);
    try js.objectField("chars_synapse");
    try js.write(event.chars_synapse);
    try js.objectField("chars_fullfile");
    try js.write(event.chars_fullfile);
    try js.objectField("chars_sr");
    try js.write(event.chars_sr);
    try js.endObject();
}

pub fn renderFooter(w: *Writer, event: Event, session: Session) !void {
    try w.writeAll("synapse ");
    switch (event.outcome) {
        .ok => try w.print("✓ {s}", .{event.label}),
        .committed => try w.writeAll("✓ committed"),
        .rejected => try w.print("✗ rejected · {s}", .{event.reason orelse "rejected"}),
        .failed => try w.print("✗ {s}", .{event.resultName()}),
    }
    if (event.trace.confidence) |c| try w.writeAll(if (c == .bounded) " · BOUNDED" else " · UNBOUNDED");
    if (event.trace.gate) |g| try w.print(" · gate {s}", .{@tagName(g)});
    if (event.outcome == .ok or event.outcome == .committed) {
        if (event.chars_synapse) |sent| {
            if (event.chars_fullfile) |full| try writeChars(w, if (event.mutating) "sent" else "read", sent, full);
        }
    }
    if (event.mutating) {
        if (event.outcome == .failed and event.trace.commit_attempted) {
            try w.writeAll(" · failed in commit phase, run synapse recover");
        } else if (event.outcome != .committed) {
            try w.writeAll(" · disk untouched");
        }
    }
    try w.print(" · session {d} edits", .{session.edits});
}

fn writeChars(w: *Writer, verb: []const u8, sent: usize, full: usize) !void {
    try w.print(" · {s} ", .{verb});
    try writeCount(w, sent);
    try w.writeAll(" / file ");
    try writeCount(w, full);
    try w.writeAll(" chars");
}

fn writeCount(w: *Writer, n: usize) !void {
    const f = @as(f64, @floatFromInt(n));
    if (n < 1000) return w.print("{d}", .{n});
    if (n < 1_000_000) return w.print("{d:.1}k", .{f / 1000});
    return w.print("{d:.1}M", .{f / 1_000_000});
}

const testing = std.testing;

fn footer(event: Event, session: Session) ![]u8 {
    var buffer: Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    try renderFooter(&buffer.writer, event, session);
    return buffer.toOwnedSlice();
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected \"{s}\" in \"{s}\"\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

fn expectLacks(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("unexpected \"{s}\" in \"{s}\"\n", .{ needle, haystack });
        return error.TestUnexpectedContains;
    }
}

test "footer gate always equals chooseGate for every confidence and scoped combination" {
    for ([_]@import("../engine/boundedness.zig").Confidence{ .bounded, .unbounded }) |confidence| {
        for ([_]bool{ false, true }) |has_scoped| {
            const gate = runner.chooseGate(confidence, has_scoped);
            const text = try footer(.{ .tool = "synapse_try", .outcome = .committed, .mutating = true, .edits = 1, .trace = .{ .gate = gate, .confidence = confidence } }, .{});
            defer testing.allocator.free(text);
            const expected = if (confidence == .bounded and has_scoped) " · gate scoped" else " · gate full";
            try expectContains(text, expected);
            try expectContains(text, if (confidence == .bounded) " · BOUNDED" else " · UNBOUNDED");
        }
    }
}

test "committed footer shows raw chars sent and the whole file size" {
    const text = try footer(.{ .tool = "synapse_try", .outcome = .committed, .mutating = true, .edits = 1, .chars_synapse = 1700, .chars_fullfile = 6630 }, .{ .edits = 3 });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("synapse ✓ committed · sent 1.7k / file 6.6k chars · session 3 edits", text);
}

test "footer never prints a ratio, a saving or a token claim" {
    const cases = [_][2]usize{ .{ 900, 400 }, .{ 10, 100_000 }, .{ 56, 2442 } };
    for (cases) |c| {
        for ([_]bool{ false, true }) |mutating| {
            const text = try footer(.{ .tool = "synapse_try", .outcome = .committed, .mutating = mutating, .edits = 1, .chars_synapse = c[0], .chars_fullfile = c[1] }, .{});
            defer testing.allocator.free(text);
            try expectLacks(text, "×");
            try expectLacks(text, "less");
            try expectLacks(text, "saving");
            try expectLacks(text, "token");
            try expectContains(text, " chars");
        }
    }
}

test "rejected footer names the reason, says disk untouched and shows no saving" {
    const text = try footer(.{ .tool = "synapse_try", .outcome = .rejected, .reason = "tests_failed", .mutating = true, .chars_synapse = 10, .chars_fullfile = 100, .trace = .{ .gate = .full, .confidence = .bounded } }, .{ .edits = 2 });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("synapse ✗ rejected · tests_failed · BOUNDED · gate full · disk untouched · session 2 edits", text);
}

test "a failure after the commit began never claims disk untouched" {
    const before = try footer(.{ .tool = "synapse_try", .outcome = .failed, .result = "HashMismatch", .mutating = true }, .{});
    defer testing.allocator.free(before);
    try testing.expectEqualStrings("synapse ✗ HashMismatch · disk untouched · session 0 edits", before);

    const during = try footer(.{ .tool = "synapse_try", .outcome = .failed, .result = "Conflict", .mutating = true, .trace = .{ .commit_attempted = true } }, .{});
    defer testing.allocator.free(during);
    try expectContains(during, "failed in commit phase");
    try expectLacks(during, "disk untouched");
}

test "a read tool footer says read, not sent, and never mentions disk" {
    const text = try footer(.{ .tool = "synapse_skeleton", .label = "skeleton", .chars_synapse = 420, .chars_fullfile = 6600 }, .{});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("synapse ✓ skeleton · read 420 / file 6.6k chars · session 0 edits", text);
}

test "session counts only committed edits and their chars" {
    var session: Session = .{};
    session.tally(.{ .tool = "synapse_try", .outcome = .committed, .edits = 1, .chars_synapse = 10, .chars_fullfile = 100 });
    session.tally(.{ .tool = "synapse_try", .outcome = .rejected, .edits = 1, .chars_synapse = 10, .chars_fullfile = 100 });
    session.tally(.{ .tool = "synapse_skeleton", .chars_synapse = 10, .chars_fullfile = 100 });
    session.tally(.{ .tool = "synapse_try_batch", .outcome = .committed, .edits = 2, .chars_synapse = 20, .chars_fullfile = 300 });
    try testing.expectEqual(@as(u64, 3), session.edits);
    try testing.expectEqual(@as(u64, 30), session.sent_chars);
    try testing.expectEqual(@as(u64, 400), session.fullfile_chars);
}

test "event line leaves uncomputable fields null instead of inventing them" {
    var buffer: Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    try writeEvent(&buffer.writer, 42, .{ .tool = "synapse_skeleton", .file = "a.ts", .chars_synapse = 5, .chars_fullfile = 50 });
    const line = buffer.written();
    try expectContains(line, "\"ts\":42");
    try expectContains(line, "\"tool\":\"synapse_skeleton\"");
    try expectContains(line, "\"symbol\":null");
    try expectContains(line, "\"gate\":null");
    try expectContains(line, "\"confidence\":null");
    try expectContains(line, "\"hash\":null");
    try expectContains(line, "\"chars_sr\":null");
    try expectContains(line, "\"chars_synapse\":5");
    try expectContains(line, "\"result\":\"ok\"");
}

test "event line carries the runner trace as strings" {
    var buffer: Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    try writeEvent(&buffer.writer, 1, .{ .tool = "synapse_try", .outcome = .failed, .result = "HashMismatch", .trace = .{ .gate = .scoped, .confidence = .unbounded, .provenance = .exported_escape, .class = .signature_change } });
    const line = buffer.written();
    try expectContains(line, "\"gate\":\"scoped\"");
    try expectContains(line, "\"confidence\":\"unbounded\"");
    try expectContains(line, "\"provenance\":\"exported_escape\"");
    try expectContains(line, "\"class\":\"signature_change\"");
    try expectContains(line, "\"result\":\"HashMismatch\"");
}
