const std = @import("std");
const server = @import("server.zig");
const json_input = @import("json_input.zig");
const policy_mod = @import("policy.zig");
const telemetry = @import("telemetry.zig");
const tool_result = @import("tool_result.zig");
const search_v1 = @import("search_v1.zig");
const map_tools = @import("map_tools.zig");
const wire = @import("wire.zig");
const repo = @import("../platform/repo.zig");
const rules = @import("../platform/rules.zig");
const shadow = @import("../platform/shadow.zig");
const display_path = @import("../platform/display_path.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const Policy = policy_mod.Policy;
const Served = server.Served;

pub const max_repositories = 16;
const max_depth = 4;
const max_scanned_folders = 4000;
const max_git_file_bytes = 4096;
const vendored_dirs = [_][]const u8{ "vendor", "third_party" };

const path_keys = [_][]const u8{ "file", "dir", "from", "to", "target_file", "path" };
const list_keys = [_][]const u8{"files"};
const fan_out_tools = [_][]const u8{ "emetgate_list", "emetgate_search", "emetgate_find", "emetgate_explore" };
const spans_repositories_reply = "{\"status\":\"error\",\"error\":\"SpansRepositories\",\"exit_code\":1,\"fix\":\"these paths are in different git repositories; make one call per repository\"}";

pub const Repository = struct {
    root: []const u8,
    label: []const u8,
    served: ?*Served = null,
};

pub const Workspace = struct {
    gpa: Allocator,
    io: std.Io,
    runtime: *Runtime,
    policy: Policy,
    environ: ?*const std.process.Environ.Map,
    primary: *Served,
    session: ?[:0]u8,
    arena: std.heap.ArenaAllocator,
    repositories: std.ArrayList(Repository) = .empty,
    below: std.ArrayList([]const u8) = .empty,
    scanned: bool = false,
    cut: bool = false,

    pub fn init(gpa: Allocator, io: std.Io, runtime: *Runtime, policy: Policy, environ: ?*const std.process.Environ.Map, primary: *Served, session: ?[:0]u8) Workspace {
        const self: Workspace = .{
            .gpa = gpa,
            .io = io,
            .runtime = runtime,
            .policy = policy,
            .environ = environ,
            .primary = primary,
            .session = session,
            .arena = .init(gpa),
        };
        primary.policy.session_dir = session;
        rules.outer_root = primary.root;
        return self;
    }

    pub fn deinit(self: *Workspace) void {
        rules.outer_root = null;
        for (self.repositories.items) |entry| {
            if (entry.served) |served| {
                served.close();
                self.gpa.destroy(served);
            }
        }
        self.repositories.deinit(self.gpa);
        self.below.deinit(self.gpa);
        self.arena.deinit();
        if (self.session) |session| self.gpa.free(session);
    }

    pub fn handle(self: *Workspace, line: []const u8, out: *Writer) !bool {
        const root = self.primary.root orelse return self.primary.handle(self.runtime, line, out);
        const session = self.session orelse return self.primary.handle(self.runtime, line, out);
        var call_arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer call_arena.deinit();
        const arena = call_arena.allocator();
        var message = json_input.parseLeaky(Value, arena, line, .{}) catch return self.primary.handle(self.runtime, line, out);
        const call = toolCall(&message) orelse {
            const method = fieldOf(message, "method") orelse return self.primary.handle(self.runtime, line, out);
            if (method == .string and std.mem.eql(u8, method.string, "tools/list")) try self.prepareRun();
            return self.primary.handle(self.runtime, line, out);
        };

        var slots: std.ArrayList(*Value) = .empty;
        if (call.arguments) |arguments| try collectSlots(arena, arguments, &slots);
        var changed = false;
        const owner = (try self.resolveSlots(arena, root, session, slots.items, &changed)) orelse {
            const id = fieldOf(message, "id") orelse .null;
            try server.writeToolResult(out, id, spans_repositories_reply, true);
            return true;
        };

        const id = fieldOf(message, "id") orelse .null;
        if (isFanOut(call.name)) {
            if (try self.fanOut(arena, session, owner, call, id, out)) return true;
        }
        if (owner == .primary and isStatus(call)) {
            if (try self.statusWithRepositories(call, id, out)) return true;
        }
        if (std.mem.eql(u8, call.name, "emetgate_run")) {
            try self.prepareRun();
            defer self.scanned = false;
            return self.dispatch(arena, .primary, &message, line, changed, out);
        }
        return self.dispatch(arena, owner, &message, line, changed, out);
    }

    fn dispatch(self: *Workspace, arena: Allocator, owner: OwnerChoice, message: *Value, line: []const u8, changed: bool, out: *Writer) !bool {
        const text = if (changed) try std.json.Stringify.valueAlloc(arena, message.*, .{}) else line;
        const target = switch (owner) {
            .primary => self.primary,
            .nested => |index| try self.servedOf(&self.repositories.items[index]),
        };
        return target.handle(self.runtime, text, out);
    }

    fn servedOf(self: *Workspace, entry: *Repository) !*Served {
        if (entry.served) |served| return served;
        const served = try self.gpa.create(Served);
        errdefer self.gpa.destroy(served);
        served.open(self.gpa, self.io, self.runtime, self.policy, .{ .root = entry.root, .environ = self.environ });
        served.policy.stash = self.primary.policy.stash;
        entry.served = served;
        return served;
    }

    fn resolveSlots(self: *Workspace, arena: Allocator, root: []const u8, session: []const u8, slots: []const *Value, changed: *bool) !?OwnerChoice {
        var choice: OwnerChoice = .primary;
        var first = true;
        for (slots) |slot| {
            const given = slot.string;
            if (given.len == 0) continue;
            const chosen = try chooseSpelling(arena, self.io, root, session, given);
            if (!std.mem.eql(u8, chosen.spelled, given)) {
                slot.* = .{ .string = chosen.spelled };
                changed.* = true;
            }
            const is_dir = isDirectory(self.io, chosen.abs);
            const found = try repo.nestedOwner(arena, self.io, root, chosen.abs, is_dir);
            const here: OwnerChoice = if (found) |nested| .{ .nested = try self.entryOf(nested) } else .primary;
            if (first) {
                choice = here;
                first = false;
            } else if (!sameOwner(choice, here)) return null;
        }
        return choice;
    }

    fn entryOf(self: *Workspace, root_abs: []const u8) !usize {
        for (self.repositories.items, 0..) |entry, index| {
            if (std.ascii.eqlIgnoreCase(entry.root, root_abs)) return index;
        }
        const a = self.arena.allocator();
        const root = try a.dupe(u8, root_abs);
        try self.repositories.append(self.gpa, .{ .root = root, .label = try labelOf(a, self.session.?, root) });
        return self.repositories.items.len - 1;
    }

    pub fn prepareRun(self: *Workspace) !void {
        const found = try self.discover();
        self.primary.policy.nested_roots = found;
    }

    fn discover(self: *Workspace) ![]const []const u8 {
        if (self.scanned) return self.below.items;
        self.below.clearRetainingCapacity();
        self.cut = false;
        const session = self.session orelse return self.below.items;
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        var budget: usize = max_scanned_folders;
        try self.walk(scratch.allocator(), session, max_depth, &budget);
        self.scanned = true;
        return self.below.items;
    }

    fn walk(self: *Workspace, a: Allocator, folder: []const u8, depth: usize, budget: *usize) anyerror!void {
        if (depth == 0) return;
        var dir = Dir.openDirAbsolute(self.io, folder, .{ .iterate = true, .follow_symlinks = false }) catch return;
        defer dir.close(self.io);
        var entries = dir.iterate();
        while (entries.next(self.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (skipped(entry.name)) continue;
            if (budget.* == 0) {
                self.cut = true;
                return;
            }
            budget.* -= 1;
            const child = try std.fmt.allocPrint(a, "{s}\\{s}", .{ folder, entry.name });
            if (shadow.isReparsePoint(child) catch true) continue;
            if (try hasGitEntry(self.io, dir, entry.name)) {
                try self.adopt(a, child);
                continue;
            }
            try self.walk(a, child, depth - 1, budget);
        }
    }

    fn adopt(self: *Workspace, a: Allocator, child: []const u8) !void {
        const final = repo.finalOf(a, child) catch return;
        const owner = repo.gitToplevel(a, self.io, final) catch return;
        if (!std.ascii.eqlIgnoreCase(owner, final)) return;
        if (self.isLinkedWorktree(final)) return;
        if (self.below.items.len == max_repositories) {
            self.cut = true;
            return;
        }
        try self.below.append(self.gpa, try self.arena.allocator().dupe(u8, final));
    }

    fn isLinkedWorktree(self: *Workspace, final: []const u8) bool {
        var buffer: [max_git_file_bytes]u8 = undefined;
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "{s}\\.git", .{final}) catch return false;
        const text = Dir.cwd().readFile(self.io, path, &buffer) catch return false;
        return std.mem.indexOf(u8, text, "/worktrees/") != null;
    }

    fn fanOut(self: *Workspace, arena: Allocator, session: []const u8, owner: OwnerChoice, call: ToolCall, id: Value, out: *Writer) !bool {
        const here = dirArgument(call) orelse ".";
        const scope = try std.fs.path.resolve(arena, &.{ session, here });
        var text: Writer.Allocating = .init(self.gpa);
        defer text.deinit();
        switch (owner) {
            .nested => |index| {
                const section = self.callSection(index, call, null) catch return false;
                defer self.gpa.free(section.text);
                const comp = server.compactReply(self.gpa, self.io, self.primary.policy, call.name, call.arguments, section.text, section.is_error) catch null;
                defer if (comp) |c| self.gpa.free(c);
                try server.writeToolResult(out, id, comp orelse section.text, section.is_error);
                return true;
            },
            .primary => {},
        }
        const found = try self.discover();
        var chosen: std.ArrayList(usize) = .empty;
        for (found) |root_abs| {
            if (!isWithin(scope, root_abs)) continue;
            try chosen.append(arena, try self.entryOf(root_abs));
        }
        if (chosen.items.len == 0) return false;

        var all_failed = true;
        var event: telemetry.Event = .{ .tool = call.name };
        tool_result.clearMissing();
        wire.clearFix();
        const primary_result = server.callAny(self.gpa, self.io, self.runtime, call.name, call.arguments, &event, self.primary.policy) catch return false;
        defer self.gpa.free(primary_result.text);
        const decorated: ?[]u8 = if (self.primary.observer) |*observer| telemetry.observe(self.gpa, self.io, observer, event, primary_result.text) else null;
        defer if (decorated) |owned| self.gpa.free(owned);
        const primary_text = decorated orelse primary_result.text;
        if (!primary_result.is_error) all_failed = false;
        if (!isEmptySection(primary_text)) try text.writer.writeAll(primary_text);
        for (chosen.items) |index| {
            const nested_dir: ?[]const u8 = if (dirArgument(call) != null or std.mem.eql(u8, call.name, "emetgate_list") or std.mem.eql(u8, call.name, "emetgate_search"))
                self.repositories.items[index].root
            else
                null;
            const section = self.callSection(index, call, nested_dir) catch |err| {
                if (text.written().len != 0) try text.writer.writeByte('\n');
                try text.writer.print("--- {s}\ncould not read this repository: {t}", .{ self.repositories.items[index].label, err });
                continue;
            };
            defer self.gpa.free(section.text);
            if (!section.is_error) all_failed = false;
            if (text.written().len != 0) try text.writer.writeByte('\n');
            try text.writer.print("--- {s}\n{s}", .{ self.repositories.items[index].label, section.text });
        }
        if (self.cut) try text.writer.print("\nmore than {d} repositories or too many folders under this one; pass dir to reach the rest", .{max_repositories});
        const comp = server.compactReply(self.gpa, self.io, self.primary.policy, call.name, call.arguments, text.written(), all_failed) catch null;
        defer if (comp) |c| self.gpa.free(c);
        try server.writeToolResult(out, id, comp orelse text.written(), all_failed);
        return true;
    }

    fn statusWithRepositories(self: *Workspace, call: ToolCall, id: Value, out: *Writer) !bool {
        const found = try self.discover();
        if (found.len == 0) return false;
        const session = self.session orelse return false;
        var event: telemetry.Event = .{ .tool = call.name };
        tool_result.clearMissing();
        wire.clearFix();
        const result = server.callAny(self.gpa, self.io, self.runtime, call.name, call.arguments, &event, self.primary.policy) catch return false;
        defer self.gpa.free(result.text);
        if (self.primary.observer) |*observer| {
            if (telemetry.observe(self.gpa, self.io, observer, event, result.text)) |owned| self.gpa.free(owned);
        }
        var text: Writer.Allocating = .init(self.gpa);
        defer text.deinit();
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        try text.writer.print("{s}\nother git repositories below this folder, reach one with dir:", .{result.text});
        for (found) |root_abs| try text.writer.print(" {s}", .{try relativeFrom(scratch.allocator(), session, root_abs)});
        try server.writeToolResult(out, id, text.written(), result.is_error);
        return true;
    }

    fn callSection(self: *Workspace, index: usize, call: ToolCall, dir: ?[]const u8) !tool_result.ToolResult {
        const entry = &self.repositories.items[index];
        const served = try self.servedOf(entry);
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var arguments: ?Value = call.arguments;
        if (dir) |text| arguments = try withDir(arena, call.arguments, text);
        var event: telemetry.Event = .{ .tool = call.name };
        tool_result.clearMissing();
        wire.clearFix();
        display_path.prefix = entry.label;
        defer display_path.prefix = "";
        const result = try server.callAny(self.gpa, self.io, self.runtime, call.name, arguments, &event, served.policy);
        if (served.observer) |*observer| {
            if (telemetry.observe(self.gpa, self.io, observer, event, result.text)) |owned| self.gpa.free(owned);
        }
        return result;
    }
};

const OwnerChoice = union(enum) {
    primary,
    nested: usize,
};

fn sameOwner(a: OwnerChoice, b: OwnerChoice) bool {
    return switch (a) {
        .primary => b == .primary,
        .nested => |index| switch (b) {
            .primary => false,
            .nested => |other| other == index,
        },
    };
}

const ToolCall = struct {
    name: []const u8,
    arguments: ?Value,
};

fn toolCall(message: *Value) ?ToolCall {
    const method = fieldOf(message.*, "method") orelse return null;
    if (method != .string or !std.mem.eql(u8, method.string, "tools/call")) return null;
    if (fieldOf(message.*, "id") == null) return null;
    const params = fieldOf(message.*, "params") orelse return null;
    const name = fieldOf(params, "name") orelse return null;
    if (name != .string) return null;
    return .{ .name = name.string, .arguments = fieldOf(params, "arguments") };
}

fn fieldOf(value: Value, key: []const u8) ?Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn collectSlots(arena: Allocator, value: Value, slots: *std.ArrayList(*Value)) anyerror!void {
    switch (value) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* == .string) {
                    if (isKey(&path_keys, entry.key_ptr.*)) try slots.append(arena, entry.value_ptr);
                } else if (entry.value_ptr.* == .array and isKey(&list_keys, entry.key_ptr.*)) {
                    for (entry.value_ptr.array.items) |*item| {
                        if (item.* == .string) try slots.append(arena, item);
                    }
                } else {
                    try collectSlots(arena, entry.value_ptr.*, slots);
                }
            }
        },
        .array => |array| {
            for (array.items) |item| try collectSlots(arena, item, slots);
        },
        else => {},
    }
}

