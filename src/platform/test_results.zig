const std = @import("std");
const sandbox = @import("sandbox.zig");

const Allocator = std.mem.Allocator;

pub const Status = enum { passed, failed, skipped };

pub const Case = struct {
    id: []const u8,
    file: []const u8 = "",
    status: Status,
    whole: bool = false,
};

pub const Results = struct {
    arena: std.heap.ArenaAllocator,
    cases: []const Case,

    pub fn deinit(self: *Results) void {
        self.arena.deinit();
    }

    pub fn failing(self: *const Results, gpa: Allocator) ![]const []const u8 {
        return failingOf(gpa, self.cases);
    }
};

pub fn failingOf(gpa: Allocator, cases: []const Case) ![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer ids.deinit(gpa);
    for (cases) |case| if (case.status == .failed) try ids.append(gpa, case.id);
    return ids.toOwnedSlice(gpa);
}

pub fn find(cases: []const Case, id: []const u8) ?Case {
    var lo: usize = 0;
    var hi: usize = cases.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, cases[mid].id, id)) {
            .eq => return cases[mid],
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

fn rank(status: Status) u8 {
    return switch (status) {
        .failed => 2,
        .passed => 1,
        .skipped => 0,
    };
}

fn lessCase(_: void, a: Case, b: Case) bool {
    return std.mem.order(u8, a.id, b.id) == .lt;
}

pub fn settle(cases: []Case) []Case {
    std.mem.sort(Case, cases, {}, lessCase);
    var kept: usize = 0;
    for (cases) |case| {
        if (kept != 0 and std.mem.eql(u8, cases[kept - 1].id, case.id)) {
            if (rank(case.status) > rank(cases[kept - 1].status)) cases[kept - 1].status = case.status;
            cases[kept - 1].whole = cases[kept - 1].whole or case.whole;
            continue;
        }
        cases[kept] = case;
        kept += 1;
    }
    return cases[0..kept];
}

const Tag = struct {
    name: []const u8,
    attrs: []const u8,
    closing: bool,
    empty: bool,
};

const Scanner = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn skipPast(self: *Scanner, from: usize, end: []const u8) void {
        self.pos = if (std.mem.indexOfPos(u8, self.bytes, from, end)) |at| at + end.len else self.bytes.len;
    }

    fn next(self: *Scanner) ?Tag {
        while (std.mem.indexOfScalarPos(u8, self.bytes, self.pos, '<')) |lt| {
            const rest = self.bytes[lt..];
            if (std.mem.startsWith(u8, rest, "<!--")) {
                self.skipPast(lt, "-->");
                continue;
            }
            if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
                self.skipPast(lt, "]]>");
                continue;
            }
            if (rest.len > 1 and (rest[1] == '?' or rest[1] == '!')) {
                self.skipPast(lt, ">");
                continue;
            }
            var i = lt + 1;
            const closing = i < self.bytes.len and self.bytes[i] == '/';
            if (closing) i += 1;
            const name_start = i;
            while (i < self.bytes.len and !std.ascii.isWhitespace(self.bytes[i]) and self.bytes[i] != '>' and self.bytes[i] != '/') i += 1;
            const name = self.bytes[name_start..i];
            const attrs_start = i;
            var quote: u8 = 0;
            while (i < self.bytes.len) : (i += 1) {
                const c = self.bytes[i];
                if (quote != 0) {
                    if (c == quote) quote = 0;
                } else if (c == '"' or c == '\'') {
                    quote = c;
                } else if (c == '>') break;
            }
            if (i >= self.bytes.len) {
                self.pos = self.bytes.len;
                return null;
            }
            self.pos = i + 1;
            const empty = i > attrs_start and self.bytes[i - 1] == '/';
            const attrs = self.bytes[attrs_start .. if (empty) i - 1 else i];
            return .{ .name = name, .attrs = attrs, .closing = closing, .empty = empty };
        }
        self.pos = self.bytes.len;
        return null;
    }
};

fn rawAttr(attrs: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < attrs.len) {
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) i += 1;
        const key_start = i;
        while (i < attrs.len and attrs[i] != '=' and !std.ascii.isWhitespace(attrs[i])) i += 1;
        const key = attrs[key_start..i];
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) i += 1;
        if (i >= attrs.len or attrs[i] != '=') {
            if (i == key_start) i += 1;
            continue;
        }
        i += 1;
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) i += 1;
        if (i >= attrs.len) return null;
        const quote = attrs[i];
        if (quote != '"' and quote != '\'') return null;
        const value_start = i + 1;
        const value_end = std.mem.indexOfScalarPos(u8, attrs, value_start, quote) orelse return null;
        i = value_end + 1;
        if (std.mem.eql(u8, key, name)) return attrs[value_start..value_end];
    }
    return null;
}

fn attr(arena: Allocator, attrs: []const u8, name: []const u8) !?[]const u8 {
    const raw = rawAttr(attrs, name) orelse return null;
    return try unescape(arena, raw);
}

