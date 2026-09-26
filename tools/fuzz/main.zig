const std = @import("std");
const emetgate = @import("emetgate");

const regex = emetgate.regex;
const memory = emetgate.memory;
const server = emetgate.server;
const cas = emetgate.cas;
const symbol = emetgate.symbol;
const journal = emetgate.journal;
const lang_registry = emetgate.lang_registry;
const Snapshot = emetgate.loader.Snapshot;
const Runtime = emetgate.runtime.Runtime;

const regex_seeds = [_][]const u8{
    "a*", "(a|b)+", "[a-z]{2,5}", "\\d\\w\\s", "^abc$", ".", "a{1,3}",
};

const protocol_seeds = [_][]const u8{
    "{}",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"emetgate_git\",\"arguments\":{\"sub\":\"status\"}}}",
};

const cas_seeds = [_][]const u8{
    "", "{ return 3; }", "{ return 1;", "{ } function evil() {}", "\x00",
};
const cas_base_source = "function f() { return 1; }\nfunction g() { return 2; }\n";

const journal_seeds = [_][]const u8{
    "{\"version\":2,\"batch\":\"0123456789abcdef\",\"intents\":[{\"op\":\"delete\",\"target\":\"a\",\"base_hash\":\"00\"}]}",
    "{\"target\":\"a\",\"base_hash\":\"00\"}",
    "{\"version\":3}",
};

const ledger_seeds = [_][]const u8{
    "{\"id\":\"r1\",\"scope\":\"global\",\"text\":\"no eval\",\"enforce\":true,\"status\":\"active\",\"ts\":1}\n",
};

const max_mutated_len = 4096;

fn mutate(random: std.Random, seed: []const u8, buf: []u8) []u8 {
    const len = @min(seed.len, buf.len);
    @memcpy(buf[0..len], seed[0..len]);
    var n = len;
    const rounds = 1 + random.uintLessThan(u8, 6);
    var i: u8 = 0;
    while (i < rounds) : (i += 1) {
        if (n == 0) {
            if (buf.len == 0) break;
            buf[0] = random.int(u8);
            n = 1;
            continue;
        }
        switch (random.uintLessThan(u8, 4)) {
            0 => buf[random.uintLessThan(usize, n)] = random.int(u8),
            1 => {
                if (n < buf.len) {
                    const at = random.uintLessThan(usize, n + 1);
                    std.mem.copyBackwards(u8, buf[at + 1 .. n + 1], buf[at..n]);
                    buf[at] = random.int(u8);
                    n += 1;
                }
            },
            2 => {
                if (n > 1) {
                    const at = random.uintLessThan(usize, n);
                    std.mem.copyForwards(u8, buf[at .. n - 1], buf[at + 1 .. n]);
                    n -= 1;
                }
            },
            3 => n = random.uintLessThan(usize, n + 1),
            else => unreachable,
        }
    }
    return buf[0..n];
}

fn notDone(io: std.Io, deadline: std.Io.Timestamp) bool {
    return std.Io.Timestamp.now(io, .awake).nanoseconds < deadline.nanoseconds;
}

fn runRegex(random: std.Random, io: std.Io, deadline: std.Io.Timestamp, buf: []u8, gpa: std.mem.Allocator) usize {
    var iterations: usize = 0;
    while (notDone(io, deadline)) : (iterations += 1) {
        const seed = regex_seeds[random.uintLessThan(usize, regex_seeds.len)];
        const input = mutate(random, seed, buf);
        std.debug.print("\rregex last input: {any}          ", .{input});
        var diag: regex.Diagnostic = .{};
        var compiled = regex.Regex.compile(gpa, input, &diag) catch continue;
        defer compiled.deinit(gpa);
        var budget: u64 = 10_000;
        _ = compiled.isMatch(gpa, "the quick brown fox jumps over 12345", &budget) catch {};
    }
    return iterations;
}

fn runProtocol(random: std.Random, io: std.Io, deadline: std.Io.Timestamp, buf: []u8, gpa: std.mem.Allocator, runtime: *Runtime) usize {
    var iterations: usize = 0;
    while (notDone(io, deadline)) : (iterations += 1) {
        const seed = protocol_seeds[random.uintLessThan(usize, protocol_seeds.len)];
        const input = mutate(random, seed, buf);
        std.debug.print("\rprotocol last input: {any}          ", .{input});
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        _ = server.handleMessage(gpa, io, runtime, input, &out.writer) catch {};
    }
    return iterations;
}

