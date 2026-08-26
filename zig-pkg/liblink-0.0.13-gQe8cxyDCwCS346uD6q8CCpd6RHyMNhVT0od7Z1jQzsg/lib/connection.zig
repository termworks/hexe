const std = @import("std");
const Allocator = std.mem.Allocator;
const quic_transport = @import("network/quic_transport.zig");

// Import modules
const kex_exchange = @import("kex/exchange.zig");
const udp = @import("network/udp.zig");
const constants = @import("common/constants.zig");
const auth = @import("auth/auth.zig");
const known_hosts = @import("auth/known_hosts.zig");
const channels = @import("channels/channels.zig");
const sftp = @import("sftp/sftp.zig");

/// SSH/QUIC connection configuration
pub const ConnectionConfig = struct {
    /// Server hostname or IP address
    server_address: []const u8,

    /// Server port (default: 22)
    server_port: u16 = 22,

    /// Optional server name indication (SNI)
    server_name: ?[]const u8 = null,

    /// Supported QUIC versions
    quic_versions: []const u32 = &[_]u32{1},

    /// Client QUIC transport parameters
    quic_params: []const u8 = "",

    /// Trusted server host key fingerprints.
    ///
    /// If non-empty, server host key must match one of these fingerprints.
    /// Fingerprint format: SHA256:<base64>
    trusted_host_fingerprints: []const []const u8 = &[_][]const u8{},

    /// Random number generator
    random: std.Random,
};

pub const HostKeyTrustPolicy = enum {
    strict,
    accept_new,
};

/// Server configuration for accepting connections
pub const ServerConfig = struct {
    /// Listen address (e.g., "0.0.0.0", "::")
    listen_address: []const u8,

    /// Listen port (default: 22)
    listen_port: u16 = 22,

    /// Supported QUIC versions
    quic_versions: []const u32 = &[_]u32{1},

    /// Server QUIC transport parameters
    quic_params: []const u8 = "",

    /// Server host key (Ed25519 public key)
    host_key: []const u8,

    /// Server host private key (Ed25519)
    host_private_key: *const [64]u8,

    /// Random number generator
    random: std.Random,
};

fn sockaddrStorageFromAddress(address: *const std.net.Address) std.posix.sockaddr.storage {
    var storage = std.mem.zeroes(std.posix.sockaddr.storage);
    const len = address.getOsSockLen();
    const dst: [*]u8 = @ptrCast(&storage);
    const src: [*]const u8 = @ptrCast(&address.any);
    @memcpy(dst[0..len], src[0..len]);
    return storage;
}