pub fn unescape(arena: Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '&') {
            try out.append(arena, raw[i]);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse {
            try out.appendSlice(arena, raw[i..]);
            break;
        };
        const entity = raw[i + 1 .. semi];
        const named = [_]struct { name: []const u8, char: u8 }{
            .{ .name = "lt", .char = '<' },
            .{ .name = "gt", .char = '>' },
            .{ .name = "amp", .char = '&' },
            .{ .name = "quot", .char = '"' },
            .{ .name = "apos", .char = '\'' },
        };
        const char: ?u8 = for (named) |n| {
            if (std.mem.eql(u8, entity, n.name)) break n.char;
        } else null;
        if (char) |c| {
            try out.append(arena, c);
        } else if (entity.len > 1 and entity[0] == '#') {
            const code = (if (entity[1] == 'x' or entity[1] == 'X') std.fmt.parseInt(u21, entity[2..], 16) else std.fmt.parseInt(u21, entity[1..], 10)) catch null;
            var buf: [4]u8 = undefined;
            const len = if (code) |cp| std.unicode.utf8Encode(cp, &buf) catch 0 else 0;
            if (len == 0) try out.appendSlice(arena, raw[i .. semi + 1]) else try out.appendSlice(arena, buf[0..len]);
        } else {
            try out.appendSlice(arena, raw[i .. semi + 1]);
        }
        i = semi + 1;
    }
    return out.items;
}

fn slashed(arena: Allocator, path: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, path);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

fn pytestId(arena: Allocator, classname: []const u8, name: []const u8, file: []const u8) ![]const u8 {
    if (file.len == 0) return if (classname.len == 0) name else std.fmt.allocPrint(arena, "{s}::{s}", .{ classname, name });
    const stem = if (std.mem.endsWith(u8, file, ".py")) file[0 .. file.len - 3] else file;
    const module = try arena.dupe(u8, stem);
    std.mem.replaceScalar(u8, module, '/', '.');
    if (std.mem.eql(u8, classname, module)) return std.fmt.allocPrint(arena, "{s}::{s}", .{ file, name });
    if (classname.len > module.len and std.mem.startsWith(u8, classname, module) and classname[module.len] == '.') {
        const inner = try arena.dupe(u8, classname[module.len + 1 ..]);
        var path: std.ArrayList(u8) = .empty;
        var parts = std.mem.splitScalar(u8, inner, '.');
        while (parts.next()) |part| {
            try path.appendSlice(arena, part);
            try path.appendSlice(arena, "::");
        }
        return std.fmt.allocPrint(arena, "{s}::{s}{s}", .{ file, path.items, name });
    }
    if (classname.len == 0) return std.fmt.allocPrint(arena, "{s}::{s}", .{ file, name });
    return std.fmt.allocPrint(arena, "{s}::{s}", .{ classname, name });
}

pub fn parseJunit(arena: Allocator, bytes: []const u8, into: *std.ArrayList(Case)) !void {
    var scanner: Scanner = .{ .bytes = bytes };
    var open: ?struct { classname: []const u8, name: []const u8, file: []const u8, status: Status, errored: bool } = null;
    while (scanner.next()) |tag| {
        if (std.mem.eql(u8, tag.name, "testcase")) {
            if (tag.closing) {
                if (open) |o| try into.append(arena, try junitCase(arena, o.classname, o.name, o.file, o.status, o.errored));
                open = null;
                continue;
            }
            const classname = (try attr(arena, tag.attrs, "classname")) orelse "";
            const name = (try attr(arena, tag.attrs, "name")) orelse continue;
            const file = try slashed(arena, (try attr(arena, tag.attrs, "file")) orelse "");
            if (tag.empty) {
                try into.append(arena, try junitCase(arena, classname, name, file, .passed, false));
                continue;
            }
            open = .{ .classname = classname, .name = name, .file = file, .status = .passed, .errored = false };
            continue;
        }
        if (tag.closing) continue;
        const o = if (open) |*held| held else continue;
        if (std.mem.eql(u8, tag.name, "failure") or std.mem.eql(u8, tag.name, "error")) {
            o.status = .failed;
            if (std.mem.eql(u8, tag.name, "error")) o.errored = true;
        } else if (std.mem.eql(u8, tag.name, "skipped")) {
            if (o.status == .passed) o.status = .skipped;
        }
    }
}

fn junitCase(arena: Allocator, classname: []const u8, name: []const u8, file: []const u8, status: Status, errored: bool) !Case {
    if (classname.len == 0 and file.len != 0 and (errored or status == .skipped)) {
        return .{ .id = file, .file = file, .status = status, .whole = true };
    }
    return .{ .id = try pytestId(arena, classname, name, file), .file = file, .status = status };
}

