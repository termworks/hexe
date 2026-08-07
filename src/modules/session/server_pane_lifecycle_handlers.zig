//! Pane-lifecycle CTL handlers (create/find-sticky/orphan/adopt/kill/set-sticky/
//! get-cwd), extracted from server.zig (PLAN.md 2.3 god-object split). Pure
//! move: Server methods taking `*Server`, dispatched by name.
const std = @import("std");
const posix = std.posix;
const core = @import("core");
const wire = core.wire;
const ses = @import("main.zig");
const server = @import("server.zig");
const pane_spawn = @import("pane_spawn.zig");
const Server = server.Server;

const path_prepend_prefix = wire.path_prepend_env_key ++ "=";
const path_env_prefix = "PATH=";

/// Value of the last `HEXE_PATH_PREPEND=` marker in `entries`, if any.
fn findPathPrepend(entries: []const []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (entries) |entry| {
        if (std.mem.startsWith(u8, entry, path_prepend_prefix)) {
            found = entry[path_prepend_prefix.len..];
        }
    }
    return found;
}

fn stripPathPrependEntries(list: *std.ArrayList([]const u8)) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (std.mem.startsWith(u8, list.items[i], path_prepend_prefix)) {
            _ = list.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

/// The PATH that `add_path` extends: an explicit `add_env` PATH wins, then the
/// inherited parent environment, then SES's own.
fn basePathFor(entries: []const []const u8, parent_env: ?[]const []const u8) []const u8 {
    var i = entries.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.startsWith(u8, entries[i], path_env_prefix)) return entries[i][path_env_prefix.len..];
    }
    if (parent_env) |env| {
        var j = env.len;
        while (j > 0) {
            j -= 1;
            if (std.mem.startsWith(u8, env[j], path_env_prefix)) return env[j][path_env_prefix.len..];
        }
    }
    return posix.getenv("PATH") orelse "";
}

fn containsDir(dirs: []const []const u8, dir: []const u8) bool {
    for (dirs) |candidate| {
        if (std.mem.eql(u8, candidate, dir)) return true;
    }
    return false;
}

/// `add_path` dirs go to the FRONT, in the order they were declared, and a dir
/// already on `base` is moved there rather than duplicated — adding a path you
/// already have is a request to raise its priority, not a no-op. Base segments
/// otherwise keep their order (and their duplicates: rearranging PATH is the
/// job here, tidying someone else's is not).
fn buildPrependedPath(allocator: std.mem.Allocator, prepend: []const u8, base: []const u8) ![]u8 {
    var added: std.ArrayList([]const u8) = .empty;
    defer added.deinit(allocator);
    var prepend_it = std.mem.splitScalar(u8, prepend, ':');
    while (prepend_it.next()) |dir| {
        if (dir.len == 0) continue;
        if (containsDir(added.items, dir)) continue; // declared twice
        try added.append(allocator, dir);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, path_env_prefix);

    var wrote_any = false;
    for (added.items) |dir| {
        if (wrote_any) try out.append(allocator, ':');
        try out.appendSlice(allocator, dir);
        wrote_any = true;
    }
    if (base.len > 0) {
        var base_it = std.mem.splitScalar(u8, base, ':');
        while (base_it.next()) |segment| {
            if (containsDir(added.items, segment)) continue; // moved to the front
            if (wrote_any) try out.append(allocator, ':');
            try out.appendSlice(allocator, segment);
            wrote_any = true;
        }
    }
    if (!wrote_any) return error.EmptyPath;
    return out.toOwnedSlice(allocator);
}

