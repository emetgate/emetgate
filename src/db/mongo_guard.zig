const std = @import("std");
const access_mod = @import("access.zig");
const bson = @import("bson.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Access = access_mod.Access;
const Mask = access_mod.Mask;

pub const max_command_bytes = 100_000;
pub const max_depth = 64;

pub const Error = error{
    CommandInvalid,
    StatementNotRead,
    StatementOnlyReads,
    TableRefused,
    HiddenFieldUsed,
    MaskedFieldUsed,
    OperatorDenied,
    GuardedColumnInWrite,
    OutOfMemory,
};

pub const ReadKind = enum { find, aggregate, distinct, countDocuments };
pub const WriteKind = enum { insertOne, insertMany, updateOne, updateMany, deleteOne, deleteMany, drop };

pub const Command = struct {
    verb: union(enum) { read: ReadKind, write: WriteKind },
    collection: []const u8,
    filter: ?ObjectMap = null,
    projection: ?ObjectMap = null,
    sort: ?ObjectMap = null,
    limit: ?i64 = null,
    skip: ?i64 = null,
    pipeline: []const Value = &.{},
    key: ?[]const u8 = null,
    documents: []const Value = &.{},
    update: ?ObjectMap = null,
    upsert: bool = false,

    pub fn verbName(self: Command) []const u8 {
        return switch (self.verb) {
            inline else => |v| @tagName(v),
        };
    }
};

const read_fields = std.StaticStringMap(void).initComptime(.{ .{"filter"}, .{"projection"}, .{"sort"}, .{"limit"}, .{"skip"}, .{"pipeline"}, .{"key"} });

pub const Scope = struct {
    access: Access,
    names: []const []const u8,

    pub fn hidden(self: Scope, field: []const u8) bool {
        for (self.names) |name| {
            if (self.access.isHidden(name, field)) return true;
        }
        return false;
    }

    pub fn mask(self: Scope, field: []const u8) ?Mask {
        if (self.hidden(field)) return null;
        for (self.names) |name| {
            if (self.access.maskOf(name, field)) |m| return m;
        }
        return null;
    }

    pub fn guarded(self: Scope) bool {
        for (self.names) |name| {
            if (self.access.guards(name)) return true;
        }
        return false;
    }

    pub fn refusal(self: Scope) ?struct { name: []const u8, why: access_mod.Refusal } {
        for (self.names) |name| {
            if (isSystem(name)) return .{ .name = name, .why = .blocked };
            if (self.access.tableRefusal(name)) |why| return .{ .name = name, .why = why };
        }
        return null;
    }

    pub fn masks(self: Scope) bool {
        for (self.access.masked) |rule| {
            for (self.names) |name| if (access_mod.nameMatches(rule.table, name)) return true;
        }
        return false;
    }

    pub fn hiddenNames(self: Scope, arena: Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (self.access.hidden) |rule| {
            for (self.names) |name| {
                if (!access_mod.nameMatches(rule.table, name)) continue;
                for (out.items) |known| {
                    if (std.mem.eql(u8, known, rule.column)) break;
                } else try out.append(arena, rule.column);
                break;
            }
        }
        return out.items;
    }

    pub fn wholeGuarded(self: Scope) bool {
        for (self.access.hidden) |rule| {
            if (!std.mem.eql(u8, rule.column, access_mod.wildcard)) continue;
            for (self.names) |name| if (access_mod.nameMatches(rule.table, name)) return true;
        }
        for (self.access.masked) |rule| {
            if (!std.mem.eql(u8, rule.column, access_mod.wildcard)) continue;
            for (self.names) |name| if (access_mod.nameMatches(rule.table, name)) return true;
        }
        return false;
    }
};

pub fn isSystem(name: []const u8) bool {
    return name.len >= 7 and std.ascii.eqlIgnoreCase(name[0..7], "system.");
}

pub const Resolver = struct {
    ptr: ?*anyopaque = null,
    chain: ?*const fn (ptr: ?*anyopaque, arena: Allocator, name: []const u8) anyerror![]const []const u8 = null,

    pub fn resolve(self: Resolver, arena: Allocator, name: []const u8) ![]const []const u8 {
        const f = self.chain orelse {
            const one = try arena.alloc([]const u8, 1);
            one[0] = name;
            return one;
        };
        return f(self.ptr, arena, name);
    }
};

const Purpose = enum { read, write };

pub const Checker = struct {
    arena: Allocator,
    scope: Scope,
    resolver: Resolver = .{},
    purpose: Purpose = .read,
    raw: bool = false,
    message: []const u8 = "",

    fn fail(self: *Checker, err: Error, comptime fmt: []const u8, args: anytype) Error {
        self.message = std.fmt.allocPrint(self.arena, fmt, args) catch "refused";
        return err;
    }

    fn collectionName(self: *const Checker) []const u8 {
        return if (self.scope.names.len == 0) "?" else self.scope.names[self.scope.names.len - 1];
    }

    fn path(self: *Checker, text: []const u8) Error!void {
        if (text.len == 0 or text[0] == '.' or text[text.len - 1] == '.' or std.mem.indexOf(u8, text, "..") != null) return self.fail(error.CommandInvalid, "field path \"{s}\" is not a valid dotted path", .{text});
        const first = text[0 .. std.mem.indexOfScalar(u8, text, '.') orelse text.len];
        try self.name(first, text);
        if (!std.mem.eql(u8, first, text)) try self.name(text, text);
    }

    fn name(self: *Checker, field: []const u8, shown: []const u8) Error!void {
        if (self.scope.hidden(field)) {
            if (self.purpose == .write) return self.fail(error.GuardedColumnInWrite, "field {s} of {s} is hidden: a write may not read or set it", .{ field, self.collectionName() });
            return self.fail(error.HiddenFieldUsed, "field {s} of {s} is hidden, so no filter, sort, projection or expression may name it (\"{s}\")", .{ field, self.collectionName(), shown });
        }
        if (self.scope.mask(field) != null) {
            if (self.purpose == .write) return self.fail(error.GuardedColumnInWrite, "field {s} of {s} is masked: a write may not read or set it", .{ field, self.collectionName() });
            return self.fail(error.MaskedFieldUsed, "field {s} of {s} is masked, so it may only be returned as it is ({{\"{s}\":1}}), never filtered, sorted, grouped or computed with (\"{s}\")", .{ field, self.collectionName(), field, shown });
        }
    }

    fn denied(self: *Checker, op: []const u8, why: []const u8) Error {
        return self.fail(error.OperatorDenied, "{s} is refused: {s}", .{ op, why });
    }

    fn deep(self: *Checker, depth: usize) Error!void {
        if (depth > max_depth) return self.fail(error.CommandInvalid, "the command nests deeper than {d} levels", .{max_depth});
    }

    pub fn filter(self: *Checker, v: Value, depth: usize) Error!void {
        try self.deep(depth);
        if (v != .object) return self.fail(error.CommandInvalid, "a filter is a JSON object", .{});
        var it = v.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            if (key.len != 0 and key[0] == '$') {
                if (eqlAny(key, &.{ "$and", "$or", "$nor" })) {
                    if (val != .array or val.array.items.len == 0) return self.fail(error.CommandInvalid, "{s} takes a non-empty array of filters", .{key});
                    for (val.array.items) |item| try self.filter(item, depth + 1);
                } else if (std.mem.eql(u8, key, "$expr")) {
                    try self.expr(val, depth + 1);
                } else if (std.mem.eql(u8, key, "$comment")) {} else if (std.mem.eql(u8, key, "$text")) {
                    if (self.scope.guarded()) return self.denied("$text", "a text search matches every indexed text field, hidden and masked ones included");
                    try self.literal(val, depth + 1);
                } else if (eqlAny(key, &.{ "$where", "$function", "$accumulator" })) {
                    return self.denied(key, "server-side JavaScript is never run");
                } else if (std.mem.eql(u8, key, "$jsonSchema")) {
                    return self.denied(key, "a schema can test hidden and masked fields");
                } else return self.denied(key, "it is not on the allowed query operator list");
                continue;
            }
            try self.path(key);
            try self.condition(val, depth + 1);
        }
    }

    fn condition(self: *Checker, v: Value, depth: usize) Error!void {
        try self.deep(depth);
        if (v != .object or bson.extendedTag(v.object) != null) return self.literal(v, depth);
        var operators: usize = 0;
        for (v.object.keys()) |key| {
            if (key.len != 0 and key[0] == '$') operators += 1;
        }
        if (operators == 0) return self.literal(v, depth);
        if (operators != v.object.count()) return self.fail(error.CommandInvalid, "an object mixes query operators and field names", .{});
        var it = v.object.iterator();
        while (it.next()) |entry| {
            const op = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            if (query_value_ops.has(op)) {
                try self.literal(val, depth + 1);
            } else if (std.mem.eql(u8, op, "$not")) {
                try self.condition(val, depth + 1);
            } else if (std.mem.eql(u8, op, "$elemMatch")) {
                if (val != .object) return self.fail(error.CommandInvalid, "$elemMatch takes an object", .{});
                var all_ops = true;
                for (val.object.keys()) |k| all_ops = all_ops and k.len != 0 and k[0] == '$' and !eqlAny(k, &.{ "$and", "$or", "$nor", "$expr" });
                if (all_ops) try self.condition(val, depth + 1) else try self.filter(val, depth + 1);
            } else if (eqlAny(op, &.{ "$where", "$function", "$accumulator" })) {
                return self.denied(op, "server-side JavaScript is never run");
            } else return self.denied(op, "it is not on the allowed query operator list");
        }
    }

    pub fn literal(self: *Checker, v: Value, depth: usize) Error!void {
        try self.deep(depth);
        switch (v) {
            .array => |list| for (list.items) |item| try self.literal(item, depth + 1),
            .object => |object| {
                if (bson.extendedTag(object) != null) return;
                var it = object.iterator();
                while (it.next()) |entry| {
                    const key = entry.key_ptr.*;
                    if (key.len != 0 and key[0] == '$' and !eqlAny(key, &.{ "$search", "$language", "$caseSensitive", "$diacriticSensitive" })) return self.fail(error.CommandInvalid, "a literal value holds the key {s}; use $literal or extended JSON ($oid, $date, $numberLong)", .{key});
                    try self.literal(entry.value_ptr.*, depth + 1);
                }
            },
            else => {},
        }
    }

    fn variable(self: *Checker, text: []const u8) Error!void {
        const body = text[2..];
        const dot = std.mem.indexOfScalar(u8, body, '.');
        const var_name = body[0 .. dot orelse body.len];
        if (std.mem.eql(u8, var_name, "ROOT") or std.mem.eql(u8, var_name, "CURRENT")) {
            const rest = if (dot) |d| body[d + 1 ..] else "";
            if (rest.len == 0) return self.denied(text, "a whole-document reference would carry hidden and masked fields; name the fields you need");
            return self.path(rest);
        }
        if (var_name.len == 0) return self.fail(error.CommandInvalid, "\"{s}\" names no variable", .{text});
        if (eqlAny(var_name, &.{ "NOW", "CLUSTER_TIME", "REMOVE" })) return;
        if (std.ascii.isLower(var_name[0]) or var_name[0] >= 0x80) return;
        return self.denied(text, "only $$NOW, $$CLUSTER_TIME, $$REMOVE and lower-case variables bound by $let, $map, $filter or $reduce may be used");
    }

    fn varName(self: *Checker, v: Value) Error!void {
        if (v != .string or v.string.len == 0 or !(std.ascii.isLower(v.string[0]) or v.string[0] >= 0x80)) return self.fail(error.CommandInvalid, "a variable name starts with a lower-case letter", .{});
    }

    fn literalName(self: *Checker, v: Value) Error![]const u8 {
        if (v == .string and (v.string.len == 0 or v.string[0] != '$')) return v.string;
        if (v == .object and v.object.count() == 1) {
            if (v.object.get("$literal")) |inner| {
                if (inner == .string) return inner.string;
            }
        }
        return self.denied("a computed field name", "$getField, $setField and $unsetField need a literal field name so the access rules can check it");
    }

    pub fn expr(self: *Checker, v: Value, depth: usize) Error!void {
        try self.deep(depth);
        switch (v) {
            .string => |text| {
                if (std.mem.startsWith(u8, text, "$$")) return self.variable(text);
                if (text.len != 0 and text[0] == '$') return self.path(text[1..]);
            },
            .array => |list| for (list.items) |item| try self.expr(item, depth + 1),
            .object => |object| {
                if (bson.extendedTag(object) != null) return;
                var operators: usize = 0;
                for (object.keys()) |key| {
                    if (key.len != 0 and key[0] == '$') operators += 1;
                }
                if (operators == 0) {
                    for (object.values()) |item| try self.expr(item, depth + 1);
                    return;
                }
                if (operators != 1 or object.count() != 1) return self.fail(error.CommandInvalid, "an expression object holds exactly one operator", .{});
                const op = object.keys()[0];
                const arg = object.values()[0];
                return self.operator(op, arg, depth);
            },
            else => {},
        }
    }

    fn operator(self: *Checker, op: []const u8, arg: Value, depth: usize) Error!void {
        if (std.mem.eql(u8, op, "$literal")) return;
        if (eqlAny(op, &.{ "$function", "$accumulator", "$where" })) return self.denied(op, "server-side JavaScript is never run");
        if (std.mem.eql(u8, op, "$getField")) {
            if (arg == .object and arg.object.get("field") != null) {
                const field = try self.literalName(arg.object.get("field").?);
                try self.name(field, field);
                const first = field[0 .. std.mem.indexOfScalar(u8, field, '.') orelse field.len];
                try self.name(first, field);
                var it = arg.object.iterator();
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, "field")) continue;
                    if (!std.mem.eql(u8, entry.key_ptr.*, "input")) return self.fail(error.CommandInvalid, "$getField takes field and input", .{});
                    const input = entry.value_ptr.*;
                    if (input == .string and (std.mem.eql(u8, input.string, "$$ROOT") or std.mem.eql(u8, input.string, "$$CURRENT"))) continue;
                    try self.expr(input, depth + 1);
                }
                return;
            }
            const field = try self.literalName(arg);
            try self.name(field, field);
            const first = field[0 .. std.mem.indexOfScalar(u8, field, '.') orelse field.len];
            return self.name(first, field);
        }
        if (eqlAny(op, &.{ "$setField", "$unsetField" })) {
            if (arg != .object) return self.fail(error.CommandInvalid, "{s} takes an object", .{op});
            const field = try self.literalName(arg.object.get("field") orelse return self.fail(error.CommandInvalid, "{s} needs field", .{op}));
            try self.name(field, field);
            var it = arg.object.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "field")) continue;
                if (!eqlAny(entry.key_ptr.*, &.{ "input", "value" })) return self.fail(error.CommandInvalid, "{s} takes field, input and value", .{op});
                try self.expr(entry.value_ptr.*, depth + 1);
            }
            return;
        }
        if (!expression_ops.has(op) and !accumulator_ops.has(op)) return self.denied(op, "it is not on the allowed expression operator list");
        if (arg != .object or bson.extendedTag(arg.object) != null) return self.expr(arg, depth + 1);
        for (arg.object.keys()) |key| {
            if (key.len != 0 and key[0] == '$') return self.expr(arg, depth + 1);
        }
        var it = arg.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            if (std.mem.eql(u8, key, "as")) {
                try self.varName(val);
            } else if (std.mem.eql(u8, key, "sortBy")) {
                if (val == .object) try self.sortSpec(val, depth + 1) else try self.literal(val, depth + 1);
            } else if (std.mem.eql(u8, key, "vars") and std.mem.eql(u8, op, "$let")) {
                if (val != .object) return self.fail(error.CommandInvalid, "$let vars is an object", .{});
                var vars = val.object.iterator();
                while (vars.next()) |bound| {
                    try self.varName(.{ .string = bound.key_ptr.* });
                    try self.expr(bound.value_ptr.*, depth + 2);
                }
            } else try self.expr(val, depth + 1);
        }
    }

    pub fn sortSpec(self: *Checker, v: Value, depth: usize) Error!void {
        try self.deep(depth);
        if (v != .object) return self.fail(error.CommandInvalid, "a sort is an object of field: 1 or -1", .{});
        var it = v.object.iterator();
        while (it.next()) |entry| {
            try self.path(entry.key_ptr.*);
            const val = entry.value_ptr.*;
            switch (val) {
                .integer => |n| if (n != 1 and n != -1) return self.fail(error.CommandInvalid, "a sort direction is 1 or -1", .{}),
                .object => |o| {
                    const meta = o.get("$meta") orelse return self.fail(error.CommandInvalid, "a sort direction is 1 or -1", .{});
                    if (o.count() != 1 or meta != .string or !std.mem.eql(u8, meta.string, "textScore")) return self.fail(error.CommandInvalid, "a sort direction is 1 or -1", .{});
                },
                else => return self.fail(error.CommandInvalid, "a sort direction is 1 or -1", .{}),
            }
        }
    }

    pub fn projection(self: *Checker, v: Value, depth: usize, nested: bool) Error!void {
        try self.deep(depth);
        if (v != .object) return self.fail(error.CommandInvalid, "a projection is an object", .{});
        var it = v.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            if (key.len == 0 or key[0] == '$') return self.fail(error.CommandInvalid, "a projection key is a field name, not {s}", .{key});
            const first = key[0 .. std.mem.indexOfScalar(u8, key, '.') orelse key.len];
            const flag: ?bool = switch (val) {
                .bool => |b| b,
                .integer => |n| n != 0,
                .float => |f| f != 0,
                else => null,
            };
            if (flag) |include| {
                if (nested) continue;
                if (self.scope.hidden(first)) {
                    if (include) try self.name(first, key);
                } else if (self.scope.mask(first) != null and include and !std.mem.eql(u8, first, key)) try self.name(first, key);
                continue;
            }
            if (val == .object and bson.extendedTag(val.object) == null and noOperatorKeys(val.object)) {
                if (!nested) try self.name(first, key);
                try self.projection(val, depth + 1, true);
                continue;
            }
            try self.expr(val, depth + 1);
        }
    }

    fn integer(self: *Checker, v: Value, what: []const u8) Error!i64 {
        if (v != .integer or v.integer < 0) return self.fail(error.CommandInvalid, "{s} is a non-negative integer", .{what});
        return v.integer;
    }

    fn foreign(self: *Checker, v: Value, stage: []const u8) Error!Scope {
        if (v != .string) return self.denied(stage, "only a collection of this database, named by a string, may be joined");
        const chain = self.resolver.resolve(self.arena, v.string) catch return self.fail(error.TableRefused, "{s} names {s}, which could not be resolved", .{ stage, v.string });
        const scope: Scope = .{ .access = self.scope.access, .names = chain };
        if (scope.refusal()) |r| return self.fail(error.TableRefused, "{s} reads {s}, which {s}", .{ stage, r.name, refusalText(r.why) });
        if (scope.guarded()) return self.denied(stage, "the joined collection has hidden or masked fields, which a join would carry out unmasked");
        return scope;
    }

    fn sub(self: *Checker, scope: Scope) Checker {
        return .{ .arena = self.arena, .scope = scope, .resolver = self.resolver, .purpose = self.purpose, .raw = true };
    }

    pub fn pipeline(self: *Checker, stages: []const Value, depth: usize) Error!void {
        try self.deep(depth);
        for (stages) |stage| {
            if (stage != .object or stage.object.count() != 1) return self.fail(error.CommandInvalid, "each pipeline stage is an object with one $stage key", .{});
            const op = stage.object.keys()[0];
            const arg = stage.object.values()[0];
            try self.stageCheck(op, arg, depth + 1);
        }
    }

    fn stageCheck(self: *Checker, op: []const u8, arg: Value, depth: usize) Error!void {
        const kind = stage_names.get(op) orelse {
            if (eqlAny(op, &.{ "$out", "$merge" })) return self.denied(op, "a read never writes to a collection");
            return self.denied(op, "it is not on the allowed stage list ($match, $project, $addFields, $set, $unset, $sort, $limit, $skip, $count, $group, $unwind, $sample, $sortByCount, $bucket, $bucketAuto, $replaceRoot, $replaceWith, $facet, $lookup, $unionWith, $graphLookup, $setWindowFields)");
        };
        switch (kind) {
            .match => try self.filter(arg, depth),
            .project => try self.projection(arg, depth, false),
            .add_fields => {
                if (arg != .object) return self.fail(error.CommandInvalid, "{s} takes an object", .{op});
                var it = arg.object.iterator();
                while (it.next()) |entry| {
                    if (entry.key_ptr.*.len == 0 or entry.key_ptr.*[0] == '$') return self.fail(error.CommandInvalid, "{s} sets field names, not {s}", .{ op, entry.key_ptr.* });
                    try self.expr(entry.value_ptr.*, depth + 1);
                }
            },
            .unset => switch (arg) {
                .string => {},
                .array => |list| for (list.items) |item| if (item != .string) return self.fail(error.CommandInvalid, "$unset takes field names", .{}),
                else => return self.fail(error.CommandInvalid, "$unset takes field names", .{}),
            },
            .sort => try self.sortSpec(arg, depth),
            .limit => {
                if ((try self.integer(arg, op)) == 0) return self.fail(error.CommandInvalid, "$limit is at least 1", .{});
            },
            .skip => _ = try self.integer(arg, op),
            .count => if (arg != .string or arg.string.len == 0 or arg.string[0] == '$') return self.fail(error.CommandInvalid, "$count takes an output field name", .{}),
            .sample => {
                if (arg != .object or arg.object.count() != 1) return self.fail(error.CommandInvalid, "$sample takes {{\"size\": n}}", .{});
                _ = try self.integer(arg.object.get("size") orelse return self.fail(error.CommandInvalid, "$sample takes {{\"size\": n}}", .{}), "$sample size");
            },
            .group => {
                if (arg != .object or arg.object.get("_id") == null) return self.fail(error.CommandInvalid, "$group needs _id", .{});
                var it = arg.object.iterator();
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, "_id")) {
                        try self.expr(entry.value_ptr.*, depth + 1);
                        continue;
                    }
                    try self.accumulator(entry.value_ptr.*, depth + 1);
                }
            },
            .unwind => switch (arg) {
                .string => |text| {
                    if (text.len < 2 or text[0] != '$' or text[1] == '$') return self.fail(error.CommandInvalid, "$unwind takes a \"$field\" path", .{});
                    try self.path(text[1..]);
                },
                .object => |object| {
                    var it = object.iterator();
                    while (it.next()) |entry| {
                        const key = entry.key_ptr.*;
                        const val = entry.value_ptr.*;
                        if (std.mem.eql(u8, key, "path")) {
                            if (val != .string or val.string.len < 2 or val.string[0] != '$' or val.string[1] == '$') return self.fail(error.CommandInvalid, "$unwind takes a \"$field\" path", .{});
                            try self.path(val.string[1..]);
                        } else if (std.mem.eql(u8, key, "includeArrayIndex")) {
                            if (val != .string) return self.fail(error.CommandInvalid, "includeArrayIndex is a field name", .{});
                        } else if (std.mem.eql(u8, key, "preserveNullAndEmptyArrays")) {
                            if (val != .bool) return self.fail(error.CommandInvalid, "preserveNullAndEmptyArrays is true or false", .{});
                        } else return self.fail(error.CommandInvalid, "$unwind takes path, includeArrayIndex and preserveNullAndEmptyArrays", .{});
                    }
                    if (object.get("path") == null) return self.fail(error.CommandInvalid, "$unwind needs path", .{});
                },
                else => return self.fail(error.CommandInvalid, "$unwind takes a \"$field\" path", .{}),
            },
            .sort_by_count, .replace_with => try self.expr(arg, depth),
            .replace_root => {
                if (arg != .object or arg.object.count() != 1) return self.fail(error.CommandInvalid, "$replaceRoot takes {{\"newRoot\": expression}}", .{});
                try self.expr(arg.object.get("newRoot") orelse return self.fail(error.CommandInvalid, "$replaceRoot takes {{\"newRoot\": expression}}", .{}), depth + 1);
            },
            .bucket, .bucket_auto => {
                if (arg != .object) return self.fail(error.CommandInvalid, "{s} takes an object", .{op});
                var it = arg.object.iterator();
                while (it.next()) |entry| {
                    const key = entry.key_ptr.*;
                    const val = entry.value_ptr.*;
                    if (std.mem.eql(u8, key, "groupBy")) {
                        try self.expr(val, depth + 1);
                    } else if (std.mem.eql(u8, key, "output")) {
                        if (val != .object) return self.fail(error.CommandInvalid, "{s} output is an object", .{op});
                        for (val.object.values()) |acc| try self.accumulator(acc, depth + 2);
                    } else if (eqlAny(key, &.{ "boundaries", "default", "buckets", "granularity" })) {
                        try self.literal(val, depth + 1);
                    } else return self.fail(error.CommandInvalid, "{s} does not take {s}", .{ op, key });
                }
            },
            .facet => {
                if (self.scope.masks() or (self.raw and self.scope.guarded())) return self.denied(op, "its sub-pipelines nest whole documents, which would carry hidden or masked fields out");
                if (arg != .object) return self.fail(error.CommandInvalid, "$facet takes named pipelines", .{});
                for (arg.object.values()) |inner| {
                    if (inner != .array) return self.fail(error.CommandInvalid, "$facet takes named pipelines", .{});
                    try self.pipeline(inner.array.items, depth + 1);
                }
            },
            .lookup => {
                if (arg != .object) return self.fail(error.CommandInvalid, "$lookup takes an object", .{});
                const scope = try self.foreign(arg.object.get("from") orelse return self.fail(error.CommandInvalid, "$lookup needs from", .{}), op);
                var it = arg.object.iterator();
                while (it.next()) |entry| {
                    const key = entry.key_ptr.*;
                    const val = entry.value_ptr.*;
                    if (std.mem.eql(u8, key, "from")) continue;
                    if (std.mem.eql(u8, key, "localField")) {
                        if (val != .string) return self.fail(error.CommandInvalid, "localField is a field path", .{});
                        try self.path(val.string);
                    } else if (eqlAny(key, &.{ "foreignField", "as" })) {
                        if (val != .string) return self.fail(error.CommandInvalid, "{s} is a field name", .{key});
                    } else if (std.mem.eql(u8, key, "let")) {
                        if (val != .object) return self.fail(error.CommandInvalid, "let is an object", .{});
                        var vars = val.object.iterator();
                        while (vars.next()) |bound| {
                            try self.varName(.{ .string = bound.key_ptr.* });
                            try self.expr(bound.value_ptr.*, depth + 2);
                        }
                    } else if (std.mem.eql(u8, key, "pipeline")) {
                        if (val != .array) return self.fail(error.CommandInvalid, "pipeline is an array", .{});
                        var inner = self.sub(scope);
                        inner.pipeline(val.array.items, depth + 1) catch |err| {
                            self.message = inner.message;
                            return err;
                        };
                    } else return self.fail(error.CommandInvalid, "$lookup does not take {s}", .{key});
                }
            },
            .union_with => {
                const coll = if (arg == .object) arg.object.get("coll") orelse return self.fail(error.CommandInvalid, "$unionWith needs coll", .{}) else arg;
                const scope = try self.foreign(coll, op);
                if (arg == .object) {
                    var it = arg.object.iterator();
                    while (it.next()) |entry| {
                        if (std.mem.eql(u8, entry.key_ptr.*, "coll")) continue;
                        if (!std.mem.eql(u8, entry.key_ptr.*, "pipeline") or entry.value_ptr.* != .array) return self.fail(error.CommandInvalid, "$unionWith takes coll and pipeline", .{});
                        var inner = self.sub(scope);
                        inner.pipeline(entry.value_ptr.*.array.items, depth + 1) catch |err| {
                            self.message = inner.message;
                            return err;
                        };
                    }
                }
            },
            .graph_lookup => {
                if (arg != .object) return self.fail(error.CommandInvalid, "$graphLookup takes an object", .{});
                const scope = try self.foreign(arg.object.get("from") orelse return self.fail(error.CommandInvalid, "$graphLookup needs from", .{}), op);
                var it = arg.object.iterator();
                while (it.next()) |entry| {
                    const key = entry.key_ptr.*;
                    const val = entry.value_ptr.*;
                    if (std.mem.eql(u8, key, "from")) continue;
                    if (std.mem.eql(u8, key, "startWith")) {
                        try self.expr(val, depth + 1);
                    } else if (eqlAny(key, &.{ "connectFromField", "connectToField", "as", "depthField" })) {
                        if (val != .string) return self.fail(error.CommandInvalid, "{s} is a field name", .{key});
                    } else if (std.mem.eql(u8, key, "maxDepth")) {
                        _ = try self.integer(val, key);
                    } else if (std.mem.eql(u8, key, "restrictSearchWithMatch")) {
                        var inner = self.sub(scope);
                        inner.filter(val, depth + 1) catch |err| {
                            self.message = inner.message;
                            return err;
                        };
                    } else return self.fail(error.CommandInvalid, "$graphLookup does not take {s}", .{key});
                }
            },
            .set_window_fields => {
                if (arg != .object) return self.fail(error.CommandInvalid, "$setWindowFields takes an object", .{});
                var it = arg.object.iterator();
                while (it.next()) |entry| {
                    const key = entry.key_ptr.*;
                    const val = entry.value_ptr.*;
                    if (std.mem.eql(u8, key, "partitionBy")) {
                        try self.expr(val, depth + 1);
                    } else if (std.mem.eql(u8, key, "sortBy")) {
                        try self.sortSpec(val, depth + 1);
                    } else if (std.mem.eql(u8, key, "output")) {
                        if (val != .object) return self.fail(error.CommandInvalid, "output is an object", .{});
                        for (val.object.values()) |field| {
                            if (field != .object) return self.fail(error.CommandInvalid, "each output field is {{\"$op\": expression, \"window\": {{...}}}}", .{});
                            var ops = field.object.iterator();
                            var seen: usize = 0;
                            while (ops.next()) |o| {
                                if (std.mem.eql(u8, o.key_ptr.*, "window")) {
                                    try self.literal(o.value_ptr.*, depth + 3);
                                    continue;
                                }
                                seen += 1;
                                try self.operatorObject(o.key_ptr.*, o.value_ptr.*, depth + 3);
                            }
                            if (seen != 1) return self.fail(error.CommandInvalid, "each output field holds one window operator", .{});
                        }
                    } else return self.fail(error.CommandInvalid, "$setWindowFields does not take {s}", .{key});
                }
            },
        }
    }

    fn operatorObject(self: *Checker, op: []const u8, arg: Value, depth: usize) Error!void {
        if (op.len == 0 or op[0] != '$') return self.fail(error.CommandInvalid, "{s} is not an operator", .{op});
        return self.operator(op, arg, depth);
    }

    fn accumulator(self: *Checker, v: Value, depth: usize) Error!void {
        if (v != .object or v.object.count() != 1) return self.fail(error.CommandInvalid, "a group field is {{\"$accumulator\": expression}}", .{});
        const op = v.object.keys()[0];
        if (std.mem.eql(u8, op, "$accumulator")) return self.denied(op, "server-side JavaScript is never run");
        if (!accumulator_ops.has(op)) return self.denied(op, "it is not on the allowed accumulator list");
        return self.operator(op, v.object.values()[0], depth);
    }

    pub fn document(self: *Checker, v: Value, depth: usize) Error!void {
        if (v != .object) return self.fail(error.CommandInvalid, "a document is a JSON object", .{});
        var it = v.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (key.len == 0 or key[0] == '$') return self.fail(error.CommandInvalid, "a document field is not named {s}", .{key});
            try self.name(key, key);
            try self.literal(entry.value_ptr.*, depth + 1);
        }
    }

    pub fn updateSpec(self: *Checker, v: ObjectMap, depth: usize) Error!void {
        var operators: usize = 0;
        for (v.keys()) |key| {
            if (key.len != 0 and key[0] == '$') operators += 1;
        }
        if (operators == 0) {
            if (self.scope.guarded()) return self.fail(error.GuardedColumnInWrite, "a replacement document rewrites every field of {s}, hidden and masked ones included; use $set", .{self.collectionName()});
            return self.document(.{ .object = v }, depth);
        }
        if (operators != v.count()) return self.fail(error.CommandInvalid, "an update mixes $operators and plain fields", .{});
        var it = v.iterator();
        while (it.next()) |entry| {
            const op = entry.key_ptr.*;
            const fields = entry.value_ptr.*;
            if (!update_ops.has(op)) return self.denied(op, "it is not on the allowed update operator list");
            if (fields != .object or fields.object.count() == 0) return self.fail(error.CommandInvalid, "{s} takes an object of fields", .{op});
            var each = fields.object.iterator();
            while (each.next()) |field| {
                const key = field.key_ptr.*;
                const val = field.value_ptr.*;
                try self.updatePath(key);
                if (std.mem.eql(u8, op, "$rename")) {
                    if (val != .string) return self.fail(error.CommandInvalid, "$rename maps a field to its new name", .{});
                    try self.updatePath(val.string);
                } else if (std.mem.eql(u8, op, "$pull")) {
                    try self.condition(val, depth + 2);
                } else if ((std.mem.eql(u8, op, "$push") or std.mem.eql(u8, op, "$addToSet")) and val == .object and val.object.get("$each") != null) {
                    var mods = val.object.iterator();
                    while (mods.next()) |m| {
                        if (!eqlAny(m.key_ptr.*, &.{ "$each", "$slice", "$sort", "$position" })) return self.denied(m.key_ptr.*, "it is not a $push modifier");
                        try self.literal(m.value_ptr.*, depth + 3);
                    }
                } else try self.literal(val, depth + 2);
            }
        }
    }

    fn updatePath(self: *Checker, text: []const u8) Error!void {
        if (text.len == 0 or text[0] == '$') return self.fail(error.CommandInvalid, "an update names fields, not {s}", .{text});
        return self.path(text);
    }
};

