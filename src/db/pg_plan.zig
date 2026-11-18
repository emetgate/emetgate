const std = @import("std");
const access_mod = @import("access.zig");
const engine = @import("engine.zig");
const pg_sql = @import("pg_sql.zig");

const Allocator = std.mem.Allocator;
const Access = access_mod.Access;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Token = pg_sql.Token;

pub const RelationFacts = struct {
    schema: []const u8,
    name: []const u8,
    chain: []const []const u8,
    system: bool = false,
    columns: []const []const u8 = &.{},
};

pub const Origin = struct {
    schema: []const u8,
    table: []const u8,
    column: []const u8,
    chain: []const []const u8,
};

pub const ResultField = struct {
    name: []const u8,
    origin: ?Origin = null,
};

pub const Evidence = struct {
    plan: []const u8,
    fields: []const ResultField = &.{},
    relations: []const RelationFacts = &.{},
    shadowed: []const []const u8 = &.{},
    operators: []const []const u8 = &.{},
};

pub const Needs = struct {
    relations: []const pg_sql.Name,
    functions: []const []const u8,
};

pub const Target = struct {
    action: engine.WriteAction,
    schema: []const u8,
    name: []const u8,
    chain: []const []const u8,
};

pub const Refusal = struct {
    err: engine.Error,
    message: []const u8,
};

pub const Approval = struct {
    treatments: []engine.Treatment,
    nulled: []const []const u8,
    targets: []const Target,
    relations: []const []const []const u8,
};

pub const Verdict = union(enum) {
    ok: Approval,
    refused: Refusal,
};

pub const system_schemas = [_][]const u8{ "pg_catalog", "information_schema" };

pub fn isSystemSchema(schema: []const u8) bool {
    for (system_schemas) |s| {
        if (std.mem.eql(u8, schema, s)) return true;
    }
    return std.mem.startsWith(u8, schema, "pg_toast");
}

pub const allowed_functions = std.StaticStringMap(void).initComptime(.{
    .{"abs"},                   .{"ceil"},                  .{"ceiling"},               .{"floor"},                  .{"round"},
    .{"trunc"},                 .{"sign"},                  .{"mod"},                   .{"div"},                    .{"power"},
    .{"pow"},                   .{"sqrt"},                  .{"cbrt"},                  .{"exp"},                    .{"ln"},
    .{"log"},                   .{"log10"},                 .{"pi"},                    .{"degrees"},                .{"radians"},
    .{"sin"},                   .{"cos"},                   .{"tan"},                   .{"asin"},                   .{"acos"},
    .{"atan"},                  .{"atan2"},                 .{"sinh"},                  .{"cosh"},                   .{"tanh"},
    .{"gcd"},                   .{"lcm"},                   .{"width_bucket"},          .{"random"},                 .{"scale"},
    .{"lower"},                 .{"upper"},                 .{"initcap"},               .{"length"},                 .{"char_length"},
    .{"character_length"},      .{"octet_length"},          .{"bit_length"},            .{"substr"},                 .{"substring"},
    .{"left"},                  .{"right"},                 .{"lpad"},                  .{"rpad"},                   .{"ltrim"},
    .{"rtrim"},                 .{"btrim"},                 .{"replace"},               .{"reverse"},                .{"repeat"},
    .{"split_part"},            .{"strpos"},                .{"position"},              .{"concat"},                 .{"concat_ws"},
    .{"format"},                .{"translate"},             .{"ascii"},                 .{"chr"},                    .{"starts_with"},
    .{"regexp_replace"},        .{"regexp_match"},          .{"regexp_matches"},        .{"regexp_split_to_array"},  .{"regexp_split_to_table"},
    .{"regexp_like"},           .{"regexp_count"},          .{"regexp_substr"},         .{"regexp_instr"},           .{"textcat"},
    .{"like_escape"},           .{"quote_ident"},           .{"quote_literal"},         .{"quote_nullable"},         .{"to_char"},
    .{"to_number"},             .{"to_date"},               .{"to_timestamp"},          .{"to_hex"},                 .{"md5"},
    .{"sha224"},                .{"sha256"},                .{"sha384"},                .{"sha512"},                 .{"encode"},
    .{"decode"},                .{"string_to_array"},       .{"array_to_string"},       .{"string_to_table"},        .{"normalize"},
    .{"now"},                   .{"clock_timestamp"},       .{"statement_timestamp"},   .{"transaction_timestamp"},  .{"date_trunc"},
    .{"date_part"},             .{"date_bin"},              .{"extract"},               .{"age"},                    .{"make_date"},
    .{"make_time"},             .{"make_timestamp"},        .{"make_timestamptz"},      .{"make_interval"},          .{"timezone"},
    .{"isfinite"},              .{"justify_days"},          .{"justify_hours"},         .{"justify_interval"},       .{"overlaps"},
    .{"count"},                 .{"sum"},                   .{"avg"},                   .{"min"},                    .{"max"},
    .{"bool_and"},              .{"bool_or"},               .{"every"},                 .{"array_agg"},              .{"string_agg"},
    .{"json_agg"},              .{"jsonb_agg"},             .{"json_object_agg"},       .{"jsonb_object_agg"},       .{"stddev"},
    .{"stddev_pop"},            .{"stddev_samp"},           .{"variance"},              .{"var_pop"},                .{"var_samp"},
    .{"corr"},                  .{"covar_pop"},             .{"covar_samp"},            .{"percentile_cont"},        .{"percentile_disc"},
    .{"mode"},                  .{"bit_and"},               .{"bit_or"},                .{"bit_xor"},                .{"any_value"},
    .{"row_number"},            .{"rank"},                  .{"dense_rank"},            .{"percent_rank"},           .{"cume_dist"},
    .{"ntile"},                 .{"lag"},                   .{"lead"},                  .{"first_value"},            .{"last_value"},
    .{"nth_value"},             .{"to_json"},               .{"to_jsonb"},              .{"row_to_json"},            .{"array_to_json"},
    .{"json_build_object"},     .{"jsonb_build_object"},    .{"json_build_array"},      .{"jsonb_build_array"},      .{"json_object"},
    .{"jsonb_object"},          .{"json_array_length"},     .{"jsonb_array_length"},    .{"json_each"},              .{"jsonb_each"},
    .{"json_each_text"},        .{"jsonb_each_text"},       .{"json_extract_path"},     .{"jsonb_extract_path"},     .{"json_extract_path_text"},
    .{"jsonb_extract_path_text"}, .{"json_object_keys"},    .{"jsonb_object_keys"},     .{"json_array_elements"},    .{"jsonb_array_elements"},
    .{"json_array_elements_text"}, .{"jsonb_array_elements_text"}, .{"json_typeof"},    .{"jsonb_typeof"},           .{"jsonb_set"},
    .{"jsonb_insert"},          .{"jsonb_pretty"},          .{"json_strip_nulls"},      .{"jsonb_strip_nulls"},      .{"jsonb_path_query"},
    .{"jsonb_path_query_array"}, .{"jsonb_path_query_first"}, .{"jsonb_path_exists"},   .{"jsonb_path_match"},       .{"json_populate_record"},
    .{"jsonb_populate_record"}, .{"json_to_record"},        .{"jsonb_to_record"},       .{"json_to_recordset"},      .{"jsonb_to_recordset"},
    .{"array_length"},          .{"array_append"},          .{"array_prepend"},         .{"array_cat"},              .{"array_position"},
    .{"array_positions"},       .{"array_remove"},          .{"array_replace"},         .{"array_dims"},             .{"array_lower"},
    .{"array_upper"},           .{"array_ndims"},           .{"cardinality"},           .{"unnest"},                 .{"array_fill"},
    .{"generate_subscripts"},   .{"trim_array"},            .{"generate_series"},       .{"num_nulls"},              .{"num_nonnulls"},
    .{"gen_random_uuid"},       .{"pg_typeof"},             .{"version"},               .{"current_database"},       .{"current_schema"},
    .{"pg_size_pretty"},        .{"to_tsvector"},           .{"to_tsquery"},            .{"plainto_tsquery"},        .{"phraseto_tsquery"},
    .{"websearch_to_tsquery"},  .{"ts_rank"},               .{"ts_rank_cd"},            .{"ts_headline"},            .{"text"},
    .{"int2"},                  .{"int4"},                  .{"int8"},                  .{"float4"},                 .{"float8"},
    .{"numeric"},               .{"bool"},                  .{"date"},                  .{"time"},                   .{"timestamp"},
    .{"timestamptz"},           .{"interval"},              .{"varchar"},               .{"bpchar"},                 .{"isempty"},
    .{"lower_inc"},             .{"upper_inc"},             .{"lower_inf"},             .{"upper_inf"},              .{"range_merge"},
    .{"host"},                  .{"network"},               .{"netmask"},               .{"masklen"},                .{"family"},
});

