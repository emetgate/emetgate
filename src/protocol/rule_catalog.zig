const std = @import("std");
const rule_command = @import("rule_command.zig");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

// A preset rule a user can SELECT by number instead of writing a --check spec.
// Each entry maps a catalog number to the exact check spec `rule add` would take
// and its text (the human label). Every preset applies to the whole repository by
// default. `scopable` marks a code rule that an optional trailing `in <path>` can
// narrow; `needs_path` marks an entry whose scope the user supplies at pick time
// (e.g. frozen --in <path>), which the batch scope never touches.
pub const Entry = struct {
    num: u8,
    group: []const u8,
    label: []const u8,
    check: []const u8,
    scopable: bool = false,
    needs_path: bool = false,
};

pub const catalog = [_]Entry{
    .{ .num = 1, .group = "Code style", .label = "no console.log", .check = "forbid:console.log", .scopable = true },
    .{ .num = 2, .group = "Code style", .label = "no new comments", .check = "added:no_comment", .scopable = true },
    .{ .num = 3, .group = "Code style", .label = "no TODO/FIXME/XXX", .check = "no_todo", .scopable = true },
    .{ .num = 4, .group = "Security", .label = "no eval", .check = "forbid:eval", .scopable = true },
    .{ .num = 5, .group = "Git hygiene", .label = "no \"Co-authored-by: Claude\" in commits", .check = "message:forbid_any_case:co-authored-by" },
    .{ .num = 6, .group = "Git hygiene", .label = "no \"Generated with Claude\" in commits", .check = "message:forbid_any_case:generated with claude" },
    .{ .num = 7, .group = "Architecture", .label = "freeze a path", .check = "frozen", .needs_path = true },
};

pub fn find(num: u8) ?Entry {
    for (catalog) |entry| {
        if (entry.num == num) return entry;
    }
    return null;
}

// The `rule add` request a picked entry maps to: the label becomes the text, the
// check is taken verbatim, the scope is the already-resolved `where` (whole repo
// when null), and every picked rule is enforced.
pub fn decidedOf(entry: Entry, where: ?[]const u8) rule_command.Decided {
    return .{
        .text = entry.label,
        .check = entry.check,
        .where = where,
        .enforce = true,
    };
}

// `/rule pick` with no numbers: print the grouped, numbered catalog.
pub fn render(out: *Writer) !void {
    try out.writeAll("pick rules to enforce (whole repo by default; add `in <path>` to scope, e.g. /rule pick 1 3 in app/):\n");
    var group: []const u8 = "";
    for (catalog) |entry| {
        if (!std.mem.eql(u8, group, entry.group)) {
            try out.print("{s}:\n", .{entry.group});
            group = entry.group;
        }
        try out.print(" {d}) {s}\n", .{ entry.num, entry.label });
        if (entry.needs_path) {
            try out.print("      -> {s} --in <path>  (e.g. /rule pick {d} src/core)\n", .{ entry.check, entry.num });
        } else {
            try out.print("      -> {s}\n", .{entry.check});
        }
    }
}

// One decision the arg walk reaches: add this entry with its resolved scope (null
// = whole repo), skip the given token with a reason, or emit a standalone note.
pub const Step = union(enum) {
    add: struct { entry: Entry, path: ?[]const u8 },
    skip: struct { token: []const u8, reason: Skip },
    note: Note,
};

pub const Skip = enum { not_a_number, no_such_number, needs_path, duplicate };
pub const Note = enum { scope_without_path };

const scope_keyword = "in";

// Split off an optional trailing batch scope `in <path>` from the picked tokens.
// `in <path>` as the last two tokens sets the scope; a trailing `in` alone reports
// a missing path and leaves the scope whole-repo. Returns the tokens to walk.
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

// Walk the picked tokens into an ordered plan, without touching the ledger. A
// trailing `in <path>` scopes the code rules (`scopable`); item 7 still takes the
// token right after its number as its own path and is unaffected by the batch
// scope, and the message rules take no scope. Unknown, duplicate or path-less
// numbers become skips so the rest still proceed. `steps` is filled in order.
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
            // Consume the next token as the path only if it exists and does not
            // itself look like a catalog number; otherwise skip and let it be
            // processed as its own pick.
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

