const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const prompt_hook = @import("emetgate").prompt_hook;
const prompt_words = @import("emetgate").prompt_words;
const rule_command = @import("emetgate").rule_command;

const testing = std.testing;
const Allocating = std.Io.Writer.Allocating;

const Repo = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,

    fn init() !Repo {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo");
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
        errdefer testing.allocator.free(root_abs);
        try git_fixture.initRepo(root_abs);
        return .{ .tmp = tmp, .root_abs = root_abs };
    }

    fn deinit(self: *Repo) void {
        testing.allocator.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn ledger(self: *Repo) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, "repo/.emetgate/ledger.ndjson", testing.allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => try testing.allocator.dupe(u8, ""),
            else => return err,
        };
    }

    fn expectLedgerUntouched(self: *Repo) !void {
        const bytes = try self.ledger();
        defer testing.allocator.free(bytes);
        try testing.expectEqualStrings("", bytes);
    }
};

const Reply = struct {
    raw: []u8,
    parsed: std.json.Parsed(std.json.Value),

    fn deinit(self: Reply) void {
        self.parsed.deinit();
        testing.allocator.free(self.raw);
    }

    fn reason(self: Reply) []const u8 {
        return self.parsed.value.object.get("reason").?.string;
    }

    fn has(self: Reply, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.reason(), needle) != null;
    }
};

fn replyTo(root: anyerror![]const u8, input: []const u8) !?Reply {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text = (try prompt_hook.ruleText(arena_state.allocator(), input)) orelse return null;
    var out: Allocating = .init(testing.allocator);
    defer out.deinit();
    try prompt_hook.respond(testing.allocator, testing.io, root, text, &out.writer);
    const raw = try testing.allocator.dupe(u8, out.written());
    errdefer testing.allocator.free(raw);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, raw, .{});
    errdefer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.object.count());
    try testing.expectEqualStrings("block", parsed.value.object.get("decision").?.string);
    return .{ .raw = raw, .parsed = parsed };
}

fn hookInput(prompt: []const u8) ![]u8 {
    var out: Allocating = .init(testing.allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try js.objectField("session_id");
    try js.write("19c2fecc-e0af-46cd-a76e-2f7a5f365593");
    try js.objectField("cwd");
    try js.write("C:\\work\\proj");
    try js.objectField("permission_mode");
    try js.write("auto");
    try js.objectField("hook_event_name");
    try js.write("UserPromptSubmit");
    try js.objectField("prompt");
    try js.write(prompt);
    try js.endObject();
    return out.toOwnedSlice();
}

fn say(repo: *Repo, prompt: []const u8) !Reply {
    const input = try hookInput(prompt);
    defer testing.allocator.free(input);
    return (try replyTo(repo.root_abs, input)) orelse error.PromptPassedOn;
}

fn idOf(reply: Reply) []const u8 {
    const said = reply.reason();
    const line = said[(std.mem.indexOfScalar(u8, said, '\n') orelse return said) + 1 ..];
    return line[0 .. std.mem.indexOfScalar(u8, line, ' ') orelse line.len];
}

fn listed(repo: *Repo) ![]u8 {
    var out: Allocating = .init(testing.allocator);
    defer out.deinit();
    var err_out: Allocating = .init(testing.allocator);
    defer err_out.deinit();
    try rule_command.run(testing.allocator, testing.io, repo.root_abs, .{ .list = .{} }, &out.writer, &err_out.writer);
    return testing.allocator.dupe(u8, out.written());
}

test "prompt words: quotes group, a single quote keeps everything, a double quote keeps a backslash" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Case = struct { text: []const u8, words: []const []const u8 };
    const cases = [_]Case{
        .{ .text = "", .words = &.{} },
        .{ .text = " \t\r\n", .words = &.{} },
        .{ .text = " add  \"no networkidle\"\t--check forbid:networkidle\n--enforce ", .words = &.{ "add", "no networkidle", "--check", "forbid:networkidle", "--enforce" } },
        .{ .text = "add \"\"", .words = &.{ "add", "" } },
        .{ .text = "add ''", .words = &.{ "add", "" } },
        .{ .text = "add \"it's\" 'say \"hi\"'", .words = &.{ "add", "it's", "say \"hi\"" } },
        .{ .text = "add \"say \\\"hi\\\"\"", .words = &.{ "add", "say \"hi\"" } },
        .{ .text = "--check \"cmd:scripts\\no-raw-sql.cmd\"", .words = &.{ "--check", "cmd:scripts\\no-raw-sql.cmd" } },
        .{ .text = "--check cmd:scripts\\lint.cmd", .words = &.{ "--check", "cmd:scripts\\lint.cmd" } },
        .{ .text = "--check 'q:((identifier) @violation (#eq? @violation \"eval\"))'", .words = &.{ "--check", "q:((identifier) @violation (#eq? @violation \"eval\"))" } },
        .{ .text = "a\"b c\"'d e'f", .words = &.{"ab cd ef"} },
        .{ .text = "add \"two\nlines\"", .words = &.{ "add", "two\nlines" } },
    };
    for (cases) |case| {
        errdefer std.debug.print("text: {s}\n", .{case.text});
        const words = try prompt_words.split(arena, case.text);
        try testing.expectEqual(case.words.len, words.len);
        for (case.words, words) |want, got| try testing.expectEqualStrings(want, got);
    }
}