pub const write_functions = std.StaticStringMap(void).initComptime(.{
    .{"nextval"},
});

pub const ddl_denied_functions = std.StaticStringMap(void).initComptime(.{
    .{"pg_read_file"},     .{"pg_read_binary_file"}, .{"pg_ls_dir"},          .{"pg_stat_file"},        .{"lo_import"},
    .{"lo_export"},        .{"lo_get"},              .{"lo_open"},            .{"loread"},              .{"lo_from_bytea"},
    .{"query_to_xml"},     .{"query_to_xmlschema"},  .{"query_to_xml_and_xmlschema"}, .{"table_to_xml"}, .{"table_to_xmlschema"},
    .{"table_to_xml_and_xmlschema"}, .{"cursor_to_xml"}, .{"schema_to_xml"},    .{"database_to_xml"},     .{"dblink"},
    .{"dblink_exec"},      .{"dblink_connect"},      .{"set_config"},         .{"current_setting"},     .{"pg_sleep"},
    .{"pg_terminate_backend"}, .{"pg_cancel_backend"}, .{"pg_reload_conf"},   .{"pg_file_write"},       .{"pg_ls_logdir"},
});

const node_types_read = std.StaticStringMap(void).initComptime(.{
    .{"Result"},          .{"ProjectSet"},       .{"Append"},            .{"Merge Append"},        .{"Recursive Union"},
    .{"BitmapAnd"},       .{"BitmapOr"},         .{"Nested Loop"},       .{"Merge Join"},          .{"Hash Join"},
    .{"Seq Scan"},        .{"Sample Scan"},      .{"Gather"},            .{"Gather Merge"},        .{"Index Scan"},
    .{"Index Only Scan"}, .{"Bitmap Index Scan"}, .{"Bitmap Heap Scan"}, .{"Tid Scan"},            .{"Tid Range Scan"},
    .{"Subquery Scan"},   .{"Function Scan"},    .{"Table Function Scan"}, .{"Values Scan"},       .{"CTE Scan"},
    .{"WorkTable Scan"},  .{"Foreign Scan"},     .{"Materialize"},       .{"Memoize"},             .{"Sort"},
    .{"Incremental Sort"}, .{"Group"},           .{"Aggregate"},         .{"WindowAgg"},           .{"Unique"},
    .{"SetOp"},           .{"Limit"},            .{"Hash"},
});

const scan_types = std.StaticStringMap(void).initComptime(.{
    .{"Seq Scan"}, .{"Sample Scan"}, .{"Index Scan"}, .{"Index Only Scan"}, .{"Bitmap Heap Scan"}, .{"Tid Scan"}, .{"Tid Range Scan"}, .{"Foreign Scan"},
});

const derived_types = std.StaticStringMap(void).initComptime(.{
    .{"Subquery Scan"}, .{"CTE Scan"}, .{"WorkTable Scan"}, .{"Function Scan"}, .{"Table Function Scan"}, .{"Values Scan"}, .{"Named Tuplestore Scan"},
});

