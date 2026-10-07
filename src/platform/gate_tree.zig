const std = @import("std");
const builtin = @import("builtin");
const dir_scan = @import("dir_scan.zig");
const link_tree = @import("link_tree.zig");
const worker_pool = @import("worker_pool.zig");

const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const Handle = windows.HANDLE;
const nt = dir_scan.win;
const Id = dir_scan.Id;

pub const How = enum { link, copy };

pub const Want = struct {
    rel: []const u8,
    source: []const u8,
    root: u8 = 0,
    how: How = .link,
    id: ?Id = null,
};

pub const Outcome = enum { absent, kept, linked, copied };

pub const Found = struct {
    dirs: usize = 0,
    skipped_links: usize = 0,
    report: ?*Report = null,
};

pub const Stats = struct {
    kept: usize = 0,
    linked: usize = 0,
    copied: usize = 0,
    removed: usize = 0,
    absent: usize = 0,
    dirs_made: usize = 0,
    skipped_links: usize = 0,
};

pub const Side = enum { kept_tree, working_tree };

pub const Reason = enum { blocked, denied, busy, link };

pub fn reasonOf(err: anyerror) Reason {
    return switch (err) {
        error.ScanDenied, error.AccessDenied => .denied,
        error.ScanBusy, error.FileBusy => .busy,
        error.ScanIsLink => .link,
        else => .blocked,
    };
}

pub const Report = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,
    side: Side = .kept_tree,
    reason: Reason = .blocked,

    pub fn path(self: *const Report) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn clear(self: *Report) void {
        self.len = 0;
    }

    pub fn reasonText(self: *const Report) []const u8 {
        return switch (self.reason) {
            .blocked => "could not be used",
            .denied => "access denied",
            .busy => "in use by another process",
            .link => "is a link",
        };
    }

    pub fn sideText(self: *const Report) []const u8 {
        return switch (self.side) {
            .kept_tree => "kept tree",
            .working_tree => "working tree",
        };
    }

    pub fn note(self: *Report, side: Side, reason: Reason, parts: []const []const u8) void {
        self.side = side;
        self.reason = reason;
        self.len = 0;
        for (parts) |part| {
            const take = @min(part.len, self.buf.len - self.len);
            @memcpy(self.buf[self.len..][0..take], part[0..take]);
            self.len += take;
        }
    }
};

pub const Options = struct {
    tree: Handle,
    roots: []const Handle,
    wants: []Want,
    outcomes: ?[]Outcome = null,
    report: ?*Report = null,
    pool: ?*worker_pool.Pool = null,
};

pub const Error = error{
    GateTreeBlocked,
    GateTreeUnavailable,
    GateTreeCaseCollision,
    GateTreeInjected,
    FileBusy,
    AccessDenied,
    UnsafePath,
    OutOfMemory,
} || dir_scan.Error;

pub var injected_fault: ?usize = null;

fn step() error{GateTreeInjected}!void {
    if (!builtin.is_test) return;
    const left = injected_fault orelse return;
    if (left == 0) return error.GateTreeInjected;
    injected_fault = left - 1;
}

const no_dir: u32 = std.math.maxInt(u32);
const remove_batch = 16;
const key_bytes = 33 * 1024;

const Lock = struct {
    held: std.atomic.Value(bool) = .init(false),

    fn acquire(self: *Lock) void {
        while (self.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn release(self: *Lock) void {
        self.held.store(false, .release);
    }
};

const Body = *const fn (state: *anyopaque, item: u32, scratch: *align(8) dir_scan.Buffer, key: []u8) Error!void;

const Sweep = struct {
    items: []const u32,
    body: Body,
    state: *anyopaque,
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    err: ?Error = null,
    lock: Lock = .{},

    fn work(raw: *anyopaque) void {
        const self: *Sweep = @ptrCast(@alignCast(raw));
        var scratch: dir_scan.Buffer align(8) = undefined;
        var key: [key_bytes]u8 = undefined;
        while (!self.failed.load(.acquire)) {
            const at = self.next.fetchAdd(1, .monotonic);
            if (at >= self.items.len) return;
            self.body(self.state, self.items[at], &scratch, &key) catch |err| {
                self.lock.acquire();
                if (self.err == null) self.err = err;
                self.lock.release();
                self.failed.store(true, .release);
                return;
            };
        }
    }

    fn run(pool: ?*worker_pool.Pool, items: []const u32, body: Body, state: *anyopaque) Error!void {
        var sweep: Sweep = .{ .items = items, .body = body, .state = state };
        if (pool) |p| p.run(p.helpers(), work, &sweep) else work(&sweep);
        if (sweep.err) |err| return err;
    }
};

fn levelsOf(arena: Allocator, parents: []const u32) Allocator.Error!Ranges {
    const depth = try arena.alloc(u32, parents.len);
    var deepest: u32 = 0;
    for (parents, 0..) |parent, index| {
        depth[index] = if (parent == no_dir) 0 else depth[parent] + 1;
        deepest = @max(deepest, depth[index]);
    }
    return Ranges.build(arena, deepest + 1, depth);
}

const DirTable = struct {
    rels: std.ArrayList([]const u8) = .empty,
    parents: std.ArrayList(u32) = .empty,
    by_rel: std.StringHashMapUnmanaged(u32) = .empty,

    fn add(self: *DirTable, arena: Allocator, rel: []const u8) Allocator.Error!u32 {
        if (self.by_rel.get(rel)) |found| return found;
        const parent: u32 = if (rel.len == 0) no_dir else try self.add(arena, parentOf(rel));
        const index: u32 = @intCast(self.rels.items.len);
        try self.rels.append(arena, rel);
        try self.parents.append(arena, parent);
        try self.by_rel.put(arena, rel, index);
        return index;
    }
};

fn parentOf(rel: []const u8) []const u8 {
    const cut = std.mem.lastIndexOfScalar(u8, rel, '/') orelse return "";
    return rel[0..cut];
}

fn baseOf(rel: []const u8) []const u8 {
    const cut = std.mem.lastIndexOfScalar(u8, rel, '/') orelse return rel;
    return rel[cut + 1 ..];
}

const Ranges = struct {
    starts: []u32,
    items: []u32,

    fn build(arena: Allocator, groups: usize, owner: []const u32) Allocator.Error!Ranges {
        const starts = try arena.alloc(u32, groups + 1);
        @memset(starts, 0);
        for (owner) |group| {
            if (group != no_dir) starts[group + 1] += 1;
        }
        for (1..starts.len) |i| starts[i] += starts[i - 1];
        const fill = try arena.dupe(u32, starts[0..groups]);
        const items = try arena.alloc(u32, starts[groups]);
        for (owner, 0..) |group, index| {
            if (group == no_dir) continue;
            items[fill[group]] = @intCast(index);
            fill[group] += 1;
        }
        return .{ .starts = starts, .items = items };
    }

    fn of(self: Ranges, group: usize) []const u32 {
        return self.items[self.starts[group]..self.starts[group + 1]];
    }
};

const SourceKind = enum { absent, file, follow };

const Context = struct {
    arena: Allocator,
    options: Options,
    stats: Stats = .{},
    kinds: []SourceKind,
    ids: []Id,
    placed: []bool,
    source_dir: []u32,
    source_handles: []?Handle,
    tree_dirs: DirTable = .{},
    tree_dir_of: []u32,
    want_by_rel: std.StringHashMapUnmanaged(u32) = .empty,
    dir_wants: Ranges = undefined,
    present: []bool,
    tree_handles: []?Handle = &.{},
    actions: []std.ArrayList(Action) = &.{},
    lock: Lock = .{},

    fn act(self: *Context, dir: u32, name: []const u16, kind: dir_scan.Kind) Allocator.Error!void {
        self.lock.acquire();
        defer self.lock.release();
        try self.actions[dir].append(self.arena, .{ .name = try self.arena.dupe(u16, name), .kind = kind });
    }

    fn blockedShared(self: *Context, reason: Reason, parts: []const []const u8) error{GateTreeBlocked} {
        self.lock.acquire();
        defer self.lock.release();
        return self.blocked(reason, parts);
    }

    fn sourceRefused(self: *Context, err: Error, rel: []const u8) Error {
        self.lock.acquire();
        defer self.lock.release();
        if (self.options.report) |report| report.note(.working_tree, reasonOf(err), &.{if (rel.len == 0) "." else rel});
        return err;
    }

    fn settle(self: *Context, want_index: u32, outcome: Outcome) void {
        switch (outcome) {
            .absent => self.stats.absent += 1,
            .kept => self.stats.kept += 1,
            .linked => self.stats.linked += 1,
            .copied => self.stats.copied += 1,
        }
        if (self.options.outcomes) |outcomes| outcomes[want_index] = outcome;
    }

    fn blocked(self: *Context, reason: Reason, parts: []const []const u8) error{GateTreeBlocked} {
        if (self.options.report) |report| report.note(.kept_tree, reason, parts);
        return error.GateTreeBlocked;
    }
};

pub fn normalize(arena: Allocator, rel: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, rel, '\\') == null) return rel;
    const owned = try arena.dupe(u8, rel);
    std.mem.replaceScalar(u8, owned, '\\', '/');
    return owned;
}