pub fn handleBinaryCreatePane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.CreatePane)) {
        self.skipPayloadRest();
        self.sendBinaryError(fd, "create_pane: payload too small for CreatePane struct");
        return;
    }
    const cp = self.readPayloadStruct(wire.CreatePane) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "create_pane request read failed", err);
        self.sendBinaryError(fd, "create_pane: read failed");
        return;
    };
    const trail_len = payload_len - @sizeOf(wire.CreatePane);

    // Read trailing: shell + cwd + sticky_pwd.
    if (trail_len > buf.len) {
        self.skipPayloadRest();
        self.sendBinaryError(fd, "payload_too_large");
        return;
    }
    if (trail_len > 0) {
        self.readPayloadInto(buf[0..trail_len]) catch |err| {
            self.ctlStreamDesynced(fd, "mid-message read failed");
            core.logging.logError("ses", "create_pane trail read failed", err);
            self.sendBinaryError(fd, "create_pane: trail read failed");
            return;
        };
    }

    ses.debugLog("create_pane: shell_len={d} cwd_len={d} sticky_key={d} isolation_profile_len={d} env_count={d}", .{ cp.shell_len, cp.cwd_len, cp.sticky_key, cp.isolation_profile_len, cp.env_count });

    var offset: usize = 0;
    // Resolved once the session env is known — an unspecified shell must come
    // from the session, not from whatever SHELL the daemon was started under.
    const requested_shell: ?[]const u8 = if (cp.shell_len > 0) blk: {
        if (offset + cp.shell_len > trail_len) {
            self.sendBinaryError(fd, "create_pane: malformed shell trail");
            return;
        }
        const s = buf[offset .. offset + cp.shell_len];
        offset += cp.shell_len;
        break :blk s;
    } else null;
    const cwd: ?[]const u8 = if (cp.cwd_len > 0) blk: {
        if (offset + cp.cwd_len > trail_len) {
            self.sendBinaryError(fd, "create_pane: malformed cwd trail");
            return;
        }
        const c = buf[offset .. offset + cp.cwd_len];
        offset += cp.cwd_len;
        break :blk c;
    } else null;
    const sticky_pwd: ?[]const u8 = if (cp.sticky_pwd_len > 0) blk: {
        if (offset + cp.sticky_pwd_len > trail_len) {
            self.sendBinaryError(fd, "create_pane: malformed sticky pwd trail");
            return;
        }
        const p = buf[offset .. offset + cp.sticky_pwd_len];
        offset += cp.sticky_pwd_len;
        break :blk p;
    } else null;
    const isolation_profile: ?[]const u8 = if (cp.isolation_profile_len > 0) blk: {
        if (offset + cp.isolation_profile_len > trail_len) {
            self.sendBinaryError(fd, "create_pane: malformed isolation profile trail");
            return;
        }
        const p = buf[offset .. offset + cp.isolation_profile_len];
        offset += cp.isolation_profile_len;
        // Reject unknown profiles HERE, at the trust boundary (PLAN.md A-10).
        // SES forwarded these as raw trail bytes, and the consumer matched
        // names with std.mem.eql and fell through to a middle-strength default
        // for anything unrecognised — so "Sandbox" or "none " silently got
        // different isolation than the caller asked for. A security control
        // that quietly downgrades is worse than one that errors.
        if (core.isolation_voidbox.parseProfile(p) == null) {
            core.logging.warn("ses", "create_pane refused: unknown isolation profile '{s}'", .{p});
            self.sendBinaryError(fd, "unknown_isolation_profile");
            return;
        }
        break :blk p;
    } else null;
    const inherit_env_parent_uuid: ?[32]u8 = if (cp.inherit_env_parent_uuid_len > 0) blk: {
        if (cp.inherit_env_parent_uuid_len != 32 or offset + 32 > trail_len) {
            self.sendBinaryError(fd, "create_pane: malformed inherit-env parent uuid");
            return;
        }
        var uuid: [32]u8 = undefined;
        @memcpy(&uuid, buf[offset .. offset + 32]);
        offset += 32;
        break :blk uuid;
    } else null;
    const sticky_key: ?u8 = if (cp.sticky_key != 0) cp.sticky_key else null;

    var env_list: std.ArrayList([]const u8) = .empty;
    defer env_list.deinit(self.allocator);
    for (0..cp.env_count) |_| {
        if (offset + 2 > trail_len) {
            self.sendBinaryError(fd, "create_pane: malformed env entry header");
            return;
        }
        const entry_len = std.mem.readInt(u16, buf[offset..][0..2], .little);
        offset += 2;
        if (offset + entry_len > trail_len) {
            self.sendBinaryError(fd, "create_pane: malformed env entry body");
            return;
        }
        env_list.append(self.allocator, buf[offset .. offset + entry_len]) catch |err| {
            core.logging.logError("ses", "create_pane env list allocation failed", err);
            self.sendBinaryError(fd, "create_pane: env list alloc failed");
            return;
        };
        offset += entry_len;
    }
    if (offset != trail_len) {
        self.sendBinaryError(fd, "create_pane: trailing payload length mismatch");
        return;
    }

    // Resolve parent environment if inherit_env was requested.
    var parent_env: ?[]const []const u8 = null;
    defer if (parent_env) |env_entries| {
        for (env_entries) |e| self.allocator.free(e);
        self.allocator.free(env_entries);
    };
    if (inherit_env_parent_uuid) |parent_uuid| {
        if (self.ses_state.getPane(parent_uuid)) |parent_pane| {
            parent_env = parent_pane.getProcEnviron(self.allocator);
        }
    }

    const client_id = self.findClientForCtlFd(fd) orelse blk: {
        const cid = self.ses_state.addClient(fd) catch |err| {
            core.logging.logError("ses", "create_pane failed to add client", err);
            self.sendBinaryError(fd, "client_add_failed");
            return;
        };
        break :blk cid;
    };

    // The session's own environment, sent by its frontend at register. This is
    // what a pane inherits when it is not an `inherit_env` float; SES's environ
    // is only the last-resort fallback inside the spawn path.
    var session_env: ?[]const []const u8 = null;
    defer if (session_env) |entries| self.allocator.free(entries);
    if (self.ses_state.getClient(client_id)) |client| {
        if (client.session_env) |blob| {
            session_env = pane_spawn.parseSessionEnv(self.allocator, blob) catch |err| brk: {
                core.logging.logError("ses", "create_pane failed to parse session env", err);
                break :brk null;
            };
        }
    }

    const base_env: ?[]const []const u8 = parent_env orelse session_env;

    const shell = requested_shell orelse
        pane_spawn.lookupSessionEnv(base_env, "SHELL") orelse
        std.posix.getenv("SHELL") orelse
        "/bin/sh";

    // Resolve `add_path`: the frontend cannot compose PATH itself because the
    // base it must extend lives here (the parent pane's environ for
    // inherit_env, else the session's, else SES's own). Strip the markers
    // either way — they are transport, not something a pane's shell should see.
    var path_entry: ?[]u8 = null;
    defer if (path_entry) |p| self.allocator.free(p);
    if (findPathPrepend(env_list.items)) |prepend| {
        stripPathPrependEntries(&env_list);
        const base = basePathFor(env_list.items, base_env);
        if (buildPrependedPath(self.allocator, prepend, base)) |composed| {
            path_entry = composed;
            env_list.append(self.allocator, composed) catch |err| {
                core.logging.logError("ses", "create_pane PATH prepend append failed", err);
                self.sendBinaryError(fd, "create_pane: env list alloc failed");
                return;
            };
        } else |err| {
            core.logging.logError("ses", "create_pane PATH prepend build failed", err);
        }
    }

    // Stamp the pane with the session it belongs to. Inherited, this named
    // whichever session the shell that started the daemon was in.
    var session_env_entry: ?[]u8 = null;
    defer if (session_env_entry) |e| self.allocator.free(e);
    if (self.ses_state.getClient(client_id)) |client| {
        if (client.session_id) |sid| {
            const hex: [32]u8 = std.fmt.bytesToHex(&sid, .lower);
            if (std.fmt.allocPrint(self.allocator, "HEXE_SESSION={s}", .{hex})) |entry| {
                session_env_entry = entry;
                env_list.append(self.allocator, entry) catch |err| {
                    core.logging.logError("ses", "create_pane HEXE_SESSION append failed", err);
                };
            } else |err| {
                core.logging.logError("ses", "create_pane HEXE_SESSION build failed", err);
            }
        }
    }

    // The frontend sets this on itself after exec, so it is absent from the
    // environ SES captured. Shell integration keys off it to decide whether it
    // is talking to a mux at all, so state it here instead of relying on the
    // daemon having inherited it.
    env_list.append(self.allocator, "HEXE_MUX_SOCKET=1") catch |err| {
        core.logging.logError("ses", "create_pane HEXE_MUX_SOCKET append failed", err);
    };

    const spawn_env: ?[]const []const u8 = if (env_list.items.len > 0) env_list.items else null;

    // Sticky/per-cwd pane reuse: if a matching sticky pane already exists,
    // attach/take over it instead of spawning a new pod.
    if (sticky_pwd) |pwd| {
        if (sticky_key) |key| {
            const preferred_session = if (self.ses_state.getClient(client_id)) |client|
                client.session_name
            else
                null;

            if (self.ses_state.findStickyPaneWithAffinity(pwd, key, preferred_session)) |existing| {
                if (existing.state == .detached or self.ses_state.isPaneParked(existing)) {
                    self.ses_state.removePaneFromDetachedSessions(existing.uuid);
                }
                if (existing.attached_to) |owner_id| {
                    if (owner_id != client_id) {
                        _ = self.ses_state.stealAttachedPane(existing.uuid, client_id);
                        _ = self.ses_state.attachPane(existing.uuid, client_id) catch |err| {
                            core.logging.logError("ses", "create_pane failed to attach stolen sticky pane", err);
                            self.sendBinaryError(fd, "attach_existing_failed");
                            return;
                        };
                    }
                } else {
                    _ = self.ses_state.attachPane(existing.uuid, client_id) catch |err| {
                        core.logging.logError("ses", "create_pane failed to attach sticky pane", err);
                        self.sendBinaryError(fd, "attach_existing_failed");
                        return;
                    };
                }

                // Force backlog replay for fresh renderer state in the new mux.
                if (self.ses_state.getPane(existing.uuid)) |p| {
                    p.requestBacklogReplay();
                }
                replayPaneBacklogNow(self, existing.uuid);

                self.ses_state.markDirty();
                var existing_resp = wire.PaneCreated{
                    .uuid = existing.uuid,
                    .pid = existing.child_pid,
                    .pane_id = existing.pane_id,
                    .socket_path_len = @intCast(existing.pod_socket_path.len),
                };
                self.replyOrCloseWithTrail(fd, .pane_created, std.mem.asBytes(&existing_resp), existing.pod_socket_path);
                return;
            }
        }
    }

    // Enforce the per-session pane cap. `allowNewPane` existed with no call
    // site at all, so `max_panes_per_session` (and HEXE_MAX_PANES_PER_SESSION)
    // did nothing: any same-uid peer could drive pane creation until the
    // machine ran out of pids or fds. Every create_pane arrives on one
    // already-established connection, so the connection rate limiter never
    // applied here either.
    const session_pane_count = if (self.ses_state.getClient(client_id)) |client|
        client.pane_uuids.items.len
    else
        0;
    if (!self.resource_monitor.allowNewPane(session_pane_count)) {
        core.logging.warn("ses", "create_pane refused: session already has {d} panes (cap reached)", .{session_pane_count});
        self.sendBinaryError(fd, "pane_limit_reached: session pane cap exceeded");
        return;
    }

    // Fork the pod, but do NOT wait for its handshake here: that wait was a
    // blocking read on the single-threaded loop, so one slow pod stalled every
    // other session (PLAN.md 1.1). The reply is deferred to the tick that sees
    // the handshake land, which keeps spawn-FAILURE reporting intact — the
    // client still learns the outcome on this request, just a tick later.
    const flight = self.ses_state.beginCreatePane(client_id, shell, cwd, sticky_pwd, sticky_key, base_env, spawn_env, isolation_profile) catch |err| {
        core.logging.logError("ses", "create_pane failed to spawn pane", err);
        self.sendBinaryError(fd, "create_failed");
        return;
    };
    self.trackPendingSpawn(flight, fd) catch |err| {
        core.logging.logError("ses", "create_pane failed to track pending spawn", err);
        var doomed = flight;
        self.ses_state.abortCreatePane(&doomed);
        self.sendBinaryError(fd, "create_failed");
        return;
    };
}

