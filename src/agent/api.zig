const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const endpoint = "https://api.anthropic.com/v1/messages";
pub const anthropic_version = "2023-06-01";
pub const context_management_beta = "context-management-2025-06-27";
pub const clear_tool_uses_type = "clear_tool_uses_20250919";
pub const api_key_variable = "ANTHROPIC_API_KEY";
pub const max_response_bytes: usize = 16 << 20;
pub const default_deadline_ms: u32 = 120_000;

pub const Role = enum { user, assistant };

pub const ToolUse = struct {
    id: []const u8,
    name: []const u8,
    input_json: []const u8,
};

pub const ToolResult = struct {
    tool_use_id: []const u8,
    content: []const u8,
    is_error: bool = false,
};

pub const ContentBlock = union(enum) {
    text: []const u8,
    tool_use: ToolUse,
    tool_result: ToolResult,
};

pub const Message = struct {
    role: Role,
    content: []const ContentBlock,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,
};

pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_input_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,
};

pub const Request = struct {
    model: []const u8,
    system: ?[]const u8 = null,
    messages: []const Message,
    tools: []const Tool = &.{},
    max_tokens: u32,
    cache_last: bool = false,
    context_management: bool = false,
};

pub const Response = struct {
    stop_reason: []const u8,
    content: []const ContentBlock,
    usage: Usage,

    pub fn deinit(self: Response, gpa: Allocator) void {
        gpa.free(self.stop_reason);
        for (self.content) |block| freeBlock(gpa, block);
        gpa.free(self.content);
    }
};

fn freeBlock(gpa: Allocator, block: ContentBlock) void {
    switch (block) {
        .text => |t| gpa.free(t),
        .tool_use => |u| {
            gpa.free(u.id);
            gpa.free(u.name);
            gpa.free(u.input_json);
        },
        .tool_result => |r| {
            gpa.free(r.tool_use_id);
            gpa.free(r.content);
        },
    }
}

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Transport = struct {
    ctx: *anyopaque,
    postFn: *const fn (ctx: *anyopaque, url: []const u8, headers: []const Header, body: []const u8) anyerror![]u8,

    pub fn post(self: Transport, url: []const u8, headers: []const Header, body: []const u8) anyerror![]u8 {
        return self.postFn(self.ctx, url, headers, body);
    }
};

fn writeRaw(js: *std.json.Stringify, arena: Allocator, raw: []const u8) !void {
    const value = try std.json.parseFromSliceLeaky(Value, arena, raw, .{});
    try js.write(value);
}

fn writeBlock(js: *std.json.Stringify, arena: Allocator, block: ContentBlock, cache: bool) !void {
    try js.beginObject();
    switch (block) {
        .text => |t| {
            try js.objectField("type");
            try js.write("text");
            try js.objectField("text");
            try js.write(t);
        },
        .tool_use => |u| {
            try js.objectField("type");
            try js.write("tool_use");
            try js.objectField("id");
            try js.write(u.id);
            try js.objectField("name");
            try js.write(u.name);
            try js.objectField("input");
            try writeRaw(js, arena, u.input_json);
        },
        .tool_result => |r| {
            try js.objectField("type");
            try js.write("tool_result");
            try js.objectField("tool_use_id");
            try js.write(r.tool_use_id);
            try js.objectField("content");
            try js.write(r.content);
            try js.objectField("is_error");
            try js.write(r.is_error);
        },
    }
    if (cache) {
        try js.objectField("cache_control");
        try js.beginObject();
        try js.objectField("type");
        try js.write("ephemeral");
        try js.endObject();
    }
    try js.endObject();
}

fn writeMessage(js: *std.json.Stringify, arena: Allocator, message: Message, cache_last: bool) !void {
    try js.beginObject();
    try js.objectField("role");
    try js.write(@tagName(message.role));
    try js.objectField("content");
    try js.beginArray();
    for (message.content, 0..) |block, i| {
        try writeBlock(js, arena, block, cache_last and i + 1 == message.content.len);
    }
    try js.endArray();
    try js.endObject();
}

