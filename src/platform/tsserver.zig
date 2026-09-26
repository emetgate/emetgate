const std = @import("std");
const sandbox = @import("sandbox.zig");
const registry = @import("../engine/lang/registry.zig");
const rename = @import("../engine/rename.zig");

const Allocator = std.mem.Allocator;
const MultiReader = std.Io.File.MultiReader;

pub const host_script = @embedFile("tsserver_host.js");

pub const default_timeout_ms: u64 = 30_000;
const max_response_bytes = 64 * 1024 * 1024;
const max_listing_bytes = 64 * 1024 * 1024;

pub const Error = error{
    TypeScriptNotInstalled,
    NodeNotFound,
    LanguageServiceTimeout,
    LanguageServiceExited,
    LanguageServiceProtocol,
    LanguageServiceFailed,
};

pub const Location = struct {
    file: []const u8,
    start: u32,
    end: u32,
    prefix: bool = false,
    definition: bool = false,
};

pub const Change = struct {
    file: []const u8,
    start: u32,
    end: u32,
    text: []const u8,
};

pub const Answer = struct {
    id: u64 = 0,
    ok: bool = false,
    @"error": []const u8 = "",
    version: []const u8 = "",
    can_rename: bool = false,
    reason: []const u8 = "",
    locations: []Location = &.{},
    references: []Location = &.{},
    changes: []Change = &.{},
};

pub const Parsed = std.json.Parsed(Answer);

pub const Options = struct {
    timeout_ms: u64 = default_timeout_ms,
    node: []const u8 = "node",
};

pub const Client = struct {
    gpa: Allocator,
    io: std.Io,
    root: []u8,
    options: Options,
    service: ?sandbox.Service = null,
    streams: MultiReader.Buffer(1) = undefined,
    reader: MultiReader = undefined,
    next_id: u64 = 1,
    starts: usize = 0,
    version: ?[]u8 = null,

    pub fn create(gpa: Allocator, io: std.Io, root: []const u8, options: Options) !*Client {
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .root = try gpa.dupe(u8, root), .options = options };
        return self;
    }

    pub fn destroy(self: *Client) void {
        self.stop();
        self.gpa.free(self.root);
        self.gpa.destroy(self);
    }

    pub fn running(self: *const Client) bool {
        const service = self.service orelse return false;
        return service.running();
    }

    pub fn stop(self: *Client) void {
        if (self.service) |*service| {
            self.reader.deinit();
            service.stop();
            self.service = null;
        }
        if (self.version) |v| self.gpa.free(v);
        self.version = null;
    }

    fn start(self: *Client) !void {
        self.stop();
        const marker = try std.fmt.allocPrint(self.gpa, "{s}\\node_modules\\typescript\\package.json", .{self.root});
        defer self.gpa.free(marker);
        std.Io.Dir.cwd().access(self.io, marker, .{}) catch return error.TypeScriptNotInstalled;
        const argv = [_][]const u8{ self.options.node, "-e", host_script, self.root };
        self.service = sandbox.spawnService(self.gpa, &argv, self.root) catch |err| switch (err) {
            error.FileNotFound, error.InvalidExe => return error.NodeNotFound,
            else => |e| return e,
        };
        self.starts += 1;
        self.reader.init(self.gpa, self.io, self.streams.toStreams(), &.{self.service.?.stdout});
        const pong = try self.exchange("{\"op\":\"ping\"", "}");
        defer pong.deinit();
        self.version = try self.gpa.dupe(u8, pong.value.version);
    }

    pub fn ensure(self: *Client) !void {
        if (self.running()) return;
        try self.start();
    }

    pub fn rename(self: *Client, file: []const u8, offset: u32) !Parsed {
        return self.ask("rename", file, offset);
    }

    pub fn references(self: *Client, file: []const u8, offset: u32) !Parsed {
        return self.ask("references", file, offset);
    }

    pub fn fileRename(self: *Client, file: []const u8, target: []const u8) !Parsed {
        try self.ensure();
        const files = try programFiles(self.gpa, self.io, self.root);
        defer freeFiles(self.gpa, files);
        var head: std.Io.Writer.Allocating = .init(self.gpa);
        defer head.deinit();
        var js: std.json.Stringify = .{ .writer = &head.writer };
        try js.beginObject();
        try js.objectField("op");
        try js.write("fileRename");
        try js.objectField("file");
        try js.write(file);
        try js.objectField("target");
        try js.write(target);
        try js.objectField("files");
        try js.write(files);
        return self.exchange(head.written(), "}");
    }

    fn ask(self: *Client, op: []const u8, file: []const u8, offset: u32) !Parsed {
        try self.ensure();
        const files = try programFiles(self.gpa, self.io, self.root);
        defer freeFiles(self.gpa, files);
        var head: std.Io.Writer.Allocating = .init(self.gpa);
        defer head.deinit();
        var js: std.json.Stringify = .{ .writer = &head.writer };
        try js.beginObject();
        try js.objectField("op");
        try js.write(op);
        try js.objectField("file");
        try js.write(file);
        try js.objectField("offset");
        try js.write(offset);
        try js.objectField("files");
        try js.write(files);
        return self.exchange(head.written(), "}");
    }

    fn exchange(self: *Client, head: []const u8, tail: []const u8) !Parsed {
        const id = self.next_id;
        self.next_id += 1;
        const line = try std.fmt.allocPrint(self.gpa, "{s},\"id\":{d}{s}\n", .{ head, id, tail });
        defer self.gpa.free(line);
        errdefer |err| if (err != error.LanguageServiceFailed) self.stop();
        self.service.?.stdin.writeStreamingAll(self.io, line) catch return error.LanguageServiceExited;
        const response = try self.readLine();
        defer self.gpa.free(response);
        const parsed = std.json.parseFromSlice(Answer, self.gpa, response, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.LanguageServiceProtocol;
        errdefer parsed.deinit();
        if (parsed.value.id != id) return error.LanguageServiceProtocol;
        if (!parsed.value.ok) return error.LanguageServiceFailed;
        return parsed;
    }

    fn readLine(self: *Client) ![]u8 {
        const timeout: std.Io.Timeout = .{ .duration = .{
            .raw = .{ .nanoseconds = @as(i96, self.options.timeout_ms) * std.time.ns_per_ms },
            .clock = .awake,
        } };
        const deadline = timeout.toDeadline(self.io).deadline;
        const r = self.reader.reader(0);
        while (true) {
            const pending = r.buffered();
            if (std.mem.indexOfScalar(u8, pending, '\n')) |at| {
                const line = try self.gpa.dupe(u8, std.mem.trimEnd(u8, pending[0..at], "\r"));
                r.toss(at + 1);
                return line;
            }
            if (pending.len > max_response_bytes) return error.LanguageServiceProtocol;
            if (std.Io.Clock.Timestamp.now(self.io, .awake).compare(.gte, deadline)) return error.LanguageServiceTimeout;
            self.reader.fill(4096, .{ .deadline = deadline }) catch |err| switch (err) {
                error.Timeout => return error.LanguageServiceTimeout,
                error.EndOfStream => return error.LanguageServiceExited,
                else => return error.LanguageServiceExited,
            };
            self.reader.checkAnyError() catch return error.LanguageServiceExited;
        }
    }
};

