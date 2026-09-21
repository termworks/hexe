//! Region content fetched from an external painter.
//!
//! A region is a rectangle of the terminal whose content an external program
//! produces. hexe still composites, clips and hit-tests it; only the content
//! comes from outside.
//!
//! The wire is deliberately dull so anything can implement it: a Unix socket,
//! one length-prefixed JSON request, one length-prefixed JSON response. hexe
//! knows nothing about which program is on the other end.
//!
//! `snapshot()` NEVER blocks. It returns the last completed response — possibly
//! stale, or empty before the first one lands — and starts a fetch when the
//! region is due. `poll()` runs once per event-loop iteration and advances every
//! in-flight fetch with non-blocking syscalls only.
//!
//! So a painter that is slow, wedged or dead costs a stale region, never a
//! frozen frame.

const std = @import("std");
const posix = std.posix;
const logging = @import("logging.zig");
const setNonBlocking = @import("ipc.zig").setNonBlocking;
const style_mod = @import("style.zig");

/// Re-run interval for a region whose config does not specify one.
pub const DEFAULT_REFRESH_MS: i64 = 1000;
/// After this long without a completed response the region is reported stale.
pub const DEFAULT_STALE_MS: i64 = 10_000;
/// An in-flight fetch that overruns this is abandoned and its socket closed.
pub const HARD_DEADLINE_MS: i64 = 2000;
/// Longest `next_frame_ms` taken seriously. The field is a delay; a painter
/// sending a Unix timestamp is describing a frame due in fifty years, and the
/// honest reading of that is "this painter means something else".
pub const MAX_FRAME_INTERVAL_MS: i64 = 60_000;
/// Base backoff after a failed fetch, doubled per consecutive failure.
pub const RETRY_BASE_MS: i64 = 500;
pub const RETRY_MAX_MS: i64 = 30_000;
/// Frame ceiling in both directions.
pub const MAX_FRAME: usize = 1024 * 1024;
pub const MAX_RUNS: usize = 256;
/// Upper bound on tracked regions; keys come from config, not user input.
pub const MAX_ENTRIES: usize = 64;

pub const Mode = enum {
    run,
    surface,

    pub fn fromString(s: []const u8) ?Mode {
        if (std.mem.eql(u8, s, "run")) return .run;
        if (std.mem.eql(u8, s, "surface")) return .surface;
        return null;
    }

    fn wireName(self: Mode) []const u8 {
        return switch (self) {
            .run => "run",
            .surface => "surface",
        };
    }
};

/// One styled run of text, as produced by the painter.
pub const Run = struct {
    text: []const u8,
    style: style_mod.Style,
};

pub const MAX_INTERACTIVE: usize = 64;

/// A clickable rectangle the painter reported inside its own output. The
/// painter names the action; hexe decides what that name does.
pub const Interactive = struct {
    id: []const u8,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    left: []const u8 = "",
    middle: []const u8 = "",
    right: []const u8 = "",
    hover_style: style_mod.Style = .{},

    pub fn contains(self: Interactive, px: u16, py: u16) bool {
        return px >= self.x and px < self.x +| self.width and
            py >= self.y and py < self.y +| self.height;
    }

    pub fn actionFor(self: Interactive, button: u8) []const u8 {
        return switch (button) {
            0 => self.left,
            1 => self.middle,
            2 => self.right,
            else => "",
        };
    }
};

/// What a renderer reads. Borrowed from the registry; valid until the next
/// `poll()`.
pub const Snapshot = struct {
    runs: []const Run = &.{},
    ansi: []const u8 = "",
    width: u16 = 0,
    /// False until the first response lands, which distinguishes "nothing yet"
    /// from "the painter legitimately returned nothing".
    done: bool = false,
    /// The last response is older than the region's stale threshold.
    stale: bool = false,
    /// Clickable rectangles the painter reported, in region-local coordinates.
    hits: []const Interactive = &.{},
    /// Which frame this is. Hit-testing compares it against the frame that was
    /// actually drawn, so rectangles are never read against a stale origin.
    done_ms: i64 = 0,
};

/// Caller state handed to the painter: shell fields at the top level, mux
/// fields under `values`.
pub const RequestContext = struct {
    cwd: ?[]const u8 = null,
    home: ?[]const u8 = null,
    exit_status: ?i32 = null,
    duration_ms: ?u64 = null,
    jobs: u16 = 0,
    started_at_ms: ?u64 = null,
    now_ms: u64 = 0,

    session_name: []const u8 = "",
    pod_name: []const u8 = "",
    last_command: ?[]const u8 = null,
    title: ?[]const u8 = null,
    tabs: []const []const u8 = &.{},
    active_tab: usize = 0,
    shell_running: bool = false,
    alt_screen: bool = false,
    adhoc_float: bool = false,
    /// OSC 9;4 progress reported by the focused pane. The pane has always
    /// parsed this; with chrome removal there was no longer anything in-process
    /// to draw it, and it reached nothing until the painter was told.
    /// State is the OSC's own vocabulary: inactive/in_progress/error/indeterminate/paused.
    progress_state: []const u8 = "inactive",
    progress_pct: ?u8 = null,
    active: bool = true,
    /// Interaction state the painter styles: which region the pointer is over,
    /// and which is held down by which button.
    hover_region: []const u8 = "",
    press_region: []const u8 = "",
    press_button: u8 = 0,
    /// Free-form extras merged into `context.values` (message, choices, ...).
    extra_json: []const u8 = "",
};

/// How a region is addressed and fetched.
pub const Spec = struct {
    /// Painter view name, e.g. "status" or "float.title".
    selector: []const u8,
    mode: Mode,
    width: u16,
    height: u16,
    refresh_ms: i64 = DEFAULT_REFRESH_MS,
    stale_ms: i64 = DEFAULT_STALE_MS,
    /// Distinguishes instances of the same view fetched for different subjects
    /// (per-pane sprites, per-float titles), which otherwise share one entry.
    key_suffix: []const u8 = "",
    /// The painter, run as hexe's own child. Null draws nothing: a region has
    /// no other way to be filled.
    exec: ?[]const u8 = null,
};

const Phase = enum { idle, queued, sent };

const Region = struct {
    key: []u8,
    selector: []u8,
    mode: Mode,
    refresh_ms: i64,
    stale_ms: i64,
    width: u16 = 0,
    height: u16 = 1,

    exec: ?[]u8 = null,
    phase: Phase = .idle,
    /// This region's request frame, length header included.
    req: std.ArrayList(u8) = .empty,
    /// Offset in `req` where the closing `now_ms` value starts; `req_key`
    /// hashes everything before it.
    req_split: usize = 0,
    req_key: u64 = 0,
    /// A request built while the last one was in flight, sent once it lands.
    staged: std.ArrayList(u8) = .empty,
    staged_split: usize = 0,
    staged_key: u64 = 0,
    has_staged: bool = false,
    /// The frame this region was last drawn in.
    frame_used: u64 = 0,
    /// Hash of the last accepted answer.
    body_hash: u64 = 0,
    /// Already reported as stale.
    stale_marked: bool = false,

    runs: std.ArrayList(Run) = .empty,
    run_text: std.ArrayList(u8) = .empty,
    ansi: std.ArrayList(u8) = .empty,
    hits: std.ArrayList(Interactive) = .empty,
    hit_text: std.ArrayList(u8) = .empty,
    out_width: u16 = 0,
    next_frame_ms: ?u64 = null,

    /// The painter's whole reply, kept parsed for as long as its frames are
    /// still playing: advancing a frame then costs no parse and no round trip,
    /// which is the point of asking for a strip at all. Freed when the next
    /// reply lands.
    strip: ?std.json.Parsed(std.json.Value) = null,
    /// Frames of `strip`, in order. Borrowed from its arena.
    strip_frames: []std.json.Value = &.{},
    strip_at: usize = 0,
    strip_due_ms: i64 = 0,

    /// The last response was a well-formed refusal (`ok:false`) rather than a
    /// transport failure, so the painter is known to be running.
    declined: bool = false,
    /// A syntactically valid response frame arrived, even if its body turned
    /// out to be unusable. Also means the painter is running.
    answered: bool = false,
    last_done_ms: i64 = 0,
    next_try_ms: i64 = 0,
    last_used_ms: i64 = 0,
    use_seq: u64 = 0,
    fail_streak: u32 = 0,

    fn inFlight(self: *const Region) bool {
        return self.phase != .idle;
    }

    fn clearStrip(self: *Region) void {
        if (self.strip) |*p| p.deinit();
        self.strip = null;
        self.strip_frames = &.{};
        self.strip_at = 0;
        self.strip_due_ms = 0;
    }

    /// A strip only animates when it has a second frame to move to.
    fn animating(self: *const Region) bool {
        return self.strip_frames.len > 1;
    }
};

