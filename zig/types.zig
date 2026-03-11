//! Lists enums for communication between JS and WASM, or important misc ones.
const std = @import("std");
const GameState = @import("memory.zig").GameState;
const GenerateOffsets = @import("generate_types.zig").GenerateOffsets;
/// Lists possible command types.
pub const Command = enum(u32) { Reset, Exit, SendSeed };

/// Masked data representing keyboard key inputs in the game.
pub const KeyBits = struct {
    // Note: generate_types.zig will skip all functions in structs, including pub ones (why would you have them here anyway??).
    fn mask(index: u5) u32 {
        return @as(u32, 1) << index;
    }

    /// Checks if a specific key KeyBit is set within the bitfield.
    pub fn isSet(bitfield: u32, key_mask: u32) bool {
        return (bitfield & key_mask) != 0;
    }

    /// Q key
    pub const drop = mask(17);

    /// Minus (or underscore) key
    pub const minus = mask(15);
    /// Plus (or equals) key
    pub const plus = mask(16);

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

/// Bitmask flags used to identify the presence of neighboring blocks.
pub const EdgeFlags = struct {
    /// Neighboring block is to the top-left (Northwest)
    pub const TOP_LEFT = 0x01;
    /// Neighboring block is directly above (North)
    pub const TOP = 0x02;
    /// Neighboring block is to the top-right (Northeast)
    pub const TOP_RIGHT = 0x04;
    /// Neighboring block is to the immediate left (West)
    pub const LEFT = 0x08;
    /// Neighboring block is to the immediate right (East)
    pub const RIGHT = 0x10;
    /// Neighboring block is to the bottom-left (Southwest)
    pub const BOTTOM_LEFT = 0x20;
    /// Neighboring block is directly below (South)
    pub const BOTTOM = 0x40;
    /// Neighboring block is to the bottom-right (Southeast)
    pub const BOTTOM_RIGHT = 0x80;
};

/// Represents location of items in GameState (in memory.zig), for use in JS.
pub const game_state_offsets = GenerateOffsets(GameState){};
