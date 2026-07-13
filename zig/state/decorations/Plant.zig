//! A 1x3 vertical plant, standing on the ground.
//! F
//! s
//! s
//!
//! (F for flower, s for stem)
//!
//! Its footprint spans three ROWS, which is what kept it out of `procedural.addDecorations()`: that pass
//! walks one chunk and can only see that chunk, so a plant whose top row fell in the chunk above would be
//! silently truncated. Anchoring on a world position instead of a per-chunk RNG stream crosses borders freely,
//! and gives the plant odds of its own rather than a slice carved out of one shared roll.
const dw = @import("../../root.zig");
const HashState = dw.seeding.HashState;
const Sprite = dw.Sprite;
const structures = @import("../structures.zig");

pub const size_x: i32 = 1;
pub const size_y: i32 = 3;

/// Odds a block anchors a plant, before `constraints` thin it out. Tune against `debug/audit.zig`.
pub const chance: f64 = 0.015;

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
    _ = local_y;
    _ = state;
    // TODO: actual plant here :)
    return .spiral_plant2;
}
