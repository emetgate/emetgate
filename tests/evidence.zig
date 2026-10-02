const std = @import("std");
const emetgate = @import("emetgate");
const evidence = emetgate.evidence;
const facts_evidence = emetgate.facts_evidence;
const answer = emetgate.answer;
const test_util = emetgate.test_util;
const Repo = @import("facts_repo.zig").Repo;

const testing = std.testing;

const RepoFiles = struct {
    repo: *Repo,
    failing: []const u8 = "",
    failure: facts_evidence.SourceError = error.Vanished,

    fn file(ctx: *anyopaque, path: []const u8) facts_evidence.SourceError!facts_evidence.File {
        const self: *RepoFiles = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, path, self.failing)) return self.failure;
        const bytes = self.repo.sources.get(path) orelse return error.Vanished;
        const profile = emetgate.lang_registry.forPath(path) orelse return error.Vanished;
        return .{ .bytes = bytes, .profile = profile };
    }

    fn source(self: *RepoFiles) facts_evidence.Source {
        return .{ .ctx = self, .fileFn = file };
    }
};

const Fixture = struct {
    runtime: *emetgate.runtime.Runtime,
    repo: Repo,
    arena: std.heap.ArenaAllocator,
    files: RepoFiles = undefined,

    fn init(fixture: *Fixture) !void {
        fixture.runtime = try test_util.openRuntime();
        fixture.repo = Repo.init(fixture.runtime);
        fixture.arena = std.heap.ArenaAllocator.init(testing.allocator);
        fixture.files = .{ .repo = &fixture.repo };
    }

    fn deinit(fixture: *Fixture) void {
        fixture.arena.deinit();
        fixture.repo.deinit();
        test_util.closeRuntime(fixture.runtime);
    }

    fn ask(fixture: *Fixture, request: evidence.EvidenceRequest, budget: usize) evidence.EvidenceAnswer {
        const store: evidence.FactStore = .{
            .arena = fixture.arena.allocator(),
            .store = &fixture.repo.store,
            .source = fixture.files.source(),
            .snapshot = .{ .barrier = 1, .root = std.mem.zeroes(answer.Digest) },
            .max_file_bytes = 1024 * 1024,
            .largest_file_bytes = 100,
        };
        return evidence.evidence(&store, request, budget);
    }
};

fn textOf(a: evidence.EvidenceAnswer) ![]const u8 {
    return switch (a) {
        .complete => |c| c.value.text,
        .partial => |p| p.value.text,
        .refused => |r| {
            std.debug.print("refused: {t} {s}\n", .{ r.code, r.detail });
            return error.Refused;
        },
    };
}

fn lastLine(text: []const u8) []const u8 {
    return text[(std.mem.lastIndexOfScalar(u8, text, '\n') orelse 0) + 1 ..];
}

fn expectLines(text: []const u8, wanted: []const []const u8) !void {
    for (wanted) |line| {
        if (std.mem.indexOf(u8, text, line) == null) {
            std.debug.print("missing \"{s}\" in\n{s}\n", .{ line, text });
            return error.LineMissing;
        }
    }
}

fn expectNoLine(text: []const u8, unwanted: []const u8) !void {
    if (std.mem.indexOf(u8, text, unwanted) != null) {
        std.debug.print("unexpected \"{s}\" in\n{s}\n", .{ unwanted, text });
        return error.UnexpectedLine;
    }
}

fn bigDecider(allocator: std.mem.Allocator) ![]u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);
    try source.appendSlice(allocator, "export function decide(x: number, node: any) {\n");
    for (0..60) |_| try source.appendSlice(allocator, "  x = x + 1;\n");
    try source.appendSlice(allocator, "  if (node.continueOnFail) {\n");
    for (0..20) |_| try source.appendSlice(allocator, "    x = x * 2;\n");
    try source.appendSlice(allocator, "    return \"continue\";\n  }\n");
    for (0..60) |_| try source.appendSlice(allocator, "  x = x - 1;\n");
    try source.appendSlice(allocator, "  return \"stop\";\n}\n");
    return source.toOwnedSlice(allocator);
}