fn writeTool(js: *std.json.Stringify, arena: Allocator, tool: Tool) !void {
    try js.beginObject();
    try js.objectField("name");
    try js.write(tool.name);
    try js.objectField("description");
    try js.write(tool.description);
    try js.objectField("input_schema");
    try writeRaw(js, arena, tool.input_schema_json);
    try js.endObject();
}

pub fn serialize(gpa: Allocator, request: Request) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };

    try js.beginObject();
    try js.objectField("model");
    try js.write(request.model);
    try js.objectField("max_tokens");
    try js.write(request.max_tokens);
    if (request.system) |system| {
        try js.objectField("system");
        try js.write(system);
    }
    try js.objectField("messages");
    try js.beginArray();
    for (request.messages, 0..) |message, i| {
        try writeMessage(&js, arena, message, request.cache_last and i + 1 == request.messages.len);
    }
    try js.endArray();
    if (request.tools.len != 0) {
        try js.objectField("tools");
        try js.beginArray();
        for (request.tools) |tool| try writeTool(&js, arena, tool);
        try js.endArray();
    }
    if (request.context_management) {
        try js.objectField("context_management");
        try js.beginObject();
        try js.objectField("edits");
        try js.beginArray();
        try js.beginObject();
        try js.objectField("type");
        try js.write(clear_tool_uses_type);
        try js.endObject();
        try js.endArray();
        try js.endObject();
    }
    try js.endObject();

    return out.toOwnedSlice();
}

fn usageField(object: Value, key: []const u8) u64 {
    if (object != .object) return 0;
    const field = object.object.get(key) orelse return 0;
    return switch (field) {
        .integer => |n| if (n < 0) 0 else @intCast(n),
        else => 0,
    };
}

fn stringField(object: Value, key: []const u8) ?[]const u8 {
    if (object != .object) return null;
    const field = object.object.get(key) orelse return null;
    return switch (field) {
        .string => |s| s,
        else => null,
    };
}

fn stringifyValue(gpa: Allocator, value: Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.write(value);
    return out.toOwnedSlice();
}

pub fn parseResponse(gpa: Allocator, body: []const u8) !Response {
    const parsed = try std.json.parseFromSlice(Value, gpa, body, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.MalformedResponse;

    const stop_reason_src = stringField(root, "stop_reason") orelse "";
    const stop_reason = try gpa.dupe(u8, stop_reason_src);
    errdefer gpa.free(stop_reason);

    var blocks: std.ArrayList(ContentBlock) = .empty;
    errdefer {
        for (blocks.items) |block| freeBlock(gpa, block);
        blocks.deinit(gpa);
    }

    if (root.object.get("content")) |content| {
        if (content == .array) {
            for (content.array.items) |item| {
                const kind = stringField(item, "type") orelse continue;
                if (std.mem.eql(u8, kind, "text")) {
                    const text = try gpa.dupe(u8, stringField(item, "text") orelse "");
                    errdefer gpa.free(text);
                    try blocks.append(gpa, .{ .text = text });
                } else if (std.mem.eql(u8, kind, "tool_use")) {
                    const id = try gpa.dupe(u8, stringField(item, "id") orelse "");
                    errdefer gpa.free(id);
                    const name = try gpa.dupe(u8, stringField(item, "name") orelse "");
                    errdefer gpa.free(name);
                    const input_value = item.object.get("input") orelse Value{ .object = .{} };
                    const input_json = try stringifyValue(gpa, input_value);
                    errdefer gpa.free(input_json);
                    try blocks.append(gpa, .{ .tool_use = .{ .id = id, .name = name, .input_json = input_json } });
                }
            }
        }
    }

    var usage: Usage = .{};
    if (root.object.get("usage")) |u| {
        usage = .{
            .input_tokens = usageField(u, "input_tokens"),
            .output_tokens = usageField(u, "output_tokens"),
            .cache_read_input_tokens = usageField(u, "cache_read_input_tokens"),
            .cache_creation_input_tokens = usageField(u, "cache_creation_input_tokens"),
        };
    }

    const content = try blocks.toOwnedSlice(gpa);
    return .{ .stop_reason = stop_reason, .content = content, .usage = usage };
}

pub fn send(gpa: Allocator, io: std.Io, transport: Transport, request: Request) !Response {
    _ = io;
    const key = std.process.getEnvVarOwned(gpa, api_key_variable) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.MissingApiKey,
        else => return err,
    };
    defer gpa.free(key);
    return sendWith(gpa, transport, request, key);
}

