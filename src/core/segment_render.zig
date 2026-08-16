//! Style resolution shared by everything that composites styled runs.

const std = @import("std");
const style = @import("style.zig");

pub fn mergeStyle(base: style.Style, override: style.Style) style.Style {
    var out = base;
    if (override.fg != .none) out.fg = override.fg;
    if (override.bg != .none) out.bg = override.bg;
    if (override.bold) out.bold = true;
    if (override.italic) out.italic = true;
    if (override.underline) out.underline = true;
    if (override.dim) out.dim = true;
    return out;
}

/// An empty override leaves the default untouched, so a painter that sends no
/// style for a run inherits whatever the caller set.
pub fn resolveSegmentStyle(default_style: style.Style, segment_style: style.Style) style.Style {
    if (segment_style.isEmpty()) return default_style;
    return mergeStyle(default_style, segment_style);
}
