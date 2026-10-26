const std = @import("std");
const rule_catalog = @import("rule_catalog.zig");
const rule_command = @import("rule_command.zig");
const memory = @import("../platform/memory.zig");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const Entry = rule_catalog.Entry;
const Decision = memory.Decision;

// The `emetgate rules` checklist is a pure state machine over the shared rule
// catalog plus a global scope field, driven by key events the raw-mode I/O layer
// turns into `Key` values. Everything the terminal shows and everything the save
// writes to the ledger is derived here by pure functions so it can be unit-tested
// without touching a console. The raw-mode layer (platform/console_raw.zig) and
// the driver (rules_command.zig) stay thin around this.

pub const max_rows = rule_catalog.catalog.len;

// A key the driver feeds the state machine. Arrows move the cursor, space toggles
// the row, enter saves, tab changes scope, esc/q cancels. `char` carries a typed
// character for the inline path fields; `backspace` edits them.
pub const Key = union(enum) {
    up,
    down,
    toggle,
    save,
    scope,
    cancel,
    char: u21,
    backspace,
    other,
};

// The global scope for the scopable code rules: the whole repository, or a single
// path. An empty path reads as whole-repo so a half-typed field never scopes.
pub const Scope = union(enum) {
    whole_repo,
    path: []const u8,

    pub fn whereOrNull(self: Scope) ?[]const u8 {
        return switch (self) {
            .whole_repo => null,
            .path => |p| if (p.len == 0) null else p,
        };
    }
};

pub const Row = struct {
    entry: Entry,
    checked: bool = false,
    // Only meaningful for a `needs_path` row (the freeze rule): its own path, which
    // the batch scope never touches. Null until the user supplies one.
    path: ?[]const u8 = null,
};

// How many checklist rows the viewport shows when the terminal height is unknown.
// The catalog is taller than most terminals, so the list scrolls (see `top`).
pub const default_viewport = 20;

pub const State = struct {
    rows: [max_rows]Row = undefined,
    len: usize = 0,
    cursor: usize = 0,
    scope: Scope = .whole_repo,
    // The scrolling viewport: `top` is the first visible row index and `viewport`
    // is how many rows fit. The cursor is always kept inside [top, top+viewport).
    top: usize = 0,
    viewport: usize = default_viewport,

    pub fn init() State {
        var s: State = .{};
        for (rule_catalog.catalog, 0..) |entry, i| s.rows[i] = .{ .entry = entry };
        s.len = rule_catalog.catalog.len;
        return s;
    }

    pub fn items(self: *const State) []const Row {
        return self.rows[0..self.len];
    }

    pub fn current(self: *State) *Row {
        return &self.rows[self.cursor];
    }

    pub fn moveUp(self: *State) void {
        if (self.cursor > 0) self.cursor -= 1;
        self.keepCursorVisible();
    }

    pub fn moveDown(self: *State) void {
        if (self.cursor + 1 < self.len) self.cursor += 1;
        self.keepCursorVisible();
    }

    // Set how many rows fit on screen (at least one), then re-anchor the viewport so
    // the cursor stays visible. The driver derives this from the terminal height.
    pub fn setViewport(self: *State, rows: usize) void {
        self.viewport = if (rows < 1) 1 else rows;
        self.keepCursorVisible();
    }

    // Standard "keep the cursor in view" scroll: pull `top` down when the cursor
    // moves above it, push it up when the cursor moves past the bottom edge.
    fn keepCursorVisible(self: *State) void {
        if (self.cursor < self.top) {
            self.top = self.cursor;
        } else if (self.cursor >= self.top + self.viewport) {
            self.top = self.cursor + 1 - self.viewport;
        }
    }

    // The exclusive end of the visible window, clamped to the row count.
    pub fn visibleEnd(self: *const State) usize {
        return @min(self.top + self.viewport, self.len);
    }

    // The rows currently visible in the viewport.
    pub fn visible(self: *const State) []const Row {
        return self.rows[self.top..self.visibleEnd()];
    }

    pub fn toggle(self: *State) void {
        self.rows[self.cursor].checked = !self.rows[self.cursor].checked;
    }
};

fn rowIndex(num: u8) usize {
    // The catalog is laid out 1..N at indices 0..N-1.
    return num - 1;
}