const metadata_keys = std.StaticStringMap(void).initComptime(.{
    .{"Node Type"},         .{"Parent Relationship"}, .{"Relation Name"}, .{"Schema"},        .{"Alias"},
    .{"Strategy"},          .{"Partial Mode"},        .{"Join Type"},     .{"Scan Direction"}, .{"Index Name"},
    .{"Subplan Name"},      .{"CTE Name"},            .{"Function Name"}, .{"Command"},       .{"Operation"},
    .{"Conflict Resolution"}, .{"Conflict Arbiter Indexes"}, .{"Cache Mode"}, .{"Sampling Method"}, .{"Plans"},
    .{"Output"},
});

const Node = struct {
    obj: *const ObjectMap,
    parent: ?usize,
    relationship: []const u8,
    node_type: []const u8,
};

const Entry = union(enum) {
    base: struct { chain: []const []const u8, label: []const u8, guarded: bool },
    derived: struct { tainted: bool, producer: ?usize, fixed: bool },
};

const Class = enum { plain, hidden, masked, tainted, unknown };

const Ref = struct {
    alias: ?[]const u8,
    column: ?[]const u8,
    label_buf: [300]u8 = undefined,
    label_len: usize = 0,
};

fn strField(obj: *const ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn chainTreatment(access: Access, chain: []const []const u8, column: []const u8) engine.Treatment {
    for (chain) |name| {
        if (access.isHidden(name, column)) return .hidden;
    }
    for (chain) |name| {
        if (access.maskOf(name, column)) |mask| return .{ .masked = mask };
    }
    return .plain;
}

fn rowGuarded(access: Access, chain: []const []const u8, columns: []const []const u8) bool {
    if (columns.len == 0) return chainGuards(access, chain);
    for (columns) |column| {
        if (chainTreatment(access, chain, column) != .plain) return true;
    }
    return false;
}

fn chainGuards(access: Access, chain: []const []const u8) bool {
    for (chain) |name| {
        if (access.guards(name)) return true;
    }
    return false;
}

fn chainRefusal(access: Access, chain: []const []const u8) ?struct { name: []const u8, why: access_mod.Refusal } {
    for (chain) |name| {
        if (access.isBlocked(name)) return .{ .name = name, .why = .blocked };
    }
    if (access.allowed_tables.len == 0) return null;
    for (chain) |name| {
        if (access.tableRefusal(name) == null) return null;
    }
    return .{ .name = chain[0], .why = .not_allowed };
}

pub fn treatmentOf(access: Access, origin: Origin) engine.Treatment {
    return chainTreatment(access, origin.chain, origin.column);
}

fn isKeyword(token: Token) bool {
    if (token.kind != .ident) return false;
    var letters = false;
    for (token.text) |c| {
        if (std.ascii.isLower(c)) return false;
        if (std.ascii.isUpper(c)) letters = true;
    }
    return letters;
}

fn nameText(arena: Allocator, token: Token) ![]const u8 {
    return pg_sql.unquote(arena, token);
}

const Chain = struct {
    parts: [4]Token = undefined,
    len: usize = 0,
    star: bool = false,
    end: usize,
    call: bool = false,
};

fn readChain(tokens: []const Token, at: usize) Chain {
    var chain: Chain = .{ .end = at + 1 };
    chain.parts[0] = tokens[at];
    chain.len = 1;
    var j = at + 1;
    while (j + 1 < tokens.len and tokens[j].is(.punct, ".")) {
        const next = tokens[j + 1];
        if (next.is(.op, "*")) {
            chain.star = true;
            j += 2;
            break;
        }
        if (!next.isName() or chain.len == chain.parts.len) break;
        chain.parts[chain.len] = next;
        chain.len += 1;
        j += 2;
    }
    chain.end = j;
    if (!chain.star and j < tokens.len and tokens[j].is(.punct, "(")) chain.call = true;
    return chain;
}

fn skipType(tokens: []const Token, at: usize) usize {
    var i = at;
    while (i < tokens.len) {
        const t = tokens[i];
        if ((t.kind == .ident and !isKeyword(t)) or t.kind == .quoted) {
            i += 1;
            continue;
        }
        if (t.is(.punct, ".") and i + 1 < tokens.len and tokens[i + 1].isName()) {
            i += 1;
            continue;
        }
        break;
    }
    if (i < tokens.len and tokens[i].is(.punct, "(")) {
        var depth: usize = 0;
        while (i < tokens.len) : (i += 1) {
            if (tokens[i].is(.punct, "(")) depth += 1;
            if (tokens[i].is(.punct, ")")) {
                depth -= 1;
                if (depth == 0) {
                    i += 1;
                    break;
                }
            }
        }
    }
    while (i + 1 < tokens.len and tokens[i].is(.punct, "[") and tokens[i + 1].is(.punct, "]")) i += 2;
    return i;
}

const Sink = struct {
    ctx: *anyopaque,
    ref: *const fn (ctx: *anyopaque, chain: Chain, bare: bool) anyerror!void,
    call: *const fn (ctx: *anyopaque, chain: Chain) anyerror!void,
    op: *const fn (ctx: *anyopaque, text: []const u8, schema: ?Token) anyerror!void,
};

fn scanTokens(tokens: []const Token, sink: Sink, bare_ok: bool) !void {
    var i: usize = 0;
    if (bare_ok and tokens.len != 0 and tokens[0].isName() and !isKeyword(tokens[0])) {
        const chain = readChain(tokens, 0);
        if (!chain.call and chain.end == tokens.len) return sink.ref(sink.ctx, chain, true);
    }
    while (i < tokens.len) {
        const t = tokens[i];
        if (t.is(.punct, "::")) {
            i = skipType(tokens, i + 1);
            continue;
        }
        switch (t.kind) {
            .string, .number, .param, .punct => {
                i += 1;
                continue;
            },
            .op => {
                try sink.op(sink.ctx, t.text, null);
                i += 1;
                continue;
            },
            else => {},
        }
        if (isKeyword(t)) {
            if (std.mem.eql(u8, t.text, "OPERATOR") and i + 1 < tokens.len and tokens[i + 1].is(.punct, "(")) {
                var j = i + 2;
                var schema: ?Token = null;
                var op_text: []const u8 = "";
                while (j < tokens.len and !tokens[j].is(.punct, ")")) : (j += 1) {
                    if (tokens[j].isName()) schema = tokens[j];
                    if (tokens[j].kind == .op) op_text = tokens[j].text;
                }
                try sink.op(sink.ctx, op_text, schema orelse Token{ .kind = .ident, .text = "pg_catalog", .start = 0 });
                i = j + 1;
                continue;
            }
            i += 1;
            continue;
        }
        const chain = readChain(tokens, i);
        if (chain.call) try sink.call(sink.ctx, chain) else try sink.ref(sink.ctx, chain, false);
        i = chain.end;
    }
}

const Analyzer = struct {
    arena: Allocator,
    access: Access,
    mode: engine.Mode,
    evidence: Evidence,
    nodes: std.ArrayList(Node) = .empty,
    aliases: std.StringHashMapUnmanaged(Entry) = .empty,
    partition_appends: std.AutoHashMapUnmanaged(usize, void) = .empty,
    refusal: ?Refusal = null,
    any_guarded: bool = false,
    any_tainted: bool = false,
    single: ?[]const u8 = null,
    targets: std.ArrayList(Target) = .empty,
    chains: std.ArrayList([]const []const u8) = .empty,
    carry_hit: bool = false,
    collect_functions: ?*std.ArrayList([]const u8) = null,

    fn refuse(self: *Analyzer, err: engine.Error, comptime fmt: []const u8, args: anytype) error{Refused} {
        if (self.refusal == null) {
            self.refusal = .{ .err = err, .message = std.fmt.allocPrint(self.arena, fmt, args) catch "refused" };
        }
        return error.Refused;
    }

    fn flatten(self: *Analyzer, value: *const Value, parent: ?usize) !void {
        if (value.* != .object) return self.refuse(error.SqlFailed, "the query plan could not be read", .{});
        const obj = &value.object;
        const index = self.nodes.items.len;
        try self.nodes.append(self.arena, .{
            .obj = obj,
            .parent = parent,
            .relationship = strField(obj, "Parent Relationship") orelse "",
            .node_type = strField(obj, "Node Type") orelse "",
        });
        if (obj.getPtr("Plans")) |plans| {
            if (plans.* != .array) return self.refuse(error.SqlFailed, "the query plan could not be read", .{});
            for (plans.array.items) |*child| try self.flatten(child, index);
        }
    }

    fn findRelation(self: *Analyzer, schema: []const u8, name: []const u8) ?RelationFacts {
        for (self.evidence.relations) |rel| {
            if (std.mem.eql(u8, rel.schema, schema) and std.mem.eql(u8, rel.name, name)) return rel;
        }
        return null;
    }

    fn putAlias(self: *Analyzer, alias: []const u8, entry: Entry) !void {
        if (self.aliases.getPtr(alias)) |known| {
            switch (known.*) {
                .base => |b| if (entry == .base and b.chain.ptr == entry.base.chain.ptr) return,
                .derived => {},
            }
            return self.refuse(error.SqlFailed, "the query plan names {s} twice, so its columns cannot be traced; give each table its own alias", .{alias});
        }
        try self.aliases.put(self.arena, alias, entry);
    }

    fn relations(self: *Analyzer) !void {
        for (self.nodes.items, 0..) |node, index| {
            const t = node.node_type;
            const is_modify = std.mem.eql(u8, t, "ModifyTable");
            if (self.mode == .read) {
                if (is_modify or std.mem.eql(u8, t, "LockRows")) return self.refuse(error.StatementNotRead, "this connection only reads: the statement would change or lock rows", .{});
                if (!node_types_read.has(t)) return self.refuse(error.ActionDenied, "the plan uses a {s} step, which emetgate does not check, so the statement is refused", .{t});
            } else if (!is_modify and !std.mem.eql(u8, t, "LockRows") and !node_types_read.has(t)) {
                return self.refuse(error.ActionDenied, "the plan uses a {s} step, which emetgate does not check, so the statement is refused", .{t});
            }
            if (strField(node.obj, "Relation Name")) |name| {
                const schema = strField(node.obj, "Schema") orelse "";
                const rel = self.findRelation(schema, name) orelse return self.refuse(error.SqlFailed, "relation {s}.{s} could not be looked up", .{ schema, name });
                if (rel.system or isSystemSchema(schema)) return self.refuse(error.TableRefused, "{s}.{s} is a system catalog; read the schema with op tables and op describe instead", .{ schema, name });
                if (chainRefusal(self.access, rel.chain)) |refused| {
                    const why = if (refused.why == .not_allowed) "is not on the allowed table list" else "is blocked";
                    return self.refuse(error.TableRefused, "table {s} {s} by the database access rules", .{ refused.name, why });
                }
                const row_guarded = rowGuarded(self.access, rel.chain, rel.columns);
                if (row_guarded) self.any_guarded = true;
                try self.chains.append(self.arena, rel.chain);
                const label = try std.fmt.allocPrint(self.arena, "{s}", .{rel.name});
                if (strField(node.obj, "Alias")) |alias| try self.putAlias(alias, .{ .base = .{ .chain = rel.chain, .label = label, .guarded = row_guarded } });
                if (is_modify) {
                    const op = strField(node.obj, "Operation") orelse "";
                    const action: engine.WriteAction = if (std.mem.eql(u8, op, "Insert")) .insert else if (std.mem.eql(u8, op, "Update")) .update else if (std.mem.eql(u8, op, "Delete")) .delete else .other;
                    try self.targets.append(self.arena, .{ .action = action, .schema = schema, .name = name, .chain = rel.chain });
                }
            } else if (std.mem.eql(u8, t, "Foreign Scan") or is_modify) {
                return self.refuse(error.ActionDenied, "the plan has a {s} step without a table name, so the statement is refused", .{t});
            }
            if (derived_types.has(t)) {
                if (strField(node.obj, "Alias")) |alias| {
                    const carries_data = derivedCarriesData(t);
                    try self.putAlias(alias, .{ .derived = .{ .tainted = false, .producer = if (carries_data) self.producerOf(index) else null, .fixed = !carries_data } });
                }
            }
        }
        try self.partitionParents();
        if (self.aliases.count() == 1) {
            var it = self.aliases.keyIterator();
            self.single = it.next().?.*;
        }
    }

    fn producerOf(self: *Analyzer, index: usize) ?usize {
        const node = self.nodes.items[index];
        if (std.mem.eql(u8, node.node_type, "Subquery Scan")) {
            for (self.nodes.items, 0..) |child, i| {
                if (child.parent == index and std.mem.eql(u8, child.relationship, "Subquery")) return i;
            }
            return null;
        }
        if (std.mem.eql(u8, node.node_type, "CTE Scan") or std.mem.eql(u8, node.node_type, "WorkTable Scan")) {
            const name = strField(node.obj, "CTE Name") orelse return null;
            for (self.nodes.items, 0..) |other, i| {
                const sub = strField(other.obj, "Subplan Name") orelse continue;
                if (std.mem.startsWith(u8, sub, "CTE ") and std.mem.eql(u8, sub[4..], name)) return i;
            }
            return null;
        }
        return index;
    }

    fn partitionParents(self: *Analyzer) !void {
        for (self.nodes.items, 0..) |node, index| {
            if (!std.mem.eql(u8, node.node_type, "Append") and !std.mem.eql(u8, node.node_type, "Merge Append")) continue;
            var prefix: ?[]const u8 = null;
            var common: ?std.ArrayList([]const u8) = null;
            var members: usize = 0;
            var ok = true;
            var any_member_guarded = false;
            for (self.nodes.items) |child| {
                if (child.parent != index) continue;
                if (!std.mem.eql(u8, child.relationship, "Member")) continue;
                members += 1;
                if (!scan_types.has(child.node_type)) {
                    ok = false;
                    break;
                }
                const alias = strField(child.obj, "Alias") orelse {
                    ok = false;
                    break;
                };
                const under = std.mem.lastIndexOfScalar(u8, alias, '_') orelse {
                    ok = false;
                    break;
                };
                const digits = alias[under + 1 ..];
                if (digits.len == 0 or std.mem.indexOfNone(u8, digits, "0123456789") != null) {
                    ok = false;
                    break;
                }
                const head = alias[0..under];
                if (prefix) |p| {
                    if (!std.mem.eql(u8, p, head)) {
                        ok = false;
                        break;
                    }
                } else prefix = head;
                const entry = self.aliases.get(alias) orelse {
                    ok = false;
                    break;
                };
                if (entry != .base) {
                    ok = false;
                    break;
                }
                if (entry.base.guarded) any_member_guarded = true;
                if (common) |*list| {
                    var kept: std.ArrayList([]const u8) = .empty;
                    for (list.items) |name| {
                        for (entry.base.chain) |other| {
                            if (std.mem.eql(u8, name, other)) {
                                try kept.append(self.arena, name);
                                break;
                            }
                        }
                    }
                    list.* = kept;
                } else {
                    var list: std.ArrayList([]const u8) = .empty;
                    try list.appendSlice(self.arena, entry.base.chain);
                    common = list;
                }
            }
            if (!ok or members == 0) continue;
            const chain = (common orelse continue).items;
            if (chain.len == 0) continue;
            const parent_alias = prefix orelse continue;
            try self.putAlias(parent_alias, .{ .base = .{ .chain = chain, .label = chain[0], .guarded = any_member_guarded } });
            try self.partition_appends.put(self.arena, index, {});
        }
    }

    fn classify(self: *Analyzer, chain: Chain) !struct { class: Class, label: []const u8 } {
        const last = chain.parts[chain.len - 1];
        if (chain.star) {
            const alias = try nameText(self.arena, last);
            const entry = self.aliases.get(alias) orelse return .{ .class = if (self.any_guarded or self.any_tainted) .unknown else .plain, .label = alias };
            return switch (entry) {
                .base => |b| .{ .class = if (b.guarded) .tainted else .plain, .label = b.label },
                .derived => |d| .{ .class = if (d.tainted) .tainted else .plain, .label = alias },
            };
        }
        const column = try nameText(self.arena, last);
        const alias: ?[]const u8 = if (chain.len >= 2) try nameText(self.arena, chain.parts[chain.len - 2]) else self.single;
        const label_column = column;
        if (alias == null) {
            for (self.chains.items) |rel_chain| {
                switch (chainTreatment(self.access, rel_chain, column)) {
                    .plain => {},
                    else => return .{ .class = .unknown, .label = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ rel_chain[0], column }) },
                }
            }
            return .{ .class = .plain, .label = column };
        }
        const entry = self.aliases.get(alias.?) orelse return .{ .class = if (self.any_guarded or self.any_tainted) .unknown else .plain, .label = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ alias.?, label_column }) };
        switch (entry) {
            .base => |b| {
                const label = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ b.label, column });
                return switch (chainTreatment(self.access, b.chain, column)) {
                    .plain => .{ .class = .plain, .label = label },
                    .hidden => .{ .class = .hidden, .label = label },
                    .masked => .{ .class = .masked, .label = label },
                };
            },
            .derived => |d| return .{ .class = if (d.tainted) .tainted else .plain, .label = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ alias.?, column }) },
        }
    }

    fn topOutput(self: *Analyzer, index: usize) ?[]const Value {
        var at = index;
        var guard: usize = 0;
        while (guard < self.nodes.items.len) : (guard += 1) {
            const node = self.nodes.items[at];
            if (node.obj.get("Output")) |out| {
                if (out == .array) return out.array.items;
                return null;
            }
            var next: ?usize = null;
            for (self.nodes.items, 0..) |child, i| {
                if (child.parent != at) continue;
                if (std.mem.eql(u8, child.relationship, "InitPlan") or std.mem.eql(u8, child.relationship, "SubPlan")) continue;
                next = i;
                break;
            }
            at = next orelse return null;
        }
        return null;
    }

    fn carries(self: *Analyzer, index: usize) !bool {
        const items = self.topOutput(index) orelse return self.any_guarded or self.any_tainted;
        self.carry_hit = false;
        for (items) |item| {
            if (item != .string) return true;
            const tokens = pg_sql.tokenize(self.arena, item.string) catch return true;
            try scanTokens(tokens, .{ .ctx = self, .ref = carryRef, .call = ignoreCall, .op = ignoreOp }, false);
            if (self.carry_hit) return true;
        }
        return false;
    }

    fn carryRef(ctx: *anyopaque, chain: Chain, bare: bool) anyerror!void {
        _ = bare;
        const self: *Analyzer = @ptrCast(@alignCast(ctx));
        const got = try self.classify(chain);
        if (got.class != .plain) self.carry_hit = true;
    }

    fn ignoreCall(ctx: *anyopaque, chain: Chain) anyerror!void {
        _ = ctx;
        _ = chain;
    }

    fn ignoreOp(ctx: *anyopaque, text: []const u8, schema: ?Token) anyerror!void {
        _ = ctx;
        _ = text;
        _ = schema;
    }

    fn taint(self: *Analyzer) !void {
        var changed = true;
        var rounds: usize = 0;
        while (changed and rounds <= self.nodes.items.len + 1) : (rounds += 1) {
            changed = false;
            var it = self.aliases.iterator();
            while (it.next()) |kv| {
                switch (kv.value_ptr.*) {
                    .base => {},
                    .derived => |*d| {
                        if (d.tainted or d.fixed) continue;
                        const producer = d.producer orelse {
                            if (self.any_guarded) {
                                d.tainted = true;
                                self.any_tainted = true;
                                changed = true;
                            }
                            continue;
                        };
                        if (try self.carries(producer)) {
                            d.tainted = true;
                            self.any_tainted = true;
                            changed = true;
                        }
                    },
                }
            }
        }
    }

    fn derivedCarriesData(node_type: []const u8) bool {
        return std.mem.eql(u8, node_type, "Subquery Scan") or std.mem.eql(u8, node_type, "CTE Scan") or std.mem.eql(u8, node_type, "WorkTable Scan");
    }

    fn exprRef(ctx: *anyopaque, chain: Chain, bare: bool) anyerror!void {
        const self: *Analyzer = @ptrCast(@alignCast(ctx));
        const got = try self.classify(chain);
        if (got.class == .plain) return;
        if (self.mode == .write) {
            return self.refuse(error.GuardedColumnInWrite, "{s} is hidden or masked (or holds a whole row of a table that has such columns): a write may not read it", .{got.label});
        }
        if (chain.star) return self.refuse(error.MaskedColumnUsed, "{s}.* is a whole row of a table with hidden or masked columns; select its columns by name instead", .{got.label});
        if (bare) return;
        return switch (got.class) {
            .hidden => self.refuse(error.MaskedColumnUsed, "{s} is hidden, so it may not be used in WHERE, JOIN, GROUP BY, ORDER BY or any expression or function; selected directly it reads as NULL", .{got.label}),
            .masked => self.refuse(error.MaskedColumnUsed, "{s} is masked, so it may appear only as a plain result column: not in WHERE, JOIN, GROUP BY, ORDER BY or any expression or function", .{got.label}),
            else => self.refuse(error.MaskedColumnUsed, "{s} may carry a hidden or masked column through a subquery, view or CTE, so it may not be used in an expression; select from the table directly", .{got.label}),
        };
    }

    fn exprCall(ctx: *anyopaque, chain: Chain) anyerror!void {
        const self: *Analyzer = @ptrCast(@alignCast(ctx));
        const last = chain.parts[chain.len - 1];
        const name = try nameText(self.arena, last);
        if (self.collect_functions) |list| {
            for (list.items) |known| {
                if (std.mem.eql(u8, known, name)) return;
            }
            try list.append(self.arena, name);
            return;
        }
        if (chain.len >= 2) {
            const schema = try nameText(self.arena, chain.parts[chain.len - 2]);
            if (!std.mem.eql(u8, schema, "pg_catalog")) return self.refuse(error.FunctionDenied, "function {s}.{s} is defined in the database, not built in; only built-in functions on the allowed list run here", .{ schema, name });
        }
        const allowed = allowed_functions.has(name) or (self.mode == .write and write_functions.has(name));
        if (!allowed) return self.refuse(error.FunctionDenied, "function {s} is not on the allowed function list", .{name});
        for (self.evidence.shadowed) |shadow| {
            if (std.mem.eql(u8, shadow, name)) return self.refuse(error.FunctionDenied, "a function named {s} is defined in this database outside pg_catalog, so a call by that name could run it; it is refused", .{name});
        }
    }

    fn exprOp(ctx: *anyopaque, text: []const u8, schema: ?Token) anyerror!void {
        const self: *Analyzer = @ptrCast(@alignCast(ctx));
        if (self.collect_functions != null) return;
        if (schema) |s| {
            const name = try nameText(self.arena, s);
            if (!std.mem.eql(u8, name, "pg_catalog")) return self.refuse(error.FunctionDenied, "operator {s}.{s} is defined in the database, not built in", .{ name, text });
        }
        for (self.evidence.operators) |op| {
            if (std.mem.eql(u8, op, text)) return self.refuse(error.FunctionDenied, "operator {s} is defined in this database outside pg_catalog, so it could run code that is not checked", .{text});
        }
    }

    fn scanValue(self: *Analyzer, value: Value, sink: Sink) anyerror!void {
        switch (value) {
            .string => |text| {
                const tokens = pg_sql.tokenize(self.arena, text) catch return self.refuse(error.SqlFailed, "the query plan holds an expression emetgate cannot read", .{});
                try scanTokens(tokens, sink, false);
            },
            .array => |list| for (list.items) |item| try self.scanValue(item, sink),
            .object => |obj| {
                var it = obj.iterator();
                while (it.next()) |kv| try self.scanValue(kv.value_ptr.*, sink);
            },
            else => {},
        }
    }

    fn expressions(self: *Analyzer) !void {
        const sink: Sink = .{ .ctx = self, .ref = exprRef, .call = exprCall, .op = exprOp };
        for (self.nodes.items) |node| {
            var it = node.obj.iterator();
            while (it.next()) |kv| {
                const key = kv.key_ptr.*;
                if (std.mem.eql(u8, key, "Output")) {
                    const out = kv.value_ptr.*;
                    if (out != .array) continue;
                    for (out.array.items) |item| {
                        if (item != .string) continue;
                        const tokens = pg_sql.tokenize(self.arena, item.string) catch return self.refuse(error.SqlFailed, "the query plan holds an expression emetgate cannot read", .{});
                        try scanTokens(tokens, sink, true);
                    }
                    continue;
                }
                if (metadata_keys.has(key)) continue;
                try self.scanValue(kv.value_ptr.*, sink);
            }
        }
    }

    fn subplansAndSetops(self: *Analyzer) !void {
        for (self.nodes.items, 0..) |node, index| {
            const sub = std.mem.eql(u8, node.relationship, "InitPlan") or std.mem.eql(u8, node.relationship, "SubPlan");
            if (sub) {
                const name = strField(node.obj, "Subplan Name") orelse "";
                if (!std.mem.startsWith(u8, name, "CTE ") and try self.carries(index)) {
                    return self.refuse(error.MaskedColumnUsed, "a scalar subquery, EXISTS, IN or ARRAY(...) returns a hidden or masked column, which loses track of where it came from; select the column directly", .{});
                }
            }
            const t = node.node_type;
            const setop = std.mem.eql(u8, t, "Append") or std.mem.eql(u8, t, "Merge Append") or std.mem.eql(u8, t, "SetOp") or std.mem.eql(u8, t, "Recursive Union");
            if (!setop or self.partition_appends.contains(index)) continue;
            for (self.nodes.items, 0..) |child, i| {
                if (child.parent != index) continue;
                if (std.mem.eql(u8, child.relationship, "InitPlan") or std.mem.eql(u8, child.relationship, "SubPlan")) continue;
                if (try self.carries(i)) return self.refuse(error.MaskedColumnUsed, "UNION, INTERSECT, EXCEPT or a recursive CTE carries a hidden or masked column, which loses track of where it came from; select the column directly", .{});
            }
        }
    }

    fn alignRoot(self: *Analyzer, treatments: []engine.Treatment, nulled: *std.ArrayList([]const u8)) !void {
        const fields = self.evidence.fields;
        for (fields, treatments) |field, *slot| {
            slot.* = if (field.origin) |o| treatmentOf(self.access, o) else .plain;
        }
        const items = self.topOutput(0) orelse {
            if (self.any_guarded or self.any_tainted) return self.refuse(error.MaskedColumnUsed, "the result columns cannot be traced to their tables, and the query touches hidden or masked columns", .{});
            return;
        };
        for (fields, 0..) |field, i| {
            if (i >= items.len) {
                if (self.any_guarded or self.any_tainted) return self.refuse(error.MaskedColumnUsed, "the result columns cannot be traced to their tables, and the query touches hidden or masked columns", .{});
                break;
            }
            const item = items[i];
            if (item != .string) continue;
            const tokens = pg_sql.tokenize(self.arena, item.string) catch return self.refuse(error.SqlFailed, "the query plan holds an expression emetgate cannot read", .{});
            if (tokens.len == 0 or !tokens[0].isName() or isKeyword(tokens[0])) continue;
            const chain = readChain(tokens, 0);
            if (chain.call or chain.end != tokens.len) continue;
            const got = try self.classify(chain);
            if (got.class == .plain) continue;
            const origin = field.origin orelse return self.refuse(error.MaskedColumnUsed, "result column {s} carries {s}, but PostgreSQL does not say which table column it is (a view, UNION or expression is in the way); select it from its table directly", .{ field.name, got.label });
            const reported = treatmentOf(self.access, origin);
            const weaker = switch (got.class) {
                .hidden => reported != .hidden,
                .masked => reported == .plain,
                else => false,
            };
            if (weaker) return self.refuse(error.MaskedColumnUsed, "result column {s} carries {s} but comes back as {s}.{s} (through a view or rename), which has weaker rules; select it from its table directly", .{ field.name, got.label, origin.table, origin.column });
        }
        for (fields, treatments) |field, how| {
            if (how != .hidden) continue;
            const o = field.origin.?;
            const label = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ o.table, o.column });
            for (nulled.items) |known| {
                if (std.mem.eql(u8, known, label)) break;
            } else try nulled.append(self.arena, label);
        }
    }
};

