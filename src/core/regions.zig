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
/// Minimum gap between attempts to start a painter that is not running.
pub const SPAWN_COOLDOWN_MS: i64 = 5_000;

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
    socket_path: ?[]const u8 = null,
    refresh_ms: i64 = DEFAULT_REFRESH_MS,
    stale_ms: i64 = DEFAULT_STALE_MS,
    /// Distinguishes instances of the same view fetched for different subjects
    /// (per-pane sprites, per-float titles), which otherwise share one entry.
    key_suffix: []const u8 = "",
    /// Optional command to start the painter when nothing is listening. Run
    /// detached through `/bin/sh -c`; hexe never waits on it.
    command: ?[]const u8 = null,
    /// Run this painter as our OWN child and speak the same frames over its
    /// pipes, instead of connecting to a socket somebody else is holding.
    ///
    /// A shared socket painter is one process every session on the machine
    /// talks to: its accept loop serialises them, its config outlives the
    /// binary that made it, and a slow render is everyone's. A child is spawned
    /// once, answers many requests down the same pipe, and dies with us.
    exec: ?[]const u8 = null,
};

const Phase = enum { idle, connecting, writing, reading };

const Region = struct {
    key: []u8,
    selector: []u8,
    socket_path: []u8,
    mode: Mode,
    refresh_ms: i64,
    stale_ms: i64,
    width: u16 = 0,
    height: u16 = 1,

    /// Read side. For a socket this is the connection; for a child it is the
    /// pipe from its stdout.
    fd: ?posix.fd_t = null,
    /// Write side, separate only for a child. Equal to `fd` on a socket, which
    /// is what lets one pump serve both.
    wfd: ?posix.fd_t = null,
    /// The painter we own, kept between requests so the Lua VM and config are
    /// paid for once rather than per frame.
    child: ?std.process.Child = null,
    exec: ?[]u8 = null,
    phase: Phase = .idle,
    req: std.ArrayList(u8) = .empty,
    req_off: usize = 0,
    hdr: [4]u8 = [_]u8{0} ** 4,
    hdr_off: usize = 0,
    body: std.ArrayList(u8) = .empty,
    body_need: usize = 0,
    started_ms: i64 = 0,

    runs: std.ArrayList(Run) = .empty,
    run_text: std.ArrayList(u8) = .empty,
    ansi: std.ArrayList(u8) = .empty,
    hits: std.ArrayList(Interactive) = .empty,
    hit_text: std.ArrayList(u8) = .empty,
    out_width: u16 = 0,
    next_frame_ms: ?u64 = null,

    command: ?[]u8 = null,
    /// When the painter was last started, so a dead command is not respawned
    /// on every retry.
    spawned_ms: i64 = 0,

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
};