/// One painter run serving every region that fell due together for the same
/// command. Requests go one at a time, each after the previous answer, so an
/// answer can only belong to the request before it; stdin closes after the last.
const Batch = struct {
    pid: posix.pid_t = 0,
    wfd: ?posix.fd_t = null,
    rfd: ?posix.fd_t = null,
    members: std.ArrayList(*Region) = .empty,
    /// Bytes of the current member's request already written.
    out_off: usize = 0,
    /// Index of the member the next answer belongs to.
    next: usize = 0,
    hdr: [4]u8 = [_]u8{0} ** 4,
    hdr_off: usize = 0,
    body: std.ArrayList(u8) = .empty,
    body_need: usize = 0,
    started_ms: i64,

    fn atFrameBoundary(self: *const Batch) bool {
        return self.hdr_off == 0 and self.body_need == 0;
    }

    fn deinit(self: *Batch, allocator: std.mem.Allocator) void {
        self.members.deinit(allocator);
        self.body.deinit(allocator);
    }
};

/// A painter whose pipes are closed but which has not been reaped yet.
const Stray = struct {
    pid: posix.pid_t,
    since_ms: i64,
    killed: bool = false,
};

/// The frontend's registry, published for the render path the same way
/// `cmd.async_cache` is. Null in short-lived processes, which have no painter.
pub var active: ?*Registry = null;

pub fn setActive(registry: *Registry) void {
    active = registry;
}

pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(*Region),
    use_counter: u64 = 0,
    /// Regions with a request built, waiting for `poll()` to start a painter.
    pending: std.ArrayList(*Region) = .empty,
    /// Painter runs in flight.
    batches: std.ArrayList(Batch) = .empty,
    /// Finished painters not reaped yet; `poll()` collects them without waiting.
    strays: std.ArrayList(Stray) = .empty,
    /// Commands seen to answer one request and exit; run once per region.
    solo: std.StringHashMapUnmanaged(void) = .empty,
    /// Counts drawn frames; a region drawn in the latest one is live.
    frame: u64 = 0,
    /// Some region's content changed since the last `takeChanged()`.
    changed: bool = false,
    scratch: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(*Region).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        const now = std.time.milliTimestamp();
        while (self.batches.items.len > 0) self.abortBatch(0, now);
        for (self.strays.items) |s| {
            posix.kill(s.pid, posix.SIG.KILL) catch {};
            _ = posix.waitpid(s.pid, 0);
        }
        self.strays.deinit(self.allocator);
        self.batches.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        var solo_it = self.solo.keyIterator();
        while (solo_it.next()) |k| self.allocator.free(k.*);
        self.solo.deinit(self.allocator);
        self.scratch.deinit(self.allocator);

        var it = self.entries.valueIterator();
        while (it.next()) |slot| self.destroyRegion(slot.*);
        self.entries.deinit();
    }

    fn destroyRegion(self: *Registry, r: *Region) void {
        r.clearStrip();
        r.req.deinit(self.allocator);
        r.staged.deinit(self.allocator);
        r.runs.deinit(self.allocator);
        r.run_text.deinit(self.allocator);
        r.hits.deinit(self.allocator);
        r.hit_text.deinit(self.allocator);
        r.ansi.deinit(self.allocator);
        self.allocator.free(r.key);
        self.allocator.free(r.selector);
        if (r.exec) |c| self.allocator.free(c);
        self.allocator.destroy(r);
    }

    /// Never blocks. Returns the last completed content for this region and
    /// schedules a refresh when one is due.
    pub fn snapshot(self: *Registry, spec: Spec, ctx: RequestContext) Snapshot {
        // Scheduling runs on the registry's own clock. `ctx.now_ms` is caller
        // data forwarded to the painter, and must not drive deadlines here.
        const now = std.time.milliTimestamp();
        const r = self.entry(spec, now) orelse return .{};

        r.last_used_ms = now;
        self.use_counter += 1;
        r.use_seq = self.use_counter;
        self.advanceStrip(r, now);

        // Geometry changes force a refetch: the painter lays out to the width
        // it was given, so a stale frame at the old width is wrong, not merely old.
        const resized = r.width != spec.width or r.height != spec.height;
        r.width = spec.width;
        r.height = spec.height;
        // Every frame of a strip was drawn to the old width, so playing the rest
        // of it animates content that no longer fits. The last frame stays on
        // screen -- stale, and dimmed as stale -- until the refetch lands.
        if (resized) r.clearStrip();

        r.frame_used = self.frame;
        // A request that differs from the last one in anything but `now_ms`
        // -- tab, hover, cwd, size -- is asked at once. The backoff still
        // applies, so a dead painter is not retried on every change.
        const changed = self.stage(r, ctx) catch false;
        if (!r.inFlight() and now >= r.next_try_ms and (resized or changed or self.isDue(r, now))) {
            self.queue(r, ctx.now_ms, now);
        }

        const done = r.last_done_ms != 0;
        return .{
            .runs = r.runs.items,
            .ansi = r.ansi.items,
            .width = r.out_width,
            .hits = r.hits.items,
            .done = done,
            .stale = done and (now - r.last_done_ms) > r.stale_ms,
            .done_ms = r.last_done_ms,
        };
    }

    /// Step a playing filmstrip to the frame due now. Costs no round trip and
    /// no parse: the frames are already in hand.
    fn advanceStrip(self: *Registry, r: *Region, now: i64) void {
        if (!r.animating()) return;
        var guard: usize = 0;
        while (now >= r.strip_due_ms and guard < r.strip_frames.len) : (guard += 1) {
            r.strip_at = (r.strip_at + 1) % r.strip_frames.len;
            const frame = switch (r.strip_frames[r.strip_at]) {
                .object => |o| o,
                else => {
                    r.clearStrip();
                    return;
                },
            };
            if (!self.applyFrame(r, frame)) {
                r.clearStrip();
                return;
            }
            // A frame with no cadence of its own ends the strip rather than
            // spinning on a deadline that never moves.
            const hold = r.next_frame_ms orelse {
                r.clearStrip();
                return;
            };
            r.strip_due_ms = now + @as(i64, @intCast(hold));
        }
    }

    fn isDue(self: *Registry, r: *Region, now: i64) bool {
        _ = self;
        if (now < r.next_try_ms) return false;
        if (r.last_done_ms == 0) return true;
        // A strip already holds every frame up to the next refresh, so asking
        // again mid-cycle would only re-fetch the same pictures. The painter's
        // own cadence drives the fetch only when it sent a single frame.
        const interval: i64 = if (r.animating())
            r.refresh_ms
        else if (r.next_frame_ms) |nf|
            @min(r.refresh_ms, @as(i64, @intCast(nf)))
        else
            r.refresh_ms;
        return (now - r.last_done_ms) >= @max(interval, 16);
    }

    fn entry(self: *Registry, spec: Spec, now: i64) ?*Region {
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}\x1f{s}\x1f{s}", .{ spec.selector, spec.mode.wireName(), spec.key_suffix }) catch return null;

        if (self.entries.get(key)) |r| return r;
        if (self.entries.count() >= MAX_ENTRIES) {
            self.evictOne();
            if (self.entries.count() >= MAX_ENTRIES) return null;
        }

        // Nothing to draw with is not an error, it is a region that stays empty:
        // a config with no painter must not become a failed fetch on a ladder.
        const exec = spec.exec orelse return null;

        const r = self.allocator.create(Region) catch return null;
        const key_owned = self.allocator.dupe(u8, key) catch {
            self.allocator.destroy(r);
            return null;
        };
        const selector_owned = self.allocator.dupe(u8, spec.selector) catch {
            self.allocator.free(key_owned);
            self.allocator.destroy(r);
            return null;
        };
        const exec_owned = self.allocator.dupe(u8, exec) catch {
            self.allocator.free(selector_owned);
            self.allocator.free(key_owned);
            self.allocator.destroy(r);
            return null;
        };

        r.* = .{
            .key = key_owned,
            .selector = selector_owned,
            .exec = exec_owned,
            .mode = spec.mode,
            .refresh_ms = @max(spec.refresh_ms, 16),
            .stale_ms = spec.stale_ms,
            .last_used_ms = now,
        };
        self.entries.put(key_owned, r) catch {
            self.destroyRegion(r);
            return null;
        };
        return r;
    }

    fn evictOne(self: *Registry) void {
        var victim: ?*Region = null;
        var it = self.entries.valueIterator();
        while (it.next()) |slot| {
            const r = slot.*;
            if (r.inFlight()) continue;
            if (victim == null or r.use_seq < victim.?.use_seq) victim = r;
        }
        const target = victim orelse return;
        _ = self.entries.remove(target.key);
        self.destroyRegion(target);
    }

    /// Build the request and queue the region for the next `poll()`. Any
    /// failure here is a failed fetch, not an error the caller sees.
    fn begin(self: *Registry, r: *Region, ctx: RequestContext, now: i64) void {
        self.buildRequest(r, ctx) catch {
            self.fail(r, now);
            return;
        };
        self.enqueue(r, now);
    }

    /// Queue the stored request, stamped with `now_ms`.
    fn queue(self: *Registry, r: *Region, now_ms: u64, now: i64) void {
        if (r.req.items.len == 0) return;
        self.restamp(r, now_ms) catch {
            self.fail(r, now);
            return;
        };
        self.enqueue(r, now);
    }

    fn enqueue(self: *Registry, r: *Region, now: i64) void {
        self.pending.append(self.allocator, r) catch {
            self.fail(r, now);
            return;
        };
        r.phase = .queued;
    }

    /// Queue every live region that fell due, from its last request, and mark
    /// any whose content just went stale.
    fn refreshDue(self: *Registry, now: i64) void {
        var it = self.entries.valueIterator();
        while (it.next()) |slot| {
            const r = slot.*;
            if (r.frame_used != self.frame) continue;
            if (!r.stale_marked and r.last_done_ms != 0 and now - r.last_done_ms > r.stale_ms) {
                r.stale_marked = true;
                self.changed = true;
            }
            if (r.inFlight() or now < r.next_try_ms or !self.isDue(r, now)) continue;
            self.queue(r, @intCast(now), now);
        }
    }

    /// Start queued fetches and advance every painter run. Non-blocking
    /// throughout.
    pub fn poll(self: *Registry) void {
        const now = std.time.milliTimestamp();
        self.refreshDue(now);
        self.launchPending(now);

        var i: usize = 0;
        while (i < self.batches.items.len) {
            const b = &self.batches.items[i];
            if (now - b.started_ms > HARD_DEADLINE_MS) {
                logging.warn("regions", "painter did not answer within {d}ms: {s}", .{ HARD_DEADLINE_MS, b.members.items[b.next].selector });
                self.abortBatch(i, now);
                continue;
            }
            if (self.pump(b, now)) {
                i += 1;
            } else {
                self.endBatch(i, now);
            }
        }
        self.reapStrays(now);
    }

    /// One painter run per command for everything queued. A region that is
    /// failing runs alone, so it cannot hold up the others.
    fn launchPending(self: *Registry, now: i64) void {
        while (self.pending.items.len > 0) {
            const lead = self.pending.items[0];
            const exec = lead.exec.?;
            const solo = self.solo.contains(exec) or lead.fail_streak > 0;
            var b: Batch = .{ .started_ms = now };

            var i: usize = 0;
            while (i < self.pending.items.len) {
                const r = self.pending.items[i];
                const joins = b.members.items.len == 0 or
                    (!solo and r.fail_streak == 0 and std.mem.eql(u8, r.exec.?, exec));
                if (!joins) {
                    i += 1;
                    continue;
                }
                _ = self.pending.orderedRemove(i);
                b.members.append(self.allocator, r) catch self.fail(r, now);
            }

            self.startBatch(&b, exec) catch {
                for (b.members.items) |r| self.fail(r, now);
                b.deinit(self.allocator);
            };
        }
    }

    fn startBatch(self: *Registry, b: *Batch, exec: []const u8) !void {
        if (b.members.items.len == 0) return error.NothingToRun;
        try self.batches.ensureUnusedCapacity(self.allocator, 1);
        const io = try spawnPainter(self.allocator, exec);
        b.pid = io.pid;
        b.wfd = io.stdin;
        b.rfd = io.stdout;
        for (b.members.items) |r| r.phase = .sent;
        self.batches.appendAssumeCapacity(b.*);
    }

    /// Advance one painter run. Returns false once it has nothing left to do.
    fn pump(self: *Registry, b: *Batch, now: i64) bool {
        const rfd = b.rfd orelse return false;
        while (b.next < b.members.items.len) {
            // The current request; stdin closes once the last one is out. A
            // painter that stopped reading may still have answered, so its
            // answers are read either way.
            if (b.wfd) |wfd| write: {
                const req = b.members.items[b.next].req.items;
                while (b.out_off < req.len) {
                    const n = posix.write(wfd, req[b.out_off..]) catch |err| switch (err) {
                        error.WouldBlock => return true,
                        else => {
                            posix.close(wfd);
                            b.wfd = null;
                            break :write;
                        },
                    };
                    if (n == 0) return true;
                    b.out_off += n;
                }
                if (b.next + 1 == b.members.items.len) {
                    posix.close(wfd);
                    b.wfd = null;
                }
            }

            while (b.hdr_off < 4) {
                const n = posix.read(rfd, b.hdr[b.hdr_off..]) catch |err| switch (err) {
                    error.WouldBlock => return true,
                    else => return self.hangUp(b, now, false),
                };
                if (n == 0) return self.hangUp(b, now, true);
                b.hdr_off += n;
            }
            if (b.body_need == 0) {
                const len = std.mem.readInt(u32, &b.hdr, .big);
                if (len == 0 or len > MAX_FRAME) return self.hangUp(b, now, false);
                b.body_need = len;
                b.body.clearRetainingCapacity();
                b.body.ensureTotalCapacity(self.allocator, len) catch return self.hangUp(b, now, false);
            }
            while (b.body.items.len < b.body_need) {
                const room = b.body.unusedCapacitySlice();
                const want = @min(room.len, b.body_need - b.body.items.len);
                const n = posix.read(rfd, room[0..want]) catch |err| switch (err) {
                    error.WouldBlock => return true,
                    else => return self.hangUp(b, now, false),
                };
                if (n == 0) return self.hangUp(b, now, true);
                b.body.items.len += n;
            }

            const r = b.members.items[b.next];
            b.next += 1;
            b.out_off = 0;
            b.hdr_off = 0;
            b.body_need = 0;
            // Stamped with the run's start so its regions fall due together.
            self.finish(r, b.body.items, b.started_ms);
        }
        return false;
    }

    /// The painter closed its output or broke the framing. After at least one
    /// clean answer and a clean exit it is a one-request painter: its remaining
    /// regions are queued again and its command runs once per region from now
    /// on. Anything else fails the remaining regions.
    fn hangUp(self: *Registry, b: *Batch, now: i64, eof: bool) bool {
        const single_shot = eof and b.next > 0 and b.atFrameBoundary();
        if (single_shot) self.markSolo(b.members.items[0].exec.?);
        for (b.members.items[b.next..]) |r| {
            if (!single_shot) {
                self.fail(r, now);
                continue;
            }
            self.pending.append(self.allocator, r) catch {
                self.fail(r, now);
                continue;
            };
            r.phase = .queued;
        }
        b.next = b.members.items.len;
        return false;
    }

    /// A completed answer arrived for this region.
    fn finish(self: *Registry, r: *Region, bytes: []const u8, now: i64) void {
        r.phase = .idle;
        r.declined = false;
        r.answered = false;
        if (self.parseResponse(r, bytes)) {
            r.last_done_ms = now;
            r.fail_streak = 0;
            r.next_try_ms = 0;
            const hash = std.hash.Wyhash.hash(0, bytes);
            if (hash != r.body_hash or r.stale_marked) self.changed = true;
            r.body_hash = hash;
            r.stale_marked = false;
        } else if (r.declined) {
            // A painter that answers `ok:false` is UP and simply does not
            // implement this view: retry on the ordinary cadence.
            r.fail_streak = 0;
            r.next_try_ms = now + @max(r.refresh_ms, RETRY_BASE_MS);
        } else {
            self.backoff(r, now);
        }
        self.sendStaged(r);
    }

    fn fail(self: *Registry, r: *Region, now: i64) void {
        r.phase = .idle;
        self.backoff(r, now);
        self.sendStaged(r);
    }

    /// Swap in a request built while the last one was in flight, and send it
    /// now unless the region is backing off.
    fn sendStaged(self: *Registry, r: *Region) void {
        if (!r.has_staged) return;
        std.mem.swap(std.ArrayList(u8), &r.req, &r.staged);
        r.req_split = r.staged_split;
        r.req_key = r.staged_key;
        r.has_staged = false;
        const now = std.time.milliTimestamp();
        if (now >= r.next_try_ms) self.queue(r, @intCast(now), now);
    }

    /// Close a finished run and reap its painter without waiting.
    fn endBatch(self: *Registry, i: usize, now: i64) void {
        var b = self.batches.swapRemove(i);
        if (b.wfd) |fd| posix.close(fd);
        if (b.rfd) |fd| posix.close(fd);
        self.release(b.pid, now);
        b.deinit(self.allocator);
    }

    /// Take a run down: the region it is stuck on fails, the ones queued behind
    /// it go back in the queue, and its painter is killed.
    fn abortBatch(self: *Registry, i: usize, now: i64) void {
        const b = &self.batches.items[i];
        if (b.next < b.members.items.len) {
            self.fail(b.members.items[b.next], now);
            for (b.members.items[b.next + 1 ..]) |r| {
                self.pending.append(self.allocator, r) catch {
                    self.fail(r, now);
                    continue;
                };
                r.phase = .queued;
            }
        }
        posix.kill(b.pid, posix.SIG.KILL) catch {};
        self.endBatch(i, now);
    }

    /// Reap now if it has exited, otherwise leave it to `reapStrays`.
    fn release(self: *Registry, pid: posix.pid_t, now: i64) void {
        if (posix.waitpid(pid, posix.W.NOHANG).pid != 0) return;
        self.strays.append(self.allocator, .{ .pid = pid, .since_ms = now }) catch {
            posix.kill(pid, posix.SIG.KILL) catch {};
            _ = posix.waitpid(pid, 0);
        };
    }

    /// Collect exited painters; one still running past the deadline is killed.
    fn reapStrays(self: *Registry, now: i64) void {
        var i: usize = 0;
        while (i < self.strays.items.len) {
            const s = &self.strays.items[i];
            if (posix.waitpid(s.pid, posix.W.NOHANG).pid != 0) {
                _ = self.strays.swapRemove(i);
                continue;
            }
            if (!s.killed and now - s.since_ms > HARD_DEADLINE_MS) {
                posix.kill(s.pid, posix.SIG.KILL) catch {};
                s.killed = true;
            }
            i += 1;
        }
    }

    fn markSolo(self: *Registry, exec: []const u8) void {
        if (self.solo.contains(exec)) return;
        const owned = self.allocator.dupe(u8, exec) catch return;
        self.solo.put(self.allocator, owned, {}) catch {
            self.allocator.free(owned);
            return;
        };
        logging.warn("regions", "painter answers one request per run; running it once per region: {s}", .{exec});
    }

    /// A painter run is queued or waiting on an answer.
    pub fn busy(self: *const Registry) bool {
        return self.pending.items.len > 0 or self.batches.items.len > 0;
    }

    /// A frame is being drawn; the regions it draws are live until the next.
    pub fn beginFrame(self: *Registry) void {
        self.frame +%= 1;
    }

    /// Whether any region's content changed since the last call.
    pub fn takeChanged(self: *Registry) bool {
        const changed = self.changed;
        self.changed = false;
        return changed;
    }

    /// Milliseconds until the loop has work for a live region: a fetch or a
    /// retry falling due, a filmstrip frame, or content going stale.
    pub fn msUntilDue(self: *Registry, now: i64) ?i64 {
        var soonest = self.msUntilFrame(now);
        var it = self.entries.valueIterator();
        while (it.next()) |slot| {
            const r = slot.*;
            if (r.frame_used != self.frame or r.inFlight()) continue;
            if (!r.stale_marked and r.last_done_ms != 0) {
                soonest = earlier(soonest, r.last_done_ms + r.stale_ms + 1 - now);
            }
            if (r.req.items.len == 0) continue;
            if (now < r.next_try_ms) {
                soonest = earlier(soonest, r.next_try_ms - now);
                continue;
            }
            const interval: i64 = if (r.animating())
                r.refresh_ms
            else if (r.next_frame_ms) |nf|
                @min(r.refresh_ms, @as(i64, @intCast(nf)))
            else
                r.refresh_ms;
            soonest = earlier(soonest, r.last_done_ms + @max(interval, 16) - now);
        }
        return soonest;
    }

    /// Milliseconds until a live region's filmstrip frame is due.
    pub fn msUntilFrame(self: *Registry, now: i64) ?i64 {
        var soonest: ?i64 = null;
        var it = self.entries.valueIterator();
        while (it.next()) |slot| {
            const r = slot.*;
            if (r.frame_used != self.frame or !r.animating()) continue;
            soonest = earlier(soonest, r.strip_due_ms - now);
        }
        return soonest;
    }

    fn earlier(soonest: ?i64, delta: i64) ?i64 {
        const d = @max(delta, 0);
        return if (soonest) |s| @min(s, d) else d;
    }

    /// Back off after a failure. Hammering a painter that cannot serve this
    /// view is no better than hammering a dead one, and the next fetch respawns
    /// the child anyway if it was the child that died.
    fn backoff(self: *Registry, r: *Region, now: i64) void {
        _ = self;
        r.fail_streak +|= 1;
        const shift: u6 = @intCast(@min(r.fail_streak - 1, 6));
        const delay = @min(RETRY_BASE_MS * (@as(i64, 1) << shift), RETRY_MAX_MS);
        r.next_try_ms = now + delay;
    }

    /// Build and keep the request `ctx` describes as the one to send.
    fn buildRequest(self: *Registry, r: *Region, ctx: RequestContext) !void {
        r.req.clearRetainingCapacity();
        r.req_split = try self.buildInto(&r.req, r, ctx);
        r.req_key = std.hash.Wyhash.hash(0, r.req.items[4..r.req_split]);
    }

    /// Build the request `ctx` describes and keep it if it differs from the
    /// last one in anything but `now_ms`: as the request to send, or staged
    /// behind the one in flight. True when the request to send changed.
    fn stage(self: *Registry, r: *Region, ctx: RequestContext) !bool {
        self.scratch.clearRetainingCapacity();
        const split = try self.buildInto(&self.scratch, r, ctx);
        const key = std.hash.Wyhash.hash(0, self.scratch.items[4..split]);
        if (r.req.items.len != 0 and key == r.req_key) {
            r.has_staged = false;
            return false;
        }
        if (r.inFlight()) {
            if (r.has_staged and key == r.staged_key) return false;
            r.staged.clearRetainingCapacity();
            try r.staged.appendSlice(self.allocator, self.scratch.items);
            r.staged_split = split;
            r.staged_key = key;
            r.has_staged = true;
            return false;
        }
        r.req.clearRetainingCapacity();
        try r.req.appendSlice(self.allocator, self.scratch.items);
        r.req_split = split;
        r.req_key = key;
        return true;
    }

    /// Rewrite the `now_ms` value that closes the stored request.
    fn restamp(self: *Registry, r: *Region, now_ms: u64) !void {
        r.req.shrinkRetainingCapacity(r.req_split);
        try r.req.writer(self.allocator).print("{d}}}", .{now_ms});
        std.mem.writeInt(u32, r.req.items[0..4], @intCast(r.req.items.len - 4), .big);
    }

    /// Write one request frame into `out`. Returns the offset where the
    /// closing `now_ms` value starts.
    fn buildInto(self: *Registry, out: *std.ArrayList(u8), r: *const Region, ctx: RequestContext) !usize {
        const start = out.items.len;
        try out.appendNTimes(self.allocator, 0, 4);
        const w = out.writer(self.allocator);

        try w.writeAll("{\"version\":1,\"select\":[");
        try writeJsonString(w, r.selector);
        try w.print("],\"mode\":\"{s}\",\"width\":{d},\"height\":{d},\"frames_ms\":{d},\"ignore_missing\":false,\"context\":{{", .{
            r.mode.wireName(), r.width, r.height, r.refresh_ms,
        });

        var first = true;
        if (ctx.cwd) |v| {
            try writeField(w, &first, "cwd");
            try writeJsonString(w, v);
        }
        if (ctx.home) |v| {
            try writeField(w, &first, "home");
            try writeJsonString(w, v);
        }
        if (ctx.exit_status) |v| {
            try writeField(w, &first, "exit_status");
            try w.print("{d}", .{v});
        }
        if (ctx.duration_ms) |v| {
            try writeField(w, &first, "duration_ms");
            try w.print("{d}", .{v});
        }
        try writeField(w, &first, "jobs");
        try w.print("{d}", .{ctx.jobs});
        if (ctx.started_at_ms) |v| {
            try writeField(w, &first, "started_at_ms");
            try w.print("{d}", .{v});
        }

        try writeField(w, &first, "values");
        try w.writeAll("{\"schema\":1");
        try w.writeAll(",\"session\":");
        try writeJsonString(w, ctx.session_name);
        try w.writeAll(",\"pod_name\":");
        try writeJsonString(w, ctx.pod_name);
        if (ctx.last_command) |v| {
            try w.writeAll(",\"last_command\":");
            try writeJsonString(w, v);
        }
        if (ctx.title) |v| {
            try w.writeAll(",\"title\":");
            try writeJsonString(w, v);
        }
        if (ctx.hover_region.len > 0) {
            try w.writeAll(",\"hover_region\":");
            try writeJsonString(w, ctx.hover_region);
        }
        if (ctx.press_region.len > 0) {
            try w.writeAll(",\"press_region\":");
            try writeJsonString(w, ctx.press_region);
            try w.print(",\"press_button\":{d}", .{ctx.press_button});
        }
        try w.print(",\"active\":{s}", .{boolStr(ctx.active)});
        try w.print(",\"active_tab\":{d}", .{ctx.active_tab});
        try w.print(",\"shell_running\":{s}", .{boolStr(ctx.shell_running)});
        try w.print(",\"alt_screen\":{s}", .{boolStr(ctx.alt_screen)});
        try w.print(",\"adhoc_float\":{s}", .{boolStr(ctx.adhoc_float)});
        try w.writeAll(",\"progress_state\":");
        try writeJsonString(w, ctx.progress_state);
        if (ctx.progress_pct) |pct| {
            try w.print(",\"progress_pct\":{d}", .{pct});
        } else {
            try w.writeAll(",\"progress_pct\":null");
        }
        try w.writeAll(",\"tabs\":[");
        for (ctx.tabs, 0..) |t, i| {
            if (i != 0) try w.writeAll(",");
            try writeJsonString(w, t);
        }
        try w.writeAll("]");
        if (ctx.extra_json.len > 0) {
            try w.writeAll(",");
            try w.writeAll(ctx.extra_json);
        }
        try w.writeAll("}},\"now_ms\":");
        const split = out.items.len;
        try w.print("{d}}}", .{ctx.now_ms});

        const len = out.items.len - start - 4;
        if (len > MAX_FRAME) return error.FrameTooLarge;
        std.mem.writeInt(u32, out.items[start..][0..4], @intCast(len), .big);
        return split;
    }

    /// Read the painter's `regions` array: clickable rectangles with an id and
    /// per-button action names. Strings are packed into one buffer so the slices
    /// handed out cannot dangle on reallocation.
    fn parseInteractive(self: *Registry, r: *Region, output: std.json.ObjectMap) void {
        r.hits.clearRetainingCapacity();
        r.hit_text.clearRetainingCapacity();

        const arr = switch (output.get("regions") orelse return) {
            .array => |a| a,
            else => return,
        };

        const Span = struct { start: usize, end: usize };
        var pending: std.ArrayList(struct {
            id: Span,
            left: Span,
            middle: Span,
            right: Span,
            x: u16,
            y: u16,
            w: u16,
            h: u16,
            hover: style_mod.Style,
        }) = .empty;
        defer pending.deinit(self.allocator);

        for (arr.items) |item| {
            if (pending.items.len >= MAX_INTERACTIVE) break;
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };

            const pack = struct {
                fn go(reg: *Region, alloc: std.mem.Allocator, text: []const u8) ?Span {
                    const start = reg.hit_text.items.len;
                    reg.hit_text.appendSlice(alloc, text) catch return null;
                    return .{ .start = start, .end = reg.hit_text.items.len };
                }
            }.go;

            const id_text = switch (obj.get("id") orelse continue) {
                .string => |v| v,
                else => continue,
            };
            const id_span = pack(r, self.allocator, id_text) orelse continue;

            var actions: [3]Span = .{ .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 } };
            if (obj.get("actions")) |av| {
                if (av == .object) {
                    const names = [_][]const u8{ "left", "middle", "right" };
                    for (names, 0..) |name, i| {
                        if (av.object.get(name)) |v| {
                            if (v == .string) {
                                actions[i] = pack(r, self.allocator, v.string) orelse continue;
                            }
                        }
                    }
                }
            }

            var hover: style_mod.Style = .{};
            if (obj.get("hover_style")) |hv| {
                if (hv == .string) hover = style_mod.Style.parse(hv.string);
            }

            const geom = struct {
                fn u16field(o: std.json.ObjectMap, key: []const u8) u16 {
                    const v = o.get(key) orelse return 0;
                    if (v != .integer or v.integer < 0) return 0;
                    return @intCast(@min(v.integer, std.math.maxInt(u16)));
                }
            };

            pending.append(self.allocator, .{
                .id = id_span,
                .left = actions[0],
                .middle = actions[1],
                .right = actions[2],
                .x = geom.u16field(obj, "x"),
                .y = geom.u16field(obj, "y"),
                .w = geom.u16field(obj, "width"),
                .h = geom.u16field(obj, "height"),
                .hover = hover,
            }) catch break;
        }

        const buf = r.hit_text.items;
        for (pending.items) |p| {
            r.hits.append(self.allocator, .{
                .id = buf[p.id.start..p.id.end],
                .x = p.x,
                .y = p.y,
                .width = p.w,
                .height = p.h,
                .left = buf[p.left.start..p.left.end],
                .middle = buf[p.middle.start..p.middle.end],
                .right = buf[p.right.start..p.right.end],
                .hover_style = p.hover,
            }) catch break;
        }
    }

    /// Replace the region's content from a painter response frame. Returns false
    /// on anything malformed, which the caller treats as a failed fetch.
    fn parseResponse(self: *Registry, r: *Region, bytes: []const u8) bool {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{}) catch |err| {
            logging.logError("regions", "painter sent invalid JSON", err);
            return false;
        };
        var retained = false;
        defer if (!retained) parsed.deinit();

        const root = switch (parsed.value) {
            .object => |o| o,
            else => return false,
        };
        if (root.get("ok")) |ok| {
            if (ok == .bool and !ok.bool) {
                r.declined = true;
                return false;
            }
        }
        const output = switch (root.get("output") orelse return false) {
            .object => |o| o,
            else => return false,
        };
        r.answered = true;

        // A filmstrip: every frame of one animation cycle, so the loop plays it
        // without asking again until the data underneath can have changed.
        if (output.get("frames")) |fv| {
            if (fv != .array or fv.array.items.len == 0) return false;
            const first = switch (fv.array.items[0]) {
                .object => |o| o,
                else => return false,
            };
            if (!self.applyFrame(r, first)) return false;
            r.clearStrip();
            r.strip = parsed;
            r.strip_frames = fv.array.items;
            r.strip_at = 0;
            r.strip_due_ms = std.time.milliTimestamp() + @as(i64, @intCast(r.next_frame_ms orelse 0));
            retained = true;
            return true;
        }

        r.clearStrip();
        return self.applyFrame(r, output);
    }

    /// Draw one frame's body into the region. Shared by a plain reply and by
    /// each frame of a filmstrip, which carry the same object.
    fn applyFrame(self: *Registry, r: *Region, output: std.json.ObjectMap) bool {
        r.next_frame_ms = null;
        if (output.get("next_frame_ms")) |nf| {
            // An INTERVAL -- "ask again in N ms" -- never a deadline.
            //
            // A painter that sent an absolute timestamp instead was not
            // rejected, it was clamped: `@min(refresh_ms, 1.7e12)` is always
            // `refresh_ms`, so the cadence request vanished and the animation
            // quietly ran at the refresh rate. Nothing failed, nothing logged,
            // and the only symptom was that it looked sluggish. Anything longer
            // than a minute is not a frame interval, so say so once rather than
            // absorb it.
            if (nf == .integer and nf.integer > 0 and nf.integer <= MAX_FRAME_INTERVAL_MS) {
                r.next_frame_ms = @intCast(nf.integer);
            } else if (nf == .integer and nf.integer > MAX_FRAME_INTERVAL_MS) {
                logging.warn("regions", "painter asked for a {d}ms frame interval; " ++
                    "`next_frame_ms` is a delay, not a timestamp -- ignoring", .{nf.integer});
            }
        }
        r.out_width = 0;
        if (output.get("width")) |wv| {
            if (wv == .integer and wv.integer >= 0) {
                r.out_width = @intCast(@min(wv.integer, std.math.maxInt(u16)));
            }
        }

        switch (r.mode) {
            .run => {
                const runs = switch (output.get("runs") orelse return false) {
                    .array => |a| a,
                    else => return false,
                };
                r.runs.clearRetainingCapacity();
                r.run_text.clearRetainingCapacity();
                // Text is packed into one buffer and referenced by offset, so a
                // reallocation cannot dangle the slices handed to the renderer.
                var offsets: std.ArrayList([2]usize) = .empty;
                defer offsets.deinit(self.allocator);
                var styles: std.ArrayList(style_mod.Style) = .empty;
                defer styles.deinit(self.allocator);

                for (runs.items) |item| {
                    if (offsets.items.len >= MAX_RUNS) break;
                    const obj = switch (item) {
                        .object => |o| o,
                        else => continue,
                    };
                    const text = switch (obj.get("text") orelse continue) {
                        .string => |s| s,
                        else => continue,
                    };
                    const style_str = if (obj.get("style")) |sv| switch (sv) {
                        .string => |s| s,
                        else => "",
                    } else "";

                    const start = r.run_text.items.len;
                    r.run_text.appendSlice(self.allocator, text) catch return false;
                    offsets.append(self.allocator, .{ start, r.run_text.items.len }) catch return false;
                    styles.append(self.allocator, style_mod.Style.parse(style_str)) catch return false;
                }

                for (offsets.items, styles.items) |span, st| {
                    r.runs.append(self.allocator, .{
                        .text = r.run_text.items[span[0]..span[1]],
                        .style = st,
                    }) catch return false;
                }
                if (r.out_width == 0) {
                    var total: usize = 0;
                    for (r.runs.items) |run| total += run.text.len;
                    r.out_width = @intCast(@min(total, std.math.maxInt(u16)));
                }
            },
            .surface => {
                const ansi = switch (output.get("ansi") orelse return false) {
                    .string => |s| s,
                    else => return false,
                };
                r.ansi.clearRetainingCapacity();
                r.ansi.appendSlice(self.allocator, ansi) catch return false;
            },
        }

        // Committed only after the body validated: a frame rejected above must
        // leave the previous rectangles in place, or clicks stop working while
        // the bar still shows the content they belong to.
        self.parseInteractive(r, output);
        return true;
    }
};