fn parsePlan(arena: Allocator, plan_text: []const u8) !Value {
    const value = std.json.parseFromSliceLeaky(Value, arena, plan_text, .{}) catch return error.PlanUnreadable;
    if (value != .array or value.array.items.len != 1) return error.PlanUnreadable;
    const top = value.array.items[0];
    if (top != .object) return error.PlanUnreadable;
    const plan = top.object.get("Plan") orelse return error.PlanUnreadable;
    return plan;
}

pub fn needs(arena: Allocator, plan_text: []const u8) !Needs {
    const plan = try parsePlan(arena, plan_text);
    var analyzer: Analyzer = .{ .arena = arena, .access = .{}, .mode = .read, .evidence = .{ .plan = plan_text } };
    analyzer.flatten(&plan, null) catch return error.PlanUnreadable;
    var rels: std.ArrayList(pg_sql.Name) = .empty;
    var functions: std.ArrayList([]const u8) = .empty;
    analyzer.collect_functions = &functions;
    for (analyzer.nodes.items) |node| {
        if (strField(node.obj, "Relation Name")) |name| {
            const schema = strField(node.obj, "Schema") orelse "";
            for (rels.items) |known| {
                if (std.mem.eql(u8, known.name, name) and std.mem.eql(u8, known.schema.?, schema)) break;
            } else try rels.append(arena, .{ .schema = schema, .name = name });
        }
    }
    analyzer.expressions() catch |err| switch (err) {
        error.Refused => {},
        else => return err,
    };
    return .{ .relations = rels.items, .functions = functions.items };
}