pub fn reconcile(gpa: Allocator, options: Options) Error!Stats {
    if (builtin.os.tag != .windows) return error.Unsupported;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const wants = options.wants;
    if (options.outcomes) |outcomes| {
        if (outcomes.len != wants.len) return error.UnsafePath;
        @memset(outcomes, .absent);
    }
    for (wants) |*want| {
        want.rel = try normalize(arena, want.rel);
        want.source = try normalize(arena, want.source);
        try validate(want.rel);
        try validate(want.source);
        if (want.root >= options.roots.len) return error.UnsafePath;
    }

    var ctx: Context = .{
        .arena = arena,
        .options = options,
        .kinds = try arena.alloc(SourceKind, wants.len),
        .ids = try arena.alloc(Id, wants.len),
        .placed = try arena.alloc(bool, wants.len),
        .source_dir = try arena.alloc(u32, wants.len),
        .source_handles = &.{},
        .tree_dir_of = try arena.alloc(u32, wants.len),
        .present = &.{},
    };
    @memset(ctx.kinds, .absent);
    @memset(ctx.placed, false);

    defer for (ctx.source_handles) |maybe| {
        if (maybe) |handle| dir_scan.close(handle);
    };
    defer for (ctx.tree_handles) |maybe| {
        if (maybe) |handle| dir_scan.close(handle);
    };
    try scanSources(&ctx);

    _ = try ctx.tree_dirs.add(arena, "");
    try ctx.want_by_rel.ensureTotalCapacity(arena, @intCast(wants.len));
    for (wants, 0..) |want, index| {
        ctx.tree_dir_of[index] = try ctx.tree_dirs.add(arena, parentOf(want.rel));
        const slot = ctx.want_by_rel.getOrPutAssumeCapacity(want.rel);
        if (slot.found_existing) {
            ctx.tree_dir_of[index] = no_dir;
            continue;
        }
        slot.value_ptr.* = @intCast(index);
    }
    const dir_count = ctx.tree_dirs.rels.items.len;
    ctx.dir_wants = try Ranges.build(arena, dir_count, ctx.tree_dir_of);
    ctx.present = try arena.alloc(bool, dir_count);
    @memset(ctx.present, false);
    ctx.tree_handles = try arena.alloc(?Handle, dir_count);
    @memset(ctx.tree_handles, null);
    ctx.actions = try arena.alloc(std.ArrayList(Action), dir_count);
    for (ctx.actions) |*list| list.* = .empty;

    const levels = try levelsOf(arena, ctx.tree_dirs.parents.items);
    for (0..levels.starts.len - 1) |level| try Sweep.run(options.pool, levels.of(level), scanTreeDir, &ctx);
    try applyTree(&ctx);
    return ctx.stats;
}

fn validate(rel: []const u8) error{UnsafePath}!void {
    if (rel.len == 0 or rel[0] == '/' or rel[rel.len - 1] == '/') return error.UnsafePath;
    if (std.mem.indexOfScalar(u8, rel, ':') != null) return error.UnsafePath;
    if (std.mem.indexOfScalar(u8, rel, 0) != null) return error.UnsafePath;
    var segments = std.mem.splitScalar(u8, rel, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return error.UnsafePath;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.UnsafePath;
    }
}

fn toWide(buffer: *[dir_scan.max_name_units + 1]u16, name: []const u8) Error![]const u16 {
    if (name.len > dir_scan.max_name_units * 3) return error.NameTooLong;
    var big: [dir_scan.max_name_units * 3]u16 = undefined;
    const len = std.unicode.wtf8ToWtf16Le(&big, name) catch return error.InvalidWtf8;
    if (len > dir_scan.max_name_units) return error.NameTooLong;
    @memcpy(buffer[0..len], big[0..len]);
    return buffer[0..len];
}

fn sourceKey(arena: Allocator, root: u8, rel: []const u8) Allocator.Error![]const u8 {
    const key = try arena.alloc(u8, rel.len + 1);
    key[0] = root;
    @memcpy(key[1..], rel);
    return key;
}

fn scanSources(ctx: *Context) Error!void {
    const arena = ctx.arena;
    const wants = ctx.options.wants;
    var dirs: DirTable = .{};
    var dir_root: std.ArrayList(u8) = .empty;
    var by_source: std.StringHashMapUnmanaged(u32) = .empty;
    try by_source.ensureTotalCapacity(arena, @intCast(wants.len));
    var needs: std.ArrayList(bool) = .empty;

    for (wants, 0..) |want, index| {
        const dir_key = try sourceKey(arena, want.root, parentOf(want.source));
        const dir_index = try addSourceDir(&dirs, arena, dir_key);
        while (dir_root.items.len < dirs.rels.items.len) {
            try dir_root.append(arena, want.root);
            try needs.append(arena, false);
        }
        ctx.source_dir[index] = dir_index;
        if (want.id) |known| {
            ctx.ids[index] = known;
            ctx.kinds[index] = .file;
        } else {
            needs.items[dir_index] = true;
            by_source.putAssumeCapacity(try sourceKey(arena, want.root, want.source), @intCast(index));
        }
    }

    const handles = try arena.alloc(?Handle, dirs.rels.items.len);
    @memset(handles, null);
    ctx.source_handles = handles;
    var scan: SourceScan = .{ .ctx = ctx, .dirs = &dirs, .needs = needs.items, .by_source = &by_source, .handles = handles };
    const levels = try levelsOf(arena, dirs.parents.items);
    for (0..levels.starts.len - 1) |level| try Sweep.run(ctx.options.pool, levels.of(level), SourceScan.body, &scan);

    var name_w: [dir_scan.max_name_units + 1]u16 = undefined;
    for (wants, 0..) |want, index| {
        if (ctx.kinds[index] != .absent) continue;
        const handle = handles[ctx.source_dir[index]] orelse continue;
        var file: Handle = undefined;
        const status = dir_scan.openRelative(handle, try toWide(&name_w, baseOf(want.source)), nt.file_read_attributes | nt.synchronize, nt.file_open, nt.option_non_directory | nt.option_open_reparse_point | nt.option_sync, &file);
        if (status != nt.status_success) continue;
        defer dir_scan.close(file);
        ctx.ids[index] = dir_scan.idOf(file) catch continue;
        ctx.kinds[index] = .file;
    }
}

