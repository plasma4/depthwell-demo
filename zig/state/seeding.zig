//! Manages seeding calculations for the game.
// seeding yippeeeeee
const std = @import("std");
const dw = @import("../root.zig");
const logger = dw.logger;
const memory = dw.memory;
const testing = std.testing;

/// Represents 2^32.
pub const POW_2_32 = 4294967296;
/// Represents 1/2^32.
pub const INV_POW_2_32 = 1.0 / 4294967296.0;
/// Represents 2^64.
pub const POW_2_64 = 18446744073709551616;
/// Represents 1/2^64.
pub const INV_POW_2_64 = 1.0 / 18446744073709551616.0;

const Vec2u = dw.utils.Vec2u;

/// A world block coordinate on ONE axis, wide enough for the whole world at any depth.
/// (1 bit for quadrant side, 64 bits for suffix, 4 bits for block axis in a chunk!)
pub const WorldCoord = u128;

/// Significant bits a `WorldCoord` actually carries: a 64-bit chunk index plus the quadrant's bit,
/// times `CHUNK_SIZE` blocks per chunk. `latticeAxis()` splits the coordinate on this bound,
/// so anything wider would silently overflow one half of that split.
pub const WORLD_COORD_BITS: comptime_int = 64 + 1 + @as(comptime_int, std.math.log2_int(u32, dw.CHUNK_SIZE));

/// Folds a `WorldCoord` into the 64 bits a hash or a noise lattice consumes.
///
/// A fold, NOT a truncation. Truncating repeats the field exactly every 2^64 units,
/// which is the structural cycling this type exists to remove;
/// folding instead sends each band of high bits to an unrelated part of the hash space.
/// Nothing is discontinuous either way: a lattice needs its cell indices to be
/// consistent between neighbors, not contiguous, so callers must fold each corner index
/// separately (`+% 1` BEFORE the fold, never after).
pub inline fn foldWorld(v: WorldCoord) u64 {
    const lo: u64 = @truncate(v);
    const hi: u64 = @truncate(v >> 64);
    // Identity while the high half is empty, which is every coordinate below 2^64.
    return lo ^ (hi *% FOLD_MULTIPLIER);
}

/// Odd constant the fold sends the high bits through. `latticeAxis()` depends on this being a plain
/// multiplication: it advances a fold by one cell with `+% FOLD_MULTIPLIER` rather than remultiplying.
pub const FOLD_MULTIPLIER: u64 = 0x9E3779B97F4A7C15;

/// A 512-bit seed state (useful for hashing and procedural generation).
pub const Seed = extern struct { value: [8]u64 align(16) = @splat(0) };
/// Contains 4 512-bit seed states, which are different for each chunk.
///
/// - `value[0]` is meant for any large-scale data.
///   - Note that for base chunks, `hash2d()` from `hash_seeds` is used instead.
/// - `value[1]` is meant for ancestor logic.
/// - `value[2]` is meant for base chunk decorations.
/// - `value[3]` is meant for unimportant seeding data (such as entity effects or `seed` property of `Block`, which is only useful for WGSL).
///
/// By creating 4 separate `Seed` values, we ensure strong "security" and randomness of chunks and prevent correlation "attacks".
pub const ChunkSeeds = extern struct { value: [4]Seed };

test "basic usage example" {
    // Start with an arbitrary seed (NOTE: seed_from_bytes fails for WASM builds)
    var world_seed: Seed = undefined;
    seedFromBytes("my-game-seed", &world_seed);

    var rng: Xoshiro512 = .init(&world_seed);
    // change to quickWarn to see result from ZLS (maybe?)
    std.log.debug("{d}", .{rng.float(f32)});
    std.log.debug("{d}", .{rng.next()});
}

// /// A fast 64-bit to 64-bit generator for avalanching the X/Y offsets.
// inline fn splitMix64(state: *u64) u64 {
//     state.* +%= 0x9E3779B97F4A7C15;
//     var z = state.*;
//     z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
//     z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
//     return z ^ (z >> 31);
// }

pub const SeedStream = enum(u64) {
    hash_seeds_init = 1,
    sound,
    particles,
    startup_layers,
    /// Starting phase of the background animation clock, so two worlds never open on the same frame.
    background,
    /// Layout of the debris a portal descent swallows; replayed identically when a save resumes one.
    portal_debris,
    /// Per-render-frame screen tremor. Cosmetic only, and never saved.
    screen_shake,
    _, // @enumFromInt is frequently used to "bypass" this enum
};

/// Mixes a base seed with another value.
/// Since BLAKE3 is cryptographic, this will yield high-quality mixing.
///
/// For better performance, consider using a custom nonce with `ChaCha12` instead.
pub inline fn mixBaseSeed(layer_seed: Seed, number: SeedStream) Seed {
    // Using packed here is disallowed (due to including an array).
    // This struct be extern or else asBytes will recieve garbage data.
    const PackedInput = extern struct { // temporary struct for faster mixing :)
        seed: [8]u64,
        number: u64,
    };
    const input: PackedInput = .{
        .seed = layer_seed.value,
        .number = @intFromEnum(number),
    };

    var out_seed: Seed = undefined;
    std.crypto.hash.Blake3.hash(std.mem.asBytes(&input), std.mem.asBytes(&out_seed), .{});
    return out_seed;
}