pub fn parseTrx(arena: Allocator, bytes: []const u8, into: *std.ArrayList(Case)) !void {
    var classes: std.StringHashMapUnmanaged([]const u8) = .empty;
    var scanner: Scanner = .{ .bytes = bytes };
    var unit: ?[]const u8 = null;
    while (scanner.next()) |tag| {
        if (std.mem.eql(u8, tag.name, "UnitTest")) {
            unit = if (tag.closing) null else try attr(arena, tag.attrs, "id");
            continue;
        }
        if (tag.closing or !std.mem.eql(u8, tag.name, "TestMethod")) continue;
        const id = unit orelse continue;
        const class = (try attr(arena, tag.attrs, "className")) orelse continue;
        try classes.put(arena, id, class);
    }
    scanner = .{ .bytes = bytes };
    while (scanner.next()) |tag| {
        if (tag.closing or !std.mem.eql(u8, tag.name, "UnitTestResult")) continue;
        const name = (try attr(arena, tag.attrs, "testName")) orelse continue;
        const outcome = (try attr(arena, tag.attrs, "outcome")) orelse "";
        const class = if (try attr(arena, tag.attrs, "testId")) |id| classes.get(id) orelse "" else "";
        const id = if (class.len == 0 or (std.mem.startsWith(u8, name, class) and name.len > class.len and name[class.len] == '.'))
            name
        else
            try std.fmt.allocPrint(arena, "{s}.{s}", .{ class, name });
        try into.append(arena, .{ .id = id, .status = trxStatus(outcome) });
    }
}

fn trxStatus(outcome: []const u8) Status {
    if (std.ascii.eqlIgnoreCase(outcome, "Passed")) return .passed;
    const skipped = [_][]const u8{ "NotExecuted", "Inconclusive", "Pending", "NotRunnable" };
    for (skipped) |s| if (std.ascii.eqlIgnoreCase(outcome, s)) return .skipped;
    return .failed;
}

const rule_line = "=" ** 70;

const TestHead = struct {
    name: []const u8,
    qualified: []const u8,
    rest: []const u8,
};

fn dottedName(text: []const u8, extra: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.' and std.mem.indexOfScalar(u8, extra, c) == null) return false;
    }
    return true;
}

fn testHead(line: []const u8) ?TestHead {
    const open = std.mem.indexOf(u8, line, " (") orelse return null;
    const close = std.mem.indexOfScalarPos(u8, line, open, ')') orelse return null;
    const name = line[0..open];
    const qualified = line[open + 2 .. close];
    if (!dottedName(name, "") or !dottedName(qualified, "<>")) return null;
    return .{ .name = name, .qualified = qualified, .rest = line[close + 1 ..] };
}

const failed_loader = "unittest.loader._FailedTest";

fn modulePath(arena: Allocator, module: []const u8) ![]const u8 {
    const path = try arena.dupe(u8, module);
    std.mem.replaceScalar(u8, path, '.', '/');
    return std.fmt.allocPrint(arena, "{s}.py", .{path});
}

fn unittestCase(arena: Allocator, head: TestHead, status: Status) !Case {
    if (std.mem.startsWith(u8, head.qualified, failed_loader)) {
        const file = try modulePath(arena, head.name);
        return .{ .id = file, .file = file, .status = .failed, .whole = true };
    }
    const ends_in_name = head.qualified.len > head.name.len and head.qualified[head.qualified.len - head.name.len - 1] == '.' and std.mem.endsWith(u8, head.qualified, head.name);
    const id = if (ends_in_name) try arena.dupe(u8, head.qualified) else try std.fmt.allocPrint(arena, "{s}.{s}", .{ head.qualified, head.name });
    return .{ .id = id, .file = try unittestFile(arena, id), .status = status };
}

fn unittestFile(arena: Allocator, id: []const u8) ![]const u8 {
    const method = std.mem.lastIndexOfScalar(u8, id, '.') orelse return "";
    const class = std.mem.lastIndexOfScalar(u8, id[0..method], '.') orelse return "";
    return modulePath(arena, id[0..class]);
}

fn sectionHead(line: []const u8) ?TestHead {
    for ([_][]const u8{ "FAIL: ", "ERROR: ", "UNEXPECTED SUCCESS: " }) |mark| {
        if (std.mem.startsWith(u8, line, mark)) return testHead(line[mark.len..]);
    }
    return null;
}

fn ranCount(line: []const u8) ?usize {
    if (!std.mem.startsWith(u8, line, "Ran ")) return null;
    const end = std.mem.indexOfScalarPos(u8, line, "Ran ".len, ' ') orelse return null;
    if (!std.mem.startsWith(u8, line[end..], " test")) return null;
    return std.fmt.parseInt(usize, line["Ran ".len..end], 10) catch null;
}

pub fn parseUnittest(arena: Allocator, text: []const u8, into: *std.ArrayList(Case)) !bool {
    var ran: ?usize = null;
    var after_rule = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const section = after_rule;
        after_rule = std.mem.eql(u8, line, rule_line);
        if (section) {
            if (sectionHead(line)) |head| {
                try into.append(arena, try unittestCase(arena, head, .failed));
                continue;
            }
        }
        if (ranCount(line)) |count| {
            ran = count;
            continue;
        }
        if (std.mem.startsWith(u8, line, "skipped '") and into.items.len != 0) {
            into.items[into.items.len - 1].status = .skipped;
            continue;
        }
        const head = testHead(line) orelse continue;
        if (head.rest.len != 0 and !std.mem.startsWith(u8, head.rest, " ...")) continue;
        const skipped = std.mem.startsWith(u8, head.rest, " ... skipped ");
        try into.append(arena, try unittestCase(arena, head, if (skipped) .skipped else .passed));
    }
    const expected = ran orelse return false;
    into.items.len = settle(into.items).len;
    return into.items.len == expected;
}

pub const Kind = enum { pytest, dotnet, unittest };

