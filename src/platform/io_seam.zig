const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const shadow = @import("shadow.zig");
const disk = @import("disk.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub const Kind = enum { file, directory, link, other };

pub const Stat = struct {
    kind: Kind,
    size: u64,
    mtime_ns: i96,
    id: u64,
};

pub const Entry = struct {
    name: []const u8,
    kind: Kind,
    size: u64,
    mtime_ns: i96,
};

pub const Follow = enum { follow, no_follow };

pub const CreateOptions = struct {
    durable: bool = false,
};

pub const ReadError = error{ FileNotFound, AccessDenied, Busy, IsDirectory, TooLarge, NameTooLong, BadPathName, InputOutput, OutOfMemory };
pub const StatError = error{ FileNotFound, AccessDenied, Busy, NameTooLong, BadPathName, InputOutput };
pub const ListError = error{ FileNotFound, NotDirectory, AccessDenied, NameTooLong, BadPathName, InputOutput };
pub const PathError = error{ FileNotFound, AccessDenied, NameTooLong, BadPathName, InputOutput, OutOfMemory };
pub const WriteError = error{ FileNotFound, AccessDenied, Busy, PathAlreadyExists, NoSpaceLeft, NameTooLong, BadPathName, InputOutput };
pub const TrackedError = error{ GitFailed, TooLarge, OutOfMemory };
pub const WatchError = error{ NotWatching, NameTooLong, BadPathName, OutOfMemory };
pub const SleepError = error{Canceled};

pub const Visitor = struct {
    context: *anyopaque,
    visit: *const fn (context: *anyopaque, entry: Entry) void,
};

pub const Fs = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        readFile: *const fn (context: *anyopaque, path: []const u8, gpa: Allocator, limit: usize) ReadError![]u8,
        stat: *const fn (context: *anyopaque, path: []const u8, follow: Follow) StatError!Stat,
        list: *const fn (context: *anyopaque, dir: []const u8, visitor: Visitor) ListError!void,
        realPath: *const fn (context: *anyopaque, path: []const u8, gpa: Allocator) PathError![:0]u8,
        tracked: *const fn (context: *anyopaque, root: []const u8, gpa: Allocator) TrackedError![][]u8,
        createFile: *const fn (context: *anyopaque, path: []const u8, bytes: []const u8, options: CreateOptions) WriteError!void,
        renameReplace: *const fn (context: *anyopaque, from: []const u8, to: []const u8) WriteError!void,
        deleteFile: *const fn (context: *anyopaque, path: []const u8) WriteError!void,
        makePath: *const fn (context: *anyopaque, path: []const u8) WriteError!void,
    };

    pub fn readFile(self: Fs, path: []const u8, gpa: Allocator, limit: usize) ReadError![]u8 {
        return self.vtable.readFile(self.context, path, gpa, limit);
    }

    pub fn stat(self: Fs, path: []const u8, follow: Follow) StatError!Stat {
        return self.vtable.stat(self.context, path, follow);
    }

    pub fn list(self: Fs, dir: []const u8, visitor: Visitor) ListError!void {
        return self.vtable.list(self.context, dir, visitor);
    }

    pub fn realPath(self: Fs, path: []const u8, gpa: Allocator) PathError![:0]u8 {
        return self.vtable.realPath(self.context, path, gpa);
    }

    pub fn tracked(self: Fs, root: []const u8, gpa: Allocator) TrackedError![][]u8 {
        return self.vtable.tracked(self.context, root, gpa);
    }

    pub fn createFile(self: Fs, path: []const u8, bytes: []const u8, options: CreateOptions) WriteError!void {
        return self.vtable.createFile(self.context, path, bytes, options);
    }

    pub fn renameReplace(self: Fs, from: []const u8, to: []const u8) WriteError!void {
        return self.vtable.renameReplace(self.context, from, to);
    }

    pub fn deleteFile(self: Fs, path: []const u8) WriteError!void {
        return self.vtable.deleteFile(self.context, path);
    }

    pub fn makePath(self: Fs, path: []const u8) WriteError!void {
        return self.vtable.makePath(self.context, path);
    }
};

pub fn freeTracked(gpa: Allocator, files: [][]u8) void {
    for (files) |file| gpa.free(file);
    gpa.free(files);
}

pub const Watch = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Handle = enum(u32) { _ };

    pub const Event = union(enum) {
        pending,
        records: usize,
        overflow,
        dead,
    };

    pub const VTable = struct {
        open: *const fn (context: *anyopaque, root: []const u8, buffer_bytes: u32) WatchError!Handle,
        poll: *const fn (context: *anyopaque, handle: Handle, wait_ms: u32, out: []align(4) u8) Event,
        close: *const fn (context: *anyopaque, handle: Handle) void,
    };

    pub fn open(self: Watch, root: []const u8, buffer_bytes: u32) WatchError!Handle {
        return self.vtable.open(self.context, root, buffer_bytes);
    }

    pub fn poll(self: Watch, handle: Handle, wait_ms: u32, out: []align(4) u8) Event {
        return self.vtable.poll(self.context, handle, wait_ms, out);
    }

    pub fn close(self: Watch, handle: Handle) void {
        self.vtable.close(self.context, handle);
    }
};