test "prompt words: a quote that never closes is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.UnterminatedQuote, prompt_words.split(arena, "add \"open"));
    try testing.expectError(error.UnterminatedQuote, prompt_words.split(arena, "add 'open"));
    try testing.expectError(error.UnterminatedQuote, prompt_words.split(arena, "add \"open\\\""));
}

test "prompt hook: only a prompt that is the /rule command is taken" {
    try testing.expectEqualStrings("", prompt_hook.argumentsOf("/rule").?);
    try testing.expectEqualStrings(" list", prompt_hook.argumentsOf("/rule list").?);
    try testing.expectEqualStrings("\tlist", prompt_hook.argumentsOf("/rule\tlist").?);
    try testing.expectEqualStrings("\nlist", prompt_hook.argumentsOf("/rule\nlist").?);
    const passed_on = [_][]const u8{ "", "fix the bug", "/rules list", "/ruler", "/rule-add x", "rule list", "run /rule list", "/RULE list", "/emetgate:rule list" };
    for (passed_on) |prompt| try testing.expect(prompt_hook.argumentsOf(prompt) == null);
}

test "prompt hook: blanks, line breaks and one byte order mark before /rule are dropped and the line is taken" {
    const taken = [_][]const u8{ " /rule list", "\n/rule list", "\t/rule list", "\r\n/rule list", " \t\r\n /rule list", "\xef\xbb\xbf/rule list", "\xef\xbb\xbf \n/rule list", "\n \xef\xbb\xbf/rule list", " \xef\xbb\xbf\t/rule list" };
    for (taken) |prompt| {
        errdefer std.debug.print("handed on: {s}\n", .{prompt});
        try testing.expectEqualStrings(" list", prompt_hook.argumentsOf(prompt).?);
    }
    try testing.expectEqualStrings("", prompt_hook.argumentsOf("\n/rule").?);
    try testing.expectEqualStrings("\n", prompt_hook.argumentsOf(" /rule\n").?);
}

test "prompt hook: a line that only resembles /rule is handed on, whatever stands before it" {
    const passed_on = [_][]const u8{
        "/rules list",
        "/ruler",
        "/rule-add x",
        "rule list",
        "run /rule list",
        "/RULE list",
        "/emetgate:rule list",
        " /rules list",
        "\n/ruler",
        "\t/rule-add x",
        " rule list",
        "\n/RULE list",
        " /emetgate:rule list",
        "\x0b/rule list",
        "\xc2\xa0/rule list",
        "/rule\x0blist",
        "/rule\xc2\xa0list",
        "\x0c/rule list",
        "\xef\xbb\xbf\xef\xbb\xbf/rule list",
        "\xef\xbb/rule list",
        "\xef\xbb\xbf",
        " \n\t",
        "x /rule list",
    };
    for (passed_on) |prompt| {
        errdefer std.debug.print("taken: {s}\n", .{prompt});
        try testing.expect(prompt_hook.argumentsOf(prompt) == null);
    }
}

test "prompt hook: a /rule line typed after a blank or a line break is answered and reaches the ledger" {
    var repo = try Repo.init();
    defer repo.deinit();
    const input = try hookInput("\n /rule add \"no console\" --check forbid:console.log");
    defer testing.allocator.free(input);
    const reply = (try replyTo(repo.root_abs, input)).?;
    defer reply.deinit();
    const bytes = try repo.ledger();
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "no console") != null);
}

