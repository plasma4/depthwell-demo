//! Basic rect with chest inside.
//! SSSSSSSSSS
//! S        S
//! S c      S
//! SSSSSSSSSS
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
pub const target_chance: f64 = 0.03;

const size_x: i32 = 8;
const size_y: i32 = 5;

// No getBounds(): the box is a plain size_x-by-size_y rect, so the default jitter in structures.zig does it.

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
    _ = cx;
    _ = cy;
    _ = struct_seed;
    const chest_x = 1 + @as(i32, @intCast(state.getLimit(u32, size_x - 2)));

    const i_wx = @as(i32, @bitCast(wx));
    const i_wy = @as(i32, @bitCast(wy));
    const struct_x = i_wx - bounds.x_start;
    const struct_y = i_wy - bounds.y_start;

    if (struct_x >= 0 and struct_y >= 0 and struct_x < size_x and struct_y < size_y) {
        // Rect outer boundary
        if (struct_x == 0 or struct_y == 0 or struct_x == size_x - 1 or struct_y == size_y - 1) {
            return .{ .id = .seagreen_stone };
        }

        // Add chest in the bottom row!
        if (struct_y == size_y - 2 and struct_x == chest_x) {
            return .{ .id = .chest };
        }

        return .{ .id = if (starting_sprite.isLiquid()) starting_sprite else .none };
    }
    return null;
}
