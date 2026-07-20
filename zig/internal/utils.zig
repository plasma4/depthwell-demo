//! Small quality-of-life utility functions.

/// Returns an int (0 or 1) of type `T` from a boolean.
pub inline fn intFromBool(comptime T: type, condition: bool) T {
    return @as(T, @intCast(@intFromBool(condition)));
}

// vector types!
pub const Vec2i = @Vector(2, i64);
pub const Vec2u = @Vector(2, u64);
pub const Vec2f = @Vector(2, f64);
pub const Vec2f32 = @Vector(2, f32);
pub const Vec4u = @Vector(4, u64);
pub const Vec4f32 = @Vector(4, f32);
