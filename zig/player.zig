const std = @import("std");
const memory = @import("memory.zig");
const math = @import("math.zig");
const logger = @import("logger.zig");
const KeyBits = @import("types.zig").KeyBits;
const main = @import("main.zig");
const world = @import("world.zig");
const CHUNK_SIZE = memory.CHUNK_SIZE;
const CHUNK_SIZE_SQUARED = memory.CHUNK_SIZE_SQUARED;
const SUBPIXELS_IN_CHUNK = memory.SUBPIXELS_IN_CHUNK;

const v2i64 = @Vector(2, i64);
const v2f64 = @Vector(2, f64);

const PLAYER_HITBOX_HALF: i64 = 96;
const GRAVITY: f64 = 0.5;
const JUMP_FORCE: f64 = -8.0;

const friction: v2f64 = .{ 0.2, 0.2 };
const ones: v2f64 = @splat(1.0);
const inv_friction: v2f64 = ones - friction;

const camera_change_speed = 1.02;
const player_base_speed = 2;

const pixel_mult: v2f64 = .{ @floatFromInt(CHUNK_SIZE), @floatFromInt(CHUNK_SIZE) };
var subpixel_accum: v2f64 = .{ 0.0, 0.0 }; // note that vectors are smartly aligned already

pub fn move(logic_speed: f64) void {
    const game = &memory.game;
    const player_speed = logic_speed * player_base_speed * CHUNK_SIZE;
    var input_dir: v2f64 = .{ 0.0, 0.0 };

    const old_camera_scale = game.camera_scale;
    if (KeyBits.isSet(KeyBits.plus, game.keys_held_mask)) {
        game.camera_scale = @min(game.camera_scale * camera_change_speed, 4);
    }
    if (KeyBits.isSet(KeyBits.minus, game.keys_held_mask)) {
        game.camera_scale = @max(game.camera_scale / camera_change_speed, 0.25);
    }
    game.camera_scale_change = game.camera_scale / old_camera_scale;

    if (KeyBits.isSet(KeyBits.left, game.keys_held_mask)) input_dir[0] -= player_speed;
    if (KeyBits.isSet(KeyBits.right, game.keys_held_mask)) input_dir[0] += player_speed;
    if (KeyBits.isSet(KeyBits.up, game.keys_held_mask)) input_dir[1] -= player_speed;
    if (KeyBits.isSet(KeyBits.down, game.keys_held_mask)) input_dir[1] += player_speed;

    game.player_velocity = game.player_velocity * inv_friction + input_dir * friction;
    if (@abs(game.player_velocity[0]) < 1e-10) game.player_velocity[0] = 0;
    if (@abs(game.player_velocity[1]) < 1e-10) game.player_velocity[1] = 0;

    // Multiply by delta/pixels and accumulate
    subpixel_accum += game.player_velocity;

    // Extract integer movement
    const move_vec = @as(v2i64, @intFromFloat(@floor(subpixel_accum)));
    game.player_pos += move_vec;
    subpixel_accum -= @as(v2f64, @floatFromInt(move_vec));

    inline for (0..2) |i| {
        const carry = @divFloor(game.player_pos[i], SUBPIXELS_IN_CHUNK);
        if (carry != 0) {
            // Treat the signed carry as bits and add to the unsigned suffix
            game.active_chunk[i] +%= @bitCast(carry);

            // Hard Limit Check for Depth 3:
            if (game.active_chunk[i] >= SUBPIXELS_IN_CHUNK) {
                // If it wrapped or exceeded, clamp it
                if (@as(i64, @bitCast(game.active_chunk[i])) < 0) {
                    game.active_chunk[i] = 0;
                } else {
                    game.active_chunk[i] = SUBPIXELS_IN_CHUNK - 1;
                }
                game.player_pos[i] = std.math.clamp(game.player_pos[i], 0, SUBPIXELS_IN_CHUNK - 1);
                game.player_velocity[i] = 0;
            } else {
                game.player_pos[i] = @mod(game.player_pos[i], SUBPIXELS_IN_CHUNK);
                game.grid_dirty = true;
            }
        }
    }

    // Camera stays in absolute local subpixels
    game.camera_pos = @as(v2f64, @floatFromInt(game.player_pos)) + subpixel_accum;
}

/// AABB check against the world grid
fn is_colliding(px: i64, py: i64, w: *world.World) bool {
    // Check the 4 corners of the player hitbox
    const corners = [_][2]i64{
        .{ px - PLAYER_HITBOX_HALF, py - PLAYER_HITBOX_HALF },
        .{ px + PLAYER_HITBOX_HALF, py - PLAYER_HITBOX_HALF },
        .{ px - PLAYER_HITBOX_HALF, py + PLAYER_HITBOX_HALF },
        .{ px + PLAYER_HITBOX_HALF, py + PLAYER_HITBOX_HALF },
    };

    for (corners) |c| {
        // Convert subpixel units to Block coordinates (1 block = 256 units)
        const bx: i32 = @intCast(@divFloor(c[0], CHUNK_SIZE_SQUARED));
        const by: i32 = @intCast(@divFloor(c[1], CHUNK_SIZE_SQUARED));

        // Get the relative chunk (-1, 0, or 1 relative to player center)
        const cx = @divFloor(bx, CHUNK_SIZE);
        const cy = @divFloor(by, CHUNK_SIZE);
        const chunk = w.get__chunk(cx, cy);

        // Get the block within that chunk
        const lx: u4 = @intCast(@mod(bx, CHUNK_SIZE));
        const ly: u4 = @intCast(@mod(by, CHUNK_SIZE));
        const block = chunk.blocks[ly * CHUNK_SIZE + lx];

        if (block.id != world.SPRITE_VOID and block.id != world.SPRITE_MUSHROOM) {
            return true;
        }
    }
    return false;
}
