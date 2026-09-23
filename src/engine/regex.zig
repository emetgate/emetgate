const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = error{ RegexUnsupported, RegexSyntax } || Allocator.Error;

pub const Diagnostic = struct {
    what: []const u8 = "",
    at: []const u8 = "",
};

pub const max_nesting = 64;

const max_code_point: u21 = 0x10FFFF;

const Range = struct { lo: u21, hi: u21 };

const Op = enum { ranges, split, jmp, begin, end, match };

const Inst = struct {
    op: Op,
    x: u32 = 0,
    y: u32 = 0,
};

pub const Regex = struct {
    insts: []const Inst,
    ranges: []const Range,

    pub fn compile(gpa: Allocator, pattern: []const u8, diag: ?*Diagnostic) Error!Regex {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        var parser: Parser = .{ .arena = arena_state.allocator(), .pattern = pattern, .diag = diag };
        const root = try parser.parseAlternation(0);
        if (parser.pos < pattern.len) return parser.syntax("unmatched )", parser.pos, 1);

        var emitter: Emitter = .{ .gpa = gpa };
        errdefer emitter.deinit();
        try emitter.emit(root);
        try emitter.push(.{ .op = .match });
        const insts = try emitter.insts.toOwnedSlice(gpa);
        errdefer gpa.free(insts);
        return .{ .insts = insts, .ranges = try emitter.ranges.toOwnedSlice(gpa) };
    }

    pub fn deinit(self: Regex, gpa: Allocator) void {
        gpa.free(self.insts);
        gpa.free(self.ranges);
    }

    pub fn isMatch(self: Regex, gpa: Allocator, text: []const u8, budget: *u64) (Allocator.Error || error{BudgetExceeded})!bool {
        const n = self.insts.len;
        const buffer = try gpa.alloc(u32, n * 6 + 2);
        defer gpa.free(buffer);
        var current = StateSet.init(buffer[0 .. 2 * n]);
        var next = StateSet.init(buffer[2 * n .. 4 * n]);
        const stack = buffer[4 * n ..];

        var pos: usize = 0;
        while (true) {
            if (try self.follow(&current, stack, 0, text, pos, budget)) return true;
            if (pos >= text.len) return false;
            const step = decode(text[pos..]);
            next.clear();
            for (current.dense[0..current.len]) |pc| {
                try spend(budget);
                const inst = self.insts[pc];
                if (inst.op == .ranges and inRanges(self.ranges[inst.x..][0..inst.y], step.code_point)) {
                    if (try self.follow(&next, stack, pc + 1, text, pos + step.len, budget)) return true;
                }
            }
            std.mem.swap(StateSet, &current, &next);
            pos += step.len;
        }
    }

    fn follow(self: Regex, set: *StateSet, stack: []u32, start: u32, text: []const u8, pos: usize, budget: *u64) error{BudgetExceeded}!bool {
        var top: usize = 0;
        stack[top] = start;
        top += 1;
        while (top > 0) {
            top -= 1;
            const pc = stack[top];
            if (set.contains(pc)) continue;
            try spend(budget);
            const inst = self.insts[pc];
            switch (inst.op) {
                .ranges => set.add(pc),
                .match => return true,
                .jmp => {
                    set.add(pc);
                    stack[top] = inst.x;
                    top += 1;
                },
                .split => {
                    set.add(pc);
                    stack[top] = inst.y;
                    stack[top + 1] = inst.x;
                    top += 2;
                },
                .begin, .end => {
                    set.add(pc);
                    const holds = if (inst.op == .begin) pos == 0 else pos == text.len;
                    if (holds) {
                        stack[top] = pc + 1;
                        top += 1;
                    }
                },
            }
        }
        return false;
    }
};

fn spend(budget: *u64) error{BudgetExceeded}!void {
    if (budget.* == 0) return error.BudgetExceeded;
    budget.* -= 1;
}

