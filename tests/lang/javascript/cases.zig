const Cases = @import("../cases.zig").Cases;

pub const cases: Cases = .{
    .member_source =
    \\class Box {
    \\  static make = () => 1;
    \\  constructor() {}
    \\  get size() { return 1; }
    \\  set size(v) {}
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
    .literal_source =
    \\async function open(page, timeoutMs) {
    \\  const navTimeout = budget(timeoutMs);
    \\  await page.goto(u, { timeout: 30000 });
    \\  await page.goto(u, { timeout: "30s" });
    \\  await page.goto(u, { timeout: budget(timeoutMs) });
    \\  await page.goto(u, { timeout: budget(timeoutMs, { reserveMs: R }) });
    \\  await page.goto(u, { timeout: navTimeout, delay: 5 });
    \\  await page.goto(u, { timeout: Math.max(2, Math.round(x)) });
    \\  await page.goto(u, { timeout });
    \\  await page.goto(u, { a: { timeout: 5 } });
    \\  await page.goto(u, { "timeout": 1000, [timeout]: 2 });
    \\  await page.goto(u, { timeout: -1 });
    \\}
    \\
    ,
    .literal_flagged = &.{ "timeout: 30000", "timeout: \"30s\"", "timeout: 5", "\"timeout\": 1000", "timeout: -1" },
};
