const std = @import("std");
const api = @import("api.zig");
const receipt = @import("receipt.zig");
const wrap = @import("wrap.zig");
const evict = @import("evict.zig");
const ledger_mod = @import("ledger.zig");

const Allocator = std.mem.Allocator;
const Target = ledger_mod.Target;

pub const model = "claude-opus-5-5";
pub const default_max_turns: usize = 40;
pub const default_max_tokens: u32 = 8192;

pub const Dispatch = struct {
    text: []u8,
    is_error: bool,
};

pub const Dispatcher = struct {
    ctx: *anyopaque,
    callFn: *const fn (ctx: *anyopaque, gpa: Allocator, name: []const u8, input_json: []const u8) anyerror!Dispatch,

    pub fn call(self: Dispatcher, gpa: Allocator, name: []const u8, input_json: []const u8) anyerror!Dispatch {
        return self.callFn(self.ctx, gpa, name, input_json);
    }
};

pub const Config = struct {
    model: []const u8 = model,
    system: ?[]const u8 = null,
    max_turns: usize = default_max_turns,
    max_tokens: u32 = default_max_tokens,
    context_management: bool = false,
    policy: evict.Policy = .{},
};

pub const Outcome = struct {
    final_text: []u8,
    stop_reason: []u8,
    turns: usize,
    tool_calls: usize,
    collapsed: usize,
    freed_tokens: usize,

    pub fn deinit(self: Outcome, gpa: Allocator) void {
        gpa.free(self.final_text);
        gpa.free(self.stop_reason);
    }
};

pub fn run(
    gpa: Allocator,
    transport: api.Transport,
    api_key: []const u8,
    dispatcher: Dispatcher,
    tools: []const api.Tool,
    config: Config,
    user_prompt: []const u8,
) !Outcome {
    var session = receipt.Session.init(gpa, config.policy);
    defer session.deinit();
    try session.appendUser(user_prompt);

    var turns: usize = 0;
    var tool_calls: usize = 0;
    var collapsed: usize = 0;
    var freed: usize = 0;
    var stop_reason: []u8 = try gpa.dupe(u8, "max_turns");
    errdefer gpa.free(stop_reason);

    while (turns < config.max_turns) : (turns += 1) {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const view = try session.sendView(arena);
        const request: api.Request = .{
            .model = config.model,
            .system = config.system,
            .messages = view.messages,
            .tools = tools,
            .max_tokens = config.max_tokens,
            .cache_last = true,
            .context_management = config.context_management,
        };

        var response = try api.sendWith(gpa, transport, request, api_key);
        defer response.deinit(gpa);
        try session.appendAssistant(response.content);

        var indices: std.ArrayList(usize) = .empty;
        defer indices.deinit(gpa);
        for (response.content) |block| {
            switch (block) {
                .tool_use => |tu| {
                    const dispatch = try dispatcher.call(gpa, tu.name, tu.input_json);
                    defer gpa.free(dispatch.text);
                    tool_calls += 1;
                    const claim = try wrap.claim(gpa, tu.name, dispatch.text, dispatch.is_error);
                    defer gpa.free(claim);
                    const tgts = try wrap.targets(arena, tu.input_json);
                    const idx = try session.registerOnly(.{
                        .tool_use_id = tu.id,
                        .claim = claim,
                        .body = dispatch.text,
                        .targets = tgts,
                        .merkle_root = std.mem.zeroes(ledger_mod.Hash),
                    });
                    try indices.append(gpa, idx);
                },
                else => {},
            }
        }

        if (indices.items.len == 0) {
            gpa.free(stop_reason);
            stop_reason = try gpa.dupe(u8, response.stop_reason);
            const final_text = try gatherText(gpa, response.content);
            turns += 1;
            return .{ .final_text = final_text, .stop_reason = stop_reason, .turns = turns, .tool_calls = tool_calls, .collapsed = collapsed, .freed_tokens = freed };
        }

        var active: std.ArrayList(Target) = .empty;
        for (indices.items) |idx| {
            for (session.ledger.entries.items[idx].targets) |t| try active.append(arena, t);
        }
        try session.appendToolResults(indices.items);
        const advance = try session.advance(active.items);
        collapsed += advance.collapsed;
        freed += advance.freed;
    }

    const final_text = try gpa.dupe(u8, "");
    return .{ .final_text = final_text, .stop_reason = stop_reason, .turns = turns, .tool_calls = tool_calls, .collapsed = collapsed, .freed_tokens = freed };
}