// A bare non-negative integer, i.e. something a user likely meant as another
// catalog number rather than as item 7's freeze path.
fn looksLikeNumber(token: []const u8) bool {
    if (token.len == 0) return false;
    for (token) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn noteSkip(out: *Writer, token: []const u8, entry: ?Entry, reason: Skip) !void {
    switch (reason) {
        .not_a_number => try out.print("skip {s}: not a catalog number\n", .{token}),
        .no_such_number => try out.print("skip {s}: no such catalog number\n", .{token}),
        .duplicate => try out.print("skip {s}: already picked\n", .{token}),
        .needs_path => try out.print("skip {s}: {s} needs a path, e.g. /rule pick {s} <path>\n", .{ token, entry.?.label, token }),
    }
}

// `/rule pick <numbers...>`: add each mapped rule through the same path `rule add`
// uses. Unknown, duplicate or path-less (item 7) numbers are skipped with a note
// without aborting the rest.
pub fn pick(gpa: Allocator, io: std.Io, root_abs: []const u8, args: []const [:0]const u8, out: *Writer, err_out: *Writer) !void {
    if (args.len == 0) return render(out);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var steps: std.ArrayList(Step) = .empty;
    try plan(args, &steps, arena_state.allocator());
    for (steps.items) |step| switch (step) {
        .note => try out.writeAll("in: no path given; applying picks to the whole repository\n"),
        .skip => |s| try noteSkip(out, s.token, find(std.fmt.parseInt(u8, s.token, 10) catch 0), s.reason),
        .add => |a| {
            const request: rule_command.Request = .{ .add = decidedOf(a.entry, a.path) };
            rule_command.runAs(.spoken, gpa, io, root_abs, request, out, err_out) catch |err| switch (err) {
                error.OutOfMemory, error.WriteFailed => return err,
                else => try out.print("skip {d}: {t}\n", .{ a.entry.num, err }),
            };
        },
    };
}

const testing = std.testing;

fn pickDecided(num: u8, path: ?[]const u8) rule_command.Decided {
    return decidedOf(find(num).?, path);
}

test "catalog renders every entry grouped and numbered" {
    var buf: [2048]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try render(&w);
    const text = w.buffered();
    for (catalog) |entry| {
        var line: [64]u8 = undefined;
        const marker = try std.fmt.bufPrint(&line, " {d}) ", .{entry.num});
        try testing.expect(std.mem.indexOf(u8, text, marker) != null);
        try testing.expect(std.mem.indexOf(u8, text, entry.label) != null);
    }
    try testing.expect(std.mem.indexOf(u8, text, "Code style:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Architecture:") != null);
}

test "pick maps numbers to the exact check specs, whole-repo scope by default, and enforce" {
    const one = pickDecided(1, null);
    try testing.expectEqualStrings("no console.log", one.text);
    try testing.expectEqualStrings("forbid:console.log", one.check.?);
    try testing.expectEqual(@as(?[]const u8, null), one.where);
    try testing.expect(one.enforce);

    const three = pickDecided(3, null);
    try testing.expectEqualStrings("no_todo", three.check.?);
    try testing.expectEqual(@as(?[]const u8, null), three.where);
    try testing.expect(three.enforce);

    const two = pickDecided(2, null);
    try testing.expectEqualStrings("added:no_comment", two.check.?);

    const five = pickDecided(5, null);
    try testing.expectEqualStrings("message:forbid_any_case:co-authored-by", five.check.?);
    try testing.expectEqual(@as(?[]const u8, null), five.where);
    try testing.expect(five.enforce);
}

test "pick 7 without a path maps to no scope; with a path maps to frozen --in path" {
    const bare = pickDecided(7, null);
    try testing.expectEqualStrings("frozen", bare.check.?);
    try testing.expectEqual(@as(?[]const u8, null), bare.where);

    const scoped = pickDecided(7, "src/core");
    try testing.expectEqualStrings("frozen", scoped.check.?);
    try testing.expectEqualStrings("src/core", scoped.where.?);
    try testing.expect(scoped.enforce);
}

test "an invalid catalog number is not found" {
    try testing.expectEqual(@as(?Entry, null), find(0));
    try testing.expectEqual(@as(?Entry, null), find(42));
    try testing.expect(find(1) != null);
    try testing.expect(find(7) != null);
}

fn planOf(args: []const [:0]const u8) !std.ArrayList(Step) {
    var steps: std.ArrayList(Step) = .empty;
    try plan(args, &steps, testing.allocator);
    return steps;
}

test "plan: pick 1 3 adds those two entries in order with their specs" {
    var steps = try planOf(&.{ "1", "3" });
    defer steps.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), steps.items.len);
    try testing.expectEqual(@as(u8, 1), steps.items[0].add.entry.num);
    try testing.expectEqualStrings("forbid:console.log", steps.items[0].add.entry.check);
    try testing.expectEqual(@as(?[]const u8, null), steps.items[0].add.path);
    try testing.expectEqual(@as(u8, 3), steps.items[1].add.entry.num);
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