fn refusalText(why: access_mod.Refusal) []const u8 {
    return switch (why) {
        .blocked => "is blocked by the database access rules",
        .not_allowed => "is not on the allowed collection list",
    };
}

fn noOperatorKeys(object: ObjectMap) bool {
    for (object.keys()) |key| {
        if (key.len != 0 and key[0] == '$') return false;
    }
    return true;
}

fn eqlAny(text: []const u8, options: []const []const u8) bool {
    for (options) |option| {
        if (std.mem.eql(u8, text, option)) return true;
    }
    return false;
}

const Stage = enum { match, project, add_fields, unset, sort, limit, skip, count, sample, group, unwind, sort_by_count, bucket, bucket_auto, replace_root, replace_with, facet, lookup, union_with, graph_lookup, set_window_fields };

const stage_names = std.StaticStringMap(Stage).initComptime(.{
    .{ "$match", .match },                       .{ "$project", .project },          .{ "$addFields", .add_fields },
    .{ "$set", .add_fields },                    .{ "$unset", .unset },              .{ "$sort", .sort },
    .{ "$limit", .limit },                       .{ "$skip", .skip },                .{ "$count", .count },
    .{ "$sample", .sample },                     .{ "$group", .group },              .{ "$unwind", .unwind },
    .{ "$sortByCount", .sort_by_count },         .{ "$bucket", .bucket },            .{ "$bucketAuto", .bucket_auto },
    .{ "$replaceRoot", .replace_root },          .{ "$replaceWith", .replace_with }, .{ "$facet", .facet },
    .{ "$lookup", .lookup },                     .{ "$unionWith", .union_with },     .{ "$graphLookup", .graph_lookup },
    .{ "$setWindowFields", .set_window_fields },
});