fn isKey(keys: []const []const u8, name: []const u8) bool {
    for (keys) |key| {
        if (std.mem.eql(u8, key, name)) return true;
    }
    return false;
}

fn isStatus(call: ToolCall) bool {
    if (!std.mem.eql(u8, call.name, "emetgate_git")) return false;
    const arguments = call.arguments orelse return false;
    const sub = fieldOf(arguments, "sub") orelse return false;
    return sub == .string and std.mem.eql(u8, sub.string, "status");
}

fn isEmptySection(text: []const u8) bool {
    if (std.mem.indexOf(u8, text, search_v1.nothing_searched) != null) return true;
    if (std.mem.indexOf(u8, text, map_tools.no_function_matched) != null) return true;
    return std.mem.startsWith(u8, text, "0 hits in 0 files");
}

fn isFanOut(name: []const u8) bool {
    return isKey(&fan_out_tools, name);
}

fn dirArgument(call: ToolCall) ?[]const u8 {
    const arguments = call.arguments orelse return null;
    const dir = fieldOf(arguments, "dir") orelse return null;
    return if (dir == .string) dir.string else null;
}

fn withDir(arena: Allocator, arguments: ?Value, dir: []const u8) !Value {
    var object: std.json.ObjectMap = .empty;
    if (arguments) |given| {
        if (given == .object) {
            var it = given.object.iterator();
            while (it.next()) |entry| try object.put(arena, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    try object.put(arena, "dir", .{ .string = dir });
    return .{ .object = object };
}

const Spelling = struct { spelled: []const u8, abs: []const u8 };

pub fn chooseSpelling(arena: Allocator, io: std.Io, root: []const u8, session: []const u8, given: []const u8) !Spelling {
    const from_session = try std.fs.path.resolve(arena, &.{ session, given });
    if (std.fs.path.isAbsolute(given) or std.ascii.eqlIgnoreCase(root, session)) return .{ .spelled = given, .abs = from_session };
    const from_root = try std.fs.path.resolve(arena, &.{ root, given });
    if (exists(io, from_session)) return .{ .spelled = given, .abs = from_session };
    const session_form: Spelling = .{ .spelled = try relativeFrom(arena, session, from_root), .abs = from_root };
    if (exists(io, from_root)) return session_form;
    if (parentExists(io, from_session)) return .{ .spelled = given, .abs = from_session };
    if (parentExists(io, from_root)) return session_form;
    return .{ .spelled = given, .abs = from_session };
}

fn exists(io: std.Io, path: []const u8) bool {
    Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn parentExists(io: std.Io, path: []const u8) bool {
    const parent = std.fs.path.dirname(path) orelse return false;
    return exists(io, parent);
}

fn isDirectory(io: std.Io, path: []const u8) bool {
    var dir = Dir.openDirAbsolute(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn hasGitEntry(io: std.Io, dir: Dir, name: []const u8) !bool {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "{s}\\.git", .{name}) catch return false;
    dir.access(io, path, .{}) catch return false;
    return true;
}

fn skipped(name: []const u8) bool {
    if (name[0] == '.') return true;
    for (shadow.dependency_dirs) |dependency| {
        if (std.ascii.eqlIgnoreCase(name, dependency)) return true;
    }
    for (vendored_dirs) |vendored| {
        if (std.ascii.eqlIgnoreCase(name, vendored)) return true;
    }
    return false;
}

pub fn isWithin(folder: []const u8, path: []const u8) bool {
    if (path.len < folder.len) return false;
    if (!std.ascii.eqlIgnoreCase(path[0..folder.len], folder)) return false;
    return path.len == folder.len or path[folder.len] == '\\' or path[folder.len] == '/' or folder[folder.len - 1] == '\\';
}

pub fn labelOf(arena: Allocator, session: []const u8, nested: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/", .{try relativeFrom(arena, session, nested)});
}

pub fn relativeFrom(arena: Allocator, from: []const u8, to: []const u8) ![]const u8 {
    var from_parts = std.mem.tokenizeAny(u8, from, "\\/");
    var to_parts = std.mem.tokenizeAny(u8, to, "\\/");
    var rest_from: ?[]const u8 = from_parts.next();
    var rest_to: ?[]const u8 = to_parts.next();
    while (rest_from != null and rest_to != null and std.ascii.eqlIgnoreCase(rest_from.?, rest_to.?)) {
        rest_from = from_parts.next();
        rest_to = to_parts.next();
    }
    var built: std.ArrayList(u8) = .empty;
    while (rest_from != null) : (rest_from = from_parts.next()) {
        if (built.items.len != 0) try built.append(arena, '/');
        try built.appendSlice(arena, "..");
    }
    while (rest_to) |part| : (rest_to = to_parts.next()) {
        if (built.items.len != 0) try built.append(arena, '/');
        try built.appendSlice(arena, part);
    }
    if (built.items.len == 0) return ".";
    return built.items;
}

test "workspace: a nested path reads relative to the session folder" {
    const a = std.testing.allocator;
    var state: std.heap.ArenaAllocator = .init(a);
    defer state.deinit();
    const arena = state.allocator();
    try std.testing.expectEqualStrings("mobil/src/a.js", try relativeFrom(arena, "C:\\p\\Tribune", "C:\\p\\Tribune\\mobil\\src\\a.js"));
    try std.testing.expectEqualStrings("../top.txt", try relativeFrom(arena, "C:\\p\\Tribune", "C:\\p\\top.txt"));
    try std.testing.expectEqualStrings(".", try relativeFrom(arena, "C:\\p\\Tribune", "c:\\P\\tribune"));
    try std.testing.expectEqualStrings("mobil/", try labelOf(arena, "C:\\p\\Tribune", "C:\\p\\Tribune\\mobil"));
}

test "workspace: a folder holds a path only on a segment boundary" {
    try std.testing.expect(isWithin("C:\\p\\a", "C:\\p\\a\\b"));
    try std.testing.expect(isWithin("C:\\p\\a", "c:\\P\\A"));
    try std.testing.expect(!isWithin("C:\\p\\a", "C:\\p\\ab"));
}