pub const Action = enum(u32) { added = 1, removed = 2, modified = 3, renamed_old = 4, renamed_new = 5, _ };

pub const Record = struct {
    action: Action,
    name: []const u16,
};

pub const record_header_bytes = 12;

pub const Records = struct {
    bytes: []align(4) const u8,
    offset: usize = 0,
    done: bool = false,

    pub fn next(self: *Records) error{Malformed}!?Record {
        if (self.done or self.bytes.len == 0) return null;
        const at = self.offset;
        if (at + record_header_bytes > self.bytes.len) return error.Malformed;
        const step = std.mem.readInt(u32, self.bytes[at..][0..4], .little);
        const action = std.mem.readInt(u32, self.bytes[at + 4 ..][0..4], .little);
        const name_bytes = std.mem.readInt(u32, self.bytes[at + 8 ..][0..4], .little);
        const start = at + record_header_bytes;
        if (name_bytes % 2 != 0 or start + name_bytes > self.bytes.len) return error.Malformed;
        if (step != 0 and (step % 4 != 0 or step < record_header_bytes + name_bytes)) return error.Malformed;
        const raw: []align(2) const u8 = @alignCast(self.bytes[start .. start + name_bytes]);
        if (step == 0) self.done = true else self.offset = at + step;
        return .{ .action = @enumFromInt(action), .name = std.mem.bytesAsSlice(u16, raw) };
    }
};

pub fn records(bytes: []align(4) const u8) Records {
    return .{ .bytes = bytes };
}

pub const Clock = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        monotonic: *const fn (context: *anyopaque) i96,
        realtime: *const fn (context: *anyopaque) i96,
        sleep: *const fn (context: *anyopaque, ns: u64) SleepError!void,
    };

    pub fn monotonic(self: Clock) i96 {
        return self.vtable.monotonic(self.context);
    }

    pub fn realtime(self: Clock) i96 {
        return self.vtable.realtime(self.context);
    }

    pub fn sleep(self: Clock, ns: u64) SleepError!void {
        return self.vtable.sleep(self.context, ns);
    }
};

pub const Entropy = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        fill: *const fn (context: *anyopaque, buffer: []u8) void,
    };

    pub fn fill(self: Entropy, buffer: []u8) void {
        self.vtable.fill(self.context, buffer);
    }
};

pub const Seam = struct {
    fs: Fs,
    watch: Watch,
    clock: Clock,
    entropy: Entropy,
};

pub fn readError(err: Dir.ReadFileAllocError) ReadError {
    return switch (err) {
        error.FileNotFound, error.NotDir => error.FileNotFound,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.FileBusy, error.DeviceBusy, error.AntivirusInterference, error.PipeBusy, error.WouldBlock => error.Busy,
        error.IsDir => error.IsDirectory,
        error.StreamTooLong, error.FileTooBig => error.TooLarge,
        error.NameTooLong => error.NameTooLong,
        error.BadPathName => error.BadPathName,
        error.OutOfMemory => error.OutOfMemory,
        else => error.InputOutput,
    };
}

pub fn statError(err: Dir.StatFileError) StatError {
    return switch (err) {
        error.FileNotFound, error.NotDir => error.FileNotFound,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.FileBusy, error.DeviceBusy, error.AntivirusInterference, error.PipeBusy, error.WouldBlock => error.Busy,
        error.NameTooLong => error.NameTooLong,
        error.BadPathName => error.BadPathName,
        else => error.InputOutput,
    };
}

pub fn pathError(err: Dir.RealPathFileAllocError) PathError {
    return switch (err) {
        error.FileNotFound, error.NotDir => error.FileNotFound,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.NameTooLong => error.NameTooLong,
        error.BadPathName => error.BadPathName,
        error.OutOfMemory => error.OutOfMemory,
        else => error.InputOutput,
    };
}

pub fn writeError(err: anyerror) WriteError {
    return switch (err) {
        error.FileNotFound, error.NotDir => error.FileNotFound,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => error.AccessDenied,
        error.FileBusy, error.DeviceBusy, error.AntivirusInterference, error.PipeBusy, error.WouldBlock => error.Busy,
        error.PathAlreadyExists => error.PathAlreadyExists,
        error.NoSpaceLeft, error.DiskQuota => error.NoSpaceLeft,
        error.NameTooLong => error.NameTooLong,
        error.BadPathName => error.BadPathName,
        else => error.InputOutput,
    };
}

pub fn trackedError(err: anyerror) TrackedError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.TooLarge,
        else => error.GitFailed,
    };
}

pub fn win32ListError(code: windows.DWORD) ListError {
    return switch (code) {
        win.error_file_not_found, win.error_path_not_found => error.FileNotFound,
        win.error_directory => error.NotDirectory,
        win.error_access_denied => error.AccessDenied,
        win.error_filename_exced_range => error.NameTooLong,
        win.error_invalid_name => error.BadPathName,
        else => error.InputOutput,
    };
}