test "evidence: a target that fits is shown whole between the header line and the certificate status line" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.repo.put("a.ts", "export function decide(x: number) {\n  if (x > 1) {\n    return \"stop\";\n  }\n  return \"go\";\n}\n");
    try f.repo.linkAll();
    const result = f.ask(.{ .targets = &.{.{ .path = "a.ts", .qname = "decide" }}, .intent = .decides, .terms = &.{"stop"} }, evidence.default_budget);
    try testing.expectEqual(answer.Status.complete, result.status());
    const text = try textOf(result);
    try testing.expect(std.mem.startsWith(u8, text, "Evidence (decides) for decide (a.ts); terms: stop."));
    try expectLines(text, &.{ "\na.ts\n1  export function decide(x: number) {  [target decide ", "\n3      return \"stop\";\n", "\n5    return \"go\";\n", "\n6  }\n" });
    try testing.expect(std.mem.startsWith(u8, lastLine(text), "\u{2713} 1 target in 1 file"));
    try expectNoLine(text, " lines elided");
    try expectNoLine(text, "Partial because");
}

test "evidence: a decides target that does not fit keeps every branch with a term whole and names every elided range" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const source = try bigDecider(testing.allocator);
    defer testing.allocator.free(source);
    _ = try f.repo.put("a.ts", source);
    try f.repo.linkAll();
    const result = f.ask(.{ .targets = &.{.{ .path = "a.ts", .qname = "decide" }}, .intent = .decides, .terms = &.{"continueOnFail"} }, 3000);
    try testing.expectEqual(answer.Status.partial, result.status());
    const text = try textOf(result);
    try testing.expect(text.len <= 3000);
    try expectLines(text, &.{
        "\na.ts\n1  export function decide(x: number, node: any) {  [target decide ",
        "\n2-61  ... 60 lines elided\n",
        "\n62    if (node.continueOnFail) {\n",
        "\n63      x = x * 2;\n",
        "\n82      x = x * 2;\n",
        "\n83      return \"continue\";\n",
        "\n84    }\n",
        "\n85-145  ... 61 lines elided\n",
        "\n146  }\n",
    });
    try expectLines(text, &.{"\nPartial because: 1 files not shown in full within the budget, each gap marked.\n"});
    try testing.expect(std.mem.startsWith(u8, lastLine(text), "partial: 1 target in 0 of 1 file"));
    try testing.expectEqual(@as(usize, 2), result.partial.value.elided.len);
}

test "evidence: callers are shown by signature and call line, every unresolved candidate is listed and the reason is named" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.repo.put("a.ts", "export class C {\n  run() { return 1; }\n}\n");
    _ = try f.repo.put("b.ts", "import { C } from \"./a\";\nexport function use(c: C, x: any) {\n  return c.run() + x.run();\n}\n");
    try f.repo.linkAll();
    const result = f.ask(.{ .targets = &.{.{ .path = "a.ts", .qname = "C.run" }}, .intent = .callers }, evidence.default_budget);
    try testing.expectEqual(answer.Status.partial, result.status());
    const text = try textOf(result);
    try expectLines(text, &.{
        "\na.ts\n2    run() { return 1; }  [target C.run ",
        "\nb.ts\n2  export function use(c: C, x: any) {  [caller of C.run: use ",
        "\n3  return c.run() + x.run();  [call typed]\n",
        "\n3  return c.run() + x.run();  [unresolved property_needs_type in use]\n",
        "\nPartial because: 1 references with the same name on receivers of unknown type may also be it.\n",
    });
    try testing.expectEqual(@as(usize, 1), result.partial.value.unresolved.len);
    try testing.expectEqual(@as(usize, 1), result.partial.value.sites.len);
    try testing.expect(std.mem.startsWith(u8, lastLine(text), "partial: 1 callers in 2 of 2 files"));
    try testing.expect(std.mem.endsWith(u8, text, evidence.open_note));
}

