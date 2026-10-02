const std = @import("std");
const emetgate = @import("emetgate");
const facts = emetgate.facts;
const facts_evidence = emetgate.facts_evidence;
const map = emetgate.map;
const map_listing = emetgate.map_listing;
const map_delta = emetgate.map_delta;
const answer = emetgate.answer;
const registry = emetgate.lang_registry;
const test_util = emetgate.test_util;
const Repo = @import("facts_repo.zig").Repo;

const testing = std.testing;
const Allocator = std.mem.Allocator;

const decorators_ts =
    \\export function Get(path: string) { return (target: any) => target; }
    \\export function Post(path: string) { return (target: any) => target; }
    \\export function Controller(path: string) { return (target: any) => target; }
    \\export function Command(options: object) { return (target: any) => target; }
    \\
;

const controller_ts =
    \\import { Get, Post, Controller } from "./decorators";
    \\import { UserService } from "./user.service";
    \\@Controller("/users")
    \\export class UsersController {
    \\  constructor(private readonly users: UserService) {}
    \\  /** Lists every user of the account. */
    \\  @Get("/")
    \\  list() { return this.users.all(); }
    \\  // Creates one user.
    \\  @Post("/")
    \\  create(name: string): string { return this.users.add(name); }
    \\}
    \\
;

const service_ts =
    \\import { load, save } from "./store";
    \\export class UserService {
    \\  all() { return load(); }
    \\  add(name: string) { return save(name); }
    \\}
    \\
;

const store_ts =
    \\export function load(): string[] { return []; }
    \\export function save(name: string) { return name; }
    \\export function reindexEverything(limit: number) { return load().slice(0, limit); }
    \\
;

const command_ts =
    \\import { Command } from "./decorators";
    \\import { reindexEverything } from "./store";
    \\@Command({ name: "reindex" })
    \\export class ReindexCommand {
    \\  run() { return reindexEverything(10); }
    \\}
    \\
;

const test_ts =
    \\import { UserService } from "../user.service";
    \\export function exercise() { return new UserService().all(); }
    \\
;

fn fixture(repo: *Repo) !void {
    _ = try repo.put("src/api/decorators.ts", decorators_ts);
    _ = try repo.put("src/api/users.controller.ts", controller_ts);
    _ = try repo.put("src/api/user.service.ts", service_ts);
    _ = try repo.put("src/api/store.ts", store_ts);
    _ = try repo.put("src/cli/reindex.command.ts", command_ts);
    _ = try repo.put("src/api/__tests__/user.service.test.ts", test_ts);
    try repo.linkAll();
}

fn allSymbols(arena: Allocator, repo: *const Repo) ![]u64 {
    var out: std.ArrayList(u64) = .empty;
    for (repo.store.files.items, 0..) |state, id| {
        if (state.status != .indexed) continue;
        for (state.facts.defs, 0..) |d, di| {
            if (d.kind == .module) continue;
            try out.append(arena, (map.SymbolId{ .file = @intCast(id), .slot = state.slots[di] }).key());
        }
    }
    std.mem.sort(u64, out.items, {}, std.sort.asc(u64));
    return out.items;
}

fn regionSymbols(arena: Allocator, built: map.Map) ![]u64 {
    var out: std.ArrayList(u64) = .empty;
    for (built.regions) |r| {
        for (r.symbols) |s| try out.append(arena, s.key());
    }
    std.mem.sort(u64, out.items, {}, std.sort.asc(u64));
    return out.items;
}

const Sources = struct {
    repo: *Repo,

    fn source(self: *Sources) facts_evidence.Source {
        return .{ .ctx = self, .fileFn = fileOf };
    }

    fn fileOf(ctx: *anyopaque, path: []const u8) facts_evidence.SourceError!facts_evidence.File {
        const self: *Sources = @ptrCast(@alignCast(ctx));
        const bytes = self.repo.sources.get(path) orelse return error.Unavailable;
        const profile = registry.forPath(path) orelse return error.Unavailable;
        return .{ .bytes = bytes, .profile = profile };
    }
};

fn context() map_listing.Context {
    return .{ .snapshot = .{ .barrier = 1, .root = answer.contentDigest("map test") } };
}

fn regionOf(built: map.Map, path: []const u8) !map.RegionId {
    return built.regionOfPath(path) orelse error.NoRegion;
}