const StateSet = struct {
    dense: []u32,
    sparse: []u32,
    len: u32 = 0,

    fn init(buffer: []u32) StateSet {
        const half = buffer.len / 2;
        return .{ .dense = buffer[0..half], .sparse = buffer[half..] };
    }

    fn clear(self: *StateSet) void {
        self.len = 0;
    }

    fn contains(self: StateSet, pc: u32) bool {
        const i = self.sparse[pc];
        return i < self.len and self.dense[i] == pc;
    }

    fn add(self: *StateSet, pc: u32) void {
        self.sparse[pc] = self.len;
        self.dense[self.len] = pc;
        self.len += 1;
    }
};

const Decoded = struct { code_point: u21, len: usize };

fn decode(bytes: []const u8) Decoded {
    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return .{ .code_point = 0xFFFD, .len = 1 };
    if (len > bytes.len) return .{ .code_point = 0xFFFD, .len = 1 };
    const code_point = std.unicode.utf8Decode(bytes[0..len]) catch return .{ .code_point = 0xFFFD, .len = 1 };
    return .{ .code_point = code_point, .len = len };
}

fn inRanges(ranges: []const Range, code_point: u21) bool {
    for (ranges) |r| {
        if (code_point >= r.lo and code_point <= r.hi) return true;
    }
    return false;
}

const Node = union(enum) {
    empty,
    ranges: []const Range,
    begin,
    end,
    concat: []const *const Node,
    alternate: []const *const Node,
    star: *const Node,
    plus: *const Node,
    quest: *const Node,
};

const digit = [_]Range{.{ .lo = '0', .hi = '9' }};
const word = [_]Range{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = '_', .hi = '_' }, .{ .lo = 'a', .hi = 'z' } };
const space = [_]Range{ .{ .lo = '\t', .hi = '\n' }, .{ .lo = 0x0C, .hi = '\r' }, .{ .lo = ' ', .hi = ' ' } };
const not_newline = [_]Range{ .{ .lo = 0, .hi = '\n' - 1 }, .{ .lo = '\n' + 1, .hi = max_code_point } };

