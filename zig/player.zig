const std = @import("std");
const memory = @import("memory.zig");
const math = @import("math.zig");
const logger = @import("logger.zig");
const KeyBits = @import("types.zig").KeyBits;
const main = @import("main.zig");
const world = @import("world.zig");
const SIDE = memory.SIDE;
const SIDE_SQUARED = memory.SIDE_SQUARED;
const SUBPIXELS_IN_CHUNK = memory.SUBPIXELS_IN_CHUNK;

const v2i64 = @Vector(2, i64);
const v2f64 = @Vector(2, f64);

const GRAVITY: f64 = 0.5;
const JUMP_FORCE: f64 = -8.0; // idk TODO

/// Friction of player movement.
const friction: v2f64 = .{ 0.2, 0.2 };
/// 1 - friction.
const inv_friction: v2f64 = @as(v2f64, @splat(1.0)) - friction;

/// The base speed of the player.
const PLAYER_BASE_SPEED = 5;
/// Half the size of the player's hitbox.
const PLAYER_HITBOX_HALF = 96;

/// The zoom in/out keys change the zoom multipler this fast per frame.
const CAMERA_CHANGE_SPEED = 1.02;
/// How fast camera smoothing should be. Larger means faster.
const CAMERA_SMOOTHING = 0.1;
/// How far the player has to move before actually panning the camera.
const CAMERA_DEADZONE_X = 10 * memory.SIDE_FLOAT_SQ; // 4 blocks
const CAMERA_DEADZONE_Y = 5 * memory.SIDE_FLOAT_SQ; // 6 blocks

const pixel_mult: v2f64 = .{ @floatFromInt(SIDE), @floatFromInt(SIDE) };
var subpixel_accum: v2f64 = .{ 0.0, 0.0 }; // note that vectors are smartly aligned already

pub fn move(logic_speed: f64) void {
    const game = &memory.game;
    const player_speed = logic_speed * PLAYER_BASE_SPEED * SIDE;
    var input_dir: v2f64 = .{ 0.0, 0.0 };

    const old_camera_scale = game.camera_scale;
    if (KeyBits.isSet(KeyBits.plus, game.keys_held_mask)) {
        game.camera_scale = @min(game.camera_scale * CAMERA_CHANGE_SPEED, 4);
    }
    if (KeyBits.isSet(KeyBits.minus, game.keys_held_mask)) {
        game.camera_scale = @max(game.camera_scale / CAMERA_CHANGE_SPEED, 0.25);
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

            // Keep the player position within 0-4095 and rebase the camera
            game.player_pos[i] = @mod(game.player_pos[i], SUBPIXELS_IN_CHUNK);
            const shift_amount = @as(f64, @floatFromInt(carry * SUBPIXELS_IN_CHUNK));
            game.camera_pos[i] -= shift_amount;
            game.last_camera_pos[i] -= shift_amount;

            game.grid_dirty = true;

            // Hard limit check for depth 3 (TODO verify acacuracy at deeper depths)
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

    const player_world_x = @as(f64, @floatFromInt(game.player_pos[0]));
    const player_world_y = @as(f64, @floatFromInt(game.player_pos[1]));

    game.last_camera_pos = game.camera_pos;

    // Calculate the current edges of the camera's "deadzone window"
    const window_left = game.camera_pos[0] - CAMERA_DEADZONE_X;
    const window_right = game.camera_pos[0] + CAMERA_DEADZONE_X;
    const window_top = game.camera_pos[1] - CAMERA_DEADZONE_Y;
    const window_bottom = game.camera_pos[1] + CAMERA_DEADZONE_Y;

    // Determine how much the player is "pushing" outside the window
    var shift_x: f64 = 0;
    var shift_y: f64 = 0;

    if (player_world_x < window_left) {
        shift_x = player_world_x - window_left;
    } else if (player_world_x > window_right) {
        shift_x = player_world_x - window_right;
    }

    if (player_world_y < window_top) {
        shift_y = player_world_y - window_top;
    } else if (player_world_y > window_bottom) {
        shift_y = player_world_y - window_bottom;
    }

    // actually move
    game.camera_pos[0] += shift_x * CAMERA_SMOOTHING;
    game.camera_pos[1] += shift_y * CAMERA_SMOOTHING;
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
        const bx: i32 = @intCast(@divFloor(c[0], SIDE_SQUARED));
        const by: i32 = @intCast(@divFloor(c[1], SIDE_SQUARED));

        // Get the relative chunk (-1, 0, or 1 relative to player center)
        const cx = @divFloor(bx, SIDE);
        const cy = @divFloor(by, SIDE);
        const chunk = w.get__chunk(cx, cy);

        // Get the block within that chunk
        const lx: u4 = @intCast(@mod(bx, SIDE));
        const ly: u4 = @intCast(@mod(by, SIDE));
        const block = chunk.blocks[ly * SIDE + lx];

        if (block.id != world.SPRITE_VOID and block.id != world.SPRITE_MUSHROOM) {
            return true;
        }
    }
    return false;
}
