//! Contains important functions and imports other files. See root.zig for exporting these functions (and others) to WASM.
const memory = @import("memory.zig");
const std = @import("std");
const dw = @import("Depthwell");
const logger = @import("logging.zig");

/// Initializes the game.
pub fn init() void {
    logger.log(@src(), "init() called: Hello from Zig!", .{});
    memory.mem.scratch_ptr = @intFromPtr(&memory.scratch_buffer);
}

/// Resets the game state.
pub fn reset() void {}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    _ = ret_addr;

    logger.err(@src(), "PANIC: {s}", .{msg});
    @trap();
}
