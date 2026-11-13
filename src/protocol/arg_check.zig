//! One argument check for every tools/call: a key the tool does not take, or a value of the
//! wrong JSON type, is refused before the tool runs, so no parameter is ever silently ignored.
//! The accepted keys are the props tools/list serves (server.tool_defs, as servedDef picks them
//! for this policy), the aliases forgive.zig maps onto one of them, and the few honored keys the
//! schema leaves out (listed in `extras`). Items of `edits` and `files` are checked the same way.
const std = @import("std");
const server = @import("server.zig");
const policy_mod = @import("policy.zig");
const forgive = @import("forgive.zig");
const wire = @import("wire.zig");
const tool_result = @import("tool_result.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Prop = server.Prop;
const Tool = server.Tool;
const Policy = policy_mod.Policy;
const Alias = forgive.Alias;

/// The legacy batch tool is served by a hand-written schema (server.writeBatchToolDef); its
/// top-level keys are listed here. A call that names a file and no edits is one item, so the
/// item keys are accepted at the top level too (forgive.normalizeBatch).
pub const batch_def: Tool = .{
    .name = "emetgate_try_batch",
    .description = "",
    .props = &.{
        .{ .name = "edits", .desc = "", .optional = true, .ty = "array" },
        .{ .name = "retry", .desc = "", .optional = true },
    },
};

/// Fields of one `edits` item of emetgate_change, emetgate_try_batch (and of the item that
/// emetgate_try and emetgate_write_doc are made into): every edit shape of emetgate_try_batch.
pub const edit_item_props = [_]Prop{
    .{ .name = "file", .desc = "" },
    .{ .name = "old_string", .desc = "", .optional = true },
    .{ .name = "new_string", .desc = "", .optional = true },
    .{ .name = "replace_all", .desc = "", .optional = true, .ty = "boolean" },
    .{ .name = "content", .desc = "", .optional = true },
    .{ .name = "hash", .desc = "", .optional = true },
    .{ .name = "symbol", .desc = "", .optional = true },
    .{ .name = "body", .desc = "", .optional = true },
    .{ .name = "node", .desc = "", .optional = true },
    .{ .name = "text", .desc = "", .optional = true },
    .{ .name = "nodes", .desc = "", .optional = true, .ty = "array" },
    .{ .name = "pointer", .desc = "", .optional = true },
    .{ .name = "heading", .desc = "", .optional = true },
    .{ .name = "line_start", .desc = "", .optional = true, .ty = "integer" },
    .{ .name = "line_end", .desc = "", .optional = true, .ty = "integer" },
    .{ .name = "line", .desc = "", .optional = true, .ty = "integer" },
    .{ .name = "kind", .desc = "", .optional = true },
    .{ .name = "op", .desc = "", .optional = true },
};

/// Fields of one object item of emetgate_read_file `files` (read_tools.Options.over).
pub const file_item_props = [_]Prop{
    .{ .name = "file", .desc = "" },
    .{ .name = "raw", .desc = "", .optional = true, .ty = "boolean" },
    .{ .name = "force", .desc = "", .optional = true, .ty = "boolean" },
    .{ .name = "pointer", .desc = "", .optional = true },
    .{ .name = "heading", .desc = "", .optional = true },
    .{ .name = "line_start", .desc = "", .optional = true, .ty = "integer" },
    .{ .name = "line_end", .desc = "", .optional = true, .ty = "integer" },
};

const detail_prop: Prop = .{ .name = "detail", .desc = "", .optional = true };
const message_prop: Prop = .{ .name = "message", .desc = "", .optional = true };
/// emetgate_write_doc is one batch item (forgive.normalize sends it through the batch).
const write_doc_extras = [_]Prop{ detail_prop, message_prop } ++ edit_item_props;

/// Keys a tool honors that its served schema leaves out.
fn extras(name: []const u8, policy: Policy) []const Prop {
    if (eql(name, "emetgate_symbols")) return &.{ .{ .name = "within", .desc = "", .optional = true }, detail_prop };
    if (eql(name, "emetgate_try") or eql(name, "emetgate_edit") or eql(name, "emetgate_write") or eql(name, "emetgate_try_batch")) return &.{ detail_prop, message_prop };
    if (eql(name, "emetgate_write_doc")) return &write_doc_extras;
    if (eql(name, "emetgate_change") and policy.commit) return &.{message_prop};
    if (eql(name, "emetgate_search") and policy.search_internals) return &.{
        .{ .name = "format", .desc = "", .optional = true },
        .{ .name = "certificate", .desc = "", .optional = true, .ty = "boolean" },
        .{ .name = "stats", .desc = "", .optional = true, .ty = "boolean" },
    };
    for (server.commit_tools) |tool| if (eql(tool, name)) return &.{message_prop};
    return &.{};
}

fn aliasesOf(name: []const u8) []const Alias {
    if (eql(name, "emetgate_try") or eql(name, "emetgate_write_doc") or eql(name, "emetgate_try_batch")) return &forgive.item_aliases;
    if (eql(name, "emetgate_write")) return &forgive.write_aliases;
    if (eql(name, "emetgate_edit")) return &forgive.edit_aliases;
    if (eql(name, "emetgate_rename")) return &forgive.rename_aliases;
    if (eql(name, "emetgate_move")) return &forgive.move_aliases;
    if (eql(name, "emetgate_move_file")) return &forgive.move_file_aliases;
    return &.{};
}

/// The definition a call to `name` is checked against, or null for a name no table holds
/// (the call then answers UnknownTool as before).
pub fn definition(name: []const u8, policy: Policy) ?Tool {
    if (eql(name, batch_def.name)) return batch_def;
    for (server.tool_defs) |tool| {
        if (eql(tool.name, name)) return server.servedDef(tool, policy.open_run);
    }
    return null;
}

/// Checks a tools/call's arguments. Null when they are accepted. An unknown key gives the error
/// reply (owned by the caller) in the shape every tool error has: status, error, exit_code,
/// message and a fix naming the accepted parameters. A value of the wrong JSON type returns
/// error.MissingArgument with tool_result.missingField() naming it and its type.
pub fn check(gpa: Allocator, name: []const u8, arguments: ?Value, policy: Policy) !?[]u8 {
    const tool = definition(name, policy) orelse return null;
    const args = arguments orelse return null;
    if (args != .object) return null;
    var it = args.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        for (policy_mod.model_policy_fields) |field| {
            if (eql(key, field)) return try reply(gpa, "ModelSuppliedTestPolicy", wire.exitCode(error.ModelSuppliedTestPolicy), "{s} is set only by the user who starts the server", .{key}, null, .{});
        }
        const spec = accepted(name, tool, key, policy) orelse {
            var names: NameList = .{};
            names.addTool(name, tool, policy);
            return try reply(gpa, "UnknownArgument", 2, "{s} has no parameter {s}", .{ name, key }, "{s} takes {s}; remove {s}", .{ name, names.text(), key });
        };
        if (!typeFits(spec, name, value)) return typeRefusal("", key, spec);
        if (eql(key, "edits") and (eql(name, "emetgate_change") or eql(name, "emetgate_try_batch"))) {
            if (try checkItems(gpa, "edits", value, &edit_item_props, &forgive.item_aliases)) |refused| return refused;
        }
        if (eql(key, "files") and eql(name, "emetgate_read_file")) {
            if (try checkItems(gpa, "files", value, &file_item_props, &.{})) |refused| return refused;
        }
    }
    return null;
}

