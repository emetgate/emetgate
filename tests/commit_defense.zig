const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const fixture = @import("ts_fixture.zig");
const support = @import("runner_support.zig");
const common = @import("commit_batch.zig");

const symbol = emetgate.symbol;
const disk = emetgate.disk;
const runner = emetgate.runner;
const shadow = emetgate.shadow;
const shadow_root = emetgate.shadow_root;
const commit_plan = emetgate.commit_plan;
const commit_store = emetgate.commit_store;
const verify_run = emetgate.verify_run;
const jcs = emetgate.jcs;
const Verdict = emetgate.checker.Verdict;

const testing = std.testing;
const Plain = common.Plain;
const Env = common.Env;
const Reply = common.Reply;

const util_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const new_body = "{\n  return b + a;\n}";
const other_body = "{\n  return b + a + 0;\n}";
const mark = "b + a";
const message = "fix: swap";
const notes_src = "# Notes\n\n## Setup\n\nold\n\n## Other\n\nkept\n";
const setup_old = "## Setup\n\nold\n\n";
const setup_new = "## Setup\n\nnew\n\n";
const flag_old = "export const flag = 'aaaa';\n";
const flag_new = "export const flag = 'bbbb';\n";
const util_file: fixture.File = .{ .rel = "src/util.ts", .text = util_src };
const flag_file: fixture.File = .{ .rel = "src/flag.ts", .text = flag_old };
const notes_file: fixture.File = .{ .rel = "notes.md", .text = notes_src };
const text_file: fixture.File = .{ .rel = "f.txt", .text = "a\nb\n" };
const ignore: fixture.File = .{ .rel = ".gitignore", .text = ".emetgate/\n" };
const files = [_]fixture.File{ util_file, flag_file, notes_file, text_file, ignore };

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn swap(env: *Env, body: []const u8, test_command: []const u8) !Reply {
    return env.call("emetgate_try", .{ .file = try env.abs("src/util.ts"), .symbol = "add", .hash = try env.hashOf("src/util.ts", "add"), .body = body, .message = message }, test_command, true);
}

fn expectLanded(env: *Env, reply: Reply, before: []const u8) !void {
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings(before, try env.git(&.{ "rev-parse", "HEAD^" }));
}

fn expectRefused(env: *Env, reply: Reply, before: []const u8, name: []const u8) !void {
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(contains(reply.text, name));
    try testing.expectEqualStrings(before, try env.head());
}

fn byHand(env: *Env, subject: []const u8) !void {
    _ = try env.git(&.{ "add", "-A" });
    _ = try env.git(&.{ "commit", "-q", "-m", subject });
}

fn verdictOf(case: *Plain) !Verdict {
    const result = try verify_run.run(testing.allocator, case.env.arena(), testing.io, case.runtime, case.repo.root_abs, .{ .commit = "HEAD", .test_command = common.green });
    return result.report.verdict;
}

fn hasNote(env: *Env) bool {
    _ = env.git(&.{ "notes", "--ref=emetgate", "show", "HEAD" }) catch return false;
    return true;
}

fn existsAbs(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(testing.io, path, .{}) catch return false;
    return true;
}

fn docHash(env: *Env, text: []const u8) ![]const u8 {
    return env.arena().dupe(u8, &symbol.formatHash(symbol.hashOf(text)));
}

fn script(case: *Plain, name: []const u8, text: []const u8) ![]const u8 {
    const env = &case.env;
    const rel = try std.fmt.allocPrint(env.arena(), ".git/{s}", .{name});
    try case.repo.write(rel, text);
    const abs = try env.arena().dupe(u8, try env.abs(rel));
    std.mem.replaceScalar(u8, abs, '\\', '/');
    return std.fmt.allocPrint(env.arena(), "sh \"{s}\"", .{abs});
}

fn lineCount(case: *Plain, rel: []const u8) usize {
    const text = case.repo.read(rel) catch return 0;
    defer testing.allocator.free(text);
    return std.mem.count(u8, text, "\n");
}

