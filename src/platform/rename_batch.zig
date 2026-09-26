const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const rename = @import("../engine/rename.zig");
const registry = @import("../engine/lang/registry.zig");
const repo = @import("repo.zig");
const shadow = @import("shadow.zig");
const tsserver = @import("tsserver.zig");
const batch = @import("batch.zig");
const batch_plan = @import("batch_plan.zig");
const sandbox = @import("sandbox.zig");
const disk = @import("disk.zig");
const runner = @import("runner.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const Snapshot = @import("../engine/loader.zig").Snapshot;

const Allocator = std.mem.Allocator;
const Span = symbol.Span;
const Prepared = batch_plan.Prepared;
const Edit = batch_plan.Edit;

pub const Request = struct {
    file_abs: []const u8,
    ref_text: []const u8,
    expected_hash: symbol.Hash,
    new_name: []const u8,
    interface_change: bool = false,
};

pub const Resolver = enum { language_service, text };

pub const Options = struct {
    request: Request,
    test_command: []const u8,
    typecheck_command: ?[]const u8 = null,
    linked: []const []const u8 = &.{"node_modules"},
    limits: sandbox.Limits = .{},
    allow_repo_memory: bool = false,
    shadow_root: ?[]const u8 = null,
    trace: ?*runner.Trace = null,
    commit_step: ?*const disk.Step = null,
    language_service: ?*tsserver.Session = null,
};

const Located = struct {
    abs: []u8,
    spans: std.ArrayList(Span) = .empty,
};

const Locations = struct {
    files: std.ArrayList(Located) = .empty,

    fn deinit(self: *Locations, gpa: Allocator) void {
        for (self.files.items) |*f| {
            gpa.free(f.abs);
            f.spans.deinit(gpa);
        }
        self.files.deinit(gpa);
    }

    fn add(self: *Locations, gpa: Allocator, abs: []u8, span: Span) !void {
        for (self.files.items) |*f| {
            if (!tsserver.sameFile(f.abs, abs)) continue;
            gpa.free(abs);
            try f.spans.append(gpa, span);
            return;
        }
        {
            errdefer gpa.free(abs);
            try self.files.append(gpa, .{ .abs = abs });
        }
        try self.files.items[self.files.items.len - 1].spans.append(gpa, span);
    }

    fn find(self: *const Locations, abs: []const u8) ?*const Located {
        for (self.files.items) |*f| {
            if (tsserver.sameFile(f.abs, abs)) return f;
        }
        return null;
    }
};

pub const Plan = struct {
    prepared: []Prepared,
    edits: []Edit,
    resolver: Resolver,
    fallback: ?anyerror,
    interface_change: bool,
    regions_checked: usize,
    symbols_checked: usize,
    new_ref: []u8,
    new_hash: symbol.Hash,

    pub fn deinit(self: Plan, gpa: Allocator) void {
        for (self.prepared) |p| p.deinit(gpa);
        for (self.edits) |e| gpa.free(e.file_abs);
        gpa.free(self.prepared);
        gpa.free(self.edits);
        gpa.free(self.new_ref);
    }
};

pub fn plan(gpa: Allocator, io: std.Io, runtime: *Runtime, root: []const u8, request: Request, session: ?*tsserver.Session) !Plan {
    const base = try Snapshot.load(runtime, io, .cwd(), request.file_abs);
    defer base.destroy();
    if (!rename.supports(base.profile)) return error.UnsupportedLanguage;
    if (base.tree.root().hasError()) return error.SourceHasErrors;
    const ref = try symbol.Ref.parse(gpa, request.ref_text);
    defer ref.deinit(gpa);
    const target = try targetOf(gpa, base, ref, request.expected_hash);
    const old = ref.name;
    if (!rename.validName(request.new_name) or std.mem.eql(u8, old, request.new_name)) return error.InvalidName;
    const offset = target.offset;
    const member = ref.container.len != 0;

    var locations: Locations = .{};
    defer locations.deinit(gpa);
    var resolver: Resolver = .text;
    var fallback: ?anyerror = error.NoLanguageService;
    if (session) |s| {
        switch (try fromService(gpa, io, root, s, request.file_abs, offset, &locations)) {
            .ok => {
                resolver = .language_service;
                fallback = null;
            },
            .unavailable => |err| {
                s.last_error = err;
                fallback = err;
            },
        }
    }
    if (resolver == .text) try fromText(gpa, io, root, base, request.file_abs, old, member, &locations);

    const own = locations.find(request.file_abs) orelse return error.IncompleteRename;
    if (!startsAt(own.spans.items, offset)) return error.IncompleteRename;
    const top_name = if (member) ref.container[0] else old;
    const interface_change = locations.files.items.len > 1 or try rename.exportedName(gpa, base, top_name);
    if (interface_change and !request.interface_change) return error.InterfaceChangeNeedsApproval;
    try refuseDynamic(gpa, io, runtime, root, &locations, old, member);

    var new_ref = ref;
    new_ref.name = request.new_name;
    const new_ref_text = try std.fmt.allocPrint(gpa, "{f}", .{new_ref});
    errdefer gpa.free(new_ref_text);

    const count = locations.files.items.len;
    const prepared = try gpa.alloc(Prepared, count);
    errdefer gpa.free(prepared);
    const edits = try gpa.alloc(Edit, count);
    errdefer gpa.free(edits);
    var built: usize = 0;
    errdefer for (prepared[0..built], edits[0..built]) |p, e| {
        p.deinit(gpa);
        gpa.free(e.file_abs);
    };
    var regions: usize = 0;
    var symbols: usize = 0;
    var new_hash: ?symbol.Hash = null;
    for (locations.files.items) |located| {
        const declaring = tsserver.sameFile(located.abs, request.file_abs);
        const file_base = try Snapshot.load(runtime, io, .cwd(), located.abs);
        defer file_base.destroy();
        const renamed = try rename.apply(gpa, file_base, old, request.new_name, located.spans.items);
        gpa.free(renamed.spans);
        errdefer renamed.snapshot.destroy();
        regions += renamed.regions_checked;
        symbols += renamed.symbols_checked;
        var body: Span = .{ .start = 0, .end = 0 };
        if (declaring) {
            const table = try renamed.snapshot.symbols();
            if (target.function) {
                const found = try table.resolve(new_ref);
                body = .{ .start = found.body.startByte(), .end = found.body.endByte() };
                new_hash = found.hash;
            } else {
                const found = declarationOf(table.*, new_ref, target.kind.?) orelse return error.IncompleteRename;
                new_hash = found.hash;
            }
        }
        const rel = try repo.relativeUnder(gpa, root, located.abs);
        errdefer gpa.free(rel);
        const abs = try gpa.dupe(u8, located.abs);
        errdefer gpa.free(abs);
        prepared[built] = .{
            .rel = rel,
            .action = .write,
            .base_hash = symbol.hashOf(file_base.source),
            .hash = symbol.hashOf(renamed.snapshot.source),
            .snapshot = renamed.snapshot,
            .body = body,
        };
        edits[built] = .{
            .file_abs = abs,
            .ref_text = if (declaring) new_ref_text else "",
            .expected_hash = .{ .present = symbol.hashOf(file_base.source) },
        };
        built += 1;
    }
    return .{
        .prepared = prepared,
        .edits = edits,
        .resolver = resolver,
        .fallback = fallback,
        .interface_change = interface_change,
        .regions_checked = regions,
        .symbols_checked = symbols,
        .new_ref = new_ref_text,
        .new_hash = new_hash orelse return error.IncompleteRename,
    };
}

const Target = struct {
    offset: u32,
    function: bool,
    kind: ?symbol.DeclarationKind = null,
};

fn targetOf(gpa: Allocator, base: *Snapshot, ref: symbol.Ref, expected: symbol.Hash) !Target {
    const table = try base.symbols();
    if (table.resolve(ref)) |found| {
        if (!std.mem.eql(u8, &found.hash, &expected)) return error.HashMismatch;
        const offset = (try batch_plan.nameOffset(gpa, base, ref.name, found.declaration)) orelse return error.SymbolNotFound;
        return .{ .offset = offset, .function = true };
    } else |err| switch (err) {
        error.SymbolNotFound => {},
        else => |e| return e,
    }
    const found = table.declarationMatching(ref, expected) orelse {
        return if (table.hasDeclaration(ref)) error.HashMismatch else error.SymbolNotFound;
    };
    return .{ .offset = found.name.startByte(), .function = false, .kind = found.kind };
}

fn declarationOf(table: symbol.Table, ref: symbol.Ref, kind: symbol.DeclarationKind) ?*const symbol.Declaration {
    for (table.declarations) |*declaration| {
        if (declaration.kind == kind and declaration.ref.eql(ref)) return declaration;
    }
    return null;
}

fn startsAt(spans: []const Span, offset: u32) bool {
    for (spans) |span| {
        if (span.start == offset) return true;
    }
    return false;
}

const ServiceAnswer = union(enum) { ok, unavailable: anyerror };

fn fromService(gpa: Allocator, io: std.Io, root: []const u8, session: *tsserver.Session, file_abs: []const u8, offset: u32, locations: *Locations) !ServiceAnswer {
    const client = session.get() catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .unavailable = err },
    };
    const file = try gpa.dupe(u8, file_abs);
    defer gpa.free(file);
    std.mem.replaceScalar(u8, file, '\\', '/');
    const answer = client.rename(file, offset) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .unavailable = err },
    };
    defer answer.deinit();
    if (!answer.value.can_rename or answer.value.locations.len == 0) return error.RenameRefused;
    for (answer.value.locations) |location| {
        if (location.prefix) return error.ShorthandReference;
        if (location.end < location.start) return error.RenameOutsideRepo;
        const abs = try jailLocation(gpa, io, root, location.file);
        try locations.add(gpa, abs, .{ .start = location.start, .end = location.end });
    }
    return .ok;
}