/// Mixes in the layer seed with X/Y values and depth using BLAKE3.
/// Used when appending on part of a seed to a quadrant.
pub inline fn mixCoordinateSeed(layer_seed: Seed, x: u64, y: u64, depth: u64) Seed {
    const PackedInput = extern struct { // temporary struct for faster mixing :)
        seed: [8]u64,
        x: u64,
        y: u64,
        depth: u64,
    };
    const input: PackedInput = .{
        .seed = layer_seed.value,
        .x = x,
        .y = y,
        .depth = depth,
    };

    var out_seed: Seed = undefined;
    std.crypto.hash.Blake3.hash(std.mem.asBytes(&input), std.mem.asBytes(&out_seed), .{});
    return out_seed;
}

/// Generates 4 sets of seeds for every chunk when combining X/Y active suffix coordinates with the seed of a quadrant.
pub inline fn mixChunkSeeds(quadrant_seed: Seed, coord_vector: Vec2u, depth: u64) ChunkSeeds {
    const PackedInput = extern struct { // do the packing thing again
        seed: [8]u64,
        c1: u64,
        c2: u64,
        depth: u64,
    };

    const input: PackedInput = .{
        .seed = quadrant_seed.value,
        .c1 = coord_vector[0],
        .c2 = coord_vector[1],
        .depth = depth,
    };

    var out_seeds: ChunkSeeds = undefined;
    std.crypto.hash.Blake3.hash(std.mem.asBytes(&input), std.mem.asBytes(&out_seeds), .{});
    return out_seeds;
}

/// Multiplies a comptime float by 2^64, returning an integer `x` such that a random 64-bit integer has its probability to be less than `x` equal `chance`.
/// Returns the 2^64-1 if the chance is set to 1.0. Convert to a boolean outcome with `random_u64 <= oddsNum(probability)`.
///
/// Consider a randomly-generated 64-bit integer.
/// If `oddsNum(0.2)` is called, then there is a 20% chance that the uniformly random integer is no larger than the value generated by this function.
/// For the case of 0.2, the number returned is 3689348814741910323. The chance is evaluated at 128-bit precision at compile-time.
pub inline fn oddsNum(chance: comptime_float) u64 {
    if (chance > 1.0 or chance < 0.0) @compileError("Chance must be between 0.0 and 1.0 (inclusive)!");
    if (chance == 1.0) return std.math.maxInt(u64);
    return @intFromFloat(chance * POW_2_64 + 0.5);
}