pub fn sendWith(gpa: Allocator, transport: Transport, request: Request, api_key: []const u8) !Response {
    const body = try serialize(gpa, request);
    defer gpa.free(body);

    var headers: std.ArrayList(Header) = .empty;
    defer headers.deinit(gpa);
    try headers.append(gpa, .{ .name = "x-api-key", .value = api_key });
    try headers.append(gpa, .{ .name = "anthropic-version", .value = anthropic_version });
    try headers.append(gpa, .{ .name = "content-type", .value = "application/json" });
    if (request.context_management) {
        try headers.append(gpa, .{ .name = "anthropic-beta", .value = context_management_beta });
    }

    const reply = try transport.post(endpoint, headers.items, body);
    defer gpa.free(reply);
    return parseResponse(gpa, reply);
}

pub const WinHttpTransport = struct {
    gpa: Allocator,
    limit: usize = max_response_bytes,
    deadline_ms: u32 = default_deadline_ms,

    pub fn transport(self: *WinHttpTransport) Transport {
        return .{ .ctx = self, .postFn = post };
    }

    fn of(ctx: *anyopaque) *WinHttpTransport {
        return @ptrCast(@alignCast(ctx));
    }

    fn post(ctx: *anyopaque, url: []const u8, headers: []const Header, body: []const u8) anyerror![]u8 {
        const self = of(ctx);
        return winPost(self.gpa, url, headers, body, self.limit, self.deadline_ms);
    }
};

