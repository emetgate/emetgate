const std = @import("std");
const c = @import("c");
const ts = @import("tree_sitter.zig");
const regex = @import("regex.zig");
const Span = @import("symbol.zig").Span;

const Allocator = std.mem.Allocator;

pub const prefix = "q:";
pub const max_query_bytes = 4 * 1024 - prefix.len;
pub const violation_capture = "violation";
pub const max_captures_per_pattern = 8;

const operations_per_callback = 100;

pub const Limits = struct {
    operations: u64 = 20_000_000,
    match_limit: u32 = 1024,
};

pub const CompileError = error{
    QueryTooLong,
    QuerySyntax,
    QueryNodeType,
    QueryField,
    QueryCapture,
    QueryStructure,
    QueryLanguage,
    QueryMissingViolation,
    QueryUnknownPredicate,
    QueryDirective,
    QueryPredicateArguments,
    QueryQuantifiedCapture,
    QueryTooManyCaptures,
    RegexUnsupported,
    RegexSyntax,
};

pub const RunError = error{ QueryBudgetExceeded, QueryMatchLimitExceeded };

pub fn dependsOnLanguage(err: CompileError) bool {
    return switch (err) {
        error.QueryNodeType, error.QueryField, error.QueryStructure, error.QueryLanguage => true,
        else => false,
    };
}

pub const Diagnostic = struct {
    what: []const u8 = "",
    buffer: [64]u8 = undefined,
    len: usize = 0,

    fn set(self: *Diagnostic, what: []const u8, at_text: []const u8) void {
        self.what = what;
        var len = @min(at_text.len, self.buffer.len);
        while (len > 0 and len < at_text.len and at_text[len] & 0xC0 == 0x80) len -= 1;
        self.len = len;
        @memcpy(self.buffer[0..self.len], at_text[0..self.len]);
    }

    pub fn at(self: *const Diagnostic) []const u8 {
        return self.buffer[0..self.len];
    }
};

const Arg = union(enum) {
    capture: u32,
    string: []const u8,
};

const Predicate = union(enum) {
    eq: struct { capture: u32, other: Arg, negate: bool },
    any_of: struct { capture: u32, values: []const []const u8 },
    match: struct { capture: u32, re: regex.Regex, negate: bool },
};

pub const Query = struct {
    raw: *c.TSQuery,
    arena: std.heap.ArenaAllocator,
    patterns: []const []const Predicate,
    violation: u32,

    pub fn deinit(self: *Query) void {
        c.ts_query_delete(self.raw);
        self.arena.deinit();
    }
};

pub fn validateLength(text: []const u8) CompileError!void {
    if (text.len > max_query_bytes) return error.QueryTooLong;
}

pub fn compile(gpa: Allocator, language: *const ts.Language, text: []const u8, diag: ?*Diagnostic) (CompileError || Allocator.Error)!Query {
    try validateLength(text);
    var offset: u32 = 0;
    var kind: c.TSQueryError = c.TSQueryErrorNone;
    const raw = c.ts_query_new(language, text.ptr, @intCast(text.len), &offset, &kind) orelse {
        if (diag) |d| d.set("tree-sitter could not compile the query", tokenAt(text, offset));
        return switch (kind) {
            c.TSQueryErrorNodeType => error.QueryNodeType,
            c.TSQueryErrorField => error.QueryField,
            c.TSQueryErrorCapture => error.QueryCapture,
            c.TSQueryErrorStructure => error.QueryStructure,
            c.TSQueryErrorLanguage => error.QueryLanguage,
            else => error.QuerySyntax,
        };
    };
    errdefer c.ts_query_delete(raw);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const violation = captureId(raw, violation_capture) orelse {
        if (diag) |d| d.set("no @" ++ violation_capture ++ " capture", patternText(raw, text, 0));
        return error.QueryMissingViolation;
    };
    const count = c.ts_query_pattern_count(raw);
    const patterns = try arena.alloc([]const Predicate, count);
    for (patterns, 0..) |*slot, i| {
        const index: u32 = @intCast(i);
        if (c.ts_query_capture_quantifier_for_id(raw, index, violation) == c.TSQuantifierZero) {
            if (diag) |d| d.set("a pattern without @" ++ violation_capture, patternText(raw, text, index));
            return error.QueryMissingViolation;
        }
        const own = rawPatternText(raw, text, index);
        if (repeatsCapture(own) or capturedGroupRepeats(own)) {
            if (diag) |d| d.set("a capture repeated with + or *, or on a group or alternation with + or * inside, costs tree-sitter quadratic work the budget cannot see; capture one node per match", patternText(raw, text, index));
            return error.QueryQuantifiedCapture;
        }
        if (captureCount(own) > max_captures_per_pattern) {
            if (diag) |d| d.set("more than " ++ std.fmt.comptimePrint("{d}", .{max_captures_per_pattern}) ++ " captures in one pattern cost tree-sitter work the budget cannot see", patternText(raw, text, index));
            return error.QueryTooManyCaptures;
        }
        slot.* = try predicatesOf(arena, raw, index, diag);
    }
    return .{ .raw = raw, .arena = arena_state, .patterns = patterns, .violation = violation };
}

