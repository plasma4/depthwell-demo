//! Root file. Imports various other codebase files for easy access and handles exporting functions to WASM.
//! All functions here (excluding internal ones like panic) should be `pub` to expose functions to `generate_types.zig`,
//! and `extern` for WASM (with no other exported functions within other Zig files).
const std = @import("std");
const builtin = @import("builtin");

/// Whether to force `is_debug` to true regardless of build mode.
/// Goes without saying: this should be false in prod!
pub const FORCE_DEBUG = true;
// pub const FORCE_DEBUG = builtin.mode != .ReleaseFast;

/// Set to true if the CPU architecture is set to `wasm32` or `wasm64`.
pub const is_wasm = builtin.target.cpu.arch == .wasm32 or builtin.target.cpu.arch == .wasm64;
/// Set to true if either test mode or `Debug` mode is used.
pub const is_debug = FORCE_DEBUG or builtin.is_test or builtin.mode == .Debug;

// Note: changing these constants below will probably have disastrous consequences.
// A lot of logic is hard-coded, such as `[6][6]Sprite` use, and a lot of logic is bound to break if these constants are modified.

/// Represents log2(CHUNK_SIZE).
pub const CHUNK_SIZE_LOG2: comptime_int = 4;
// (Note: we use u4 instead of a type defined here for simplicity: these are hard-coded and not subjected to change regardless.)

/// The core dimension, 16: how many units one level spans of the level below, along a single axis.
/// - blocks per chunk edge
/// - pixels per block edge
/// - subpixels per pixel edge
pub const CHUNK_SIZE: comptime_int = 16;
/// `CHUNK_SIZE` squared, 256, along a single axis:
/// - subpixels per block edge
/// - pixels per chunk edge
pub const CHUNK_SIZE_SQ: comptime_int = CHUNK_SIZE * CHUNK_SIZE;
/// `CHUNK_SIZE` cubed, 4096: subpixels per chunk edge.
/// Player X/Y wrap within [0, 4095] (= this value minus one).
pub const SUBPIXELS_IN_CHUNK: comptime_int = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE;

/// Float equivalent of `CHUNK_SIZE`.
pub const CHUNK_SIZE_FLOAT: comptime_float = @floatFromInt(CHUNK_SIZE);
/// Float equivalent of `CHUNK_SIZE_SQ`.
pub const CHUNK_SIZE_FLOAT_SQ: comptime_float = @floatFromInt(CHUNK_SIZE_SQ);

/// Represents log2(ZOOM_FACTOR).
pub const ZOOM_LOG2: comptime_int = 2;
/// The factor for zooming, increasing the depth by 1.
/// (So, 4 times means that the world will get 4 times wider and taller during depth increase.)
pub const ZOOM_FACTOR: comptime_int = 4;
/// The highest possible depth value where all coordinates can be represented in 1 quadrant.
/// Equivalent to the highest depth value where `ZOOM_LOG2 * HORIZON_DEPTH <= 64` is true.
///
/// This is an important value for ancestry and depth increase calculations.
pub const HORIZON_DEPTH: comptime_int = 32;
/// Represents how many blocks in a child chunk map to ONE parent block.
/// A 4x4 area of child blocks is 1 parent block if `ZOOM_FACTOR` is 4.
pub const BLOCKS_PER_PARENT: comptime_int = CHUNK_SIZE / ZOOM_FACTOR;

pub const memory = @import("memory.zig");
pub const startup = @import("startup.zig");

// The width of the screen for the internal viewport. Normalized to 0-1 before being used in WebGPU.
pub const SCREEN_WIDTH = 480;
// The height of the screen for the internal viewport. Normalized to 0-1 before being used in WebGPU.
pub const SCREEN_HEIGHT = 270;
// Half the internal viewport width.
pub const SCREEN_WIDTH_HALF = SCREEN_WIDTH / 2;
// Half the internal viewport height.
pub const SCREEN_HEIGHT_HALF = SCREEN_HEIGHT / 2;

pub const utils = @import("internal/utils.zig");
pub const GenerateOffsets = @import("internal/offsets.zig").GenerateOffsets;
pub const SegmentedList = @import("internal/segmented_list.zig").SegmentedList;
pub const Fifo = @import("internal/fifo.zig").UnboundedFifo;
pub const ColorRgba = @import("internal/color_rgba.zig").ColorRgba;

