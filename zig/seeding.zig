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

/// Mixes a base seed with some values. Since BLAKE3 is cryptographic this will yield high-quality results.
pub fn mix_base_seed(layer_seed: Seed, number: u64) Seed {
    const PackedInput = extern struct { // temporary struct for faster mixing :)
        seed: Seed,
        number: u64,
    };
    const input = PackedInput{ .seed = layer_seed, .number = number };

    var out_bytes: [64]u8 = undefined;
    std.crypto.hash.Blake3.hash(std.mem.asBytes(&input), &out_bytes, .{});
    return @bitCast(out_bytes);
}

/// Mixes in the layer seed with X/Y values. Used when appending on part of a seed to a quadrant.
pub fn mix_coordinate_seed(layer_seed: Seed, x: u64, y: u64) Seed {
    const PackedInput = extern struct { // temporary struct for faster mixing :)
        seed: Seed,
        x: u64,
        y: u64,
        depth: u64,
    };
    const input = PackedInput{
        .seed = layer_seed,
        .x = x,
        .y = y,
        .depth = memory.game.depth,
    };

    var out_bytes: [64]u8 = undefined;
    std.crypto.hash.Blake3.hash(std.mem.asBytes(&input), &out_bytes, .{});
    return @bitCast(out_bytes);
}

/// Generates 4 sets of seeds for every chunk when combining X/Y active suffix coordinates with the seed of a quadrant.
pub fn mix_chunk_seeds(quadrant_seed: Seed, coord_vector: memory.v2u64) [4]Seed {
    const PackedInput = extern struct { // do the packing thing again
        seed: Seed,
        vector: memory.v2u64,
        depth: u64,
    };
    const input = PackedInput{
        .seed = quadrant_seed,
        .vector = coord_vector,
        .depth = memory.game.depth,
    };

    var out_bytes: [256]u8 = undefined; // TODO figure out if this is a performance bottleneck slowdown
    std.crypto.hash.Blake3.hash(std.mem.asBytes(&input), &out_bytes, .{});
    return @bitCast(out_bytes);
}

/// ChaCha12 based PRNG. Basically cryptographically secure, can generate 64-byte blocks at a time, and supports skipping. All with 512-bit seeding!
pub const ChaCha12 = struct {
    // Internal state stored as vectors for SIMD!
    row0: @Vector(4, u32),
    row1: @Vector(4, u32),
    row2: @Vector(4, u32),
    row3: @Vector(4, u32),

    /// Pre-generated keystream buffer (64 bytes).
    keystream: [8]u64,
    /// Which u64 index in keystream to serve next.
    position: u32,

    const V4 = @Vector(4, u32);

    pub fn init(seed_data: Seed) ChaCha12 {
        const s: [16]u32 = @bitCast(seed_data);

        return ChaCha12{
            .row0 = V4{ s[0], s[1], s[2], s[3] },
            .row1 = V4{ s[4], s[5], s[6], s[7] },
            .row2 = V4{ s[8], s[9], s[10], s[11] },
            .row3 = V4{ s[12], s[13], s[14], s[15] },
            .keystream = undefined,
            .position = 8,
        };
    }

    pub fn next(self: *@This()) u64 {
        if (self.position >= 8) {
            self.generateBlock();
            self.position = 0;
        }

        const val = self.keystream[self.position];
        self.position += 1;
        return val;
    }

    /// Skips forward by `count` u64 values in true O(1) time.
    pub fn skip(self: *@This(), count: u64) void {
        if (count == 0) return;

        // If we are already at the end of a block, trigger the reset logic early
        if (self.position >= 8) {
            self.generateBlock();
            self.position = 0;
        }

        const remaining_u64s_in_block = 8 - self.position;

        // If the skip lands within our currently generated block, just move the pointer
        if (count < remaining_u64s_in_block) {
            self.position += @as(u32, @truncate(count));
            return;
        }

        // Otherwise, figure out how many blocks we need to skip entirely
        const count_after_block = count - remaining_u64s_in_block;
        const blocks_to_skip = (count_after_block / 8) + 1;
        const new_pos = count_after_block % 8;

        // Fast-forward the internal 64-bit counter (row3[0] = low, row3[1] = high)
        const counter_add = blocks_to_skip - 1;
        if (counter_add > 0) {
            const add_low: u32 = @as(u32, @truncate(counter_add));
            const add_high: u32 = @as(u32, @truncate(counter_add >> 32));

            const low_before = self.row3[0];
            self.row3[0] +%= add_low;
            // Catch overflow for the low 32 bits
            if (self.row3[0] < low_before) {
                self.row3[1] +%= 1;
            }
            self.row3[1] +%= add_high;
        }

        // Generate only the exact block we landed on
        self.generateBlock();
        self.position = @as(u32, @truncate(new_pos));
    }

    /// Returns a float value (32/64 bits of information)
    pub fn float(self: *@This(), comptime T: type) T {
        if (T == f64) {
            return @as(f64, @floatFromInt(self.next())) * (1.0 / 18446744073709551616.0);
        } else if (T == f32) {
            return @as(f32, @floatFromInt(self.next())) * (1.0 / 18446744073709551616.0);
        }
        @compileError("Only f32 and f64 floats are supported.");
    }

    fn generateBlock(self: *@This()) void {
        var x0 = self.row0;
        var x1 = self.row1;
        var x2 = self.row2;
        var x3 = self.row3;

        // 6 double-rounds
        inline for (0..6) |_| {
            // Column rounds: QR on (0,4,8,12), (1,5,9,13), (2,6,10,14), (3,7,11,15)
            // With row layout, columns are already aligned.
            quarterRound(&x0, &x1, &x2, &x3);

            // Diagonal rounds: QR on (0,5,10,15), (1,6,11,12), (2,7,8,13), (3,4,9,14)
            // Rotate rows to align diagonals into columns.
            x1 = @shuffle(u32, x1, undefined, [4]i32{ 1, 2, 3, 0 });
            x2 = @shuffle(u32, x2, undefined, [4]i32{ 2, 3, 0, 1 });
            x3 = @shuffle(u32, x3, undefined, [4]i32{ 3, 0, 1, 2 });

            quarterRound(&x0, &x1, &x2, &x3);

            // Rotate back.
            x1 = @shuffle(u32, x1, undefined, [4]i32{ 3, 0, 1, 2 });
            x2 = @shuffle(u32, x2, undefined, [4]i32{ 2, 3, 0, 1 });
            x3 = @shuffle(u32, x3, undefined, [4]i32{ 1, 2, 3, 0 });
        }

        // Add original state
        x0 +%= self.row0;
        x1 +%= self.row1;
        x2 +%= self.row2;
        x3 +%= self.row3;

        // Interleave into u64 pairs and write to keystream.
        // Row layout: x0 = [s0, s1, s2, s3], x1 = [s4, s5, s6, s7], etc.
        // We want keystream as u64s: (s0|s1), (s2|s3), (s4|s5), (s6|s7), ...
        self.keystream[0] = packU64(x0, 0, 1);
        self.keystream[1] = packU64(x0, 2, 3);
        self.keystream[2] = packU64(x1, 0, 1);
        self.keystream[3] = packU64(x1, 2, 3);
        self.keystream[4] = packU64(x2, 0, 1);
        self.keystream[5] = packU64(x2, 2, 3);
        self.keystream[6] = packU64(x3, 0, 1);
        self.keystream[7] = packU64(x3, 2, 3);

        // Increment counter (row3[0] is low word, row3[1] is high word)
        self.row3[0] +%= 1;
        if (self.row3[0] == 0) {
            self.row3[1] +%= 1;
        }
    }

    inline fn packU64(v: V4, lo: comptime_int, hi: comptime_int) u64 {
        return @as(u64, v[lo]) | (@as(u64, v[hi]) << 32);
    }

    inline fn rotl(v: V4, comptime n: u8) V4 {
        const shift_left: @Vector(4, u8) = @splat(n);
        const shift_right: @Vector(4, u8) = @splat(32 - n);
        return (v << shift_left) | (v >> shift_right);
    }

    inline fn quarterRound(a: *V4, b: *V4, c: *V4, d: *V4) void {
        a.* +%= b.*;
        d.* ^= a.*;
        d.* = rotl(d.*, 16);

        c.* +%= d.*;
        b.* ^= c.*;
        b.* = rotl(b.*, 12);

        a.* +%= b.*;
        d.* ^= a.*;
        d.* = rotl(d.*, 8);

        c.* +%= d.*;
        b.* ^= c.*;
        b.* = rotl(b.*, 7);
    }
};