const Words = struct {
    text: []const u8,
    at: usize = 0,

    fn next(self: *Words) ?[]const u8 {
        while (self.at < self.text.len and (self.text[self.at] == ' ' or self.text[self.at] == '\t')) self.at += 1;
        if (self.at >= self.text.len) return null;
        const quoted = self.text[self.at] == '"';
        const start = if (quoted) self.at + 1 else self.at;
        const stops: []const u8 = if (quoted) "\"" else " \t";
        const end = std.mem.indexOfAnyPos(u8, self.text, start, stops) orelse self.text.len;
        self.at = if (quoted) @min(end + 1, self.text.len) else end;
        return self.text[start..end];
    }
};

fn programName(word: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfAny(u8, word, "\\/");
    const base = if (slash) |at| word[at + 1 ..] else word;
    for ([_][]const u8{ ".exe", ".cmd", ".bat" }) |tail| {
        if (std.ascii.endsWithIgnoreCase(base, tail)) return base[0 .. base.len - tail.len];
    }
    return base;
}

fn isPython(program: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(program, "py")) return true;
    for ([_][]const u8{ "python", "pypy" }) |stem| {
        if (!std.ascii.startsWithIgnoreCase(program, stem)) continue;
        for (program[stem.len..]) |c| if (!std.ascii.isDigit(c) and c != '.') return false;
        return true;
    }
    return false;
}

fn pythonModuleKind(words: *Words) ?Kind {
    while (words.next()) |word| {
        if (std.mem.eql(u8, word, "-m")) {
            const module = words.next() orelse return null;
            if (std.mem.eql(u8, module, "pytest")) return .pytest;
            if (std.mem.eql(u8, module, "unittest")) return .unittest;
            return null;
        }
        if (word.len == 0 or word[0] != '-') return null;
        if (std.mem.eql(u8, word, "-X") or std.mem.eql(u8, word, "-W")) _ = words.next() orelse return null;
    }
    return null;
}

fn runnerKind(first: []const u8, words: *Words) ?Kind {
    const program = programName(first);
    if (std.ascii.eqlIgnoreCase(program, "pytest") or std.ascii.eqlIgnoreCase(program, "py.test")) return .pytest;
    if (isPython(program)) return pythonModuleKind(words);
    if (std.ascii.eqlIgnoreCase(program, "dotnet")) {
        const verb = words.next() orelse return null;
        return if (std.mem.eql(u8, verb, "test")) .dotnet else null;
    }
    return null;
}

pub fn kindOf(command: []const u8) ?Kind {
    if (std.mem.indexOfAny(u8, command, "&|;<>`\r\n") != null) return null;
    var words: Words = .{ .text = command };
    var first = words.next() orelse return null;
    for ([_][]const u8{ "uv", "poetry", "pipenv", "pdm" }) |wrapper| {
        if (!std.ascii.eqlIgnoreCase(programName(first), wrapper)) continue;
        const verb = words.next() orelse return null;
        if (!std.mem.eql(u8, verb, "run")) return null;
        first = words.next() orelse return null;
        break;
    }
    const kind = runnerKind(first, &words) orelse return null;
    while (words.next()) |word| {
        if (std.mem.eql(u8, word, "--")) return null;
        if (kind == .unittest and (std.mem.eql(u8, word, "-f") or std.mem.eql(u8, word, "--failfast"))) return null;
    }
    return kind;
}

const report_file = "emetgate-junit.xml";
const report_dir = "emetgate-trx";

fn plainName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    return true;
}