pub fn win32WriteError(code: windows.DWORD) WriteError {
    return switch (code) {
        win.error_file_not_found, win.error_path_not_found => error.FileNotFound,
        win.error_access_denied => error.AccessDenied,
        win.error_sharing_violation, win.error_lock_violation => error.Busy,
        win.error_file_exists, win.error_already_exists => error.PathAlreadyExists,
        win.error_disk_full => error.NoSpaceLeft,
        win.error_filename_exced_range => error.NameTooLong,
        win.error_invalid_name => error.BadPathName,
        else => error.InputOutput,
    };
}

fn statKind(kind: std.Io.File.Kind) Kind {
    return switch (kind) {
        .file => .file,
        .directory => .directory,
        .sym_link => .link,
        else => .other,
    };
}

fn entryKind(attributes: u32, reparse_tag: u32) Kind {
    if (attributes & win.file_attribute_reparse_point != 0) {
        return if (reparse_tag & win.reparse_tag_name_surrogate != 0) .link else .other;
    }
    if (attributes & win.file_attribute_directory != 0) return .directory;
    return .file;
}

pub const max_watches = 8;
pub const min_watch_buffer_bytes: u32 = 64;

const WidePath = [std.fs.max_path_bytes:0]u16;

fn toWide(buffer: *WidePath, path: []const u8) error{ NameTooLong, BadPathName }![*:0]const u16 {
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\");
    const long = path.len >= 240 and path.len > 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/');
    const offset: usize = if (long) prefix.len else 0;
    if (long) @memcpy(buffer[0..prefix.len], prefix);
    const len = std.unicode.wtf8ToWtf16Le(buffer[offset..], path) catch return error.BadPathName;
    if (offset + len >= buffer.len) return error.NameTooLong;
    if (long) {
        for (buffer[offset .. offset + len]) |*unit| {
            if (unit.* == '/') unit.* = '\\';
        }
    }
    buffer[offset + len] = 0;
    return buffer;
}

const WatchSlot = struct {
    handle: windows.HANDLE,
    event: windows.HANDLE,
    overlapped: win.OVERLAPPED,
    buffer: []align(4) u8,
    pending: bool = false,
    dead: bool = false,

    fn issue(self: *WatchSlot) void {
        if (self.dead) return;
        self.overlapped = std.mem.zeroes(win.OVERLAPPED);
        self.overlapped.hEvent = self.event;
        if (win.ResetEvent(self.event) == .FALSE) {
            self.dead = true;
            return;
        }
        if (win.ReadDirectoryChangesW(self.handle, self.buffer.ptr, @intCast(self.buffer.len), .TRUE, win.notify_filter, null, &self.overlapped, null) == .FALSE) {
            self.dead = true;
            return;
        }
        self.pending = true;
    }

    fn failed(self: *WatchSlot, code: windows.DWORD) Watch.Event {
        self.pending = false;
        if (code != win.error_notify_enum_dir) {
            self.dead = true;
            return .dead;
        }
        self.issue();
        return .overflow;
    }

    fn poll(self: *WatchSlot, wait_ms: u32, out: []align(4) u8) Watch.Event {
        if (!self.pending) self.issue();
        if (self.dead) return .dead;
        var bytes: windows.DWORD = 0;
        if (win.GetOverlappedResult(self.handle, &self.overlapped, &bytes, .FALSE) == .FALSE) {
            const code = win.GetLastError();
            if (code != win.error_io_incomplete) return self.failed(code);
            if (wait_ms == 0) return .pending;
            if (win.WaitForSingleObject(self.event, wait_ms) != win.wait_object_0) return .pending;
            if (win.GetOverlappedResult(self.handle, &self.overlapped, &bytes, .FALSE) == .FALSE) {
                const again = win.GetLastError();
                if (again == win.error_io_incomplete) return .pending;
                return self.failed(again);
            }
        }
        self.pending = false;
        if (bytes == 0 or bytes > out.len) {
            self.issue();
            return .overflow;
        }
        @memcpy(out[0..bytes], self.buffer[0..bytes]);
        self.issue();
        return .{ .records = bytes };
    }

    fn close(self: *WatchSlot, gpa: Allocator) void {
        if (self.pending) {
            _ = win.CancelIoEx(self.handle, &self.overlapped);
            var bytes: windows.DWORD = 0;
            _ = win.GetOverlappedResult(self.handle, &self.overlapped, &bytes, .TRUE);
        }
        windows.CloseHandle(self.handle);
        windows.CloseHandle(self.event);
        gpa.free(self.buffer);
        gpa.destroy(self);
    }
};

