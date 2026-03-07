const memory = @import("memory.zig");
const math = @import("math.zig");
const logger = @import("logger.zig");
const KeyBits = @import("types.zig").KeyBits;
const CHUNK_SIZE = memory.CHUNK_SIZE;

const v2i64 = @Vector(2, i64);
const v2f64 = @Vector(2, f64);
const player_speed = 1;

const friction: v2f64 = .{ 0.1, 0.1 };
const ones: v2f64 = @splat(1.0);
const inv_friction: v2f64 = ones - friction;

const pixel_mult: v2f64 = .{ @floatFromInt(CHUNK_SIZE), @floatFromInt(CHUNK_SIZE) };
var subpixel_accum: v2f64 = .{ 0.0, 0.0 }; // note that vectors are smartly aligned already

pub fn move() void {
    const game = &memory.game;
    var input_dir: v2f64 = .{ 0.0, 0.0 };

    if (KeyBits.isSet(KeyBits.left, game.keys_held_mask)) input_dir[0] -= player_speed;
    if (KeyBits.isSet(KeyBits.right, game.keys_held_mask)) input_dir[0] += player_speed;
    if (KeyBits.isSet(KeyBits.up, game.keys_held_mask)) input_dir[1] -= player_speed;
    if (KeyBits.isSet(KeyBits.down, game.keys_held_mask)) input_dir[1] += player_speed;

    game.player_velocity = (game.player_velocity) * inv_friction + input_dir * friction;

    if (@abs(game.player_velocity[0]) < 0.01) game.player_velocity[0] = 0;
    if (@abs(game.player_velocity[1]) < 0.01) game.player_velocity[1] = 0;

    // Multiply by delta/pixels and accumulate
    const frame_movement = game.player_velocity * pixel_mult;
    subpixel_accum += frame_movement;

    // Extract only whole integers to apply to the grid position
    const move_int = @floor(subpixel_accum);
    game.player_pos += @as(v2i64, @intFromFloat(move_int));
    subpixel_accum -= move_int; // Leave only the remainder

    // Add subpixel_accum to camera_pos so the camera doesn't visually stutter
    game.camera_pos = @as(v2f64, @floatFromInt(game.player_pos)) + subpixel_accum;
}