fn jailLocation(gpa: Allocator, io: std.Io, root: []const u8, file: []const u8) ![]u8 {
    const normalized = try gpa.dupe(u8, file);
    defer gpa.free(normalized);
    std.mem.replaceScalar(u8, normalized, '/', '\\');
    const rel = repo.relativeUnder(gpa, root, normalized) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.RenameOutsideRepo,
    };
    defer gpa.free(rel);
    repo.refuseInternal(rel) catch return error.RenameOutsideRepo;
    const profile = registry.forPath(rel) orelse return error.RenameOutsideRepo;
    if (!rename.supports(profile)) return error.RenameOutsideRepo;
    repo.refuseLinkAsWritten(gpa, io, normalized) catch return error.RenameOutsideRepo;
    const listing = repo.trackedListing(gpa, io, root, rel) catch return error.RenameOutsideRepo;
    defer gpa.free(listing);
    if (std.mem.trim(u8, listing, &.{0}).len == 0) return error.RenameOutsideRepo;
    const place = repo.jail(gpa, io, root, normalized) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.RenameOutsideRepo,
    };
    defer place.deinit(gpa);
    if (!tsserver.sameFile(place.rel, rel)) return error.RenameOutsideRepo;
    return gpa.dupe(u8, place.abs);
}

fn fromText(gpa: Allocator, io: std.Io, root: []const u8, base: *Snapshot, file_abs: []const u8, old: []const u8, member: bool, locations: *Locations) !void {
    if (member) return error.RenameUnresolved;
    if (try rename.exportedName(gpa, base, old)) return error.RenameUnresolved;
    if (try rename.binderCount(gpa, base, old) != 1) return error.RenameUnresolved;
    const leaves = try rename.leavesNamed(gpa, base, old);
    defer gpa.free(leaves);
    for (leaves) |leaf| {
        if (leaf.shorthand or !leaf.free) return error.RenameUnresolved;
    }
    const listing = try repo.filesMentioning(gpa, io, root, old);
    defer gpa.free(listing);
    var files = std.mem.tokenizeScalar(u8, listing, 0);
    while (files.next()) |rel| {
        const abs = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root, rel });
        defer gpa.free(abs);
        if (!tsserver.sameFile(abs, file_abs)) return error.RenameUnresolved;
    }
    for (leaves) |leaf| try locations.add(gpa, try gpa.dupe(u8, file_abs), leaf.span);
}