const query_value_ops = std.StaticStringMap(void).initComptime(.{
    .{"$eq"},           .{"$ne"},    .{"$gt"},      .{"$gte"},        .{"$lt"},         .{"$lte"},
    .{"$in"},           .{"$nin"},   .{"$all"},     .{"$exists"},     .{"$type"},       .{"$size"},
    .{"$mod"},          .{"$regex"}, .{"$options"}, .{"$bitsAllSet"}, .{"$bitsAnySet"}, .{"$bitsAllClear"},
    .{"$bitsAnyClear"},
});

const update_ops = std.StaticStringMap(void).initComptime(.{
    .{"$set"},  .{"$unset"},    .{"$inc"},  .{"$mul"},     .{"$rename"}, .{"$min"},         .{"$max"}, .{"$currentDate"},
    .{"$push"}, .{"$addToSet"}, .{"$pull"}, .{"$pullAll"}, .{"$pop"},    .{"$setOnInsert"}, .{"$bit"},
});

pub const accumulator_ops = std.StaticStringMap(void).initComptime(.{
    .{"$sum"},            .{"$avg"},       .{"$min"},        .{"$max"},      .{"$first"},        .{"$last"},          .{"$push"},           .{"$addToSet"},
    .{"$count"},          .{"$stdDevPop"}, .{"$stdDevSamp"}, .{"$top"},      .{"$topN"},         .{"$bottom"},        .{"$bottomN"},        .{"$firstN"},
    .{"$lastN"},          .{"$maxN"},      .{"$minN"},       .{"$median"},   .{"$percentile"},   .{"$mergeObjects"},  .{"$rank"},           .{"$denseRank"},
    .{"$documentNumber"}, .{"$shift"},     .{"$derivative"}, .{"$integral"}, .{"$expMovingAvg"}, .{"$covariancePop"}, .{"$covarianceSamp"}, .{"$locf"},
    .{"$linearFill"},
});

