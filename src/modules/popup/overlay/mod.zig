//! Overlay system for transient UI elements.
//!
//! Provides types and state management for:
//! - Info overlays (auto-expire, e.g. resize coordinates)
//! - Pane select mode (modal, with dimming)
//! - Resize info display
//!
//! Rendering is handled separately by mux/overlay_render.zig.

pub const types = @import("types.zig");
pub const pane_select = @import("pane_select.zig");
pub const manager = @import("manager.zig");
pub const digits = @import("digits.zig");

// Re-export main types
pub const OverlayManager = manager.OverlayManager;
pub const Overlay = types.Overlay;
pub const OverlayKind = types.OverlayKind;
pub const Position = types.Position;
pub const Corner = types.Corner;
pub const CornerPosition = types.CornerPosition;
pub const AbsolutePosition = types.AbsolutePosition;

pub const PaneLabel = pane_select.PaneLabel;
pub const PaneSelectState = pane_select.PaneSelectState;
pub const labelForIndex = pane_select.labelForIndex;
pub const indexFromLabel = pane_select.indexFromLabel;

// ASCII art digit rendering
pub const BigDigit = digits.BigDigit;
pub const getDigit = digits.getDigit;
pub const DIGIT_WIDTH = digits.WIDTH;
pub const DIGIT_HEIGHT = digits.HEIGHT;

// New quadrant-based rendering
pub const DigitSize = digits.Size;
pub const PixelMap = digits.PixelMap;
pub const Block = digits.Block;
pub const getPixelMap = digits.getPixelMap;
pub const getQuadrantChar = digits.getQuadrantChar;
