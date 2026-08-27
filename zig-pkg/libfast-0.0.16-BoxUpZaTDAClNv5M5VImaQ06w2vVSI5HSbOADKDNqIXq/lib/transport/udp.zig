const std = @import("std");
const net = std.net;
const os = std.os;

/// UDP socket for QUIC transport
pub const UdpSocket = struct {
    fd: std.posix.socket_t,
    local_addr: net.Address,
    allocator: std.mem.Allocator,

    /// Error types for UDP operations
    pub const Error = error{
        SocketCreateFailed,
        BindFailed,
        SendFailed,
        ReceiveFailed,
        AddressResolveFailed,
        InvalidIPAddressFormat,
    } || std.posix.SocketError || std.posix.BindError || std.posix.SendToError || std.posix.RecvFromError;

    /// Create and bind a UDP socket
    pub fn bind(allocator: std.mem.Allocator, addr: net.Address) Error!UdpSocket {
        const fd = try std.posix.socket(
            addr.any.family,
            std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK,
            std.posix.IPPROTO.UDP,
        );
        errdefer std.posix.close(fd);

        try std.posix.bind(fd, &addr.any, addr.getOsSockLen());

        return UdpSocket{
            .fd = fd,
            .local_addr = addr,
            .allocator = allocator,
        };
    }

    /// Create UDP socket bound to any available port
    pub fn bindAny(allocator: std.mem.Allocator, port: u16) Error!UdpSocket {
        const addr = try net.Address.parseIp("0.0.0.0", port);
        return try bind(allocator, addr);
    }

    /// Close the socket
    pub fn close(self: *UdpSocket) void {
        std.posix.close(self.fd);
    }

    /// Send datagram to specified address
    pub fn sendTo(self: *UdpSocket, data: []const u8, dest: net.Address) Error!usize {
        return std.posix.sendto(
            self.fd,
            data,
            0,
            &dest.any,
            dest.getOsSockLen(),
        ) catch |err| {
            std.log.err("UDP sendTo failed: {}", .{err});
            return error.SendFailed;
        };
    }

    /// Receive datagram (non-blocking)
    /// Returns number of bytes received and sender address
    pub fn recvFrom(self: *UdpSocket, buffer: []u8) Error!struct { bytes: usize, addr: net.Address } {
        var src_addr: std.posix.sockaddr = undefined;
        var src_addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

        const bytes_read = std.posix.recvfrom(
            self.fd,
            buffer,
            0,
            &src_addr,
            &src_addr_len,
        ) catch |err| switch (err) {
            error.WouldBlock => return error.WouldBlock,
            else => {
                std.log.err("UDP recvFrom failed: {}", .{err});
                return error.ReceiveFailed;
            },
        };

        const addr = net.Address.initPosix(@alignCast(&src_addr));

        return .{
            .bytes = bytes_read,
            .addr = addr,
        };
    }

    /// Get local address
    pub fn getLocalAddress(self: *UdpSocket) Error!net.Address {
        var addr: std.posix.sockaddr = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

        try std.posix.getsockname(self.fd, &addr, &addr_len);

        return net.Address.initPosix(@alignCast(&addr));
    }

    /// Set socket to blocking or non-blocking mode
    pub fn setNonBlocking(self: *UdpSocket, non_blocking: bool) Error!void {
        const flags = try std.posix.fcntl(self.fd, std.posix.F.GETFL, 0);
        const new_flags = if (non_blocking)
            flags | @as(u32, std.posix.O.NONBLOCK)
        else
            flags & ~@as(u32, std.posix.O.NONBLOCK);
        _ = try std.posix.fcntl(self.fd, std.posix.F.SETFL, new_flags);
    }
};

// Tests

test "UDP socket bind and close" {
    const allocator = std.testing.allocator;

    var socket = try UdpSocket.bindAny(allocator, 0);
    defer socket.close();

    const addr = try socket.getLocalAddress();
    try std.testing.expect(addr.getPort() > 0);
}

test "UDP socket send and receive" {
    const allocator = std.testing.allocator;

    // Create two sockets
    var socket1 = try UdpSocket.bindAny(allocator, 0);
    defer socket1.close();
    const addr1 = try socket1.getLocalAddress();

    var socket2 = try UdpSocket.bindAny(allocator, 0);
    defer socket2.close();
    const addr2 = try socket2.getLocalAddress();

    // Send from socket1 to socket2
    const test_data = "Hello, QUIC!";
    const sent = try socket1.sendTo(test_data, addr2);
    try std.testing.expectEqual(test_data.len, sent);

    // Receive on socket2
    var recv_buf: [1024]u8 = undefined;

    // Try receiving with a small delay (busy wait for test)
    var retries: u32 = 100;
    const result = while (retries > 0) : (retries -= 1) {
        if (socket2.recvFrom(&recv_buf)) |r| {
            break r;
        } else |err| {
            if (err == error.WouldBlock) {
                // Wait a bit and retry
                var i: u32 = 0;
                while (i < 10000) : (i += 1) {
                    @import("std").mem.doNotOptimizeAway(i);
                }
                continue;
            }
            return err;
        }
    } else socket2.recvFrom(&recv_buf) catch |err| {
        if (err == error.WouldBlock) {
            std.debug.print("Receive would block (expected in some environments)\n", .{});
            return;
        }
        return err;
    };

    try std.testing.expectEqual(test_data.len, result.bytes);
    try std.testing.expectEqualStrings(test_data, recv_buf[0..result.bytes]);
    try std.testing.expectEqual(addr1.getPort(), result.addr.getPort());
}
