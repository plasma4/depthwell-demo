const memory = @import("memory.zig");
const math = @import("math.zig");
const logger = @import("logger.zig");
const KeyBits = @import("types.zig").KeyBits;

const v2i64 = @Vector(2, i64);
const v2f64 = @Vector(2, f64);
const player_speed = 256;

pub fn move() void {
    const game = &memory.game;
    var position_change: @Vector(2, i64) = .{ 0, 0 };

    if (KeyBits.isSet(KeyBits.left, memory.game.keys_held_mask)) {
        position_change[0] = -player_speed;
    } else if (KeyBits.isSet(KeyBits.right, memory.game.keys_held_mask)) {
        position_change[0] = player_speed;
    }

    if (KeyBits.isSet(KeyBits.up, memory.game.keys_held_mask)) {
        position_change[1] = -player_speed;
    } else if (KeyBits.isSet(KeyBits.down, memory.game.keys_held_mask)) {
        position_change[1] = player_speed;
    }

    const decay = (game.player_d * @as(v2i64, @splat(7))) / @as(v2i64, @splat(8));
    const gain = (position_change * @as(v2i64, @splat(1))) / @as(v2i64, @splat(8));

    game.player_d = math.zero_if_less_than(decay + gain, 1);
    game.player_pos += game.player_d;

    // Set camera to negative of player position for now
    game.camera_pos = @as(v2f64, @floatFromInt(memory.game.player_pos)) * @as(v2f64, @splat(-64));
}