pub const expression_ops = std.StaticStringMap(void).initComptime(.{
    .{"$abs"},           .{"$add"},              .{"$ceil"},             .{"$divide"},          .{"$exp"},
    .{"$floor"},         .{"$ln"},               .{"$log"},              .{"$log10"},           .{"$mod"},
    .{"$multiply"},      .{"$pow"},              .{"$round"},            .{"$sqrt"},            .{"$subtract"},
    .{"$trunc"},         .{"$arrayElemAt"},      .{"$arrayToObject"},    .{"$concatArrays"},    .{"$filter"},
    .{"$in"},            .{"$indexOfArray"},     .{"$isArray"},          .{"$map"},             .{"$range"},
    .{"$reduce"},        .{"$reverseArray"},     .{"$size"},             .{"$slice"},           .{"$sortArray"},
    .{"$zip"},           .{"$and"},              .{"$not"},              .{"$or"},              .{"$cmp"},
    .{"$eq"},            .{"$gt"},               .{"$gte"},              .{"$lt"},              .{"$lte"},
    .{"$ne"},            .{"$cond"},             .{"$ifNull"},           .{"$switch"},          .{"$dateAdd"},
    .{"$dateDiff"},      .{"$dateFromParts"},    .{"$dateFromString"},   .{"$dateSubtract"},    .{"$dateToParts"},
    .{"$dateToString"},  .{"$dateTrunc"},        .{"$dayOfMonth"},       .{"$dayOfWeek"},       .{"$dayOfYear"},
    .{"$hour"},          .{"$isoDayOfWeek"},     .{"$isoWeek"},          .{"$isoWeekYear"},     .{"$millisecond"},
    .{"$minute"},        .{"$month"},            .{"$second"},           .{"$toDate"},          .{"$week"},
    .{"$year"},          .{"$mergeObjects"},     .{"$objectToArray"},    .{"$allElementsTrue"}, .{"$anyElementTrue"},
    .{"$setDifference"}, .{"$setEquals"},        .{"$setIntersection"},  .{"$setIsSubset"},     .{"$setUnion"},
    .{"$concat"},        .{"$indexOfBytes"},     .{"$indexOfCP"},        .{"$ltrim"},           .{"$regexFind"},
    .{"$regexFindAll"},  .{"$regexMatch"},       .{"$replaceOne"},       .{"$replaceAll"},      .{"$rtrim"},
    .{"$split"},         .{"$strLenBytes"},      .{"$strLenCP"},         .{"$strcasecmp"},      .{"$substr"},
    .{"$substrBytes"},   .{"$substrCP"},         .{"$toLower"},          .{"$toString"},        .{"$trim"},
    .{"$toUpper"},       .{"$convert"},          .{"$isNumber"},         .{"$toBool"},          .{"$toDecimal"},
    .{"$toDouble"},      .{"$toInt"},            .{"$toLong"},           .{"$toObjectId"},      .{"$type"},
    .{"$let"},           .{"$rand"},             .{"$tsSecond"},         .{"$tsIncrement"},     .{"$binarySize"},
    .{"$bsonSize"},      .{"$sinh"},             .{"$cosh"},             .{"$tanh"},            .{"$sin"},
    .{"$cos"},           .{"$tan"},              .{"$asin"},             .{"$acos"},            .{"$atan"},
    .{"$atan2"},         .{"$degreesToRadians"}, .{"$radiansToDegrees"},
});

