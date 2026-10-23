const std = @import("std");
const c = @import("c");

const Allocator = std.mem.Allocator;

pub const Error = error{ RegexUnsupported, RegexSyntax } || Allocator.Error;

pub const MatchError = error{ BudgetExceeded, OutOfMemory };

pub const Diagnostic = struct {
    buffer: [256]u8 = undefined,
    len: usize = 0,
    offset: usize = 0,
    at: []const u8 = "",

    pub fn what(self: *const Diagnostic) []const u8 {
        return self.buffer[0..self.len];
    }
};

pub const Span = struct { start: usize, end: usize };

const compile_options: u32 = c.PCRE2_UTF | c.PCRE2_UCP | c.PCRE2_MATCH_INVALID_UTF;
const heap_limit_kib: u32 = 64 * 1024;
const jit_stack_start: usize = 32 * 1024;
const jit_stack_max: usize = 10 * 1024 * 1024;
const context_bytes = 16;

const Memory = struct {
    gpa: Allocator,

    const alignment: std.mem.Alignment = .fromByteUnits(@max(@alignOf(std.c.max_align_t), 16));
    const header_len = alignment.toByteUnits();

    fn malloc(size: usize, data: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *Memory = @ptrCast(@alignCast(data.?));
        const len = std.math.add(usize, header_len, size) catch return null;
        const block = self.gpa.alignedAlloc(u8, alignment, len) catch return null;
        std.mem.writeInt(usize, block[0..@sizeOf(usize)], len, .native);
        return block[header_len..].ptr;
    }

    fn free(ptr: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        const payload = ptr orelse return;
        const self: *Memory = @ptrCast(@alignCast(data.?));
        const base: [*]align(header_len) u8 = @ptrFromInt(@intFromPtr(payload) - header_len);
        const len = std.mem.readInt(usize, base[0..@sizeOf(usize)], .native);
        self.gpa.free(base[0..len]);
    }

    fn create(gpa: Allocator) Allocator.Error!*Memory {
        const self = try gpa.create(Memory);
        self.* = .{ .gpa = gpa };
        return self;
    }

    fn general(self: *Memory) Allocator.Error!*c.pcre2_general_context_8 {
        return c.pcre2_general_context_create_8(&malloc, &free, self) orelse error.OutOfMemory;
    }
};

pub const Regex = struct {
    code: *c.pcre2_code_8,
    memory: *Memory,

    pub fn compile(gpa: Allocator, pattern: []const u8, diag: ?*Diagnostic) Error!Regex {
        const re = try build(gpa, pattern, compile_options, diag);
        _ = c.pcre2_jit_compile_8(re.code, c.PCRE2_JIT_COMPLETE);
        return re;
    }

    pub fn compileCounted(gpa: Allocator, pattern: []const u8, diag: ?*Diagnostic) Error!Regex {
        return build(gpa, pattern, compile_options | c.PCRE2_AUTO_CALLOUT, diag);
    }

    fn build(gpa: Allocator, pattern: []const u8, options: u32, diag: ?*Diagnostic) Error!Regex {
        const memory = try Memory.create(gpa);
        errdefer gpa.destroy(memory);
        const general = try memory.general();
        defer c.pcre2_general_context_free_8(general);
        const context = c.pcre2_compile_context_create_8(general) orelse return error.OutOfMemory;
        defer c.pcre2_compile_context_free_8(context);
        var code: c_int = 0;
        var offset: usize = 0;
        const compiled = c.pcre2_compile_8(pattern.ptr, pattern.len, options, &code, &offset, context) orelse
            return refuse(pattern, code, offset, diag);
        return .{ .code = compiled, .memory = memory };
    }

    pub fn deinit(self: Regex, gpa: Allocator) void {
        c.pcre2_code_free_8(self.code);
        gpa.destroy(self.memory);
    }

    pub fn isMatch(self: Regex, gpa: Allocator, text: []const u8, budget: *u64) MatchError!bool {
        if (budget.* < text.len + 1) return error.BudgetExceeded;
        budget.* -= text.len + 1;
        var matcher = try Matcher.initWith(gpa, @intCast(@min(budget.*, std.math.maxInt(u32))), false);
        defer matcher.deinit(gpa);
        _ = c.pcre2_set_callout_8(matcher.context, &spend, budget);
        return try matcher.find(self, text) != null;
    }
};

