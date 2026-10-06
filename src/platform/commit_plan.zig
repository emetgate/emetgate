const std = @import("std");
const git_commit = @import("git_commit.zig");
const rules = @import("rules.zig");

const Allocator = std.mem.Allocator;

pub const Change = git_commit.Change;

pub const Request = struct {
    message: []const u8,
    oid: ?[]u8 = null,

    pub fn deinit(self: Request, gpa: Allocator) void {
        if (self.oid) |oid| gpa.free(oid);
    }
};

pub const Opened = union(enum) {
    ok: Session,
    violated: rules.Report,
    failed: rules.Failure,
};

pub const Session = struct {
    request: ?*Request = null,
    head: ?git_commit.Head = null,
    prepared: ?[]u8 = null,

    pub fn open(gpa: Allocator, io: std.Io, root: []const u8, request: ?*Request, rels: []const []const u8) !Opened {
        const plan = request orelse return .{ .ok = .{} };
        switch (try rules.messageGate(gpa, io, root, plan.message)) {
            .ok => {},
            .violated => |report| return .{ .violated = report },
            .failed => |failure| return .{ .failed = failure },
        }
        return .{ .ok = .{ .request = plan, .head = try git_commit.preflight(gpa, io, root, rels) } };
    }

    pub fn prepare(self: *Session, gpa: Allocator, io: std.Io, root: []const u8, changes: []const Change) !void {
        const plan = self.request orelse return;
        self.prepared = try git_commit.prepare(gpa, io, root, self.head.?, changes, plan.message);
    }

    pub fn publish(self: *Session, gpa: Allocator, io: std.Io, root: []const u8, changes: []const Change) !void {
        const plan = self.request orelse return;
        try git_commit.publish(gpa, io, root, self.head.?, self.prepared.?, changes);
        plan.oid = self.prepared;
        self.prepared = null;
    }

    pub fn deinit(self: Session, gpa: Allocator) void {
        if (self.prepared) |oid| gpa.free(oid);
        if (self.head) |head| head.deinit(gpa);
    }
};