const Parser = struct {
    arena: Allocator,
    pattern: []const u8,
    diag: ?*Diagnostic,
    pos: usize = 0,

    fn fail(self: *Parser, err: Error, what: []const u8, at: usize, len: usize) Error {
        if (self.diag) |d| {
            const start = @min(at, self.pattern.len);
            var end = @min(self.pattern.len, at + len);
            while (end < self.pattern.len and isContinuation(self.pattern[end])) end += 1;
            d.* = .{ .what = what, .at = self.pattern[start..end] };
        }
        return err;
    }

    fn invalidUtf8(self: *Parser) Error {
        if (self.diag) |d| d.* = .{ .what = "invalid UTF-8", .at = "" };
        return error.RegexSyntax;
    }

    fn isContinuation(byte: u8) bool {
        return byte & 0xC0 == 0x80;
    }

    fn unsupported(self: *Parser, what: []const u8, at: usize, len: usize) Error {
        return self.fail(error.RegexUnsupported, what, at, len);
    }

    fn syntax(self: *Parser, what: []const u8, at: usize, len: usize) Error {
        return self.fail(error.RegexSyntax, what, at, len);
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.pattern.len) self.pattern[self.pos] else null;
    }

    fn node(self: *Parser, value: Node) Error!*const Node {
        const n = try self.arena.create(Node);
        n.* = value;
        return n;
    }

    fn parseAlternation(self: *Parser, depth: usize) Error!*const Node {
        var branches: std.ArrayList(*const Node) = .empty;
        try branches.append(self.arena, try self.parseConcat(depth));
        while (self.peek() == '|') {
            self.pos += 1;
            try branches.append(self.arena, try self.parseConcat(depth));
        }
        if (branches.items.len == 1) return branches.items[0];
        return self.node(.{ .alternate = branches.items });
    }

    fn parseConcat(self: *Parser, depth: usize) Error!*const Node {
        var items: std.ArrayList(*const Node) = .empty;
        while (self.peek()) |ch| {
            if (ch == '|' or ch == ')') break;
            try items.append(self.arena, try self.parseRepeat(depth));
        }
        return switch (items.items.len) {
            0 => self.node(.empty),
            1 => items.items[0],
            else => self.node(.{ .concat = items.items }),
        };
    }

    fn parseRepeat(self: *Parser, depth: usize) Error!*const Node {
        var atom = try self.parseAtom(depth);
        var repeated = false;
        while (self.peek()) |ch| {
            const at = self.pos;
            switch (ch) {
                '*', '+', '?' => {},
                '{' => return self.unsupported("counted repetition {n,m}; escape a literal brace as \\{", at, 1),
                else => break,
            }
            self.pos += 1;
            if (self.peek()) |after| {
                if (after == '?') return self.unsupported("lazy quantifier", at, 2);
                if (after == '+') return self.unsupported("possessive quantifier", at, 2);
            }
            if (repeated) return self.syntax("quantifier after a quantifier", at, 1);
            repeated = true;
            atom = try self.node(switch (ch) {
                '*' => .{ .star = atom },
                '+' => .{ .plus = atom },
                else => .{ .quest = atom },
            });
        }
        return atom;
    }

    fn parseAtom(self: *Parser, depth: usize) Error!*const Node {
        const at = self.pos;
        const ch = self.peek().?;
        switch (ch) {
            '*', '+', '?' => return self.syntax("quantifier with nothing to repeat", at, 1),
            '{' => return self.unsupported("counted repetition {n,m}; escape a literal brace as \\{", at, 1),
            '(' => {
                if (depth + 1 > max_nesting) return self.syntax("groups nested too deep", at, 1);
                self.pos += 1;
                if (self.peek() == '?') return self.unsupported(groupKind(self.pattern[self.pos..]), at, @min(4, self.pattern.len - at));
                const inner = try self.parseAlternation(depth + 1);
                if (self.peek() != ')') return self.syntax("missing )", at, 1);
                self.pos += 1;
                return inner;
            },
            '[' => return self.parseClass(),
            '.' => {
                self.pos += 1;
                return self.node(.{ .ranges = &not_newline });
            },
            '^' => {
                self.pos += 1;
                return self.node(.begin);
            },
            '$' => {
                self.pos += 1;
                return self.node(.end);
            },
            '\\' => {
                const ranges = try self.parseEscape(false);
                return self.node(.{ .ranges = ranges });
            },
            else => return self.node(.{ .ranges = try self.single(try self.literal()) }),
        }
    }

    fn groupKind(rest: []const u8) []const u8 {
        if (std.mem.startsWith(u8, rest, "?=") or std.mem.startsWith(u8, rest, "?!")) return "lookahead";
        if (std.mem.startsWith(u8, rest, "?<=") or std.mem.startsWith(u8, rest, "?<!")) return "lookbehind";
        if (std.mem.startsWith(u8, rest, "?P=")) return "named backreference";
        if (std.mem.startsWith(u8, rest, "?#")) return "comment";
        if (std.mem.startsWith(u8, rest, "?P<") or std.mem.startsWith(u8, rest, "?<")) return "named group";
        if (std.mem.startsWith(u8, rest, "?:")) return "non-capturing group; ( ) already does not capture";
        if (std.mem.startsWith(u8, rest, "?>")) return "atomic group";
        return "inline flags";
    }

    fn literal(self: *Parser) Error!u21 {
        const rest = self.pattern[self.pos..];
        const len = std.unicode.utf8ByteSequenceLength(rest[0]) catch return self.invalidUtf8();
        if (len > rest.len) return self.invalidUtf8();
        const code_point = std.unicode.utf8Decode(rest[0..len]) catch return self.invalidUtf8();
        self.pos += len;
        return code_point;
    }

    fn single(self: *Parser, code_point: u21) Error![]const Range {
        const one = try self.arena.alloc(Range, 1);
        one[0] = .{ .lo = code_point, .hi = code_point };
        return one;
    }

    fn parseEscape(self: *Parser, in_class: bool) Error![]const Range {
        const at = self.pos;
        self.pos += 1;
        const ch = self.peek() orelse return self.syntax("trailing backslash", at, 1);
        self.pos += 1;
        return switch (ch) {
            'd' => &digit,
            'w' => &word,
            's' => &space,
            'D' => self.complement(&digit),
            'W' => self.complement(&word),
            'S' => self.complement(&space),
            'n' => self.single('\n'),
            't' => self.single('\t'),
            'r' => self.single('\r'),
            'f' => self.single(0x0C),
            'v' => self.single(0x0B),
            '1'...'9' => self.unsupported("backreference", at, 2),
            'b', 'B' => if (in_class) self.unsupported("escape inside a class", at, 2) else self.unsupported("word boundary", at, 2),
            '<', '>' => if (in_class) self.single(ch) else self.unsupported("word boundary", at, 2),
            '`', '\'' => if (in_class) self.single(ch) else self.unsupported("text anchor; use ^ or $", at, 2),
            'A', 'z', 'Z' => self.unsupported("text anchor; use ^ or $", at, 2),
            'p', 'P' => self.unsupported("unicode class", at, 2),
            'x', 'u', '0' => self.unsupported("numeric escape", at, 2),
            'Q', 'E' => self.unsupported("quoted literal", at, 2),
            'K', 'G' => self.unsupported("match reset", at, 2),
            else => if (std.ascii.isAlphanumeric(ch))
                self.unsupported("unknown escape", at, 2)
            else if (ch < 0x80)
                self.single(ch)
            else if (!std.unicode.utf8ValidateSlice(self.pattern[at + 1 .. @min(self.pattern.len, at + 1 + (std.unicode.utf8ByteSequenceLength(ch) catch 1))]))
                self.invalidUtf8()
            else
                self.syntax("backslash before a non-ASCII character", at, 2),
        };
    }

    fn complement(self: *Parser, ranges: []const Range) Error![]const Range {
        const sorted = try self.normalize(ranges);
        var out: std.ArrayList(Range) = .empty;
        var next: u32 = 0;
        for (sorted) |r| {
            if (r.lo > next) try out.append(self.arena, .{ .lo = @intCast(next), .hi = r.lo - 1 });
            next = @as(u32, r.hi) + 1;
        }
        if (next <= max_code_point) try out.append(self.arena, .{ .lo = @intCast(next), .hi = max_code_point });
        return out.items;
    }

    fn normalize(self: *Parser, ranges: []const Range) Error![]const Range {
        const copy = try self.arena.dupe(Range, ranges);
        std.mem.sort(Range, copy, {}, struct {
            fn lessThan(_: void, a: Range, b: Range) bool {
                return a.lo < b.lo;
            }
        }.lessThan);
        var len: usize = 0;
        for (copy) |r| {
            if (len > 0 and @as(u32, r.lo) <= @as(u32, copy[len - 1].hi) + 1) {
                copy[len - 1].hi = @max(copy[len - 1].hi, r.hi);
            } else {
                copy[len] = r;
                len += 1;
            }
        }
        return copy[0..len];
    }

    fn parseClass(self: *Parser) Error!*const Node {
        const open = self.pos;
        self.pos += 1;
        var negated = false;
        if (self.peek() == '^') {
            negated = true;
            self.pos += 1;
        }
        var members: std.ArrayList(Range) = .empty;
        var first = true;
        while (true) {
            const ch = self.peek() orelse return self.syntax("missing ]", open, 1);
            if (ch == ']' and !first) break;
            first = false;
            if (ch == '[' and self.pos + 1 < self.pattern.len and (self.pattern[self.pos + 1] == ':' or self.pattern[self.pos + 1] == '=' or self.pattern[self.pos + 1] == '.')) {
                return self.unsupported("POSIX class", self.pos, 2);
            }
            const lo_start = self.pos;
            const lo = try self.classAtom();
            const is_range = self.peek() == '-' and self.pos + 1 < self.pattern.len and self.pattern[self.pos + 1] != ']';
            if (!is_range) {
                try members.appendSlice(self.arena, lo);
                continue;
            }
            if (lo.len != 1 or lo[0].lo != lo[0].hi) return self.syntax("class shorthand as a range start", lo_start, self.pos + 1 - lo_start);
            const dash = self.pos;
            self.pos += 1;
            const hi = try self.classAtom();
            if (hi.len != 1 or hi[0].lo != hi[0].hi) return self.syntax("class shorthand as a range end", dash, self.pos - dash);
            if (hi[0].lo < lo[0].lo) return self.syntax("range out of order", lo_start, self.pos - lo_start);
            try members.append(self.arena, .{ .lo = lo[0].lo, .hi = hi[0].lo });
        }
        self.pos += 1;
        const ranges = if (negated) try self.complement(members.items) else try self.normalize(members.items);
        return self.node(.{ .ranges = ranges });
    }

    fn classAtom(self: *Parser) Error![]const Range {
        if (self.peek() == '\\') return self.parseEscape(true);
        return self.single(try self.literal());
    }
};

