const std = @import("std");
const shadow_root = @import("shadow_root.zig");

const Allocator = std.mem.Allocator;

pub const command_name = "rule";
pub const hook_args = [_][]const u8{ "hook", "prompt" };
pub const hook_event = "UserPromptSubmit";
pub const local_app_data_variable = "LOCALAPPDATA";
pub const settings_name = "settings.json";
pub const command_dir = ".claude\\commands";
pub const command_file_name = command_name ++ ".md";
pub const command_file =
    "---\n" ++
    "description: add, list, supersede or forget an emetgate rule\n" ++
    "disable-model-invocation: true\n" ++
    "---\n";

pub const Entry = struct {
    dir: []u8,
    settings: []u8,

    pub fn deinit(self: Entry, gpa: Allocator) void {
        gpa.free(self.dir);
        gpa.free(self.settings);
    }
};

pub fn stateDir(gpa: Allocator, local_app_data: []const u8, exe_abs: []const u8) ![]u8 {
    const key = shadow_root.repoKey(exe_abs);
    return std.fmt.allocPrint(gpa, "{s}\\emetgate\\lockdown\\{s}", .{ local_app_data, &key });
}

pub fn settingsJson(gpa: Allocator, exe_abs: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try js.objectField("hooks");
    try js.beginObject();
    try js.objectField(hook_event);
    try js.beginArray();
    try js.beginObject();
    try js.objectField("hooks");
    try js.beginArray();
    try js.beginObject();
    try js.objectField("type");
    try js.write("command");
    try js.objectField("command");
    try js.write(exe_abs);
    try js.objectField("args");
    try js.write(hook_args);
    try js.endObject();
    try js.endArray();
    try js.endObject();
    try js.endArray();
    try js.endObject();
    try js.endObject();
    return out.toOwnedSlice();
}

pub fn install(gpa: Allocator, io: std.Io, local_app_data: []const u8, exe_abs: []const u8) !Entry {
    const dir = try stateDir(gpa, local_app_data, exe_abs);
    errdefer gpa.free(dir);
    const commands = try std.fs.path.join(gpa, &.{ dir, command_dir });
    defer gpa.free(commands);
    try std.Io.Dir.cwd().createDirPath(io, commands);

    const command_abs = try std.fs.path.join(gpa, &.{ commands, command_file_name });
    defer gpa.free(command_abs);
    try place(gpa, io, command_abs, command_file);

    const settings = try std.fs.path.join(gpa, &.{ dir, settings_name });
    errdefer gpa.free(settings);
    const json = try settingsJson(gpa, exe_abs);
    defer gpa.free(json);
    try place(gpa, io, settings, json);
    return .{ .dir = dir, .settings = settings };
}

pub fn place(gpa: Allocator, io: std.Io, abs: []const u8, data: []const u8) !void {
    if (holds(gpa, io, abs, data)) return;
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const staged = try std.fmt.allocPrint(gpa, "{s}.{x}.tmp", .{ abs, &nonce });
    defer gpa.free(staged);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = staged, .data = data });
    errdefer std.Io.Dir.cwd().deleteFile(io, staged) catch {};
    try std.Io.Dir.renameAbsolute(staged, abs, io);
}

fn holds(gpa: Allocator, io: std.Io, abs: []const u8, data: []const u8) bool {
    const present = std.Io.Dir.cwd().readFileAlloc(io, abs, gpa, .limited(data.len + 1)) catch return false;
    defer gpa.free(present);
    return std.mem.eql(u8, present, data);
}

pub fn extend(gpa: Allocator, argv: []const []const u8, entry: Entry) ![][]const u8 {
    const added = [_][]const u8{ "--add-dir", entry.dir, "--settings", entry.settings };
    const out = try gpa.alloc([]const u8, argv.len + added.len);
    out[0] = argv[0];
    @memcpy(out[1 .. 1 + added.len], &added);
    @memcpy(out[1 + added.len ..], argv[1..]);
    return out;
}