const PainterIo = struct {
    pid: posix.pid_t,
    stdin: posix.fd_t,
    stdout: posix.fd_t,
};

/// Opaque storage for libc's file-action list, larger than glibc's and musl's.
const SpawnFileActions = extern struct {
    storage: [256]u8 align(16) = undefined,
};
extern "c" fn posix_spawn_file_actions_init(actions: *SpawnFileActions) c_int;
extern "c" fn posix_spawn_file_actions_destroy(actions: *SpawnFileActions) c_int;
extern "c" fn posix_spawn_file_actions_adddup2(actions: *SpawnFileActions, fd: c_int, new_fd: c_int) c_int;
extern "c" fn posix_spawnp(
    pid: *posix.pid_t,
    file: [*:0]const u8,
    actions: *const SpawnFileActions,
    attr: ?*const anyopaque,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) c_int;

/// Start a painter with piped, non-blocking stdin and stdout. `posix_spawn`
/// shares the frontend's address space until the exec instead of copying it.
fn spawnPainter(allocator: std.mem.Allocator, cmd: []const u8) !PainterIo {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const argv = try painterArgv(arena.allocator(), cmd);

    const to_child = try posix.pipe2(.{ .CLOEXEC = true });
    const from_child = posix.pipe2(.{ .CLOEXEC = true }) catch |err| {
        posix.close(to_child[0]);
        posix.close(to_child[1]);
        return err;
    };
    defer posix.close(to_child[0]);
    defer posix.close(from_child[1]);
    errdefer posix.close(to_child[1]);
    errdefer posix.close(from_child[0]);

    var actions: SpawnFileActions = .{};
    if (posix_spawn_file_actions_init(&actions) != 0) return error.SpawnFailed;
    defer _ = posix_spawn_file_actions_destroy(&actions);
    if (posix_spawn_file_actions_adddup2(&actions, to_child[0], posix.STDIN_FILENO) != 0) return error.SpawnFailed;
    if (posix_spawn_file_actions_adddup2(&actions, from_child[1], posix.STDOUT_FILENO) != 0) return error.SpawnFailed;

    var pid: posix.pid_t = 0;
    if (posix_spawnp(&pid, argv[0].?, &actions, null, argv.ptr, @ptrCast(std.c.environ)) != 0) return error.SpawnFailed;

    setNonBlocking(to_child[1]) catch {};
    setNonBlocking(from_child[0]) catch {};
    return .{ .pid = pid, .stdin = to_child[1], .stdout = from_child[0] };
}