const Url = struct {
    host: []const u8,
    path: []const u8,

    fn parse(url: []const u8) ?Url {
        const scheme = "https://";
        if (!std.mem.startsWith(u8, url, scheme)) return null;
        const rest = url[scheme.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        if (slash == 0) return null;
        const host = rest[0..slash];
        for (host) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-')) return null;
        return .{ .host = host, .path = rest[slash..] };
    }
};

fn winPost(gpa: Allocator, url: []const u8, headers: []const Header, body: []const u8, limit: usize, deadline_ms: u32) ![]u8 {
    const parsed = Url.parse(url) orelse return error.UnsupportedUrl;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var header_text: std.ArrayList(u8) = .empty;
    for (headers) |header| {
        try header_text.appendSlice(arena, header.name);
        try header_text.appendSlice(arena, ": ");
        try header_text.appendSlice(arena, header.value);
        try header_text.appendSlice(arena, "\r\n");
    }

    const agent_w = try std.unicode.wtf8ToWtf16LeAllocZ(arena, "emetgate-agent");
    const host_w = try std.unicode.wtf8ToWtf16LeAllocZ(arena, parsed.host);
    const path_w = try std.unicode.wtf8ToWtf16LeAllocZ(arena, parsed.path);
    const verb_w = try std.unicode.wtf8ToWtf16LeAllocZ(arena, "POST");
    const headers_w = try std.unicode.wtf8ToWtf16LeAllocZ(arena, header_text.items);

    const session = win.WinHttpOpen(agent_w, win.access_type_automatic_proxy, null, null, 0) orelse return error.HttpUnavailable;
    defer _ = win.WinHttpCloseHandle(session);
    const timeout: c_int = @intCast(@min(deadline_ms, std.math.maxInt(c_int)));
    if (win.WinHttpSetTimeouts(session, timeout, timeout, timeout, timeout) == .FALSE) return error.HttpUnavailable;
    const connection = win.WinHttpConnect(session, host_w, 443, 0) orelse return error.ConnectFailed;
    defer _ = win.WinHttpCloseHandle(connection);
    const request = win.WinHttpOpenRequest(connection, verb_w, path_w, null, null, null, win.flag_secure) orelse return error.RequestFailed;
    defer _ = win.WinHttpCloseHandle(request);

    const header_ptr: ?[*]const u16 = if (header_text.items.len == 0) null else headers_w.ptr;
    const header_len: u32 = @intCast(headers_w.len);
    const body_ptr: ?*anyopaque = if (body.len == 0) null else @constCast(@ptrCast(body.ptr));
    const body_len: u32 = @intCast(body.len);
    if (win.WinHttpSendRequest(request, header_ptr, header_len, body_ptr, body_len, body_len, 0) == .FALSE) return error.SendFailed;
    if (win.WinHttpReceiveResponse(request, null) == .FALSE) return error.ReceiveFailed;

    var status: u32 = 0;
    var status_len: u32 = @sizeOf(u32);
    if (win.WinHttpQueryHeaders(request, win.query_status_code | win.query_flag_number, null, &status, &status_len, null) == .FALSE) return error.ReceiveFailed;

    var collected: std.ArrayList(u8) = .empty;
    errdefer collected.deinit(gpa);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        var read: u32 = 0;
        if (win.WinHttpReadData(request, &chunk, chunk.len, &read) == .FALSE) return error.ReceiveFailed;
        if (read == 0) break;
        if (collected.items.len + read > limit) return error.ResponseTooLarge;
        try collected.appendSlice(gpa, chunk[0..read]);
    }
    if (status != 200) return error.HttpStatus;
    return collected.toOwnedSlice(gpa);
}