const SourceScan = struct {
    ctx: *Context,
    dirs: *const DirTable,
    needs: []const bool,
    by_source: *const std.StringHashMapUnmanaged(u32),
    handles: []?Handle,

    fn body(raw: *anyopaque, dir: u32, scratch: *align(8) dir_scan.Buffer, key_buf: []u8) Error!void {
        const self: *SourceScan = @ptrCast(@alignCast(raw));
        const key = self.dirs.rels.items[dir];
        const parent = self.dirs.parents.items[dir];
        var name_w: [dir_scan.max_name_units + 1]u16 = undefined;
        const handle = if (parent == no_dir)
            try duplicate(self.ctx.options.roots[key[0]])
        else opened: {
            const parent_handle = self.handles[parent] orelse return;
            break :opened (dir_scan.openChild(parent_handle, try toWide(&name_w, baseOf(key[1..]))) catch |err| switch (err) {
                error.ScanIsLink => return,
                else => |e| return self.ctx.sourceRefused(e, key[1..]),
            }) orelse return;
        };
        self.handles[dir] = handle;
        if (!self.needs[dir]) return;

        if (key.len + 1 > key_buf.len) return error.NameTooLong;
        @memcpy(key_buf[0..key.len], key);
        var at = key.len;
        if (key.len > 1) {
            key_buf[at] = '/';
            at += 1;
        }
        var reader = dir_scan.Reader.init(handle, scratch);
        while (try reader.next()) |entry| {
            if (entry.kind == .directory or entry.kind == .link_directory) continue;
            if (at + entry.name.len * 3 > key_buf.len) return error.NameTooLong;
            const used = std.unicode.wtf16LeToWtf8(key_buf[at..], entry.name);
            const want_index = self.by_source.get(key_buf[0 .. at + used]) orelse continue;
            self.ctx.ids[want_index] = entry.id;
            self.ctx.kinds[want_index] = if (entry.kind == .link_file) .follow else .file;
        }
    }
};

fn addSourceDir(dirs: *DirTable, arena: Allocator, key: []const u8) Allocator.Error!u32 {
    if (dirs.by_rel.get(key)) |found| return found;
    const parent: u32 = if (key.len == 1) no_dir else try addSourceDir(dirs, arena, key[0 .. 1 + parentOf(key[1..]).len]);
    const index: u32 = @intCast(dirs.rels.items.len);
    try dirs.rels.append(arena, key);
    try dirs.parents.append(arena, parent);
    try dirs.by_rel.put(arena, key, index);
    return index;
}

fn duplicate(handle: Handle) Error!Handle {
    var out: Handle = undefined;
    const process = win.GetCurrentProcess();
    if (win.DuplicateHandle(process, handle, process, &out, 0, .FALSE, win.duplicate_same_access) == .FALSE) return error.ScanFailed;
    return out;
}

const Action = struct {
    name: []const u16,
    kind: dir_scan.Kind,
};

fn scanTreeDir(raw: *anyopaque, dir: u32, scratch: *align(8) dir_scan.Buffer, key_buf: []u8) Error!void {
    const ctx: *Context = @ptrCast(@alignCast(raw));
    const rel = ctx.tree_dirs.rels.items[dir];
    const parent = ctx.tree_dirs.parents.items[dir];
    var name_w: [dir_scan.max_name_units + 1]u16 = undefined;
    const handle = if (parent == no_dir)
        try duplicate(ctx.options.tree)
    else opened: {
        if (!ctx.present[dir]) return;
        const parent_handle = ctx.tree_handles[parent] orelse return;
        break :opened (dir_scan.openChild(parent_handle, try toWide(&name_w, baseOf(rel))) catch |err| switch (err) {
            error.ScanIsLink, error.ScanDenied, error.ScanBusy => |e| return ctx.blockedShared(reasonOf(e), &.{rel}),
            else => |e| return e,
        }) orelse return ctx.blockedShared(.blocked, &.{rel});
    };
    ctx.tree_handles[dir] = handle;

    if (rel.len + 1 > key_buf.len) return error.NameTooLong;
    @memcpy(key_buf[0..rel.len], rel);
    var at = rel.len;
    if (rel.len != 0) {
        key_buf[at] = '/';
        at += 1;
    }
    var reader = dir_scan.Reader.init(handle, scratch);
    while (try reader.next()) |entry| {
        if (at + entry.name.len * 3 > key_buf.len) return error.NameTooLong;
        const used = std.unicode.wtf16LeToWtf8(key_buf[at..], entry.name);
        const key = key_buf[0 .. at + used];
        const keep = switch (entry.kind) {
            .link_file, .link_directory => false,
            .directory => if (ctx.tree_dirs.by_rel.get(key)) |child| mark: {
                ctx.present[child] = true;
                break :mark true;
            } else false,
            .file => if (ctx.want_by_rel.get(key)) |want_index| same: {
                if (ctx.options.wants[want_index].how != .link or ctx.kinds[want_index] != .file) break :same false;
                if (!std.mem.eql(u8, &ctx.ids[want_index], &entry.id)) break :same false;
                ctx.placed[want_index] = true;
                break :same true;
            } else false,
        };
        if (!keep) try ctx.act(dir, entry.name, entry.kind);
    }
}

fn applyTree(ctx: *Context) Error!void {
    var name_w: [dir_scan.max_name_units + 1]u16 = undefined;
    for (ctx.tree_dirs.rels.items, 0..) |rel, index| {
        const dir: u32 = @intCast(index);
        const handle = ctx.tree_handles[index] orelse made: {
            const parent_handle = ctx.tree_handles[ctx.tree_dirs.parents.items[index]] orelse return ctx.blocked(.blocked, &.{rel});
            const name = try toWide(&name_w, baseOf(rel));
            try step();
            try makeDir(ctx, parent_handle, name, rel);
            const opened = (dir_scan.openChild(parent_handle, name) catch |err| switch (err) {
                error.ScanIsLink, error.ScanDenied, error.ScanBusy => |e| return ctx.blocked(reasonOf(e), &.{rel}),
                else => |e| return e,
            }) orelse return ctx.blocked(.blocked, &.{rel});
            ctx.tree_handles[index] = opened;
            break :made opened;
        };
        for (ctx.actions[index].items) |action| {
            try step();
            try removeName(ctx, handle, action.name, action.kind, rel);
        }
        for (ctx.dir_wants.of(dir)) |want_index| {
            if (ctx.placed[want_index]) {
                ctx.settle(want_index, .kept);
                continue;
            }
            if (ctx.kinds[want_index] == .absent) {
                ctx.settle(want_index, .absent);
                continue;
            }
            try step();
            try place(ctx, handle, want_index);
        }
    }
}

