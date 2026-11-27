//! `hexe terminal wait` — block until a pane exits, goes idle, matches a
//! pattern, or reaches a lifecycle status (`done`, `blocked`, `attention`, ...).
//!
//! Uses event-driven I/O (`poll(2)` on the pod's observer stream for `exit`,
//! `idle`, and `pattern`, or `poll(2)` on the session control socket's event
//! subscription for status conditions) rather than busy-spinning.
//!
//! Exit codes:
//!   0   — condition met
//!   1   — invalid arguments
//!   2   — target pane / session unreachable or disappeared unexpectedly
//!   124 — timed out (`--timeout` exceeded)

const std = @import("std");
const posix = std.posix;
const core = @import("core");
const com = @import("com.zig");
const api_cmd = @import("api.zig");
const shared = @import("shared.zig");
const cli_ui = core.cli_ui;

pub const WaitCondition = union(enum) {
    exit,
    idle,
    done,
    blocked,
    attention,
    status: core.pane_status.Status,
    pattern: []const u8,
};

pub const WaitArgs = struct {
    target: shared.PaneTarget = .{},
    until: []const u8 = "",
    pattern: []const u8 = "",
    lines: u32 = 40,
    idle_ms: u64 = 1500,
    timeout_ms: u64 = 0,
    interval_ms: u64 = 100,
    print_output: bool = false,
    json: bool = false,
};

pub const WaitResult = struct {
    matched: bool = true,
    reason: []const u8,
    status: ?[]const u8 = null,
    note: ?[]const u8 = null,
    elapsed_ms: i64 = 0,
    exited: bool = false,
};

pub fn parseCondition(until: []const u8, pattern: []const u8) !WaitCondition {
    if (until.len > 0 and pattern.len > 0) {
        return error.ConflictingConditions;
    }
    if (pattern.len > 0) {
        return .{ .pattern = pattern };
    }
    if (until.len == 0 or std.ascii.eqlIgnoreCase(until, "exit")) {
        return .exit;
    }
    if (std.ascii.eqlIgnoreCase(until, "idle")) return .idle;
    if (std.ascii.eqlIgnoreCase(until, "done")) return .done;
    if (std.ascii.eqlIgnoreCase(until, "blocked")) return .blocked;
    if (std.ascii.eqlIgnoreCase(until, "attention")) return .attention;
    if (std.mem.startsWith(u8, until, "status:")) {
        const raw = until["status:".len..];
        const st = core.pane_status.Status.fromString(raw) orelse return error.InvalidCondition;
        return .{ .status = st };
    }
    if (std.mem.startsWith(u8, until, "pattern:")) {
        const pat = until["pattern:".len..];
        if (pat.len == 0) return error.InvalidCondition;
        return .{ .pattern = pat };
    }
    return error.InvalidCondition;
}

fn remainingTimeoutMs(deadline_ms: ?i64, now_ms: i64) ?i32 {
    const dl = deadline_ms orelse return null;
    const rem = dl - now_ms;
    if (rem <= 0) return 0;
    return @intCast(@min(rem, std.math.maxInt(i32)));
}

fn minPositiveTimeout(a: ?i32, b: ?i32) i32 {
    if (a) |va| {
        if (b) |vb| return @min(va, vb);
        return va;
    }
    return b orelse -1;
}

/// Non-blocking framed reader for `pod_protocol` frames (5-byte header + payload).
const PodFrameReader = struct {
    hdr: [5]u8 = undefined,
    hdr_got: usize = 0,
    payload_rem: usize = 0,
    frame_type: u8 = 0,

    const Step = enum {
        need_more,
        eof,
        output_frame,
        backlog_end,
        other_frame,
    };

    const DrainResult = struct {
        eof: bool = false,
        saw_output: bool = false,
        saw_backlog_end: bool = false,
    };

    fn drainNonBlocking(self: *PodFrameReader, fd: posix.fd_t) !DrainResult {
        var res = DrainResult{};
        var discard_buf: [8192]u8 = undefined;

        while (true) {
            if (self.payload_rem > 0) {
                const want = @min(self.payload_rem, discard_buf.len);
                const n = posix.read(fd, discard_buf[0..want]) catch |err| switch (err) {
                    error.WouldBlock => return res,
                    else => return err,
                };
                if (n == 0) {
                    res.eof = true;
                    return res;
                }
                self.payload_rem -= n;
                continue;
            }

            const n = posix.read(fd, self.hdr[self.hdr_got..]) catch |err| switch (err) {
                error.WouldBlock => return res,
                else => return err,
            };
            if (n == 0) {
                res.eof = true;
                return res;
            }
            self.hdr_got += n;
            if (self.hdr_got < 5) continue;

            self.frame_type = self.hdr[0];
            self.payload_rem = std.mem.readInt(u32, self.hdr[1..5], .big);
            self.hdr_got = 0;

            if (self.frame_type == @intFromEnum(core.pod_protocol.FrameType.output)) {
                res.saw_output = true;
            } else if (self.frame_type == @intFromEnum(core.pod_protocol.FrameType.backlog_end)) {
                res.saw_backlog_end = true;
            }
        }
    }
};

