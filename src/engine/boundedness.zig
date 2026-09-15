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

    const class: MutationClass = if (isBodyOnly(sym.*, mutation_span)) .body_only_no_op else .signature_change;

    if (isExported(sym.*)) return unbounded(class, .exported_escape);
    if (hasReexportOf(snapshot, ref.name)) return unbounded(class, .reexport_ambiguous);
    if (hasDynamicConstruct(snapshot)) return unbounded(class, .dynamic_construct);
    if (hasStringKey(snapshot, ref.name)) return unbounded(class, .string_key_escape);

    return enumerateReferences(gpa, snapshot, sym.*, ref.name, class);
}

fn isBodyOnly(sym: symbol.Symbol, mutation_span: symbol.Span) bool {
    return mutation_span.start >= sym.body.startByte() and mutation_span.end <= sym.body.endByte();
}

fn enumerateReferences(gpa: Allocator, snapshot: *Snapshot, sym: symbol.Symbol, name: []const u8, class: MutationClass) !FrameReport {
    var refs: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (refs.items) |r| gpa.free(r);
        refs.deinit(gpa);
    }

    var walker = traversal.Walker.init(snapshot.tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        if (!isNameCarrier(node.kind())) continue;
        if (!std.mem.eql(u8, snapshot.tree.text(node), name)) continue;
        if (isWithin(node, sym.declaration)) continue;

        if (classifyReference(node)) |escape| {
            for (refs.items) |r| gpa.free(r);
            refs.deinit(gpa);
            return unbounded(class, escape);
        }
        try refs.append(gpa, try gpa.dupe(u8, snapshot.tree.text(callSite(node))));
    }

    return .{
        .mutation_class = class,
        .confidence = .bounded,
        .provenance = null,
        .same_file_refs = try refs.toOwnedSlice(gpa),
        .gpa = gpa,
    };
}

fn isNameCarrier(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "identifier") or
        std.mem.eql(u8, kind, "property_identifier") or
        std.mem.eql(u8, kind, "shorthand_property_identifier") or
        std.mem.eql(u8, kind, "shorthand_property_identifier_pattern");
}

fn classifyReference(node: ts.Node) ?Provenance {
    if (!std.mem.eql(u8, node.kind(), "identifier")) return .unrecognized_reference;
    const parent = node.parent() orelse return .unrecognized_reference;
    if (std.mem.eql(u8, parent.kind(), "call_expression") and isPlainCall(parent, node)) return null;
    if (std.mem.eql(u8, parent.kind(), "arguments")) return .first_class_escape;
    return .unrecognized_reference;
}

