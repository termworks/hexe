const std = @import("std");

const Ed25519 = std.crypto.sign.Ed25519;

pub const SignatureError = error{
    InvalidPrivateKey,
};

pub const KeyPair = struct {
    public_key: [32]u8,
    private_key: [64]u8,

    pub fn generate(random: std.Random) KeyPair {
        var seed: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &seed);
        random.bytes(&seed);

        const key_pair = Ed25519.KeyPair.generateDeterministic(seed) catch unreachable;
        return .{
            .public_key = key_pair.public_key.bytes,
            .private_key = key_pair.secret_key.bytes,
        };
    }
};

pub fn sign_ed25519(
    data: []const u8,
    private_key: *const [64]u8,
    signature: *[64]u8,
) SignatureError!void {
    const public_bytes = private_key[32..64];
    var public_key: [32]u8 = undefined;
    @memcpy(&public_key, public_bytes);

    const key_pair = Ed25519.KeyPair{
        .public_key = Ed25519.PublicKey{ .bytes = public_key },
        .secret_key = Ed25519.SecretKey{ .bytes = private_key.* },
    };

    const sig = key_pair.sign(data, null) catch {
        return error.InvalidPrivateKey;
    };
    @memcpy(signature, &sig.toBytes());
}

pub fn sign(data: []const u8, private_key: *const [64]u8) SignatureError![64]u8 {
    var signature: [64]u8 = undefined;
    try sign_ed25519(data, private_key, &signature);
    return signature;
}

pub fn signEd25519(
    data: []const u8,
    private_key: *const [64]u8,
    signature: *[64]u8,
) SignatureError!void {
    try sign_ed25519(data, private_key, signature);
}

pub fn verify_ed25519(
    data: []const u8,
    signature: *const [64]u8,
    public_key: *const [32]u8,
) bool {
    const sig = Ed25519.Signature.fromBytes(signature.*);
    const pub_key = Ed25519.PublicKey{ .bytes = public_key.* };
    sig.verify(data, pub_key) catch {
        return false;
    };
    return true;
}

pub fn verifyEd25519(
    data: []const u8,
    signature: *const [64]u8,
    public_key: *const [32]u8,
) bool {
    return verify_ed25519(data, signature, public_key);
}

test "ed25519 sign and verify" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    const key_pair = KeyPair.generate(random);

    const data = "test message";
    const signature = try sign(data, &key_pair.private_key);

    try std.testing.expect(verify_ed25519(data, &signature, &key_pair.public_key));
    try std.testing.expect(!verify_ed25519("wrong", &signature, &key_pair.public_key));
}