test "commit defense: a committing batch of doc edits only is one commit with no receipt, and verify calls it unverified" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    const reply = try env.call("emetgate_try_batch", .{
        .edits = .{.{ .file = try env.abs("notes.md"), .kind = "doc", .heading = "Setup", .hash = try docHash(env, setup_old), .content = setup_new }},
        .message = message,
    }, common.green, true);
    try expectLanded(env, reply, before);
    try testing.expectEqualStrings("M\tnotes.md", try env.git(&.{ "diff", "--name-status", "HEAD^", "HEAD" }));
    try testing.expectEqualStrings("", try env.git(&.{ "status", "--porcelain" }));
    try testing.expect(!hasNote(env));
    try testing.expect(!contains(reply.text, "receipt_attach_error"));
    try testing.expectEqual(Verdict.unverified, try verdictOf(&case));
}

test "commit defense: a committing write_doc is one commit with no receipt, and verify calls it unverified" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    const reply = try env.call("emetgate_write_doc", .{ .file = try env.abs("notes.md"), .heading = "Setup", .hash = try docHash(env, setup_old), .content = setup_new, .message = message }, common.green, true);
    try expectLanded(env, reply, before);
    try testing.expectEqualStrings("M\tnotes.md", try env.git(&.{ "diff", "--name-status", "HEAD^", "HEAD" }));
    try testing.expect(!hasNote(env));
    try testing.expectEqual(Verdict.unverified, try verdictOf(&case));
}

test "commit defense: a file of the store in another line end form that git stores as the same blob is committed as HEAD has it" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    _ = try env.git(&.{ "config", "core.autocrlf", "true" });
    const before = try env.head();
    const blob = try env.git(&.{ "rev-parse", "HEAD:f.txt" });
    try expectRefused(env, try swap(env, new_body, common.red), before, "rejected");

    const location = try shadow_root.locate(testing.allocator, case.repo.root_abs, null);
    defer location.deinit(testing.allocator);
    const stored = try std.fs.path.join(env.arena(), &.{ location.committed, commit_store.tree_name, "f.txt" });
    try testing.expectEqualStrings("a\r\nb\r\n", try std.Io.Dir.cwd().readFileAlloc(testing.io, stored, env.arena(), .limited(64)));
    var file = try std.Io.Dir.cwd().openFile(testing.io, stored, .{ .mode = .read_write });
    try file.setLength(testing.io, 0);
    try file.writePositionalAll(testing.io, "a\nb\n", 0);
    file.close(testing.io);

    try expectLanded(env, try swap(env, new_body, "for %I in (f.txt) do if not %~zI==4 exit 1"), before);
    try testing.expectEqualStrings(blob, try env.git(&.{ "rev-parse", "HEAD:f.txt" }));
    try testing.expectEqualStrings("M\tsrc/util.ts", try env.git(&.{ "diff", "--name-status", "HEAD^", "HEAD" }));
}

test "commit defense: with core.safecrlf on, a file whose line ends git refuses to convert is refused before the test runs and nothing is written" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    _ = try env.git(&.{ "config", "core.autocrlf", "true" });
    _ = try env.git(&.{ "config", "core.safecrlf", "true" });
    const before = try env.head();
    try expectRefused(env, try swap(env, new_body, common.green), before, "GitFailed");
    try testing.expectEqualStrings(util_src, try env.read("src/util.ts"));
    try testing.expectEqualStrings("", try env.git(&.{ "status", "--porcelain" }));

    _ = try env.git(&.{ "config", "core.safecrlf", "false" });
    try expectLanded(env, try swap(env, new_body, common.green), before);
}

test "commit defense: an encoding that an included configuration file brings in shapes the tested file, and the commit keeps the stored blob" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    _ = try env.git(&.{ "config", "core.autocrlf", "false" });
    try case.repo.write(".git/extra-attributes", "*.txt working-tree-encoding=UTF-16LE\n");
    const attributes = try env.arena().dupe(u8, try env.abs(".git/extra-attributes"));
    std.mem.replaceScalar(u8, attributes, '\\', '/');
    try case.repo.write(".git/extra-config", try std.fmt.allocPrint(env.arena(), "[core]\n\tattributesFile = {s}\n", .{attributes}));
    _ = try env.git(&.{ "config", "include.path", "extra-config" });
    const before = try env.head();
    const blob = try env.git(&.{ "rev-parse", "HEAD:f.txt" });
    try expectLanded(env, try swap(env, new_body, "for %I in (f.txt) do if not %~zI==8 exit 1"), before);
    try testing.expectEqualStrings(blob, try env.git(&.{ "rev-parse", "HEAD:f.txt" }));
    try testing.expectEqualStrings("M\tsrc/util.ts", try env.git(&.{ "diff", "--name-status", "HEAD^", "HEAD" }));
}

extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) std.os.windows.BOOL;

test "commit defense: with GIT_ATTR_SOURCE set for the server, a call still lands and changes only its own file" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    _ = try env.git(&.{ "config", "core.autocrlf", "false" });
    try case.repo.write(".gitattributes", "*.txt text eol=crlf\n");
    try byHand(env, "user: attributes");
    const with_rule = try env.head();
    try case.repo.write(".gitattributes", "*.txt -text\n");
    try byHand(env, "user: other attributes");
    const before = try env.head();
    const blob = try env.git(&.{ "rev-parse", "HEAD:f.txt" });

    var wide: [80:0]u16 = undefined;
    const len = try std.unicode.utf8ToUtf16Le(&wide, with_rule);
    wide[len] = 0;
    const name = std.unicode.utf8ToUtf16LeStringLiteral("GIT_ATTR_SOURCE");
    try testing.expect(SetEnvironmentVariableW(name, &wide) != .FALSE);
    const outcome = swap(env, new_body, "for %I in (f.txt) do if not %~zI==4 exit 1");
    _ = SetEnvironmentVariableW(name, null);
    try expectLanded(env, try outcome, before);
    try testing.expectEqualStrings(blob, try env.git(&.{ "rev-parse", "HEAD:f.txt" }));
    try testing.expectEqualStrings("M\tsrc/util.ts", try env.git(&.{ "diff", "--name-status", "HEAD^", "HEAD" }));
}

test "commit defense: a filter the tree names and the configuration does not define runs nothing and changes no blob" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    _ = try env.git(&.{ "config", "core.autocrlf", "false" });
    try case.repo.write(".gitattributes", "*.ts filter=fromtree\n*.txt filter=fromtree\n");
    try byHand(env, "user: a filter name with no driver");
    const before = try env.head();
    const blob = try env.git(&.{ "rev-parse", "HEAD:f.txt" });
    try expectLanded(env, try swap(env, new_body, "for %I in (f.txt) do if not %~zI==4 exit 1"), before);
    try testing.expectEqualStrings(blob, try env.git(&.{ "rev-parse", "HEAD:f.txt" }));
    try testing.expect(contains(try env.git(&.{ "show", "HEAD:src/util.ts" }), mark));
}

test "commit defense: a configured filter runs with the user's rights: its smudge once when the store is built, its clean on every committing call" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    _ = try env.git(&.{ "config", "core.autocrlf", "false" });
    try case.repo.write(".gitattributes", "*.txt filter=tap\n");
    try byHand(env, "user: a filter on one file");
    const logs = try env.arena().dupe(u8, try env.abs(".git"));
    std.mem.replaceScalar(u8, logs, '\\', '/');
    _ = try env.git(&.{ "config", "filter.tap.smudge", try script(&case, "tap-smudge.sh", try std.fmt.allocPrint(env.arena(), "echo smudge >> \"{s}/tap-smudge.log\"\ncat\n", .{logs})) });
    _ = try env.git(&.{ "config", "filter.tap.clean", try script(&case, "tap-clean.sh", try std.fmt.allocPrint(env.arena(), "echo clean >> \"{s}/tap-clean.log\"\ncat\n", .{logs})) });
    const before = try env.head();

    try expectRefused(env, try swap(env, new_body, common.red), before, "rejected");
    try testing.expectEqual(@as(usize, 1), lineCount(&case, ".git/tap-smudge.log"));
    const cleaned = lineCount(&case, ".git/tap-clean.log");
    try testing.expect(cleaned >= 1);

    try expectRefused(env, try swap(env, new_body, common.red), before, "rejected");
    try testing.expectEqual(@as(usize, 1), lineCount(&case, ".git/tap-smudge.log"));
    try testing.expectEqual(cleaned + 1, lineCount(&case, ".git/tap-clean.log"));
    try expectLanded(env, try swap(env, new_body, common.green), before);
}