pub fn replayPaneBacklogNow(self: *Server, uuid: [32]u8) void {
    const pane = self.ses_state.getPane(uuid) orelse return;
    const owner_id = pane.attached_to orelse {
        pane.requestBacklogReplay();
        return;
    };
    const owner = self.ses_state.getClient(owner_id) orelse {
        pane.requestBacklogReplay();
        return;
    };
    if (owner.mux_vt_fd == null) {
        pane.requestBacklogReplay();
        return;
    }

    const pane_id = pane.pane_id;
    const pod_socket_path = pane.pod_socket_path;
    if (self.ses_state.connectPodVt(uuid, pod_socket_path, pane_id)) {
        if (self.ses_state.getPane(uuid)) |updated| {
            updated.needs_backlog_replay = false;
        }
    } else if (self.ses_state.getPane(uuid)) |updated| {
        updated.requestBacklogReplay();
    }
}

pub fn handleBinaryFindSticky(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.FindSticky)) {
        self.skipPayloadRest();
        self.sendBinaryError(fd, "find_sticky: payload too small");
        return;
    }
    const fs = self.readPayloadStruct(wire.FindSticky) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "find_sticky request read failed", err);
        self.sendBinaryError(fd, "find_sticky: read failed");
        return;
    };
    if (fs.pwd_len > buf.len) {
        self.skipPayloadRest();
        self.sendBinaryError(fd, "find_sticky: pwd too large");
        return;
    }
    if (fs.pwd_len > 0) {
        self.readPayloadInto(buf[0..fs.pwd_len]) catch |err| {
            self.ctlStreamDesynced(fd, "mid-message read failed");
            core.logging.logError("ses", "find_sticky pwd read failed", err);
            self.sendBinaryError(fd, "find_sticky: pwd read failed");
            return;
        };
    }
    const pwd = buf[0..fs.pwd_len];

    const client_id = self.findClientForCtlFd(fd) orelse {
        self.replyOrClose(fd, .pane_not_found, &.{});
        return;
    };

    // Get session name for affinity preference
    const preferred_session = if (self.ses_state.getClient(client_id)) |client|
        client.session_name
    else
        null;

    if (self.ses_state.findStickyPaneWithAffinity(pwd, fs.key, preferred_session)) |pane| {
        var already_attached_to_client = false;
        if (pane.attached_to) |owner_id| {
            already_attached_to_client = owner_id == client_id;
        }

        if (fs.claim_free != 0 and !already_attached_to_client) {
            // Claim-free lookups (startup/reattach reconciliation) must
            // never steal: refuse panes owned by another live client and
            // panes parked inside a detached session's adoptable set. The
            // explicit toggle handoff path uses claim_free=0 instead.
            if (pane.attached_to) |owner_id| {
                if (self.ses_state.getClient(owner_id) != null) {
                    ses.debugLog("find_sticky: claim_free refused, uuid={s} owned by live client {d}", .{ pane.uuid[0..8], owner_id });
                    self.replyOrClose(fd, .pane_not_found, &.{});
                    return;
                }
            }
            if (self.ses_state.isPaneParked(pane)) {
                ses.debugLog("find_sticky: claim_free refused, uuid={s} parked in detached session", .{pane.uuid[0..8]});
                self.replyOrClose(fd, .pane_not_found, &.{});
                return;
            }
        }

        if (pane.state == .detached or self.ses_state.isPaneParked(pane)) {
            self.ses_state.removePaneFromDetachedSessions(pane.uuid);
        }
        if (!already_attached_to_client) {
            if (pane.attached_to) |owner_id| {
                if (owner_id != client_id) {
                    _ = self.ses_state.stealAttachedPane(pane.uuid, client_id);
                }
            }
        }

        if (!already_attached_to_client) {
            _ = self.ses_state.attachPane(pane.uuid, client_id) catch |err| {
                core.logging.logError("ses", "find_sticky failed to attach sticky pane", err);
                self.replyOrClose(fd, .pane_not_found, &.{});
                return;
            };
        }

        // New mux needs a full screen restore for sticky adoption/takeover.
        // Try the VT replay immediately so cross-session CWD-float handoff
        // feels instant; keep needs_backlog_replay set if the mux VT/pod VT
        // endpoint is not ready yet so the periodic worker can retry.
        if (self.ses_state.getPane(pane.uuid)) |p| {
            p.requestBacklogReplay();
        }
        replayPaneBacklogNow(self, pane.uuid);
        ses.debugLog("find_sticky: requested immediate backlog replay for uuid={s}", .{pane.uuid[0..8]});

        var resp = wire.PaneFound{
            .uuid = pane.uuid,
            .pid = pane.child_pid,
            .pane_id = pane.pane_id,
            .socket_path_len = @intCast(pane.pod_socket_path.len),
        };
        self.replyOrCloseWithTrail(fd, .pane_found, std.mem.asBytes(&resp), pane.pod_socket_path);
    } else {
        self.replyOrClose(fd, .pane_not_found, &.{});
    }
}