fn spend(_: [*c]c.pcre2_callout_block_8, data: ?*anyopaque) callconv(.c) c_int {
    const budget: *u64 = @ptrCast(@alignCast(data.?));
    if (budget.* == 0) return c.PCRE2_ERROR_CALLOUT;
    budget.* -= 1;
    return 0;
}

fn refuse(pattern: []const u8, code: c_int, offset: usize, diag: ?*Diagnostic) Error {
    if (code == c.PCRE2_ERROR_HEAP_FAILED) return error.OutOfMemory;
    if (diag) |d| {
        const written = c.pcre2_get_error_message_8(code, &d.buffer, d.buffer.len);
        d.len = if (written < 0) 0 else @intCast(written);
        d.offset = @min(offset, pattern.len);
        d.at = around(pattern, d.offset);
    }
    return switch (code) {
        c.PCRE2_ERROR_UNSUPPORTED_ESCAPE_SEQUENCE, c.PCRE2_ERROR_POSIX_NO_SUPPORT_COLLATING => error.RegexUnsupported,
        else => error.RegexSyntax,
    };
}

fn around(pattern: []const u8, offset: usize) []const u8 {
    var end = @min(pattern.len, offset + 1);
    while (end < pattern.len and pattern[end] & 0xC0 == 0x80) end += 1;
    var start = end -| context_bytes;
    while (start < end and pattern[start] & 0xC0 == 0x80) start += 1;
    const window = pattern[start..end];
    return if (std.unicode.utf8ValidateSlice(window)) window else "";
}

pub const Matcher = struct {
    memory: *Memory,
    data: *c.pcre2_match_data_8,
    context: *c.pcre2_match_context_8,
    stack: ?*c.pcre2_jit_stack_8,

    pub fn init(gpa: Allocator, limit: u32) Allocator.Error!Matcher {
        return initWith(gpa, limit, true);
    }

    fn initWith(gpa: Allocator, limit: u32, jit: bool) Allocator.Error!Matcher {
        const memory = try Memory.create(gpa);
        errdefer gpa.destroy(memory);
        const general = try memory.general();
        defer c.pcre2_general_context_free_8(general);
        const data = c.pcre2_match_data_create_8(1, general) orelse return error.OutOfMemory;
        errdefer c.pcre2_match_data_free_8(data);
        const context = c.pcre2_match_context_create_8(general) orelse return error.OutOfMemory;
        errdefer c.pcre2_match_context_free_8(context);
        _ = c.pcre2_set_match_limit_8(context, limit);
        _ = c.pcre2_set_depth_limit_8(context, limit);
        _ = c.pcre2_set_heap_limit_8(context, heap_limit_kib);
        const stack = if (jit) c.pcre2_jit_stack_create_8(jit_stack_start, jit_stack_max, general) else null;
        if (stack) |s| c.pcre2_jit_stack_assign_8(context, null, s);
        return .{ .memory = memory, .data = data, .context = context, .stack = stack };
    }

    pub fn deinit(self: Matcher, gpa: Allocator) void {
        if (self.stack) |s| c.pcre2_jit_stack_free_8(s);
        c.pcre2_match_context_free_8(self.context);
        c.pcre2_match_data_free_8(self.data);
        gpa.destroy(self.memory);
    }

    pub fn find(self: *const Matcher, re: Regex, text: []const u8) MatchError!?Span {
        const rc = c.pcre2_match_8(re.code, text.ptr, text.len, 0, 0, self.data, self.context);
        if (rc == c.PCRE2_ERROR_NOMATCH) return null;
        if (rc == c.PCRE2_ERROR_NOMEMORY) return error.OutOfMemory;
        if (rc < 0) return error.BudgetExceeded;
        const ovector = c.pcre2_get_ovector_pointer_8(self.data);
        const start = @min(ovector[0], ovector[1]);
        return .{ .start = start, .end = ovector[1] };
    }
};

const testing = std.testing;

fn matches(pattern: []const u8, text: []const u8) !bool {
    const re = try Regex.compile(testing.allocator, pattern, null);
    defer re.deinit(testing.allocator);
    const matcher = try Matcher.init(testing.allocator, 1_000_000);
    defer matcher.deinit(testing.allocator);
    return try matcher.find(re, text) != null;
}