pub const Real = struct {
    gpa: Allocator,
    io: std.Io,
    watches: [max_watches]?*WatchSlot = @splat(null),

    pub fn init(gpa: Allocator, io: std.Io) Real {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *Real) void {
        for (&self.watches) |*slot| {
            if (slot.*) |s| s.close(self.gpa);
            slot.* = null;
        }
    }

    pub fn seam(self: *Real) Seam {
        return .{
            .fs = .{ .context = self, .vtable = &fs_vtable },
            .watch = .{ .context = self, .vtable = &watch_vtable },
            .clock = .{ .context = self, .vtable = &clock_vtable },
            .entropy = .{ .context = self, .vtable = &entropy_vtable },
        };
    }

    const fs_vtable: Fs.VTable = .{
        .readFile = readFile,
        .stat = stat,
        .list = list,
        .realPath = realPath,
        .tracked = tracked,
        .createFile = createFile,
        .renameReplace = renameReplace,
        .deleteFile = deleteFile,
        .makePath = makePath,
    };

    const watch_vtable: Watch.VTable = .{ .open = watchOpen, .poll = watchPoll, .close = watchClose };

    const clock_vtable: Clock.VTable = .{ .monotonic = monotonic, .realtime = realtime, .sleep = sleep };

    const entropy_vtable: Entropy.VTable = .{ .fill = fill };

    fn of(context: *anyopaque) *Real {
        return @ptrCast(@alignCast(context));
    }

    fn readFile(context: *anyopaque, path: []const u8, gpa: Allocator, limit: usize) ReadError![]u8 {
        return Dir.cwd().readFileAlloc(of(context).io, path, gpa, .limited(limit)) catch |err| return readError(err);
    }

    fn stat(context: *anyopaque, path: []const u8, follow: Follow) StatError!Stat {
        const got = Dir.cwd().statFile(of(context).io, path, .{ .follow_symlinks = follow == .follow }) catch |err| return statError(err);
        return .{ .kind = statKind(got.kind), .size = got.size, .mtime_ns = got.mtime.nanoseconds, .id = @intCast(got.inode) };
    }

    fn list(context: *anyopaque, dir: []const u8, visitor: Visitor) ListError!void {
        _ = context;
        var pattern_buf: [std.fs.max_path_bytes]u8 = undefined;
        const pattern = std.fmt.bufPrint(&pattern_buf, "{s}\\*", .{dir}) catch return error.NameTooLong;
        var wide: WidePath = undefined;
        const w = try toWide(&wide, pattern);
        var data: win.FindData = undefined;
        const handle = win.FindFirstFileExW(w, win.find_ex_info_basic, &data, 0, null, win.find_first_ex_large_fetch);
        if (handle == windows.INVALID_HANDLE_VALUE) return win32ListError(win.GetLastError());
        defer _ = win.FindClose(handle);
        var name_buf: [1024]u8 = undefined;
        while (true) {
            const units = std.mem.indexOfScalar(u16, &data.name, 0) orelse data.name.len;
            const n = std.unicode.wtf16LeToWtf8(&name_buf, data.name[0..units]);
            const name = name_buf[0..n];
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                const hns: i64 = @bitCast((@as(u64, data.last_write.high) << 32) | data.last_write.low);
                visitor.visit(visitor.context, .{
                    .name = name,
                    .kind = entryKind(data.attributes, data.reserved0),
                    .size = (@as(u64, data.size_high) << 32) | data.size_low,
                    .mtime_ns = windows.fromSysTime(hns).nanoseconds,
                });
            }
            if (win.FindNextFileW(handle, &data) == .FALSE) {
                const code = win.GetLastError();
                if (code == win.error_no_more_files) return;
                return win32ListError(code);
            }
        }
    }

    fn realPath(context: *anyopaque, path: []const u8, gpa: Allocator) PathError![:0]u8 {
        return Dir.cwd().realPathFileAlloc(of(context).io, path, gpa) catch |err| return pathError(err);
    }

    fn tracked(context: *anyopaque, root: []const u8, gpa: Allocator) TrackedError![][]u8 {
        return shadow.trackedFiles(gpa, of(context).io, root) catch |err| return trackedError(err);
    }

    fn createFile(context: *anyopaque, path: []const u8, bytes: []const u8, options: CreateOptions) WriteError!void {
        const io = of(context).io;
        if (options.durable) return disk.writeDurably(io, path, bytes) catch |err| return writeError(err);
        const file = Dir.createFileAbsolute(io, path, .{ .exclusive = true }) catch |err| return writeError(err);
        defer file.close(io);
        file.writeStreamingAll(io, bytes) catch |err| return writeError(err);
    }

    fn renameReplace(context: *anyopaque, from: []const u8, to: []const u8) WriteError!void {
        _ = context;
        var from_wide: WidePath = undefined;
        var to_wide: WidePath = undefined;
        const from_w = try toWide(&from_wide, from);
        const to_w = try toWide(&to_wide, to);
        if (win.MoveFileExW(from_w, to_w, win.movefile_replace_existing | win.movefile_write_through) == .FALSE) return win32WriteError(win.GetLastError());
    }

    fn deleteFile(context: *anyopaque, path: []const u8) WriteError!void {
        return Dir.deleteFileAbsolute(of(context).io, path) catch |err| return writeError(err);
    }

    fn makePath(context: *anyopaque, path: []const u8) WriteError!void {
        return Dir.cwd().createDirPath(of(context).io, path) catch |err| return writeError(err);
    }

    fn watchOpen(context: *anyopaque, root: []const u8, buffer_bytes: u32) WatchError!Watch.Handle {
        const self = of(context);
        if (builtin.os.tag != .windows) return error.NotWatching;
        const index = for (self.watches, 0..) |slot, i| {
            if (slot == null) break i;
        } else return error.NotWatching;
        var wide: WidePath = undefined;
        const root_w = try toWide(&wide, root);
        if (root.len < 3 or !std.ascii.isAlphabetic(root[0]) or root[1] != ':') return error.NotWatching;
        const drive: [3:0]u16 = .{ root[0], ':', '\\' };
        if (win.GetDriveTypeW(&drive) == win.drive_remote) return error.NotWatching;
        const attributes = win.GetFileAttributesW(root_w);
        if (attributes == win.invalid_file_attributes) return error.NotWatching;
        if (attributes & win.file_attribute_directory == 0 or attributes & win.file_attribute_reparse_point != 0) return error.NotWatching;
        const handle = win.CreateFileW(root_w, win.file_list_directory, win.file_share_all, null, win.open_existing, win.file_flag_backup_semantics | win.file_flag_overlapped, null);
        if (handle == windows.INVALID_HANDLE_VALUE) return error.NotWatching;
        errdefer windows.CloseHandle(handle);
        const event = win.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.NotWatching;
        errdefer windows.CloseHandle(event);
        const slot = try self.gpa.create(WatchSlot);
        errdefer self.gpa.destroy(slot);
        const buffer = try self.gpa.alignedAlloc(u8, .@"4", @max(buffer_bytes, min_watch_buffer_bytes) & ~@as(u32, 3));
        errdefer self.gpa.free(buffer);
        slot.* = .{ .handle = handle, .event = event, .overlapped = std.mem.zeroes(win.OVERLAPPED), .buffer = buffer };
        slot.issue();
        if (slot.dead) return error.NotWatching;
        self.watches[index] = slot;
        return @enumFromInt(index);
    }

    fn watchSlot(self: *Real, handle: Watch.Handle) ?*WatchSlot {
        const index = @intFromEnum(handle);
        if (index >= max_watches) return null;
        return self.watches[index];
    }

    fn watchPoll(context: *anyopaque, handle: Watch.Handle, wait_ms: u32, out: []align(4) u8) Watch.Event {
        const slot = of(context).watchSlot(handle) orelse return .dead;
        return slot.poll(wait_ms, out);
    }

    fn watchClose(context: *anyopaque, handle: Watch.Handle) void {
        const self = of(context);
        const slot = self.watchSlot(handle) orelse return;
        slot.close(self.gpa);
        self.watches[@intFromEnum(handle)] = null;
    }

    fn monotonic(context: *anyopaque) i96 {
        return std.Io.Clock.awake.now(of(context).io).nanoseconds;
    }

    fn realtime(context: *anyopaque) i96 {
        return std.Io.Clock.real.now(of(context).io).nanoseconds;
    }

    fn sleep(context: *anyopaque, ns: u64) SleepError!void {
        return of(context).io.sleep(.fromNanoseconds(ns), .awake);
    }

    fn fill(context: *anyopaque, buffer: []u8) void {
        of(context).io.random(buffer);
    }
};

