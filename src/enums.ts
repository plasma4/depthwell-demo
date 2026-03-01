// This is a dynamically generated file from generate_types.zig for use in engine.ts. See the folders in /zig for more detailed documentation.

/**
 * A pointer in the WASM memory.
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
    readonly execute_commands: () => void;
    readonly wasm_seed_from_string: () => void;
    readonly get_memory_layout_ptr: () => Pointer;
    readonly wasm_alloc: (arg0: number) => Pointer;
    readonly wasm_free: (arg0: Pointer, arg1: number) => void;
    readonly scratch_alloc: (arg0: number) => Pointer;
    readonly isDebug: () => boolean;
}

// Enum data from types.zig:
export enum Command {
    Reset = 0,
    Begin = 1,
    Exit = 2,
    SendSeed = 3,
}

export enum KeyBits {
    K0 = 1,
    K1 = 2,
    K2 = 4,
    K3 = 8,
    K4 = 16,
    K5 = 32,
    K6 = 64,
    K7 = 128,
    K8 = 256,
    K9 = 512,
    UP = 1024,
    LEFT = 2048,
    DOWN = 4096,
    RIGHT = 8192,
}
