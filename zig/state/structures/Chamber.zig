//! A chamber of black plates, standing on the surface on a plinth.
//! PPPPPPPP  <- room
//! P      P
//! P      P
//! P      P
//! PLLLLLLP
//! PPPPPPPP  <- base row: sits exactly ON the ground
//! PPPPPPPP  <- plinth: fills the ground wherever it dips out from under the chamber
//! PPPPPPPP
//! PPPPPPPP
//! PPPPPPPP
//!
//! Seating it convincingly is the whole problem. Ground flat enough for a rigid flat-bottomed box is rare in
//! this terrain, so demanding it outright means almost no chambers; tolerating a RISE instead lets the room
//! sink into the hill, which is the look being avoided. So the chamber does what a builder would:
//! `getBounds()` seats it on the ground, `max_rise = 0` keeps the room from ever being buried, and the
//! `PLINTH_ROWS` below the room fill in whatever the ground drops away by (`max_drop`).
//!
//! Room size IS the density dial: flat-enough ground gets rare fast as the room widens (measured, per 1M
//! blocks: 8x6 -> ~26 chambers, 10x8 -> ~9, 12x8 -> ~7). Widen the room and chambers become a rare landmark.
const dw = @import("../../root.zig");
const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;
const structures = @import("../structures.zig");
const Rect = structures.Rect;

pub const spawn_area: u32 = 16;
pub const max_w: u32 = size_x;
/// Vertical reach from the cell anchor: the whole footprint, plus however far `getBounds()` may seat it down.
/// `structures.zig` scans back this far to find the candidate covering a block, and asserts it fits within
/// the one-cell overhang budget (`<= spawn_area`).
pub const max_h: u32 = total_h + SNAP_DEPTH;

/// Baseline spawn chance per grid cell, BEFORE collision compensation and before `constraints` run.
/// Most candidates still die on the terrain gate, so this sits at the ceiling; `spawn_area` is the real dial.
pub const target_chance: f64 = 1.0;

const size_x: i32 = 8;
/// Height of the room itself (the part you see and walk into).
const size_y: i32 = 6;
/// Solid plate rows below the room, filling the ground where it dips out from under the chamber.
/// Also the deepest dip the chamber can cover, so it bounds `max_drop` in `constraints`.
const PLINTH_ROWS: i32 = 4;
const total_h: i32 = size_y + PLINTH_ROWS;

/// How far `getBounds()` may pull a candidate DOWN to seat it on the ground.
/// Seating only ever moves the box down, so the anchor never leaves its cell.
const SNAP_DEPTH: i32 = 6;

/// The ground line: where the terrain surface (the topmost solid row) has to land.
/// It sits one row BELOW the first plinth row, so the chamber stands ON the surface rather than replacing it:
/// seating it flush would sink the whole structure a block into the ground.
const ground_row: structures.Edge = .{ .at = .end, .off = -PLINTH_ROWS + 1 };
/// One row past `ground_row`, for the region rules below.
const below_ground_row: structures.Edge = .{ .at = .end, .off = -PLINTH_ROWS + 2 };

/// Terrain rules; `structures.zig` runs them cheapest-first and memoizes the verdict per grid cell.
/// Terrain INSIDE the footprint is deliberately unconstrained: the chamber carves out whatever it lands on.
pub const constraints = [_]structures.Constraint{
    // Both ends of the ground line rest on solid terrain. 1 sample each, and it kills every mid-air candidate.
    .{ .solid = .{
        .x0 = .{ .at = .start },
        .x1 = .{ .at = .start, .off = 1 },
        .y0 = ground_row,
        .y1 = below_ground_row,
    } },
    .{ .solid = .{
        .x0 = .{ .at = .end, .off = -1 },
        .x1 = .{ .at = .end },
        .y0 = ground_row,
        .y1 = below_ground_row,
    } },
    // A roof pressed into rock reads as a wall, so the row above the chamber must be open.
    .{ .empty = .{
        .y0 = .{ .at = .start, .off = -1 },
        .y1 = .{ .at = .start },
    } },
    // The room must READ as resting on the surface: `max_rise = 0` forbids any column's ground from rising
    // above the ground line (nothing buries the chamber), while a dip is fine because the plinth fills it in.
    // Only `PLINTH_ROWS - 1` plinth rows sit at or below the ground line, so that is the deepest dip covered.
    .{ .level = .{
        .row = ground_row,
        .max_slope = PLINTH_ROWS - 1,
        .max_rise = 0,
        .max_drop = PLINTH_ROWS - 1,
    } },
};

/// Anchors the candidate, then SEATS it: the jittered box is pulled down until its ground line lands on the
/// HIGHEST ground under the footprint. Without seating, the box keeps whatever y the hash happened to pick,
/// and would only look grounded when that y coincidentally matched the terrain.
///
/// Seating on the highest column rather than (say) the center is what makes `max_rise = 0` achievable: by
/// construction no column's ground can then rise above the chamber, so every remaining column dips, and dips
/// are exactly what the plinth is for. Seating on the center instead would demand the center happen to be the
/// high point of all `size_x` columns, which almost never holds.
pub fn getBounds(state: *HashState, cx: i32, cy: i32) Rect {
    var bounds = structures.jitter(state, cx, cy, spawn_area, size_x, total_h);
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
    if (struct_x < 0 or struct_y < 0 or struct_x >= size_x or struct_y >= total_h) return null;

    // the plinth is solid plate all the way across, so a dip in the ground reads as a base and not a gap
    if (struct_y >= size_y) return .{ .id = .black_plate };

    if (struct_x == 0 or struct_x == size_x - 1 or struct_y == 0 or struct_y == size_y - 1) {
        return .{ .id = .black_plate };
    }
    if (struct_y == size_y - 2) return .{ .id = .lava_stone };
    return .{ .id = .none };
}