test "evidence: callers that do not fit the budget are counted, named as cut and turn the answer partial" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.repo.put("a.ts", "export function decide(x: number) {\n  return x;\n}\n");
    var callers: std.ArrayList(u8) = .empty;
    defer callers.deinit(testing.allocator);
    try callers.appendSlice(testing.allocator, "import { decide } from \"./a\";\nexport function many(n: number) {\n");
    for (0..300) |_| try callers.appendSlice(testing.allocator, "  decide(n);\n");
    try callers.appendSlice(testing.allocator, "}\n");
    _ = try f.repo.put("b.ts", callers.items);
    try f.repo.linkAll();
    const result = f.ask(.{ .targets = &.{.{ .path = "a.ts", .qname = "decide" }}, .intent = .callers }, 2000);
    try testing.expectEqual(answer.Status.partial, result.status());
    const text = try textOf(result);
    try testing.expect(text.len <= 2000);
    try expectLines(text, &.{ "\nb.ts\n2  export function many(n: number) {  [caller of decide: many ", "\n3  decide(n);  [call proven]\n", " call sites\n", "\nPartial because: 1 files not shown in full within the budget, each gap marked.\n" });
    try testing.expectEqual(@as(usize, 300), result.partial.value.sites.len);
    try testing.expect(result.partial.value.cut > 250);
}

test "evidence: the block never passes its budget whatever the budget and the intent" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const source = try bigDecider(testing.allocator);
    defer testing.allocator.free(source);
    _ = try f.repo.put("a.ts", source);
    var callers: std.ArrayList(u8) = .empty;
    defer callers.deinit(testing.allocator);
    try callers.appendSlice(testing.allocator, "import { decide } from \"./a\";\nexport function many(n: any) {\n");
    for (0..80) |_| try callers.appendSlice(testing.allocator, "  decide(1, n); n.decide();\n");
    try callers.appendSlice(testing.allocator, "}\n");
    _ = try f.repo.put("b.ts", callers.items);
    try f.repo.linkAll();
    for ([_]usize{ 1000, 1500, 2000, 4000, 9500 }) |budget| {
        for (std.enums.values(evidence.Intent)) |intent| {
            const result = f.ask(.{ .targets = &.{ .{ .path = "a.ts", .qname = "decide" }, .{ .path = "b.ts", .qname = "many" } }, .intent = intent, .terms = &.{"continueOnFail"} }, budget);
            const text = try textOf(result);
            if (text.len > budget) {
                std.debug.print("{t} at {d}: {d} characters\n", .{ intent, budget, text.len });
                return error.OverBudget;
            }
            try testing.expect(std.mem.startsWith(u8, text, "Evidence ("));
        }
    }
}

test "evidence: callees are shown by signature with their call lines and an unresolved call in the body is listed" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.repo.put("a.ts", "function g() { return 1; }\nexport function f(x: any) {\n  setTimeout(g, 1);\n  return g() + x.m();\n}\n");
    try f.repo.linkAll();
    const result = f.ask(.{ .targets = &.{.{ .path = "a.ts", .qname = "f" }}, .intent = .callees }, evidence.default_budget);
    try testing.expectEqual(answer.Status.partial, result.status());
    const text = try textOf(result);
    try expectLines(text, &.{
        "\n4    return g() + x.m();\n",
        "\na.ts\n1  function g() { return 1; }  [callee of f: g ",
        ", called at line 4, proven]\n",
        "\n4  return g() + x.m();  [unresolved property_needs_type in f]\n",
        "\nPartial because: 1 calls in the target body could not be resolved.\n",
    });
}

test "evidence: flow lists both the callers and the callees of the target" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.repo.put("a.ts", "export function low() { return 1; }\nexport function mid() { return low(); }\nexport function top() { return mid(); }\n");
    try f.repo.linkAll();
    const result = f.ask(.{ .targets = &.{.{ .path = "a.ts", .qname = "mid" }}, .intent = .flow }, evidence.default_budget);
    try testing.expectEqual(answer.Status.complete, result.status());
    const text = try textOf(result);
    try expectLines(text, &.{
        "\na.ts\n3  export function top() { return mid(); }  [caller of mid: top ",
        "\n3  export function top() { return mid(); }  [call proven]\n",
        "\n1  export function low() { return 1; }  [callee of mid: low ",
    });
    try testing.expect(std.mem.startsWith(u8, lastLine(text), "\u{2713} 2 call edges in 1 file"));
}