fn accepted(name: []const u8, tool: Tool, key: []const u8, policy: Policy) ?Prop {
    if (find(tool.props, key)) |prop| return prop;
    const more = extras(name, policy);
    if (find(more, key)) |prop| return prop;
    if (eql(name, batch_def.name)) if (find(&edit_item_props, key)) |prop| return prop;
    if (canonical(aliasesOf(name), key)) |target| {
        if (find(tool.props, target) != null or find(more, target) != null) return .{ .name = key, .desc = "", .optional = true, .ty = "any" };
        if (eql(name, batch_def.name) and find(&edit_item_props, target) != null) return .{ .name = key, .desc = "", .optional = true, .ty = "any" };
    }
    return null;
}

fn checkItems(gpa: Allocator, field: []const u8, list: Value, props: []const Prop, aliases: []const Alias) !?[]u8 {
    const items: []const Value = switch (list) {
        .array => |a| a.items,
        .object => (&list)[0..1],
        else => return null,
    };
    for (items, 0..) |item, i| {
        if (item != .object) continue;
        var it = item.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const spec = itemField(props, aliases, key) orelse {
                var names: NameList = .{};
                names.addProps(props);
                return try reply(gpa, "UnknownArgument", 2, "{s}[{d}] has no field {s}", .{ field, i, key }, "an item of {s} takes {s}; remove {s}", .{ field, names.text(), key });
            };
            if (!typeFits(spec, "", entry.value_ptr.*)) {
                var where_buf: [48]u8 = undefined;
                const where = std.fmt.bufPrint(&where_buf, "{s}[{d}].", .{ field, i }) catch field;
                return typeRefusal(where, key, spec);
            }
        }
    }
    return null;
}

