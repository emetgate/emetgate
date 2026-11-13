const std = @import("std");
const emetgate = @import("emetgate");
const rule_offer = emetgate.rule_offer;
const prompt_hook = emetgate.prompt_hook;

const testing = std.testing;
const Allocating = std.Io.Writer.Allocating;
const Suggestion = rule_offer.Suggestion;

fn expectPick(prompt: []const u8, num: u8, path: ?[]const u8) !void {
    errdefer std.debug.print("prompt: {s}\n", .{prompt});
    const got = rule_offer.detect(prompt) orelse return error.NotDetected;
    try testing.expect(got == .pick);
    try testing.expectEqual(num, got.pick.num);
    if (path) |want| try testing.expectEqualStrings(want, got.pick.path.?) else try testing.expect(got.pick.path == null);
}

fn expectAnyCheck(prompt: []const u8) !void {
    errdefer std.debug.print("prompt: {s}\n", .{prompt});
    const got = rule_offer.detect(prompt) orelse return error.NotDetected;
    try testing.expect(got == .any_check);
}

fn offerOf(prompt: []const u8) ![]u8 {
    var out: Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = try prompt_hook.offer(prompt, &out.writer);
    return testing.allocator.dupe(u8, out.written());
}

test "rule offer: Turkish lasting instructions map to the catalog rule" {
    try expectPick("bundan sonra yorum satırı ekleme", 19, null);
    try expectPick("Asla console.log kullanma.", 1, null);
    try expectPick("artık hiç debugger bırakma", 2, null);
    try expectPick("hiçbir zaman eval kullanmayın", 23, null);
    try expectPick("migrations klasörüne asla dokunma", 30, "migrations");
    try expectPick("her zaman fonksiyonlara yorum ekle", 20, null);
    try expectPick("şu hatayı düzelt. bundan sonra commit mesajına Co-authored-by yazma", 26, null);
    try expectAnyCheck("bundan sonra hep pnpm kullan");
    try expectAnyCheck("daima testleri çalıştır");
}

test "rule offer: English lasting instructions map to the catalog rule or a check" {
    try expectPick("from now on, don't add comments", 19, null);
    try expectPick("Never use console.log in this repo", 1, null);
    try expectPick("never touch the migrations folder", 30, "migrations");
    try expectPick("Please never edit src/generated", 30, "src/generated");
    try expectPick("do not ever write WIP in a commit message", 28, null);
    try expectPick("going forward, always use conventional commit subjects", 29, null);
    try expectAnyCheck("from now on use pnpm");
    try expectAnyCheck("always run the tests before you commit");

    const imported = rule_offer.detect("never import lodash").?;
    try testing.expectEqualStrings("lodash", imported.forbid_import);
    const forbidden = rule_offer.detect("don't ever use `moment` here").?;
    try testing.expectEqualStrings("moment", forbidden.forbid);
}

test "rule offer: questions, long prompts, slash lines and ordinary requests pass on silently" {
    var long: [700]u8 = undefined;
    @memset(&long, 'a');
    @memcpy(long[0..30], "never use console.log anywhere");
    const silent = [_][]const u8{
        "should we never use console.log?",
        "bundan sonra yorum ekleme mi",
        "asla console.log kullanmamalı mıyız",
        &long,
        "/rule add \"no console.log\" --check forbid:console.log --enforce",
        "/compact never use comments",
        "fix the failing test in src/app.ts",
        "add a comment to the parse function",
        "I never said that, just rename the variable",
        "never mind, revert it",
        "as always, run the build",
        "this is always failing on CI",
        "her zaman olduğu gibi testleri çalıştır",
        "bundan sonra testleri çalıştır",
        "bu fonksiyon her zaman null dönüyor",
        "her zaman haklısın",
        "",
    };
    for (silent) |prompt| {
        errdefer std.debug.print("prompt: {s}\n", .{prompt});
        try testing.expect(rule_offer.detect(prompt) == null);
        const said = try offerOf(prompt);
        defer testing.allocator.free(said);
        try testing.expectEqualStrings("", said);
    }
}

test "rule offer: the hook output is UserPromptSubmit additionalContext, plain ASCII, no decision" {
    const said = try offerOf("bundan sonra yorum satırı ekleme");
    defer testing.allocator.free(said);
    for (said) |c| try testing.expect(c < 0x80);
    try testing.expect(std.mem.endsWith(u8, said, "\n"));
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, said, .{});
    defer parsed.deinit();
    const top = parsed.value.object;
    try testing.expectEqual(@as(usize, 1), top.count());
    const specific = top.get("hookSpecificOutput").?.object;
    try testing.expectEqual(@as(usize, 2), specific.count());
    try testing.expectEqualStrings("UserPromptSubmit", specific.get("hookEventName").?.string);
    const context = specific.get("additionalContext").?.string;
    try testing.expectEqualStrings(
        "emetgate: the user stated a lasting instruction, which compaction will lose. After handling the request, offer once to make it an enforced emetgate rule the user types: /rule pick 19 (catalog rule 19, no new comments, check added:no_comment).",
        context,
    );
    try testing.expect(context.len < 400);
}

test "rule offer: the context names the exact line for each kind of suggestion" {
    const Case = struct { prompt: []const u8, needle: []const u8 };
    const cases = [_]Case{
        .{ .prompt = "never touch the migrations folder", .needle = "/rule pick 30 migrations (catalog rule 30, freeze a path, check frozen)." },
        .{ .prompt = "never import lodash", .needle = "/rule add \\\"no import of lodash\\\" --check forbid_import:lodash --enforce" },
        .{ .prompt = "don't ever use `moment` here", .needle = "/rule add \\\"no moment\\\" --check forbid:moment --enforce" },
        .{ .prompt = "from now on use pnpm", .needle = "show the line to type: /rule add \\\"<rule>\\\" --check <check> --enforce" },
    };
    for (cases) |case| {
        errdefer std.debug.print("prompt: {s}\n", .{case.prompt});
        const said = try offerOf(case.prompt);
        defer testing.allocator.free(said);
        try testing.expect(std.mem.indexOf(u8, said, case.needle) != null);
    }
}

test "rule offer: a /rule line still gets only the rule hook's answer" {
    var out: Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expect(!try prompt_hook.offer("/rule list never use console.log", &out.writer));
    try testing.expectEqualStrings("", out.written());
    try testing.expectEqualStrings(" list never use console.log", prompt_hook.argumentsOf("/rule list never use console.log").?);
}