const win = struct {
    const windows = std.os.windows;
    const access_type_automatic_proxy: u32 = 4;
    const flag_secure: u32 = 0x00800000;
    const query_status_code: u32 = 19;
    const query_flag_number: u32 = 0x20000000;

    extern "winhttp" fn WinHttpOpen(agent: ?[*:0]const u16, access_type: u32, proxy: ?[*:0]const u16, bypass: ?[*:0]const u16, flags: u32) callconv(.winapi) ?*anyopaque;
    extern "winhttp" fn WinHttpSetTimeouts(handle: *anyopaque, resolve: c_int, connect: c_int, send: c_int, receive: c_int) callconv(.winapi) windows.BOOL;
    extern "winhttp" fn WinHttpConnect(session: *anyopaque, server: [*:0]const u16, port: u16, reserved: u32) callconv(.winapi) ?*anyopaque;
    extern "winhttp" fn WinHttpOpenRequest(connection: *anyopaque, verb: [*:0]const u16, object: [*:0]const u16, version: ?[*:0]const u16, referrer: ?[*:0]const u16, accept_types: ?*const ?[*:0]const u16, flags: u32) callconv(.winapi) ?*anyopaque;
    extern "winhttp" fn WinHttpSendRequest(request: *anyopaque, headers: ?[*]const u16, headers_len: u32, optional: ?*anyopaque, optional_len: u32, total_len: u32, context: usize) callconv(.winapi) windows.BOOL;
    extern "winhttp" fn WinHttpReceiveResponse(request: *anyopaque, reserved: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "winhttp" fn WinHttpQueryHeaders(request: *anyopaque, info_level: u32, name: ?[*:0]const u16, buffer: ?*anyopaque, buffer_len: *u32, index: ?*u32) callconv(.winapi) windows.BOOL;
    extern "winhttp" fn WinHttpReadData(request: *anyopaque, buffer: [*]u8, to_read: u32, read: *u32) callconv(.winapi) windows.BOOL;
    extern "winhttp" fn WinHttpCloseHandle(handle: *anyopaque) callconv(.winapi) windows.BOOL;
};

const testing = std.testing;

const MockTransport = struct {
    gpa: Allocator,
    canned: []const u8,
    seen_body: ?[]u8 = null,
    seen_url: ?[]const u8 = null,
    seen_headers: ?[]Header = null,

    fn transport(self: *MockTransport) Transport {
        return .{ .ctx = self, .postFn = post };
    }

    fn post(ctx: *anyopaque, url: []const u8, headers: []const Header, body: []const u8) anyerror![]u8 {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        self.seen_url = url;
        self.seen_body = try self.gpa.dupe(u8, body);
        self.seen_headers = try self.gpa.dupe(Header, headers);
        return self.gpa.dupe(u8, self.canned);
    }

    fn deinit(self: *MockTransport) void {
        if (self.seen_body) |b| self.gpa.free(b);
        if (self.seen_headers) |h| self.gpa.free(h);
    }
};

test "agent.api serialize request round-trips key fields" {
    const gpa = testing.allocator;
    const messages = [_]Message{.{ .role = .user, .content = &.{.{ .text = "hello" }} }};
    const request: Request = .{
        .model = "claude-opus-4-8",
        .system = "be brief",
        .messages = &messages,
        .max_tokens = 1024,
    };
    const json = try serialize(gpa, request);
    defer gpa.free(json);

    const parsed = try std.json.parseFromSlice(Value, gpa, json, .{});
    defer parsed.deinit();
    const root = parsed.value;
    try testing.expectEqualStrings("claude-opus-4-8", root.object.get("model").?.string);
    try testing.expectEqual(@as(i64, 1024), root.object.get("max_tokens").?.integer);
    try testing.expectEqualStrings("be brief", root.object.get("system").?.string);
    const msgs = root.object.get("messages").?.array;
    try testing.expectEqual(@as(usize, 1), msgs.items.len);
    try testing.expectEqualStrings("user", msgs.items[0].object.get("role").?.string);
    const block0 = msgs.items[0].object.get("content").?.array.items[0];
    try testing.expectEqualStrings("text", block0.object.get("type").?.string);
    try testing.expectEqualStrings("hello", block0.object.get("text").?.string);
    try testing.expect(root.object.get("context_management") == null);
}

test "agent.api serialize emits tool_use input, cache_control and context_management" {
    const gpa = testing.allocator;
    const assistant_blocks = [_]ContentBlock{.{ .tool_use = .{ .id = "tu_1", .name = "search", .input_json = "{\"q\":\"zig\",\"n\":3}" } }};
    const user_blocks = [_]ContentBlock{.{ .tool_result = .{ .tool_use_id = "tu_1", .content = "done", .is_error = false } }};
    const messages = [_]Message{
        .{ .role = .assistant, .content = &assistant_blocks },
        .{ .role = .user, .content = &user_blocks },
    };
    const tools = [_]Tool{.{ .name = "search", .description = "search the web", .input_schema_json = "{\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"string\"}}}" }};
    const request: Request = .{
        .model = "claude-opus-4-8",
        .messages = &messages,
        .tools = &tools,
        .max_tokens = 2048,
        .cache_last = true,
        .context_management = true,
    };
    const json = try serialize(gpa, request);
    defer gpa.free(json);

    const parsed = try std.json.parseFromSlice(Value, gpa, json, .{});
    defer parsed.deinit();
    const root = parsed.value;

    const msgs = root.object.get("messages").?.array;
    const tool_use = msgs.items[0].object.get("content").?.array.items[0];
    try testing.expectEqualStrings("tool_use", tool_use.object.get("type").?.string);
    const input = tool_use.object.get("input").?.object;
    try testing.expectEqualStrings("zig", input.get("q").?.string);
    try testing.expectEqual(@as(i64, 3), input.get("n").?.integer);

    const last_block = msgs.items[1].object.get("content").?.array.items[0];
    try testing.expectEqualStrings("ephemeral", last_block.object.get("cache_control").?.object.get("type").?.string);

    const t = root.object.get("tools").?.array.items[0];
    try testing.expectEqualStrings("search", t.object.get("name").?.string);
    try testing.expectEqualStrings("object", t.object.get("input_schema").?.object.get("type").?.string);

    const edits = root.object.get("context_management").?.object.get("edits").?.array;
    try testing.expectEqualStrings(clear_tool_uses_type, edits.items[0].object.get("type").?.string);
}

test "agent.api parseResponse reads text, tool_use and usage" {
    const gpa = testing.allocator;
    const canned =
        \\{"stop_reason":"tool_use","content":[
        \\{"type":"text","text":"let me check"},
        \\{"type":"tool_use","id":"tu_9","name":"lookup","input":{"key":"value"}}
        \\],"usage":{"input_tokens":12,"output_tokens":34,"cache_read_input_tokens":5,"cache_creation_input_tokens":7}}
    ;
    const response = try parseResponse(gpa, canned);
    defer response.deinit(gpa);

    try testing.expectEqualStrings("tool_use", response.stop_reason);
    try testing.expectEqual(@as(usize, 2), response.content.len);
    try testing.expectEqualStrings("let me check", response.content[0].text);
    try testing.expectEqualStrings("tu_9", response.content[1].tool_use.id);
    try testing.expectEqualStrings("lookup", response.content[1].tool_use.name);

    const reparsed = try std.json.parseFromSlice(Value, gpa, response.content[1].tool_use.input_json, .{});
    defer reparsed.deinit();
    try testing.expectEqualStrings("value", reparsed.value.object.get("key").?.string);

    try testing.expectEqual(@as(u64, 12), response.usage.input_tokens);
    try testing.expectEqual(@as(u64, 34), response.usage.output_tokens);
    try testing.expectEqual(@as(u64, 5), response.usage.cache_read_input_tokens);
    try testing.expectEqual(@as(u64, 7), response.usage.cache_creation_input_tokens);
}

test "agent.api sendWith goes through transport with no network" {
    const gpa = testing.allocator;
    const canned =
        \\{"stop_reason":"end_turn","content":[{"type":"text","text":"ok"}],"usage":{"output_tokens":2}}
    ;
    var mock: MockTransport = .{ .gpa = gpa, .canned = canned };
    defer mock.deinit();

    const messages = [_]Message{.{ .role = .user, .content = &.{.{ .text = "ping" }} }};
    const request: Request = .{
        .model = "claude-opus-4-8",
        .messages = &messages,
        .max_tokens = 64,
        .context_management = true,
    };
    const response = try sendWith(gpa, mock.transport(), request, "sk-test-key");
    defer response.deinit(gpa);

    try testing.expectEqualStrings("end_turn", response.stop_reason);
    try testing.expectEqualStrings("ok", response.content[0].text);
    try testing.expectEqual(@as(u64, 2), response.usage.output_tokens);

    try testing.expect(mock.seen_body != null);
    try testing.expect(std.mem.indexOf(u8, mock.seen_body.?, "\"model\":\"claude-opus-4-8\"") != null);

    var saw_key = false;
    var saw_version = false;
    var saw_beta = false;
    for (mock.seen_headers.?) |header| {
        if (std.mem.eql(u8, header.name, "x-api-key") and std.mem.eql(u8, header.value, "sk-test-key")) saw_key = true;
        if (std.mem.eql(u8, header.name, "anthropic-version") and std.mem.eql(u8, header.value, anthropic_version)) saw_version = true;
        if (std.mem.eql(u8, header.name, "anthropic-beta") and std.mem.eql(u8, header.value, context_management_beta)) saw_beta = true;
    }
    try testing.expect(saw_key);
    try testing.expect(saw_version);
    try testing.expect(saw_beta);
}
