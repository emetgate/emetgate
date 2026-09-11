const std = @import("std");
const builtin = @import("builtin");

pub fn stdout() std.Io.File {
    var file = std.Io.File.stdout();
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
