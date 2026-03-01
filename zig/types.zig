//! Lists enums for communication between JS and WASM, or important misc ones.
pub const Command = enum(u32) { Reset, Begin, Exit, SendSeed };

pub const KeyBits = enum(u32) {
    K0 = 1 << 0,
    K1 = 1 << 1,
    K2 = 1 << 2,
    K3 = 1 << 3,
    K4 = 1 << 4,
    K5 = 1 << 5,
    K6 = 1 << 6,
    K7 = 1 << 7,
    K8 = 1 << 8,
    K9 = 1 << 9,
    UP = 1 << 10, // W, ArrowUp, Space
    LEFT = 1 << 11, // A, ArrowLeft
    DOWN = 1 << 12, // S, ArrowDown
    RIGHT = 1 << 13, // D, ArrowRight
};