test "commit defense: a clean filter that fails refuses the call before the test runs and names the file git could not store" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    _ = try env.git(&.{ "config", "core.autocrlf", "false" });
    try case.repo.write(".gitattributes", "*.txt filter=broken\n");
    try byHand(env, "user: a filter on one file");
    _ = try env.git(&.{ "config", "filter.broken.smudge", "cat" });
    _ = try env.git(&.{ "config", "filter.broken.clean", try script(&case, "broken-clean.sh", "exit 1\n") });
    _ = try env.git(&.{ "config", "filter.broken.required", "true" });
    const before = try env.head();
    const reply = try swap(env, new_body, common.green);
    try expectRefused(env, reply, before, "\"error\":\"GateTreeNotHead\"");
    try testing.expect(contains(reply.text, "\"paths\":[\"f.txt\"]"));
    try testing.expectEqualStrings(util_src, try env.read("src/util.ts"));
}

test "commit defense: a record whose branch and paths read like options for git changes no ref and writes no file" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try case.repo.write("src/flag.ts", flag_new);
    try byHand(env, "user: bbbb");
    const head = try env.head();
    const base = try env.git(&.{ "rev-parse", "HEAD^" });
    const refs = try env.git(&.{ "for-each-ref" });
    const shapes = [_][]const u8{
        "{{\"version\":1,\"commit\":\"{s}\",\"base\":\"{s}\",\"branch\":\"refs/heads/--output=owned.txt\",\"lock\":\"{s}\",\"items\":[{{\"path\":\"--output=owned.txt\",\"mode\":\"100644\"}},{{\"path\":\"-rf\",\"mode\":\"100644\"}}]}}",
        "{{\"version\":1,\"commit\":\"{s}\",\"base\":\"{s}\",\"branch\":\"--upload-pack=owned.txt\",\"lock\":\"{s}\",\"items\":[]}}",
        "{{\"version\":1,\"commit\":\"{s}\",\"base\":\"{s}\",\"branch\":\"refs/heads/main\",\"lock\":\"{s}\",\"items\":[{{\"path\":\"../owned.txt\",\"mode\":\"100644\"}}]}}",
        "{{\"version\":1,\"commit\":\"{s}\",\"base\":\"{s}\",\"branch\":\"refs/heads/main\",\"lock\":\"{s}\",\"items\":[{{\"path\":\"src/flag.ts\",\"mode\":\"--help\",\"blob\":\"--output=owned.txt\"}}]}}",
    };
    inline for (shapes) |shape| {
        try case.repo.write(".emetgate/intents/0123456789abcdef.json", try std.fmt.allocPrint(env.arena(), shape, .{ head, base, "00" ** 32 }));
        const report = try disk.recover(testing.allocator, testing.io, case.repo.root_abs);
        try testing.expectEqual(@as(usize, 0), report.commits.written);
        try testing.expect(!case.repo.exists("owned.txt"));
        try testing.expect(!case.repo.exists("src/owned.txt"));
        try testing.expect(!case.repo.exists("-rf"));
        try testing.expect(!case.repo.exists("--output=owned.txt"));
        try testing.expectEqualStrings(refs, try env.git(&.{ "for-each-ref" }));
        try testing.expectEqualStrings(head, try env.head());
        try testing.expectEqualStrings(flag_new, try env.read("src/flag.ts"));
        try testing.expectEqualStrings("", try env.git(&.{ "status", "--porcelain" }));
    }
}

test "commit defense: verify in a sparse checkout answers for the commit and leaves the sparse settings, the index and the working tree as they were" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ util_file, flag_file, ignore, .{ .rel = "lib/far.ts", .text = "export const far = 1;\n" } });
    defer case.deinit();
    const env = &case.env;
    _ = try env.git(&.{ "sparse-checkout", "init", "--cone" });
    _ = try env.git(&.{ "sparse-checkout", "set", "src" });
    try testing.expect(!case.repo.exists("lib/far.ts"));
    const before = try env.head();
    try expectLanded(env, try swap(env, new_body, common.green), before);

    const pattern = try env.read(".git/info/sparse-checkout");
    const flags = try env.git(&.{ "ls-files", "-t" });
    const config = try env.read(".git/config");
    const index = try env.read(".git/index");
    try testing.expect(contains(flags, "S lib/far.ts"));

    try testing.expectEqual(Verdict.verified, try verdictOf(&case));
    try testing.expectEqualStrings(pattern, try env.read(".git/info/sparse-checkout"));
    try testing.expectEqualStrings(config, try env.read(".git/config"));
    try testing.expectEqualSlices(u8, index, try env.read(".git/index"));
    try testing.expectEqualStrings(flags, try env.git(&.{ "ls-files", "-t" }));
    try testing.expect(!case.repo.exists("lib/far.ts"));
    try testing.expectEqualStrings("", try env.git(&.{ "status", "--porcelain" }));
}

