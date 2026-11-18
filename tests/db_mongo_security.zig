const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const fake_mod = @import("mongo_fake.zig");
const mongo = emetgate.db_mongo;
const engine = emetgate.db_engine;
const render = emetgate.db_render;
const access = emetgate.db_access;

const testing = std.testing;
const Fake = fake_mod.Fake;

const users_docs =
    \\[{"_id":1,"name":"Alice","email":"alice@example.com","ssn":"111-22-3333","SSN":"HASH-CASE","password_hash":"HASH-A","age":30,"profile":{"city":"Izmir"}},
    \\ {"_id":2,"name":"Bob","email":"bob@example.com","ssn":"444-55-6666","password_hash":"HASH-B","age":41,"profile":{"city":"Ankara"}},
    \\ {"_id":3,"name":"Carol","email":"carol@example.com","ssn":"777-88-9999","password_hash":"HASH-C","age":25},
    \\ {"_id":4,"name":"Dan","email":"dan@example.com","ssn":"000-11-2222","password_hash":"HASH-D","age":52},
    \\ {"_id":5,"name":"Eve","email":"eve@example.com","ssn":"999-00-1111","password_hash":"HASH-E","age":33}]
;

const collections = [_]fake_mod.Collection{
    .{ .name = "users", .docs = users_docs },
    .{ .name = "orders", .docs = "[{\"_id\":1,\"user\":1,\"total\":9.5},{\"_id\":2,\"user\":2,\"total\":20}]" },
    .{ .name = "secret", .docs = "[{\"_id\":1,\"token\":\"TOKEN-XYZ\"}]" },
    .{ .name = "user_view", .kind = "view", .view_on = "users", .pipeline = "[{\"$project\":{\"name\":1,\"x\":\"$ssn\"}}]", .docs = "[{\"_id\":1,\"name\":\"Alice\",\"x\":\"111-22-3333\"}]" },
    .{ .name = "secret_view", .kind = "view", .view_on = "secret", .pipeline = "[]", .docs = "[{\"_id\":1,\"token\":\"TOKEN-XYZ\"}]" },
    .{ .name = "big_orders", .kind = "view", .view_on = "orders", .pipeline = "[{\"$match\":{\"total\":{\"$gt\":10}}}]", .docs = "[{\"_id\":2,\"user\":2,\"total\":20}]" },
    .{ .name = "orders_nested", .kind = "view", .view_on = "orders", .pipeline = "[{\"$facet\":{\"all\":[{\"$match\":{}}]}}]", .docs = "[{\"all\":[{\"_id\":1,\"password_hash\":\"HASH-O\"}]}]" },
    .{ .name = "system.views", .docs = "[]" },
};

const secrets = [_][]const u8{ "111-22", "444-55", "777-88", "HASH-", "TOKEN-XYZ", "alice@", "bob@", "carol@", "dan@", "eve@" };

const rules: access.Access = .{
    .hidden = &.{ .{ .table = "users", .column = "ssn" }, .{ .table = "*", .column = "password_hash" } },
    .masked = &.{.{ .table = "users", .column = "email", .mode = .email }},
    .blocked_tables = &.{"secret"},
};

const Setup = struct {
    fake: *Fake,
    conn: *mongo.Conn,

    fn init(mode: engine.Mode, limits: engine.Limits) !Setup {
        return initWith(mode, limits, rules, .{});
    }

    fn initWith(mode: engine.Mode, limits: engine.Limits, given: access.Access, options: fake_mod.Options) !Setup {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const fake = try Fake.start(testing.allocator, &collections, options);
        errdefer fake.stopAndFree();
        var buf: [200]u8 = undefined;
        var why: mongo.OpenProblem = .{};
        const conn = mongo.open(testing.allocator, fake.uri(&buf), .{ .io = testing.io, .mode = mode, .access = given, .limits = limits }, &why) catch |err| {
            std.debug.print("open failed: {s}\n", .{why.text()});
            return err;
        };
        return .{ .fake = fake, .conn = conn };
    }

    fn deinit(self: Setup) void {
        self.conn.close();
        self.fake.stopAndFree();
    }
};

const Ran = struct {
    err: ?anyerror,
    text: []u8,
    rows: usize,
    more: bool,

    fn deinit(self: Ran) void {
        testing.allocator.free(self.text);
    }
};

fn query(conn: *mongo.Conn, text: []const u8) !Ran {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var rows: render.Rows = .init(testing.allocator, .json, conn.limits);
    defer rows.deinit();
    const outcome = conn.query(arena_state.allocator(), text, rows.sink()) catch |err| {
        return .{ .err = err, .text = try testing.allocator.dupe(u8, conn.problem()), .rows = 0, .more = false };
    };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    for (rows.columns) |column| try out.writer.print("{s},", .{column.name});
    try out.writer.print("|{s}", .{rows.written()});
    return .{ .err = null, .text = try out.toOwnedSlice(), .rows = outcome.rows, .more = outcome.more };
}

fn expectNoLeak(text: []const u8) !void {
    for (secrets) |secret| {
        if (std.mem.indexOf(u8, text, secret) != null) {
            std.debug.print("leaked {s} in: {s}\n", .{ secret, text });
            return error.TestLeaked;
        }
    }
}