fn makeDir(ctx: *Context, parent: Handle, name: []const u16, rel: []const u8) Error!void {
    var made: Handle = undefined;
    const status = dir_scan.openRelative(parent, name, nt.file_list_directory | nt.synchronize, nt.file_create, nt.option_directory | nt.option_sync, &made);
    if (status != nt.status_success) return ctx.blocked(.blocked, &.{rel});
    dir_scan.close(made);
    ctx.stats.dirs_made += 1;
}

fn removeName(ctx: *Context, parent: Handle, name: []const u16, kind: dir_scan.Kind, dir_rel: []const u8) Error!void {
    var name8: [dir_scan.max_name_units * 3]u8 = undefined;
    const shown = name8[0..std.unicode.wtf16LeToWtf8(&name8, name)];
    removeEntry(parent, name, kind, &ctx.stats.removed) catch |err| {
        if (ctx.options.report) |report| report.note(.kept_tree, reasonOf(err), &.{ dir_rel, if (dir_rel.len == 0) "" else "/", shown });
        return err;
    };
}

fn removeEntry(parent: Handle, name: []const u16, kind: dir_scan.Kind, removed: *usize) Error!void {
    const directory = kind == .directory or kind == .link_directory;
    const access: u32 = nt.delete | nt.synchronize | nt.file_read_attributes | (if (kind == .directory) nt.file_list_directory else 0);
    const options: u32 = nt.option_open_reparse_point | nt.option_sync | (if (directory) nt.option_directory else nt.option_non_directory);
    var handle: Handle = undefined;
    const status = dir_scan.openRelative(parent, name, access, nt.file_open, options, &handle);
    switch (status) {
        nt.status_success => {},
        nt.status_name_not_found, nt.status_path_not_found => return,
        nt.status_sharing_violation => return error.FileBusy,
        nt.status_access_denied => return error.AccessDenied,
        else => return error.GateTreeBlocked,
    }
    defer dir_scan.close(handle);

    if (kind == .directory) {
        const buffer = std.heap.page_allocator.alignedAlloc(u8, .@"8", dir_scan.buffer_bytes) catch return error.OutOfMemory;
        defer std.heap.page_allocator.free(buffer);
        var pending: [remove_batch]Action = undefined;
        var storage: [remove_batch][dir_scan.max_name_units]u16 = undefined;
        while (true) {
            var count: usize = 0;
            var reader = dir_scan.Reader.init(handle, buffer[0..dir_scan.buffer_bytes]);
            while (count < pending.len) {
                const entry = (try reader.next()) orelse break;
                @memcpy(storage[count][0..entry.name.len], entry.name);
                pending[count] = .{ .name = storage[count][0..entry.name.len], .kind = entry.kind };
                count += 1;
            }
            if (count == 0) break;
            for (pending[0..count]) |child| try removeEntry(handle, child.name, child.kind, removed);
        }
    }

    var disposition: win.DispositionEx = .{ .flags = win.disposition_delete | win.disposition_posix | win.disposition_ignore_readonly };
    var iosb: nt.IoStatusBlock = undefined;
    if (win.NtSetInformationFile(handle, &iosb, &disposition, @sizeOf(win.DispositionEx), win.class_disposition_ex) != nt.status_success) return error.GateTreeBlocked;
    removed.* += 1;
}

fn place(ctx: *Context, tree_dir: Handle, want_index: u32) Error!void {
    const want = ctx.options.wants[want_index];
    const source_dir = ctx.source_handles[ctx.source_dir[want_index]] orelse return ctx.settle(want_index, .absent);
    var source_w: [dir_scan.max_name_units + 1]u16 = undefined;
    var name_w: [dir_scan.max_name_units + 1]u16 = undefined;
    const source_name = try toWide(&source_w, baseOf(want.source));
    const name = try toWide(&name_w, baseOf(want.rel));

    if (want.how == .link and ctx.kinds[want_index] == .file) {
        var source: Handle = undefined;
        const status = dir_scan.openRelative(source_dir, source_name, nt.read_control | nt.file_write_attributes | nt.synchronize, nt.file_open, nt.option_non_directory | nt.option_open_reparse_point | nt.option_sync, &source);
        switch (status) {
            nt.status_success => {
                defer dir_scan.close(source);
                if (try lowWriteBlocked(source)) {
                    switch (linkInto(source, tree_dir, name)) {
                        nt.status_success => return ctx.settle(want_index, .linked),
                        nt.status_too_many_links => {},
                        nt.status_not_same_device, nt.status_not_supported, nt.status_invalid_device_request => return error.GateTreeUnavailable,
                        nt.status_name_collision => {
                            if (ctx.options.report) |report| report.note(.kept_tree, .blocked, &.{want.rel});
                            return error.GateTreeCaseCollision;
                        },
                        else => return ctx.blocked(.blocked, &.{want.rel}),
                    }
                }
            },
            nt.status_name_not_found, nt.status_path_not_found => return ctx.settle(want_index, .absent),
            else => {},
        }
    }
    try copyInto(ctx, want_index, source_dir, source_name, tree_dir, name, want.rel);
}

fn lowWriteBlocked(file: Handle) Error!bool {
    var buffer: [4096]u8 align(8) = undefined;
    var needed: u32 = 0;
    if (win.GetKernelObjectSecurity(file, win.label_security_information, &buffer, buffer.len, &needed) == .FALSE) return false;
    var present: windows.BOOL = .FALSE;
    var defaulted: windows.BOOL = .FALSE;
    var sacl: ?[*]const u8 = null;
    if (win.GetSecurityDescriptorSacl(&buffer, &present, &sacl, &defaulted) == .FALSE) return false;
    const acl = sacl orelse return true;
    if (present == .FALSE) return true;
    return link_tree.labelBlocksLowWrite(acl);
}

fn linkInto(source: Handle, tree_dir: Handle, name: []const u16) u32 {
    var buffer: [win.link_name_offset + dir_scan.max_name_units * 2]u8 align(8) = undefined;
    @memset(buffer[0..win.link_name_offset], 0);
    std.mem.writeInt(usize, buffer[8..16], @intFromPtr(tree_dir), .little);
    std.mem.writeInt(u32, buffer[16..20], @intCast(name.len * 2), .little);
    @memcpy(buffer[win.link_name_offset..][0 .. name.len * 2], std.mem.sliceAsBytes(name));
    var iosb: nt.IoStatusBlock = undefined;
    return win.NtSetInformationFile(source, &iosb, &buffer, @intCast(win.link_name_offset + name.len * 2), win.class_link);
}

fn copyInto(ctx: *Context, want_index: u32, source_dir: Handle, source_name: []const u16, tree_dir: Handle, name: []const u16, rel: []const u8) Error!void {
    var source: Handle = undefined;
    switch (dir_scan.openRelative(source_dir, source_name, nt.generic_read | nt.synchronize, nt.file_open, nt.option_non_directory | nt.option_sync, &source)) {
        nt.status_success => {},
        nt.status_name_not_found, nt.status_path_not_found, nt.status_file_is_a_directory => return ctx.settle(want_index, .absent),
        else => return ctx.blocked(.blocked, &.{rel}),
    }
    defer dir_scan.close(source);
    var dest: Handle = undefined;
    switch (dir_scan.openRelative(tree_dir, name, nt.generic_write | nt.synchronize, nt.file_create, nt.option_non_directory | nt.option_sync, &dest)) {
        nt.status_success => {},
        nt.status_name_collision => {
            if (ctx.options.report) |report| report.note(.kept_tree, .blocked, &.{rel});
            return error.GateTreeCaseCollision;
        },
        else => return ctx.blocked(.blocked, &.{rel}),
    }
    defer dir_scan.close(dest);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        var got: u32 = 0;
        if (win.ReadFile(source, &chunk, chunk.len, &got, null) == .FALSE) return ctx.blocked(.blocked, &.{rel});
        if (got == 0) break;
        if (!writeAll(dest, chunk[0..got])) return ctx.blocked(.blocked, &.{rel});
    }
    ctx.settle(want_index, .copied);
}

