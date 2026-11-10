const std = @import("std");
const builtin = @import("builtin");
const sandbox = @import("sandbox.zig");
const open_nowait = @import("open_nowait.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const flate = std.compress.flate;
const Sha1 = std.crypto.hash.Sha1;

pub const Kind = enum(u3) { commit = 1, tree = 2, blob = 3, tag = 4 };

pub const Object = struct {
    kind: Kind,
    data: []const u8,
};

pub const Oid = [20]u8;

const blocking_env = [_][]const u8{
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_COMMON_DIR",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_REPLACE_REF_BASE",
    "GIT_NO_REPLACE_OBJECTS",
    "GIT_GRAFT_FILE",
    "GIT_SHALLOW_FILE",
    "GIT_CONFIG_PARAMETERS",
    "GIT_CONFIG_COUNT",
    "GIT_ICASE_PATHSPECS",
    "GIT_LITERAL_PATHSPECS",
    "GIT_GLOB_PATHSPECS",
    "GIT_NOGLOB_PATHSPECS",
};

const blocking_config = [_][]const u8{ "objectformat", "refstorage", "worktree", "usereplacerefs", "grafts" };

const max_object_bytes = 512 * 1024 * 1024;
const max_chain = 10_000;
const max_ref_depth = 64;

pub const Store = struct {
    arena: Allocator,
    io: std.Io,
    objects: []const u8,
    window: []u8,
    packs: ?[]const []const u8 = null,

    pub fn open(arena: Allocator, io: std.Io, git_dir: []const u8, env: ?*const std.process.Environ.Map) !?Store {
        if (builtin.os.tag != .windows) return null;
        for (blocking_env) |name| {
            if (try envSet(arena, env, name)) return null;
        }
        const common = try commonDir(arena, io, git_dir) orelse return null;
        for ([_][]const u8{ "info/grafts", "shallow", "reftable", "refs/replace", "objects/info/alternates", "objects/info/http-alternates" }) |rest| {
            if (try present(arena, io, common, rest)) return null;
        }
        for ([_][]const u8{ git_dir, common }) |dir| {
            if (!try plainConfig(arena, io, dir)) return null;
        }
        const refs = readSmall(arena, io, try std.fs.path.join(arena, &.{ common, "packed-refs" }), 64 * 1024 * 1024) catch return null;
        if (refs) |text| {
            if (std.mem.indexOf(u8, text, "refs/replace/") != null) return null;
        }
        return .{
            .arena = arena,
            .io = io,
            .objects = try std.fs.path.join(arena, &.{ common, "objects" }),
            .window = try arena.alloc(u8, flate.max_window_len),
        };
    }

    pub fn read(self: *Store, hex: []const u8) !?Object {
        const oid = parseHex(hex) orelse return null;
        return self.readOid(oid, 0) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => null,
        };
    }

    fn readOid(self: *Store, oid: Oid, depth: usize) anyerror!Object {
        if (depth > max_ref_depth) return error.TooDeep;
        const object = (try self.loose(oid)) orelse (try self.packed_(oid, depth)) orelse return error.NotFound;
        if (!std.mem.eql(u8, &hashOf(object), &oid)) return error.HashMismatch;
        return object;
    }

    fn loose(self: *Store, oid: Oid) !?Object {
        const hex = std.fmt.bytesToHex(oid, .lower);
        const path = try std.fmt.allocPrint(self.arena, "{s}\\{s}\\{s}", .{ self.objects, hex[0..2], hex[2..] });
        const bytes = Dir.cwd().readFileAlloc(self.io, path, self.arena, .limited(max_object_bytes)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        var input: std.Io.Reader = .fixed(bytes);
        var inflate: flate.Decompress = .init(&input, .zlib, self.window);
        const whole = try inflate.reader.allocRemaining(self.arena, .limited(max_object_bytes + 64));
        const nul = std.mem.indexOfScalar(u8, whole, 0) orelse return error.BadLoose;
        const space = std.mem.indexOfScalar(u8, whole[0..nul], ' ') orelse return error.BadLoose;
        const kind = kindNamed(whole[0..space]) orelse return error.BadLoose;
        const size = std.fmt.parseInt(usize, whole[space + 1 .. nul], 10) catch return error.BadLoose;
        if (whole.len - nul - 1 != size) return error.BadLoose;
        return .{ .kind = kind, .data = whole[nul + 1 ..] };
    }

    fn packList(self: *Store) ![]const []const u8 {
        if (self.packs) |known| return known;
        var list: std.ArrayList([]const u8) = .empty;
        const pack_dir = try std.fs.path.join(self.arena, &.{ self.objects, "pack" });
        var dir = Dir.openDirAbsolute(self.io, pack_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                self.packs = &.{};
                return &.{};
            },
            else => return err,
        };
        defer dir.close(self.io);
        var entries = dir.iterate();
        while (try entries.next(self.io)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
            const stem = entry.name[0 .. entry.name.len - ".idx".len];
            try list.append(self.arena, try std.fmt.allocPrint(self.arena, "{s}\\{s}", .{ pack_dir, stem }));
        }
        self.packs = list.items;
        return list.items;
    }

    fn packed_(self: *Store, oid: Oid, depth: usize) !?Object {
        for (try self.packList()) |stem| {
            const offset = (try self.lookup(stem, oid)) orelse continue;
            return try self.unpack(stem, offset, depth);
        }
        return null;
    }

    fn lookup(self: *Store, stem: []const u8, oid: Oid) !?u64 {
        const path = try std.fmt.allocPrint(self.arena, "{s}.idx", .{stem});
        const file = try Dir.openFileAbsolute(self.io, path, .{});
        defer file.close(self.io);
        var head: [8 + 1024]u8 = undefined;
        try readAt(self.io, file, &head, 0);
        if (!std.mem.eql(u8, head[0..8], &.{ 0xff, 't', 'O', 'c', 0, 0, 0, 2 })) return error.UnsupportedIndex;
        const fan = head[8..];
        const count: u64 = std.mem.readInt(u32, fan[255 * 4 ..][0..4], .big);
        var low: u64 = if (oid[0] == 0) 0 else std.mem.readInt(u32, fan[(@as(usize, oid[0]) - 1) * 4 ..][0..4], .big);
        var high: u64 = std.mem.readInt(u32, fan[@as(usize, oid[0]) * 4 ..][0..4], .big);
        if (high > count or low > high) return error.BadIndex;
        const names: u64 = 8 + 1024;
        while (low < high) {
            const mid = low + (high - low) / 2;
            var name: Oid = undefined;
            try readAt(self.io, file, &name, names + mid * 20);
            switch (std.mem.order(u8, &name, &oid)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => {
                    var small: [4]u8 = undefined;
                    try readAt(self.io, file, &small, names + count * 24 + mid * 4);
                    const value = std.mem.readInt(u32, &small, .big);
                    if (value & 0x80000000 == 0) return value;
                    var large: [8]u8 = undefined;
                    try readAt(self.io, file, &large, names + count * 28 + @as(u64, value & 0x7fffffff) * 8);
                    return std.mem.readInt(u64, &large, .big);
                },
            }
        }
        return null;
    }

    fn unpack(self: *Store, stem: []const u8, offset: u64, depth: usize) !Object {
        const path = try std.fmt.allocPrint(self.arena, "{s}.pack", .{stem});
        const file = try Dir.openFileAbsolute(self.io, path, .{});
        defer file.close(self.io);
        var buffer: [16 * 1024]u8 = undefined;
        var reader = file.reader(self.io, &buffer);
        var deltas: std.ArrayList([]const u8) = .empty;
        var at = offset;
        var base: Object = undefined;
        while (true) {
            if (deltas.items.len > max_chain) return error.ChainTooLong;
            try reader.seekTo(at);
            const in = &reader.interface;
            var byte = try in.takeByte();
            const code: u3 = @truncate(byte >> 4);
            var size: u64 = byte & 0x0f;
            var shift: u6 = 4;
            while (byte & 0x80 != 0) {
                if (shift > 57) return error.BadPack;
                byte = try in.takeByte();
                size |= @as(u64, byte & 0x7f) << shift;
                shift += 7;
            }
            if (size > max_object_bytes) return error.TooLarge;
            switch (code) {
                1, 2, 3, 4 => {
                    base = .{ .kind = @enumFromInt(code), .data = try self.inflateExact(in, @intCast(size)) };
                    break;
                },
                6 => {
                    byte = try in.takeByte();
                    var back: u64 = byte & 0x7f;
                    while (byte & 0x80 != 0) {
                        if (back > (std.math.maxInt(u64) >> 8)) return error.BadPack;
                        byte = try in.takeByte();
                        back = ((back + 1) << 7) | (byte & 0x7f);
                    }
                    if (back == 0 or back > at) return error.BadPack;
                    try deltas.append(self.arena, try self.inflateExact(in, @intCast(size)));
                    at -= back;
                },
                7 => {
                    var base_oid: Oid = undefined;
                    try in.readSliceAll(&base_oid);
                    try deltas.append(self.arena, try self.inflateExact(in, @intCast(size)));
                    base = try self.readOid(base_oid, depth + 1);
                    break;
                },
                else => return error.BadPack,
            }
        }
        var data = base.data;
        var i = deltas.items.len;
        while (i > 0) {
            i -= 1;
            data = try applyDelta(self.arena, data, deltas.items[i]);
        }
        return .{ .kind = base.kind, .data = data };
    }

    fn inflateExact(self: *Store, in: *std.Io.Reader, size: usize) ![]u8 {
        var inflate: flate.Decompress = .init(in, .zlib, self.window);
        const out = try self.arena.alloc(u8, size);
        try inflate.reader.readSliceAll(out);
        return out;
    }

    pub fn treeOf(self: *Store, hex: []const u8) !?Oid {
        const object = (try self.read(hex)) orelse return null;
        return switch (object.kind) {
            .tree => parseHex(hex),
            .commit => commitTree(object.data),
            else => null,
        };
    }

    pub fn parents(self: *Store, hex: []const u8) !?[]const []const u8 {
        const object = (try self.read(hex)) orelse return null;
        if (object.kind != .commit) return null;
        _ = commitTree(object.data) orelse return null;
        var list: std.ArrayList([]const u8) = .empty;
        var rest = object.data["tree ".len + 41 ..];
        while (std.mem.startsWith(u8, rest, "parent ")) {
            if (rest.len < "parent ".len + 41 or rest["parent ".len + 40] != '\n') return null;
            const id = rest["parent ".len..][0..40];
            _ = parseHex(id) orelse return null;
            try list.append(self.arena, id);
            rest = rest["parent ".len + 41 ..];
        }
        return list.items;
    }

    pub fn entriesAt(self: *Store, rev: []const u8, paths: []const []const u8, out: anytype) !bool {
        const root = (try self.treeOf(rev)) orelse return false;
        for (paths) |path| {
            if (!plainPath(path)) return false;
            for (paths) |other| {
                if (other.len > path.len and other[path.len] == '/' and std.mem.startsWith(u8, other, path)) return false;
            }
        }
        for (paths, 0..) |path, n| {
            for (paths[0..n]) |earlier| {
                if (std.mem.eql(u8, earlier, path)) break;
            } else {
                var tree = root;
                var parts = std.mem.splitScalar(u8, path, '/');
                while (parts.next()) |part| {
                    const listed = try self.readTree(tree) orelse return false;
                    const found = (try findEntry(listed, part)) orelse break;
                    if (parts.peek() == null) {
                        try out.add(path, found.mode, found.oid);
                        break;
                    }
                    if (found.mode != 0o040000) break;
                    tree = found.oid;
                }
            }
        }
        return true;
    }

    pub fn listing(self: *Store, rev: []const u8) !?[]u8 {
        const root = (try self.treeOf(rev)) orelse return null;
        var out: std.ArrayList(u8) = .empty;
        var prefix: std.ArrayList(u8) = .empty;
        if (!try self.walk(root, &prefix, &out)) return null;
        return out.items;
    }

    fn walk(self: *Store, tree: Oid, prefix: *std.ArrayList(u8), out: *std.ArrayList(u8)) !bool {
        const data = (try self.readTree(tree)) orelse return false;
        var pos: usize = 0;
        while (try nextEntry(data, &pos)) |entry| {
            const mark = prefix.items.len;
            try prefix.appendSlice(self.arena, entry.name);
            if (entry.mode == 0o040000) {
                try prefix.append(self.arena, '/');
                if (!try self.walk(entry.oid, prefix, out)) return false;
            } else {
                try out.print(self.arena, "{o:0>6} {s} {s}\t{s}\x00", .{ entry.mode, kindOfMode(entry.mode), std.fmt.bytesToHex(entry.oid, .lower), prefix.items });
            }
            prefix.shrinkRetainingCapacity(mark);
        }
        return true;
    }

    fn readTree(self: *Store, oid: Oid) !?[]const u8 {
        const hex = std.fmt.bytesToHex(oid, .lower);
        const object = (try self.read(&hex)) orelse return null;
        if (object.kind != .tree) return null;
        var pos: usize = 0;
        while (nextEntry(object.data, &pos) catch return null) |_| {}
        return object.data;
    }

    pub fn writeTree(self: *Store, lines: []const u8) !?[]const u8 {
        const root = self.buildRoot(lines) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        } orelse return null;
        return try self.arena.dupe(u8, &std.fmt.bytesToHex(root, .lower));
    }

    fn buildRoot(self: *Store, lines: []const u8) !?Oid {
        var items: std.ArrayList(Item) = .empty;
        var records = std.mem.splitScalar(u8, lines, 0);
        while (records.next()) |record| {
            if (record.len == 0) {
                if (records.peek() != null) return null;
                break;
            }
            try items.append(self.arena, parseRecord(record) orelse return null);
        }
        if (!try sameNamesOnce(self.arena, items.items)) return null;
        for (items.items) |item| {
            if (item.mode == 0o160000) continue;
            if (!try self.has(item.oid)) return null;
        }
        std.mem.sort(Item, items.items, {}, struct {
            fn lessThan(_: void, a: Item, b: Item) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.lessThan);
        return try self.build(items.items, 0);
    }

    fn build(self: *Store, items: []const Item, base: usize) !Oid {
        var body: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < items.len) {
            const rest = items[i].path[base..];
            if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
                const name = rest[0..slash];
                var end = i + 1;
                while (end < items.len and under(items[end].path, base, name)) end += 1;
                const sub = try self.build(items[i..end], base + slash + 1);
                try body.print(self.arena, "40000 {s}\x00", .{name});
                try body.appendSlice(self.arena, &sub);
                i = end;
            } else {
                try body.print(self.arena, "{o} {s}\x00", .{ items[i].mode, rest });
                try body.appendSlice(self.arena, &items[i].oid);
                i += 1;
            }
        }
        return self.put(.tree, body.items);
    }

    fn has(self: *Store, oid: Oid) !bool {
        const hex = std.fmt.bytesToHex(oid, .lower);
        if (try present(self.arena, self.io, self.objects, &(hex[0..2].* ++ "\\".* ++ hex[2..].*))) return true;
        for (try self.packList()) |stem| {
            if (try self.lookup(stem, oid) != null) return true;
        }
        return false;
    }

    pub fn putObject(self: *Store, kind: Kind, data: []const u8) !Oid {
        return self.put(kind, data);
    }

    fn put(self: *Store, kind: Kind, data: []const u8) !Oid {
        const oid = hashOf(.{ .kind = kind, .data = data });
        if (try self.freshen(oid)) return oid;
        const hex = std.fmt.bytesToHex(oid, .lower);
        const dir = try std.fmt.allocPrint(self.arena, "{s}\\{s}", .{ self.objects, hex[0..2] });
        try Dir.cwd().createDirPath(self.io, dir);
        var random: [8]u8 = undefined;
        self.io.random(&random);
        const temp = try std.fmt.allocPrint(self.arena, "{s}\\tmp_obj_{s}", .{ dir, std.fmt.bytesToHex(random, .lower) });
        const final = try std.fmt.allocPrint(self.arena, "{s}\\{s}", .{ dir, hex[2..] });
        const packed_bytes = try deflate(self.arena, kind, data);
        {
            const file = try Dir.cwd().createFile(self.io, temp, .{ .exclusive = true });
            defer file.close(self.io);
            errdefer Dir.cwd().deleteFile(self.io, temp) catch {};
            try file.writeStreamingAll(self.io, packed_bytes);
            try file.sync(self.io);
        }
        Dir.renamePreserve(Dir.cwd(), temp, Dir.cwd(), final, self.io) catch |err| {
            Dir.cwd().deleteFile(self.io, temp) catch {};
            if (err != error.PathAlreadyExists) return err;
        };
        return oid;
    }

    fn freshen(self: *Store, oid: Oid) !bool {
        const hex = std.fmt.bytesToHex(oid, .lower);
        for (try self.packList()) |stem| {
            if (try self.lookup(stem, oid) == null) continue;
            const pack = try std.fmt.allocPrint(self.arena, "{s}.pack", .{stem});
            if (open_nowait.touch(pack)) |_| return true else |_| {}
        }
        const path = try std.fmt.allocPrint(self.arena, "{s}\\{s}\\{s}", .{ self.objects, hex[0..2], hex[2..] });
        open_nowait.touch(path) catch return false;
        return true;
    }
};

