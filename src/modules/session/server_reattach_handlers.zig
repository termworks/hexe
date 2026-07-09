//! Detach / reattach / disconnect CTL handlers, extracted from server.zig
//! (PLAN.md 2.3 god-object split). Pure move: Server methods (incl. the
//! completeReattach helper) taking `*Server`, dispatched by name.
const std = @import("std");
const posix = std.posix;
const core = @import("core");
const wire = core.wire;
const ses = @import("main.zig");
const server = @import("server.zig");
const Server = server.Server;

/// Force-detach with full server-side fd bookkeeping. The state layer's
/// forceDetachAttachedSession closes the owner's fds (noted), but only the
/// server knows about watchers, binary_ctl_fds, pending pops and the per-fd
/// mux VT queue — skipping the purge leaves armed watchers on dead fds and,
/// worse, lets a NEW connection that reuses the vt fd number inherit the old
/// owner's queued output bytes.
fn forceDetachWithPurge(self: *Server, session_id: [16]u8) bool {
    for (self.ses_state.store.clients.items) |client| {
        if (client.session_id) |sid| {
            if (std.mem.eql(u8, &sid, &session_id)) {
                self.purgeClientFdState(client.id);
                break;
            }
        }
    }
    return self.ses_state.forceDetachAttachedSession(session_id);
}

pub fn handleBinaryDetach(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.Detach)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "detach: payload too small for Detach header");
        return;
    }
    const det = wire.readStructTimeout(wire.Detach, fd, server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "detach request read failed", err);
        self.sendBinaryError(fd, "detach: read failed");
        return;
    };
    const extra_len = payload_len - @sizeOf(wire.Detach);
    if (extra_len > 0) {
        self.skipBinaryPayload(fd, extra_len, buf);
        self.sendBinaryError(fd, "detach: legacy state payload is no longer accepted");
        return;
    }

    // Convert session_id hex to binary.
    const session_id = core.uuid.hexToBin(det.session_id) orelse {
        self.sendBinaryError(fd, "detach: invalid session_id hex format");
        return;
    };

    const client_id = self.findClientForCtlFd(fd) orelse {
        self.sendBinaryError(fd, "detach: client not registered");
        return;
    };

    const session_name = if (self.ses_state.getClient(client_id)) |client|
        client.session_name orelse "unknown"
    else
        "unknown";

    // Acquire session lock to prevent concurrent reattach
    self.ses_state.acquireSessionLock(session_id, client_id, .detaching) catch |err| {
        core.logging.logError("ses", "detach failed to acquire session lock", err);
        self.sendBinaryError(fd, "session_locked: another client is attaching this session");
        return;
    };
    // Lock will be released after detach completes

    if (self.ses_state.detachSession(client_id, session_id, session_name)) {
        self.ses_state.markDirty();
        // The detach ack promises the session is recoverable: persist the
        // detached snapshot before replying so a daemon crash inside the
        // next periodic-save window cannot lose it.
        self.persistNow();
        // Release lock after successful detach
        self.ses_state.releaseSessionLock(session_id);
        self.replyOrClose(fd, .session_detached, &.{});
    } else {
        // Release lock on failure too
        self.ses_state.releaseSessionLock(session_id);
        self.sendBinaryError(fd, "detach_failed");
    }
}

