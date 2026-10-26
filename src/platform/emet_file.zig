const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const dir_scan = @import("dir_scan.zig");

const magic = "EMETv006".*;
const binary_probe = 8000;
const max_pattern = 4096;
const empty: u32 = std.math.maxInt(u32);

pub const Header = extern struct {
    magic: [8]u8,
    n_files: u32,
    n_text: u32,
    n: u64,
    n_orig: u64,
    n_lines: u64,
    paths_len: u64,
    off_text: u64,
    off_ends: u64,
    off_orig: u64,
    off_sa: u64,
    off_files: u64,
    off_paths: u64,
    off_lines: u64,
    off_olines: u64,
    off_stamps: u64,
    owner: WaveletPlace,
    prev: WaveletPlace,
    size: u64,
};

pub const WaveletPlace = extern struct {
    levels: u64,
    off_zeros: u64,
    off_lines: u64,
    off_coarse: u64,
};

pub const Line = extern struct {
    before: u64,
    bits: [7]u64,
};

const line_bits = 448;
const coarse_step = 64;

pub const FileRow = extern struct {
    start: u32,
    len: u32,
    ostart: u32,
    olen: u32,
    first_line: u32,
    path_off: u32,
    path_len: u32,
};

pub const Stamp = extern struct {
    size: u64,
    mtime: i64,

    pub fn of(stat: Io.File.Stat) Stamp {
        return .{ .size = stat.size, .mtime = @truncate(stat.mtime.nanoseconds) };
    }

    pub fn eql(a: Stamp, b: Stamp) bool {
        return a.size == b.size and a.mtime == b.mtime;
    }
};

fn linesFor(n: u64) u64 {
    return n / line_bits + 1;
}

fn coarseFor(n: u64) u64 {
    return linesFor(n) / coarse_step + 1;
}

fn endWords(n: u64) u64 {
    return n / 64 + 1;
}

const FoldRun = struct { start: u21, count: u16, stride: u8, delta: i32 };

