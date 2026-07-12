//! A flat-bottomed chamber of black plates, resting on level ground.
//! PPPPPPPPPPPP
//! P          P
//! P          P
//! P          P
//! P          P
//! P          P
//! PLLLLLLLLLLP
//! PPPPPPPPPPPP
//!
//! Terrain rules live in the declarative `constraints` list below.
const dw = @import("../../root.zig");
const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;
const structures = @import("../structures.zig");
const Rect = structures.Rect;

pub const spawn_area: u32 = 16;
pub const max_w: u32 = size_x;
pub const max_h: u32 = size_y;

/// Baseline spawn chance per grid cell, BEFORE collision compensation and before `constraints` run.
/// Only ~1 candidate in 60 survives the terrain gate (most are mid-air or roofed into rock), so this sits
/// at the ceiling and the real density knobs are `spawn_area` and the tolerances in `constraints`.
pub const target_chance: f64 = 1.0;

const size_x: i32 = 12;
const size_y: i32 = 8;

/// The row directly below the box: the ground the chamber stands on.
const floor_row: structures.Edge = .{ .at = .end };

/// Terrain rules; `structures.zig` runs them cheapest-first and memoizes the verdict per grid cell.
/// They encode "the chamber must look like it was BUILT on this ground, not dropped into it".
/// Terrain INSIDE the footprint is deliberately unconstrained: the chamber carves out whatever it lands on.
pub const constraints = [_]structures.Constraint{
    // Both bottom corners rest on ground. 1 sample each, and it kills nearly every mid-air candidate.
    .{ .solid = .{
        .x0 = .{ .at = .start },
        .x1 = .{ .at = .start, .off = 1 },
        .y0 = floor_row,
        .y1 = .{ .at = .end, .off = 1 },
    } },
    .{ .solid = .{
        .x0 = .{ .at = .end, .off = -1 },
        .x1 = .{ .at = .end },
        .y0 = floor_row,
        .y1 = .{ .at = .end, .off = 1 },
    } },
    // A roof pressed into rock reads as a wall, so the row above the chamber must be open.
    .{ .empty = .{
        .y0 = .{ .at = .start, .off = -1 },
        .y1 = .{ .at = .start },
    } },
    // The chamber lies flat. `max_drop = 0` is what enforces that: no ground column may sit below the base
    // row, so the chamber never has a gap under it. Ground ABOVE the base row is fine and just means the
    // chamber is dug into a rise, so `max_rise` can afford to be generous.
    .{ .level = .{ .row = floor_row, .max_slope = 5, .max_rise = 5, .max_drop = 0 } },
};

pub fn getBounds(state: *HashState, cx: i32, cy: i32) Rect {
    return structures.jitter(state, cx, cy, spawn_area, size_x, size_y);
}

pub fn generate(
    starting_sprite: Sprite,
    wx: u32,
    wy: u32,
    cx: i32,
    cy: i32,
    bounds: Rect,
    state: *HashState,
    struct_seed: Vec2u,
) ?structures.StructureResult {
    _ = starting_sprite;
    _ = cx;
    _ = cy;
    _ = state;
    _ = struct_seed;
    const struct_x = @as(i32, @bitCast(wx)) - bounds.x_start;
    const struct_y = @as(i32, @bitCast(wy)) - bounds.y_start;
    if (struct_x < 0 or struct_y < 0 or struct_x >= size_x or struct_y >= size_y) return null;

    if (struct_x == 0 or struct_x == size_x - 1 or struct_y == 0 or struct_y == size_y - 1) {
        return .{ .id = .black_plate };
    }
    if (struct_y == size_y - 2) return .{ .id = .lava_stone };
    return .{ .id = .none };
}
