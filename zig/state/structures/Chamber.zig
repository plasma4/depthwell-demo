//! A chamber of black plates, standing on flat ground.
//! PPPPPPPP  <- roof
//! P      P
//! P      P
//! P      P
//! PLLLLLLP  <- lava stone floor course
//! PPPPPPPP  <- base row: the ground starts directly BENEATH it, so the room stands on the surface
//!
//! Seating is the whole problem. The box is rigid and flat-bottomed, so it needs ground that is actually
//! flat: `getBounds()` drops the jittered box until it rests on the terrain, and `constraints` then throws
//! it out unless every column underneath agrees on the same surface row.
//!
//! Room size IS the density dial: flat-enough ground gets rare fast as the room widens, so widening it turns
//! the chamber into a rare landmark. `spawn_area` is the other dial (and the cheaper one -- see the note on
//! `target_chance`).
const dw = @import("../../root.zig");
const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;
const structures = @import("../structures.zig");
const Rect = structures.Rect;

pub const spawn_area: u32 = 16;
pub const max_w: u32 = size_x;
/// Vertical reach from the cell anchor: the footprint, plus however far `getBounds()` may seat it down.
/// `structures.zig` scans back this far to find the candidate covering a block, and asserts it fits within
/// the one-cell overhang budget (`<= spawn_area`).
pub const max_h: u32 = size_y + SNAP_DEPTH;

/// Baseline spawn chance per grid cell, BEFORE collision compensation and before `constraints` run.
/// Nearly every candidate dies on the flatness gate, so this sits at the ceiling and `spawn_area` is the real
/// dial. Note the cost of that choice: a candidate at every cell means `getBounds()` runs its seating scan at
/// every cell too, which is the structure system's single largest terrain-sampling cost.
pub const target_chance: f64 = 1.0;

const size_x: i32 = 8;
/// Height of the room itself. There is nothing below it: the base row IS the bottom of the structure.
const size_y: i32 = 6;

/// How far `getBounds()` may pull a candidate DOWN to seat it on the ground.
/// Seating only ever moves the box down, so the anchor never leaves its cell.
const SNAP_DEPTH: i32 = 6;

/// The ground line: the row the terrain's topmost solid block has to land on.
///
/// It is the row directly BELOW the box (`.end` is exclusive), which is what makes the chamber stand ON the
/// ground instead of being sunk into it: seating the box so its own last row coincided with the surface would
/// bury that row a block deep.
const ground_row: structures.Edge = .{ .at = .end };

/// Terrain rules; `structures.zig` runs them cheapest-first and memoizes the verdict per grid cell.
/// Terrain INSIDE the footprint is deliberately unconstrained: the chamber carves out whatever it lands on.
pub const constraints = [_]structures.Constraint{
    // Both ends of the base row rest on solid terrain. 1 sample each, and it kills every mid-air candidate.
    .{ .solid = .{
        .x0 = .{ .at = .start },
        .x1 = .{ .at = .start, .off = 1 },
        .y0 = ground_row,
        .y1 = .{ .at = .end, .off = 1 },
    } },
    .{ .solid = .{
        .x0 = .{ .at = .end, .off = -1 },
        .x1 = .{ .at = .end },
        .y0 = ground_row,
        .y1 = .{ .at = .end, .off = 1 },
    } },
    // A roof pressed into rock reads as a wall, so the row above the chamber must be open.
    .{ .empty = .{
        .y0 = .{ .at = .start, .off = -1 },
        .y1 = .{ .at = .start },
    } },
    // With nothing under the room to bridge a dip, the ground has to be genuinely flat:
    // - a RISE would bury the base row (`max_rise = 0`),
    // - a DROP would leave the room floating over a gap (`max_drop = 0`).
    // `getBounds()` already seats on the highest column, so `max_rise = 0` holds by construction and this
    // really tests that no column dips below it.
    .{ .level = .{
        .row = ground_row,
        .max_slope = 0,
        .max_rise = 0,
        .max_drop = 0,
    } },
};

/// Anchors the candidate, then SEATS it: the jittered box is pulled down until the row below it lands on the
/// HIGHEST ground under the footprint. Without seating, the box keeps whatever y the hash happened to pick,
/// and would only look grounded when that y coincidentally matched the terrain.
///
/// Seating on the highest column (rather than, say, the center) is what makes `max_rise = 0` free: by
/// construction no column's ground can then rise above the base row, so every surviving candidate is one
/// where the remaining columns do not dip either.
pub fn getBounds(state: *HashState, cx: i32, cy: i32) Rect {
    var bounds = structures.jitter(state, cx, cy, spawn_area, size_x, size_y);
    const line = ground_row.resolve(bounds.y_start, bounds.y_end);

    var highest: ?i32 = null;
    var x = bounds.x_start;
    while (x < bounds.x_end) : (x += 1) {
        const surface = structures.surfaceY(x, line, line + SNAP_DEPTH) orelse continue;
        highest = if (highest) |h| @min(h, surface) else surface;
    }

    // no ground at all under the box: leave it unseated, and `constraints` throws it out
    const seat = (highest orelse return bounds) - line;
    bounds.y_start += seat;
    bounds.y_end += seat;
    return bounds;
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