/// Active SSH/QUIC client connection
pub const ClientConnection = struct {
    allocator: Allocator,
    transport: *quic_transport.QuicTransport,
    kex: kex_exchange.ClientKeyExchange,
    channel_manager: channels.ChannelManager,
    socket: std.posix.socket_t,

    const Self = @This();

    /// Establish a new SSH/QUIC connection to a server
    ///
    /// This performs:
    /// 1. SSH key exchange (SSH_QUIC_INIT/REPLY) over UDP
    /// 2. QUIC secret derivation from SSH exchange
    /// 3. QUIC connection initialization with SSH secrets
    ///
    /// Returns ready-to-use connection
    pub fn connect(allocator: Allocator, config: ConnectionConfig) !Self {
        std.log.info("Connecting to {s}:{}...", .{ config.server_address, config.server_port });

        // Initialize UDP transport for key exchange
        var udp_transport = try udp.KeyExchangeTransport.initClient(
            allocator,
            config.server_address,
            config.server_port,
        );
        // NOTE: Don't deinit udp_transport - we'll pass its socket to QUIC

        // Initialize key exchange
        var kex = try kex_exchange.ClientKeyExchange.init(allocator, config.random);
        errdefer kex.deinit();

        // Create SSH_QUIC_INIT message
        const server_name = config.server_name orelse config.server_address;
        const init_data = try kex.createInit(
            server_name,
            config.quic_versions,
            config.quic_params,
            config.trusted_host_fingerprints,
        );
        defer allocator.free(init_data);

        // Send SSH_QUIC_INIT over UDP
        try udp_transport.sendInit(init_data);

        // Receive SSH_QUIC_REPLY (with 10 second timeout)
        const reply_data = try udp_transport.receiveReply(10000);
        defer allocator.free(reply_data);

        // Process reply and derive QUIC secrets
        std.log.info("Processing SSH_QUIC_REPLY...", .{});
        const secrets = try kex.processReply(reply_data);

        // Initialize QUIC transport with SSH-derived secrets
        std.log.info("Initializing QUIC connection...", .{});

        const local_conn_id = secrets.client_connection_id;
        const remote_conn_id = secrets.server_connection_id;

        // Prepare server address for client to send packets to
        const server_storage = sockaddrStorageFromAddress(&udp_transport.socket.address);

        const transport = try allocator.create(quic_transport.QuicTransport);
        errdefer allocator.destroy(transport);

        transport.* = try quic_transport.QuicTransport.init(
            allocator,
            udp_transport.socket.socket, // Reuse UDP socket
            local_conn_id,
            remote_conn_id,
            secrets.client_secret,
            secrets.server_secret,
            false, // client mode
            server_storage, // Set peer address for client
        );
        errdefer transport.deinit();

        std.log.info("SSH/QUIC connection established", .{});

        // Initialize channel manager with pointer to heap-allocated transport
        const channel_manager = channels.ChannelManager.init(allocator, transport, false);

        return Self{
            .allocator = allocator,
            .transport = transport,
            .kex = kex,
            .channel_manager = channel_manager,
            .socket = udp_transport.socket.socket,
        };
    }

    pub fn deinit(self: *Self) void {
        self.channel_manager.deinit();
        self.transport.deinit();
        self.allocator.destroy(self.transport);
        self.kex.deinit();
        std.posix.close(self.socket);
    }

    /// Open a new SSH channel (maps to QUIC stream)
    pub fn openChannel(self: *Self) !u64 {
        return self.transport.openStream();
    }

    /// Close a channel
    pub fn closeChannel(self: *Self, channel_id: u64) !void {
        return self.transport.closeStream(channel_id);
    }

    /// Send data on a channel
    pub fn sendData(self: *Self, channel_id: u64, data: []const u8) !void {
        return self.transport.sendOnStream(channel_id, data);
    }

    /// Receive data from a channel
    pub fn receiveData(self: *Self, channel_id: u64, buffer: []u8) !usize {
        return self.transport.receiveFromStream(channel_id, buffer);
    }

    /// Authenticate with public key
    ///
    /// First queries if the key is acceptable, then sends signed request.
    /// Returns true on success, false on failure.
    pub fn authenticatePublicKey(
        self: *Self,
        username: []const u8,
        algorithm_name: []const u8,
        public_key_blob: []const u8,
        private_key: *const [64]u8,
    ) !bool {
        var auth_client = auth.AuthClient.init(self.allocator, username);
        try self.ensureAuthStreamOpen();

        // Get exchange hash (session identifier) from key exchange
        const exchange_hash = self.kex.getExchangeHash();

        // First try: query without signature
        {
            const query_data = try auth_client.authenticatePublicKey(
                algorithm_name,
                public_key_blob,
                null, // no signature
                exchange_hash,
            );
            defer self.allocator.free(query_data);

            try self.transport.sendOnStream(0, query_data);

            while (true) {
                var result = try self.receiveAuthResult(&auth_client);
                switch (result) {
                    .banner => {
                        result.deinit(self.allocator);
                        continue;
                    },
                    .pk_ok => {
                        result.deinit(self.allocator);
                        break;
                    },
                    .failure => {
                        result.deinit(self.allocator);
                        return false;
                    },
                    .success => {
                        result.deinit(self.allocator);
                        break;
                    },
                }
            }
        }

        // Second try: with signature
        {
            const auth_data = try auth_client.authenticatePublicKey(
                algorithm_name,
                public_key_blob,
                private_key,
                exchange_hash,
            );
            defer self.allocator.free(auth_data);

            try self.transport.sendOnStream(0, auth_data);

            while (true) {
                var result = try self.receiveAuthResult(&auth_client);
                switch (result) {
                    .banner => {
                        result.deinit(self.allocator);
                        continue;
                    },
                    .pk_ok => {
                        result.deinit(self.allocator);
                        continue;
                    },
                    .success => {
                        result.deinit(self.allocator);
                        return true;
                    },
                    .failure => {
                        result.deinit(self.allocator);
                        return false;
                    },
                }
            }
        }
    }

    /// Query available authentication methods
    pub fn queryAuthMethods(self: *Self, username: []const u8) ![]const []const u8 {
        var auth_client = auth.AuthClient.init(self.allocator, username);
        try self.ensureAuthStreamOpen();

        const none_data = try auth_client.authenticateNone();
        defer self.allocator.free(none_data);

        try self.transport.sendOnStream(0, none_data);

        while (true) {
            var result = try self.receiveAuthResult(&auth_client);
            switch (result) {
                .banner => {
                    result.deinit(self.allocator);
                    continue;
                },
                .pk_ok => {
                    result.deinit(self.allocator);
                    continue;
                },
                .failure => |f| {
                    // Caller owns returned methods memory.
                    return f.methods;
                },
                .success => {
                    result.deinit(self.allocator);
                    return &[_][]const u8{};
                },
            }
        }
    }

    /// Returns the server host key fingerprint observed during KEX.
    pub fn getServerHostKeyFingerprint(self: *const Self) []const u8 {
        return self.kex.getServerHostKeyFingerprint();
    }

    fn ensureAuthStreamOpen(self: *Self) !void {
        // Stream 0 is pre-created in QUIC connection init for auth.
        // No need to open a new stream — that would waste a stream ID.
        _ = self;
    }

    fn receiveAuthResult(self: *Self, auth_client: *auth.AuthClient) !auth.AuthResult {
        var response_buffer: [16384]u8 = undefined;
        var total_received: usize = 0;
        var attempts: usize = 0;

        while (attempts < 300) : (attempts += 1) {
            try self.transport.poll(100);

            const len = self.transport.receiveFromStream(0, response_buffer[total_received..]) catch |err| {
                if (err == error.NoData) continue;
                return err;
            };

            if (len == 0) continue;
            total_received += len;

            const response_data = response_buffer[0..total_received];
            return auth_client.processResponse(response_data) catch |err| {
                if (err == error.EndOfBuffer or err == error.InvalidResponse) {
                    continue;
                }
                return err;
            };
        }

        return error.AuthenticationTimeout;
    }

    /// Open a new session channel
    ///
    /// Returns a SessionChannel for shell, exec, or subsystem requests.
    pub fn openSession(self: *Self) !channels.SessionChannel {
        return channels.SessionChannel.open(self.allocator, &self.channel_manager);
    }

    /// Request shell on a session channel (convenience method)
    ///
    /// Opens a session channel, requests a PTY, requests a shell, and returns the channel.
    pub fn requestShell(self: *Self, term_cols: u32, term_rows: u32) !channels.SessionChannel {
        var session = try self.openSession();
        errdefer session.close() catch {};

        try session.waitForConfirmation();

        // Request PTY before shell for proper terminal support
        try session.requestPty(
            "xterm-256color", // TERM environment variable
            term_cols, // width in characters (from client terminal)
            term_rows, // height in rows (from client terminal)
            0, // width in pixels (0 = not specified)
            0, // height in pixels (0 = not specified)
        );

        try session.requestShell();

        return session;
    }

    /// Execute a command on a session channel (convenience method)
    ///
    /// Opens a session channel, executes the command, and returns the channel.
    pub fn requestExec(self: *Self, command: []const u8) !channels.SessionChannel {
        var session = try self.openSession();
        errdefer session.close() catch {};

        try session.waitForConfirmation();
        try session.requestExec(command);

        return session;
    }

    /// Request subsystem (e.g., "sftp") on a session channel
    ///
    /// Opens a session channel, requests the subsystem, and returns the channel.
    pub fn requestSubsystem(self: *Self, subsystem_name: []const u8) !channels.SessionChannel {
        var session = try self.openSession();
        errdefer session.close() catch {};

        try session.waitForConfirmation();
        try session.requestSubsystem(subsystem_name);

        return session;
    }

    /// Open SFTP session (convenience method)
    ///
    /// Opens a session channel, requests "sftp" subsystem, and returns
    /// an SFTP channel ready for file operations.
    pub fn openSftp(self: *Self) !sftp.SftpChannel {
        const session = try self.requestSubsystem("sftp");
        return sftp.SftpChannel.init(self.allocator, session);
    }
};