const Emitter = struct {
    gpa: Allocator,
    insts: std.ArrayList(Inst) = .empty,
    ranges: std.ArrayList(Range) = .empty,

    fn deinit(self: *Emitter) void {
        self.insts.deinit(self.gpa);
        self.ranges.deinit(self.gpa);
    }

    fn here(self: *Emitter) u32 {
        return @intCast(self.insts.items.len);
    }

    fn push(self: *Emitter, inst: Inst) Allocator.Error!void {
        try self.insts.append(self.gpa, inst);
    }

    fn emit(self: *Emitter, n: *const Node) Allocator.Error!void {
        switch (n.*) {
            .empty => {},
            .ranges => |ranges| {
                const start: u32 = @intCast(self.ranges.items.len);
                try self.ranges.appendSlice(self.gpa, ranges);
                try self.push(.{ .op = .ranges, .x = start, .y = @intCast(ranges.len) });
            },
            .begin => try self.push(.{ .op = .begin }),
            .end => try self.push(.{ .op = .end }),
            .concat => |items| for (items) |item| try self.emit(item),
            .alternate => |branches| {
                var jumps: std.ArrayList(u32) = .empty;
                defer jumps.deinit(self.gpa);
                for (branches, 0..) |branch, i| {
                    if (i + 1 == branches.len) {
                        try self.emit(branch);
                        break;
                    }
                    const split = self.here();
                    try self.push(.{ .op = .split, .x = split + 1 });
                    try self.emit(branch);
                    try jumps.append(self.gpa, self.here());
                    try self.push(.{ .op = .jmp });
                    self.insts.items[split].y = self.here();
                }
                for (jumps.items) |at| self.insts.items[at].x = self.here();
            },
            .star => |inner| {
                const split = self.here();
                try self.push(.{ .op = .split, .x = split + 1 });
                try self.emit(inner);
                try self.push(.{ .op = .jmp, .x = split });
                self.insts.items[split].y = self.here();
            },
            .plus => |inner| {
                const start = self.here();
                try self.emit(inner);
                try self.push(.{ .op = .split, .x = start, .y = self.here() + 1 });
            },
            .quest => |inner| {
                const split = self.here();
                try self.push(.{ .op = .split, .x = split + 1 });
                try self.emit(inner);
                self.insts.items[split].y = self.here();
            },
        }
    }
};

