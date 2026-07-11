const std = @import("std");
const core = @import("core");
const frontend_core = @import("frontend_core");

/// Browser-originated event shape for the future web gateway.
///
/// This adapter deliberately maps browser concepts into `frontend_core.HostEvent`
/// without importing terminal/vaxis/raw-mode modules.
pub const BrowserEvent = union(enum) {
    input_bytes: []const u8,
    key: frontend_core.KeyEvent,
    mouse: frontend_core.MouseEvent,
    paste: []const u8,
    resize_cells: frontend_core.Resize,
    close_requested,
    connection_lost,
    tick,
};

pub const WebHost = struct {
    allocator: std.mem.Allocator,
    current_view: ?frontend_core.SessionView = null,

    pub fn init(allocator: std.mem.Allocator) WebHost {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *WebHost) void {
        if (self.current_view) |*view| view.deinit();
        self.current_view = null;
    }

    pub fn capabilities() frontend_core.HostCapabilities {
        return frontend_core.defaultCapabilities(.web);
    }

    pub fn mapBrowserEvent(event: BrowserEvent) frontend_core.HostEvent {
        return switch (event) {
            .input_bytes => |bytes| .{ .input_bytes = bytes },
            .key => |key| .{ .key = key },
            .mouse => |mouse| .{ .mouse = mouse },
            .paste => |bytes| .{ .paste = bytes },
            .resize_cells => |resize| .{ .resize = resize },
            .close_requested => .close_requested,
            .connection_lost => .{ .connection_lost = .transport_lost },
            .tick => .tick,
        };
    }

    /// Apply a canonical SES session snapshot to the web adapter's shared
    /// frontend view. Browser rendering can diff this view without importing
    /// terminal state or vaxis types.
    pub fn applySessionStateJson(self: *WebHost, session_json: []const u8) !void {
        var next = try frontend_core.SessionView.fromJson(self.allocator, session_json);
        errdefer next.deinit();
        if (self.current_view) |*old| old.deinit();
        self.current_view = next;
    }

    pub fn applyPendingRuntimeEvents(self: *WebHost, runtime: *core.FrontendRuntime) frontend_core.RuntimeEventApplyResult {
        if (self.current_view) |*view| {
            return frontend_core.applyPendingRuntimeEvents(view, runtime);
        }
        return .{};
    }
};

test "WebHost advertises browser capabilities without terminal dependencies" {
    const caps = WebHost.capabilities();

    try std.testing.expectEqual(@as(@TypeOf(caps.frontend_kind), .web), caps.frontend_kind);
    try std.testing.expect(caps.cell_render);
    // No pixel renderer exists yet — not advertised (honesty, PLAN 3.2).
    try std.testing.expect(!caps.pixel_render);
    try std.testing.expect(caps.mouse);
    try std.testing.expect(caps.clipboard);
    try std.testing.expect(caps.reconnect);
    try std.testing.expect(!caps.remote_transport);
}

test "WebHost maps browser resize into frontend-neutral host event" {
    const event = WebHost.mapBrowserEvent(.{ .resize_cells = .{ .cols = 100, .rows = 32 } });

    try std.testing.expectEqual(@as(u16, 100), event.resize.cols);
    try std.testing.expectEqual(@as(u16, 32), event.resize.rows);
}

test "WebHost preserves browser input bytes" {
    const input = "abc";
    const event = WebHost.mapBrowserEvent(.{ .input_bytes = input });

    try std.testing.expectEqualStrings(input, event.input_bytes);
}

test "WebHost maps browser disconnect to structured connection loss" {
    const event = WebHost.mapBrowserEvent(.connection_lost);

    try std.testing.expectEqual(frontend_core.DisconnectReason.transport_lost, event.connection_lost);
}

test "WebHost applies canonical session snapshots into shared view" {
    const allocator = std.testing.allocator;
    var host = WebHost.init(allocator);
    defer host.deinit();

    const json =
        \\{"version":1,"uuid":"ssssssssssssssssssssssssssssssss","session_name":"web","base_root":"/tmp/hexe","tab_counter":1,"active_tab":0,"active_float_uuid":null,"focused_pane_uuid":null,"tabs":[],"panes":[],"floats":[]}
    ;
    try host.applySessionStateJson(json);

    try std.testing.expect(host.current_view != null);
    try std.testing.expectEqualStrings("web", host.current_view.?.session_name);
    try std.testing.expectEqualStrings("/tmp/hexe", host.current_view.?.base_root.?);
}
