//! Root file. Imports main.zig and handles exporting functions to WASM. All functions here (excluding internal ones like panic) should be pub export to expose functions to generate_types.zig and WASM (with no other exports within other Zig files).
const std = @import("std");
const main = @import("main.zig");
const memory = @import("memory.zig");
const seeding = @import("seeding.zig");
const procedural = @import("internal/procedural.zig");
const logger = @import("logger.zig");
const player = @import("player.zig");
const colors = @import("color_rgba.zig");
const builtin = @import("builtin");

pub export fn init() void {
    main.init();
}
pub export fn reset() void {
    main.reset();
}
pub export fn prepare_visible_chunks(time_interpolated: f64, canvas_w: f64, canvas_h: f64) void {
    main.prepare_visible_chunks(time_interpolated, canvas_w, canvas_h);
}

pub export fn tick(speed: f64) void {
    player.move(speed);
}

pub export fn wasm_seed_from_string() void {
    seeding.wasm_seed_from_string(memory.scratch_buffer.ptr, memory.mem.scratch_len, &memory.game.seed);
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

        // Comment this test out if you lack access to internal files.
        export fn test_procedural() void {
            procedural.run_tests();
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
    const modules = .{
        @import("internal/png/png_to_binary.zig"),
    };

    inline for (modules) |mod| {
        std.testing.refAllDecls(mod);
    }
}

// Runs tests from other files. I have to remember to add more as necessary...
test "main_tests" {
    const modules = .{
        @import("color_rgba.zig"),
        @import("seeding.zig"),
        @import("logger.zig"),
    };

    inline for (modules) |mod| {
        std.testing.refAllDecls(mod);
    }
}
