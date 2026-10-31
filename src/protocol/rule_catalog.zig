const std = @import("std");
const rule_command = @import("rule_command.zig");
const text_checks = @import("../engine/text_checks.zig");
const memory = @import("../platform/memory.zig");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

pub const Lang = enum {
    universal,
    js_ts,
    python,
    csharp,

    pub fn tag(self: Lang) []const u8 {
        return switch (self) {
            .universal => "",
            .js_ts => " [js/ts]",
            .python => " [py]",
            .csharp => " [c#]",
        };
    }

    pub fn name(self: Lang) []const u8 {
        return switch (self) {
            .universal => "",
            .js_ts => "js/ts",
            .python => "py",
            .csharp => "c#",
        };
    }
};

pub const Entry = struct {
    num: u8,
    group: []const u8,
    label: []const u8,
    check: []const u8,
    lang: Lang = .universal,
    scopable: bool = false,
    needs_path: bool = false,
};

pub const catalog = [_]Entry{
    .{ .num = 1, .group = "Code style", .label = "no console.log", .check = "forbid:console.log", .lang = .js_ts, .scopable = true },
    .{ .num = 2, .group = "Code style", .label = "no debugger", .check = "forbid:debugger", .lang = .js_ts, .scopable = true },
    .{ .num = 3, .group = "Code style", .label = "no alert", .check = "forbid:alert", .lang = .js_ts, .scopable = true },
    .{ .num = 4, .group = "Code style", .label = "no var (use let/const)", .check = "q:((variable_declaration) @violation)", .lang = .js_ts, .scopable = true },
    .{ .num = 5, .group = "Code style", .label = "no any type", .check = "q:((predefined_type) @violation (#eq? @violation \"any\"))", .lang = .js_ts, .scopable = true },
    .{ .num = 6, .group = "Code style", .label = "no document.write", .check = "forbid:document.write", .lang = .js_ts, .scopable = true },
    .{ .num = 7, .group = "Code style", .label = "no innerHTML", .check = "forbid:innerHTML", .lang = .js_ts, .scopable = true },
    .{ .num = 8, .group = "Code style", .label = "no dangerouslySetInnerHTML", .check = "forbid:dangerouslySetInnerHTML", .lang = .js_ts, .scopable = true },
    .{ .num = 9, .group = "Code style", .label = "no focused tests (.only)", .check = "forbid:.only", .lang = .js_ts, .scopable = true },
    .{ .num = 10, .group = "Code style", .label = "no @ts-ignore", .check = "forbid:@ts-ignore", .lang = .js_ts, .scopable = true },
    .{ .num = 11, .group = "Code style", .label = "no print", .check = "q:(print_statement) @violation ((call function: (identifier) @violation) (#eq? @violation \"print\"))", .lang = .python, .scopable = true },
    .{ .num = 12, .group = "Code style", .label = "no exec", .check = "q:(exec_statement) @violation ((call function: (identifier) @violation) (#eq? @violation \"exec\"))", .lang = .python, .scopable = true },
    .{ .num = 13, .group = "Code style", .label = "no assert", .check = "q:(assert_statement) @violation", .lang = .python, .scopable = true },
    .{ .num = 14, .group = "Code style", .label = "no bare except", .check = "q:(except_clause !value) @violation", .lang = .python, .scopable = true },
    .{ .num = 15, .group = "Code style", .label = "no pickle", .check = "forbid_import:pickle", .lang = .python, .scopable = true },
    .{ .num = 16, .group = "Code style", .label = "no Console.WriteLine", .check = "q:((invocation_expression function: (member_access_expression expression: [(identifier) @type (member_access_expression name: (identifier) @type) (qualified_name name: (identifier) @type)] name: (identifier) @violation)) (#eq? @type \"Console\") (#eq? @violation \"WriteLine\"))", .lang = .csharp, .scopable = true },
    .{ .num = 17, .group = "Code style", .label = "no Debug.WriteLine", .check = "q:((invocation_expression function: (member_access_expression expression: [(identifier) @type (member_access_expression name: (identifier) @type) (qualified_name name: (identifier) @type)] name: (identifier) @violation)) (#eq? @type \"Debug\") (#eq? @violation \"WriteLine\"))", .lang = .csharp, .scopable = true },
    .{ .num = 18, .group = "Code style", .label = "no Thread.Sleep", .check = "q:((invocation_expression function: (member_access_expression expression: [(identifier) @type (member_access_expression name: (identifier) @type) (qualified_name name: (identifier) @type)] name: (identifier) @violation)) (#eq? @type \"Thread\") (#eq? @violation \"Sleep\"))", .lang = .csharp, .scopable = true },
    .{ .num = 19, .group = "Code style", .label = "no new comments", .check = "added:no_comment", .scopable = true },
    .{ .num = 20, .group = "Code style", .label = "doc comment on definitions", .check = "require_comment", .scopable = true },
    .{ .num = 21, .group = "Code style", .label = "functions at most 50 lines", .check = "max_function_lines:50", .scopable = true },
    .{ .num = 22, .group = "Code style", .label = "no TODO/FIXME/XXX", .check = "no_todo", .scopable = true },
    .{ .num = 23, .group = "Security", .label = "no eval", .check = "forbid:eval", .scopable = true },
    .{ .num = 24, .group = "Security", .label = "no hardcoded secrets", .check = "forbid_regex:(apiKey|api_key|apikey|secret|password|token|API_KEY|SECRET|PASSWORD|TOKEN)[\"']?\\s*[:=]\\s*[\"'][^\"']+", .scopable = true },
    .{ .num = 25, .group = "Security", .label = "no insecure http:// URLs", .check = "forbid:http://", .scopable = true },
    .{ .num = 26, .group = "Git hygiene", .label = "no Co-authored-by", .check = "message:forbid_any_case:co-authored-by" },
    .{ .num = 27, .group = "Git hygiene", .label = "no \"Generated with Claude\"", .check = "message:forbid_any_case:generated with claude" },
    .{ .num = 28, .group = "Git hygiene", .label = "no WIP", .check = "message:forbid_any_case:wip" },
    .{ .num = 29, .group = "Git hygiene", .label = "conventional commit subject", .check = "message:conventional" },
    .{ .num = 30, .group = "Architecture", .label = "freeze a path", .check = "frozen", .needs_path = true },
};