const testing = std.testing;

fn matches(pattern: []const u8, text: []const u8) !bool {
    const re = try Regex.compile(testing.allocator, pattern, null);
    defer re.deinit(testing.allocator);
    var budget: u64 = std.math.maxInt(u64);
    return re.isMatch(testing.allocator, text, &budget);
}

fn expectMatch(pattern: []const u8, text: []const u8) !void {
    errdefer std.debug.print("expected /{s}/ to match \"{s}\"\n", .{ pattern, text });
    try testing.expect(try matches(pattern, text));
}

fn expectNoMatch(pattern: []const u8, text: []const u8) !void {
    errdefer std.debug.print("expected /{s}/ not to match \"{s}\"\n", .{ pattern, text });
    try testing.expect(!try matches(pattern, text));
}

fn expectRefused(pattern: []const u8, err: Error, what: []const u8) !void {
    var diag: Diagnostic = .{};
    errdefer std.debug.print("pattern /{s}/ gave \"{s}\" at \"{s}\"\n", .{ pattern, diag.what, diag.at });
    try testing.expectError(err, Regex.compile(testing.allocator, pattern, &diag));
    try testing.expect(std.mem.startsWith(u8, diag.what, what));
}

test "regex literals match anywhere unless anchored" {
    try expectMatch("price", "priceFloat");
    try expectMatch("Float", "priceFloat");
    try expectNoMatch("pricefloat", "priceFloat");
    try expectMatch("", "");
    try expectMatch("", "anything");
    try expectMatch("ğü", "düğün ğü");
    try expectNoMatch("ğü", "gu");
}