pub fn parse(arena: Allocator, text: []const u8, message: *[]const u8) Error!Command {
    if (text.len > max_command_bytes) {
        message.* = "the command is over 100000 bytes";
        return error.CommandInvalid;
    }
    const json_input = @import("../protocol/json_input.zig");
    const value = json_input.parseLeaky(Value, arena, text, .{}) catch {
        message.* = "the command is not one JSON object, e.g. {\"find\":\"users\",\"filter\":{\"age\":{\"$gt\":30}},\"limit\":10}";
        return error.CommandInvalid;
    };
    return parseValue(arena, value, message);
}

pub fn parseValue(arena: Allocator, value: Value, message: *[]const u8) Error!Command {
    if (value != .object or value.object.count() == 0) {
        message.* = "the command is one JSON object whose first key names the command, e.g. {\"find\":\"users\"}";
        return error.CommandInvalid;
    }
    const verb_name = value.object.keys()[0];
    const target = value.object.values()[0];
    var cmd: Command = undefined;
    if (std.meta.stringToEnum(ReadKind, verb_name)) |kind| {
        cmd = .{ .verb = .{ .read = kind }, .collection = "" };
    } else if (std.meta.stringToEnum(WriteKind, verb_name)) |kind| {
        cmd = .{ .verb = .{ .write = kind }, .collection = "" };
    } else {
        message.* = std.fmt.allocPrint(arena, "{s} is not a command emetgate runs: reads are find, aggregate, distinct and countDocuments; writes are insertOne, insertMany, updateOne, updateMany, deleteOne, deleteMany and drop", .{verb_name}) catch "unknown command";
        return error.CommandInvalid;
    }
    if (target != .string or target.string.len == 0 or target.string[0] == '$' or std.mem.indexOfScalar(u8, target.string, 0) != null) {
        message.* = std.fmt.allocPrint(arena, "{s} takes a collection name", .{verb_name}) catch "bad collection";
        return error.CommandInvalid;
    }
    cmd.collection = target.string;
    var it = value.object.iterator();
    _ = it.next();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        const allowed: []const []const u8 = switch (cmd.verb) {
            .read => |k| switch (k) {
                .find => &.{ "filter", "projection", "sort", "limit", "skip" },
                .aggregate => &.{"pipeline"},
                .distinct => &.{ "key", "filter" },
                .countDocuments => &.{"filter"},
            },
            .write => |k| switch (k) {
                .insertOne => &.{"document"},
                .insertMany => &.{"documents"},
                .updateOne, .updateMany => &.{ "filter", "update", "upsert" },
                .deleteOne, .deleteMany => &.{"filter"},
                .drop => &.{},
            },
        };
        if (!eqlAny(key, allowed)) {
            message.* = std.fmt.allocPrint(arena, "{s} does not take {s}; it takes: {s}", .{ verb_name, key, if (allowed.len == 0) "nothing else" else allowedText(arena, allowed) }) catch "unknown field";
            return error.CommandInvalid;
        }
        const bad: ?[]const u8 = blk: {
            if (eqlAny(key, &.{ "filter", "projection", "sort", "update", "document" })) {
                if (val != .object) break :blk "an object";
                if (std.mem.eql(u8, key, "filter")) cmd.filter = val.object;
                if (std.mem.eql(u8, key, "projection")) cmd.projection = val.object;
                if (std.mem.eql(u8, key, "sort")) cmd.sort = val.object;
                if (std.mem.eql(u8, key, "update")) cmd.update = val.object;
                if (std.mem.eql(u8, key, "document")) {
                    const one = arena.alloc(Value, 1) catch return error.OutOfMemory;
                    one[0] = val;
                    cmd.documents = one;
                }
            } else if (eqlAny(key, &.{ "limit", "skip" })) {
                if (val != .integer or val.integer < 0) break :blk "a non-negative integer";
                if (std.mem.eql(u8, key, "limit")) cmd.limit = val.integer else cmd.skip = val.integer;
            } else if (eqlAny(key, &.{ "pipeline", "documents" })) {
                if (val != .array) break :blk "an array";
                if (std.mem.eql(u8, key, "pipeline")) cmd.pipeline = val.array.items else cmd.documents = val.array.items;
            } else if (std.mem.eql(u8, key, "key")) {
                if (val != .string or val.string.len == 0) break :blk "a field path";
                cmd.key = val.string;
            } else if (std.mem.eql(u8, key, "upsert")) {
                if (val != .bool) break :blk "true or false";
                cmd.upsert = val.bool;
            }
            break :blk null;
        };
        if (bad) |what| {
            message.* = std.fmt.allocPrint(arena, "{s} is {s}", .{ key, what }) catch "bad field";
            return error.CommandInvalid;
        }
    }
    switch (cmd.verb) {
        .read => |k| if (k == .distinct and cmd.key == null) {
            message.* = "distinct needs key, the field whose values to list";
            return error.CommandInvalid;
        },
        .write => |k| switch (k) {
            .insertOne, .insertMany => if (cmd.documents.len == 0) {
                message.* = "insertOne needs document; insertMany needs a non-empty documents array";
                return error.CommandInvalid;
            },
            .updateOne, .updateMany => if (cmd.update == null or cmd.filter == null) {
                message.* = "an update needs filter and update ({\"$set\":{...}})";
                return error.CommandInvalid;
            },
            .deleteOne, .deleteMany => if (cmd.filter == null) {
                message.* = "a delete needs filter";
                return error.CommandInvalid;
            },
            .drop => {},
        },
    }
    return cmd;
}

