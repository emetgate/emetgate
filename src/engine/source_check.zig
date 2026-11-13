//! The per-language source check every gated write runs after tree-sitter reparses the new
//! text. tree-sitter recovers from some errors without an ERROR or MISSING node (Python's
//! indentation rules are one), so a language whose compiler refuses more than its grammar
//! does names a check in its profile. A refusal is kept here for the reply's fix line.
const std = @import("std");

pub const Fault = struct {
    /// 1-based line of the first offending line.
    line: u32,
    /// What the language's own tool would say, as a static string.
    reason: []const u8,
};

pub const Check = *const fn (source: []const u8) ?Fault;

threadlocal var last_fault: ?Fault = null;
threadlocal var last_file_buffer: [512]u8 = undefined;
threadlocal var last_file_len: usize = 0;

/// Records the fault for the reply and returns the error a gated write refuses with.
pub fn refuse(rel: []const u8, fault: Fault) error{SyntaxCheckFailed} {
    last_fault = fault;
    last_file_len = @min(rel.len, last_file_buffer.len);
    @memcpy(last_file_buffer[0..last_file_len], rel[0..last_file_len]);
    return error.SyntaxCheckFailed;
}

/// Writes the fix line for the last refusal into `buffer` and forgets it.
pub fn takeFix(buffer: []u8) ?[]const u8 {
    const fault = last_fault orelse return null;
    last_fault = null;
    return std.fmt.bufPrint(buffer, "{s} line {d}: {s}; the file would not compile, so nothing was written. Fix the indentation of that line (and the lines after it) and resend", .{ last_file_buffer[0..last_file_len], fault.line, fault.reason }) catch null;
}

/// The check fails `after` only when `base` (the file before the edit, null for a new
/// file) passed it, so an edit to a file that already failed is not blocked by it.
pub fn judge(check: Check, base: ?[]const u8, after: []const u8) ?Fault {
    const fault = check(after) orelse return null;
    if (base) |b| if (check(b) != null) return null;
    return fault;
}