fn writeAll(dest: Handle, data: []const u8) bool {
    var done: usize = 0;
    while (done < data.len) {
        var put: u32 = 0;
        const take: u32 = @intCast(@min(data.len - done, 1 << 20));
        if (win.WriteFile(dest, data[done..].ptr, take, &put, null) == .FALSE or put == 0) return false;
        done += put;
    }
    return true;
}

pub fn writeFile(tree: Handle, rel_raw: []const u8, data: []const u8) Error!void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (rel_raw.len > rel_buf.len) return error.NameTooLong;
    const rel = rel_buf[0..rel_raw.len];
    @memcpy(rel, rel_raw);
    std.mem.replaceScalar(u8, rel, '\\', '/');
    try validate(rel);
    const parent = try descend(tree, parentOf(rel), true);
    defer dir_scan.close(parent.?);
    var name_w: [dir_scan.max_name_units + 1]u16 = undefined;
    const name = try toWide(&name_w, baseOf(rel));
    var removed: usize = 0;
    try removeAny(parent.?, name, &removed);
    var dest: Handle = undefined;
    if (dir_scan.openRelative(parent.?, name, nt.generic_write | nt.synchronize, nt.file_create, nt.option_non_directory | nt.option_sync, &dest) != nt.status_success) return error.GateTreeBlocked;
    defer dir_scan.close(dest);
    if (!writeAll(dest, data)) return error.GateTreeBlocked;
}

pub fn deleteFile(tree: Handle, rel_raw: []const u8) Error!void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (rel_raw.len > rel_buf.len) return error.NameTooLong;
    const rel = rel_buf[0..rel_raw.len];
    @memcpy(rel, rel_raw);
    std.mem.replaceScalar(u8, rel, '\\', '/');
    try validate(rel);
    const parent = (try descend(tree, parentOf(rel), false)) orelse return;
    defer dir_scan.close(parent);
    var name_w: [dir_scan.max_name_units + 1]u16 = undefined;
    var removed: usize = 0;
    try removeAny(parent, try toWide(&name_w, baseOf(rel)), &removed);
}

fn removeAny(parent: Handle, name: []const u16, removed: *usize) Error!void {
    var probe: Handle = undefined;
    switch (dir_scan.openRelative(parent, name, nt.file_read_attributes | nt.synchronize, nt.file_open, nt.option_open_reparse_point | nt.option_sync, &probe)) {
        nt.status_success => {},
        nt.status_name_not_found, nt.status_path_not_found => return,
        else => return error.GateTreeBlocked,
    }
    var info: win.BasicInfo = undefined;
    const known = win.GetFileInformationByHandleEx(probe, win.file_basic_info, &info, @sizeOf(win.BasicInfo));
    dir_scan.close(probe);
    if (known == .FALSE) return error.GateTreeBlocked;
    try removeEntry(parent, name, dir_scan.kindOf(info.attributes), removed);
}

fn descend(tree: Handle, dir_rel: []const u8, create: bool) Error!?Handle {
    var current = try duplicate(tree);
    errdefer dir_scan.close(current);
    var name_w: [dir_scan.max_name_units + 1]u16 = undefined;
    var segments = std.mem.tokenizeScalar(u8, dir_rel, '/');
    while (segments.next()) |segment| {
        const name = try toWide(&name_w, segment);
        const next = (dir_scan.openChild(current, name) catch |err| switch (err) {
            error.ScanIsLink => return error.UnsafePath,
            else => |e| return e,
        }) orelse made: {
            if (!create) {
                dir_scan.close(current);
                return null;
            }
            var made: Handle = undefined;
            if (dir_scan.openRelative(current, name, nt.file_list_directory | nt.synchronize, nt.file_create, nt.option_directory | nt.option_sync, &made) != nt.status_success) return error.GateTreeBlocked;
            dir_scan.close(made);
            break :made (try dir_scan.openChild(current, name)) orelse return error.GateTreeBlocked;
        };
        dir_scan.close(current);
        current = next;
    }
    return current;
}

const Frontier = struct {
    handle: Handle,
    rel: []const u8,
};

const Discovery = struct {
    arena: Allocator,
    root_index: u8,
    wants: *std.ArrayList(Want),
    found: *Found,
    current: []const Frontier,
    next: std.ArrayList(Frontier) = .empty,
    lock: Lock = .{},

    fn pathOf(self: *Discovery, rel: []const u8, name: []const u16) Allocator.Error![]const u8 {
        const child = try self.arena.alloc(u8, rel.len + 1 + name.len * 3);
        @memcpy(child[0..rel.len], rel);
        child[rel.len] = '/';
        const used = std.unicode.wtf16LeToWtf8(child[rel.len + 1 ..], name);
        return child[0 .. rel.len + 1 + used];
    }

    fn file(self: *Discovery, rel: []const u8, entry: dir_scan.Entry) Allocator.Error!void {
        self.lock.acquire();
        defer self.lock.release();
        const path = try self.pathOf(rel, entry.name);
        try self.wants.append(self.arena, .{ .rel = path, .source = path, .root = self.root_index, .id = entry.id });
    }

    fn directory(self: *Discovery, rel: []const u8, name: []const u16, handle: Handle) Allocator.Error!void {
        self.lock.acquire();
        defer self.lock.release();
        try self.next.append(self.arena, .{ .handle = handle, .rel = try self.pathOf(rel, name) });
    }

    fn refused(self: *Discovery, err: Error, rel: []const u8, name: []const u16) Error {
        self.lock.acquire();
        defer self.lock.release();
        const report = self.found.report orelse return err;
        var name8: [dir_scan.max_name_units * 3]u8 = undefined;
        report.note(.working_tree, reasonOf(err), &.{ rel, "/", name8[0..std.unicode.wtf16LeToWtf8(&name8, name)] });
        return err;
    }

    fn skip(self: *Discovery) void {
        self.lock.acquire();
        defer self.lock.release();
        self.found.skipped_links += 1;
    }

    fn body(raw: *anyopaque, item: u32, scratch: *align(8) dir_scan.Buffer, key: []u8) Error!void {
        _ = key;
        const self: *Discovery = @ptrCast(@alignCast(raw));
        const at = self.current[item];
        var reader = dir_scan.Reader.init(at.handle, scratch);
        while (try reader.next()) |entry| {
            switch (entry.kind) {
                .link_file, .link_directory => self.skip(),
                .file => try self.file(at.rel, entry),
                .directory => {
                    const child = (dir_scan.openChild(at.handle, entry.name) catch |err| switch (err) {
                        error.ScanIsLink => {
                            self.skip();
                            continue;
                        },
                        else => |e| return self.refused(e, at.rel, entry.name),
                    }) orelse continue;
                    self.directory(at.rel, entry.name, child) catch |err| {
                        dir_scan.close(child);
                        return err;
                    };
                },
            }
        }
    }
};