pub const Reporter = struct {
    kind: Kind,
    command: []const u8,
    path: []const u8,

    pub fn of(gpa: Allocator, gate_dir: []const u8, command: []const u8) !?Reporter {
        const kind = kindOf(command) orelse return null;
        const base = std.fs.path.basename(gate_dir);
        if (!plainName(base)) return null;
        const name = switch (kind) {
            .pytest => report_file,
            .dotnet => report_dir,
            .unittest => "",
        };
        const path = try std.fmt.allocPrint(gpa, "{s}-cache\\{s}", .{ gate_dir, name });
        errdefer gpa.free(path);
        const augmented = switch (kind) {
            .pytest => try std.fmt.allocPrint(gpa, "{s} --junitxml=..\\{s}-cache\\{s} -o junit_family=xunit1 --continue-on-collection-errors --maxfail=0", .{ std.mem.trim(u8, command, " \t"), base, name }),
            .dotnet => try std.fmt.allocPrint(gpa, "{s} --logger trx --results-directory ..\\{s}-cache\\{s}", .{ std.mem.trim(u8, command, " \t"), base, name }),
            .unittest => try std.fmt.allocPrint(gpa, "{s} -v", .{std.mem.trim(u8, command, " \t")}),
        };
        return .{ .kind = kind, .command = augmented, .path = path };
    }

    pub fn deinit(self: Reporter, gpa: Allocator) void {
        gpa.free(self.command);
        gpa.free(self.path);
    }

    pub fn clear(self: Reporter, io: std.Io) void {
        switch (self.kind) {
            .pytest => std.Io.Dir.deleteFileAbsolute(io, self.path) catch {},
            .dotnet => std.Io.Dir.cwd().deleteTree(io, self.path) catch {},
            .unittest => {},
        }
    }

    pub fn refused(self: Reporter, report: sandbox.Report) bool {
        const code = switch (report.outcome) {
            .exited => |code| code,
            else => return false,
        };
        return switch (self.kind) {
            .pytest => code == 4,
            .unittest => code == 2,
            .dotnet => false,
        };
    }

    pub fn collect(self: Reporter, gpa: Allocator, io: std.Io, report: sandbox.Report) !?Results {
        const code = switch (report.outcome) {
            .exited => |code| code,
            else => return null,
        };
        if (report.killed_leftovers) return null;
        const known = switch (self.kind) {
            .pytest, .unittest => code == 0 or code == 1 or code == 5,
            .dotnet => code == 0 or code == 1,
        };
        if (!known) return null;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();
        var cases: std.ArrayList(Case) = .empty;
        const found = switch (self.kind) {
            .pytest => try self.readJunit(arena, io, &cases),
            .dotnet => try self.readTrx(arena, io, &cases),
            .unittest => try parseUnittest(arena, report.stderr, &cases),
        };
        if (!found) {
            arena_state.deinit();
            return null;
        }
        const settled = settle(cases.items);
        const any_failed = for (settled) |case| {
            if (case.status == .failed) break true;
        } else false;
        if (any_failed != (code == 1)) {
            arena_state.deinit();
            return null;
        }
        return .{ .arena = arena_state, .cases = settled };
    }

    fn readJunit(self: Reporter, arena: Allocator, io: std.Io, cases: *std.ArrayList(Case)) !bool {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, self.path, arena, .limited(max_report_bytes)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        if (std.mem.indexOf(u8, bytes, "</testsuites>") == null and std.mem.indexOf(u8, bytes, "</testsuite>") == null) return false;
        try parseJunit(arena, bytes, cases);
        return true;
    }

    fn readTrx(self: Reporter, arena: Allocator, io: std.Io, cases: *std.ArrayList(Case)) !bool {
        var dir = std.Io.Dir.openDirAbsolute(io, self.path, .{ .iterate = true }) catch return false;
        defer dir.close(io);
        var any = false;
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.name, ".trx")) continue;
            const bytes = dir.readFileAlloc(io, entry.name, arena, .limited(max_report_bytes)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return false,
            };
            if (std.mem.indexOf(u8, bytes, "</TestRun>") == null) return false;
            try parseTrx(arena, bytes, cases);
            any = true;
        }
        return any;
    }
};

const max_report_bytes = 64 * 1024 * 1024;

pub const Verdict = struct {
    regressed: []const []const u8,
    vanished: []const Case,
};

pub fn judge(arena: Allocator, before: []const Case, after: []const Case) !Verdict {
    var regressed: std.ArrayList([]const u8) = .empty;
    var vanished: std.ArrayList(Case) = .empty;
    for (before) |was| {
        if (was.status != .passed) continue;
        if (find(after, was.id)) |now| {
            switch (now.status) {
                .passed => {},
                .failed => try regressed.append(arena, was.id),
                .skipped => try vanished.append(arena, was),
            }
            continue;
        }
        const broken = was.file.len != 0 and if (find(after, was.file)) |module| module.whole and module.status == .failed else false;
        if (broken) try regressed.append(arena, was.id) else try vanished.append(arena, was);
    }
    return .{ .regressed = regressed.items, .vanished = vanished.items };
}

pub const Touched = struct {
    rel: []const u8,
    original: ?[]const u8,
};

fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const short, const long = if (a.len <= b.len) .{ a, b } else .{ b, a };
    const tail = long[long.len - short.len ..];
    for (tail, short) |x, y| {
        const nx = if (x == '\\') '/' else std.ascii.toLower(x);
        const ny = if (y == '\\') '/' else std.ascii.toLower(y);
        if (nx != ny) return false;
    }
    return long.len == short.len or long[long.len - short.len - 1] == '/' or long[long.len - short.len - 1] == '\\';
}

pub fn shortName(id: []const u8) []const u8 {
    var end = id.len;
    if (std.mem.indexOfAny(u8, id, "[(")) |cut| end = cut;
    const head = id[0..end];
    const colon = if (std.mem.lastIndexOf(u8, head, "::")) |at| at + 2 else 0;
    const dot = if (std.mem.lastIndexOfScalar(u8, head, '.')) |at| at + 1 else 0;
    return head[@max(colon, dot)..];
}

pub fn unexempt(arena: Allocator, vanished: []const Case, touched: []const Touched) ![]const []const u8 {
    var kept: std.ArrayList([]const u8) = .empty;
    for (vanished) |case| {
        const exempt = for (touched) |t| {
            if (case.file.len != 0) {
                if (samePath(case.file, t.rel)) break true;
                continue;
            }
            const name = shortName(case.id);
            const original = t.original orelse continue;
            if (name.len != 0 and std.mem.indexOf(u8, original, name) != null) break true;
        } else false;
        if (!exempt) try kept.append(arena, case.id);
    }
    return kept.items;
}

const testing = std.testing;

fn parsed(arena: Allocator, bytes: []const u8, comptime parse: anytype) ![]Case {
    var cases: std.ArrayList(Case) = .empty;
    try parse(arena, bytes, &cases);
    return settle(cases.items);
}

