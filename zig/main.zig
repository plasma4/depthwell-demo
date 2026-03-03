//! Contains important functions and imports other files. See root.zig for exporting these functions (and others) to WASM.
const memory = @import("memory.zig");
const std = @import("std");
const dw = @import("Depthwell");
const logger = @import("logger.zig");

/// Initializes the game.
pub fn init() void {
    logger.log(@src(), "init() called: Hello from Zig!", .{});
    memory.mem.game_ptr = @intFromPtr(&memory.game);
    memory.mem.scratch_ptr = @intFromPtr(&memory.scratch_buffer);
}

/// Resets the game state.
pub fn reset() void {}