test "prompt hook: any other prompt gets no answer at all" {
    const prompts = [_][]const u8{ "add a rule that forbids networkidle", "/rules", "/help" };
    for (prompts) |prompt| {
        const input = try hookInput(prompt);
        defer testing.allocator.free(input);
        try testing.expect((try replyTo(error.NotAGitRepository, input)) == null);
    }
}

test "prompt hook: input that carries no prompt text is refused by name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const inputs = [_][]const u8{ "", "not json", "[]", "\"/rule list\"", "{}", "{\"prompt\":7}", "{\"prompt\":null}", "{\"user_prompt\":\"/rule list\"}", "{\"prompt\":\"/rule list\"" };
    for (inputs) |input| try testing.expectError(error.HookInputInvalid, prompt_hook.ruleText(arena, input));
}

test "prompt hook: /rule add adopts the rule and answers with its id" {
    var repo = try Repo.init();
    defer repo.deinit();

    const reply = try say(&repo, "/rule add \"no networkidle\" --check forbid:networkidle --enforce");
    defer reply.deinit();
    const id = idOf(reply);
    try testing.expectEqual(@as(usize, 17), id.len);
    try testing.expectEqual(@as(u8, 'm'), id[0]);
    const said = try std.fmt.allocPrint(testing.allocator, "rule added: no networkidle\n{s}  enforce  forbid:networkidle  whole repository", .{id});
    defer testing.allocator.free(said);
    try testing.expectEqualStrings(said, reply.reason());
    try testing.expectEqual(@as(u8, '\n'), reply.raw[reply.raw.len - 1]);

    const rows = try listed(&repo);
    defer testing.allocator.free(rows);
    const row = try std.fmt.allocPrint(testing.allocator, "{s}\tactive\tenforce\tforbid:networkidle\t-\tno networkidle\n", .{id});
    defer testing.allocator.free(row);
    try testing.expectEqualStrings(row, rows);
}

test "prompt hook: /rule list answers with the rows emetgate rule list prints" {
    var repo = try Repo.init();
    defer repo.deinit();

    const added = try say(&repo, "/rule add 'prefer explicit waits'");
    defer added.deinit();
    const reply = try say(&repo, "/rule list");
    defer reply.deinit();
    const id = idOf(added);
    const want = try std.fmt.allocPrint(
        testing.allocator,
        "id                 state   mode      check     where             rule\n{s}  active  advisory  no check  whole repository  prefer explicit waits",
        .{id},
    );
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, reply.reason());
    const rows = try listed(&repo);
    defer testing.allocator.free(rows);
    try testing.expect(std.mem.startsWith(u8, rows, id));
}

test "prompt hook: /rule forget removes the rule, and a command that prints nothing still answers" {
    var repo = try Repo.init();
    defer repo.deinit();

    const empty = try say(&repo, "/rule list");
    defer empty.deinit();
    try testing.expectEqualStrings("no rules", empty.reason());

    const added = try say(&repo, "/rule add \"no networkidle\" --check forbid:networkidle --enforce");
    defer added.deinit();
    const prompt = try std.fmt.allocPrint(testing.allocator, "/rule forget {s}", .{idOf(added)});
    defer testing.allocator.free(prompt);
    const forgotten = try say(&repo, prompt);
    defer forgotten.deinit();
    const said = try std.fmt.allocPrint(testing.allocator, "rule forgotten: {s}", .{idOf(added)});
    defer testing.allocator.free(said);
    try testing.expectEqualStrings(said, forgotten.reason());

    const rows = try listed(&repo);
    defer testing.allocator.free(rows);
    try testing.expectEqualStrings("", rows);
}

test "prompt hook: a /rule that prints nothing still answers ok" {
    var repo = try Repo.init();
    defer repo.deinit();

    const empty = try say(&repo, "/rule list --json");
    defer empty.deinit();
    try testing.expectEqualStrings("ok", empty.reason());
}

const turkish = "\u{11f}\u{fc}\u{15f}\u{131}\u{f6}\u{e7} \u{130}\u{11e}\u{dc}\u{15e}\u{d6}\u{c7}";

