//! Manages seeding calculations for the game.
// seeding yippeeeeee
const std = @import("std");
const chunk = @import("chunk.zig");
const testing = std.testing;

test "full usage example" {
    const logger = @import("logger.zig");
    const allocator = std.testing.allocator;

    // Start with an arbitrary seed
    var world_seed: [8]u64 = undefined;
    seedFromBytes("my-game-seed", &world_seed);

    // Derive a unique seed for a specific chunk
    const chunk_seed = mixChunkSeed(world_seed, [_]u64{ 10, 20 });
    var rng = Xoshiro512.init(chunk_seed);

    // Fill a buffer of data
    const light_buffer = try allocator.alloc(u4, 16 * 16 * 16);
    defer allocator.free(light_buffer);

    // Log or use this float value
    logger.quick(rng.float(f32));

    // Verify we got data
    try std.testing.expect(light_buffer[0] <= 15);
}

/// Xoshiro512** (StarStar), public domain randomness function.
/// A high-performance, all-purpose generator with a period of 2^512 - 1.
pub const Xoshiro512 = struct {
    state: [8]u64,

    pub fn init(seed_data: [8]u64) Xoshiro512 {
        var state = seed_data;
        var check: u64 = 0;
        for (state) |s| check |= s;
        if (check == 0) {
            @branchHint(.unlikely);
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

    pub fn float(self: *Xoshiro512, comptime T: type) T {
        if (T == f64) {
            // Use 53 bits of entropy (mantissa size for f64)
            return @as(f64, @floatFromInt(self.next() >> 11)) * (1.0 / 9007199254740992.0);
        } else if (T == f32) {
            // Use 24 bits of entropy (mantissa size for f32)
            return @as(f32, @floatFromInt(self.next() >> 40)) * (1.0 / 16777216.0);
        }
        @compileError("Only f32 and f64 floats are supported.");
    }

    pub fn checkpoint(self: Xoshiro512) Xoshiro512 {
        return self;
    }
};

/// Stafford Mix 13 for 64-bit entropy avalanching.
pub inline fn staffordMix13(z_in: u64) u64 {
    var z = (z_in ^ (z_in >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// Takes a 512-bit starting seed and mixes it with a compile-time tuple or vector using staffordMix13.
pub inline fn mixChunkSeed(base_seed: [8]u64, inputs: anytype) [8]u64 {
    var state = base_seed;
    const ArgsType = @TypeOf(inputs);
    const info = @typeInfo(ArgsType);

    switch (info) {
        .@"struct" => |s| {
            inline for (s.fields, 0..) |field, i| {
                validateAndMix(&state, i % 8, field.type, inputs[i]);
            }
        },
        .array => |a| {
            inline for (0..a.len) |i| {
                validateAndMix(&state, i % 8, a.child, inputs[i]);
            }
        },
        else => @compileError("mixChunkSeed requires a struct, tuple, or array. Found: " ++ @typeName(ArgsType)),
    }

    // Final diffusion pass
    const old = state;
    inline for (0..8) |i| {
        state[i] = staffordMix13(old[i] ^ old[(i + 1) % 8]);
    }
    return state;
}

/// Validates mixChunkSeed and performs the mixing
inline fn validateAndMix(state: *[8]u64, idx: usize, comptime T: type, val: anytype) void {
    if (T != u64 and T != i64) {
        @compileError("mixChunkSeed only accepts u64 or i64. Found: " ++ @typeName(T));
    }
    const casted_val: u64 = if (T == i64) @bitCast(val) else val;
    state[idx] +%= staffordMix13(casted_val);
}

/// Mixes a ScaleCoord into the base seed.
pub fn mixScaleCoord(base_seed: [8]u64, coord: chunk.ScaleCoord) [8]u64 {
    var state = base_seed;

    // Mix the spatial vector
    state[0] +%= staffordMix13(@bitCast(coord.pos[0]));
    state[1] +%= staffordMix13(@bitCast(coord.pos[1]));

    // Mix the unbounded depth stack (packing u4s into u64s for fast mixing)
    var current_val: u64 = 0;
    var shift: u6 = 0;
    var state_idx: usize = 2; // Start after pos mix

    for (coord.depth_stack) |nibble| {
        current_val |= @as(u64, nibble) << shift;
        shift +%= 4;

        if (shift == 0) { // 16 nibbles (64 bits) accumulated
            state[state_idx % 8] +%= staffordMix13(current_val);
            state_idx += 1;
            current_val = 0;
        }
    }
    // Mix remaining nibbles
    if (shift > 0) {
        state[state_idx % 8] +%= staffordMix13(current_val);
    }

    // Final diffusion pass
    const old = state;
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

/// BROKEN WHEN EXPORTING, DO NOT USE. JS LOGIC EXISTS ALREADY. Converts a base-26 [a-z]-only string to 64 bytes. Input should  too no larger than 100 characters.
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
    const input_1 = [_]u64{ 10, 20, 1 };
    const input_2 = [_]u64{ 10, 21, 1 };
    const c1 = mixChunkSeed(world_seed, input_1);
    const c2 = mixChunkSeed(world_seed, input_1);
    const c3 = mixChunkSeed(world_seed, input_2);
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
    try testing.expectEqual(rng1.float(f32), rng2.float(f32));
}

test "branching check" {
    var seed: [8]u64 = undefined;
    seedFromBytes("test", &seed);
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
fn seedFromBytes(input: []const u8, out_seed: *[8]u64) void {
    var hash_out: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(input, &hash_out, .{});

    // Write directly into the pointer provided
    inline for (0..8) |i| {
        const start = i * 8;
        out_seed[i] = std.mem.readInt(u64, hash_out[start .. start + 8], .little);
    }
}