fn isPlainCall(call: ts.Node, callee_node: ts.Node) bool {
    const callee = call.childByField("function") orelse return false;
    if (!callee.eql(callee_node)) return false;
    const args = call.childByField("arguments") orelse return false;
    if (!std.mem.eql(u8, args.kind(), "arguments")) return false;
    var i: u32 = 0;
    while (call.child(i)) |c| : (i += 1) {
        if (!c.isNamed() and std.mem.eql(u8, c.kind(), "?.")) return false;
    }
    return true;
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

test "adversarial: a dynamic import anywhere in the file forces UNBOUNDED" {
    try expectUnbounded(decl ++ "const loaded = import(\"./module\");", "process", .dynamic_construct);
}

test "adversarial: a Function constructor anywhere in the file forces UNBOUNDED" {
    try expectUnbounded(decl ++ "const run = new Function(\"return 1\");", "process", .dynamic_construct);
}

test "adversarial: a star re-export in the file is UNBOUNDED" {
    try expectUnbounded(decl ++ "export * from \"./other\";", "process", .reexport_ambiguous);
}

test "precision: a helper declared inside an exported function body is not itself exported" {
    var case = try Case.init(
        \\export function outer(): number {
        \\  function inner(): number { return 1; }
        \\  return inner();
        \\}
    );
    defer case.deinit();
    const span = try case.signatureSpan("outer.inner");
    const report = try case.run("outer.inner", span);
    defer report.deinit();
    try testing.expectEqual(Confidence.bounded, report.confidence);
    try testing.expectEqual(@as(usize, 1), report.same_file_refs.len);
}

test "whitelist proof: a reference shape outside the escape blacklist still UNBOUNDED" {
    // returning the symbol as a value is neither eval/string-key nor a call argument,
    // yet positive enumeration must still refuse it as an unrecognized reference.
    try expectUnbounded(
        \\function process(x: number): number { return x; }
        \\function wrap(): unknown { return process; }
    , "process", .unrecognized_reference);
}

fn expectUnboundedAny(src: []const u8, ref_text: []const u8) !void {
    var case = try Case.init(src);
    defer case.deinit();
    const span = try case.signatureSpan(ref_text);
    const report = try case.run(ref_text, span);
    defer report.deinit();
    errdefer std.debug.print("got confidence={t} provenance={?}\n", .{ report.confidence, report.provenance });
    try testing.expectEqual(Confidence.unbounded, report.confidence);
    try testing.expect(report.provenance != null);
}

const decl = "function process(x: number): number { return x; }\n";

test "corpus: computed subscript reference is UNBOUNDED" {
    try expectUnbounded(decl ++ "const c = obj[process]();", "process", .unrecognized_reference);
}
test "corpus: namespace/member property reference is UNBOUNDED" {
    try expectUnbounded(decl ++ "NS.process();", "process", .unrecognized_reference);
}
test "corpus: this-method property reference is UNBOUNDED" {
    try expectUnbounded(decl ++ "class C { m(): void { this.process(); } }", "process", .unrecognized_reference);
}
test "corpus: tagged template reference is UNBOUNDED" {
    try expectUnbounded(decl ++ "const t = process`x`;", "process", .unrecognized_reference);
}
test "corpus: spread reference is UNBOUNDED" {
    try expectUnbounded(decl ++ "const a = [...process];", "process", .unrecognized_reference);
}
test "corpus: destructure-pattern reference is UNBOUNDED" {
    try expectUnbounded(decl ++ "const { process } = obj;", "process", .unrecognized_reference);
}
test "corpus: object shorthand reference is UNBOUNDED" {
    try expectUnbounded(decl ++ "const o = { process };", "process", .unrecognized_reference);
}
test "corpus: alias assignment reference is UNBOUNDED" {
    try expectUnbounded(decl ++ "const alias = process;", "process", .unrecognized_reference);
}
test "corpus: typeof type-query reference is UNBOUNDED" {
    try expectUnbounded(decl ++ "type T = typeof process;", "process", .unrecognized_reference);
}
test "corpus: decorator reference is UNBOUNDED" {
    try expectUnboundedAny(decl ++ "@process class C {}", "process");
}
test "corpus: optional call reference is UNBOUNDED" {
    try expectUnboundedAny(decl ++ "process?.();", "process");
}
test "corpus: renamed export specifier is UNBOUNDED" {
    try expectUnbounded(decl ++ "export { process as other };", "process", .reexport_ambiguous);
}
test "corpus: commonjs exports assignment is UNBOUNDED" {
    try expectUnbounded(decl ++ "exports.foo = process;", "process", .unrecognized_reference);
}
test "corpus: assign-to-exported-object is UNBOUNDED" {
    try expectUnbounded(decl ++ "const obj = {}; obj.foo = process; export { obj };", "process", .unrecognized_reference);
}
test "corpus: export default declaration is UNBOUNDED" {
    try expectUnbounded("export default function process(x: number): number { return x; }", "process", .exported_escape);
}
test "corpus: shadowing local passed as callback is UNBOUNDED (over-count is safe)" {
    try expectUnboundedAny(decl ++ "function outer(): void { const process = 1; [process].map((process) => process); }", "process");
}

test "completeness: a reference in a nested scope is still counted" {
    var case = try Case.init(decl ++ "function outer(): number { return process(1); }\nprocess(2);");
    defer case.deinit();
    const span = try case.signatureSpan("process");
    const report = try case.run("process", span);
    defer report.deinit();
    try testing.expectEqual(Confidence.bounded, report.confidence);
    try testing.expectEqual(@as(usize, 2), report.same_file_refs.len);
}

test "boundary: a mutation one byte into the signature flips to signature_change" {
    var case = try Case.init(decl ++ "process(1);");
    defer case.deinit();
    const table = try case.snapshot.symbols();
    const ref = try symbol.Ref.parse(testing.allocator, "process");
    defer ref.deinit(testing.allocator);
    const sym = try table.resolve(ref);
    const just_before_body: symbol.Span = .{ .start = sym.body.startByte() - 1, .end = sym.body.endByte() };

    const report = analyze(testing.allocator, case.snapshot, ref, just_before_body);
    defer report.deinit();
    try testing.expectEqual(MutationClass.signature_change, report.mutation_class);
    try testing.expectEqual(Confidence.bounded, report.confidence);
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

fn expectBodyOnlyUnbounded(src: []const u8, ref_text: []const u8, provenance: Provenance) !void {
    var case = try Case.init(src);
    defer case.deinit();
    const table = try case.snapshot.symbols();
    const ref = try symbol.Ref.parse(testing.allocator, ref_text);
    defer ref.deinit(testing.allocator);
    const sym = try table.resolve(ref);
    const body_span: symbol.Span = .{ .start = sym.body.startByte(), .end = sym.body.endByte() };

    const report = analyze(testing.allocator, case.snapshot, ref, body_span);
    defer report.deinit();
    errdefer std.debug.print("got confidence={t} provenance={?}\n", .{ report.confidence, report.provenance });
    try testing.expectEqual(MutationClass.body_only_no_op, report.mutation_class);
    try testing.expectEqual(Confidence.unbounded, report.confidence);
    try testing.expectEqual(provenance, report.provenance.?);
}

test "body-only: an exported declaration is UNBOUNDED" {
    try expectBodyOnlyUnbounded(
        \\export function process(x: number): number { return x; }
    , "process", .exported_escape);
}

test "body-only: a callback escape is UNBOUNDED" {
    try expectBodyOnlyUnbounded(decl ++ "const out = [1, 2].map(process);", "process", .first_class_escape);
}

test "body-only: a dynamic construct in the file forces UNBOUNDED" {
    try expectBodyOnlyUnbounded(decl ++ "const run = eval(\"process\");", "process", .dynamic_construct);
}

test "reachability: a realistic module-private helper with several call sites stays BOUNDED" {
    var case = try Case.init(
        \\import { log } from "./log.ts";
        \\function clamp(x: number, lo: number, hi: number): number { return Math.min(hi, Math.max(lo, x)); }
        \\function a(v: number): number { return clamp(v, 0, 10); }
        \\function b(v: number): number { log(v); return clamp(v, 0, 100); }
        \\export function api(v: number): number { return clamp(v, -1, 1); }
    );
    defer case.deinit();
    const span = try case.signatureSpan("clamp");
    const report = try case.run("clamp", span);
    defer report.deinit();
    try testing.expectEqual(MutationClass.signature_change, report.mutation_class);
    try testing.expectEqual(Confidence.bounded, report.confidence);
    try testing.expectEqual(@as(usize, 3), report.same_file_refs.len);
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
