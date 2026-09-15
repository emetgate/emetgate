const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const cas = @import("../engine/cas.zig");
const skeleton = @import("../engine/skeleton.zig");
const wire = @import("wire.zig");
const telemetry = @import("telemetry.zig");
const policy_mod = @import("policy.zig");
const read_tools = @import("read_tools.zig");
const tool_result = @import("tool_result.zig");
const runner = @import("../platform/runner.zig");
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
    if (std.mem.eql(u8, name, "emetgate_symbols")) return callSymbols(gpa, io, runtime, args, event);
    if (std.mem.eql(u8, name, "emetgate_skeleton")) return callSkeleton(gpa, io, runtime, args, event);
    if (std.mem.eql(u8, name, "emetgate_read_symbol")) return callReadSymbol(gpa, io, runtime, args, event);
    if (std.mem.eql(u8, name, "emetgate_mutate")) return callMutate(gpa, io, runtime, args, event);
    if (std.mem.eql(u8, name, "emetgate_try")) return callTry(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_try_batch")) return callTryBatch(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_read_file")) return read_tools.callReadFile(gpa, io, args, event);
    if (std.mem.eql(u8, name, "emetgate_list")) return read_tools.callList(gpa, io, args, event);
    if (std.mem.eql(u8, name, "emetgate_search")) return read_tools.callSearch(gpa, io, args, event);
    return error.UnknownTool;
}

fn callSymbols(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event) !ToolResult {
    const file = try requireString(args, "file");
    event.label = "symbols";
    event.file = file;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderSymbols(gpa, io, runtime, file, &buffer.writer) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn loadJailed(gpa: Allocator, io: std.Io, runtime: *Runtime, file: []const u8) !*Snapshot {
    const file_abs = try std.Io.Dir.cwd().realPathFileAlloc(io, file, gpa);
    defer gpa.free(file_abs);
    try runner.assertUnderCwdRepo(gpa, io, file_abs);
    return Snapshot.load(runtime, io, .cwd(), file_abs);
}

fn renderSymbols(gpa: Allocator, io: std.Io, runtime: *Runtime, file: []const u8, w: *Writer) !void {
    const snapshot = try loadJailed(gpa, io, runtime, file);
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    try wire.writeSymbols(gpa, w, file, table.*);
}

fn callSkeleton(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event) !ToolResult {
    const file = try requireString(args, "file");
    event.label = "skeleton";
    event.file = file;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderSkeleton(gpa, io, runtime, file, &buffer.writer, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn renderSkeleton(gpa: Allocator, io: std.Io, runtime: *Runtime, file: []const u8, w: *Writer, event: *telemetry.Event) !void {
    const snapshot = try loadJailed(gpa, io, runtime, file);
    defer snapshot.destroy();
    const text = try skeleton.skeletonize(gpa, runtime.parser, snapshot.tree);
    defer gpa.free(text);
    event.chars_emetgate = text.len;
    event.chars_fullfile = snapshot.source.len;
    try wire.writeSkeleton(w, file, text);
}

fn callReadSymbol(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event) !ToolResult {
    const file = try requireString(args, "file");
    const sym = try requireString(args, "symbol");
    event.label = "read_symbol";
    event.file = file;
    event.symbol = sym;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderSymbolBody(gpa, io, runtime, file, sym, &buffer.writer, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn renderSymbolBody(gpa: Allocator, io: std.Io, runtime: *Runtime, file: []const u8, sym: []const u8, w: *Writer, event: *telemetry.Event) !void {
    const snapshot = try loadJailed(gpa, io, runtime, file);
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

fn callMutate(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event) !ToolResult {
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
    renderMutate(gpa, io, runtime, file, sym, hash_hex, body, &buffer.writer, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn renderMutate(gpa: Allocator, io: std.Io, runtime: *Runtime, file: []const u8, sym: []const u8, hash_hex: []const u8, body: []const u8, w: *Writer, event: *telemetry.Event) !void {
    const ref = try symbol.Ref.parse(gpa, sym);
    defer ref.deinit(gpa);
    const expected = try symbol.parseHash(hash_hex);
    const base = try loadJailed(gpa, io, runtime, file);
    defer base.destroy();
    if (base.tree.root().hasError()) return error.SourceHasErrors;
    const target = try (try base.symbols()).resolve(ref);
    const old_body_len = target.body.endByte() - target.body.startByte();
    const applied = try cas.apply(base, .{ .ref = ref, .expected_hash = expected, .new_body = body });
    defer applied.snapshot.destroy();
    event.hash = applied.hash;
    event.chars_emetgate = sym.len + hash_hex.len + body.len;
    event.chars_fullfile = applied.snapshot.source.len;
    event.chars_sr = old_body_len + body.len;
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
        try wire.writeError(&buffer.writer, @errorName(err), wire.exitCode(err));
        break :blk true;
    };
    return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = is_error };
}

fn tryInto(gpa: Allocator, io: std.Io, runtime: *Runtime, file: []const u8, sym: []const u8, hash_hex: []const u8, body: []const u8, args: ?Value, policy: Policy, w: *Writer, event: *telemetry.Event) !bool {
    const given = try trustedTestCommand(args, policy);
    const file_abs = try std.Io.Dir.cwd().realPathFileAlloc(io, file, gpa);
    defer gpa.free(file_abs);
    const test_command = try runner.resolveTestCommand(gpa, io, file_abs, given, policy.allow_repo_config);
    defer gpa.free(test_command);
    const typecheck_command = try runner.resolveTypecheckCommand(gpa, io, file_abs, trustedTypecheckCommand(policy), policy.allow_repo_config);
    defer if (typecheck_command) |command| gpa.free(command);
    const expected = try symbol.parseHash(hash_hex);
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
    var built: usize = 0;
    defer {
        var i = built;
        while (i > 0) {
            i -= 1;
            const owned: [:0]const u8 = edits[i].file_abs.ptr[0..edits[i].file_abs.len :0];
            gpa.free(owned);
        }
    }
    for (items, 0..) |item, i| {
        const file_abs = try std.Io.Dir.cwd().realPathFileAlloc(io, getString(item, "file").?, gpa);
        edits[i].file_abs = file_abs;
        built = i + 1;
        edits[i].ref_text = getString(item, "symbol").?;
        edits[i].new_body = getString(item, "body").?;
        edits[i].expected_hash = try symbol.parseHash(getString(item, "hash").?);
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
