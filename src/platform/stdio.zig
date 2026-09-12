const std = @import("std");
const builtin = @import("builtin");

pub fn stdout() std.Io.File {
    var file = std.Io.File.stdout();
    if (builtin.os.tag == .windows) file.flags.nonblocking = isOverlapped(file.handle);
    return file;
}

pub fn stdin() std.Io.File {
    var file = std.Io.File.stdin();
    if (builtin.os.tag == .windows) file.flags.nonblocking = isOverlapped(file.handle);
    return file;
}

fn isOverlapped(handle: std.os.windows.HANDLE) bool {
    const windows = std.os.windows;
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    var mode: windows.FILE.MODE = undefined;
    const status = windows.ntdll.NtQueryInformationFile(handle, &iosb, &mode, @sizeOf(windows.FILE.MODE), .Mode);
    return status == .SUCCESS and mode.IO == .ASYNCHRONOUS;
}

const testing = std.testing;

const test_pipe = struct {
    const windows = std.os.windows;
    const access_outbound: windows.DWORD = 0x00000002;
    const flag_overlapped: windows.DWORD = 0x40000000;
    const buffer_size: windows.DWORD = 4096;

    extern "kernel32" fn CreateNamedPipeW(
        name: [*:0]const u16,
        open_mode: windows.DWORD,
        pipe_mode: windows.DWORD,
        max_instances: windows.DWORD,
        out_buffer_size: windows.DWORD,
        in_buffer_size: windows.DWORD,
        default_timeout: windows.DWORD,
        security_attributes: ?*anyopaque,
    ) callconv(.winapi) windows.HANDLE;

    extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;

    fn create(name: [*:0]const u16, open_mode: windows.DWORD) !windows.HANDLE {
        const handle = CreateNamedPipeW(name, open_mode, 0, 1, buffer_size, buffer_size, 0, null);
        if (handle == windows.INVALID_HANDLE_VALUE) return error.PipeCreationFailed;
        return handle;
    }
};

test "overlapped pipes are detected so large writes wait instead of hitting unreachable" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const overlapped = try test_pipe.create(
        std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\synapse-stdio-overlapped"),
        test_pipe.access_outbound | test_pipe.flag_overlapped,
    );
    defer _ = test_pipe.CloseHandle(overlapped);
    const synchronous = try test_pipe.create(
        std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\synapse-stdio-synchronous"),
        test_pipe.access_outbound,
    );
    defer _ = test_pipe.CloseHandle(synchronous);

    try testing.expect(isOverlapped(overlapped));
    try testing.expect(!isOverlapped(synchronous));
}
