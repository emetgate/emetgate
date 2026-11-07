const std = @import("std");
const disk = @import("emetgate").disk;

const testing = std.testing;
const Allocator = std.mem.Allocator;
const windows = std.os.windows;

const kernel32 = struct {
    const FileTime = extern struct { low: u32, high: u32 };
    const Info = extern struct {
        attributes: u32,
        creation: FileTime,
        access: FileTime,
        write: FileTime,
        volume: u32,
        size_high: u32,
        size_low: u32,
        links: u32,
        index_high: u32,
        index_low: u32,
    };
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn GetFileInformationByHandle(file: windows.HANDLE, info: *Info) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn ReadFile(file: windows.HANDLE, buffer: [*]u8, len: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn WriteFile(file: windows.HANDLE, buffer: [*]const u8, len: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn SetFileTime(file: windows.HANDLE, creation: ?*const FileTime, access: ?*const FileTime, write: ?*const FileTime) callconv(.winapi) windows.BOOL;
};

const generic_read: u32 = 0x80000000;
const generic_write: u32 = 0x40000000;
const share_all: u32 = 0x7;
const open_existing: u32 = 3;
const create_new: u32 = 1;

pub const Snapshots = struct {
    roots: []const []const u8,
    store_abs: []u8,
    count: usize = 0,
    failure: ?anyerror = null,

    pub fn init(root_abs: []const u8) !Snapshots {
        return initAll(&.{root_abs});
    }

    pub fn initAll(roots: []const []const u8) !Snapshots {
        const parent = std.fs.path.dirname(roots[0]) orelse return error.NoParent;
        const store_abs = try std.fmt.allocPrint(testing.allocator, "{s}\\crash-snapshots", .{parent});
        errdefer testing.allocator.free(store_abs);
        try std.Io.Dir.cwd().createDirPath(testing.io, store_abs);
        return .{ .roots = try testing.allocator.dupe([]const u8, roots), .store_abs = store_abs };
    }

    pub fn deinit(self: *Snapshots) void {
        testing.allocator.free(self.roots);
        testing.allocator.free(self.store_abs);
    }

    pub fn step(self: *Snapshots) disk.Step {
        return .{ .context = self, .reached = reached };
    }

    pub fn taken(self: *const Snapshots) !usize {
        if (self.failure) |err| return err;
        return self.count;
    }

    fn reached(context: *anyopaque) bool {
        const self: *Snapshots = @ptrCast(@alignCast(context));
        self.count += 1;
        self.take(self.count) catch |err| {
            if (self.failure == null) self.failure = err;
        };
        return false;
    }

    fn take(self: *Snapshots, k: usize) !void {
        for (self.roots, 0..) |root, i| {
            const to = try self.slot(k, i, "taken");
            defer testing.allocator.free(to);
            try copyTree(root, to);
        }
    }

    pub fn restore(self: *Snapshots, k: usize) !void {
        for (self.roots, 0..) |root, i| {
            const from = try self.slot(k, i, "taken");
            defer testing.allocator.free(from);
            const aside = try self.slot(k, i, "replaced");
            defer testing.allocator.free(aside);
            try std.Io.Dir.renameAbsolute(root, aside, testing.io);
            try std.Io.Dir.renameAbsolute(from, root, testing.io);
        }
    }

    fn slot(self: *const Snapshots, k: usize, i: usize, what: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, "{s}\\{d}-{d}-{s}", .{ self.store_abs, k, i, what });
    }
};

fn copyTree(from_abs: []const u8, to_abs: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(testing.io, to_abs);
    var dir = try std.Io.Dir.openDirAbsolute(testing.io, from_abs, .{ .iterate = true });
    defer dir.close(testing.io);
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();
    while (try walker.next(testing.io)) |entry| {
        const target = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}", .{ to_abs, entry.path });
        defer testing.allocator.free(target);
        switch (entry.kind) {
            .directory => try std.Io.Dir.cwd().createDirPath(testing.io, target),
            .file => {
                const source = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}", .{ from_abs, entry.path });
                defer testing.allocator.free(source);
                try copyFile(testing.allocator, source, target);
            },
            else => return error.UnsupportedEntry,
        }
    }
}

fn copyFile(gpa: Allocator, source: []const u8, target: []const u8) !void {
    const wide_source = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, source);
    defer gpa.free(wide_source);
    const wide_target = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, target);
    defer gpa.free(wide_target);
    const from = kernel32.CreateFileW(wide_source, generic_read, share_all, null, open_existing, 0, null);
    if (from == windows.INVALID_HANDLE_VALUE) return switch (windows.GetLastError()) {
        .SHARING_VIOLATION => {},
        else => error.CopyOpenFailed,
    };
    defer windows.CloseHandle(from);
    var info: kernel32.Info = undefined;
    if (kernel32.GetFileInformationByHandle(from, &info) == .FALSE) return error.CopyInfoFailed;
    const to = kernel32.CreateFileW(wide_target, generic_write, 0, null, create_new, info.attributes, null);
    if (to == windows.INVALID_HANDLE_VALUE) return error.CopyCreateFailed;
    defer windows.CloseHandle(to);
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        var got: u32 = 0;
        if (kernel32.ReadFile(from, &buffer, buffer.len, &got, null) == .FALSE) return error.CopyReadFailed;
        if (got == 0) break;
        var done: u32 = 0;
        while (done < got) {
            var put: u32 = 0;
            if (kernel32.WriteFile(to, buffer[done..].ptr, got - done, &put, null) == .FALSE) return error.CopyWriteFailed;
            done += put;
        }
    }
    if (kernel32.SetFileTime(to, &info.creation, &info.access, &info.write) == .FALSE) return error.CopyTimeFailed;
}
