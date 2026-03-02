const memory = @import("memory.zig");
const KeyBits = @import("types.zig").KeyBits;

const player_speed = 0.25;
pub fn move() void {
    if (KeyBits.isSet(KeyBits.up, memory.game.keys_held_mask)) {
        memory.game.player_pos[1] -= player_speed;
    } else if (KeyBits.isSet(KeyBits.down, memory.game.keys_held_mask)) {
        memory.game.player_pos[1] += player_speed;
    }

    if (KeyBits.isSet(KeyBits.left, memory.game.keys_held_mask)) {
        memory.game.player_pos[0] -= player_speed;
    } else if (KeyBits.isSet(KeyBits.right, memory.game.keys_held_mask)) {
        memory.game.player_pos[0] += player_speed;
    }

    // Set camera to negative of player position for now
    memory.game.camera_pos = -memory.game.player_pos;
}
