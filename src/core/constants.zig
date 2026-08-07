/// Centralized constants for the Hexa terminal multiplexer.
/// All timing, size limits, and configuration constants should be defined here
/// to improve maintainability and make them easy to find and modify.
const std = @import("std");

/// Timing-related constants (all values in milliseconds)
pub const Timing = struct {
    /// Status bar update interval for non-animated content
    /// Used in: src/frontends/terminal/loop_core.zig
    pub const status_update_interval_base: i64 = 250;

    /// Status bar update interval when animations are active
    /// Used in: src/frontends/terminal/loop_core.zig
    pub const status_update_interval_anim: i64 = 75;

    /// Interval for syncing pane info (CWD, foreground process)
    /// Used in: src/frontends/terminal/loop_core.zig
    pub const pane_sync_interval: i64 = 1000;

    /// Heartbeat interval for keeping SES connection alive
    /// Used in: src/frontends/terminal/loop_core.zig
    pub const heartbeat_interval: i64 = 30000;

    /// Timeout for spawning new pod processes
    /// Used in: src/cli/commands/pod_new.zig
    pub const pod_spawn_timeout: i64 = 2500;

    /// Budget for reading a newly spawned pod's handshake line.
    ///
    /// This is a BLOCKING wait on the single-threaded SES event loop, so it is
    /// also the worst-case stall every other session pays for one pane
    /// creation (PLAN.md 1.1). With the CTL read/reply stalls removed in
    /// 1.2/1.5 it is now the largest remaining one, so it is bounded by data
    /// rather than by a round number: measured over 10 spawns on a box at load
    /// ~58/24 cores, the handshake takes min 15ms, median 22ms, max 31ms. 500ms
    /// keeps ~16x headroom over that while cutting the worst-case freeze 4x,
    /// and matches HANDLER_IO_TIMEOUT_MS, the established bounded-stall budget
    /// elsewhere in the daemon.
    ///
    /// Overshooting it fails ONE create_pane with a visible "create_failed"
    /// that the user can retry; the old budget instead froze every session for
    /// 2s, invisibly. Removing the wait entirely needs the async spawn state
    /// machine, which is the rest of 1.1.
    /// Used in: src/modules/session/pane_spawn.zig
    pub const ses_spawn_timeout: i64 = 500;

    /// Key repeat event tracking timeout
    /// Used in: src/frontends/terminal/keybinds.zig
    pub const key_repeat_timeout: i64 = 100;

    /// Mouse acceleration timeout for rapid movements
    /// Used in: src/frontends/terminal/loop_input.zig
    pub const mouse_acceleration_timeout: i64 = 500;

    /// Internal poll interval for key timer checks
    /// Used in: src/frontends/terminal/loop_core.zig
    pub const key_timer_interval: i64 = 30;
};

/// Connection and client limits
pub const Limits = struct {
    /// Maximum number of concurrent registered CLIENTS (frontends) for SES.
    /// Used in: src/modules/session/server.zig
    pub const max_clients: usize = 64;

    /// Maximum concurrent SOCKET connections SES will hold.
    ///
    /// Distinct from `max_clients`, and much larger, because it counts every
    /// fd — not just registered frontends. SES holds two connections per pane
    /// (the pod's CTL uplink and its VT channel) plus two per frontend, so a
    /// 30-pane session already sits near 62. Reusing the 64-client number here
    /// would start refusing connections at roughly 32 panes.
    ///
    /// It exists so that accepted-but-unregistered connections cannot evade the
    /// cap (PLAN.md A-13) — the DoS vector — while leaving ordinary large
    /// sessions far below the ceiling. 512 allows ~250 panes.
    pub const max_connections: usize = 512;

    /// Maximum retry attempts for wire protocol operations
    /// Used in: src/core/wire.zig
    pub const max_wire_retries: usize = 10;
};

/// Buffer and payload size limits
pub const Sizes = struct {
    /// Maximum payload length for wire protocol messages (4MB)
    /// Used in: src/core/wire.zig, src/core/pod_protocol.zig
    pub const max_payload_len: usize = 4 * 1024 * 1024;

    /// Maximum frame length (same as max payload)
    /// Used in: src/core/pod_protocol.zig
    pub const max_frame_len: usize = max_payload_len;

    /// Maximum clipboard data size (128KB)
    /// Used in: src/frontends/terminal/clipboard.zig
    pub const max_clipboard_bytes: usize = 128 * 1024;

    /// Maximum encoded OSC 52 sequence size.
    pub const max_clipboard_osc_bytes: usize = ((max_clipboard_bytes + 2) / 3) * 4 + 16;

    /// Maximum reasonable terminal rows (sanity check)
    /// Used in: src/core/vt.zig, src/frontends/terminal/render_state_blit.zig
    pub const max_reasonable_rows: usize = 10000;

    /// Maximum reasonable terminal columns (sanity check)
    /// Used in: src/core/vt.zig, src/frontends/terminal/render_state_blit.zig
    pub const max_reasonable_cols: usize = 1000;
};
