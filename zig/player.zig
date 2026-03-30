//! Handles the main player movement and camera logic.
const std = @import("std");
const memory = @import("memory.zig");
const logger = @import("logger.zig");
const KeyBits = @import("types.zig").KeyBits;
const main = @import("main.zig");
const world = @import("world.zig");
const SPAN = memory.SPAN;
const SPAN_SQ = memory.SPAN_SQ;
const SUBPIXELS_IN_CHUNK = memory.SUBPIXELS_IN_CHUNK;

const v2i64 = memory.v2i64;
const v2f64 = memory.v2f64;

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

/// Minimum camera zoom/scale allowed. This is strategically calculated to make sure the default render distance is safe.
const CAMERA_MIN_ZOOM = 1.0 / 4.0; // ~25% (any more and sim_buffer nor chunk_cache would no longer be able to reliably cache, remember that simulation is centered around the player!)
/// Maximum camera zoom/scale allowed. This is strategically calculated to make sure the player always remains in the viewport.
const CAMERA_MAX_ZOOM = 1.0; // 100%

/// The zoom in/out keys change the zoom multiplier this fast per frame.
const CAMERA_CHANGE_SPEED = 1.02;
/// How fast camera smoothing should be. Larger means faster.
const CAMERA_SMOOTHING = 0.2;

/// How far the player has to move before actually panning the camera in sub-pixels (x-axis).
const CAMERA_DEADZONE_X = 10 * memory.SPAN_SQ; // memory.SPAN_SQ means 1 block, basically
/// How far the player has to move before actually panning the camera in sub-pixels (y-axis).
const CAMERA_DEADZONE_Y = 4 * memory.SPAN_SQ;

const pixel_mult: v2f64 = .{ @floatFromInt(SPAN), @floatFromInt(SPAN) };
var subpixel_accum: v2f64 = .{ 0.0, 0.0 }; // note that vectors are smartly aligned already

/// Moves the player, handling camera changes.
pub fn move(logic_speed: f64) void {
    const game = &memory.game;
    const player_speed = logic_speed * PLAYER_BASE_SPEED * SPAN;
    var input_dir: v2f64 = .{ 0.0, 0.0 };

    const old_camera_scale = game.camera_scale;
    if (KeyBits.isSet(KeyBits.plus, game.keys_held_mask)) {
        // since this doesn't really influence logic, std.math.pow can be non-deterministic
        game.camera_scale = @min(game.camera_scale * std.math.pow(f64, CAMERA_CHANGE_SPEED, logic_speed), CAMERA_MAX_ZOOM);
    }
    if (KeyBits.isSet(KeyBits.minus, game.keys_held_mask)) {
        game.camera_scale = @max(game.camera_scale / std.math.pow(f64, CAMERA_CHANGE_SPEED, logic_speed), CAMERA_MIN_ZOOM);
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
    game.last_player_pos = game.player_pos;
    game.player_pos += move_vec;
    subpixel_accum -= @as(v2f64, @floatFromInt(move_vec));

    inline for (0..2) |i| {
        const carry: i64 = @divFloor(game.player_pos[i], SUBPIXELS_IN_CHUNK);
        if (carry != 0) {
            // Treat the signed carry as bits and add to the unsigned suffix
            game.player_chunk[i] +%= @bitCast(carry);

            // Keep the player position within 0-4095 and rebase the camera
            game.player_pos[i] = @mod(game.player_pos[i], SUBPIXELS_IN_CHUNK);

            // Shift these variables since they're relative
            const shift_amount = carry * SUBPIXELS_IN_CHUNK;
            game.last_player_pos[i] -= shift_amount;
            game.camera_pos[i] -= shift_amount;
            game.last_camera_pos[i] -= shift_amount;

            // game.grid_dirty = true;
            game.player_pos[i] = @mod(game.player_pos[i], SUBPIXELS_IN_CHUNK);
        }
    }

    game.last_camera_pos = game.camera_pos;

    // Calculate the current edges of the camera's "deadzone window", making sure it's based on the player's sprite center
    const x_deadzone = @as(i64, @intFromFloat(CAMERA_DEADZONE_X / game.camera_scale));
    const y_deadzone = @as(i64, @intFromFloat(CAMERA_DEADZONE_Y / game.camera_scale));
    // const player_size_half = memory.SPAN_SQ / 2;
    const window_left = game.camera_pos[0] - x_deadzone;
    const window_right = game.camera_pos[0] + x_deadzone;
    const window_top = game.camera_pos[1] - y_deadzone;
    const window_bottom = game.camera_pos[1] + y_deadzone;
    // Example logs (note how the numbers are funky due to us wanting the center player to be centered in the deadzone logic): (256, 256) | (256, 256) | -2304 | 2560 | -768 | 1024
    // logger.clear(3);
    // logger.write(3, .{ game.player_pos, game.camera_pos, window_left, window_right, window_top, window_bottom });

    // Determine how much the player is "pushing" outside the window
    var shift_x: i64 = 0;
    var shift_y: i64 = 0;

    if (game.player_pos[0] < window_left) {
        shift_x = game.player_pos[0] - window_left;
    } else if (game.player_pos[0] > window_right) {
        shift_x = game.player_pos[0] - window_right;
    }

    if (game.player_pos[1] < window_top) {
        shift_y = game.player_pos[1] - window_top;
    } else if (game.player_pos[1] > window_bottom) {
        shift_y = game.player_pos[1] - window_bottom;
    }

    // actually move! since camera speed does not influence logic, std.math.pow can be non-deterministic
    const smooth_speed = 1.0 - std.math.pow(f64, 1.0 - CAMERA_SMOOTHING, logic_speed);
    game.camera_pos[0] += @intFromFloat(@as(f64, @floatFromInt(shift_x)) * smooth_speed);
    game.camera_pos[1] += @intFromFloat(@as(f64, @floatFromInt(shift_y)) * smooth_speed);
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
        const bx: i32 = @intCast(@divFloor(c[0], SPAN_SQ));
        const by: i32 = @intCast(@divFloor(c[1], SPAN_SQ));

        // Get the relative chunk (-1, 0, or 1 relative to player center)
        const cx = @divFloor(bx, SPAN);
        const cy = @divFloor(by, SPAN);
        const chunk = w.get_chunk(cx, cy);

        // Get the block within that chunk
        const lx: u4 = @intCast(@mod(bx, SPAN));
        const ly: u4 = @intCast(@mod(by, SPAN));
        const block = chunk.blocks[ly * SPAN + lx];

        if (block.id != world.SPRITE_VOID and block.id != world.SPRITE_MUSHROOM) {
            return true;
        }
    }
    return false;
}