/// Where hexe looks for a painter when the config does not say.
///
/// `HEXE_PAINTER_SOCKET` first, so a painter can advertise itself without the
/// user editing config at all.
pub fn defaultSocketPath(allocator: std.mem.Allocator) ![]u8 {
    if (posix.getenv("HEXE_PAINTER_SOCKET")) |path| {
        return allocator.dupe(u8, path);
    }
    if (posix.getenv("XDG_RUNTIME_DIR")) |dir| {
        return std.fmt.allocPrint(allocator, "{s}/hexe/painter.sock", .{dir});
    }
    return std.fmt.allocPrint(allocator, "/tmp/hexe-{d}/painter.sock", .{std.os.linux.getuid()});
}

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
    /// Painters this registry started. Reaped without blocking in `poll()`;
    /// unreaped they would be a zombie per spawn for the life of the process.
    spawned: std.ArrayList(std.process.Child) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(*Region).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.entries.valueIterator();
        while (it.next()) |slot| self.destroyRegion(slot.*);
        self.entries.deinit();
        // Collect what has already exited; anything still running is reparented
        // to init, so it cannot become a lasting zombie.
        for (self.spawned.items) |*c| _ = posix.waitpid(c.id, posix.W.NOHANG);
        self.spawned.deinit(self.allocator);
    }

    /// Collect exited painters. Never blocks.
    fn reapSpawned(self: *Registry) void {
        var i: usize = 0;
        while (i < self.spawned.items.len) {
            const res = posix.waitpid(self.spawned.items[i].id, posix.W.NOHANG);
            if (res.pid != 0) {
                _ = self.spawned.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    fn destroyRegion(self: *Registry, r: *Region) void {
        self.closeConn(r);
        r.req.deinit(self.allocator);
        r.body.deinit(self.allocator);
        r.runs.deinit(self.allocator);
        r.run_text.deinit(self.allocator);
        r.hits.deinit(self.allocator);
        r.hit_text.deinit(self.allocator);
        r.ansi.deinit(self.allocator);
        self.allocator.free(r.key);
        self.allocator.free(r.selector);
        self.allocator.free(r.socket_path);
        if (r.command) |c| self.allocator.free(c);
        if (r.exec) |c| self.allocator.free(c);
        // A painter we own goes when its region does, or it outlives what it
        // was drawing -- which is the shared-daemon problem in miniature.
        self.dropChild(r);
        self.allocator.destroy(r);
    }

    /// End the current request. A socket connection is per-request and closed;
    /// a child's pipes are the point of having a child and stay open.
    fn closeConn(self: *Registry, r: *Region) void {
        _ = self;
        if (r.child == null) {
            if (r.fd) |fd| posix.close(fd);
            r.fd = null;
            r.wfd = null;
        }
        r.phase = .idle;
        r.req_off = 0;
        r.hdr_off = 0;
        r.body_need = 0;
    }

    /// Take down the painter we own. Its pipes go with it, so the next fetch
    /// starts a fresh one -- which is the recovery for a child that died,
    /// wedged, or answered something unparseable.
    fn dropChild(self: *Registry, r: *Region) void {
        if (r.child) |*c| {
            if (r.fd) |fd| posix.close(fd);
            if (r.wfd) |fd| posix.close(fd);
            c.stdin = null;
            c.stdout = null;
            _ = c.kill() catch {};
            r.child = null;
            logging.warn("regions", "painter child for '{s}' was taken down; it will be restarted", .{r.selector});
        }
        r.fd = null;
        r.wfd = null;
        r.phase = .idle;
        _ = self;
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

        // Geometry changes force a refetch: the painter lays out to the width
        // it was given, so a stale frame at the old width is wrong, not merely old.
        const resized = r.width != spec.width or r.height != spec.height;
        r.width = spec.width;
        r.height = spec.height;

        // A resize invalidates the last frame, but it must not bypass the
        // backoff: otherwise a dead painter is retried on every resize event.
        if (!r.inFlight() and now >= r.next_try_ms and (resized or self.isDue(r, now))) {
            self.begin(r, ctx, now);
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

    fn isDue(self: *Registry, r: *Region, now: i64) bool {
        _ = self;
        if (now < r.next_try_ms) return false;
        if (r.last_done_ms == 0) return true;
        // The painter tells us when its own next frame is due; honour it when
        // it asks for a shorter interval than the configured refresh.
        const interval: i64 = if (r.next_frame_ms) |nf|
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

        const socket_path = if (spec.socket_path) |p|
            self.allocator.dupe(u8, p) catch return null
        else
            defaultSocketPath(self.allocator) catch return null;

        const r = self.allocator.create(Region) catch {
            self.allocator.free(socket_path);
            return null;
        };
        const key_owned = self.allocator.dupe(u8, key) catch {
            self.allocator.free(socket_path);
            self.allocator.destroy(r);
            return null;
        };
        const selector_owned = self.allocator.dupe(u8, spec.selector) catch {
            self.allocator.free(key_owned);
            self.allocator.free(socket_path);
            self.allocator.destroy(r);
            return null;
        };

        const command_owned: ?[]u8 = if (spec.command) |c|
            (self.allocator.dupe(u8, c) catch null)
        else
            null;

        const exec_owned: ?[]u8 = if (spec.exec) |c|
            (self.allocator.dupe(u8, c) catch null)
        else
            null;

        r.* = .{
            .key = key_owned,
            .selector = selector_owned,
            .socket_path = socket_path,
            .command = command_owned,
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

    /// Open the socket and queue the request. Any failure here is a failed
    /// fetch, not an error the caller sees.
    fn begin(self: *Registry, r: *Region, ctx: RequestContext, now: i64) void {
        r.req.clearRetainingCapacity();
        r.req_off = 0;
        r.hdr_off = 0;
        r.body.clearRetainingCapacity();
        r.body_need = 0;

        self.buildRequest(r, ctx) catch {
            self.fail(r, now);
            return;
        };

        // Our own painter, if this region was configured with one: spawned on
        // the first fetch and kept, so every later request is a write and a
        // read down a pipe that is already open.
        if (r.exec != null) {
            if (r.child == null) self.startChild(r, now) catch {
                self.fail(r, now);
                return;
            };
            r.started_ms = now;
            r.phase = .writing;
            self.pump(r, now);
            return;
        }

        const fd = posix.socket(
            posix.AF.UNIX,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            0,
        ) catch {
            self.fail(r, now);
            return;
        };

        var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = [_]u8{0} ** 108 };
        if (r.socket_path.len >= addr.path.len) {
            posix.close(fd);
            self.fail(r, now);
            return;
        }
        @memcpy(addr.path[0..r.socket_path.len], r.socket_path);

        r.fd = fd;
        r.started_ms = now;
        posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| switch (err) {
            error.WouldBlock => {
                r.phase = .connecting;
                return;
            },
            else => {
                self.fail(r, now);
                return;
            },
        };
        r.phase = .writing;
        self.pump(r, now);
    }

    /// Advance every in-flight region. Non-blocking throughout.
    pub fn poll(self: *Registry) void {
        self.reapSpawned();
        const now = std.time.milliTimestamp();
        var it = self.entries.valueIterator();
        while (it.next()) |slot| {
            const r = slot.*;
            if (!r.inFlight()) continue;
            if (now - r.started_ms > HARD_DEADLINE_MS) {
                logging.warn("regions", "painter did not answer within {d}ms: {s}", .{ HARD_DEADLINE_MS, r.selector });
                self.fail(r, now);
                continue;
            }
            self.pump(r, now);
        }
    }

    fn pump(self: *Registry, r: *Region, now: i64) void {
        const fd = r.fd orelse {
            self.fail(r, now);
            return;
        };
        // The same pump serves both transports: a socket hands back one fd for
        // each direction, a child hands back two.
        const wfd = r.wfd orelse fd;

        if (r.phase == .connecting) {
            var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
            const ready = posix.poll(&pfd, 0) catch {
                self.fail(r, now);
                return;
            };
            if (ready == 0) return;
            if (pfd[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
                self.fail(r, now);
                return;
            }
            if (pfd[0].revents & posix.POLL.OUT == 0) return;
            r.phase = .writing;
        }

        if (r.phase == .writing) {
            while (r.req_off < r.req.items.len) {
                const n = posix.write(wfd, r.req.items[r.req_off..]) catch |err| switch (err) {
                    error.WouldBlock => return,
                    else => {
                        self.fail(r, now);
                        return;
                    },
                };
                if (n == 0) {
                    self.fail(r, now);
                    return;
                }
                r.req_off += n;
            }
            r.phase = .reading;
        }

        if (r.phase != .reading) return;

        while (r.hdr_off < 4) {
            const n = posix.read(fd, r.hdr[r.hdr_off..]) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    self.fail(r, now);
                    return;
                },
            };
            if (n == 0) {
                self.fail(r, now);
                return;
            }
            r.hdr_off += n;
        }
        if (r.body_need == 0) {
            const len = std.mem.readInt(u32, &r.hdr, .big);
            if (len == 0 or len > MAX_FRAME) {
                self.fail(r, now);
                return;
            }
            r.body_need = len;
            r.body.ensureTotalCapacity(self.allocator, len) catch {
                self.fail(r, now);
                return;
            };
        }

        var chunk: [8192]u8 = undefined;
        while (r.body.items.len < r.body_need) {
            const want = @min(chunk.len, r.body_need - r.body.items.len);
            const n = posix.read(fd, chunk[0..want]) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    self.fail(r, now);
                    return;
                },
            };
            if (n == 0) {
                self.fail(r, now);
                return;
            }
            r.body.appendSlice(self.allocator, chunk[0..n]) catch {
                self.fail(r, now);
                return;
            };
        }

        self.finish(r, now);
    }

    /// A completed frame arrived: parse it and retire the connection.
    fn finish(self: *Registry, r: *Region, now: i64) void {
        r.declined = false;
        r.answered = false;
        const parsed = self.parseResponse(r, r.body.items);
        self.closeConn(r);
        if (parsed) {
            r.last_done_ms = now;
            r.fail_streak = 0;
            r.next_try_ms = 0;
            return;
        }
        // A painter that answers `ok:false` is UP and simply does not implement
        // this view. Backing off through the failure ladder also re-ran
        // `command`, so a declining painter was relaunched forever (every
        // SPAWN_COOLDOWN_MS, capped only by the retry ceiling). Retry on the
        // ordinary cadence instead, and never spawn: nothing is missing.
        if (r.declined) {
            r.fail_streak = 0;
            r.next_try_ms = now + @max(r.refresh_ms, RETRY_BASE_MS);
            return;
        }
        // A frame that parsed but carried a body this mode cannot use still
        // proves the painter is running: back off, but do not fork another one.
        self.backoffInner(r, now, !r.answered);
    }

    fn fail(self: *Registry, r: *Region, now: i64) void {
        // A broken pipe means the child is gone or out of step with us, and
        // reusing it would resynchronise onto the middle of a frame.
        if (r.child != null) self.dropChild(r);
        self.closeConn(r);
        self.backoff(r, now);
    }

    /// Spawn the painter we own and keep its pipes.
    ///
    /// Both ends are non-blocking, because everything in `pump` is: a painter
    /// that stops reading must cost a stale region, never a stalled frame. The
    /// child is `/bin/sh -c` like the detached spawner, so a configured command
    /// means the same thing in both transports.
    fn startChild(self: *Registry, r: *Region, now: i64) !void {
        const cmd = r.exec orelse return error.NoCommand;
        var child = std.process.Child.init(&.{ "/bin/sh", "-c", cmd }, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        // Left alone: a painter's diagnostics belong on the terminal that
        // started hexe, not swallowed into a pipe nobody drains.
        child.stderr_behavior = .Inherit;
        try child.spawn();

        const in_fd = child.stdin.?.handle;
        const out_fd = child.stdout.?.handle;
        setNonBlocking(in_fd) catch {};
        setNonBlocking(out_fd) catch {};

        r.child = child;
        r.wfd = in_fd;
        r.fd = out_fd;
        r.spawned_ms = now;
    }

    /// Start the configured painter, detached. Never waits, never retries fast:
    /// a command that exits immediately must not become a fork loop.
    fn spawnPainter(self: *Registry, r: *Region, now: i64) void {
        const cmd = r.command orelse return;
        if (r.spawned_ms != 0 and now - r.spawned_ms < SPAWN_COOLDOWN_MS) return;
        r.spawned_ms = now;

        var child = std.process.Child.init(&.{ "/bin/sh", "-c", cmd }, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch |err| {
            logging.logError("regions", "failed to start painter", err);
            return;
        };
        logging.warn("regions", "started painter: {s}", .{cmd});
        // Tracked only so poll() can reap it. Never waited on: that is exactly
        // the stall this module exists to avoid.
        self.spawned.append(self.allocator, child) catch {
            _ = posix.waitpid(child.id, posix.W.NOHANG);
        };
    }

    /// Milliseconds until the soonest live region is due, or null when nothing
    /// is scheduled. `next_frame_ms` was only ever a gate inside isDue(), so a
    /// painter asking for 75ms still repainted at the loop's own cadence; the
    /// caller uses this to arm its timer for the painter's frame instead.
    pub fn msUntilDue(self: *Registry, now: i64) ?i64 {
        var soonest: ?i64 = null;
        var it = self.entries.valueIterator();
        while (it.next()) |r| {
            if (r.*.inFlight()) continue;
            if (r.*.next_try_ms != 0 and now < r.*.next_try_ms) continue;
            const interval: i64 = if (r.*.next_frame_ms) |nf|
                @min(r.*.refresh_ms, @as(i64, @intCast(nf)))
            else
                r.*.refresh_ms;
            const due = r.*.last_done_ms + @max(interval, 16);
            const delta = @max(due - now, 0);
            if (soonest == null or delta < soonest.?) soonest = delta;
        }
        return soonest;
    }

    fn backoff(self: *Registry, r: *Region, now: i64) void {
        self.backoffInner(r, now, true);
    }

    /// `spawn` is false when the painter demonstrably answered: the retry ladder
    /// still applies, because hammering a painter that cannot serve this view is
    /// no better than hammering a dead one, but running `command` again would
    /// fork a second copy of a process that is already up.
    fn backoffInner(self: *Registry, r: *Region, now: i64, spawn: bool) void {
        r.fail_streak +|= 1;
        const shift: u6 = @intCast(@min(r.fail_streak - 1, 6));
        const delay = @min(RETRY_BASE_MS * (@as(i64, 1) << shift), RETRY_MAX_MS);
        r.next_try_ms = now + delay;
        if (spawn) self.spawnPainter(r, now);
    }

    fn buildRequest(self: *Registry, r: *Region, ctx: RequestContext) !void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);
        const w = body.writer(self.allocator);

        try w.writeAll("{\"version\":1,\"select\":[");
        try writeJsonString(w, r.selector);
        try w.print("],\"mode\":\"{s}\",\"width\":{d},\"height\":{d},\"now_ms\":{d},\"ignore_missing\":false,\"context\":{{", .{
            r.mode.wireName(), r.width, r.height, ctx.now_ms,
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
        try w.writeAll("}}}");

        if (body.items.len > MAX_FRAME) return error.FrameTooLarge;

        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr, @intCast(body.items.len), .big);
        try r.req.appendSlice(self.allocator, &hdr);
        try r.req.appendSlice(self.allocator, body.items);
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
        defer parsed.deinit();

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

    const spec = Spec{ .selector = "status", .mode = .run, .width = 40, .height = 1 };
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

    const spec = Spec{ .selector = "overlay.sprite", .mode = .surface, .width = 10, .height = 4 };
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

    const spec = Spec{ .selector = "status", .mode = .run, .width = 40, .height = 1 };
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

    const spec = Spec{ .selector = "prompt.left", .mode = .run, .width = 100, .height = 1 };
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

/// Minimal stand-in for the painter: accepts one connection, reads the request
/// frame, and writes back `reply` framed the same way.
const FakePainter = struct {
    path: []const u8,
    reply: []const u8,
    listen_fd: posix.fd_t,
    thread: ?std.Thread = null,

    fn start(path: []const u8, reply: []const u8) !*FakePainter {
        const self = try std.testing.allocator.create(FakePainter);
        errdefer std.testing.allocator.destroy(self);

        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = [_]u8{0} ** 108 };
        @memcpy(addr.path[0..path.len], path);
        posix.unlink(path) catch {};
        try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        try posix.listen(fd, 4);

        self.* = .{ .path = path, .reply = reply, .listen_fd = fd };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    fn serve(self: *FakePainter) void {
        const conn = posix.accept(self.listen_fd, null, null, 0) catch return;
        defer posix.close(conn);

        var hdr: [4]u8 = undefined;
        var got: usize = 0;
        while (got < 4) {
            const n = posix.read(conn, hdr[got..]) catch return;
            if (n == 0) return;
            got += n;
        }
        const need = std.mem.readInt(u32, &hdr, .big);
        var sink: [65536]u8 = undefined;
        var read_total: usize = 0;
        while (read_total < need) {
            const want = @min(sink.len, need - read_total);
            const n = posix.read(conn, sink[0..want]) catch return;
            if (n == 0) return;
            read_total += n;
        }

        var out_hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &out_hdr, @intCast(self.reply.len), .big);
        _ = posix.write(conn, &out_hdr) catch return;
        _ = posix.write(conn, self.reply) catch return;
    }

    fn stop(self: *FakePainter) void {
        if (self.thread) |t| t.join();
        posix.close(self.listen_fd);
        posix.unlink(self.path) catch {};
        std.testing.allocator.destroy(self);
    }
};

test "fetches a run frame over a real socket without blocking" {
    const allocator = std.testing.allocator;
    const path = "/tmp/hexe-regions-test-run.sock";
    const reply =
        \\{"version":1,"ok":true,"output":{"mode":"run","runs":[{"text":" hi ","style":"fg:15 bg:237 bold"}],"width":4,"next_frame_ms":null}}
    ;
    const painter = try FakePainter.start(path, reply);
    defer painter.stop();

    var reg = Registry.init(allocator);
    defer reg.deinit();

    const spec = Spec{
        .selector = "status",
        .mode = .run,
        .width = 80,
        .height = 1,
        .socket_path = path,
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

test "a painter that never answers leaves the region empty and never blocks" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    // Nothing is listening on this path.
    const spec = Spec{
        .selector = "status",
        .mode = .run,
        .width = 80,
        .height = 1,
        .socket_path = "/tmp/hexe-regions-test-absent.sock",
    };

    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const snap = reg.snapshot(spec, .{ .now_ms = @intCast(i) });
        try std.testing.expect(!snap.done);
        reg.poll();
    }
    // 200 render passes against a dead painter must cost effectively nothing.
    try std.testing.expect(timer.read() < 500 * std.time.ns_per_ms);
}

test "backoff grows and a good frame clears it" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    const spec = Spec{ .selector = "status", .mode = .run, .width = 40, .height = 1 };
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

test "interactive regions parse with ids, geometry and actions" {
    const allocator = std.testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    const spec = Spec{ .selector = "status", .mode = .run, .width = 100, .height = 1 };
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
