const std = @import("std");
const json_input = @import("json_input.zig");
const lockdown_slash = @import("../platform/lockdown_slash.zig");
const open_nowait = @import("../platform/open_nowait.zig");
const shadow_root = @import("../platform/shadow_root.zig");

const Allocator = std.mem.Allocator;
const Map = std.process.Environ.Map;

pub const hook_args = lockdown_slash.session_args;
pub const path_variable = lockdown_slash.context_variable;
pub const project_variable = "CLAUDE_PROJECT_DIR";
pub const session_variable = "CLAUDE_CODE_SESSION_ID";
pub const max_input_bytes = 4 * 1024 * 1024;
pub const max_epoch_bytes = 1024;
const write_attempts = 3;

pub fn path(gpa: Allocator, env: *const Map) Allocator.Error!?[]u8 {
    if (env.get(path_variable)) |given| {
        if (given.len != 0) return try gpa.dupe(u8, given);
    }
    const local = env.get(lockdown_slash.local_app_data_variable) orelse return null;
    const project = env.get(project_variable) orelse return null;
    if (local.len == 0 or project.len == 0) return null;
    const key = shadow_root.repoKey(project);
    return try std.fmt.allocPrint(gpa, "{s}\\emetgate\\{s}\\{s}{s}", .{ local, lockdown_slash.context_dir, &key, lockdown_slash.context_extension });
}

pub const Watch = struct {
    gpa: Allocator,
    path: ?[]u8 = null,
    session: ?[]u8 = null,
    last: ?u64 = null,
    armed: bool = false,

    pub fn init(gpa: Allocator, env: ?*const Map) Watch {
        const map = env orelse return .{ .gpa = gpa };
        const file = path(gpa, map) catch null;
        const session = if (map.get(session_variable)) |id| gpa.dupe(u8, id) catch null else null;
        return .{ .gpa = gpa, .path = file, .session = session };
    }

    pub fn deinit(self: *Watch) void {
        if (self.path) |owned| self.gpa.free(owned);
        if (self.session) |owned| self.gpa.free(owned);
        self.* = undefined;
    }

    pub fn stale(self: *Watch) bool {
        const file = self.path orelse return true;
        const bytes = open_nowait.readFileAlloc(self.gpa, file, max_epoch_bytes) catch return true;
        defer self.gpa.free(bytes);
        const now = std.hash.Wyhash.hash(0, bytes);
        const before = self.last;
        self.last = now;
        const seen = before orelse {
            self.armed = self.ownSession(bytes);
            return true;
        };
        if (seen == now) return !self.armed;
        self.armed = true;
        return true;
    }

    fn ownSession(self: *const Watch, bytes: []const u8) bool {
        const own = self.session orelse return false;
        if (own.len == 0) return false;
        const line = std.mem.trim(u8, bytes, " \r\n");
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse return false;
        return std.mem.eql(u8, line[space + 1 ..], own);
    }
};

fn sessionOf(arena: Allocator, input: []const u8) []const u8 {
    const parsed = json_input.parseLeaky(std.json.Value, arena, input, .{}) catch return "";
    if (parsed != .object) return "";
    const id = parsed.object.get("session_id") orelse return "";
    if (id != .string or id.string.len > max_epoch_bytes / 2) return "";
    for (id.string) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return "";
    }
    return id.string;
}

fn write(gpa: Allocator, io: std.Io, file: []const u8, text: []const u8) !void {
    if (std.fs.path.dirname(file)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    var attempt: usize = 1;
    while (true) : (attempt += 1) {
        lockdown_slash.place(gpa, io, file, text) catch |err| {
            if (err == error.OutOfMemory or attempt == write_attempts) return err;
            continue;
        };
        return;
    }
}

pub fn record(gpa: Allocator, io: std.Io, file: []const u8, input: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var token: [16]u8 = undefined;
    io.random(&token);
    const text = try std.fmt.allocPrint(arena, "{x} {s}\n", .{ &token, sessionOf(arena, input) });
    write(gpa, io, file, text) catch |err| {
        std.Io.Dir.cwd().deleteFile(io, file) catch {};
        return err;
    };
}

pub fn hook(gpa: Allocator, io: std.Io, env: *const Map, input: []const u8) !void {
    const file = (try path(gpa, env)) orelse return;
    defer gpa.free(file);
    try record(gpa, io, file, input);
}
