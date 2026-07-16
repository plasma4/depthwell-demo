//! A 1x3 vertical plant, standing on the ground.
//! F
//! s
//! s
//!
//! (F for flower, s for stem)
//!
//! Its footprint spans three ROWS, so it anchors on its top cell and grows down. Higher priority than the
//! ground clutter below it in `decorations.points`, or a bush would steal the cell out from under its base.
const dw = @import("../../root.zig");
const HashState = dw.seeding.HashState;
const Sprite = dw.Sprite;
const structures = @import("../structures.zig");

pub const size_x: i32 = 1;
pub const size_y: i32 = 3;

/// Odds a block anchors a plant, before `constraints` thin it out. Tune against `debug/audit.zig`.
pub const chance: f64 = 0.009;

pub const constraints = [_]structures.Constraint{
    // standing on solid ground (1 sample; can't be in mid-air!)
    .{ .solid = .{
        .y0 = .{ .at = .end },
        .y1 = .{ .at = .end, .off = 1 },
    } },
    // with the whole 3-tall shaft in open space, so a plant is never buried in rock
    .{ .empty = .{} },
};

pub fn generate(local_x: i32, local_y: i32, state: *HashState) ?Sprite {
    _ = local_x;
    _ = state;
    // Top cell is the flower, with plant vine beneath.
    if (local_y == 0) return .cornflower;
    return .plant_base;
}
