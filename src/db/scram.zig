const std = @import("std");

const Allocator = std.mem.Allocator;
const b64 = std.base64.standard;

pub const Mechanism = enum {
    sha1,
    sha256,

    pub fn name(self: Mechanism) []const u8 {
        return switch (self) {
            .sha1 => "SCRAM-SHA-1",
            .sha256 => "SCRAM-SHA-256",
        };
    }

    pub fn parse(text: []const u8) ?Mechanism {
        if (std.mem.eql(u8, text, "SCRAM-SHA-1")) return .sha1;
        if (std.mem.eql(u8, text, "SCRAM-SHA-256")) return .sha256;
        return null;
    }
};

pub const min_iterations = 4096;
pub const max_iterations = 10_000_000;
pub const max_digest = 32;

pub const Error = error{ ScramProtocol, ScramServerSignature, OutOfMemory };

const Sha1 = std.crypto.hash.Sha1;
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub fn digestLen(m: Mechanism) usize {
    return switch (m) {
        .sha1 => Sha1.digest_length,
        .sha256 => Sha256.digest_length,
    };
}

pub fn hmac(m: Mechanism, out: []u8, key: []const u8, msg: []const u8) void {
    switch (m) {
        .sha1 => HmacSha1.create(out[0..HmacSha1.mac_length], msg, key),
        .sha256 => HmacSha256.create(out[0..HmacSha256.mac_length], msg, key),
    }
}

pub fn hash(m: Mechanism, out: []u8, msg: []const u8) void {
    switch (m) {
        .sha1 => Sha1.hash(msg, out[0..Sha1.digest_length], .{}),
        .sha256 => Sha256.hash(msg, out[0..Sha256.digest_length], .{}),
    }
}

pub fn saltedPassword(m: Mechanism, out: []u8, password: []const u8, salt: []const u8, rounds: u32) Error!void {
    const n = digestLen(m);
    switch (m) {
        .sha1 => std.crypto.pwhash.pbkdf2(out[0..n], password, salt, rounds, HmacSha1) catch return error.ScramProtocol,
        .sha256 => std.crypto.pwhash.pbkdf2(out[0..n], password, salt, rounds, HmacSha256) catch return error.ScramProtocol,
    }
}

pub fn mongoPassword(arena: Allocator, m: Mechanism, user: []const u8, password: []const u8) ![]const u8 {
    if (m == .sha256) return password;
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(user);
    md5.update(":mongo:");
    md5.update(password);
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    return std.fmt.allocPrint(arena, "{x}", .{&digest});
}

pub fn escapeUser(arena: Allocator, user: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (user) |ch| switch (ch) {
        '=' => try out.appendSlice(arena, "=3D"),
        ',' => try out.appendSlice(arena, "=2C"),
        else => try out.append(arena, ch),
    };
    return out.items;
}

