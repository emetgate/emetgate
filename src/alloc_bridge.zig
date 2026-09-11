const std = @import("std");
const c = @import("c");

const min_malloc_alignment = 16;
const block_alignment: std.mem.Alignment = .fromByteUnits(@max(@alignOf(std.c.max_align_t), min_malloc_alignment));
const header_len = block_alignment.toByteUnits();
const Block = []align(header_len) u8;

const Header = extern struct {
    size: usize,
    magic: usize,
};

const live_magic: usize = @truncate(0x53594E4150534521);

comptime {
    std.debug.assert(@sizeOf(Header) <= header_len);
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
    headerOf(new_block).size = size;
    _ = live_bytes.fetchSub(old_size, .monotonic);
    _ = live_bytes.fetchAdd(size, .monotonic);
    return new_block[header_len..].ptr;
}

fn tsFree(ptr: ?*anyopaque) callconv(.c) void {
    const block = blockOf(ptr orelse return);
    headerOf(block).magic = 0;
    _ = live_blocks.fetchSub(1, .monotonic);
    _ = live_bytes.fetchSub(payloadLen(block), .monotonic);
    backingAllocator().free(block);
}

fn allocate(size: usize) []u8 {
    const block = backingAllocator().alignedAlloc(u8, block_alignment, blockLen(size)) catch outOfMemory();
    headerOf(block).* = .{ .size = size, .magic = live_magic };
    _ = live_blocks.fetchAdd(1, .monotonic);
    _ = live_bytes.fetchAdd(size, .monotonic);
    return block[header_len..];
}

fn blockOf(payload: *anyopaque) Block {
    const base: [*]align(header_len) u8 = @ptrFromInt(@intFromPtr(payload) - header_len);
    const header: *const Header = @ptrCast(base);
    if (header.magic != live_magic) @panic("tree-sitter released a pointer the bridge does not own");
    return base[0 .. header_len + header.size];
}

fn headerOf(block: Block) *Header {
    return @ptrCast(block.ptr);
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

    var slots = slotsOf(tsCalloc(4, @sizeOf(u64)));
    errdefer tsFree(slots);
    for (slots[0..4]) |slot| try testing.expectEqual(@as(u64, 0), slot);
    for (slots[0..4], 1..) |*slot, value| slot.* = value;
    try testing.expectEqual(Stats{ .blocks = 1, .bytes = 32 }, stats());

    slots = slotsOf(tsRealloc(slots, 64 * @sizeOf(u64)));
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4 }, slots[0..4]);
    try testing.expectEqual(Stats{ .blocks = 1, .bytes = 512 }, stats());

    slots = slotsOf(tsRealloc(slots, 2 * @sizeOf(u64)));
    try testing.expectEqualSlices(u64, &.{ 1, 2 }, slots[0..2]);
    try testing.expectEqual(Stats{ .blocks = 1, .bytes = 16 }, stats());

    tsFree(slots);
    try testing.expectEqual(Stats{ .blocks = 0, .bytes = 0 }, stats());
}

test "null realloc allocates, zero realloc keeps a live block, null free is a no-op" {
    install(testing.allocator);
    defer uninstall();

    const from_null = tsRealloc(null, 8);
    defer tsFree(from_null);
    const shrunk_to_zero = tsRealloc(tsMalloc(24), 0);
    defer tsFree(shrunk_to_zero);
    const empty_a = tsMalloc(0);
    defer tsFree(empty_a);
    const empty_b = tsMalloc(0);
    defer tsFree(empty_b);

    try testing.expect(shrunk_to_zero != null);
    try testing.expect(empty_a != empty_b);
    try testing.expectEqual(Stats{ .blocks = 4, .bytes = 8 }, stats());
    tsFree(null);
}

test "payloads honour the malloc alignment contract" {
    install(testing.allocator);
    defer uninstall();

    const ptr = tsMalloc(3).?;
    defer tsFree(ptr);
    try testing.expect(block_alignment.check(@intFromPtr(ptr)));
    try testing.expect(block_alignment.toByteUnits() >= min_malloc_alignment);
}
