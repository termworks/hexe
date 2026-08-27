const std = @import("std");
const ssh_secrets = @import("secret_derivation.zig");

pub const RekeyError = error{
    DerivationFailed,
    OutOfMemory,
};

pub const RekeyThresholdPolicy = struct {
    max_bytes: u64,
    max_seconds: u64,

    pub fn should_rekey(self: RekeyThresholdPolicy, bytes_since_last_rekey: u64, seconds_since_last_rekey: u64) bool {
        return self.should_rekey_by_bytes(bytes_since_last_rekey) or self.should_rekey_by_time(seconds_since_last_rekey);
    }

    pub fn should_rekey_by_bytes(self: RekeyThresholdPolicy, bytes_since_last_rekey: u64) bool {
        if (self.max_bytes == 0) return false;
        return bytes_since_last_rekey >= self.max_bytes;
    }

    pub fn should_rekey_by_time(self: RekeyThresholdPolicy, seconds_since_last_rekey: u64) bool {
        if (self.max_seconds == 0) return false;
        return seconds_since_last_rekey >= self.max_seconds;
    }
};

pub const RekeyContextLabel = enum {
    handshake,
    application,
    update,

    pub fn as_string(self: RekeyContextLabel) []const u8 {
        return switch (self) {
            .handshake => "handshake",
            .application => "application",
            .update => "update",
        };
    }
};

pub const RekeyTrafficSecrets = struct {
    client_to_server: [32]u8,
    server_to_client: [32]u8,

    pub fn zeroize(self: *RekeyTrafficSecrets) void {
        @memset(&self.client_to_server, 0);
        @memset(&self.server_to_client, 0);
    }
};

pub const OwnedSecretBuffer = struct {
    allocator: std.mem.Allocator,
    buf: []u8,

    pub fn init_copy(allocator: std.mem.Allocator, data: []const u8) RekeyError!OwnedSecretBuffer {
        const copied = try allocator.dupe(u8, data);
        return .{
            .allocator = allocator,
            .buf = copied,
        };
    }

    pub fn as_slice(self: *const OwnedSecretBuffer) []const u8 {
        return self.buf;
    }

    pub fn deinit(self: *OwnedSecretBuffer) void {
        @memset(self.buf, 0);
        self.allocator.free(self.buf);
        self.buf = &[_]u8{};
    }
};

pub fn derive_next_generation_traffic_secrets(
    allocator: std.mem.Allocator,
    shared_secret_k: []const u8,
    exchange_hash_h: []const u8,
    context_label: RekeyContextLabel,
    generation: u32,
) RekeyError!RekeyTrafficSecrets {
    var generation_context: [4]u8 = undefined;
    std.mem.writeInt(u32, &generation_context, generation, .big);

    const client_label = try std.fmt.allocPrint(allocator, "rekey/client/{s}", .{context_label.as_string()});
    defer allocator.free(client_label);
    const server_label = try std.fmt.allocPrint(allocator, "rekey/server/{s}", .{context_label.as_string()});
    defer allocator.free(server_label);

    const client_secret = ssh_secrets.deriveSshQuicExporterSecret(
        allocator,
        shared_secret_k,
        exchange_hash_h,
        client_label,
        &generation_context,
    ) catch {
        return error.DerivationFailed;
    };

    const server_secret = ssh_secrets.deriveSshQuicExporterSecret(
        allocator,
        shared_secret_k,
        exchange_hash_h,
        server_label,
        &generation_context,
    ) catch {
        return error.DerivationFailed;
    };

    return .{
        .client_to_server = client_secret,
        .server_to_client = server_secret,
    };
}

pub fn derive_updated_traffic_secrets(
    current: *const RekeyTrafficSecrets,
    context_label: RekeyContextLabel,
    generation: u32,
) RekeyTrafficSecrets {
    var generation_context: [4]u8 = undefined;
    std.mem.writeInt(u32, &generation_context, generation, .big);

    var client_to_server: [32]u8 = undefined;
    var server_to_client: [32]u8 = undefined;

    const client_label = switch (context_label) {
        .handshake => "rekey/update/client/handshake",
        .application => "rekey/update/client/application",
        .update => "rekey/update/client/update",
    };
    const server_label = switch (context_label) {
        .handshake => "rekey/update/server/handshake",
        .application => "rekey/update/server/application",
        .update => "rekey/update/server/update",
    };

    var client_hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(&current.client_to_server);
    client_hmac.update(client_label);
    client_hmac.update(&generation_context);
    client_hmac.final(&client_to_server);

    var server_hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(&current.server_to_client);
    server_hmac.update(server_label);
    server_hmac.update(&generation_context);
    server_hmac.final(&server_to_client);

    return .{
        .client_to_server = client_to_server,
        .server_to_client = server_to_client,
    };
}

test "rekey threshold policy checks bytes and time" {
    const policy = RekeyThresholdPolicy{ .max_bytes = 1024, .max_seconds = 60 };
    try std.testing.expect(!policy.should_rekey(512, 10));
    try std.testing.expect(policy.should_rekey(1024, 10));
    try std.testing.expect(policy.should_rekey(1, 60));
}

