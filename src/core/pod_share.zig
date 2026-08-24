//! Client for a pod's share control channel (⑥).
//!
//! Asking the pod directly, rather than routing through SES, is the point: this
//! is what "stop sharing" is built on, and it has to work when the program that
//! opened those observers has stopped answering. Every hop added here is
//! another process that can be wedged while a user is trying to cut a stream.

const std = @import("std");
const posix = std.posix;

const ipc = @import("ipc.zig");
const wire = @import("wire.zig");
const logging = @import("logging.zig");

/// Same budget the pod applies on its side, so neither end waits on a peer that
/// has already given up on the other.
const SHARE_TIMEOUT_MS: i32 = 250;

pub const Status = struct {
    observers: u16,
    blocked: bool,
};

/// Send one command to a pane's pod and read back what it decided.
///
/// `query` never changes anything, so it is also the way to read the truth when
/// a caller does not trust its cached copy.
pub fn request(allocator: std.mem.Allocator, uuid: []const u8, cmd: wire.PodShareCmd) !Status {
    const path = try ipc.getPodSocketPath(allocator, uuid);
    defer allocator.free(path);
    return requestPath(path, cmd);
}

/// The same, for callers that already resolved a socket -- the CLI accepts a
/// name or an explicit path, neither of which is a uuid.
pub fn requestPath(socket_path: []const u8, cmd: wire.PodShareCmd) !Status {
    const client = try ipc.Client.connect(socket_path);
    defer posix.close(client.fd);

    // Handshake and command in one write: the pod reads the two-byte preamble
    // and then does a bounded read for the command, so splitting them across
    // two writes would put a syscall's worth of latency inside that budget for
    // no reason.
    const msg = [_]u8{ wire.POD_HANDSHAKE_AUX_CONTROL, wire.PROTOCOL_VERSION, @intFromEnum(cmd) };
    try wire.writeAllTimeout(client.fd, &msg, SHARE_TIMEOUT_MS);

    var reply: wire.PodShareStatus = undefined;
    try wire.readExactTimeout(client.fd, std.mem.asBytes(&reply), SHARE_TIMEOUT_MS);
    return .{ .observers = reply.observers, .blocked = reply.blocked != 0 };
}

/// Best-effort variant for callers that have somewhere better to put an error
/// than the return value -- a Lua verb, a decor button.
pub fn requestLogged(allocator: std.mem.Allocator, uuid: []const u8, cmd: wire.PodShareCmd) ?Status {
    return request(allocator, uuid, cmd) catch |err| {
        logging.logError("pod_share", "share control request failed", err);
        return null;
    };
}
