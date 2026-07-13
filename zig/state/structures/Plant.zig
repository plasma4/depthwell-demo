//! A 1x3 vertical plant, standing on the ground.
//! F
//! s
//! s
//!
//! (F for flower, s for stem)
//!
//! Lives here rather than in `procedural.addDecorations()` because its footprint spans three ROWS.
//! The decor pass walks one chunk's blocks and can only see that chunk,
//! so a plant whose top row falls in the chunk above would be silently truncated;
//! and each new decor type has to carve its odds out of one shared `rng_decor` roll,
//! so adding types quietly re-weights the existing ones. A structure is hashed from world coordinates alone,
//! so it crosses chunk borders and owns an independent probability.
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
/// Plants are meant to be common, so this sits high and the terrain gate does the thinning.
pub const target_chance: f64 = 0.75;

const size_x: i32 = 1;
const size_y: i32 = 3;

pub const constraints = [_]structures.Constraint{
    // standing on solid ground (1 sample; can't be in mid-air!)
    .{ .solid = .{
        .y0 = .{ .at = .end },
        .y1 = .{ .at = .end, .off = 1 },
    } },
    // with the whole 3-tall shaft in open space, so a plant is never buried in rock
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
    _ = wx;
    _ = wy;
    _ = cx;
    _ = cy;
    _ = bounds;
    _ = state;
    _ = struct_seed;
    // TODO: actual plant here :)
    return .{ .id = .spiral_plant2 };
}