/// argv for a painter command: plain words are exec'd directly, anything the
/// shell would interpret goes through `/bin/sh -c`.
fn painterArgv(arena: std.mem.Allocator, cmd: []const u8) ![:null]?[*:0]const u8 {
    if (plainWords(cmd)) {
        var list: std.ArrayList(?[*:0]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, cmd, ' ');
        while (it.next()) |word| try list.append(arena, try arena.dupeZ(u8, word));
        return list.toOwnedSliceSentinel(arena, null);
    }
    const argv = try arena.allocSentinel(?[*:0]const u8, 3, null);
    argv[0] = "/bin/sh";
    argv[1] = "-c";
    argv[2] = try arena.dupeZ(u8, cmd);
    return argv;
}

/// Space-separated words with no quoting, expansion, redirection or leading
/// `VAR=value` assignment.
fn plainWords(cmd: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, cmd, ' ');
    const first = it.next() orelse return false;
    if (std.mem.indexOfScalar(u8, first, '=') != null) return false;
    for (cmd) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', ' ', '_', '-', '.', '/', ':', ',', '+', '@', '%', '=' => {},
        else => return false,
    };
    return true;
}

fn boolStr(v: bool) []const u8 {
    return if (v) "true" else "false";
}

fn writeField(w: anytype, first: *bool, name: []const u8) !void {
    if (!first.*) try w.writeAll(",");
    first.* = false;
    try w.print("\"{s}\":", .{name});
}

