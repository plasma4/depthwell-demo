//! Handles procedural generation logic for the game.
const memory = @import("memory.zig");
const seeding = @import("seeding.zig");
const world = @import("world.zig");

const Sprite = world.Sprite;

/// Generates an initial block for seeding.
pub inline fn generate_initial_block(moisture: f64, density: f64, height: f64) Sprite {
    _ = moisture;
    _ = height;

    if (density < 0.4) return .none;
    if (density < 0.55) return .spiral_plant;
    if (density < 0.8) return .stone;
    if (density < 0.85) return .gold;
    if (density < 0.95) return .iron;
    return .silver;
}

inline fn lerp(a: f64, b: f64, t: f64) f64 {
    return a + t * (b - a);
}

inline fn fade(t: f64) f64 {
    // Smootherstep: 6t^5 - 15t^4 + 10t^3
    return t * t * t * (t * (t * 6 - 15) + 10);
}

pub fn get_value_noise(base_seed: seeding.Seed, world_x: f64, world_y: f64) f64 {
    const x0 = @floor(world_x);
    const y0 = @floor(world_y);

    const fx = world_x - x0;
    const fy = world_y - y0;

    // Get 4 random values for the corners
    const v00 = get_random_value(base_seed, @intFromFloat(x0), @intFromFloat(y0));
    const v10 = get_random_value(base_seed, @intFromFloat(x0 + 1), @intFromFloat(y0));
    const v01 = get_random_value(base_seed, @intFromFloat(x0), @intFromFloat(y0 + 1));
    const v11 = get_random_value(base_seed, @intFromFloat(x0 + 1), @intFromFloat(y0 + 1));

    // Smooth the coordinates
    const u = fade(fx);
    const v = fade(fy);

    // Bilinear interpolation
    return lerp(lerp(v00, v10, u), lerp(v01, v11, u), v);
}

/// Returns a random deterministic value based on an X and Y value.
fn get_random_value(seed: seeding.Seed, x: u64, y: u64) f64 {
    var key = seed;
    key[0] ^= @bitCast(x);
    key[1] ^= @bitCast(y);
    var prng = seeding.ChaCha12.init(key);
    return @as(f64, @floatFromInt(prng.next())) * (1.0 / 18446744073709551616.0);
}

/// Simple noise for testing. Unused.
pub fn get_test_noise(seed: seeding.Seed, x: f64, y: f64) f64 {
    _ = .{ x, y };
    var prng = seeding.ChaCha12.init(seed);
    return @as(f64, @floatFromInt(prng.next() & 127)) / 128;
}