// The scope that a row resolves to when saved: the freeze row carries its own path,
// the scopable code rules take the batch scope, and the message rules take none.
pub fn whereFor(row: Row, scope: Scope) ?[]const u8 {
    if (row.entry.needs_path) return row.path;
    if (row.entry.scopable) return scope.whereOrNull();
    return null;
}

fn sameWhere(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

// The catalog entry whose check a ledger decision carries, but only if the decision
// is an enforced rule. A decision is "catalog-managed" exactly when it was (or could
// have been) produced by picking this entry: same check, enforced. Advisory rules
// and rules whose check is not in the catalog are never claimed, so a rule the user
// wrote by hand is never pre-checked and never forgotten.
pub fn catalogManaged(d: Decision) ?Entry {
    if (!d.enforce) return null;
    const check = d.check orelse return null;
    for (rule_catalog.catalog) |entry| {
        if (std.mem.eql(u8, entry.check, check)) return entry;
    }
    return null;
}

// Pre-check the boxes for rules already enforced in the ledger, and seed the scope
// fields from them, so re-running the checklist shows the real current state.
pub fn precheck(state: *State, decisions: []const Decision) void {
    for (decisions) |d| {
        const entry = catalogManaged(d) orelse continue;
        var row = &state.rows[rowIndex(entry.num)];
        row.checked = true;
        if (entry.needs_path) {
            row.path = d.where;
        } else if (entry.scopable) {
            if (d.where) |w| state.scope = .{ .path = w };
        }
    }
}

pub const Add = struct { entry: Entry, where: ?[]const u8 };
pub const Forget = struct { id: []const u8, entry: Entry, where: ?[]const u8 };

pub const Changes = struct {
    adds: []const Add,
    forgets: []const Forget,
};

// A checked freeze row with no path yet cannot be added (frozen needs a path); it is
// simply ignored by the diff, exactly as `/rule pick 7` with no path is skipped.
fn addable(row: Row) bool {
    if (!row.checked) return false;
    if (row.entry.needs_path and row.path == null) return false;
    return true;
}

// Diff the checked set against the current ledger: ADD every checked rule not already
// enforced at its chosen scope, and FORGET every catalog-managed enforced rule no
// longer represented by a checked row at the same (check, scope). A scope change on a
// kept rule therefore forgets the old scope and adds the new one. Rules outside the
// catalog, and advisory rules, are never touched.
pub fn planChanges(
    state: *const State,
    decisions: []const Decision,
    adds: *std.ArrayList(Add),
    forgets: *std.ArrayList(Forget),
    gpa: Allocator,
) !void {
    for (state.items()) |row| {
        if (!addable(row)) continue;
        const w = whereFor(row, state.scope);
        var present = false;
        for (decisions) |d| {
            const e = catalogManaged(d) orelse continue;
            if (e.num == row.entry.num and sameWhere(d.where, w)) {
                present = true;
                break;
            }
        }
        if (!present) try adds.append(gpa, .{ .entry = row.entry, .where = w });
    }

    for (decisions) |d| {
        const e = catalogManaged(d) orelse continue;
        var kept = false;
        for (state.items()) |row| {
            if (!addable(row) or row.entry.num != e.num) continue;
            if (sameWhere(whereFor(row, state.scope), d.where)) {
                kept = true;
                break;
            }
        }
        if (!kept) try forgets.append(gpa, .{ .id = d.id, .entry = e, .where = d.where });
    }
}

// ANSI escapes for the raw-mode render. Kept here so the driver stays thin.
pub const esc = struct {
    pub const clear_screen = "\x1b[2J\x1b[H";
    pub const clear_line = "\x1b[2K";
    pub const hide_cursor = "\x1b[?25l";
    pub const show_cursor = "\x1b[?25h";
    pub const inverse = "\x1b[7m";
    pub const dim = "\x1b[2m";
    pub const reset = "\x1b[0m";
};

const everywhere = "whole repo";

fn scopeLabel(scope: Scope) []const u8 {
    return switch (scope) {
        .whole_repo => everywhere,
        .path => |p| if (p.len == 0) everywhere else p,
    };
}

// Render the checklist. `ansi` adds color/cursor control for a real terminal; with
// it off the output is plain text the unit tests assert on. `editing` highlights the
// field the driver is currently typing into (none, the scope, or a freeze path row).
pub const Editing = union(enum) { none, scope, path: usize };

pub fn render(out: *Writer, state: *const State, ansi: bool, editing: Editing) !void {
    if (ansi) try out.writeAll(esc.clear_screen ++ esc.hide_cursor);
    // ASCII-only so it renders on any console code page (no UTF-8 CP dependency).
    try out.writeAll("emetgate rules  -  Space toggle, up/down (or k/j) move, Tab scope, Enter save, q cancel\n");
    if (ansi) try out.writeAll("\r");

    // Only the visible window is drawn; a hint marks rows scrolled out of view. The
    // group starts empty so the first visible row always prints its group header,
    // even when the window opens in the middle of a group.
    if (state.top > 0) {
        if (ansi) try out.writeAll(esc.clear_line);
        try out.print("  ... {d} more above\n", .{state.top});
        if (ansi) try out.writeAll("\r");
    }
    var group: []const u8 = "";
    const end = state.visibleEnd();
    var i = state.top;
    while (i < end) : (i += 1) {
        const row = state.rows[i];
        if (!std.mem.eql(u8, group, row.entry.group)) {
            if (ansi) try out.writeAll(esc.clear_line);
            try out.print("\n{s}:\n", .{row.entry.group});
            if (ansi) try out.writeAll("\r");
            group = row.entry.group;
        }
        const on_cursor = i == state.cursor;
        if (ansi) {
            try out.writeAll(esc.clear_line);
            if (on_cursor) try out.writeAll(esc.inverse);
        }
        const box: []const u8 = if (row.checked) "[x]" else "[ ]";
        const marker: []const u8 = if (on_cursor) ">" else " ";
        try out.print("{s} {s} {s}{s}", .{ marker, box, row.entry.label, row.entry.lang.tag() });
        try writeRowScope(out, row, state.scope, editing, i);
        if (ansi and on_cursor) try out.writeAll(esc.reset);
        try out.writeAll("\n");
        if (ansi) try out.writeAll("\r");
    }
    const below = state.len - end;
    if (below > 0) {
        if (ansi) try out.writeAll(esc.clear_line);
        try out.print("  ... {d} more below\n", .{below});
        if (ansi) try out.writeAll("\r");
    }

    if (ansi) try out.writeAll(esc.clear_line);
    const scope_editing = editing == .scope;
    try out.print("\nscope (code rules): {s}{s}\n", .{ scopeLabel(state.scope), if (scope_editing) "_" else "" });
    if (ansi) try out.writeAll("\r");
}

fn writeRowScope(out: *Writer, row: Row, scope: Scope, editing: Editing, index: usize) !void {
    const editing_this = switch (editing) {
        .path => |p| p == index,
        else => false,
    };
    if (row.entry.needs_path) {
        if (editing_this) {
            try out.print("  (freeze path: {s}_)", .{row.path orelse ""});
        } else if (row.checked) {
            try out.print("  (in {s})", .{row.path orelse "?"});
        } else {
            try out.writeAll("  (needs a path)");
        }
        return;
    }
    if (row.entry.scopable and row.checked) {
        if (scope.whereOrNull()) |w| try out.print("  (in {s})", .{w});
    }
}

// ---------------------------------------------------------------------------
// The input reducer: a pure fold of key events over the checklist plus the inline
// text fields. The driver owns one Editor for the whole session, calls `feed` per
// key, re-renders, and acts on the returned Outcome. All path text lives in the
// Editor's own buffers so a scope slice is never clobbered by editing a freeze path.
// ---------------------------------------------------------------------------

pub const path_cap = 512;

pub const Mode = union(enum) { normal, scope_edit, path_edit: usize };

pub const Outcome = enum { run, save, cancel };

pub const Editor = struct {
    state: State,
    mode: Mode = .normal,
    scope_buf: [path_cap]u8 = undefined,
    scope_len: usize = 0,
    row_buf: [max_rows][path_cap]u8 = undefined,
    row_len: [max_rows]usize = [_]usize{0} ** max_rows,

    pub fn init() Editor {
        return .{ .state = State.init() };
    }

    // Copy the paths precheck seeded (which point into the recall arena) into the
    // Editor's own buffers and repoint the state slices at them, so later edits are
    // stable and the recall arena can be released.
    pub fn seed(self: *Editor) void {
        switch (self.state.scope) {
            .whole_repo => {},
            .path => |p| {
                const n = @min(p.len, path_cap);
                @memcpy(self.scope_buf[0..n], p[0..n]);
                self.scope_len = n;
            },
        }
        self.setScopeSlice();
        for (0..self.state.len) |i| {
            const row = &self.state.rows[i];
            if (row.path) |p| {
                const n = @min(p.len, path_cap);
                @memcpy(self.row_buf[i][0..n], p[0..n]);
                self.row_len[i] = n;
            }
            self.setRowSlice(i);
        }
    }

    fn setScopeSlice(self: *Editor) void {
        self.state.scope = if (self.scope_len == 0) .whole_repo else .{ .path = self.scope_buf[0..self.scope_len] };
    }

    fn setRowSlice(self: *Editor, i: usize) void {
        self.state.rows[i].path = if (self.row_len[i] == 0) null else self.row_buf[i][0..self.row_len[i]];
    }

    pub fn editing(self: *const Editor) Editing {
        return switch (self.mode) {
            .normal => .none,
            .scope_edit => .scope,
            .path_edit => |i| .{ .path = i },
        };
    }

    pub fn feed(self: *Editor, key: Key) Outcome {
        return switch (self.mode) {
            .normal => self.feedNormal(key),
            .scope_edit => self.feedScope(key),
            .path_edit => |i| self.feedPath(key, i),
        };
    }

    fn feedNormal(self: *Editor, key: Key) Outcome {
        switch (key) {
            .up => self.state.moveUp(),
            .down => self.state.moveDown(),
            .scope => self.mode = .scope_edit,
            .save => return .save,
            .cancel => return .cancel,
            .backspace, .other => {},
            .toggle => self.toggleCurrent(),
            .char => |c| {
                if (c == ' ') {
                    self.toggleCurrent();
                } else if (c == 'k' or c == 'K') {
                    self.state.moveUp(); // vim-style navigation
                } else if (c == 'j' or c == 'J') {
                    self.state.moveDown();
                } else if (c == 'q' or c == 'Q') {
                    return .cancel;
                }
            },
        }
        return .run;
    }

    // Toggling a freeze row on with no path yet drops straight into its path field.
    fn toggleCurrent(self: *Editor) void {
        self.state.toggle();
        const cur = self.state.cursor;
        const row = self.state.rows[cur];
        if (row.entry.needs_path and row.checked and self.row_len[cur] == 0) {
            self.mode = .{ .path_edit = cur };
        }
    }

    fn feedScope(self: *Editor, key: Key) Outcome {
        switch (key) {
            .save, .scope, .cancel => self.mode = .normal,
            .backspace => if (self.scope_len > 0) {
                self.scope_len -= 1;
            },
            .char => |c| appendByte(&self.scope_buf, &self.scope_len, c),
            .up, .down, .toggle, .other => {},
        }
        self.setScopeSlice();
        return .run;
    }

    fn feedPath(self: *Editor, key: Key, i: usize) Outcome {
        switch (key) {
            .save, .scope, .cancel => self.mode = .normal,
            .backspace => if (self.row_len[i] > 0) {
                self.row_len[i] -= 1;
            },
            .char => |c| appendByte(&self.row_buf[i], &self.row_len[i], c),
            .up, .down, .toggle, .other => {},
        }
        self.setRowSlice(i);
        return .run;
    }
};

fn appendByte(buf: []u8, len: *usize, c: u21) void {
    if (c < 0x20 or c > 0x7e) return; // printable ASCII only; paths are ASCII
    if (len.* >= buf.len) return;
    buf[len.*] = @intCast(c);
    len.* += 1;
}

// ---------------------------------------------------------------------------
// Tests: the pure state machine, the ledger diff, the scope resolution.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn checkOf(num: u8) []const u8 {
    return rule_catalog.find(num).?.check;
}