pub fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => {
            if (c < 0x20) {
                try w.print("\\u{x:0>4}", .{c});
            } else {
                try w.writeByte(c);
            }
        },
    };
    try w.writeAll("\"");
}

test "run response parses into styled runs" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    const spec = Spec{ .selector = "status", .mode = .run, .width = 40, .height = 1, .exec = "true" };
    const r = reg.entry(spec, 0).?;

    const frame =
        \\{"version":1,"ok":true,"output":{"mode":"run","runs":[
        \\{"text":" A ","style":"fg:#ff5500 bg:237 bold"},
        \\{"text":"B","style":"fg:250"}],"width":4,"next_frame_ms":75}}
    ;
    try std.testing.expect(reg.parseResponse(r, frame));
    try std.testing.expectEqual(@as(usize, 2), r.runs.items.len);
    try std.testing.expectEqualStrings(" A ", r.runs.items[0].text);
    try std.testing.expectEqual(style_mod.Color{ .rgb = .{ .r = 255, .g = 85, .b = 0 } }, r.runs.items[0].style.fg);
    try std.testing.expectEqual(style_mod.Color{ .palette = 237 }, r.runs.items[0].style.bg);
    try std.testing.expect(r.runs.items[0].style.bold);
    try std.testing.expectEqualStrings("B", r.runs.items[1].text);
    try std.testing.expectEqual(@as(u16, 4), r.out_width);
    try std.testing.expectEqual(@as(?u64, 75), r.next_frame_ms);
}

test "surface response parses into ansi bytes" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    const spec = Spec{ .selector = "overlay.sprite", .mode = .surface, .width = 10, .height = 4, .exec = "true" };
    const r = reg.entry(spec, 0).?;

    const frame =
        \\{"version":1,"ok":true,"output":{"mode":"surface","ansi":"\u001b[31mX\u001b[0m","width":10,"height":4}}
    ;
    try std.testing.expect(reg.parseResponse(r, frame));
    try std.testing.expectEqualStrings("\x1b[31mX\x1b[0m", r.ansi.items);
}

test "malformed and error frames are rejected without clobbering content" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    const spec = Spec{ .selector = "status", .mode = .run, .width = 40, .height = 1, .exec = "true" };
    const r = reg.entry(spec, 0).?;

    try std.testing.expect(reg.parseResponse(r, "{\"ok\":true,\"output\":{\"mode\":\"run\",\"runs\":[{\"text\":\"ok\"}],\"width\":2}}"));
    try std.testing.expectEqual(@as(usize, 1), r.runs.items.len);

    try std.testing.expect(!reg.parseResponse(r, "not json"));
    try std.testing.expect(!reg.parseResponse(r, "{\"ok\":false,\"output\":{}}"));
    try std.testing.expect(!reg.parseResponse(r, "{\"ok\":true}"));
    // The last good frame survives a rejected one.
    try std.testing.expectEqual(@as(usize, 1), r.runs.items.len);
    try std.testing.expectEqualStrings("ok", r.runs.items[0].text);
}

