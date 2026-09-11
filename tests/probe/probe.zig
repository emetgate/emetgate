const std = @import("std");
const windows = std.os.windows;

extern "kernel32" fn ExitProcess(code: windows.UINT) callconv(.winapi) noreturn;
extern "kernel32" fn Sleep(milliseconds: windows.DWORD) callconv(.winapi) void;
extern "kernel32" fn GetProcessId(process: windows.HANDLE) callconv(.winapi) windows.DWORD;
extern "kernel32" fn GetStdHandle(which: windows.DWORD) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;

const std_output_handle: windows.DWORD = @bitCast(@as(i32, -11));
const std_error_handle: windows.DWORD = @bitCast(@as(i32, -12));

const flood_line = "flood flood flood flood flood flood flood flood flood flood\n";

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const mode: []const u8 = if (args.len > 1) args[1] else "";

    var buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &buffer);
    const out = &stdout_writer.interface;

    if (std.mem.eql(u8, mode, "exit")) {
        const code = try std.fmt.parseInt(u32, args[2], 10);
        try out.print("exiting with {d}\n", .{code});
        try out.flush();
        ExitProcess(code);
    }
    if (std.mem.eql(u8, mode, "both")) {
        try out.writeAll("to stdout\n");
        try out.flush();
        std.debug.print("to stderr\n", .{});
        ExitProcess(0);
    }
    if (std.mem.eql(u8, mode, "spin")) {
        var counter: u64 = 0;
        while (true) {
            counter +%= 1;
            std.mem.doNotOptimizeAway(counter);
        }
    }
    if (std.mem.eql(u8, mode, "flood")) {
        while (true) try out.writeAll(flood_line);
    }
    if (std.mem.eql(u8, mode, "closeout")) {
        _ = CloseHandle(GetStdHandle(std_output_handle).?);
        _ = CloseHandle(GetStdHandle(std_error_handle).?);
        while (true) Sleep(1000);
    }
    if (std.mem.eql(u8, mode, "sleep")) {
        while (true) Sleep(1000);
    }
    if (std.mem.eql(u8, mode, "orphan")) {
        const child = try std.process.spawn(init.io, .{
            .argv = &.{ args[0], "sleep" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        try out.print("{d}\n", .{GetProcessId(child.id.?)});
        try out.flush();
        ExitProcess(0);
    }
    if (std.mem.eql(u8, mode, "grandchild")) {
        const child = try std.process.spawn(init.io, .{
            .argv = &.{ args[0], "sleep" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        try out.print("{d}\n", .{GetProcessId(child.id.?)});
        try out.flush();
        while (true) Sleep(1000);
    }
    ExitProcess(99);
}