pub fn discover(arena: Allocator, pool: ?*worker_pool.Pool, root: Handle, root_index: u8, dir_rel_raw: []const u8, wants: *std.ArrayList(Want), found: *Found) Error!void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    const dir_rel = try normalize(arena, dir_rel_raw);
    try validate(dir_rel);
    const top = (descendExisting(root, dir_rel) catch |err| switch (err) {
        error.ScanIsLink => {
            found.skipped_links += 1;
            return;
        },
        else => |e| {
            if (found.report) |report| report.note(.working_tree, reasonOf(e), &.{dir_rel});
            return e;
        },
    }) orelse return;
    var first = [_]Frontier{.{ .handle = top, .rel = dir_rel }};
    var state: Discovery = .{ .arena = arena, .root_index = root_index, .wants = wants, .found = found, .current = &first };
    while (state.current.len != 0) {
        const level = state.current;
        defer for (level) |entry| dir_scan.close(entry.handle);
        errdefer for (state.next.items) |entry| dir_scan.close(entry.handle);
        found.dirs += level.len;
        const items = try arena.alloc(u32, level.len);
        for (items, 0..) |*item, index| item.* = @intCast(index);
        state.next = .empty;
        try Sweep.run(pool, items, Discovery.body, &state);
        state.current = state.next.items;
    }
}

fn descendExisting(root: Handle, dir_rel: []const u8) Error!?Handle {
    var current = try duplicate(root);
    errdefer dir_scan.close(current);
    var name_w: [dir_scan.max_name_units + 1]u16 = undefined;
    var segments = std.mem.tokenizeScalar(u8, dir_rel, '/');
    while (segments.next()) |segment| {
        const next = (try dir_scan.openChild(current, try toWide(&name_w, segment))) orelse {
            dir_scan.close(current);
            return null;
        };
        dir_scan.close(current);
        current = next;
    }
    return current;
}

pub fn removeAll(tree: Handle) Error!usize {
    if (builtin.os.tag != .windows) return error.Unsupported;
    var removed: usize = 0;
    const buffer = std.heap.page_allocator.alignedAlloc(u8, .@"8", dir_scan.buffer_bytes) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(buffer);
    var pending: [remove_batch]Action = undefined;
    var storage: [remove_batch][dir_scan.max_name_units]u16 = undefined;
    while (true) {
        var count: usize = 0;
        var reader = dir_scan.Reader.init(tree, buffer[0..dir_scan.buffer_bytes]);
        while (count < pending.len) {
            const entry = (try reader.next()) orelse break;
            @memcpy(storage[count][0..entry.name.len], entry.name);
            pending[count] = .{ .name = storage[count][0..entry.name.len], .kind = entry.kind };
            count += 1;
        }
        if (count == 0) break;
        for (pending[0..count]) |child| try removeEntry(tree, child.name, child.kind, &removed);
    }
    return removed;
}

const win = struct {
    const duplicate_same_access: u32 = 2;
    const label_security_information: u32 = 0x10;
    const class_link: u32 = 11;
    const class_disposition_ex: u32 = 64;
    const link_name_offset = 20;
    const disposition_delete: u32 = 0x1;
    const disposition_posix: u32 = 0x2;
    const disposition_ignore_readonly: u32 = 0x10;
    const file_basic_info: u32 = 0;

    const DispositionEx = extern struct { flags: u32 };

    const BasicInfo = extern struct {
        creation_time: i64,
        last_access_time: i64,
        last_write_time: i64,
        change_time: i64,
        attributes: u32,
    };

    extern "ntdll" fn NtSetInformationFile(handle: Handle, iosb: *nt.IoStatusBlock, info: *anyopaque, length: u32, class: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) Handle;
    extern "kernel32" fn DuplicateHandle(source_process: Handle, source: Handle, target_process: Handle, target: *Handle, access: u32, inherit: windows.BOOL, options: u32) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn ReadFile(handle: Handle, buffer: [*]u8, length: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn WriteFile(handle: Handle, buffer: [*]const u8, length: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetFileInformationByHandleEx(handle: Handle, class: u32, info: *anyopaque, size: u32) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn GetKernelObjectSecurity(handle: Handle, info: u32, descriptor: *anyopaque, length: u32, needed: *u32) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn GetSecurityDescriptorSacl(descriptor: *anyopaque, present: *windows.BOOL, sacl: *?[*]const u8, defaulted: *windows.BOOL) callconv(.winapi) windows.BOOL;
};

const testing = std.testing;
const Dir = std.Io.Dir;

const test_win = struct {
    extern "kernel32" fn CreateHardLinkW(new_name: [*:0]const u16, existing: [*:0]const u16, security: ?*anyopaque) callconv(.winapi) windows.BOOL;
};

fn hardLinkAbsolute(existing_abs: []const u8, new_abs: []const u8) !void {
    var existing_w: [std.fs.max_path_bytes:0]u16 = undefined;
    var new_w: [std.fs.max_path_bytes:0]u16 = undefined;
    existing_w[try std.unicode.wtf8ToWtf16Le(&existing_w, existing_abs)] = 0;
    new_w[try std.unicode.wtf8ToWtf16Le(&new_w, new_abs)] = 0;
    if (test_win.CreateHardLinkW(&new_w, &existing_w, null) == .FALSE) return error.TestHardLinkFailed;
}

const Fixture = struct {
    tmp: testing.TmpDir,
    top: [:0]u8,
    work: Handle,
    tree: Handle,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "work/src/deep");
        try tmp.dir.createDirPath(testing.io, "tree");
        try tmp.dir.createDirPath(testing.io, "outside");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "work/a.ts", .data = "a1\n" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "work/src/b.ts", .data = "b1\n" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "work/src/deep/c.ts", .data = "c1\n" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside/secret.txt", .data = "secret\n" });
        const top = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(top);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const work = (try dir_scan.openRoot(try std.fmt.bufPrint(&buf, "{s}\\work", .{top}))).?;
        errdefer dir_scan.close(work);
        const tree = (try dir_scan.openRoot(try std.fmt.bufPrint(&buf, "{s}\\tree", .{top}))).?;
        return .{ .tmp = tmp, .top = top, .work = work, .tree = tree };
    }

    fn deinit(self: *Fixture) void {
        dir_scan.close(self.tree);
        dir_scan.close(self.work);
        testing.allocator.free(self.top);
        self.tmp.cleanup();
    }

    fn run(self: *Fixture, wants: []Want) Error!Stats {
        return reconcile(testing.allocator, .{ .tree = self.tree, .roots = &.{self.work}, .wants = wants });
    }

    fn tracked(self: *Fixture) Error!Stats {
        var wants = [_]Want{
            .{ .rel = "a.ts", .source = "a.ts" },
            .{ .rel = "src/b.ts", .source = "src/b.ts" },
            .{ .rel = "src/deep/c.ts", .source = "src/deep/c.ts" },
        };
        return self.run(&wants);
    }

    fn expect(self: *Fixture, sub_path: []const u8, expected: []const u8) !void {
        errdefer std.debug.print("unexpected content in {s}\n", .{sub_path});
        const actual = try self.tmp.dir.readFileAlloc(testing.io, sub_path, testing.allocator, .unlimited);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(expected, actual);
    }

    fn missing(self: *Fixture, sub_path: []const u8) !void {
        errdefer std.debug.print("still present: {s}\n", .{sub_path});
        try testing.expectError(error.FileNotFound, self.tmp.dir.access(testing.io, sub_path, .{}));
    }

    fn sameFile(self: *Fixture, a: []const u8, b: []const u8) !bool {
        const sa = try self.tmp.dir.statFile(testing.io, a, .{});
        const sb = try self.tmp.dir.statFile(testing.io, b, .{});
        return sa.inode == sb.inode;
    }

    fn replace(self: *Fixture, sub_path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "incoming.tmp", .data = data });
        try self.tmp.dir.rename("incoming.tmp", self.tmp.dir, sub_path, testing.io);
    }

    fn abs(self: *Fixture, buf: []u8, sub_path: []const u8) ![]u8 {
        return std.fmt.bufPrint(buf, "{s}\\{s}", .{ self.top, sub_path });
    }
};

