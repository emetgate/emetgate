const std = @import("std");
const emetgate = @import("emetgate");
const rank = emetgate.map_region_rank;
const fixture = @import("map_fixture.zig");
const Fixture = fixture.Fixture;
const position = fixture.position;

const testing = std.testing;

test "map rank region: the function whose name, owner and body hold the question terms ranks first" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.load();
    const english = try f.ranked("Which code decides whether the workflow continues when a node error happens?");
    try testing.expectEqualStrings("WorkflowRunner.handleNodeError", english.hits[0].qname);
    const retry = try f.ranked("When is a failed call retried and when does the retry give up?");
    try testing.expect(position(retry, "RetryPolicy.shouldRetry").? < 2);
    try testing.expect(position(retry, "runWithRetry").? < 2);
}

test "map rank region: a turkish question reaches the english code terms through the lexicon" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.load();
    const ranked = try f.ranked("Hata verince devam ediliyor mu?");
    try testing.expectEqualStrings("WorkflowRunner.handleNodeError", ranked.hits[0].qname);
    try testing.expect(ranked.hits[0].matched != 0);
}

test "map rank region: every function of the region is ranked once, best first, and the order is the same on every run" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.load();
    const one = try f.ranked("format the output items of a node");
    const two = try f.ranked("format the output items of a node");
    try testing.expectEqual(one.candidates, @as(u32, @intCast(one.hits.len)));
    try testing.expect(one.candidates >= 8);
    for (one.hits[1..], one.hits[0 .. one.hits.len - 1]) |b, a| try testing.expect(a.score >= b.score);
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(testing.allocator);
    for (one.hits, two.hits) |a, b| {
        try testing.expectEqualStrings(a.qname, b.qname);
        try testing.expectEqual(a.score, b.score);
        const entry = try seen.getOrPut(testing.allocator, a.symbol.key());
        try testing.expect(!entry.found_existing);
    }
    try testing.expectEqualStrings("WorkflowRunner.formatOutput", one.hits[0].qname);
}

test "map rank region: terms that meet on one line outrank the same terms far apart" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.load();
    const ranked = try f.ranked("alpha and beta");
    try testing.expect(position(ranked, "termsClose").? < position(ranked, "termsApart").?);
}

test "map rank region: the names a function calls in its body count for it and for the functions around it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.load();
    const ranked = try f.ranked("escape markup");
    try testing.expectEqualStrings("WorkflowRunner.formatOutput", ranked.hits[0].qname);
    try testing.expect(ranked.hits[0].matched != 0 and ranked.hits[1].matched == 0);
    const nested = try f.ranked("measure");
    try testing.expect(position(nested, "outerPlanner").? < 2);
    try testing.expect(nested.hits[0].matched != 0 and nested.hits[1].matched != 0);
}

test "map rank region: the property names a file reads count for the functions of that file" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.load();
    const ranked = try f.ranked("continueOnFail");
    try testing.expectEqualStrings("WorkflowRunner.handleNodeError", ranked.hits[0].qname);
    for (ranked.hits[0..3]) |hit| {
        try testing.expect(hit.matched != 0);
        try testing.expectEqualStrings("src/run/workflow.ts", hit.path);
    }
    try testing.expect(ranked.hits[3].matched == 0);
}

test "map rank region: a term few functions hold weighs more than a term many hold" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.load();
    const ranked = try f.ranked("shared thing or unique thing");
    try testing.expect(position(ranked, "rarestPick").? < position(ranked, "commonPick").?);
}

test "map rank region: an unknown region is refused" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.load();
    const t = try f.terms("anything");
    try testing.expectError(error.UnknownRegion, rank.rankInRegion(f.arena(), &f.repo.store, &f.built, @intCast(f.built.regions.len), &t, .{}));
}
