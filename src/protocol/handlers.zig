const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const cas = @import("../engine/cas.zig");
const skeleton = @import("../engine/skeleton.zig");
const wire = @import("wire.zig");
const telemetry = @import("telemetry.zig");
const policy_mod = @import("policy.zig");
const read_tools = @import("read_tools.zig");
const scan_command = @import("scan_command.zig");
const tool_result = @import("tool_result.zig");
const runner = @import("../platform/runner.zig");
const repo = @import("../platform/repo.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const Snapshot = @import("../engine/loader.zig").Snapshot;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const Policy = policy_mod.Policy;
const trustedTestCommand = policy_mod.trustedTestCommand;
const trustedTypecheckCommand = policy_mod.trustedTypecheckCommand;
const ToolResult = tool_result.ToolResult;
const requireString = tool_result.requireString;
const getField = tool_result.getField;
const getString = tool_result.getString;
const success = tool_result.success;
const failure = tool_result.failure;
const dupTrim = tool_result.dupTrim;

pub fn callTool(gpa: Allocator, io: std.Io, runtime: *Runtime, name: []const u8, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    if (std.mem.eql(u8, name, "emetgate_symbols")) return callSymbols(gpa, io, runtime, args, event, policy.root);
    if (std.mem.eql(u8, name, "emetgate_skeleton")) return callSkeleton(gpa, io, runtime, args, event, policy.root);
    if (std.mem.eql(u8, name, "emetgate_read_symbol")) return callReadSymbol(gpa, io, runtime, args, event, policy.root);
    if (std.mem.eql(u8, name, "emetgate_mutate")) return callMutate(gpa, io, runtime, args, event, policy.root);
    if (std.mem.eql(u8, name, "emetgate_try")) return callTry(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_try_batch")) return callTryBatch(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_read_file")) return read_tools.callReadFile(gpa, io, args, event, policy.root);
    if (std.mem.eql(u8, name, "emetgate_list")) return read_tools.callList(gpa, io, args, event, policy.root);
    if (std.mem.eql(u8, name, "emetgate_search")) return read_tools.callSearch(gpa, io, args, event, policy.root);
    if (std.mem.eql(u8, name, "emetgate_scan")) return callScan(gpa, io, runtime, args, event, policy.root);
    return error.UnknownTool;
}

pub const max_scan_violations = 100;

fn callScan(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, root: ?[]const u8) !ToolResult {
    const check = try requireString(args, "check");
    const where: ?[]const u8 = if (getField(args.?, "where")) |field| switch (field) {
        .string => |text| text,
        else => return error.MissingArgument,
    } else null;
    event.label = "scan";
    event.file = where;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    var refusal: ?[]const u8 = null;
    renderScan(gpa, io, runtime, root, check, where, &buffer.writer, &refusal) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    if (refusal) |name| {
        event.fail(name);
        return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = true };
    }
    return success(gpa, &buffer);
}

fn renderScan(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, check: []const u8, where: ?[]const u8, w: *Writer, refusal: *?[]const u8) !void {
    const root_abs = try repo.servedRoot(gpa, io, root);
    defer gpa.free(root_abs);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = try scan_command.run(gpa, io, runtime, root_abs, .{
        .source = .{ .check = .{ .spec = check, .where = where } },
        .json = true,
        .max_violations = max_scan_violations,
        .refusal = refusal,
    }, w, &discard.writer);
}

