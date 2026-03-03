// This is a dynamically generated file from generate_types.zig for use in engine.ts and should not be manually modified. See types.zig for where type definitions come from.

/**
 * A pointer in the WASM memory. Equals 0 to represent a null value.
 */
export type Pointer = number;

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
    readonly tick: () => void;
    readonly renderFrame: () => void;
    readonly wasm_seed_from_string: () => void;
    readonly get_memory_layout_ptr: () => Pointer;
    readonly wasm_alloc: (arg0: number) => Pointer;
    readonly wasm_free: (arg0: Pointer, arg1: number) => void;
    readonly scratch_alloc: (arg0: number) => Pointer;
    readonly isDebug: () => boolean;
}

// Generated enum and struct data from types.zig:
export enum Command {
    Reset = 0,
    Exit = 1,
    SendSeed = 2,
}

export const KeyBits = {
    drop: 32768,
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

export const game_state_offsets = {
    player_pos: 0,
    player_d: 16,
    camera_pos: 32,
    camera_scale: 48,
    keys_pressed_mask: 56,
    keys_held_mask: 60,
    seed: 64,
} as const;