test "reconcile links every wanted file to the working file itself and the next call keeps them all" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();

    const first = try fx.tracked();
    try testing.expectEqual(@as(usize, 3), first.linked);
    try testing.expectEqual(@as(usize, 0), first.copied);
    try testing.expectEqual(@as(usize, 2), first.dirs_made);
    try fx.expect("tree/src/deep/c.ts", "c1\n");
    try testing.expect(try fx.sameFile("work/a.ts", "tree/a.ts"));
    try testing.expect(try fx.sameFile("work/src/b.ts", "tree/src/b.ts"));

    const second = try fx.tracked();
    try testing.expectEqual(Stats{ .kept = 3 }, second);
}

test "an edit made in place shows through the link and a replace-style save is relinked by the next call" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    _ = try fx.tracked();

    var file = try fx.tmp.dir.openFile(testing.io, "work/a.ts", .{ .mode = .read_write });
    try file.writePositionalAll(testing.io, "A2\n", 0);
    file.close(testing.io);
    try fx.expect("tree/a.ts", "A2\n");
    try testing.expectEqual(Stats{ .kept = 3 }, try fx.tracked());

    try fx.replace("work/src/b.ts", "b2\n");
    try fx.expect("tree/src/b.ts", "b1\n");
    const after = try fx.tracked();
    try testing.expectEqual(Stats{ .kept = 2, .linked = 1, .removed = 1 }, after);
    try fx.expect("tree/src/b.ts", "b2\n");
    try testing.expect(try fx.sameFile("work/src/b.ts", "tree/src/b.ts"));
}

test "a name the tree should not hold is removed: a file, a directory with content, a replaced link and a junction whose target stays" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const shadow = @import("shadow.zig");
    var fx = try Fixture.init();
    defer fx.deinit();
    _ = try fx.tracked();

    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "tree/leftover.log", .data = "left\n" });
    try fx.tmp.dir.createDirPath(testing.io, "tree/dist/nested");
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "tree/dist/nested/out.js", .data = "out\n" });
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "tree/src/extra.ts", .data = "extra\n" });
    try fx.tmp.dir.deleteFile(testing.io, "tree/a.ts");
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "tree/a.ts", .data = "forged\n" });
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    try shadow.createJunction(testing.io, try fx.abs(&link_buf, "tree\\jump"), try fx.abs(&target_buf, "outside"));
    try shadow.createJunction(testing.io, try fx.abs(&link_buf, "tree\\dist\\jump"), try fx.abs(&target_buf, "outside"));

    const stats = try fx.tracked();
    try testing.expectEqual(@as(usize, 2), stats.kept);
    try testing.expectEqual(@as(usize, 1), stats.linked);
    try testing.expectEqual(@as(usize, 8), stats.removed);
    try fx.missing("tree/leftover.log");
    try fx.missing("tree/dist");
    try fx.missing("tree/src/extra.ts");
    try fx.missing("tree/jump");
    try fx.expect("tree/a.ts", "a1\n");
    try fx.expect("work/a.ts", "a1\n");
    try fx.expect("outside/secret.txt", "secret\n");
}

test "a wanted file that the working tree does not have is absent from the tree, and leaves it when it disappears" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    _ = try fx.tracked();
    try fx.tmp.dir.deleteFile(testing.io, "work/src/b.ts");

    const stats = try fx.tracked();
    try testing.expectEqual(Stats{ .kept = 2, .removed = 1, .absent = 1 }, stats);
    try fx.missing("tree/src/b.ts");
    try fx.expect("tree/a.ts", "a1\n");
}

test "a directory where a file is wanted and a file where a directory is wanted are both replaced" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.tmp.dir.createDirPath(testing.io, "tree/a.ts/inner");
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "tree/a.ts/inner/x", .data = "x\n" });
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "tree/src", .data = "not a directory\n" });

    const stats = try fx.tracked();
    try testing.expectEqual(@as(usize, 3), stats.linked);
    try fx.expect("tree/a.ts", "a1\n");
    try fx.expect("tree/src/deep/c.ts", "c1\n");
}

test "a name that differs from the wanted one only in letter case is replaced by the wanted name" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    _ = try fx.tracked();
    try fx.tmp.dir.rename("tree/a.ts", fx.tmp.dir, "tree/A.TS", testing.io);

    const stats = try fx.tracked();
    try testing.expectEqual(Stats{ .kept = 2, .linked = 1, .removed = 1 }, stats);
    var tree = try fx.tmp.dir.openDir(testing.io, "tree", .{ .iterate = true });
    defer tree.close(testing.io);
    var it = tree.iterate();
    var exact = false;
    while (try it.next(testing.io)) |entry| {
        if (std.mem.eql(u8, entry.name, "a.ts")) exact = true;
        try testing.expect(!std.mem.eql(u8, entry.name, "A.TS"));
    }
    try testing.expect(exact);
}

test "a want marked copy is a private file that is made again on every call" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    var wants = [_]Want{
        .{ .rel = "a.ts", .source = "a.ts", .how = .copy },
        .{ .rel = "src/b.ts", .source = "src/b.ts" },
    };
    var outcomes: [2]Outcome = undefined;
    const first = try reconcile(testing.allocator, .{ .tree = fx.tree, .roots = &.{fx.work}, .wants = &wants, .outcomes = &outcomes });
    try testing.expectEqual(@as(usize, 1), first.copied);
    try testing.expectEqual(@as(usize, 1), first.linked);
    try testing.expectEqualSlices(Outcome, &.{ .copied, .linked }, &outcomes);
    try testing.expect(!try fx.sameFile("work/a.ts", "tree/a.ts"));

    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "tree/a.ts", .data = "written by a test\n" });
    try fx.expect("work/a.ts", "a1\n");
    var again = [_]Want{
        .{ .rel = "a.ts", .source = "a.ts", .how = .copy },
        .{ .rel = "src/b.ts", .source = "src/b.ts" },
    };
    const second = try fx.run(&again);
    try testing.expectEqual(Stats{ .kept = 1, .copied = 1, .removed = 1 }, second);
    try fx.expect("tree/a.ts", "a1\n");
}