fn enforced(id: []const u8, num: u8, where: ?[]const u8) Decision {
    return .{
        .id = id,
        .scope = .project,
        .text = rule_catalog.find(num).?.label,
        .enforce = true,
        .check = checkOf(num),
        .status = .active,
        .ts = 0,
        .where = where,
    };
}

test "init builds one row per catalog entry, unchecked, cursor at top" {
    const s = State.init();
    try testing.expectEqual(rule_catalog.catalog.len, s.len);
    try testing.expectEqual(@as(usize, 0), s.cursor);
    for (s.items()) |row| try testing.expect(!row.checked);
    try testing.expectEqual(@as(u8, 1), s.rows[0].entry.num);
}

test "cursor moves within bounds and toggles the current row" {
    var s = State.init();
    s.moveUp();
    try testing.expectEqual(@as(usize, 0), s.cursor);
    s.moveDown();
    try testing.expectEqual(@as(usize, 1), s.cursor);
    s.toggle();
    try testing.expect(s.rows[1].checked);
    s.toggle();
    try testing.expect(!s.rows[1].checked);
    s.cursor = s.len - 1;
    s.moveDown();
    try testing.expectEqual(s.len - 1, s.cursor);
}

test "whereFor: scopable takes batch scope, message takes none, freeze takes its own path" {
    const scope: Scope = .{ .path = "app/" };
    const console = Row{ .entry = rule_catalog.find(1).? }; // scopable
    const msg = Row{ .entry = rule_catalog.find(26).? }; // message rule
    const freeze = Row{ .entry = rule_catalog.find(30).?, .path = "src/core" };
    try testing.expectEqualStrings("app/", whereFor(console, scope).?);
    try testing.expectEqual(@as(?[]const u8, null), whereFor(msg, scope));
    try testing.expectEqualStrings("src/core", whereFor(freeze, scope).?);
    try testing.expectEqual(@as(?[]const u8, null), whereFor(console, .whole_repo));
}