const fold_runs = [_]FoldRun{
    .{ .start = 0xB5, .count = 1, .stride = 1, .delta = 775 },
    .{ .start = 0xC0, .count = 23, .stride = 1, .delta = 32 },
    .{ .start = 0xD8, .count = 7, .stride = 1, .delta = 32 },
    .{ .start = 0x100, .count = 24, .stride = 2, .delta = 1 },
    .{ .start = 0x130, .count = 1, .stride = 1, .delta = -199 },
    .{ .start = 0x131, .count = 1, .stride = 1, .delta = -200 },
    .{ .start = 0x132, .count = 3, .stride = 2, .delta = 1 },
    .{ .start = 0x139, .count = 8, .stride = 2, .delta = 1 },
    .{ .start = 0x14A, .count = 23, .stride = 2, .delta = 1 },
    .{ .start = 0x178, .count = 1, .stride = 1, .delta = -121 },
    .{ .start = 0x179, .count = 3, .stride = 2, .delta = 1 },
    .{ .start = 0x17F, .count = 1, .stride = 1, .delta = -268 },
    .{ .start = 0x181, .count = 1, .stride = 1, .delta = 210 },
    .{ .start = 0x182, .count = 2, .stride = 2, .delta = 1 },
    .{ .start = 0x186, .count = 1, .stride = 1, .delta = 206 },
    .{ .start = 0x187, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0x189, .count = 2, .stride = 1, .delta = 205 },
    .{ .start = 0x18B, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0x18E, .count = 1, .stride = 1, .delta = 79 },
    .{ .start = 0x18F, .count = 1, .stride = 1, .delta = 202 },
    .{ .start = 0x190, .count = 1, .stride = 1, .delta = 203 },
    .{ .start = 0x191, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0x193, .count = 1, .stride = 1, .delta = 205 },
    .{ .start = 0x194, .count = 1, .stride = 1, .delta = 207 },
    .{ .start = 0x196, .count = 1, .stride = 1, .delta = 211 },
    .{ .start = 0x197, .count = 1, .stride = 1, .delta = 209 },
    .{ .start = 0x198, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0x19C, .count = 1, .stride = 1, .delta = 211 },
    .{ .start = 0x19D, .count = 1, .stride = 1, .delta = 213 },
    .{ .start = 0x19F, .count = 1, .stride = 1, .delta = 214 },
    .{ .start = 0x1A0, .count = 3, .stride = 2, .delta = 1 },
    .{ .start = 0x1A6, .count = 1, .stride = 1, .delta = 218 },
    .{ .start = 0x1A7, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0x1A9, .count = 1, .stride = 1, .delta = 218 },
    .{ .start = 0x1AC, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0x1AE, .count = 1, .stride = 1, .delta = 218 },
    .{ .start = 0x1AF, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0x1B1, .count = 2, .stride = 1, .delta = 217 },
    .{ .start = 0x1B3, .count = 2, .stride = 2, .delta = 1 },
    .{ .start = 0x1B7, .count = 1, .stride = 1, .delta = 219 },
    .{ .start = 0x1B8, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0x1BC, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0x1C4, .count = 1, .stride = 1, .delta = 2 },
    .{ .start = 0x1C5, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0x1C7, .count = 1, .stride = 1, .delta = 2 },
    .{ .start = 0x1C8, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0x1CA, .count = 1, .stride = 1, .delta = 2 },
    .{ .start = 0x1CB, .count = 9, .stride = 2, .delta = 1 },
    .{ .start = 0x1DE, .count = 9, .stride = 2, .delta = 1 },
    .{ .start = 0x1F1, .count = 1, .stride = 1, .delta = 2 },
    .{ .start = 0x1F2, .count = 2, .stride = 2, .delta = 1 },
    .{ .start = 0x1F6, .count = 1, .stride = 1, .delta = -97 },
    .{ .start = 0x1F7, .count = 1, .stride = 1, .delta = -56 },
    .{ .start = 0x1F8, .count = 20, .stride = 2, .delta = 1 },
    .{ .start = 0x220, .count = 1, .stride = 1, .delta = -130 },
    .{ .start = 0x222, .count = 9, .stride = 2, .delta = 1 },
    .{ .start = 0x23A, .count = 1, .stride = 1, .delta = 10795 },
    .{ .start = 0x23B, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0x23D, .count = 1, .stride = 1, .delta = -163 },
    .{ .start = 0x23E, .count = 1, .stride = 1, .delta = 10792 },
    .{ .start = 0x241, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0x243, .count = 1, .stride = 1, .delta = -195 },
    .{ .start = 0x244, .count = 1, .stride = 1, .delta = 69 },
    .{ .start = 0x245, .count = 1, .stride = 1, .delta = 71 },
    .{ .start = 0x246, .count = 5, .stride = 2, .delta = 1 },
    .{ .start = 0x345, .count = 1, .stride = 1, .delta = 116 },
    .{ .start = 0x370, .count = 2, .stride = 2, .delta = 1 },
    .{ .start = 0x376, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0x37F, .count = 1, .stride = 1, .delta = 116 },
    .{ .start = 0x386, .count = 1, .stride = 1, .delta = 38 },
    .{ .start = 0x388, .count = 3, .stride = 1, .delta = 37 },
    .{ .start = 0x38C, .count = 1, .stride = 1, .delta = 64 },
    .{ .start = 0x38E, .count = 2, .stride = 1, .delta = 63 },
    .{ .start = 0x391, .count = 17, .stride = 1, .delta = 32 },
    .{ .start = 0x3A3, .count = 9, .stride = 1, .delta = 32 },
    .{ .start = 0x3C2, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0x3CF, .count = 1, .stride = 1, .delta = 8 },
    .{ .start = 0x3D0, .count = 1, .stride = 1, .delta = -30 },
    .{ .start = 0x3D1, .count = 1, .stride = 1, .delta = -25 },
    .{ .start = 0x3D5, .count = 1, .stride = 1, .delta = -15 },
    .{ .start = 0x3D6, .count = 1, .stride = 1, .delta = -22 },
    .{ .start = 0x3D8, .count = 12, .stride = 2, .delta = 1 },
    .{ .start = 0x3F0, .count = 1, .stride = 1, .delta = -54 },
    .{ .start = 0x3F1, .count = 1, .stride = 1, .delta = -48 },
    .{ .start = 0x3F4, .count = 1, .stride = 1, .delta = -60 },
    .{ .start = 0x3F5, .count = 1, .stride = 1, .delta = -64 },
    .{ .start = 0x3F7, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0x3F9, .count = 1, .stride = 1, .delta = -7 },
    .{ .start = 0x3FA, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0x3FD, .count = 3, .stride = 1, .delta = -130 },
    .{ .start = 0x400, .count = 16, .stride = 1, .delta = 80 },
    .{ .start = 0x410, .count = 32, .stride = 1, .delta = 32 },
    .{ .start = 0x460, .count = 17, .stride = 2, .delta = 1 },
    .{ .start = 0x48A, .count = 27, .stride = 2, .delta = 1 },
    .{ .start = 0x4C0, .count = 1, .stride = 1, .delta = 15 },
    .{ .start = 0x4C1, .count = 7, .stride = 2, .delta = 1 },
    .{ .start = 0x4D0, .count = 48, .stride = 2, .delta = 1 },
    .{ .start = 0x531, .count = 38, .stride = 1, .delta = 48 },
    .{ .start = 0x10A0, .count = 38, .stride = 1, .delta = 7264 },
    .{ .start = 0x10C7, .count = 1, .stride = 1, .delta = 7264 },
    .{ .start = 0x10CD, .count = 1, .stride = 1, .delta = 7264 },
    .{ .start = 0x13F8, .count = 6, .stride = 1, .delta = -8 },
    .{ .start = 0x1C80, .count = 1, .stride = 1, .delta = -6222 },
    .{ .start = 0x1C81, .count = 1, .stride = 1, .delta = -6221 },
    .{ .start = 0x1C82, .count = 1, .stride = 1, .delta = -6212 },
    .{ .start = 0x1C83, .count = 2, .stride = 1, .delta = -6210 },
    .{ .start = 0x1C85, .count = 1, .stride = 1, .delta = -6211 },
    .{ .start = 0x1C86, .count = 1, .stride = 1, .delta = -6204 },
    .{ .start = 0x1C87, .count = 1, .stride = 1, .delta = -6180 },
    .{ .start = 0x1C88, .count = 1, .stride = 1, .delta = 35267 },
    .{ .start = 0x1C89, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0x1C90, .count = 43, .stride = 1, .delta = -3008 },
    .{ .start = 0x1CBD, .count = 3, .stride = 1, .delta = -3008 },
    .{ .start = 0x1E00, .count = 75, .stride = 2, .delta = 1 },
    .{ .start = 0x1E9B, .count = 1, .stride = 1, .delta = -58 },
    .{ .start = 0x1E9E, .count = 1, .stride = 1, .delta = -7615 },
    .{ .start = 0x1EA0, .count = 48, .stride = 2, .delta = 1 },
    .{ .start = 0x1F08, .count = 8, .stride = 1, .delta = -8 },
    .{ .start = 0x1F18, .count = 6, .stride = 1, .delta = -8 },
    .{ .start = 0x1F28, .count = 8, .stride = 1, .delta = -8 },
    .{ .start = 0x1F38, .count = 8, .stride = 1, .delta = -8 },
    .{ .start = 0x1F48, .count = 6, .stride = 1, .delta = -8 },
    .{ .start = 0x1F59, .count = 4, .stride = 2, .delta = -8 },
    .{ .start = 0x1F68, .count = 8, .stride = 1, .delta = -8 },
    .{ .start = 0x1F88, .count = 8, .stride = 1, .delta = -8 },
    .{ .start = 0x1F98, .count = 8, .stride = 1, .delta = -8 },
    .{ .start = 0x1FA8, .count = 8, .stride = 1, .delta = -8 },
    .{ .start = 0x1FB8, .count = 2, .stride = 1, .delta = -8 },
    .{ .start = 0x1FBA, .count = 2, .stride = 1, .delta = -74 },
    .{ .start = 0x1FBC, .count = 1, .stride = 1, .delta = -9 },
    .{ .start = 0x1FBE, .count = 1, .stride = 1, .delta = -7173 },
    .{ .start = 0x1FC8, .count = 4, .stride = 1, .delta = -86 },
    .{ .start = 0x1FCC, .count = 1, .stride = 1, .delta = -9 },
    .{ .start = 0x1FD8, .count = 2, .stride = 1, .delta = -8 },
    .{ .start = 0x1FDA, .count = 2, .stride = 1, .delta = -100 },
    .{ .start = 0x1FE8, .count = 2, .stride = 1, .delta = -8 },
    .{ .start = 0x1FEA, .count = 2, .stride = 1, .delta = -112 },
    .{ .start = 0x1FEC, .count = 1, .stride = 1, .delta = -7 },
    .{ .start = 0x1FF8, .count = 2, .stride = 1, .delta = -128 },
    .{ .start = 0x1FFA, .count = 2, .stride = 1, .delta = -126 },
    .{ .start = 0x1FFC, .count = 1, .stride = 1, .delta = -9 },
    .{ .start = 0x2126, .count = 1, .stride = 1, .delta = -7517 },
    .{ .start = 0x212A, .count = 1, .stride = 1, .delta = -8383 },
    .{ .start = 0x212B, .count = 1, .stride = 1, .delta = -8262 },
    .{ .start = 0x2132, .count = 1, .stride = 1, .delta = 28 },
    .{ .start = 0x2160, .count = 16, .stride = 1, .delta = 16 },
    .{ .start = 0x2183, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0x24B6, .count = 26, .stride = 1, .delta = 26 },
    .{ .start = 0x2C00, .count = 48, .stride = 1, .delta = 48 },
    .{ .start = 0x2C60, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0x2C62, .count = 1, .stride = 1, .delta = -10743 },
    .{ .start = 0x2C63, .count = 1, .stride = 1, .delta = -3814 },
    .{ .start = 0x2C64, .count = 1, .stride = 1, .delta = -10727 },
    .{ .start = 0x2C67, .count = 3, .stride = 2, .delta = 1 },
    .{ .start = 0x2C6D, .count = 1, .stride = 1, .delta = -10780 },
    .{ .start = 0x2C6E, .count = 1, .stride = 1, .delta = -10749 },
    .{ .start = 0x2C6F, .count = 1, .stride = 1, .delta = -10783 },
    .{ .start = 0x2C70, .count = 1, .stride = 1, .delta = -10782 },
    .{ .start = 0x2C72, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0x2C75, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0x2C7E, .count = 2, .stride = 1, .delta = -10815 },
    .{ .start = 0x2C80, .count = 50, .stride = 2, .delta = 1 },
    .{ .start = 0x2CEB, .count = 2, .stride = 2, .delta = 1 },
    .{ .start = 0x2CF2, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0xA640, .count = 23, .stride = 2, .delta = 1 },
    .{ .start = 0xA680, .count = 14, .stride = 2, .delta = 1 },
    .{ .start = 0xA722, .count = 7, .stride = 2, .delta = 1 },
    .{ .start = 0xA732, .count = 31, .stride = 2, .delta = 1 },
    .{ .start = 0xA779, .count = 2, .stride = 2, .delta = 1 },
    .{ .start = 0xA77D, .count = 1, .stride = 1, .delta = -35332 },
    .{ .start = 0xA77E, .count = 5, .stride = 2, .delta = 1 },
    .{ .start = 0xA78B, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0xA78D, .count = 1, .stride = 1, .delta = -42280 },
    .{ .start = 0xA790, .count = 2, .stride = 2, .delta = 1 },
    .{ .start = 0xA796, .count = 10, .stride = 2, .delta = 1 },
    .{ .start = 0xA7AA, .count = 1, .stride = 1, .delta = -42308 },
    .{ .start = 0xA7AB, .count = 1, .stride = 1, .delta = -42319 },
    .{ .start = 0xA7AC, .count = 1, .stride = 1, .delta = -42315 },
    .{ .start = 0xA7AD, .count = 1, .stride = 1, .delta = -42305 },
    .{ .start = 0xA7AE, .count = 1, .stride = 1, .delta = -42308 },
    .{ .start = 0xA7B0, .count = 1, .stride = 1, .delta = -42258 },
    .{ .start = 0xA7B1, .count = 1, .stride = 1, .delta = -42282 },
    .{ .start = 0xA7B2, .count = 1, .stride = 1, .delta = -42261 },
    .{ .start = 0xA7B3, .count = 1, .stride = 1, .delta = 928 },
    .{ .start = 0xA7B4, .count = 8, .stride = 2, .delta = 1 },
    .{ .start = 0xA7C4, .count = 1, .stride = 1, .delta = -48 },
    .{ .start = 0xA7C5, .count = 1, .stride = 1, .delta = -42307 },
    .{ .start = 0xA7C6, .count = 1, .stride = 1, .delta = -35384 },
    .{ .start = 0xA7C7, .count = 2, .stride = 2, .delta = 1 },
    .{ .start = 0xA7CB, .count = 1, .stride = 1, .delta = -42343 },
    .{ .start = 0xA7CC, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0xA7D0, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0xA7D6, .count = 3, .stride = 2, .delta = 1 },
    .{ .start = 0xA7DC, .count = 1, .stride = 1, .delta = -42561 },
    .{ .start = 0xA7F5, .count = 1, .stride = 1, .delta = 1 },
    .{ .start = 0xAB70, .count = 80, .stride = 1, .delta = -38864 },
    .{ .start = 0xFF21, .count = 26, .stride = 1, .delta = 32 },
    .{ .start = 0x10400, .count = 40, .stride = 1, .delta = 40 },
    .{ .start = 0x104B0, .count = 36, .stride = 1, .delta = 40 },
    .{ .start = 0x10570, .count = 11, .stride = 1, .delta = 39 },
    .{ .start = 0x1057C, .count = 15, .stride = 1, .delta = 39 },
    .{ .start = 0x1058C, .count = 7, .stride = 1, .delta = 39 },
    .{ .start = 0x10594, .count = 2, .stride = 1, .delta = 39 },
    .{ .start = 0x10C80, .count = 51, .stride = 1, .delta = 64 },
    .{ .start = 0x10D50, .count = 22, .stride = 1, .delta = 32 },
    .{ .start = 0x118A0, .count = 32, .stride = 1, .delta = 32 },
    .{ .start = 0x16E40, .count = 32, .stride = 1, .delta = 32 },
    .{ .start = 0x1E900, .count = 34, .stride = 1, .delta = 34 },
};