fn itemField(props: []const Prop, aliases: []const Alias, key: []const u8) ?Prop {
    if (find(props, key)) |prop| return prop;
    const target = canonical(aliases, key) orelse return null;
    if (find(props, target) == null) return null;
    return .{ .name = key, .desc = "", .optional = true, .ty = "any" };
}

fn typeFits(prop: Prop, name: []const u8, value: Value) bool {
    if (value == .null) return true;
    if (eql(prop.ty, "any")) return true;
    if (eql(prop.ty, "string")) return value == .string;
    if (eql(prop.ty, "boolean")) return value == .bool;
    if (eql(prop.ty, "integer")) return value == .integer or (value == .number_string and isInteger(value.number_string));
    if (eql(prop.ty, "array")) {
        if (value == .array) return true;
        // git takes args as one string split on spaces; the batch tool takes one item as edits.
        if (eql(prop.name, "args")) return value == .string;
        if (eql(prop.name, "edits") and eql(name, batch_def.name)) return value == .object;
        return false;
    }
    return true;
}

fn isInteger(text: []const u8) bool {
    if (text.len == 0) return false;
    const digits = if (text[0] == '-') text[1..] else text;
    if (digits.len == 0) return false;
    for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// A value of the wrong type is the invalid-params error a tool gives for it
/// ("Missing or invalid argument: raw (boolean)"), so it reads the same wherever it is caught.
fn typeRefusal(where: []const u8, key: []const u8, prop: Prop) error{MissingArgument} {
    return tool_result.missing("{s}{s} ({s})", .{ where, key, typeWord(prop.ty) });
}

fn typeWord(ty: []const u8) []const u8 {
    if (eql(ty, "boolean")) return "boolean";
    if (eql(ty, "integer")) return "integer";
    if (eql(ty, "array")) return "array";
    return "string";
}

fn reply(gpa: Allocator, name: []const u8, exit_code: u8, comptime message_fmt: []const u8, message_args: anytype, comptime fix_fmt: ?[]const u8, fix_args: anytype) ![]u8 {
    var message_buf: [512]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buf, message_fmt, message_args) catch message_buf[0..];
    wire.clearFix();
    if (fix_fmt) |fmt| wire.setFix(fmt, fix_args);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try wire.writeErrorMessage(&out.writer, name, exit_code, message);
    const written = out.written();
    const end = if (written.len > 0 and written[written.len - 1] == '\n') written.len - 1 else written.len;
    return gpa.dupe(u8, written[0..end]);
}

/// The accepted names, comma separated, for a fix.
const NameList = struct {
    buf: [640]u8 = undefined,
    len: usize = 0,

    fn add(self: *NameList, name: []const u8) void {
        const sep: []const u8 = if (self.len == 0) "" else ", ";
        if (self.len + sep.len + name.len > self.buf.len) return;
        @memcpy(self.buf[self.len..][0..sep.len], sep);
        self.len += sep.len;
        @memcpy(self.buf[self.len..][0..name.len], name);
        self.len += name.len;
    }

    fn addProps(self: *NameList, props: []const Prop) void {
        for (props) |prop| self.add(prop.name);
    }

    fn addTool(self: *NameList, name: []const u8, tool: Tool, policy: Policy) void {
        const nested = policy.nested_roots.len != 0;
        for (tool.props) |prop| if (!prop.nested or nested) self.add(prop.name);
        for (extras(name, policy)) |prop| {
            if (eql(prop.name, "message") and !policy.commit) continue;
            if (find(&edit_item_props, prop.name) != null) continue;
            self.add(prop.name);
        }
        if (self.len == 0) self.add("no parameters");
    }

    fn text(self: *const NameList) []const u8 {
        return self.buf[0..self.len];
    }
};

fn find(props: []const Prop, key: []const u8) ?Prop {
    for (props) |prop| if (eql(prop.name, key)) return prop;
    return null;
}

fn canonical(aliases: []const Alias, key: []const u8) ?[]const u8 {
    for (aliases) |alias| {
        for (alias[1]) |other| if (eql(other, key)) return alias[0];
    }
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