fn rawPatternText(raw: *const c.TSQuery, text: []const u8, pattern: u32) []const u8 {
    const start = @min(c.ts_query_start_byte_for_pattern(raw, pattern), text.len);
    const end = @min(c.ts_query_end_byte_for_pattern(raw, pattern), text.len);
    return text[@min(start, end)..end];
}

fn captureCount(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        switch (text[i]) {
            '"' => i = stringEnd(text, i),
            ';' => i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len,
            '(' => {
                var next = i + 1;
                while (next < text.len and std.ascii.isWhitespace(text[next])) next += 1;
                i = if (next < text.len and text[next] == '#') predicateEnd(text, next) else i + 1;
            },
            '@' => {
                count += 1;
                i = tokenEnd(text, i + 1);
            },
            else => i += 1,
        }
    }
    return count;
}

fn predicateEnd(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len) {
        switch (text[i]) {
            '"' => i = stringEnd(text, i),
            ')' => return i + 1,
            else => i += 1,
        }
    }
    return text.len;
}

fn repeatsCapture(text: []const u8) bool {
    var opens: [max_query_bytes]u32 = undefined;
    var depth: usize = 0;
    var item: ?usize = null;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        switch (ch) {
            ' ', '\t', '\r', '\n' => i += 1,
            ';' => i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len,
            '"' => {
                item = i;
                i = stringEnd(text, i);
            },
            '(', '[' => {
                if (depth == opens.len) return true;
                opens[depth] = @intCast(i);
                depth += 1;
                item = null;
                i += 1;
            },
            ')', ']' => {
                item = if (depth > 0) opens[depth - 1] else null;
                depth -|= 1;
                i += 1;
            },
            '+', '*' => {
                if (item) |from| {
                    if (hasCapture(text[from..i]) or nextIsCapture(text, i + 1)) return true;
                }
                i += 1;
            },
            '@' => {
                item = null;
                i = tokenEnd(text, i + 1);
            },
            else => {
                item = i;
                i = tokenEnd(text, i + 1);
            },
        }
    }
    return false;
}

fn capturedGroupRepeats(text: []const u8) bool {
    var opens: [max_query_bytes]u32 = undefined;
    var depth: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        switch (text[i]) {
            '"' => i = stringEnd(text, i),
            ';' => i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len,
            '(', '[' => {
                if (depth == opens.len) return true;
                opens[depth] = @intCast(i);
                depth += 1;
                i += 1;
            },
            ')', ']' => {
                if (depth > 0) {
                    depth -= 1;
                    const open = opens[depth];
                    if (isGroup(text, open) and nextIsCapture(text, i + 1) and hasRepeat(text[open + 1 .. i])) return true;
                }
                i += 1;
            },
            else => i += 1,
        }
    }
    return false;
}

fn isGroup(text: []const u8, open: usize) bool {
    if (text[open] == '[') return true;
    var i = open + 1;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    return i < text.len and switch (text[i]) {
        '(', '[', '"', '.' => true,
        else => false,
    };
}

fn hasRepeat(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        switch (text[i]) {
            '"' => i = stringEnd(text, i),
            ';' => i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len,
            '(' => i = if (isGroup(text, i)) i + 1 else closingEnd(text, i),
            '+', '*' => return true,
            else => i += 1,
        }
    }
    return false;
}

fn closingEnd(text: []const u8, open: usize) usize {
    var depth: usize = 0;
    var i = open;
    while (i < text.len) {
        switch (text[i]) {
            '"' => i = stringEnd(text, i),
            ';' => i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len,
            '(', '[' => {
                depth += 1;
                i += 1;
            },
            ')', ']' => {
                depth -|= 1;
                i += 1;
                if (depth == 0) return i;
            },
            else => i += 1,
        }
    }
    return text.len;
}

fn stringEnd(text: []const u8, open: usize) usize {
    var i = open + 1;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '\\' => i += 1,
            '"' => return i + 1,
            else => {},
        }
    }
    return text.len;
}

fn tokenEnd(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            ' ', '\t', '\r', '\n', '(', ')', '[', ']', '"', '@', ';', '+', '*' => return i,
            else => {},
        }
    }
    return text.len;
}

fn hasCapture(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        switch (text[i]) {
            '"' => i = stringEnd(text, i),
            ';' => i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len,
            '@' => return true,
            else => i += 1,
        }
    }
    return false;
}

fn nextIsCapture(text: []const u8, from: usize) bool {
    var i = from;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    return i < text.len and text[i] == '@';
}