test "catalogManaged claims enforced catalog checks only" {
    try testing.expect(catalogManaged(enforced("m1", 1, null)) != null);
    var advisory = enforced("m2", 1, null);
    advisory.enforce = false;
    try testing.expectEqual(@as(?Entry, null), catalogManaged(advisory));
    var hand = enforced("m3", 1, null);
    hand.check = "forbid:mystuff";
    try testing.expectEqual(@as(?Entry, null), catalogManaged(hand));
    var nocheck = enforced("m4", 1, null);
    nocheck.check = null;
    try testing.expectEqual(@as(?Entry, null), catalogManaged(nocheck));
}

test "precheck marks enforced rules, seeds scope and freeze path" {
    var s = State.init();
    const decisions = [_]Decision{
        enforced("a", 1, "app/"),
        enforced("b", 26, null),
        enforced("c", 30, "src/core"),
    };
    precheck(&s, &decisions);
    try testing.expect(s.rows[0].checked);
    try testing.expect(s.rows[25].checked);
    try testing.expect(s.rows[29].checked);
    try testing.expect(!s.rows[1].checked);
    try testing.expectEqualStrings("app/", s.scope.path);
    try testing.expectEqualStrings("src/core", s.rows[29].path.?);
}

fn planOf(s: *const State, decisions: []const Decision) !struct { adds: std.ArrayList(Add), forgets: std.ArrayList(Forget) } {
    var adds: std.ArrayList(Add) = .empty;
    var forgets: std.ArrayList(Forget) = .empty;
    try planChanges(s, decisions, &adds, &forgets, testing.allocator);
    return .{ .adds = adds, .forgets = forgets };
}