fn allowedText(arena: Allocator, allowed: []const []const u8) []const u8 {
    return std.mem.join(arena, ", ", allowed) catch "";
}

pub fn checkRead(checker: *Checker, cmd: Command) Error!void {
    if (cmd.verb != .read) {
        checker.message = "emetgate_db only reads; a change goes through emetgate_db_write after the user types /db write";
        return error.StatementNotRead;
    }
    if (checker.scope.wholeGuarded()) return checker.fail(error.HiddenFieldUsed, "every field of {s} is hidden or masked", .{cmd.collection});
    if (cmd.filter) |f| try checker.filter(.{ .object = f }, 1);
    if (cmd.projection) |p| try checker.projection(.{ .object = p }, 1, false);
    if (cmd.sort) |s| try checker.sortSpec(.{ .object = s }, 1);
    if (cmd.key) |k| try checker.path(k);
    try checker.pipeline(cmd.pipeline, 1);
}

pub fn checkWrite(checker: *Checker, cmd: Command) Error!void {
    if (cmd.verb != .write) {
        checker.message = "this command only reads: run it with emetgate_db op query";
        return error.StatementOnlyReads;
    }
    checker.purpose = .write;
    if (cmd.filter) |f| try checker.filter(.{ .object = f }, 1);
    for (cmd.documents) |doc| try checker.document(doc, 1);
    if (cmd.update) |u| try checker.updateSpec(u, 1);
}

