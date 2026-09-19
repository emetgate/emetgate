const std = @import("std");
const checks = @import("../engine/checks.zig");
const symbol = @import("../engine/symbol.zig");
const lang = @import("../engine/lang/registry.zig");
const Snapshot = @import("../engine/loader.zig").Snapshot;
const Runtime = @import("../engine/runtime.zig").Runtime;
const rules = @import("rules.zig");
const shadow = @import("shadow.zig");
const where_mod = @import("where.zig");

const Allocator = std.mem.Allocator;

pub const Source = union(enum) {
    ledger,
    check: Adhoc,
};

pub const Adhoc = struct {
    spec: []const u8,
    where: ?[]const u8 = null,
};

pub const Unresolved = struct {
    rule: rules.Rule,
    reason: anyerror,
};

pub const Unreadable = struct {
    file: []u8,
    reason: Snapshot.LoadError,
};

pub const Malformed = struct {
    rule: rules.Rule,
    reason: checks.Error,
};

pub const Result = struct {
    rules: usize,
    scanned: usize,
    unsupported: usize,
    out_of_scope: usize,
    unreadable: []Unreadable,
    parse_errors: [][]u8,
    violations: []rules.Violation,

    pub fn nothingInScope(self: Result) bool {
        return self.rules != 0 and self.scanned == 0;
    }

    pub fn deinit(self: Result, gpa: Allocator) void {
        for (self.unreadable) |u| gpa.free(u.file);
        gpa.free(self.unreadable);
        for (self.parse_errors) |file| gpa.free(file);
        gpa.free(self.parse_errors);
        (rules.Report{ .violations = self.violations }).deinit(gpa);
    }
};

pub const torn_retry_ms = 50;

pub const Pause = struct {
    context: ?*anyopaque = null,
    call: *const fn (context: ?*anyopaque, io: std.Io) void = sleepBriefly,

    fn sleepBriefly(_: ?*anyopaque, io: std.Io) void {
        io.sleep(.fromMilliseconds(torn_retry_ms), .awake) catch {};
    }
};

pub fn load(gpa: Allocator, io: std.Io, root_abs: []const u8, source: Source, pause: Pause) !rules.Enforced {
    return switch (source) {
        .ledger => rules.peek(gpa, io, root_abs) catch |err| {
            if (@as(anyerror, err) != error.LedgerNeedsRepair) return err;
            pause.call(pause.context, io);
            return rules.peek(gpa, io, root_abs);
        },
        .check => |adhoc| {
            return .{ .gpa = gpa, .recall = null, .rules = try gpa.dupe(rules.Rule, &.{.{ .id = adhoc.spec, .check = adhoc.spec, .where = adhoc.where }}) };
        },
    };
}

fn covers(scopes: []const ?where_mod.Where, file: []const u8) bool {
    if (scopes.len == 0) return true;
    for (scopes) |scope| {
        const w = scope orelse return true;
        if (w.coversFile(file)) return true;
    }
    return false;
}

pub fn firstMalformed(list: []const rules.Rule) ?Malformed {
    for (list) |rule| {
        checks.validate(rule.check) catch |err| return .{ .rule = rule, .reason = err };
    }
    return null;
}

pub fn firstUnresolved(gpa: Allocator, io: std.Io, runtime: *Runtime, root_abs: []const u8, list: []const rules.Rule) !?Unresolved {
    const files = try shadow.trackedFiles(gpa, io, root_abs);
    defer gpa.free(files);
    defer shadow.freeFileList(gpa, files);
    var root = try std.Io.Dir.openDirAbsolute(io, root_abs, .{});
    defer root.close(io);
    return firstUnresolvedIn(gpa, io, runtime, root, files, list);
}

fn firstUnresolvedIn(gpa: Allocator, io: std.Io, runtime: *Runtime, root: std.Io.Dir, files: []const []u8, list: []const rules.Rule) !?Unresolved {
    for (list) |rule| {
        const text = rule.where orelse continue;
        const scope = try where_mod.parse(text);
        resolveScope(gpa, io, runtime, root, files, scope) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return .{ .rule = rule, .reason = err },
        };
    }
    return null;
}