/// Simple compile-time getter for hashing data, incrementing `y` over time.
pub const HashState = struct {
    /// `getChance()` max margin of error is `2^-GET_CHANCE_MARGIN_BITS`.
    /// Raising this tightens the approximation but consumes more entropy per call.
    /// Values up to 64 are supported, since the search below needs `k` up to
    /// `GET_CHANCE_MARGIN_BITS - 1` and `get()` can serve at most 63 bits at once.
    const GET_CHANCE_MARGIN_BITS = 32;
    /// `getChance()` function max margin of error.
    const GET_CHANCE_MARGIN = 1.0 / @as(comptime_float, 1 << GET_CHANCE_MARGIN_BITS);
    /// Largest denominator exponent `getChance()` must search:
    /// rounding to a denominator of `2^k` errs by at most `2^-(k+1)`,
    /// so `k = GET_CHANCE_MARGIN_BITS - 1` always lands within the margin.
    const GET_CHANCE_MAX_K = GET_CHANCE_MARGIN_BITS - 1;

    comptime {
        std.debug.assert(GET_CHANCE_MARGIN_BITS >= 1 and GET_CHANCE_MARGIN_BITS <= 64);
    }

    value: u64 = 0,
    seed_vector: Vec2u,
    x: u64,
    y: u64,
    bits_left: u8 = 0,

    /// Returns an integer of type `T` in the range `[0, limit)` for non-power-of-two limits.
    /// Increments the hash state; consumes less bits than `getLimit()` but requires comptime-known limits.
    pub inline fn get(self: *HashState, T: type, modulo: comptime_int) T {
        comptime {
            if (modulo <= 0 or !std.math.isPowerOfTwo(modulo)) {
                @compileError("Modulo must be a positive power of two for the mask bitwise logic to be correct. Use getLimit() for non-powers-of-two.");
            }
            // modulo is a power of 2, log2() comptime_int result is always exact
            if (std.math.log2(modulo) > @bitSizeOf(T)) {
                @compileError("The modulo must fit within the type itself.");
            }
            if (modulo > (1 << 63)) {
                @compileError("HashState.get() supports up to 63 bits (modulo <= 1 << 63); use getRaw() for 64-bit extractions.");
            }
        }
        const bits_needed: u8 = std.math.log2(modulo);

        if (self.bits_left < bits_needed) {
            // Only this block is generated when bits are depleted.
            const next_y = self.y + 1;
            const next_value = FastHash.hash2d(self.seed_vector, self.x, next_y);
            self.value = next_value >> bits_needed;
            self.y = next_y;
            self.bits_left = 64 - bits_needed;
            return @intCast(next_value & (modulo - 1));
        } else {
            // Happy path: only shift and bitwise mask are generated.
            const result: T = @intCast(self.value & (modulo - 1));
            self.value >>= bits_needed;
            self.bits_left -= bits_needed;
            return result;
        }
    }

    /// Directly extracts a full 64-bit unsigned integer.
    /// If a completely unused 64-bit word is available in the pool, it consumes and returns it.
    /// Otherwise, it increments `y` to pull a new 64-bit word,
    /// leaving the existing partial entropy pool untouched for future `get()`s.
    pub inline fn getRaw(self: *HashState) u64 {
        if (self.bits_left == 64) {
            self.bits_left = 0;
            return self.value;
        } else {
            const next_y = self.y + 1;
            const next_value = FastHash.hash2d(self.seed_vector, self.x, next_y);
            self.y = next_y;
            return next_value;
        }
    }

    /// Determines a boolean outcome for a given probability chance.
    /// The chance is rounded at compile-time to the nearest fraction `n / 2^k` within `GET_CHANCE_MARGIN`,
    /// using the smallest such `k` so only `k` bits of entropy are consumed via `get()`
    /// (1 bit for 0.5, 2 bits for 0.25, and so on) rather than a full 64-bit word.
    pub inline fn getChance(self: *HashState, comptime chance: comptime_float) bool {
        const opt = comptime find_opt: {
            if (chance < 0.0 or chance > 1.0) {
                @compileError("Chance must be in the range [0.0, 1.0]");
            }

            // Search for the smallest power-of-two denominator that represents the chance within the margin of error.
            // A match is guaranteed by GET_CHANCE_MAX_K, since rounding errs by at most 2^-(k+1).
            var k: u8 = 1;
            while (k <= GET_CHANCE_MAX_K) : (k += 1) {
                // comptime_float -> f128 precision
                const d: comptime_float = @floatFromInt(@as(u64, 1) << k);
                const n_float = @round(chance * d);
                const n: u64 = @intFromFloat(n_float);
                const approx = n_float / d;
                const diff = if (approx > chance) approx - chance else chance - approx;
                if (diff <= GET_CHANCE_MARGIN) {
                    break :find_opt .{ .k = k, .n = n };
                }
            }
            @compileError("getChance() found no match, contradicting the GET_CHANCE_MAX_K bound");
        };

        return self.get(u64, 1 << opt.k) < opt.n;
    }

    /// Performs a 64x64-bit widening multiplication returning a 128-bit product split into low and high halves.
    /// This executes using only native 64-bit instructions, completely avoiding slow `__multi3` (128-bit multiplication).
    inline fn mul64x64To128(a: u64, b: u64) struct { lo: u64, hi: u64 } {
        const mask = 0xffffffff;
        const a0 = a & mask;
        const a1 = a >> 32;
        const b0 = b & mask;
        const b1 = b >> 32;

        const a0b0 = a0 * b0;
        const a0b1 = a0 * b1;
        const a1b0 = a1 * b0;
        const a1b1 = a1 * b1;

        const mid = a0b1 +% a1b0;
        const carry1 = @as(u64, @intFromBool(mid < a0b1));
        const lo = a0b0 +% ((mid & mask) << 32);
        const carry0 = @as(u64, @intFromBool(lo < a0b0));
        const hi = (mid >> 32) +% a1b1 +% (carry1 << 32) +% carry0;

        return .{ .lo = lo, .hi = hi };
    }

    /// Returns an integer of type `T` in the range `[0, limit)` for non-power-of-two limits.
    /// Uses a division-free multiplicative method with guaranteed termination (with marginal statistical error).
    ///
    /// Precondition: `T` is a 64-bit integer or smaller, and `limit` is positive.
    pub inline fn getLimit(self: *HashState, T: type, limit: T) T {
        if (limit <= 1) return 0;

        const limit_u64 = @as(u64, @intCast(limit));
        const v = self.getRaw();

        if (@bitSizeOf(T) <= 32 or limit_u64 <= 0xFFFFFFFF) {
            // 64-bit multiply gives the high 32 bits directly!
            return @intCast((@as(u64, @intCast(v >> 32)) * limit_u64) >> 32);
        } else {
            // Only the .hi half of the 128-bit product is needed AND we're going for WASM.
            return if (dw.is_wasm) @intCast(mul64x64To128(v, limit_u64).hi) else @intCast((@as(u128, v) * limit) >> 64);
        }
    }

    /// Returns an integer of type `T` in the range `[min, max)` (exclusive of max).
    /// The `bits` property specifies how many bits of entropy to consume from the state.
    /// Uses fixed-point multiplication reduction (nearly unbiased).
    ///
    /// Precondition: `T` is a 64-bit integer or smaller, and `max` > `min`.
    pub inline fn getRange(self: *HashState, T: type, min: T, max: T) T {
        return min + self.getLimit(T, max - min);
    }
};

