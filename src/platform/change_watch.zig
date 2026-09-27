const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const Allocator = std.mem.Allocator;

pub const cookie_dir = ".emetgate/cookies";
pub const default_buffer_bytes: u32 = 64 * 1024;
pub const min_buffer_bytes: u32 = 1024;

pub const StartError = error{ NotWatching, NameTooLong, InvalidWtf8, OutOfMemory };
pub const SyncError = error{ Overflow, Timeout, NotWatching, OutOfMemory };

pub const Options = struct {
    buffer_bytes: u32 = default_buffer_bytes,
};

pub const Dirty = struct {
    files: [][]u8,
    subtrees: [][]u8,

    pub fn deinit(self: Dirty, gpa: Allocator) void {
        for (self.files) |p| gpa.free(p);
        gpa.free(self.files);
        for (self.subtrees) |p| gpa.free(p);
        gpa.free(self.subtrees);
    }

    pub fn contains(self: Dirty, rel: []const u8) bool {
        for (self.files) |p| {
            if (samePath(p, rel)) return true;
        }
        for (self.subtrees) |p| {
            if (under(p, rel)) return true;
        }
        return false;
    }
};

pub fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (foldChar(x) != foldChar(y)) return false;
    }
    return true;
}

pub fn under(dir: []const u8, rel: []const u8) bool {
    if (rel.len < dir.len) return false;
    if (!samePath(dir, rel[0..dir.len])) return false;
    return rel.len == dir.len or rel[dir.len] == '/';
}

fn foldChar(c: u8) u8 {
    const slashed: u8 = if (c == '\\') '/' else c;
    return std.ascii.toLower(slashed);
}

pub const Kind = enum { ignore, file, subtree, unsafe };

pub fn classify(rel: []const u8) Kind {
    if (rel.len == 0) return .unsafe;
    if (rel[0] == '/' or rel[0] == '\\') return .unsafe;
    var parts = std.mem.tokenizeAny(u8, rel, "/\\");
    var first = true;
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return .unsafe;
        if (std.mem.indexOfScalar(u8, part, ':') != null) return .unsafe;
        if (first) {
            if (std.ascii.eqlIgnoreCase(part, ".git") or std.ascii.eqlIgnoreCase(part, ".emetgate")) return .ignore;
            first = false;
        }
    }
    if (looksShort(rel)) return .subtree;
    return .file;
}

fn looksShort(rel: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < rel.len) : (i += 1) {
        if (rel[i] == '~' and std.ascii.isDigit(rel[i + 1])) return true;
    }
    return false;
}

