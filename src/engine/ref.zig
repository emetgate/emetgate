const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Accessor = enum { none, get, set, delete, add, remove };

pub const Ref = struct {
    container: []const []const u8 = &.{},
    name: []const u8,
    overload: []const u8 = "",
    accessor: Accessor = .none,
    is_static: bool = false,

    pub const ParseError = error{InvalidRef} || Allocator.Error;

    pub fn parse(gpa: Allocator, text: []const u8) ParseError!Ref {
        const shape = shapeOf(text);
        var ref: Ref = .{ .name = undefined };
        if (shape.qualifiers < text.len) try ref.applyQualifiers(text[shape.qualifiers + 1 ..]);

        const path = text[0..shape.overload];
        const container = try gpa.alloc([]const u8, countDots(path));
        errdefer gpa.free(container);
        var start: usize = 0;
        for (container) |*segment| {
            const dot = nextDot(path, start).?;
            segment.* = try nonEmpty(path[start..dot]);
            start = dot + 1;
        }
        ref.name = try nonEmpty(path[start..]);
        if (container.len == 0 and isBareQualifier(ref.name)) return error.InvalidRef;
        ref.overload = text[shape.overload..shape.qualifiers];
        ref.container = container;
        return ref;
    }

    pub fn deinit(self: Ref, gpa: Allocator) void {
        gpa.free(self.container);
    }

    fn applyQualifiers(self: *Ref, text: []const u8) error{InvalidRef}!void {
        var qualifiers = std.mem.splitScalar(u8, text, '@');
        while (qualifiers.next()) |qualifier| {
            if (std.mem.eql(u8, qualifier, "static")) {
                if (self.is_static) return error.InvalidRef;
                self.is_static = true;
                continue;
            }
            const accessor = std.meta.stringToEnum(Accessor, qualifier) orelse return error.InvalidRef;
            if (accessor == .none or self.accessor != .none) return error.InvalidRef;
            self.accessor = accessor;
        }
    }

    pub fn format(self: Ref, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.container) |segment| try writer.print("{s}.", .{segment});
        try writer.writeAll(self.name);
        try writer.writeAll(self.overload);
        if (self.is_static) try writer.writeAll("@static");
        if (self.accessor != .none) try writer.print("@{t}", .{self.accessor});
    }

    pub fn eql(a: Ref, b: Ref) bool {
        return std.mem.eql(u8, a.overload, b.overload) and a.sameMember(b);
    }

    pub fn sameMember(a: Ref, b: Ref) bool {
        return a.accessor == b.accessor and a.is_static == b.is_static and a.sameName(b);
    }

    pub fn sameName(a: Ref, b: Ref) bool {
        if (!std.mem.eql(u8, a.name, b.name) or a.container.len != b.container.len) return false;
        for (a.container, b.container) |x, y| {
            if (!std.mem.eql(u8, x, y)) return false;
        }
        return true;
    }

    pub fn abbreviates(short: Ref, full: Ref) bool {
        if (!std.mem.eql(u8, short.name, full.name)) return false;
        if (short.is_static and !full.is_static) return false;
        if (short.accessor != .none and short.accessor != full.accessor) return false;
        if (short.overload.len != 0 and !sameSpelling(short.overload, full.overload)) return false;
        if (short.container.len > full.container.len) return false;
        const tail = full.container[full.container.len - short.container.len ..];
        for (short.container, tail) |x, y| {
            if (!std.mem.eql(u8, x, y)) return false;
        }
        return true;
    }
};

pub fn simpleName(text: []const u8) []const u8 {
    const path = text[0..shapeOf(text).overload];
    var start: usize = 0;
    while (nextDot(path, start)) |dot| start = dot + 1;
    return path[start..];
}

fn isBareQualifier(name: []const u8) bool {
    if (name[0] != '@') return false;
    return std.mem.eql(u8, name[1..], "static") or std.meta.stringToEnum(Accessor, name[1..]) != null;
}

fn nonEmpty(segment: []const u8) error{InvalidRef}![]const u8 {
    return if (segment.len == 0) error.InvalidRef else segment;
}

const Shape = struct { overload: usize, qualifiers: usize };

fn shapeOf(text: []const u8) Shape {
    var depth: usize = 0;
    var segment_start: usize = 0;
    var overload: ?usize = null;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (i == segment_start and isOperatorName(text[i..])) return operatorShape(text, i);
        switch (text[i]) {
            '@' => if (depth == 0 and i != segment_start) return .{ .overload = overload orelse i, .qualifiers = i },
            '.' => if (depth == 0) {
                segment_start = i + 1;
                overload = null;
            },
            '(', '[' => {
                if (depth == 0 and overload == null) overload = i;
                depth += 1;
            },
            '<' => {
                if (depth == 0 and overload == null and !closesBeforeDot(text, i)) overload = i;
                depth += 1;
            },
            ')', ']', '>' => depth -|= 1,
            else => {},
        }
    }
    return .{ .overload = overload orelse text.len, .qualifiers = text.len };
}