test "map: every symbol of the store is in exactly one region and every region is in the text" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    try fixture(&repo);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]u32{ 40, 120, 100_000 }) |capacity| {
        const built = try map.buildMap(arena, &repo.store, .{ .region_chars = capacity, .budget_tokens = 4_000 });
        try testing.expectEqualSlices(u64, try allSymbols(arena, &repo), try regionSymbols(arena, built));
        for (built.regions) |r| {
            const line = try std.fmt.allocPrint(arena, "\nr{d} ", .{r.id + 1});
            try testing.expect(std.mem.indexOf(u8, built.text, line) != null);
            if (r.listing_chars > built.stats.region_chars) try testing.expectEqual(@as(usize, 1), r.files.len);
        }
    }
}

test "map: test files are kept in test regions apart from the code they exercise" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    try fixture(&repo);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const built = try map.buildMap(arena_state.allocator(), &repo.store, .{});
    const tests = built.regions[try regionOf(built, "src/api/__tests__/user.service.test.ts")];
    try testing.expectEqual(map.Family.tests, tests.family);
    try testing.expectEqual(map.Family.code, built.regions[try regionOf(built, "src/api/store.ts")].family);
    try testing.expect(std.mem.indexOf(u8, built.text, "# Tests\n") != null);
}

test "map: the text is the same bytes on every build of the same snapshot" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    try fixture(&repo);
    var first_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer first_arena.deinit();
    var second_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer second_arena.deinit();
    for ([_]u32{ 300, 4_000 }) |budget| {
        const one = try map.buildMap(first_arena.allocator(), &repo.store, .{ .budget_tokens = budget, .region_chars = 120 });
        const two = try map.buildMap(second_arena.allocator(), &repo.store, .{ .budget_tokens = budget, .region_chars = 120 });
        try testing.expectEqualStrings(one.text, two.text);
    }
}

test "map: a small project is mapped symbol by symbol and says so" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    try fixture(&repo);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const built = try map.buildMap(arena_state.allocator(), &repo.store, .{ .budget_tokens = 4_000 });
    try testing.expect(built.stats.complete);
    try testing.expect(std.mem.indexOf(u8, built.text, "every symbol is listed") != null);
    for (repo.store.files.items) |state| {
        if (state.status != .indexed) continue;
        if (std.mem.indexOf(u8, state.path, "__tests__") != null) continue;
        for (state.facts.defs) |d| {
            if (d.kind == .module) continue;
            if (std.mem.indexOf(u8, built.text, d.name) == null) {
                std.debug.print("missing {s}\n", .{d.qname});
                return error.SymbolNotInMap;
            }
        }
    }
}

fn manyFunctions(repo: *Repo, files: usize, per_file: usize) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (0..files) |f| {
        var source: std.ArrayList(u8) = .empty;
        for (0..per_file) |i| {
            if (i == 0) {
                try source.appendSlice(arena, try std.fmt.allocPrint(arena, "export function hub{d}() {{ return 0; }}\n", .{f}));
                continue;
            }
            try source.appendSlice(arena, try std.fmt.allocPrint(arena, "export function placeholderStep{d}x{d}(value: number) {{ return hub{d}() + value; }}\n", .{ f, i, f }));
        }
        _ = try repo.put(try std.fmt.allocPrint(arena, "pkg/module{d}/steps.ts", .{f}), source.items);
    }
    try repo.linkAll();
}

test "map: a large project stays inside the token budget and names its most called symbols first" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    try manyFunctions(&repo, 12, 30);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const options: map.MapOptions = .{ .budget_tokens = 700, .region_chars = 900, .chars_per_token = 3.3 };
    const built = try map.buildMap(arena, &repo.store, options);
    try testing.expect(!built.stats.complete);
    try testing.expect(@as(f64, @floatFromInt(built.text.len)) <= @as(f64, @floatFromInt(options.budget_tokens)) * options.chars_per_token);
    try testing.expect(built.stats.names > 0);
    for (0..12) |f| {
        const hub = try std.fmt.allocPrint(arena, "hub{d}", .{f});
        try testing.expect(std.mem.indexOf(u8, built.text, hub) != null);
    }
    const tighter = try map.buildMap(arena, &repo.store, .{ .budget_tokens = 450, .region_chars = 900, .chars_per_token = 3.3 });
    try testing.expect(tighter.text.len < built.text.len);
}