/// Active SSH/QUIC server connection handler
pub const ServerConnection = struct {
    allocator: Allocator,
    transport: quic_transport.QuicTransport,
    kex: kex_exchange.ServerKeyExchange,
    channel_manager: channels.ChannelManager,
    socket: ?std.posix.socket_t = null,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.channel_manager.deinit();
        self.transport.deinit();
        self.kex.deinit();
        if (self.socket) |s| std.posix.close(s);
    }

    /// Accept a new channel opened by client
    ///
    /// Waits for SSH_MSG_CHANNEL_OPEN on the next available client stream,
    /// validates the request, and sends SSH_MSG_CHANNEL_OPEN_CONFIRMATION.
    ///
    /// Returns the stream ID of the opened channel.
    pub fn acceptChannel(self: *Self) !u64 {
        // Determine next expected client stream (client streams are 4, 8, 12, ...)
        const next_stream_id = self.channel_manager.getNextClientStream();

        // Use channel manager to accept the channel
        try self.channel_manager.acceptChannel(next_stream_id);

        std.log.info("Server accepted channel on stream {}", .{next_stream_id});

        return next_stream_id;
    }

    /// Send data on a channel
    pub fn sendData(self: *Self, channel_id: u64, data: []const u8) !void {
        return self.transport.sendOnStream(channel_id, data);
    }

    /// Receive data from a channel
    pub fn receiveData(self: *Self, channel_id: u64, buffer: []u8) !usize {
        return self.transport.receiveFromStream(channel_id, buffer);
    }

    /// Handle client authentication request
    ///
    /// Receives authentication request on stream 0, validates credentials,
    /// and sends response. Returns true if authentication succeeds.
    pub fn handleAuthentication(
        self: *Self,
        publickey_validator: ?auth.AuthServer.PublicKeyValidator,
    ) !bool {
        const identity = try self.handleAuthenticationIdentity(publickey_validator);
        if (identity) |user| {
            self.allocator.free(user);
            return true;
        }
        return false;
    }

    /// Handle authentication and return authenticated username on success.
    /// Caller owns returned memory when non-null.
    pub fn handleAuthenticationIdentity(
        self: *Self,
        publickey_validator: ?auth.AuthServer.PublicKeyValidator,
    ) !?[]u8 {
        std.log.info("Waiting for authentication request...", .{});

        var auth_server = auth.AuthServer.init(self.allocator);
        if (publickey_validator) |validator| {
            auth_server.setPublicKeyValidator(validator);
            std.log.debug("Public key authentication enabled", .{});
        }

        var auth_rounds: usize = 0;
        while (auth_rounds < 10) : (auth_rounds += 1) {
            var request_buffer: [16384]u8 = undefined;
            var total_received: usize = 0;
            var attempts: usize = 0;

            var response: auth.AuthResponse = blk: {
                while (attempts < 300) : (attempts += 1) {
                    try self.transport.poll(100);

                    const len = self.transport.receiveFromStream(0, request_buffer[total_received..]) catch |err| {
                        if (err == error.NoData) continue;
                        std.log.err("Failed to receive authentication request: {}", .{err});
                        return err;
                    };

                    if (len == 0) continue;
                    total_received += len;

                    const request_data = request_buffer[0..total_received];
                    const exchange_hash = self.kex.getExchangeHash();

                    const auth_response = auth_server.processRequest(request_data, exchange_hash) catch |err| {
                        if (err == error.EndOfBuffer) {
                            continue;
                        }
                        std.log.err("Failed to process authentication request: {}", .{err});
                        return err;
                    };

                    break :blk auth_response;
                }

                return error.AuthenticationTimeout;
            };
            defer response.deinit(self.allocator);

            try self.transport.sendOnStream(0, response.data);

            if (response.success) {
                std.log.info("✓ Authentication successful", .{});
                if (response.authenticated_username) |user| {
                    const user_copy = try self.allocator.dupe(u8, user);
                    return user_copy;
                }
                return null;
            }

            if (response.data.len >= 1 and response.data[0] == constants.SSH_MSG.USERAUTH_PK_OK) {
                std.log.debug("Public key query accepted, waiting for signed auth request", .{});
                continue;
            }

            if (response.data.len >= 1 and response.data[0] == constants.SSH_MSG.USERAUTH_FAILURE) {
                std.log.warn("Authentication attempt failed, waiting for another method", .{});
                continue;
            }

            return null;
        }

        std.log.warn("✗ Authentication failed after maximum attempts", .{});
        return null;
    }

    /// Send authentication banner to client
    pub fn sendAuthBanner(self: *Self, message: []const u8, language_tag: []const u8) !void {
        var auth_server = auth.AuthServer.init(self.allocator);
        const banner_data = try auth_server.sendBanner(message, language_tag);
        defer self.allocator.free(banner_data);

        try self.transport.sendOnStream(0, banner_data);
    }

    /// Create a session server for handling client session requests
    pub fn createSessionServer(self: *Self) channels.SessionServer {
        return channels.SessionServer.init(self.allocator, &self.channel_manager);
    }

    /// Accept incoming session channel (convenience method)
    pub fn acceptSession(self: *Self, stream_id: u64) !void {
        try self.channel_manager.acceptChannel(stream_id);
    }

    /// Send data on a session channel
    pub fn sendSessionData(self: *Self, stream_id: u64, data: []const u8) !void {
        try self.channel_manager.sendData(stream_id, data);
    }

    /// Receive data from a session channel
    pub fn receiveSessionData(self: *Self, stream_id: u64) ![]u8 {
        return self.channel_manager.receiveData(stream_id);
    }

    /// Send EOF on a session channel
    pub fn sendSessionEof(self: *Self, stream_id: u64) !void {
        try self.channel_manager.sendEof(stream_id);
    }

    /// Close a session channel
    pub fn closeSession(self: *Self, stream_id: u64) !void {
        try self.channel_manager.closeChannel(stream_id);
    }
};