fn setForm(case: *Plain, form: ?[]const u8) !void {
    const env = &case.env;
    const arena = env.arena();
    const parsed = try jcs.parse(arena, try env.git(&.{ "notes", "--ref=emetgate", "show", "HEAD" }));
    for (parsed.value.array.items) |*item| {
        const predicate = item.object.getPtr("predicate").?;
        _ = predicate.object.orderedRemove("form");
        if (form) |name| try predicate.object.put(arena, "form", .{ .string = name });
    }
    try case.repo.write(".git/note-edit", try jcs.canonicalize(arena, parsed.value));
    _ = try env.git(&.{ "notes", "--ref=emetgate", "add", "-f", "-F", ".git/note-edit", "HEAD" });
}

const wrapped = "@@@ wrapped {{{";

test "commit defense: for a file a filter stores in another form, a receipt whose form field is taken away or renamed no longer verifies" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ util_file, ignore });
    defer case.deinit();
    const env = &case.env;
    _ = try env.git(&.{ "config", "filter.wrap.clean", try script(&case, "wrap-clean.sh", "printf '%s\\n' '" ++ wrapped ++ "'\nsed 's/ + 0//'\n") });
    _ = try env.git(&.{ "config", "filter.wrap.smudge", try script(&case, "wrap-smudge.sh", "tail -n +2\n") });
    _ = try env.git(&.{ "config", "filter.wrap.required", "true" });
    try case.repo.write(".gitattributes", "*.ts filter=wrap -text\n");
    _ = try env.git(&.{ "add", ".gitattributes" });
    _ = try env.git(&.{ "add", "--renormalize", "." });
    _ = try env.git(&.{ "commit", "-q", "-m", "store wrapped" });
    const before = try env.head();
    try expectLanded(env, try swap(env, other_body, common.green), before);
    try testing.expect(contains(try env.git(&.{ "cat-file", "blob", "HEAD:src/util.ts" }), wrapped));
    try testing.expectEqual(Verdict.verified, try verdictOf(&case));

    try setForm(&case, null);
    try testing.expect(try verdictOf(&case) != .verified);
    try setForm(&case, "checked_out");
    try testing.expect(try verdictOf(&case) != .verified);
    try setForm(&case, "stored");
    try testing.expectEqual(Verdict.verified, try verdictOf(&case));
}

const AtStep = struct {
    case: *Plain,
    at: usize,
    seen: usize = 0,
    rel: []const u8,
    data: []const u8,
    wrote: ?bool = null,

    fn reached(context: *anyopaque) bool {
        const self: *AtStep = @ptrCast(@alignCast(context));
        self.seen += 1;
        if (self.seen != self.at) return false;
        if (self.case.repo.write(self.rel, self.data)) |_| {
            self.wrote = true;
        } else |_| {
            self.wrote = false;
        }
        return false;
    }
};

const after_index_published = 5;

test "commit defense: between the index being published and the file being written the target cannot be written by anyone else" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    var hand: AtStep = .{ .case = &case, .at = after_index_published, .rel = "src/util.ts", .data = "export const by = 'hand';\n" };
    const step: disk.Step = .{ .context = &hand, .reached = AtStep.reached };
    var plan: commit_plan.Request = .{ .message = message };
    defer plan.deinit(testing.allocator);
    const file = try env.abs("src/util.ts");
    const result = try runner.tryMutate(testing.allocator, testing.io, case.runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = .{ .present = try support.hashOfRef(testing.allocator, testing.io, case.runtime, file, "add") },
        .new_body = new_body,
        .test_command = common.green,
        .commit = &plan,
        .commit_step = &step,
    });
    result.deinit(testing.allocator);
    try testing.expectEqual(@as(?bool, false), hand.wrote);
    try testing.expectEqualStrings(before, try env.git(&.{ "rev-parse", "HEAD^" }));
    try testing.expect(plan.unfinished == null);
    try testing.expect(contains(try env.read("src/util.ts"), mark));
    try testing.expectEqualStrings("", try env.git(&.{ "status", "--porcelain" }));
}