fn foldRune(c: u21) u21 {
    if (c < 0x80) return std.ascii.toLower(@intCast(c));
    var lo: usize = 0;
    var hi: usize = fold_runs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (fold_runs[mid].start <= c) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return c;
    const r = fold_runs[lo - 1];
    const d = c - r.start;
    if (d % r.stride != 0 or d / r.stride >= r.count) return c;
    return @intCast(@as(i32, c) + r.delta);
}

fn foldInto(dst: []u8, s: []const u8) usize {
    var i: usize = 0;
    var o: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            dst[o] = std.ascii.toLower(b);
            o += 1;
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(b) catch 1;
        const c = if (len > 1 and i + len <= s.len) std.unicode.utf8Decode(s[i..][0..len]) catch null else null;
        if (c) |rune| {
            o += std.unicode.utf8Encode(foldRune(rune), dst[o..]) catch unreachable;
            i += len;
        } else {
            dst[o] = b;
            o += 1;
            i += 1;
        }
    }
    return o;
}

pub const Encoding = enum { utf8, utf16le, utf16be, windows1254 };

pub const Read = struct { text: []const u8, encoding: Encoding, binary: bool };

fn decode(gpa: Allocator, raw: []const u8, buf: *std.ArrayList(u8)) !Read {
    buf.clearRetainingCapacity();
    if (std.mem.startsWith(u8, raw, "\xFF\xFE")) return utf16(gpa, raw[2..], .little, buf);
    if (std.mem.startsWith(u8, raw, "\xFE\xFF")) return utf16(gpa, raw[2..], .big, buf);
    const body = if (std.mem.startsWith(u8, raw, "\xEF\xBB\xBF")) raw[3..] else raw;
    if (body.len == raw.len) if (utf16Guess(raw)) |endian| return utf16(gpa, raw, endian, buf);
    const binary = std.mem.indexOfScalar(u8, body[0..@min(body.len, binary_probe)], 0) != null;
    if (std.unicode.utf8ValidateSlice(body)) return .{ .text = body, .encoding = .utf8, .binary = binary };
    try buf.ensureUnusedCapacity(gpa, 3 * body.len);
    for (body) |b| {
        const c: u21 = switch (b) {
            0x80...0x9F => windows1254_high[b - 0x80],
            0xD0 => 0x11E,
            0xDD => 0x130,
            0xDE => 0x15E,
            0xF0 => 0x11F,
            0xFD => 0x131,
            0xFE => 0x15F,
            else => b,
        };
        buf.items.len += std.unicode.utf8Encode(c, buf.unusedCapacitySlice()) catch unreachable;
    }
    return .{ .text = buf.items, .encoding = .windows1254, .binary = binary };
}

const windows1254_high = [32]u21{
    0x20AC, 0x81,   0x201A, 0x192,  0x201E, 0x2026, 0x2020, 0x2021, 0x2C6, 0x2030, 0x160, 0x2039, 0x152, 0x8D, 0x8E, 0x8F,
    0x90,   0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x2DC, 0x2122, 0x161, 0x203A, 0x153, 0x9D, 0x9E, 0x178,
};

fn utf16Guess(raw: []const u8) ?std.builtin.Endian {
    const pairs: usize = @min(raw.len, binary_probe) / 2;
    if (pairs == 0) return null;
    var even: usize = 0;
    var odd: usize = 0;
    for (0..pairs) |i| {
        if (raw[2 * i] == 0) even += 1;
        if (raw[2 * i + 1] == 0) odd += 1;
    }
    if (odd * 10 >= pairs * 9 and even * 10 <= pairs) return .little;
    if (even * 10 >= pairs * 9 and odd * 10 <= pairs) return .big;
    return null;
}

fn utf16(gpa: Allocator, raw: []const u8, endian: std.builtin.Endian, buf: *std.ArrayList(u8)) !Read {
    const units = raw.len / 2;
    try buf.ensureUnusedCapacity(gpa, 3 * units);
    var i: usize = 0;
    while (i < units) : (i += 1) {
        var c: u21 = std.mem.readInt(u16, raw[2 * i ..][0..2], endian);
        if (c >= 0xD800 and c < 0xDC00 and i + 1 < units) {
            const lo = std.mem.readInt(u16, raw[2 * i + 2 ..][0..2], endian);
            if (lo >= 0xDC00 and lo < 0xE000) {
                c = 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00);
                i += 1;
            }
        }
        if (c >= 0xD800 and c < 0xE000) c = 0xFFFD;
        buf.items.len += std.unicode.utf8Encode(c, buf.unusedCapacitySlice()) catch unreachable;
    }
    const text = buf.items;
    const binary = std.mem.indexOfScalar(u8, text[0..@min(text.len, binary_probe)], 0) != null;
    return .{ .text = text, .encoding = if (endian == .little) .utf16le else .utf16be, .binary = binary };
}

const Texts = struct {
    text: std.ArrayList(u8) = .empty,
    ends: std.ArrayList(u32) = .empty,
    orig: std.ArrayList(u8) = .empty,
    rows: std.ArrayList(FileRow) = .empty,
    paths: std.ArrayList(u8) = .empty,
    lines: std.ArrayList(u32) = .empty,
    olines: std.ArrayList(u32) = .empty,
    stamps: std.ArrayList(Stamp) = .empty,

    fn deinit(t: *Texts, gpa: Allocator) void {
        inline for (std.meta.fields(Texts)) |f| @field(t, f.name).deinit(gpa);
    }

    fn add(t: *Texts, gpa: Allocator, path: []const u8, content: []const u8, stamp: Stamp) !void {
        const start = t.text.items.len;
        const ostart = t.orig.items.len;
        try t.text.ensureUnusedCapacity(gpa, 2 * content.len + 1);
        t.text.items.len += foldInto(t.text.unusedCapacitySlice(), content);
        const folded = t.text.items[start..];
        if (t.text.items.len + 2 >= empty or ostart + content.len + 1 >= empty) return error.TreeTooLarge;
        try t.rows.append(gpa, .{
            .start = @intCast(start),
            .len = @intCast(folded.len),
            .ostart = @intCast(ostart),
            .olen = @intCast(content.len),
            .first_line = @intCast(t.lines.items.len),
            .path_off = @intCast(t.paths.items.len),
            .path_len = @intCast(path.len),
        });
        try t.stamps.append(gpa, stamp);
        try t.paths.appendSlice(gpa, path);
        try lineStarts(gpa, &t.lines, start, folded);
        try lineStarts(gpa, &t.olines, ostart, content);
        try t.orig.appendSlice(gpa, content);
        try t.ends.append(gpa, @intCast(t.text.items.len));
        t.text.appendAssumeCapacity(0);
        try t.orig.append(gpa, 0);
    }

    fn lineStarts(gpa: Allocator, lines: *std.ArrayList(u32), start: usize, s: []const u8) !void {
        try lines.append(gpa, @intCast(start));
        for (s, 0..) |c, i| {
            if (c == '\n' and i + 1 < s.len) try lines.append(gpa, @intCast(start + i + 1));
        }
    }
};

pub const Target = union(enum) { file: []const u8, memory: void };

/// Optional build-stage profiler. Null (production) unless set by `find build`.
pub const BuildProfile = struct {
    io: Io,
    last: Io.Timestamp = undefined,
    read_ns: u64 = 0,
    ends_ns: u64 = 0,
    sais_ns: u64 = 0,
    owner_ns: u64 = 0,
    emit_ns: u64 = 0,
    sections_ns: u64 = 0,
    wavelets_ns: u64 = 0,

    fn lap(p: *BuildProfile) u64 {
        const now = Io.Timestamp.now(p.io, .awake);
        const ns: u64 = @intCast(p.last.durationTo(now).nanoseconds);
        p.last = now;
        return ns;
    }
};

/// Not threadlocal: build() runs on a worker thread while `find build` sets this
/// from the main thread, and prepare() joins that worker before the fields are read.
pub var build_profile: ?*BuildProfile = null;