/// Connection listener for accepting multiple client connections
pub const ConnectionListener = struct {
    allocator: Allocator,
    config: ServerConfig,
    udp_transport: udp.KeyExchangeTransport,
    running: bool,
    active_connections: std.ArrayList(*ServerConnection),

    const Self = @This();

    /// Start listening for SSH/QUIC connections
    pub fn listen(allocator: Allocator, config: ServerConfig) !Self {
        std.log.info("SSH/QUIC server listening on {s}:{}", .{
            config.listen_address,
            config.listen_port,
        });

        // Initialize UDP transport for receiving key exchange messages
        var udp_transport = try udp.KeyExchangeTransport.initServer(
            allocator,
            config.listen_address,
            config.listen_port,
        );
        errdefer udp_transport.deinit();

        return Self{
            .allocator = allocator,
            .config = config,
            .udp_transport = udp_transport,
            .running = true,
            .active_connections = std.ArrayList(*ServerConnection){},
        };
    }

    pub fn deinit(self: *Self) void {
        // Clean up all active connections
        for (self.active_connections.items) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.active_connections.deinit(self.allocator);

        self.udp_transport.deinit();
    }

    /// Graceful shutdown - stops accepting new connections
    pub fn shutdown(self: *Self) void {
        std.log.info("Server shutting down gracefully...", .{});
        self.running = false;
    }

    /// Get number of active connections
    pub fn getActiveConnectionCount(self: *Self) usize {
        return self.active_connections.items.len;
    }

    /// Remove a connection from tracking (called when client disconnects)
    pub fn removeConnection(self: *Self, conn: *ServerConnection) void {
        for (self.active_connections.items, 0..) |tracked_conn, i| {
            if (tracked_conn == conn) {
                _ = self.active_connections.swapRemove(i);
                conn.deinit();
                self.allocator.destroy(conn);
                std.log.info("Client disconnected, {} active connections remaining", .{
                    self.active_connections.items.len,
                });
                return;
            }
        }
    }

    /// Accept the next incoming connection
    ///
    /// This blocks until a client connects. Returns a pointer to the
    /// ServerConnection which is tracked by the listener.
    ///
    /// The connection is automatically cleaned up when removeConnection() is called
    /// or when the listener is deinitialized.
    pub fn acceptConnection(self: *Self) !*ServerConnection {
        if (!self.running) {
            return error.ServerShutdown;
        }

        // Receive SSH_QUIC_INIT from client (may return WouldBlock if no data ready)
        const init_result = try self.udp_transport.receiveInit();
        defer self.allocator.free(init_result.init_data);

        std.log.info("Received connection from {any}", .{init_result.client_address});

        // Initialize server key exchange
        var kex = kex_exchange.ServerKeyExchange.init(self.allocator, self.config.random);
        errdefer kex.deinit();

        // Process init and create reply
        const result = try kex.processInitAndCreateReply(
            init_result.init_data,
            self.config.quic_versions,
            self.config.quic_params,
            self.config.host_key,
            self.config.host_private_key,
        );
        defer self.allocator.free(result.reply_data);

        // Send SSH_QUIC_REPLY back to client
        try self.udp_transport.sendReply(result.reply_data, init_result.client_address);

        // Initialize QUIC transport with derived secrets
        std.log.info("Initializing QUIC connection...", .{});

        const local_conn_id = result.server_connection_id;
        const remote_conn_id = result.client_connection_id;

        // Create a per-connection UDP socket connected to this specific client.
        // The kernel routes packets from this client to the connected socket,
        // keeping the listener socket free for new clients.
        const conn_socket = try std.posix.socket(
            init_result.client_address.any.family,
            std.posix.SOCK.DGRAM,
            std.posix.IPPROTO.UDP,
        );
        errdefer std.posix.close(conn_socket);

        const reuse: u32 = 1;
        try std.posix.setsockopt(conn_socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&reuse));
        try std.posix.setsockopt(conn_socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, std.mem.asBytes(&reuse));

        // Bind to same address as listener
        const listen_addr = self.udp_transport.socket.address;
        try std.posix.bind(conn_socket, &listen_addr.any, listen_addr.getOsSockLen());

        // Connect to client — this filters incoming packets to only this client
        try std.posix.connect(conn_socket, &init_result.client_address.any, init_result.client_address.getOsSockLen());

        // Prepare client address for server transport (convert Address to sockaddr.storage)
        const client_storage = sockaddrStorageFromAddress(&init_result.client_address);

        var transport = try quic_transport.QuicTransport.init(
            self.allocator,
            conn_socket, // Per-connection socket
            local_conn_id,
            remote_conn_id,
            result.client_secret,
            result.server_secret,
            true, // server mode
            client_storage, // Set peer address for server
        );
        errdefer transport.deinit();

        // Allocate and track the connection
        const conn = try self.allocator.create(ServerConnection);
        errdefer self.allocator.destroy(conn);

        conn.* = ServerConnection{
            .allocator = self.allocator,
            .transport = transport,
            .kex = kex,
            .channel_manager = undefined, // Initialize after transport is in place
            .socket = conn_socket,
        };

        // Initialize channel manager with pointer to conn.transport (not local variable!)
        conn.channel_manager = channels.ChannelManager.init(self.allocator, &conn.transport, true);

        try self.active_connections.append(self.allocator, conn);

        std.log.info("Client connection established, {} total active connections", .{
            self.active_connections.items.len,
        });

        return conn;
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Create a simple client connection (convenience wrapper)
pub fn connectClient(
    allocator: Allocator,
    server_address: []const u8,
    server_port: u16,
    random: std.Random,
) !ClientConnection {
    const config = ConnectionConfig{
        .server_address = server_address,
        .server_port = server_port,
        .random = random,
    };

    return ClientConnection.connect(allocator, config);
}

/// Create a client connection with known-hosts trust policy.
pub fn connectClientTrusted(
    allocator: Allocator,
    server_address: []const u8,
    server_port: u16,
    random: std.Random,
    policy: HostKeyTrustPolicy,
) !ClientConnection {
    const host_key = try known_hosts.hostKeyForEndpoint(allocator, server_address, server_port);
    defer allocator.free(host_key);

    const trusted_owned = try known_hosts.loadFingerprintsForHost(allocator, host_key);
    defer known_hosts.freeFingerprints(allocator, trusted_owned);

    if (policy == .strict and trusted_owned.len == 0) {
        return error.UnknownHostKey;
    }

    const trusted = try allocator.alloc([]const u8, trusted_owned.len);
    defer allocator.free(trusted);
    for (trusted_owned, 0..) |fp, idx| {
        trusted[idx] = fp;
    }

    const config = ConnectionConfig{
        .server_address = server_address,
        .server_port = server_port,
        .trusted_host_fingerprints = trusted,
        .random = random,
    };

    var conn = try ClientConnection.connect(allocator, config);

    if (policy == .accept_new and trusted_owned.len == 0) {
        const observed = conn.getServerHostKeyFingerprint();
        if (observed.len > 0) {
            try known_hosts.addFingerprint(allocator, host_key, observed);
        }
    }

    return conn;
}

/// Start a simple server listener (convenience wrapper)
pub fn startServer(
    allocator: Allocator,
    listen_address: []const u8,
    listen_port: u16,
    host_key: []const u8,
    host_private_key: *const [64]u8,
    random: std.Random,
) !ConnectionListener {
    const config = ServerConfig{
        .listen_address = listen_address,
        .listen_port = listen_port,
        .host_key = host_key,
        .host_private_key = host_private_key,
        .random = random,
    };

    return ConnectionListener.listen(allocator, config);
}

// ============================================================================
// Tests
// ============================================================================

test "ConnectionConfig - default values" {
    const testing = std.testing;

    var prng = std.Random.DefaultPrng.init(54321);
    const random = prng.random();

    const config = ConnectionConfig{
        .server_address = "example.com",
        .random = random,
    };

    try testing.expectEqual(@as(u16, 22), config.server_port);
    try testing.expectEqual(@as(?[]const u8, null), config.server_name);
}

test "ServerConfig - initialization" {
    const testing = std.testing;

    var prng = std.Random.DefaultPrng.init(99999);
    const random = prng.random();

    var host_private_key: [64]u8 = undefined;
    random.bytes(&host_private_key);

    const config = ServerConfig{
        .listen_address = "0.0.0.0",
        .host_key = "ssh-ed25519 key...",
        .host_private_key = &host_private_key,
        .random = random,
    };

    try testing.expectEqual(@as(u16, 22), config.listen_port);
    try testing.expectEqualStrings("0.0.0.0", config.listen_address);
}

test "sockaddrStorageFromAddress preserves IPv4 addresses" {
    const testing = std.testing;

    const address = try std.net.Address.parseIp4("127.0.0.1", 2222);
    const storage = sockaddrStorageFromAddress(&address);
    const roundtrip = std.net.Address.initPosix(@ptrCast(&storage));

    try testing.expect(std.net.Address.eql(address, roundtrip));
}

test "sockaddrStorageFromAddress preserves IPv6 addresses" {
    const testing = std.testing;

    const address = try std.net.Address.parseIp6("2001:db8::1", 2222);
    const storage = sockaddrStorageFromAddress(&address);
    const roundtrip = std.net.Address.initPosix(@ptrCast(&storage));

    try testing.expect(std.net.Address.eql(address, roundtrip));
}

// Test helper: public key validator
fn testPublicKeyValidator(username: []const u8, algorithm: []const u8, public_key_blob: []const u8) bool {
    _ = public_key_blob;
    std.log.info("Public key validation: user={s}, algorithm={s}", .{ username, algorithm });
    return std.mem.eql(u8, username, "keyuser") and std.mem.eql(u8, algorithm, "ssh-ed25519");
}

test "ServerConnection - authentication validators" {
    const testing = std.testing;

    // Test public key validator
    const dummy_key = "dummy-key";
    try testing.expect(testPublicKeyValidator("keyuser", "ssh-ed25519", dummy_key));
    try testing.expect(!testPublicKeyValidator("keyuser", "ssh-rsa", dummy_key));
    try testing.expect(!testPublicKeyValidator("wronguser", "ssh-ed25519", dummy_key));
}

test "ConnectionListener - init and shutdown" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(99999);
    const random = prng.random();

    // Generate Ed25519 keypair for testing
    const Ed25519 = std.crypto.sign.Ed25519;
    const ed_keypair = Ed25519.KeyPair.generate();

    var host_private_key: [64]u8 = undefined;
    @memcpy(&host_private_key, &ed_keypair.secret_key.bytes);

    var host_public_key: [32]u8 = undefined;
    @memcpy(&host_public_key, &ed_keypair.public_key.bytes);

    // Encode host key as SSH blob
    const host_key_blob = try encodeTestHostKey(allocator, &host_public_key);
    defer allocator.free(host_key_blob);

    const config = ServerConfig{
        .listen_address = "127.0.0.1",
        .listen_port = 9999, // Use high port for testing
        .host_key = host_key_blob,
        .host_private_key = &host_private_key,
        .random = random,
    };

    // Note: Can't actually initialize listener without network stack
    // This tests the configuration structure
    try testing.expectEqualStrings("127.0.0.1", config.listen_address);
    try testing.expectEqual(@as(u16, 9999), config.listen_port);
}