test "regex dot matches one code point but not a newline" {
    try expectMatch("a.c", "abc");
    try expectMatch("a.c", "aşc");
    try expectNoMatch("a.c", "a\nc");
    try expectNoMatch("a.c", "ac");
}

test "regex classes, ranges and negated classes" {
    try expectMatch("[abc]", "xxbxx");
    try expectNoMatch("[abc]", "xyz");
    try expectMatch("^[a-z]+$", "scrape");
    try expectNoMatch("^[a-z]+$", "scrapeHB");
    try expectMatch("^[^0-9]+$", "abc");
    try expectNoMatch("^[^0-9]+$", "ab1");
    try expectMatch("^[^a]$", "ş");
    try expectMatch("[]a]", "]");
    try expectMatch("[a-]", "-");
    try expectMatch("[\\]\\\\]", "\\");
    try expectMatch("[\\d_]", "_");
    try expectMatch("^[\\D]$", "x");
    try expectNoMatch("^[\\D]$", "7");
}

test "regex shorthand classes and their inverses" {
    try expectMatch("^\\d+$", "2026");
    try expectNoMatch("^\\d+$", "20x6");
    try expectMatch("^\\w+$", "price_Float2");
    try expectNoMatch("^\\w+$", "price-float");
    try expectMatch("^a\\sb$", "a\tb");
    try expectMatch("^\\D\\W\\S$", "a-b");
    try expectNoMatch("^\\D$", "5");
    try expectNoMatch("^\\W$", "_");
    try expectNoMatch("^\\S$", " ");
    try expectMatch("a\\.b", "a.b");
    try expectNoMatch("a\\.b", "axb");
    try expectMatch("\\(\\)", "f()");
}

test "regex anchors hold only at the ends of the text" {
    try expectMatch("^scrape", "scrapeHepsiburadaApi");
    try expectNoMatch("^Api", "scrapeHepsiburadaApi");
    try expectMatch("Api$", "scrapeHepsiburadaApi");
    try expectNoMatch("scrape$", "scrapeHepsiburadaApi");
    try expectNoMatch("^b", "a\nb");
    try expectMatch("^$", "");
}

test "regex star, plus and question mark" {
    try expectMatch("^ab*c$", "ac");
    try expectMatch("^ab*c$", "abbbc");
    try expectNoMatch("^ab+c$", "ac");
    try expectMatch("^ab+c$", "abc");
    try expectMatch("^ab?c$", "ac");
    try expectMatch("^ab?c$", "abc");
    try expectNoMatch("^ab?c$", "abbc");
}

test "regex alternation and grouping" {
    try expectMatch("^(get|post)Json$", "postJson");
    try expectNoMatch("^(get|post)Json$", "putJson");
    try expectMatch("^a(|b)c$", "ac");
    try expectMatch("^(ab)+$", "ababab");
    try expectNoMatch("^(ab)+$", "aba");
    try expectMatch("^(a*)*$", "aaaa");
    try expectMatch("^()$", "");
    try expectMatch("x|", "y");
}

