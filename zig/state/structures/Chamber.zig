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
//! Terrain constraints live in `fits()` and are ordered cheap -> expensive, since most candidates die on
//! the first one. They encode "the chamber must look like it was BUILT on this ground, not dropped into it":
//!  - both bottom corners rest on solid base terrain (2 samples, kills nearly everything mid-air),
//!  - the roof breaks into open space rather than burying itself in rock (`max_w` samples),
//!  - the ground profile under the footprint is level to within `MAX_SLOPE` (the expensive one).
//! Terrain INSIDE the footprint is unconstrained: the chamber freely carves out whatever it lands on.
const std = @import("std");
const dw = @import("../../root.zig");
const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;
const structures = @import("../structures.zig");
const Rect = structures.Rect;

pub const spawn_area: u32 = 32;
pub const max_w: u32 = size_x;
pub const max_h: u32 = size_y;

/// Baseline spawn chance per grid cell, BEFORE collision compensation and before `fits()` runs.
/// Only ~1 candidate in 150 survives the terrain gate (most are mid-air or roofed into rock), so this
/// sits near 1.0 and the real density knob is `MAX_SLOPE`/`SURFACE_SPAN` below.
pub const target_chance: f64 = 0.9;

const size_x: i32 = 12;
const size_y: i32 = 8;

/// Greatest height difference, in blocks, allowed between any two ground columns under the footprint.
/// 0 would demand perfectly flat terrain (almost never generated); each step up admits rougher slopes.
const MAX_SLOPE: i32 = 2;

/// How far above/below the chamber's base row a column's ground surface may sit and still count as
/// the floor it rests on. Must stay small, or the chamber floats over a pit / sinks into a rise.
const SURFACE_SPAN: i32 = 3;

pub fn getBounds(state: *HashState, cx: i32, cy: i32) Rect {
    const i_area = @as(i32, @intCast(spawn_area));
    const max_pos_x = @as(u32, @intCast(i_area - size_x));
    const max_pos_y = @as(u32, @intCast(i_area - size_y));

    const pos_x = @as(i32, @intCast(state.getLimit(u32, max_pos_x)));
    const pos_y = @as(i32, @intCast(state.getLimit(u32, max_pos_y)));

    const x_start = cx * i_area + pos_x;
    const y_start = cy * i_area + pos_y;
    return .{
        .x_start = x_start,
        .y_start = y_start,
        .x_end = x_start + size_x,
        .y_end = y_start + size_y,
    };
}

/// Terrain gate for a chamber candidate; see the file header for what each check buys.
pub fn fits(bounds: Rect) bool {
    // first row BELOW the box, which is the ground the chamber stands on
    const floor_y = bounds.y_end;

    if (!structures.baseSolid(bounds.x_start, floor_y)) return false;
    if (!structures.baseSolid(bounds.x_end - 1, floor_y)) return false;

    // A roof pressed into rock reads as a wall, so the row above the chamber must be open.
    var x = bounds.x_start;
    while (x < bounds.x_end) : (x += 1) {
        if (structures.baseSolid(x, bounds.y_start - 1)) return false;
    }

    // The chamber lies flat, so every column's surface has to fall inside one MAX_SLOPE-tall band.
    var highest: i32 = std.math.maxInt(i32);
    var lowest: i32 = std.math.minInt(i32);
    x = bounds.x_start;
    while (x < bounds.x_end) : (x += 1) {
        const surface = structures.surfaceY(x, floor_y, SURFACE_SPAN) orelse return false;
        highest = @min(highest, surface);
        lowest = @max(lowest, surface);
        if (lowest - highest > MAX_SLOPE) return false;
    }
    return true;
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
