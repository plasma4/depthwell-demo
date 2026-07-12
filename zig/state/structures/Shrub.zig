//! The 2x1 moss shrub, as a pair of half-sprites that must stay side by side.
//! LR
const dw = @import("../../root.zig");
const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;
const structures = @import("../structures.zig");
const Rect = structures.Rect;

pub const spawn_area: u32 = 8;
pub const max_w: u32 = size_x;
pub const max_h: u32 = size_y;

/// Baseline spawn chance per grid cell, before collision compensation and before `constraints` run.
pub const target_chance: f64 = 0.30;

const size_x: i32 = 2;
const size_y: i32 = 1;

pub const constraints = [_]structures.Constraint{
    // both halves stand on solid ground
    .{ .solid = .{
        .y0 = .{ .at = .end },
        .y1 = .{ .at = .end, .off = 1 },
    } },
    // in open space, so a shrub is never embedded in rock
    .{ .empty = .{} },
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
    _ = wy;
    _ = cx;
    _ = cy;
    _ = struct_seed;
    const struct_x = @as(i32, @bitCast(wx)) - bounds.x_start;

    const second_variant = state.getChance(0.5);
    return .{ .id = if (second_variant)
        (if (struct_x == 0) .moss_shrub2 else .moss_shrub2_right)
    else
        (if (struct_x == 0) .moss_shrub1 else .moss_shrub1_right) };
}