pub fn build(io: Io, gpa: Allocator, arena: Allocator, root_path: []const u8, paths: [][]const u8, target: Target, cancel: *const std.atomic.Value(bool)) !Index {
    if (build_profile) |p| p.last = Io.Timestamp.now(p.io, .awake);
    var root = try Io.Dir.cwd().openDir(io, root_path, .{});
    defer root.close(io);
    std.mem.sort([]const u8, paths, {}, lessPath);
    var kept: usize = 0;
    for (paths) |p| {
        if (kept > 0 and std.mem.eql(u8, paths[kept - 1], p)) continue;
        paths[kept] = p;
        kept += 1;
    }

    var t: Texts = .{};
    defer t.deinit(gpa);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var binary: std.ArrayList([]const u8) = .empty;
    for ([_]bool{ false, true }) |second| {
        for (if (second) binary.items else paths[0..kept]) |p| {
            try check(cancel);
            const stat = root.statFile(io, p, .{}) catch continue;
            if (stat.kind != .file) continue;
            const raw = root.readFileAlloc(io, p, gpa, .unlimited) catch continue;
            defer gpa.free(raw);
            const r = try decode(gpa, raw, &buf);
            if (r.binary and !second) {
                try binary.append(arena, p);
                continue;
            }
            try t.add(gpa, p, r.text, .of(stat));
        }
    }
    const n_files: u32 = @intCast(t.rows.items.len);
    const n_text = n_files - @as(u32, @intCast(binary.items.len));
    try t.ends.append(gpa, @intCast(t.text.items.len));
    try t.text.append(gpa, 0);
    const n = t.text.items.len;
    try t.rows.append(gpa, .{
        .start = @intCast(n),
        .len = 0,
        .ostart = @intCast(t.orig.items.len),
        .olen = 0,
        .first_line = @intCast(t.lines.items.len),
        .path_off = @intCast(t.paths.items.len),
        .path_len = 0,
    });

    if (build_profile) |p| p.read_ns = p.lap();
    const ends = try gpa.alloc(u64, endWords(n));
    defer gpa.free(ends);
    @memset(ends, 0);
    for (t.ends.items) |e| ends[e / 64] |= @as(u64, 1) << @intCast(e % 64);
    if (build_profile) |p| p.ends_ns = p.lap();

    var sa: ?[]u32 = try gpa.alloc(u32, n);
    defer if (sa) |owned| gpa.free(owned);
    {
        const sym = try gpa.alloc(u16, n);
        defer gpa.free(sym);
        for (t.text.items, sym) |c, *s| s.* = @as(u16, c) + 2;
        for (t.ends.items) |e| sym[e] = 1;
        sym[n - 1] = 0;
        try sais(u16, gpa, sym, sa.?, 258);
    }
    try check(cancel);
    if (build_profile) |p| p.sais_ns = p.lap();

    const owner = try gpa.alloc(u32, n);
    defer gpa.free(owner);
    const prev = try gpa.alloc(u32, n);
    defer gpa.free(prev);
    {
        const last = try gpa.alloc(u32, @max(n_files, 1));
        defer gpa.free(last);
        @memset(last, 0);
        for (sa.?, owner, prev, 0..) |pos, *o, *p, r| {
            const f = fileOf(t.rows.items, n_files, pos);
            o.* = f;
            p.* = last[f];
            last[f] = @intCast(r + 1);
        }
    }

    const owner_levels: u64 = if (n_files <= 1) 1 else std.math.log2_int_ceil(u64, n_files);
    const prev_levels: u64 = std.math.log2_int_ceil(u64, n + 1);

    var h: Header = std.mem.zeroes(Header);
    h.magic = magic;
    h.n_files = n_files;
    h.n_text = n_text;
    h.n = n;
    h.n_orig = t.orig.items.len;
    h.n_lines = t.lines.items.len;
    h.paths_len = t.paths.items.len;
    var off: u64 = std.mem.alignForward(u64, @sizeOf(Header), 64);
    h.off_text = off;
    off = std.mem.alignForward(u64, off + n, 64);
    h.off_ends = off;
    off = std.mem.alignForward(u64, off + 8 * ends.len, 64);
    h.off_orig = off;
    off = std.mem.alignForward(u64, off + h.n_orig, 64);
    h.off_sa = off;
    off = std.mem.alignForward(u64, off + 4 * n, 64);
    h.off_files = off;
    off = std.mem.alignForward(u64, off + @sizeOf(FileRow) * t.rows.items.len, 64);
    h.off_paths = off;
    off = std.mem.alignForward(u64, off + h.paths_len, 64);
    h.off_lines = off;
    off = std.mem.alignForward(u64, off + 4 * h.n_lines, 64);
    h.off_olines = off;
    off = std.mem.alignForward(u64, off + 4 * h.n_lines, 64);
    h.off_stamps = off;
    off = std.mem.alignForward(u64, off + @sizeOf(Stamp) * n_files, 64);
    h.owner = placeWavelet(&off, n, owner_levels);
    h.prev = placeWavelet(&off, n, prev_levels);
    h.size = off;
    try check(cancel);

    if (build_profile) |p| p.owner_ns = p.lap();
    const parts: Parts = .{ .h = &h, .t = &t, .ends = ends, .owner = owner, .prev = prev };
    switch (target) {
        .file => |out_path| {
            const tmp_path = try std.fmt.allocPrint(arena, "{s}.tmp", .{out_path});
            var file = try Io.Dir.cwd().createFile(io, tmp_path, .{});
            var file_open = true;
            defer if (file_open) file.close(io);
            var wbuf: [1 << 16]u8 = undefined;
            var fw = file.writer(io, &wbuf);
            try emit(gpa, &fw.interface, parts, &sa);
            try fw.interface.flush();
            if (build_profile) |p| p.emit_ns = p.lap();
            file.close(io);
            file_open = false;
            try Io.Dir.cwd().rename(tmp_path, Io.Dir.cwd(), out_path, io);
            return Index.open(io, out_path);
        },
        .memory => {
            const m = try gpa.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), h.size);
            errdefer gpa.free(m);
            var w = Io.Writer.fixed(m);
            try emit(gpa, &w, parts, &sa);
            return Index.over(m, .{ .owned = gpa });
        },
    }
}

const Parts = struct {
    h: *const Header,
    t: *const Texts,
    ends: []const u64,
    owner: []u32,
    prev: []u32,
};

fn emit(gpa: Allocator, w: *Io.Writer, parts: Parts, sa: *?[]u32) !void {
    const h = parts.h;
    const t = parts.t;
    var at: u64 = 0;
    try put(w, &at, h.off_text, std.mem.asBytes(h));
    try put(w, &at, h.off_ends, t.text.items);
    try put(w, &at, h.off_orig, std.mem.sliceAsBytes(parts.ends));
    try put(w, &at, h.off_sa, t.orig.items);
    try put(w, &at, h.off_files, std.mem.sliceAsBytes(sa.*.?));
    gpa.free(sa.*.?);
    sa.* = null;
    try put(w, &at, h.off_paths, std.mem.sliceAsBytes(t.rows.items));
    try put(w, &at, h.off_lines, t.paths.items);
    try put(w, &at, h.off_olines, std.mem.sliceAsBytes(t.lines.items));
    try put(w, &at, h.off_stamps, std.mem.sliceAsBytes(t.olines.items));
    try put(w, &at, h.owner.off_zeros, std.mem.sliceAsBytes(t.stamps.items));
    if (build_profile) |p| p.sections_ns = p.lap();

    const other = try gpa.alloc(u32, h.n);
    defer gpa.free(other);
    try writeWavelet(gpa, w, &at, h.owner, h.prev.off_zeros, parts.owner, other);
    try writeWavelet(gpa, w, &at, h.prev, h.size, parts.prev, other);
    if (build_profile) |p| p.wavelets_ns = p.lap();
}

fn check(cancel: *const std.atomic.Value(bool)) error{Canceled}!void {
    if (cancel.load(.acquire)) return error.Canceled;
}

pub fn list(io: Io, gpa: Allocator, arena: Allocator, root_path: []const u8) ![][]const u8 {
    return listUnder(io, gpa, arena, root_path, null);
}

pub fn listUnder(io: Io, gpa: Allocator, arena: Allocator, root_path: []const u8, specs: ?[]const []const u8) ![][]const u8 {
    var root = try Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer root.close(io);
    var paths: std.ArrayList([]const u8) = .empty;
    if (specs) |given| {
        if (given.len == 0) return paths.items;
    }
    if (try listGit(io, gpa, arena, root, root_path, specs, &paths)) return paths.items;
    paths.clearRetainingCapacity();
    const roots: []const []const u8 = specs orelse &.{""};
    for (roots) |spec| try listTree(io, gpa, arena, root, spec, &paths);
    return paths.items;
}

const max_command = 24 << 10;

fn listGit(io: Io, gpa: Allocator, arena: Allocator, root: Io.Dir, root_path: []const u8, specs: ?[]const []const u8, paths: *std.ArrayList([]const u8)) !bool {
    root.access(io, ".git", .{}) catch return false;
    const modes = [_][]const []const u8{
        &.{ "--cached", "--recurse-submodules" },
        &.{ "--others", "--exclude-standard" },
    };
    const given = specs orelse &.{};
    var start: usize = 0;
    while (true) {
        const end = chunkEnd(given, start);
        for (modes) |mode| {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(arena, &.{ "git", "--literal-pathspecs", "-C", root_path, "ls-files", "-z" });
            try argv.appendSlice(arena, mode);
            if (specs != null) {
                try argv.append(arena, "--");
                try argv.appendSlice(arena, given[start..end]);
            }
            const r = std.process.run(gpa, io, .{ .argv = argv.items }) catch return false;
            defer gpa.free(r.stdout);
            gpa.free(r.stderr);
            if (r.term != .exited or r.term.exited != 0) return false;
            var it = std.mem.splitScalar(u8, r.stdout, 0);
            while (it.next()) |p| if (p.len > 0) try paths.append(arena, try arena.dupe(u8, p));
        }
        start = end;
        if (start >= given.len) return true;
    }
}