pub fn decide(arena: Allocator, evidence: Evidence, access: Access, mode: engine.Mode) !Verdict {
    var analyzer: Analyzer = .{ .arena = arena, .access = access, .mode = mode, .evidence = evidence };
    const plan = parsePlan(arena, evidence.plan) catch return .{ .refused = .{ .err = error.SqlFailed, .message = "the query plan could not be read" } };
    const treatments = try arena.alloc(engine.Treatment, evidence.fields.len);
    @memset(treatments, .plain);
    var nulled: std.ArrayList([]const u8) = .empty;
    run(&analyzer, &plan, treatments, &nulled) catch |err| switch (err) {
        error.Refused => return .{ .refused = analyzer.refusal.? },
        else => return err,
    };
    return .{ .ok = .{ .treatments = treatments, .nulled = nulled.items, .targets = analyzer.targets.items, .relations = analyzer.chains.items } };
}

fn run(analyzer: *Analyzer, plan: *const Value, treatments: []engine.Treatment, nulled: *std.ArrayList([]const u8)) !void {
    try analyzer.flatten(plan, null);
    try analyzer.relations();
    try analyzer.taint();
    try analyzer.expressions();
    if (analyzer.mode == .read) {
        try analyzer.subplansAndSetops();
        try analyzer.alignRoot(treatments, nulled);
    }
}