const win = struct {
    const FileTime = extern struct { low: u32, high: u32 };
    const FindData = extern struct {
        attributes: u32,
        creation: FileTime,
        last_access: FileTime,
        last_write: FileTime,
        size_high: u32,
        size_low: u32,
        reserved0: u32,
        reserved1: u32,
        name: [260]u16,
        alternate: [14]u16,
    };
    const OVERLAPPED = extern struct {
        Internal: usize,
        InternalHigh: usize,
        Offset: windows.DWORD,
        OffsetHigh: windows.DWORD,
        hEvent: ?windows.HANDLE,
    };

    const find_ex_info_basic: c_int = 1;
    const find_first_ex_large_fetch: windows.DWORD = 2;
    const file_attribute_directory: u32 = 0x10;
    const file_attribute_reparse_point: u32 = 0x400;
    const reparse_tag_name_surrogate: u32 = 0x20000000;
    const invalid_file_attributes: windows.DWORD = 0xFFFFFFFF;
    const movefile_replace_existing: windows.DWORD = 0x1;
    const movefile_write_through: windows.DWORD = 0x8;
    const file_list_directory: windows.DWORD = 0x1;
    const file_share_all: windows.DWORD = 0x7;
    const open_existing: windows.DWORD = 3;
    const file_flag_backup_semantics: windows.DWORD = 0x02000000;
    const file_flag_overlapped: windows.DWORD = 0x40000000;
    const drive_remote: c_uint = 4;
    const wait_object_0: windows.DWORD = 0;
    const notify_filter: windows.DWORD = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x40 | 0x100;

    const error_file_not_found: windows.DWORD = 2;
    const error_path_not_found: windows.DWORD = 3;
    const error_access_denied: windows.DWORD = 5;
    const error_no_more_files: windows.DWORD = 18;
    const error_sharing_violation: windows.DWORD = 32;
    const error_lock_violation: windows.DWORD = 33;
    const error_file_exists: windows.DWORD = 80;
    const error_disk_full: windows.DWORD = 112;
    const error_invalid_name: windows.DWORD = 123;
    const error_already_exists: windows.DWORD = 183;
    const error_filename_exced_range: windows.DWORD = 206;
    const error_directory: windows.DWORD = 267;
    const error_io_incomplete: windows.DWORD = 996;
    const error_notify_enum_dir: windows.DWORD = 1022;

    extern "kernel32" fn FindFirstFileExW(name: [*:0]const u16, level: c_int, data: *FindData, search: c_int, filter: ?*anyopaque, flags: windows.DWORD) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn FindNextFileW(handle: windows.HANDLE, data: *FindData) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn FindClose(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: windows.DWORD, share: windows.DWORD, security: ?*anyopaque, disposition: windows.DWORD, flags: windows.DWORD, template: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn ReadDirectoryChangesW(handle: windows.HANDLE, buffer: *anyopaque, length: windows.DWORD, subtree: windows.BOOL, filter: windows.DWORD, returned: ?*windows.DWORD, overlapped: *OVERLAPPED, routine: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetOverlappedResult(handle: windows.HANDLE, overlapped: *OVERLAPPED, transferred: *windows.DWORD, wait: windows.BOOL) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CancelIoEx(handle: windows.HANDLE, overlapped: ?*OVERLAPPED) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CreateEventW(security: ?*anyopaque, manual: windows.BOOL, initial: windows.BOOL, name: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn ResetEvent(event: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, milliseconds: windows.DWORD) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;
    extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn GetDriveTypeW(root: [*:0]const u16) callconv(.winapi) c_uint;
};

const testing = std.testing;

const TempRoot = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,

    fn init() !TempRoot {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        return .{ .tmp = tmp, .root = root };
    }

    fn deinit(self: *TempRoot) void {
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn path(self: TempRoot, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, "{s}\\{s}", .{ self.root, rel });
    }

    fn write(self: TempRoot, rel: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = data });
    }
};