fn expectRefused(s: Setup, text: []const u8, want: anyerror) !void {
    const before = s.fake.sent("aggregate");
    const ran = try query(s.conn, text);
    defer ran.deinit();
    try expectNoLeak(ran.text);
    if (ran.err) |err| {
        if (err != want) {
            std.debug.print("{s}: wanted {t}, got {t}: {s}\n", .{ text, want, err, ran.text });
            return error.TestWrongRefusal;
        }
        if (s.fake.sent("aggregate") != before) {
            std.debug.print("{s}: refused, but only after it reached the server\n", .{text});
            return error.TestSentBeforeRefusal;
        }
        return;
    }
    std.debug.print("{s}: wanted {t}, it ran: {s}\n", .{ text, want, ran.text });
    return error.TestExpectedRefusal;
}

fn expectRuns(s: Setup, text: []const u8, contains: []const []const u8) !void {
    const ran = try query(s.conn, text);
    defer ran.deinit();
    try expectNoLeak(ran.text);
    if (ran.err) |err| {
        std.debug.print("{s}: wanted rows, got {t}: {s}\n", .{ text, err, ran.text });
        return error.TestUnexpectedRefusal;
    }
    for (contains) |part| {
        if (std.mem.indexOf(u8, ran.text, part) == null) {
            std.debug.print("{s}: wanted {s} in: {s}\n", .{ text, part, ran.text });
            return error.TestExpectedText;
        }
    }
}

fn expectSent(s: Setup, verb: []const u8, contains: []const []const u8) !void {
    const line = s.fake.last(verb) orelse return error.TestNothingSent;
    for (contains) |part| {
        if (std.mem.indexOf(u8, line, part) == null) {
            std.debug.print("wanted {s} in the sent command: {s}\n", .{ part, line });
            return error.TestExpectedText;
        }
    }
}

test "db mongo security: hidden fields are stripped and masked fields masked even when the server ignores the pipeline" {
    const s = try Setup.init(.read, .{});
    defer s.deinit();
    try expectRuns(s, "{\"find\":\"users\"}", &.{ "a***@example.com", "Alice", "profile," });
    try expectSent(s, "aggregate", &.{ "{\"$unset\":[\"ssn\",\"password_hash\"]}", "{\"$limit\":201}", "\"maxTimeMS\"" });
    try expectRuns(s, "{\"find\":\"users\",\"projection\":{\"email\":1,\"name\":1}}", &.{"b***@example.com"});
    try expectRuns(s, "{\"aggregate\":\"users\",\"pipeline\":[{\"$match\":{\"age\":{\"$gt\":20}}}]}", &.{"c***@example.com"});
    const sent = s.fake.last("aggregate").?;
    try testing.expect(std.mem.indexOf(u8, sent, "{\"$unset\":[\"ssn\",\"password_hash\"]}") != null);
    try testing.expect(std.mem.startsWith(u8, sent[std.mem.indexOf(u8, sent, "\"pipeline\":[").? + 12 ..], "{\"$unset\""));
    const ran = try query(s.conn, "{\"find\":\"users\"}");
    defer ran.deinit();
    try testing.expect(std.mem.indexOf(u8, ran.text, "ssn") == null and std.mem.indexOf(u8, ran.text, "SSN") == null);
}

test "db mongo security: a hidden field named in a filter, sort, projection, distinct key, dotted path, regex or $expr is refused before anything is sent" {
    const s = try Setup.init(.read, .{});
    defer s.deinit();
    for ([_][]const u8{
        "{\"find\":\"users\",\"filter\":{\"ssn\":\"111-22-3333\"}}",
        "{\"find\":\"users\",\"filter\":{\"ssn\":{\"$regex\":\"^1\"}}}",
        "{\"find\":\"users\",\"filter\":{\"SSN\":{\"$exists\":true}}}",
        "{\"find\":\"users\",\"filter\":{\"ssn.0\":\"1\"}}",
        "{\"find\":\"users\",\"filter\":{\"$or\":[{\"age\":1},{\"ssn\":{\"$gt\":\"5\"}}]}}",
        "{\"find\":\"users\",\"filter\":{\"$expr\":{\"$gt\":[\"$ssn\",\"5\"]}}}",
        "{\"find\":\"users\",\"filter\":{\"age\":{\"$not\":{\"$gt\":1}},\"password_hash\":{\"$in\":[\"x\"]}}}",
        "{\"find\":\"users\",\"sort\":{\"ssn\":1}}",
        "{\"find\":\"users\",\"projection\":{\"ssn\":1}}",
        "{\"find\":\"users\",\"projection\":{\"x\":\"$ssn\"}}",
        "{\"find\":\"users\",\"projection\":{\"x\":{\"$concat\":[\"$name\",\"$ssn\"]}}}",
        "{\"distinct\":\"users\",\"key\":\"ssn\"}",
        "{\"countDocuments\":\"users\",\"filter\":{\"ssn\":{\"$regex\":\"^1\"}}}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$group\":{\"_id\":\"$ssn\"}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$addFields\":{\"x\":{\"$regexMatch\":{\"input\":\"$ssn\",\"regex\":\"^1\"}}}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$unwind\":\"$ssn\"}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$sortByCount\":\"$password_hash\"}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$setWindowFields\":{\"sortBy\":{\"ssn\":1},\"output\":{\"r\":{\"$rank\":{}}}}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$project\":{\"x\":{\"$map\":{\"input\":[1],\"as\":\"i\",\"in\":\"$ssn\"}}}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$group\":{\"_id\":null,\"t\":{\"$topN\":{\"n\":1,\"sortBy\":{\"ssn\":1},\"output\":\"$name\"}}}}]}",
    }) |text| try expectRefused(s, text, error.HiddenFieldUsed);
}

