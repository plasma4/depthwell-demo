//! Manages seeding calculations for the game.
// seeding yippeeeeee
const std = @import("std");
const testing = std.testing;

test "full usage example" {
    const allocator = std.testing.allocator;

    // Start with an arbitrary seed
    var world_seed: [8]u64 = undefined;
    seedFromBytes("my-game-seed", &world_seed);

    // Derive a unique seed for a specific chunk
    const chunk_seed = mixChunkSeed(world_seed, 10, -5, 20);
    var rng = Xoshiro512.init(chunk_seed);

    // Fill a buffer for block light levels (u4 = 0-15)
    const light_buffer = try allocator.alloc(u4, 16 * 16 * 16);
    defer allocator.free(light_buffer);
    rng.fillU4(light_buffer);

    // Verify we got data
    try std.testing.expect(light_buffer[0] <= 15);
}

/// Xoshiro512** (StarStar), public domain
/// A high-performance, all-purpose generator with a period of 2^512 - 1.
pub const Xoshiro512 = struct {
    state: [8]u64,

    pub fn init(seed_data: [8]u64) Xoshiro512 {
        var state = seed_data;
        var check: u64 = 0;
        for (state) |s| check |= s;
        if (check == 0) {
            state[0] = 0xbf58476d1ce4e5b9; // fill with some random constant (technically not needed with seeding.ts logic being sound)
        }
        return .{ .state = state };
    }

    pub fn next(self: *Xoshiro512) u64 {
        const result = std.math.rotl(u64, self.state[1] *% 5, 7) *% 9;

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

    pub fn checkpoint(self: Xoshiro512) Xoshiro512 {
        return self;
    }

    pub fn fillU4(self: *Xoshiro512, buffer: []u4) void {
        var i: usize = 0;
        // Process 16 elements at a time contiguously for better SIMD optimization
        while (i + 16 <= buffer.len) : (i += 16) {
            const r = self.next();
            inline for (0..16) |j| {
                buffer[i + j] = @truncate(r >> @intCast(j * 4));
            }
        }
        // Cleanup remaining elements
        if (i < buffer.len) {
            const r = self.next();
            var rem: usize = 0;
            while (i < buffer.len) : (i += 1) {
                buffer[i] = @truncate(r >> @intCast(rem * 4));
                rem += 1;
            }
        }
    }
};

/// Stafford Mix 13 for 64-bit entropy avalanching.
inline fn staffordMix13(z_in: u64) u64 {
    var z = (z_in ^ (z_in >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// Takes a 512-bit world seed and mixes it with chunk coordinates and depth using SplitMix64.
pub fn mixChunkSeed(base_seed: [8]u64, x: i32, y: i32, depth: i32) [8]u64 {
    var state = base_seed;
    state[0] +%= staffordMix13(@bitCast(@as(i64, x)));
    state[1] +%= staffordMix13(@bitCast(@as(i64, y)));
    state[2] +%= staffordMix13(@bitCast(@as(i64, depth)));

    const old = state; // Capture state to break the dependency chain
    inline for (0..8) |i| {
        state[i] = staffordMix13(old[i] ^ old[(i + 1) % 8]);
    }
    return state;
}

/// Mixes chunk data using BLAKE3 (fast and WASM-friendly).
pub fn mixLargeChunkData(world_seed: [8]u64, data: []const u8) [8]u64 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(std.mem.asBytes(&world_seed));
    hasher.update(data);

    var out: [64]u8 = undefined;
    hasher.final(&out);

    return @bitCast(out);
}

/// BROKEN WHEN EXPORTING, DO NOT USE. JS LOGIC EXISTS ALREADY. Converts a base-26 [a-z]-only string to 64 bytes. Input should be no larger than 100 characters.
pub fn seedFromBase26(input: []const u8, out_seed: *[8]u64) void {
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
pub fn wasm_seed_from_string(str_ptr: [*]const u8, str_len: u64, output_ptr: *[8]u64) void {
    const temp: usize = @intCast(str_len);
    const input = str_ptr[0..temp];
    seedFromBase26(input, output_ptr);
}

test "bijective seeding uniqueness" {
    var s1: [8]u64 = undefined;
    var s2: [8]u64 = undefined;
    var s3: [8]u64 = undefined;
    seedFromBase26("a", &s1);
    seedFromBase26("b", &s2);
    seedFromBase26("c", &s3);
    try testing.expect(!std.mem.eql(u64, &s1, &s2));
    try testing.expect(!std.mem.eql(u64, &s2, &s3));
}

test "chunk mixing determinism" {
    const world_seed = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const c1 = mixChunkSeed(world_seed, 10, 20, 1);
    const c2 = mixChunkSeed(world_seed, 10, 20, 1);
    const c3 = mixChunkSeed(world_seed, 10, 21, 1);
    try testing.expectEqualSlices(u64, &c1, &c2);
    try testing.expect(!std.mem.eql(u64, &c2, &c3));
}

test "Xoshiro512** initialization/consistency" {
    var seed: [8]u64 = undefined;
    seedFromBytes("test_seed", &seed);
    var rng1 = Xoshiro512.init(seed);
    var rng2 = Xoshiro512.init(seed);

    // Both generators should produce identical output
    try testing.expectEqual(rng1.next(), rng2.next());
    try testing.expectEqual(rng1.next(), rng2.next());
}

test "branching check" {
    var seed: [8]u64 = undefined;
    seedFromBytes("test", &seed);
    var rng_main = Xoshiro512.init(seed);

    var branch_a = rng_main.checkpoint(); // Value copy
    var branch_b = rng_main.checkpoint(); // Value copy

    const val_a = branch_a.next();
    const val_b = branch_b.next();

    try testing.expectEqual(val_a, val_b); // MUST pass

    _ = branch_a.next(); // branch_a advances
    // branch_b is still at the previous state

    try testing.expect(branch_a.next() != branch_b.next());
}

test "bulk u4 generation" {
    var seed: [8]u64 = undefined;
    seedFromBytes("u4_test", &seed);
    var rng = Xoshiro512.init(seed);

    // Buffer size not divisible by 16 to test edge cases
    var buf: [35]u4 = undefined;
    rng.fillU4(&buf);

    // Just ensure data is actually written (probabilistic)
    var sum: u32 = 0;
    for (buf) |val| sum += val;
    try testing.expect(sum > 0);
}

/// Hashes an arbitrary string into a 512-bit seed directly into the destination (using Sha512).
fn seedFromBytes(input: []const u8, out_seed: *[8]u64) void {
    var hash_out: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(input, &hash_out, .{});

    // Write directly into the pointer provided
    inline for (0..8) |i| {
        const start = i * 8;
        out_seed[i] = std.mem.readInt(u64, hash_out[start .. start + 8], .little);
    }
}
