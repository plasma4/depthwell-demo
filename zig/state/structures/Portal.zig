//! Portal vestibule: a rounded-rect chamber standing on flat ground, with the portal on the floor inside.
//! TODO: add all the items required to make portal "unlocking" a req
//!
//!   #######
//!  #########
//! ###.....###
//! #.........#
//! #....P....#
//! ###########
//!
//! The corners are chamfered so the shell reads as rounded rather than as another box.
//! `#` is shell, `.` is carved-out air, `P` is the portal.
const std = @import("std");
const dw = @import("../../root.zig");
const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;
const structures = @import("../structures.zig");
const Rect = structures.Rect;

pub const spawn_area: u32 = 64;
pub const max_w: u32 = size_x;
/// Footprint height only. `structures.zig` adds `seat.max_drop` when it computes the vertical reach.
pub const max_h: u32 = size_y;

/// Flat ground wide enough for the vestibule is rare, so nearly every roll dies on the seating stage.
/// This sits at the ceiling and lets seating do the thinning; see `attempts`.
pub const target_chance: f64 = 1.0;

/// Flat ground is rare enough that one jitter draw per cell would waste almost every cell.
/// Cheap to retry, because a doomed seating scan bails after a couple of columns.
pub const attempts: u32 = 30;

const size_x: i32 = 11;
const size_y: i32 = 6;

/// Depth of the diagonal chamfer taken out of each corner.
/// A block is outside the shell when its distance to the two nearest edges sums to less than this,
/// which cuts a clean 45-degree bevel without any per-block distance math.
const CORNER: i32 = 3;

/// Stands the vestibule on flat ground, sliding it down up to 6 rows to meet the surface.
/// Seating also guarantees the floor row has terrain beneath it,
/// so no explicit "my base rests on solid ground" constraint is needed.
///
/// `max_slope = 2` tolerates gently uneven ground instead of demanding a perfectly flat strip,
/// which is rare enough to strangle the spawn rate.
/// Seating drops to the LOWEST column, so the higher columns just embed into the footprint (carved out, reading as "dug into a rise");
/// nothing floats. The grade-filler below then dresses those embedded columns with a clean stone foundation.
pub const seat: structures.Seat = .{ .max_drop = 6, .max_slope = 2 };

/// Terrain rules! Evaluated by `structures.zig` cheapest-first; result is cached on a grid-cell level.
/// Terrain INSIDE the footprint is deliberately unconstrained: the vestibule carves out whatever it lands on.
pub const constraints = [_]structures.Constraint{
    // A roof pressed into rock reads as a wall, so the row above the vestibule must be open.
    // The chamfer means the top row is narrower than the footprint, so only that span is checked.
    .{ .empty = .{
        .x0 = .{ .at = .start, .off = CORNER },
        .x1 = .{ .at = .end, .off = -CORNER },
        .y0 = .{ .at = .start, .off = -1 },
        .y1 = .{ .at = .start },
    } },
};

/// Whether a footprint-local block is part of the vestibule at all.
/// Blocks outside it are declined so the surrounding terrain shows through the chamfered corners.
inline fn inShape(x: i32, y: i32) bool {
    if (x < 0 or y < 0 or x >= size_x or y >= size_y) return false;
    // Distance to the nearest vertical and horizontal edge; both are 0 at a corner.
    const edge_x = @min(x, size_x - 1 - x);
    const edge_y = @min(y, size_y - 1 - y);
    return edge_x + edge_y >= CORNER;
}

/// Whether a block is on the shell: inside the shape, but with at least one neighbor outside it.
/// Deriving the shell from `inShape()` rather than testing for the footprint's edges keeps the wall exactly one block thick all the way around the chamfer,
/// with no special-casing per corner.
inline fn isShell(x: i32, y: i32) bool {
    return inShape(x, y) and
        !(inShape(x - 1, y) and inShape(x + 1, y) and inShape(x, y - 1) and inShape(x, y + 1));
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
    _ = .{ cx, cy, state, struct_seed };

    const local_x = @as(i32, @bitCast(wx)) - bounds.x_start;
    const local_y = @as(i32, @bitCast(wy)) - bounds.y_start;
    if (!inShape(local_x, local_y)) return null;

    if (isShell(local_x, local_y)) return .{ .id = .black_plate };

    // The portal stands centered on the floor, in the row just above the base shell.
    if (local_x == size_x / 2 and local_y == size_y - 2) return .{ .id = .portal };

    // on uneven ground, seating drops to the lowest column and the higher columns embed into the footprint.
    // rather than carve that away and expose a raw dug notch, keep the natural terrain that was already there.
    if (structures.baseSolid(@bitCast(wx), @bitCast(wy))) return .{ .id = starting_sprite };

    return .{ .id = .none };
}