test "rekey threshold policy allows disabling individual thresholds" {
    const bytes_only = RekeyThresholdPolicy{ .max_bytes = 1024, .max_seconds = 0 };
    try std.testing.expect(!bytes_only.should_rekey(100, 99999));
    try std.testing.expect(bytes_only.should_rekey(1024, 0));

    const time_only = RekeyThresholdPolicy{ .max_bytes = 0, .max_seconds = 60 };
    try std.testing.expect(!time_only.should_rekey(99999, 10));
    try std.testing.expect(time_only.should_rekey(0, 60));
}

test "derive next generation traffic secrets varies by generation" {
    const allocator = std.testing.allocator;
    const shared_secret = "test_shared_secret_32_bytes_value!";
    const exchange_hash = "test_exchange_hash_value_32_bytes!";

    var g1 = try derive_next_generation_traffic_secrets(
        allocator,
        shared_secret,
        exchange_hash,
        .application,
        1,
    );
    defer g1.zeroize();

    var g2 = try derive_next_generation_traffic_secrets(
        allocator,
        shared_secret,
        exchange_hash,
        .application,
        2,
    );
    defer g2.zeroize();

    try std.testing.expect(!std.mem.eql(u8, &g1.client_to_server, &g2.client_to_server));
    try std.testing.expect(!std.mem.eql(u8, &g1.server_to_client, &g2.server_to_client));
}

test "derive updated traffic secrets is deterministic and generation scoped" {
    var current = RekeyTrafficSecrets{
        .client_to_server = [_]u8{0x1A} ** 32,
        .server_to_client = [_]u8{0x2B} ** 32,
    };
    defer current.zeroize();

    var g1a = derive_updated_traffic_secrets(&current, .application, 1);
    defer g1a.zeroize();
    var g1b = derive_updated_traffic_secrets(&current, .application, 1);
    defer g1b.zeroize();
    var g2 = derive_updated_traffic_secrets(&current, .application, 2);
    defer g2.zeroize();

    try std.testing.expectEqualSlices(u8, &g1a.client_to_server, &g1b.client_to_server);
    try std.testing.expectEqualSlices(u8, &g1a.server_to_client, &g1b.server_to_client);
    try std.testing.expect(!std.mem.eql(u8, &g1a.client_to_server, &g2.client_to_server));
    try std.testing.expect(!std.mem.eql(u8, &g1a.server_to_client, &g2.server_to_client));
}

test "derive updated traffic secrets separates contexts" {
    var current = RekeyTrafficSecrets{
        .client_to_server = [_]u8{0x9C} ** 32,
        .server_to_client = [_]u8{0x3D} ** 32,
    };
    defer current.zeroize();

    var app = derive_updated_traffic_secrets(&current, .application, 5);
    defer app.zeroize();
    var hs = derive_updated_traffic_secrets(&current, .handshake, 5);
    defer hs.zeroize();
    var upd = derive_updated_traffic_secrets(&current, .update, 5);
    defer upd.zeroize();

    try std.testing.expect(!std.mem.eql(u8, &app.client_to_server, &hs.client_to_server));
    try std.testing.expect(!std.mem.eql(u8, &app.client_to_server, &upd.client_to_server));
    try std.testing.expect(!std.mem.eql(u8, &hs.server_to_client, &upd.server_to_client));
}

test "derive updated traffic secrets does not mutate source secrets" {
    var current = RekeyTrafficSecrets{
        .client_to_server = [_]u8{0xA7} ** 32,
        .server_to_client = [_]u8{0xB8} ** 32,
    };
    defer current.zeroize();

    const before_client = current.client_to_server;
    const before_server = current.server_to_client;

    var next = derive_updated_traffic_secrets(&current, .application, 9);
    defer next.zeroize();

    try std.testing.expectEqualSlices(u8, &before_client, &current.client_to_server);
    try std.testing.expectEqualSlices(u8, &before_server, &current.server_to_client);
}

test "owned secret buffer stores independent copy" {
    const allocator = std.testing.allocator;
    var source = [_]u8{ 1, 2, 3, 4 };
    var owned = try OwnedSecretBuffer.init_copy(allocator, &source);
    defer owned.deinit();

    source[0] = 9;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, owned.as_slice());
}

test "rekey traffic secrets zeroize clears both directions" {
    var secrets = RekeyTrafficSecrets{
        .client_to_server = [_]u8{0x11} ** 32,
        .server_to_client = [_]u8{0x22} ** 32,
    };

    secrets.zeroize();

    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 32, &secrets.client_to_server);
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 32, &secrets.server_to_client);
}

test "owned secret buffer deinit resets slice" {
    const allocator = std.testing.allocator;
    var owned = try OwnedSecretBuffer.init_copy(allocator, &[_]u8{ 9, 8, 7 });
    owned.deinit();
    try std.testing.expectEqual(@as(usize, 0), owned.as_slice().len);
}