pub const render = @import("render/render.zig");
pub const sound = @import("render/sound.zig");
pub const chunks = @import("render/chunk.zig");
pub const lighting = @import("render/lighting.zig");
pub const entity = @import("render/entity.zig");
pub const progress = @import("render/progress.zig");
pub const indicators = @import("render/indicators.zig");
pub const particles = @import("render/particles.zig");

pub const types = @import("types/types.zig");
pub const KeyBits = types.KeyBits;
pub const geometry = @import("types/geometry.zig");

pub const sprite = @import("types/sprite.zig");
pub const Sprite = sprite.Sprite;
pub const variation = @import("types/variation.zig");

pub const drops = @import("state/drops.zig");
pub const seeding = @import("state/seeding.zig");
pub const procedural = @import("state/procedural.zig");
pub const structures = @import("state/structures.zig");
pub const decorations = @import("state/decorations.zig");
pub const player = @import("state/player.zig");
pub const world = @import("state/world.zig");
pub const ancestor = @import("state/ancestor.zig");
pub const water = @import("state/water.zig");
pub const portal = @import("state/portal.zig");
pub const save = @import("state/save.zig");
pub const handleTick = @import("state/tick.zig").handleTick;

pub const logger = @import("debug/logger.zig");
pub const chunk_preview = @import("debug/chunk_preview.zig");
pub const audit = @import("debug/audit.zig");

pub const inventory = @import("input/inventory.zig");
pub const mining = @import("input/mining.zig");
pub const mouse = @import("input/mouse.zig");

/// Logging bridge between JS and WASM.
pub extern "env" fn jsMessage(ptr: [*]const u8, len: usize, message_type: logger.LogCategory) void;

/// Logging bridge between JS and WASM for writing to specific text elements.
pub extern "env" fn jsWriteText(id: u8, ptr: [*]const u8, len: usize) void;

/// Returns the current time (calling `performance.now()` in JS)
pub extern "env" fn jsGetTime() f64;

/// External function that makes a call to `engine.handleVisibleChunks()`.
pub extern "env" fn jsHandleVisibleChunks(opacity: f64, wireframe_opacity: f64) void;

/// External function that makes a call to `engine.handleVisibleEntities()`.
pub extern "env" fn jsHandleVisibleEntities() void;

/// External function that makes a call to `engine.drawBackground()`.
/// Draws the background using the scene the most recent chunk pass published.
pub extern "env" fn jsDrawBackground(opacity: f64) void;

/// External function that makes a call to `engine.setMouseType()`.
pub extern "env" fn jsSetMouseType(mouse_type: mouse.CursorType) void;

/// External function that plays a sound (with pitch and volume variation factors).
/// Plays the chosen sound through `AudioContext`.
pub extern "env" fn jsPlaySound(soundId: u32, volume: f64, pitch: f64) void;

pub fn main() callconv(.c) void {
    // nothing happens here for now
}

comptime {
    if (is_wasm) {
        @export(&main, .{
            .name = "main",
            .linkage = .strong,
        });
    }
}

pub export fn init() void {
    startup.init(true);
}
pub export fn initSkipSetup() void {
    startup.init(false);
}
pub export fn prepareVisibleData(time_interpolated: f64, time_diff: f64, canvas_w: f64, canvas_h: f64) void {
    render.prepareVisibleData(time_interpolated, time_diff, canvas_w, canvas_h);
}

// Dimensions of sprite sheet
pub export fn getTilesPerRow() u32 {
    // Sprites are saved as a .png in a sprite sheet 256 pixels wide from build.zig
    // each individual sprite is 16x16, so there's 16 tiles/row (or 16 columns)
    return 16;
}
pub export fn getTilesPerColumn() u32 {
    return sprite.max_sprite_value / getTilesPerRow() + 1; // works out from 0-indexing
}

pub export fn handleMouse(mouse_x: f64, mouse_y: f64, action: u32) void {
    mouse.handleMouse(mouse_x, mouse_y, action);
}