test "evidence: a cut class keeps the header of the method that holds a relevant line" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "export class Big {\n  first() {\n    return 1;\n  }\n  run(node: any) {\n    let x = 0;\n");
    for (0..40) |_| try source.appendSlice(testing.allocator, "    x = x + 1;\n");
    try source.appendSlice(testing.allocator, "    if (node.continueOnFail) {\n      x = 2;\n    }\n    return x;\n  }\n}\n");
    _ = try f.repo.put("a.ts", source.items);
    try f.repo.linkAll();
    const result = f.ask(.{ .targets = &.{.{ .path = "a.ts", .qname = "Big" }}, .intent = .explain, .terms = &.{"continueOnFail"} }, 1500);
    const text = try textOf(result);
    try expectLines(text, &.{ "\na.ts\n1  export class Big {  [target Big ", "\n5    run(node: any) {\n", "\n47      if (node.continueOnFail) {\n", "\n48        x = 2;\n", "\n51    }\n", "\n52  }" });
    try expectNoLine(text, "\n2    first() {\n");
}

test "evidence: a term found in a comment brings the statement the comment describes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "export function work(node: any) {\n  let x = 0;\n");
    for (0..40) |_| try source.appendSlice(testing.allocator, "  x = x + 1;\n");
    try source.appendSlice(testing.allocator, "  // retry when the node keeps failing\n  const attempts = node.maxTries;\n");
    for (0..40) |_| try source.appendSlice(testing.allocator, "  x = x - 1;\n");
    try source.appendSlice(testing.allocator, "  return x + attempts;\n}\n");
    _ = try f.repo.put("a.ts", source.items);
    try f.repo.linkAll();
    const result = f.ask(.{ .targets = &.{.{ .path = "a.ts", .qname = "work" }}, .intent = .explain, .terms = &.{"retry"} }, 1500);
    const text = try textOf(result);
    try expectLines(text, &.{ "\n43    // retry when the node keeps failing\n", "\n44    const attempts = node.maxTries;\n" });
}

test "evidence: a line too long for the evidence is cut with the number of hidden characters and the answer turns partial" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "export function long() {\n  const s = \"");
    for (0..1000) |_| try source.append(testing.allocator, 'a');
    try source.appendSlice(testing.allocator, "\";\n  return s;\n}\n");
    _ = try f.repo.put("a.ts", source.items);
    try f.repo.linkAll();
    const result = f.ask(.{ .targets = &.{.{ .path = "a.ts", .qname = "long" }}, .intent = .explain }, evidence.default_budget);
    try testing.expectEqual(answer.Status.partial, result.status());
    const text = try textOf(result);
    try expectLines(text, &.{ " ... (715 more characters on this line)\n", "\n3    return s;\n" });
}

fn askFailing(f: *Fixture, failure: facts_evidence.SourceError) !evidence.EvidenceAnswer {
    _ = try f.repo.put("a.ts", "export function f() {\n  return 1;\n}\n");
    try f.repo.linkAll();
    f.files.failing = "a.ts";
    f.files.failure = failure;
    return f.ask(.{ .targets = &.{.{ .path = "a.ts", .qname = "f" }}, .intent = .explain }, evidence.default_budget);
}

test "evidence: a target whose file changed after the snapshot is named, never shown, and the answer is partial with the change named" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const result = try askFailing(&f, error.Changed);
    try testing.expectEqual(answer.Status.partial, result.status());
    const text = try textOf(result);
    try expectLines(text, &.{ "\na.ts\n1  " ++ evidence.changed_note ++ "  [target f ", "\nPartial because: 1 files changed after the snapshot and could not be refreshed.\n" });
    try expectNoLine(text, "return 1;");
    try testing.expect(std.mem.indexOf(u8, lastLine(text), "missing 1 changed_since_snapshot") != null);
}