pub fn ignored(io: Io, gpa: Allocator, arena: Allocator, root_path: []const u8, paths: []const []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    while (start < paths.len) {
        const end = chunkEnd(paths, start);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ "git", "-c", "core.quotePath=false", "-C", root_path, "check-ignore", "--" });
        try argv.appendSlice(arena, paths[start..end]);
        const r = std.process.run(gpa, io, .{ .argv = argv.items }) catch return out.items;
        defer gpa.free(r.stdout);
        gpa.free(r.stderr);
        if (r.term != .exited or r.term.exited > 1) return out.items;
        var it = std.mem.splitScalar(u8, r.stdout, '\n');
        while (it.next()) |line| {
            const p = std.mem.trimEnd(u8, line, "\r");
            if (p.len > 0) try out.append(arena, try arena.dupe(u8, p));
        }
        start = end;
    }
    return out.items;
}

pub fn stampEach(io: Io, arena: Allocator, root_path: []const u8, paths: []const []const u8) ![]?Stamp {
    const out = try arena.alloc(?Stamp, paths.len);
    @memset(out, null);
    try statMissing(io, root_path, paths, out);
    return out;
}

pub fn stampTree(io: Io, arena: Allocator, root_path: []const u8, paths: []const []const u8) ![]?Stamp {
    const out = try arena.alloc(?Stamp, paths.len);
    @memset(out, null);
    if (builtin.os.tag == .windows) scanStamps(io, arena, root_path, paths, out) catch {};
    try statMissing(io, root_path, paths, out);
    return out;
}

fn statMissing(io: Io, root_path: []const u8, paths: []const []const u8, out: []?Stamp) !void {
    var root = try Io.Dir.cwd().openDir(io, root_path, .{});
    defer root.close(io);
    for (paths, out) |p, *stamp| {
        if (stamp.* != null) continue;
        const stat = root.statFile(io, p, .{}) catch continue;
        if (stat.kind == .file) stamp.* = .of(stat);
    }
}

fn scanStamps(io: Io, arena: Allocator, root_path: []const u8, paths: []const []const u8, out: []?Stamp) !void {
    const abs = try Io.Dir.cwd().realPathFileAlloc(io, root_path, arena);
    const root = (try dir_scan.openRoot(abs)) orelse return;
    defer dir_scan.close(root);
    var dirs: std.StringArrayHashMapUnmanaged(std.StringHashMapUnmanaged(usize)) = .empty;
    for (paths, 0..) |p, i| {
        const cut = std.mem.lastIndexOfScalar(u8, p, '/');
        const entry = try dirs.getOrPut(arena, if (cut) |k| p[0..k] else "");
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.put(arena, if (cut) |k| p[k + 1 ..] else p, i);
    }
    const buffer = try arena.alignedAlloc(u8, .@"8", dir_scan.buffer_bytes);
    var name: [3 * dir_scan.max_name_units]u8 = undefined;
    for (dirs.keys(), dirs.values()) |d, names| {
        const handle = if (d.len == 0) root else (openUnder(arena, root, d) catch continue) orelse continue;
        defer if (d.len != 0) dir_scan.close(handle);
        var reader = dir_scan.Reader.init(handle, buffer[0..dir_scan.buffer_bytes]);
        while (reader.next() catch null) |e| {
            if (e.kind != .file or e.name.len > dir_scan.max_name_units) continue;
            const i = names.get(name[0..std.unicode.wtf16LeToWtf8(&name, e.name)]) orelse continue;
            out[i] = .{ .size = e.size, .mtime = @truncate(std.os.windows.fromSysTime(e.write_time).nanoseconds) };
        }
    }
}

fn openUnder(arena: Allocator, root: std.os.windows.HANDLE, d: []const u8) !?std.os.windows.HANDLE {
    const wide = try std.unicode.wtf8ToWtf16LeAlloc(arena, d);
    for (wide) |*unit| {
        if (unit.* == '/') unit.* = '\\';
    }
    return dir_scan.openChild(root, wide);
}

fn chunkEnd(given: []const []const u8, start: usize) usize {
    var end = start;
    var len: usize = 0;
    while (end < given.len and (end == start or len + given[end].len < max_command)) : (end += 1) len += given[end].len + 1;
    return end;
}

fn listTree(io: Io, gpa: Allocator, arena: Allocator, root: Io.Dir, spec: []const u8, paths: *std.ArrayList([]const u8)) !void {
    if (spec.len != 0) {
        const stat = root.statFile(io, spec, .{}) catch return;
        if (stat.kind != .directory) return paths.append(arena, try arena.dupe(u8, spec));
    }
    var dir = if (spec.len == 0) root else root.openDir(io, spec, .{ .iterate = true }) catch return;
    defer if (spec.len != 0) dir.close(io);
    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => try walker.enter(io, entry),
        .file, .sym_link => {
            const p = if (spec.len == 0) try arena.dupe(u8, entry.path) else try std.fmt.allocPrint(arena, "{s}/{s}", .{ spec, entry.path });
            for (p) |*c| if (c.* == '\\') {
                c.* = '/';
            };
            try paths.append(arena, p);
        },
        else => {},
    };
}

fn placeWavelet(off: *u64, n: u64, levels: u64) WaveletPlace {
    var p: WaveletPlace = .{ .levels = levels, .off_zeros = off.*, .off_lines = 0, .off_coarse = 0 };
    p.off_lines = std.mem.alignForward(u64, p.off_zeros + 4 * levels, 64);
    p.off_coarse = std.mem.alignForward(u64, p.off_lines + @sizeOf(Line) * linesFor(n) * levels, 64);
    off.* = std.mem.alignForward(u64, p.off_coarse + 8 * coarseFor(n) * levels, 64);
    return p;
}

fn writeWavelet(gpa: Allocator, w: *Io.Writer, at: *u64, place: WaveletPlace, end: u64, values: []u32, other: []u32) !void {
    const n = values.len;
    const levels = place.levels;
    const lines = linesFor(n);
    const coarse = coarseFor(n);
    const zeros = try gpa.alloc(u32, levels);
    defer gpa.free(zeros);
    const all = try gpa.alloc(Line, lines * levels);
    defer gpa.free(all);
    @memset(all, std.mem.zeroes(Line));
    const coarse_all = try gpa.alloc(u64, coarse * levels);
    defer gpa.free(coarse_all);

    var cur = values;
    var nxt = other;
    for (0..levels) |l| {
        const shift: u6 = @intCast(levels - 1 - l);
        const ll = all[l * lines ..][0..lines];
        var z: usize = 0;
        for (cur, 0..) |v, i| {
            if ((@as(u64, v) >> shift) & 1 == 1) {
                const at_line = i % line_bits;
                ll[i / line_bits].bits[at_line / 64] |= @as(u64, 1) << @intCast(at_line % 64);
            } else z += 1;
        }
        zeros[l] = @intCast(z);
        var zi: usize = 0;
        var oi: usize = z;
        for (cur) |v| {
            if ((@as(u64, v) >> shift) & 1 == 1) {
                nxt[oi] = v;
                oi += 1;
            } else {
                nxt[zi] = v;
                zi += 1;
            }
        }
        const lc = coarse_all[l * coarse ..][0..coarse];
        @memset(lc, 0);
        var ones: u64 = 0;
        for (ll, 0..) |*line, li| {
            line.before = ones;
            if (li % coarse_step == 0) lc[li / coarse_step] = ones;
            for (line.bits) |word| ones += @popCount(word);
        }
        std.mem.swap([]u32, &cur, &nxt);
    }
    try put(w, at, place.off_lines, std.mem.sliceAsBytes(zeros));
    try put(w, at, place.off_coarse, std.mem.sliceAsBytes(all));
    try put(w, at, end, std.mem.sliceAsBytes(coarse_all));
}

fn put(w: *Io.Writer, at: *u64, next_off: u64, bytes: []const u8) !void {
    try w.writeAll(bytes);
    at.* += bytes.len;
    while (at.* < next_off) : (at.* += 1) try w.writeByte(0);
}

fn lessPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn fileOf(rows: []const FileRow, n_files: u32, pos: u32) u32 {
    var lo: u32 = 0;
    var hi: u32 = n_files;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (rows[mid].start <= pos) lo = mid else hi = mid;
    }
    return lo;
}