pub fn find(num: u8) ?Entry {
    for (catalog) |entry| {
        if (entry.num == num) return entry;
    }
    return null;
}

pub fn decidedOf(entry: Entry, where: ?[]const u8) rule_command.Decided {
    return .{
        .text = entry.label,
        .check = entry.check,
        .where = where,
        .enforce = true,
    };
}

pub const Marks = struct {
    on: [catalog.len]bool = @splat(false),

    pub fn of(decisions: []const memory.Decision) Marks {
        var marks: Marks = .{};
        for (decisions) |d| {
            if (!d.enforce or d.status != .active) continue;
            const check = d.check orelse continue;
            for (catalog, 0..) |entry, i| {
                if (std.mem.eql(u8, entry.check, check)) marks.on[i] = true;
            }
        }
        return marks;
    }

    pub fn inRepo(gpa: Allocator, io: std.Io, root: anyerror![]const u8) Marks {
        const root_abs = root catch return .{};
        const recalled = memory.recall(gpa, io, root_abs) catch return .{};
        defer recalled.deinit();
        return of(recalled.decisions);
    }

    fn any(self: Marks) bool {
        return std.mem.indexOfScalar(bool, &self.on, true) != null;
    }
};

pub const Verb = enum { pick, show };
pub const Outcome = enum { done, refused };

pub fn verbOf(word: []const u8) ?Verb {
    return std.meta.stringToEnum(Verb, word);
}

pub fn run(verb: Verb, gpa: Allocator, io: std.Io, root: anyerror![]const u8, args: []const [:0]const u8, prefix: []const u8, out: *Writer, err_out: *Writer) !Outcome {
    switch (verb) {
        .pick => {
            if (args.len == 0) {
                try render(out, prefix, Marks.inRepo(gpa, io, root));
                return .done;
            }
            try pick(gpa, io, try root, args, prefix, out, err_out);
            return .done;
        },
        .show => return show(out, err_out, prefix, args, Marks.inRepo(gpa, io, root)),
    }
}

pub const max_columns = 80;
const indent = "  ";
const gap = "   ";
const mark = " *";
const path_hint = " (needs a path: {s}pick {d} <path>)";
const usage_line = "{s}pick <numbers> [in <path>]";
const example_line = "e.g. {s}pick 1 19 26 in src/";
const separator = gap ++ " ";
const legend_line = "* = already enforced here";
const show_line = "{s}show N = what rule N checks";

const Layout = struct {
    num_width: usize,
    text_width: usize,
    lang_width: usize,

    fn of(entries: []const Entry, prefix: []const u8) Layout {
        var layout: Layout = .{ .num_width = digits(catalog[catalog.len - 1].num), .text_width = 0, .lang_width = 0 };
        for (entries) |entry| {
            layout.text_width = @max(layout.text_width, textWidth(entry, prefix));
            layout.lang_width = @max(layout.lang_width, entry.lang.name().len);
        }
        return layout;
    }

    fn cell(self: Layout) usize {
        const lang_part = if (self.lang_width == 0) 0 else 1 + self.lang_width;
        return self.num_width + 1 + self.text_width + mark.len + lang_part;
    }

    fn columns(self: Layout, count: usize) usize {
        const room = max_columns - indent.len + gap.len;
        const fit = @max(1, room / (self.cell() + gap.len));
        return @min(fit, count);
    }
};

fn digits(num: usize) usize {
    return std.fmt.count("{d}", .{num});
}

fn textWidth(entry: Entry, prefix: []const u8) usize {
    const hint = if (entry.needs_path) std.fmt.count(path_hint, .{ prefix, entry.num }) else 0;
    return entry.label.len + hint;
}

pub fn render(out: *Writer, prefix: []const u8, marks: Marks) !void {
    const usage_width = std.fmt.count(usage_line, .{prefix});
    const example_width = std.fmt.count(example_line, .{prefix});
    try out.print(usage_line, .{prefix});
    try out.writeAll(if (usage_width + separator.len + example_width <= max_columns) separator else "\n" ++ indent);
    try out.print(example_line ++ "\n\n", .{prefix});
    var start: usize = 0;
    while (start < catalog.len) {
        var end = start + 1;
        while (end < catalog.len and std.mem.eql(u8, catalog[end].group, catalog[start].group)) end += 1;
        try out.print("{s}\n", .{catalog[start].group});
        try renderGroup(out, prefix, marks, start, end);
        start = end;
    }
    try out.writeByte('\n');
    const show_width = std.fmt.count(show_line, .{prefix});
    if (marks.any()) {
        try out.writeAll(legend_line);
        try out.writeAll(if (legend_line.len + separator.len + show_width <= max_columns) separator else "\n");
    }
    try out.print(show_line ++ "\n", .{prefix});
}

