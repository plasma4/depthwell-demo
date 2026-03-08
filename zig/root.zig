//! Root file. Imports main.zig and handles exporting functions to WASM. All functions here (excluding internal ones like panic) should be pub export to expose functions to generate_types.zig and WASM (with no other exports within other Zig files).
const std = @import("std");
const main = @import("main.zig");
const memory = @import("memory.zig");
const seeding = @import("seeding.zig");
const logger = @import("logger.zig");
const player = @import("player.zig");
const colors = @import("color_rgba.zig");
const chunk = @import("chunk.zig");
const builtin = @import("builtin");

pub export fn init() void {
    main.init();
}
pub export fn reset() void {
    main.reset();
}

pub export fn tick() void {
    player.move();
}
pub export fn renderFrame() void {}

pub export fn wasm_seed_from_string() void {
    seeding.wasm_seed_from_string(memory.scratch_buffer.ptr, memory.mem.scratch_len, &memory.game.seed);
}

var test_chunk: memory.Chunk = std.mem.zeroInit(memory.Chunk, .{});
var test_coord: chunk.ScaleCoord = .{
    .depth_stack = &[_]u64{ 0x0, 0x0 },
    .pos = .{ 10, -5 },
};

/// Generate a test chunk with the given seed. Returns pointer to tile data.
pub export fn generate_chunk() [*]u32 {
    chunk.generate_chunk(&test_chunk, test_coord);
    return chunk.get_tile_ptr(&test_chunk);
}

/// Get pointer to the current test chunk tile data
pub export fn get_test_chunk_ptr() [*]u32 {
    return chunk.get_tile_ptr(&test_chunk);
}

/// Get total chunk size (width * height)
pub export fn get_chunk_size() u32 {
    return memory.CHUNK_SIZE;
}

/// Recalculate edge flags for the test chunk (after manual modifications)
pub export fn recalculate_test_chunk_edges() void {
    chunk.recalculate_edge_flags(&test_chunk);
}

// Layout logic
pub export fn get_memory_layout_ptr() *const memory.MemoryLayout {
    return memory.get_memory_layout_ptr();
}
pub export fn wasm_alloc(len: usize) ?[*]u8 {
    return memory.wasm_alloc(len);
}
pub export fn wasm_free(ptr: [*]u8, len: usize) void {
    memory.wasm_free(ptr, len);
}
pub export fn scratch_alloc(len: usize) ?[*]u8 {
    return memory.scratch_alloc(len);
}

// Debug/testing logic

const in_debug_mode = builtin.mode == .Debug;

/// Returns if code is in debugging mode for JS to see.
pub export fn isDebug() bool {
    return in_debug_mode;
}

// Import debugging API if optimization level is Debug.
comptime {
    _ = if (in_debug_mode) struct {
        export fn test_logs() void {
            logger.test_logs(true);
        }

        export fn test_scratch_allocation() void {
            memory.run_scratch_allocation_tests();
        }
    };
}

/// Custom panic function. Note that you can press the arrow for any warnings/errors to see more detailed information (so you might be able to see details such as $debug.FullPanic((function 'panic')).integerOverflow)
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    const addr = ret_addr orelse 0;
    logger.err(@src(), "PANIC [addr: 0x{x}]: {s}", .{ addr, msg });
    @trap();
}

// Comment this test out if you lack access to internal files.
test "internal imports" {
    _ = @import("internal/png/png_to_binary.zig");
}

// Runs tests from other files. I have to remember to add more as necessary...
test "main_tests" {
    const modules = .{
        @import("color_rgba.zig"),
        @import("seeding.zig"),
        @import("logger.zig"),
        @import("math.zig"),
    };

    inline for (modules) |mod| {
        std.testing.refAllDecls(mod);
    }
}
