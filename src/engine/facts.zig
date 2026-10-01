const std = @import("std");
const symbol = @import("symbol.zig");

pub const Hash = symbol.Hash;
pub const Span = symbol.Span;

pub const none: u32 = std.math.maxInt(u32);

pub const DefKind = enum(u8) {
    module,
    function,
    generator,
    method,
    getter,
    setter,
    constructor,
    arrow,
    function_expression,
    class,
    variable,
    interface,
    type_alias,
    enumeration,
    field,
    enum_member,

    pub fn callable(self: DefKind) bool {
        return switch (self) {
            .function, .generator, .method, .getter, .setter, .constructor, .arrow, .function_expression, .class => true,
            else => false,
        };
    }

    pub fn isType(self: DefKind) bool {
        return switch (self) {
            .class, .interface, .type_alias, .enumeration => true,
            else => false,
        };
    }
};

pub const RefKind = enum(u8) {
    call,
    new,
    read,
    write,
    type,
    import,

    pub fn invokes(self: RefKind) bool {
        return self == .call or self == .new;
    }
};

pub const Reason = enum(u8) {
    property_needs_type,
    dynamic_access,
    dynamic_call,
    computed_import,
    local_value,
    global,
    dynamic_this,
    parse_error,
    external_module,
    module_not_found,
    unindexed_module,
    export_not_found,
    member_not_found,
    external_base,
    interface_member,
    reexport_cycle,

    pub fn outsideRepo(self: Reason) bool {
        return self == .global or self == .external_module;
    }
};

pub const Certainty = enum(u8) { proven, typed };

pub const Target = union(enum) {
    local: u32,
    binding: u32,
    member_of_def: u32,
    member_of_binding: u32,
    member_of_super: u32,
    member_of_type: u32,
    unresolved: Reason,
};

pub const Def = struct {
    kind: DefKind,
    name: []const u8,
    qname: []const u8,
    parent: u32,
    span: Span,
    name_start: u32,
    line: u32,
    hash: Hash,
    alpha: Hash,
    exported: bool = false,
    is_static: bool = false,
};

pub const Ref = struct {
    from: u32,
    kind: RefKind,
    name: []const u8,
    start: u32,
    line: u32,
    target: Target,
    static: bool = false,
};

pub const SpecKind = enum(u8) { static, dynamic };

pub const Spec = struct {
    text: []const u8,
    line: u32,
    kind: SpecKind,
};

pub const namespace_name = "*";
pub const default_name = "default";

pub const Binding = struct {
    spec: u32,
    imported: []const u8,
    local: []const u8,
    start: u32,
    type_only: bool,
};

pub const ExportKind = enum(u8) { local, binding, star };

pub const Export = struct {
    name: []const u8,
    kind: ExportKind,
    index: u32,
};

pub const TypeRef = struct {
    target: Target,
    member: []const u8 = "",
};

pub const Class = struct {
    def: u32,
    base: u32,
};

pub const MemberType = struct {
    class: u32,
    name: []const u8,
    is_static: bool,
    type: u32,
};

pub const Loose = struct {
    name: []const u8,
    count: u32,
};

pub const FileFacts = struct {
    defs: []const Def,
    refs: []const Ref,
    specs: []const Spec,
    bindings: []const Binding,
    exports: []const Export,
    types: []const TypeRef,
    classes: []const Class,
    member_types: []const MemberType,
    loose: []const Loose,
    dynamic_reads: u32,
    module_mode: bool,
    parse_errors: bool,
};

pub fn qualified(arena: std.mem.Allocator, owner: []const u8, member: []const u8, is_static: bool) ![]const u8 {
    if (owner.len == 0) return std.fmt.allocPrint(arena, "{s}{s}", .{ member, if (is_static) "@static" else "" });
    return std.fmt.allocPrint(arena, "{s}.{s}{s}", .{ owner, member, if (is_static) "@static" else "" });
}

const testing = std.testing;

test "facts: invoking kinds are call and new, outside-repo reasons are global and external modules" {
    try testing.expect(RefKind.call.invokes() and RefKind.new.invokes());
    try testing.expect(!RefKind.read.invokes() and !RefKind.type.invokes());
    try testing.expect(Reason.global.outsideRepo() and Reason.external_module.outsideRepo());
    try testing.expect(!Reason.property_needs_type.outsideRepo() and !Reason.module_not_found.outsideRepo());
    try testing.expect(DefKind.class.callable() and DefKind.class.isType() and !DefKind.variable.callable());
}

test "facts: a member is qualified by its owner and marked static only when static" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("A.b", try qualified(arena, "A", "b", false));
    try testing.expectEqualStrings("A.b@static", try qualified(arena, "A", "b", true));
    try testing.expectEqualStrings("b", try qualified(arena, "", "b", false));
}
