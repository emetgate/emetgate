const std = @import("std");
const symbol = @import("emetgate").symbol;
const test_util = @import("emetgate").test_util;

const testing = std.testing;

const Pinned = struct { ref: []const u8, hash: []const u8 };

const pinned_functions = [_]Pinned{
    .{ .ref = "add", .hash = "35b462b8e42e39e0fe66ae0dae747ab7" },
    .{ .ref = "stream", .hash = "d3be7d2963b0fa23bf52bea21e306f7a" },
    .{ .ref = "overloaded", .hash = "a2a63dbd63eb6320caefeb5b2766c5e6" },
    .{ .ref = "validateToken", .hash = "6398a233acddef9d0c7dfd96f8cc0c58" },
    .{ .ref = "validateToken.helper", .hash = "00f6980b7d63f290b31f46de0b1a9871" },
    .{ .ref = "square", .hash = "59d24a70163089b7090819e80943bc84" },
    .{ .ref = "Repository.handler", .hash = "a92dfc29edf55e236a6624b610c05381" },
    .{ .ref = "Repository.constructor", .hash = "e7330ccf1253769182b6ce1e3f8d0a35" },
    .{ .ref = "Repository.label@get", .hash = "c914a85c63ec981cc4b5d74e91040561" },
    .{ .ref = "Repository.label@set", .hash = "4e345f9b88cc79f60b06011145d2c49a" },
    .{ .ref = "Repository.now", .hash = "09f196e2efdde7bfd18128f7fa00a7a1" },
    .{ .ref = "Repository.ids", .hash = "ab7ea18eb333cea0f8ab9121e460fa3c" },
    .{ .ref = "routes.home", .hash = "26f26545458db4a5da0d648490142e3c" },
    .{ .ref = "routes.about", .hash = "b39f11b3d932d463dd7ccdff40732f6e" },
    .{ .ref = "Legacy.old", .hash = "c2330df3c57d1f2c53aa8cd3f52c0a3e" },
    .{ .ref = "afterUnicode", .hash = "667bd5763617927d8bfd85ffa7c688f0" },
};

test "declarations: the function and method hashes of the fixture are the ones main computed before declarations joined the table" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const snapshot = try test_util.loadFixture(runtime, "functions.ts");
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    var ok = table.symbols.len == pinned_functions.len;
    for (table.symbols, 0..) |s, i| {
        const ref = try std.fmt.allocPrint(testing.allocator, "{f}", .{s.ref});
        defer testing.allocator.free(ref);
        const hex = symbol.formatHash(s.hash);
        if (i < pinned_functions.len) {
            if (!std.mem.eql(u8, pinned_functions[i].ref, ref) or !std.mem.eql(u8, pinned_functions[i].hash, &hex)) ok = false;
        }
        if (!ok) std.debug.print("    .{{ .ref = \"{s}\", .hash = \"{s}\" }},\n", .{ ref, hex });
    }
    try testing.expect(ok);
}

test "declarations: classes, fields, interfaces, types, enums, members and variables of the fixture are addressable" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const snapshot = try test_util.loadFixture(runtime, "functions.ts");
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    const expected = [_]struct { ref: []const u8, kind: []const u8 }{
        .{ .ref = "Clock", .kind = "interface" },
        .{ .ref = "Handler", .kind = "type_alias" },
        .{ .ref = "Repository", .kind = "class" },
        .{ .ref = "Repository.instances@static", .kind = "field" },
        .{ .ref = "routes", .kind = "variable" },
        .{ .ref = "Level", .kind = "enumeration" },
        .{ .ref = "Level.Low", .kind = "enum_member" },
        .{ .ref = "Level.High", .kind = "enum_member" },
        .{ .ref = "counter", .kind = "variable" },
        .{ .ref = "greeting", .kind = "variable" },
    };
    errdefer for (table.declarations) |d| std.debug.print("got {f} {t}\n", .{ d.ref, d.kind });
    try testing.expectEqual(expected.len, table.declarations.len);
    for (expected, table.declarations) |want, got| {
        const ref = try std.fmt.allocPrint(testing.allocator, "{f}", .{got.ref});
        defer testing.allocator.free(ref);
        try testing.expectEqualStrings(want.ref, ref);
        try testing.expectEqualStrings(want.kind, @tagName(got.kind));
        try testing.expect(!got.ambiguous);
    }
}

test "declarations: a declaration hash is domain separated, so the same text never hashes like a function" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const source = "const f = 1;\n";
    const snapshot = try test_util.snapshotOf(runtime, source);
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    try testing.expectEqual(@as(usize, 1), table.declarations.len);
    try testing.expect(!std.mem.eql(u8, &table.declarations[0].hash, &symbol.hashOf(source)));
    try testing.expect(!std.mem.eql(u8, &table.declarations[0].hash, &symbol.hashOf(source[0 .. source.len - 1])));
}

test "declarations: a merged interface and class share a ref and are marked ambiguous, a destructuring and a function value are not declarations" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const snapshot = try test_util.snapshotOf(runtime, "interface Box { a: number }\nclass Box { b = 1; run = () => 2; }\nconst { x, y } = { x: 1, y: 2 };\nconst f = () => 1, g = 3;\n");
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    errdefer for (table.declarations) |d| std.debug.print("got {f} {t}\n", .{ d.ref, d.kind });
    try testing.expectEqual(@as(usize, 4), table.declarations.len);
    try testing.expect(table.declarations[0].ambiguous and table.declarations[1].ambiguous);
    try testing.expectEqualStrings("b", table.declarations[2].ref.name);
    try testing.expectEqualStrings("g", table.declarations[3].ref.name);
}
