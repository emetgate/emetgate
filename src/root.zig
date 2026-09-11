const std = @import("std");
const c = @import("c");

test "typescript grammar links and is ABI compatible with the core" {
    const parser = c.ts_parser_new() orelse return error.ParserAllocationFailed;
    defer c.ts_parser_delete(parser);

    const language = c.tree_sitter_typescript();
    try std.testing.expectEqual(@as(u32, 14), c.ts_language_abi_version(language));
    try std.testing.expect(c.ts_parser_set_language(parser, language));
}
