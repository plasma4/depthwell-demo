//! A chamber of black plates, standing on flat ground.
//! PPPPPPPP
//! P      P
//! P      P
//! P      P
//! PLLLLLLP <- lava stone
//! PPPPPPPP  <- base row: ground starts right beneath this
//!
//! NOTE: flat-enough ground gets rare fast as the room widens:
//! widening makes this rarer!
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
/// `structures.zig` scans back this far to find the candidate covering a block,
/// and asserts it fits within the one-cell overhang budget (`<= spawn_area`).
pub const max_h: u32 = size_y + SNAP_DEPTH;

/// Spawn chance per grid cell. Nearly every roll dies on the flatness gate, so this sits at the ceiling.
pub const target_chance: f64 = 1.0;

/// Flat ground is quite rare, so one shot per cell almost always misses.
/// Cheap to retry, because a doomed seating scan bails after ~2 columns.
pub const attempts: u32 = 8;

const size_x: i32 = 8;
/// Height of the room itself. There is nothing below it: the base row IS the bottom of the structure.
const size_y: i32 = 6;

/// How far `getBounds()` may pull a candidate DOWN to seat it on the ground.
/// Seating only ever moves the box down, so the anchor never leaves its cell.
const SNAP_DEPTH: i32 = 6;

/// The ground line: the row the terrain's topmost solid block has to land on.
///
/// It is the row directly BELOW the box (`.end` is exclusive),
/// which is what makes the chamber stand ON the ground instead of being sunk into it:
/// seating the box so its own last row coincided with the surface would bury that row a block deep.
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
};

/// Seats the candidate on the ground, and rejects it unless the ground is genuinely flat.
///
/// The jittered box is pulled DOWN until the row below it rests on the terrain surface.
pub fn getBounds(state: *HashState, cx: i32, cy: i32) ?Rect {
    var bounds = structures.jitter(state, cx, cy, spawn_area, size_x, size_y);
    const line = ground_row.resolve(bounds.y_start, bounds.y_end);

    var surface: ?i32 = null;
    var x = bounds.x_start;
    while (x < bounds.x_end) : (x += 1) {
        // a column with no surface in reach is open air or solid rock: either way the box cannot rest on it
        const column = structures.surfaceY(x, line, line + SNAP_DEPTH) orelse return null;
        if (surface) |s| {
            if (column != s) return null; // uneven ground
        } else surface = column;
    }

    const seat = surface.? - line;
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
