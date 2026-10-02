const profile_mod = @import("../profile.zig");

const MapTable = profile_mod.MapTable;
const MapDecorator = profile_mod.MapDecorator;
const MapCallForm = profile_mod.MapCallForm;

const decorators = [_]MapDecorator{
    .{ .name = "Get", .kind = .route, .tag = "GET" },
    .{ .name = "Post", .kind = .route, .tag = "POST" },
    .{ .name = "Put", .kind = .route, .tag = "PUT" },
    .{ .name = "Patch", .kind = .route, .tag = "PATCH" },
    .{ .name = "Delete", .kind = .route, .tag = "DELETE" },
    .{ .name = "Head", .kind = .route, .tag = "HEAD" },
    .{ .name = "Options", .kind = .route, .tag = "OPTIONS" },
    .{ .name = "All", .kind = .route, .tag = "ALL" },
    .{ .name = "Controller", .kind = .route, .tag = "controller" },
    .{ .name = "JsonController", .kind = .route, .tag = "controller" },
    .{ .name = "Resolver", .kind = .route, .tag = "resolver" },
    .{ .name = "Query", .kind = .route, .tag = "query" },
    .{ .name = "Mutation", .kind = .route, .tag = "mutation" },
    .{ .name = "Command", .kind = .command, .tag = "cmd" },
    .{ .name = "SubCommand", .kind = .command, .tag = "cmd" },
    .{ .name = "EventPattern", .kind = .event, .tag = "on" },
    .{ .name = "MessagePattern", .kind = .event, .tag = "on" },
    .{ .name = "SubscribeMessage", .kind = .event, .tag = "on" },
    .{ .name = "EventSubscriber", .kind = .event, .tag = "on" },
    .{ .name = "HostListener", .kind = .event, .tag = "on" },
    .{ .name = "Cron", .kind = .event, .tag = "cron" },
    .{ .name = "Interval", .kind = .event, .tag = "cron" },
    .{ .name = "Timeout", .kind = .event, .tag = "cron" },
    .{ .name = "On", .kind = .event, .tag = "on", .prefix = true },
};

const call_forms = [_]MapCallForm{
    .{
        .modules = &.{ "express", "koa-router", "@koa/router", "fastify", "hono", "restify", "polka", "router" },
        .methods = &.{ "get", "post", "put", "patch", "delete", "del", "all", "head", "options", "route" },
        .kind = .route,
        .tag = "routes",
    },
    .{
        .modules = &.{ "commander", "yargs", "cac", "sade", "@oclif/core", "clipanion" },
        .methods = &.{"command"},
        .kind = .command,
        .tag = "cmd",
    },
};

pub const table: MapTable = .{
    .test_segments = &.{ "__tests__", "__mocks__", "__fixtures__", "test", "tests", "e2e", "fixtures", "mocks", "testing" },
    .test_infixes = &.{ ".test.", ".spec.", ".e2e.", "-spec." },
    .decorators = &decorators,
    .call_forms = &call_forms,
    .doc_open = "/*",
    .doc_close = "*/",
    .line_comment = "//",
    .body_open = '{',
    .arrow = "=>",
    .statement_end = ';',
    .open_brackets = "([<",
    .close_brackets = ")]>",
};