const Item = struct {
    path: []const u8,
    mode: u32,
    oid: Oid,
};

fn parseRecord(record: []const u8) ?Item {
    const tab = std.mem.indexOfScalar(u8, record, '\t') orelse return null;
    var fields = std.mem.splitScalar(u8, record[0..tab], ' ');
    const mode_text = fields.next() orelse return null;
    const kind = fields.next() orelse return null;
    const hex = fields.next() orelse return null;
    if (fields.next() != null) return null;
    const mode: u32 = for ([_]u32{ 0o100644, 0o100755, 0o120000, 0o160000 }) |known| {
        var buffer: [8]u8 = undefined;
        if (std.mem.eql(u8, mode_text, std.fmt.bufPrint(&buffer, "{o}", .{known}) catch unreachable)) break known;
    } else return null;
    if (!std.mem.eql(u8, kind, kindOfMode(mode))) return null;
    const path = record[tab + 1 ..];
    if (!safePath(path, mode == 0o120000)) return null;
    return .{ .path = path, .mode = mode, .oid = parseHex(hex) orelse return null };
}

const reserved_names = [_][]const u8{ "con", "prn", "aux", "nul", "conin$", "conout$", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9" };

fn safePath(path: []const u8, link: bool) bool {
    if (path.len == 0) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        for (part) |c| {
            if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-_.+=,@#$%&()[]{}!' ^", c) == null) return false;
        }
        if (part[part.len - 1] == '.' or part[part.len - 1] == ' ') return false;
        if (std.ascii.eqlIgnoreCase(part, ".git")) return false;
        if (link and part[0] == '.') return false;
        const stem = std.mem.trimEnd(u8, part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len], " ");
        for (reserved_names) |name| {
            if (std.ascii.eqlIgnoreCase(stem, name)) return false;
        }
    }
    return true;
}

