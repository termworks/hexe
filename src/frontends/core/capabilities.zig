const std = @import("std");
const core = @import("core");

/// Host capability flags advertised by concrete frontend adapters.
///
/// These are intentionally coarse-grained. The first useful boundary is whether
/// a frontend can represent a feature at all; later protocol negotiation can
/// refine exact browser/terminal versions, render formats, and auth policies.
pub const HostCapabilities = struct {
    frontend_kind: core.wire.FrontendKind,
    interactive_input: bool = true,
    cell_render: bool = true,
    pixel_render: bool = false,
    mouse: bool = false,
    clipboard: bool = false,
    desktop_notify: bool = false,
    reconnect: bool = false,
    remote_transport: bool = false,
};

pub fn defaultCapabilities(kind: core.wire.FrontendKind) HostCapabilities {
    return switch (kind) {
        .terminal => .{
            .frontend_kind = .terminal,
            .mouse = true,
            .clipboard = true,
            .desktop_notify = true,
        },
        // `pixel_render` is deliberately NOT advertised: there is no pixel
        // renderer anywhere yet — the web/desktop hosts are cell/snapshot
        // consumers. The remaining flags below describe input events these
        // adapters already translate (see WebHost.mapBrowserEvent /
        // SyslinkHost.mapRemoteEvent); re-add `pixel_render` when a real
        // pixel-drawing frontend lands.
        .web => .{
            .frontend_kind = .web,
            .mouse = true,
            .clipboard = true,
            .desktop_notify = true,
            .reconnect = true,
        },
        .desktop => .{
            .frontend_kind = .desktop,
            .mouse = true,
            .clipboard = true,
            .desktop_notify = true,
            .reconnect = true,
            .remote_transport = true,
        },
    };
}

pub fn toWireFlags(caps: HostCapabilities) u32 {
    var flags: u32 = 0;
    if (caps.interactive_input) flags |= core.wire.FrontendCapabilityFlag.interactive_input;
    if (caps.cell_render) flags |= core.wire.FrontendCapabilityFlag.cell_render;
    if (caps.pixel_render) flags |= core.wire.FrontendCapabilityFlag.pixel_render;
    if (caps.mouse) flags |= core.wire.FrontendCapabilityFlag.mouse;
    if (caps.clipboard) flags |= core.wire.FrontendCapabilityFlag.clipboard;
    if (caps.desktop_notify) flags |= core.wire.FrontendCapabilityFlag.desktop_notify;
    if (caps.reconnect) flags |= core.wire.FrontendCapabilityFlag.reconnect;
    if (caps.remote_transport) flags |= core.wire.FrontendCapabilityFlag.remote_transport;
    return flags;
}

pub fn fromWireFlags(kind: core.wire.FrontendKind, flags: u32) HostCapabilities {
    return .{
        .frontend_kind = kind,
        .interactive_input = (flags & core.wire.FrontendCapabilityFlag.interactive_input) != 0,
        .cell_render = (flags & core.wire.FrontendCapabilityFlag.cell_render) != 0,
        .pixel_render = (flags & core.wire.FrontendCapabilityFlag.pixel_render) != 0,
        .mouse = (flags & core.wire.FrontendCapabilityFlag.mouse) != 0,
        .clipboard = (flags & core.wire.FrontendCapabilityFlag.clipboard) != 0,
        .desktop_notify = (flags & core.wire.FrontendCapabilityFlag.desktop_notify) != 0,
        .reconnect = (flags & core.wire.FrontendCapabilityFlag.reconnect) != 0,
        .remote_transport = (flags & core.wire.FrontendCapabilityFlag.remote_transport) != 0,
    };
}

test "defaultCapabilities separates terminal and web concerns" {
    const terminal = defaultCapabilities(.terminal);
    const web = defaultCapabilities(.web);

    try std.testing.expectEqual(core.wire.FrontendKind.terminal, terminal.frontend_kind);
    try std.testing.expect(terminal.cell_render);
    try std.testing.expect(!terminal.pixel_render);
    try std.testing.expect(!terminal.remote_transport);

    try std.testing.expectEqual(core.wire.FrontendKind.web, web.frontend_kind);
    try std.testing.expect(web.cell_render);
    // No pixel renderer exists yet — must not be advertised (honesty, PLAN 3.2).
    try std.testing.expect(!web.pixel_render);
    try std.testing.expect(web.reconnect);
}

test "defaultCapabilities marks syslink-style desktop host as remote capable" {
    const syslink = defaultCapabilities(.desktop);

    try std.testing.expectEqual(core.wire.FrontendKind.desktop, syslink.frontend_kind);
    try std.testing.expect(syslink.remote_transport);
    try std.testing.expect(syslink.reconnect);
}

test "HostCapabilities round-trips through wire flags" {
    const web = defaultCapabilities(.web);
    const flags = toWireFlags(web);
    const decoded = fromWireFlags(.web, flags);

    try std.testing.expectEqual(web.frontend_kind, decoded.frontend_kind);
    try std.testing.expectEqual(web.cell_render, decoded.cell_render);
    try std.testing.expectEqual(web.pixel_render, decoded.pixel_render);
    try std.testing.expectEqual(web.mouse, decoded.mouse);
    try std.testing.expectEqual(web.clipboard, decoded.clipboard);
    try std.testing.expectEqual(web.reconnect, decoded.reconnect);
    try std.testing.expectEqual(web.remote_transport, decoded.remote_transport);
}
