const Cases = @import("../cases.zig").Cases;

pub const cases: Cases = .{
    .source =
    \\function target(a) {
    \\  return a + 1;
    \\}
    \\function neighbour() {
    \\  return target(1);
    \\}
    \\export function api() {
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
    \\function target(a) {
    \\  return a;
    \\}
    \\target?.(1);
    \\
    ,
};