test "evidence: a target whose file was deleted is named, never shown, and the answer is partial with the file vanished" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const result = try askFailing(&f, error.Vanished);
    try testing.expectEqual(answer.Status.partial, result.status());
    const text = try textOf(result);
    try expectLines(text, &.{ "\na.ts\n1  " ++ evidence.vanished_note ++ "  [target f ", "\nPartial because: 1 files no longer exist.\n" });
    try expectNoLine(text, "return 1;");
    try testing.expect(std.mem.indexOf(u8, lastLine(text), "missing 1 vanished") != null);
}

test "evidence: a target whose file cannot be read is named, never shown, and the answer is partial with the file unreadable" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const result = try askFailing(&f, error.Unreadable);
    try testing.expectEqual(answer.Status.partial, result.status());
    const text = try textOf(result);
    try expectLines(text, &.{ "\na.ts\n1  " ++ evidence.unreadable_note ++ "  [target f ", "\nPartial because: 1 files could not be read (locked or access denied).\n" });
    try expectNoLine(text, "return 1;");
    try testing.expect(std.mem.indexOf(u8, lastLine(text), "missing 1 unreadable") != null);
}

test "evidence: a target whose file grew over the size limit is excluded by the declared rule and the limit is named" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const result = try askFailing(&f, error.TooLarge);
    try testing.expectEqual(answer.Status.complete, result.status());
    const text = try textOf(result);
    try expectLines(text, &.{ "\na.ts\n1  " ++ evidence.large_note ++ "  [target f ", "\nExcluded by rule: 1 files over the 1048576-byte size limit are not read.\n" });
    try expectNoLine(text, "return 1;");
    try expectNoLine(text, "Partial because");
    try testing.expect(std.mem.endsWith(u8, lastLine(text), "; skipped 1 too_large"));
}

test "evidence: a call from one target to another target is kept when the caller does not fit" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "export function helper() { return 1; }\nexport function big() {\n  let x = 0;\n");
    for (0..60) |_| try source.appendSlice(testing.allocator, "  x = x + 1;\n");
    try source.appendSlice(testing.allocator, "  x = x + helper();\n");
    for (0..60) |_| try source.appendSlice(testing.allocator, "  x = x - 1;\n");
    try source.appendSlice(testing.allocator, "  return x;\n}\n");
    _ = try f.repo.put("a.ts", source.items);
    try f.repo.linkAll();
    const result = f.ask(.{ .targets = &.{ .{ .path = "a.ts", .qname = "big" }, .{ .path = "a.ts", .qname = "helper" } }, .intent = .explain }, 2000);
    const text = try textOf(result);
    try expectLines(text, &.{ "\n64    x = x + helper();\n", "\n1  export function helper() { return 1; }  [target helper " });
}

test "evidence: an unknown target is named in the header and the answer is refused only when no target is known" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.repo.put("a.ts", "export function f() { return 1; }\n");
    try f.repo.linkAll();
    const some = f.ask(.{ .targets = &.{ .{ .path = "a.ts", .qname = "f" }, .{ .path = "a.ts", .qname = "nope" } }, .intent = .explain }, evidence.default_budget);
    const text = try textOf(some);
    try testing.expect(std.mem.startsWith(u8, text, "Evidence (explain) for f (a.ts); not found: a.ts#nope."));
    const none = f.ask(.{ .targets = &.{.{ .path = "a.ts", .qname = "nope" }}, .intent = .explain }, evidence.default_budget);
    try testing.expectEqual(answer.Status.refused, none.status());
    try testing.expectEqual(error.SubjectNotFound, none.refused.code);
    const small = f.ask(.{ .targets = &.{.{ .path = "a.ts", .qname = "f" }}, .intent = .explain }, evidence.min_budget - 1);
    try testing.expectEqual(error.BudgetTooSmall, small.refused.code);
}

fn testsOf(a: evidence.EvidenceAnswer) []const evidence.TestLine {
    return switch (a) {
        .complete => |c| c.value.tests,
        .partial => |p| p.value.tests,
        .refused => &.{},
    };
}