const junit_sample =
    \\<?xml version="1.0" encoding="utf-8"?><testsuites><testsuite name="pytest" errors="1" failures="2" skipped="1" tests="6">
    \\<testcase classname="" name="tests.test_b" file="tests/test_b.py" time="0.000"><error message="collection failure">ImportError &lt;module&gt;</error></testcase>
    \\<testcase classname="tests.test_a" name="test_ok" file="tests\test_a.py" line="0" time="0.001" />
    \\<testcase classname="tests.test_a.TestX" name="test_bad" file="tests\test_a.py" line="4"><failure message="assert 1 == 2"><![CDATA[<testcase name="fake"/>]]></failure></testcase>
    \\<testcase classname="tests.test_a" name="test_sk" file="tests\test_a.py" line="8"><skipped type="pytest.skip" message="unconditional skip">x</skipped></testcase>
    \\<testcase classname="tests.test_a" name="test_p[a&amp;b]" file="tests\test_a.py" line="11" />
    \\<testcase classname="tests.test_a" name="test_p[2]" file="tests\test_a.py" line="11"><failure message="assert 2 == 1">x</failure></testcase>
    \\<testcase classname="tests.test_a" name="test_ok" file="tests\test_a.py" line="0"><error message="failed on teardown">x</error></testcase>
    \\</testsuite></testsuites>
;

test "a pytest junit report becomes one result per test id, with a collection error as a failed whole module" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const cases = try parsed(arena_state.allocator(), junit_sample, parseJunit);
    try testing.expectEqual(@as(usize, 6), cases.len);
    const module = find(cases, "tests/test_b.py").?;
    try testing.expect(module.whole);
    try testing.expectEqual(Status.failed, module.status);
    try testing.expectEqual(Status.failed, find(cases, "tests/test_a.py::test_ok").?.status);
    try testing.expectEqual(Status.failed, find(cases, "tests/test_a.py::TestX::test_bad").?.status);
    try testing.expectEqual(Status.skipped, find(cases, "tests/test_a.py::test_sk").?.status);
    try testing.expectEqual(Status.passed, find(cases, "tests/test_a.py::test_p[a&b]").?.status);
    try testing.expectEqual(Status.failed, find(cases, "tests/test_a.py::test_p[2]").?.status);
    try testing.expectEqualStrings("tests/test_a.py", find(cases, "tests/test_a.py::test_sk").?.file);
    try testing.expect(find(cases, "fake") == null);
}

const trx_sample =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<TestRun id="1" xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010">
    \\  <Results>
    \\    <UnitTestResult executionId="e1" testId="t1" testName="Calc.Tests.AddTests.AddsTwo" outcome="Passed" />
    \\    <UnitTestResult executionId="e2" testId="t2" testName="Subtracts" outcome="Failed"><Output><ErrorInfo><Message>Assert.Equal() Failure</Message></ErrorInfo></Output></UnitTestResult>
    \\    <UnitTestResult executionId="e3" testId="t3" testName="Later" outcome="NotExecuted" />
    \\    <UnitTestResult executionId="e4" testId="t4" testName="Calc.Tests.AddTests.Overflows(x: &quot;big&quot;)" outcome="Error" />
    \\  </Results>
    \\  <TestDefinitions>
    \\    <UnitTest name="AddsTwo" id="t1"><TestMethod className="Calc.Tests.AddTests" name="AddsTwo" /></UnitTest>
    \\    <UnitTest name="Subtracts" id="t2"><TestMethod className="Calc.Tests.SubTests" name="Subtracts" /></UnitTest>
    \\    <UnitTest name="Later" id="t3"><TestMethod className="Calc.Tests.SubTests" name="Later" /></UnitTest>
    \\  </TestDefinitions>
    \\</TestRun>
;

test "a dotnet trx report becomes one result per fully qualified test, with not executed as skipped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const cases = try parsed(arena_state.allocator(), trx_sample, parseTrx);
    try testing.expectEqual(@as(usize, 4), cases.len);
    try testing.expectEqual(Status.passed, find(cases, "Calc.Tests.AddTests.AddsTwo").?.status);
    try testing.expectEqual(Status.failed, find(cases, "Calc.Tests.SubTests.Subtracts").?.status);
    try testing.expectEqual(Status.skipped, find(cases, "Calc.Tests.SubTests.Later").?.status);
    try testing.expectEqual(Status.failed, find(cases, "Calc.Tests.AddTests.Overflows(x: \"big\")").?.status);
    try testing.expectEqualStrings("Overflows", shortName("Calc.Tests.AddTests.Overflows(x: \"big\")"));
}

