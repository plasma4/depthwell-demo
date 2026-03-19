// This is a dynamically generated file from generate_types.zig for use in engine.ts and should not be manually modified. See types.zig for where type definitions come from.

/**
 * A pointer in the WASM memory. Equals 0/0n to represent a null value.
 */
export type Pointer = number | bigint;

/**
 * Represents a length from Zig.
 */
export type LengthLike = number | bigint;

/**
 * A pointer in the WASM memory (converted from potential BigInt to number).
 */
export type PointerLike = number;

/**
 * Represents a set of errors from Zig.
 */
export type ErrorSet = number;

/**
 * Configuration options for the GameEngine.
 */
export interface EngineOptions {
    highPerformance?: boolean;
}

// Generated from exported functions (should all be in root.zig):
export interface EngineExports extends WebAssembly.Exports {
    readonly memory: WebAssembly.Memory;

    readonly init: () => void;
    readonly reset: () => void;
    readonly prepare_visible_chunks: (arg0: number, arg1: number, arg2: number) => void;
    readonly tick: (arg0: number) => void;
    readonly wasm_seed_from_string: () => void;
    readonly get_memory_layout_ptr: () => Pointer;
    readonly wasm_alloc: (arg0: number) => Pointer;
    readonly wasm_free: (arg0: Pointer, arg1: number) => void;
    readonly scratch_alloc: (arg0: number) => Pointer;
    readonly isDebug: () => boolean;
}

// Generated enum and struct data from types.zig:
export const KeyBits = {
    drop: 131072,
    minus: 32768,
    plus: 65536,
    up: 2048,
    left: 4096,
    down: 8192,
    right: 16384,
    k0: 1,
    k1: 2,
    k2: 4,
    k3: 8,
    k4: 16,
    k5: 32,
    k6: 64,
    k7: 128,
    k8: 256,
    k9: 512,
} as const;

export const EdgeFlags = {
    TOP_LEFT: 1,
    TOP: 2,
    TOP_RIGHT: 4,
    LEFT: 8,
    RIGHT: 16,
    BOTTOM_LEFT: 32,
    BOTTOM: 64,
    BOTTOM_RIGHT: 128,
} as const;

export const game_state_offsets = {
    player_pos: 0,
    last_player_pos: 16,
    player_chunk: 32,
    player_velocity: 48,
    camera_pos: 64,
    last_camera_pos: 80,
    camera_scale: 96,
    camera_scale_change: 104,
    player_screen_offset: 112,
    grid_dirty: 120,
    last_grid_min_bx: 124,
    last_grid_min_by: 128,
    last_player_chunk_x: 136,
    last_player_chunk_y: 144,
    depth: 152,
    keys_pressed_mask: 160,
    keys_held_mask: 164,
    seed: 176,
} as const;
