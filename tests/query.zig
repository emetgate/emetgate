const std = @import("std");
const builtin = @import("builtin");
const runner = @import("../src/platform/runner.zig");
const rules = @import("../src/platform/rules.zig");
const memory = @import("../src/platform/memory.zig");
const wire = @import("../src/protocol/wire.zig");
const symbol = @import("../src/engine/symbol.zig");
const checks = @import("../src/engine/checks.zig");
const lang = @import("../src/engine/lang/registry.zig");
const Runtime = @import("../src/engine/runtime.zig").Runtime;
const Snapshot = @import("../src/engine/loader.zig").Snapshot;

const testing = std.testing;

const n11_source =
    \\export function parseListing(state) {
    \\  // priceFloat/displayPriceFloat pair the old regex read
    \\  const price = parsePrice(state.price);
    \\  return { price, title: state.title };
    \\}
    \\
;

const n11_regressed =
    \\export function parseListing(state) {
    \\  const price = state.priceFloat;
    \\  return { price, fallback: priceFloat(state) };
    \\}
    \\
;

const price_float_query = "q:([(identifier) (property_identifier)] @violation (#eq? @violation \"priceFloat\"))";

const hb_source =
    \\export async function scrapeHepsiburada(url) {
    \\  try {
    \\    return await scrapeHepsiburadaApi(url);
    \\  } catch (err) {
    \\    return await withBrowser(url);
    \\  }
    \\}
    \\export function debugApi(url) {
    \\  return scrapeHepsiburadaApi(url);
    \\}
    \\
;

const hb_query = "q:((call_expression function: (identifier) @violation) (#eq? @violation \"scrapeHepsiburadaApi\"))";

const Hits = struct {
    texts: [][]const u8,
    lines: []u32,

    fn deinit(self: Hits) void {
        testing.allocator.free(self.texts);
        testing.allocator.free(self.lines);
    }
};

fn hitsIn(path: []const u8, source: []const u8, ref_text: ?[]const u8, spec: []const u8) !Hits {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const snapshot = try Snapshot.fromSource(runtime, lang.forPath(path).?, try testing.allocator.dupe(u8, source));
    defer snapshot.destroy();

    var span: symbol.Span = .{ .start = 0, .end = @intCast(source.len) };
    if (ref_text) |text| {
        const ref = try symbol.Ref.parse(testing.allocator, text);
        defer ref.deinit(testing.allocator);
        const target = try (try snapshot.symbols()).resolve(ref);
        span = .{ .start = target.body.startByte(), .end = target.body.endByte() };
    }
    const found = try checks.run(testing.allocator, snapshot.profile, snapshot.tree, span, &.{spec});
    defer testing.allocator.free(found);
    const texts = try testing.allocator.alloc([]const u8, found.len);
    errdefer testing.allocator.free(texts);
    const lines = try testing.allocator.alloc(u32, found.len);
    for (found, texts, lines) |hit, *text, *line| {
        text.* = source[hit.span.start..hit.span.end];
        line.* = @intCast(std.mem.count(u8, source[0..hit.span.start], "\n") + 1);
    }
    return .{ .texts = texts, .lines = lines };
}

test "real case: priceFloat in a comment is not a use, a real read or call is" {
    const forbidden = try hitsIn("src/scraper/n11.js", n11_source, null, "forbid:priceFloat");
    defer forbidden.deinit();
    try testing.expectEqual(@as(usize, 1), forbidden.texts.len);
    try testing.expectEqual(@as(u32, 2), forbidden.lines[0]);

    const clean = try hitsIn("src/scraper/n11.js", n11_source, null, price_float_query);
    defer clean.deinit();
    try testing.expectEqual(@as(usize, 0), clean.texts.len);

    const regressed = try hitsIn("src/scraper/n11.js", n11_regressed, null, price_float_query);
    defer regressed.deinit();
    try testing.expectEqual(@as(usize, 2), regressed.texts.len);
    try testing.expectEqualSlices(u32, &.{ 2, 3 }, regressed.lines);
}

test "real case: a call inside the orchestrator is caught and the same call elsewhere stays out of scope" {
    const in_orchestrator = try hitsIn("src/scraper/hepsiburada.js", hb_source, "scrapeHepsiburada", hb_query);
    defer in_orchestrator.deinit();
    try testing.expectEqual(@as(usize, 1), in_orchestrator.texts.len);
    try testing.expectEqualStrings("scrapeHepsiburadaApi", in_orchestrator.texts[0]);
    try testing.expectEqual(@as(u32, 3), in_orchestrator.lines[0]);

    const whole_file = try hitsIn("src/scraper/hepsiburada.js", hb_source, null, hb_query);
    defer whole_file.deinit();
    try testing.expectEqual(@as(usize, 2), whole_file.texts.len);

    const old_name = try hitsIn("src/scraper/hepsiburada.js", hb_source, "scrapeHepsiburada", "q:((call_expression function: (identifier) @violation) (#eq? @violation \"scrapeHepsiburadaFast\"))");
    defer old_name.deinit();
    try testing.expectEqual(@as(usize, 0), old_name.texts.len);
}

