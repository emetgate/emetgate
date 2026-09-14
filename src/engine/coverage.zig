const std = @import("std");
const symbol = @import("symbol.zig");

const Allocator = std.mem.Allocator;

pub const Verdict = enum { called, not_called, unknown };

pub const Range = struct {
    startOffset: u32,
    endOffset: u32,
    count: u64,
};

pub const Function = struct {
    functionName: []const u8 = "",
    ranges: []const Range,
};

pub const Script = struct {
    url: []const u8,
    functions: []const Function,
};

pub const Payload = struct {
    result: []const Script,
};

pub const Error = error{InvalidCoverage} || Allocator.Error;

pub fn parse(gpa: Allocator, bytes: []const u8) Error!std.json.Parsed(Payload) {
    return std.json.parseFromSlice(Payload, gpa, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidCoverage,
    };
}

pub fn findScript(payload: Payload, url: []const u8) ?Script {
    var found: ?Script = null;
    for (payload.result) |script| {
        if (!std.ascii.eqlIgnoreCase(script.url, url)) continue;
        if (found != null) return null;
        found = script;
    }
    return found;
}

pub fn fileUrl(gpa: Allocator, path_abs: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "file:///");
    for (path_abs) |byte| {
        if (byte == '\\') {
            try out.append(gpa, '/');
        } else if (needsEscape(byte)) {
            try out.print(gpa, "%{X:0>2}", .{byte});
        } else {
            try out.append(gpa, byte);
        }
    }
    return out.toOwnedSlice(gpa);
}

fn needsEscape(byte: u8) bool {
    return byte <= 0x20 or byte >= 0x7f or byte == '%' or byte == '#' or byte == '?';
}

const invalid_unit = std.math.maxInt(u32);

pub fn utf16Index(gpa: Allocator, source: []const u8) Error![]u32 {
    var index: std.ArrayList(u32) = .empty;
    errdefer index.deinit(gpa);
    var i: usize = 0;
    while (i < source.len) {
        const len = std.unicode.utf8ByteSequenceLength(source[i]) catch return error.InvalidCoverage;
        if (i + len > source.len) return error.InvalidCoverage;
        _ = std.unicode.utf8Decode(source[i..][0..len]) catch return error.InvalidCoverage;
        try index.append(gpa, @intCast(i));
        if (len == 4) try index.append(gpa, invalid_unit);
        i += len;
    }
    try index.append(gpa, @intCast(source.len));
    return index.toOwnedSlice(gpa);
}

pub fn byteAt(index: []const u32, offset: u32) ?u32 {
    if (offset >= index.len) return null;
    const byte = index[offset];
    return if (byte == invalid_unit) null else byte;
}

const Located = struct { start: u32, end: u32, count: u64 };

pub fn verdicts(gpa: Allocator, source: []const u8, table: symbol.Table, script: Script) Error![]Verdict {
    const out = try gpa.alloc(Verdict, table.symbols.len);
    errdefer gpa.free(out);
    @memset(out, .unknown);

    const index = utf16Index(gpa, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidCoverage => return out,
    };
    defer gpa.free(index);

    var located: std.ArrayList(Located) = .empty;
    defer located.deinit(gpa);
    for (script.functions) |function| {
        if (function.ranges.len == 0) return out;
        const outer = function.ranges[0];
        if (isModuleWrapper(function)) continue;
        const start = byteAt(index, outer.startOffset) orelse return out;
        const end = byteAt(index, outer.endOffset) orelse return out;
        if (start >= end) return out;
        try located.append(gpa, .{ .start = start, .end = end, .count = outer.count });
    }

    for (table.symbols, out) |sym, *verdict| {
        const body_start = sym.body.startByte();
        const body_end = sym.body.endByte();
        const node_start = sym.node.startByte();
        var matches: usize = 0;
        var count: u64 = 0;
        for (located.items) |candidate| {
            if (candidate.end != body_end) continue;
            if (candidate.start < node_start or candidate.start > body_start) continue;
            matches += 1;
            count = candidate.count;
        }
        if (matches == 1) verdict.* = if (count > 0) .called else .not_called;
    }
    return out;
}

fn isModuleWrapper(function: Function) bool {
    return function.functionName.len == 0 and function.ranges[0].startOffset == 0;
}

const testing = std.testing;
const test_util = @import("test_util.zig");