fn expectMatch(pattern: []const u8, text: []const u8) !void {
    errdefer std.debug.print("expected /{s}/ to match \"{s}\"\n", .{ pattern, text });
    try testing.expect(try matches(pattern, text));
}

fn expectNoMatch(pattern: []const u8, text: []const u8) !void {
    errdefer std.debug.print("expected /{s}/ not to match \"{s}\"\n", .{ pattern, text });
    try testing.expect(!try matches(pattern, text));
}

fn expectRefused(pattern: []const u8, err: Error) !Diagnostic {
    var diag: Diagnostic = .{};
    errdefer std.debug.print("pattern /{s}/ gave \"{s}\" at \"{s}\"\n", .{ pattern, diag.what(), diag.at });
    try testing.expectError(err, Regex.compile(testing.allocator, pattern, &diag));
    try testing.expect(diag.what().len != 0);
    try testing.expect(std.unicode.utf8ValidateSlice(diag.at));
    return diag;
}

fn expectSpan(pattern: []const u8, text: []const u8, start: usize, end: usize) !void {
    const re = try Regex.compile(testing.allocator, pattern, null);
    defer re.deinit(testing.allocator);
    const matcher = try Matcher.init(testing.allocator, 1_000_000);
    defer matcher.deinit(testing.allocator);
    try testing.expectEqual(Span{ .start = start, .end = end }, (try matcher.find(re, text)).?);
}

test "regex literals, classes, anchors and alternation" {
    try expectMatch("scrape", "x.scrapeHepsiburadaApi()");
    try expectMatch("^scrape", "scrapeApi");
    try expectNoMatch("^Api", "scrapeApi");
    try expectMatch("^(get|post)Json$", "postJson");
    try expectNoMatch("^(get|post)Json$", "putJson");
    try expectMatch("^[a-z]+\\d$", "abc1");
    try expectNoMatch("^[^a-z]+$", "ABc");
    try expectMatch("a\\.b", "a.b");
    try expectNoMatch("a\\.b", "axb");
}

test "regex word boundaries, counted repetition and non-capturing groups" {
    try expectMatch("<button\\b", "<button class=x>");
    try expectNoMatch("<button\\b", "<buttons>");
    try expectMatch("\\.pruneData\\b|softDeleteOnPruningCycle", "  await this.pruneData(ids)");
    try expectMatch("^a{2,3}$", "aaa");
    try expectNoMatch("^a{2,3}$", "aaaa");
    try expectMatch("(?:function|const)\\s+\\w*Button\\b", "const SaveButton = 1");
}

test "regex flags, lookaround, backreferences, named groups and lazy quantifiers" {
    try expectMatch("(?i)hello", "HeLLo");
    try expectMatch("foo(?=bar)", "foobar");
    try expectNoMatch("foo(?!bar)", "foobar");
    try expectMatch("(?<=\\$)\\d+", "cost $42");
    try expectNoMatch("(?<!\\$)\\b\\d+", "$42");
    try expectMatch("(['\"]).*\\1", "say \"hi\" now");
    try expectNoMatch("^(['\"]).*\\1$", "'hi\"");
    try expectMatch("(?<q>x)\\k<q>", "axxb");
    try expectMatch("(?P<q>x)(?P=q)", "axxb");
    try expectSpan("<.+?>", "<a><b>", 0, 3);
    try expectMatch("^a++b$", "aab");
    try expectMatch("(?>a+)b", "aab");
}

test "regex Unicode classes, POSIX classes, escapes and quoting" {
    try expectMatch("^\\w+$", "şğüöçı");
    try expectMatch("\\bş\\b", "a ş b");
    try expectMatch("^\\p{L}+$", "Ünïcödé");
    try expectNoMatch("^\\p{Lu}$", "a");
    try expectMatch("^[[:alpha:]]+$", "abc");
    try expectMatch("\\x41\\x{42}", "AB");
    try expectMatch("\\Qa.b*\\E", "xa.b*y");
    try expectNoMatch("\\Qa.b\\E", "axb");
    try expectMatch("^\\d+$", "١٢٣");
}

test "regex dot never crosses a newline and invalid UTF-8 in the text never matches a dot" {
    try expectNoMatch("a.b", "a\nb");
    try expectNoMatch("^a.b$", "a\xffb");
    try expectMatch("b", "a\xffb");
    try expectMatch("ş", "\xffş");
}