fn tokenAt(text: []const u8, offset: u32) []const u8 {
    const start = @min(offset, text.len);
    var end = start;
    while (end < text.len and end - start < 32 and !std.ascii.isWhitespace(text[end]) and text[end] != ')') end += 1;
    if (end == start) end = @min(text.len, start + 1);
    return text[start..end];
}

fn patternText(raw: *const c.TSQuery, text: []const u8, index: u32) []const u8 {
    const start = c.ts_query_start_byte_for_pattern(raw, index);
    const end = c.ts_query_end_byte_for_pattern(raw, index);
    return std.mem.trim(u8, text[@min(start, text.len)..@min(end, text.len)], " \t\r\n");
}

fn captureId(raw: *const c.TSQuery, name: []const u8) ?u32 {
    const count = c.ts_query_capture_count(raw);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var len: u32 = 0;
        const ptr = c.ts_query_capture_name_for_id(raw, i, &len);
        if (std.mem.eql(u8, ptr[0..len], name)) return i;
    }
    return null;
}

fn stringValue(raw: *const c.TSQuery, id: u32) []const u8 {
    var len: u32 = 0;
    const ptr = c.ts_query_string_value_for_id(raw, id, &len);
    return ptr[0..len];
}

fn predicatesOf(arena: Allocator, raw: *const c.TSQuery, pattern: u32, diag: ?*Diagnostic) (CompileError || Allocator.Error)![]const Predicate {
    var step_count: u32 = 0;
    const steps_ptr = c.ts_query_predicates_for_pattern(raw, pattern, &step_count);
    const steps = if (step_count == 0) &[_]c.TSQueryPredicateStep{} else steps_ptr[0..step_count];
    var list: std.ArrayList(Predicate) = .empty;
    var start: usize = 0;
    for (steps, 0..) |step, i| {
        if (step.type != c.TSQueryPredicateStepTypeDone) continue;
        try list.append(arena, try predicateOf(arena, raw, steps[start..i], diag));
        start = i + 1;
    }
    return list.items;
}

fn predicateOf(arena: Allocator, raw: *const c.TSQuery, steps: []const c.TSQueryPredicateStep, diag: ?*Diagnostic) (CompileError || Allocator.Error)!Predicate {
    const name = stringValue(raw, steps[0].value_id);
    const args = steps[1..];
    if (std.mem.endsWith(u8, name, "!")) {
        if (diag) |d| d.set("directives are not supported", name);
        return error.QueryDirective;
    }
    const Kind = enum { eq, not_eq, any_of, match, not_match };
    const known = [_]struct { []const u8, Kind }{
        .{ "eq?", .eq },
        .{ "not-eq?", .not_eq },
        .{ "any-of?", .any_of },
        .{ "match?", .match },
        .{ "not-match?", .not_match },
    };
    const kind = for (known) |entry| {
        if (std.mem.eql(u8, entry[0], name)) break entry[1];
    } else {
        if (diag) |d| d.set("unknown predicate; supported: #eq? #not-eq? #any-of? #match? #not-match?", name);
        return error.QueryUnknownPredicate;
    };

    const shape_ok = args.len >= 2 and args[0].type == c.TSQueryPredicateStepTypeCapture and switch (kind) {
        .eq, .not_eq => args.len == 2,
        .any_of => allStrings(args[1..]),
        .match, .not_match => args.len == 2 and args[1].type == c.TSQueryPredicateStepTypeString,
    };
    if (!shape_ok) {
        if (diag) |d| d.set(switch (kind) {
            .eq, .not_eq => "takes a capture and one capture or string",
            .any_of => "takes a capture and one or more strings",
            .match, .not_match => "takes a capture and one regex string",
        }, name);
        return error.QueryPredicateArguments;
    }

    const capture = args[0].value_id;
    switch (kind) {
        .eq, .not_eq => return .{ .eq = .{
            .capture = capture,
            .other = if (args[1].type == c.TSQueryPredicateStepTypeCapture) .{ .capture = args[1].value_id } else .{ .string = stringValue(raw, args[1].value_id) },
            .negate = kind == .not_eq,
        } },
        .any_of => {
            const values = try arena.alloc([]const u8, args.len - 1);
            for (args[1..], values) |arg, *value| value.* = stringValue(raw, arg.value_id);
            return .{ .any_of = .{ .capture = capture, .values = values } };
        },
        .match, .not_match => {
            var regex_diag: regex.Diagnostic = .{};
            const re = regex.Regex.compile(arena, stringValue(raw, args[1].value_id), &regex_diag) catch |err| {
                if (diag) |d| d.set(regex_diag.what, regex_diag.at);
                return err;
            };
            return .{ .match = .{ .capture = capture, .re = re, .negate = kind == .not_match } };
        },
    }
}

fn allStrings(steps: []const c.TSQueryPredicateStep) bool {
    for (steps) |step| {
        if (step.type != c.TSQueryPredicateStepTypeString) return false;
    }
    return true;
}