const probe_source =
    "function add(a: number, b: number): number {\n" ++
    "  return a + b;\n" ++
    "}\n" ++
    "export function unused(x: string): string {\n" ++
    "  return x;\n" ++
    "}\n" ++
    "class Box {\n" ++
    "  static make(): Box { return new Box(); }\n" ++
    "  get size(): number { return 1; }\n" ++
    "  scale(n: number): number { return n * 2; }\n" ++
    "}\n" ++
    "export const square = (n: number): number => n * n;\n" ++
    "const cafe = (s: string) => { return s + '\u{e9}'; };\n" ++
    "const after = () => 1;\n" ++
    "add(1, 2); Box.make().size; square(3); cafe('x'); after();\n";

const probe_functions =
    \\{"functionName":"","ranges":[{"startOffset":0,"endOffset":609,"count":1}]},
    \\{"functionName":"add","ranges":[{"startOffset":0,"endOffset":62,"count":1}]},
    \\{"functionName":"unused","ranges":[{"startOffset":70,"endOffset":120,"count":0}]},
    \\{"functionName":"make","ranges":[{"startOffset":142,"endOffset":175,"count":1}]},
    \\{"functionName":"get size","ranges":[{"startOffset":178,"endOffset":210,"count":1}]},
    \\{"functionName":"scale","ranges":[{"startOffset":213,"endOffset":255,"count":0}]},
    \\{"functionName":"square","ranges":[{"startOffset":280,"endOffset":308,"count":1}]},
    \\{"functionName":"cafe","ranges":[{"startOffset":323,"endOffset":357,"count":1}]},
    \\{"functionName":"after","ranges":[{"startOffset":373,"endOffset":380,"count":1}]}
;

const probe_url = "file:///C:/repo/src/sample.ts";

fn payloadWith(comptime functions: []const u8) []const u8 {
    return "{\"result\":[{\"scriptId\":\"1\",\"url\":\"" ++ probe_url ++ "\",\"functions\":[" ++ functions ++ "]}]}";
}

const Expect = struct { ref: []const u8, verdict: Verdict };

fn expectVerdicts(source: []const u8, payload_json: []const u8, expected: []const Expect) !void {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const snapshot = try test_util.snapshotOf(runtime, source);
    defer snapshot.destroy();
    const table = try snapshot.symbols();

    const parsed = try parse(testing.allocator, payload_json);
    defer parsed.deinit();
    const script = findScript(parsed.value, probe_url) orelse return error.TestScriptMissing;
    const got = try verdicts(testing.allocator, source, table.*, script);
    defer testing.allocator.free(got);

    for (expected) |e| {
        const ref = try symbol.Ref.parse(testing.allocator, e.ref);
        defer ref.deinit(testing.allocator);
        const target = try table.resolve(ref);
        const at = (@intFromPtr(target) - @intFromPtr(table.symbols.ptr)) / @sizeOf(symbol.Symbol);
        errdefer std.debug.print("symbol {s}: expected {t}, got {t}\n", .{ e.ref, e.verdict, got[at] });
        try testing.expectEqual(e.verdict, got[at]);
    }
}

test "real node 24 offsets: called, not called and non-ASCII shifted symbols are all recognised" {
    try expectVerdicts(probe_source, payloadWith(probe_functions), &.{
        .{ .ref = "add", .verdict = .called },
        .{ .ref = "unused", .verdict = .not_called },
        .{ .ref = "Box.make@static", .verdict = .called },
        .{ .ref = "Box.size@get", .verdict = .called },
        .{ .ref = "Box.scale", .verdict = .not_called },
        .{ .ref = "square", .verdict = .called },
        .{ .ref = "cafe", .verdict = .called },
        .{ .ref = "after", .verdict = .called },
    });
}

test "a symbol with no V8 function is unknown, never not_called" {
    try expectVerdicts(probe_source, payloadWith(
        \\{"functionName":"add","ranges":[{"startOffset":0,"endOffset":62,"count":1}]}
    ), &.{
        .{ .ref = "add", .verdict = .called },
        .{ .ref = "unused", .verdict = .unknown },
        .{ .ref = "Box.scale", .verdict = .unknown },
    });
}

test "offsets from a transpiled source make the whole file unknown" {
    try expectVerdicts(probe_source, payloadWith(
        \\{"functionName":"add","ranges":[{"startOffset":0,"endOffset":62,"count":1}]},
        \\{"functionName":"unused","ranges":[{"startOffset":70,"endOffset":900,"count":0}]}
    ), &.{
        .{ .ref = "add", .verdict = .unknown },
        .{ .ref = "unused", .verdict = .unknown },
    });
}