fn renderGroup(out: *Writer, prefix: []const u8, marks: Marks, start: usize, end: usize) !void {
    const layout = Layout.of(catalog[start..end], prefix);
    const count = end - start;
    const cols = layout.columns(count);
    const rows = (count + cols - 1) / cols;
    for (0..rows) |row| {
        try out.writeAll(indent);
        for (0..cols) |col| {
            const at = col * rows + row;
            if (at >= count) break;
            const last = col + 1 == cols or (col + 1) * rows + row >= count;
            if (col > 0) try out.writeAll(gap);
            try renderCell(out, prefix, layout, catalog[start + at], marks.on[start + at], last);
        }
        try out.writeByte('\n');
    }
}

fn renderCell(out: *Writer, prefix: []const u8, layout: Layout, entry: Entry, marked: bool, last: bool) !void {
    try out.splatByteAll(' ', layout.num_width - digits(entry.num));
    try out.print("{d} {s}", .{ entry.num, entry.label });
    if (entry.needs_path) try out.print(path_hint, .{ prefix, entry.num });
    const tag = entry.lang.name();
    if (last and tag.len == 0) {
        if (marked) try out.writeAll(mark);
        return;
    }
    try out.writeAll(if (marked) mark else "  ");
    try out.splatByteAll(' ', layout.text_width - textWidth(entry, prefix));
    if (layout.lang_width == 0) return;
    try out.writeByte(' ');
    try out.writeAll(tag);
    if (!last) try out.splatByteAll(' ', layout.lang_width - tag.len);
}

pub fn show(out: *Writer, err_out: *Writer, prefix: []const u8, args: []const [:0]const u8, marks: Marks) !Outcome {
    const first = catalog[0].num;
    const final = catalog[catalog.len - 1].num;
    if (args.len != 1) {
        try err_out.print("usage: {s}show <number>   (a rule number from {d} to {d})\n", .{ prefix, first, final });
        return .refused;
    }
    const num = std.fmt.parseInt(u8, args[0], 10) catch null;
    const entry = (if (num) |n| find(n) else null) orelse {
        try err_out.print("show {s}: no such rule; give a number from {d} to {d}\n", .{ args[0], first, final });
        return .refused;
    };
    const marked = for (catalog, 0..) |candidate, i| {
        if (candidate.num == entry.num) break marks.on[i];
    } else false;
    try out.print("{d} {s}{s}\n", .{ entry.num, entry.label, if (marked) " (already enforced here)" else "" });
    try out.writeAll("applies to: ");
    if (text_checks.of(entry.check) != null) {
        try out.writeAll("commit messages\n");
    } else {
        if (entry.lang == .universal) try out.writeAll("every language") else try out.print("{s} files", .{entry.lang.name()});
        if (entry.needs_path) {
            try out.print(", the path you give: {s}pick {d} <path>\n", .{ prefix, entry.num });
        } else if (entry.scopable) {
            try out.print(", whole repository or {s}pick {d} in <path>\n", .{ prefix, entry.num });
        } else {
            try out.writeAll(", whole repository\n");
        }
    }
    try out.print("checks: {s}\n", .{entry.check});
    return .done;
}

pub const Step = union(enum) {
    add: struct { entry: Entry, path: ?[]const u8 },
    skip: struct { token: []const u8, reason: Skip },
    note: Note,
};

pub const Skip = enum { not_a_number, no_such_number, needs_path, duplicate };
pub const Note = enum { scope_without_path };

const scope_keyword = "in";

fn splitBatchScope(args: []const [:0]const u8, scope: *?[]const u8, missing: *bool) []const [:0]const u8 {
    if (args.len >= 2 and std.mem.eql(u8, args[args.len - 2], scope_keyword)) {
        scope.* = args[args.len - 1];
        return args[0 .. args.len - 2];
    }
    if (args.len >= 1 and std.mem.eql(u8, args[args.len - 1], scope_keyword)) {
        missing.* = true;
        return args[0 .. args.len - 1];
    }
    return args;
}

pub fn plan(args: []const [:0]const u8, steps: *std.ArrayList(Step), gpa: Allocator) !void {
    var batch_scope: ?[]const u8 = null;
    var scope_missing = false;
    const picks = splitBatchScope(args, &batch_scope, &scope_missing);

    var seen = [_]bool{false} ** (catalog.len + 1);
    var i: usize = 0;
    while (i < picks.len) : (i += 1) {
        const arg = picks[i];
        const num = std.fmt.parseInt(u8, arg, 10) catch {
            try steps.append(gpa, .{ .skip = .{ .token = arg, .reason = .not_a_number } });
            continue;
        };
        const entry = find(num) orelse {
            try steps.append(gpa, .{ .skip = .{ .token = arg, .reason = .no_such_number } });
            continue;
        };
        var where: ?[]const u8 = null;
        if (entry.needs_path) {
            if (i + 1 >= picks.len or looksLikeNumber(picks[i + 1])) {
                try steps.append(gpa, .{ .skip = .{ .token = arg, .reason = .needs_path } });
                continue;
            }
            i += 1;
            where = picks[i];
        } else if (entry.scopable) {
            where = batch_scope;
        }
        if (seen[num]) {
            try steps.append(gpa, .{ .skip = .{ .token = arg, .reason = .duplicate } });
            continue;
        }
        seen[num] = true;
        try steps.append(gpa, .{ .add = .{ .entry = entry, .path = where } });
    }
    if (scope_missing) try steps.append(gpa, .{ .note = .scope_without_path });
}