test "db mongo security: $$ROOT, $$CURRENT, a rebound CURRENT and whole-document operators are refused" {
    const s = try Setup.init(.read, .{});
    defer s.deinit();
    for ([_][]const u8{
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$project\":{\"doc\":\"$$ROOT\"}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$replaceRoot\":{\"newRoot\":{\"wrapped\":\"$$CURRENT\"}}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$project\":{\"kv\":{\"$objectToArray\":\"$$ROOT\"}}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$replaceWith\":{\"$mergeObjects\":[\"$$ROOT\",{\"a\":1}]}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$group\":{\"_id\":null,\"all\":{\"$push\":\"$$ROOT\"}}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$project\":{\"n\":{\"$bsonSize\":\"$$CURRENT\"}}}]}",
        "{\"find\":\"users\",\"filter\":{\"$expr\":{\"$eq\":[{\"$size\":{\"$objectToArray\":\"$$ROOT\"}},8]}}}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$project\":{\"x\":{\"$setField\":{\"field\":\"a\",\"input\":\"$$ROOT\",\"value\":1}}}}]}",
    }) |text| try expectRefused(s, text, error.OperatorDenied);
    for ([_][]const u8{
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$project\":{\"x\":\"$$ROOT.ssn\"}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$project\":{\"x\":\"$$CURRENT.password_hash\"}}]}",
    }) |text| try expectRefused(s, text, error.HiddenFieldUsed);
    for ([_][]const u8{
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$project\":{\"x\":{\"$let\":{\"vars\":{\"CURRENT\":\"$profile\"},\"in\":\"$city\"}}}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$project\":{\"x\":{\"$map\":{\"input\":\"$tags\",\"as\":\"ROOT\",\"in\":\"$$ROOT\"}}}}]}",
    }) |text| try expectRefused(s, text, error.CommandInvalid);
    try expectRuns(s, "{\"aggregate\":\"users\",\"pipeline\":[{\"$project\":{\"city\":\"$$ROOT.profile.city\",\"kv\":{\"$objectToArray\":\"$profile\"}}}]}", &.{"Izmir"});
}

test "db mongo security: $getField, $setField and $unsetField take only a literal field name, which is checked" {
    const s = try Setup.init(.read, .{});
    defer s.deinit();
    for ([_][]const u8{
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$project\":{\"x\":{\"$getField\":\"ssn\"}}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$project\":{\"x\":{\"$getField\":{\"field\":\"ssn\",\"input\":\"$$CURRENT\"}}}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$project\":{\"x\":{\"$getField\":{\"field\":{\"$literal\":\"password_hash\"},\"input\":\"$$ROOT\"}}}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$project\":{\"x\":{\"$getField\":\"ssn.part\"}}}]}",
    }) |text| try expectRefused(s, text, error.HiddenFieldUsed);
    for ([_][]const u8{
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$project\":{\"x\":{\"$getField\":{\"field\":{\"$concat\":[\"s\",\"sn\"]},\"input\":\"$$ROOT\"}}}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$project\":{\"x\":{\"$getField\":{\"$toLower\":\"SSN\"}}}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$project\":{\"x\":{\"$setField\":{\"field\":{\"$concat\":[\"a\"]},\"input\":{},\"value\":1}}}}]}",
    }) |text| try expectRefused(s, text, error.OperatorDenied);
    try expectRuns(s, "{\"aggregate\":\"users\",\"pipeline\":[{\"$project\":{\"n\":{\"$getField\":\"name\"}}}]}", &.{"Alice"});
}

test "db mongo security: a masked field comes back masked as it is but is never filtered, sorted, grouped, renamed or computed with" {
    const s = try Setup.init(.read, .{});
    defer s.deinit();
    try expectRuns(s, "{\"find\":\"users\",\"projection\":{\"email\":1}}", &.{"a***@example.com"});
    try expectRuns(s, "{\"aggregate\":\"users\",\"pipeline\":[{\"$project\":{\"email\":true,\"age\":1}}]}", &.{"d***@example.com"});
    for ([_][]const u8{
        "{\"find\":\"users\",\"filter\":{\"email\":{\"$regex\":\"^a\"}}}",
        "{\"find\":\"users\",\"filter\":{\"email\":\"alice@example.com\"}}",
        "{\"find\":\"users\",\"sort\":{\"email\":1}}",
        "{\"find\":\"users\",\"projection\":{\"e\":\"$email\"}}",
        "{\"find\":\"users\",\"projection\":{\"email.x\":1}}",
        "{\"find\":\"users\",\"projection\":{\"email\":{\"$substrCP\":[\"$email\",0,3]}}}",
        "{\"distinct\":\"users\",\"key\":\"email\"}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$group\":{\"_id\":\"$email\"}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$group\":{\"_id\":null,\"e\":{\"$push\":\"$email\"}}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$project\":{\"len\":{\"$strLenCP\":\"$email\"}}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$match\":{\"$expr\":{\"$eq\":[{\"$substrCP\":[\"$email\",0,1]},\"a\"]}}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$unwind\":{\"path\":\"$email\"}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$bucketAuto\":{\"groupBy\":\"$email\",\"buckets\":2}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$replaceWith\":{\"e\":\"$email\"}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$project\":{\"x\":{\"$getField\":\"email\"}}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$sort\":{\"email\":-1}}]}",
    }) |text| try expectRefused(s, text, error.MaskedFieldUsed);
}