fn sameNamesOnce(arena: Allocator, items: []const Item) !bool {
    var seen: std.StringHashMapUnmanaged(struct { exact: []const u8, dir: bool }) = .empty;
    for (items) |item| {
        var at: usize = 0;
        while (std.mem.indexOfScalarPos(u8, item.path, at, '/')) |slash| : (at = slash + 1) {
            const dir = item.path[0..slash];
            const key = try std.ascii.allocLowerString(arena, dir);
            const slot = try seen.getOrPut(arena, key);
            if (slot.found_existing) {
                if (!slot.value_ptr.dir or !std.mem.eql(u8, slot.value_ptr.exact, dir)) return false;
            } else slot.value_ptr.* = .{ .exact = dir, .dir = true };
        }
        const slot = try seen.getOrPut(arena, try std.ascii.allocLowerString(arena, item.path));
        if (slot.found_existing) return false;
        slot.value_ptr.* = .{ .exact = item.path, .dir = false };
    }
    return true;
}

fn under(path: []const u8, base: usize, name: []const u8) bool {
    return path.len > base + name.len and std.mem.eql(u8, path[base..][0..name.len], name) and path[base + name.len] == '/';
}

fn deflate(arena: Allocator, kind: Kind, data: []const u8) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(arena, data.len / 2 + 64);
    const window = try arena.alloc(u8, flate.max_window_len);
    var compress = try flate.Compress.init(&out.writer, window, .zlib, .default);
    try compress.writer.print("{s} {d}\x00", .{ @tagName(kind), data.len });
    try compress.writer.writeAll(data);
    try compress.finish();
    return out.written();
}