pub fn handleBinaryOrphanPane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    _ = buf;
    if (payload_len < @sizeOf(wire.PaneUuid)) {
        self.skipPayloadRest();
        self.sendBinaryError(fd, "orphan_pane: payload too small for PaneUuid");
        return;
    }
    const pu = self.readPayloadStruct(wire.PaneUuid) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "orphan_pane request read failed", err);
        self.sendBinaryError(fd, "orphan_pane: read failed");
        return;
    };
    if (!requesterMayReleasePane(self, pu.uuid, self.findClientForCtlFd(fd), "orphan_pane")) {
        self.sendBinaryError(fd, "orphan_pane: pane owned by another client");
        return;
    }
    self.ses_state.suspendPane(pu.uuid) catch |e| {
        ses.debugLog("handleBinaryOrphanPane: suspendPane error: {s}", .{@errorName(e)});
        self.sendBinaryError(fd, "orphan_pane: pane not found");
        return;
    };
    self.ses_state.markDirty();
    self.replyOrClose(fd, .ok, &.{});
}

/// A client may kill/orphan a pane it owns, or one that nobody living
/// owns. It must never release a pane attached to another live client:
/// steal notifications are best-effort, so a mux can hold a stale view of
/// a float that has since moved to a different mux — acting on that stale
/// view would destroy the new owner's pane mid-use.
pub fn requesterMayReleasePane(self: *Server, uuid: [32]u8, requester: ?usize, comptime op: []const u8) bool {
    const pane = self.ses_state.store.panes.getPtr(uuid) orelse return true;
    const owner_id = pane.attached_to orelse return true;
    if (requester) |cid| {
        if (owner_id == cid) return true;
    }
    if (self.ses_state.getClient(owner_id) == null) return true;
    core.logging.warnWithSource(
        "ses",
        op ++ ": refused, pane {s} attached to live client {d} (requester {?d})",
        .{ uuid[0..8], owner_id, requester },
        @src(),
    );
    return false;
}

