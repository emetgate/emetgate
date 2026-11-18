const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const b64 = std.base64.standard;

pub const mechanism = "SCRAM-SHA-256";
pub const min_iterations = 1;
pub const max_iterations = 10_000_000;
pub const key_len = Sha256.digest_length;

pub const Error = error{ ScramBadServerMessage, ScramNonceMismatch, ScramBadIterations, ScramServerUnverified, ScramBufferTooSmall };

pub const Keys = struct {
    client_key: [key_len]u8,
    stored_key: [key_len]u8,
    server_key: [key_len]u8,

    pub fn derive(password: []const u8, salt: []const u8, iterations: u32) Keys {
        var salted: [key_len]u8 = undefined;
        std.crypto.pwhash.pbkdf2(&salted, password, salt, iterations, Hmac) catch unreachable;
        defer std.crypto.secureZero(u8, &salted);
        var keys: Keys = undefined;
        Hmac.create(&keys.client_key, "Client Key", &salted);
        Sha256.hash(&keys.client_key, &keys.stored_key, .{});
        Hmac.create(&keys.server_key, "Server Key", &salted);
        return keys;
    }

    pub fn wipe(self: *Keys) void {
        std.crypto.secureZero(u8, &self.client_key);
        std.crypto.secureZero(u8, &self.server_key);
    }
};

fn authMessage(buf: []u8, first_bare: []const u8, server_first: []const u8, final_bare: []const u8) Error![]const u8 {
    return std.fmt.bufPrint(buf, "{s},{s},{s}", .{ first_bare, server_first, final_bare }) catch error.ScramBufferTooSmall;
}

pub fn proofFor(keys: Keys, message: []const u8) [key_len]u8 {
    var signature: [key_len]u8 = undefined;
    Hmac.create(&signature, message, &keys.stored_key);
    var proof: [key_len]u8 = undefined;
    for (&proof, keys.client_key, signature) |*p, k, s| p.* = k ^ s;
    return proof;
}

pub fn serverSignature(keys: Keys, message: []const u8) [key_len]u8 {
    var signature: [key_len]u8 = undefined;
    Hmac.create(&signature, message, &keys.server_key);
    return signature;
}

fn attribute(message: []const u8, name: u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, message, ',');
    while (parts.next()) |part| {
        if (part.len >= 2 and part[0] == name and part[1] == '=') return part[2..];
    }
    return null;
}

