const std = @import("std");
const builtin = @import("builtin");
const tsserver = @import("emetgate").tsserver;
const fixture = @import("ts_fixture.zig");

const testing = std.testing;
const TsRepo = fixture.TsRepo;

const source = "export function add(a: number): number {\n  return a + 1;\n}\n";

fn session(repo: *TsRepo, timeout_ms: u64) tsserver.Session {
    return .{ .gpa = testing.allocator, .io = testing.io, .root = repo.root_abs, .options = .{ .timeout_ms = timeout_ms } };
}

fn askRename(repo: *TsRepo, s: *tsserver.Session, rel: []const u8, offset: u32) !tsserver.Parsed {
    const client = try s.get();
    const file = try repo.slashed(testing.allocator, rel);
    defer testing.allocator.free(file);
    return client.rename(file, offset);
}

test "tsserver: the language service starts on first use, answers and stays warm" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try TsRepo.init(&.{.{ .rel = "src/a.ts", .text = source }});
    defer repo.deinit();
    try repo.installStub();
    const locs = try fixture.locationsJson(testing.allocator, &repo, "rename", &.{.{ .rel = "src/a.ts", .needle = "function add", .name = "add" }});
    defer testing.allocator.free(locs);
    try repo.setPlan(locs);

    var s = session(&repo, 20_000);
    defer s.deinit();
    const client = try s.get();
    try testing.expectEqual(@as(usize, 0), client.starts);
    try testing.expect(!client.running());

    const first = try askRename(&repo, &s, "src/a.ts", 16);
    defer first.deinit();
    try testing.expect(first.value.can_rename);
    try testing.expectEqual(@as(usize, 1), first.value.locations.len);
    try testing.expectEqual(@as(u32, 16), first.value.locations[0].start);
    try testing.expectEqual(@as(u32, 19), first.value.locations[0].end);
    try testing.expectEqualStrings("0.0.0-stub", client.version.?);

    const second = try askRename(&repo, &s, "src/a.ts", 16);
    defer second.deinit();
    try testing.expectEqual(@as(usize, 1), client.starts);
    try testing.expect(client.running());
}

test "tsserver: a repo without node_modules/typescript is an explicit error, not a global fallback" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try TsRepo.init(&.{.{ .rel = "src/a.ts", .text = source }});
    defer repo.deinit();
    var s = session(&repo, 20_000);
    defer s.deinit();
    try testing.expectError(error.TypeScriptNotInstalled, askRename(&repo, &s, "src/a.ts", 16));
}

test "tsserver: a hung language service is killed at the timeout and restarted by the next request" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try TsRepo.init(&.{.{ .rel = "src/a.ts", .text = source }});
    defer repo.deinit();
    try repo.installStub();
    try repo.setPlan("{\"hang\":true}");
    var s = session(&repo, 2_000);
    defer s.deinit();
    try testing.expectError(error.LanguageServiceTimeout, askRename(&repo, &s, "src/a.ts", 16));
    const client = try s.get();
    try testing.expect(!client.running());

    try repo.setPlan("{\"echo\":3}");
    const answer = try askRename(&repo, &s, "src/a.ts", 16);
    defer answer.deinit();
    try testing.expectEqual(@as(usize, 2), client.starts);
    try testing.expectEqual(@as(u32, 16), answer.value.locations[0].start);
}

test "tsserver: a language service that exits mid-request is reported and restarted" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try TsRepo.init(&.{.{ .rel = "src/a.ts", .text = source }});
    defer repo.deinit();
    try repo.installStub();
    try repo.setPlan("{\"exit\":true}");
    var s = session(&repo, 20_000);
    defer s.deinit();
    try testing.expectError(error.LanguageServiceExited, askRename(&repo, &s, "src/a.ts", 16));
    try repo.setPlan("{\"echo\":3}");
    const answer = try askRename(&repo, &s, "src/a.ts", 16);
    defer answer.deinit();
    try testing.expectEqual(@as(usize, 2), (try s.get()).starts);
}

test "tsserver: the language service runs at low integrity and cannot write into the repo" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try TsRepo.init(&.{.{ .rel = "src/a.ts", .text = source }});
    defer repo.deinit();
    try repo.installStub();
    const target = try repo.slashed(testing.allocator, "src/planted.ts");
    defer testing.allocator.free(target);
    const plan = try std.fmt.allocPrint(testing.allocator, "{{\"write\":\"{s}\",\"echo\":3}}", .{target});
    defer testing.allocator.free(plan);
    try repo.setPlan(plan);
    var s = session(&repo, 20_000);
    defer s.deinit();
    const answer = try askRename(&repo, &s, "src/a.ts", 16);
    defer answer.deinit();
    try testing.expect(!repo.exists("src/planted.ts"));
}

test "tsserver: tsconfig plugins never reach the language service" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try TsRepo.init(&.{
        .{ .rel = "src/a.ts", .text = source },
        .{ .rel = "tsconfig.json", .text = "{\"compilerOptions\":{\"strict\":true,\"plugins\":[{\"name\":\"evil-plugin\"}]}}" },
    });
    defer repo.deinit();
    try repo.installStub();
    try repo.setPlan("{\"echo\":3}");
    var s = session(&repo, 20_000);
    defer s.deinit();
    const answer = try askRename(&repo, &s, "src/a.ts", 16);
    defer answer.deinit();
    try testing.expect(answer.value.can_rename);
}

test "tsserver: byte offsets survive the UTF-16 positions of the language service" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const text = "// \xc4\x9f\xf0\x9f\x98\x80 note\nexport function add(a: number): number {\n  return a + 1;\n}\n";
    var repo = try TsRepo.init(&.{.{ .rel = "src/a.ts", .text = text }});
    defer repo.deinit();
    try repo.installStub();
    try repo.setPlan("{\"echo\":3}");
    var s = session(&repo, 20_000);
    defer s.deinit();
    const offset = fixture.offsetOf(text, "function add", 0, "add");
    const answer = try askRename(&repo, &s, "src/a.ts", offset);
    defer answer.deinit();
    try testing.expectEqual(offset, answer.value.locations[0].start);
    try testing.expectEqual(offset + 3, answer.value.locations[0].end);
}

test "tsserver: the program is every tracked TypeScript and JavaScript file and nothing untracked" {
    var repo = try TsRepo.init(&.{
        .{ .rel = "src/a.ts", .text = source },
        .{ .rel = "src/b.js", .text = "module.exports = 1;\n" },
        .{ .rel = "README.md", .text = "# r\n" },
    });
    defer repo.deinit();
    try repo.installStub();
    const files = try tsserver.programFiles(testing.allocator, testing.io, repo.root_abs);
    defer tsserver.freeFiles(testing.allocator, files);
    try testing.expectEqual(@as(usize, 2), files.len);
    for (files) |f| try testing.expect(std.mem.indexOf(u8, f, "node_modules") == null);
}
