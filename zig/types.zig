//! Lists enums for communication between JS and WASM, or important misc ones.
const GameState = @import("memory.zig").GameState;
/// Lists possible command keys.
pub const Command = enum(u32) { Reset, Begin, Exit, SendSeed };

/// Masked data representing keyboard keys in the game.
pub const KeyBits = struct {
    // Note: generate_types.zig will skip all functions in KeyBits, including pub ones.
    fn mask(index: u5) u32 {
        return @as(u32, 1) << index;
    }

    /// Checks if a specific key KeyBit is set within the bitfield.
    pub fn isSet(bitfield: u32, key_mask: u32) bool {
        return (bitfield & key_mask) != 0;
    }

    /// W, ArrowUp, Space keys
    pub const up = mask(11);
    /// A, ArrowLeft keys
    pub const left = mask(12);
    /// S, ArrowDown keys
    pub const down = mask(13);
    /// D, ArrowRight keys
    pub const right = mask(14);

    /// 0 key
    pub const k0 = mask(0);
    /// 1 key
    pub const k1 = mask(1);
    /// 2 key
    pub const k2 = mask(2);
    /// 3 key
    pub const k3 = mask(3);
    /// 4 key
    pub const k4 = mask(4);
    /// 5 key
    pub const k5 = mask(5);
    /// 6 key
    pub const k6 = mask(6);
    /// 7 key
    pub const k7 = mask(7);
    /// 8 key
    pub const k8 = mask(8);
    /// 9 key
    pub const k9 = mask(9);
};

/// Represents location of items in GameState (in memory.zig), for use in JS.
pub const game_state_offsets = struct {
    pub const player_pos = @offsetOf(GameState, "player_pos");
    pub const camera_pos = @offsetOf(GameState, "camera_pos");
    pub const camera_scale = @offsetOf(GameState, "camera_scale");
    pub const keys_pressed_mask = @offsetOf(GameState, "keys_pressed_mask");
    pub const keys_held_mask = @offsetOf(GameState, "keys_held_mask");
    pub const seed = @offsetOf(GameState, "seed");
};