pub fn handleBinaryAdoptPane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    _ = buf;
    if (payload_len < @sizeOf(wire.PaneUuid)) {
        self.skipPayloadRest();
        self.sendBinaryError(fd, "adopt_pane: payload too small for PaneUuid");
        return;
    }
    const pu = self.readPayloadStruct(wire.PaneUuid) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "adopt_pane request read failed", err);
        self.sendBinaryError(fd, "adopt_pane: read failed");
        return;
    };

    const client_id = self.findClientForCtlFd(fd) orelse {
        self.sendBinaryError(fd, "adopt_pane: client not registered");
        return;
    };

    const pane = self.ses_state.attachPane(pu.uuid, client_id) catch |err| {
        core.logging.logError("ses", "adopt_pane failed to attach pane", err);
        self.sendBinaryError(fd, "adopt_pane: pane not found or already attached");
        return;
    };

    // Adopt into a fresh mux view: request a screen restore, but do not
    // run replay inline. Reconnecting POD VT sockets from the CTL handler
    // can stall attach/reattach; the periodic replay worker will pick this
    // up once the mux VT channel is ready.
    pane.requestBacklogReplay();
    ses.debugLog("adopt_pane: queued deferred backlog replay for uuid={s}", .{pu.uuid[0..8]});

    self.ses_state.markDirty();

    var resp = wire.PaneFound{
        .uuid = pane.uuid,
        .pid = pane.child_pid,
        .pane_id = pane.pane_id,
        .socket_path_len = @intCast(pane.pod_socket_path.len),
    };
    self.replyOrCloseWithTrail(fd, .pane_found, std.mem.asBytes(&resp), pane.pod_socket_path);
}

