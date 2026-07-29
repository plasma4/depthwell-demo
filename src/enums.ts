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
 * A pointer in the WASM memory (converted from potential BigInt to number). Safe because memory size can't reasonably grow past 2**53 bytes.
 */
export type PointerLike = number;

/**
 * Represents a set of errors from Zig.
 */
export type ErrorSet = number;

/**
 * Configuration options for the `GameEngine`.
 */
export interface EngineOptions {
    highPerformance?: boolean;
}

/** Generated from exported functions (should all be in `zig/root.zig`). */
export interface EngineExports extends WebAssembly.Exports {
    readonly memory: WebAssembly.Memory;

    readonly SegmentedList: (arg0: unknown, arg1: number) => unknown;
    readonly Fifo: (arg0: unknown) => unknown;
    readonly handleTick: (arg0: number, arg1: number) => void;
    readonly jsMessage: (arg0: number /* Pointers are questionably supported from Zig due to Memory64 export issues. You may want to return/request a u64 instead. */, arg1: number, arg2: number) => void;
    readonly jsWriteText: (arg0: number, arg1: number /* Pointers are questionably supported from Zig due to Memory64 export issues. You may want to return/request a u64 instead. */, arg2: number) => void;
    readonly jsGetTime: () => number;
    readonly jsHandleVisibleChunks: (arg0: number, arg1: number) => void;
    readonly jsHandleVisibleEntities: () => void;
    readonly jsDrawBackground: (arg0: number) => void;
    readonly jsSetMouseType: (arg0: number) => void;
    readonly jsPlaySound: (arg0: number, arg1: number, arg2: number) => void;
    readonly main: () => void;
    readonly init: () => void;
    readonly initSkipSetup: () => void;
    readonly prepareVisibleData: (arg0: number, arg1: number, arg2: number, arg3: number) => void;
    readonly getTilesPerRow: () => number;
    readonly getTilesPerColumn: () => number;
    readonly handleMouse: (arg0: number, arg1: number, arg2: number) => void;
    readonly tick: (arg0: number, arg1: number) => void;
    readonly mixSeed: (arg0: bigint) => bigint;
    readonly mixSeedF64: (arg0: bigint) => number;
    readonly setSeedString: (arg0: bigint, arg1: bigint) => void;
    readonly getSeedStringLen: () => bigint;
    readonly getSeedStringPtr: () => bigint;
    readonly getMemoryLayoutPtr: () => bigint;
    readonly scratchAlloc: (arg0: number) => bigint;
    readonly isDebug: () => boolean;
    readonly saveExportAll: () => bigint;
    readonly saveGetExportPtr: () => bigint;
    readonly saveGetExportLen: () => bigint;
    readonly saveBeginSnapshot: () => bigint;
    readonly saveWriteBatch: (arg0: bigint) => bigint;
    readonly savePrepareImport: (arg0: bigint) => bigint;
    readonly saveImportAll: (arg0: bigint) => boolean;
    readonly saveFinalizeLoad: () => void;
    readonly saveLastImportError: () => number;
}

// Generated enum and struct data from types.zig:
export const KeyBits = {
    increase_depth: 2097152,
    decrease_depth: 1048576,
    mine: 524288,
    inventory_up: 262144,
    inventory_down: 131072,
    minus: 65536,
    plus: 32768,
    up: 16384,
    left: 8192,
    down: 4096,
    right: 2048,
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
    depth: 112,
    player_quadrant: 120,
    frame: 124,
    blocks_mined: 128,
    keys_pressed_mask: 136,
    keys_held_mask: 140,
    seed: 144,
    seed2: 208,
    portal_chunk: 416,
    bg_time: 432,
    portal_frame: 440,
    portal_phase: 444,
    portal_quadrant: 445,
    portal_bx: 446,
    portal_by: 447,
    seed_string: 448,
    seed_string_len: 548,
} as const;
