//! Contains sound effect logic and dispatches them to JavaScript.
const std = @import("std");
const dw = @import("../root.zig");

/// Random seed used for particle spawning. Seeded in `startup.init()`.
pub var seed: dw.seeding.ChaCha12 = undefined;

/// Use volume and pitch arguments to control a random percentage-based variation.
pub fn playSound(id: u32, base_volume: f64, volume_variation: f64, pitch_variation: f64) void {
    if (dw.is_wasm) {
        dw.jsPlaySound(
            id,
            @max(base_volume + generateVariation(volume_variation), 0.1),
            1.0 + generateVariation(pitch_variation),
        );
    } else {
        return;
    }
}

/// Generates a number from -mult to +mult by advancing `seed`.
pub fn generateVariation(mult: f64) f64 {
    return @as(f64, @floatFromInt(seed.next())) * (std.math.pow(f64, 2, -63) * mult);
}