pub const Watcher = struct {
    gpa: Allocator,
    io: std.Io,
    root: []u8,
    handle: windows.HANDLE,
    event: windows.HANDLE,
    overlapped: win.OVERLAPPED,
    buffer: []align(4) u8,
    pending: bool = false,
    dead: bool = false,
    overflowed: bool = false,
    files: std.StringHashMapUnmanaged(void) = .empty,
    subtrees: std.StringHashMapUnmanaged(void) = .empty,
    cookie: ?[]u8 = null,
    cookie_seen: bool = false,
    stats: Stats = .{},

    pub const Stats = struct {
        records: u64 = 0,
        reads: u64 = 0,
    };

    pub fn start(gpa: Allocator, io: std.Io, root_abs: []const u8, options: Options) StartError!*Watcher {
        if (builtin.os.tag != .windows) return error.NotWatching;
        const buffer_bytes = @max(options.buffer_bytes, min_buffer_bytes) & ~@as(u32, 3);
        var wide: WidePath = undefined;
        const root_w = try toWide(&wide, root_abs);
        if (root_abs.len < 3 or !std.ascii.isAlphabetic(root_abs[0]) or root_abs[1] != ':') return error.NotWatching;
        const drive: [3:0]u16 = .{ root_abs[0], ':', '\\' };
        if (win.GetDriveTypeW(&drive) == win.drive_remote) return error.NotWatching;
        const attributes = win.GetFileAttributesW(root_w);
        if (attributes == win.invalid_file_attributes) return error.NotWatching;
        if (attributes & win.file_attribute_directory == 0 or attributes & win.file_attribute_reparse_point != 0) return error.NotWatching;

        const handle = win.CreateFileW(root_w, win.file_list_directory, win.file_share_all, null, win.open_existing, win.file_flag_backup_semantics | win.file_flag_overlapped, null);
        if (handle == windows.INVALID_HANDLE_VALUE) return error.NotWatching;
        errdefer windows.CloseHandle(handle);
        const event = win.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.NotWatching;
        errdefer windows.CloseHandle(event);

        const self = try gpa.create(Watcher);
        errdefer gpa.destroy(self);
        const buffer = try gpa.alignedAlloc(u8, .@"4", buffer_bytes);
        errdefer gpa.free(buffer);
        const root = try gpa.dupe(u8, root_abs);
        errdefer gpa.free(root);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .root = root,
            .handle = handle,
            .event = event,
            .overlapped = std.mem.zeroes(win.OVERLAPPED),
            .buffer = buffer,
        };
        self.issue();
        if (self.dead) return error.NotWatching;
        return self;
    }

    pub fn deinit(self: *Watcher) void {
        if (self.pending) {
            _ = win.CancelIoEx(self.handle, &self.overlapped);
            var bytes: windows.DWORD = 0;
            _ = win.GetOverlappedResult(self.handle, &self.overlapped, &bytes, .TRUE);
        }
        windows.CloseHandle(self.handle);
        windows.CloseHandle(self.event);
        self.clearSets();
        self.files.deinit(self.gpa);
        self.subtrees.deinit(self.gpa);
        if (self.cookie) |c| self.gpa.free(c);
        self.gpa.free(self.buffer);
        self.gpa.free(self.root);
        self.gpa.destroy(self);
    }

    fn issue(self: *Watcher) void {
        if (self.dead) return;
        self.overlapped = std.mem.zeroes(win.OVERLAPPED);
        self.overlapped.hEvent = self.event;
        _ = win.ResetEvent(self.event);
        if (win.ReadDirectoryChangesW(self.handle, self.buffer.ptr, @intCast(self.buffer.len), .TRUE, win.notify_filter, null, &self.overlapped, null) == .FALSE) {
            self.dead = true;
            self.pending = false;
            return;
        }
        self.pending = true;
        self.stats.reads += 1;
    }

    fn clearSets(self: *Watcher) void {
        var files = self.files.keyIterator();
        while (files.next()) |k| self.gpa.free(k.*);
        self.files.clearRetainingCapacity();
        var subtrees = self.subtrees.keyIterator();
        while (subtrees.next()) |k| self.gpa.free(k.*);
        self.subtrees.clearRetainingCapacity();
    }

    fn poll(self: *Watcher, wait_ms: windows.DWORD) error{OutOfMemory}!bool {
        if (!self.pending) return false;
        var bytes: windows.DWORD = 0;
        if (win.GetOverlappedResult(self.handle, &self.overlapped, &bytes, .FALSE) == .FALSE) {
            const code = win.GetLastError();
            if (code == win.error_io_incomplete) {
                if (wait_ms == 0) return false;
                const waited = win.WaitForSingleObject(self.event, wait_ms);
                if (waited != win.wait_object_0) return false;
                if (win.GetOverlappedResult(self.handle, &self.overlapped, &bytes, .FALSE) == .FALSE) {
                    const again = win.GetLastError();
                    if (again == win.error_io_incomplete) return false;
                    return self.failed(again);
                }
            } else return self.failed(code);
        }
        self.pending = false;
        if (bytes == 0) {
            self.overflowed = true;
        } else {
            try self.absorb(self.buffer[0..bytes]);
        }
        self.issue();
        return true;
    }

    fn failed(self: *Watcher, code: windows.DWORD) bool {
        self.pending = false;
        if (code == win.error_notify_enum_dir) {
            self.overflowed = true;
            self.issue();
        } else {
            self.dead = true;
        }
        return true;
    }

    fn absorb(self: *Watcher, bytes: []align(4) const u8) error{OutOfMemory}!void {
        var offset: usize = 0;
        while (true) {
            if (offset + win.notify_header > bytes.len) {
                self.overflowed = true;
                return;
            }
            const next = std.mem.readInt(u32, bytes[offset..][0..4], .little);
            const action = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .little);
            const name_bytes = std.mem.readInt(u32, bytes[offset + 8 ..][0..4], .little);
            const name_start = offset + win.notify_header;
            if (name_bytes % 2 != 0 or name_start + name_bytes > bytes.len) {
                self.overflowed = true;
                return;
            }
            const units = std.mem.bytesAsSlice(u16, @as([]align(2) const u8, @alignCast(bytes[name_start .. name_start + name_bytes])));
            try self.record(action, units);
            self.stats.records += 1;
            if (next == 0) return;
            offset += next;
        }
    }

    fn record(self: *Watcher, action: u32, units: []const u16) error{OutOfMemory}!void {
        const rel = std.unicode.wtf16LeToWtf8Alloc(self.gpa, units) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer self.gpa.free(rel);
        std.mem.replaceScalar(u8, rel, '\\', '/');
        if (self.cookie) |cookie| {
            if (action == win.file_action_added and samePath(rel, cookie)) self.cookie_seen = true;
        }
        switch (classify(rel)) {
            .ignore => return,
            .unsafe => {
                self.overflowed = true;
                return;
            },
            .subtree => {
                const parent = std.fs.path.dirnamePosix(rel) orelse "";
                if (parent.len == 0) {
                    self.overflowed = true;
                    return;
                }
                try addKey(self.gpa, &self.subtrees, parent);
                return;
            },
            .file => {},
        }
        if (action == win.file_action_renamed_old_name) {
            try addKey(self.gpa, &self.subtrees, rel);
            return;
        }
        try addKey(self.gpa, &self.files, rel);
        switch (action) {
            win.file_action_removed => try addKey(self.gpa, &self.subtrees, rel),
            win.file_action_added, win.file_action_renamed_new_name => {
                if (self.isDirectoryOrGone(rel)) try addKey(self.gpa, &self.subtrees, rel);
            },
            else => {},
        }
    }

    fn isDirectoryOrGone(self: *Watcher, rel: []const u8) bool {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const joined = std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ self.root, rel }) catch return true;
        var wide: WidePath = undefined;
        const w = toWide(&wide, joined) catch return true;
        const attributes = win.GetFileAttributesW(w);
        if (attributes == win.invalid_file_attributes) return true;
        return attributes & win.file_attribute_directory != 0;
    }

    pub fn sync(self: *Watcher, timeout_ms: u32) SyncError!Dirty {
        if (self.dead) return error.NotWatching;
        const deadline = win.GetTickCount64() + timeout_ms;
        try self.createCookie();
        defer self.dropCookie();

        while (!self.cookie_seen) {
            if (self.dead) return self.fail(error.NotWatching);
            if (self.overflowed) return self.fail(error.Overflow);
            const now = win.GetTickCount64();
            if (now >= deadline) return self.fail(error.Timeout);
            _ = try self.poll(@intCast(@min(deadline - now, std.math.maxInt(u32) - 1)));
        }
        while (try self.poll(0)) {}
        if (self.dead) return self.fail(error.NotWatching);
        if (self.overflowed) return self.fail(error.Overflow);
        return self.take();
    }

    fn fail(self: *Watcher, err: SyncError) SyncError {
        self.clearSets();
        self.overflowed = false;
        return err;
    }

    fn take(self: *Watcher) error{OutOfMemory}!Dirty {
        const files = try keys(self.gpa, &self.files);
        errdefer {
            for (files) |p| self.gpa.free(p);
            self.gpa.free(files);
        }
        const subtrees = try keys(self.gpa, &self.subtrees);
        self.clearSets();
        return .{ .files = files, .subtrees = subtrees };
    }

    fn createCookie(self: *Watcher) SyncError!void {
        if (self.cookie) |c| self.gpa.free(c);
        self.cookie = null;
        self.cookie_seen = false;
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_abs = std.fmt.bufPrint(&dir_buf, "{s}\\.emetgate\\cookies", .{self.root}) catch return error.NotWatching;
        try self.ensureCookieDir(dir_abs);

        var random: [16]u8 = undefined;
        self.io.random(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        const rel = std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ cookie_dir, hex }) catch return error.OutOfMemory;
        errdefer self.gpa.free(rel);
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs = std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ dir_abs, hex }) catch return error.NotWatching;
        var wide: WidePath = undefined;
        const w = toWide(&wide, abs) catch return error.NotWatching;
        const handle = win.CreateFileW(w, win.generic_write, 0, null, win.create_new, win.file_attribute_normal, null);
        if (handle == windows.INVALID_HANDLE_VALUE) return error.NotWatching;
        windows.CloseHandle(handle);
        self.cookie = rel;
    }

    fn ensureCookieDir(self: *Watcher, dir_abs: []const u8) SyncError!void {
        var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
        const parent = std.fmt.bufPrint(&parent_buf, "{s}\\.emetgate", .{self.root}) catch return error.NotWatching;
        for ([_][]const u8{ parent, dir_abs }) |path| {
            var wide: WidePath = undefined;
            const w = toWide(&wide, path) catch return error.NotWatching;
            var attributes = win.GetFileAttributesW(w);
            if (attributes == win.invalid_file_attributes) {
                if (win.CreateDirectoryW(w, null) == .FALSE and win.GetLastError() != win.error_already_exists) return error.NotWatching;
                attributes = win.GetFileAttributesW(w);
            }
            if (attributes == win.invalid_file_attributes) return error.NotWatching;
            if (attributes & win.file_attribute_directory == 0) return error.NotWatching;
            if (attributes & win.file_attribute_reparse_point != 0) return error.NotWatching;
        }
    }

    fn dropCookie(self: *Watcher) void {
        const rel = self.cookie orelse return;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs = std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ self.root, rel }) catch return;
        std.mem.replaceScalar(u8, abs, '/', '\\');
        var wide: WidePath = undefined;
        const w = toWide(&wide, abs) catch return;
        _ = win.DeleteFileW(w);
    }
};