pub const Entry = struct {
    mode: u32,
    name: []const u8,
    oid: Oid,
};

pub fn nextEntry(data: []const u8, pos: *usize) !?Entry {
    if (pos.* == data.len) return null;
    const rest = data[pos.*..];
    const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.BadTree;
    const mode = std.fmt.parseInt(u32, rest[0..space], 8) catch return error.BadTree;
    switch (mode) {
        0o100644, 0o100755, 0o120000, 0o040000, 0o160000 => {},
        else => return error.BadTree,
    }
    if (rest[0] == '0') return error.BadTree;
    const nul = std.mem.indexOfScalarPos(u8, rest, space + 1, 0) orelse return error.BadTree;
    const name = rest[space + 1 .. nul];
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.BadTree;
    if (rest.len < nul + 1 + 20) return error.BadTree;
    pos.* += nul + 1 + 20;
    return .{ .mode = mode, .name = name, .oid = rest[nul + 1 ..][0..20].* };
}

fn findEntry(data: []const u8, name: []const u8) !?Entry {
    var pos: usize = 0;
    while (try nextEntry(data, &pos)) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

pub fn kindOfMode(mode: u32) []const u8 {
    return switch (mode) {
        0o040000 => "tree",
        0o160000 => "commit",
        else => "blob",
    };
}

fn commitTree(data: []const u8) ?Oid {
    if (!std.mem.startsWith(u8, data, "tree ") or data.len < "tree ".len + 41 or data["tree ".len + 40] != '\n') return null;
    return parseHex(data["tree ".len..][0..40]);
}

fn plainPath(path: []const u8) bool {
    if (path.len == 0 or path[0] == ':' or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

pub fn parseHex(hex: []const u8) ?Oid {
    if (hex.len != 40) return null;
    for (hex) |c| {
        if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return null;
    }
    var oid: Oid = undefined;
    _ = std.fmt.hexToBytes(&oid, hex) catch return null;
    return oid;
}

fn kindNamed(name: []const u8) ?Kind {
    inline for (.{ .commit, .tree, .blob, .tag }) |kind| {
        if (std.mem.eql(u8, name, @tagName(kind))) return kind;
    }
    return null;
}

pub fn hashOf(object: Object) Oid {
    var hasher = Sha1.init(.{});
    var header: [32]u8 = undefined;
    hasher.update(std.fmt.bufPrint(&header, "{s} {d}\x00", .{ @tagName(object.kind), object.data.len }) catch unreachable);
    hasher.update(object.data);
    return hasher.finalResult();
}

fn readVarint(delta: []const u8, pos: *usize) !u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (pos.* >= delta.len or shift > 63) return error.BadDelta;
        const byte = delta[pos.*];
        pos.* += 1;
        value |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return value;
        if (shift > 56) return error.BadDelta;
        shift += 7;
    }
}

pub fn applyDelta(arena: Allocator, base: []const u8, delta: []const u8) ![]u8 {
    var pos: usize = 0;
    if (try readVarint(delta, &pos) != base.len) return error.BadDelta;
    const wanted = try readVarint(delta, &pos);
    if (wanted > max_object_bytes) return error.TooLarge;
    const out = try arena.alloc(u8, @intCast(wanted));
    var made: usize = 0;
    while (pos < delta.len) {
        const op = delta[pos];
        pos += 1;
        if (op & 0x80 != 0) {
            var from: usize = 0;
            var len: usize = 0;
            inline for (0..4) |bit| {
                if (op & (1 << bit) != 0) {
                    if (pos >= delta.len) return error.BadDelta;
                    from |= @as(usize, delta[pos]) << (8 * bit);
                    pos += 1;
                }
            }
            inline for (0..3) |bit| {
                if (op & (0x10 << bit) != 0) {
                    if (pos >= delta.len) return error.BadDelta;
                    len |= @as(usize, delta[pos]) << (8 * bit);
                    pos += 1;
                }
            }
            if (len == 0) len = 0x10000;
            if (from + len > base.len or made + len > out.len) return error.BadDelta;
            @memcpy(out[made..][0..len], base[from..][0..len]);
            made += len;
        } else if (op != 0) {
            if (pos + op > delta.len or made + op > out.len) return error.BadDelta;
            @memcpy(out[made..][0..op], delta[pos..][0..op]);
            pos += op;
            made += op;
        } else return error.BadDelta;
    }
    if (made != out.len) return error.BadDelta;
    return out;
}

fn readAt(io: std.Io, file: std.Io.File, buffer: []u8, offset: u64) !void {
    if (try file.readPositionalAll(io, buffer, offset) != buffer.len) return error.Truncated;
}

fn envSet(arena: Allocator, env: ?*const std.process.Environ.Map, name: []const u8) !bool {
    if (env) |map| return map.get(name) != null;
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(arena, name);
    return try sandbox.environmentValue(arena, wide) != null;
}

fn commonDir(arena: Allocator, io: std.Io, git_dir: []const u8) !?[]const u8 {
    const named = readSmall(arena, io, try std.fs.path.join(arena, &.{ git_dir, "commondir" }), 4096) catch return null;
    const text = named orelse return git_dir;
    const line = std.mem.trimEnd(u8, text, "\r\n");
    if (line.len == 0 or std.mem.indexOfAny(u8, line, "\r\n") != null) return null;
    if (std.fs.path.isAbsolute(line)) return line;
    return try std.fs.path.resolve(arena, &.{ git_dir, line });
}

fn present(arena: Allocator, io: std.Io, dir: []const u8, rest: []const u8) !bool {
    const path = try std.fs.path.join(arena, &.{ dir, rest });
    _ = Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return true,
    };
    return true;
}

fn plainConfig(arena: Allocator, io: std.Io, dir: []const u8) !bool {
    const text = (readSmall(arena, io, try std.fs.path.join(arena, &.{ dir, "config" }), 16 * 1024 * 1024) catch return false) orelse return true;
    for (blocking_config) |word| {
        if (std.ascii.findIgnoreCase(text, word) != null) return false;
    }
    return true;
}

fn readSmall(arena: Allocator, io: std.Io, path: []const u8, limit: usize) !?[]u8 {
    return Dir.cwd().readFileAlloc(io, path, arena, .limited(limit)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}
