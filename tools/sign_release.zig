const std = @import("std");

const Ed25519 = std.crypto.sign.Ed25519;
const base64 = std.base64.standard;

pub const seed_variable = "EMETGATE_SIGNING_KEY";

const usage =
    \\usage: emetgate-sign keygen
    \\       emetgate-sign sign <emetgate.exe> <emetgate.exe.sig> <release_key.pub>
    \\       emetgate-sign verify <emetgate.exe> <emetgate.exe.sig> <release_key.pub>
    \\
    \\keygen prints a new Ed25519 seed for the EMETGATE_SIGNING_KEY secret and its
    \\public key for src/update/release_key.pub.
    \\sign reads the seed from EMETGATE_SIGNING_KEY, refuses when its public key is not
    \\the one in release_key.pub, and writes the base64 signature of the exe bytes.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 2 and std.mem.eql(u8, args[1], "keygen")) return keygen(init.io);
    if (args.len == 5 and std.mem.eql(u8, args[1], "sign")) return sign(init, args[2], args[3], args[4]);
    if (args.len == 5 and std.mem.eql(u8, args[1], "verify")) return verify(init, args[2], args[3], args[4]);
    std.debug.print("{s}", .{usage});
    return 2;
}

fn keygen(io: std.Io) u8 {
    const pair = Ed25519.KeyPair.generate(io);
    var seed_text: [44]u8 = undefined;
    var public_text: [44]u8 = undefined;
    const seed = pair.secret_key.seed();
    std.debug.print("EMETGATE_SIGNING_KEY secret: {s}\nsrc/update/release_key.pub:  {s}\n", .{
        base64.Encoder.encode(&seed_text, &seed),
        base64.Encoder.encode(&public_text, &pair.public_key.toBytes()),
    });
    return 0;
}

fn decodeExact(dest: []u8, text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (try base64.Decoder.calcSizeForSlice(trimmed) != dest.len) return error.WrongLength;
    try base64.Decoder.decode(dest, trimmed);
}

fn readPublicKey(init: std.process.Init, path: []const u8) !?Ed25519.PublicKey {
    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.arena.allocator(), .limited(4096));
    var bytes: [32]u8 = undefined;
    decodeExact(&bytes, text) catch {
        std.debug.print("{s} holds no base64 public key; run emetgate-sign keygen and paste the public key there\n", .{path});
        return null;
    };
    const key = try Ed25519.PublicKey.fromBytes(bytes);
    return key;
}

fn sign(init: std.process.Init, exe_path: []const u8, sig_path: []const u8, key_path: []const u8) !u8 {
    const seed_text = init.environ_map.get(seed_variable) orelse {
        std.debug.print("{s} is not set\n", .{seed_variable});
        return 1;
    };
    var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
    decodeExact(&seed, seed_text) catch {
        std.debug.print("{s} is not the base64 of a 32-byte seed\n", .{seed_variable});
        return 1;
    };
    const pair = try Ed25519.KeyPair.generateDeterministic(seed);
    std.crypto.secureZero(u8, &seed);
    const public_key = try readPublicKey(init, key_path) orelse return 1;
    if (!std.mem.eql(u8, &public_key.toBytes(), &pair.public_key.toBytes())) {
        std.debug.print("{s} does not belong to the public key in {s}\n", .{ seed_variable, key_path });
        return 1;
    }
    const exe = try std.Io.Dir.cwd().readFileAlloc(init.io, exe_path, init.arena.allocator(), .limited(64 << 20));
    const signature = try pair.sign(exe, null);
    try signature.verify(exe, public_key);
    var text: [88]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = sig_path, .data = base64.Encoder.encode(&text, &signature.toBytes()) });
    return 0;
}

fn verify(init: std.process.Init, exe_path: []const u8, sig_path: []const u8, key_path: []const u8) !u8 {
    const public_key = try readPublicKey(init, key_path) orelse return 1;
    const exe = try std.Io.Dir.cwd().readFileAlloc(init.io, exe_path, init.arena.allocator(), .limited(64 << 20));
    const sig_text = try std.Io.Dir.cwd().readFileAlloc(init.io, sig_path, init.arena.allocator(), .limited(1024));
    var bytes: [Ed25519.Signature.encoded_length]u8 = undefined;
    decodeExact(&bytes, sig_text) catch {
        std.debug.print("{s} is not a base64 signature\n", .{sig_path});
        return 1;
    };
    Ed25519.Signature.fromBytes(bytes).verify(exe, public_key) catch {
        std.debug.print("{s} does not verify {s} with {s}\n", .{ sig_path, exe_path, key_path });
        return 1;
    };
    std.debug.print("{s} verifies {s}\n", .{ sig_path, exe_path });
    return 0;
}
