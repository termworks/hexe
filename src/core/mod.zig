// Core - built entirely on ghostty-vt
const std = @import("std");
pub const build_options = @import("build_options");
const logging_mod = @import("logging.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logging_mod.stdLogFn,
};

pub const pty = @import("pty.zig");
pub const vt = @import("vt.zig");
pub const config = @import("config.zig");
pub const config_v2 = @import("config_v2.zig");
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
pub const cmd = @import("cmd.zig");
pub const strings = @import("strings.zig");
pub const sprites_embedded = @import("sprites_embedded.zig");
pub const constants = @import("constants.zig");
pub const resource_limits = @import("resource_limits.zig");
pub const isolation_voidbox = @import("isolation_voidbox.zig");
pub const session_config = @import("session_config.zig");
pub const session_model = @import("session_model.zig");
pub const trust = @import("trust.zig");
pub const session_projection = @import("session_projection.zig");
pub const frontend_attach_state = @import("frontend_attach_state.zig");
pub const frontend_attach = @import("frontend_attach.zig");
pub const frontend_runtime = @import("frontend_runtime.zig");
pub const frontend_transport_helpers = @import("frontend_transport_helpers.zig");
pub const frontend_client = @import("frontend_client.zig");
pub const recording = @import("recording/mod.zig");

pub const LuaRuntime = lua_runtime.LuaRuntime;
pub const SessionConfig = session_config.SessionConfig;
pub const ConfigStatus = lua_runtime.ConfigStatus;
pub const FrontendClient = frontend_client.SesClient;
pub const FrontendTransport = frontend_client.Transport;
pub const FrontendConnectOptions = frontend_transport_helpers.ConnectOptions;
pub const FrontendDetachedSessionInfo = frontend_client.DetachedSessionInfo;
pub const FrontendOrphanedPaneInfo = frontend_client.OrphanedPaneInfo;
pub const SessionProjection = session_projection.SessionProjection;
pub const FrontendAttachState = frontend_attach_state.FrontendAttachState;
pub const FrontendAttach = frontend_attach;
pub const FrontendRuntime = frontend_runtime.FrontendRuntime;
pub const FrontendTransportHelpers = frontend_transport_helpers;
pub const SessionProjectionTabFocusKind = session_projection.TabFocusKind;
pub const SessionProjectionPaneShellInfo = session_projection.PaneShellInfo;
pub const SessionProjectionPaneProcInfo = session_projection.PaneProcInfo;
pub const FrontendKind = wire.FrontendKind;
pub const FrontendTransportKind = wire.FrontendTransportKind;

pub const Pty = pty.Pty;
pub const VT = vt.VT;

// IPC exports
pub const IpcServer = ipc.Server;
pub const IpcClient = ipc.Client;
pub const IpcConnection = ipc.Connection;
pub const Config = config.Config;
pub const HexeConfigV2 = config_v2.HexeConfigV2;
pub const FloatDef = config.FloatDef;
pub const FloatStyle = config.FloatStyle;
pub const FloatStylePosition = config.FloatStylePosition;
pub const BorderColor = config.BorderColor;
pub const SplitStyle = config.SplitStyle;
pub const SplitsConfig = config.SplitsConfig;
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

test {
    // Collect the inline tests from each core submodule. We reference the
    // files explicitly rather than refAllDeclsRecursive(@This()): the latter
    // recurses through vt.zig into the ghostty-vt module's internal decls and
    // tries to compile them standalone (dcimgui/oniguruma), which fails in a
    // test build. `_ = @import(f)` forces analysis of f's own test blocks
    // without deep-walking third-party module internals.
    _ = @import("strings.zig");
    _ = @import("uuid.zig");
    _ = @import("config.zig");
    _ = @import("config_v2.zig");
    _ = @import("session_config.zig");
    _ = @import("lua_runtime.zig");
    _ = @import("lua_api_exec.zig");
    _ = @import("api_bridge.zig");
    _ = @import("frontend_client.zig");
    _ = @import("frontend_liblink_transport.zig");
    _ = @import("recording/asciicast.zig");
    _ = @import("pod_protocol.zig");
    _ = @import("resource_limits.zig");
}