fn looksLikeNumber(token: []const u8) bool {
    if (token.len == 0) return false;
    for (token) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn noteSkip(out: *Writer, prefix: []const u8, token: []const u8, entry: ?Entry, reason: Skip) !void {
    switch (reason) {
        .not_a_number => try out.print("skip {s}: not a catalog number\n", .{token}),
        .no_such_number => try out.print("skip {s}: no such catalog number\n", .{token}),
        .duplicate => try out.print("skip {s}: already picked\n", .{token}),
        .needs_path => try out.print("skip {s}: {s} needs a path, e.g. {s}pick {s} <path>\n", .{ token, entry.?.label, prefix, token }),
    }
}

pub fn pick(gpa: Allocator, io: std.Io, root_abs: []const u8, args: []const [:0]const u8, prefix: []const u8, out: *Writer, err_out: *Writer) !void {
    if (args.len == 0) return render(out, prefix, .{});
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var steps: std.ArrayList(Step) = .empty;
    try plan(args, &steps, arena);
    var added: std.ArrayList(Step) = .empty;
    var problems: Writer.Allocating = .init(gpa);
    defer problems.deinit();
    var sink_buffer: [256]u8 = undefined;
    var sink: Writer.Discarding = .init(&sink_buffer);
    for (steps.items) |step| switch (step) {
        .note => try out.writeAll("in: no path given; applying picks to the whole repository\n"),
        .skip => |s| try noteSkip(out, prefix, s.token, find(std.fmt.parseInt(u8, s.token, 10) catch 0), s.reason),
        .add => |a| {
            problems.clearRetainingCapacity();
            const request: rule_command.Request = .{ .add = decidedOf(a.entry, a.path) };
            rule_command.runAs(.terse, gpa, io, root_abs, request, &sink.writer, &problems.writer) catch |err| switch (err) {
                error.OutOfMemory, error.WriteFailed => return err,
                else => {
                    try err_out.writeAll(problems.written());
                    try err_out.print("skip {d}: {t}\n", .{ a.entry.num, err });
                    continue;
                },
            };
            try added.append(arena, step);
        },
    };
    try writeEnforcing(out, added.items);
}

fn writeEnforcing(out: *Writer, added: []const Step) !void {
    if (added.len == 0) return;
    try out.print("enforcing {d} rule{s}: ", .{ added.len, if (added.len == 1) "" else "s" });
    for (added, 0..) |step, i| {
        if (i > 0) try out.writeAll(", ");
        try out.print("{d} {s}", .{ step.add.entry.num, step.add.entry.label });
        if (step.add.path) |path| try out.print(" in {s}", .{path});
    }
    try out.writeByte('\n');
}

const testing = std.testing;

fn pickDecided(num: u8, path: ?[]const u8) rule_command.Decided {
    return decidedOf(find(num).?, path);
}

const prefixes = [_][]const u8{ "/rule ", "emetgate rule " };

fn rendered(prefix: []const u8, marks: Marks) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try render(&out.writer, prefix, marks);
    return out.toOwnedSlice();
}

fn allMarked() Marks {
    var marks: Marks = .{};
    marks.on = @splat(true);
    return marks;
}

fn occurrences(text: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, text, needle);
}

test "catalog list: every line fits 80 columns, is ASCII, has no trailing blank, and the list stays short" {
    for (prefixes) |prefix| {
        for ([_]Marks{ .{}, allMarked() }) |marks| {
            const text = try rendered(prefix, marks);
            defer testing.allocator.free(text);
            errdefer std.debug.print("{s}\n", .{text});
            try testing.expect(std.mem.endsWith(u8, text, "\n"));
            var lines = std.mem.splitScalar(u8, text[0 .. text.len - 1], '\n');
            var count: usize = 0;
            while (lines.next()) |line| {
                count += 1;
                try testing.expect(line.len <= max_columns);
                try testing.expect(!std.mem.endsWith(u8, line, " "));
                for (line) |c| try testing.expect(c >= 0x20 and c < 0x7f);
            }
            try testing.expect(count <= 25);
        }
    }
}

test "catalog list: every rule number appears exactly once, and no check spec is shown" {
    for (prefixes) |prefix| {
        const text = try rendered(prefix, .{});
        defer testing.allocator.free(text);
        for (catalog) |entry| {
            var buf: [128]u8 = undefined;
            const cell = try std.fmt.bufPrint(&buf, " {d} {s}", .{ entry.num, entry.label });
            try testing.expectEqual(@as(usize, 1), occurrences(text, cell));
            if (entry.check.len > entry.label.len) try testing.expect(occurrences(text, entry.check) == 0);
        }
        try testing.expect(occurrences(text, "->") == 0);
        try testing.expect(occurrences(text, "q:(") == 0);
        var groups: usize = 0;
        for (catalog, 0..) |entry, i| {
            if (i == 0 or !std.mem.eql(u8, catalog[i - 1].group, entry.group)) {
                groups += 1;
                var buf: [64]u8 = undefined;
                try testing.expectEqual(@as(usize, 1), occurrences(text, try std.fmt.bufPrint(&buf, "\n{s}\n", .{entry.group})));
            }
        }
        try testing.expect(groups >= 4);
    }
}