pub const Client = struct {
    nonce_buf: [64]u8 = undefined,
    nonce_len: usize = 0,
    first_buf: [256]u8 = undefined,
    first_len: usize = 0,
    auth_buf: [1024]u8 = undefined,
    auth_len: usize = 0,
    keys: ?Keys = null,

    pub fn init(raw_nonce: []const u8) Client {
        var self: Client = .{};
        const encoded = b64.Encoder.encode(&self.nonce_buf, raw_nonce[0..@min(raw_nonce.len, 45)]);
        for (self.nonce_buf[0..encoded.len]) |*c| {
            if (c.* == ',') c.* = '-';
        }
        self.nonce_len = encoded.len;
        return self;
    }

    pub fn initNonce(nonce_text: []const u8) Client {
        var self: Client = .{};
        @memcpy(self.nonce_buf[0..nonce_text.len], nonce_text);
        self.nonce_len = nonce_text.len;
        return self;
    }

    fn nonce(self: *const Client) []const u8 {
        return self.nonce_buf[0..self.nonce_len];
    }

    fn firstBare(self: *const Client) []const u8 {
        return self.first_buf[3..self.first_len];
    }

    pub fn first(self: *Client, user: []const u8) Error![]const u8 {
        const text = std.fmt.bufPrint(&self.first_buf, "n,,n={s},r={s}", .{ user, self.nonce() }) catch return error.ScramBufferTooSmall;
        self.first_len = text.len;
        return text;
    }

    pub fn final(self: *Client, password: []const u8, server_first: []const u8, out: []u8) Error![]const u8 {
        const server_nonce = attribute(server_first, 'r') orelse return error.ScramBadServerMessage;
        const salt_text = attribute(server_first, 's') orelse return error.ScramBadServerMessage;
        const iter_text = attribute(server_first, 'i') orelse return error.ScramBadServerMessage;
        if (server_first.len > 512) return error.ScramBadServerMessage;
        if (!std.mem.startsWith(u8, server_nonce, self.nonce()) or server_nonce.len == self.nonce().len) return error.ScramNonceMismatch;
        const iterations = std.fmt.parseUnsigned(u32, iter_text, 10) catch return error.ScramBadIterations;
        if (iterations < min_iterations or iterations > max_iterations) return error.ScramBadIterations;
        var salt_buf: [256]u8 = undefined;
        const salt_len = b64.Decoder.calcSizeForSlice(salt_text) catch return error.ScramBadServerMessage;
        if (salt_len > salt_buf.len) return error.ScramBadServerMessage;
        b64.Decoder.decode(salt_buf[0..salt_len], salt_text) catch return error.ScramBadServerMessage;
        var keys = Keys.derive(password, salt_buf[0..salt_len], iterations);
        var bare_buf: [512]u8 = undefined;
        const bare = std.fmt.bufPrint(&bare_buf, "c=biws,r={s}", .{server_nonce}) catch return error.ScramBufferTooSmall;
        const message = try authMessage(&self.auth_buf, self.firstBare(), server_first, bare);
        self.auth_len = message.len;
        var proof = proofFor(keys, message);
        defer std.crypto.secureZero(u8, &proof);
        std.crypto.secureZero(u8, &keys.client_key);
        self.keys = keys;
        var proof_text: [64]u8 = undefined;
        const encoded = b64.Encoder.encode(&proof_text, &proof);
        return std.fmt.bufPrint(out, "{s},p={s}", .{ bare, encoded }) catch error.ScramBufferTooSmall;
    }

    pub fn verify(self: *Client, server_final: []const u8) Error!void {
        const keys = self.keys orelse return error.ScramServerUnverified;
        defer if (self.keys) |*k| k.wipe();
        if (attribute(server_final, 'e') != null) return error.ScramServerUnverified;
        const text = attribute(server_final, 'v') orelse return error.ScramBadServerMessage;
        var got: [key_len]u8 = undefined;
        const n = b64.Decoder.calcSizeForSlice(text) catch return error.ScramBadServerMessage;
        if (n != key_len) return error.ScramServerUnverified;
        b64.Decoder.decode(&got, text) catch return error.ScramBadServerMessage;
        const want = serverSignature(keys, self.auth_buf[0..self.auth_len]);
        if (!std.crypto.timing_safe.eql([key_len]u8, got, want)) return error.ScramServerUnverified;
    }
};

const testing = std.testing;

test "pg scram: the RFC 7677 exchange produces the published proof and accepts the published server signature" {
    var client = Client.initNonce("rOprNGfwEbeRWgbNEkqO");
    try testing.expectEqualStrings("n,,n=user,r=rOprNGfwEbeRWgbNEkqO", try client.first("user"));
    var out: [512]u8 = undefined;
    const server_first = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
    const final = try client.final("pencil", server_first, &out);
    try testing.expectEqualStrings("c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=", final);
    try client.verify("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=");
}

test "pg scram: a forged server signature, a foreign nonce and absurd iteration counts are refused" {
    var out: [512]u8 = undefined;
    var forged = Client.initNonce("rOprNGfwEbeRWgbNEkqO");
    _ = try forged.first("user");
    _ = try forged.final("pencil", "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096", &out);
    try testing.expectError(error.ScramServerUnverified, forged.verify("v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="));
    var foreign = Client.initNonce("abc");
    _ = try foreign.first("");
    try testing.expectError(error.ScramNonceMismatch, foreign.final("x", "r=xyz123,s=QUJD,i=4096", &out));
    try testing.expectError(error.ScramNonceMismatch, foreign.final("x", "r=abc,s=QUJD,i=4096", &out));
    try testing.expectError(error.ScramBadIterations, foreign.final("x", "r=abcd,s=QUJD,i=0", &out));
    try testing.expectError(error.ScramBadIterations, foreign.final("x", "r=abcd,s=QUJD,i=99999999999", &out));
    try testing.expectError(error.ScramBadServerMessage, foreign.final("x", "r=abcd,i=4096", &out));
    var unverified = Client.initNonce("abc");
    try testing.expectError(error.ScramServerUnverified, unverified.verify("v=x"));
}
