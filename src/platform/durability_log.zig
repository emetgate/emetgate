const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const windows = std.os.windows;

pub const Kind = enum { created, removed, renamed, made_dir, removed_dir };

pub const Op = struct {
    kind: Kind,
    path: []u8,
    from: ?[]u8 = null,
    saved: ?[]u8 = null,
    after_crash: bool = false,

    pub fn dir(self: Op) []const u8 {
        return std.fs.path.dirname(self.path) orelse self.path;
    }

    pub fn endsWith(self: Op, suffix: []const u8) bool {
        return std.ascii.endsWithIgnoreCase(self.path, suffix);
    }

    fn deinit(self: Op, gpa: Allocator) void {
        gpa.free(self.path);
        if (self.from) |f| gpa.free(f);
        if (self.saved) |s| gpa.free(s);
    }
};

pub const Log = struct {
    gpa: Allocator,
    io: std.Io,
    ops: std.ArrayList(Op) = .empty,
    flushes: usize = 0,
    crash_at_flush: ?usize = null,
    frozen: bool = false,

    pub fn init(gpa: Allocator, io: std.Io) Log {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *Log) void {
        for (self.ops.items) |op| op.deinit(self.gpa);
        self.ops.deinit(self.gpa);
    }

    pub fn unflushed(self: *const Log) []const Op {
        return self.ops.items;
    }

    fn add(self: *Log, op: Op) void {
        var owned = op;
        owned.after_crash = self.frozen;
        self.ops.append(self.gpa, owned) catch owned.deinit(self.gpa);
    }

    fn flushed(self: *Log, dir_abs: []const u8) bool {
        self.flushes += 1;
        if (self.crash_at_flush) |at| {
            if (self.flushes >= at) self.frozen = true;
        }
        if (self.frozen) return false;
        var k: usize = 0;
        while (k < self.ops.items.len) {
            if (sameDir(self.ops.items[k].dir(), dir_abs)) {
                self.ops.orderedRemove(k).deinit(self.gpa);
            } else k += 1;
        }
        return true;
    }

    pub fn powerLoss(self: *Log, lose: *const fn (op: Op) bool) void {
        var k = self.ops.items.len;
        while (k > 0) {
            k -= 1;
            const op = self.ops.items[k];
            if (op.after_crash or lose(op)) undo(self.io, op);
        }
        for (self.ops.items) |op| op.deinit(self.gpa);
        self.ops.clearRetainingCapacity();
        self.frozen = false;
        self.crash_at_flush = null;
    }
};

pub var active: ?*Log = null;

fn current() ?*Log {
    if (!builtin.is_test) return null;
    return active;
}

pub fn created(path: []const u8) void {
    const log = current() orelse return;
    const owned = log.gpa.dupe(u8, stripPrefix(path)) catch return;
    log.add(.{ .kind = .created, .path = owned });
}

pub fn beforeRemove(path: []const u8) ?[]u8 {
    const log = current() orelse return null;
    return std.Io.Dir.cwd().readFileAlloc(log.io, stripPrefix(path), log.gpa, .unlimited) catch null;
}

pub fn discard(saved: ?[]u8) void {
    const log = current() orelse return;
    if (saved) |bytes| log.gpa.free(bytes);
}

pub fn removed(path: []const u8, saved: ?[]u8) void {
    const log = current() orelse return;
    const bytes = saved orelse return;
    const owned = log.gpa.dupe(u8, stripPrefix(path)) catch {
        log.gpa.free(bytes);
        return;
    };
    log.add(.{ .kind = .removed, .path = owned, .saved = bytes });
}

pub const Removal = struct { path: ?[]u8 = null, saved: ?[]u8 = null };

pub fn beforeHandleRemove(handle: windows.HANDLE) Removal {
    const log = current() orelse return .{};
    const path = pathOf(log.gpa, handle) orelse return .{};
    return .{ .path = path, .saved = beforeRemove(path) };
}

pub fn handleRemoved(removal: Removal, ok: bool) void {
    const log = current() orelse return;
    const path = removal.path orelse return;
    if (!ok or removal.saved == null) {
        log.gpa.free(path);
        if (removal.saved) |s| log.gpa.free(s);
        return;
    }
    log.add(.{ .kind = .removed, .path = path, .saved = removal.saved });
}

pub const Pending = struct { from: []u8, saved_target: ?[]u8 };

pub fn beforeRename(handle: windows.HANDLE, target_abs: []const u8, replace_existing: bool) ?Pending {
    const log = current() orelse return null;
    const from = pathOf(log.gpa, handle) orelse return null;
    const saved: ?[]u8 = if (replace_existing) beforeRemove(target_abs) else null;
    return .{ .from = from, .saved_target = saved };
}

pub fn renamed(pending: ?Pending, target_abs: []const u8, ok: bool) void {
    const log = current() orelse return;
    const p = pending orelse return;
    if (!ok) {
        log.gpa.free(p.from);
        if (p.saved_target) |s| log.gpa.free(s);
        return;
    }
    const to = log.gpa.dupe(u8, stripPrefix(target_abs)) catch return;
    log.add(.{ .kind = .renamed, .path = to, .from = p.from, .saved = p.saved_target });
}

pub fn madeDir(path: []const u8) void {
    const log = current() orelse return;
    const owned = log.gpa.dupe(u8, stripPrefix(path)) catch return;
    log.add(.{ .kind = .made_dir, .path = owned });
}

pub fn removedDir(path: []const u8) void {
    const log = current() orelse return;
    const owned = log.gpa.dupe(u8, stripPrefix(path)) catch return;
    log.add(.{ .kind = .removed_dir, .path = owned });
}

pub fn flushing(dir_abs: []const u8) bool {
    const log = current() orelse return true;
    return log.flushed(stripPrefix(dir_abs));
}

fn undo(io: std.Io, op: Op) void {
    const cwd = std.Io.Dir.cwd();
    switch (op.kind) {
        .created => cwd.deleteFile(io, op.path) catch {},
        .removed => cwd.writeFile(io, .{ .sub_path = op.path, .data = op.saved.? }) catch {},
        .renamed => {
            std.Io.Dir.renameAbsolute(op.path, op.from.?, io) catch return;
            if (op.saved) |bytes| cwd.writeFile(io, .{ .sub_path = op.path, .data = bytes }) catch {};
        },
        .made_dir => cwd.deleteDir(io, op.path) catch {},
        .removed_dir => cwd.createDir(io, op.path, .default_dir) catch {},
    }
}

fn sameDir(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, a, "\\/"), std.mem.trimEnd(u8, stripPrefix(b), "\\/"));
}

fn stripPrefix(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "\\\\?\\")) return path[4..];
    return path;
}

extern "kernel32" fn GetFinalPathNameByHandleW(handle: windows.HANDLE, buffer: [*]u16, len: windows.DWORD, flags: windows.DWORD) callconv(.winapi) windows.DWORD;

fn pathOf(gpa: Allocator, handle: windows.HANDLE) ?[]u8 {
    var buf: [std.fs.max_path_bytes]u16 = undefined;
    const n = GetFinalPathNameByHandleW(handle, &buf, buf.len, 0);
    if (n == 0 or n >= buf.len) return null;
    const utf8 = std.unicode.wtf16LeToWtf8Alloc(gpa, buf[0..n]) catch return null;
    defer gpa.free(utf8);
    return gpa.dupe(u8, stripPrefix(utf8)) catch null;
}