test "catalog list: the usage line comes first and the path rule says it needs a path" {
    const text = try rendered("/rule ", .{});
    defer testing.allocator.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "/rule pick <numbers> [in <path>]    e.g. /rule pick 1 19 26 in src/\n\n"));
    try testing.expect(occurrences(text, "30 freeze a path (needs a path: /rule pick 30 <path>)\n") == 1);
    try testing.expect(std.mem.endsWith(u8, text, "\n\n/rule show N = what rule N checks\n"));
    try testing.expect(occurrences(text, "*") == 0);
    try testing.expect(occurrences(text, "  1 no console.log") == 1);
    try testing.expect(occurrences(text, "js/ts   12 no exec") == 1);

    const cli = try rendered("emetgate rule ", .{});
    defer testing.allocator.free(cli);
    try testing.expect(std.mem.startsWith(u8, cli, "emetgate rule pick <numbers> [in <path>]\n  e.g. emetgate rule pick 1 19 26 in src/\n\n"));
    try testing.expect(occurrences(cli, "(needs a path: emetgate rule pick 30 <path>)") == 1);
}

test "catalog list: rules enforced in the ledger are marked and only those" {
    const decisions = [_]memory.Decision{
        .{ .id = "m1", .scope = .project, .text = "anything", .enforce = true, .check = "message:forbid_any_case:co-authored-by", .status = .active, .ts = 0 },
        .{ .id = "m2", .scope = .project, .text = "anything", .enforce = true, .check = "forbid:console.log", .status = .active, .ts = 0, .where = "app/" },
        .{ .id = "m3", .scope = .project, .text = "advisory", .enforce = false, .check = "no_todo", .status = .active, .ts = 0 },
        .{ .id = "m4", .scope = .project, .text = "gone", .enforce = true, .check = "forbid:eval", .status = .superseded, .ts = 0 },
        .{ .id = "m5", .scope = .project, .text = "hand written", .enforce = true, .check = "forbid:networkidle", .status = .active, .ts = 0 },
        .{ .id = "m6", .scope = .project, .text = "no check", .enforce = false, .status = .active, .ts = 0 },
    };
    const marks = Marks.of(&decisions);
    for (catalog, 0..) |entry, i| try testing.expectEqual(entry.num == 1 or entry.num == 26, marks.on[i]);

    const text = try rendered("/rule ", marks);
    defer testing.allocator.free(text);
    try testing.expectEqual(@as(usize, 3), occurrences(text, "*"));
    try testing.expect(occurrences(text, "1 no console.log *") == 1);
    try testing.expect(occurrences(text, "26 no Co-authored-by *") == 1);
    try testing.expect(std.mem.endsWith(u8, text, "\n\n* = already enforced here    /rule show N = what rule N checks\n"));
}

test "catalog list: outside a repository nothing is marked and nothing fails" {
    const marks = Marks.inRepo(testing.allocator, testing.io, error.NotAGitRepository);
    for (marks.on) |on| try testing.expect(!on);
}

fn shown(args: []const [:0]const u8, marks: Marks) !struct { outcome: Outcome, out: []u8, err: []u8 } {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err_out: Writer.Allocating = .init(testing.allocator);
    defer err_out.deinit();
    const outcome = try show(&out.writer, &err_out.writer, "/rule ", args, marks);
    const said = try out.toOwnedSlice();
    errdefer testing.allocator.free(said);
    return .{ .outcome = outcome, .out = said, .err = try err_out.toOwnedSlice() };
}

fn expectShown(args: []const [:0]const u8, marks: Marks, want: []const u8) !void {
    const got = try shown(args, marks);
    defer testing.allocator.free(got.out);
    defer testing.allocator.free(got.err);
    try testing.expectEqual(Outcome.done, got.outcome);
    try testing.expectEqualStrings("", got.err);
    try testing.expectEqualStrings(want, got.out);
}

fn expectRefused(args: []const [:0]const u8, want: []const u8) !void {
    const got = try shown(args, .{});
    defer testing.allocator.free(got.out);
    defer testing.allocator.free(got.err);
    try testing.expectEqual(Outcome.refused, got.outcome);
    try testing.expectEqualStrings("", got.out);
    try testing.expectEqualStrings(want, got.err);
}

test "show N prints the title, what it applies to and the full check spec" {
    try expectShown(&.{"1"}, .{}, "1 no console.log\napplies to: js/ts files, whole repository or /rule pick 1 in <path>\nchecks: forbid:console.log\n");
    try expectShown(&.{"19"}, allMarked(), "19 no new comments (already enforced here)\napplies to: every language, whole repository or /rule pick 19 in <path>\nchecks: added:no_comment\n");
    try expectShown(&.{"26"}, .{}, "26 no Co-authored-by\napplies to: commit messages\nchecks: message:forbid_any_case:co-authored-by\n");
    try expectShown(&.{"30"}, .{}, "30 freeze a path\napplies to: every language, the path you give: /rule pick 30 <path>\nchecks: frozen\n");
    for (catalog) |entry| {
        var buf: [4]u8 = undefined;
        const num = try std.fmt.bufPrintZ(&buf, "{d}", .{entry.num});
        const got = try shown(&.{num}, .{});
        defer testing.allocator.free(got.out);
        defer testing.allocator.free(got.err);
        try testing.expectEqual(Outcome.done, got.outcome);
        try testing.expect(std.mem.indexOf(u8, got.out, entry.label) != null);
        try testing.expect(std.mem.indexOf(u8, got.out, entry.check) != null);
    }
}

