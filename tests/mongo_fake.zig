const std = @import("std");
const emetgate = @import("emetgate");
const bson = emetgate.db_bson;
const wire = emetgate.db_mongo_wire;
const scram = emetgate.db_scram;

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Collection = struct {
    name: []const u8,
    kind: []const u8 = "collection",
    view_on: ?[]const u8 = null,
    pipeline: []const u8 = "[]",
    docs: []const u8 = "[]",
};

pub const Options = struct {
    user: []const u8 = "app",
    password: []const u8 = "s3cret",
    forge_signature: bool = false,
    writable: bool = true,
};

pub const Fake = struct {
    gpa: Allocator,
    listener: wire.SOCKET,
    port: u16,
    thread: std.Thread = undefined,
    collections: []const Collection,
    options: Options,
    count_matched: i64 = 1,
    log: std.ArrayList([]u8) = .empty,
    stop: std.atomic.Value(bool) = .init(false),
    client: std.atomic.Value(usize) = .init(wire.invalid_socket),

    pub fn start(gpa: Allocator, collections: []const Collection, options: Options) !*Fake {
        wire.startup();
        const listener = wire.socket(2, 1, 6);
        if (listener == wire.invalid_socket) return error.SkipZigTest;
        var addr = [_]u8{0} ** 16;
        addr[0] = 2;
        addr[4] = 127;
        addr[7] = 1;
        if (wire.bind(listener, &addr, 16) != 0 or wire.listen(listener, 4) != 0) {
            _ = wire.closesocket(listener);
            return error.SkipZigTest;
        }
        var bound = [_]u8{0} ** 16;
        var len: i32 = 16;
        _ = wire.getsockname(listener, &bound, &len);
        const port = std.mem.readInt(u16, bound[2..4], .big);
        const self = try gpa.create(Fake);
        self.* = .{ .gpa = gpa, .listener = listener, .port = port, .collections = collections, .options = options };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn stopAndFree(self: *Fake) void {
        self.stop.store(true, .release);
        _ = wire.closesocket(self.listener);
        const client = self.client.swap(wire.invalid_socket, .acq_rel);
        if (client != wire.invalid_socket) _ = wire.closesocket(client);
        self.thread.join();
        for (self.log.items) |line| self.gpa.free(line);
        self.log.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn uri(self: *Fake, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "mongodb://{s}:{s}@127.0.0.1:{d}/shop?authSource=admin", .{ self.options.user, self.options.password, self.port }) catch unreachable;
    }

    pub fn sent(self: *Fake, verb: []const u8) usize {
        var n: usize = 0;
        for (self.log.items) |line| {
            if (std.mem.startsWith(u8, line[2..], verb)) n += 1;
        }
        return n;
    }

    pub fn last(self: *Fake, verb: []const u8) ?[]const u8 {
        var i = self.log.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.startsWith(u8, self.log.items[i][2..], verb)) return self.log.items[i];
        }
        return null;
    }

    fn run(self: *Fake) void {
        while (!self.stop.load(.acquire)) {
            const s = wire.accept(self.listener, null, null);
            if (s == wire.invalid_socket) return;
            self.client.store(s, .release);
            if (self.stop.load(.acquire)) {
                if (self.client.swap(wire.invalid_socket, .acq_rel) != wire.invalid_socket) _ = wire.closesocket(s);
                return;
            }
            self.serve(s) catch {};
            if (self.client.swap(wire.invalid_socket, .acq_rel) != wire.invalid_socket) _ = wire.closesocket(s);
        }
    }

    fn recvAll(s: wire.SOCKET, buf: []u8) !void {
        var at: usize = 0;
        while (at < buf.len) {
            const n = wire.recv(s, buf[at..].ptr, @intCast(buf.len - at), 0);
            if (n <= 0) return error.Closed;
            at += @intCast(n);
        }
    }

    fn sendAll(s: wire.SOCKET, bytes: []const u8) !void {
        var at: usize = 0;
        while (at < bytes.len) {
            const n = wire.send(s, bytes[at..].ptr, @intCast(bytes.len - at), 0);
            if (n <= 0) return error.Closed;
            at += @intCast(n);
        }
    }

    const Sasl = struct {
        arena: Allocator,
        first_bare: []const u8 = "",
        server_first: []const u8 = "",
    };

    fn serve(self: *Fake, s: wire.SOCKET) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        var conn_state = std.heap.ArenaAllocator.init(self.gpa);
        defer conn_state.deinit();
        var sasl: Sasl = .{ .arena = conn_state.allocator() };
        while (true) {
            _ = arena_state.reset(.retain_capacity);
            const arena = arena_state.allocator();
            var head: [16]u8 = undefined;
            try recvAll(s, &head);
            const header = try wire.Header.parse(&head);
            const payload = try arena.alloc(u8, header.length - 16);
            try recvAll(s, payload);
            const body = try wire.bodyOf(payload);
            var it = body.iterator();
            const first = (try it.next()) orelse return error.Empty;
            const text = try bson.toJson(self.gpa, body);
            try self.log.append(self.gpa, text);
            const reply = try self.handle(arena, first.key, body, &sasl);
            const total = 16 + 5 + reply.len;
            const out = try arena.alloc(u8, total);
            std.mem.writeInt(i32, out[0..4], @intCast(total), .little);
            std.mem.writeInt(i32, out[4..8], 900, .little);
            std.mem.writeInt(i32, out[8..12], header.request_id, .little);
            std.mem.writeInt(i32, out[12..16], wire.op_msg, .little);
            std.mem.writeInt(u32, out[16..20], 0, .little);
            out[20] = 0;
            @memcpy(out[21..], reply);
            try sendAll(s, out);
        }
    }

    fn find(self: *Fake, name: []const u8) ?Collection {
        for (self.collections) |c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }

    fn docsOf(self: *Fake, arena: Allocator, name: []const u8) ![]const Value {
        const c = self.find(name) orelse return &.{};
        const parsed = try std.json.parseFromSliceLeaky(Value, arena, c.docs, .{});
        return parsed.array.items;
    }

    fn cursorReply(b: *bson.Builder, ns: []const u8, docs: []const Value) !void {
        try b.beginDoc("cursor");
        try b.int64("id", 0);
        try b.string("ns", ns);
        try b.beginArray("firstBatch");
        var name: [16]u8 = undefined;
        for (docs, 0..) |doc, i| try b.json(std.fmt.bufPrint(&name, "{d}", .{i}) catch unreachable, doc);
        try b.end();
        try b.end();
    }

    fn handle(self: *Fake, arena: Allocator, verb: []const u8, body: bson.Doc, sasl: *Sasl) ![]const u8 {
        var b: bson.Builder = .init(arena);
        try b.begin();
        const eql = std.mem.eql;
        if (eql(u8, verb, "hello") or eql(u8, verb, "isMaster")) {
            try b.boolean("isWritablePrimary", self.options.writable);
            try b.int32("maxWireVersion", 21);
            try b.beginArray("saslSupportedMechs");
            try b.string("0", "SCRAM-SHA-256");
            try b.end();
        } else if (eql(u8, verb, "saslStart")) {
            const payload = body.get("payload").?.binary().?.bytes;
            if (!std.mem.startsWith(u8, payload, "n,,")) return failReply(&b, "bad gs2 header");
            sasl.first_bare = try sasl.arena.dupe(u8, payload[3..]);
            const r_at = std.mem.indexOf(u8, sasl.first_bare, ",r=") orelse return failReply(&b, "no nonce");
            const nonce = sasl.first_bare[r_at + 3 ..];
            sasl.server_first = try std.fmt.allocPrint(sasl.arena, "r={s}SRVNONCE,s=c2FsdHNhbHQ=,i=4096", .{nonce});
            try b.int32("conversationId", 1);
            try b.boolean("done", false);
            try b.binary("payload", 0, sasl.server_first);
        } else if (eql(u8, verb, "saslContinue")) {
            const payload = body.get("payload").?.binary().?.bytes;
            const p_at = std.mem.indexOf(u8, payload, ",p=") orelse return failReply(&b, "no proof");
            const without = payload[0..p_at];
            var proof: [32]u8 = undefined;
            std.base64.standard.Decoder.decode(&proof, payload[p_at + 3 ..]) catch return failReply(&b, "bad proof");
            var salted: [32]u8 = undefined;
            try scram.saltedPassword(.sha256, &salted, self.options.password, "saltsalt", 4096);
            var client_key: [32]u8 = undefined;
            scram.hmac(.sha256, &client_key, &salted, "Client Key");
            var stored: [32]u8 = undefined;
            scram.hash(.sha256, &stored, &client_key);
            const auth = try std.fmt.allocPrint(arena, "{s},{s},{s}", .{ sasl.first_bare, sasl.server_first, without });
            var signature: [32]u8 = undefined;
            scram.hmac(.sha256, &signature, &stored, auth);
            var recovered: [32]u8 = undefined;
            for (&recovered, proof, signature) |*r, p, sg| r.* = p ^ sg;
            var check: [32]u8 = undefined;
            scram.hash(.sha256, &check, &recovered);
            if (!std.mem.eql(u8, &check, &stored)) {
                try b.double("ok", 0);
                try b.string("errmsg", "Authentication failed.");
                try b.int32("code", 18);
                try b.end();
                return b.bytes();
            }
            var server_key: [32]u8 = undefined;
            scram.hmac(.sha256, &server_key, &salted, "Server Key");
            var server_sig: [32]u8 = undefined;
            scram.hmac(.sha256, &server_sig, &server_key, auth);
            if (self.options.forge_signature) server_sig[0] ^= 0xFF;
            var encoded: [44]u8 = undefined;
            _ = std.base64.standard.Encoder.encode(&encoded, &server_sig);
            try b.int32("conversationId", 1);
            try b.boolean("done", true);
            try b.binary("payload", 0, try std.fmt.allocPrint(arena, "v={s}", .{&encoded}));
        } else if (eql(u8, verb, "listCollections")) {
            var docs: std.ArrayList(Value) = .empty;
            for (self.collections) |c| {
                var object: std.json.ObjectMap = .empty;
                try object.put(arena, "name", .{ .string = c.name });
                try object.put(arena, "type", .{ .string = c.kind });
                if (c.view_on) |on| {
                    var options: std.json.ObjectMap = .empty;
                    try options.put(arena, "viewOn", .{ .string = on });
                    try options.put(arena, "pipeline", try std.json.parseFromSliceLeaky(Value, arena, c.pipeline, .{}));
                    try object.put(arena, "options", .{ .object = options });
                }
                try docs.append(arena, .{ .object = object });
            }
            try cursorReply(&b, "shop.$cmd.listCollections", docs.items);
        } else if (eql(u8, verb, "aggregate")) {
            const coll = body.get("aggregate").?.string().?;
            if (std.mem.eql(u8, coll, "slow")) {
                b.buf.items.len = 4;
                try b.double("ok", 0);
                try b.string("errmsg", "operation exceeded time limit");
                try b.int32("code", 50);
                try b.string("codeName", "MaxTimeMSExpired");
                try b.end();
                return b.bytes();
            }
            const pipeline = body.get("pipeline").?.doc().?;
            var pit = pipeline.iterator();
            const first_stage = (try pit.next()) orelse return failReply(&b, "empty");
            const stage_doc = first_stage.doc().?;
            const docs = try self.docsOf(arena, coll);
            if (stage_doc.get("$sample") != null and std.mem.indexOf(u8, body.bytes, "$objectToArray") != null) {
                var shaped: std.ArrayList(Value) = .empty;
                for (docs) |doc| {
                    var pairs = std.json.Array.init(arena);
                    var dit = doc.object.iterator();
                    while (dit.next()) |entry| {
                        var pair: std.json.ObjectMap = .empty;
                        try pair.put(arena, "k", .{ .string = entry.key_ptr.* });
                        try pair.put(arena, "t", .{ .string = switch (entry.value_ptr.*) {
                            .string => "string",
                            .integer => "int",
                            .float => "double",
                            .bool => "bool",
                            .null => "null",
                            .array => "array",
                            else => "object",
                        } });
                        try pairs.append(.{ .object = pair });
                    }
                    var wrapped: std.json.ObjectMap = .empty;
                    try wrapped.put(arena, "f", .{ .array = pairs });
                    try shaped.append(arena, .{ .object = wrapped });
                }
                try cursorReply(&b, "shop.x", shaped.items);
            } else if (stage_doc.get("$count") != null or std.mem.indexOf(u8, body.bytes, "$count") != null) {
                var object: std.json.ObjectMap = .empty;
                try object.put(arena, "count", .{ .integer = @intCast(docs.len) });
                try cursorReply(&b, "shop.x", &.{.{ .object = object }});
            } else try cursorReply(&b, try std.fmt.allocPrint(arena, "shop.{s}", .{coll}), docs);
        } else if (eql(u8, verb, "count")) {
            const coll = body.get("count").?.string().?;
            const docs = try self.docsOf(arena, coll);
            const filtered = if (body.get("query")) |q| (q.doc().?.bytes.len > 5) else false;
            try b.int64("n", if (filtered) self.count_matched else @intCast(docs.len));
        } else if (eql(u8, verb, "listIndexes")) {
            const indexes = try std.json.parseFromSliceLeaky(Value, arena, "[{\"v\":2,\"key\":{\"_id\":1},\"name\":\"_id_\"},{\"v\":2,\"key\":{\"email\":1,\"age\":-1},\"name\":\"email_1_age_-1\",\"unique\":true}]", .{});
            try cursorReply(&b, "shop.users", indexes.array.items);
        } else if (eql(u8, verb, "explain")) {
            const plan = try std.json.parseFromSliceLeaky(Value, arena, "{\"winningPlan\":{\"stage\":\"FETCH\",\"inputStage\":{\"stage\":\"IXSCAN\",\"indexName\":\"age_1\",\"direction\":\"forward\"}}}", .{});
            try b.json("queryPlanner", plan);
        } else if (eql(u8, verb, "insert")) {
            const docs = body.get("documents").?.doc().?;
            var n: i32 = 0;
            var dit = docs.iterator();
            while (try dit.next()) |_| n += 1;
            try b.int32("n", n);
        } else if (eql(u8, verb, "update")) {
            try b.int32("n", 1);
            try b.int32("nModified", 1);
        } else if (eql(u8, verb, "delete")) {
            try b.int64("n", self.count_matched);
        } else if (eql(u8, verb, "drop") or eql(u8, verb, "killCursors") or eql(u8, verb, "ping")) {} else {
            return failReply(&b, "no such command");
        }
        try b.double("ok", 1);
        try b.end();
        return b.bytes();
    }

    fn failReply(b: *bson.Builder, message: []const u8) ![]const u8 {
        b.buf.items.len = 4;
        try b.double("ok", 0);
        try b.string("errmsg", message);
        try b.int32("code", 59);
        try b.end();
        return b.bytes();
    }
};
