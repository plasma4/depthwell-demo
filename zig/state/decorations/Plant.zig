//! The 2x1 plant, as a pair of half-sprites that must stay side by side.
//! LR
const dw = @import("../../root.zig");
const HashState = dw.seeding.HashState;
const Sprite = dw.Sprite;
const structures = @import("../structures.zig");

pub const size_x: i32 = 2;
pub const size_y: i32 = 1;

/// Odds a block anchors a shrub, before `constraints` thin it out. Tune against `debug/audit.zig`.
pub const chance: f64 = 0.02;

/// Terrain rules! Evaluated by `structures.zig` cheapest-first; result is cached on a grid-cell level.
pub const constraints = [_]structures.Constraint{
    // both halves stand on solid ground
    .{ .solid = .{
        .y0 = .{ .at = .end },
        .y1 = .{ .at = .end, .off = 1 },
    } },
    // in open space, so a shrub is never embedded in rock
    .{ .empty = .{} },
};

pub fn generate(local_x: i32, local_y: i32, state: *HashState) ?Sprite {
    _ = local_y;
    // determine which style of shrub to use!
    const second_variant = state.getChance(0.5);
    return if (second_variant)
        (if (local_x == 0) .moss_shrub2 else .moss_shrub2_right)
    else
        (if (local_x == 0) .moss_shrub1 else .moss_shrub1_right);
}