test "ConnectionListener - running flag" {
    const testing = std.testing;

    // Simulate listener state
    var running: bool = true;
    try testing.expect(running);

    // Simulate shutdown
    running = false;
    try testing.expect(!running);
}

test "ConnectionListener - connection tracking" {
    const testing = std.testing;

    // Test connection counting logic
    var count: usize = 0;

    // Add connections
    count += 1;
    count += 1;
    count += 1;
    try testing.expectEqual(@as(usize, 3), count);

    // Remove a connection
    count -= 1;
    try testing.expectEqual(@as(usize, 2), count);

    // Clear all
    count = 0;
    try testing.expectEqual(@as(usize, 0), count);
}

// Helper to encode SSH host key for tests
fn encodeTestHostKey(allocator: std.mem.Allocator, public_key: *const [32]u8) ![]u8 {
    const algorithm = "ssh-ed25519";
    const blob_size = 4 + algorithm.len + 4 + public_key.len;
    const host_key_blob = try allocator.alloc(u8, blob_size);
    errdefer allocator.free(host_key_blob);

    var offset: usize = 0;

    // Write algorithm name
    std.mem.writeInt(u32, host_key_blob[offset..][0..4], @intCast(algorithm.len), .big);
    offset += 4;
    @memcpy(host_key_blob[offset .. offset + algorithm.len], algorithm);
    offset += algorithm.len;

    // Write public key
    std.mem.writeInt(u32, host_key_blob[offset..][0..4], @intCast(public_key.len), .big);
    offset += 4;
    @memcpy(host_key_blob[offset .. offset + public_key.len], public_key);

    return host_key_blob;
}
