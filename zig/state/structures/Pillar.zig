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
pub const max_w: u32 = size_x;
pub const max_h: u32 = size_y;
pub const target_chance: f64 = 0.09;

const size_x: i32 = 24;
const size_y: i32 = 12;

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
    _ = starting_sprite;
    _ = cx;
    _ = cy;
    _ = struct_seed;
    const i_wx = @as(i32, @bitCast(wx));
    const i_wy = @as(i32, @bitCast(wy));

    const water_bit = state.getChance(0.5);

    const struct_x = i_wx - bounds.x_start;
    const struct_y = i_wy - bounds.y_start;

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
            // The altar row IS the upper water row when `water_bit` is set, and a chest is waterloggable,
            // so it must generate already submerged or the pool is not at equilibrium.
            return .{ .id = .chest, .water_volume = if (water_bit) dw.memory.Block.MAX_HP else 0 };
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
