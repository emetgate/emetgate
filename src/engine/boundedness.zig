//! Reference-boundedness analysis (Option B, pure tree-sitter, zero dependency).
//!
//! Consumption model (this sets the soundness bar):
//! BOUNDED is a proof that the blast radius of a mutation stays entirely inside
//! one file, and it alone permits the file-local test gate; UNBOUNDED forces the
//! full-project test gate. Therefore BOUNDED is produced ONLY by positively
//! counting EVERY reference to the symbol and proving each is a safe in-file
//! direct call — a single unrecognized reference shape drops the result to
//! UNBOUNDED.
//!
//! Closed-world ordering (the core invariant): every symbol starts UNBOUNDED.
//! BOUNDED is reached only through explicit proof branches; every default/else
//! and every analysis error stays UNBOUNDED. This is a positive whitelist
//! (prove good), never a blacklist of known-bad escape patterns — an incomplete
//! blacklist would silently leak false-BOUNDED, which equals an unverified
//! breaking change reaching disk.
//!
//! Scope note: a body-only mutation keeps the signature byte-identical, so no
//! type-level cross-file breakage is possible (BOUNDED). Behavioral changes
//! (return value, throwing) are out of scope here — that is the test command's
//! job, not this pass's.

const std = @import("std");
const ts = @import("tree_sitter.zig");
const symbol = @import("symbol.zig");
const traversal = @import("traversal.zig");
const loader = @import("loader.zig");

const Allocator = std.mem.Allocator;
const Snapshot = loader.Snapshot;

pub const MutationClass = enum { body_only_no_op, signature_change };

pub const Confidence = enum { bounded, unbounded };

pub const Provenance = enum {
    exported_escape,
    reexport_ambiguous,
    dynamic_construct,
    string_key_escape,
    first_class_escape,
    unrecognized_reference,
    analysis_error,
};

pub const FrameReport = struct {
    mutation_class: MutationClass,
    confidence: Confidence,
    provenance: ?Provenance,
    same_file_refs: [][]const u8,
    gpa: ?Allocator = null,

    pub fn deinit(self: FrameReport) void {
        const gpa = self.gpa orelse return;
        for (self.same_file_refs) |r| gpa.free(r);
        gpa.free(self.same_file_refs);
    }
};

fn unbounded(class: MutationClass, provenance: Provenance) FrameReport {
    return .{ .mutation_class = class, .confidence = .unbounded, .provenance = provenance, .same_file_refs = &.{} };
}

pub fn analyze(gpa: Allocator, snapshot: *Snapshot, ref: symbol.Ref, mutation_span: symbol.Span) FrameReport {
    return analyzeInner(gpa, snapshot, ref, mutation_span) catch unbounded(.signature_change, .analysis_error);
}

fn analyzeInner(gpa: Allocator, snapshot: *Snapshot, ref: symbol.Ref, mutation_span: symbol.Span) !FrameReport {
    if (snapshot.tree.root().hasError()) return unbounded(.signature_change, .analysis_error);
    const table = try snapshot.symbols();
    const sym = try table.resolve(ref);

    if (isBodyOnly(sym.*, mutation_span)) {
        return .{ .mutation_class = .body_only_no_op, .confidence = .bounded, .provenance = null, .same_file_refs = &.{} };
    }

    if (isExported(sym.*)) return unbounded(.signature_change, .exported_escape);
    if (hasReexportOf(snapshot, ref.name)) return unbounded(.signature_change, .reexport_ambiguous);
    if (hasDynamicConstruct(snapshot)) return unbounded(.signature_change, .dynamic_construct);
    if (hasStringKey(snapshot, ref.name)) return unbounded(.signature_change, .string_key_escape);

    return enumerateReferences(gpa, snapshot, sym.*, ref.name);
}

fn isBodyOnly(sym: symbol.Symbol, mutation_span: symbol.Span) bool {
    return mutation_span.start >= sym.body.startByte() and mutation_span.end <= sym.body.endByte();
}