test "db mongo security: $lookup, $graphLookup, $unionWith and $facet that reach guarded or blocked data are refused" {
    const s = try Setup.init(.read, .{});
    defer s.deinit();
    for ([_][]const u8{
        "{\"aggregate\":\"orders\",\"pipeline\":[{\"$lookup\":{\"from\":\"secret\",\"localField\":\"user\",\"foreignField\":\"_id\",\"as\":\"s\"}}]}",
        "{\"aggregate\":\"orders\",\"pipeline\":[{\"$unionWith\":\"secret\"}]}",
        "{\"aggregate\":\"orders\",\"pipeline\":[{\"$unionWith\":{\"coll\":\"secret_view\",\"pipeline\":[]}}]}",
        "{\"aggregate\":\"orders\",\"pipeline\":[{\"$graphLookup\":{\"from\":\"secret\",\"startWith\":\"$user\",\"connectFromField\":\"a\",\"connectToField\":\"b\",\"as\":\"g\"}}]}",
        "{\"aggregate\":\"orders\",\"pipeline\":[{\"$facet\":{\"a\":[{\"$lookup\":{\"from\":\"secret\",\"pipeline\":[],\"as\":\"s\"}}]}}]}",
        "{\"aggregate\":\"secret\",\"pipeline\":[]}",
        "{\"find\":\"secret_view\"}",
        "{\"find\":\"system.views\"}",
    }) |text| try expectRefused(s, text, error.TableRefused);
    for ([_][]const u8{
        "{\"aggregate\":\"orders\",\"pipeline\":[{\"$lookup\":{\"from\":\"users\",\"localField\":\"user\",\"foreignField\":\"_id\",\"as\":\"u\"}}]}",
        "{\"aggregate\":\"orders\",\"pipeline\":[{\"$unionWith\":\"users\"}]}",
        "{\"aggregate\":\"orders\",\"pipeline\":[{\"$graphLookup\":{\"from\":\"users\",\"startWith\":\"$user\",\"connectFromField\":\"a\",\"connectToField\":\"b\",\"as\":\"g\"}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$facet\":{\"all\":[{\"$match\":{}}]}}]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$lookup\":{\"from\":\"users\",\"pipeline\":[],\"as\":\"self\"}}]}",
        "{\"aggregate\":\"orders\",\"pipeline\":[{\"$lookup\":{\"from\":{\"db\":\"other\",\"coll\":\"users\"},\"pipeline\":[],\"as\":\"x\"}}]}",
        "{\"aggregate\":\"orders\",\"pipeline\":[{\"$lookup\":{\"from\":\"user_view\",\"pipeline\":[],\"as\":\"x\"}}]}",
    }) |text| try expectRefused(s, text, error.OperatorDenied);
    try expectRefused(s, "{\"aggregate\":\"orders\",\"pipeline\":[{\"$lookup\":{\"from\":\"big_orders\",\"localField\":\"user\",\"foreignField\":\"user\",\"as\":\"o\"}}]}", error.OperatorDenied);
    const narrow: access.Access = .{ .hidden = &.{.{ .table = "users", .column = "ssn" }}, .blocked_tables = &.{"secret"} };
    const n = try Setup.initWith(.read, .{}, narrow, .{});
    defer n.deinit();
    try expectRefused(n, "{\"aggregate\":\"orders\",\"pipeline\":[{\"$lookup\":{\"from\":\"big_orders\",\"let\":{\"u\":\"$user\"},\"pipeline\":[{\"$match\":{\"$expr\":{\"$eq\":[\"$user\",\"$$u\"]}}},{\"$out\":\"x\"}],\"as\":\"o\"}}]}", error.OperatorDenied);
    try expectRefused(n, "{\"aggregate\":\"orders\",\"pipeline\":[{\"$lookup\":{\"from\":\"big_orders\",\"let\":{\"u\":\"$user\"},\"pipeline\":[{\"$lookup\":{\"from\":\"secret\",\"pipeline\":[],\"as\":\"t\"}}],\"as\":\"o\"}}]}", error.TableRefused);
    try expectRuns(n, "{\"aggregate\":\"orders\",\"pipeline\":[{\"$lookup\":{\"from\":\"big_orders\",\"localField\":\"user\",\"foreignField\":\"user\",\"as\":\"o\"}},{\"$facet\":{\"n\":[{\"$count\":\"c\"}]}}]}", &.{});
}

test "db mongo security: $out and $merge are never run by a read, at the top or nested" {
    const s = try Setup.init(.read, .{});
    defer s.deinit();
    for ([_][]const u8{
        "{\"aggregate\":\"orders\",\"pipeline\":[{\"$out\":\"copy\"}]}",
        "{\"aggregate\":\"orders\",\"pipeline\":[{\"$merge\":{\"into\":\"copy\"}}]}",
        "{\"aggregate\":\"orders\",\"pipeline\":[{\"$facet\":{\"a\":[{\"$out\":\"copy\"}]}}]}",
        "{\"aggregate\":\"orders\",\"pipeline\":[{\"$unionWith\":{\"coll\":\"orders\",\"pipeline\":[{\"$merge\":\"copy\"}]}}]}",
    }) |text| try expectRefused(s, text, error.OperatorDenied);
}

