const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const index_file = @import("search_index_file.zig");
const worker_pool = @import("worker_pool.zig");

const Allocator = std.mem.Allocator;
const WidePath = [std.fs.max_path_bytes:0]u16;

pub const Stamp = index_file.Stamp;

pub const Kind = enum { file, directory, other };

pub const Seen = struct {
    stamp: Stamp,
    kind: Kind,
};

pub fn stampAll(gpa: Allocator, root: []const u8, paths: []const []const u8, out: []?Seen, pool: ?*worker_pool.Pool) !void {
    std.debug.assert(paths.len == out.len);
    @memset(out, null);
    var by_dir: std.StringArrayHashMapUnmanaged(std.ArrayList(u32)) = .empty;
    defer {
        for (by_dir.values()) |*v| v.deinit(gpa);
        by_dir.deinit(gpa);
    }
    for (paths, 0..) |p, i| {
        const dir = std.fs.path.dirnamePosix(p) orelse "";
        const got = try by_dir.getOrPut(gpa, dir);
        if (!got.found_existing) got.value_ptr.* = .empty;
        try got.value_ptr.append(gpa, @intCast(i));
    }
    var job: Job = .{ .gpa = gpa, .root = root, .paths = paths, .out = out, .dirs = by_dir.keys(), .groups = by_dir.values() };
    if (pool) |p| p.run(worker_pool.max_threads, Job.run, &job) else Job.run(&job);
    if (job.failed.load(.acquire)) return error.OutOfMemory;
}

const Job = struct {
    gpa: Allocator,
    root: []const u8,
    paths: []const []const u8,
    out: []?Seen,
    dirs: []const []const u8,
    groups: []const std.ArrayList(u32),
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),

    fn run(ctx: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(ctx));
        const buffer = self.gpa.alignedAlloc(u8, .@"8", list_buffer_bytes) catch {
            self.failed.store(true, .release);
            return;
        };
        defer self.gpa.free(buffer);
        var names: std.StringHashMapUnmanaged(u32) = .empty;
        defer names.deinit(self.gpa);
        while (true) {
            const i = self.next.fetchAdd(1, .monotonic);
            if (i >= self.dirs.len) return;
            names.clearRetainingCapacity();
            for (self.groups[i].items) |at| {
                names.put(self.gpa, std.fs.path.basenamePosix(self.paths[at]), at) catch {
                    self.failed.store(true, .release);
                    return;
                };
            }
            var visit: Visit = .{ .names = &names, .out = self.out };
            listDirectory(self.root, self.dirs[i], buffer, &visit) catch {};
        }
    }
};

const Visit = struct {
    names: *const std.StringHashMapUnmanaged(u32),
    out: []?Seen,

    fn see(self: *Visit, name: []const u8, seen: Seen) void {
        if (self.names.get(name)) |at| self.out[at] = seen;
    }
};

const list_buffer_bytes = 64 * 1024;

fn listDirectory(root: []const u8, rel_dir: []const u8, buffer: []align(8) u8, visit: *Visit) !void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_abs = if (rel_dir.len == 0) root else try std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ root, rel_dir });
    var wide: WidePath = undefined;
    const w = try toWide(&wide, dir_abs);
    const handle = win.CreateFileW(w, win.file_list_directory, win.file_share_all, null, win.open_existing, win.file_flag_backup_semantics, null);
    if (handle == windows.INVALID_HANDLE_VALUE) return error.OpenFailed;
    defer windows.CloseHandle(handle);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (true) {
        if (win.GetFileInformationByHandleEx(handle, win.file_full_directory_info, buffer.ptr, @intCast(buffer.len)) == .FALSE) {
            if (win.GetLastError() == win.error_no_more_files) return;
            return error.ListFailed;
        }
        var offset: usize = 0;
        while (true) {
            const rec = buffer[offset..];
            const next = std.mem.readInt(u32, rec[0..4], .little);
            const write = std.mem.readInt(i64, rec[24..32], .little);
            const change = std.mem.readInt(i64, rec[32..40], .little);
            const size = std.mem.readInt(i64, rec[40..48], .little);
            const attributes = std.mem.readInt(u32, rec[56..60], .little);
            const reparse_tag = std.mem.readInt(u32, rec[64..68], .little);
            const name_bytes = std.mem.readInt(u32, rec[60..64], .little);
            const units = std.mem.bytesAsSlice(u16, @as([]align(2) const u8, @alignCast(rec[68..][0..name_bytes])));
            const n = std.unicode.wtf16LeToWtf8(&name_buf, units);
            const link = attributes & win.file_attribute_reparse_point != 0 and reparse_tag & win.reparse_tag_name_surrogate != 0;
            const kind: Kind = if (link) .other else if (attributes & win.file_attribute_directory != 0) .directory else .file;
            visit.see(name_buf[0..n], .{
                .stamp = .{ .mtime_ns = toNs(write), .ctime_ns = toNs(change), .size = @intCast(@max(size, 0)) },
                .kind = kind,
            });
            if (next == 0) break;
            offset += next;
        }
    }
}