test "prompt hook: quotes and Turkish letters reach the ledger byte for byte and the answer is plain ASCII" {
    var repo = try Repo.init();
    defer repo.deinit();

    const text = turkish ++ " 'tek' \"\u{e7}ift\"";
    const check = "forbid:\"\u{15f}\u{131}k\"";
    const added = try say(&repo, "/rule add \"" ++ turkish ++ " 'tek' \\\"\u{e7}ift\\\"\" --check 'forbid:\"\u{15f}\u{131}k\"' --enforce");
    defer added.deinit();
    try testing.expectEqual(@as(usize, 17), idOf(added).len);
    for (added.raw) |byte| try testing.expect(byte < 0x80);

    const reply = try say(&repo, "/rule list");
    defer reply.deinit();
    for (reply.raw) |byte| try testing.expect(byte < 0x80);
    const row = try std.fmt.allocPrint(testing.allocator, "{s}  active  enforce  {s}  whole repository  {s}", .{ idOf(added), check, text });
    defer testing.allocator.free(row);
    try testing.expect(std.mem.endsWith(u8, reply.reason(), row));
    try testing.expect(std.mem.startsWith(u8, reply.reason(), "id "));

    const escaped = "{\"prompt\":\"/rule add \\\"\\u011f\\u00fc\\u015f\\\"\"}";
    const again = (try replyTo(repo.root_abs, escaped)).?;
    defer again.deinit();
    const rows = try listed(&repo);
    defer testing.allocator.free(rows);
    try testing.expect(std.mem.indexOf(u8, rows, "\t\u{11f}\u{fc}\u{15f}\n") != null);
}

test "prompt hook: a refused rule answers with the error name and the names that exist, and writes nothing" {
    var repo = try Repo.init();
    defer repo.deinit();

    const typo = try say(&repo, "/rule add typo --check frbid:x --enforce");
    defer typo.deinit();
    try testing.expectEqualStrings("no_comment forbid no_literal q frozen cmd: added: message:forbid message:forbid_any_case message:require message:require_any_case message:max_lines message:max_subject message:max_line\nerror: UnknownCheck", typo.reason());

    const unchecked = try say(&repo, "/rule add \"no networkidle\" --enforce");
    defer unchecked.deinit();
    try testing.expectEqualStrings("error: EnforceWithoutCheck", unchecked.reason());

    const query = try say(&repo, "/rule add typo --check 'q:(no_such_node) @violation' --enforce");
    defer query.deinit();
    try testing.expect(query.has("does not compile for typescript"));
    try testing.expect(std.mem.endsWith(u8, query.reason(), "\nerror: QueryNodeType"));
    try repo.expectLedgerUntouched();

    const added = try say(&repo, "/rule add 'prefer explicit waits'");
    defer added.deinit();
    const unknown = try say(&repo, "/rule forget mdeadbeefdeadbeef");
    defer unknown.deinit();
    const want = try std.fmt.allocPrint(
        testing.allocator,
        "id                 state   mode      check     where             rule\n{s}  active  advisory  no check  whole repository  prefer explicit waits\nerror: DecisionNotActive",
        .{idOf(added)},
    );
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, unknown.reason());
}

test "prompt hook: a /rule the grammar does not define answers with the usage and writes nothing" {
    var repo = try Repo.init();
    defer repo.deinit();

    const usage = "/rule add <text> [--check <spec>] [--in <where>] [--enforce]\n/rule list [--all] [--json]\n/rule supersede <id> <text> [--check <spec>] [--in <where>] [--enforce]\n/rule forget <id>";
    const prompts = [_][]const u8{ "/rule", "/rule adopt x", "/rule add", "/rule add \"open", "/rule add t --check", "/rule forget a b", "/rule add no networkidle" };
    for (prompts) |prompt| {
        errdefer std.debug.print("prompt: {s}\n", .{prompt});
        const reply = try say(&repo, prompt);
        defer reply.deinit();
        try testing.expectEqualStrings(usage, reply.reason());
    }
    try repo.expectLedgerUntouched();
}

test "prompt hook: outside a repository a /rule prompt is still stopped, with the error as the answer" {
    const input = try hookInput("/rule add \"no networkidle\"");
    defer testing.allocator.free(input);
    const reply = (try replyTo(error.NotAGitRepository, input)).?;
    defer reply.deinit();
    try testing.expectEqualStrings("error: NotAGitRepository", reply.reason());
}