/// Folds a small, low-entropy value (a depth, a field id) into a seed lane.
/// Useful for avalanching seeds (non-cryptographic); intentionally separate constants.
pub const NoiseMix = struct {
    // it's as simple as `openssl rand -hex 8` (+@popCount() check using another language but whatever)
    // a specific shell function is left as an exercise to the reader
    const A: u64 = 0x465b4e4aec1a19a5;
    const B: u64 = 0xffd51ce1147d52a3;
    const C: u64 = 0xbe6a3ddc83e2904b;
    const D: u64 = 0xecf5e85671b64339;

    comptime {
        for ([_]u64{ A, B, C, D }) |k| {
            if (@popCount(k) < 28 or @popCount(k) > 36) @compileError("NoiseMix constants must have a @popcount() betwen 28-36 inclusive.");
            if (k % 2 == 0) @compileError("NoiseMix constants must be odd to stay bijective under multiplication.");
        }
    }

    /// One lane of a noise seed: `base` avalanched together with `value`.
    pub inline fn lane(base: u64, value: u64) u64 {
        var x = base +% (value *% A);
        x ^= x >> 32;
        x *%= B;
        x ^= x >> 29;
        x *%= C;
        x ^= x >> 32;
        x *%= D;
        x ^= x >> 31;
        return x;
    }
};

/// A high-performance, stateless hash. Not cryptographically secure; has acceptable flaws.
///
/// Significantly faster than both ChaCha12/Xoshiro512** for procedural generation.
/// Fully deterministic and highly optimized across both WASM and 64-bit Native targets.
pub const FastHash = struct {
    // Look inside
    // >It's not really secret.
    // const secret: [4]u64 = {
    //     0xa0761d6478bd642f,
    //     0xe7037ed1a0b428db,
    //     0x8ebc6af09c88c6e3,
    //     0x589965cc75374cc3,
    // };

    /// A pure 64-bit platform-independent mixer.
    /// Combines inputs additively to avoid a zero-sink.
    inline fn mix(a: u64, b: u64) u64 {
        var x = a +% b;
        x ^= x >> 30;
        x *%= 0xbf58476d1ce4e5b9;
        x ^= x >> 27;
        x *%= 0x94d049bb133111eb;
        x ^= x >> 31;
        return x;
    }

    /// `hash2d()` for a full-width world coordinate; see `WorldCoord` and `foldWorld()`.
    pub inline fn hash2dWorld(seed_vector: Vec2u, x: WorldCoord, y: WorldCoord) u64 {
        return hash2d(seed_vector, foldWorld(x), foldWorld(y));
    }

    /// Returns a 64-bit hash value, assuming `seed_vector` is securely generated from BLAKE3 already.
    pub inline fn hash2d(seed_vector: Vec2u, x: u64, y: u64) u64 {
        var h1 = x ^ seed_vector[0];
        var h2 = y ^ seed_vector[1];

        // Mix both lanes with prime constants
        h1 = h1 *% 0xa0761d6478bd642f;
        h2 = h2 *% 0xe7037ed1a0b428db;

        // Cross-lane diffusion
        var combined = (h1 ^ h2) +% (h1 >> 32) +% (h2 >> 32);

        // SplitMix64 finalizer step
        combined ^= combined >> 30;
        combined *%= 0xbf58476d1ce4e5b9;
        combined ^= combined >> 27;
        combined *%= 0x94d049bb133111eb;
        combined ^= combined >> 31;

        return combined;
    }

    /// Returns a 64-bit float value from [0, 1], assuming `seed_vector` is securely generated from BLAKE3 already.
    pub inline fn float2d(seed_vector: Vec2u, x: u64, y: u64) f64 {
        @setFloatMode(.strict); // just in case ig

        const h = hash2d(seed_vector, x, y);
        return @as(f64, @floatFromInt(h)) / POW_2_64;
    }

    /// Returns a 32-bit float value from [0, 1], assuming `seed_vector` is securely generated from BLAKE3 already.
    pub inline fn float2d_32(seed_vector: Vec2u, x: u64, y: u64) f32 {
        @setFloatMode(.strict); // just in case ig

        const h = hash2d(seed_vector, x, y);
        return @as(f32, @floatFromInt(h)) / POW_2_64;
    }

    const Vec4u = @Vector(4, u64);

    /// Exact vectorized 4-lane version of `hash2d()`, hashing 4 coordinates in parallel (using SIMD).
    /// Each lane `i` equals `hash2d(seed_vector, vx[i], vy[i])`.
    pub inline fn hash2d_4x(seed_vector: Vec2u, vx: Vec4u, vy: Vec4u) Vec4u {
        const h1 = (vx ^ @as(Vec4u, @splat(seed_vector[0]))) *% @as(Vec4u, @splat(0xa0761d6478bd642f));
        const h2 = (vy ^ @as(Vec4u, @splat(seed_vector[1]))) *% @as(Vec4u, @splat(0xe7037ed1a0b428db));

        var combined = (h1 ^ h2) +% (h1 >> @as(Vec4u, @splat(32))) +% (h2 >> @as(Vec4u, @splat(32)));

        combined ^= combined >> @as(Vec4u, @splat(30));
        combined *%= @as(Vec4u, @splat(0xbf58476d1ce4e5b9));
        combined ^= combined >> @as(Vec4u, @splat(27));
        combined *%= @as(Vec4u, @splat(0x94d049bb133111eb));
        combined ^= combined >> @as(Vec4u, @splat(31));

        return combined;
    }
};

