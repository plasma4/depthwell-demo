//! Geode (ore shell containing yummy gems)
//!     OOOOO
//!   OO  G  OO
//! OO  G GG  OO
//!   OO   G OO
//!     OOOOO
const std = @import("std");
const dw = @import("../../root.zig");
const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;
const structures = @import("../structures.zig");
const Rect = structures.Rect;

pub const spawn_area: u32 = 64;
pub const max_w: u32 = 20;
pub const max_h: u32 = 20;
pub const target_chance: f64 = 0.88;

pub fn getBounds(state: *HashState, cx: i32, cy: i32) ?Rect {
    const radius = state.getRange(i32, 5, 10);
    return structures.jitter(state, cx, cy, spawn_area, radius * 2, radius * 2);
}

/// The geode's outer disc, in absolute world blocks. This is the SAME test `generate()` uses to draw the shell,
/// factored out so the encase check can ask about blocks just outside the footprint too.
fn covers(wx: i32, wy: i32, bounds: Rect) bool {
    const radius = @divExact(bounds.x_end - bounds.x_start, 2);
    const dx = (wx - bounds.x_start) - radius;
    const dy = (wy - bounds.y_start) - radius;
    return dx * dx + dy * dy <= radius * radius;
}

/// A geode should be mostly buried but never perfectly sealed to make it more findable and interesting!
/// `Encase` walls the disc regardless of its rolled radius, with no per-radius bounding box.
pub const constraints = [_]structures.Constraint{
    .{ .encase = .{
        .covers = covers,
        .min_open = 0.20,
        .max_open = 0.35,
    } },
};

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
    const i_wx = @as(i32, @bitCast(wx));
    const i_wy = @as(i32, @bitCast(wy));

    // the hashed radius is already baked into the bounds (see getBounds()), so no re-rolls are needed
    const radius = @divExact(bounds.x_end - bounds.x_start, 2);
    const core_radius = radius - 2;

    const struct_x = i_wx - bounds.x_start;
    const struct_y = i_wy - bounds.y_start;

    if (struct_x >= 0 and struct_y >= 0 and struct_x < radius * 2 and struct_y < radius * 2) {
        // Get center of the geode relative to the area
        const center_x = radius;
        const center_y = radius;
        const dx = struct_x - center_x;
        const dy = struct_y - center_y;

        // Determine the shell's block type
        const shell_rand = state.getLimit(u32, 5);
        const shell: Sprite = switch (shell_rand) {
            0...1 => .pink_stone,
            2...3 => .purple_stone,
            4 => .deep_blue_stone,
            else => unreachable,
        };

        // Check if within the bounding box of the geode
        const dist_sq = (dx * dx) + (dy * dy);
        if (dist_sq <= core_radius * core_radius) {
            // We are in the core (center area)! Determine whether to use stone or a gem.
            var block_state = structures.makeBlockHash(struct_seed, wx, wy, 3);
            const core_rand = block_state.getLimit(u32, 50);
            const which_stone = state.getLimit(u32, 3);

            // The plain stone this core block would be if it weren't a gem.
            // Gems overlay this so their base_id reflects the geode (not the natural terrain the structure replaced).
            // The inner rim gets a consistent stone accent; everything deeper is a stone variant.
            const core_stone: Sprite = if (dist_sq >= (core_radius - 1) * (core_radius - 1))
                (if (shell == .bright_red_stone) .stone else ([_]Sprite{ .stone, .deep_blue_stone, .purple_stone })[which_stone])
            else
                .stone;

            const gem: Sprite = switch (core_rand) {
                0...4 => .quartz,
                5...8 => .amethyst,
                9...11 => .sapphire,
                12...13 => .emerald,
                14...15 => .ruby,
                else => return .{ .id = core_stone }, // gems weren't selected: plain core stone
            };
            return .{ .id = gem, .base = core_stone };
        } else if (dist_sq <= radius * radius) {
            return .{ .id = shell };
        }
    }

    return null;
}