test "commit defense: a file that appears at a new path between the index being published and the write is kept, the commit stands and the path is named" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    const by_hand = "export const fresh = 'by hand';\n";
    var hand: AtStep = .{ .case = &case, .at = after_index_published, .rel = "src/fresh.ts", .data = by_hand };
    const step: disk.Step = .{ .context = &hand, .reached = AtStep.reached };
    var plan: commit_plan.Request = .{ .message = message };
    defer plan.deinit(testing.allocator);
    const result = try runner.tryMutate(testing.allocator, testing.io, case.runtime, .{
        .file_abs = try env.abs("src/fresh.ts"),
        .ref_text = "fresh",
        .expected_hash = .absent,
        .new_body = "export function fresh(): number {\n  return 1;\n}\n",
        .test_command = common.green,
        .commit = &plan,
        .commit_step = &step,
    });
    result.deinit(testing.allocator);
    try testing.expectEqual(@as(?bool, true), hand.wrote);
    try testing.expectEqualStrings(before, try env.git(&.{ "rev-parse", "HEAD^" }));
    try testing.expect(contains(try env.git(&.{ "show", "HEAD:src/fresh.ts" }), "return 1;"));
    try testing.expectEqualStrings(by_hand, try env.read("src/fresh.ts"));
    try testing.expectEqualStrings("TargetChangedAfterCommit", plan.unfinished.?);
    try testing.expectEqualStrings("src/fresh.ts", plan.left_names[0..plan.left_names_len]);
    try testing.expectEqualStrings("M src/fresh.ts", try env.git(&.{ "status", "--porcelain" }));
}

var swap_victim: []const u8 = "";
var swap_sub: []const u8 = "";
var swap_moved: ?bool = null;

fn swapTree(tree_abs: []const u8) void {
    var from_buf: [std.fs.max_path_bytes]u8 = undefined;
    var to_buf: [std.fs.max_path_bytes]u8 = undefined;
    const from = if (swap_sub.len == 0) tree_abs else std.fmt.bufPrint(&from_buf, "{s}\\{s}", .{ tree_abs, swap_sub }) catch return;
    const to = std.fmt.bufPrint(&to_buf, "{s}.aside", .{tree_abs}) catch return;
    std.Io.Dir.renameAbsolute(from, to, testing.io) catch {
        swap_moved = false;
        return;
    };
    swap_moved = true;
    shadow.createJunction(testing.io, from, swap_victim) catch {};
}

test "commit defense: the directory the store keeps its files in cannot be moved away and replaced by a link between the link check and the checkout" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try testing.expect((try swap(env, new_body, common.red)).is_error);
    try case.repo.write("src/flag.ts", flag_new);
    try byHand(env, "user: bbbb");
    const before = try env.head();

    swap_victim = try env.abs(".git/victim");
    try std.Io.Dir.cwd().createDirPath(testing.io, swap_victim);
    swap_sub = "";
    swap_moved = null;
    commit_store.probe.before_checkout = swapTree;
    const outcome = swap(env, new_body, "findstr bbbb src\\flag.ts");
    commit_store.probe.before_checkout = null;
    try testing.expectEqual(@as(?bool, false), swap_moved);
    try expectLanded(env, try outcome, before);
    try testing.expect(!existsAbs(try std.fs.path.join(env.arena(), &.{ swap_victim, "src" })));
}

test "commit defense: the directory of the store cannot be moved away and replaced by a link while a rewritten file is checked out again" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    try testing.expect((try swap(env, new_body, common.red)).is_error);
    const location = try shadow_root.locate(testing.allocator, case.repo.root_abs, null);
    defer location.deinit(testing.allocator);
    const stored = try std.fs.path.join(env.arena(), &.{ location.committed, commit_store.tree_name, "src", "flag.ts" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = stored, .data = "export const flag = 'rewritten';\n" });

    swap_victim = try env.abs(".git/victim");
    try std.Io.Dir.cwd().createDirPath(testing.io, swap_victim);
    swap_sub = "";
    swap_moved = null;
    commit_store.probe.before_checkout = swapTree;
    const outcome = swap(env, new_body, common.green);
    commit_store.probe.before_checkout = null;
    try testing.expectEqual(@as(?bool, false), swap_moved);
    try expectRefused(env, try outcome, before, "GateTreeNotHead");
    try testing.expect(!existsAbs(try std.fs.path.join(env.arena(), &.{ swap_victim, "src" })));
    try expectLanded(env, try swap(env, new_body, "findstr aaaa src\\flag.ts"), before);
}