fn sais(comptime T: type, gpa: Allocator, s: []const T, sa: []u32, k: usize) !void {
    const n = s.len;
    if (n == 1) {
        sa[0] = 0;
        return;
    }
    var stype = try std.DynamicBitSetUnmanaged.initEmpty(gpa, n);
    defer stype.deinit(gpa);
    stype.set(n - 1);
    var i: usize = n - 1;
    while (i > 0) {
        i -= 1;
        if (s[i] < s[i + 1] or (s[i] == s[i + 1] and stype.isSet(i + 1))) stype.set(i);
    }
    const bkt = try gpa.alloc(u32, k);
    defer gpa.free(bkt);

    const ctx: Sais(T) = .{ .s = s, .sa = sa, .t = &stype, .bkt = bkt };

    ctx.bucketEnds();
    @memset(sa, empty);
    for (1..n) |p| if (ctx.isLms(p)) {
        bkt[s[p]] -= 1;
        sa[bkt[s[p]]] = @intCast(p);
    };
    ctx.induce();

    var n1: usize = 0;
    for (0..n) |r| if (ctx.isLms(sa[r])) {
        sa[n1] = sa[r];
        n1 += 1;
    };
    @memset(sa[n1..], empty);
    var name: u32 = 0;
    var prev: u32 = empty;
    for (0..n1) |r| {
        const pos = sa[r];
        if (prev == empty or !ctx.sameLms(prev, pos)) {
            name += 1;
            prev = pos;
        }
        sa[n1 + pos / 2] = name - 1;
    }
    var j: usize = n;
    var r: usize = n;
    while (r > n1) {
        r -= 1;
        if (sa[r] != empty) {
            j -= 1;
            sa[j] = sa[r];
        }
    }

    const s1 = sa[n - n1 ..];
    const sa1 = sa[0..n1];
    if (name < n1) {
        try sais(u32, gpa, s1, sa1, name);
    } else {
        for (s1, 0..) |c, q| sa1[c] = @intCast(q);
    }

    j = 0;
    for (1..n) |p| if (ctx.isLms(p)) {
        s1[j] = @intCast(p);
        j += 1;
    };
    for (sa1) |*v| v.* = s1[v.*];
    @memset(sa[n1..], empty);
    ctx.bucketEnds();
    r = n1;
    while (r > 0) {
        r -= 1;
        const p = sa[r];
        sa[r] = empty;
        bkt[s[p]] -= 1;
        sa[bkt[s[p]]] = p;
    }
    ctx.induce();
}

fn Sais(comptime T: type) type {
    return struct {
        s: []const T,
        sa: []u32,
        t: *const std.DynamicBitSetUnmanaged,
        bkt: []u32,

        const Self = @This();

        fn isLms(c: Self, p: usize) bool {
            return p != empty and p > 0 and c.t.isSet(p) and !c.t.isSet(p - 1);
        }

        fn sameLms(c: Self, a: u32, b: u32) bool {
            var d: usize = 0;
            while (true) : (d += 1) {
                if (c.s[a + d] != c.s[b + d] or c.t.isSet(a + d) != c.t.isSet(b + d)) return false;
                if (d > 0 and (c.isLms(a + d) or c.isLms(b + d))) return c.isLms(a + d) and c.isLms(b + d);
            }
        }

        fn counts(c: Self) void {
            @memset(c.bkt, 0);
            for (c.s) |ch| c.bkt[ch] += 1;
        }

        fn bucketEnds(c: Self) void {
            c.counts();
            var sum: u32 = 0;
            for (c.bkt) |*b| {
                sum += b.*;
                b.* = sum;
            }
        }

        fn bucketStarts(c: Self) void {
            c.counts();
            var sum: u32 = 0;
            for (c.bkt) |*b| {
                const v = b.*;
                b.* = sum;
                sum += v;
            }
        }

        fn induce(c: Self) void {
            const n = c.s.len;
            c.bucketStarts();
            for (0..n) |r| {
                const p = c.sa[r];
                if (p == empty or p == 0) continue;
                const q = p - 1;
                if (!c.t.isSet(q)) {
                    c.sa[c.bkt[c.s[q]]] = q;
                    c.bkt[c.s[q]] += 1;
                }
            }
            c.bucketEnds();
            var r: usize = n;
            while (r > 0) {
                r -= 1;
                const p = c.sa[r];
                if (p == empty or p == 0) continue;
                const q = p - 1;
                if (c.t.isSet(q)) {
                    c.bkt[c.s[q]] -= 1;
                    c.sa[c.bkt[c.s[q]]] = q;
                }
            }
        }
    };
}

pub const Wavelet = struct {
    levels: u32,
    lines_per_level: u64,
    coarse_per_level: u64,
    zeros: []const u32,
    lines: []const Line,
    coarse: []const u64,

    fn rank1(wm: *const Wavelet, l: usize, i: u32) u32 {
        const line = &wm.lines[l * wm.lines_per_level + i / line_bits];
        const at = i % line_bits;
        var c: u64 = line.before;
        const full = at / 64;
        for (line.bits[0..full]) |word| c += @popCount(word);
        const mask = (@as(u64, 1) << @intCast(at % 64)) - 1;
        if (full < 7) c += @popCount(line.bits[full] & mask);
        return @intCast(c);
    }

    fn select(wm: *const Wavelet, l: usize, bit: u1, k: u32) u32 {
        const lc = wm.coarse[l * wm.coarse_per_level ..][0..wm.coarse_per_level];
        const ll = wm.lines[l * wm.lines_per_level ..][0..wm.lines_per_level];
        var lo: usize = 0;
        var hi: usize = lc.len;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            const before: u64 = if (bit == 1) lc[mid] else mid * coarse_step * line_bits - lc[mid];
            if (before <= k) lo = mid else hi = mid;
        }
        var a: usize = lo * coarse_step;
        var b: usize = @min(a + coarse_step, ll.len);
        while (b - a > 1) {
            const mid = a + (b - a) / 2;
            const before: u64 = if (bit == 1) ll[mid].before else mid * line_bits - ll[mid].before;
            if (before <= k) a = mid else b = mid;
        }
        const line = &ll[a];
        var left: u64 = k - if (bit == 1) line.before else a * line_bits - line.before;
        for (line.bits, 0..) |raw, wi| {
            const word = if (bit == 1) raw else ~raw;
            const pc: u64 = @popCount(word);
            if (left < pc) {
                var x = word;
                while (left > 0) : (left -= 1) x &= x - 1;
                return @intCast(a * line_bits + wi * 64 + @ctz(x));
            }
            left -= pc;
        }
        unreachable;
    }

    fn countBelow(wm: *const Wavelet, s0: u32, e0: u32, x: u64) u32 {
        var s = s0;
        var e = e0;
        var below: u32 = 0;
        for (0..wm.levels) |l| {
            const s1 = wm.rank1(l, s);
            const e1 = wm.rank1(l, e);
            if ((x >> @intCast(wm.levels - 1 - l)) & 1 == 1) {
                below += (e - s) - (e1 - s1);
                s = wm.zeros[l] + s1;
                e = wm.zeros[l] + e1;
            } else {
                s -= s1;
                e -= e1;
            }
        }
        return below;
    }

    fn up(wm: *const Wavelet, value: u32, leaf: u32, j: u32) u32 {
        var p = leaf + j;
        var l: usize = wm.levels;
        while (l > 0) {
            l -= 1;
            const bit: u1 = @intCast((value >> @intCast(wm.levels - 1 - l)) & 1);
            p = if (bit == 1) wm.select(l, 1, p - wm.zeros[l]) else wm.select(l, 0, p);
        }
        return p;
    }
};

pub const FileHits = struct { file: u32, count: u32, leaf: u32 };

const Node = struct {
    count: u32,
    level: u32,
    s: u32,
    value: u32,

    fn before(a: Node, b: Node, levels: u32) bool {
        if (a.count != b.count) return a.count > b.count;
        return (@as(u64, a.value) << @intCast(levels - a.level)) < (@as(u64, b.value) << @intCast(levels - b.level));
    }
};

