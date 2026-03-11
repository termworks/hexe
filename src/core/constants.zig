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

    /// Timeout for SES state operations
    /// Used in: src/modules/session/state.zig
    pub const ses_spawn_timeout: i64 = 2000;

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
    /// Maximum number of concurrent clients for SES daemon
    /// Used in: src/modules/session/server.zig
    pub const max_clients: usize = 64;

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

    /// Maximum captured output for pane capture (1MB)
    /// Used in: src/frontends/terminal/pane_capture.zig
    pub const max_captured_output: usize = 1024 * 1024;

    /// Maximum reasonable terminal rows (sanity check)
    /// Used in: src/core/vt.zig, src/frontends/terminal/render_state_blit.zig
    pub const max_reasonable_rows: usize = 10000;

    /// Maximum reasonable terminal columns (sanity check)
    /// Used in: src/core/vt.zig, src/frontends/terminal/render_state_blit.zig
    pub const max_reasonable_cols: usize = 1000;
};
