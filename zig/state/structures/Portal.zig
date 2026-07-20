//! Portal.
//! TODO: add encasing shell and all the items required to make portal "unlocking" a req
//! P
const std = @import("std");
const dw = @import("../../root.zig");
const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;
const structures = @import("../structures.zig");
const Rect = structures.Rect;

pub const spawn_area: u32 = 32;
pub const max_w: u32 = size_x;
pub const max_h: u32 = size_y;
pub const target_chance: f64 = 0.12;

const size_x: i32 = 1;
const size_y: i32 = 1;

/// Terrain rules! Evaluated by `structures.zig` cheapest-first; result is cached on a grid-cell level.
pub const constraints = [_]structures.Constraint{
    // TODO
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
    _ = .{ starting_sprite, wx, wy, cx, cy, bounds, state, struct_seed };
    return .{ .id = .portal };
}