test "db mongo security: server-side JavaScript, $jsonSchema, $text on a guarded collection and unknown operators are refused" {
    const s = try Setup.init(.read, .{});
    defer s.deinit();
    for ([_][]const u8{
        "{\"find\":\"users\",\"filter\":{\"$where\":\"this.ssn.startsWith('1')\"}}",
        "{\"find\":\"orders\",\"filter\":{\"$where\":\"sleep(100000)\"}}",
        "{\"find\":\"orders\",\"filter\":{\"$expr\":{\"$function\":{\"body\":\"function(){return true}\",\"args\":[],\"lang\":\"js\"}}}}",
        "{\"aggregate\":\"orders\",\"pipeline\":[{\"$group\":{\"_id\":null,\"x\":{\"$accumulator\":{\"init\":\"function(){}\"}}}}]}",
        "{\"find\":\"users\",\"filter\":{\"$jsonSchema\":{\"properties\":{\"ssn\":{\"pattern\":\"^1\"}}}}}",
        "{\"find\":\"users\",\"filter\":{\"$text\":{\"$search\":\"111\"}}}",
        "{\"find\":\"orders\",\"filter\":{\"total\":{\"$geoWithin\":{}}}}",
        "{\"aggregate\":\"orders\",\"pipeline\":[{\"$redact\":\"$$KEEP\"}]}",
        "{\"aggregate\":\"orders\",\"pipeline\":[{\"$currentOp\":{}}]}",
        "{\"aggregate\":\"orders\",\"pipeline\":[{\"$project\":{\"x\":{\"$frobnicate\":1}}}]}",
        "{\"aggregate\":\"orders\",\"pipeline\":[{\"$project\":{\"x\":\"$$JS_SCOPE\"}}]}",
    }) |text| try expectRefused(s, text, error.OperatorDenied);
}

test "db mongo security: a malformed command, a write in a read, a NUL in a key and extended JSON abuse are refused" {
    const s = try Setup.init(.read, .{});
    defer s.deinit();
    for ([_][]const u8{
        "SELECT * FROM users",
        "{\"find\":\"users\",\"filter\":{},\"hint\":\"ssn_1\"}",
        "{\"find\":\"users\",\"filter\":{\"$comment\":1,\"age\":{\"$gt\":1,\"name\":2}}}",
        "{\"find\":\"users\",\"filter\":{\"age\":{\"$fake\":1,\"x\":2}}}",
        "{\"find\":{\"$x\":1}}",
        "{\"aggregate\":1,\"pipeline\":[]}",
        "{\"aggregate\":\"users\",\"pipeline\":[{\"$match\":{},\"$limit\":1}]}",
        "{\"runCommand\":\"users\"}",
    }) |text| try expectRefused(s, text, error.CommandInvalid);
    for ([_][]const u8{
        "{\"insertOne\":\"users\",\"document\":{\"name\":\"x\"}}",
        "{\"drop\":\"users\"}",
    }) |text| try expectRefused(s, text, error.StatementNotRead);
    try expectRefused(s, "{\"find\":\"orders\",\"filter\":{\"to\\u0000tal\":1}}", error.CommandInvalid);
    try expectRefused(s, "{\"find\":\"users\",\"filter\":{\"ssn\\u0000x\":1}}", error.CommandInvalid);
    try expectRefused(s, "{\"find\":\"users\",\"filter\":{\"profile\":{\"$ssn\":1}}}", error.OperatorDenied);
    try expectRefused(s, "{\"find\":\"orders\",\"filter\":{\"_id\":{\"$oid\":\"nothex\"}}}", error.CommandInvalid);
    try expectRuns(s, "{\"find\":\"orders\",\"filter\":{\"_id\":{\"$oid\":\"64b7f0c2a1b2c3d4e5f60718\"},\"at\":{\"$gte\":{\"$date\":\"2024-01-01T00:00:00Z\"}}}}", &.{});
    try expectSent(s, "aggregate", &.{ "{\"$oid\":\"64b7f0c2a1b2c3d4e5f60718\"}", "{\"$date\":\"2024-01-01T00:00:00Z\"}" });
}

test "db mongo security: a blocked collection and a view over hidden data are refused in tables, count, describe and sample" {
    const s = try Setup.init(.read, .{});
    defer s.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const listed = try s.conn.tables(arena);
    try testing.expectEqual(@as(usize, 2), listed.withheld);
    for (listed.shown) |t| {
        try testing.expect(!std.mem.eql(u8, t.name, "secret") and !std.mem.eql(u8, t.name, "secret_view") and !std.mem.startsWith(u8, t.name, "system."));
    }
    try testing.expectError(error.TableRefused, s.conn.count(arena, "secret"));
    try testing.expectError(error.TableRefused, s.conn.count(arena, "secret_view"));
    try testing.expectError(error.TableRefused, s.conn.describe(arena, "secret"));
    try testing.expectError(error.TableRefused, s.conn.describe(arena, "user_view"));
    try testing.expect(std.mem.indexOf(u8, s.conn.problem(), "view user_view") != null);
    var rows: render.Rows = .init(testing.allocator, .json, s.conn.limits);
    defer rows.deinit();
    try testing.expectError(error.TableRefused, s.conn.sample(arena, "user_view", 5, rows.sink()));
    try expectRefused(s, "{\"find\":\"user_view\"}", error.TableRefused);
    try expectRefused(s, "{\"find\":\"orders_nested\"}", error.TableRefused);
    try expectRuns(s, "{\"aggregate\":\"orders\",\"pipeline\":[{\"$facet\":{\"all\":[{\"$match\":{}}]}}]}", &.{});
    try expectSent(s, "aggregate", &.{"\"pipeline\":[{\"$unset\":[\"password_hash\"]},{\"$facet\""});
    try expectRuns(s, "{\"find\":\"big_orders\"}", &.{"20"});
    try testing.expectEqual(@as(i64, 5), try s.conn.count(arena, "users"));
}