pub fn makeStage(arena: Allocator, op: []const u8, arg: Value) !Value {
    var object: ObjectMap = .empty;
    try object.put(arena, op, arg);
    return .{ .object = object };
}

pub fn stringArray(arena: Allocator, items: []const []const u8) !Value {
    var list = std.json.Array.init(arena);
    for (items) |item| try list.append(.{ .string = item });
    return .{ .array = list };
}

pub fn readPipeline(arena: Allocator, cmd: Command, hidden: []const []const u8, cap: i64) ![]const Value {
    var out: std.ArrayList(Value) = .empty;
    if (hidden.len != 0) try out.append(arena, try makeStage(arena, "$unset", try stringArray(arena, hidden)));
    switch (cmd.verb.read) {
        .find => {
            if (cmd.filter) |f| if (f.count() != 0) try out.append(arena, try makeStage(arena, "$match", .{ .object = f }));
            if (cmd.sort) |s| if (s.count() != 0) try out.append(arena, try makeStage(arena, "$sort", .{ .object = s }));
            if (cmd.skip) |n| if (n != 0) try out.append(arena, try makeStage(arena, "$skip", .{ .integer = n }));
            try out.append(arena, try makeStage(arena, "$limit", .{ .integer = if (cmd.limit) |n| (if (n == 0) cap else @min(n, cap)) else cap }));
            if (cmd.projection) |p| if (p.count() != 0) try out.append(arena, try makeStage(arena, "$project", .{ .object = p }));
            if (hidden.len != 0) try out.append(arena, try makeStage(arena, "$unset", try stringArray(arena, hidden)));
            return out.items;
        },
        .aggregate => try out.appendSlice(arena, cmd.pipeline),
        .distinct => {
            if (cmd.filter) |f| if (f.count() != 0) try out.append(arena, try makeStage(arena, "$match", .{ .object = f }));
            const ref = try std.fmt.allocPrint(arena, "${s}", .{cmd.key.?});
            try out.append(arena, try makeStage(arena, "$unwind", .{ .string = ref }));
            var group: ObjectMap = .empty;
            try group.put(arena, "_id", .{ .string = ref });
            try out.append(arena, try makeStage(arena, "$group", .{ .object = group }));
            var by: ObjectMap = .empty;
            try by.put(arena, "_id", .{ .integer = 1 });
            try out.append(arena, try makeStage(arena, "$sort", .{ .object = by }));
            var shape: ObjectMap = .empty;
            try shape.put(arena, "_id", .{ .integer = 0 });
            try shape.put(arena, "value", .{ .string = "$_id" });
            try out.append(arena, try makeStage(arena, "$project", .{ .object = shape }));
        },
        .countDocuments => {
            if (cmd.filter) |f| if (f.count() != 0) try out.append(arena, try makeStage(arena, "$match", .{ .object = f }));
            try out.append(arena, try makeStage(arena, "$count", .{ .string = "count" }));
            return out.items;
        },
    }
    if (hidden.len != 0) try out.append(arena, try makeStage(arena, "$unset", try stringArray(arena, hidden)));
    try out.append(arena, try makeStage(arena, "$limit", .{ .integer = cap }));
    return out.items;
}