test "every read error keeps its meaning when it crosses the seam" {
    try testing.expectEqual(error.TooLarge, readError(error.StreamTooLong));
    try testing.expectEqual(error.TooLarge, readError(error.FileTooBig));
    try testing.expectEqual(error.FileNotFound, readError(error.FileNotFound));
    try testing.expectEqual(error.FileNotFound, readError(error.NotDir));
    try testing.expectEqual(error.IsDirectory, readError(error.IsDir));
    try testing.expectEqual(error.AccessDenied, readError(error.AccessDenied));
    try testing.expectEqual(error.Busy, readError(error.FileBusy));
    try testing.expectEqual(error.NameTooLong, readError(error.NameTooLong));
    try testing.expectEqual(error.OutOfMemory, readError(error.OutOfMemory));
    try testing.expectEqual(error.InputOutput, readError(error.SystemResources));
    try testing.expectEqual(error.TooLarge, trackedError(error.StreamTooLong));
    try testing.expectEqual(error.GitFailed, trackedError(error.FileNotFound));
    try testing.expectEqual(error.NotDirectory, win32ListError(win.error_directory));
    try testing.expectEqual(error.Busy, win32WriteError(win.error_sharing_violation));
}

test "the real file system reads below the limit and refuses a file at the limit as too large" {
    var t = try TempRoot.init();
    defer t.deinit();
    try t.write("small.txt", "123456789");
    try t.write("edge.txt", "1234567890");
    var real = Real.init(testing.allocator, testing.io);
    defer real.deinit();
    const fs = real.seam().fs;
    const small = try t.path("small.txt");
    defer testing.allocator.free(small);
    const edge = try t.path("edge.txt");
    defer testing.allocator.free(edge);
    const bytes = try fs.readFile(small, testing.allocator, 10);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("123456789", bytes);
    try testing.expectError(error.TooLarge, fs.readFile(edge, testing.allocator, 10));
}

test "the real file system reports a missing file and a directory as errors and never as empty content" {
    var t = try TempRoot.init();
    defer t.deinit();
    try t.tmp.dir.createDirPath(testing.io, "sub");
    var real = Real.init(testing.allocator, testing.io);
    defer real.deinit();
    const fs = real.seam().fs;
    const missing = try t.path("missing.txt");
    defer testing.allocator.free(missing);
    const sub = try t.path("sub");
    defer testing.allocator.free(sub);
    try testing.expectError(error.FileNotFound, fs.readFile(missing, testing.allocator, 100));
    try testing.expectError(error.IsDirectory, fs.readFile(sub, testing.allocator, 100));
}

test "the real file system stats a file, a directory and a missing path" {
    var t = try TempRoot.init();
    defer t.deinit();
    try t.write("a.txt", "abc");
    try t.tmp.dir.createDirPath(testing.io, "sub");
    var real = Real.init(testing.allocator, testing.io);
    defer real.deinit();
    const fs = real.seam().fs;
    const a = try t.path("a.txt");
    defer testing.allocator.free(a);
    const sub = try t.path("sub");
    defer testing.allocator.free(sub);
    const missing = try t.path("missing.txt");
    defer testing.allocator.free(missing);
    const file_stat = try fs.stat(a, .follow);
    try testing.expectEqual(Kind.file, file_stat.kind);
    try testing.expectEqual(@as(u64, 3), file_stat.size);
    try testing.expect(file_stat.mtime_ns > 0);
    try testing.expectEqual(Kind.directory, (try fs.stat(sub, .no_follow)).kind);
    try testing.expectError(error.FileNotFound, fs.stat(missing, .follow));
}