test "map: a heavy file that its region path does not show is named on the region line" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "alpha", "beta", "delta", "epsilon", "eta", "iota", "kappa" }) |name| {
        const path = try std.fmt.allocPrint(arena, "pkg/{s}.ts", .{name});
        _ = try repo.put(path, try std.fmt.allocPrint(arena, "export function {s}Only() {{ return 1; }}\n", .{name}));
    }
    var heavy: std.ArrayList(u8) = .empty;
    for (0..24) |i| try heavy.appendSlice(arena, try std.fmt.allocPrint(arena, "export function step{d}(x: number) {{ const y = x * {d}; const z = y + {d}; return z - x + y * z; }}\n", .{ i, i, i }));
    _ = try repo.put("pkg/gamma.ts", heavy.items);
    try repo.linkAll();
    const built = try map.buildMap(arena, &repo.store, .{ .budget_tokens = 200, .region_chars = 700, .chars_per_token = 3.3 });
    try testing.expect(!built.stats.complete);
    const region = built.regions[try regionOf(built, "pkg/gamma.ts")];
    try testing.expect(std.mem.indexOf(u8, region.label, "gamma") == null);
    const line_start = std.mem.indexOf(u8, built.text, try std.fmt.allocPrint(arena, "\nr{d} ", .{region.id + 1})).? + 1;
    const line_end = std.mem.indexOfScalarPos(u8, built.text, line_start, '\n').?;
    try testing.expect(std.mem.indexOf(u8, built.text[line_start..line_end], "[gamma") != null);
    try testing.expect(built.stats.files_named >= 1);
}

test "map: symbols that share one name in a region are named once" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (0..5) |i| {
        _ = try repo.put(try std.fmt.allocPrint(arena, "scripts/task{d}.ts", .{i}), "export function main() { return 1; }\n");
    }
    try repo.linkAll();
    const built = try map.buildMap(arena, &repo.store, .{});
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, built.text, "main"));
}

test "map: route, command and api entry points come from decorators and cross region calls" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    try fixture(&repo);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const built = try map.buildMap(arena_state.allocator(), &repo.store, .{ .region_chars = 200 });
    try testing.expect(std.mem.indexOf(u8, built.text, "GET list") != null);
    try testing.expect(std.mem.indexOf(u8, built.text, "POST create") != null);
    try testing.expect(std.mem.indexOf(u8, built.text, "cmd ReindexCommand") != null);
    const api_region = built.regions[try regionOf(built, "src/api/store.ts")];
    var routes: usize = 0;
    var api: usize = 0;
    for (built.regions) |r| {
        for (r.entry_points) |e| switch (e.kind) {
            .route => routes += 1,
            .api => api += 1,
            else => {},
        };
    }
    try testing.expect(routes >= 2);
    try testing.expect(api >= 1 or api_region.entry_points.len == 0);
}

test "map listing: a region that fits is listed whole with signatures and first doc lines" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    try fixture(&repo);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const built = try map.buildMap(arena, &repo.store, .{ .region_chars = 100_000 });
    var sources: Sources = .{ .repo = &repo };
    const region = try regionOf(built, "src/api/users.controller.ts");
    const listed = try map_listing.regionListing(arena, &repo.store, &built, region, context(), .{ .source = sources.source() });
    try testing.expectEqual(answer.Status.complete, listed.status());
    const value = listed.complete.value;
    try testing.expectEqual(map_listing.Level.full, value.level);
    try testing.expect(value.next == null);
    try testing.expect(std.mem.indexOf(u8, value.text, "\napi/\ndecorators.ts\n") != null);
    try testing.expect(std.mem.indexOf(u8, value.text, "\nusers.controller.ts\n") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, value.text, "api/"));
    try testing.expect(std.mem.indexOf(u8, value.text, "  8 method UsersController.list() - Lists every user of the account.\n") != null);
    try testing.expect(std.mem.indexOf(u8, value.text, "UsersController.create(name: string): string - Creates one user.") != null);
    try testing.expect(std.mem.indexOf(u8, value.text, "\u{2713}") != null);
}

test "map listing: a region over the budget is paged, every page declares the cut, and the pages cover it exactly once" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    try manyFunctions(&repo, 2, 60);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const built = try map.buildMap(arena, &repo.store, .{ .region_chars = 1_000_000 });
    try testing.expectEqual(@as(usize, 1), built.regions.len);
    var offset: u32 = 0;
    var seen: usize = 0;
    var pages: usize = 0;
    while (true) {
        const page = try map_listing.regionListing(arena, &repo.store, &built, 0, context(), .{ .budget = 1_200, .offset = offset });
        pages += 1;
        const value = switch (page) {
            .partial => |p| p.value,
            .complete => |c| c.value,
            .refused => return error.Refused,
        };
        try testing.expect(value.text.len <= 1_200 + 200);
        seen += value.shown;
        if (value.next) |next| {
            try testing.expectEqual(answer.Status.partial, page.status());
            try testing.expect(std.mem.indexOf(u8, value.text, "next page") != null);
            var budget_cut = false;
            for (page.missingList()) |m| {
                if (m.reason == .budget) budget_cut = true;
            }
            try testing.expect(budget_cut);
            offset = next;
        } else break;
    }
    try testing.expect(pages > 2);
    try testing.expectEqual(@as(usize, 120), seen);
}

