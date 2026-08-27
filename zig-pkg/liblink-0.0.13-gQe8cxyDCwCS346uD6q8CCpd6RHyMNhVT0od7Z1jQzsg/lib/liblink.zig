const std = @import("std");
const libfast_mod = @import("libfast");

// Import our modules
pub const protocol = struct {
    pub const wire = @import("protocol/wire.zig");
    pub const random = @import("protocol/random.zig");
    pub const obfuscation = @import("protocol/obfuscation.zig");
    pub const kex_init = @import("protocol/kex_init.zig");
    pub const kex_reply = @import("protocol/kex_reply.zig");
    pub const kex_cancel = @import("protocol/kex_cancel.zig");
    pub const kex_curve25519 = @import("protocol/kex_curve25519.zig");
    pub const key_derivation = @import("protocol/key_derivation.zig");
    pub const ssh_packet = @import("protocol/ssh_packet.zig");
    pub const quic_streams = @import("protocol/quic_streams.zig");
    pub const channel = @import("protocol/channel.zig");
    pub const ext_info = @import("protocol/ext_info.zig");
    pub const auth = @import("protocol/auth.zig");
    pub const userauth = @import("protocol/userauth.zig");
};

pub const common = struct {
    pub const errors = @import("common/errors.zig");
    pub const constants = @import("common/constants.zig");
};

pub const kex = struct {
    pub const shared_secrets = @import("kex/shared_secrets.zig");
    pub const exchange = @import("kex/exchange.zig");
};

pub const libfast = libfast_mod;

pub const network = struct {
    pub const udp = @import("network/udp.zig");
    pub const endpoint = @import("network/endpoint.zig");
};

pub const auth = struct {
    pub const dispatcher = @import("auth/auth.zig");
    pub const keyfile = @import("auth/keyfile.zig");
    pub const known_hosts = @import("auth/known_hosts.zig");
    pub const workflow = @import("auth/workflow.zig");
    pub const client = @import("auth/client.zig");
    pub const system = @import("auth/system.zig");
};

pub const channels = @import("channels/channels.zig");

pub const sftp = @import("sftp/sftp.zig");

pub const connection = @import("connection.zig");

pub const server = struct {
    pub const daemon = @import("server/daemon.zig");
    pub const session_runtime = @import("server/session_runtime.zig");
};

pub const platform = struct {
    pub const pty = @import("platform/pty.zig");
    pub const user = @import("platform/user.zig");
};

pub const ChannelData = @import("protocol/channel.zig").ChannelData;
pub const ChannelExtendedData = @import("protocol/channel.zig").ChannelExtendedData;
pub const ChannelRequest = @import("protocol/channel.zig").ChannelRequest;

test {
    std.testing.refAllDecls(@This());
    _ = @import("protocol/integration_test.zig");
    _ = @import("tests/integration/integration_tests.zig");
}