test "request frame is length-prefixed and carries geometry" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    const spec = Spec{ .selector = "prompt.left", .mode = .run, .width = 100, .height = 1, .exec = "true" };
    const r = reg.entry(spec, 0).?;
    r.width = 100;
    r.height = 1;

    try reg.buildRequest(r, .{ .cwd = "/tmp/a\"b", .now_ms = 42, .session_name = "main" });

    const len = std.mem.readInt(u32, r.req.items[0..4], .big);
    try std.testing.expectEqual(@as(usize, len), r.req.items.len - 4);

    const body = r.req.items[4..];
    try std.testing.expect(std.mem.indexOf(u8, body, "\"select\":[\"prompt.left\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"width\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"mode\":\"run\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"schema\":1") != null);
    // Quotes in caller state must not break the frame.
    try std.testing.expect(std.mem.indexOf(u8, body, "/tmp/a\\\"b") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
}

/// A painter as a child, framed the way the protocol says: four big-endian
/// length bytes then the JSON. `printf` writes it in one go, so the test needs
/// no helper process of its own.
fn framedEcho(allocator: std.mem.Allocator, reply: []const u8) ![]u8 {
    const n = reply.len;
    return std.fmt.allocPrint(allocator, "printf '\\{o}\\{o}\\{o}\\{o}%s' '{s}'", .{
        (n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff, reply,
    });
}

test "fetches a run frame from its own child without blocking" {
    const allocator = std.testing.allocator;
    const reply =
        \\{"version":1,"ok":true,"output":{"mode":"run","runs":[{"text":" hi ","style":"fg:15 bg:237 bold"}],"width":4,"next_frame_ms":null}}
    ;
    const cmd = try framedEcho(allocator, reply);
    defer allocator.free(cmd);

    var reg = Registry.init(allocator);
    defer reg.deinit();

    const spec = Spec{
        .selector = "status",
        .mode = .run,
        .width = 80,
        .height = 1,
        .exec = cmd,
    };

    // First look starts the fetch and must return empty rather than wait.
    const first = reg.snapshot(spec, .{ .now_ms = 1 });
    try std.testing.expect(!first.done);
    try std.testing.expectEqual(@as(usize, 0), first.runs.len);

    // Drive poll() until the frame lands, exactly as the event loop does.
    var spins: usize = 0;
    while (spins < 2000) : (spins += 1) {
        reg.poll();
        const snap = reg.snapshot(spec, .{ .now_ms = 1 });
        if (snap.done) {
            try std.testing.expectEqual(@as(usize, 1), snap.runs.len);
            try std.testing.expectEqualStrings(" hi ", snap.runs[0].text);
            try std.testing.expectEqual(style_mod.Color{ .palette = 15 }, snap.runs[0].style.fg);
            try std.testing.expectEqual(style_mod.Color{ .palette = 237 }, snap.runs[0].style.bg);
            try std.testing.expect(snap.runs[0].style.bold);
            try std.testing.expect(!snap.stale);
            return;
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.PainterFrameNeverArrived;
}

/// How many descriptors this process holds. A leak per fetch is invisible in
/// any single render and fatal after a thousand of them.
fn openFdCount() usize {
    var dir = std.fs.openDirAbsolute("/proc/self/fd", .{ .iterate = true }) catch return 0;
    defer dir.close();
    var it = dir.iterate();
    var n: usize = 0;
    while (it.next() catch null) |_| n += 1;
    return n;
}

test "fetching many times leaks no descriptors" {
    const allocator = std.testing.allocator;
    if (openFdCount() == 0) return error.SkipZigTest; // no /proc

    const reply =
        \\{"version":1,"ok":true,"output":{"mode":"run","runs":[{"text":"x"}],"width":1,"next_frame_ms":null}}
    ;
    const cmd = try framedEcho(allocator, reply);
    defer allocator.free(cmd);

    var reg = Registry.init(allocator);
    defer reg.deinit();
    const spec = Spec{ .selector = "status", .mode = .run, .width = 20, .height = 1, .exec = cmd };

    // One fetch to settle, then measure across many more. Each spawns a painter,
    // writes to it, reads its answer and reaps it -- and every descriptor that
    // opens must close, including the one `Child.spawn` keeps for itself.
    var warm: usize = 0;
    while (warm < 40) : (warm += 1) {
        _ = reg.snapshot(spec, .{ .now_ms = 1 });
        reg.poll();
        std.Thread.sleep(std.time.ns_per_ms);
    }
    const before = openFdCount();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var r = reg.entries.get("status\x1frun\x1f").?;
        r.last_done_ms = 0; // force it due again
        r.next_try_ms = 0;
        _ = reg.snapshot(spec, .{ .now_ms = @intCast(i) });
        reg.poll();
        std.Thread.sleep(std.time.ns_per_ms);
    }
    const after = openFdCount();
    if (after > before + 8) {
        std.debug.print("descriptors {d} -> {d} over 200 fetches\n", .{ before, after });
        return error.DescriptorLeak;
    }
}

test "a painter that never answers leaves the region empty and never blocks" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    // Reads nothing and writes nothing, which is the wedged painter this
    // module exists to survive.
    const spec = Spec{
        .selector = "status",
        .mode = .run,
        .width = 80,
        .height = 1,
        .exec = "cat >/dev/null",
    };

    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const snap = reg.snapshot(spec, .{ .now_ms = @intCast(i) });
        try std.testing.expect(!snap.done);
        reg.poll();
    }
    // 200 render passes against a wedged painter must cost effectively nothing.
    try std.testing.expect(timer.read() < 500 * std.time.ns_per_ms);
}

test "a region with no painter configured stays empty" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    // No `exec`: nothing to draw with is an empty region, not a failed fetch on
    // a retry ladder.
    const spec = Spec{ .selector = "status", .mode = .run, .width = 80, .height = 1 };
    const snap = reg.snapshot(spec, .{ .now_ms = 1 });
    try std.testing.expect(!snap.done);
    try std.testing.expectEqual(@as(usize, 0), snap.runs.len);
    reg.poll();
}

test "backoff grows and a good frame clears it" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    const spec = Spec{ .selector = "status", .mode = .run, .width = 40, .height = 1, .exec = "true" };
    const r = reg.entry(spec, 0).?;

    reg.backoff(r, 1000);
    const first = r.next_try_ms;
    reg.backoff(r, 1000);
    try std.testing.expect(r.next_try_ms > first);

    try std.testing.expect(!reg.isDue(r, 1000));

    r.fail_streak = 0;
    r.next_try_ms = 0;
    r.last_done_ms = 0;
    try std.testing.expect(reg.isDue(r, 1000));
}

/// A painter that logs one line per run to `log` and answers with `replies` in
/// order, 20ms apart, without reading its requests.
fn framedReplies(allocator: std.mem.Allocator, log: []const u8, replies: []const []const u8) ![]u8 {
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(allocator);
    const w = script.writer(allocator);
    try w.print("echo run >> '{s}'", .{log});
    for (replies) |reply| {
        const n = reply.len;
        try w.print("; printf '\\{o}\\{o}\\{o}\\{o}%s' '{s}'; sleep 0.02", .{
            (n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff, reply,
        });
    }
    return script.toOwnedSlice(allocator);
}

fn pollUntilDone(reg: *Registry, specs: []const Spec) !void {
    var spins: usize = 0;
    while (spins < 2000) : (spins += 1) {
        reg.poll();
        var done: usize = 0;
        for (specs) |s| {
            if (reg.snapshot(s, .{ .now_ms = 1 }).done) done += 1;
        }
        if (done == specs.len) return;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.PainterFramesNeverArrived;
}

test "regions due together share one painter run" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    const log = try std.fs.path.join(allocator, &.{ dir, "runs" });
    defer allocator.free(log);

    const replies = [_][]const u8{
        \\{"version":1,"ok":true,"output":{"mode":"run","runs":[{"text":"a"}],"width":1}}
        ,
        \\{"version":1,"ok":true,"output":{"mode":"run","runs":[{"text":"b"}],"width":1}}
        ,
        \\{"version":1,"ok":true,"output":{"mode":"run","runs":[{"text":"c"}],"width":1}}
        ,
    };
    const cmd = try framedReplies(allocator, log, &replies);
    defer allocator.free(cmd);

    var reg = Registry.init(allocator);
    defer reg.deinit();
    const zones = [_][]const u8{ "left", "center", "right" };
    var specs: [3]Spec = undefined;
    for (&specs, zones) |*s, zone| {
        s.* = .{ .selector = "status", .mode = .run, .width = 10, .height = 1, .key_suffix = zone, .exec = cmd };
    }

    for (specs) |s| _ = reg.snapshot(s, .{ .now_ms = 1 });
    try pollUntilDone(&reg, &specs);

    for (specs, [_][]const u8{ "a", "b", "c" }) |s, text| {
        try std.testing.expectEqualStrings(text, reg.snapshot(s, .{ .now_ms = 1 }).runs[0].text);
    }
    const runs = try tmp.dir.readFileAlloc(allocator, "runs", 1024);
    defer allocator.free(runs);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, runs, "run\n"));

    // Answered on different wakes, still due together on the next refresh.
    const left = reg.entries.get("status\x1frun\x1fleft").?;
    for ([_][]const u8{ "status\x1frun\x1fcenter", "status\x1frun\x1fright" }) |key| {
        try std.testing.expectEqual(left.last_done_ms, reg.entries.get(key).?.last_done_ms);
    }
}

