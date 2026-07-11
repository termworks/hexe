const std = @import("std");
const posix = std.posix;
const core = @import("core");
const wire = core.wire;
const ses = @import("main.zig");
const polling_mod = @import("polling.zig");
const store_mod = @import("store.zig");

const POD_VT_ACK_TIMEOUT_MS: i32 = 1000;

// Dialed fds must be non-blocking: every wire timeout only engages on
// error.WouldBlock, so a blocking pod VT fd turns a wedged pod into an
// indefinitely blocked SES event loop (every session frozen at once). Shared
// helper: core.ipc.setNonBlocking.

/// Connect the VT data channel to a POD socket.
/// On success, stores the fd in the pane and populates routing tables.
pub fn connectPodVt(
    allocator: std.mem.Allocator,
    store: *store_mod.SessionStore,
    polling: *polling_mod.PollingState,
    uuid: [32]u8,
    pod_socket_path: []const u8,
    pane_id: u16,
) bool {
    const client = core.ipc.Client.connect(pod_socket_path) catch {
        ses.debugLog("connectPodVt: failed to connect to {s}", .{pod_socket_path});
        return false;
    };
    const fd = client.fd;

    core.ipc.setNonBlocking(fd) catch |err| {
        core.logging.logError("ses", "failed to set POD VT fd nonblocking", err);
        posix.close(fd);
        return false;
    };

    wire.sendHandshake(fd, wire.POD_HANDSHAKE_SES_VT) catch {
        posix.close(fd);
        return false;
    };

    const ack_hdr = wire.readControlHeaderTimeout(fd, POD_VT_ACK_TIMEOUT_MS) catch {
        posix.close(fd);
        return false;
    };
    const ack_type: wire.MsgType = @enumFromInt(ack_hdr.msg_type);
    if (ack_type != .ok) {
        ses.debugLog("connectPodVt: unexpected ack {x}, closing", .{ack_hdr.msg_type});
        posix.close(fd);
        return false;
    }

    const pane = store.panes.getPtr(uuid) orelse {
        posix.close(fd);
        return false;
    };
    if (pane.pod_vt_fd) |old_fd| {
        ses.debugLog("connectPodVt: closing old fd={d}", .{old_fd});
        _ = store.pod_vt_to_pane_id.remove(old_fd);
        polling.pending_remove_poll_fds.append(allocator, old_fd) catch |err| {
            core.logging.logError("ses", "failed to queue old POD VT fd removal", err);
        };
        store.noteClosedFd(old_fd);
        posix.close(old_fd);
    }
    pane.pod_vt_fd = fd;

    store.pane_id_to_pod_vt.put(pane_id, fd) catch |err| {
        core.logging.logError("ses", "failed to route pane id to POD VT fd", err);
        pane.pod_vt_fd = null;
        posix.close(fd);
        return false;
    };
    store.pod_vt_to_pane_id.put(fd, pane_id) catch |err| {
        core.logging.logError("ses", "failed to route POD VT fd to pane id", err);
        _ = store.pane_id_to_pod_vt.remove(pane_id);
        pane.pod_vt_fd = null;
        posix.close(fd);
        return false;
    };
    // Best-effort fast-path index for pod→mux output routing; lookups
    // validate against the pane and fall back to a scan on a miss.
    store.pane_id_to_uuid.put(pane_id, uuid) catch |err| {
        core.logging.logError("ses", "failed to index pane id to uuid", err);
    };

    polling.pending_poll_fds.append(allocator, fd) catch |err| {
        core.logging.logError("ses", "failed to queue POD VT fd for polling", err);
        _ = store.pane_id_to_pod_vt.remove(pane_id);
        _ = store.pod_vt_to_pane_id.remove(fd);
        pane.pod_vt_fd = null;
        posix.close(fd);
        return false;
    };

    const hex_uuid: [32]u8 = std.fmt.bytesToHex(uuid[0..16], .lower);
    ses.debugLog("connectPodVt: uuid={s} pane_id={d} fd={d}", .{ hex_uuid[0..8], pane_id, fd });
    return true;
}