pub fn handleBinaryReattach(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.Reattach)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "invalid_payload");
        return;
    }
    const ra = wire.readStructTimeout(wire.Reattach, fd, server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "reattach request read failed", err);
        self.sendBinaryError(fd, "reattach: read failed");
        return;
    };
    if (ra.id_len > buf.len or ra.id_len == 0) {
        self.skipBinaryPayload(fd, ra.id_len, buf);
        self.sendBinaryError(fd, "invalid_id");
        return;
    }
    wire.readExactTimeout(fd, buf[0..ra.id_len], server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "reattach id read failed", err);
        self.sendBinaryError(fd, "reattach: id read failed");
        return;
    };
    const id_prefix = buf[0..ra.id_len];

    // Enforce minimum prefix length to avoid ambiguous matches
    if (id_prefix.len < 4) {
        self.sendBinaryError(fd, "prefix_too_short: provide at least 4 characters (UUID or session name)");
        return;
    }

    // Phase 1: Try UUID prefix match (most specific, unambiguous).
    // UUID matching takes priority over name matching.
    var uuid_matched_id: ?[16]u8 = null;
    var uuid_match_count: usize = 0;
    var ds_iter = self.ses_state.store.detached_sessions.iterator();
    while (ds_iter.next()) |entry| {
        const key_ptr = entry.key_ptr;
        const hex_id: [32]u8 = std.fmt.bytesToHex(key_ptr, .lower);
        if (std.mem.startsWith(u8, &hex_id, id_prefix)) {
            uuid_matched_id = key_ptr.*;
            uuid_match_count += 1;
        }
    }

    // If UUID matched uniquely, use it immediately (don't try name matching).
    if (uuid_match_count == 1) {
        const session_id = uuid_matched_id.?;
        const client_id = self.findClientForCtlFd(fd) orelse {
            self.sendBinaryError(fd, "no_client");
            return;
        };
        completeReattach(self, fd, session_id, client_id);
        return;
    }

    // If multiple UUID matches (very rare, but possible with short prefixes), report ambiguity.
    if (uuid_match_count > 1) {
        self.sendBinaryError(fd, "ambiguous_uuid_prefix: provide more characters");
        return;
    }

    // Phase 2: No detached UUID match, try exact DETACHED session name match.
    // Collect all matching detached sessions for disambiguation.
    var name_matches: [16]struct {
        session_id: [16]u8,
        name: []const u8,
    } = undefined;
    var name_match_count: usize = 0;

    ds_iter = self.ses_state.store.detached_sessions.iterator();
    while (ds_iter.next()) |entry| {
        const key_ptr = entry.key_ptr;
        const detached = entry.value_ptr;

        // Exact name match (case-insensitive).
        if (std.ascii.eqlIgnoreCase(detached.session_snapshot.session_name, id_prefix)) {
            if (name_match_count < name_matches.len) {
                name_matches[name_match_count] = .{
                    .session_id = key_ptr.*,
                    .name = detached.session_snapshot.session_name,
                };
                name_match_count += 1;
            }
        }
    }

    if (name_match_count == 0) {
        // Phase 3: Session may be actively attached elsewhere.
        // If matched, force-detach owner and continue attach here.

        // 3a) UUID prefix among attached sessions.
        var attached_uuid_match: ?[16]u8 = null;
        var attached_uuid_count: usize = 0;
        for (self.ses_state.store.clients.items) |client| {
            if (client.session_id) |sid| {
                const sid_hex: [32]u8 = std.fmt.bytesToHex(&sid, .lower);
                if (std.mem.startsWith(u8, &sid_hex, id_prefix)) {
                    attached_uuid_match = sid;
                    attached_uuid_count += 1;
                }
            }
        }

        if (attached_uuid_count == 1) {
            const session_id = attached_uuid_match.?;
            if (!forceDetachWithPurge(self, session_id)) {
                core.logging.warn("ses", "reattach failed to force-detach attached session by uuid session={s}", .{id_prefix});
                self.sendBinaryError(fd, "reattach_failed");
                return;
            }

            const client_id = self.findClientForCtlFd(fd) orelse {
                self.sendBinaryError(fd, "no_client");
                return;
            };
            completeReattach(self, fd, session_id, client_id);
            return;
        }

        if (attached_uuid_count > 1) {
            self.sendBinaryError(fd, "ambiguous_uuid_prefix: provide more characters");
            return;
        }

        // 3b) Exact attached session name match.
        var attached_name_matches: [16]struct {
            session_id: [16]u8,
            name: []const u8,
        } = undefined;
        var attached_name_count: usize = 0;

        for (self.ses_state.store.clients.items) |client| {
            const sid = client.session_id orelse continue;
            const sname = client.session_name orelse continue;
            if (std.ascii.eqlIgnoreCase(sname, id_prefix)) {
                if (attached_name_count < attached_name_matches.len) {
                    attached_name_matches[attached_name_count] = .{
                        .session_id = sid,
                        .name = sname,
                    };
                    attached_name_count += 1;
                }
            }
        }

        if (attached_name_count == 0) {
            self.sendBinaryError(fd, "session_not_found");
            return;
        }

        if (attached_name_count == 1) {
            const session_id = attached_name_matches[0].session_id;
            if (!forceDetachWithPurge(self, session_id)) {
                core.logging.warn("ses", "reattach failed to force-detach attached session by name session={s}", .{id_prefix});
                self.sendBinaryError(fd, "reattach_failed");
                return;
            }

            const client_id = self.findClientForCtlFd(fd) orelse {
                self.sendBinaryError(fd, "no_client");
                return;
            };
            completeReattach(self, fd, session_id, client_id);
            return;
        }

        var attached_err_buf: [512]u8 = undefined;
        var attached_stream = std.io.fixedBufferStream(&attached_err_buf);
        const attached_writer = attached_stream.writer();
        attached_writer.print("ambiguous: multiple sessions named '{s}'. Use UUID prefix:\n", .{id_prefix}) catch {
            self.sendBinaryError(fd, "ambiguous_session_name");
            return;
        };
        for (attached_name_matches[0..attached_name_count]) |match| {
            const hex_id = std.fmt.bytesToHex(&match.session_id, .lower);
            attached_writer.print("  {s} ({s})\n", .{ hex_id[0..8], match.name }) catch {
                self.sendBinaryError(fd, "ambiguous_session_name");
                return;
            };
        }
        self.sendBinaryError(fd, attached_stream.getWritten());
        return;
    }

    if (name_match_count == 1) {
        const session_id = name_matches[0].session_id;
        const client_id = self.findClientForCtlFd(fd) orelse {
            self.sendBinaryError(fd, "no_client");
            return;
        };
        completeReattach(self, fd, session_id, client_id);
        return;
    }

    // Multiple sessions with the same name - build disambiguation message.
    var err_buf: [512]u8 = undefined;
    var err_stream = std.io.fixedBufferStream(&err_buf);
    const writer = err_stream.writer();
    writer.print("ambiguous: multiple sessions named '{s}'. Use UUID prefix:\n", .{id_prefix}) catch {
        self.sendBinaryError(fd, "ambiguous_session_name");
        return;
    };
    for (name_matches[0..name_match_count]) |match| {
        const hex_id = std.fmt.bytesToHex(&match.session_id, .lower);
        writer.print("  {s} ({s})\n", .{ hex_id[0..8], match.name }) catch {
            self.sendBinaryError(fd, "ambiguous_session_name");
            return;
        };
    }
    self.sendBinaryError(fd, err_stream.getWritten());
}

