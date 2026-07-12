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
pub const max_w: u32 = 8;
pub const max_h: u32 = 5;
pub const target_chance: f64 = 0.03;

pub fn getBounds(state: *HashState, cx: i32, cy: i32) Rect {
    const i_area = @as(i32, @intCast(spawn_area));
    const size_x = 8;
    const size_y = 5;
    const max_pos_x = @as(u32, @intCast(i_area - size_x));
    const max_pos_y = @as(u32, @intCast(i_area - size_y));

    const pos_x = @as(i32, @intCast(state.getLimit(u32, max_pos_x)));
    const pos_y = @as(i32, @intCast(state.getLimit(u32, max_pos_y)));

    const x_start = cx * i_area + pos_x;
    const y_start = cy * i_area + pos_y;
    return .{
        .x_start = x_start,
        .y_start = y_start,
        .x_end = x_start + size_x,
        .y_end = y_start + size_y,
    };
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
    _ = bounds;
    _ = struct_seed;
    const i_area = @as(i32, @intCast(spawn_area));
    const i_wx = @as(i32, @bitCast(wx));
    const i_wy = @as(i32, @bitCast(wy));

    const size_x = 8;
    const size_y = 5;
    const max_pos_x = @as(u32, @intCast(i_area - size_x));
    const max_pos_y = @as(u32, @intCast(i_area - size_y));

    const pos_x = @as(i32, @intCast(state.getLimit(u32, max_pos_x)));
    const pos_y = @as(i32, @intCast(state.getLimit(u32, max_pos_y)));
    const chest_x = 1 + @as(i32, @intCast(state.getLimit(u32, size_x - 2)));

    const struct_x = i_wx - (cx * i_area + pos_x);
    const struct_y = i_wy - (cy * i_area + pos_y);

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