test "map listing: an unknown region and an offset past the end are refused" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    try fixture(&repo);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const built = try map.buildMap(arena, &repo.store, .{});
    const unknown = try map_listing.regionListing(arena, &repo.store, &built, 999, context(), .{});
    try testing.expectEqual(error.UnknownRegion, unknown.refused.code);
    const past = try map_listing.regionListing(arena, &repo.store, &built, 0, context(), .{ .offset = 10_000 });
    try testing.expectEqual(error.OffsetOutOfRange, past.refused.code);
}

test "map delta: an unchanged store has no delta, and added, removed and changed symbols are reported by region" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    try fixture(&repo);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const built = try map.buildMap(arena, &repo.store, .{});
    const quiet = try map_delta.mapDelta(arena, &repo.store, &built);
    try testing.expect(quiet.unchanged);
    try testing.expectEqualStrings("", quiet.text);

    const id = try repo.put("src/api/store.ts", "export function load(): string[] { return [\"x\"]; }\nexport function purge() { return 0; }\n");
    _ = try repo.store.relink(&.{id}, &.{id}, repo.resolver());
    const delta = try map_delta.mapDelta(arena, &repo.store, &built);
    try testing.expect(!delta.unchanged);
    try testing.expectEqual(@as(u32, 1), delta.added);
    try testing.expectEqual(@as(u32, 2), delta.removed);
    try testing.expectEqual(@as(u32, 1), delta.changed);
    try testing.expect(std.mem.indexOf(u8, delta.text, " api/store.ts: ") != null);
    try testing.expect(std.mem.indexOf(u8, delta.text, "+purge 2") != null);
    try testing.expect(std.mem.indexOf(u8, delta.text, "-save") != null);
    try testing.expect(std.mem.indexOf(u8, delta.text, "-reindexEverything") != null);
    try testing.expect(std.mem.indexOf(u8, delta.text, "~load 1") != null);
    const region = try regionOf(built, "src/api/store.ts");
    for (delta.changes) |c| try testing.expectEqual(@as(?map.RegionId, region), c.region);
}

test "map delta: a new file and a removed file are both reported" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    try fixture(&repo);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const built = try map.buildMap(arena, &repo.store, .{});
    const added = try repo.put("src/api/audit.ts", "export function auditTrail() { return 1; }\n");
    const gone = repo.store.fileId("src/cli/reindex.command.ts").?;
    _ = try repo.store.remove(gone);
    _ = try repo.store.relink(&.{added}, &.{ added, gone }, repo.resolver());
    const delta = try map_delta.mapDelta(arena, &repo.store, &built);
    try testing.expect(std.mem.indexOf(u8, delta.text, "+auditTrail") != null);
    try testing.expect(std.mem.indexOf(u8, delta.text, "-ReindexCommand") != null);
    try testing.expect(std.mem.indexOf(u8, delta.text, "-ReindexCommand.run") != null);
    try testing.expectEqual(@as(u32, 1), delta.added);
    try testing.expectEqual(@as(u32, 2), delta.removed);
}

test "map delta: a delta over the character limit is summarized by region and points to the region listing" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    try manyFunctions(&repo, 4, 3);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const built = try map.buildMap(arena, &repo.store, .{});
    var source: std.ArrayList(u8) = .empty;
    for (0..150) |i| try source.appendSlice(arena, try std.fmt.allocPrint(arena, "export function freshlyAddedFunctionNumber{d}() {{ return {d}; }}\n", .{ i, i }));
    const id = try repo.put("pkg/module1/steps.ts", source.items);
    _ = try repo.store.relink(&.{id}, &.{id}, repo.resolver());
    const delta = try map_delta.mapDelta(arena, &repo.store, &built);
    try testing.expect(delta.summarized);
    try testing.expect(delta.text.len <= map_delta.max_chars);
    try testing.expectEqual(@as(u32, 150), delta.added);
    try testing.expect(std.mem.indexOf(u8, delta.text, "emetgate_region") != null);
}
