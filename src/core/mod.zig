// Core - built entirely on ghostty-vt

pub const pty = @import("pty.zig");
pub const vt = @import("vt.zig");
pub const config = @import("config.zig");
pub const ipc = @import("ipc.zig");
pub const wire = @import("wire.zig");
pub const query = @import("query.zig");
pub const style = @import("style.zig");
pub const segment_render = @import("segment_render.zig");
pub const segments = @import("segments/mod.zig");
pub const pod_protocol = @import("pod_protocol.zig");
pub const pod_meta = @import("pod_meta.zig");
pub const lua_runtime = @import("lua_runtime.zig");
pub const config_builder = @import("config_builder.zig");
pub const uuid = @import("uuid.zig");
pub const logging = @import("logging.zig");
pub const strings = @import("strings.zig");
pub const sprites_embedded = @import("sprites_embedded.zig");
pub const constants = @import("constants.zig");
pub const resource_limits = @import("resource_limits.zig");
pub const isolation_voidbox = @import("isolation_voidbox.zig");
pub const session_config = @import("session_config.zig");
pub const session_model = @import("session_model.zig");
pub const frontend_session_cache = @import("frontend_session_cache.zig");
pub const frontend_client = @import("frontend_client.zig");
pub const recording = @import("recording/mod.zig");

pub const LuaRuntime = lua_runtime.LuaRuntime;
pub const SessionConfig = session_config.SessionConfig;
pub const ConfigStatus = lua_runtime.ConfigStatus;
pub const FrontendClient = frontend_client.SesClient;
pub const FrontendTransport = frontend_client.Transport;
pub const FrontendDetachedSessionInfo = frontend_client.DetachedSessionInfo;
pub const FrontendOrphanedPaneInfo = frontend_client.OrphanedPaneInfo;
pub const FrontendSessionCache = frontend_session_cache.FrontendSessionCache;
pub const FrontendTabFocusKind = frontend_session_cache.TabFocusKind;
pub const FrontendKind = wire.FrontendKind;
pub const FrontendTransportKind = wire.FrontendTransportKind;

pub const Pty = pty.Pty;
pub const VT = vt.VT;

// IPC exports
pub const IpcServer = ipc.Server;
pub const IpcClient = ipc.Client;
pub const IpcConnection = ipc.Connection;
pub const Config = config.Config;
pub const FloatDef = config.FloatDef;
pub const FloatStyle = config.FloatStyle;
pub const FloatStylePosition = config.FloatStylePosition;
pub const BorderColor = config.BorderColor;
pub const SplitStyle = config.SplitStyle;
pub const SplitsConfig = config.SplitsConfig;
pub const PanesConfig = config.PanesConfig;
pub const SesConfig = config.SesConfig;
pub const LayoutDef = config.LayoutDef;
pub const LayoutTabDef = config.LayoutTabDef;
pub const LayoutFloatDef = config.LayoutFloatDef;
pub const LayoutSplitDef = config.LayoutSplitDef;
pub const LayoutPaneDef = config.LayoutPaneDef;
pub const Segment = config.Segment;
pub const OutputDef = config.OutputDef;
pub const WhenDef = config.WhenDef;
pub const SpinnerDef = config.SpinnerDef;
pub const NotificationStyleConfig = config.NotificationStyleConfig;
pub const NotificationConfig = config.NotificationConfig;
pub const PaneQuery = query.PaneQuery;