test "planChanges: checking fresh rules on an empty ledger only adds" {
    var s = State.init();
    s.rows[0].checked = true; // 1
    s.rows[2].checked = true; // 3
    var plan = try planOf(&s, &.{});
    defer plan.adds.deinit(testing.allocator);
    defer plan.forgets.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), plan.adds.items.len);
    try testing.expectEqual(@as(usize, 0), plan.forgets.items.len);
    try testing.expectEqual(@as(u8, 1), plan.adds.items[0].entry.num);
    try testing.expectEqual(@as(u8, 3), plan.adds.items[1].entry.num);
}

test "planChanges: an already-enforced rule left checked is neither added nor forgotten" {
    var s = State.init();
    const decisions = [_]Decision{enforced("a", 1, null)};
    precheck(&s, &decisions);
    var plan = try planOf(&s, &decisions);
    defer plan.adds.deinit(testing.allocator);
    defer plan.forgets.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), plan.adds.items.len);
    try testing.expectEqual(@as(usize, 0), plan.forgets.items.len);
}

test "planChanges: unchecking a catalog rule forgets exactly it" {
    var s = State.init();
    const decisions = [_]Decision{ enforced("a", 1, null), enforced("b", 3, null) };
    precheck(&s, &decisions);
    s.rows[0].checked = false; // uncheck 1
    var plan = try planOf(&s, &decisions);
    defer plan.adds.deinit(testing.allocator);
    defer plan.forgets.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), plan.adds.items.len);
    try testing.expectEqual(@as(usize, 1), plan.forgets.items.len);
    try testing.expectEqualStrings("a", plan.forgets.items[0].id);
    try testing.expectEqual(@as(u8, 1), plan.forgets.items[0].entry.num);
}

