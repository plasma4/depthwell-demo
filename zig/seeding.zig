//! Manages seeding calculations for the game.
// seeding yippeeeeee
const std = @import("std");
const memory = @import("memory.zig");
const testing = std.testing;

test "basic usage example" {
    const logger = @import("logger.zig");

    // Start with an arbitrary seed (NOTE: seed_from_bytes fails for WASM builds)
    var world_seed: Seed = undefined;
    seed_from_bytes("my-game-seed", &world_seed);

    var rng: Xoshiro512 = .{ .state = world_seed };
    // change to quickWarn to see result from ZLS
    logger.quick(rng.float(f32));
    logger.quick(rng.next());
}

/// A 512-bit seed state (also used for hashing).
pub const Seed = [8]u64;

// /// A fast 64-bit to 64-bit generator for avalanching the X/Y offsets.
// inline fn split_mix_64(state: *u64) u64 {
//     state.* +%= 0x9E3779B97F4A7C15;
//     var z = state.*;
//     z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
//     z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
//     return z ^ (z >> 31);
// }

/// BLAKE3 mix, also mixing in the layer seed. Used when appending on part of a seed to a quadrant.
pub fn mix_coordinate_seed(layer_seed: Seed, x: u64, y: u64) Seed {
    const PackedInput = extern struct { // temporary struct for faster mixing :)
        seed: Seed,
        x: u64,
        y: u64,
    };
    const input = PackedInput{ .seed = layer_seed, .x = x, .y = y };

    var out_bytes: [64]u8 = undefined;
    std.crypto.hash.Blake3.hash(std.mem.asBytes(&input), &out_bytes, .{});
    return @bitCast(out_bytes);
}

/// Bijective mixer for generating an individual seed for every chunk when combining X/Y active suffix coordinates with the seed of a quadrant.
pub fn mix_chunk_seed(quadrant_seed: Seed, coord_vector: memory.v2u64) Seed {
    const PackedInput = extern struct { // do the packing thing again
        seed: Seed,
        vector: memory.v2u64,
    };
    const input = PackedInput{ .seed = quadrant_seed, .vector = coord_vector };

    var out_bytes: [64]u8 = undefined;
    std.crypto.hash.Blake3.hash(std.mem.asBytes(&input), &out_bytes, .{});
    return @bitCast(out_bytes);
}

pub const ChaCha20 = std.crypto.aead.chacha_poly.ChaCha20Poly1305; // TODO actually use this in procedural generation as a CSPRNG

/// Xoshiro512** (StarStar), public domain randomness function.
/// A high-performance, all-purpose generator with a period of 2^512 - 1.
pub const Xoshiro512 = struct {
    state: Seed,

    /// Creates a new instance with seed data.
    pub fn init(seed_data: Seed) Xoshiro512 {
        var state = seed_data;
        var check: u64 = 0;
        for (state) |s| check |= s;
        if (check == 0) {
            @branchHint(.unlikely);
            state[0] = 0xbf58476d1ce4e5b9; // fill with some random constant (technically not needed with seeding.ts logic being sound)
        }
        return .{ .state = state };
    }

    /// Returns the next 64 bits of psuedo-random data.
    pub fn next(self: *@This()) u64 {
        const result = std.math.rotl(u64, self.state[1] *% 5, 7) *% 9; // the ** part of things

        // Xoshiro512 state transition
        const t = self.state[1] << 11;
        self.state[2] ^= self.state[0];
        self.state[5] ^= self.state[1];
        self.state[1] ^= self.state[2];
        self.state[7] ^= self.state[3];
        self.state[3] ^= self.state[4];
        self.state[4] ^= self.state[5];
        self.state[0] ^= self.state[6];
        self.state[6] ^= self.state[7];
        self.state[6] ^= t;
        self.state[7] = std.math.rotl(u64, self.state[7], 21);
        return result;
    }

    /// Returns a float value (32/64 bits of information)
    pub fn float(self: *@This(), comptime T: type) T {
        if (T == f64) {
            return @as(f64, @floatFromInt(self.next())) * (1.0 / 18446744073709551616.0);
        } else if (T == f32) {
            return @as(f32, @floatFromInt(self.next())) * (1.0 / 4294967296.0);
        }
        @compileError("Only f32 and f64 floats are supported.");
    }
};