test "evidence: the tests that reference a target are listed by test name with how each was bound" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.repo.put("a.ts", "export function decide(x: number) {\n  return x > 1 ? \"stop\" : \"go\";\n}\n");
    _ = try f.repo.put("a.test.ts", "import { decide } from \"./a\";\ndescribe(\"decide\", () => {\n  it(\"stops\", () => {\n    expect(decide(2)).toBe(\"stop\");\n    expect(decide(3)).toBe(\"stop\");\n  });\n  it(\"guesses\", () => {\n    const x: any = {};\n    x.decide(1);\n  });\n});\n");
    _ = try f.repo.put("b.ts", "import { decide } from \"./a\";\nexport function use() { return decide(1); }\n");
    _ = try f.repo.put("c.test.ts", "describe(\"other\", () => {\n  it(\"calls a decide of its own\", () => {\n    const y: any = {};\n    y.decide(1);\n  });\n});\n");
    try f.repo.linkAll();
    const result = f.ask(.{ .targets = &.{.{ .path = "a.ts", .qname = "decide" }}, .intent = .explain }, evidence.default_budget);
    const text = try textOf(result);
    try expectLines(text, &.{
        "\na.test.ts\n3  decide > stops  [test of decide: 2 references, proven]\n",
        "\n7  decide > guesses  [test of decide: 1 reference, by name only]\n",
    });
    try expectNoLine(text, "calls a decide of its own");
    try testing.expectEqual(@as(usize, 2), testsOf(result).len);
    const off = f.ask(.{ .targets = &.{.{ .path = "a.ts", .qname = "decide" }}, .intent = .explain, .include = .{ .tests = false } }, evidence.default_budget);
    try expectNoLine(try textOf(off), "[test of");
    try testing.expectEqual(@as(usize, 0), testsOf(off).len);
}

test "evidence: an explain answer brings callers, callees and tests unless the include field turns them off" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.repo.put("a.ts", "export function decide(x: number) {\n  return x;\n}\n");
    _ = try f.repo.put("b.ts", "import { decide } from \"./a\";\nexport function use() { return decide(1); }\n");
    _ = try f.repo.put("a.test.ts", "import { decide } from \"./a\";\ntest(\"runs\", () => decide(1));\n");
    try f.repo.linkAll();
    const plain = f.ask(.{ .targets = &.{.{ .path = "a.ts", .qname = "decide" }}, .intent = .explain }, evidence.default_budget);
    const text = try textOf(plain);
    try expectLines(text, &.{ "\nb.ts\n2  export function use() { return decide(1); }  [caller of decide: use ", "\n2  export function use() { return decide(1); }  [call proven]\n", "\na.test.ts\n2  runs  [test of decide: 1 reference, proven]\n" });
    try testing.expect(std.mem.startsWith(u8, lastLine(text), "\u{2713} 1 target in 3 files"));
    const off = f.ask(.{ .targets = &.{.{ .path = "a.ts", .qname = "decide" }}, .intent = .explain, .include = .{ .callers = false, .callees = false, .tests = false } }, evidence.default_budget);
    try expectNoLine(try textOf(off), "[caller of");
    try expectNoLine(try textOf(off), "[test of");
    const defined = f.ask(.{ .targets = &.{.{ .path = "a.ts", .qname = "decide" }}, .intent = .where_defined }, evidence.default_budget);
    try expectNoLine(try textOf(defined), "[caller of");
    try expectNoLine(try textOf(defined), "[test of");
}

test "evidence: a test file shows three tests of a target and counts the rest" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.repo.put("a.ts", "export function decide(x: number) {\n  return x;\n}\n");
    var suite: std.ArrayList(u8) = .empty;
    defer suite.deinit(testing.allocator);
    try suite.appendSlice(testing.allocator, "import { decide } from \"./a\";\n");
    for (0..5) |i| try suite.print(testing.allocator, "test(\"case {d}\", () => decide({d}));\n", .{ i, i });
    _ = try f.repo.put("a.test.ts", suite.items);
    try f.repo.linkAll();
    const result = f.ask(.{ .targets = &.{.{ .path = "a.ts", .qname = "decide" }}, .intent = .explain, .include = .{ .callers = false } }, evidence.default_budget);
    const text = try textOf(result);
    try expectLines(text, &.{ "\na.test.ts\n2  case 0  [test of decide: 1 reference, proven]\n", "\n4  case 2  [test of decide: 1 reference, proven]\n", "\n...  2 more tests in this file\n" });
    try expectNoLine(text, "case 3");
    try testing.expectEqual(answer.Status.complete, result.status());
}

