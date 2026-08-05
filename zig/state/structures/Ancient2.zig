//! Another alternate ancient (rose stone) ruin with random rocks inside.
//! IMPORTANT: structure size skews significantly.
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

pub const spawn_area: u32 = 128;
pub const max_w: u32 = 28;
pub const max_h: u32 = 18;
pub const target_chance: f64 = 0.32;
pub const attempts: u32 = 2;

/// Ring of empty blocks the ellipse is inset by, so the shell never touches the bounding box.
const padding = 2;

/// Check if coordinate is inside ellipse footprint!
fn covers(wx: i32, wy: i32, bounds: Rect) bool {
    const size_x = bounds.x_end - bounds.x_start;
    const size_y = bounds.y_end - bounds.y_start;
    const rx = (size_x >> 1) - padding;
    const ry = (size_y >> 1) - padding;
    if (rx <= 0 or ry <= 0) return false;

    const center_x = bounds.x_start + (size_x >> 1);
    const center_y = bounds.y_start + (size_y >> 1);
    const dx = wx - center_x;
    const dy = wy - center_y;

    return (dx * dx * ry * ry) + (dy * dy * rx * rx) <= rx * rx * ry * ry;
}

/// Just the encase constraint: this structure should be fully buried!
pub const constraints = [_]structures.Constraint{
    .{ .encase = .{
        .covers = covers,
        .min_open = 0.00,
        .max_open = 0.00,
    } },
};

pub fn getBounds(state: *HashState, cx: i32, cy: i32) ?Rect {
    const base_radius_x = state.getRange(i32, 6, 12);
    const base_radius_y = state.getRange(i32, 4, 7);
    return structures.jitter(
        state,
        cx,
        cy,
        spawn_area,
        (base_radius_x + padding) * 2,
        (base_radius_y + padding) * 2,
    );
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
    _ = cx;
    _ = cy;
    _ = state;
    const i_wx = @as(i32, @bitCast(wx));
    const i_wy = @as(i32, @bitCast(wy));

    const size_x = bounds.x_end - bounds.x_start;
    const size_y = bounds.y_end - bounds.y_start;
    const base_radius_x = @divExact(size_x, 2) - padding;
    const base_radius_y = @divExact(size_y, 2) - padding;

    const struct_x = i_wx - bounds.x_start;
    const struct_y = i_wy - bounds.y_start;

    // check tile bounds
    if (struct_x >= 0 and struct_y >= 0 and struct_x < size_x and struct_y < size_y) {
        // create per tile hash state
        var block_state = structures.makeBlockHash(struct_seed, wx, wy, 1);

        const center_x = size_x >> 1;
        const center_y = size_y >> 1;
        const dx = struct_x - center_x;
        const dy = struct_y - center_y;

        // compute radius variations from block state
        const skew_x = block_state.getRange(i32, -1, 1);
        const skew_y = block_state.getRange(i32, -1, 1);
        const local_noise_x = block_state.getRange(i32, -1, 1);

        const rx = base_radius_x + skew_x + local_noise_x;
        const ry = base_radius_y + skew_y;

        if (rx > 0 and ry > 0) {
            const dist_sq = (dx * dx * ry * ry) + (dy * dy * rx * rx);
            const outer_bound = rx * rx * ry * ry;

            const wall_thickness: i32 = 2;
            const inner_rx: i32 = @max(1, rx - wall_thickness);
            const inner_ry: i32 = @max(1, ry - wall_thickness);

            if (dist_sq <= outer_bound) {
                const inner_dist_sq = (dx * dx * inner_ry * inner_ry) + (dy * dy * inner_rx * inner_rx);
                const inner_bound = inner_rx * inner_rx * inner_ry * inner_ry;

                if (inner_dist_sq > inner_bound) {
                    // compute wall erosion
                    const erosion_factor = (wx ^ wy) % 7;
                    if (erosion_factor == 0) return .{ .id = .none };
                    return .{ .id = .rose_stone };
                } else {
                    // check tile below with position hash
                    const wy_below = wy + 1;
                    const struct_y_below = struct_y + 1;
                    const dy_below = struct_y_below - center_y;

                    var block_below_state = structures.makeBlockHash(struct_seed, wx, wy_below, 1);
                    const skew_x_below = block_below_state.getRange(i32, -1, 2);
                    const skew_y_below = block_below_state.getRange(i32, -1, 1);
                    const local_noise_x_below = block_below_state.getRange(i32, -1, 1);

                    const rx_below = base_radius_x + skew_x_below + local_noise_x_below;
                    const ry_below = base_radius_y + skew_y_below;

                    if (rx_below > 0 and ry_below > 0) {
                        const dist_sq_below = (dx * dx * ry_below * ry_below) + (dy_below * dy_below * rx_below * rx_below);
                        const outer_bound_below = rx_below * rx_below * ry_below * ry_below;

                        const inner_rx_below: i32 = @max(1, rx_below - wall_thickness);
                        const inner_ry_below: i32 = @max(1, ry_below - wall_thickness);
                        const inner_dist_sq_below = (dx * dx * inner_ry_below * inner_ry_below) + (dy_below * dy_below * inner_rx_below * inner_rx_below);
                        const inner_bound_below = inner_rx_below * inner_rx_below * inner_ry_below * inner_ry_below;

                        const below_is_wall = (dist_sq_below <= outer_bound_below) and (inner_dist_sq_below > inner_bound_below);
                        const below_is_eroded = ((wx ^ wy_below) % 7) == 0;

                        if (below_is_wall and !below_is_eroded) {
                            const stone_rand = block_state.getLimit(u32, 47);
                            if (stone_rand <= 4) {
                                return .{ .id = .rock };
                            } else if (stone_rand <= 9) {
                                return .{ .id = .flint };
                            } else if (stone_rand <= 10) {
                                return .{ .id = .campfire };
                            } else if (stone_rand <= 20) {
                                return .{ .id = .aqua_stone };
                            } else if (stone_rand <= 30) {
                                return .{ .id = .fiberstone };
                            }
                        }
                    }

                    return .{ .id = .none };
                }
            }
        }
    }
    return null;
}