pub fn ddlCheck(arena: Allocator, tokens: []const Token, access: Access, involved: []const []const u8, shadowed: []const []const u8) !?Refusal {
    for (tokens, 0..) |token, i| {
        if (!token.isName()) continue;
        const name = try pg_sql.unquote(arena, token);
        for (access.hidden) |col| {
            if (!access_mod.nameMatches(col.column, name)) continue;
            if (ruleTouches(col.table, involved)) return .{ .err = error.GuardedColumnInWrite, .message = try std.fmt.allocPrint(arena, "{s}.{s} is hidden: a write may not name it", .{ col.table, col.column }) };
        }
        for (access.masked) |mask| {
            if (!access_mod.nameMatches(mask.column, name)) continue;
            if (ruleTouches(mask.table, involved)) return .{ .err = error.GuardedColumnInWrite, .message = try std.fmt.allocPrint(arena, "{s}.{s} is masked: a write may not name it", .{ mask.table, mask.column }) };
        }
        if (i + 1 < tokens.len and tokens[i + 1].is(.punct, "(")) {
            const lower = try std.ascii.allocLowerString(arena, name);
            if (ddl_denied_functions.has(lower) or std.mem.startsWith(u8, lower, "dblink") or std.mem.startsWith(u8, lower, "pg_")) {
                return .{ .err = error.FunctionDenied, .message = try std.fmt.allocPrint(arena, "function {s} may not appear in a write", .{name}) };
            }
            for (shadowed) |shadow| {
                if (std.mem.eql(u8, shadow, name) or std.mem.eql(u8, shadow, lower)) return .{ .err = error.FunctionDenied, .message = try std.fmt.allocPrint(arena, "function {s} is defined in this database outside pg_catalog; a write may not call it", .{name}) };
            }
        }
    }
    return null;
}