test "db mongo security: describe lists inferred field types and indexes and labels hidden and masked fields; explain shows the plan" {
    const s = try Setup.init(.read, .{});
    defer s.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try s.conn.describe(arena, "users");
    var seen_ssn = false;
    var seen_email = false;
    for (d.columns) |column| {
        if (std.mem.eql(u8, column.name, "ssn")) seen_ssn = column.treatment == .hidden;
        if (std.mem.eql(u8, column.name, "email")) seen_email = column.treatment == .masked;
        if (std.mem.eql(u8, column.name, "profile")) try testing.expectEqualStrings("object|missing", column.decl_type);
        if (std.mem.eql(u8, column.name, "_id")) try testing.expect(column.primary_key == 1 and column.not_null);
    }
    try testing.expect(seen_ssn and seen_email);
    try testing.expectEqual(@as(usize, 2), d.indexes.len);
    try testing.expectEqualStrings("age desc", d.indexes[1].columns[1]);
    const plan = try s.conn.explain(arena, "{\"find\":\"users\",\"filter\":{\"age\":{\"$gt\":3}}}");
    try testing.expectEqualStrings("FETCH", plan[0]);
    try testing.expectEqualStrings("  IXSCAN age_1 forward", plan[1]);
    try testing.expectError(error.HiddenFieldUsed, s.conn.explain(arena, "{\"find\":\"users\",\"filter\":{\"ssn\":1}}"));
}

test "db mongo security: the row cap holds and the reply says more documents exist" {
    const s = try Setup.init(.read, .{ .max_rows = 2 });
    defer s.deinit();
    const ran = try query(s.conn, "{\"find\":\"users\",\"limit\":1000}");
    defer ran.deinit();
    try testing.expect(ran.err == null);
    try testing.expectEqual(@as(usize, 2), ran.rows);
    try testing.expect(ran.more);
    try expectSent(s, "aggregate", &.{ "{\"$limit\":3}", "\"batchSize\":3" });
}

fn write(conn: *mongo.Conn, text: []const u8, destructive: bool) !engine.WriteOutcome {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const got = try conn.write(arena_state.allocator(), text, .{ .destructive = destructive });
    return .{ .action = got.action, .table = null, .changes = got.changes, .destructive = got.destructive, .elapsed_ms = 0 };
}

test "db mongo security: a write may not read or set hidden or masked fields, replace a guarded document or touch a blocked collection" {
    const s = try Setup.init(.write, .{});
    defer s.deinit();
    for ([_][]const u8{
        "{\"insertOne\":\"users\",\"document\":{\"name\":\"x\",\"ssn\":\"1\"}}",
        "{\"insertMany\":\"users\",\"documents\":[{\"name\":\"x\"},{\"email\":\"x@y\"}]}",
        "{\"updateOne\":\"users\",\"filter\":{\"_id\":1},\"update\":{\"$set\":{\"ssn\":\"1\"}}}",
        "{\"updateOne\":\"users\",\"filter\":{\"_id\":1},\"update\":{\"$set\":{\"email.domain\":\"x\"}}}",
        "{\"updateOne\":\"users\",\"filter\":{\"_id\":1},\"update\":{\"$rename\":{\"ssn\":\"open\"}}}",
        "{\"updateOne\":\"users\",\"filter\":{\"_id\":1},\"update\":{\"$rename\":{\"name\":\"password_hash\"}}}",
        "{\"updateMany\":\"users\",\"filter\":{\"email\":{\"$regex\":\"^a\"}},\"update\":{\"$set\":{\"age\":1}}}",
        "{\"deleteOne\":\"users\",\"filter\":{\"ssn\":\"111-22-3333\"}}",
        "{\"updateOne\":\"users\",\"filter\":{\"_id\":1},\"update\":{\"name\":\"replaced\"}}",
    }) |text| try testing.expectError(error.GuardedColumnInWrite, write(s.conn, text, true));
    try testing.expectError(error.OperatorDenied, write(s.conn, "{\"updateOne\":\"orders\",\"filter\":{\"_id\":1},\"update\":{\"$where\":{}}}", true));
    try testing.expectError(error.CommandInvalid, write(s.conn, "{\"updateOne\":\"orders\",\"filter\":{\"_id\":1},\"update\":[{\"$set\":{\"a\":\"$total\"}}]}", true));
    try testing.expectError(error.TableRefused, write(s.conn, "{\"deleteOne\":\"secret\",\"filter\":{\"_id\":1}}", true));
    try testing.expectError(error.TableRefused, write(s.conn, "{\"drop\":\"system.views\"}", true));
    try testing.expectError(error.StatementOnlyReads, write(s.conn, "{\"find\":\"users\"}", true));
    try testing.expectEqual(@as(usize, 0), s.fake.sent("insert") + s.fake.sent("update") + s.fake.sent("delete") + s.fake.sent("drop"));
    const ok = try write(s.conn, "{\"updateOne\":\"users\",\"filter\":{\"_id\":1},\"update\":{\"$set\":{\"age\":31}}}", false);
    try testing.expectEqual(engine.WriteAction.update, ok.action);
    try testing.expectEqual(@as(i64, 1), ok.changes);
    const inserted = try write(s.conn, "{\"insertMany\":\"orders\",\"documents\":[{\"total\":1},{\"total\":2}]}", false);
    try testing.expectEqual(@as(i64, 2), inserted.changes);
}