const Collected = struct {
    names: std.ArrayList([]u8) = .empty,
    kinds: std.ArrayList(Kind) = .empty,
    sizes: std.ArrayList(u64) = .empty,
    failed: bool = false,

    fn visit(context: *anyopaque, entry: Entry) void {
        const self: *Collected = @ptrCast(@alignCast(context));
        const name = testing.allocator.dupe(u8, entry.name) catch {
            self.failed = true;
            return;
        };
        self.names.append(testing.allocator, name) catch {
            testing.allocator.free(name);
            self.failed = true;
            return;
        };
        self.kinds.append(testing.allocator, entry.kind) catch {
            self.failed = true;
            return;
        };
        self.sizes.append(testing.allocator, entry.size) catch {
            self.failed = true;
            return;
        };
    }

    fn deinit(self: *Collected) void {
        for (self.names.items) |n| testing.allocator.free(n);
        self.names.deinit(testing.allocator);
        self.kinds.deinit(testing.allocator);
        self.sizes.deinit(testing.allocator);
    }

    fn find(self: Collected, name: []const u8) ?usize {
        for (self.names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return i;
        }
        return null;
    }
};

test "the real file system lists every entry of a directory with its kind and size and refuses a missing one" {
    var t = try TempRoot.init();
    defer t.deinit();
    try t.write("a.txt", "abc");
    try t.write("b.txt", "");
    try t.tmp.dir.createDirPath(testing.io, "sub");
    var real = Real.init(testing.allocator, testing.io);
    defer real.deinit();
    const fs = real.seam().fs;
    var seen: Collected = .{};
    defer seen.deinit();
    try fs.list(t.root, .{ .context = &seen, .visit = Collected.visit });
    try testing.expect(!seen.failed);
    try testing.expectEqual(@as(usize, 3), seen.names.items.len);
    const a = seen.find("a.txt") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Kind.file, seen.kinds.items[a]);
    try testing.expectEqual(@as(u64, 3), seen.sizes.items[a]);
    try testing.expectEqual(Kind.directory, seen.kinds.items[seen.find("sub") orelse return error.TestUnexpectedResult]);
    const missing = try t.path("missing");
    defer testing.allocator.free(missing);
    var none: Collected = .{};
    defer none.deinit();
    try testing.expectError(error.FileNotFound, fs.list(missing, .{ .context = &none, .visit = Collected.visit }));
}

test "the real file system creates a file once and refuses to create it again" {
    var t = try TempRoot.init();
    defer t.deinit();
    var real = Real.init(testing.allocator, testing.io);
    defer real.deinit();
    const fs = real.seam().fs;
    const cookie = try t.path("cookie");
    defer testing.allocator.free(cookie);
    try fs.createFile(cookie, "", .{});
    try testing.expectError(error.PathAlreadyExists, fs.createFile(cookie, "", .{}));
    const durable = try t.path("durable.bin");
    defer testing.allocator.free(durable);
    try fs.createFile(durable, "kept", .{ .durable = true });
    const back = try fs.readFile(durable, testing.allocator, 100);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("kept", back);
}

test "the real file system replaces a file by rename and refuses to rename a missing file" {
    var t = try TempRoot.init();
    defer t.deinit();
    try t.write("target.txt", "old");
    var real = Real.init(testing.allocator, testing.io);
    defer real.deinit();
    const fs = real.seam().fs;
    const temp = try t.path("target.txt.tmp");
    defer testing.allocator.free(temp);
    const target = try t.path("target.txt");
    defer testing.allocator.free(target);
    try fs.createFile(temp, "new", .{ .durable = true });
    try fs.renameReplace(temp, target);
    const back = try fs.readFile(target, testing.allocator, 100);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("new", back);
    try testing.expectError(error.FileNotFound, fs.stat(temp, .follow));
    try testing.expectError(error.FileNotFound, fs.renameReplace(temp, target));
}

test "the real file system deletes a file, makes a nested path and resolves a path to its real form" {
    var t = try TempRoot.init();
    defer t.deinit();
    try t.write("a.txt", "x");
    var real = Real.init(testing.allocator, testing.io);
    defer real.deinit();
    const fs = real.seam().fs;
    const nested = try t.path("one\\two");
    defer testing.allocator.free(nested);
    try fs.makePath(nested);
    try testing.expectEqual(Kind.directory, (try fs.stat(nested, .follow)).kind);
    const roundabout = try t.path("one\\..\\a.txt");
    defer testing.allocator.free(roundabout);
    const resolved = try fs.realPath(roundabout, testing.allocator);
    defer testing.allocator.free(resolved);
    try testing.expect(std.mem.endsWith(u8, resolved, "\\a.txt"));
    try testing.expect(std.mem.indexOf(u8, resolved, "..") == null);
    const a = try t.path("a.txt");
    defer testing.allocator.free(a);
    try fs.deleteFile(a);
    try testing.expectError(error.FileNotFound, fs.deleteFile(a));
}

test "the real file system lists the files a repository tracks" {
    var t = try TempRoot.init();
    defer t.deinit();
    try t.write("a.ts", "export const a = 1;\n");
    try t.write("untracked.ts", "x\n");
    for ([_][]const []const u8{ &.{ "git", "init", "-q", "--template=" }, &.{ "git", "add", "a.ts" } }) |argv| {
        const result = try std.process.run(testing.allocator, testing.io, .{ .argv = argv, .cwd = .{ .path = t.root } });
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.TestUnexpectedResult,
            else => return error.TestUnexpectedResult,
        }
    }
    var real = Real.init(testing.allocator, testing.io);
    defer real.deinit();
    const files = try real.seam().fs.tracked(t.root, testing.allocator);
    defer freeTracked(testing.allocator, files);
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expectEqualStrings("a.ts", files[0]);
    const missing = try t.path("missing");
    defer testing.allocator.free(missing);
    try testing.expectError(error.GitFailed, real.seam().fs.tracked(missing, testing.allocator));
}