test "the runner is read from every way of writing its command, and a command that cannot take the report flags has none" {
    const pytest_forms = [_][]const u8{ "pytest", "pytest -q", "py.test tests", "pytest.exe -x", ".venv\\Scripts\\pytest", "python -m pytest", "python -m pytest -q tests", "py -3.12 -m pytest", "python3 -X utf8 -m pytest", "\"C:\\Program Files\\Py\\python.exe\" -m pytest -k \"a b\"", "uv run pytest", "poetry run python -m pytest -q", "pipenv run pytest", "pdm run pytest" };
    for (pytest_forms) |form| try testing.expectEqual(@as(?Kind, .pytest), kindOf(form));
    const unittest_forms = [_][]const u8{ "python -m unittest", "python -m unittest discover -s tests", "python -m unittest tests.test_a -b", ".venv\\Scripts\\python -m unittest discover", "py -m unittest" };
    for (unittest_forms) |form| try testing.expectEqual(@as(?Kind, .unittest), kindOf(form));
    const dotnet_forms = [_][]const u8{ "dotnet test", "dotnet test t\\T.csproj --no-restore", "dotnet.exe test" };
    for (dotnet_forms) |form| try testing.expectEqual(@as(?Kind, .dotnet), kindOf(form));
    const others = [_][]const u8{ "", "pytest && echo done", "pytest > out.txt", "npm test", "python manage.py test", "python -c \"import pytest\"", "python -m nose", "dotnet build", "uv sync", "pythonista -m pytest", "pytest -- -x", "dotnet test -- x=y", "python -m unittest -f", "python -m unittest --failfast discover" };
    for (others) |form| try testing.expectEqual(@as(?Kind, null), kindOf(form));
}

fn unittestCases(arena: Allocator, text: []const u8) !?[]Case {
    var cases: std.ArrayList(Case) = .empty;
    if (!try parseUnittest(arena, text, &cases)) return null;
    return cases.items;
}

test "verbose unittest output becomes one result per test on the names of every Python" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = (try unittestCases(arena,
        "test_good (pkg.test_a.T.test_good) ... ok\r\n" ++
            "test_old (pkg.test_a.T) ... ok\r\n" ++
            "test_bad (pkg.test_a.T.test_bad) ... FAIL\r\n" ++
            "test_loud (pkg.test_a.T.test_loud) ... noise from the test\r\nok\r\n" ++
            "test_doc (pkg.test_a.T.test_doc)\r\nWhat it does ... ok\r\n" ++
            "test_sub (pkg.test_a.T.test_sub) ... \r\n" ++
            "test_skip (pkg.test_a.T.test_skip) ... skipped 'later'\r\n" ++
            "test_late (pkg.test_a.T.test_late) ... noise\r\nskipped 'later'\r\n" ++
            "test_lucky (pkg.test_a.T.test_lucky) ... unexpected success\r\n" ++
            "test_gone (unittest.loader._FailedTest.test_gone) ... ERROR\r\n" ++
            "\r\n" ++ rule_line ++ "\r\nFAIL: test_bad (pkg.test_a.T.test_bad)\r\n----\r\nAssertionError\r\n" ++
            rule_line ++ "\r\nFAIL: test_sub (pkg.test_a.T.test_sub) (i=1)\r\n----\r\n" ++
            "FAIL: test_good (pkg.test_a.T.test_good)\r\n" ++
            rule_line ++ "\r\nUNEXPECTED SUCCESS: test_lucky (pkg.test_a.T.test_lucky)\r\n" ++
            rule_line ++ "\r\nERROR: test_gone (unittest.loader._FailedTest.test_gone)\r\n" ++
            "----\r\nRan 10 tests in 0.002s\r\n\r\nFAILED (failures=2, errors=1, skipped=2, unexpected successes=1)\r\n")).?;
    try testing.expectEqual(@as(usize, 10), cases.len);
    try testing.expectEqual(Status.passed, find(cases, "pkg.test_a.T.test_good").?.status);
    try testing.expectEqual(Status.passed, find(cases, "pkg.test_a.T.test_old").?.status);
    try testing.expectEqual(Status.failed, find(cases, "pkg.test_a.T.test_bad").?.status);
    try testing.expectEqual(Status.passed, find(cases, "pkg.test_a.T.test_loud").?.status);
    try testing.expectEqual(Status.passed, find(cases, "pkg.test_a.T.test_doc").?.status);
    try testing.expectEqual(Status.failed, find(cases, "pkg.test_a.T.test_sub").?.status);
    try testing.expectEqual(Status.skipped, find(cases, "pkg.test_a.T.test_skip").?.status);
    try testing.expectEqual(Status.skipped, find(cases, "pkg.test_a.T.test_late").?.status);
    try testing.expectEqual(Status.failed, find(cases, "pkg.test_a.T.test_lucky").?.status);
    try testing.expectEqualStrings("pkg/test_a.py", find(cases, "pkg.test_a.T.test_bad").?.file);
    const module = find(cases, "test_gone.py").?;
    try testing.expect(module.whole);
    try testing.expectEqual(Status.failed, module.status);
}

test "unittest output that does not add up to its Ran line gives no per-test result" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect(try unittestCases(arena, "test_a (m.T.test_a) ... ok\n") == null);
    try testing.expect(try unittestCases(arena, "setUpClass (m.T) ... ERROR\n----\nRan 0 tests in 0.0s\n") == null);
    try testing.expect(try unittestCases(arena, "m.T.test_a ... ok\n----\nRan 1 test in 0.0s\n") == null);
    try testing.expectEqual(@as(usize, 0), (try unittestCases(arena, "----\nRan 0 tests in 0.000s\n\nNO TESTS RAN\n")).?.len);
}

