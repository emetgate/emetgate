const std = @import("std");
const access_mod = @import("access.zig");

const Allocator = std.mem.Allocator;

pub const Access = access_mod.Access;
pub const Mask = access_mod.Mask;

pub const Kind = enum {
    sqlite,
    postgres,
    mysql,
    mongodb,

    pub fn parse(text: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, text);
    }

    pub fn supported(self: Kind) bool {
        return self == .sqlite or self == .postgres or self == .mongodb;
    }
};

pub const Mode = enum { read, write };

pub const Limits = struct {
    max_rows: u32 = 200,
    max_cell_chars: u32 = 2000,
    max_result_bytes: u32 = 16_000,
    timeout_ms: u32 = 5_000,
    rate_per_minute: u32 = 60,

    pub const ceiling: Limits = .{
        .max_rows = 10_000,
        .max_cell_chars = 100_000,
        .max_result_bytes = 200_000,
        .timeout_ms = 120_000,
        .rate_per_minute = 10_000,
    };

    pub const Field = std.meta.FieldEnum(Limits);

    pub fn set(self: *Limits, field: Field, value: u32) error{LimitOutOfRange}!void {
        switch (field) {
            inline else => |tag| {
                const top = @field(ceiling, @tagName(tag));
                if (value == 0 or value > top) return error.LimitOutOfRange;
                @field(self, @tagName(tag)) = value;
            },
        }
    }

    pub fn parseField(text: []const u8) ?Field {
        var buf: [32]u8 = undefined;
        if (text.len > buf.len) return null;
        for (text, 0..) |ch, i| buf[i] = if (ch == '-') '_' else ch;
        return std.meta.stringToEnum(Field, buf[0..text.len]);
    }
};

pub const Value = union(enum) {
    null,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
    json: []const u8,
};

pub const Treatment = union(enum) {
    plain,
    hidden,
    masked: Mask,
};

pub const ResultColumn = struct {
    name: []const u8,
    table: ?[]const u8 = null,
    origin: ?[]const u8 = null,
    treatment: Treatment = .plain,
};

pub const Sink = struct {
    ptr: *anyopaque,
    begin: *const fn (ptr: *anyopaque, columns: []const ResultColumn) anyerror!void,
    row: *const fn (ptr: *anyopaque, values: []const Value) anyerror!bool,
};

pub const Stop = enum { none, rows, bytes };

pub const Outcome = struct {
    nulled: []const []const u8 = &.{},
    rows: usize = 0,
    more: bool = false,
    stop: Stop = .none,
    elapsed_ms: u64 = 0,
};

pub const TableKind = enum { table, view };

pub const TableInfo = struct {
    name: []const u8,
    kind: TableKind,
};

pub const Tables = struct {
    shown: []const TableInfo,
    withheld: usize,
};

pub const ColumnInfo = struct {
    name: []const u8,
    decl_type: []const u8,
    not_null: bool,
    primary_key: u32,
    default: ?[]const u8,
    generated: bool,
    treatment: Treatment,
};

pub const IndexInfo = struct {
    name: []const u8,
    unique: bool,
    columns: []const []const u8,
};

pub const ForeignKey = struct {
    from: []const u8,
    table: []const u8,
    to: ?[]const u8,
};

pub const Description = struct {
    table: []const u8,
    kind: TableKind,
    columns: []const ColumnInfo,
    indexes: []const IndexInfo,
    foreign_keys: []const ForeignKey,
};

pub const Permit = struct {
    destructive: bool = false,
};

pub const WriteAction = enum { insert, update, delete, create, drop, alter, other };

pub const WriteOutcome = struct {
    action: WriteAction,
    table: ?[]const u8,
    changes: i64,
    destructive: bool,
    elapsed_ms: u64,
};

pub const Error = error{
    EmptyStatement,
    MultipleStatements,
    StatementNotRead,
    StatementOnlyReads,
    TableRefused,
    TableNotFound,
    MaskedColumnUsed,
    ActionDenied,
    FunctionDenied,
    GuardedColumnInWrite,
    DestructiveNotGranted,
    QueryTimeout,
    SqlFailed,
    DatabaseUnavailable,
    EngineNotSupported,
    CommandInvalid,
    HiddenFieldUsed,
    MaskedFieldUsed,
    OperatorDenied,
};

pub const Settings = struct {
    io: std.Io,
    mode: Mode,
    access: Access,
    limits: Limits,
};

pub const Connection = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        close: *const fn (ptr: *anyopaque) void,
        problem: *const fn (ptr: *anyopaque) []const u8,
        tables: *const fn (ptr: *anyopaque, arena: Allocator) anyerror!Tables,
        describe: *const fn (ptr: *anyopaque, arena: Allocator, table: []const u8) anyerror!Description,
        count: *const fn (ptr: *anyopaque, arena: Allocator, table: []const u8) anyerror!i64,
        sample: *const fn (ptr: *anyopaque, arena: Allocator, table: []const u8, rows: u32, sink: Sink) anyerror!Outcome,
        query: *const fn (ptr: *anyopaque, arena: Allocator, sql: []const u8, sink: Sink) anyerror!Outcome,
        explain: *const fn (ptr: *anyopaque, arena: Allocator, sql: []const u8) anyerror![]const []const u8,
        write: *const fn (ptr: *anyopaque, arena: Allocator, sql: []const u8, permit: Permit) anyerror!WriteOutcome,
    };

    pub fn close(self: Connection) void {
        self.vtable.close(self.ptr);
    }

    pub fn problem(self: Connection) []const u8 {
        return self.vtable.problem(self.ptr);
    }

    pub fn tables(self: Connection, arena: Allocator) !Tables {
        return self.vtable.tables(self.ptr, arena);
    }

    pub fn describe(self: Connection, arena: Allocator, table: []const u8) !Description {
        return self.vtable.describe(self.ptr, arena, table);
    }

    pub fn count(self: Connection, arena: Allocator, table: []const u8) !i64 {
        return self.vtable.count(self.ptr, arena, table);
    }

    pub fn sample(self: Connection, arena: Allocator, table: []const u8, rows: u32, sink: Sink) !Outcome {
        return self.vtable.sample(self.ptr, arena, table, rows, sink);
    }

    pub fn query(self: Connection, arena: Allocator, sql: []const u8, sink: Sink) !Outcome {
        return self.vtable.query(self.ptr, arena, sql, sink);
    }

    pub fn explain(self: Connection, arena: Allocator, sql: []const u8) ![]const []const u8 {
        return self.vtable.explain(self.ptr, arena, sql);
    }

    pub fn write(self: Connection, arena: Allocator, sql: []const u8, permit: Permit) !WriteOutcome {
        return self.vtable.write(self.ptr, arena, sql, permit);
    }
};

const testing = std.testing;

test "db engine: limits take a dashed or underscored name and refuse zero and values over the ceiling" {
    var limits: Limits = .{};
    try limits.set(Limits.parseField("max-rows").?, 50);
    try testing.expectEqual(@as(u32, 50), limits.max_rows);
    try testing.expectError(error.LimitOutOfRange, limits.set(.max_rows, 0));
    try testing.expectError(error.LimitOutOfRange, limits.set(.timeout_ms, Limits.ceiling.timeout_ms + 1));
    try testing.expect(Limits.parseField("rows") == null);
    try testing.expect(Limits.parseField("timeout_ms") != null);
    try testing.expect(Kind.sqlite.supported() and Kind.postgres.supported() and !Kind.mysql.supported());
}