/// Stafford Mix 13 for 64-bit entropy avalanching.
pub inline fn stafford_mix_13(z_in: u64) u64 {
    var z = (z_in ^ (z_in >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// BROKEN WHEN EXPORTING, DO NOT USE. JS LOGIC EXISTS ALREADY. Converts a base-26 [a-z]-only string to 64 bytes. Input should  too no larger than 100 characters.
pub fn seed_from_base26(noalias input: []const u8, noalias out_seed: *Seed) void {
    // Initialize out_seed to 0
    @memset(out_seed, 0);

    for (input) |char| {
        const char_val = @as(u64, char - 'a') + 1;

        var carry: u64 = char_val;
        // Manual 512-bit multiplication (total = total * 26 + char_val)
        // We iterate through our 8 limbs
        for (out_seed) |*limb| {
            // u128 is perfect for intermediate math to catch u64 overflow
            const prod = (@as(u128, limb.*) * 26) + carry;
            limb.* = @intCast(prod & 0xFFFFFFFFFFFFFFFF);
            carry = @intCast(prod >> 64);
        }
    }

    var borrow: u64 = 1;
    for (out_seed) |*limb| {
        if (limb.* >= borrow) {
            limb.* -= borrow;
            borrow = 0;
            break;
        } else {
            limb.* = std.math.maxInt(u64); // Underflow/wrap
            borrow = 1;
        }
    }
}

/// Bridge to WASM, creates seed data from a string using bijective mapping
pub fn wasm_seed_from_string(str_ptr: [*]const u8, str_len: u64, output_ptr: *Seed) void {
    const temp: usize = @intCast(str_len);
    const input = str_ptr[0..temp];
    seed_from_base26(input, output_ptr);
}

test "bijective seeding uniqueness" {
    var s1: Seed = undefined;
    var s2: Seed = undefined;
    var s3: Seed = undefined;
    seed_from_base26("a", &s1);
    seed_from_base26("b", &s2);
    seed_from_base26("c", &s3);
    try testing.expect(!std.mem.eql(u64, &s1, &s2));
    try testing.expect(!std.mem.eql(u64, &s2, &s3));
}

test "Xoshiro512** initialization/consistency" {
    var seed: Seed = undefined;
    seed_from_bytes("test_seed", &seed);
    var rng1 = Xoshiro512.init(seed);
    var rng2 = Xoshiro512.init(seed);

    // Both generators should produce identical output
    try testing.expectEqual(rng1.next(), rng2.next());
    try testing.expectEqual(rng1.next(), rng2.next());
    try testing.expectEqual(rng1.float(f32), rng2.float(f32));
}

test "branching check" {
    var seed: Seed = undefined;
    seed_from_bytes("test", &seed);
    var rng_main = Xoshiro512.init(seed);

    // Make value copies of the state
    var branch_a = rng_main.checkpoint();
    var branch_b = rng_main.checkpoint();

    const val_a = branch_a.next();
    const val_b = branch_b.next();

    try testing.expectEqual(val_a, val_b); // MUST pass

    _ = branch_a.next(); // branch_a advances
    // branch_b is still at the previous state

    try testing.expect(branch_a.next() != branch_b.next());
}

/// Hashes an arbitrary string into a 512-bit seed directly into the destination (using Sha512).
/// Used for testing only; actual seeding uses a string with only [a-z] characters and using Sha512 would be too slow for practical use.
fn seed_from_bytes(noalias input: []const u8, noalias out_seed: *Seed) void {
    var hash_out: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(input, &hash_out, .{});

    // Write directly into the pointer provided
    inline for (0..8) |i| {
        const start = i * 8;
        out_seed[i] = std.mem.readInt(u64, hash_out[start .. start + 8], .little);
    }
}

/// Hashes 2D integer coordinates to a float in [0, 1). TODO find better candidate and use
pub fn hash_2d(seed: u64, x: i32, y: i32) f32 {
    var h: u64 = seed;
    h ^= @as(u64, @bitCast(@as(i64, x))) *% 0x517cc1b727220a95;
    h ^= @as(u64, @bitCast(@as(i64, y))) *% 0x6c62272e07bb0142;
    h = stafford_mix_13(h);
    return @as(f32, @floatFromInt(h >> 40)) / 16777216.0;
}

/// 2D value noise with smoothstep interpolation. Returns [0, 1).
/// `scale` = feature size in blocks. 4–8 recommended for 16-block chunks.
/// Continuous across chunk boundaries (operates in world-space).
pub fn value_noise_2d(seed: u64, x: i32, y: i32, scale: i32) f32 {
    const s = @max(scale, 2);
    const gx = @divFloor(x, s);
    const gy = @divFloor(y, s);
    const fx: f32 = @as(f32, @floatFromInt(@mod(x, s))) / @as(f32, @floatFromInt(s));
    const fy: f32 = @as(f32, @floatFromInt(@mod(y, s))) / @as(f32, @floatFromInt(s));

    const v00 = hash_2d(seed, gx, gy);
    const v10 = hash_2d(seed, gx + 1, gy);
    const v01 = hash_2d(seed, gx, gy + 1);
    const v11 = hash_2d(seed, gx + 1, gy + 1);

    // Smoothstep (C1 continuous, no visible grid artifacts)
    const sx = fx * fx * (3.0 - 2.0 * fx);
    const sy = fy * fy * (3.0 - 2.0 * fy);

    const top = v00 + (v10 - v00) * sx;
    const bot = v01 + (v11 - v01) * sx;
    return top + (bot - top) * sy;
}

/// Fractal Brownian Motion: layers multiple octaves of value noise.
/// 2 octaves = fast and decent. 3 = nicer caves. 4+ = diminishing returns.
/// Returns [0, ~1) (not exactly normalized but close enough).
pub fn fbm_2d(seed: u64, x: i32, y: i32, octaves: u32) f32 {
    var value: f32 = 0;
    var amp: f32 = 0.5;
    var s: u64 = seed;
    var scale: i32 = 8;
    for (0..octaves) |_| {
        value += value_noise_2d(s, x, y, @max(scale, 2)) * amp;
        amp *= 0.5;
        scale = @max(@divFloor(scale, 2), 2);
        s +%= 0x9E3779B97F4A7C15;
    }
    return value;
}

test "noise basic sanity" {
    // Same input gives same output (crazy testing)
    const a = value_noise_2d(42, 10, 20, 6);
    const b = value_noise_2d(42, 10, 20, 6);
    try testing.expectEqual(a, b);

    const c = value_noise_2d(42, 11, 20, 6);
    try testing.expect(a != c);

    // I would hope it doesn't equal exactly 0.0
    try testing.expect(a > 0.0 and a < 1.0);

    const f = fbm_2d(42, 10, 20, 3);
    try testing.expect(f > 0.0 and f < 1.0);
}