test "plan: pick 7 without a path adds nothing for 7 but still processes the others" {
    var steps = try planOf(&.{ "1", "3", "7" });
    defer steps.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), steps.items.len);
    try testing.expectEqual(@as(u8, 1), steps.items[0].add.entry.num);
    try testing.expectEqual(@as(u8, 3), steps.items[1].add.entry.num);
    try testing.expectEqual(Skip.needs_path, steps.items[2].skip.reason);
}

test "plan: pick 7 src/core adds frozen --in src/core (path is not a number)" {
    var steps = try planOf(&.{ "7", "src/core" });
    defer steps.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), steps.items.len);
    const decided = decidedOf(steps.items[0].add.entry, steps.items[0].add.path);
    try testing.expectEqualStrings("frozen", decided.check.?);
    try testing.expectEqualStrings("src/core", decided.where.?);
    try testing.expect(decided.enforce);
}

test "plan: pick 7 alone skips 7 for lack of a path" {
    var steps = try planOf(&.{"7"});
    defer steps.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), steps.items.len);
    try testing.expectEqual(Skip.needs_path, steps.items[0].skip.reason);
}

test "plan: pick 7 99 does not eat 99 as a path; 7 is skipped and 99 is its own pick" {
    var steps = try planOf(&.{ "7", "99" });
    defer steps.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), steps.items.len);
    try testing.expectEqual(Skip.needs_path, steps.items[0].skip.reason);
    try testing.expectEqualStrings("7", steps.items[0].skip.token);
    try testing.expectEqual(Skip.no_such_number, steps.items[1].skip.reason);
    try testing.expectEqualStrings("99", steps.items[1].skip.token);
}

test "plan: pick 1 7 2 adds 1, skips 7 for lack of a path, adds 2" {
    var steps = try planOf(&.{ "1", "7", "2" });
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
    var steps = try planOf(&.{ "1", "5", "in", "app/" });
    defer steps.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), steps.items.len);
    try testing.expectEqualStrings("app/", steps.items[0].add.path.?);
    try testing.expectEqual(@as(u8, 5), steps.items[1].add.entry.num);
    try testing.expectEqual(@as(?[]const u8, null), steps.items[1].add.path);
}

test "plan: pick 7 src/core in app/ keeps 7's own path and still scopes code rules" {
    var steps = try planOf(&.{ "7", "src/core", "in", "app/" });
    defer steps.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), steps.items.len);
    try testing.expectEqual(@as(u8, 7), steps.items[0].add.entry.num);
    try testing.expectEqualStrings("src/core", steps.items[0].add.path.?);

    var both = try planOf(&.{ "1", "7", "src/core", "in", "app/" });
    defer both.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), both.items.len);
    try testing.expectEqual(@as(u8, 1), both.items[0].add.entry.num);
    try testing.expectEqualStrings("app/", both.items[0].add.path.?);
    try testing.expectEqual(@as(u8, 7), both.items[1].add.entry.num);
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