test "a working file that a low-integrity process may write is given a private copy, never a link" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const shadow = @import("shadow.zig");
    var fx = try Fixture.init();
    defer fx.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try shadow.grantLowIntegrityWrite(try fx.abs(&buf, "work\\a.ts"));

    const first = try fx.tracked();
    try testing.expectEqual(@as(usize, 2), first.linked);
    try testing.expectEqual(@as(usize, 1), first.copied);
    try testing.expect(!try fx.sameFile("work/a.ts", "tree/a.ts"));
    try fx.expect("tree/a.ts", "a1\n");
    const second = try fx.tracked();
    try testing.expectEqual(Stats{ .kept = 2, .copied = 1, .removed = 1 }, second);
}

test "a working file that already has the most names a file can have is given a private copy" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.tmp.dir.createDirPath(testing.io, "links");
    var existing_buf: [std.fs.max_path_bytes]u8 = undefined;
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const existing = try fx.abs(&existing_buf, "work\\a.ts");
    for (0..1023) |i| {
        try hardLinkAbsolute(existing, try std.fmt.bufPrint(&name_buf, "{s}\\links\\l{d}", .{ fx.top, i }));
    }
    const stats = try fx.tracked();
    try testing.expectEqual(@as(usize, 2), stats.linked);
    try testing.expectEqual(@as(usize, 1), stats.copied);
    try fx.expect("tree/a.ts", "a1\n");
    try testing.expect(!try fx.sameFile("work/a.ts", "tree/a.ts"));
}

test "writing the proposed edit replaces the name and never writes through the link into the working file" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    _ = try fx.tracked();

    try writeFile(fx.tree, "a.ts", "edited\n");
    try writeFile(fx.tree, "src\\new\\d.ts", "created\n");
    try fx.expect("tree/a.ts", "edited\n");
    try fx.expect("work/a.ts", "a1\n");
    try fx.expect("tree/src/new/d.ts", "created\n");
    try fx.missing("work/src/new");

    try deleteFile(fx.tree, "src/b.ts");
    try deleteFile(fx.tree, "src/never/was.ts");
    try fx.missing("tree/src/b.ts");
    try fx.expect("work/src/b.ts", "b1\n");

    const stats = try fx.tracked();
    try testing.expectEqual(@as(usize, 1), stats.kept);
    try testing.expectEqual(@as(usize, 2), stats.linked);
    try fx.expect("tree/a.ts", "a1\n");
    try fx.missing("tree/src/new");
}

test "writing the edit refuses a path that leaves the tree or passes through a junction" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const shadow = @import("shadow.zig");
    var fx = try Fixture.init();
    defer fx.deinit();
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    try shadow.createJunction(testing.io, try fx.abs(&link_buf, "tree\\jump"), try fx.abs(&target_buf, "outside"));
    for ([_][]const u8{ "../escape.txt", "src/../../escape.txt", "/rooted.txt", "a.ts:stream", "jump/planted.txt", "", "src//x.ts" }) |bad| {
        errdefer std.debug.print("writeFile accepted: \"{s}\"\n", .{bad});
        try testing.expectError(error.UnsafePath, writeFile(fx.tree, bad, "PWNED"));
    }
    try fx.missing("outside/planted.txt");
    try fx.missing("escape.txt");
}

test "discover lists every file under a directory with its id and skips junctions without following them" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const shadow = @import("shadow.zig");
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.tmp.dir.createDirPath(testing.io, "work/node_modules/pkg/lib");
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "work/node_modules/pkg/index.js", .data = "i\n" });
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "work/node_modules/pkg/lib/x.js", .data = "x\n" });
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    try shadow.createJunction(testing.io, try fx.abs(&link_buf, "work\\node_modules\\pkg\\escape"), try fx.abs(&target_buf, "outside"));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var wants: std.ArrayList(Want) = .empty;
    var found: Found = .{};
    try discover(arena_state.allocator(), null, fx.work, 0, "node_modules", &wants, &found);
    try discover(arena_state.allocator(), null, fx.work, 0, "vendor_missing", &wants, &found);
    try testing.expectEqual(@as(usize, 2), wants.items.len);
    try testing.expectEqual(Found{ .dirs = 3, .skipped_links = 1 }, found);
    for (wants.items) |want| try testing.expect(want.id != null);

    const stats = try fx.run(wants.items);
    try testing.expectEqual(@as(usize, 2), stats.linked);
    try fx.expect("tree/node_modules/pkg/lib/x.js", "x\n");
    try fx.missing("tree/node_modules/pkg/escape");
}

test "a failure at any step of reconcile leaves a tree that the next call makes right" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    defer injected_fault = null;
    var steps: usize = 0;
    while (steps < 64) : (steps += 1) {
        var fx = try Fixture.init();
        defer fx.deinit();
        injected_fault = null;
        _ = try fx.tracked();
        try fx.replace("work/a.ts", "a2\n");
        try fx.tmp.dir.deleteFile(testing.io, "work/src/deep/c.ts");
        try fx.tmp.dir.createDirPath(testing.io, "work/lib");
        try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "work/lib/n.ts", .data = "n1\n" });
        try fx.tmp.dir.createDirPath(testing.io, "tree/dist");
        try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "tree/dist/out.js", .data = "out\n" });
        try fx.tmp.dir.deleteFile(testing.io, "tree/src/b.ts");
        try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "tree/src/b.ts", .data = "forged\n" });

        var wants = [_]Want{
            .{ .rel = "a.ts", .source = "a.ts" },
            .{ .rel = "src/b.ts", .source = "src/b.ts" },
            .{ .rel = "src/deep/c.ts", .source = "src/deep/c.ts" },
            .{ .rel = "lib/n.ts", .source = "lib/n.ts" },
        };
        injected_fault = steps;
        const interrupted = fx.run(&wants);
        injected_fault = null;
        const finished = if (interrupted) |_| true else |err| blk: {
            try testing.expectEqual(error.GateTreeInjected, err);
            break :blk false;
        };

        var again = [_]Want{
            .{ .rel = "a.ts", .source = "a.ts" },
            .{ .rel = "src/b.ts", .source = "src/b.ts" },
            .{ .rel = "src/deep/c.ts", .source = "src/deep/c.ts" },
            .{ .rel = "lib/n.ts", .source = "lib/n.ts" },
        };
        _ = try fx.run(&again);
        errdefer std.debug.print("after a fault at step {d}\n", .{steps});
        try fx.expect("tree/a.ts", "a2\n");
        try fx.expect("tree/src/b.ts", "b1\n");
        try fx.expect("tree/lib/n.ts", "n1\n");
        try fx.missing("tree/src/deep/c.ts");
        try fx.missing("tree/dist");
        try testing.expect(try fx.sameFile("work/a.ts", "tree/a.ts"));
        try testing.expect(try fx.sameFile("work/src/b.ts", "tree/src/b.ts"));
        try fx.expect("work/src/b.ts", "b1\n");
        var proof = [_]Want{
            .{ .rel = "a.ts", .source = "a.ts" },
            .{ .rel = "src/b.ts", .source = "src/b.ts" },
            .{ .rel = "src/deep/c.ts", .source = "src/deep/c.ts" },
            .{ .rel = "lib/n.ts", .source = "lib/n.ts" },
        };
        try testing.expectEqual(Stats{ .kept = 3, .absent = 1 }, try fx.run(&proof));
        if (finished) {
            try testing.expect(steps >= 6);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "removeAll empties the tree without touching the files it links to" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    _ = try fx.tracked();
    try testing.expectEqual(@as(usize, 5), try removeAll(fx.tree));
    try fx.missing("tree/a.ts");
    try fx.missing("tree/src");
    try fx.expect("work/src/deep/c.ts", "c1\n");
}