test "hash2d_4x matches hash2d" {
    var seed: Seed = undefined;
    seedFromBytes("hash2d-lane-equality", &seed);
    const seed_vector: Vec2u = .{ seed.value[0], seed.value[1] };

    const vx: FastHash.Vec4u = .{ 0, 1, 12345, std.math.maxInt(u64) };
    const vy: FastHash.Vec4u = .{ 0, 987654321, 1, std.math.maxInt(u64) - 7 };
    const h = FastHash.hash2d_4x(seed_vector, vx, vy);

    inline for (0..4) |i| {
        try testing.expectEqual(FastHash.hash2d(seed_vector, vx[i], vy[i]), h[i]);
    }

    // Regression check for the old symmetric mixer: swapping X and Y must not collide.
    const swapped = FastHash.hash2d_4x(seed_vector, vy, vx);
    try testing.expect(!@reduce(.And, h == swapped));
}

/// ChaCha12-based PRNG hard-coded to accept 512 bits of seeding and without certain features. Basically cryptographically secure, can generate 64-byte blocks at a time, and supports skipping.
pub const ChaCha12 = struct {
    /// Internal state.
    state: [16]u32 align(16),

    /// Pre-generated keystream buffer (64 bytes).
    keystream: [8]u64 align(16) = @splat(0),
    /// Which `u64` index in keystream to serve next.
    position: u32,

    const v4u32 = @Vector(4, u32);

    /// Creates a new instance of ChaCha12, without a nonce (utilizing all 512 seed bits).
    pub fn init(seed_data: *const Seed) ChaCha12 {
        var val: [16]u32 align(16) = undefined;
        inline for (0..8) |i| {
            const val_u64 = seed_data.value[i];
            val[i * 2] = @as(u32, @truncate(val_u64));
            val[i * 2 + 1] = @as(u32, @truncate(val_u64 >> 32));
        }
        if (val[0] == 0) {
            @branchHint(.unlikely);
            var check: u32 = 0;
            for (val[1..16]) |s| check |= s;
            if (check == 0) {
                @branchHint(.unlikely);
                val[0] = 0xbf58476d; // fill with deterministic 32-bit constant
            }
        }

        return .{
            .state = val,
            .position = 8,
        };
    }

    /// Creates a new instance of `ChaCha12`, with a custom nonce (utilizing the first 384 seed bits).
    pub fn initWithNonce(seed_data: *const Seed, nonce: [2]u32) ChaCha12 {
        var val: [16]u32 align(16) = undefined;
        // Copy the first 6 u64s (384 bits) into 12 u32s
        inline for (0..6) |i| {
            const val_u64 = seed_data.value[i];
            val[i * 2] = @as(u32, @truncate(val_u64));
            val[i * 2 + 1] = @as(u32, @truncate(val_u64 >> 32));
        }
        val[12] = 0; // Counter always starts at 0 for a new layer
        val[13] = 0;
        val[14] = nonce[0];
        val[15] = nonce[1];

        return ChaCha12{
            .state = val,
            .position = 8,
        };
    }

    /// Returns the next 64 bits of psuedo-random data.
    pub fn next(self: *@This()) u64 {
        if (self.position == 8) {
            self.generateBlock();
            self.position = 0;
        }

        const val = self.keystream[self.position];
        self.position += 1;
        return val;
    }

    /// Skips forward by `count` u64 values. A simple O(1) operation.
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

        // Fast-forward the internal 64-bit counter (located in state[12..13])
        const counter_add = blocks_to_skip - 1;
        if (counter_add > 0) {
            const add_low: u32 = @as(u32, @truncate(counter_add));
            const add_high: u32 = @as(u32, @truncate(counter_add >> 32));

            const low_before = self.state[12];
            self.state[12] +%= add_low;

            // Handle 32-bit overflow carry to the high counter word
            if (self.state[12] < low_before) {
                self.state[13] +%= 1;
            }
            self.state[13] +%= add_high;
        }

        // Generate only the exact block we landed on
        self.generateBlock();
        self.position = @as(u32, @truncate(new_pos));
    }

    /// Returns a float value from [0, 1], using 64 bits of seeding data.
    pub fn float(self: *@This(), comptime T: type) T {
        if (T == f64 or T == f32 or T == f16) {
            return @as(T, @floatFromInt(self.next())) / POW_2_64;
        }
        @compileError("Only floats up to 64-bit precision are supported.");
    }

    /// Treats X and Y as the `ChaCha12` nonce/counter to return a random value.
    /// Expensive stateless 2D hash (using the first 384 seed bits), returning 128 bits of data.
    pub fn hash2d128(comptime T: type, seed_data: *const Seed, x: u64, y: u64) @Vector(2, T) {
        var s: [16]u32 align(16) = undefined;
        inline for (0..8) |i| {
            const val_u64 = seed_data.value[i];
            s[i * 2] = @as(u32, @truncate(val_u64));
            s[i * 2 + 1] = @as(u32, @truncate(val_u64 >> 32));
        }

        var x0: v4u32 = @bitCast(s[0..4].*);
        var x1: v4u32 = @bitCast(s[4..8].*);
        var x2: v4u32 = @bitCast(s[8..12].*);
        // Inject coordinates directly into the final row
        var x3: v4u32 = .{
            @as(u32, @truncate(x)),
            @as(u32, @truncate(x >> 32)),
            @as(u32, @truncate(y)),
            @as(u32, @truncate(y >> 32)),
        };

        const orig0 = x0;
        const orig1 = x1;

        inline for (0..6) |_| {
            quarterRound(&x0, &x1, &x2, &x3);
            x1 = @shuffle(u32, x1, undefined, [4]i32{ 1, 2, 3, 0 });
            x2 = @shuffle(u32, x2, undefined, [4]i32{ 2, 3, 0, 1 });
            x3 = @shuffle(u32, x3, undefined, [4]i32{ 3, 0, 1, 2 });
            quarterRound(&x0, &x1, &x2, &x3);
            x1 = @shuffle(u32, x1, undefined, [4]i32{ 3, 0, 1, 2 });
            x2 = @shuffle(u32, x2, undefined, [4]i32{ 2, 3, 0, 1 });
            x3 = @shuffle(u32, x3, undefined, [4]i32{ 1, 2, 3, 0 });
        }

        x0 +%= orig0;
        x1 +%= orig1;

        // Return 128 bits of data (as two u64s)
        if (T == f64) {
            return .{
                @as(f64, @floatFromInt(@as(u64, x0[0]) | (@as(u64, x0[1]) << 32))) / POW_2_64,
                @as(f64, @floatFromInt(@as(u64, x0[2]) | (@as(u64, x0[3]) << 32))) / POW_2_64,
            };
        } else if (T == u64) {
            return .{
                @as(u64, x0[0]) | (@as(u64, x0[1]) << 32),
                @as(u64, x0[2]) | (@as(u64, x0[3]) << 32),
            };
        }
        @compileError("Only u64 and f64 values are supported.");
    }

    /// Expensive stateless 2D hash (using the first 384 seed bits), returning 512 bits of data.
    /// Treats X and Y as the `ChaCha12` nonce/counter to return a random value.
    pub fn hash2d512(comptime T: type, seed_data: *const Seed, x: u64, y: u64) [8]T {
        var s: [16]u32 align(16) = undefined;
        inline for (0..8) |i| {
            const val_u64 = seed_data.value[i];
            s[i * 2] = @as(u32, @truncate(val_u64));
            s[i * 2 + 1] = @as(u32, @truncate(val_u64 >> 32));
        }

        var x0 = @as(v4u32, @bitCast(s[0..4].*));
        var x1 = @as(v4u32, @bitCast(s[4..8].*));
        var x2 = @as(v4u32, @bitCast(s[8..12].*));
        var x3: v4u32 = .{
            @as(u32, @truncate(x)),
            @as(u32, @truncate(x >> 32)),
            @as(u32, @truncate(y)),
            @as(u32, @truncate(y >> 32)),
        };

        const orig = [4]v4u32{ x0, x1, x2, x3 };

        // 4 double-rounds = 8 rounds total
        inline for (0..6) |_| {
            quarterRound(&x0, &x1, &x2, &x3);
            x1 = @shuffle(u32, x1, undefined, [4]i32{ 1, 2, 3, 0 });
            x2 = @shuffle(u32, x2, undefined, [4]i32{ 2, 3, 0, 1 });
            x3 = @shuffle(u32, x3, undefined, [4]i32{ 3, 0, 1, 2 });
            quarterRound(&x0, &x1, &x2, &x3);
            x1 = @shuffle(u32, x1, undefined, [4]i32{ 3, 0, 1, 2 });
            x2 = @shuffle(u32, x2, undefined, [4]i32{ 2, 3, 0, 1 });
            x3 = @shuffle(u32, x3, undefined, [4]i32{ 1, 2, 3, 0 });
        }

        const array: Seed = .{
            packU64(x0 +% orig[0], 0, 1), packU64(x0 +% orig[0], 2, 3),
            packU64(x1 +% orig[1], 0, 1), packU64(x1 +% orig[1], 2, 3),
            packU64(x2 +% orig[2], 0, 1), packU64(x2 +% orig[2], 2, 3),
            packU64(x3 +% orig[3], 0, 1), packU64(x3 +% orig[3], 2, 3),
        };
        if (T == f64) {
            // convert to floats
            return .{
                @as(f64, @floatFromInt(array[0])) / POW_2_64,
                @as(f64, @floatFromInt(array[1])) / POW_2_64,
                @as(f64, @floatFromInt(array[2])) / POW_2_64,
                @as(f64, @floatFromInt(array[3])) / POW_2_64,
                @as(f64, @floatFromInt(array[4])) / POW_2_64,
                @as(f64, @floatFromInt(array[5])) / POW_2_64,
                @as(f64, @floatFromInt(array[6])) / POW_2_64,
                @as(f64, @floatFromInt(array[7])) / POW_2_64,
            };
        } else if (T == u64) {
            return array;
        }
        @compileError("Only u64 and f64 array values are supported.");
    }

    /// Generates the next 64 bytes of seeding data.
    fn generateBlock(self: *@This()) void {
        var x = self.state;

        // 12 rounds total (6 double-rounds)
        inline for (0..6) |_| {
            // Odd rounds (columns)
            quarterRound(&x[0], &x[4], &x[8], &x[12]);
            quarterRound(&x[1], &x[5], &x[9], &x[13]);
            quarterRound(&x[2], &x[6], &x[10], &x[14]);
            quarterRound(&x[3], &x[7], &x[11], &x[15]);

            // Even rounds (diagonals)
            quarterRound(&x[0], &x[5], &x[10], &x[15]);
            quarterRound(&x[1], &x[6], &x[11], &x[12]);
            quarterRound(&x[2], &x[7], &x[8], &x[13]);
            quarterRound(&x[3], &x[4], &x[9], &x[14]);
        }

        // Add original state and write back to the 64-byte keystream buffer
        inline for (0..8) |i| {
            const lo = x[i * 2] +% self.state[i * 2];
            const hi = x[i * 2 + 1] +% self.state[i * 2 + 1];
            self.keystream[i] = @as(u64, lo) | (@as(u64, hi) << 32);
        }

        // Increment the state counter (ChaCha block counter)
        self.state[12] +%= 1;
        if (self.state[12] == 0) {
            self.state[13] +%= 1;
        }
    }

    inline fn packU64(v: v4u32, lo: comptime_int, hi: comptime_int) u64 {
        return @as(u64, v[lo]) | (@as(u64, v[hi]) << 32);
    }

    inline fn quarterRound(a: *u32, b: *u32, c: *u32, d: *u32) void {
        a.* +%= b.*;
        d.* ^= a.*;
        d.* = std.math.rotl(u32, d.*, 16);
        c.* +%= d.*;
        b.* ^= c.*;
        b.* = std.math.rotl(u32, b.*, 12);
        a.* +%= b.*;
        d.* ^= a.*;
        d.* = std.math.rotl(u32, d.*, 8);
        c.* +%= d.*;
        b.* ^= c.*;
        b.* = std.math.rotl(u32, b.*, 7);
    }
};

