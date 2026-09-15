const Cases = @import("../cases.zig").Cases;

pub const cases: Cases = .{
    .member_source =
    \\class Box {
    \\  static make = () => 1;
    \\  constructor() {}
    \\  get size() { return 1; }
    \\  set size(v: number) {}
    \\}
    \\
    ,
    .members = &.{
        .{ .ref = "Box.make@static", .kind = .arrow },
        .{ .ref = "Box.constructor", .kind = .constructor },
        .{ .ref = "Box.size@get", .kind = .getter },
        .{ .ref = "Box.size@set", .kind = .setter },
    },
    .source =
    \\function target(a: number): number {
    \\  return a + 1;
    \\}
    \\function neighbour(): number {
    \\  return target(1);
    \\}
    \\export function api(): number {
    \\  return 2;
    \\}
    \\
    ,
    .target_ref = "target",
    .neighbour_ref = "neighbour",
    .exported_ref = "api",
    .valid_body = "{\n  return a + 2;\n}",
    .placeholder_body = "{\n  // TODO\n}",
    .escaping_body = "{ return 1; } function evil() {}",
    .broken_body = "{ return (a; }",
    .optional_call_source =
    \\function target(a: number): number {
    \\  return a;
    \\}
    \\target?.(1);
    \\
    ,
};