test "regex refuses every construct outside the subset by name" {
    try expectRefused("(a)\\1", error.RegexUnsupported, "backreference");
    try expectRefused("a(?=b)", error.RegexUnsupported, "lookahead");
    try expectRefused("a(?!b)", error.RegexUnsupported, "lookahead");
    try expectRefused("(?<=a)b", error.RegexUnsupported, "lookbehind");
    try expectRefused("(?<!a)b", error.RegexUnsupported, "lookbehind");
    try expectRefused("(?P<n>a)", error.RegexUnsupported, "named group");
    try expectRefused("(?<n>a)", error.RegexUnsupported, "named group");
    try expectRefused("(?:a)", error.RegexUnsupported, "non-capturing group");
    try expectRefused("(?i)a", error.RegexUnsupported, "inline flags");
    try expectRefused("(?>a)", error.RegexUnsupported, "atomic group");
    try expectRefused("a*?", error.RegexUnsupported, "lazy quantifier");
    try expectRefused("a+?", error.RegexUnsupported, "lazy quantifier");
    try expectRefused("a++", error.RegexUnsupported, "possessive quantifier");
    try expectRefused("a?+", error.RegexUnsupported, "possessive quantifier");
    try expectRefused("a{2}", error.RegexUnsupported, "counted repetition");
    try expectRefused("{", error.RegexUnsupported, "counted repetition");
    try expectRefused("\\bword", error.RegexUnsupported, "word boundary");
    try expectRefused("\\Bword", error.RegexUnsupported, "word boundary");
    try expectRefused("\\Aword", error.RegexUnsupported, "text anchor");
    try expectRefused("word\\z", error.RegexUnsupported, "text anchor");
    try expectRefused("\\p{L}", error.RegexUnsupported, "unicode class");
    try expectRefused("\\x41", error.RegexUnsupported, "numeric escape");
    try expectRefused("\\Qa.b\\E", error.RegexUnsupported, "quoted literal");
    try expectRefused("[[:alpha:]]", error.RegexUnsupported, "POSIX class");
    try expectRefused("\\q", error.RegexUnsupported, "unknown escape");
    try expectRefused("[\\b]", error.RegexUnsupported, "escape inside a class");
}

test "regex refuses malformed patterns as syntax errors" {
    try expectRefused("(a", error.RegexSyntax, "missing )");
    try expectRefused("a)", error.RegexSyntax, "unmatched )");
    try expectRefused("[a", error.RegexSyntax, "missing ]");
    try expectRefused("[z-a]", error.RegexSyntax, "range out of order");
    try expectRefused("[a-\\d]", error.RegexSyntax, "class shorthand as a range end");
    try expectRefused("*a", error.RegexSyntax, "quantifier with nothing to repeat");
    try expectRefused("a|*", error.RegexSyntax, "quantifier with nothing to repeat");
    try expectRefused("a**", error.RegexSyntax, "quantifier after a quantifier");
    try expectRefused("a\\", error.RegexSyntax, "trailing backslash");
    try expectRefused("(" ** (max_nesting + 1) ++ ")" ** (max_nesting + 1), error.RegexSyntax, "groups nested too deep");
    try expectMatch("(" ** max_nesting ++ "a" ++ ")" ** max_nesting, "a");
}

fn expectRefusedAt(pattern: []const u8, err: Error, what: []const u8, at: []const u8) !void {
    try expectRefused(pattern, err, what);
    var diag: Diagnostic = .{};
    _ = Regex.compile(testing.allocator, pattern, &diag) catch {};
    try testing.expectEqualStrings(at, diag.at);
}

test "regex refuses GNU and Vim word boundaries and buffer anchors instead of reading them as literals" {
    try expectRefusedAt("\\<word", error.RegexUnsupported, "word boundary", "\\<");
    try expectRefusedAt("word\\>", error.RegexUnsupported, "word boundary", "\\>");
    try expectRefusedAt("\\`word", error.RegexUnsupported, "text anchor", "\\`");
    try expectRefusedAt("word\\'", error.RegexUnsupported, "text anchor", "\\'");
    try expectMatch("^[\\<\\>]+$", "<>");
    try expectMatch("^[\\`\\']+$", "`'");
}

test "regex names a comment group and a named backreference by what they are" {
    try expectRefused("(?#note)a", error.RegexUnsupported, "comment");
    try expectRefused("a(?P=n)", error.RegexUnsupported, "named backreference");
    try expectRefused("(?i)a", error.RegexUnsupported, "inline flags");
}

