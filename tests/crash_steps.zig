const std = @import("std");
const disk = @import("emetgate").disk;
const shadow = @import("emetgate").shadow;
const memory = @import("emetgate").memory;

const testing = std.testing;
const Dir = std.Io.Dir;

// These locks are opened with delete-on-close, so the process that dies holding one leaves
// no file behind; a snapshot that kept them would show a state no crash can produce.
const vanishing_locks = [_][]const u8{
    shadow.workspace_dir ++ "\\" ++ shadow.workspace_lock_name,
    shadow.workspace_dir ++ "\\" ++ memory.lock_name,
};

pub const StopAt = struct {
    target: usize,
    seen: usize = 0,

    pub fn step(self: *StopAt) disk.Step {
        return .{ .context = self, .reached = reached };
    }

    fn reached(context: *anyopaque) bool {
        const self: *StopAt = @ptrCast(@alignCast(context));
        self.seen += 1;
        return self.seen == self.target;
    }
};

// A crash leaves only what is on disk, and the commit path touches the disk before every
// step it reports, so one uninterrupted run that copies the repository at each step yields
// the same states as one run cut at each step, without repeating the gate before the commit.
// The journal records absolute paths, so a state is checked by putting it back at the root
// it was taken from, never in a copy elsewhere.
pub const Snapshots = struct {
    root_abs: []const u8,
    store: testing.TmpDir,
    taken: usize = 0,
    failure: ?anyerror = null,

    pub fn init(root_abs: []const u8) Snapshots {
        return .{ .root_abs = root_abs, .store = testing.tmpDir(.{ .iterate = true }) };
    }

    pub fn deinit(self: *Snapshots) void {
        self.store.cleanup();
    }

    pub fn step(self: *Snapshots) disk.Step {
        return .{ .context = self, .reached = reached };
    }

    fn reached(context: *anyopaque) bool {
        const self: *Snapshots = @ptrCast(@alignCast(context));
        if (self.failure == null) self.save(self.taken + 1) catch |err| {
            self.failure = err;
        };
        self.taken += 1;
        return false;
    }

    fn save(self: *Snapshots, number: usize) !void {
        var name_buf: [24]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{d}", .{number});
        try self.store.dir.createDirPath(testing.io, name);
        var dest = try self.store.dir.openDir(testing.io, name, .{});
        defer dest.close(testing.io);
        var root = try Dir.openDirAbsolute(testing.io, self.root_abs, .{ .iterate = true });
        defer root.close(testing.io);
        try copyTree(root, dest);
    }

    pub fn restore(self: *Snapshots, number: usize) !void {
        if (number == 0 or number > self.taken) return error.NoSuchSnapshot;
        var name_buf: [24]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{d}", .{number});
        var saved = try self.store.dir.openDir(testing.io, name, .{ .iterate = true });
        defer saved.close(testing.io);
        var root = try Dir.openDirAbsolute(testing.io, self.root_abs, .{ .iterate = true });
        defer root.close(testing.io);
        try clear(root);
        try copyTree(saved, root);
    }
};

fn copyTree(source: Dir, dest: Dir) !void {
    var walker = try source.walk(testing.allocator);
    defer walker.deinit();
    while (try walker.next(testing.io)) |entry| switch (entry.kind) {
        .directory => try dest.createDirPath(testing.io, entry.path),
        .file => if (!isVanishingLock(entry.path)) entry.dir.copyFile(entry.basename, dest, entry.path, testing.io, .{ .make_path = true }) catch |err| {
            std.debug.print("snapshot: cannot copy {s}: {t}\n", .{ entry.path, err });
            return err;
        },
        else => return error.UnexpectedEntryKind,
    };
}

fn isVanishingLock(path: []const u8) bool {
    for (vanishing_locks) |lock| {
        if (std.ascii.eqlIgnoreCase(path, lock)) return true;
    }
    return false;
}

fn clear(root: Dir) !void {
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| testing.allocator.free(name);
        names.deinit(testing.allocator);
    }
    var it = root.iterate();
    while (try it.next(testing.io)) |entry| try names.append(testing.allocator, try testing.allocator.dupe(u8, entry.name));
    for (names.items) |name| try root.deleteTree(testing.io, name);
}