pub fn handleBinaryKillPane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    _ = buf;
    if (payload_len < @sizeOf(wire.PaneUuid)) {
        self.skipPayloadRest();
        self.sendBinaryError(fd, "kill_pane: payload too small for PaneUuid");
        return;
    }
    const pu = self.readPayloadStruct(wire.PaneUuid) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "kill_pane request read failed", err);
        self.sendBinaryError(fd, "kill_pane: read failed");
        return;
    };
    const client_id = self.findClientForCtlFd(fd);
    const hex_uuid: [32]u8 = std.fmt.bytesToHex(pu.uuid[0..16], .lower);
    ses.debugLog("handleBinaryKillPane: uuid={s} ctl_fd={d}", .{ hex_uuid[0..8], fd });
    if (!requesterMayReleasePane(self, pu.uuid, client_id, "kill_pane")) {
        self.sendBinaryError(fd, "kill_pane: pane owned by another client");
        return;
    }
    self.ses_state.killPane(pu.uuid) catch |e| {
        ses.debugLog("handleBinaryKillPane: killPane error: {s}", .{@errorName(e)});
        self.sendBinaryError(fd, "kill_pane: pane not found");
        return;
    };
    self.ses_state.markDirty();
    if (client_id) |cid| {
        self.pushClientSessionSnapshot(cid);
    }
    ses.debugLog("handleBinaryKillPane: sending .ok response", .{});
    self.replyOrClose(fd, .ok, &.{});
    ses.debugLog("handleBinaryKillPane: done", .{});
}