test "basic determinism" {
    var seed: Seed = .{};
    seed.value[0] = 42;

    var rng1 = ChaCha12.init(&seed);
    var rng2 = ChaCha12.init(&seed);

    for (0..100) |_| {
        try std.testing.expectEqual(rng1.next(), rng2.next());
    }
}

test "skip produces same values" {
    var seed: Seed = .{};
    seed.value[0] = 123;
    seed.value[5] = 77;

    var rng_sequential = ChaCha12.init(&seed);

    // Consume 50 values
    var values: [50]u64 = undefined;
    for (0..50) |i| {
        values[i] = rng_sequential.next();
    }

    // Skip to position 25 and verify
    var rng_skipped = ChaCha12.init(&seed);
    rng_skipped.skip(25);

    for (25..50) |i| {
        try std.testing.expectEqual(values[i], rng_skipped.next());
    }
}

test "skip forward matches sequential" {
    var seed: Seed = .{};
    seed.value[3] = 0xAB;

    var rng1 = ChaCha12.init(&seed);
    var rng2 = ChaCha12.init(&seed);

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
    var seed: Seed = .{};
    seedFromBytes("my-game-seed", &seed);

    var rng = ChaCha12.init(&seed);

    // Get value at position 15 (spans two blocks since each block = 8 u64s)
    var reference = ChaCha12.init(&seed);
    for (0..15) |_| {
        _ = reference.next();
    }
    const expected = reference.next();

    rng.skip(15);
    try std.testing.expectEqual(expected, rng.next());
}

