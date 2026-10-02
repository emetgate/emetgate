const std = @import("std");
const emetgate = @import("emetgate");
const facts = emetgate.facts;
const facts_query = emetgate.facts_query;
const facts_evidence = emetgate.facts_evidence;
const answer = emetgate.answer;
const test_util = emetgate.test_util;
const Repo = @import("facts_repo.zig").Repo;

const testing = std.testing;

const context: facts_query.Context = .{
    .snapshot = .{ .barrier = 1, .root = std.mem.zeroes(answer.Digest) },
    .max_file_bytes = 1024 * 1024,
    .largest_file_bytes = 100,
};

fn ask(arena: std.mem.Allocator, repo: *Repo, relation: facts_query.Relation, subject: []const u8) !facts_query.FactsAnswer {
    return facts_query.run(arena, &repo.store, context, .{ .relation = relation, .subject = subject });
}

fn valueOf(a: facts_query.FactsAnswer) !facts_query.Edges {
    return switch (a) {
        .complete => |c| c.value,
        .partial => |p| p.value,
        .refused => |r| {
            std.debug.print("refused: {t} {s}\n", .{ r.code, r.detail });
            return error.Refused;
        },
    };
}

const RepoFiles = struct {
    repo: *Repo,

    fn file(ctx: *anyopaque, path: []const u8) facts_evidence.SourceError!facts_evidence.File {
        const self: *RepoFiles = @ptrCast(@alignCast(ctx));
        const bytes = self.repo.sources.get(path) orelse return error.Vanished;
        const profile = emetgate.lang_registry.forPath(path) orelse return error.Vanished;
        return .{ .bytes = bytes, .profile = profile };
    }

    fn source(self: *RepoFiles) facts_evidence.Source {
        return .{ .ctx = self, .fileFn = file };
    }
};

test "facts query: callers is complete when every reference that could reach the subject is resolved" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    _ = try repo.put("a.ts", "export function f() { return 1; }\n");
    _ = try repo.put("b.ts", "import { f } from \"./a\";\nimport { g } from \"lodash\";\nexport function h() { return f() + g(); }\n");
    try repo.linkAll();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try ask(arena.allocator(), &repo, .callers, "f");
    try testing.expectEqual(answer.Status.complete, result.status());
    const value = try valueOf(result);
    try testing.expectEqual(@as(usize, 1), value.sites.len);
    try testing.expectEqualStrings("b.ts", value.sites[0].path);
    try testing.expectEqualStrings("h", value.sites[0].owner.qname);
    try testing.expectEqual(@as(u32, 2), result.certificate().?.scope.listed);
    try testing.expectEqual(@as(u32, 2), result.certificate().?.scope.evaluated);
}

test "facts query: a same-name call on an unknown receiver makes callers partial and is listed with its place" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    _ = try repo.put("a.ts", "export class C { run() { return 1; } }\n");
    _ = try repo.put("b.ts", "export function use(x: any) {\n  return x.run();\n}\n");
    try repo.linkAll();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try ask(arena.allocator(), &repo, .callers, "C.run");
    try testing.expectEqual(answer.Status.partial, result.status());
    const missing = result.missingList();
    try testing.expectEqual(@as(usize, 1), missing.len);
    try testing.expectEqual(answer.Reason.unresolved, missing[0].reason);
    try testing.expectEqualStrings("b.ts", missing[0].path.?);
    try testing.expectEqual(@as(u32, 2), missing[0].line);
    const value = try valueOf(result);
    try testing.expectEqual(facts.Reason.property_needs_type, value.unknown[0].reason);
    try testing.expectEqual(facts_query.Rule.same_name, value.unknown[0].rule);
}

test "facts query: a dynamic-key call counts only in a file that reaches the subject's module through imports" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    _ = try repo.put("a.ts", "export function f() { return 1; }\n");
    _ = try repo.put("b.ts", "import { f } from \"./a\";\nexport function h(o: any, k: string) { return o[k]() + f() + o[0]() + require(k); }\n");
    _ = try repo.put("c.ts", "export function far(o: any, k: string) { return o[k]() + o[0](); }\n");
    _ = try repo.put("d.ts", "import { h } from \"./b\";\nexport function g(o: any, k: string) { return o[k](h); }\n");
    try repo.linkAll();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try ask(arena.allocator(), &repo, .callers, "f");
    try testing.expectEqual(answer.Status.partial, result.status());
    const value = try valueOf(result);
    try testing.expectEqual(@as(usize, 2), value.unknown.len);
    try testing.expectEqualStrings("b.ts", value.unknown[0].path);
    try testing.expectEqualStrings("d.ts", value.unknown[1].path);
    for (value.unknown) |u| try testing.expectEqual(facts_query.Rule.dynamic_key, u.rule);
}

