const std = @import("std");

pub const public_key_size = 32;
pub const private_key_size = 32;
pub const shared_secret_size = 32;

pub const EcdhError = error{
    KeyExchangeFailed,
};

pub const KeyPair = struct {
    public_key: [public_key_size]u8,
    private_key: [private_key_size]u8,

    pub fn generate(random: std.Random) EcdhError!KeyPair {
        var private_key: [private_key_size]u8 = undefined;
        random.bytes(&private_key);

        const public_key = std.crypto.dh.X25519.recoverPublicKey(private_key) catch {
            return error.KeyExchangeFailed;
        };

        return .{
            .public_key = public_key,
            .private_key = private_key,
        };
    }

    pub fn from_private_key(private_key: [private_key_size]u8) EcdhError!KeyPair {
        const public_key = std.crypto.dh.X25519.recoverPublicKey(private_key) catch {
            return error.KeyExchangeFailed;
        };

        return .{
            .public_key = public_key,
            .private_key = private_key,
        };
    }

    pub fn fromPrivateKey(private_key: [private_key_size]u8) EcdhError!KeyPair {
        return from_private_key(private_key);
    }
};

pub fn exchange(
    private_key: *const [private_key_size]u8,
    peer_public_key: *const [public_key_size]u8,
) EcdhError![shared_secret_size]u8 {
    return std.crypto.dh.X25519.scalarmult(private_key.*, peer_public_key.*) catch {
        return error.KeyExchangeFailed;
    };
}

test "x25519 key exchange" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    const alice = try KeyPair.generate(random);
    const bob = try KeyPair.generate(random);

    const alice_shared = try exchange(&alice.private_key, &bob.public_key);
    const bob_shared = try exchange(&bob.private_key, &alice.public_key);

    try std.testing.expectEqualSlices(u8, &alice_shared, &bob_shared);
}

test "x25519 from_private_key derives deterministic public key" {
    const private_key = [_]u8{0x42} ** private_key_size;

    const a = try KeyPair.from_private_key(private_key);
    const b = try KeyPair.from_private_key(private_key);

    try std.testing.expectEqualSlices(u8, &a.public_key, &b.public_key);
    try std.testing.expectEqualSlices(u8, &private_key, &a.private_key);
}

test "x25519 exchange is deterministic for fixed inputs" {
    const alice_priv = [_]u8{0x11} ** private_key_size;
    const bob_priv = [_]u8{0x22} ** private_key_size;

    const alice = try KeyPair.from_private_key(alice_priv);
    const bob = try KeyPair.from_private_key(bob_priv);

    const shared_1 = try exchange(&alice.private_key, &bob.public_key);
    const shared_2 = try exchange(&alice.private_key, &bob.public_key);

    try std.testing.expectEqualSlices(u8, &shared_1, &shared_2);
}
