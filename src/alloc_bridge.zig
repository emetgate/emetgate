const std = @import("std");
const c = @import("c");

const block_alignment: std.mem.Alignment = .fromByteUnits(@alignOf(std.c.max_align_t));
const header_len = block_alignment.toByteUnits();
const Block = []align(header_len) u8;

comptime {
    std.debug.assert(header_len >= @sizeOf(usize));
}

var backing: ?std.mem.Allocator = null;
var live_blocks: std.atomic.Value(usize) = .init(0);
var live_bytes: std.atomic.Value(usize) = .init(0);

pub const Stats = struct {
    blocks: usize,
    bytes: usize,
};

pub fn install(allocator: std.mem.Allocator) void {
    if (backing != null) @panic("tree-sitter allocator bridge is already installed");
    backing = allocator;
    c.ts_set_allocator(&tsMalloc, &tsCalloc, &tsRealloc, &tsFree);
}

pub fn uninstall() void {
    if (live_blocks.load(.acquire) != 0) @panic("tree-sitter allocator bridge uninstalled with live allocations");
    c.ts_set_allocator(null, null, null, null);
    backing = null;
}

pub fn stats() Stats {
    return .{
        .blocks = live_blocks.load(.acquire),
        .bytes = live_bytes.load(.acquire),
    };
}

fn tsMalloc(size: usize) callconv(.c) ?*anyopaque {
    return allocate(size).ptr;
}

fn tsCalloc(count: usize, size: usize) callconv(.c) ?*anyopaque {
    const total = std.math.mul(usize, count, size) catch outOfMemory();
    const payload = allocate(total);
    @memset(payload, 0);
    return payload.ptr;
}

fn tsRealloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    const old_block = blockOf(ptr orelse return tsMalloc(size));
    const old_size = payloadLen(old_block);
    const new_block = backingAllocator().realloc(old_block, blockLen(size)) catch outOfMemory();
    writeSize(new_block, size);
    _ = live_bytes.fetchSub(old_size, .monotonic);
    _ = live_bytes.fetchAdd(size, .monotonic);
    return new_block[header_len..].ptr;
}

fn tsFree(ptr: ?*anyopaque) callconv(.c) void {
    const block = blockOf(ptr orelse return);
    _ = live_blocks.fetchSub(1, .monotonic);
    _ = live_bytes.fetchSub(payloadLen(block), .monotonic);
    backingAllocator().free(block);
}

fn allocate(size: usize) []u8 {
    const block = backingAllocator().alignedAlloc(u8, block_alignment, blockLen(size)) catch outOfMemory();
    writeSize(block, size);
    _ = live_blocks.fetchAdd(1, .monotonic);
    _ = live_bytes.fetchAdd(size, .monotonic);
    return block[header_len..];
}

fn blockOf(payload: *anyopaque) Block {
    const base: [*]align(header_len) u8 = @ptrFromInt(@intFromPtr(payload) - header_len);
    const size = @as(*const usize, @ptrCast(base)).*;
    return base[0 .. header_len + size];
}

fn writeSize(block: Block, size: usize) void {
    @as(*usize, @ptrCast(block.ptr)).* = size;
}

fn payloadLen(block: Block) usize {
    return block.len - header_len;
}

fn blockLen(size: usize) usize {
    return std.math.add(usize, header_len, size) catch outOfMemory();
}

fn backingAllocator() std.mem.Allocator {
    return backing orelse @panic("tree-sitter allocated through an uninstalled bridge");
}

fn outOfMemory() noreturn {
    @panic("tree-sitter allocation failed: out of memory");
}

const testing = std.testing;

fn slotsOf(ptr: ?*anyopaque) [*]u64 {
    return @ptrCast(@alignCast(ptr.?));
}

test "calloc zeroes, realloc preserves contents across grow and shrink, free releases" {
    install(testing.allocator);
    defer uninstall();

    const zeroed = slotsOf(tsCalloc(4, @sizeOf(u64)));
    for (zeroed[0..4]) |slot| try testing.expectEqual(@as(u64, 0), slot);
    for (zeroed[0..4], 1..) |*slot, value| slot.* = value;
    try testing.expectEqual(Stats{ .blocks = 1, .bytes = 32 }, stats());

    const grown = slotsOf(tsRealloc(zeroed, 64 * @sizeOf(u64)));
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4 }, grown[0..4]);
    try testing.expectEqual(Stats{ .blocks = 1, .bytes = 512 }, stats());

    const shrunk = slotsOf(tsRealloc(grown, 2 * @sizeOf(u64)));
    try testing.expectEqualSlices(u64, &.{ 1, 2 }, shrunk[0..2]);
    try testing.expectEqual(Stats{ .blocks = 1, .bytes = 16 }, stats());

    tsFree(shrunk);
    try testing.expectEqual(Stats{ .blocks = 0, .bytes = 0 }, stats());
}

test "null realloc allocates, null free is a no-op, zero-size blocks are unique" {
    install(testing.allocator);
    defer uninstall();

    const from_null = tsRealloc(null, 8);
    const empty_a = tsMalloc(0);
    const empty_b = tsMalloc(0);
    try testing.expect(empty_a != empty_b);
    try testing.expectEqual(Stats{ .blocks = 3, .bytes = 8 }, stats());

    tsFree(null);
    tsFree(from_null);
    tsFree(empty_a);
    tsFree(empty_b);
    try testing.expectEqual(Stats{ .blocks = 0, .bytes = 0 }, stats());
}

test "payloads honour max_align_t" {
    install(testing.allocator);
    defer uninstall();

    const ptr = tsMalloc(3).?;
    defer tsFree(ptr);
    try testing.expect(block_alignment.check(@intFromPtr(ptr)));
}