pub fn handleBinarySetSticky(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    if (payload_len < @sizeOf(wire.SetSticky)) {
        self.skipPayloadRest();
        self.sendBinaryError(fd, "set_sticky: payload too small");
        return;
    }
    const ss = self.readPayloadStruct(wire.SetSticky) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "set_sticky request read failed", err);
        self.sendBinaryError(fd, "set_sticky: read failed");
        return;
    };
    if (ss.pwd_len > buf.len) {
        self.skipPayloadRest();
        self.sendBinaryError(fd, "set_sticky: pwd too large");
        return;
    }
    if (ss.pwd_len > 0) {
        self.readPayloadInto(buf[0..ss.pwd_len]) catch |err| {
            self.ctlStreamDesynced(fd, "mid-message read failed");
            core.logging.logError("ses", "set_sticky pwd read failed", err);
            self.sendBinaryError(fd, "set_sticky: pwd read failed");
            return;
        };
    }

    if (self.ses_state.store.panes.getPtr(ss.uuid)) |pane| {
        const new_sticky_pwd = if (ss.pwd_len > 0)
            self.allocator.dupe(u8, buf[0..ss.pwd_len]) catch |err| {
                core.logging.logError("ses", "failed to store sticky pane cwd", err);
                self.sendBinaryError(fd, "set_sticky: cwd allocation failed");
                return;
            }
        else
            null;

        // Store session name for affinity
        const client_id = self.findClientForCtlFd(fd) orelse null;
        const new_sticky_session_name = if (client_id) |cid| blk: {
            if (self.ses_state.getClient(cid)) |client| {
                if (client.session_name) |sn| {
                    break :blk self.allocator.dupe(u8, sn) catch |err| {
                        core.logging.logError("ses", "failed to store sticky pane session name", err);
                        if (new_sticky_pwd) |owned| self.allocator.free(owned);
                        self.sendBinaryError(fd, "set_sticky: session name allocation failed");
                        return;
                    };
                }
            }
            break :blk null;
        } else null;

        // Apply the identity atomically, only after every allocation
        // succeeded: mutating sticky_key before a failable alloc could
        // leave a new-key/old-pwd hybrid that matches neither identity,
        // making the float unreachable by key.
        if (pane.sticky_pwd) |old| self.allocator.free(old);
        if (pane.sticky_session_name) |old_ssn| self.allocator.free(old_ssn);
        pane.sticky_key = if (ss.key != 0) ss.key else null;
        pane.sticky_pwd = new_sticky_pwd;
        pane.sticky_session_name = new_sticky_session_name;

        // set_sticky sets sticky metadata, but must not force attached panes
        // into sticky state. Sticky state is entered on suspend/disown.
        if (pane.sticky_pwd != null and pane.attached_to == null) {
            _ = pane.transitionState(.sticky, "set_sticky command");
        }
        self.ses_state.markDirty();
    }
    self.replyOrClose(fd, .ok, &.{});
}