pub const Index = struct {
    memory: []align(std.heap.page_size_min) u8,
    backing: Backing,
    h: *const Header,
    text: []const u8,
    ends: []const u64,
    orig: []const u8,
    sa: []const u32,
    rows: []const FileRow,
    paths: []const u8,
    lines: []const u32,
    olines: []const u32,
    stamps: []const Stamp,
    owner: Wavelet,
    prev: Wavelet,

    pub const Backing = union(enum) {
        mapped: struct { map: Io.File.MemoryMap, file: Io.File },
        owned: Allocator,
    };

    pub fn open(io: Io, file_path: []const u8) !Index {
        var file = try Io.Dir.cwd().openFile(io, file_path, .{});
        errdefer file.close(io);
        const len = try file.length(io);
        if (len < @sizeOf(Header)) return error.NotAnEmetFile;
        var map = try file.createMemoryMap(io, .{ .len = @intCast(len), .protection = .{ .read = true, .write = false } });
        errdefer map.destroy(io);
        return over(map.memory, .{ .mapped = .{ .map = map, .file = file } });
    }

    pub fn over(m: []align(std.heap.page_size_min) u8, backing: Backing) !Index {
        if (m.len < @sizeOf(Header)) return error.NotAnEmetFile;
        const h: *const Header = @ptrCast(m.ptr);
        if (!std.mem.eql(u8, &h.magic, &magic) or h.size != m.len) return error.NotAnEmetFile;
        return .{
            .memory = m,
            .backing = backing,
            .h = h,
            .text = m[h.off_text..][0..h.n],
            .ends = section(u64, m, h.off_ends, endWords(h.n)),
            .orig = m[h.off_orig..][0..h.n_orig],
            .sa = section(u32, m, h.off_sa, h.n),
            .rows = section(FileRow, m, h.off_files, h.n_files + 1),
            .paths = m[h.off_paths..][0..h.paths_len],
            .lines = section(u32, m, h.off_lines, h.n_lines),
            .olines = section(u32, m, h.off_olines, h.n_lines),
            .stamps = section(Stamp, m, h.off_stamps, h.n_files),
            .owner = wavelet(m, h.owner, h.n),
            .prev = wavelet(m, h.prev, h.n),
        };
    }

    pub fn warm(ix: *const Index, cancel: *const std.atomic.Value(bool)) void {
        const m = ix.memory;
        var sum: u8 = 0;
        var i: usize = 0;
        while (i < m.len and !cancel.load(.monotonic)) : (i += std.heap.pageSize()) sum +%= @as(*const volatile u8, @ptrCast(&m[i])).*;
        std.mem.doNotOptimizeAway(sum);
    }

    pub fn close(ix: *Index, io: Io) void {
        switch (ix.backing) {
            .mapped => |*mapped| {
                mapped.map.destroy(io);
                mapped.file.close(io);
            },
            .owned => |gpa| gpa.free(ix.memory),
        }
    }

    fn section(comptime T: type, m: []align(std.heap.page_size_min) u8, off: u64, count: u64) []const T {
        const p: [*]const T = @ptrCast(@alignCast(m.ptr + off));
        return p[0..count];
    }

    fn wavelet(m: []align(std.heap.page_size_min) u8, p: WaveletPlace, n: u64) Wavelet {
        return .{
            .levels = @intCast(p.levels),
            .lines_per_level = linesFor(n),
            .coarse_per_level = coarseFor(n),
            .zeros = section(u32, m, p.off_zeros, p.levels),
            .lines = section(Line, m, p.off_lines, linesFor(n) * p.levels),
            .coarse = section(u64, m, p.off_coarse, coarseFor(n) * p.levels),
        };
    }

    pub fn path(ix: *const Index, f: u32) []const u8 {
        const r = ix.rows[f];
        return ix.paths[r.path_off..][0..r.path_len];
    }

    pub fn isBinary(ix: *const Index, f: u32) bool {
        return f >= ix.h.n_text;
    }

    pub fn lookup(ix: *const Index, p: []const u8) ?u32 {
        return ix.seek(0, ix.h.n_text, p) orelse ix.seek(ix.h.n_text, ix.h.n_files, p);
    }

    fn seek(ix: *const Index, first: u32, last: u32, p: []const u8) ?u32 {
        var lo = first;
        var hi = last;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, ix.path(mid), p)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return mid,
            }
        }
        return null;
    }

    pub fn range(ix: *const Index, pattern: []const u8) [2]u32 {
        const n: u32 = @intCast(ix.h.n);
        var lo: u32 = 0;
        var hi: u32 = n;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (ix.order(ix.sa[mid], pattern) < 0) lo = mid + 1 else hi = mid;
        }
        const first = lo;
        hi = n;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (ix.order(ix.sa[mid], pattern) <= 0) lo = mid + 1 else hi = mid;
        }
        return .{ first, lo };
    }

    inline fn order(ix: *const Index, pos: u32, pattern: []const u8) i32 {
        const lim = ix.untilEnd(pos, pattern.len);
        for (ix.text[pos..][0..lim], pattern[0..lim]) |a, b| {
            if (a != b) return if (a < b) -1 else 1;
        }
        return if (lim < pattern.len) -1 else 0;
    }

    inline fn untilEnd(ix: *const Index, pos: u32, m: usize) usize {
        var wi: usize = pos / 64;
        var word = ix.ends[wi] & (~@as(u64, 0) << @intCast(pos % 64));
        while (word == 0) {
            wi += 1;
            if (wi * 64 - pos >= m) return m;
            word = ix.ends[wi];
        }
        return @min(m, wi * 64 + @ctz(word) - pos);
    }

    pub fn fileCount(ix: *const Index, lo: u32, hi: u32) u32 {
        return ix.prev.countBelow(lo, hi, @as(u64, lo) + 1);
    }

    pub const Tally = struct { hits: u32 = 0, files: u32 = 0 };

    pub fn tally(ix: *const Index, lo: u32, hi: u32, files: []const u32) Tally {
        var sum: Tally = .{};
        ix.tallyUnder(0, lo, hi, files, &sum);
        return sum;
    }

    fn tallyUnder(ix: *const Index, l: usize, s: u32, e: u32, files: []const u32, sum: *Tally) void {
        if (files.len == 0 or s == e) return;
        const wm = &ix.owner;
        if (l == wm.levels) {
            sum.hits += e - s;
            sum.files += 1;
            return;
        }
        const shift: u5 = @intCast(wm.levels - 1 - l);
        var k: usize = 0;
        while (k < files.len and (files[k] >> shift) & 1 == 0) k += 1;
        const s1 = wm.rank1(l, s);
        const e1 = wm.rank1(l, e);
        ix.tallyUnder(l + 1, s - s1, e - e1, files[0..k], sum);
        ix.tallyUnder(l + 1, wm.zeros[l] + s1, wm.zeros[l] + e1, files[k..], sum);
    }

    pub fn firstFiles(ix: *const Index, lo: u32, hi: u32, skip: []const u64, budget: u32, out: []FileHits) usize {
        var len: usize = 0;
        var left = budget;
        ix.walk(0, lo, hi, 0, skip, out, &len, &left);
        return len;
    }

    fn walk(ix: *const Index, l: usize, s: u32, e: u32, value: u32, skip: []const u64, out: []FileHits, len: *usize, left: *u32) void {
        if (s == e or left.* == 0 or len.* == out.len) return;
        const wm = &ix.owner;
        if (l == wm.levels) {
            if (skipped(skip, value)) return;
            out[len.*] = .{ .file = value, .count = e - s, .leaf = s };
            len.* += 1;
            left.* -|= e - s;
            return;
        }
        const s1 = wm.rank1(l, s);
        const e1 = wm.rank1(l, e);
        ix.walk(l + 1, s - s1, e - e1, value << 1, skip, out, len, left);
        ix.walk(l + 1, wm.zeros[l] + s1, wm.zeros[l] + e1, (value << 1) | 1, skip, out, len, left);
    }

    pub const Heaviest = struct { text: usize = 0, binary: usize = 0 };

    pub fn topFiles(ix: *const Index, lo: u32, hi: u32, skip: []const u64, heap: []Node, out: []FileHits, bin: []FileHits) Heaviest {
        const wm = &ix.owner;
        const L = wm.levels;
        var hn: usize = 0;
        var len: usize = 0;
        var nb: usize = 0;
        if (lo == hi) return .{};
        heapPush(heap, &hn, .{ .count = hi - lo, .level = 0, .s = lo, .value = 0 }, L);
        while (hn > 0 and len < out.len) {
            const top = heapPop(heap, &hn, L);
            if (top.level == L) {
                const fh: FileHits = .{ .file = top.value, .count = top.count, .leaf = top.s };
                if (skipped(skip, fh.file)) continue;
                if (!ix.isBinary(fh.file)) {
                    out[len] = fh;
                    len += 1;
                } else if (nb < bin.len) {
                    bin[nb] = fh;
                    nb += 1;
                }
                continue;
            }
            if (hn + 2 > heap.len) break;
            const l = top.level;
            const e = top.s + top.count;
            const s1 = wm.rank1(l, top.s);
            const e1 = wm.rank1(l, e);
            const zs = top.s - s1;
            const ze = e - e1;
            if (ze > zs) heapPush(heap, &hn, .{ .count = ze - zs, .level = l + 1, .s = zs, .value = top.value << 1 }, L);
            if (e1 > s1) heapPush(heap, &hn, .{ .count = e1 - s1, .level = l + 1, .s = wm.zeros[l] + s1, .value = (top.value << 1) | 1 }, L);
        }
        return .{ .text = len, .binary = nb };
    }

    pub fn hitRank(ix: *const Index, fh: FileHits, j: u32) u32 {
        return ix.owner.up(fh.file, fh.leaf, j);
    }

    pub const Place = struct { file: u32, line: u32, col: u32, text: []const u8 };

    pub fn place(ix: *const Index, f: u32, pos: u32) Place {
        const row = ix.rows[f];
        const after = ix.rows[f + 1].first_line;
        var lo: u32 = row.first_line;
        var hi: u32 = after;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (ix.lines[mid] <= pos) lo = mid else hi = mid;
        }
        const ostart = ix.olines[lo];
        var oend: u32 = if (lo + 1 < after) ix.olines[lo + 1] else row.ostart + row.olen;
        while (oend > ostart and (ix.orig[oend - 1] == '\n' or ix.orig[oend - 1] == '\r')) oend -= 1;
        var col: u32 = 1;
        for (ix.text[ix.lines[lo]..pos]) |b| {
            if (b & 0xC0 != 0x80) col += 1;
        }
        return .{ .file = f, .line = lo - row.first_line + 1, .col = col, .text = ix.orig[ostart..oend] };
    }
};