test "planChanges: changing scope on a kept rule forgets the old and adds the new" {
    var s = State.init();
    const decisions = [_]Decision{enforced("a", 1, "app/")};
    precheck(&s, &decisions);
    try testing.expectEqualStrings("app/", s.scope.path);
    s.scope = .{ .path = "lib/" };
    var plan = try planOf(&s, &decisions);
    defer plan.adds.deinit(testing.allocator);
    defer plan.forgets.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), plan.adds.items.len);
    try testing.expectEqualStrings("lib/", plan.adds.items[0].where.?);
    try testing.expectEqual(@as(usize, 1), plan.forgets.items.len);
    try testing.expectEqualStrings("a", plan.forgets.items[0].id);
}

test "planChanges: a hand rule outside the catalog is never forgotten" {
    var s = State.init();
    var hand = enforced("h", 1, null);
    hand.check = "cmd:npm run lint";
    hand.text = "lint must pass";
    const decisions = [_]Decision{hand};
    // user checks nothing
    var plan = try planOf(&s, &decisions);
    defer plan.adds.deinit(testing.allocator);
    defer plan.forgets.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), plan.forgets.items.len);
    try testing.expectEqual(@as(usize, 0), plan.adds.items.len);
}

test "planChanges: an advisory catalog-check rule is left alone when unchecked" {
    var s = State.init();
    var advisory = enforced("adv", 1, null);
    advisory.enforce = false;
    const decisions = [_]Decision{advisory};
    var plan = try planOf(&s, &decisions);
    defer plan.adds.deinit(testing.allocator);
    defer plan.forgets.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), plan.forgets.items.len);
}

test "planChanges: a checked freeze row with no path adds nothing" {
    var s = State.init();
    s.rows[29].checked = true; // freeze, no path
    var plan = try planOf(&s, &.{});
    defer plan.adds.deinit(testing.allocator);
    defer plan.forgets.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), plan.adds.items.len);
}

test "planChanges: a checked freeze row with a path adds frozen at that path" {
    var s = State.init();
    s.rows[29].checked = true;
    s.rows[29].path = "src/core";
    var plan = try planOf(&s, &.{});
    defer plan.adds.deinit(testing.allocator);
    defer plan.forgets.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), plan.adds.items.len);
    try testing.expectEqualStrings("frozen", plan.adds.items[0].entry.check);
    try testing.expectEqualStrings("src/core", plan.adds.items[0].where.?);
}

test "render plain text shows checkboxes, cursor marker, groups and scope" {
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    var s = State.init();
    s.rows[0].checked = true;
    s.cursor = 0;
    try render(&w, &s, false, .none);
    const text = w.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "> [x] no console.log") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[ ] no debugger") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Code style:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "scope (code rules): whole repo") != null);
    // The catalog is taller than the default viewport, so a "more below" hint shows.
    try testing.expect(std.mem.indexOf(u8, text, "more below") != null);
}

test "render shows the batch scope only against checked scopable rows" {
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    var s = State.init();
    s.rows[0].checked = true;
    s.scope = .{ .path = "app/" };
    try render(&w, &s, false, .none);
    const text = w.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "no console.log [js/ts]  (in app/)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "scope (code rules): app/") != null);
}