fn gatherText(gpa: Allocator, content: []const api.ContentBlock) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (content) |block| {
        switch (block) {
            .text => |t| {
                if (out.items.len != 0) try out.append(gpa, '\n');
                try out.appendSlice(gpa, t);
            },
            else => {},
        }
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

const MockTransport = struct {
    gpa: Allocator,
    bodies: []const []const u8,
    i: usize = 0,

    fn post(ctx: *anyopaque, url: []const u8, headers: []const api.Header, body: []const u8) anyerror![]u8 {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        _ = url;
        _ = headers;
        _ = body;
        if (self.i >= self.bodies.len) return error.NoMoreResponses;
        const out = try self.gpa.dupe(u8, self.bodies[self.i]);
        self.i += 1;
        return out;
    }

    fn transport(self: *MockTransport) api.Transport {
        return .{ .ctx = self, .postFn = post };
    }
};

const MockDispatcher = struct {
    reply: []const u8,

    fn call(ctx: *anyopaque, gpa: Allocator, name: []const u8, input_json: []const u8) anyerror!Dispatch {
        const self: *MockDispatcher = @ptrCast(@alignCast(ctx));
        _ = name;
        _ = input_json;
        return .{ .text = try gpa.dupe(u8, self.reply), .is_error = false };
    }

    fn dispatcher(self: *MockDispatcher) Dispatcher {
        return .{ .ctx = self, .callFn = call };
    }
};

test "the loop runs a tool turn then a final turn and returns the assistant text" {
    const bodies = [_][]const u8{
        "{\"stop_reason\":\"tool_use\",\"content\":[{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"emetgate_search\",\"input\":{\"pattern\":\"fold\"}}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}",
        "{\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"found it in read_budget.zig\"}],\"usage\":{\"input_tokens\":20,\"output_tokens\":6}}",
    };
    var mt: MockTransport = .{ .gpa = testing.allocator, .bodies = &bodies };
    var md: MockDispatcher = .{ .reply = "read_budget.zig:4 default_budget\nread_budget.zig:93 fold" };

    const outcome = try run(testing.allocator, mt.transport(), "test-key", md.dispatcher(), &.{}, .{}, "where is the fold budget");
    defer outcome.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), outcome.turns);
    try testing.expectEqual(@as(usize, 1), outcome.tool_calls);
    try testing.expectEqualStrings("end_turn", outcome.stop_reason);
    try testing.expectEqualStrings("found it in read_budget.zig", outcome.final_text);
}

test "the loop terminates at max_turns when the model never stops calling tools" {
    const loop_body = "{\"stop_reason\":\"tool_use\",\"content\":[{\"type\":\"tool_use\",\"id\":\"tu_x\",\"name\":\"emetgate_search\",\"input\":{\"pattern\":\"x\"}}],\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}";
    const bodies = [_][]const u8{ loop_body, loop_body, loop_body };
    var mt: MockTransport = .{ .gpa = testing.allocator, .bodies = &bodies };
    var md: MockDispatcher = .{ .reply = "hit" };

    const outcome = try run(testing.allocator, mt.transport(), "k", md.dispatcher(), &.{}, .{ .max_turns = 3 }, "go");
    defer outcome.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), outcome.turns);
    try testing.expectEqual(@as(usize, 3), outcome.tool_calls);
    try testing.expectEqualStrings("max_turns", outcome.stop_reason);
}