pub const Client = struct {
    mechanism: Mechanism,
    password: []const u8,
    nonce: []const u8,
    first_bare: []const u8 = "",
    server_signature: [max_digest]u8 = undefined,

    pub fn init(arena: Allocator, mechanism: Mechanism, user: []const u8, password: []const u8, nonce: []const u8) !Client {
        const escaped = try escapeUser(arena, user);
        return .{
            .mechanism = mechanism,
            .password = try mongoPassword(arena, mechanism, user, password),
            .nonce = nonce,
            .first_bare = try std.fmt.allocPrint(arena, "n={s},r={s}", .{ escaped, nonce }),
        };
    }

    pub fn first(self: *const Client, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "n,,{s}", .{self.first_bare});
    }

    pub fn final(self: *Client, arena: Allocator, server_first: []const u8) Error![]const u8 {
        var nonce: ?[]const u8 = null;
        var salt_text: ?[]const u8 = null;
        var rounds: ?u32 = null;
        var it = std.mem.splitScalar(u8, server_first, ',');
        while (it.next()) |part| {
            if (part.len < 2 or part[1] != '=') return error.ScramProtocol;
            switch (part[0]) {
                'r' => nonce = part[2..],
                's' => salt_text = part[2..],
                'i' => rounds = std.fmt.parseUnsigned(u32, part[2..], 10) catch return error.ScramProtocol,
                'm' => return error.ScramProtocol,
                else => {},
            }
        }
        const server_nonce = nonce orelse return error.ScramProtocol;
        if (server_nonce.len <= self.nonce.len or !std.mem.startsWith(u8, server_nonce, self.nonce)) return error.ScramProtocol;
        const n = rounds orelse return error.ScramProtocol;
        if (n < min_iterations or n > max_iterations) return error.ScramProtocol;
        const salt_b64 = salt_text orelse return error.ScramProtocol;
        const salt_len = b64.Decoder.calcSizeForSlice(salt_b64) catch return error.ScramProtocol;
        const salt = try arena.alloc(u8, salt_len);
        b64.Decoder.decode(salt, salt_b64) catch return error.ScramProtocol;
        const len = digestLen(self.mechanism);
        var salted: [max_digest]u8 = undefined;
        try saltedPassword(self.mechanism, &salted, self.password, salt, n);
        defer std.crypto.secureZero(u8, &salted);
        var client_key: [max_digest]u8 = undefined;
        hmac(self.mechanism, &client_key, salted[0..len], "Client Key");
        var stored_key: [max_digest]u8 = undefined;
        hash(self.mechanism, &stored_key, client_key[0..len]);
        const without_proof = try std.fmt.allocPrint(arena, "c=biws,r={s}", .{server_nonce});
        const auth_message = try std.fmt.allocPrint(arena, "{s},{s},{s}", .{ self.first_bare, server_first, without_proof });
        var signature: [max_digest]u8 = undefined;
        hmac(self.mechanism, &signature, stored_key[0..len], auth_message);
        var proof: [max_digest]u8 = undefined;
        for (proof[0..len], client_key[0..len], signature[0..len]) |*p, k, s| p.* = k ^ s;
        var server_key: [max_digest]u8 = undefined;
        hmac(self.mechanism, &server_key, salted[0..len], "Server Key");
        hmac(self.mechanism, &self.server_signature, server_key[0..len], auth_message);
        const proof_b64 = try arena.alloc(u8, b64.Encoder.calcSize(len));
        _ = b64.Encoder.encode(proof_b64, proof[0..len]);
        return std.fmt.allocPrint(arena, "{s},p={s}", .{ without_proof, proof_b64 });
    }

    pub fn verify(self: *const Client, server_final: []const u8) Error!void {
        if (std.mem.startsWith(u8, server_final, "e=")) return error.ScramProtocol;
        if (!std.mem.startsWith(u8, server_final, "v=")) return error.ScramProtocol;
        const end = std.mem.indexOfScalar(u8, server_final, ',') orelse server_final.len;
        const text = server_final[2..end];
        var got: [max_digest]u8 = undefined;
        const len = digestLen(self.mechanism);
        const n = b64.Decoder.calcSizeForSlice(text) catch return error.ScramServerSignature;
        if (n != len) return error.ScramServerSignature;
        b64.Decoder.decode(got[0..len], text) catch return error.ScramServerSignature;
        var diff: u8 = 0;
        for (got[0..len], self.server_signature[0..len]) |a, b| diff |= a ^ b;
        if (diff != 0) return error.ScramServerSignature;
    }
};

const testing = std.testing;

test "db scram: SCRAM-SHA-256 matches the RFC 7677 exchange" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var client: Client = .{ .mechanism = .sha256, .password = "pencil", .nonce = "rOprNGfwEbeRWgbNEkqO", .first_bare = "n=user,r=rOprNGfwEbeRWgbNEkqO" };
    try testing.expectEqualStrings("n,,n=user,r=rOprNGfwEbeRWgbNEkqO", try client.first(a));
    const final = try client.final(a, "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096");
    try testing.expectEqualStrings("c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=", final);
    try client.verify("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=");
    try testing.expectError(error.ScramServerSignature, client.verify("v=AAAATRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="));
}

test "db scram: SCRAM-SHA-1 matches the RFC 5802 exchange and MongoDB digests the password first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var client: Client = .{ .mechanism = .sha1, .password = "pencil", .nonce = "fyko+d2lbbFgONRv9qkxdawL", .first_bare = "n=user,r=fyko+d2lbbFgONRv9qkxdawL" };
    const final = try client.final(a, "r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096");
    try testing.expectEqualStrings("c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,p=v0X8v3Bz2T0CJGbJQyF0X+HI4Ts=", final);
    try client.verify("v=rmF9pqV8S7suAoZWja4dJRkFsKQ=");
    try testing.expectEqualStrings("1c33006ec1ffd90f9cadcbcc0e118200", try mongoPassword(a, .sha1, "user", "pencil"));
}

test "db scram: a server nonce that does not extend ours, too few rounds or an error reply is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var client = try Client.init(a, .sha256, "a=b,c", "pw", "abc");
    try testing.expectEqualStrings("n=a=3Db=2Cc,r=abc", client.first_bare);
    try testing.expectError(error.ScramProtocol, client.final(a, "r=xyz123,s=QSXCR+Q6sek8bf92,i=4096"));
    try testing.expectError(error.ScramProtocol, client.final(a, "r=abc,s=QSXCR+Q6sek8bf92,i=4096"));
    try testing.expectError(error.ScramProtocol, client.final(a, "r=abcd,s=QSXCR+Q6sek8bf92,i=1"));
    try testing.expectError(error.ScramProtocol, client.verify("e=invalid-proof"));
}