pub fn handleBinaryGetPaneCwd(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
    _ = buf;
    if (payload_len < @sizeOf(wire.GetPaneCwd)) {
        self.skipPayloadRest();
        self.sendBinaryError(fd, "get_pane_cwd: payload too small");
        return;
    }
    const gpc = self.readPayloadStruct(wire.GetPaneCwd) catch |err| {
        self.ctlStreamDesynced(fd, "mid-message read failed");
        core.logging.logError("ses", "get_pane_cwd request read failed", err);
        self.sendBinaryError(fd, "get_pane_cwd: read failed");
        return;
    };

    if (self.ses_state.getPane(gpc.uuid)) |pane| {
        const cwd = pane.getProcCwd();
        if (cwd) |c| {
            var resp = wire.PaneCwd{ .uuid = gpc.uuid, .cwd_len = @intCast(c.len) };
            self.replyOrCloseWithTrail(fd, .get_pane_cwd, std.mem.asBytes(&resp), c);
            return;
        }
    }
    // No CWD available.
    var resp = wire.PaneCwd{ .uuid = gpc.uuid, .cwd_len = 0 };
    self.replyOrClose(fd, .get_pane_cwd, std.mem.asBytes(&resp));
}

test "add_path prepends dirs ahead of the inherited PATH" {
    const alloc = std.testing.allocator;
    const entries = [_][]const u8{ path_prepend_prefix ++ "/opt/bin:/opt/other", "EDITOR=hx" };
    const parent = [_][]const u8{ "PATH=/usr/bin:/bin", "HOME=/home/me" };

    const prepend = findPathPrepend(&entries) orelse return error.TestUnexpectedResult;
    const base = basePathFor(&entries, &parent);
    const composed = try buildPrependedPath(alloc, prepend, base);
    defer alloc.free(composed);

    try std.testing.expectEqualStrings("PATH=/opt/bin:/opt/other:/usr/bin:/bin", composed);
}

test "add_path extends an add_env PATH, keeping declaration order" {
    const alloc = std.testing.allocator;
    const entries = [_][]const u8{ "PATH=/custom/bin", path_prepend_prefix ++ "/custom/bin:/extra/bin" };
    const composed = try buildPrependedPath(
        alloc,
        findPathPrepend(&entries) orelse return error.TestUnexpectedResult,
        basePathFor(&entries, null),
    );
    defer alloc.free(composed);

    try std.testing.expectEqualStrings("PATH=/custom/bin:/extra/bin", composed);
}

test "add_path promotes a dir already on PATH instead of leaving it where it was" {
    const alloc = std.testing.allocator;
    const composed = try buildPrependedPath(alloc, "/usr/local/bin", "/usr/bin:/usr/local/bin:/bin");
    defer alloc.free(composed);

    // Not a no-op: the dir the user asked for is now searched first.
    try std.testing.expectEqualStrings("PATH=/usr/local/bin:/usr/bin:/bin", composed);
}

test "add_path collapses every copy of a promoted dir, and dedupes its own list" {
    const alloc = std.testing.allocator;
    const composed = try buildPrependedPath(
        alloc,
        "/home/me/.local/bin:/opt/bin:/home/me/.local/bin",
        "/home/me/.local/bin:/usr/bin:/home/me/.local/bin:/bin",
    );
    defer alloc.free(composed);

    try std.testing.expectEqualStrings("PATH=/home/me/.local/bin:/opt/bin:/usr/bin:/bin", composed);
}

test "path prepend markers are stripped from the spawned environment" {
    const alloc = std.testing.allocator;
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(alloc);
    try list.append(alloc, "FOO=bar");
    try list.append(alloc, path_prepend_prefix ++ "/opt/bin");
    try list.append(alloc, "BAZ=qux");

    stripPathPrependEntries(&list);

    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("FOO=bar", list.items[0]);
    try std.testing.expectEqualStrings("BAZ=qux", list.items[1]);
}
