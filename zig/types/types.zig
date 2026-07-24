//! Lists enums for communication between JS and WASM, or important misc ones.
const std = @import("std");
const dw = @import("../root.zig");

const GameState = @import("../memory.zig").GameState; // Direct relative import
const GenerateOffsets = @import("../internal/offsets.zig").GenerateOffsets;

// Note: generate_types.zig will skip all all functions in structs, including pub ones.

/// Handles bitmasked data representing keyboard key inputs in the game.
pub const KeyBits = struct {
    /// Returns 2^index.
    inline fn mask(comptime index: u5) u32 {
        return @as(u32, 1) << index;
    }

    /// Checks if a specific key KeyBit is set within the bitfield.
    pub inline fn isSet(comptime bitfield: u32, key_mask: u32) bool {
        return (bitfield & key_mask) != 0;
    }

    /// Returns a number selected, if any.
    /// Prioritizes smaller numbers, returning 65535 for none.
    /// Treats 0 key as nine, and shifts 1-9 keys left by one (so 1 returns zero instead).
    pub inline fn getNumber(key_mask: u32) u16 {
        inline for (0..10) |i| { // k0 -> mask(0), k9 -> mask(9)
            if (key_mask & @This().mask(i) != 0) {
                if (i == 0) return 9;
                return i - 1;
            }
        }

        return 65535;
    }

    /// Z key (increases depth, for testing)
    pub const increase_depth = mask(21);
    /// X key (decreases depth, for testing)
    pub const decrease_depth = mask(20);

    /// Backquote key
    pub const mine = mask(19);
    /// Q key
    pub const inventory_up = mask(18);
    /// E key
    pub const inventory_down = mask(17);

    /// Minus (or underscore) key
    pub const minus = mask(16);
    /// Plus (or equals) key
    pub const plus = mask(15);

    /// W, ArrowUp, Space keys
    pub const up = mask(14);
    /// A, ArrowLeft keys
    pub const left = mask(13);
    /// S, ArrowDown keys
    pub const down = mask(12);
    /// D, ArrowRight keys
    pub const right = mask(11);

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
    /// Helper to map dx/dy offsets to these flags
    pub inline fn getFlagBit(dx: i32, dy: i32) u8 {
        if (dy == -1) {
            if (dx == -1) return TOP_LEFT;
            if (dx == 0) return TOP;
            if (dx == 1) return TOP_RIGHT;
        } else if (dy == 0) {
            if (dx == -1) return LEFT;
            if (dx == 1) return RIGHT;
        } else if (dy == 1) {
            if (dx == -1) return BOTTOM_LEFT;
            if (dx == 0) return BOTTOM;
            if (dx == 1) return BOTTOM_RIGHT;
        }
        return 0;
    }

    /// Neighboring block is to the top-left (Northwest)
    pub const TOP_LEFT = 0x01;
    /// Neighboring block is directly above (North)
    pub const TOP = 0x02;
    /// Neighboring block is to the top-right (Northeast)
    pub const TOP_RIGHT = 0x04;
    /// Neighboring block is to the left (West)
    pub const LEFT = 0x08;
    /// Neighboring block is to the right (East)
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