fn callSymbols(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, root: ?[]const u8) !ToolResult {
    const file = try requireString(args, "file");
    event.label = "symbols";
    event.file = file;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderSymbols(gpa, io, runtime, root, file, &buffer.writer) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn loadJailed(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, file: []const u8) !*Snapshot {
    const place = try repo.jail(gpa, io, root, file);
    defer place.deinit(gpa);
    return Snapshot.load(runtime, io, .cwd(), place.abs);
}

fn renderSymbols(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, file: []const u8, w: *Writer) !void {
    const snapshot = try loadJailed(gpa, io, runtime, root, file);
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    try wire.writeSymbols(gpa, w, file, table.*);
}

fn callSkeleton(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, root: ?[]const u8) !ToolResult {
    const file = try requireString(args, "file");
    event.label = "skeleton";
    event.file = file;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderSkeleton(gpa, io, runtime, root, file, &buffer.writer, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn renderSkeleton(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, file: []const u8, w: *Writer, event: *telemetry.Event) !void {
    const snapshot = try loadJailed(gpa, io, runtime, root, file);
    defer snapshot.destroy();
    const text = try skeleton.skeletonize(gpa, runtime.parser, snapshot.profile, snapshot.tree);
    defer gpa.free(text);
    event.chars_emetgate = text.len;
    event.chars_fullfile = snapshot.source.len;
    try wire.writeSkeleton(w, file, text);
}

fn callReadSymbol(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, root: ?[]const u8) !ToolResult {
    const file = try requireString(args, "file");
    const sym = try requireString(args, "symbol");
    event.label = "read_symbol";
    event.file = file;
    event.symbol = sym;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderSymbolBody(gpa, io, runtime, root, file, sym, &buffer.writer, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn renderSymbolBody(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, file: []const u8, sym: []const u8, w: *Writer, event: *telemetry.Event) !void {
    const snapshot = try loadJailed(gpa, io, runtime, root, file);
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    const ref = try symbol.Ref.parse(gpa, sym);
    defer ref.deinit(gpa);
    const found = try table.resolve(ref);
    const body = snapshot.tree.text(found.body);
    event.hash = found.hash;
    event.chars_emetgate = body.len;
    event.chars_fullfile = snapshot.source.len;
    try wire.writeSymbolBody(w, file, sym, found.hash, body);
}

fn callMutate(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, root: ?[]const u8) !ToolResult {
    const file = try requireString(args, "file");
    const sym = try requireString(args, "symbol");
    const hash_hex = try requireString(args, "hash");
    const body = try requireString(args, "body");
    event.label = "dry-run";
    event.file = file;
    event.symbol = sym;
    event.mutating = true;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderMutate(gpa, io, runtime, root, file, sym, hash_hex, body, &buffer.writer, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn renderMutate(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, file: []const u8, sym: []const u8, hash_hex: []const u8, body: []const u8, w: *Writer, event: *telemetry.Event) !void {
    const ref = try symbol.Ref.parse(gpa, sym);
    defer ref.deinit(gpa);
    const expected = try symbol.parseExpected(hash_hex);
    const place = try repo.jailTarget(gpa, io, root, file, expected == .absent);
    defer place.deinit(gpa);
    if (place.creates) {
        const created = try runner.prepareCreate(gpa, io, runtime, place.root, place.abs, place.rel, ref, body);
        defer created.snapshot.destroy();
        event.hash = created.hash;
        event.chars_emetgate = sym.len + hash_hex.len + body.len;
        event.chars_fullfile = created.snapshot.source.len;
        try wire.writeMutated(w, sym, expected, created.hash, created.snapshot.source);
        return;
    }
    const base = try Snapshot.load(runtime, io, .cwd(), place.abs);
    defer base.destroy();
    if (base.tree.root().hasError()) return error.SourceHasErrors;
    if (expected == .present) {
        const target = try (try base.symbols()).resolve(ref);
        event.chars_sr = target.body.endByte() - target.body.startByte() + body.len;
    }
    const applied = try cas.propose(base, ref, expected, body);
    defer applied.snapshot.destroy();
    event.hash = applied.hash;
    event.chars_emetgate = sym.len + hash_hex.len + body.len;
    event.chars_fullfile = applied.snapshot.source.len;
    try wire.writeMutated(w, sym, expected, applied.hash, applied.snapshot.source);
}

fn callTry(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    const file = try requireString(args, "file");
    const sym = try requireString(args, "symbol");
    const hash_hex = try requireString(args, "hash");
    const body = try requireString(args, "body");
    event.file = file;
    event.symbol = sym;
    event.mutating = true;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const is_error = tryInto(gpa, io, runtime, file, sym, hash_hex, body, args, policy, &buffer.writer, event) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        event.fail(@errorName(err));
        buffer.clearRetainingCapacity();
        if (err == error.WrittenButNotIndexed) {
            try wire.writeNotIndexed(&buffer.writer, file);
        } else {
            try wire.writeError(&buffer.writer, @errorName(err), wire.exitCode(err));
        }
        break :blk true;
    };
    return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = is_error };
}

fn tryInto(gpa: Allocator, io: std.Io, runtime: *Runtime, file: []const u8, sym: []const u8, hash_hex: []const u8, body: []const u8, args: ?Value, policy: Policy, w: *Writer, event: *telemetry.Event) !bool {
    const given = try trustedTestCommand(args, policy);
    const expected = try symbol.parseExpected(hash_hex);
    const place = try repo.jailTarget(gpa, io, policy.root, file, expected == .absent);
    defer place.deinit(gpa);
    const file_abs = place.abs;
    const test_command = try runner.resolveTestCommand(gpa, io, file_abs, given, policy.allow_repo_config);
    defer gpa.free(test_command);
    const typecheck_command = try runner.resolveTypecheckCommand(gpa, io, file_abs, trustedTypecheckCommand(policy), policy.allow_repo_config);
    defer if (typecheck_command) |command| gpa.free(command);
    const result = try runner.tryMutate(gpa, io, runtime, .{
        .file_abs = file_abs,
        .ref_text = sym,
        .expected_hash = expected,
        .new_body = body,
        .test_command = test_command,
        .typecheck_command = typecheck_command,
        .trace = &event.trace,
    });
    defer result.deinit(gpa);
    event.chars_emetgate = sym.len + hash_hex.len + body.len;
    event.chars_fullfile = event.trace.new_len;
    event.chars_sr = if (event.trace.old_body_len) |old| old + body.len else null;
    switch (result) {
        .committed => |new_hash| {
            event.outcome = .committed;
            event.edits = 1;
            event.hash = new_hash;
            try wire.writeCommitted(w, sym, expected, new_hash);
            return false;
        },
        .rejected => |report| {
            event.outcome = .rejected;
            event.reason = wire.rejectionReason(report);
            try wire.writeRejected(gpa, w, test_command, report);
            return true;
        },
        .typecheck_failed => |report| {
            event.outcome = .rejected;
            event.reason = wire.typecheckReason(report);
            try wire.writeTypecheckRejected(gpa, w, typecheck_command.?, report);
            return true;
        },
        .rule_violation => |report| {
            event.outcome = .rejected;
            event.reason = "rule_violation";
            try wire.writeRuleViolation(w, report);
            return true;
        },
    }
}

fn callTryBatch(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    const arguments = args orelse return error.MissingArgument;
    const edits_val = getField(arguments, "edits") orelse return error.MissingArgument;
    if (edits_val != .array or edits_val.array.items.len == 0) return error.MissingArgument;
    for (edits_val.array.items) |item| {
        _ = getString(item, "file") orelse return error.MissingArgument;
        _ = getString(item, "symbol") orelse return error.MissingArgument;
        _ = getString(item, "hash") orelse return error.MissingArgument;
        _ = getString(item, "body") orelse return error.MissingArgument;
    }
    event.mutating = true;

    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const is_error = batchInto(gpa, io, runtime, edits_val.array.items, arguments, policy, &buffer.writer, event) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        event.fail(@errorName(err));
        buffer.clearRetainingCapacity();
        try wire.writeError(&buffer.writer, @errorName(err), wire.exitCode(err));
        break :blk true;
    };
    return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = is_error };
}

fn batchInto(gpa: Allocator, io: std.Io, runtime: *Runtime, items: []const Value, args: Value, policy: Policy, w: *Writer, event: *telemetry.Event) !bool {
    const given = try trustedTestCommand(args, policy);
    const edits = try gpa.alloc(runner.Edit, items.len);
    defer gpa.free(edits);
    const places = try gpa.alloc(repo.Jailed, items.len);
    defer gpa.free(places);
    var built: usize = 0;
    defer for (places[0..built]) |place| place.deinit(gpa);
    for (items, 0..) |item, i| {
        places[i] = try repo.jail(gpa, io, policy.root, getString(item, "file").?);
        built = i + 1;
        edits[i] = .{
            .file_abs = places[i].abs,
            .ref_text = getString(item, "symbol").?,
            .new_body = getString(item, "body").?,
            .expected_hash = switch (try symbol.parseExpected(getString(item, "hash").?)) {
                .present => |hash| hash,
                .absent => return error.AbsentInBatch,
            },
        };
    }

    const resolved = try runner.resolveTestCommand(gpa, io, edits[0].file_abs, given, policy.allow_repo_config);
    defer gpa.free(resolved);
    const typecheck_command = try runner.resolveTypecheckCommand(gpa, io, edits[0].file_abs, trustedTypecheckCommand(policy), policy.allow_repo_config);
    defer if (typecheck_command) |command| gpa.free(command);
    const result = try runner.tryMutateBatch(gpa, io, runtime, .{ .edits = edits, .test_command = resolved, .typecheck_command = typecheck_command, .trace = &event.trace });
    defer result.deinit(gpa);

    var sent: usize = 0;
    for (items) |item| sent += getString(item, "symbol").?.len + getString(item, "hash").?.len + getString(item, "body").?.len;
    event.chars_emetgate = sent;
    event.chars_fullfile = event.trace.new_len;
    switch (result) {
        .committed => |hashes| {
            event.outcome = .committed;
            event.edits = items.len;
            const views = try gpa.alloc(wire.BatchEdit, items.len);
            defer gpa.free(views);
            for (items, 0..) |item, i| views[i] = .{
                .file = getString(item, "file").?,
                .symbol = getString(item, "symbol").?,
                .old_hash = edits[i].expected_hash,
                .new_hash = hashes[i],
            };
            try wire.writeBatchCommitted(w, views);
            return false;
        },
        .rejected => |report| {
            event.outcome = .rejected;
            event.reason = wire.rejectionReason(report);
            try wire.writeRejected(gpa, w, resolved, report);
            return true;
        },
        .typecheck_failed => |report| {
            event.outcome = .rejected;
            event.reason = wire.typecheckReason(report);
            try wire.writeTypecheckRejected(gpa, w, typecheck_command.?, report);
            return true;
        },
        .rule_violation => |report| {
            event.outcome = .rejected;
            event.reason = "rule_violation";
            try wire.writeRuleViolation(w, report);
            return true;
        },
    }
}
