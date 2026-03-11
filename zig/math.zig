//! Math functions for the game.
const std = @import("std");

/// Determines if a number is odd.
pub inline fn is_odd(num: i32) bool {
    return (num & 1) != 0;
}

/// Determines if a number is even.
pub inline fn is_even(num: i32) bool {
    return (num & 1) == 0;
}

pub fn isVector(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .vector => true,
        else => false,
    };
}

/// Returns 0 if @abs(value) (as scalar or vector) is less than threshold, and value otherwise.
pub inline fn zero_if_less_than(value: anytype, threshold: anytype) @TypeOf(value) {
    const T = @TypeOf(value);
    if (comptime isVector(T)) {
        const Child = @typeInfo(T).vector.child;
        const threshold_vec: T = @splat(@as(Child, threshold));
        const zero_vec: T = @splat(@as(Child, 0));
        const mask = @abs(value) < threshold_vec;
        return @select(Child, mask, zero_vec, value);
    } else {
        return if (value < threshold) 0 else value;
    }
}

/// Flushes f32 denormalized numbers to zero while preserving the sign bit.
/// Fast and deterministic for WASM.
pub inline fn flush_denormal(val: f32) f32 {
    const bits: u32 = @bitCast(val);

    // Extract the 8-bit exponent (bits 23-30)
    const exponent = (bits >> 23) & 0xFF;

    // In IEEE 754, an exponent of 0 means the number is either 0 or subnormal.
    if (exponent == 0) {
        // Return 0.0, but keep the original sign bit (bit 31)
        return @bitCast(bits & 0x80000000);
    }

    return val;
}

test "isVector identifies types correctly" {
    try std.testing.expect(isVector(@Vector(4, f32)) == true);
    try std.testing.expect(isVector(f32) == false);
    try std.testing.expect(isVector(i32) == false);
    try std.testing.expect(isVector([4]f32) == false); // Arrays are not vectors
}

test "zero_if_less_than with scalars" {
    // Standard floats
    try std.testing.expectEqual(@as(f32, 10.0), zero_if_less_than(@as(f32, 10.0), 5.0));
    try std.testing.expectEqual(@as(f32, 0.0), zero_if_less_than(@as(f32, 3.0), 5.0));

    // Integers
    try std.testing.expectEqual(@as(i32, 100), zero_if_less_than(@as(i32, 100), 50));
    try std.testing.expectEqual(@as(i32, 0), zero_if_less_than(@as(i32, 20), 50));
}

test "zero_if_less_than with vectors" {
    const Vec6 = @Vector(6, f32);
    const input: Vec6 = .{ 1.0, 10.0, 2.0, 8.0, -4.0, -6.0 };
    const threshold: f32 = 5.0;

    const result = zero_if_less_than(input, threshold);

    try std.testing.expectEqual(result[0], 0.0);
    try std.testing.expectEqual(result[1], 10.0);
    try std.testing.expectEqual(result[2], 0.0);
    try std.testing.expectEqual(result[3], 8.0);
    try std.testing.expectEqual(result[4], 0.0);
    try std.testing.expectEqual(result[5], -6.0);
}

test "flush_denormal behavior" {
    // Normal numbers should remain untouched
    try std.testing.expectEqual(@as(f32, 1.0), flush_denormal(1.0));
    try std.testing.expectEqual(@as(f32, -0.5), flush_denormal(-0.5));

    // Smallest positive normal f32 is ~1.175e-38
    const smallest_normal: f32 = 1.17549435e-38;
    try std.testing.expectEqual(smallest_normal, flush_denormal(smallest_normal));

    // Denormal/Subnormal numbers (exponent bits are all 0)
    // Example: smallest_normal / 2
    const subnormal_pos: f32 = @bitCast(@as(u32, 0x00400000));
    const subnormal_neg: f32 = @bitCast(@as(u32, 0x80400000));

    // Should flush to zero but keep sign
    const flushed_pos = flush_denormal(subnormal_pos);
    const flushed_neg = flush_denormal(subnormal_neg);

    try std.testing.expectEqual(flushed_pos, 0.0);
    try std.testing.expectEqual(flushed_neg, -0.0);

    // Verify sign bit preservation specifically
    try std.testing.expect(@as(u32, @bitCast(flushed_pos)) == 0x00000000);
    try std.testing.expect(@as(u32, @bitCast(flushed_neg)) == 0x80000000);
}
