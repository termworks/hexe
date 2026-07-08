//! Client registration CTL handler (frontend_register), extracted from
//! server.zig (PLAN.md 2.3 god-object split). Pure move: Server method taking
//! `*Server`, dispatched by name.
const std = @import("std");
const posix = std.posix;
const core = @import("core");
const wire = core.wire;
const ses = @import("main.zig");
const server = @import("server.zig");
const Server = server.Server;

pub fn handleBinaryRegister(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.Register)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "register: payload too small");
        return;
    }
    const reg = wire.readStructTimeout(wire.FrontendRegister, fd, server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "register request read failed", err);
        self.sendBinaryError(fd, "register: read failed");
        return;
    };

    const trailing_len: usize = @as(usize, reg.name_len) + @as(usize, reg.base_root_len);
    if (trailing_len != payload_len - @sizeOf(wire.Register)) {
        self.skipBinaryPayload(fd, payload_len - @sizeOf(wire.Register), buf);
        self.sendBinaryError(fd, "register: trailing payload size mismatch");
        return;
    }

    // Read trailing name and base root.
    var name_slice: []const u8 = "";
    var base_root_slice: []const u8 = "";
    if (trailing_len > 0) {
        if (trailing_len > wire.MAX_PAYLOAD_LEN) {
            // Name exceeds protocol limit - drain and reject
            self.skipBinaryPayload(fd, @intCast(trailing_len), buf);
            self.sendBinaryError(fd, "register: trailing payload exceeds MAX_PAYLOAD_LEN");
            return;
        }
        if (trailing_len <= buf.len) {
            wire.readExactTimeout(fd, buf[0..trailing_len], server.HANDLER_IO_TIMEOUT_MS) catch |err| {
                self.ctlStreamDesynced(fd, "mid-message read failed");
                core.logging.logError("ses", "register trailing payload read failed", err);
                self.sendBinaryError(fd, "register: name read failed");
                return;
            };
            name_slice = buf[0..reg.name_len];
            base_root_slice = buf[reg.name_len..trailing_len];
        } else {
            // Name too large for buffer - drain bytes to keep stream aligned, then reject
            self.skipBinaryPayload(fd, @intCast(trailing_len), buf);
            self.sendBinaryError(fd, "register: trailing payload too long for buffer");
            return;
        }
    }

    // Convert 32-byte hex session_id to 16-byte binary.
    const session_id = core.uuid.hexToBin(reg.session_id) orelse {
        self.sendBinaryError(fd, "register: invalid session_id hex");
        return;
    };

    // Find or create client.
    const client_id = self.findClientForCtlFd(fd) orelse blk: {
        const cid = self.ses_state.addClient(fd) catch |err| {
            core.logging.logError("ses", "register failed to add client", err);
            self.sendBinaryError(fd, "register: addClient failed");
            return;
        };
        break :blk cid;
    };

    // Resolve session name to ensure uniqueness (avoid collisions with detached sessions)
    const resolved_name: ?[]u8 = if (name_slice.len > 0)
        self.ses_state.resolveSessionName(name_slice, client_id, session_id) catch |err| {
            core.logging.logError("ses", "failed to resolve client session name", err);
            self.sendBinaryError(fd, "register: session name resolution failed");
            return;
        }
    else
        null;
    defer if (resolved_name) |rn| self.allocator.free(rn);

    if (self.ses_state.getClient(client_id)) |client| {
        client.keepalive = (reg.keepalive != 0);
        client.session_id = session_id;
        client.pending_reattach_session_id = null;
        client.mux_ctl_fd = fd;
        client.frontend_kind = reg.frontend_kind;
        client.transport_kind = reg.transport_kind;
        client.capability_flags = reg.capability_flags;
        if (base_root_slice.len > 0) {
            const owned_root = client.allocator.dupe(u8, base_root_slice) catch |err| {
                core.logging.logError("ses", "failed to store frontend base root", err);
                self.sendBinaryError(fd, "register: base root allocation failed");
                return;
            };
            if (client.base_root) |old| client.allocator.free(old);
            client.base_root = owned_root;
            if (client.session_snapshot) |*snapshot| {
                if (snapshot.base_root) |old| snapshot.allocator.free(old);
                snapshot.base_root = snapshot.allocator.dupe(u8, base_root_slice) catch |err| {
                    core.logging.logError("ses", "failed to store snapshot base root", err);
                    self.sendBinaryError(fd, "register: snapshot base root allocation failed");
                    return;
                };
            }
        }
        // Store the resolved name (duplicated since resolved_name will be freed)
        if (resolved_name) |rn| {
            const owned_name = client.allocator.dupe(u8, rn) catch |err| {
                core.logging.logError("ses", "failed to store resolved client session name", err);
                self.sendBinaryError(fd, "register: session name allocation failed");
                return;
            };
            if (client.session_name) |old| client.allocator.free(old);
            client.session_name = owned_name;
        } else {
            if (client.session_name) |old| client.allocator.free(old);
            client.session_name = null;
        }
    }

    // If this session_id matches a detached session, the frontend has successfully
    // restored it — remove the detached entry now.
    self.ses_state.removeDetachedSession(session_id);

    // Transaction log: reattach commit
    const hex_id: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
    self.ses_state.persistence.txlog.write(.reattach_commit, session_id, &hex_id) catch |err| {
        core.logging.logError("ses", "failed to write reattach_commit txlog entry", err);
    };

    // Release session lock (set during reattach in completeReattach)
    self.ses_state.releaseSessionLock(session_id);

    const final_name = resolved_name orelse name_slice;
    ses.debugLog("registered: session={s} name={s} (requested={s}) client_id={d} frontend_kind={d} transport_kind={d} caps=0x{x}", .{
        reg.session_id[0..8],
        final_name,
        name_slice,
        client_id,
        reg.frontend_kind,
        reg.transport_kind,
        reg.capability_flags,
    });

    // Send Registered response with resolved name
    const resp = wire.FrontendRegistered{ .name_len = @intCast(final_name.len) };
    self.replyOrCloseWithTrail(fd, .registered, std.mem.asBytes(&resp), final_name);
}