pub fn toNs(hns: i64) i64 {
    return @intCast(windows.fromSysTime(hns).nanoseconds);
}

fn toWide(buffer: *WidePath, path: []const u8) ![*:0]const u16 {
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\");
    const long = path.len >= 240 and path.len > 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
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
    const file_list_directory: windows.DWORD = 0x0001;
    const file_share_all: windows.DWORD = 0x00000007;
    const open_existing: windows.DWORD = 3;
    const file_flag_backup_semantics: windows.DWORD = 0x02000000;
    const file_full_directory_info: c_int = 14;
    const error_no_more_files: windows.DWORD = 18;
    const file_attribute_directory: u32 = 0x10;
    const file_attribute_reparse_point: u32 = 0x400;
    const reparse_tag_name_surrogate: u32 = 0x20000000;

    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: windows.DWORD, share: windows.DWORD, security: ?*anyopaque, disposition: windows.DWORD, flags: windows.DWORD, template: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn GetFileInformationByHandleEx(file: windows.HANDLE, class: c_int, info: *anyopaque, size: windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;
};

const testing = std.testing;

test "stat scan: every listed file gets its size, write time and change time, and a missing one stays null" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src/deep");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "abc" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/deep/b.ts", .data = "hello" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const paths = [_][]const u8{ "a.ts", "src/deep/b.ts", "src/gone.ts", "src/deep" };
    var out: [paths.len]?Seen = undefined;
    try stampAll(testing.allocator, root, &paths, &out, null);
    try testing.expectEqual(@as(u64, 3), out[0].?.stamp.size);
    try testing.expectEqual(@as(u64, 5), out[1].?.stamp.size);
    try testing.expect(out[2] == null);
    try testing.expectEqual(Kind.directory, out[3].?.kind);
    const stat = try tmp.dir.statFile(testing.io, "src/deep/b.ts", .{});
    try testing.expectEqual(@as(i64, @intCast(stat.mtime.nanoseconds)), out[1].?.stamp.mtime_ns);
    try testing.expect(out[1].?.stamp.ctime_ns != 0);
}

test "stat scan: setting the write time back still changes the change time" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "one" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const paths = [_][]const u8{"a.ts"};
    var before: [1]?Seen = undefined;
    try stampAll(testing.allocator, root, &paths, &before, null);
    try std.Io.sleep(testing.io, .fromMilliseconds(30), .awake);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "two" });
    const file = try tmp.dir.openFile(testing.io, "a.ts", .{ .mode = .read_write });
    try file.setTimestamps(testing.io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = before[0].?.stamp.mtime_ns } } });
    file.close(testing.io);
    var after: [1]?Seen = undefined;
    try stampAll(testing.allocator, root, &paths, &after, null);
    try testing.expectEqual(before[0].?.stamp.mtime_ns, after[0].?.stamp.mtime_ns);
    try testing.expectEqual(before[0].?.stamp.size, after[0].?.stamp.size);
    try testing.expect(before[0].?.stamp.ctime_ns != after[0].?.stamp.ctime_ns);
}
