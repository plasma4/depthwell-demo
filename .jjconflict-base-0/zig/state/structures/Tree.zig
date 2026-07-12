//! A basic tree with a trunk and leaves.
//!       CCC
//!      CCCCC
//!      CCCCC
//!       CTC
//!        T
//!        T
//!        T
//!
//! To gate placement on terrain (as this tree only appears on ground), we:
//!  - sample ONLY base terrain via `procedural.getBaseSpriteType(cx, cy, bx, by).sprite.isFoundation()`.
//!  - check the anchoring floor first and early-out (cheap); only then scan the larger clearance box.
//! Most candidates fail the floor test, so further tests run rarely.
//!
//!  TODO: see if `computeColumnSeeds()`-like approach is more viable if more constraints stack up.
const std = @import("std");
const dw = @import("../../root.zig");
const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;
const structures = @import("../structures.zig");
const procedural = dw.procedural;
const Rect = structures.Rect;

const CHUNK_SIZE = dw.CHUNK_SIZE;

pub const spawn_area: u32 = 16;
pub const max_w: u32 = size_x;
pub const max_h: u32 = size_y;

/// Baseline spawn chance per grid cell.
/// (Before general-structure collision compensation, but doesn't factor in `treeIsGrounded()`.)
pub const target_chance: f64 = 0.80;

const size_x: u32 = 5;
const size_y: u32 = 7;

/// Column the single-wide trunk occupies (centered).
const trunk_x: i32 = size_x / 2;
/// Rows [0, canopy_rows) hold the canopy; the trunk fills the rest down to the base.
const canopy_rows: i32 = 4;
/// Vertical center of the canopy blob and its squared radius.
const canopy_cy: i32 = 2;
const canopy_r_sq: i32 = 5;

pub fn getBounds(state: *HashState, cx: i32, cy: i32) Rect {
    const i_area = @as(i32, @intCast(spawn_area));
    const max_pos_x = @as(u32, @intCast(i_area - @as(i32, size_x)));
    const max_pos_y = @as(u32, @intCast(i_area - @as(i32, size_y)));

    const pos_x = @as(i32, @intCast(state.getLimit(u32, max_pos_x)));
    const pos_y = @as(i32, @intCast(state.getLimit(u32, max_pos_y)));

    const x_start = cx * i_area + pos_x;
    const y_start = cy * i_area + pos_y;
    return .{
        .x_start = x_start,
        .y_start = y_start,
        .x_end = x_start + @as(i32, size_x),
        .y_end = y_start + @as(i32, size_y),
    };
}

/// Base-terrain (pre-ore, pre-structure) foundation test at absolute world block (wx, wy).
inline fn baseSolid(wx: i32, wy: i32) bool {
    const cx: u32 = @intCast(@divFloor(wx, @as(i32, CHUNK_SIZE)));
    const cy: u32 = @intCast(@divFloor(wy, @as(i32, CHUNK_SIZE)));
    const bx: u4 = @intCast(@mod(wx, @as(i32, CHUNK_SIZE)));
    const by: u4 = @intCast(@mod(wy, @as(i32, CHUNK_SIZE)));
    return procedural.getBaseSpriteType(cx, cy, bx, by).sprite.isFoundation();
}

/// Terrain constraint for a tree anchored at bounding-box origin (x0, y0) (deeper = larger y).
fn treeIsGrounded(x0: i32, y0: i32) bool {
    // we order checks from cheap to expensive
    // start with 3 foundation cells centered under the trunk (deeper row, just below the box)
    const floor_y = y0 + @as(i32, size_y);
    var dx: i32 = trunk_x - 1;
    while (dx <= trunk_x + 1) : (dx += 1) {
        if (!baseSolid(x0 + dx, floor_y)) return false; // early-out: no ground here
    }

    // the vertical trunk shaft must be empty base terrain so the tree isn't buried in rock
    var by: i32 = 0;
    while (by < @as(i32, size_y)) : (by += 1) {
        if (baseSolid(x0 + trunk_x, y0 + by)) return false;
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
    const i_wx = @as(i32, @bitCast(wx));
    const i_wy = @as(i32, @bitCast(wy));

    // bounds already carry the hashed anchor (see getBounds), so no re-rolls of `state` are needed
    const struct_x = i_wx - bounds.x_start;
    const struct_y = i_wy - bounds.y_start;
    if (struct_x < 0 or struct_y < 0 or struct_x >= @as(i32, size_x) or struct_y >= @as(i32, size_y)) return null;

    // resolve this cell's body sprite FIRST (cheap); only body cells pay for the terrain gate
    const body: ?Sprite = blk: {
        // Draw the wooden trunk! Simple column below the canopy down to the base.
        if (struct_x == trunk_x and struct_y >= canopy_rows) break :blk .wood;
        // Don't let any blocks be horizontally adjacent to the trunk, because it looks weird.
        if ((struct_x == trunk_x - 1 or struct_x == trunk_x + 1) and struct_y >= canopy_rows) break :blk .none;
        // Generate the canopy part; basically a rounded blob of leaves centered over the trunk (the GREEN).
        if (struct_y < canopy_rows) {
            const dx = struct_x - trunk_x;
            const dy = struct_y - canopy_cy;
            if (dx * dx + dy * dy <= canopy_r_sq) break :blk .leaves;
        }
        break :blk null;
    };

    if (body) |sprite| {
        if (!treeIsGrounded(bounds.x_start, bounds.y_start)) return null;
        return .{ .id = sprite };
    }
    return null;
}