fn enumerateReferences(gpa: Allocator, snapshot: *Snapshot, sym: symbol.Symbol, name: []const u8) !FrameReport {
    var refs: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (refs.items) |r| gpa.free(r);
        refs.deinit(gpa);
    }

    var walker = traversal.Walker.init(snapshot.tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        if (!std.mem.eql(u8, node.kind(), "identifier")) continue;
        if (!std.mem.eql(u8, snapshot.tree.text(node), name)) continue;
        if (isWithin(node, sym.declaration)) continue;

        if (classifyReference(node)) |escape| {
            for (refs.items) |r| gpa.free(r);
            refs.deinit(gpa);
            return unbounded(.signature_change, escape);
        }
        try refs.append(gpa, try gpa.dupe(u8, snapshot.tree.text(callSite(node))));
    }

    return .{
        .mutation_class = .signature_change,
        .confidence = .bounded,
        .provenance = null,
        .same_file_refs = try refs.toOwnedSlice(gpa),
        .gpa = gpa,
    };
}

fn classifyReference(node: ts.Node) ?Provenance {
    const parent = node.parent() orelse return .unrecognized_reference;
    if (std.mem.eql(u8, parent.kind(), "call_expression")) {
        if (parent.childByField("function")) |callee| {
            if (callee.eql(node)) return null;
        }
    }
    if (std.mem.eql(u8, parent.kind(), "arguments")) return .first_class_escape;
    return .unrecognized_reference;
}

fn callSite(node: ts.Node) ts.Node {
    return node.parent() orelse node;
}

fn isWithin(node: ts.Node, span: symbol.Span) bool {
    return node.startByte() >= span.start and node.endByte() <= span.end;
}

fn isExported(sym: symbol.Symbol) bool {
    var current = sym.node.parent();
    var hops: u8 = 0;
    while (current) |p| : (hops += 1) {
        if (hops > 6) return false;
        const kind = p.kind();
        if (std.mem.eql(u8, kind, "export_statement")) return true;
        if (std.mem.eql(u8, kind, "program") or std.mem.eql(u8, kind, "statement_block")) return false;
        current = p.parent();
    }
    return false;
}

fn hasReexportOf(snapshot: *Snapshot, name: []const u8) bool {
    var walker = traversal.Walker.init(snapshot.tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        const kind = node.kind();
        if (std.mem.eql(u8, kind, "export_specifier")) {
            if (node.childByField("name")) |n| {
                if (std.mem.eql(u8, snapshot.tree.text(n), name)) return true;
            }
        } else if (std.mem.eql(u8, kind, "namespace_export") or (std.mem.eql(u8, kind, "export_statement") and hasStarClause(node))) {
            return true;
        }
    }
    return false;
}

fn hasStarClause(node: ts.Node) bool {
    var i: u32 = 0;
    while (node.child(i)) |c| : (i += 1) {
        if (!c.isNamed() and std.mem.eql(u8, c.kind(), "*")) return true;
    }
    return false;
}

fn hasDynamicConstruct(snapshot: *Snapshot) bool {
    var walker = traversal.Walker.init(snapshot.tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        const kind = node.kind();
        if (std.mem.eql(u8, kind, "call_expression")) {
            if (node.childByField("function")) |callee| {
                const text = snapshot.tree.text(callee);
                if (std.mem.eql(u8, text, "eval") or std.mem.eql(u8, text, "import")) return true;
            }
        } else if (std.mem.eql(u8, kind, "new_expression")) {
            if (node.childByField("constructor")) |ctor| {
                if (std.mem.eql(u8, snapshot.tree.text(ctor), "Function")) return true;
            }
        }
    }
    return false;
}

fn hasStringKey(snapshot: *Snapshot, name: []const u8) bool {
    var walker = traversal.Walker.init(snapshot.tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        if (!std.mem.eql(u8, node.kind(), "string")) continue;
        const text = snapshot.tree.text(node);
        if (text.len >= 2 and std.mem.eql(u8, text[1 .. text.len - 1], name)) return true;
    }
    return false;
}

const testing = std.testing;
const Runtime = @import("runtime.zig").Runtime;