test "show with a number outside the catalog answers one line naming the valid range" {
    try expectRefused(&.{"31"}, "show 31: no such rule; give a number from 1 to 30\n");
    try expectRefused(&.{"0"}, "show 0: no such rule; give a number from 1 to 30\n");
    try expectRefused(&.{"999"}, "show 999: no such rule; give a number from 1 to 30\n");
    try expectRefused(&.{"x"}, "show x: no such rule; give a number from 1 to 30\n");
    try expectRefused(&.{}, "usage: /rule show <number>   (a rule number from 1 to 30)\n");
    try expectRefused(&.{ "1", "2" }, "usage: /rule show <number>   (a rule number from 1 to 30)\n");
}

test "a pick answers one short line naming the rules it now enforces" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const steps = [_]Step{
        .{ .add = .{ .entry = find(1).?, .path = null } },
        .{ .add = .{ .entry = find(19).?, .path = null } },
        .{ .add = .{ .entry = find(26).?, .path = null } },
    };
    try writeEnforcing(&out.writer, &steps);
    try testing.expectEqualStrings("enforcing 3 rules: 1 no console.log, 19 no new comments, 26 no Co-authored-by\n", out.written());

    out.clearRetainingCapacity();
    try writeEnforcing(&out.writer, &.{.{ .add = .{ .entry = find(30).?, .path = "src/core" } }});
    try testing.expectEqualStrings("enforcing 1 rule: 30 freeze a path in src/core\n", out.written());

    out.clearRetainingCapacity();
    try writeEnforcing(&out.writer, &.{});
    try testing.expectEqualStrings("", out.written());
}

test "catalog verbs: pick and show are taken, anything else is not" {
    try testing.expectEqual(Verb.pick, verbOf("pick").?);
    try testing.expectEqual(Verb.show, verbOf("show").?);
    try testing.expectEqual(@as(?Verb, null), verbOf("list"));
    try testing.expectEqual(@as(?Verb, null), verbOf("Pick"));
}

test "pick maps numbers to the exact check specs, whole-repo scope by default, and enforce" {
    const one = pickDecided(1, null);
    try testing.expectEqualStrings("no console.log", one.text);
    try testing.expectEqualStrings("forbid:console.log", one.check.?);
    try testing.expectEqual(@as(?[]const u8, null), one.where);
    try testing.expect(one.enforce);

    const todo = pickDecided(22, null);
    try testing.expectEqualStrings("no_todo", todo.check.?);
    try testing.expectEqual(@as(?[]const u8, null), todo.where);
    try testing.expect(todo.enforce);

    const comments = pickDecided(19, null);
    try testing.expectEqualStrings("added:no_comment", comments.check.?);

    const coauthored = pickDecided(26, null);
    try testing.expectEqualStrings("message:forbid_any_case:co-authored-by", coauthored.check.?);
    try testing.expectEqual(@as(?[]const u8, null), coauthored.where);
    try testing.expect(coauthored.enforce);
}

test "the new catalog entries map to the exact verified check specs and carry their language tag" {
    const debugger = pickDecided(2, null);
    try testing.expectEqualStrings("forbid:debugger", debugger.check.?);
    const alert = pickDecided(3, null);
    try testing.expectEqualStrings("forbid:alert", alert.check.?);
    const no_var = pickDecided(4, null);
    try testing.expectEqualStrings("q:((variable_declaration) @violation)", no_var.check.?);
    const no_any = pickDecided(5, null);
    try testing.expectEqualStrings("q:((predefined_type) @violation (#eq? @violation \"any\"))", no_any.check.?);
    const dangerous = pickDecided(8, null);
    try testing.expectEqualStrings("forbid:dangerouslySetInnerHTML", dangerous.check.?);
    const require = pickDecided(20, null);
    try testing.expectEqualStrings("require_comment", require.check.?);
    const max_len = pickDecided(21, null);
    try testing.expectEqualStrings("max_function_lines:50", max_len.check.?);
    const secrets = pickDecided(24, null);
    try testing.expect(std.mem.startsWith(u8, secrets.check.?, "forbid_regex:"));
    const http = pickDecided(25, null);
    try testing.expectEqualStrings("forbid:http://", http.check.?);
    const conventional = pickDecided(29, null);
    try testing.expectEqualStrings("message:conventional", conventional.check.?);

    try testing.expectEqualStrings("q:(except_clause !value) @violation", find(14).?.check);
    try testing.expectEqualStrings("forbid_import:pickle", find(15).?.check);
    for (catalog) |entry| {
        if (entry.num >= 11 and entry.num <= 15) try testing.expectEqual(Lang.python, entry.lang);
        if (entry.num >= 16 and entry.num <= 18) try testing.expectEqual(Lang.csharp, entry.lang);
    }

    // Language tags are set where they matter and absent for universal rules.
    try testing.expectEqual(Lang.js_ts, find(1).?.lang);
    try testing.expectEqual(Lang.universal, find(22).?.lang);
    try testing.expectEqualStrings(" [js/ts]", find(1).?.lang.tag());
    try testing.expectEqualStrings(" [py]", find(11).?.lang.tag());
    try testing.expectEqualStrings(" [c#]", find(16).?.lang.tag());
    try testing.expectEqualStrings("", find(22).?.lang.tag());
}