pub fn isEmptyFilter(f: ?ObjectMap) bool {
    const object = f orelse return true;
    return object.count() == 0;
}

const testing = std.testing;

const test_rules: Access = .{
    .hidden = &.{.{ .table = "users", .column = "ssn" }},
    .masked = &.{.{ .table = "users", .column = "email", .mode = .email }},
    .blocked_tables = &.{"vault"},
};

fn checkText(text: []const u8) Error!void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var message: []const u8 = "";
    const cmd = try parse(arena.allocator(), text, &message);
    const names = [_][]const u8{cmd.collection};
    var checker: Checker = .{ .arena = arena.allocator(), .scope = .{ .access = test_rules, .names = &names } };
    return if (cmd.verb == .read) checkRead(&checker, cmd) else checkWrite(&checker, cmd);
}

test "db mongo guard: the walker names the rule each bypass hits" {
    const cases = [_]struct { []const u8, ?Error }{
        .{ "{\"find\":\"users\",\"filter\":{\"age\":{\"$gt\":3}},\"projection\":{\"email\":1}}", null },
        .{ "{\"find\":\"users\",\"filter\":{\"ssn\":{\"$regex\":\"^1\"}}}", error.HiddenFieldUsed },
        .{ "{\"find\":\"users\",\"filter\":{\"$expr\":{\"$eq\":[{\"$getField\":\"ssn\"},1]}}}", error.HiddenFieldUsed },
        .{ "{\"find\":\"users\",\"sort\":{\"email\":1}}", error.MaskedFieldUsed },
        .{ "{\"aggregate\":\"users\",\"pipeline\":[{\"$project\":{\"e\":\"$email\"}}]}", error.MaskedFieldUsed },
        .{ "{\"aggregate\":\"users\",\"pipeline\":[{\"$replaceWith\":\"$$ROOT\"}]}", error.OperatorDenied },
        .{ "{\"aggregate\":\"users\",\"pipeline\":[{\"$out\":\"x\"}]}", error.OperatorDenied },
        .{ "{\"aggregate\":\"users\",\"pipeline\":[{\"$lookup\":{\"from\":\"vault\",\"pipeline\":[],\"as\":\"v\"}}]}", error.TableRefused },
        .{ "{\"aggregate\":\"users\",\"pipeline\":[{\"$lookup\":{\"from\":\"users\",\"pipeline\":[],\"as\":\"v\"}}]}", error.OperatorDenied },
        .{ "{\"aggregate\":\"users\",\"pipeline\":[{\"$facet\":{\"a\":[]}}]}", error.OperatorDenied },
        .{ "{\"find\":\"users\",\"filter\":{\"$where\":\"1\"}}", error.OperatorDenied },
        .{ "{\"find\":\"users\",\"limit\":-1}", error.CommandInvalid },
        .{ "{\"updateOne\":\"users\",\"filter\":{},\"update\":{\"$set\":{\"ssn\":1}}}", error.GuardedColumnInWrite },
        .{ "{\"updateOne\":\"users\",\"filter\":{},\"update\":{\"name\":\"x\"}}", error.GuardedColumnInWrite },
        .{ "{\"insertOne\":\"users\",\"document\":{\"email\":\"x\"}}", error.GuardedColumnInWrite },
        .{ "{\"deleteMany\":\"users\",\"filter\":{\"age\":{\"$lt\":1}}}", null },
    };
    for (cases) |case| {
        if (case[1]) |want| {
            testing.expectError(want, checkText(case[0])) catch |err| {
                std.debug.print("{s}\n", .{case[0]});
                return err;
            };
        } else try checkText(case[0]);
    }
}

test "db mongo guard: a read pipeline starts and ends by unsetting hidden fields and caps the rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var message: []const u8 = "";
    const cmd = try parse(a, "{\"find\":\"users\",\"filter\":{\"age\":1},\"sort\":{\"age\":-1},\"skip\":2,\"limit\":500,\"projection\":{\"age\":1}}", &message);
    const stages = try readPipeline(a, cmd, &.{"ssn"}, 21);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(stages, .{}, &out.writer);
    try testing.expectEqualStrings("[{\"$unset\":[\"ssn\"]},{\"$match\":{\"age\":1}},{\"$sort\":{\"age\":-1}},{\"$skip\":2},{\"$limit\":21},{\"$project\":{\"age\":1}},{\"$unset\":[\"ssn\"]}]", out.written());
}