test "a painter that answers once per run still serves every region" {
    const allocator = std.testing.allocator;
    const reply =
        \\{"version":1,"ok":true,"output":{"mode":"run","runs":[{"text":"x"}],"width":1}}
    ;
    const cmd = try framedEcho(allocator, reply);
    defer allocator.free(cmd);

    var reg = Registry.init(allocator);
    defer reg.deinit();
    const zones = [_][]const u8{ "left", "center", "right" };
    var specs: [3]Spec = undefined;
    for (&specs, zones) |*s, zone| {
        s.* = .{ .selector = "status", .mode = .run, .width = 10, .height = 1, .key_suffix = zone, .exec = cmd };
    }

    for (specs) |s| _ = reg.snapshot(s, .{ .now_ms = 1 });
    try pollUntilDone(&reg, &specs);
    try std.testing.expect(reg.solo.contains(cmd));
}

test "a failing region runs alone while the others share a run" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    const zones = [_][]const u8{ "left", "center", "right" };
    var regions: [3]*Region = undefined;
    for (&regions, zones) |*r, zone| {
        r.* = reg.entry(.{ .selector = "status", .mode = .run, .width = 10, .height = 1, .key_suffix = zone, .exec = "cat >/dev/null" }, 0).?;
        r.*.width = 10;
    }
    regions[1].fail_streak = 1;
    for (regions) |r| reg.begin(r, .{ .now_ms = 1 }, 0);

    reg.launchPending(0);
    try std.testing.expectEqual(@as(usize, 2), reg.batches.items.len);
    try std.testing.expectEqual(@as(usize, 2), reg.batches.items[0].members.items.len);
    try std.testing.expectEqual(regions[0], reg.batches.items[0].members.items[0]);
    try std.testing.expectEqual(regions[2], reg.batches.items[0].members.items[1]);
    try std.testing.expectEqual(@as(usize, 1), reg.batches.items[1].members.items.len);
    try std.testing.expectEqual(regions[1], reg.batches.items[1].members.items[0]);
}

test "only an answer that differs asks for a redraw" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();
    const r = reg.entry(.{ .selector = "status", .mode = .run, .width = 10, .height = 1, .exec = "true" }, 0).?;
    const a =
        \\{"version":1,"ok":true,"output":{"mode":"run","runs":[{"text":"a"}],"width":1}}
    ;
    const b =
        \\{"version":1,"ok":true,"output":{"mode":"run","runs":[{"text":"b"}],"width":1}}
    ;
    reg.finish(r, a, 1);
    try std.testing.expect(reg.takeChanged());
    reg.finish(r, a, 2);
    try std.testing.expect(!reg.takeChanged());
    reg.finish(r, b, 3);
    try std.testing.expect(reg.takeChanged());
}

fn countRuns(dir: std.fs.Dir, allocator: std.mem.Allocator) !usize {
    const runs = dir.readFileAlloc(allocator, "runs", 4096) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer allocator.free(runs);
    return std.mem.count(u8, runs, "run\n");
}

test "a drawn region refreshes itself, one no longer drawn does not" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    const log = try std.fs.path.join(allocator, &.{ dir, "runs" });
    defer allocator.free(log);
    const reply =
        \\{"version":1,"ok":true,"output":{"mode":"run","runs":[{"text":"x"}],"width":1}}
    ;
    const cmd = try framedReplies(allocator, log, &.{reply});
    defer allocator.free(cmd);

    var reg = Registry.init(allocator);
    defer reg.deinit();
    const spec = Spec{ .selector = "status", .mode = .run, .width = 10, .height = 1, .refresh_ms = 30, .exec = cmd };

    reg.beginFrame();
    try pollUntilDone(&reg, &.{spec});

    // Not drawn again, and still asked again once due.
    var spins: usize = 0;
    while (try countRuns(tmp.dir, allocator) < 2) : (spins += 1) {
        if (spins > 2000) return error.RegionNeverRefreshed;
        reg.poll();
        std.Thread.sleep(std.time.ns_per_ms);
    }

    // A frame that does not draw it retires it.
    reg.beginFrame();
    spins = 0;
    while (reg.busy()) : (spins += 1) {
        if (spins > 2000) return error.RunNeverFinished;
        reg.poll();
        std.Thread.sleep(std.time.ns_per_ms);
    }
    const settled = try countRuns(tmp.dir, allocator);
    for (0..100) |_| {
        reg.poll();
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expectEqual(settled, try countRuns(tmp.dir, allocator));
}

test "a request that changes is sent at once, even behind one in flight" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    const log = try std.fs.path.join(allocator, &.{ dir, "runs" });
    defer allocator.free(log);
    const reply =
        \\{"version":1,"ok":true,"output":{"mode":"run","runs":[{"text":"x"}],"width":1}}
    ;
    const cmd = try framedReplies(allocator, log, &.{reply});
    defer allocator.free(cmd);

    var reg = Registry.init(allocator);
    defer reg.deinit();
    const spec = Spec{ .selector = "status", .mode = .run, .width = 10, .height = 1, .exec = cmd };

    _ = reg.snapshot(spec, .{ .now_ms = 1, .cwd = "/a" });
    const r = reg.entries.get("status\x1frun\x1f").?;
    try std.testing.expect(r.inFlight());

    // Nowhere near due, but what would be sent changed.
    _ = reg.snapshot(spec, .{ .now_ms = 2, .cwd = "/b" });
    try std.testing.expect(r.has_staged);

    var spins: usize = 0;
    while (try countRuns(tmp.dir, allocator) < 2 or reg.busy()) : (spins += 1) {
        if (spins > 2000) return error.StagedRequestNeverSent;
        reg.poll();
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(std.mem.indexOf(u8, r.req.items, "\"/b\"") != null);
}

test "plain painter commands skip the shell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const direct = try painterArgv(a, "pixy serve  --stdio");
    try std.testing.expectEqual(@as(usize, 3), direct.len);
    try std.testing.expectEqualStrings("pixy", std.mem.span(direct[0].?));
    try std.testing.expectEqualStrings("--stdio", std.mem.span(direct[2].?));

    for ([_][]const u8{ "FOO=1 pixy", "pixy | tee x", "~/bin/p", "p \"a b\"", "p $HOME", "p >log" }) |cmd| {
        const shell = try painterArgv(a, cmd);
        try std.testing.expectEqualStrings("/bin/sh", std.mem.span(shell[0].?));
        try std.testing.expectEqualStrings(cmd, std.mem.span(shell[2].?));
    }
}

test "interactive regions parse with ids, geometry and actions" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    const spec = Spec{ .selector = "status", .mode = .run, .width = 100, .height = 1, .exec = "true" };
    const r = reg.entry(spec, 0).?;

    const frame =
        \\{"ok":true,"output":{"mode":"run","runs":[{"text":"x","style":""}],"width":1,
        \\"regions":[{"id":"tab.1","x":10,"y":0,"width":6,"height":1,
        \\"actions":{"left":"tab.select.1","right":"tab.close.1"},"hover_style":"fg:0 bg:7"}]}}
    ;
    try std.testing.expect(reg.parseResponse(r, frame));
    try std.testing.expectEqual(@as(usize, 1), r.hits.items.len);

    const hit = r.hits.items[0];
    try std.testing.expectEqualStrings("tab.1", hit.id);
    try std.testing.expectEqualStrings("tab.select.1", hit.actionFor(0));
    try std.testing.expectEqualStrings("", hit.actionFor(1));
    try std.testing.expectEqualStrings("tab.close.1", hit.actionFor(2));
    try std.testing.expect(hit.contains(10, 0));
    try std.testing.expect(hit.contains(15, 0));
    try std.testing.expect(!hit.contains(16, 0));
    try std.testing.expect(!hit.contains(9, 0));
    try std.testing.expectEqual(style_mod.Color{ .palette = 7 }, hit.hover_style.bg);
}