test "regex refuses a class shorthand as the start of a range, as RE2 does" {
    try expectRefusedAt("[\\d-z]", error.RegexSyntax, "class shorthand as a range start", "\\d-");
    try expectRefusedAt("[\\w-a]", error.RegexSyntax, "class shorthand as a range start", "\\w-");
    try expectRefused("[\\s-\\d]", error.RegexSyntax, "class shorthand as a range start");
    try expectMatch("^[\\d-]+$", "1-2");
    try expectMatch("^[-\\d]+$", "-3");
    try expectMatch("^[a-z\\d]+$", "a1");
}

test "regex refuses invalid UTF-8 in the pattern" {
    try expectRefusedAt("a\xffb", error.RegexSyntax, "invalid UTF-8", "");
    try expectRefusedAt("a\xe2\x82", error.RegexSyntax, "invalid UTF-8", "");
    try expectRefusedAt("[\xc3]", error.RegexSyntax, "invalid UTF-8", "");
    try expectRefusedAt("\\\xff", error.RegexSyntax, "invalid UTF-8", "");
    try expectRefusedAt("\xed\xa0\x80", error.RegexSyntax, "invalid UTF-8", "");
    try expectMatch("ş", "şu");
}

test "regex errors point at whole characters, never into the middle of one" {
    try expectRefusedAt("[ş-a]", error.RegexSyntax, "range out of order", "ş-a");
    try expectRefusedAt("\\ş", error.RegexSyntax, "backslash before a non-ASCII character", "\\ş");
    try expectRefusedAt("(?<ş>a)", error.RegexUnsupported, "named group", "(?<ş");
    try expectRefusedAt("a{ş}", error.RegexUnsupported, "counted repetition", "{");
    for ([_][]const u8{ "[ş-a]", "\\ş", "(?<ş>a)", "(?Pş", "[ğ-a]", "a{ğ" }) |pattern| {
        var diag: Diagnostic = .{};
        if (Regex.compile(testing.allocator, pattern, &diag)) |re| {
            re.deinit(testing.allocator);
            return error.TestExpectedRefusal;
        } else |_| {}
        errdefer std.debug.print("pattern {s} at \"{s}\"\n", .{ pattern, diag.at });
        try testing.expect(std.unicode.utf8ValidateSlice(diag.at));
    }
}

test "regex reads invalid UTF-8 as replacement characters instead of failing" {
    try expectMatch("^a.b$", "a\xffb");
    try expectMatch("^..$", "\xe2\x82");
}

fn stepsFor(pattern: []const u8, text: []const u8) !u64 {
    const re = try Regex.compile(testing.allocator, pattern, null);
    defer re.deinit(testing.allocator);
    const start: u64 = std.math.maxInt(u64);
    var budget = start;
    try testing.expect(!try re.isMatch(testing.allocator, text, &budget));
    return start - budget;
}

test "a pathological pattern runs in linear time on a long input" {
    const short = try testing.allocator.alloc(u8, 50_000);
    defer testing.allocator.free(short);
    @memset(short, 'a');
    short[short.len - 1] = '!';
    const long = try testing.allocator.alloc(u8, 100_000);
    defer testing.allocator.free(long);
    @memset(long, 'a');
    long[long.len - 1] = '!';

    const started = std.Io.Timestamp.now(testing.io, .awake);
    const steps_short = try stepsFor("(a+)+$", short);
    const steps_long = try stepsFor("(a+)+$", long);
    const elapsed_ms = started.durationTo(std.Io.Timestamp.now(testing.io, .awake)).toMilliseconds();

    try testing.expect(steps_long <= steps_short * 2 + 64);
    try testing.expect(steps_long >= steps_short * 2 - 64);
    try testing.expect(elapsed_ms < 2000);

    _ = try stepsFor("(a*)*b", long);
    _ = try stepsFor("(a|aa)+$", long);
}

test "running out of budget is an error and never a miss" {
    const re = try Regex.compile(testing.allocator, "b", null);
    defer re.deinit(testing.allocator);
    var budget: u64 = 10;
    try testing.expectError(error.BudgetExceeded, re.isMatch(testing.allocator, "a" ** 100 ++ "b", &budget));
    budget = 1000;
    try testing.expect(try re.isMatch(testing.allocator, "a" ** 100 ++ "b", &budget));
}
