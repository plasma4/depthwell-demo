//! Handles procedural generation logic for the game.
const std = @import("std");
const logger = @import("logger.zig");
const memory = @import("memory.zig");
const seeding = @import("seeding.zig");
const world = @import("world.zig");

/// Represents 2^32.
const POW_2_32 = 4294967296;
const POW_2_64 = seeding.POW_2_64;

const hash_2d_512 = seeding.ChaCha12.hash_2d_512;
const FastHash = seeding.FastHash;
const Seed = seeding.Seed;
const Sprite = world.Sprite;
const v2f64 = memory.v2f64;

/// Determines whether to use a heatmap or not.
const USE_HEATMAP = false;

/// Generates a block for seeding (based on previous procedural generation logic).
pub inline fn generate_block_from_values(moisture: f64, density: f64, height: f64) Sprite {
    _ = moisture;
    _ = height;

    if (USE_HEATMAP) return @enumFromInt(256 + @as(u20, @intFromFloat(density * 256.0))); // sprite IDs from 256-512 create a neat little heatmap

    if (density < 0.4) return .none;
    if (density < 0.6) return .green_stone;
    if (density < 0.8) return .seagreen_stone;
    if (density < 0.9) return .blue_stone;
    return .stone;

    // if (density < 0.98) return .iron;
    // if (density < 0.99) return .silver;
    // return .gold;
}

/// Returns a value between 0-1, used as a terrain starting point for the default depth (D = 3).
/// Acts as the "parent" from which all blocks at higher depths ("more zoomed in") get generated from.
/// This function is called 256 times per chunk and is performance-sensitive.
pub fn get_fbm_worley_density(world_seed: Seed, x: u64, y: u64) f32 {
    const fx = @as(f32, @floatFromInt(x));
    const fy = @as(f32, @floatFromInt(y * 2)); // scaled Y

    const cell_size: f32 = 16.0;
    const h_stretch: f32 = 4.0;
    const fbm_octaves: usize = 3;

    var warp_x: f32 = 0;
    var warp_y: f32 = 0;
    var amp: f32 = 20.0;
    var freq: u64 = 1;

    // FBM warping
    inline for (0..fbm_octaves) |_| {
        const noise = get_dual_value_noise(world_seed, x *% freq, y *% freq);
        warp_x += noise[0] * amp;
        warp_y += noise[1] * amp;
        amp *= 0.5;
        freq *%= 2;
    }

    const wx = fx + warp_x;
    const wy = fy + warp_y;
    const cell_w = cell_size * h_stretch;

    const cx_f = @floor(wx / cell_w);
    const cy_f = @floor(wy / cell_size);
    const cx_i = @as(i64, @intFromFloat(cx_f));
    const cy_i = @as(i64, @intFromFloat(cy_f));

    var d1_sq: f32 = 1e10;
    var d2_sq: f32 = 1e10;

    // Worley search
    var ox: i32 = -1;
    while (ox <= 1) : (ox += 1) {
        var oy: i32 = -1;
        while (oy <= 1) : (oy += 1) {
            const cur_x = @as(u64, @bitCast(cx_i + ox));
            const cur_y = @as(u64, @bitCast(cy_i + oy));

            // Hash once for both offsets
            const h = FastHash.hash_2d(world_seed, cur_x, cur_y);
            const off_x = @as(f32, @floatFromInt(h % POW_2_32)) / POW_2_32;
            const off_y = @as(f32, @floatFromInt(h >> 32)) / POW_2_32;

            const px = (@as(f32, @floatFromInt(cx_i + ox)) + off_x) * cell_w;
            const py = (@as(f32, @floatFromInt(cy_i + oy)) + off_y) * cell_size;

            const dx = wx - px;
            const dy = wy - py;
            const dist_sq = dx * dx + dy * dy;

            if (dist_sq < d1_sq) {
                d2_sq = d1_sq;
                d1_sq = dist_sq;
            } else if (dist_sq < d2_sq) {
                d2_sq = dist_sq;
            }
        }
    }

    const normalization = 25.0; // idk anymore
    const density = (@sqrt(d2_sq) - @sqrt(d1_sq)) / normalization;
    return @min(1.0, density);
}