/// Helper to complete reattach after session_id is resolved.
pub fn completeReattach(self: *Server, fd: posix.fd_t, session_id: [16]u8, client_id: usize) void {
    const hex_id_dbg: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
    ses.debugLog("completeReattach: begin session={s} client_id={d} fd={d}", .{ hex_id_dbg[0..8], client_id, fd });

    // Transaction log: reattach start
    const hex_id: [32]u8 = std.fmt.bytesToHex(&session_id, .lower);
    self.ses_state.persistence.txlog.write(.reattach_start, session_id, &hex_id) catch |err| {
        core.logging.logError("ses", "failed to write reattach_start txlog entry", err);
    };

    // Acquire session lock to prevent concurrent reattach
    self.ses_state.acquireSessionLock(session_id, client_id, .attaching) catch |err| {
        core.logging.logError("ses", "reattach failed to acquire session lock", err);
        self.sendBinaryError(fd, "session_locked: another client is attaching this session");
        return;
    };
    // Note: Lock will be released in handleBinaryRegister after successful registration

    const result = self.ses_state.reattachSession(session_id, client_id) catch |err| {
        core.logging.logError("ses", "reattach session state mutation failed", err);
        ses.debugLog("completeReattach: ses_state.reattachSession threw", .{});
        self.ses_state.releaseSessionLock(session_id);
        self.sendBinaryError(fd, "reattach_failed");
        return;
    };
    if (result == null) {
        ses.debugLog("completeReattach: session not found after lock", .{});
        self.ses_state.releaseSessionLock(session_id);
        self.sendBinaryError(fd, "session_not_found");
        return;
    }
    const reattach_result = result.?;
    ses.debugLog("completeReattach: borrowed snapshot panes={d}", .{reattach_result.pane_uuids.len});
    const snapshot = reattach_result.session_snapshot;
    ses.debugLog(
        "completeReattach: snapshot name={s} uuid={s} tabs={d} panes={d} floats={d} active_tab={d}",
        .{
            snapshot.session_name,
            snapshot.uuid[0..8],
            snapshot.tabs.items.len,
            snapshot.panes.count(),
            snapshot.floats.items.len,
            snapshot.active_tab,
        },
    );
    for (snapshot.tabs.items, 0..) |tab, idx| {
        ses.debugLog(
            "completeReattach: tab[{d}] name={s} root={} focused={}",
            .{ idx, tab.name, tab.root != null, tab.focused_pane_uuid != null },
        );
    }
    const session_json = reattach_result.session_snapshot.toJson(self.allocator) catch |err| {
        core.logging.logError("ses", "reattach snapshot serialization failed", err);
        ses.debugLog("completeReattach: snapshot toJson failed", .{});
        self.ses_state.releaseSessionLock(session_id);
        self.sendBinaryError(fd, "reattach_snapshot_failed");
        return;
    };
    defer self.allocator.free(session_json);
    ses.debugLog("completeReattach: session_json_len={d}", .{session_json.len});

    // Send SessionReattached: header + mux_state bytes + pane_count * 32 UUID bytes.
    var resp = wire.SessionReattached{
        .state_len = @intCast(session_json.len),
        .pane_count = @intCast(reattach_result.pane_uuids.len),
    };
    const uuid_data_len = reattach_result.pane_uuids.len * 32;
    const total_payload = @sizeOf(wire.SessionReattached) + session_json.len + uuid_data_len;

    var ctrl_hdr: wire.ControlHeader = .{
        .msg_type = @intFromEnum(wire.MsgType.session_reattached),
        .request_id = self.responseRequestIdForFd(fd),
        .payload_len = @intCast(total_payload),
    };
    ses.debugLog("completeReattach: writing response payload={d}", .{total_payload});
    wire.writeAll(fd, std.mem.asBytes(&ctrl_hdr)) catch |err| {
        core.logging.logError("ses", "reattach response header write failed", err);
        self.ses_state.releaseSessionLock(session_id);
        return;
    };
    wire.writeAll(fd, std.mem.asBytes(&resp)) catch |err| {
        core.logging.logError("ses", "reattach response body header write failed", err);
        self.ses_state.releaseSessionLock(session_id);
        return;
    };
    wire.writeAll(fd, session_json) catch |err| {
        core.logging.logError("ses", "reattach response session json write failed", err);
        self.ses_state.releaseSessionLock(session_id);
        return;
    };
    for (reattach_result.pane_uuids) |uuid| {
        wire.writeAll(fd, &uuid) catch |err| {
            core.logging.logError("ses", "reattach response pane uuid write failed", err);
            self.ses_state.releaseSessionLock(session_id);
            return;
        };
    }
    ses.debugLog("completeReattach: response sent", .{});
}

