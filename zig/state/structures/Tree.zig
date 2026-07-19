//! A basic tree with a trunk and leaves.
//!       CCC
//!      CCCCC
//!      CCCCC
//!       CTC
//!        T
//!        T
//!        T
//!
//! Placement is gated on BASE terrain only (pre-ore, pre-structure) by the `constraints` list.
const dw = @import("../../root.zig");
const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;
const structures = @import("../structures.zig");
const Rect = structures.Rect;

pub const spawn_area: u32 = 8;
pub const max_w: u32 = size_x;
pub const max_h: u32 = size_y;

/// Spawn chance per grid cell, before `constraints` thin it out. Tune against `debug/audit.zig`.
pub const target_chance: f64 = 0.50;

const size_x: i32 = 5;
const size_y: i32 = 7;

/// Column the single-wide trunk occupies (centered).
const trunk_x: i32 = size_x / 2;
/// Rows [0, canopy_rows) hold the canopy; the trunk fills the rest down to the base.
const canopy_rows: i32 = 4;
/// Vertical center of the canopy blob and its squared radius.
const canopy_cy: i32 = 2;
const canopy_r_sq: i32 = 5;

/// Terrain rules! Evaluated by `structures.zig` cheapest-first; result is cached on a grid-cell level.
pub const constraints = [_]structures.Constraint{
    // 3 foundation cells centered under the trunk, in the row just below the box: the ground it stands on.
    .{ .solid = .{
        .x0 = .{ .at = .start, .off = trunk_x - 1 },
        .x1 = .{ .at = .start, .off = trunk_x + 2 },
        .y0 = .{ .at = .end },
        .y1 = .{ .at = .end, .off = 1 },
    } },
    // The trunk shaft must be empty base terrain, so the tree is never buried in rock.
    .{ .empty = .{
        .x0 = .{ .at = .start, .off = trunk_x },
        .x1 = .{ .at = .start, .off = trunk_x + 1 },
    } },
};

pub fn getBounds(state: *HashState, cx: i32, cy: i32) ?Rect {
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
    const i_wx = @as(i32, @bitCast(wx));
    const i_wy = @as(i32, @bitCast(wy));

    // bounds already carry the hashed anchor (see getBounds()), so no re-rolls of `state` are needed
    const struct_x = i_wx - bounds.x_start;
    const struct_y = i_wy - bounds.y_start;
    if (struct_x < 0 or struct_y < 0 or struct_x >= size_x or struct_y >= size_y) return null;

    // terrain is already gated by `constraints`, so this only resolves the cell's body sprite
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
