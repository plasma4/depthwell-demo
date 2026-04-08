//! Handles procedural generation logic for the game.
const std = @import("std");
const logger = @import("logger.zig");
const memory = @import("memory.zig");
const seeding = @import("seeding.zig");
const world = @import("world.zig");

const POW_2_64 = seeding.POW_2_64;
const hash_2d = seeding.ChaCha12.hash_2d;
const Seed = seeding.Seed;
const Sprite = world.Sprite;

/// Generates a block for seeding (based on previous procedural generation logic).
pub inline fn generate_block_from_values(moisture: f64, density: f64, height: f64) Sprite {
    _ = moisture;
    _ = height;

    return @enumFromInt(512 - @as(u20, @intFromFloat(density * 256.0))); // sprite IDs from 256-512 create a neat little heatmap
    // if (density < 0.1) return .none;
    // if (density < 0.2) return .spiral_plant;
    // if (density < 0.3) return .edge_stone;
    // if (density < 0.4) return .green_stone;
    // if (density < 0.5) return .seagreen_stone;
    // if (density < 0.6) return .blue_stone;
    // if (density < 0.7) return .iron;
    // if (density < 0.8) return .silver;
    // if (density < 0.9) return .gold;
    // return .stone;
}

// TODO improve, choose ideal procedural terrain generation algorithm (pretty bad currently)
/// Returns a value between 0-1, used as a terrain starting point for the default depth (D = 3).
/// Acts as the "parent" from which all blocks at higher depths ("more zoomed in") get generated from.
pub fn get_fbm_worley_density(world_seed: Seed, x: u64, y: u64) f64 {
    const fx = @as(f64, @floatFromInt(x));
    const fy = @as(f64, @floatFromInt(y));

    const cell_size = 16.0; // Slightly larger for smoother tunnels
    const h_stretch: f64 = 2.0;
    const fbm_octaves: usize = 4;
    const persistence: f64 = 0.5;
    var amp: f64 = 4.0; // TODO decide if we should even use FBM in the first place

    var warp_x: f64 = 0;
    var warp_y: f64 = 0;
    var freq: f64 = 1.0 / cell_size;

    for (0..fbm_octaves) |_| {
        const h: memory.v2f64 = hash_2d(f64, world_seed, @as(u64, @intFromFloat(fx * freq + 1e5)), @as(u64, @intFromFloat(fy * freq)));
        warp_x += (h[0] - 0.5) * amp;
        warp_y += (h[1] - 0.5) * amp;
        amp *= persistence;
        freq *= 2.0;
    }

    // Apply warp to coordinates
    const wx = fx + warp_x;
    const wy = fy + warp_y;

    const cell_w = cell_size * h_stretch; // Worley time!
    const cell_h = cell_size;

    const cx = @floor(wx / cell_w);
    const cy = @floor(wy / cell_h);

    var d1: f64 = 1e10; // closest
    var d2: f64 = 1e10; // 2nd closest

    var ox: i32 = -1;
    while (ox <= 1) : (ox += 1) {
        var oy: i32 = -1;
        while (oy <= 1) : (oy += 1) {
            const cur_cx_i = @as(i64, @intFromFloat(cx)) + ox;
            const cur_cy_i = @as(i64, @intFromFloat(cy)) + oy;

            const offset: memory.v2f64 = hash_2d(f64, world_seed, @as(u64, @bitCast(cur_cx_i)), @as(u64, @bitCast(cur_cy_i)));

            const px = (@as(f64, @floatFromInt(cur_cx_i)) + offset[0]) * cell_w;
            const py = (@as(f64, @floatFromInt(cur_cy_i)) + offset[1]) * cell_h;

            const dx = wx - px;
            const dy = wy - py;
            const dist = @sqrt(dx * dx + dy * dy); // plan dist formula

            // Worley F2 - F1 thing
            if (dist < d1) {
                d2 = d1;
                d1 = dist;
            } else if (dist < d2) {
                d2 = dist;
            }
        }
    }

    // The d2 - d1 creates the "walls" or "tunnels" between points
    const density = (d2 - d1) / cell_size;

    // TODO try second layer of Simplex/Perlin/Value masking?
    // TODO figure out what I want for structures
    return @min(1.0, density);
}

/// Simply calls `hash_2d`.
fn get_cell_point(seed: Seed, cx: i64, cy: i64) memory.v2f64 {
    return hash_2d(f64, seed, @bitCast(cx), @bitCast(cy));
}

/// Multiplies a float by 2**64, returning an integer x such that a random u64 value has its probability to be less than x equal to the chance variable.
pub inline fn odds_num(chance: comptime_float) u64 {
    return @intFromFloat(chance * POW_2_64);
}

// UNUSED AREA

pub fn get_value_noise_density(base_seed: seeding.Seed, x: u64, y: u64) f64 {
    const scale = 16.0;
    const world_x = @as(f64, @floatFromInt(x)) / scale;
    const world_y = @as(f64, @floatFromInt(y)) / scale;
    const x0 = @floor(world_x);
    const y0 = @floor(world_y);

    const fx = world_x - x0;
    const fy = world_y - y0;

    // Get 4 random values for the corners
    const v00: memory.v2f64 = hash_2d(f64, base_seed, @intFromFloat(x0), @intFromFloat(y0));
    const v10: memory.v2f64 = hash_2d(f64, base_seed, @intFromFloat(x0 + 1), @intFromFloat(y0));
    const v01: memory.v2f64 = hash_2d(f64, base_seed, @intFromFloat(x0), @intFromFloat(y0 + 1));
    const v11: memory.v2f64 = hash_2d(f64, base_seed, @intFromFloat(x0 + 1), @intFromFloat(y0 + 1));

    // Smooth the coordinates
    const u = fade(fx);
    const v = fade(fy);

    // Bilinear interpolation
    return lerp(lerp(v00[0], v10[0], u), lerp(v01[0], v11[0], u), v);
}

/// Linearly interpolates between a and b.
inline fn lerp(a: f64, b: f64, time: f64) f64 {
    return a + time * (b - a);
}

/// Smootherstep formula.
inline fn fade(t: f64) f64 {
    return t * t * t * (t * (t * 6 - 15) + 10);
}

/// Simple noise for testing. Unused.
pub fn get_test_noise(seed: Seed, x: f64, y: f64) f64 {
    _ = .{ x, y };
    var prng = seeding.ChaCha12.init(seed);
    return @as(f64, @floatFromInt(prng.next() & 127)) / 128;
}
