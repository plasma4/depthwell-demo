//! Example structure documentation; UNUSED. Read the comments to understand more!
//!
//! Hut design:
//!     #########     <- roof
//!     #.......#
//!     #.......#     <- chest on floor
//!     #.c.....#
//!     #########     <- floor rests on terrain surface
//!
//! `#` is wall, `.` is carved air, `c` is chest
const std = @import("std");
const dw = @import("../../root.zig");
const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;
const structures = @import("../structures.zig");
const Rect = structures.Rect;

/// grid cell size in blocks
pub const spawn_area: u32 = 32;

/// max footprint width
pub const max_w: u32 = size_x;
/// max footprint height
pub const max_h: u32 = size_y;

/// chance to attempt placement
pub const target_chance: f64 = 1.0;

/// placement attempt limit per cell
pub const attempts: u32 = 8;

/// hut width in blocks
const size_x: i32 = 9;
/// hut height in blocks
const size_y: i32 = 5;

/// stands hut on ground
pub const seat: structures.Seat = .{ .max_drop = 6 };

/// placement constraint rules
pub const constraints = [_]structures.Constraint{
    // require open row above roof
    .{ .empty = .{
        .y0 = .{ .at = .start, .off = -1 },
        .y1 = .{ .at = .start },
    } },
};

/// unique roll identifier
const SPECKLE_ROLL_ID = 0;

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
    // The cell coordinates are already baked into `state` by structures.zig,
    // and this structure has doesn't use the base terrain sprite it is replacing.
    _ = starting_sprite;
    _ = cx;
    _ = cy;

    // correlated wall sprite roll
    const wall: Sprite = if (state.getChance(0.5)) .stone else .pink_stone;

    // correlated chest column position
    const chest_x = 1 + state.getLimit(i32, size_x - 2);

    // convert world position to local footprint coordinate
    const local_x = @as(i32, @bitCast(wx)) - bounds.x_start;
    const local_y = @as(i32, @bitCast(wy)) - bounds.y_start;

    // decline blocks outside footprint
    if (local_x < 0 or local_y < 0 or local_x >= size_x or local_y >= size_y) return null;

    const is_edge = local_x == 0 or local_x == size_x - 1 or
        local_y == 0 or local_y == size_y - 1;

    if (is_edge) {
        // uncorrelated speckle roll per block
        var block_state = structures.makeBlockHash(struct_seed, wx, wy, SPECKLE_ROLL_ID);
        if (block_state.getChance(0.1)) {
            return .{ .id = if (wall == .stone) .pink_stone else .stone };
        }
        return .{ .id = wall };
    }

    // place chest on floor row
    if (local_x == chest_x and local_y == size_y - 2) {
        return .{ .id = .chest };
    }

    // carve interior space to air
    return .{ .id = .none };
}

const testing = std.testing;

test "example structure compiles and stays consistent" {
    try testing.expect(std.math.isPowerOfTwo(spawn_area));
    try testing.expect(max_w <= spawn_area);
    try testing.expect(max_h <= spawn_area);
    try testing.expect(target_chance >= 0.0 and target_chance <= 1.0);

    const sorted = comptime structures.sortConstraints(&constraints, max_w, max_h);
    try testing.expectEqual(constraints.len, sorted.len);

    const bounds: Rect = .{ .x_start = 0, .y_start = 0, .x_end = size_x, .y_end = size_y };
    const seed: Vec2u = .{ 0x1234, 0x5678 };

    // decline block outside footprint
    {
        var state: HashState = .{ .seed_vector = seed, .x = 0, .y = 0 };
        try testing.expectEqual(
            @as(?structures.StructureResult, null),
            generate(.stone, @bitCast(size_x), 0, 0, 0, bounds, &state, seed),
        );
    }

    // claim corner block
    {
        var state: HashState = .{ .seed_vector = seed, .x = 0, .y = 0 };
        const corner = generate(.stone, 0, 0, 0, 0, bounds, &state, seed);
        try testing.expect(corner != null);
    }

    // verify stream agreement across footprint
    var wall_seen: ?Sprite = null;
    var y: u32 = 0;
    while (y < size_y) : (y += 1) {
        var x: u32 = 0;
        while (x < size_x) : (x += 1) {
            const on_edge = x == 0 or x == size_x - 1 or y == 0 or y == size_y - 1;
            if (!on_edge) continue;

            var state: HashState = .{ .seed_vector = seed, .x = 0, .y = 0 };
            const result = generate(.stone, x, y, 0, 0, bounds, &state, seed);
            try testing.expect(result != null);

            var probe: HashState = structures.makeBlockHash(seed, x, y, SPECKLE_ROLL_ID);
            if (probe.getChance(0.1)) continue;

            if (wall_seen) |w| {
                try testing.expectEqual(w, result.?.id);
            } else wall_seen = result.?.id;
        }
    }
    try testing.expect(wall_seen != null);
}