fn encodeRecord(out: []align(4) u8, at: usize, step: u32, action: Action, name: []const u8) usize {
    std.mem.writeInt(u32, out[at..][0..4], step, .little);
    std.mem.writeInt(u32, out[at + 4 ..][0..4], @intFromEnum(action), .little);
    std.mem.writeInt(u32, out[at + 8 ..][0..4], @intCast(name.len * 2), .little);
    for (name, 0..) |c, i| std.mem.writeInt(u16, out[at + record_header_bytes + 2 * i ..][0..2], c, .little);
    return at + record_header_bytes + name.len * 2;
}

test "notify records decode in order and a cut or overlapping record is malformed" {
    var buffer: [64]u8 align(4) = @splat(0);
    _ = encodeRecord(&buffer, 0, 20, .added, "a.ts");
    const end = encodeRecord(&buffer, 20, 0, .removed, "b");
    var it = records(buffer[0..end]);
    const first = (try it.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Action.added, first.action);
    try testing.expectEqual(@as(usize, 4), first.name.len);
    try testing.expectEqual(@as(u16, 'a'), first.name[0]);
    const second = (try it.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Action.removed, second.action);
    try testing.expect((try it.next()) == null);
    var cut = records(buffer[0 .. end - 4]);
    _ = try cut.next();
    try testing.expectError(error.Malformed, cut.next());
    std.mem.writeInt(u32, buffer[0..4], 8, .little);
    var overlapping = records(buffer[0..end]);
    try testing.expectError(error.Malformed, overlapping.next());
}

fn pollUntil(watch: Watch, handle: Watch.Handle, out: []align(4) u8) Watch.Event {
    var tries: usize = 0;
    while (tries < 40) : (tries += 1) {
        const event = watch.poll(handle, 100, out);
        if (event != .pending) return event;
    }
    return .pending;
}

fn hasName(bytes: []align(4) const u8, wanted: []const u8) !bool {
    var it = records(bytes);
    while (try it.next()) |record| {
        var buf: [512]u8 = undefined;
        const n = std.unicode.wtf16LeToWtf8(&buf, record.name);
        if (std.mem.eql(u8, buf[0..n], wanted)) return true;
    }
    return false;
}

test "the real watch reports a file created after it was opened" {
    var t = try TempRoot.init();
    defer t.deinit();
    var real = Real.init(testing.allocator, testing.io);
    defer real.deinit();
    const watch = real.seam().watch;
    const handle = try watch.open(t.root, 64 * 1024);
    defer watch.close(handle);
    try t.write("created-after-open.txt", "x");
    var out: [64 * 1024]u8 align(4) = undefined;
    var found = false;
    var rounds: usize = 0;
    while (!found and rounds < 10) : (rounds += 1) {
        switch (pollUntil(watch, handle, &out)) {
            .records => |n| found = try hasName(out[0..n], "created-after-open.txt"),
            .pending, .overflow, .dead => return error.TestUnexpectedResult,
        }
    }
    try testing.expect(found);
}

test "a change that does not fit the watch buffer is reported as overflow and never as silence" {
    var t = try TempRoot.init();
    defer t.deinit();
    var real = Real.init(testing.allocator, testing.io);
    defer real.deinit();
    const watch = real.seam().watch;
    const handle = try watch.open(t.root, min_watch_buffer_bytes);
    defer watch.close(handle);
    try t.write("a-name-long-enough-that-its-record-cannot-fit-in-sixty-four-bytes.txt", "x");
    var out: [min_watch_buffer_bytes]u8 align(4) = undefined;
    try testing.expectEqual(Watch.Event.overflow, pollUntil(watch, handle, &out));
}

test "polling a handle that was never opened or was closed reports a dead watch" {
    var t = try TempRoot.init();
    defer t.deinit();
    var real = Real.init(testing.allocator, testing.io);
    defer real.deinit();
    const watch = real.seam().watch;
    var out: [64]u8 align(4) = undefined;
    try testing.expectEqual(Watch.Event.dead, watch.poll(@enumFromInt(max_watches - 1), 0, &out));
    const handle = try watch.open(t.root, 4096);
    watch.close(handle);
    try testing.expectEqual(Watch.Event.dead, watch.poll(handle, 0, &out));
}

test "the real clock moves forward and the real time is after 2020" {
    var real = Real.init(testing.allocator, testing.io);
    defer real.deinit();
    const clock = real.seam().clock;
    const before = clock.monotonic();
    try clock.sleep(std.time.ns_per_ms);
    try testing.expect(clock.monotonic() > before);
    try testing.expect(clock.realtime() > 1_577_836_800 * std.time.ns_per_s);
    var a: [16]u8 = @splat(0);
    real.seam().entropy.fill(&a);
    var b: [16]u8 = @splat(0);
    real.seam().entropy.fill(&b);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}