test "db mongo security: drop, an empty-filter or match-all deleteMany and updateMany need the destructive grant" {
    const s = try Setup.init(.write, .{});
    defer s.deinit();
    try testing.expectError(error.DestructiveNotGranted, write(s.conn, "{\"drop\":\"orders\"}", false));
    try testing.expectError(error.DestructiveNotGranted, write(s.conn, "{\"deleteMany\":\"orders\",\"filter\":{}}", false));
    try testing.expectError(error.DestructiveNotGranted, write(s.conn, "{\"updateMany\":\"users\",\"filter\":{},\"update\":{\"$set\":{\"age\":1}}}", false));
    s.fake.count_matched = 5;
    try testing.expectError(error.DestructiveNotGranted, write(s.conn, "{\"deleteMany\":\"users\",\"filter\":{\"age\":{\"$gte\":0}}}", false));
    try testing.expectError(error.DestructiveNotGranted, write(s.conn, "{\"updateMany\":\"users\",\"filter\":{\"_id\":{\"$exists\":true}},\"update\":{\"$inc\":{\"age\":1}}}", false));
    try testing.expectEqual(@as(usize, 0), s.fake.sent("delete") + s.fake.sent("update") + s.fake.sent("drop"));
    s.fake.count_matched = 2;
    const some = try write(s.conn, "{\"deleteMany\":\"users\",\"filter\":{\"age\":{\"$gte\":40}}}", false);
    try testing.expect(!some.destructive);
    try testing.expectEqual(@as(i64, 2), some.changes);
    const wiped = try write(s.conn, "{\"deleteMany\":\"orders\",\"filter\":{}}", true);
    try testing.expect(wiped.destructive);
    const dropped = try write(s.conn, "{\"drop\":\"orders\"}", true);
    try testing.expectEqual(engine.WriteAction.drop, dropped.action);
}

test "db mongo security: a read connection refuses every write command" {
    const s = try Setup.init(.read, .{});
    defer s.deinit();
    try testing.expectError(error.ActionDenied, write(s.conn, "{\"insertOne\":\"orders\",\"document\":{\"a\":1}}", true));
    try testing.expectEqual(@as(usize, 0), s.fake.sent("insert"));
}

test "db mongo security: SCRAM-SHA-256 logs in, and a wrong password or a server that cannot prove the password is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const fake = try Fake.start(testing.allocator, &collections, .{});
    defer fake.stopAndFree();
    var buf: [200]u8 = undefined;
    var why: mongo.OpenProblem = .{};
    const good = try mongo.open(testing.allocator, fake.uri(&buf), .{ .io = testing.io, .mode = .read, .access = .{}, .limits = .{} }, &why);
    good.close();
    try expectSentLine(fake, "saslStart", "SCRAM-SHA-256");
    const wrong = try std.fmt.allocPrint(testing.allocator, "mongodb://app:nope@127.0.0.1:{d}/shop", .{fake.port});
    defer testing.allocator.free(wrong);
    try testing.expectError(error.DatabaseUnavailable, mongo.open(testing.allocator, wrong, .{ .io = testing.io, .mode = .read, .access = .{}, .limits = .{} }, &why));
    try testing.expect(std.mem.indexOf(u8, why.text(), "Authentication failed") != null);
    const forged = try Fake.start(testing.allocator, &collections, .{ .forge_signature = true });
    defer forged.stopAndFree();
    try testing.expectError(error.DatabaseUnavailable, mongo.open(testing.allocator, forged.uri(&buf), .{ .io = testing.io, .mode = .read, .access = .{}, .limits = .{} }, &why));
    try testing.expect(std.mem.indexOf(u8, why.text(), "signature") != null);
    try testing.expectError(error.DatabaseUnavailable, mongo.open(testing.allocator, "mongodb+srv://a:b@cluster.example.net/app", .{ .io = testing.io, .mode = .read, .access = .{}, .limits = .{} }, &why));
}

fn expectSentLine(fake: *Fake, verb: []const u8, part: []const u8) !void {
    const line = fake.last(verb) orelse return error.TestNothingSent;
    if (std.mem.indexOf(u8, line, part) == null) return error.TestExpectedText;
}

test "db mongo security: a wildcard hidden rule hides a field in every collection, and a whole-collection rule refuses reads" {
    const wide: access.Access = .{ .hidden = &.{ .{ .table = "*", .column = "total" }, .{ .table = "users", .column = "*" } } };
    const s = try Setup.initWith(.read, .{}, wide, .{});
    defer s.deinit();
    try expectRefused(s, "{\"find\":\"orders\",\"sort\":{\"total\":1}}", error.HiddenFieldUsed);
    try expectRuns(s, "{\"find\":\"orders\"}", &.{"user,"});
    const ran = try query(s.conn, "{\"find\":\"orders\"}");
    defer ran.deinit();
    try testing.expect(std.mem.indexOf(u8, ran.text, "total") == null);
    try expectRefused(s, "{\"find\":\"users\"}", error.HiddenFieldUsed);
}

const server = emetgate.server;
const db_tool = emetgate.db_tool;
const db_command = emetgate.db_command;
const db_config = emetgate.db_config;

const ToolReply = struct { text: []u8, is_error: bool };