pub export fn tick(logic_speed: f64, iterations: u32) void {
    // A trap inside handleTick() leaves this set, so the torn state can never be saved (see `save.in_tick`).
    save.in_tick = true;
    handleTick(logic_speed, iterations);
    save.in_tick = false;

    // give some helpful info!
    // this gets cleared every frame since writeOnce() is used
    // logger.writeOnce(3, .{
    //     "{mh}Selected sprite ID",
    //     inventory.selected_sprite.getName(),
    //     "{mh}Hovered sprite type",
    //     if (mouse.mouse_chunk_coord) |coord| world.getChunk(coord).getBlock(mouse.mouse_block_x, mouse.mouse_block_y).id.getName() else null,
    //     "{mh}Mouse status",
    //     mouse.cursor_type,
    // });
    // logger.writeOnce(3, .{if (mouse.mouse_chunk_coord) |coord| world.getChunk(coord).getBlock(mouse.mouse_block_x, mouse.mouse_block_y) else null});
}

pub export fn mixSeed(number: u64) i64 {
    // IMPORTANT! For some reason, it appears that this returns an `i64` even with `u64` return type.
    // Therefore, that's the type we return.
    return @intCast(seeding.mixBaseSeed(memory.game.seed, @enumFromInt(number)).value[0] >> 1);
}
pub export fn mixSeedF64(number: u64) f64 { // same thing as mix_seed but f64
    return @as(f64, @floatFromInt(
        seeding.mixBaseSeed(memory.game.seed, @enumFromInt(number)).value[0] >> 1,
    )) / seeding.POW_2_64;
}

// pub export fn wasmSeedFromString() void {
//     seeding.wasmSeedFromString(
//         memory.scratch_buffer.ptr,
//         memory.mem.scratch_len,
//         &memory.game.seed,
//     );
// }

/// Records the seed string a world was created from, alongside the derived `seed` the host writes
/// straight into `GameState`. Call it with a scratch-buffer pointer from `writeStr()`.
/// Over-long input is truncated rather than rejected; see `GameState.setSeedString()`.
pub export fn setSeedString(str_ptr: u64, str_len: u64) void {
    const ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(str_ptr)));
    memory.game.setSeedString(ptr[0..@intCast(str_len)]);
}

/// Length of the recorded seed string; 0 for a world saved before it was recorded.
pub export fn getSeedStringLen() u64 {
    return memory.game.seed_string_len;
}

/// Pointer to the recorded seed string, to be read with `getSeedStringLen()` bytes.
pub export fn getSeedStringPtr() u64 {
    return @intFromPtr(&memory.game.seed_string);
}

// Layout logic
pub export fn getMemoryLayoutPtr() u64 { // pointer-like *const memory.MemoryLayout, Memory64 hack
    return @intFromPtr(memory.getMemoryLayoutPtr());
}
pub export fn scratchAlloc(len: usize) u64 { // pointer-like [*]u8, Memory64 hack
    return @intFromPtr(memory.scratchAlloc(len));
}
// pub export fn wasmAlloc(len: usize) u64 { // pointer-like [*]u8, Memory64 hack
//     return @intFromPtr(memory.wasmAlloc(len));
// }
// pub export fn wasmFree(ptr: u64, len: usize) void {
//     memory.wasmFree(@ptrFromInt(@as(usize, @intCast(ptr))), len); // Memory64 hack
// }

/// Returns if code is in debugging mode for JS to see.
pub export fn isDebug() bool {
    return is_debug;
}

// Save/load API. The JS host owns the atomic OPFS write and per-frame budgeting;
// these move data across the boundary and (de)serialize the game state (see state/save.zig).
pub export fn saveExportAll() u64 {
    return save.exportAll();
}
pub export fn saveGetExportPtr() u64 { // pointer-like [*]u8, Memory64 hack
    return save.getExportPtr();
}
pub export fn saveGetExportLen() u64 {
    return save.getExportLen();
}
pub export fn saveBeginSnapshot() i64 {
    return save.beginSnapshot();
}
pub export fn saveWriteBatch(max_chunks: u64) i64 {
    return save.writeBatch(@intCast(max_chunks));
}
pub export fn savePrepareImport(len: u64) u64 { // pointer-like [*]u8, Memory32/64 consistency hack
    return save.prepareImport(@intCast(len));
}
pub export fn saveImportAll(len: u64) bool {
    return save.importAll(@intCast(len));
}
pub export fn saveFinalizeLoad() void {
    save.finalizeLoad();
}
pub export fn saveLastImportError() u32 {
    return save.lastImportError();
}

