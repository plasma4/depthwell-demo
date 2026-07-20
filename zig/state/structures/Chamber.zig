//! A chamber of black plates, standing on flat ground.
//! PPPPPPPP
//! P      P
//! P      P
//! P      P
//! PLLLLLLP <- lava stone
//! PPPPPPPP  <- base row: ground starts right beneath this
//!
//! NOTE: flat-enough ground gets rare fast as the room widens: widening makes this rarer!
//! `target_chance`).
const dw = @import("../../root.zig");
const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;
const structures = @import("../structures.zig");
const Rect = structures.Rect;

pub const spawn_area: u32 = 16;
pub const max_w: u32 = size_x;
/// Footprint height only. `structures.zig` adds `seat.max_drop` when it computes the vertical reach.
pub const max_h: u32 = size_y;

/// Spawn chance per grid cell. Nearly every roll dies on the flatness gate, so this sits at the ceiling.
pub const target_chance: f64 = 1.0;

/// Flat ground is quite rare, so one shot per cell almost always misses.
/// Cheap to retry, because a doomed seating scan bails after ~2 columns.
pub const attempts: u32 = 8;

const size_x: i32 = 8;
/// Height of the room itself. There is nothing below it: the base row IS the bottom of the structure.
const size_y: i32 = 6;

/// Stands the chamber on flat ground, sliding it down up to 6 rows to meet the surface.
/// `max_slope` is 0 because a flat-bottomed room reads badly on any grade at all.
///
/// This also covers what used to be two explicit "the base row rests on solid terrain" constraints:
/// a seated box has already proven every column has a surface at the seated row.
pub const seat: structures.Seat = .{ .max_drop = 6 };

/// Terrain rules! Evaluated by `structures.zig` cheapest-first; result is cached on a grid-cell level.
/// Terrain INSIDE the footprint is deliberately unconstrained: the chamber carves out whatever it lands on.
pub const constraints = [_]structures.Constraint{
    // A roof pressed into rock reads as a wall, so the row above the chamber must be open.
    .{ .empty = .{
        .y0 = .{ .at = .start, .off = -1 },
        .y1 = .{ .at = .start },
    } },
};

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
