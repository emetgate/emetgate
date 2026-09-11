const std = @import("std");
const ts = @import("tree_sitter.zig");
const symbol = @import("symbol.zig");
const Runtime = @import("runtime.zig").Runtime;
const test_util = @import("test_util.zig");

const max_source_len = std.math.maxInt(u32);

pub const Snapshot = struct {
    runtime: *Runtime,
    source: []u8,
    tree: ts.Tree,
    table: ?symbol.Table = null,

    pub const CreateError = ts.Error || std.mem.Allocator.Error;
    pub const LoadError = std.Io.Dir.ReadFileAllocError || ts.Error;

    pub fn fromSource(runtime: *Runtime, source: []u8) CreateError!*Snapshot {
        errdefer runtime.gpa.free(source);
        const tree = try runtime.parser.parse(source);
        errdefer tree.deinit();
        const self = try runtime.gpa.create(Snapshot);
        self.* = .{ .runtime = runtime, .source = source, .tree = tree };
        runtime.live_snapshots += 1;
        return self;
    }

    pub fn load(runtime: *Runtime, io: std.Io, dir: std.Io.Dir, path: []const u8) LoadError!*Snapshot {
        const source = try dir.readFileAlloc(io, path, runtime.gpa, .limited(max_source_len));
        return fromSource(runtime, source);
    }

    pub fn destroy(self: *Snapshot) void {
        const runtime = self.runtime;
        if (self.table) |table| table.deinit();
        self.tree.deinit();
        runtime.gpa.free(self.source);
        self.* = undefined;
        runtime.gpa.destroy(self);
        runtime.live_snapshots -= 1;
    }

    pub fn symbols(self: *Snapshot) symbol.Table.BuildError!*const symbol.Table {
        if (self.table == null) self.table = try symbol.Table.build(self.runtime.gpa, self.tree);
        return &self.table.?;
    }
};

const testing = std.testing;

test "loads a fixture from disk into a snapshot that owns its source and tree" {
    var runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(&runtime);

    const snapshot = try test_util.loadFixture(&runtime, "functions.ts");
    defer snapshot.destroy();

    try testing.expect(snapshot.source.len > 0);
    try testing.expectEqualStrings("program", snapshot.tree.root().kind());
    try testing.expect(!snapshot.tree.root().hasError());
    try testing.expectEqual(@as(u32, @intCast(snapshot.source.len)), snapshot.tree.root().endByte());
    try testing.expect(snapshot.tree.source.ptr == snapshot.source.ptr);
}

test "a syntactically broken fixture loads but reports the error and refuses a symbol table" {
    var runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(&runtime);

    const snapshot = try test_util.loadFixture(&runtime, "broken.ts");
    defer snapshot.destroy();

    try testing.expect(snapshot.tree.root().hasError());
    try testing.expectError(error.SourceHasErrors, snapshot.symbols());
    try testing.expect(snapshot.table == null);
}

test "a missing file surfaces FileNotFound and creates no snapshot" {
    var runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(&runtime);

    try testing.expectError(error.FileNotFound, test_util.loadFixture(&runtime, "does-not-exist.ts"));
    try testing.expectEqual(@as(usize, 0), runtime.live_snapshots);
}

test "the symbol table is built once, cached, and released with its snapshot" {
    var runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(&runtime);

    const snapshot = try test_util.loadFixture(&runtime, "functions.ts");
    const first = try snapshot.symbols();
    const second = try snapshot.symbols();
    try testing.expect(first == second);
    try testing.expect(first.symbols.len > 0);
    snapshot.destroy();
}