fn addKey(gpa: Allocator, set: *std.StringHashMapUnmanaged(void), rel: []const u8) error{OutOfMemory}!void {
    if (set.contains(rel)) return;
    const owned = try gpa.dupe(u8, rel);
    errdefer gpa.free(owned);
    try set.put(gpa, owned, {});
}

fn keys(gpa: Allocator, set: *std.StringHashMapUnmanaged(void)) error{OutOfMemory}![][]u8 {
    const out = try gpa.alloc([]u8, set.count());
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |p| gpa.free(p);
        gpa.free(out);
    }
    var it = set.keyIterator();
    while (it.next()) |k| : (copied += 1) out[copied] = try gpa.dupe(u8, k.*);
    std.mem.sort([]u8, out, {}, lessPath);
    return out;
}

fn lessPath(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

const WidePath = [std.fs.max_path_bytes:0]u16;

fn toWide(buffer: *WidePath, path: []const u8) error{ NameTooLong, InvalidWtf8 }![*:0]const u16 {
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\");
    const long = path.len >= 240 and path.len > 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/');
    const offset: usize = if (long) prefix.len else 0;
    if (long) @memcpy(buffer[0..prefix.len], prefix);
    const len = std.unicode.wtf8ToWtf16Le(buffer[offset..], path) catch return error.InvalidWtf8;
    if (offset + len >= buffer.len) return error.NameTooLong;
    if (long) {
        for (buffer[offset .. offset + len]) |*unit| {
            if (unit.* == '/') unit.* = '\\';
        }
    }
    buffer[offset + len] = 0;
    return buffer;
}

const win = struct {
    const OVERLAPPED = extern struct {
        Internal: usize,
        InternalHigh: usize,
        Offset: windows.DWORD,
        OffsetHigh: windows.DWORD,
        hEvent: ?windows.HANDLE,
    };

    const file_list_directory: windows.DWORD = 0x0001;
    const generic_write: windows.DWORD = 0x40000000;
    const file_share_all: windows.DWORD = 0x00000007;
    const open_existing: windows.DWORD = 3;
    const create_new: windows.DWORD = 1;
    const file_flag_backup_semantics: windows.DWORD = 0x02000000;
    const file_flag_overlapped: windows.DWORD = 0x40000000;
    const file_attribute_normal: windows.DWORD = 0x80;
    const file_attribute_directory: windows.DWORD = 0x10;
    const file_attribute_reparse_point: windows.DWORD = 0x400;
    const invalid_file_attributes: windows.DWORD = 0xFFFFFFFF;
    const drive_remote: c_uint = 4;
    const wait_object_0: windows.DWORD = 0;
    const error_io_incomplete: windows.DWORD = 996;
    const error_notify_enum_dir: windows.DWORD = 1022;
    const error_already_exists: windows.DWORD = 183;
    const notify_header: usize = 12;
    const notify_filter: windows.DWORD = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x40 | 0x100;
    const file_action_added: u32 = 1;
    const file_action_removed: u32 = 2;
    const file_action_modified: u32 = 3;
    const file_action_renamed_old_name: u32 = 4;
    const file_action_renamed_new_name: u32 = 5;

    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: windows.DWORD, share: windows.DWORD, security: ?*anyopaque, disposition: windows.DWORD, flags: windows.DWORD, template: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn ReadDirectoryChangesW(handle: windows.HANDLE, buffer: *anyopaque, length: windows.DWORD, subtree: windows.BOOL, filter: windows.DWORD, returned: ?*windows.DWORD, overlapped: *OVERLAPPED, routine: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetOverlappedResult(handle: windows.HANDLE, overlapped: *OVERLAPPED, transferred: *windows.DWORD, wait: windows.BOOL) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CancelIoEx(handle: windows.HANDLE, overlapped: ?*OVERLAPPED) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CreateEventW(security: ?*anyopaque, manual: windows.BOOL, initial: windows.BOOL, name: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn ResetEvent(event: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, milliseconds: windows.DWORD) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
    extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn CreateDirectoryW(name: [*:0]const u16, security: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn DeleteFileW(name: [*:0]const u16) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetDriveTypeW(root: [*:0]const u16) callconv(.winapi) c_uint;
};

test "classify drops the repository's own directories and refuses names that leave the root" {
    try std.testing.expectEqual(Kind.ignore, classify(".git/index"));
    try std.testing.expectEqual(Kind.ignore, classify(".GIT/HEAD"));
    try std.testing.expectEqual(Kind.ignore, classify(".emetgate/cookies/abc"));
    try std.testing.expectEqual(Kind.file, classify("src/.git-keep"));
    try std.testing.expectEqual(Kind.file, classify("src/a.ts"));
    try std.testing.expectEqual(Kind.unsafe, classify("../outside.ts"));
    try std.testing.expectEqual(Kind.unsafe, classify("src/../../outside.ts"));
    try std.testing.expectEqual(Kind.unsafe, classify("C:/Windows/win.ini"));
    try std.testing.expectEqual(Kind.unsafe, classify("/etc/passwd"));
    try std.testing.expectEqual(Kind.unsafe, classify("src/a.ts:stream"));
    try std.testing.expectEqual(Kind.unsafe, classify(""));
    try std.testing.expectEqual(Kind.subtree, classify("PROGRA~1/x.ts"));
}

test "a dirty subtree covers every path below it and nothing beside it" {
    const dirty: Dirty = .{ .files = @constCast(&[_][]u8{@constCast("src/a.ts")}), .subtrees = @constCast(&[_][]u8{@constCast("lib")}) };
    try std.testing.expect(dirty.contains("src/a.ts"));
    try std.testing.expect(dirty.contains("SRC\\A.TS"));
    try std.testing.expect(dirty.contains("lib"));
    try std.testing.expect(dirty.contains("lib/deep/x.ts"));
    try std.testing.expect(!dirty.contains("library/x.ts"));
    try std.testing.expect(!dirty.contains("src/b.ts"));
}