test "shifted offsets that still land inside the source match nothing and stay unknown" {
    try expectVerdicts(probe_source, payloadWith(
        \\{"functionName":"add","ranges":[{"startOffset":3,"endOffset":65,"count":1}]},
        \\{"functionName":"unused","ranges":[{"startOffset":73,"endOffset":123,"count":0}]}
    ), &.{
        .{ .ref = "add", .verdict = .unknown },
        .{ .ref = "unused", .verdict = .unknown },
    });
}

test "an offset inside a surrogate pair makes the whole file unknown" {
    const source = "const face = () => '\u{1F600}';\nfunction f() { return 1; }\n";
    try expectVerdicts(source, payloadWith(
        \\{"functionName":"f","ranges":[{"startOffset":25,"endOffset":51,"count":1}]},
        \\{"functionName":"face","ranges":[{"startOffset":13,"endOffset":21,"count":1}]}
    ), &.{
        .{ .ref = "f", .verdict = .unknown },
    });
}

test "a surrogate pair counts as two UTF-16 units before a later function" {
    const source = "const face = () => '\u{1F600}';\nfunction f() { return 1; }\n";
    try expectVerdicts(source, payloadWith(
        \\{"functionName":"f","ranges":[{"startOffset":25,"endOffset":51,"count":1}]}
    ), &.{
        .{ .ref = "f", .verdict = .called },
    });
}

test "a range that ends with the body but starts inside it does not count for the symbol" {
    const source = "function f() { return 1; }\n";
    try expectVerdicts(source, payloadWith(
        \\{"functionName":"","ranges":[{"startOffset":15,"endOffset":26,"count":0}]}
    ), &.{
        .{ .ref = "f", .verdict = .unknown },
    });
}

test "two V8 functions that both fit one symbol make it unknown" {
    const source = "const f = () => () => 1;\n";
    try expectVerdicts(source, payloadWith(
        \\{"functionName":"f","ranges":[{"startOffset":10,"endOffset":23,"count":1}]},
        \\{"functionName":"","ranges":[{"startOffset":16,"endOffset":23,"count":0}]}
    ), &.{
        .{ .ref = "f", .verdict = .unknown },
    });
}

test "a function without ranges makes the whole file unknown" {
    try expectVerdicts(probe_source, payloadWith(
        \\{"functionName":"add","ranges":[{"startOffset":0,"endOffset":62,"count":1}]},
        \\{"functionName":"odd","ranges":[]}
    ), &.{
        .{ .ref = "add", .verdict = .unknown },
    });
}

test "malformed coverage json is InvalidCoverage" {
    try testing.expectError(error.InvalidCoverage, parse(testing.allocator, "{\"result\":"));
    try testing.expectError(error.InvalidCoverage, parse(testing.allocator, "{\"result\":[{\"url\":1}]}"));
}

test "script lookup ignores drive-letter case and refuses duplicate urls" {
    const parsed = try parse(testing.allocator,
        \\{"result":[{"url":"file:///c:/repo/a.ts","functions":[]},{"url":"file:///C:/repo/b.ts","functions":[]},{"url":"file:///C:/repo/b.ts","functions":[]}]}
    );
    defer parsed.deinit();
    try testing.expect(findScript(parsed.value, "file:///C:/repo/a.ts") != null);
    try testing.expect(findScript(parsed.value, "file:///C:/repo/b.ts") == null);
    try testing.expect(findScript(parsed.value, "file:///C:/repo/missing.ts") == null);
}

test "file urls use forward slashes and escape spaces, percent and non-ASCII bytes" {
    const url = try fileUrl(testing.allocator, "C:\\Users\\a b\\100%\\caf\u{e9}\\x.ts");
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("file:///C:/Users/a%20b/100%25/caf%C3%A9/x.ts", url);
}

test "utf16 index maps units to bytes and rejects the middle of a surrogate pair" {
    const index = try utf16Index(testing.allocator, "a\u{e9}\u{1F600}b");
    defer testing.allocator.free(index);
    try testing.expectEqual(@as(?u32, 0), byteAt(index, 0));
    try testing.expectEqual(@as(?u32, 1), byteAt(index, 1));
    try testing.expectEqual(@as(?u32, 3), byteAt(index, 2));
    try testing.expectEqual(@as(?u32, null), byteAt(index, 3));
    try testing.expectEqual(@as(?u32, 7), byteAt(index, 4));
    try testing.expectEqual(@as(?u32, 8), byteAt(index, 5));
    try testing.expectEqual(@as(?u32, null), byteAt(index, 6));
    try testing.expectError(error.InvalidCoverage, utf16Index(testing.allocator, "bad \xff byte"));
}