fn resolveScope(gpa: Allocator, io: std.Io, runtime: *Runtime, root: std.Io.Dir, files: []const []u8, scope: where_mod.Where) !void {
    const file = for (files) |file| {
        if (scope.base.coversFile(file)) break file;
    } else return switch (scope.base) {
        .dir => error.NoTrackedFileUnder,
        else => error.FileNotTracked,
    };
    const ref_text = switch (scope.base) {
        .symbol => |s| s.ref,
        else => return,
    };
    const snapshot = try Snapshot.load(runtime, io, root, file);
    defer snapshot.destroy();
    _ = try symbolSpan(gpa, snapshot, ref_text);
}

pub fn scan(gpa: Allocator, io: std.Io, runtime: *Runtime, root_abs: []const u8, list: []const rules.Rule) !Result {
    if (firstMalformed(list)) |bad| return bad.reason;
    const scopes = try gpa.alloc(?where_mod.Where, list.len);
    defer gpa.free(scopes);
    for (list, scopes) |rule, *scope| {
        scope.* = if (rule.where) |text| try where_mod.parse(text) else null;
    }

    const files = try shadow.trackedFiles(gpa, io, root_abs);
    defer gpa.free(files);
    defer shadow.freeFileList(gpa, files);
    var root = try std.Io.Dir.openDirAbsolute(io, root_abs, .{});
    defer root.close(io);
    if (try firstUnresolvedIn(gpa, io, runtime, root, files, list) != null) return error.ScopeUnresolved;

    var unreadable: std.ArrayList(Unreadable) = .empty;
    defer unreadable.deinit(gpa);
    errdefer for (unreadable.items) |u| gpa.free(u.file);
    var parse_errors: std.ArrayList([]u8) = .empty;
    defer parse_errors.deinit(gpa);
    errdefer for (parse_errors.items) |file| gpa.free(file);
    var violations: std.ArrayList(rules.Violation) = .empty;
    defer violations.deinit(gpa);
    errdefer (rules.Report{ .violations = violations.items }).deinitItems(gpa);

    var scanned: usize = 0;
    var unsupported: usize = 0;
    var out_of_scope: usize = 0;
    for (files) |file| {
        if (!covers(scopes, file)) {
            out_of_scope += 1;
            continue;
        }
        if (lang.forPath(file) == null) {
            unsupported += 1;
            continue;
        }
        const snapshot = Snapshot.load(runtime, io, root, file) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try unreadable.ensureUnusedCapacity(gpa, 1);
                unreadable.appendAssumeCapacity(.{ .file = try gpa.dupe(u8, file), .reason = err });
                continue;
            },
        };
        defer snapshot.destroy();
        scanned += 1;
        if (snapshot.tree.root().hasError()) {
            try parse_errors.ensureUnusedCapacity(gpa, 1);
            parse_errors.appendAssumeCapacity(try gpa.dupe(u8, file));
        }

        const whole: symbol.Span = .{ .start = 0, .end = @intCast(snapshot.source.len) };
        for (list, scopes) |*rule, scope| {
            var span = whole;
            if (scope) |w| {
                if (!w.coversFile(file)) continue;
                switch (w.base) {
                    .symbol => |s| span = try symbolSpan(gpa, snapshot, s.ref),
                    else => {},
                }
            }
            const report = try rules.evaluate(gpa, file, snapshot.profile, snapshot.tree, span, rule[0..1]) orelse continue;
            defer gpa.free(report.violations);
            violations.ensureUnusedCapacity(gpa, report.violations.len) catch |err| {
                report.deinitItems(gpa);
                return err;
            };
            violations.appendSliceAssumeCapacity(report.violations);
        }
    }

    const owned_unreadable = try unreadable.toOwnedSlice(gpa);
    errdefer {
        for (owned_unreadable) |u| gpa.free(u.file);
        gpa.free(owned_unreadable);
    }
    const owned_parse_errors = try parse_errors.toOwnedSlice(gpa);
    errdefer {
        for (owned_parse_errors) |f| gpa.free(f);
        gpa.free(owned_parse_errors);
    }
    return .{
        .rules = list.len,
        .scanned = scanned,
        .unsupported = unsupported,
        .out_of_scope = out_of_scope,
        .unreadable = owned_unreadable,
        .parse_errors = owned_parse_errors,
        .violations = try violations.toOwnedSlice(gpa),
    };
}

fn symbolSpan(gpa: Allocator, snapshot: *Snapshot, ref_text: []const u8) !symbol.Span {
    const ref = try symbol.Ref.parse(gpa, ref_text);
    defer ref.deinit(gpa);
    const table = try snapshot.symbols();
    const target = try table.resolve(ref);
    return .{ .start = target.body.startByte(), .end = target.body.endByte() };
}