/// Multiplies a float by 2^64, returning an integer `x` such that a random 64-bit integer has its probability to be less than `x` equal `chance`.
pub inline fn odds_num(chance: comptime_float) u64 {
    return @intFromFloat(chance * POW_2_64);
}

/// Returns two independent noise values based on the classic Value Noise algorithm.
pub fn get_dual_value_noise(seed: Seed, x: u64, y: u64) @Vector(2, f32) {
    const scale: f32 = 16.0;
    const fx_raw = @as(f32, @floatFromInt(x)) / scale;
    const fy_raw = @as(f32, @floatFromInt(y)) / scale;

    const x0 = @as(u64, @intFromFloat(@floor(fx_raw)));
    const y0 = @as(u64, @intFromFloat(@floor(fy_raw)));
    const tx = fx_raw - @floor(fx_raw);
    const ty = fy_raw - @floor(fy_raw);

    // Fade curves
    const u = tx * tx * tx * (tx * (tx * 6 - 15) + 10);
    const v = ty * ty * ty * (ty * (ty * 6 - 15) + 10);

    const h00 = FastHash.hash_2d(seed, x0, y0); // ChaCha12 is too slow ):
    const h10 = FastHash.hash_2d(seed, x0 +% 1, y0);
    const h01 = FastHash.hash_2d(seed, x0, y0 +% 1);
    const h11 = FastHash.hash_2d(seed, x0 +% 1, y0 +% 1);

    var res: @Vector(2, f32) = .{ 0, 0 };
    inline for (0..2) |i| {
        const shift = @as(u6, @intCast(i * 32));
        const v00 = @as(f32, @floatFromInt(@as(u32, @truncate(h00 >> shift)))) / POW_2_32;
        const v10 = @as(f32, @floatFromInt(@as(u32, @truncate(h10 >> shift)))) / POW_2_32;
        const v01 = @as(f32, @floatFromInt(@as(u32, @truncate(h01 >> shift)))) / POW_2_32;
        const v11 = @as(f32, @floatFromInt(@as(u32, @truncate(h11 >> shift)))) / POW_2_32;

        const nx0 = v00 + u * (v10 - v00);
        const nx1 = v01 + u * (v11 - v01);
        res[i] = nx0 + v * (nx1 - nx0);
    }
    return res;
}

// pub fn get_value_noise(base_seed: seeding.Seed, x: u64, y: u64) f64 {
//     const scale = 16.0;
//     const world_x = @as(f64, @floatFromInt(x)) / scale;
//     const world_y = @as(f64, @floatFromInt(y)) / scale;
//     const x0 = @floor(world_x);
//     const y0 = @floor(world_y);

//     const fx = world_x - x0;
//     const fy = world_y - y0;

//     // Get 4 random values for the corners
//     const v00: v2f64 = hash_2d_512(f64, base_seed, @intFromFloat(x0), @intFromFloat(y0));
//     const v10: v2f64 = hash_2d_512(f64, base_seed, @intFromFloat(x0 + 1), @intFromFloat(y0));
//     const v01: v2f64 = hash_2d_512(f64, base_seed, @intFromFloat(x0), @intFromFloat(y0 + 1));
//     const v11: v2f64 = hash_2d_512(f64, base_seed, @intFromFloat(x0 + 1), @intFromFloat(y0 + 1));

//     // Smooth the coordinates
//     const u = fade(fx);
//     const v = fade(fy);

//     // Bilinear interpolation
//     return lerp(lerp(v00[0], v10[0], u), lerp(v01[0], v11[0], u), v);
// }

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