fn ruleTouches(pattern: []const u8, involved: []const []const u8) bool {
    if (std.mem.eql(u8, pattern, access_mod.wildcard)) return true;
    for (involved) |name| {
        if (access_mod.nameMatches(pattern, name)) return true;
    }
    return false;
}

pub fn involvedNames(arena: Allocator, tokens: []const Token, extra: []const []const []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (tokens) |token| {
        if (token.isName()) try list.append(arena, try pg_sql.unquote(arena, token));
    }
    for (extra) |chain| try list.appendSlice(arena, chain);
    return list.items;
}

pub fn planLines(arena: Allocator, plan_text: []const u8) ![]const []const u8 {
    const plan = try parsePlan(arena, plan_text);
    var lines: std.ArrayList([]const u8) = .empty;
    try planLine(arena, &plan, 0, &lines);
    return lines.items;
}

fn planLine(arena: Allocator, value: *const Value, depth: usize, lines: *std.ArrayList([]const u8)) !void {
    if (value.* != .object) return;
    const obj = &value.object;
    var line: std.Io.Writer.Allocating = .init(arena);
    const w = &line.writer;
    try w.splatByteAll(' ', depth * 2);
    try w.writeAll(strField(obj, "Node Type") orelse "?");
    if (strField(obj, "Join Type")) |join| try w.print(" ({s})", .{join});
    if (strField(obj, "Relation Name")) |name| {
        try w.print(" on {s}.{s}", .{ strField(obj, "Schema") orelse "", name });
        if (strField(obj, "Alias")) |alias| {
            if (!std.mem.eql(u8, alias, name)) try w.print(" {s}", .{alias});
        }
    } else if (strField(obj, "Alias")) |alias| try w.print(" {s}", .{alias});
    if (strField(obj, "Index Name")) |index| try w.print(" using {s}", .{index});
    if (obj.get("Plan Rows")) |rows| {
        if (rows == .integer) try w.print(" rows={d}", .{rows.integer});
        if (rows == .float) try w.print(" rows={d}", .{@as(i64, @intFromFloat(rows.float))});
    }
    try lines.append(arena, line.written());
    for ([_][]const u8{ "Index Cond", "Hash Cond", "Merge Cond", "Join Filter", "Filter", "Recheck Cond" }) |key| {
        const cond = strField(obj, key) orelse continue;
        try lines.append(arena, try std.fmt.allocPrint(arena, "{s}  {s}: {s}", .{ indentOf(arena, depth) catch "", key, cond }));
    }
    if (obj.get("Plans")) |plans| {
        if (plans == .array) for (plans.array.items) |*child| try planLine(arena, child, depth + 1, lines);
    }
}

fn indentOf(arena: Allocator, depth: usize) ![]const u8 {
    const out = try arena.alloc(u8, depth * 2);
    @memset(out, ' ');
    return out;
}