test "regex reports where a match starts and ends in bytes" {
    try expectSpan("Error\\(", "  throw new Error(x)", 12, 18);
    try expectSpan("ş+", "aşşb", 1, 5);
    try expectSpan("^", "abc", 0, 0);
    try expectSpan("foo\\Kbar", "foobar", 3, 6);
}

test "regex refuses a malformed pattern as a syntax error and says where" {
    _ = try expectRefused("(a", error.RegexSyntax);
    _ = try expectRefused("a)", error.RegexSyntax);
    _ = try expectRefused("[a", error.RegexSyntax);
    _ = try expectRefused("[z-a]", error.RegexSyntax);
    _ = try expectRefused("*a", error.RegexSyntax);
    _ = try expectRefused("a\\", error.RegexSyntax);
    _ = try expectRefused("(?<n>a)(?<n>b)", error.RegexSyntax);
    _ = try expectRefused("\\k<missing>", error.RegexSyntax);
    const diag = try expectRefused("abc[z-a]", error.RegexSyntax);
    try testing.expectEqualStrings("range out of order in character class", diag.what());
    try testing.expectEqualStrings("abc[z-a]", diag.at);
}

test "regex refuses escapes PCRE2 does not implement as unsupported" {
    _ = try expectRefused("\\Uabc", error.RegexUnsupported);
    _ = try expectRefused("\\N{DIGIT ONE}", error.RegexUnsupported);
    _ = try expectRefused("[[.a.]]", error.RegexUnsupported);
}

test "regex refuses invalid UTF-8 in the pattern and points at nothing inside it" {
    for ([_][]const u8{ "a\xffb", "a\xe2\x82", "[\xc3]", "\xed\xa0\x80" }) |pattern| {
        const diag = try expectRefused(pattern, error.RegexSyntax);
        try testing.expectEqualStrings("", diag.at);
    }
    for ([_][]const u8{ "[ş-a]", "ş(", "ğğğğğğğğğğ[z-a]" }) |pattern| _ = try expectRefused(pattern, error.RegexSyntax);
}

test "a catastrophic pattern stops at the match limit instead of running away" {
    const re = try Regex.compile(testing.allocator, "^(a+)+$", null);
    defer re.deinit(testing.allocator);
    const matcher = try Matcher.init(testing.allocator, 100_000);
    defer matcher.deinit(testing.allocator);
    const text = "a" ** 40 ++ "!";
    try testing.expectError(error.BudgetExceeded, matcher.find(re, text));
    try testing.expect(try matcher.find(re, "a" ** 40) != null);
}

test "a counted match charges the text and every pattern step, and running out is an error, never a miss" {
    const re = try Regex.compileCounted(testing.allocator, "b", null);
    defer re.deinit(testing.allocator);
    var budget: u64 = 10;
    try testing.expectError(error.BudgetExceeded, re.isMatch(testing.allocator, "a" ** 100 ++ "b", &budget));
    budget = 1000;
    try testing.expect(try re.isMatch(testing.allocator, "a" ** 100 ++ "b", &budget));
    try testing.expect(budget < 1000 - 101);

    const slow = try Regex.compileCounted(testing.allocator, "^(a|aa)+$", null);
    defer slow.deinit(testing.allocator);
    budget = 1_000_000;
    try testing.expectError(error.BudgetExceeded, slow.isMatch(testing.allocator, "a" ** 60 ++ "!", &budget));
    try testing.expectEqual(@as(u64, 0), budget);
}

test "one compiled regex matches from many threads at once" {
    const re = try Regex.compile(testing.allocator, "(?i)\\bneedle\\d{2}\\b", null);
    defer re.deinit(testing.allocator);
    const Worker = struct {
        fn run(r: Regex, found: *std.atomic.Value(u32)) void {
            const matcher = Matcher.init(testing.allocator, 1_000_000) catch return;
            defer matcher.deinit(testing.allocator);
            for (0..1000) |i| {
                const text = if (i % 2 == 0) "hay NEEDLE42 hay" else "hay needle4 hay";
                if (matcher.find(r, text) catch null) |_| _ = found.fetchAdd(1, .monotonic);
            }
        }
    };
    var found: std.atomic.Value(u32) = .init(0);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ re, &found });
    for (threads) |t| t.join();
    try testing.expectEqual(@as(u32, 2000), found.load(.monotonic));
}