test "commit defense: a junction that stands inside the store where a changed file belongs is refused, and nothing is deleted or written where it points" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try testing.expect((try swap(env, new_body, common.red)).is_error);
    const location = try shadow_root.locate(testing.allocator, case.repo.root_abs, null);
    defer location.deinit(testing.allocator);

    const victim = try env.abs(".git/victim");
    try std.Io.Dir.cwd().createDirPath(testing.io, victim);
    try case.repo.write(".git/victim/flag.ts", "the user's own file\n");
    const inside = try std.fs.path.join(env.arena(), &.{ location.committed, commit_store.tree_name, "src" });
    const aside = try std.fs.path.join(env.arena(), &.{ location.committed, "src.aside" });
    try std.Io.Dir.renameAbsolute(inside, aside, testing.io);
    try shadow.createJunction(testing.io, inside, victim);
    defer std.Io.Dir.cwd().deleteDir(testing.io, inside) catch {};

    try case.repo.write("src/flag.ts", flag_new);
    try case.repo.write("src/extra.ts", "export const extra = 1;\n");
    try byHand(env, "user: bbbb and one more file");
    const before = try env.head();
    const reply = try swap(env, new_body, common.green);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(contains(reply.text, "WorkspaceIsLink"));
    try testing.expectEqualStrings(before, try env.head());
    try testing.expectEqualStrings("the user's own file\n", try env.read(".git/victim/flag.ts"));
    try testing.expect(!case.repo.exists(".git/victim/extra.ts"));
    try testing.expect(!case.repo.exists(".git/victim/util.ts"));
}

var planted_victim: []const u8 = "";
var planted: bool = false;

fn plantJunction(tree_abs: []const u8) void {
    var inside_buf: [std.fs.max_path_bytes]u8 = undefined;
    var aside_buf: [std.fs.max_path_bytes]u8 = undefined;
    const inside = std.fmt.bufPrint(&inside_buf, "{s}\\src", .{tree_abs}) catch return;
    const aside = std.fmt.bufPrint(&aside_buf, "{s}.src.aside", .{tree_abs}) catch return;
    std.Io.Dir.renameAbsolute(inside, aside, testing.io) catch return;
    shadow.createJunction(testing.io, inside, planted_victim) catch return;
    planted = true;
}

test "commit defense: a junction put inside the store between the link check and the checkout never replaces or deletes a file where it points, and the call is refused" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try testing.expect((try swap(env, new_body, common.red)).is_error);
    try case.repo.write("src/flag.ts", flag_new);
    try byHand(env, "user: bbbb");
    const before = try env.head();
    const location = try shadow_root.locate(testing.allocator, case.repo.root_abs, null);
    defer location.deinit(testing.allocator);

    planted_victim = try env.abs(".git/victim");
    try std.Io.Dir.cwd().createDirPath(testing.io, planted_victim);
    try case.repo.write(".git/victim/flag.ts", "the user's own file\n");
    planted = false;
    commit_store.probe.before_checkout = plantJunction;
    const outcome = swap(env, new_body, common.green);
    commit_store.probe.before_checkout = null;
    defer std.Io.Dir.cwd().deleteDir(testing.io, std.fs.path.join(env.arena(), &.{ location.committed, commit_store.tree_name, "src" }) catch "") catch {};
    try testing.expect(planted);
    const reply = try outcome;
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(contains(reply.text, "CommittedTreeUnavailable"));
    try testing.expectEqualStrings(before, try env.head());
    try testing.expectEqualStrings("the user's own file\n", try env.read(".git/victim/flag.ts"));

    const again = try swap(env, new_body, common.green);
    try testing.expect(again.is_error);
    try testing.expect(contains(again.text, "WorkspaceIsLink"));
    try testing.expectEqualStrings("the user's own file\n", try env.read(".git/victim/flag.ts"));
    try testing.expectEqualStrings(before, try env.head());
}