test "catalog invariant: numbers run 1..N in array order and groups are contiguous" {
    var seen_groups: [catalog.len][]const u8 = undefined;
    var group_count: usize = 0;
    for (catalog, 0..) |entry, i| {
        try testing.expectEqual(@as(u8, @intCast(i + 1)), entry.num);
        // A group may only start once: if this row begins a new group, that group
        // must not have appeared before (otherwise a header would print twice).
        if (i == 0 or !std.mem.eql(u8, catalog[i - 1].group, entry.group)) {
            for (seen_groups[0..group_count]) |g| try testing.expect(!std.mem.eql(u8, g, entry.group));
            seen_groups[group_count] = entry.group;
            group_count += 1;
        }
    }
}

test "pick 30 without a path maps to no scope; with a path maps to frozen --in path" {
    const bare = pickDecided(30, null);
    try testing.expectEqualStrings("frozen", bare.check.?);
    try testing.expectEqual(@as(?[]const u8, null), bare.where);

    const scoped = pickDecided(30, "src/core");
    try testing.expectEqualStrings("frozen", scoped.check.?);
    try testing.expectEqualStrings("src/core", scoped.where.?);
    try testing.expect(scoped.enforce);
}

test "an invalid catalog number is not found" {
    try testing.expectEqual(@as(?Entry, null), find(0));
    try testing.expectEqual(@as(?Entry, null), find(42));
    try testing.expectEqual(@as(?Entry, null), find(31));
    try testing.expect(find(1) != null);
    try testing.expect(find(30) != null);
}

fn planOf(args: []const [:0]const u8) !std.ArrayList(Step) {
    var steps: std.ArrayList(Step) = .empty;
    try plan(args, &steps, testing.allocator);
    return steps;
}

test "plan: pick 1 22 adds those two entries in order with their specs" {
    var steps = try planOf(&.{ "1", "22" });
    defer steps.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), steps.items.len);
    try testing.expectEqual(@as(u8, 1), steps.items[0].add.entry.num);
    try testing.expectEqualStrings("forbid:console.log", steps.items[0].add.entry.check);
    try testing.expectEqual(@as(?[]const u8, null), steps.items[0].add.path);
    try testing.expectEqual(@as(u8, 22), steps.items[1].add.entry.num);
    try testing.expectEqualStrings("no_todo", steps.items[1].add.entry.check);
}

test "plan: an invalid number is skipped while the valid ones still add" {
    var steps = try planOf(&.{ "1", "99", "x", "4" });
    defer steps.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), steps.items.len);
    try testing.expectEqual(@as(u8, 1), steps.items[0].add.entry.num);
    try testing.expectEqual(Skip.no_such_number, steps.items[1].skip.reason);
    try testing.expectEqual(Skip.not_a_number, steps.items[2].skip.reason);
    try testing.expectEqual(@as(u8, 4), steps.items[3].add.entry.num);
}

test "plan: a duplicate number is skipped the second time" {
    var steps = try planOf(&.{ "2", "2" });
    defer steps.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), steps.items.len);
    try testing.expectEqual(@as(u8, 2), steps.items[0].add.entry.num);
    try testing.expectEqual(Skip.duplicate, steps.items[1].skip.reason);
}

test "plan: pick 30 without a path adds nothing for 30 but still processes the others" {
    var steps = try planOf(&.{ "1", "3", "30" });
    defer steps.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), steps.items.len);
    try testing.expectEqual(@as(u8, 1), steps.items[0].add.entry.num);
    try testing.expectEqual(@as(u8, 3), steps.items[1].add.entry.num);
    try testing.expectEqual(Skip.needs_path, steps.items[2].skip.reason);
}

test "plan: pick 30 src/core adds frozen --in src/core (path is not a number)" {
    var steps = try planOf(&.{ "30", "src/core" });
    defer steps.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), steps.items.len);
    const decided = decidedOf(steps.items[0].add.entry, steps.items[0].add.path);
    try testing.expectEqualStrings("frozen", decided.check.?);
    try testing.expectEqualStrings("src/core", decided.where.?);
    try testing.expect(decided.enforce);
}

test "plan: pick 30 alone skips 30 for lack of a path" {
    var steps = try planOf(&.{"30"});
    defer steps.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), steps.items.len);
    try testing.expectEqual(Skip.needs_path, steps.items[0].skip.reason);
}

test "plan: pick 30 99 does not eat 99 as a path; 30 is skipped and 99 is its own pick" {
    var steps = try planOf(&.{ "30", "99" });
    defer steps.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), steps.items.len);
    try testing.expectEqual(Skip.needs_path, steps.items[0].skip.reason);
    try testing.expectEqualStrings("30", steps.items[0].skip.token);
    try testing.expectEqual(Skip.no_such_number, steps.items[1].skip.reason);
    try testing.expectEqualStrings("99", steps.items[1].skip.token);
}

test "plan: pick 1 30 2 adds 1, skips 30 for lack of a path, adds 2" {
    var steps = try planOf(&.{ "1", "30", "2" });
    defer steps.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), steps.items.len);
    try testing.expectEqual(@as(u8, 1), steps.items[0].add.entry.num);
    try testing.expectEqual(Skip.needs_path, steps.items[1].skip.reason);
    try testing.expectEqual(@as(u8, 2), steps.items[2].add.entry.num);
}

test "plan: pick 1 3 adds both to the whole repo (no scope)" {
    var steps = try planOf(&.{ "1", "3" });
    defer steps.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), steps.items.len);
    try testing.expectEqual(@as(?[]const u8, null), steps.items[0].add.path);
    try testing.expectEqual(@as(?[]const u8, null), steps.items[1].add.path);
}

