const std = @import("std");
const facts_store = @import("facts_store.zig");
const facts_query = @import("facts_query.zig");
const facts_evidence = @import("facts_evidence.zig");
const answer = @import("answer.zig");
const shared = @import("evidence_request.zig");

const Allocator = std.mem.Allocator;

pub const Intent = shared.Intent;
pub const SymbolRef = shared.SymbolRef;
pub const EvidenceRequest = shared.EvidenceRequest;

pub const default_budget: usize = 9_500;
pub const min_budget: usize = 1_000;

pub const FactStore = struct {
    arena: Allocator,
    store: *const facts_store.Store,
    source: facts_evidence.Source,
    snapshot: answer.Snapshot,
    max_file_bytes: u64,
    largest_file_bytes: u64,
};

pub const Elided = struct {
    path: []const u8,
    first: u32,
    last: u32,
};

pub const EvidenceBlock = struct {
    text: []const u8 = "",
    intent: Intent,
    targets: []const facts_query.Subject = &.{},
    not_found: []const SymbolRef = &.{},
    sites: []const facts_query.Site = &.{},
    unresolved: []const facts_query.Unknown = &.{},
    elided: []const Elided = &.{},
    cut: usize = 0,
};

pub const EvidenceAnswer = answer.Answer(EvidenceBlock);

pub fn evidence(store: *const FactStore, request: EvidenceRequest, budget: usize) EvidenceAnswer {
    _ = store;
    _ = request;
    _ = budget;
    return EvidenceAnswer.refuse(error.NotImplemented, "the evidence compiler is not built yet");
}