pub fn programFiles(gpa: Allocator, io: std.Io, root: []const u8) ![][]u8 {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "git", "ls-files", "-z" },
        .cwd = .{ .path = root },
        .stdout_limit = .limited(max_listing_bytes),
    }) catch return error.GitFailed;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |f| gpa.free(f);
        out.deinit(gpa);
    }
    var entries = std.mem.tokenizeScalar(u8, result.stdout, 0);
    while (entries.next()) |rel| {
        const profile = registry.forPath(rel) orelse continue;
        if (!rename.supports(profile)) continue;
        const abs = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root, rel });
        std.mem.replaceScalar(u8, abs, '\\', '/');
        try out.append(gpa, abs);
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeFiles(gpa: Allocator, files: []const []u8) void {
    for (files) |f| gpa.free(f);
    gpa.free(files);
}

pub const Session = struct {
    gpa: Allocator,
    io: std.Io,
    root: ?[]const u8,
    options: Options = .{},
    client: ?*Client = null,
    last_error: ?anyerror = null,

    pub fn deinit(self: *Session) void {
        if (self.client) |c| c.destroy();
        self.client = null;
    }

    pub fn get(self: *Session) !*Client {
        if (self.client) |c| return c;
        const root = self.root orelse return error.NotInRepo;
        self.client = try Client.create(self.gpa, self.io, root, self.options);
        return self.client.?;
    }
};

pub fn sameFile(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const l: u8 = if (x == '\\') '/' else std.ascii.toLower(x);
        const r: u8 = if (y == '\\') '/' else std.ascii.toLower(y);
        if (l != r) return false;
    }
    return true;
}

const testing = std.testing;

test "tsserver: file names compare without case and slash direction" {
    try testing.expect(sameFile("C:\\Repo\\src\\a.ts", "c:/repo/src/A.ts"));
    try testing.expect(!sameFile("C:\\Repo\\src\\a.ts", "C:\\Repo\\src\\b.ts"));
    try testing.expect(!sameFile("C:\\Repo\\src\\a.ts", "C:\\Repo\\src\\a.tsx"));
}

test "tsserver: the host script never passes tsconfig plugins to the language service" {
    try testing.expect(std.mem.indexOf(u8, host_script, "delete options.plugins;") != null);
    try testing.expect(std.mem.indexOf(u8, host_script, "createLanguageService") != null);
    try testing.expect(std.mem.indexOf(u8, host_script, "tsserver.js") == null);
}