/// Returns false: the connection is consumed by the disconnect, so the
/// watcher must stop polling it.
pub fn handleBinaryDisconnect(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) bool {
    if (payload_len < @sizeOf(wire.Disconnect)) {
        self.skipBinaryPayload(fd, payload_len, buf);
        self.sendBinaryError(fd, "disconnect: payload too small");
        return true;
    }
    const dc = wire.readStructTimeout(wire.Disconnect, fd, server.HANDLER_IO_TIMEOUT_MS) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "disconnect request read failed", err);
        return false;
    };
    const client_id = self.findClientForCtlFd(fd) orelse {
        core.logging.warn("ses", "disconnect from unregistered fd={d}", .{fd});
        self.sendBinaryError(fd, "disconnect: client not registered");
        return true;
    };

    const reason = std.meta.intToEnum(wire.DisconnectReason, dc.reason) catch .unspecified;
    ses.debugLog("disconnect: client={d} mode={d} reason={s} preserve_sticky={}", .{
        client_id,
        dc.mode,
        @tagName(reason),
        dc.preserve_sticky != 0,
    });

    // Reply while the fd is still open: client removal below closes the
    // very connection this request arrived on, and a reply attempted
    // afterwards would fail and queue a second close of the same fd.
    self.replyOrClose(fd, .ok, &.{});

    // Purge server-side per-fd state (watchers, queues, pending pops)
    // before the state layer closes the fds.
    self.purgeClientFdState(client_id);

    if (dc.mode == @intFromEnum(wire.DisconnectMode.shutdown)) {
        self.ses_state.shutdownClient(client_id, dc.preserve_sticky != 0);
    } else {
        self.ses_state.removeClientGraceful(client_id);
    }
    return false;
}