const Case = struct {
    runtime: *Runtime,
    snapshot: *Snapshot,

    fn init(src: []const u8) !Case {
        const runtime = try Runtime.create(testing.allocator);
        errdefer runtime.destroy() catch {};
        const owned = try testing.allocator.dupe(u8, src);
        const snapshot = try Snapshot.fromSource(runtime, owned);
        return .{ .runtime = runtime, .snapshot = snapshot };
    }

    fn deinit(self: *Case) void {
        self.snapshot.destroy();
        self.runtime.destroy() catch @panic("live snapshots");
    }

    fn signatureSpan(self: *Case, ref_text: []const u8) !symbol.Span {
        const table = try self.snapshot.symbols();
        const ref = try symbol.Ref.parse(testing.allocator, ref_text);
        defer ref.deinit(testing.allocator);
        const sym = try table.resolve(ref);
        return sym.declaration;
    }

    fn run(self: *Case, ref_text: []const u8, span: symbol.Span) !FrameReport {
        const ref = try symbol.Ref.parse(testing.allocator, ref_text);
        defer ref.deinit(testing.allocator);
        return analyze(testing.allocator, self.snapshot, ref, span);
    }
};

fn expectUnbounded(src: []const u8, ref_text: []const u8, provenance: Provenance) !void {
    var case = try Case.init(src);
    defer case.deinit();
    const span = try case.signatureSpan(ref_text);
    const report = try case.run(ref_text, span);
    defer report.deinit();
    errdefer std.debug.print("got confidence={t} provenance={?}\n", .{ report.confidence, report.provenance });
    try testing.expectEqual(Confidence.unbounded, report.confidence);
    try testing.expectEqual(provenance, report.provenance.?);
}

test "adversarial: a dynamic construct in the file forces UNBOUNDED" {
    try expectUnbounded(
        \\function process(x: number): number { return x; }
        \\const run = eval("process");
    , "process", .dynamic_construct);
}

test "adversarial: a re-exported symbol is UNBOUNDED" {
    try expectUnbounded(
        \\function process(x: number): number { return x; }
        \\export { process };
    , "process", .reexport_ambiguous);
}

test "adversarial: an exported declaration is UNBOUNDED" {
    try expectUnbounded(
        \\export function process(x: number): number { return x; }
    , "process", .exported_escape);
}

test "adversarial: a callback escape is UNBOUNDED (first-class)" {
    try expectUnbounded(
        \\function process(x: number): number { return x; }
        \\const out = [1, 2].map(process);
    , "process", .first_class_escape);
}

test "adversarial: a string-key mention is UNBOUNDED" {
    try expectUnbounded(
        \\function process(x: number): number { return x; }
        \\const key = "process";
    , "process", .string_key_escape);
}

test "whitelist proof: a reference shape outside the escape blacklist still UNBOUNDED" {
    // returning the symbol as a value is neither eval/string-key nor a call argument,
    // yet positive enumeration must still refuse it as an unrecognized reference.
    try expectUnbounded(
        \\function process(x: number): number { return x; }
        \\function wrap(): unknown { return process; }
    , "process", .unrecognized_reference);
}

test "positive control: a body-only mutation is BODY_ONLY_NO_OP and bounded" {
    var case = try Case.init(
        \\function process(x: number): number { return x; }
        \\process(1);
    );
    defer case.deinit();
    const table = try case.snapshot.symbols();
    const ref = try symbol.Ref.parse(testing.allocator, "process");
    defer ref.deinit(testing.allocator);
    const sym = try table.resolve(ref);
    const body_span: symbol.Span = .{ .start = sym.body.startByte(), .end = sym.body.endByte() };

    const report = analyze(testing.allocator, case.snapshot, ref, body_span);
    defer report.deinit();
    try testing.expectEqual(MutationClass.body_only_no_op, report.mutation_class);
    try testing.expectEqual(Confidence.bounded, report.confidence);
}

test "positive control: a module-private, escape-free, in-file-called symbol is BOUNDED" {
    var case = try Case.init(
        \\function process(x: number): number { return x; }
        \\function caller(): number { return process(1) + process(2); }
    );
    defer case.deinit();
    const span = try case.signatureSpan("process");
    const report = try case.run("process", span);
    defer report.deinit();
    try testing.expectEqual(MutationClass.signature_change, report.mutation_class);
    try testing.expectEqual(Confidence.bounded, report.confidence);
    try testing.expectEqual(@as(usize, 2), report.same_file_refs.len);
}