fn skipped(skip: []const u64, f: u32) bool {
    return skip.len != 0 and (skip[f / 64] >> @intCast(f % 64)) & 1 != 0;
}

fn heapPush(heap: []Node, n: *usize, node: Node, levels: u32) void {
    var i = n.*;
    n.* += 1;
    heap[i] = node;
    while (i > 0) {
        const parent = (i - 1) / 2;
        if (!Node.before(heap[i], heap[parent], levels)) break;
        std.mem.swap(Node, &heap[i], &heap[parent]);
        i = parent;
    }
}

fn heapPop(heap: []Node, n: *usize, levels: u32) Node {
    const top = heap[0];
    n.* -= 1;
    heap[0] = heap[n.*];
    var i: usize = 0;
    while (true) {
        const a = 2 * i + 1;
        const b = a + 1;
        var best = i;
        if (a < n.* and Node.before(heap[a], heap[best], levels)) best = a;
        if (b < n.* and Node.before(heap[b], heap[best], levels)) best = b;
        if (best == i) break;
        std.mem.swap(Node, &heap[i], &heap[best]);
        i = best;
    }
    return top;
}

pub const Answer = struct {
    hits: u32,
    files: u32,
    text: []const u8,
};

const top_files = 20;
const shown_hits = 40;
const shown_line = 160;

pub const View = struct {
    base: *const Index,
    overlay: ?*const Index = null,
    hidden: []const u32 = &.{},
    hidden_bits: []const u64 = &.{},
};

const Found = struct {
    ix: *const Index,
    fh: FileHits,

    fn path(f: Found) []const u8 {
        return f.ix.path(f.fh.file);
    }

    fn binary(f: Found) bool {
        return f.ix.isBinary(f.fh.file);
    }

    fn earlier(_: void, a: Found, b: Found) bool {
        if (a.binary() != b.binary()) return b.binary();
        return lessPath({}, a.path(), b.path());
    }

    fn heavier(_: void, a: Found, b: Found) bool {
        if (a.fh.count != b.fh.count) return a.fh.count > b.fh.count;
        return earlier({}, a, b);
    }
};

const Span = struct { ix: *const Index, lo: u32, hi: u32, skip: []const u64 };

/// Optional stage profiler for the find hot path. When `profile_sink` is null
/// (the default, and always so in production) search() takes a handful of
/// branch-predicted no-ops; it is only set by the `find profile` CLI command.
pub const Profile = struct {
    io: Io,
    range_ns: u64 = 0,
    collect_ns: u64 = 0,
    sort_ns: u64 = 0,
    format_ns: u64 = 0,
};

pub threadlocal var profile_sink: ?*Profile = null;

fn lapNs(p: *Profile, last: *Io.Timestamp) u64 {
    const now = Io.Timestamp.now(p.io, .awake);
    const ns: u64 = @intCast(last.durationTo(now).nanoseconds);
    last.* = now;
    return ns;
}

pub const Scratch = struct {
    heap: [4096]Node = undefined,
    top: [top_files]FileHits = undefined,
    bin: [top_files]FileHits = undefined,
    first: [shown_hits]FileHits = undefined,
    heavy: [2 * top_files]Found = undefined,
    heavy_bin: [2 * top_files]Found = undefined,
    early: [2 * shown_hits]Found = undefined,
    positions: [shown_hits]u32 = undefined,
    pattern: [2 * max_pattern]u8 = undefined,
    out: [64 << 10]u8 = undefined,
};

fn gather(dst: []Found, len: *usize, ix: *const Index, src: []const FileHits) void {
    for (src) |fh| {
        dst[len.*] = .{ .ix = ix, .fh = fh };
        len.* += 1;
    }
}

pub fn search(view: View, sc: *Scratch, pattern: []const u8) !Answer {
    var tlast: Io.Timestamp = if (profile_sink) |p| Io.Timestamp.now(p.io, .awake) else undefined;
    var w = Io.Writer.fixed(&sc.out);
    if (pattern.len == 0 or pattern.len > max_pattern) {
        try w.print("no hits: a pattern holds 1 to {d} bytes\n", .{max_pattern});
        return .{ .hits = 0, .files = 0, .text = w.buffered() };
    }
    const folded = sc.pattern[0..foldInto(&sc.pattern, pattern)];
    var spans: [2]Span = undefined;
    var n_spans: usize = 0;
    var hits: u32 = 0;
    var files: u32 = 0;
    for ([_]?*const Index{ view.base, view.overlay }, [_][]const u64{ view.hidden_bits, &.{} }) |layer, skip| {
        const ix = layer orelse continue;
        const r = ix.range(folded);
        if (r[0] == r[1]) continue;
        hits += r[1] - r[0];
        files += ix.fileCount(r[0], r[1]);
        if (skip.len != 0) {
            const gone = ix.tally(r[0], r[1], view.hidden);
            hits -= gone.hits;
            files -= gone.files;
        }
        spans[n_spans] = .{ .ix = ix, .lo = r[0], .hi = r[1], .skip = skip };
        n_spans += 1;
    }
    if (profile_sink) |p| {
        p.range_ns = lapNs(p, &tlast);
    }
    try w.print("{d} hits in {d} files\n", .{ hits, files });
    if (hits == 0) return .{ .hits = 0, .files = 0, .text = w.buffered() };

    var n_heavy: usize = 0;
    var n_heavy_bin: usize = 0;
    var n_early: usize = 0;
    for (spans[0..n_spans]) |sp| {
        const got = sp.ix.topFiles(sp.lo, sp.hi, sp.skip, &sc.heap, &sc.top, &sc.bin);
        gather(&sc.heavy, &n_heavy, sp.ix, sc.top[0..got.text]);
        gather(&sc.heavy_bin, &n_heavy_bin, sp.ix, sc.bin[0..got.binary]);
        const n_first = sp.ix.firstFiles(sp.lo, sp.hi, sp.skip, shown_hits, &sc.first);
        gather(&sc.early, &n_early, sp.ix, sc.first[0..n_first]);
    }
    if (profile_sink) |p| {
        p.collect_ns = lapNs(p, &tlast);
    }
    std.mem.sort(Found, sc.heavy[0..n_heavy], {}, Found.heavier);
    std.mem.sort(Found, sc.heavy_bin[0..n_heavy_bin], {}, Found.heavier);
    std.mem.sort(Found, sc.early[0..n_early], {}, Found.earlier);
    if (profile_sink) |p| {
        p.sort_ns = lapNs(p, &tlast);
    }

    try w.print("\nmost hits:\n", .{});
    const n_text = @min(n_heavy, top_files);
    const n_bin = @min(n_heavy_bin, top_files - n_text);
    for (sc.heavy[0..n_text]) |f| try w.print("  {d:>7}  {s}\n", .{ f.fh.count, f.path() });
    for (sc.heavy_bin[0..n_bin]) |f| try w.print("  {d:>7}  {s} (binary)\n", .{ f.fh.count, f.path() });

    try w.print("\nfirst hits:\n", .{});
    var shown: usize = 0;
    for (sc.early[0..n_early]) |f| {
        if (shown == shown_hits) break;
        const take = @min(f.fh.count, @as(u32, @intCast(shown_hits - shown)));
        const ps = sc.positions[0..take];
        for (ps, 0..) |*p, j| p.* = f.ix.sa[f.ix.hitRank(f.fh, @intCast(j))];
        std.mem.sort(u32, ps, {}, std.sort.asc(u32));
        const fpath = f.path();
        for (ps) |p| {
            const pl = f.ix.place(f.fh.file, p);
            var cut: usize = @min(pl.text.len, shown_line);
            while (cut > 0 and cut < pl.text.len and pl.text[cut] & 0xC0 == 0x80) cut -= 1;
            try w.print("{s}:{d}:{d}: {s}\n", .{ fpath, pl.line, pl.col, std.mem.trim(u8, pl.text[0..cut], " \t") });
        }
        shown += take;
    }
    if (hits > shown) try w.print("... and {d} more\n", .{hits - shown});
    if (profile_sink) |p| {
        p.format_ns = lapNs(p, &tlast);
    }
    return .{ .hits = hits, .files = files, .text = w.buffered() };
}

pub const Priority = enum(i32) { background = 0x10000, foreground = 0x20000, normal = 0, critical = 15 };

pub fn setPriority(priority: Priority) void {
    if (builtin.os.tag != .windows) return;
    _ = SetThreadPriority(@ptrFromInt(std.math.maxInt(usize) - 1), @intFromEnum(priority));
}

extern "kernel32" fn SetThreadPriority(thread: std.os.windows.HANDLE, priority: i32) callconv(.winapi) std.os.windows.BOOL;