const Repo = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,

    const ts_source = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
    const js_source = "export function add(a, b) {\n  return a + b;\n}\n";

    fn init() !Repo {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/math.ts", .data = ts_source });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/math.js", .data = js_source });
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
        errdefer testing.allocator.free(root_abs);
        inline for (.{
            &.{ "init", "-q" },
            &.{ "config", "user.email", "t@t" },
            &.{ "config", "user.name", "t" },
            &.{ "add", "." },
            &.{ "commit", "-q", "-m", "init" },
        }) |args| try git(root_abs, args);
        return .{ .tmp = tmp, .root_abs = root_abs };
    }

    fn git(root_abs: []const u8, args: []const []const u8) !void {
        var argv: [8][]const u8 = undefined;
        argv[0] = "git";
        @memcpy(argv[1..][0..args.len], args);
        const result = try std.process.run(testing.allocator, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root_abs } });
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitSetupFailed,
            else => return error.GitSetupFailed,
        }
    }

    fn deinit(self: *Repo) void {
        testing.allocator.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn adopt(self: *Repo, check: []const u8) !void {
        const id = try memory.remember(testing.allocator, testing.io, self.root_abs, .project, "q rule", true, check, null);
        testing.allocator.free(id);
    }

    fn propose(self: *Repo, runtime: *Runtime, rel: []const u8, body: []const u8) !runner.Result {
        const file = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}", .{ self.root_abs, rel });
        defer testing.allocator.free(file);
        const snapshot = try Snapshot.load(runtime, testing.io, .cwd(), file);
        const hash = hash: {
            defer snapshot.destroy();
            const ref = try symbol.Ref.parse(testing.allocator, "add");
            defer ref.deinit(testing.allocator);
            break :hash (try (try snapshot.symbols()).resolve(ref)).hash;
        };
        return runner.tryMutate(testing.allocator, testing.io, runtime, .{
            .file_abs = file,
            .ref_text = "add",
            .expected_hash = .{ .present = hash },
            .new_body = body,
            .test_command = "exit 0",
        });
    }

    fn expectPristine(self: *Repo) !void {
        for ([_][]const u8{ "repo/src/math.ts", "repo/src/math.js" }, [_][]const u8{ ts_source, js_source }) |path, want| {
            const on_disk = try self.tmp.dir.readFileAlloc(testing.io, path, testing.allocator, .unlimited);
            defer testing.allocator.free(on_disk);
            try testing.expectEqualStrings(want, on_disk);
        }
    }
};

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

fn expectCheckFailed(result: runner.Result, detail: []const u8, text: []const u8) !void {
    errdefer std.debug.print("result: {t}\n", .{result});
    try testing.expect(result == .rule_check_failed);
    try testing.expectEqualStrings(detail, result.rule_check_failed.detail);
    try testing.expectEqualStrings(text, result.rule_check_failed.text);

    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    try wire.writeRuleCheckFailed(&buffer.writer, result.rule_check_failed);
    try testing.expect(std.mem.indexOf(u8, buffer.written(), "\"reason\":\"rule_check_crashed\"") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.written(), "rule_violation") == null);
}

test "redteam query: an enforced q: rule rejects a matching body with start and end positions" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    try repo.adopt("q:((call_expression function: (identifier) @violation) (#eq? @violation \"eval\"))");

    const result = try repo.propose(runtime, "src/math.ts", "{\n  // eval is not called here\n  return eval(\"a\") + b;\n}");
    defer result.deinit(testing.allocator);
    try testing.expect(result == .rule_violation);
    const violations = result.rule_violation.violations;
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqualStrings("eval", violations[0].text);
    try testing.expectEqual(@as(u32, 3), violations[0].line);
    try testing.expectEqual(@as(u32, 10), violations[0].col);
    try testing.expectEqual(@as(u32, 3), violations[0].end_line);
    try testing.expectEqual(@as(u32, 14), violations[0].end_col);
    try repo.expectPristine();
}

test "redteam query: a q: rule that outruns its budget rejects the proposal and is not a violation" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const pattern = "a?" ** 1500 ++ "b";
    try repo.adopt("q:((string_fragment) @violation (#match? @violation \"" ++ pattern ++ "\"))");

    const body = "{\n  const s = \"" ++ "a" ** 20_000 ++ "\";\n  return a + b + s.length;\n}";
    const started = std.Io.Timestamp.now(testing.io, .awake);
    const result = try repo.propose(runtime, "src/math.ts", body);
    defer result.deinit(testing.allocator);
    const elapsed_ms = started.durationTo(std.Io.Timestamp.now(testing.io, .awake)).toMilliseconds();
    try expectCheckFailed(result, "query_budget_exceeded", "typescript");
    try testing.expect(elapsed_ms < 10_000);
    try repo.expectPristine();
}

test "redteam query: a q: rule past the match limit rejects the proposal and is not a violation" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    try repo.adopt("q:(arguments (identifier) @violation (identifier) @violation)");

    const body = "{\n  return f(" ++ "a, " ** 3000 ++ "b);\n}";
    const result = try repo.propose(runtime, "src/math.ts", body);
    defer result.deinit(testing.allocator);
    try expectCheckFailed(result, "query_match_limit_exceeded", "typescript");
    try repo.expectPristine();
}

test "redteam query: a q: rule the file's grammar cannot compile rejects the proposal by name" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    try repo.adopt("q:(type_annotation) @violation");

    const js = try repo.propose(runtime, "src/math.js", "{\n  return a - b;\n}");
    defer js.deinit(testing.allocator);
    try expectCheckFailed(js, "query_not_for_language", "javascript");

    const ts = try repo.propose(runtime, "src/math.ts", "{\n  const d: number = a - b;\n  return d;\n}");
    defer ts.deinit(testing.allocator);
    try testing.expect(ts == .rule_violation);
    try repo.expectPristine();
}

test "redteam query: a hand-edited ledger row with a malformed q: query fails closed" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    try repo.adopt("q:((identifier) @violation (#set! key value))");
    try repo.adopt("q:(identifier) @id");

    const result = try repo.propose(runtime, "src/math.ts", "{\n  return a - b;\n}");
    defer result.deinit(testing.allocator);
    try expectCheckFailed(result, "query_malformed", "typescript");
    try repo.expectPristine();
}
