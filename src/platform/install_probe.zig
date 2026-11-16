const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const Allocator = std.mem.Allocator;

pub const Process = struct {
    pid: u32,
    image: []const u8,
    command_line: []const u8,
};

const emetgate_images = [_][]const u8{ "emetgate.exe", "emetgate.old.exe", "emetgate.new.exe" };

pub fn isEmetgateImage(name: []const u8) bool {
    for (emetgate_images) |image| if (std.ascii.eqlIgnoreCase(name, image)) return true;
    return false;
}

pub fn emetgateProcesses(arena: Allocator) ![]Process {
    if (builtin.os.tag != .windows) return &.{};
    const snapshot = win.CreateToolhelp32Snapshot(win.snap_process, 0);
    if (snapshot == windows.INVALID_HANDLE_VALUE) return error.SnapshotFailed;
    defer windows.CloseHandle(snapshot);
    const own = win.GetCurrentProcessId();
    var found: std.ArrayList(Process) = .empty;
    var entry: win.ProcessEntry = undefined;
    entry.size = @sizeOf(win.ProcessEntry);
    var more = win.Process32FirstW(snapshot, &entry);
    while (more != .FALSE) : (more = win.Process32NextW(snapshot, &entry)) {
        if (entry.process_id == own) continue;
        const name = std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.sliceTo(&entry.exe_file, 0)) catch continue;
        if (!isEmetgateImage(name)) continue;
        var process: Process = .{ .pid = entry.process_id, .image = name, .command_line = "" };
        if (win.OpenProcess(win.query_limited, .FALSE, entry.process_id)) |handle| {
            defer windows.CloseHandle(handle);
            if (imagePath(arena, handle)) |path| process.image = path;
            if (commandLine(arena, handle)) |line| process.command_line = line;
        }
        try found.append(arena, process);
    }
    return found.toOwnedSlice(arena);
}

fn imagePath(arena: Allocator, handle: windows.HANDLE) ?[]const u8 {
    var buf: [windows.PATH_MAX_WIDE]u16 = undefined;
    var size: windows.DWORD = buf.len;
    if (win.QueryFullProcessImageNameW(handle, 0, &buf, &size) == .FALSE) return null;
    return std.unicode.wtf16LeToWtf8Alloc(arena, buf[0..size]) catch null;
}

fn commandLine(arena: Allocator, handle: windows.HANDLE) ?[]const u8 {
    const buf = arena.alignedAlloc(u8, .of(win.UnicodeString), 32 * 1024) catch return null;
    var returned: u32 = 0;
    if (win.NtQueryInformationProcess(handle, win.process_command_line_information, buf.ptr, @intCast(buf.len), &returned) < 0) return null;
    const header: *const win.UnicodeString = @ptrCast(buf.ptr);
    const units = header.buffer orelse return null;
    return std.unicode.wtf16LeToWtf8Alloc(arena, units[0 .. header.length / 2]) catch null;
}

pub const Size = struct {
    bytes: u64 = 0,
    files: u64 = 0,
    complete: bool = true,
};

pub const max_counted_entries: u64 = 300_000;

pub fn treeSize(arena: Allocator, root: []const u8) !Size {
    if (builtin.os.tag != .windows) return .{ .complete = false };
    var size: Size = .{};
    var entries: u64 = 0;
    var pending: std.ArrayList([]const u8) = .empty;
    try pending.append(arena, root);
    var data: win.FindData = undefined;
    while (pending.pop()) |dir| {
        const pattern = try std.fmt.allocPrint(arena, "\\\\?\\{s}\\*", .{std.mem.trimEnd(u8, dir, "\\/")});
        const wide = std.unicode.wtf8ToWtf16LeAllocZ(arena, pattern) catch continue;
        for (wide) |*unit| {
            if (unit.* == '/') unit.* = '\\';
        }
        const handle = win.FindFirstFileExW(wide.ptr, win.find_ex_info_basic, &data, 0, null, win.find_first_ex_large_fetch);
        if (handle == windows.INVALID_HANDLE_VALUE) continue;
        defer _ = win.FindClose(handle);
        while (true) {
            entries += 1;
            if (entries > max_counted_entries) {
                size.complete = false;
                return size;
            }
            const name = std.mem.sliceTo(&data.file_name, 0);
            const dot = name.len == 1 and name[0] == '.';
            const dotdot = name.len == 2 and name[0] == '.' and name[1] == '.';
            if (!dot and !dotdot) {
                if (data.attributes & win.attribute_directory != 0) {
                    if (data.attributes & win.attribute_reparse_point == 0) {
                        const child = std.unicode.wtf16LeToWtf8Alloc(arena, name) catch "";
                        if (child.len != 0) try pending.append(arena, try std.fmt.allocPrint(arena, "{s}\\{s}", .{ std.mem.trimEnd(u8, dir, "\\/"), child }));
                    }
                } else {
                    size.files += 1;
                    size.bytes +|= (@as(u64, data.size_high) << 32) | data.size_low;
                }
            }
            if (win.FindNextFileW(handle, &data) == .FALSE) break;
        }
    }
    return size;
}

pub fn writeBytes(w: *std.Io.Writer, bytes: u64) !void {
    const units = [_][]const u8{ "KiB", "MiB", "GiB", "TiB" };
    if (bytes < 1024) return w.print("{d} B", .{bytes});
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    value /= 1024;
    while (value >= 1024 and unit + 1 < units.len) : (unit += 1) value /= 1024;
    try w.print("{d:.1} {s}", .{ value, units[unit] });
}

const win = struct {
    const snap_process: u32 = 0x2;
    const query_limited: u32 = 0x1000;
    const process_command_line_information: u32 = 60;
    const find_ex_info_basic: u32 = 1;
    const find_first_ex_large_fetch: u32 = 2;
    const attribute_directory: u32 = 0x10;
    const attribute_reparse_point: u32 = 0x400;

    const ProcessEntry = extern struct {
        size: u32,
        usage: u32,
        process_id: u32,
        default_heap_id: usize,
        module_id: u32,
        threads: u32,
        parent_process_id: u32,
        priority: i32,
        flags: u32,
        exe_file: [260]u16,
    };

    const UnicodeString = extern struct {
        length: u16,
        maximum_length: u16,
        buffer: ?[*]const u16,
    };

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
        file_name: [260]u16,
        alternate_file_name: [14]u16,
    };

    extern "kernel32" fn CreateToolhelp32Snapshot(flags: u32, process_id: u32) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn Process32FirstW(snapshot: windows.HANDLE, entry: *ProcessEntry) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn Process32NextW(snapshot: windows.HANDLE, entry: *ProcessEntry) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn OpenProcess(access: u32, inherit: windows.BOOL, pid: u32) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn QueryFullProcessImageNameW(process: windows.HANDLE, flags: windows.DWORD, name: [*]u16, size: *windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "ntdll" fn NtQueryInformationProcess(process: windows.HANDLE, class: u32, info: *anyopaque, length: u32, returned: ?*u32) callconv(.winapi) i32;
    extern "kernel32" fn FindFirstFileExW(name: [*:0]const u16, level: u32, data: *FindData, search: u32, filter: ?*anyopaque, flags: u32) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn FindNextFileW(handle: windows.HANDLE, data: *FindData) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn FindClose(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
};