fn connectPodObserver(allocator: std.mem.Allocator, uuid: [32]u8) !core.ipc.Client {
    const socket_path = try core.ipc.getPodSocketPath(allocator, &uuid);
    defer allocator.free(socket_path);

    var client = core.ipc.Client.connect(socket_path) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) return error.PodNotRunning;
        return err;
    };
    errdefer client.close();

    try core.wire.sendHandshake(client.fd, core.wire.POD_HANDSHAKE_AUX_OBSERVER);
    try core.ipc.setNonBlocking(client.fd);
    return client;
}

fn waitForPodCondition(
    allocator: std.mem.Allocator,
    uuid: [32]u8,
    cond: WaitCondition,
    args: WaitArgs,
    start_ms: i64,
    deadline_ms: ?i64,
) !?WaitResult {
    // Pattern check up front so an already-present line returns immediately.
    if (cond == .pattern) {
        if (shared.readPod(allocator, uuid, .lines, args.lines)) |got| {
            defer allocator.free(got.text);
            if (std.mem.indexOf(u8, got.text, cond.pattern) != null) {
                return .{
                    .reason = "pattern",
                    .elapsed_ms = std.time.milliTimestamp() - start_ms,
                };
            }
        } else |err| switch (err) {
            error.PodNotRunning => return error.PodNotRunning,
            else => {},
        }
    }

    var client = connectPodObserver(allocator, uuid) catch |err| {
        if (err == error.PodNotRunning and cond == .exit) {
            return .{
                .reason = "exit",
                .elapsed_ms = std.time.milliTimestamp() - start_ms,
                .exited = true,
            };
        }
        return err;
    };
    defer client.close();

    var reader = PodFrameReader{};
    var backlog_done = false;
    var last_activity_ms: i64 = std.time.milliTimestamp();
    var last_pattern_check_ms: i64 = start_ms;
    var dirty_for_pattern = false;

    while (true) {
        const now_ms = std.time.milliTimestamp();
        if (deadline_ms) |dl| {
            if (now_ms >= dl) return null; // timed out
        }

        if (cond == .idle and backlog_done) {
            if (now_ms - last_activity_ms >= @as(i64, @intCast(args.idle_ms))) {
                return .{
                    .reason = "idle",
                    .elapsed_ms = now_ms - start_ms,
                };
            }
        }

        if (cond == .pattern and dirty_for_pattern and
            (now_ms - last_pattern_check_ms >= @as(i64, @intCast(args.interval_ms))))
        {
            dirty_for_pattern = false;
            last_pattern_check_ms = now_ms;
            if (shared.readPod(allocator, uuid, .lines, args.lines)) |got| {
                defer allocator.free(got.text);
                if (std.mem.indexOf(u8, got.text, cond.pattern) != null) {
                    return .{
                        .reason = "pattern",
                        .elapsed_ms = std.time.milliTimestamp() - start_ms,
                    };
                }
            } else |_| {}
        }

        const dl_rem = remainingTimeoutMs(deadline_ms, now_ms);
        var wake_ms: ?i32 = null;
        if (cond == .idle and backlog_done) {
            const idle_rem = @as(i64, @intCast(args.idle_ms)) - (now_ms - last_activity_ms);
            wake_ms = @intCast(@max(idle_rem, 1));
        } else if (cond == .pattern and dirty_for_pattern) {
            const int_rem = @as(i64, @intCast(args.interval_ms)) - (now_ms - last_pattern_check_ms);
            wake_ms = @intCast(@max(int_rem, 1));
        } else if (cond == .idle and !backlog_done) {
            // Safety fallback in case a pod omits backlog_end or takes a moment.
            wake_ms = 250;
        }

        var pfds = [_]posix.pollfd{.{
            .fd = client.fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const poll_ms = minPositiveTimeout(dl_rem, wake_ms);
        const rc = try posix.poll(&pfds, poll_ms);

        if (rc == 0) {
            if (cond == .idle and !backlog_done and (std.time.milliTimestamp() - last_activity_ms) >= 250) {
                backlog_done = true;
            }
            continue;
        }

        if ((pfds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            const step = reader.drainNonBlocking(client.fd) catch {
                if (cond == .exit) {
                    return .{
                        .reason = "exit",
                        .elapsed_ms = std.time.milliTimestamp() - start_ms,
                        .exited = true,
                    };
                }
                return error.PodNotRunning;
            };
            if (step.saw_backlog_end) {
                backlog_done = true;
                last_activity_ms = std.time.milliTimestamp();
            }
            if (step.saw_output) {
                if (backlog_done) {
                    last_activity_ms = std.time.milliTimestamp();
                }
                dirty_for_pattern = true;
            }
            if (step.eof) {
                if (cond == .exit) {
                    return .{
                        .reason = "exit",
                        .elapsed_ms = std.time.milliTimestamp() - start_ms,
                        .exited = true,
                    };
                }
                // Check pattern one last time before reporting pod exit.
                if (cond == .pattern) {
                    if (shared.readPod(allocator, uuid, .lines, args.lines)) |got| {
                        defer allocator.free(got.text);
                        if (std.mem.indexOf(u8, got.text, cond.pattern) != null) {
                            return .{
                                .reason = "pattern",
                                .elapsed_ms = std.time.milliTimestamp() - start_ms,
                                .exited = true,
                            };
                        }
                    } else |_| {}
                }
                return error.PodNotRunning;
            }
        }
    }
}

fn statusMatchesCondition(cond: WaitCondition, st_str: []const u8, attention: bool) bool {
    const st = core.pane_status.Status.fromString(st_str) orelse return false;
    return switch (cond) {
        .done => st == .done,
        .blocked => st == .blocked,
        .attention => attention or st.needsAttention(),
        .status => |want| st == want,
        else => false,
    };
}

fn readFramedJsonWithPoll(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    deadline_ms: ?i64,
) !?[]u8 {
    var hdr: [4]u8 = undefined;
    var got: usize = 0;
    while (got < 4) {
        const now_ms = std.time.milliTimestamp();
        const rem = remainingTimeoutMs(deadline_ms, now_ms);
        if (rem != null and rem.? == 0) return null;

        var pfds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        const rc = try posix.poll(&pfds, rem orelse -1);
        if (rc == 0) return null;
        const n = posix.read(fd, hdr[got..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.UnexpectedEof;
        got += n;
    }

    const len = std.mem.readInt(u32, &hdr, .big);
    if (len > 4 * 1024 * 1024) return error.StreamTooLong;

    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    got = 0;
    while (got < len) {
        const now_ms = std.time.milliTimestamp();
        const rem = remainingTimeoutMs(deadline_ms, now_ms);
        if (rem != null and rem.? == 0) {
            allocator.free(buf);
            return null;
        }
        var pfds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        const rc = try posix.poll(&pfds, rem orelse -1);
        if (rc == 0) {
            allocator.free(buf);
            return null;
        }
        const n = posix.read(fd, buf[got..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.UnexpectedEof;
        got += n;
    }
    return buf;
}

fn waitForStatusCondition(
    allocator: std.mem.Allocator,
    uuid: [32]u8,
    session_opt: ?[]const u8,
    cond: WaitCondition,
    start_ms: i64,
    deadline_ms: ?i64,
) !?struct { result: WaitResult, owned_status: ?[]u8 = null, owned_note: ?[]u8 = null } {
    const endpoint = try api_cmd.resolveEndpointForPane(allocator, session_opt, &uuid);
    defer endpoint.deinit(allocator);

    // 1. Subscribe FIRST so no status transition can slip between the initial
    //    snapshot query and subscription activation (eliminates TOCTOU race).
    const stream = try std.net.connectUnixSocket(endpoint.path);
    defer stream.close();
    const sub_body = "{\"subscribe\":[\"pane_status_changed\",\"pane_exited\"]}";
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, @intCast(sub_body.len), .big);
    try stream.writeAll(&hdr);
    try stream.writeAll(sub_body);

    // Read subscribe ack.
    const ack = (try readFramedJsonWithPoll(allocator, stream.handle, deadline_ms)) orelse return null;
    defer allocator.free(ack);
    if (std.mem.startsWith(u8, ack, "{\"ok\":false")) return error.SubscribeRefused;

    // 2. Check current status after subscribing so we never miss a transition
    //    that occurred before or during connect/subscribe.
    var req_buf: [128]u8 = undefined;
    const check_req = try std.fmt.bufPrint(&req_buf, "{{\"call\":\"status\",\"args\":[\"{s}\"]}}", .{uuid[0..]});
    const initial_reply = try api_cmd.request(allocator, endpoint.label, endpoint.path, check_req, false);
    defer allocator.free(initial_reply);

    {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, initial_reply, .{}) catch return error.InvalidReply;
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("result")) |res| {
                const first = if (res == .array and res.array.items.len > 0) res.array.items[0] else res;
                if (first == .null) return error.PodNotRunning;
                if (first == .object) {
                    const st_str = if (first.object.get("status")) |v| (if (v == .string) v.string else "idle") else "idle";
                    const att = if (first.object.get("attention")) |v| (if (v == .bool) v.bool else false) else false;
                    if (statusMatchesCondition(cond, st_str, att)) {
                        const owned_st = try allocator.dupe(u8, st_str);
                        errdefer allocator.free(owned_st);
                        const owned_note: ?[]u8 = if (first.object.get("note")) |nv|
                            (if (nv == .string) try allocator.dupe(u8, nv.string) else null)
                        else
                            null;
                        return .{
                            .result = .{
                                .reason = @tagName(cond),
                                .status = owned_st,
                                .note = owned_note,
                                .elapsed_ms = std.time.milliTimestamp() - start_ms,
                            },
                            .owned_status = owned_st,
                            .owned_note = owned_note,
                        };
                    }
                }
            }
        }
    }

    while (true) {
        const frame = (try readFramedJsonWithPoll(allocator, stream.handle, deadline_ms)) orelse return null;
        defer allocator.free(frame);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, frame, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const ev = switch (obj.get("event") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const payload = switch (obj.get("payload") orelse continue) {
            .object => |o| o,
            else => continue,
        };
        const ev_uuid = switch (payload.get("pane_uuid") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, ev_uuid, &uuid)) continue;

        if (std.mem.eql(u8, ev, "pane_exited")) {
            if (cond == .done) {
                return .{
                    .result = .{
                        .reason = "exit",
                        .status = "exited",
                        .elapsed_ms = std.time.milliTimestamp() - start_ms,
                        .exited = true,
                    },
                };
            }
            return error.PodNotRunning;
        }

        if (std.mem.eql(u8, ev, "pane_status_changed")) {
            const st_str = if (payload.get("status")) |v| (if (v == .string) v.string else "idle") else "idle";
            const att = if (payload.get("attention")) |v| (if (v == .bool) v.bool else false) else false;
            if (statusMatchesCondition(cond, st_str, att)) {
                const owned_st = try allocator.dupe(u8, st_str);
                errdefer allocator.free(owned_st);
                const owned_note: ?[]u8 = if (payload.get("note")) |nv|
                    (if (nv == .string) try allocator.dupe(u8, nv.string) else null)
                else
                    null;
                return .{
                    .result = .{
                        .reason = @tagName(cond),
                        .status = owned_st,
                        .note = owned_note,
                        .elapsed_ms = std.time.milliTimestamp() - start_ms,
                    },
                    .owned_status = owned_st,
                    .owned_note = owned_note,
                };
            }
        }
    }
}

pub fn runWait(allocator: std.mem.Allocator, args: WaitArgs) !void {
    const cond = parseCondition(args.until, args.pattern) catch |err| {
        switch (err) {
            error.ConflictingConditions => cli_ui.printErr("pass either --until or --pattern, not both", .{}),
            else => cli_ui.printErr("invalid --until condition '{s}' (expected: exit, idle, done, blocked, attention, status:<state>, pattern:<text>)", .{args.until}),
        }
        std.process.exit(1);
    };

    const resolved = com.resolvePaneTarget(allocator, args.target) catch |err| com.exitUnresolved(err, args.target);
    const start_ms = std.time.milliTimestamp();
    const deadline_ms: ?i64 = if (args.timeout_ms > 0) start_ms + @as(i64, @intCast(args.timeout_ms)) else null;
    const session_opt: ?[]const u8 = if (args.target.session.len > 0) args.target.session else null;

    var final_result: ?WaitResult = null;
    var owned_status: ?[]u8 = null;
    var owned_note: ?[]u8 = null;
    defer if (owned_status) |s| allocator.free(s);
    defer if (owned_note) |n| allocator.free(n);

    switch (cond) {
        .exit, .idle, .pattern => {
            final_result = waitForPodCondition(allocator, resolved.uuid, cond, args, start_ms, deadline_ms) catch |err| {
                switch (err) {
                    error.PodNotRunning => {
                        cli_ui.printErr("pane exited before wait condition was met", .{});
                        std.process.exit(2);
                    },
                    else => {
                        cli_ui.printErr("wait failed: {s}", .{@errorName(err)});
                        std.process.exit(2);
                    },
                }
            };
        },
        .done, .blocked, .attention, .status => {
            const got = waitForStatusCondition(allocator, resolved.uuid, session_opt, cond, start_ms, deadline_ms) catch |err| {
                switch (err) {
                    error.PodNotRunning => {
                        cli_ui.printErr("pane exited before reaching target status", .{});
                        std.process.exit(2);
                    },
                    else => {
                        cli_ui.printErr("wait failed: {s}", .{@errorName(err)});
                        std.process.exit(2);
                    },
                }
            };
            if (got) |g| {
                final_result = g.result;
                owned_status = g.owned_status;
                owned_note = g.owned_note;
            }
        },
    }

    const res = final_result orelse {
        if (args.json) {
            var out = std.fs.File.stdout().deprecatedWriter();
            try out.print("{{\"ok\":false,\"timed_out\":true,\"uuid\":\"{s}\",\"elapsed_ms\":{d}}}\n", .{
                resolved.uuid[0..],
                std.time.milliTimestamp() - start_ms,
            });
        } else {
            cli_ui.printErr("timed out after {d}ms", .{args.timeout_ms});
        }
        std.process.exit(124);
    };

    var out = std.fs.File.stdout().deprecatedWriter();
    if (args.json) {
        try out.writeAll("{\"ok\":true,\"uuid\":");
        try core.regions.writeJsonString(out, &resolved.uuid);
        try out.writeAll(",\"reason\":");
        try core.regions.writeJsonString(out, res.reason);
        if (res.status) |st| {
            try out.writeAll(",\"status\":");
            try core.regions.writeJsonString(out, st);
        }
        if (res.note) |n| {
            try out.writeAll(",\"note\":");
            try core.regions.writeJsonString(out, n);
        }
        try out.print(",\"exited\":{s},\"elapsed_ms\":{d}}}\n", .{
            if (res.exited) "true" else "false",
            res.elapsed_ms,
        });
        return;
    }

    if (args.print_output) {
        if (res.note) |n| {
            try out.print("{s}\n", .{n});
        } else if (!res.exited) {
            if (shared.readPod(allocator, resolved.uuid, .lines, args.lines)) |got| {
                defer allocator.free(got.text);
                try out.writeAll(got.text);
                if (got.text.len > 0 and got.text[got.text.len - 1] != '\n') try out.writeAll("\n");
            } else |_| {}
        }
    }
}

test "parseCondition handles all supported forms" {
    try std.testing.expectEqual(WaitCondition.exit, try parseCondition("", ""));
    try std.testing.expectEqual(WaitCondition.exit, try parseCondition("exit", ""));
    try std.testing.expectEqual(WaitCondition.idle, try parseCondition("idle", ""));
    try std.testing.expectEqual(WaitCondition.done, try parseCondition("done", ""));
    try std.testing.expectEqual(WaitCondition.blocked, try parseCondition("blocked", ""));
    try std.testing.expectEqual(WaitCondition.attention, try parseCondition("attention", ""));
    try std.testing.expectEqual(WaitCondition{ .status = .working }, try parseCondition("status:working", ""));
    const p1 = try parseCondition("pattern:READY", "");
    try std.testing.expectEqualStrings("READY", p1.pattern);
    const p2 = try parseCondition("", "DONE");
    try std.testing.expectEqualStrings("DONE", p2.pattern);
    try std.testing.expectError(error.ConflictingConditions, parseCondition("idle", "DONE"));
    try std.testing.expectError(error.InvalidCondition, parseCondition("bogus", ""));
}
