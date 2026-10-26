const std = @import("std");
const rules_tui = @import("rules_tui.zig");
const rule_catalog = @import("rule_catalog.zig");
const rule_command = @import("rule_command.zig");
const console_raw = @import("../platform/console_raw.zig");
const memory = @import("../platform/memory.zig");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

// `emetgate rules`: the interactive, zero-syntax way to pick which rules the ledger
// enforces. It renders the shared rule catalog as a raw-mode checklist, pre-checks
// the rules already enforced, and on save diffs the checked set against the ledger
// and writes the adds/forgets through the same `rule_command` path `/rule pick` uses.
// The checklist logic is in rules_tui.zig; the Windows console I/O is in
// console_raw.zig; this file is the thin driver between them.

pub fn run(gpa: Allocator, io: std.Io, root_abs: []const u8, out: *Writer, err_out: *Writer) !void {
    var ed = rules_tui.Editor.init();
    {
        const recalled = try memory.recall(gpa, io, root_abs);
        defer recalled.deinit();
        rules_tui.precheck(&ed.state, recalled.decisions);
        ed.seed(); // copy seeded paths into the editor's own buffers before the arena dies
    }

    const handles = console_raw.Handles.get();
    if (!console_raw.isTty(handles)) {
        try rule_catalog.render(out);
        try out.writeAll(
            \\
            \\not a terminal: run `emetgate rules` in an interactive terminal to toggle
            \\these with the keyboard, or use `/rule pick <numbers>` directly.
            \\
        );
        return;
    }

    switch (try interact(&ed, handles, out)) {
        .run => unreachable,
        .cancel => try out.writeAll("rules: cancelled; nothing written.\n"),
        .save => try applySave(gpa, io, root_abs, &ed, out, err_out),
    }
}

// Own the console for the duration of the loop and hand it back on every exit path.
fn interact(ed: *rules_tui.Editor, handles: console_raw.Handles, out: *Writer) !rules_tui.Outcome {
    const raw = try console_raw.Raw.enter(handles);
    defer raw.restore();
    defer out.writeAll(rules_tui.esc.show_cursor) catch {};
    defer out.flush() catch {};

    while (true) {
        try rules_tui.render(out, &ed.state, true, ed.editing());
        try out.flush();
        const key = try raw.readKey();
        switch (ed.feed(key)) {
            .run => {},
            else => |outcome| {
                try out.writeAll(rules_tui.esc.clear_screen ++ rules_tui.esc.show_cursor);
                try out.flush();
                return outcome;
            },
        }
    }
}

// Diff the final checked set against a fresh recall and apply it. Forgets go first so
// a rule whose scope changed drops its old scope before the new one is added.
fn applySave(gpa: Allocator, io: std.Io, root_abs: []const u8, ed: *rules_tui.Editor, out: *Writer, err_out: *Writer) !void {
    const recalled = try memory.recall(gpa, io, root_abs);
    defer recalled.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var adds: std.ArrayList(rules_tui.Add) = .empty;
    var forgets: std.ArrayList(rules_tui.Forget) = .empty;
    try rules_tui.planChanges(&ed.state, recalled.decisions, &adds, &forgets, arena);

    if (adds.items.len == 0 and forgets.items.len == 0) {
        try out.writeAll("rules: no changes to save.\n");
        return;
    }

    var applied_forgets: usize = 0;
    for (forgets.items) |f| {
        rule_command.runAs(.spoken, gpa, io, root_abs, .{ .forget = f.id }, out, err_out) catch |err| switch (err) {
            error.OutOfMemory, error.WriteFailed => return err,
            else => {
                try out.print("skip forget {s}: {t}\n", .{ f.id, err });
                continue;
            },
        };
        applied_forgets += 1;
    }

    var applied_adds: usize = 0;
    for (adds.items) |a| {
        const request: rule_command.Request = .{ .add = rule_catalog.decidedOf(a.entry, a.where) };
        rule_command.runAs(.spoken, gpa, io, root_abs, request, out, err_out) catch |err| switch (err) {
            error.OutOfMemory, error.WriteFailed => return err,
            else => {
                try out.print("skip add {d}: {t}\n", .{ a.entry.num, err });
                continue;
            },
        };
        applied_adds += 1;
    }

    try out.print("\nrules saved: {d} enforced, {d} forgotten.\n", .{ applied_adds, applied_forgets });
}