fn refuseDynamic(gpa: Allocator, io: std.Io, runtime: *Runtime, root: []const u8, locations: *const Locations, old: []const u8, member: bool) !void {
    for (locations.files.items) |located| try refuseDynamicIn(gpa, runtime, io, located.abs, old, member, false);
    const listing = try repo.filesMentioning(gpa, io, root, old);
    defer gpa.free(listing);
    var files = std.mem.tokenizeScalar(u8, listing, 0);
    while (files.next()) |rel| {
        const profile = registry.forPath(rel) orelse continue;
        if (!rename.supports(profile)) continue;
        const abs = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root, rel });
        defer gpa.free(abs);
        if (locations.find(abs) != null) continue;
        try refuseDynamicIn(gpa, runtime, io, abs, old, member, true);
    }
}

fn refuseDynamicIn(gpa: Allocator, runtime: *Runtime, io: std.Io, abs: []const u8, old: []const u8, member: bool, untouched: bool) !void {
    const snapshot = try Snapshot.load(runtime, io, .cwd(), abs);
    defer snapshot.destroy();
    if (snapshot.tree.root().hasError()) return error.SourceHasErrors;
    if (rename.dynamicAccess(snapshot, old, member) != null) return error.DynamicReference;
    if (untouched and try rename.freeOccurrence(gpa, snapshot, old, true)) return error.IncompleteRename;
}

pub const Outcome = struct {
    plan: Plan,
    result: batch.BatchResult,

    pub fn deinit(self: Outcome, gpa: Allocator) void {
        self.result.deinit(gpa);
        self.plan.deinit(gpa);
    }
};

pub fn tryRename(gpa: Allocator, io: std.Io, runtime: *Runtime, options: Options) !Outcome {
    if (options.test_command.len == 0) return error.NoTestCommand;
    const dir = std.fs.path.dirname(options.request.file_abs) orelse return error.InvalidPath;
    const root = try repo.gitToplevel(gpa, io, dir);
    defer gpa.free(root);
    const lock = try shadow.Lock.acquire(io, root);
    defer lock.release();
    const planned = try plan(gpa, io, runtime, root, options.request, options.language_service);
    errdefer planned.deinit(gpa);
    const result = try batch.commitPlanned(gpa, io, root, planned.prepared, planned.edits, .{
        .edits = planned.edits,
        .test_command = options.test_command,
        .typecheck_command = options.typecheck_command,
        .linked = options.linked,
        .limits = options.limits,
        .allow_repo_memory = options.allow_repo_memory,
        .shadow_root = options.shadow_root,
        .trace = options.trace,
        .commit_step = options.commit_step,
    });
    return .{ .plan = planned, .result = result };
}
