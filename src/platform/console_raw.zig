const std = @import("std");
const builtin = @import("builtin");
const rules_tui = @import("../protocol/rules_tui.zig");

const windows = std.os.windows;
const WORD = windows.WORD;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const HANDLE = windows.HANDLE;

// The thin Windows-console raw-mode layer for `emetgate rules`. It toggles the
// console into a raw, VT-processing mode, reads key events, and restores the
// original modes on exit. All the checklist logic lives in rules_tui.zig; this file
// only talks to the Console API, in the same `extern "kernel32"` style as stdio.zig.

extern "kernel32" fn GetStdHandle(id: DWORD) callconv(.winapi) HANDLE;
extern "kernel32" fn GetConsoleMode(handle: HANDLE, mode: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn SetConsoleMode(handle: HANDLE, mode: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn ReadConsoleInputW(handle: HANDLE, buffer: [*]InputRecord, length: DWORD, read: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetConsoleScreenBufferInfo(handle: HANDLE, info: *ConsoleScreenBufferInfo) callconv(.winapi) BOOL;

const Coord = extern struct { x: i16, y: i16 };
const SmallRect = extern struct { left: i16, top: i16, right: i16, bottom: i16 };
const ConsoleScreenBufferInfo = extern struct {
    size: Coord,
    cursor: Coord,
    attributes: WORD,
    window: SmallRect,
    maximum_window_size: Coord,
};

// The number of visible rows in the console window, so the checklist viewport fits
// the terminal. Returns null when the size cannot be read (not a console), and the
// caller falls back to a default.
pub fn windowRows(handles: Handles) ?usize {
    if (builtin.os.tag != .windows) return null;
    var info: ConsoleScreenBufferInfo = undefined;
    if (!GetConsoleScreenBufferInfo(handles.out, &info).toBool()) return null;
    const rows = @as(i32, info.window.bottom) - @as(i32, info.window.top) + 1;
    if (rows <= 0) return null;
    return @intCast(rows);
}

const std_input_handle: DWORD = 0xFFFFFFF6; // (DWORD)-10
const std_output_handle: DWORD = 0xFFFFFFF5; // (DWORD)-11

// stdin mode flags.
const enable_processed_input: DWORD = 0x0001;
const enable_line_input: DWORD = 0x0002;
const enable_echo_input: DWORD = 0x0004;

// stdout mode flags.
const enable_processed_output: DWORD = 0x0001;
const enable_virtual_terminal_processing: DWORD = 0x0004;

const key_event: WORD = 0x0001;

// Virtual-key codes for the keys the checklist reads.
const vk_back: WORD = 0x08;
const vk_tab: WORD = 0x09;
const vk_return: WORD = 0x0D;
const vk_escape: WORD = 0x1B;
const vk_space: WORD = 0x20;
const vk_up: WORD = 0x26;
const vk_down: WORD = 0x28;

const KeyEventRecord = extern struct {
    bKeyDown: BOOL,
    wRepeatCount: WORD,
    wVirtualKeyCode: WORD,
    wVirtualScanCode: WORD,
    UnicodeChar: WORD,
    dwControlKeyState: DWORD,
};

const InputRecord = extern struct {
    EventType: WORD,
    _reserved: WORD = 0,
    Event: extern union {
        key: KeyEventRecord,
        // The union is sized to the largest event record (16 bytes); we only read
        // key events, so a filler guarantees the layout matches INPUT_RECORD.
        filler: [16]u8,
    },
};

comptime {
    // INPUT_RECORD is 20 bytes on Windows (WORD + 2 pad + 16-byte union).
    std.debug.assert(@sizeOf(InputRecord) == 20);
    std.debug.assert(@sizeOf(KeyEventRecord) == 16);
}

pub const Handles = struct {
    in: HANDLE,
    out: HANDLE,

    pub fn get() Handles {
        return .{ .in = GetStdHandle(std_input_handle), .out = GetStdHandle(std_output_handle) };
    }
};

// Both stdin and stdout are real consoles iff GetConsoleMode succeeds on each. A
// pipe or redirect fails, which is how the driver detects a non-TTY and falls back.
pub fn isTty(handles: Handles) bool {
    if (builtin.os.tag != .windows) return false;
    var mode: DWORD = undefined;
    if (!GetConsoleMode(handles.in, &mode).toBool()) return false;
    if (!GetConsoleMode(handles.out, &mode).toBool()) return false;
    return true;
}

// The original console modes, restored by `defer raw.restore()` on every exit path
// (save, cancel, or error) so the user's terminal is never left in raw mode.
pub const Raw = struct {
    handles: Handles,
    in_mode: DWORD,
    out_mode: DWORD,

    pub fn enter(handles: Handles) !Raw {
        var in_mode: DWORD = undefined;
        var out_mode: DWORD = undefined;
        if (!GetConsoleMode(handles.in, &in_mode).toBool()) return error.NotATerminal;
        if (!GetConsoleMode(handles.out, &out_mode).toBool()) return error.NotATerminal;

        // Raw stdin: no line buffering, no echo; also drop processed input so Ctrl+C
        // arrives as a key event we treat as cancel and still restore cleanly. We do
        // NOT enable ENABLE_VIRTUAL_TERMINAL_INPUT: with VT input on, arrow keys arrive
        // as ANSI escape byte sequences (ESC [ A / ESC [ B) instead of KEY_EVENT records
        // with VK_UP/VK_DOWN, and ReadConsoleInputW VK handling would never see them.
        const raw_in = in_mode & ~(enable_line_input | enable_echo_input | enable_processed_input);
        // VT processing on stdout so the ANSI render (clear, cursor, inverse) works.
        const raw_out = out_mode | enable_virtual_terminal_processing | enable_processed_output;

        if (!SetConsoleMode(handles.in, raw_in).toBool()) return error.RawModeUnavailable;
        if (!SetConsoleMode(handles.out, raw_out).toBool()) {
            _ = SetConsoleMode(handles.in, in_mode);
            return error.RawModeUnavailable;
        }
        return .{ .handles = handles, .in_mode = in_mode, .out_mode = out_mode };
    }

    pub fn restore(self: Raw) void {
        _ = SetConsoleMode(self.handles.in, self.in_mode);
        _ = SetConsoleMode(self.handles.out, self.out_mode);
    }

    // Block for the next meaningful key down, mapped to a checklist Key. Non-key
    // events (focus, resize, mouse) and key-up events are skipped.
    pub fn readKey(self: Raw) !rules_tui.Key {
        var record: [1]InputRecord = undefined;
        while (true) {
            var read: DWORD = 0;
            if (!ReadConsoleInputW(self.handles.in, &record, 1, &read).toBool()) return error.ConsoleReadFailed;
            if (read == 0 or record[0].EventType != key_event) continue;
            const ev = record[0].Event.key;
            if (!ev.bKeyDown.toBool()) continue;
            if (mapKey(ev)) |key| return key;
        }
    }
};

// Navigation keys are mapped from virtual-key codes; every printable character
// (space included) comes back as `.char` so the driver can read it literally when a
// path field is being typed and only interpret space/q as commands in normal mode.
// Ctrl+C is always cancel so the loop can never be trapped.
fn mapKey(ev: KeyEventRecord) ?rules_tui.Key {
    switch (ev.wVirtualKeyCode) {
        vk_up => return .up,
        vk_down => return .down,
        vk_return => return .save,
        vk_tab => return .scope,
        vk_escape => return .cancel,
        vk_back => return .backspace,
        else => {},
    }
    const ch = ev.UnicodeChar;
    if (ch == 0x03) return .cancel; // Ctrl+C
    if (ch == 0 or ch < 0x20) return .other;
    return .{ .char = ch };
}

const testing = std.testing;

fn keyDown(vk: WORD, ch: WORD) KeyEventRecord {
    return .{ .bKeyDown = BOOL.fromBool(true), .wRepeatCount = 1, .wVirtualKeyCode = vk, .wVirtualScanCode = 0, .UnicodeChar = ch, .dwControlKeyState = 0 };
}

test "mapKey maps the navigation virtual keys to semantic keys (arrows come as VK, not VT escapes)" {
    // With ENABLE_VIRTUAL_TERMINAL_INPUT left OFF, arrows arrive as KEY_EVENT records
    // carrying VK_UP/VK_DOWN, which is exactly what this maps. The UnicodeChar for an
    // arrow key is 0, so the VK switch must fire before the char path.
    try testing.expectEqual(rules_tui.Key.up, mapKey(keyDown(vk_up, 0)).?);
    try testing.expectEqual(rules_tui.Key.down, mapKey(keyDown(vk_down, 0)).?);
    try testing.expectEqual(rules_tui.Key.save, mapKey(keyDown(vk_return, 0x0d)).?);
    try testing.expectEqual(rules_tui.Key.scope, mapKey(keyDown(vk_tab, 0x09)).?);
    try testing.expectEqual(rules_tui.Key.cancel, mapKey(keyDown(vk_escape, 0x1b)).?);
    try testing.expectEqual(rules_tui.Key.backspace, mapKey(keyDown(vk_back, 0x08)).?);
}

fn expectChar(key: ?rules_tui.Key, want: u21) !void {
    switch (key orelse return error.TestUnexpectedResult) {
        .char => |c| try testing.expectEqual(want, c),
        else => return error.TestUnexpectedResult,
    }
}

test "mapKey passes printable characters (space, q, j, k) through as chars so they stay literal while editing" {
    try testing.expectEqual(rules_tui.Key.cancel, mapKey(keyDown(0, 0x03)).?); // Ctrl+C
    try expectChar(mapKey(keyDown(vk_space, 0x20)), ' ');
    try expectChar(mapKey(keyDown(0, 'q')), 'q');
    try expectChar(mapKey(keyDown(0, 'j')), 'j');
    try expectChar(mapKey(keyDown(0, 'k')), 'k');
    // The reducer (rules_tui) turns space->toggle, k/j->up/down and q->cancel in normal
    // mode, but keeps them literal inside a path field; that is tested there.
}