test "float range" {
    var seed: Seed = .{};
    seedFromBytes("my-game-seed", &seed);

    var rng = ChaCha12.init(&seed);

    for (0..1000) |_| {
        const f64_val = rng.float(f64);
        try std.testing.expect(f64_val >= 0.0 and f64_val < 1.0);

        const f32_val = rng.float(f32);
        try std.testing.expect(f32_val >= 0.0 and f32_val < 1.0);
    }
}

/// Xoshiro512** (StarStar), public domain randomness function.
/// A decent performance, all-purpose generator with a period of 2^512 - 1.
pub const Xoshiro512 = struct {
    state: [8]u64 align(16),

    /// Creates a new instance with seed data.
    pub inline fn init(seed_data: *const Seed) Xoshiro512 {
        var val: [8]u64 align(16) = seed_data.value; // copy
        if (val[0] == 0) {
            @branchHint(.unlikely);
            var check: u64 = 0;
            for (val[1..8]) |s| check |= s;
            if (check == 0) {
                @branchHint(.unlikely);
                val[0] = 0xbf58476d1ce4e5b9; // fill with deterministic constant
            }
            return .{ .state = val };
        }
        return .{ .state = val };
    }

    /// Returns the next 64 bits of psuedo-random data.
    pub fn next(self: *@This()) u64 {
        const result = std.math.rotl(u64, self.state[1] *% 5, 7) *% 9; // the "StarStar" part of things

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

    /// Returns a float value from [0, 1], using 64 bits of seeding data.
    pub fn float(self: *@This(), comptime T: type) T {
        if (T == f64 or T == f32 or T == f16) {
            return @as(T, @floatFromInt(self.next())) / POW_2_64;
        }
        @compileError("Only floats up to 64-bit precision are supported.");
    }
};

/// Basic seeding algorithm for 64-bit entropy avalanching.
pub inline fn staffordMix13(value: u64) u64 {
    var z = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// DO NOT USE FOR WASM, AS JS LOGIC EXISTS ALREADY. (Can be used for native in the future.)
/// Converts a base-26 [a-z]-only string to 64 bytes.
///
/// Asserts that the input is no longer than 100 characters.
pub fn seedFromBase26(noalias input: []const u8, noalias out_seed: *Seed) void {
    std.debug.assert(input.len <= 100);
    // Initialize out_seed to 0
    // @memset(out_seed, 0);
    out_seed.*.value = @splat(0); // NOTE: performance thing: @memset is slower

    for (input) |char| {
        const char_val = @as(u64, char - 'a') + 1;

        var carry: u64 = char_val;
        // Manual 512-bit multiplication (total = total * 26 + char_val)
        // We iterate through our 8 limbs
        for (&out_seed.value) |*limb| {
            // u128 is perfect for intermediate math to catch u64 overflow
            const prod = (@as(u128, limb.*) * 26) + carry;
            limb.* = @intCast(prod & 0xFFFFFFFFFFFFFFFF);
            carry = @intCast(prod >> 64);
        }
    }

    var borrow: u64 = 1;
    for (&out_seed.value) |*limb| {
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

/// Bridge to WASM, creates seed data from a string using bijective mapping.
pub fn wasmSeedFromString(noalias str_ptr: [*]const u8, str_len: u64, noalias output_ptr: *Seed) void {
    const temp: usize = @intCast(str_len);
    const input = str_ptr[0..temp];
    seedFromBase26(input, output_ptr);
}

test "bijective seeding uniqueness" {
    var s1: Seed = undefined;
    var s2: Seed = undefined;
    var s3: Seed = undefined;
    seedFromBase26("a", &s1);
    seedFromBase26("b", &s2);
    seedFromBase26("c", &s3);
    try testing.expect(!std.mem.eql(u64, &s1.value, &s2.value));
    try testing.expect(!std.mem.eql(u64, &s2.value, &s3.value));
}

test "Xoshiro512** initialization/consistency" {
    var seed: Seed = undefined;
    seedFromBytes("test_seed", &seed);
    var rng1 = Xoshiro512.init(&seed);
    var rng2 = Xoshiro512.init(&seed);

    // Both generators should produce identical output
    try testing.expectEqual(rng1.next(), rng2.next());
    try testing.expectEqual(rng1.next(), rng2.next());
    try testing.expectEqual(rng1.float(f32), rng2.float(f32));
}

test "branching check" {
    var seed: Seed = undefined;
    seedFromBytes("test", &seed);
    const rng_main = Xoshiro512.init(&seed);

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
fn seedFromBytes(noalias input: []const u8, noalias out_seed: *Seed) void {
    var hash_out: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(input, &hash_out, .{});

    // Write directly into the pointer provided
    inline for (0..8) |i| {
        const start = i * 8;
        out_seed.value[i] = std.mem.readInt(u64, hash_out[start .. start + 8], .little);
    }
}