const Progress = struct {
    cursor: *c.TSQueryCursor,
    budget: *u64,
    stopped: ?RunError = null,

    fn callback(state: [*c]c.TSQueryCursorState) callconv(.c) bool {
        const self: *Progress = @ptrCast(@alignCast(state.*.payload));
        return self.spend(operations_per_callback);
    }

    fn spend(self: *Progress, cost: u64) bool {
        if (self.stopped != null) return true;
        if (c.ts_query_cursor_did_exceed_match_limit(self.cursor)) {
            self.stopped = error.QueryMatchLimitExceeded;
            return true;
        }
        if (self.budget.* < cost) {
            self.stopped = error.QueryBudgetExceeded;
            return true;
        }
        self.budget.* -= cost;
        return false;
    }
};

pub fn run(gpa: Allocator, query: *const Query, tree: ts.Tree, span: Span, limits: Limits, out: *std.ArrayList(Span)) (RunError || Allocator.Error)!void {
    const cursor = c.ts_query_cursor_new().?;
    defer c.ts_query_cursor_delete(cursor);
    c.ts_query_cursor_set_match_limit(cursor, limits.match_limit);
    _ = c.ts_query_cursor_set_byte_range(cursor, span.start, span.end);

    var budget = limits.operations;
    var progress: Progress = .{ .cursor = cursor, .budget = &budget };
    const options: c.TSQueryCursorOptions = .{ .payload = &progress, .progress_callback = &Progress.callback };
    c.ts_query_cursor_exec_with_options(cursor, query.raw, tree.root().raw, &options);

    const first = out.items.len;
    errdefer out.shrinkRetainingCapacity(first);
    var match: c.TSQueryMatch = undefined;
    while (c.ts_query_cursor_next_match(cursor, &match)) {
        if (progress.spend(operations_per_callback)) break;
        const captures = if (match.capture_count == 0) &[_]c.TSQueryCapture{} else match.captures[0..match.capture_count];
        const holds = satisfies(gpa, query.patterns[match.pattern_index], tree, captures, &budget) catch |err| switch (err) {
            error.BudgetExceeded => return error.QueryBudgetExceeded,
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (!holds) continue;
        for (captures) |capture| {
            if (capture.index != query.violation) continue;
            const node: ts.Node = .{ .raw = capture.node };
            if (node.startByte() < span.start or node.endByte() > span.end) continue;
            try out.append(gpa, .{ .start = node.startByte(), .end = node.endByte() });
        }
    }
    _ = progress.spend(0);
    if (progress.stopped) |err| return err;
    dedupe(out, first);
}

fn dedupe(out: *std.ArrayList(Span), first: usize) void {
    const found = out.items[first..];
    std.mem.sort(Span, found, {}, struct {
        fn lessThan(_: void, a: Span, b: Span) bool {
            return a.start < b.start or (a.start == b.start and a.end < b.end);
        }
    }.lessThan);
    var len: usize = 0;
    for (found) |s| {
        if (len > 0 and found[len - 1].start == s.start and found[len - 1].end == s.end) continue;
        found[len] = s;
        len += 1;
    }
    out.shrinkRetainingCapacity(first + len);
}

fn satisfies(gpa: Allocator, predicates: []const Predicate, tree: ts.Tree, captures: []const c.TSQueryCapture, budget: *u64) (Allocator.Error || error{BudgetExceeded})!bool {
    for (predicates) |predicate| {
        switch (predicate) {
            .eq => |p| for (captures) |capture| {
                try charge(budget, 1);
                if (capture.index != p.capture) continue;
                const text = textOf(tree, capture.node);
                const same = switch (p.other) {
                    .string => |s| try equal(budget, text, s),
                    .capture => |other| try otherEquals(tree, captures, other, text, budget),
                };
                if (same == p.negate) return false;
            },
            .any_of => |p| for (captures) |capture| {
                try charge(budget, 1);
                if (capture.index != p.capture) continue;
                const text = textOf(tree, capture.node);
                for (p.values) |value| {
                    if (try equal(budget, text, value)) break;
                } else return false;
            },
            .match => |p| for (captures) |capture| {
                try charge(budget, 1);
                if (capture.index != p.capture) continue;
                if (try p.re.isMatch(gpa, textOf(tree, capture.node), budget) == p.negate) return false;
            },
        }
    }
    return true;
}

fn otherEquals(tree: ts.Tree, captures: []const c.TSQueryCapture, other: u32, text: []const u8, budget: *u64) error{BudgetExceeded}!bool {
    for (captures) |capture| {
        try charge(budget, 1);
        if (capture.index != other) continue;
        if (!try equal(budget, textOf(tree, capture.node), text)) return false;
    }
    return true;
}

fn equal(budget: *u64, a: []const u8, b: []const u8) error{BudgetExceeded}!bool {
    try charge(budget, 1 + @min(a.len, b.len));
    return std.mem.eql(u8, a, b);
}

fn charge(budget: *u64, cost: u64) error{BudgetExceeded}!void {
    if (budget.* < cost) return error.BudgetExceeded;
    budget.* -= cost;
}

fn textOf(tree: ts.Tree, node: c.TSNode) []const u8 {
    return tree.text(.{ .raw = node });
}

const testing = std.testing;
const alloc_bridge = @import("alloc_bridge.zig");
const typescript = &@import("lang/typescript/profile.zig").profile;
const javascript = &@import("lang/javascript/profile.zig").profile;

fn expectCompileError(text: []const u8, err: CompileError, at: []const u8) !void {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    var diag: Diagnostic = .{};
    errdefer std.debug.print("query {s}: {s} at \"{s}\"\n", .{ text, diag.what, diag.at() });
    try testing.expectError(err, compile(testing.allocator, typescript.grammar(), text, &diag));
    try testing.expectEqualStrings(at, diag.at());
}

const Found = struct {
    texts: [][]const u8,

    fn deinit(self: Found) void {
        testing.allocator.free(self.texts);
    }
};

fn findIn(language: *const ts.Language, source: []const u8, span: Span, text: []const u8, limits: Limits) !Found {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try ts.Parser.init(language);
    defer parser.deinit();
    const tree = try parser.parse(source);
    defer tree.deinit();
    var query = try compile(testing.allocator, language, text, null);
    defer query.deinit();
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(testing.allocator);
    try run(testing.allocator, &query, tree, span, limits, &spans);
    const texts = try testing.allocator.alloc([]const u8, spans.items.len);
    for (spans.items, texts) |s, *t| t.* = source[s.start..s.end];
    return .{ .texts = texts };
}

fn whole(source: []const u8) Span {
    return .{ .start = 0, .end = @intCast(source.len) };
}

fn expectFound(source: []const u8, text: []const u8, expected: []const []const u8) !void {
    const found = try findIn(typescript.grammar(), source, whole(source), text, .{});
    defer found.deinit();
    errdefer for (found.texts) |t| std.debug.print("found: {s}\n", .{t});
    try testing.expectEqual(expected.len, found.texts.len);
    for (expected, found.texts) |want, got| try testing.expectEqualStrings(want, got);
}

test "q: tree-sitter compile errors keep their kind and point at the offending token" {
    try expectCompileError("(call_expression", error.QuerySyntax, "");
    try expectCompileError("(no_such_node) @violation", error.QueryNodeType, "no_such_node");
    try expectCompileError("(call_expression no_such_field: (identifier)) @violation", error.QueryField, "no_such_field:");
    try expectCompileError("((identifier) @violation (#eq? @other \"x\"))", error.QueryCapture, "other");
}

test "q: a diagnostic cut to its buffer ends on a whole character" {
    var diag: Diagnostic = .{};
    const text = "a" ** 63 ++ "ş" ++ "tail";
    diag.set("x", text);
    try testing.expectEqualStrings("a" ** 63, diag.at());
    diag.set("x", "a" ** 62 ++ "ş");
    try testing.expectEqualStrings("a" ** 62 ++ "ş", diag.at());
    try expectCompileError("((identifier) @violation (#match? @violation \"[ş-a]\"))", error.RegexSyntax, "ş-a");
}

test "q: every pattern must capture @violation" {
    try expectCompileError("(identifier) @id", error.QueryMissingViolation, "(identifier) @id");
    try expectCompileError("(identifier) @violation (string) @s", error.QueryMissingViolation, "(string) @s");
    try expectCompileError("(identifier) @Violation", error.QueryMissingViolation, "(identifier) @Violation");
}

test "q: an unknown predicate or any directive is refused by name" {
    try expectCompileError("((identifier) @violation (#foo? @violation \"x\"))", error.QueryUnknownPredicate, "foo?");
    try expectCompileError("((identifier) @violation (#is? local))", error.QueryUnknownPredicate, "is?");
    try expectCompileError("((identifier) @violation (#any-eq? @violation \"x\"))", error.QueryUnknownPredicate, "any-eq?");
    try expectCompileError("((identifier) @violation (#set! priority 1))", error.QueryDirective, "set!");
    try expectCompileError("((identifier) @violation (#select-adjacent! @violation))", error.QueryDirective, "select-adjacent!");
}

test "q: a predicate with the wrong arguments is refused by name" {
    try expectCompileError("((identifier) @violation (#eq? @violation))", error.QueryPredicateArguments, "eq?");
    try expectCompileError("((identifier) @violation (#eq? \"x\" @violation))", error.QueryPredicateArguments, "eq?");
    try expectCompileError("((identifier) @violation (#not-eq? @violation \"a\" \"b\"))", error.QueryPredicateArguments, "not-eq?");
    try expectCompileError("((identifier) @violation (#any-of? @violation))", error.QueryPredicateArguments, "any-of?");
    try expectCompileError("((identifier) @violation (#any-of? @violation \"a\" @violation))", error.QueryPredicateArguments, "any-of?");
    try expectCompileError("((identifier) @violation (#match? @violation @violation))", error.QueryPredicateArguments, "match?");
    try expectCompileError("((identifier) @violation (#not-match? @violation))", error.QueryPredicateArguments, "not-match?");
}

test "q: a regex outside the supported subset is refused by its construct" {
    try expectCompileError("((identifier) @violation (#match? @violation \"^a{2}$\"))", error.RegexUnsupported, "{");
    try expectCompileError("((identifier) @violation (#not-match? @violation \"(?=x)\"))", error.RegexUnsupported, "(?=x");
    try expectCompileError("((identifier) @violation (#match? @violation \"(a\"))", error.RegexSyntax, "(");
}

test "q: the query text is capped at 4 KB" {
    const head = "(identifier) @violation";
    try expectCompileError(head ++ " " ** (max_query_bytes + 1 - head.len), error.QueryTooLong, "");
    try expectFound("x;\n", head ++ " " ** (max_query_bytes - head.len), &.{"x"});
    try testing.expectEqual(@as(usize, 4 * 1024), prefix.len + max_query_bytes);
}

test "q: #eq? and #not-eq? compare a capture with a string" {
    const source = "priceFloat(a);\nother(b);\n";
    try expectFound(source, "((identifier) @violation (#eq? @violation \"priceFloat\"))", &.{"priceFloat"});
    try expectFound(source, "((identifier) @violation (#eq? @violation \"pricefloat\"))", &.{});
    try expectFound(source, "((identifier) @violation (#not-eq? @violation \"priceFloat\"))", &.{ "a", "other", "b" });
}

test "q: #eq? and #not-eq? compare two captures" {
    const source = "a = a;\nb = c;\n";
    try expectFound(source, "((assignment_expression left: (identifier) @violation right: (identifier) @r) (#eq? @violation @r))", &.{"a"});
    try expectFound(source, "((assignment_expression left: (identifier) @violation right: (identifier) @r) (#not-eq? @violation @r))", &.{"b"});
}

test "q: #any-of? accepts a capture equal to one of the strings" {
    const source = "fetch(u);\naxios(u);\nget(u);\n";
    try expectFound(source, "((call_expression function: (identifier) @violation) (#any-of? @violation \"fetch\" \"axios\"))", &.{ "fetch", "axios" });
    try expectFound(source, "((call_expression function: (identifier) @violation) (#any-of? @violation \"post\"))", &.{});
}

test "q: #match? and #not-match? run the regex over the capture's text" {
    const source = "scrapeHepsiburadaApi();\nscrapeTrendyol();\nparse();\n";
    try expectFound(source, "((call_expression function: (identifier) @violation) (#match? @violation \"^scrape.*Api$\"))", &.{"scrapeHepsiburadaApi"});
    try expectFound(source, "((call_expression function: (identifier) @violation) (#match? @violation \"^scrape\"))", &.{ "scrapeHepsiburadaApi", "scrapeTrendyol" });
    try expectFound(source, "((call_expression function: (identifier) @violation) (#not-match? @violation \"^scrape\"))", &.{"parse"});
    try expectFound(source, "((call_expression function: (identifier) @violation) (#match? @violation \"^Api\"))", &.{});
}

test "q: predicates on one pattern all have to hold" {
    const source = "fetchJson();\nfetchText();\npostJson();\n";
    try expectFound(source, "((call_expression function: (identifier) @violation) (#match? @violation \"^fetch\") (#not-eq? @violation \"fetchText\"))", &.{"fetchJson"});
}

test "q: a match that captured no node is skipped instead of crashing" {
    try expectFound("f();\n", "(arguments (identifier)? @violation)", &.{});
    try expectFound("f(a);\n", "(arguments (identifier)? @violation)", &.{"a"});
}

test "q: a predicate on a capture that caught no node holds, as in tree-sitter's own bindings" {
    const source = "f();\ng(x);\nh(y);\n";
    const head = "((call_expression function: (identifier) @violation arguments: (arguments . (identifier)? @a)) ";
    try expectFound(source, head ++ "(#eq? @a \"x\"))", &.{ "f", "g" });
    try expectFound(source, head ++ "(#not-eq? @a \"x\"))", &.{ "f", "h" });
    try expectFound(source, head ++ "(#any-of? @a \"y\"))", &.{ "f", "h" });
    try expectFound(source, head ++ "(#match? @a \"^x$\"))", &.{ "f", "g" });
    try expectFound(source, head ++ "(#eq? @a @violation))", &.{"f"});
}

test "q: odd query text is refused or run, never a crash" {
    const odd = [_][]const u8{
        "((identifier) @violation (#))",
        "((identifier) @violation (# @violation))",
        "((identifier) @violation (#eq?))",
        "((identifier) @violation (#\"eq?\" @violation \"x\"))",
        "((identifier) @violation (#match? @violation \"\"))",
        "((identifier) @violation (#any-of? @violation \"\"))",
        "(_) @violation",
        "(ERROR) @violation",
        "(MISSING) @violation",
        "[(identifier) (identifier)] @violation @violation",
        "((_) @violation . (_) @violation)",
        "(program . (_)? @violation .)",
        "((identifier)+ @violation (#eq? @violation \"a\"))",
        "\"return\" @violation",
        "(_ \"(\" @violation)",
        "",
        "@violation",
        "(",
        ")",
        "; comment only\n",
    };
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try ts.Parser.init(typescript.grammar());
    defer parser.deinit();
    const source = "function f(a: number) { return a(1, (2)); }\nconst x = [;\n";
    const tree = try parser.parse(source);
    defer tree.deinit();
    for (odd) |text| {
        errdefer std.debug.print("query: {s}\n", .{text});
        var query = compile(testing.allocator, typescript.grammar(), text, null) catch continue;
        defer query.deinit();
        var spans: std.ArrayList(Span) = .empty;
        defer spans.deinit(testing.allocator);
        run(testing.allocator, &query, tree, whole(source), .{}, &spans) catch {};
    }
}

test "q: a node reported by two patterns is reported once" {
    try expectFound("x;\n", "(identifier) @violation ((identifier) @violation (#eq? @violation \"x\"))", &.{"x"});
}

test "q: only nodes wholly inside the span are reported" {
    const source = "function outer() {\n  run(1);\n  function inner() { run(2); }\n}\nrun(3);\n";
    const text = "(call_expression) @violation";
    const body_start: u32 = @intCast(std.mem.indexOf(u8, source, "{").?);
    const body_end: u32 = @intCast(std.mem.indexOf(u8, source, "}\n}").? + 3);
    const inside = try findIn(typescript.grammar(), source, .{ .start = body_start, .end = body_end }, text, .{});
    defer inside.deinit();
    try testing.expectEqual(@as(usize, 2), inside.texts.len);
    try testing.expectEqualStrings("run(1)", inside.texts[0]);
    try testing.expectEqualStrings("run(2)", inside.texts[1]);

    const cut_at: u32 = @intCast(std.mem.indexOf(u8, source, "(2)").?);
    const cut = try findIn(typescript.grammar(), source, .{ .start = body_start, .end = cut_at }, text, .{});
    defer cut.deinit();
    try testing.expectEqual(@as(usize, 1), cut.texts.len);
    try testing.expectEqualStrings("run(1)", cut.texts[0]);
}

test "q: a query that outruns its operation budget fails instead of passing" {
    const source = "a;\n" ** 2000;
    try testing.expectError(error.QueryBudgetExceeded, findIn(typescript.grammar(), source, whole(source), "(identifier) @violation", .{ .operations = 1000 }));
    const found = try findIn(typescript.grammar(), source, whole(source), "(identifier) @violation", .{});
    defer found.deinit();
    try testing.expectEqual(@as(usize, 2000), found.texts.len);
}

test "q: regex work counts against the same budget" {
    const source = "const s = \"" ++ "a" ** 4000 ++ "\";\n";
    const text = "((string_fragment) @violation (#match? @violation \"(a|aa)+b\"))";
    try testing.expectError(error.QueryBudgetExceeded, findIn(typescript.grammar(), source, whole(source), text, .{ .operations = 5000 }));
    const found = try findIn(typescript.grammar(), source, whole(source), text, .{});
    defer found.deinit();
    try testing.expectEqual(@as(usize, 0), found.texts.len);
}

test "q: comparing captures with each other counts against the budget" {
    const source = "a;\n" ** 100;
    const text = "((program (_) @violation" ++ " . (_) @violation" ** 7 ++ ") (#eq? @violation @violation))";
    const found = try findIn(typescript.grammar(), source, whole(source), text, .{});
    defer found.deinit();
    try testing.expectEqual(@as(usize, 100), found.texts.len);
    try testing.expectError(error.QueryBudgetExceeded, findIn(typescript.grammar(), source, whole(source), text, .{ .operations = 20_000 }));
}

test "q: more than eight captures in one pattern are refused, predicate arguments do not count" {
    const eight = "(program (_) @violation" ++ " . (_) @violation" ** 7 ++ ")";
    const nine = "(program (_) @violation" ++ " . (_) @violation" ** 8 ++ ")";
    try expectCompileError(nine, error.QueryTooManyCaptures, nine[0..64]);
    try expectCompileError("(identifier) @violation " ++ nine, error.QueryTooManyCaptures, nine[0..64]);
    try expectFound("a;\n" ** 8, eight, &.{ "a;", "a;", "a;", "a;", "a;", "a;", "a;", "a;" });
    try expectFound("a;\n" ** 8, "(" ++ eight ++ " (#eq? @violation @violation) (#not-eq? @violation \"@x @y\"))", &.{ "a;", "a;", "a;", "a;", "a;", "a;", "a;", "a;" });
}

test "q: a capture repeated with + or * is refused, one with ? or an uncaptured repeat is not" {
    try expectCompileError("(program (_)+ @violation)", error.QueryQuantifiedCapture, "(program (_)+ @violation)");
    try expectCompileError("(arguments (identifier)* @violation)", error.QueryQuantifiedCapture, "(arguments (identifier)* @violation)");
    try expectCompileError("((arguments (identifier)+ @args) @violation)", error.QueryQuantifiedCapture, "((arguments (identifier)+ @args) @violation)");
    try expectCompileError("(identifier) @violation (arguments ((identifier) @a)+) @violation", error.QueryQuantifiedCapture, "(arguments ((identifier) @a)+) @violation");
    try expectCompileError("[(identifier) (string)]* @violation", error.QueryQuantifiedCapture, "[(identifier) (string)]* @violation");
    try expectFound("f(a, b);\n", "((arguments (identifier)+) @violation)", &.{"(a, b)"});
    try expectFound("f(a, b);\n", "(arguments . (identifier)? @violation)", &.{"a"});
    try expectFound("f(a, b);\n", "(arguments . (identifier) @violation . (identifier) @violation)", &.{ "a", "b" });
    try expectFound("f(a, b);\n", "((identifier) @violation (#not-match? @violation \"a+@*\") ; (_)+ @x\n)", &.{ "f", "b" });
    try expectFound("f(a, b);\n", "((identifier) @violation (#any-of? @violation \"*\" \"f\"))", &.{"f"});
}

test "q: a capture on a group or alternation with + or * at its own level is refused by name" {
    const refused = [_][]const u8{
        "(program ((expression_statement)+) @violation)",
        "(program [(expression_statement)+ (comment)] @violation)",
        "(program [(comment) (expression_statement)*] @violation)",
        "(program (((expression_statement)+)) @violation)",
        "(program ((expression_statement)* (comment)) @violation)",
        "(program ((comment) (expression_statement)+) @violation)",
        "(program ([(comment) ((expression_statement)+)]) @violation)",
        "(program ((expression_statement (identifier))+ ) @violation)",
    };
    for (refused) |text| {
        errdefer std.debug.print("query: {s}\n", .{text});
        try expectCompileError(text, error.QueryQuantifiedCapture, text);
    }
    try expectFound("f(a, b);\n", "((call_expression (arguments (identifier)+)) @violation)", &.{"f(a, b)"});
    try expectFound("f(a, b);\n", "([(call_expression (arguments (identifier)*)) (number)] @violation)", &.{"f(a, b)"});
    try expectFound("f(a, b);\n", "((identifier) @violation (#match? @violation \"[a-z]+\"))", &.{ "f", "a", "b" });
}

test "q: string comparisons count their bytes against the budget" {
    const source = "const s = \"" ++ "a" ** 4000 ++ "\";\n";
    const eq = "((string_fragment) @violation (#eq? @violation \"" ++ "a" ** 3000 ++ "\"))";
    const any_of = "((string_fragment) @violation (#any-of? @violation \"" ++ "a" ** 3000 ++ "\"))";
    const self = "((string_fragment) @violation (#eq? @violation @violation))";
    for ([_][]const u8{ eq, any_of, self }) |text| {
        errdefer std.debug.print("query: {s}\n", .{text[0..@min(text.len, 60)]});
        const found = try findIn(typescript.grammar(), source, whole(source), text, .{});
        found.deinit();
        const operations: u64 = if (text.ptr == self.ptr) 2500 else 1500;
        try testing.expectError(error.QueryBudgetExceeded, findIn(typescript.grammar(), source, whole(source), text, .{ .operations = operations }));
    }
}

test "q: dropping in-progress matches past the match limit fails instead of passing" {
    const source = "f(" ++ "a, " ** 200 ++ "b);\n";
    const text = "(arguments (identifier) @violation (identifier) @violation)";
    try testing.expectError(error.QueryMatchLimitExceeded, findIn(typescript.grammar(), source, whole(source), text, .{ .match_limit = 2 }));
    const found = try findIn(typescript.grammar(), source, whole(source), text, .{});
    defer found.deinit();
    try testing.expect(found.texts.len > 0);
}

test "q: a node type only one grammar has compiles only for that grammar" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    var query = try compile(testing.allocator, typescript.grammar(), "(type_annotation) @violation", null);
    query.deinit();
    try testing.expectError(error.QueryNodeType, compile(testing.allocator, javascript.grammar(), "(type_annotation) @violation", null));
    try testing.expect(dependsOnLanguage(error.QueryNodeType));
    try testing.expect(!dependsOnLanguage(error.QuerySyntax));
    try testing.expect(!dependsOnLanguage(error.QueryUnknownPredicate));
}
