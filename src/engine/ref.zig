const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Accessor = enum { none, get, set };

pub const Ref = struct {
    container: []const []const u8 = &.{},
    name: []const u8,
    accessor: Accessor = .none,
    is_static: bool = false,

    pub const ParseError = error{InvalidRef} || Allocator.Error;

    pub fn parse(gpa: Allocator, text: []const u8) ParseError!Ref {
        const qualifier_start = std.mem.indexOfScalar(u8, text, '@') orelse text.len;
        var ref: Ref = .{ .name = undefined };
        if (qualifier_start < text.len) try ref.applyQualifiers(text[qualifier_start + 1 ..]);

        const path = text[0..qualifier_start];
        const container = try gpa.alloc([]const u8, std.mem.count(u8, path, "."));
        errdefer gpa.free(container);
        var segments = std.mem.splitScalar(u8, path, '.');
        for (container) |*segment| segment.* = try nonEmpty(segments.next().?);
        ref.name = try nonEmpty(segments.next().?);
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
        if (self.is_static) try writer.writeAll("@static");
        if (self.accessor != .none) try writer.print("@{t}", .{self.accessor});
    }

    pub fn eql(a: Ref, b: Ref) bool {
        if (a.accessor != b.accessor or a.is_static != b.is_static) return false;
        if (!std.mem.eql(u8, a.name, b.name) or a.container.len != b.container.len) return false;
        for (a.container, b.container) |x, y| {
            if (!std.mem.eql(u8, x, y)) return false;
        }
        return true;
    }
};

fn nonEmpty(segment: []const u8) error{InvalidRef}![]const u8 {
    return if (segment.len == 0) error.InvalidRef else segment;
}