// Import debugging API and functions if optimization level is Debug.
comptime {
    _ = if (is_debug) struct {
        pub const debug_ui = @import("debug/debug_ui.zig");
        pub export fn debugBuildUiMetadata() void {
            if (is_debug) debug_ui.buildMetadata();
        }
        pub export fn changeDebugUiSlider(id: u32, val: f32) void {
            if (is_debug) debug_ui.changeSlider(id, val);
        }
        pub export fn clickDebugUiButton(id: u32) void {
            if (is_debug) debug_ui.clickButton(id);
        }

        pub export fn testLogs() void {
            logger.testLogs(true);
        }

        pub export fn testScratchAlloc() void {
            memory.runScratchAllocTests();
        }

        pub export fn sampleWorldAroundPlayer() void {
            audit.sampleWorldAroundPlayer();
        }

        pub export fn verifyInvariants() void {
            audit.verifySimInvariants();
        }

        pub export fn validateSimBuffer() void {
            if (world.SimBuffer.validateSimBuffer())
                logger.log(@src(), "Edge flag and sprite validity check passed for all resident SimBuffer chunks.", .{})
            else
                logger.err(@src(), "Edge flag and sprite validity check FAILED (see logged mismatches above).", .{});
        }

        /// Checks that every chunk held live, in the `SimBuffer` or in `chunk_cache` behind it,
        /// still equals what a rebuild from `mod_store` would produce.
        pub export fn validateSimPersistence() void {
            if (world.SimBuffer.validateAgainstMaterialization())
                logger.log(@src(), "Every resident SimBuffer chunk matches its materialization.", .{})
            else
                logger.err(@src(), "SimBuffer persistence check FAILED (see logged divergences above).", .{});

            if (world.chunk_cache.validateAgainstMaterialization())
                logger.log(@src(), "Every cached chunk outside the SimBuffer matches its materialization.", .{})
            else
                logger.err(@src(), "ChunkCache persistence check FAILED (see logged divergences above).", .{});
        }

        pub export fn logInventory() void {
            inventory.logInventory();
        }

        pub export fn testPanic() void {
            logger.log(@src(), "A call to @panic() will be dispatched. This should trap or abort the program.", .{});
            @panic("Panic test!");
        }

        // pub export fn getParent(x: u64, y: u64, quadrant: u32, depth: u32) void {
        //     if (depth < startup.STARTING_ZOOM_TIMES)
        //         logger.quick("Depth is too small! ):")
        //     else if (depth > memory.game.depth)
        //         logger.quick("Depth is higher than current game depth!")
        //     else {
        //         var key = world.DepthCoordinate{
        //             .quadrant = quadrant,
        //             .suffix = .{ x, y },
        //             .depth = memory.game.depth,
        //         };
        //         while (key.depth > depth) {
        //             key = key.getParent();
        //         }
        //         logger.quick(.{ "{h}Resulting key", key });
        //     }
        // }

        // pub export fn getPlayerPosAtDepth(depth: u32) void {
        //     logger.quick(.{ "{h}Current depth", memory.game.depth });
        //     if (depth == 0) {
        //         logger.quick(.{ "{h}Current coord", memory.game.getPlayerCoord() });
        //         return;
        //     }
        //     var key = memory.game.getPlayerCoord().asDepthCoordinate(depth);
        //     while (key.depth > depth) {
        //         key = key.getParent();
        //     }
        //     logger.quick(.{ "{h}Resulting key", key });
        // }
    };
}

/// Custom override panic function that calls `logger.err()` and either traps or aborts the process.
pub const panic = std.debug.FullPanic(customPanic);

fn customPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    @branchHint(.cold);
    if (ret_addr) |addr| {
        logger.err(@src(), "PANIC [addr: 0x{x}]: {s}", .{ addr, msg });
    } else logger.err(@src(), "PANIC: {s}", .{msg});
    if (is_wasm) @trap() else std.process.abort();
}

// Runs tests from other files. I have to remember to add more as necessary when new files with tests appear...
test "main_tests" {
    const modules = .{
        @import("png/png_to_binary.zig"),
        @import("internal/color_rgba.zig"),
        @import("state/seeding.zig"),
        @import("debug/logger.zig"),
        @import("state/world.zig"),
        @import("state/save.zig"),
        @import("state/structures.zig"),
        @import("state/template.zig"),
        @import("render/particles.zig"),
        // Not registered in the `structures` tuple on purpose; listed here only so its test still runs.
        @import("state/structures/Example.zig"),
    };

    inline for (modules) |mod| {
        std.testing.refAllDecls(mod);
    }
}