test "evidence: the body of a flow target that fits is shown whole before its callers take the rest of the budget" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, "export function work(x: number) {\n");
    for (0..70) |_| try body.appendSlice(testing.allocator, "  x = x + 1;\n");
    try body.appendSlice(testing.allocator, "  return x;\n}\n");
    _ = try f.repo.put("a.ts", body.items);
    var callers: std.ArrayList(u8) = .empty;
    defer callers.deinit(testing.allocator);
    try callers.appendSlice(testing.allocator, "import { work } from \"./a\";\n");
    for (0..60) |i| try callers.print(testing.allocator, "export function caller{d}() {{ return work({d}); }}\n", .{ i, i });
    _ = try f.repo.put("b.ts", callers.items);
    try f.repo.linkAll();
    const result = f.ask(.{ .targets = &.{.{ .path = "a.ts", .qname = "work" }}, .intent = .flow }, 2500);
    const text = try textOf(result);
    try testing.expect(text.len <= 2500);
    try expectLines(text, &.{ "\na.ts\n1  export function work(x: number) {  [target work ", "\n72    return x;\n", "\n73  }\n", " call sites" });
    try testing.expectEqual(answer.Status.partial, result.status());
    for (result.partial.value.elided) |e| try testing.expect(!std.mem.eql(u8, e.path, "a.ts"));
}

test "evidence: two targets that do not fit share the budget in request order and both keep their signature and term lines" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    for ([_][]const u8{ "a", "b" }) |tag| {
        try source.print(testing.allocator, "export function {s}Work(x: number) {{\n", .{tag});
        for (0..100) |i| {
            if (i % 5 == 0) {
                try source.print(testing.allocator, "  if (x > {d}) return \"needle {s}{d}\";\n", .{ i, tag, i });
            } else try source.appendSlice(testing.allocator, "  x = x + 1;\n");
        }
        try source.appendSlice(testing.allocator, "  return x;\n}\n");
    }
    _ = try f.repo.put("a.ts", source.items);
    try f.repo.linkAll();
    const result = f.ask(.{ .targets = &.{ .{ .path = "a.ts", .qname = "aWork" }, .{ .path = "a.ts", .qname = "bWork" } }, .intent = .decides, .terms = &.{"needle"} }, 2500);
    const text = try textOf(result);
    try testing.expect(text.len <= 2500);
    try expectLines(text, &.{
        "\na.ts\n1  export function aWork(x: number) {  [target aWork ",
        "\n2    if (x > 0) return \"needle a0\";\n",
        "\n104  export function bWork(x: number) {  [target bWork ",
        "\n105    if (x > 0) return \"needle b0\";\n",
    });
    try expectNoLine(text, " targets\n");
}

test "evidence: a function that does not fit keeps its whole signature up to the line where its body opens" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "export function long(\n  first: number,\n  second: number,\n): number {\n");
    for (0..80) |_| try source.appendSlice(testing.allocator, "  first = first + second;\n");
    try source.appendSlice(testing.allocator, "  return first;\n}\n");
    _ = try f.repo.put("a.ts", source.items);
    try f.repo.linkAll();
    const result = f.ask(.{ .targets = &.{.{ .path = "a.ts", .qname = "long" }}, .intent = .explain }, 1200);
    const text = try textOf(result);
    try expectLines(text, &.{
        "\na.ts\n1  export function long(  [target long ",
        "\n2    first: number,\n",
        "\n3    second: number,\n",
        "\n4  ): number {\n",
        "\n86  }",
    });
    try testing.expectEqual(answer.Status.partial, result.status());
}
