const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const commit_record = @import("commit_record.zig");
const disk = @import("disk.zig");

const Allocator = std.mem.Allocator;

pub const version: u32 = 2;
pub const max_bytes = 1024 * 1024;

pub const Op = enum { modify, create, delete };

pub const Intent = struct {
    op: Op,
    target: []const u8,
    tag: []const u8 = "",
    base_hash: ?symbol.Hash = null,
    new_hash: ?symbol.Hash = null,
};

pub fn write(gpa: Allocator, io: std.Io, journal_dir: []const u8, batch: []const u8, intents: []const Intent) ![]u8 {
    std.Io.Dir.cwd().createDirPath(io, journal_dir) catch {};
    const final = try std.fmt.allocPrint(gpa, "{s}\\{s}.json", .{ journal_dir, batch });
    errdefer gpa.free(final);
    const staged = try std.fmt.allocPrint(gpa, "{s}.tmp", .{final});
    defer gpa.free(staged);

    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    var js: std.json.Stringify = .{ .writer = &buffer.writer };
    try js.beginObject();
    try js.objectField("version");
    try js.write(version);
    try js.objectField("batch");
    try js.write(batch);
    try js.objectField("intents");
    try js.beginArray();
    for (intents) |intent| try writeIntent(&js, intent);
    try js.endArray();
    try js.endObject();

    try disk.writeDurably(io, staged, buffer.written());
    errdefer std.Io.Dir.deleteFileAbsolute(io, staged) catch {};
    try commit_record.moveDurably(staged, final);
    commit_record.flushDir(journal_dir) catch {};
    return final;
}

fn writeIntent(js: *std.json.Stringify, intent: Intent) !void {
    try js.beginObject();
    try js.objectField("op");
    try js.write(@tagName(intent.op));
    try js.objectField("target");
    try js.write(intent.target);
    if (intent.tag.len != 0) {
        try js.objectField("tag");
        try js.write(intent.tag);
    }
    if (intent.base_hash) |hash| {
        const hex = symbol.formatHash(hash);
        try js.objectField("base_hash");
        try js.write(hex[0..]);
    }
    if (intent.new_hash) |hash| {
        const hex = symbol.formatHash(hash);
        try js.objectField("new_hash");
        try js.write(hex[0..]);
    }
    try js.endObject();
}

pub const RawIntent = struct {
    op: []const u8 = "",
    target: []const u8 = "",
    tag: []const u8 = "",
    base_hash: []const u8 = "",
    new_hash: []const u8 = "",
};

pub const Batch = struct {
    version: u32 = 0,
    batch: []const u8 = "",
    intents: []const RawIntent = &.{},
};

pub const Legacy = struct {
    op: []const u8 = "modify",
    target: []const u8 = "",
    base_hash: []const u8 = "",
    new_hash: []const u8 = "",
    batch: []const u8 = "",
};

pub const Parsed = union(enum) {
    batch: std.json.Parsed(Batch),
    legacy: std.json.Parsed(Legacy),

    pub fn deinit(self: Parsed) void {
        switch (self) {
            inline else => |p| p.deinit(),
        }
    }
};

const Probe = struct {
    version: u32 = 1,
};

pub fn parse(gpa: Allocator, bytes: []const u8) !Parsed {
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const probe = std.json.parseFromSlice(Probe, gpa, bytes, options) catch return error.CorruptJournal;
    defer probe.deinit();
    if (probe.value.version == version) {
        return .{ .batch = std.json.parseFromSlice(Batch, gpa, bytes, options) catch return error.CorruptJournal };
    }
    if (probe.value.version != 1) return error.CorruptJournal;
    return .{ .legacy = std.json.parseFromSlice(Legacy, gpa, bytes, options) catch return error.CorruptJournal };
}

const testing = std.testing;

test "journal: a v2 journal and a per-file journal from before v2 both parse" {
    const v2 = try parse(testing.allocator, "{\"version\":2,\"batch\":\"0123456789abcdef\",\"intents\":[{\"op\":\"delete\",\"target\":\"C:\\\\r\\\\a.ts\",\"base_hash\":\"00\"}]}");
    defer v2.deinit();
    try testing.expect(v2 == .batch);
    try testing.expectEqual(@as(usize, 1), v2.batch.value.intents.len);
    try testing.expectEqualStrings("delete", v2.batch.value.intents[0].op);

    const legacy = try parse(testing.allocator, "{\"target\":\"C:\\\\r\\\\a.ts\",\"base_hash\":\"00\"}");
    defer legacy.deinit();
    try testing.expect(legacy == .legacy);
    try testing.expectEqualStrings("modify", legacy.legacy.value.op);

    try testing.expectError(error.CorruptJournal, parse(testing.allocator, "{\"version\":3}"));
    try testing.expectError(error.CorruptJournal, parse(testing.allocator, "{ not json"));
}