test "plan: pick 1 3 in app/ scopes both code rules to app/" {
    var steps = try planOf(&.{ "1", "3", "in", "app/" });
    defer steps.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), steps.items.len);
    try testing.expectEqual(@as(u8, 1), steps.items[0].add.entry.num);
    try testing.expectEqualStrings("app/", steps.items[0].add.path.?);
    try testing.expectEqual(@as(u8, 3), steps.items[1].add.entry.num);
    try testing.expectEqualStrings("app/", steps.items[1].add.path.?);
}

test "plan: a batch scope never touches a message rule" {
    var steps = try planOf(&.{ "1", "26", "in", "app/" });
    defer steps.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), steps.items.len);
    try testing.expectEqualStrings("app/", steps.items[0].add.path.?);
    try testing.expectEqual(@as(u8, 26), steps.items[1].add.entry.num);
    try testing.expectEqual(@as(?[]const u8, null), steps.items[1].add.path);
}

test "plan: pick 30 src/core in app/ keeps 30's own path and still scopes code rules" {
    var steps = try planOf(&.{ "30", "src/core", "in", "app/" });
    defer steps.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), steps.items.len);
    try testing.expectEqual(@as(u8, 30), steps.items[0].add.entry.num);
    try testing.expectEqualStrings("src/core", steps.items[0].add.path.?);

    var both = try planOf(&.{ "1", "30", "src/core", "in", "app/" });
    defer both.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), both.items.len);
    try testing.expectEqual(@as(u8, 1), both.items[0].add.entry.num);
    try testing.expectEqualStrings("app/", both.items[0].add.path.?);
    try testing.expectEqual(@as(u8, 30), both.items[1].add.entry.num);
    try testing.expectEqualStrings("src/core", both.items[1].add.path.?);
}

test "plan: a trailing in with no path leaves whole-repo scope and emits a note" {
    var steps = try planOf(&.{ "1", "3", "in" });
    defer steps.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), steps.items.len);
    try testing.expectEqual(@as(?[]const u8, null), steps.items[0].add.path);
    try testing.expectEqual(@as(?[]const u8, null), steps.items[1].add.path);
    try testing.expectEqual(Note.scope_without_path, steps.items[2].note);
}

const ts = @import("../engine/tree_sitter.zig");
const lang = @import("../engine/lang/registry.zig");
const checks = @import("../engine/checks.zig");
const alloc_bridge = @import("../engine/alloc_bridge.zig");

fn presetHits(num: u8, path: []const u8, source: []const u8) ![]const []const u8 {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const profile = lang.forPath(path).?;
    const parser = try ts.Parser.init(profile.grammar());
    defer parser.deinit();
    const tree = try parser.parse(source);
    defer tree.deinit();
    const violations = try checks.run(testing.allocator, profile, tree, .{ .start = 0, .end = @intCast(source.len) }, &.{find(num).?.check});
    defer testing.allocator.free(violations);
    const texts = try testing.allocator.alloc([]const u8, violations.len);
    for (violations, texts) |v, *text| text.* = source[v.span.start..v.span.end];
    return texts;
}

fn expectPreset(num: u8, path: []const u8, source: []const u8, expected: []const []const u8) !void {
    const texts = try presetHits(num, path, source);
    defer testing.allocator.free(texts);
    errdefer for (texts) |text| std.debug.print("preset {d} flagged: {s}\n", .{ num, text });
    try testing.expectEqual(expected.len, texts.len);
    for (expected, texts) |want, got| try testing.expectEqualStrings(want, got);
}

test "python presets flag the construct itself and not a name, string or comment that mentions it" {
    try expectPreset(11, "a.py", "print(x)\nlog.print(x)\nblueprint(x)\ns = \"print\"\n# print\n", &.{"print"});
    try expectPreset(12, "a.py", "exec(code)\nexecute(code)\nself.exec(q)\ns = \"exec\"\n", &.{"exec"});
    try expectPreset(13, "a.py", "assert x\nassertEqual(a, b)\nself.assertTrue(a)\n", &.{"assert x"});
    try expectPreset(14, "a.py", "try:\n    f()\nexcept:\n    pass\n", &.{"except:\n    pass"});
    try expectPreset(14, "a.py", "try:\n    f()\nexcept ValueError:\n    pass\nexcept (A, B) as e:\n    pass\n", &.{});
    try expectPreset(15, "a.py", "import pickle\nimport pickle as p\nfrom pickle import loads\nimport pickle.x\n", &.{ "import pickle", "import pickle as p", "from pickle import loads", "import pickle.x" });
    try expectPreset(15, "a.py", "import pickles\nimport cloudpickle\nfrom mypickle import x\ns = \"pickle\"\n", &.{});
}

test "c# presets flag the named member call and not another type or member of the same name" {
    const source =
        \\class A {
        \\    void F() {
        \\        Console.WriteLine(1);
        \\        System.Console.WriteLine(2);
        \\        Debug.WriteLine(3);
        \\        Thread.Sleep(4);
        \\        MyConsole.WriteLine(5);
        \\        Console.Write(6);
        \\        var s = "Console.WriteLine";
        \\        Sleep(7);
        \\    }
        \\}
        \\
    ;
    try expectPreset(16, "a.cs", source, &.{ "WriteLine", "WriteLine" });
    try expectPreset(17, "a.cs", source, &.{"WriteLine"});
    try expectPreset(18, "a.cs", source, &.{"Sleep"});
}