fn runCas(random: std.Random, io: std.Io, deadline: std.Io.Timestamp, buf: []u8, gpa: std.mem.Allocator) !usize {
    var iterations: usize = 0;
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch {};
    while (notDone(io, deadline)) : (iterations += 1) {
        const seed = cas_seeds[random.uintLessThan(usize, cas_seeds.len)];
        const input = mutate(random, seed, buf);
        std.debug.print("\rcas last input: {any}          ", .{input});
        const source = try gpa.dupe(u8, cas_base_source);
        const base = Snapshot.fromSource(runtime, lang_registry.profiles[0], source) catch continue;
        defer base.destroy();
        const table = base.symbols() catch continue;
        const ref: symbol.Ref = .{ .name = "f" };
        const target = table.resolve(ref) catch continue;
        const cut_start = target.body.startByte();
        const cut_end = target.body.endByte();

        const applied = cas.apply(base, .{ .ref = ref, .expected_hash = target.hash, .new_body = input }) catch continue;
        defer applied.snapshot.destroy();
        const out = applied.snapshot.source;
        const tail_len = cas_base_source.len - cut_end;
        if (!std.mem.eql(u8, cas_base_source[0..cut_start], out[0..cut_start]) or
            !std.mem.eql(u8, cas_base_source[cut_end..], out[out.len - tail_len ..]))
        {
            std.debug.print("\nBUG: cas.apply touched bytes outside the slot on input {any}\n", .{input});
            return error.InvariantViolated;
        }
    }
    return iterations;
}

fn runJournal(random: std.Random, io: std.Io, deadline: std.Io.Timestamp, buf: []u8, gpa: std.mem.Allocator) !usize {
    var iterations: usize = 0;
    while (notDone(io, deadline)) : (iterations += 1) {
        const seed = journal_seeds[random.uintLessThan(usize, journal_seeds.len)];
        const input = mutate(random, seed, buf);
        std.debug.print("\rjournal last input: {any}          ", .{input});
        const parsed = journal.parse(gpa, input) catch continue;
        defer parsed.deinit();
        switch (parsed) {
            .batch => |b| if (b.value.version != journal.version) {
                std.debug.print("\nBUG: journal.parse returned .batch for version {d}\n", .{b.value.version});
                return error.InvariantViolated;
            },
            .legacy => {},
        }
    }
    return iterations;
}

fn runLedger(random: std.Random, io: std.Io, deadline: std.Io.Timestamp, buf: []u8, gpa: std.mem.Allocator) usize {
    var iterations: usize = 0;
    while (notDone(io, deadline)) : (iterations += 1) {
        const seed = ledger_seeds[random.uintLessThan(usize, ledger_seeds.len)];
        const input = mutate(random, seed, buf);
        std.debug.print("\rledger last input: {any}          ", .{input});
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        _ = memory.parseLedger(arena_state.allocator(), input) catch {};
    }
    return iterations;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = std.heap.page_allocator;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: emetgate-fuzz <regex|protocol|ledger|cas|journal> [seconds]\n", .{});
        return 2;
    }
    const target = args[1];
    var seconds: i64 = 20;
    if (args.len > 2) seconds = std.fmt.parseInt(i64, args[2], 10) catch seconds;

    const now = std.Io.Timestamp.now(io, .awake);
    var prng = std.Random.DefaultPrng.init(@truncate(@as(u96, @bitCast(now.nanoseconds))));
    const random = prng.random();
    const deadline: std.Io.Timestamp = .{ .nanoseconds = now.nanoseconds + @as(i96, seconds) * std.time.ns_per_s };
    var buf: [max_mutated_len]u8 = undefined;

    const iterations = if (std.mem.eql(u8, target, "regex"))
        runRegex(random, io, deadline, &buf, gpa)
    else if (std.mem.eql(u8, target, "ledger"))
        runLedger(random, io, deadline, &buf, gpa)
    else if (std.mem.eql(u8, target, "protocol")) blk: {
        const runtime = try Runtime.create(gpa);
        defer runtime.destroy() catch {};
        break :blk runProtocol(random, io, deadline, &buf, gpa, runtime);
    } else if (std.mem.eql(u8, target, "cas"))
        try runCas(random, io, deadline, &buf, gpa)
    else if (std.mem.eql(u8, target, "journal"))
        try runJournal(random, io, deadline, &buf, gpa)
    else {
        std.debug.print("unknown target: {s}\n", .{target});
        return 2;
    };

    std.debug.print("\n{s}: {d} iterations in {d}s, no crash\n", .{ target, iterations, seconds });
    return 0;
}