fn feedAll(ed: *Editor, keys: []const Key) Outcome {
    var last: Outcome = .run;
    for (keys) |k| last = ed.feed(k);
    return last;
}

test "reducer: down then space checks the second row and stays running" {
    var ed = Editor.init();
    const out = feedAll(&ed, &.{ .down, .{ .char = ' ' } });
    try testing.expectEqual(Outcome.run, out);
    try testing.expect(ed.state.rows[1].checked);
    try testing.expectEqual(@as(usize, 1), ed.state.cursor);
}

test "reducer: arrows and vim k/j both move the cursor in normal mode" {
    var ed = Editor.init();
    _ = ed.feed(.down);
    _ = ed.feed(.down);
    try testing.expectEqual(@as(usize, 2), ed.state.cursor);
    _ = ed.feed(.up);
    try testing.expectEqual(@as(usize, 1), ed.state.cursor);
    _ = ed.feed(.{ .char = 'j' });
    try testing.expectEqual(@as(usize, 2), ed.state.cursor);
    _ = ed.feed(.{ .char = 'k' });
    try testing.expectEqual(@as(usize, 1), ed.state.cursor);
}

test "reducer: j and k are literal text, not navigation, inside a path field" {
    var ed = Editor.init();
    _ = ed.feed(.scope);
    _ = feedAll(&ed, &.{ .{ .char = 's' }, .{ .char = 'r' }, .{ .char = 'c' }, .{ .char = '/' }, .{ .char = 'j' }, .{ .char = 'k' } });
    try testing.expectEqual(Mode.scope_edit, ed.mode);
    try testing.expectEqualStrings("src/jk", ed.state.scope.path);
}

test "reducer: enter saves, esc and q cancel from normal mode" {
    var ed = Editor.init();
    try testing.expectEqual(Outcome.save, ed.feed(.save));
    try testing.expectEqual(Outcome.cancel, ed.feed(.cancel));
    try testing.expectEqual(Outcome.cancel, ed.feed(.{ .char = 'q' }));
}

test "reducer: Tab opens scope edit, typed path becomes the scope, Tab confirms" {
    var ed = Editor.init();
    _ = ed.feed(.scope);
    try testing.expectEqual(Mode.scope_edit, ed.mode);
    _ = feedAll(&ed, &.{ .{ .char = 'a' }, .{ .char = 'p' }, .{ .char = 'p' }, .{ .char = '/' } });
    try testing.expectEqualStrings("app/", ed.state.scope.path);
    _ = ed.feed(.scope);
    try testing.expectEqual(Mode.normal, ed.mode);
    try testing.expectEqualStrings("app/", ed.state.scope.path);
}

test "reducer: typing q into a path field is literal, not a cancel" {
    var ed = Editor.init();
    _ = ed.feed(.scope);
    _ = feedAll(&ed, &.{ .{ .char = 'q' }, .{ .char = 'q' } });
    try testing.expectEqual(Mode.scope_edit, ed.mode);
    try testing.expectEqualStrings("qq", ed.state.scope.path);
}

test "reducer: backspace trims the scope field, emptying it back to whole repo" {
    var ed = Editor.init();
    _ = ed.feed(.scope);
    _ = feedAll(&ed, &.{ .{ .char = 'a' }, .backspace });
    try testing.expectEqual(Scope.whole_repo, ed.state.scope);
}

test "reducer: checking the freeze row drops into its path field and records the path" {
    var ed = Editor.init();
    ed.state.cursor = 29; // freeze row
    _ = ed.feed(.{ .char = ' ' }); // check -> path edit
    try testing.expectEqual(Mode{ .path_edit = 29 }, ed.mode);
    _ = feedAll(&ed, &.{ .{ .char = 's' }, .{ .char = 'r' }, .{ .char = 'c' } });
    _ = ed.feed(.save); // confirm field, not a program save
    try testing.expectEqual(Mode.normal, ed.mode);
    try testing.expect(ed.state.rows[29].checked);
    try testing.expectEqualStrings("src", ed.state.rows[29].path.?);
}

