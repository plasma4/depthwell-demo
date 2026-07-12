//! A basic tree with a trunk and leaves.
//!       CCC
//!      CCCCC
//!      CCCCC
//!       CTC
//!        T
//!        T
//!        T
//!
//! To gate placement on terrain (as this tree only appears on ground), `fits()` samples ONLY base terrain
//! (`structures.baseSolid()`), checking the anchoring floor first and early-outing before it scans the
//! taller trunk shaft. Most candidates fail the floor test, so the shaft scan runs rarely.
//! `structures.zig` calls `fits()` once per grid cell and memoizes the verdict, so the terrain noise is
//! never re-sampled for the other 34 cells of the footprint.
const std = @import("std");
const dw = @import("../../root.zig");
const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;
const structures = @import("../structures.zig");
const Rect = structures.Rect;

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

/// Terrain gate: the tree must stand on ground, with an unburied trunk shaft (deeper = larger y).
pub fn fits(bounds: Rect) bool {
    // we order checks from cheap to expensive
    // start with 3 foundation cells centered under the trunk (deeper row, just below the box)
    const floor_y = bounds.y_end;
    var dx: i32 = trunk_x - 1;
    while (dx <= trunk_x + 1) : (dx += 1) {
        if (!structures.baseSolid(bounds.x_start + dx, floor_y)) return false; // early-out: no ground here
    }

    // the vertical trunk shaft must be empty base terrain so the tree isn't buried in rock
    var by: i32 = 0;
    while (by < @as(i32, size_y)) : (by += 1) {
        if (structures.baseSolid(bounds.x_start + trunk_x, bounds.y_start + by)) return false;
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

    // terrain is already gated by `fits()`, so this only resolves the cell's body sprite
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

    if (body) |sprite| return .{ .id = sprite };
    return null;
}