test "facts query: an unknown subject is refused, never answered with an empty list" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    _ = try repo.put("a.ts", "export function f() { return 1; }\n");
    try repo.linkAll();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try ask(arena.allocator(), &repo, .callers, "nope");
    try testing.expectEqual(answer.Status.refused, result.status());
    try testing.expectEqual(error.SubjectNotFound, result.refused.code);
    const deep = try facts_query.run(arena.allocator(), &repo.store, context, .{ .relation = .callers, .subject = "f", .depth = 9 });
    try testing.expectEqual(answer.Status.refused, deep.status());
}

test "facts query: a file that mentions the name but was not parsed is reported as not analyzed" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    _ = try repo.put("a.ts", "export function f() { return 1; }\n");
    const vue = try repo.store.ensureFile("view.vue");
    _ = try repo.store.markUnindexed(vue, .unindexed, "", &.{ "template", "f" });
    const other = try repo.store.ensureFile("other.vue");
    _ = try repo.store.markUnindexed(other, .unindexed, "", &.{"g"});
    try repo.linkAll();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try ask(arena.allocator(), &repo, .defined_at, "f");
    try testing.expectEqual(answer.Status.partial, result.status());
    const missing = result.missingList();
    try testing.expectEqual(@as(usize, 1), missing.len);
    try testing.expectEqual(answer.Reason.unclassified, missing[0].reason);
    try testing.expectEqualStrings("view.vue", missing[0].path.?);
    try testing.expectEqual(@as(u32, 3), result.certificate().?.scope.listed);
    try testing.expectEqual(@as(u32, 2), result.certificate().?.scope.evaluated);
}

test "facts query: callees lists resolved calls, keeps globals outside and an unknown receiver as unresolved" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    _ = try repo.put("a.ts", "function g() { return 1; }\nexport function f(x: any) {\n  setTimeout(g, 1);\n  return g() + x.m();\n}\n");
    try repo.linkAll();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try ask(arena.allocator(), &repo, .callees, "f");
    try testing.expectEqual(answer.Status.partial, result.status());
    const value = try valueOf(result);
    try testing.expectEqual(@as(usize, 1), value.sites.len);
    try testing.expectEqualStrings("g", value.sites[0].target.qname);
    try testing.expectEqual(@as(usize, 1), value.outside.len);
    try testing.expectEqual(@as(usize, 1), value.unknown.len);
    try testing.expectEqualStrings("m", value.unknown[0].name);
}

test "facts query: the same question on the same snapshot gives the same certificate bytes" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    _ = try repo.put("a.ts", "export function f() { return 1; }\n");
    _ = try repo.put("b.ts", "import { f } from \"./a\";\nexport function h(x: any) { return f() + x.f(); }\n");
    _ = try repo.put("c.ts", "import { f } from \"./a\";\nexport function k() { return f(); }\n");
    try repo.linkAll();
    var texts: [2][]u8 = undefined;
    for (&texts) |*slot| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const result = try ask(arena.allocator(), &repo, .callers, "f");
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer };
        try result.writeCertificate(&js);
        slot.* = try testing.allocator.dupe(u8, out.written());
    }
    defer for (texts) |t| testing.allocator.free(t);
    try testing.expectEqualStrings(texts[0], texts[1]);
}

test "facts evidence: a partial answer ends with the not-a-proof line and stays within the budget" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    _ = try repo.put("a.ts", "export function f() { return 1; }\n");
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "import { f } from \"./a\";\nexport function many(x: any) {\n");
    for (0..120) |_| try source.appendSlice(testing.allocator, "  f(); x.f();\n");
    try source.appendSlice(testing.allocator, "}\n");
    _ = try repo.put("b.ts", source.items);
    try repo.linkAll();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try ask(arena.allocator(), &repo, .callers, "f");
    try testing.expectEqual(answer.Status.partial, result.status());
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var files: RepoFiles = .{ .repo = &repo };
    const rendered = try facts_evidence.render(arena.allocator(), &out.writer, result, files.source(), facts_evidence.min_budget);
    try testing.expect(out.written().len <= facts_evidence.min_budget);
    try testing.expectEqual(out.written().len, rendered.bytes);
    try testing.expect(rendered.cut > 0);
    try testing.expectEqual(answer.Status.partial, rendered.status);
    const text = out.written();
    const last = text[(std.mem.lastIndexOfScalar(u8, text, '\n') orelse 0) + 1 ..];
    try testing.expect(std.mem.startsWith(u8, last, facts_evidence.open_footer ++ "120"));
    try testing.expect(std.mem.indexOf(u8, text, "more lines not shown") != null);
    try testing.expect(std.mem.indexOf(u8, text, "proven]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "missing") != null);
}

test "facts evidence: a complete answer says so on its last line and labels each edge" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    _ = try repo.put("a.ts", "export class C { go() { return 1; } }\n");
    _ = try repo.put("b.ts", "import { C } from \"./a\";\nexport function use(c: C) { return c.go() + new C().go(); }\n");
    try repo.linkAll();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try ask(arena.allocator(), &repo, .callers, "C.go");
    try testing.expectEqual(answer.Status.complete, result.status());
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var files: RepoFiles = .{ .repo = &repo };
    const rendered = try facts_evidence.render(arena.allocator(), &out.writer, result, files.source(), facts_evidence.default_budget);
    const text = out.written();
    try testing.expectEqual(answer.Status.complete, rendered.status);
    try testing.expect(std.mem.endsWith(u8, text, facts_evidence.closed_footer));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, " typed]"));
    try testing.expect(std.mem.startsWith(u8, text, "\u{2713} 2 callers in 2 files"));
    try testing.expect(std.mem.indexOf(u8, text, "b.ts:2  export function use(c: C)") != null);
}