test "a pytest or dotnet or unittest command gets a reporter, and only on a plain gate directory name" {
    const gpa = testing.allocator;
    const py = (try Reporter.of(gpa, "C:\\w\\k\\shadow", ".venv\\Scripts\\python -m pytest")).?;
    defer py.deinit(gpa);
    try testing.expectEqualStrings(".venv\\Scripts\\python -m pytest --junitxml=..\\shadow-cache\\emetgate-junit.xml -o junit_family=xunit1 --continue-on-collection-errors --maxfail=0", py.command);
    try testing.expectEqualStrings("C:\\w\\k\\shadow-cache\\emetgate-junit.xml", py.path);
    const net = (try Reporter.of(gpa, "C:\\w\\k\\shadow", "dotnet test \"t\\T.csproj\"")).?;
    defer net.deinit(gpa);
    try testing.expectEqual(Kind.dotnet, net.kind);
    try testing.expect(std.mem.endsWith(u8, net.command, " --logger trx --results-directory ..\\shadow-cache\\emetgate-trx"));
    try testing.expect(try Reporter.of(gpa, "C:\\w\\k\\shadow", "zig build test") == null);
    const bare = (try Reporter.of(gpa, "C:\\w\\k\\shadow", "pytest -q")).?;
    defer bare.deinit(gpa);
    try testing.expect(std.mem.startsWith(u8, bare.command, "pytest -q --junitxml="));
    const unit = (try Reporter.of(gpa, "C:\\w\\k\\shadow", "python -m unittest discover")).?;
    defer unit.deinit(gpa);
    try testing.expectEqualStrings("python -m unittest discover -v", unit.command);
    try testing.expect(try Reporter.of(gpa, "C:\\w\\k\\sha dow", "python -m pytest") == null);
}

fn cases3(comptime statuses: [3]Status) [3]Case {
    return .{
        .{ .id = "t.py::a", .file = "t.py", .status = statuses[0] },
        .{ .id = "t.py::b", .file = "t.py", .status = statuses[1] },
        .{ .id = "u.py::c", .file = "u.py", .status = statuses[2] },
    };
}

test "the gate judges per test: a passing test that fails or breaks its module regressed, one that is gone or skipped vanished" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = cases3(.{ .passed, .failed, .passed });

    const same = try judge(arena, &before, &before);
    try testing.expectEqual(@as(usize, 0), same.regressed.len + same.vanished.len);

    const fixed = cases3(.{ .passed, .passed, .passed });
    const better = try judge(arena, &before, &fixed);
    try testing.expectEqual(@as(usize, 0), better.regressed.len + better.vanished.len);

    const worse = cases3(.{ .failed, .failed, .passed });
    const regressed = try judge(arena, &before, &worse);
    try testing.expectEqual(@as(usize, 1), regressed.regressed.len);
    try testing.expectEqualStrings("t.py::a", regressed.regressed[0]);

    var added = [_]Case{ before[0], before[1], .{ .id = "t.py::new", .file = "t.py", .status = .failed }, before[2] };
    const debt = try judge(arena, &before, settle(&added));
    try testing.expectEqual(@as(usize, 0), debt.regressed.len + debt.vanished.len);

    const broken = [_]Case{ .{ .id = "t.py", .file = "t.py", .status = .failed, .whole = true }, before[2] };
    const collection = try judge(arena, &before, &broken);
    try testing.expectEqual(@as(usize, 1), collection.regressed.len);
    try testing.expectEqualStrings("t.py::a", collection.regressed[0]);

    const gone = [_]Case{before[1]};
    const missing = try judge(arena, &before, &gone);
    try testing.expectEqual(@as(usize, 0), missing.regressed.len);
    try testing.expectEqual(@as(usize, 2), missing.vanished.len);
    try testing.expectEqual(@as(usize, 2), (try unexempt(arena, missing.vanished, &.{})).len);
    const kept = try unexempt(arena, missing.vanished, &.{.{ .rel = "src\\t.py", .original = null }});
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqualStrings("u.py::c", kept[0]);
    try testing.expectEqual(@as(usize, 0), (try unexempt(arena, missing.vanished, &.{ .{ .rel = "T.py", .original = null }, .{ .rel = "u.py", .original = null } })).len);
    try testing.expectEqual(@as(usize, 2), (try unexempt(arena, missing.vanished, &.{.{ .rel = "at.py", .original = null }})).len);

    const skipped = cases3(.{ .passed, .failed, .skipped });
    const quiet = try judge(arena, &before, &skipped);
    try testing.expectEqual(@as(usize, 1), quiet.vanished.len);
    try testing.expectEqualStrings("u.py::c", quiet.vanished[0].id);

    const named = [_]Case{.{ .id = "Calc.Tests.AddTests.AddsTwo", .status = .passed }};
    const dropped = try judge(arena, &named, &.{});
    try testing.expectEqual(@as(usize, 1), (try unexempt(arena, dropped.vanished, &.{.{ .rel = "tests/Other.cs", .original = "void Other() {}" }})).len);
    try testing.expectEqual(@as(usize, 0), (try unexempt(arena, dropped.vanished, &.{.{ .rel = "tests/AddTests.cs", .original = "public void AddsTwo() {}" }})).len);
}