test "basic determinism" {
    var seed = std.mem.zeroes(Seed);
    seed[0] = 42;

    var rng1 = ChaCha12.init(seed);
    var rng2 = ChaCha12.init(seed);

    for (0..100) |_| {
        try std.testing.expectEqual(rng1.next(), rng2.next());
    }
}

test "skip produces same values" {
    var seed = std.mem.zeroes(Seed);
    seed[0] = 123;
    seed[5] = 77;

    var rng_sequential = ChaCha12.init(seed);

    // Consume 50 values
    var values: [50]u64 = undefined;
    for (0..50) |i| {
        values[i] = rng_sequential.next();
    }

    // Skip to position 25 and verify
    var rng_skipped = ChaCha12.init(seed);
    rng_skipped.skip(25);

    for (25..50) |i| {
        try std.testing.expectEqual(values[i], rng_skipped.next());
    }
}

test "skip forward matches sequential" {
    var seed = std.mem.zeroes(Seed);
    seed[3] = 0xAB;

    var rng1 = ChaCha12.init(seed);
    var rng2 = ChaCha12.init(seed);

    // Advance rng1 by 37 calls
    for (0..37) |_| {
        _ = rng1.next();
    }

    // Skip rng2 forward by 37
    rng2.skip(37);

    // They should now agree
    for (0..20) |_| {
        try std.testing.expectEqual(rng1.next(), rng2.next());
    }
}

test "cross-block boundary skip" {
    var seed = std.mem.zeroes(Seed);
    seed[0] = 1;

    var rng = ChaCha12.init(seed);

    // Get value at position 15 (spans two blocks since each block = 8 u64s)
    var reference = ChaCha12.init(seed);
    for (0..15) |_| {
        _ = reference.next();
    }
    const expected = reference.next();

    rng.skip(15);
    try std.testing.expectEqual(expected, rng.next());
}

test "float range" {
    var seed = std.mem.zeroes(Seed);
    seed[0] = 99;

    var rng = ChaCha12.init(seed);

    for (0..1000) |_| {
        const f64_val = rng.float(f64);
        try std.testing.expect(f64_val >= 0.0 and f64_val < 1.0);

        const f32_val = rng.float(f32);
        try std.testing.expect(f32_val >= 0.0 and f32_val < 1.0);
    }
}

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
            return @as(f32, @floatFromInt(self.next())) * (1.0 / 18446744073709551616.0);
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
    const rng_main = Xoshiro512.init(seed);

    // Make value copies of the state
    var branch_a: Xoshiro512 = rng_main;
    var branch_b: Xoshiro512 = rng_main;

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
