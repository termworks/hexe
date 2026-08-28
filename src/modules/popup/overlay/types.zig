const std = @import("std");

/// Overlay positioning options.
pub const Position = union(enum) {
    /// Anchored to screen corner with offset
    corner: CornerPosition,
    /// Centered on a specific pane (by UUID)
    pane_center: [32]u8,
    /// Absolute screen coordinates
    absolute: AbsolutePosition,
};

pub const CornerPosition = struct {
    anchor: Corner,
    offset_x: u16 = 0,
    offset_y: u16 = 0,
};

pub const AbsolutePosition = struct {
    x: u16,
    y: u16,
};

pub const Corner = enum {
    top_left,
    top_right,
    bottom_left,
    bottom_right,
    center,
};

/// Overlay types
pub const OverlayKind = enum {
    /// Auto-expires after duration (resize coordinates)
    info,
    /// Stays until explicitly dismissed
    persistent,
    /// Captures input, optional dimming (swap mode)
    modal,
};

/// A single generic overlay entry
pub const Overlay = struct {
    kind: OverlayKind,
    position: Position,
    text: []const u8,
    owned: bool, // true if text needs to be freed
    expires_at: i64, // 0 = never expires
    fg: u8, // palette index
    bg: u8, // palette index
    bold: bool = true,
    padding_x: u8 = 1,
    padding_y: u8 = 0,
};
