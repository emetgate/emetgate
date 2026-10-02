const std = @import("std");
const emetgate = @import("emetgate");
const evidence = emetgate.evidence;
const facts_evidence = emetgate.facts_evidence;
const answer = emetgate.answer;
const map = emetgate.map;
const rank = emetgate.map_region_rank;
const question_lexicon = emetgate.question_lexicon;
const test_util = emetgate.test_util;
const Repo = @import("facts_repo.zig").Repo;

const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const workflow_ts =
    \\export class WorkflowRunner {
    \\  handleNodeError(node: { continueOnFail: boolean }, error: Error) {
    \\    if (node.continueOnFail) return { continueExecution: true };
    \\    return { continueExecution: false, error };
    \\  }
    \\  runNode(node: { name: string }) { return node.name; }
    \\  formatOutput(items: string[]) { return items.map((item) => escapeMarkup(item)).join(","); }
    \\}
    \\
;

const retry_ts =
    \\export class RetryPolicy {
    \\  constructor(private readonly limit: number) {}
    \\  shouldRetry(attempt: number, failure: Error): boolean {
    \\    if (failure.name === "AbortError") return false;
    \\    return attempt < this.limit;
    \\  }
    \\  delayFor(attempt: number): number { return 100 * attempt; }
    \\}
    \\export function runWithRetry(task: () => number, policy: RetryPolicy) {
    \\  let attempt = 0;
    \\  while (true) {
    \\    try { return task(); } catch (caught) {
    \\      attempt++;
    \\      if (!policy.shouldRetry(attempt, caught as Error)) throw caught;
    \\    }
    \\  }
    \\}
    \\
;

const near_ts =
    \\export function termsApart() {
    \\  alphaValue();
    \\  noopOne();
    \\  noopTwo();
    \\  noopThree();
    \\  betaValue();
    \\}
    \\export function termsClose() {
    \\  noopOne();
    \\  noopTwo();
    \\  alphaValue();
    \\  betaValue();
    \\  noopThree();
    \\}
    \\
;

const outer_ts =
    \\export function outerPlanner(steps: string[]) {
    \\  const plannerStep = (step: string) => measureStep(step);
    \\  return steps.map(plannerStep);
    \\}
    \\
;

const pick_ts =
    \\export function commonPick() { sharedThing(); }
    \\export function rarestPick() { uniqueThing(); }
    \\export function otherPickA() { sharedThing(); }
    \\export function otherPickB() { sharedThing(); }
    \\
;

pub const RepoFiles = struct {
    repo: *Repo,

    pub fn file(ctx: *anyopaque, path: []const u8) facts_evidence.SourceError!facts_evidence.File {
        const self: *RepoFiles = @ptrCast(@alignCast(ctx));
        const bytes = self.repo.sources.get(path) orelse return error.Vanished;
        const profile = emetgate.lang_registry.forPath(path) orelse return error.Vanished;
        return .{ .bytes = bytes, .profile = profile };
    }

    pub fn source(self: *RepoFiles) facts_evidence.Source {
        return .{ .ctx = self, .fileFn = file };
    }
};

pub const Fixture = struct {
    runtime: *emetgate.runtime.Runtime,
    repo: Repo,
    arena_state: std.heap.ArenaAllocator,
    files: RepoFiles = undefined,
    lex: *question_lexicon.Lexicon = undefined,
    built: map.Map = undefined,

    pub fn init(f: *Fixture) !void {
        f.runtime = try test_util.openRuntime();
        f.repo = Repo.init(f.runtime);
        f.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        f.files = .{ .repo = &f.repo };
        f.lex = try question_lexicon.Lexicon.parse(testing.allocator, question_lexicon.default_text);
    }

    pub fn deinit(f: *Fixture) void {
        f.lex.deinit();
        f.arena_state.deinit();
        f.repo.deinit();
        test_util.closeRuntime(f.runtime);
    }

    pub fn arena(f: *Fixture) Allocator {
        return f.arena_state.allocator();
    }

    pub fn load(f: *Fixture) !void {
        _ = try f.repo.put("src/run/workflow.ts", workflow_ts);
        _ = try f.repo.put("src/run/retry.ts", retry_ts);
        _ = try f.repo.put("src/run/near.ts", near_ts);
        _ = try f.repo.put("src/run/outer.ts", outer_ts);
        _ = try f.repo.put("src/run/pick.ts", pick_ts);
        try f.repo.linkAll();
        f.built = try map.buildMap(f.arena(), &f.repo.store, .{});
    }

    pub fn terms(f: *Fixture, question: []const u8) !rank.Terms {
        return rank.Terms.ofQuestion(f.arena(), f.lex, question);
    }

    pub fn region(f: *Fixture) !map.RegionId {
        return f.built.regionOfPath("src/run/workflow.ts") orelse error.NoRegion;
    }

    pub fn ranked(f: *Fixture, question: []const u8) !rank.Ranking {
        const t = try f.arena().create(rank.Terms);
        t.* = try f.terms(question);
        return rank.rankInRegion(f.arena(), &f.repo.store, &f.built, try f.region(), t, .{});
    }

    pub fn view(f: *Fixture) evidence.FactStore {
        return .{
            .arena = f.arena(),
            .store = &f.repo.store,
            .source = f.files.source(),
            .snapshot = .{ .barrier = 1, .root = answer.contentDigest("map explore test") },
            .max_file_bytes = 1024 * 1024,
            .largest_file_bytes = 100,
        };
    }
};

pub fn position(ranking: rank.Ranking, qname: []const u8) ?usize {
    for (ranking.hits, 0..) |hit, i| {
        if (std.mem.eql(u8, hit.qname, qname)) return i;
    }
    return null;
}
