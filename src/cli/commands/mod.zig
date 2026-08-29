//! The `hexe` subcommand implementations, as one module.
//!
//! These are a module rather than a pile of files imported into `app.zig` so
//! they can be compiled for size while the frontend is compiled for speed. A
//! subcommand runs once and exits; `zig build -h` explains the trade next to
//! the `cold` mode in build.zig.
//!
//! The boundary is cheap because these files only ever reach for `core`, `xev`
//! and the terminal frontend's entry point -- nothing here is on a hot path,
//! and nothing on a hot path reaches back in.

pub const api = @import("api.zig");
pub const com = @import("com.zig");
pub const com_layout = @import("com_layout.zig");
pub const config_validate = @import("config_validate.zig");
pub const lua_api = @import("lua_api.zig");
pub const mux_float = @import("mux_float.zig");
pub const mux_record = @import("mux_record.zig");
pub const palette = @import("palette.zig");
pub const plugin = @import("plugin.zig");
pub const pod_attach = @import("pod_attach.zig");
pub const pod_gc = @import("pod_gc.zig");
pub const pod_kill = @import("pod_kill.zig");
pub const pod_list = @import("pod_list.zig");
pub const pod_new = @import("pod_new.zig");
pub const pod_record = @import("pod_record.zig");
pub const pod_send = @import("pod_send.zig");
pub const pod_share = @import("pod_share.zig");
pub const profile = @import("profile.zig");
pub const record_ctl = @import("record_ctl.zig");
pub const ses_export = @import("ses_export.zig");
pub const ses_freeze = @import("ses_freeze.zig");
pub const ses_open = @import("ses_open.zig");
pub const ses_pipe = @import("ses_pipe.zig");
pub const ses_stats = @import("ses_stats.zig");
pub const shared = @import("shared.zig");
pub const tty = @import("tty.zig");
