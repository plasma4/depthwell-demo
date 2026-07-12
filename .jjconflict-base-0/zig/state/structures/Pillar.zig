//! Pillar thing with water at the bottom.
//! SSSSSSSSSSSSSSSS
//! S   P     P    S
//! S   P     P    S
//! S      c       S
//! SwwwwwSSSwwwwwwS
//! SSSSSSSSSSSSSSSS
const std = @import("std");
const dw = @import("../../root.zig");
const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;
const structures = @import("../structures.zig");
const Rect = structures.Rect;

pub const spawn_area: u32 = 128;
pub const max_w: u32 = 24;
pub const max_h: u32 = 12;
pub const target_chance: f64 = 0.08;

pub fn getBounds(state: *HashState, cx: i32, cy: i32) Rect {
    const i_area = @as(i32, @intCast(spawn_area));
    const size_x = 24;
    const size_y = 12;
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
    _ = starting_sprite;
    _ = bounds;
    _ = struct_seed;
    const i_area = @as(i32, @intCast(spawn_area));
    const i_wx = @as(i32, @bitCast(wx));
    const i_wy = @as(i32, @bitCast(wy));

    const size_x = 24;
    const size_y = 12;
    const max_pos_x = @as(u32, @intCast(i_area - size_x));
    const max_pos_y = @as(u32, @intCast(i_area - size_y));

    const pos_x = @as(i32, @intCast(state.getLimit(u32, max_pos_x)));
    const pos_y = @as(i32, @intCast(state.getLimit(u32, max_pos_y)));
    const water_bit = state.getChance(0.5);

    const struct_x = i_wx - (cx * i_area + pos_x);
    const struct_y = i_wy - (cy * i_area + pos_y);

    if (struct_x >= 0 and struct_y >= 0 and struct_x < size_x and struct_y < size_y) {
        // Plate frame
        if (struct_x == 0 or struct_y == 0 or struct_x == size_x - 1 or struct_y == size_y - 1) {
            return .{ .id = .white_plate };
        }

        // Columns are placed every 5 blocks on the x-axis, centered vertically
        const rel_col_x = @rem((struct_x - 3), 5);
        const is_pillar_column = rel_col_x == 1;
        const is_pillar_row = (struct_y >= 3 and struct_y <= size_y - 4);

        if (is_pillar_column and is_pillar_row) {
            // Don't block the very center where the tomb altar sits
            const is_near_center = (struct_x >= size_x / 2 - 3 and struct_x <= size_x / 2 + 2);
            if (!is_near_center) {
                return .{ .id = .mossy_stone };
            }
        }

        // Central altar and chest placement
        const altar_x = size_x / 2;
        const altar_y = size_y - 3;
        if (struct_y == altar_y and struct_x == altar_x) {
            return .{ .id = .chest };
        }
        if (struct_y == altar_y + 1 and (struct_x >= altar_x - 1 and struct_x <= altar_x + 1)) {
            return .{ .id = .seagreen_stone };
        }

        if (struct_y == size_y - 2 or (struct_y == size_y - 3 and water_bit)) {
            return .{ .id = .water };
        }

        return .{ .id = .none };
    }
    return null;
}
