const std = @import("std");
const memory = @import("emetgate").memory;

const testing = std.testing;

const good_row = "{\"id\":\"r1\",\"scope\":\"global\",\"text\":\"no eval\",\"enforce\":true,\"status\":\"active\",\"ts\":1}\n";

const seed_corpus = [_][]const u8{
    "",
    "\n",
    "{}\n",
    "{}",
    good_row,
    good_row ++ good_row,
    good_row[0 .. good_row.len - 1],
    "\n" ++ good_row,
    good_row ++ "\n",
    "not json\n",
    "{\"id\":\"\",\"scope\":\"global\",\"text\":\"x\",\"enforce\":true,\"status\":\"active\",\"ts\":1}\n",
    "{\"id\":\"r1\",\"scope\":\"bogus\",\"text\":\"x\",\"enforce\":true,\"status\":\"active\",\"ts\":1}\n",
    "{\"id\":\"r1\",\"scope\":\"global\",\"text\":\"x\",\"enforce\":\"maybe\",\"status\":\"active\",\"ts\":1}\n",
    "{\"id\":\"r1\",\"scope\":\"global\",\"text\":\"\\u0000\",\"enforce\":true,\"status\":\"active\",\"ts\":1}\n",
    "{\"id\":\"r1\",\"scope\":\"global\",\"text\":\"x\",\"enforce\":true,\"status\":\"active\",\"ts\":1,\"supersedes\":\"r1\"}\n",
    good_row ++ "{\"id\":\"r1\",\"scope\":\"global\",\"text\":\"different\",\"enforce\":true,\"status\":\"active\",\"ts\":2}\n",
    "\xff\xfe\x00\x01\n",
    "{" ++ "\"a\":" ** 500 ++ "1" ++ "}" ** 500 ++ "\n",
};

fn testOne(_: void, smith: *testing.Smith) anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    _ = memory.parseLedger(arena_state.allocator(), smith.in.?) catch return;
}

test "fuzz: parseLedger never crashes or leaks on malformed ledger bytes" {
    try testing.fuzz({}, testOne, .{ .corpus = &seed_corpus });
}