fn toolCall(root: []const u8, session: *db_tool.Session, tool: []const u8, args: []const u8) !ToolReply {
    const line = try std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ tool, args });
    defer testing.allocator.free(line);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = try server.handleMessageObserved(testing.allocator, testing.io, undefined, line, &out.writer, null, .{ .root = root, .db_session = session });
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?;
    const text = result.object.get("content").?.array.items[0].object.get("text").?.string;
    return .{ .text = try testing.allocator.dupe(u8, text), .is_error = result.object.get("isError").?.bool };
}

fn command(root: []const u8, words: []const [:0]const u8) !u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_out.deinit();
    const request = db_command.parse(words) orelse return error.TestBadCommand;
    return db_command.run(testing.allocator, testing.io, root, request, &out.writer, &err_out.writer);
}

test "db mongo security: db add checks the server and password before sealing the URI, and the tool serves what it added" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const fake = try Fake.start(testing.allocator, &collections, .{});
    defer fake.stopAndFree();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "repo/.emetgate");
    try tmp.dir.createDirPath(testing.io, "state");
    const root = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
    defer testing.allocator.free(root);
    const state = try tmp.dir.realPathFileAlloc(testing.io, "state", testing.allocator);
    defer testing.allocator.free(state);
    db_config.global_dir_override = state;
    defer db_config.global_dir_override = null;
    const wrong = try std.fmt.allocPrintSentinel(testing.allocator, "mongodb://app:nope@127.0.0.1:{d}/shop", .{fake.port}, 0);
    defer testing.allocator.free(wrong);
    try testing.expectEqual(@as(u8, 1), try command(root, &.{ "add", "main", wrong }));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "state/credentials/main.dpapi", .{}));
    var buf: [200]u8 = undefined;
    const good = try testing.allocator.dupeZ(u8, fake.uri(&buf));
    defer testing.allocator.free(good);
    try testing.expectEqual(@as(u8, 0), try command(root, &.{ "add", "main", good }));
    const sealed = try tmp.dir.readFileAlloc(testing.io, "state/credentials/main.dpapi", testing.allocator, .unlimited);
    defer testing.allocator.free(sealed);
    try testing.expect(std.mem.indexOf(u8, sealed, "s3cret") == null);
    const saved = try tmp.dir.readFileAlloc(testing.io, "repo/.emetgate/db.json", testing.allocator, .unlimited);
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "\"engine\": \"mongodb\"") != null and std.mem.indexOf(u8, saved, "s3cret") == null);
    try testing.expectEqual(@as(u8, 0), try command(root, &.{ "hide", "main", "users.ssn" }));
    try testing.expectEqual(@as(u8, 0), try command(root, &.{ "hide", "main", "users.password_hash" }));
    try testing.expectEqual(@as(u8, 0), try command(root, &.{ "mask", "main", "users.email", "--mode", "email" }));
    try testing.expectEqual(@as(u8, 0), try command(root, &.{ "block", "main", "secret" }));
    var session: db_tool.Session = .init(testing.allocator, null);
    defer session.deinit();
    const listed = try toolCall(root, &session, "emetgate_db", "{\"op\":\"tables\"}");
    defer testing.allocator.free(listed.text);
    try testing.expect(!listed.is_error and std.mem.indexOf(u8, listed.text, "\"secret\"") == null);
    const found = try toolCall(root, &session, "emetgate_db", "{\"sql\":\"{\\\"find\\\":\\\"users\\\",\\\"sort\\\":{\\\"age\\\":1}}\"}");
    defer testing.allocator.free(found.text);
    try expectNoLeak(found.text);
    try testing.expect(!found.is_error and std.mem.indexOf(u8, found.text, "\"masked\":[\"email\"]") != null and std.mem.indexOf(u8, found.text, "\"hidden\":[\"users.ssn\",\"users.password_hash\"]") != null);
    const refused = try toolCall(root, &session, "emetgate_db", "{\"sql\":\"{\\\"find\\\":\\\"users\\\",\\\"filter\\\":{\\\"ssn\\\":{\\\"$regex\\\":\\\"^1\\\"}}}\"}");
    defer testing.allocator.free(refused.text);
    try testing.expect(refused.is_error and std.mem.indexOf(u8, refused.text, "\"error\":\"HiddenFieldUsed\"") != null and std.mem.indexOf(u8, refused.text, "\"fix\"") != null);
    const bad = try toolCall(root, &session, "emetgate_db", "{\"sql\":\"SELECT * FROM users\"}");
    defer testing.allocator.free(bad.text);
    try testing.expect(bad.is_error and std.mem.indexOf(u8, bad.text, "\"error\":\"CommandInvalid\"") != null and std.mem.indexOf(u8, bad.text, "countDocuments") != null);
    const timeout = try toolCall(root, &session, "emetgate_db", "{\"sql\":\"{\\\"find\\\":\\\"slow\\\"}\"}");
    defer testing.allocator.free(timeout.text);
    try testing.expect(timeout.is_error and std.mem.indexOf(u8, timeout.text, "\"error\":\"QueryTimeout\"") != null);
    const written = try toolCall(root, &session, "emetgate_db_write", "{\"sql\":\"{\\\"insertOne\\\":\\\"orders\\\",\\\"document\\\":{\\\"a\\\":1}}\"}");
    defer testing.allocator.free(written.text);
    try testing.expect(written.is_error and std.mem.indexOf(u8, written.text, "WriteGrantUnavailable") != null);
    try testing.expectEqual(@as(usize, 0), fake.sent("insert"));
}
