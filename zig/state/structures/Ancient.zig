//! Ancient (fossil-like) ruin with chest inside
//!   SSSS
//!  SS  SS
//! SS c SSS
//!  SSSSSS
const std = @import("std");
const dw = @import("../../root.zig");
const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;
const structures = @import("../structures.zig");
const Rect = structures.Rect;

pub const spawn_area: u32 = 64;
pub const max_w: u32 = 30;
pub const max_h: u32 = 20;
pub const target_chance: f64 = 0.32;

pub fn getBounds(state: *HashState, cx: i32, cy: i32) Rect {
    const i_area = @as(i32, @intCast(spawn_area));
    const base_radius_x = state.getRange(i32, 6, 12);
    const base_radius_y = state.getRange(i32, 4, 7);
    const padding = 3;
    const size_x = (base_radius_x + padding) * 2;
    const size_y = (base_radius_y + padding) * 2;

    const max_pos_x = @max(1, i_area - size_x);
    const max_pos_y = @max(1, i_area - size_y);

    const pos_x = state.getLimit(i32, max_pos_x);
    const pos_y = state.getLimit(i32, max_pos_y);

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

    const base_radius_x = state.getRange(i32, 6, 12);
    const base_radius_y = state.getRange(i32, 4, 7);
    const padding = 3;
    const size_x = (base_radius_x + padding) * 2;
    const size_y = (base_radius_y + padding) * 2;

    // Determine the randomized offset position of the structure within the chunk
    const max_pos_x = @max(1, i_area - size_x);
    const max_pos_y = @max(1, i_area - size_y);

    const pos_x = state.getLimit(i32, max_pos_x);
    const pos_y = state.getLimit(i32, max_pos_y);

    const struct_x = i_wx - (cx * i_area + pos_x);
    const struct_y = i_wy - (cy * i_area + pos_y);

    // Check if the current world tile falls within the bounding box of the ruin
    if (struct_x >= 0 and struct_y >= 0 and struct_x < size_x and struct_y < size_y) {
        const center_x = size_x >> 1;
        const center_y = size_y >> 1;
        const dx = struct_x - center_x;
        const dy = struct_y - center_y;

        // Add random variation
        const skew_x = state.getRange(i32, -1, 2);
        const skew_y = state.getRange(i32, -1, 1);
        const local_noise_x = state.getRange(i32, -1, 1);

        // Compute the final mutated outer radii for the ellipse math!
        const rx = base_radius_x + skew_x + local_noise_x;
        const ry = base_radius_y + skew_y;
        if (rx > 0 and ry > 0) {
            const dist_sq = (dx * dx * ry * ry) + (dy * dy * rx * rx);
            const outer_bound = rx * rx * ry * ry;

            const wall_thickness = 2;
            const inner_rx: i32 = @max(1, rx - wall_thickness);
            const inner_ry: i32 = @max(1, ry - wall_thickness);

            if (dist_sq <= outer_bound) {
                const inner_dist_sq = (dx * dx * inner_ry * inner_ry) + (dy * dy * inner_rx * inner_rx);
                const inner_bound = inner_rx * inner_rx * inner_ry * inner_ry;

                const floor_y = center_y + inner_ry - 1;
                const chest_range = inner_rx;
                const chest_offset = (-inner_rx >> 1) + state.getLimit(i32, chest_range);
                const chest_x = center_x + chest_offset;

                // prioritize chest placement
                if (struct_x == chest_x) {
                    if (struct_y == floor_y) {
                        return .{ .id = .chest };
                    }
                    if (struct_y == floor_y + 1) {
                        // guarantee something for the chest to stay on with unwarped coords
                        return .{ .id = .white_plate };
                    }
                }

                if (inner_dist_sq > inner_bound) {
                    const erosion_factor = (wx ^ wy) % 7;
                    if (erosion_factor == 0) return .{ .id = .none };
                    return .{ .id = .sulfuric_stone };
                } else {
                    return .{ .id = .none };
                }
            }
        }
    }
    return null;
}