fn operatorShape(text: []const u8, start: usize) Shape {
    var i = start;
    while (i < text.len and text[i] != '(' and text[i] != '@') i += 1;
    const overload = i;
    var depth: usize = 0;
    while (i < text.len) : (i += 1) switch (text[i]) {
        '(', '[', '<' => depth += 1,
        ')', ']', '>' => depth -|= 1,
        '@' => if (depth == 0) return .{ .overload = overload, .qualifiers = i },
        else => {},
    };
    return .{ .overload = overload, .qualifiers = text.len };
}

fn closesBeforeDot(text: []const u8, open: usize) bool {
    var depth: usize = 0;
    var i = open;
    while (i < text.len) : (i += 1) switch (text[i]) {
        '<', '(', '[' => depth += 1,
        '>', ')', ']' => {
            depth -|= 1;
            if (depth == 0) return i + 1 < text.len and text[i + 1] == '.';
        },
        else => {},
    };
    return false;
}

fn isOperatorName(text: []const u8) bool {
    const word = "operator";
    if (!std.mem.startsWith(u8, text, word) or text.len == word.len) return false;
    const next = text[word.len];
    return !std.ascii.isAlphanumeric(next) and next != '_' and next != '.' and next != '@' and next != '(';
}

fn nextDot(path: []const u8, from: usize) ?usize {
    if (isOperatorName(path[from..])) return null;
    var depth: usize = 0;
    var i = from;
    while (i < path.len) : (i += 1) switch (path[i]) {
        '(', '[', '<' => depth += 1,
        ')', ']', '>' => depth -|= 1,
        '.' => if (depth == 0) return i,
        else => {},
    };
    return null;
}

fn countDots(path: []const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (nextDot(path, start)) |dot| : (count += 1) start = dot + 1;
    return count;
}

fn sameSpelling(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and std.ascii.isWhitespace(a[i])) i += 1;
        while (j < b.len and std.ascii.isWhitespace(b[j])) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (a[i] != b[j]) return false;
        i += 1;
        j += 1;
    }
}

const testing = std.testing;

fn expectRoundTrip(text: []const u8) !void {
    const ref = try Ref.parse(testing.allocator, text);
    defer ref.deinit(testing.allocator);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try ref.format(&writer);
    try testing.expectEqualStrings(text, writer.buffered());
}

test "a ref carries its overload, generic segments, operators and verbatim names through parse and format" {
    for ([_][]const u8{
        "f",
        "A.b.c@static@get",
        "A.f(int,string)",
        "N.C.F<T>(T)@static",
        "C.G<T>()",
        "C.F(System.Int32,Dictionary<string,int>)",
        "C.IList<int>.Add(int)",
        "Box.this(int)@get",
        "Box.operator+(Box,Box)@static",
        "Box.operator>>(Box,int)@static",
        "Box.operator<(Box,Box)@static",
        "Box.operator int",
        "Box.operator N.Other(Box)@static",
        "Box.~Box",
        "C.@class",
        "@class.@event@static",
        "P.size@delete",
        "E.Changed@add",
        "operator.call",
    }) |text| try expectRoundTrip(text);
}

test "a ref splits its overload from its name and keeps generic containers whole" {
    const ref = try Ref.parse(testing.allocator, "N.IList<int,string>.F<T>(T, Map<int,int>)@static@get");
    defer ref.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), ref.container.len);
    try testing.expectEqualStrings("IList<int,string>", ref.container[1]);
    try testing.expectEqualStrings("F", ref.name);
    try testing.expectEqualStrings("<T>(T, Map<int,int>)", ref.overload);
    try testing.expect(ref.is_static);
    try testing.expectEqual(Accessor.get, ref.accessor);
}

test "the simple name of a ref leaves out its container, overload and qualifiers" {
    try testing.expectEqualStrings("f", simpleName("f"));
    try testing.expectEqualStrings("c", simpleName("A.b.c@static@get"));
    try testing.expectEqualStrings("F", simpleName("N.C.F(System.Int32,N.Other)@static"));
    try testing.expectEqualStrings("operator+", simpleName("Box.operator+(Box,Box)@static"));
    try testing.expectEqualStrings("@class", simpleName("C.@class"));
}

test "a shorter ref abbreviates a longer one only where every part it states agrees" {
    const full = try Ref.parse(testing.allocator, "Shop.Cart.Add(int, string)@static");
    defer full.deinit(testing.allocator);
    for ([_][]const u8{ "Add", "Cart.Add", "Shop.Cart.Add", "Add@static", "Cart.Add(int,string)", "Add(int,string)@static" }) |text| {
        const short = try Ref.parse(testing.allocator, text);
        defer short.deinit(testing.allocator);
        try testing.expect(short.abbreviates(full));
    }
    for ([_][]const u8{ "Shop.Add", "Other.Cart.Add", "Add(int)", "Add@get", "Remove", "More.Shop.Cart.Add" }) |text| {
        const short = try Ref.parse(testing.allocator, text);
        defer short.deinit(testing.allocator);
        try testing.expect(!short.abbreviates(full));
    }
}
