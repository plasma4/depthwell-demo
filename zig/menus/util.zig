//! Shared building blocks for menu panels: UV/pixel conversions, panel, slot hitboxes, slot grids, and count labels.
//! Every menu places its panel in UV space (top-left aligned) and hit-tests in viewport pixels;
//! single-sourcing both derivations here means a menu's drawing and hit-testing can never drift apart.
const std = @import("std");
const dw = @import("../root.zig");

const uvToViewport = dw.entity.uvToViewport;
const Vec2f = dw.utils.Vec2f;
const Vec2f32 = dw.utils.Vec2f32;
const Vec4f32 = dw.utils.Vec4f32;

/// Viewport pixel scale for converting UV positions.
pub const px_scale: Vec2f = .{ dw.SCREEN_WIDTH, dw.SCREEN_HEIGHT };

/// Mouse position in viewport pixels.
pub inline fn mousePx() Vec2f {
    return dw.mouse.uv_position * px_scale;
}

/// Round-rect hitbox covering a whole menu panel (UV pos/size in, viewport-px shape out).
pub fn panelHitbox(pos: Vec2f32, size: Vec2f32) dw.geometry.Shape {
    const p = uvToViewport(pos);
    const s = uvToViewport(size);
    return .{ .start = p, .w = s[0], .h = s[1], .r = 0.05 };
}

/// Whether the cursor is over the panel; `open` short-circuits so a closed menu never claims hover.
/// Used by `mouse.processDownCaptures()` to keep pointerdown from falling through to the world.
pub fn isHovering(open: bool, pos: Vec2f32, size: Vec2f32) bool {
    if (!open) return false;
    return panelHitbox(pos, size).contains(mousePx());
}

/// Builds a centered round-square hitbox in viewport pixels.
pub fn slotHitbox(center_px: Vec2f, size: f64) dw.geometry.Shape {
    return .roundSquare(center_px - @as(Vec2f, @splat(size / 2.0)), size, 0.2);
}

/// Draws a number (with a darker drop-shadow).
pub fn drawCount(count: u64, center_px: Vec2f, color: Vec4f32, alpha: f32) void {
    const pos: Vec2f32 = .{ @floatCast(center_px[0]), @floatCast(center_px[1]) };
    dw.entity.drawNumber(count, pos - Vec2f32{ 0.5, 0.5 }, .{
        .font_size = 6.0,
        .lcha = .{ color[0] * 0.4, color[1] * 0.8, color[2] - 0.25, 0.75 * alpha },
    });
    dw.entity.drawNumber(count, pos, .{
        .font_size = 6.0,
        .lcha = .{ color[0], color[1], color[2], color[3] * alpha },
    });
}

/// Layout options for `Grid()`. All lengths are in viewport pixels.
pub const GridOptions = struct {
    /// Number of slots the grid holds; the panel sizes itself from this.
    len: usize,
    /// Slots per row before wrapping.
    cols: usize = 5,
    slot: f64 = 18.0,
    gap: f64 = 7.0,
    pad_x: f64 = 10.0,
    /// Room for a title icon above the slots.
    top_pad: f64 = 18.0,
    bot_pad: f64 = 8.0,
};

/// Comptime slot-grid layout. The panel size derives from `opts.len`, so adding a slot resizes
/// the panel automatically and menus never hand-tune panel rects against their contents.
pub fn Grid(comptime opts: GridOptions) type {
    return struct {
        pub const COLS = opts.cols;
        pub const ROWS = (opts.len + opts.cols - 1) / opts.cols;
        pub const SLOT = opts.slot;

        const filled_cols: usize = @min(opts.cols, opts.len);
        const content_w: f64 = @as(f64, @floatFromInt(filled_cols)) * opts.slot +
            @as(f64, @floatFromInt(filled_cols -| 1)) * opts.gap;
        const content_h: f64 = @as(f64, @floatFromInt(ROWS)) * opts.slot +
            @as(f64, @floatFromInt(ROWS -| 1)) * opts.gap;

        /// Panel size in viewport pixels.
        pub const SIZE_PX: Vec2f = .{
            content_w + 2 * opts.pad_x,
            content_h + opts.top_pad + opts.bot_pad,
        };
        /// Panel size in UV space.
        pub const SIZE_UV: Vec2f32 = .{
            @floatCast(SIZE_PX[0] / dw.SCREEN_WIDTH),
            @floatCast(SIZE_PX[1] / dw.SCREEN_HEIGHT),
        };

        /// The pixel center of slot `i` for a panel whose top-left sits at `pos` (UV).
        pub fn slotCenterPx(pos: Vec2f32, i: usize) Vec2f {
            const panel = uvToViewport(pos);
            const col: f64 = @floatFromInt(i % opts.cols);
            const row: f64 = @floatFromInt(i / opts.cols);
            return .{
                panel[0] + opts.pad_x + opts.slot / 2.0 + col * (opts.slot + opts.gap),
                panel[1] + opts.top_pad + opts.slot / 2.0 + row * (opts.slot + opts.gap),
            };
        }

        /// The pixel center of the title-icon strip above the slots.
        pub fn titleCenterPx(pos: Vec2f32) Vec2f {
            const panel = uvToViewport(pos);
            return .{ panel[0] + SIZE_PX[0] / 2.0, panel[1] + opts.top_pad / 2.0 };
        }
    };
}