test "reducer: seed copies precheck paths into owned buffers and they survive edits elsewhere" {
    var ed = Editor.init();
    const decisions = [_]Decision{ enforced("a", 1, "app/"), enforced("c", 30, "src/core") };
    precheck(&ed.state, &decisions);
    ed.seed();
    // scope slice now points into the editor's own buffer
    try testing.expectEqualStrings("app/", ed.state.scope.path);
    try testing.expectEqualStrings("src/core", ed.state.rows[29].path.?);
    // editing the freeze path must not disturb the scope slice
    ed.state.cursor = 29;
    _ = ed.feed(.scope); // opens... no; cursor doesn't matter, open path edit directly
    ed.mode = .{ .path_edit = 29 };
    _ = feedAll(&ed, &.{ .backspace, .backspace, .backspace, .backspace });
    try testing.expectEqualStrings("app/", ed.state.scope.path);
}

// ---------------------------------------------------------------------------
// The scrolling viewport: a pure "keep the cursor in view" fold over the row set.
// ---------------------------------------------------------------------------

test "viewport: moving the cursor past the bottom scrolls the window down" {
    var s = State.init();
    s.setViewport(5);
    try testing.expectEqual(@as(usize, 0), s.top);
    // Move to row 4 (the last visible one): still no scroll.
    for (0..4) |_| s.moveDown();
    try testing.expectEqual(@as(usize, 4), s.cursor);
    try testing.expectEqual(@as(usize, 0), s.top);
    // One more step pushes the window so the cursor stays on the bottom edge.
    s.moveDown();
    try testing.expectEqual(@as(usize, 5), s.cursor);
    try testing.expectEqual(@as(usize, 1), s.top);
    try testing.expectEqual(@as(usize, 6), s.visibleEnd());
}

test "viewport: moving the cursor back above the top scrolls the window up" {
    var s = State.init();
    s.setViewport(5);
    for (0..10) |_| s.moveDown(); // cursor 10, top 6
    try testing.expectEqual(@as(usize, 6), s.top);
    for (0..7) |_| s.moveUp(); // cursor 3, above top
    try testing.expectEqual(@as(usize, 3), s.cursor);
    try testing.expectEqual(@as(usize, 3), s.top);
}

test "viewport: the cursor is always inside the visible window while scrolling the whole list" {
    var s = State.init();
    s.setViewport(7);
    var guard: usize = 0;
    while (s.cursor + 1 < s.len and guard < 1000) : (guard += 1) {
        s.moveDown();
        try testing.expect(s.cursor >= s.top);
        try testing.expect(s.cursor < s.visibleEnd());
    }
    try testing.expectEqual(s.len - 1, s.cursor);
}

test "viewport: a list shorter than the viewport never scrolls" {
    var s = State.init();
    s.setViewport(s.len + 10);
    for (0..s.len * 2) |_| s.moveDown();
    try testing.expectEqual(@as(usize, 0), s.top);
    try testing.expectEqual(s.len, s.visibleEnd());
    // No "more above/below" hint, and the last group's header still renders.
    var buf: [8192]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try render(&w, &s, false, .none);
    const text = w.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "more above") == null);
    try testing.expect(std.mem.indexOf(u8, text, "more below") == null);
    try testing.expect(std.mem.indexOf(u8, text, "Architecture:") != null);
}

test "viewport: render shows the scrolled slice, both hints, and a group header inside the window" {
    var s = State.init();
    s.setViewport(6);
    for (0..s.len - 1) |_| s.moveDown(); // scroll to the bottom (freeze row)
    var buf: [8192]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try render(&w, &s, false, .none);
    const text = w.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "more above") != null);
    try testing.expect(std.mem.indexOf(u8, text, "more below") == null);
    // The bottom window opens mid-catalog, so its first group header still prints,
    // and the freeze row (last entry) is visible.
    try testing.expect(std.mem.indexOf(u8, text, "freeze a path") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Architecture:") != null);
    // A row scrolled out of view is not drawn.
    try testing.expect(std.mem.indexOf(u8, text, "no console.log") == null);
}

test "setViewport clamps to at least one row and keeps the cursor visible" {
    var s = State.init();
    for (0..10) |_| s.moveDown(); // cursor 10
    s.setViewport(0); // clamped to 1
    try testing.expectEqual(@as(usize, 1), s.viewport);
    try testing.expectEqual(@as(usize, 10), s.top);
    try testing.expectEqual(@as(usize, 11), s.visibleEnd());
}