test "facts evidence: a function that fits is shown whole with its line numbers and nothing is elided" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    _ = try repo.put("a.ts", "function g() { return 1; }\nexport function f(x: number) {\n  if (x > 1) {\n    return g();\n  }\n  return 0;\n}\n");
    try repo.linkAll();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try ask(arena.allocator(), &repo, .callees, "f");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var files: RepoFiles = .{ .repo = &repo };
    const rendered = try facts_evidence.render(arena.allocator(), &out.writer, result, files.source(), facts_evidence.default_budget);
    const text = out.written();
    try testing.expect(!rendered.elided);
    try testing.expectEqual(answer.Status.complete, rendered.status);
    for ([_][]const u8{ "     2  export function f(x: number) {", "     3    if (x > 1) {", "     4      return g();", "     6    return 0;", "     7  }" }) |line| {
        if (std.mem.indexOf(u8, text, line) == null) {
            std.debug.print("missing line {s} in\n{s}\n", .{ line, text });
            return error.LineMissing;
        }
    }
    try testing.expect(std.mem.indexOf(u8, text, "elided") == null);
}

test "facts evidence: a function over the budget keeps the whole block around each call, declares every elided range and turns the answer partial" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "function target() { return 1; }\nfunction unused(): number { return 0; }\nexport function big(x: number) {\n  for (let i = 0; i < x; i++) {\n");
    for (0..150) |_| try source.appendSlice(testing.allocator, "    x = x + i * 2 + 1;\n");
    try source.appendSlice(testing.allocator, "    if (i > 3) {\n      target();\n    }\n");
    for (0..150) |_| try source.appendSlice(testing.allocator, "    x = x + i * 2 + 1;\n");
    try source.appendSlice(testing.allocator, "  }\n  return x;\n}\n");
    _ = try repo.put("a.ts", source.items);
    try repo.linkAll();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try facts_query.run(arena.allocator(), &repo.store, context, .{ .relation = .callees, .subject = "big" });
    try testing.expectEqual(answer.Status.complete, result.status());
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var files: RepoFiles = .{ .repo = &repo };
    const rendered = try facts_evidence.render(arena.allocator(), &out.writer, result, files.source(), facts_evidence.default_budget);
    const text = out.written();
    try testing.expect(text.len <= facts_evidence.default_budget);
    try testing.expect(rendered.elided);
    try testing.expectEqual(answer.Status.partial, rendered.status);
    try testing.expect(std.mem.startsWith(u8, text, "partial:"));
    for ([_][]const u8{ "   155      if (i > 3) {", "   156        target();", "   157      }", "     4    for (let i = 0; i < x; i++) {", "   308    }", "   310  }", "... 150 lines elided (5-154)", "... 150 lines elided (158-307)", "... 1 lines elided (309-309)" }) |line| {
        if (std.mem.indexOf(u8, text, line) == null) {
            std.debug.print("missing {s} in\n{s}\n", .{ line, text });
            return error.LineMissing;
        }
    }
    try testing.expect(std.mem.indexOf(u8, text, "emetgate_read_symbol {\"file\":\"a.ts\",\"symbol\":\"big\"}") != null);
}

test "facts evidence: a complete answer whose lines do not all fit turns partial and says how many were cut" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    _ = try repo.put("a.ts", "export function f() { return 1; }\n");
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "import { f } from \"./a\";\nexport function many() {\n");
    for (0..150) |_| try source.appendSlice(testing.allocator, "  f();\n");
    try source.appendSlice(testing.allocator, "}\n");
    _ = try repo.put("b.ts", source.items);
    try repo.linkAll();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try ask(arena.allocator(), &repo, .callers, "f");
    try testing.expectEqual(answer.Status.complete, result.status());
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var files: RepoFiles = .{ .repo = &repo };
    const rendered = try facts_evidence.render(arena.allocator(), &out.writer, result, files.source(), facts_evidence.min_budget);
    try testing.expect(rendered.cut > 0);
    try testing.expectEqual(answer.Status.partial, rendered.status);
    try testing.expect(std.mem.startsWith(u8, out.written(), "partial:"));
    try testing.expect(std.mem.indexOf(u8, out.written(), "budget") != null);
}
