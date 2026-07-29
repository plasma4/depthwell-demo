//! Small quality-of-life utility functions.
const std = @import("std");

/// Returns an int (0 or 1) of type `T` from a boolean.
pub inline fn intFromBool(comptime T: type, condition: bool) T {
    return @as(T, @intCast(@intFromBool(condition)));
}

/// Slot a 2D cell occupies in a direct-mapped cache laid out as a `width` x `height` tile of slots.
/// A tile, NOT a hash of the coordinates.
///
/// Two cells share a slot only when they sit a whole tile apart on an axis!
///
/// `x` and `y` may be signed; only their low bits are read, so a negative cell wraps like any other.
/// The dimensions must be powers of two, and their product is the slot count.
pub inline fn tileIndex(comptime width: u32, comptime height: u32, x: anytype, y: anytype) usize {
    comptime {
        if (!std.math.isPowerOfTwo(width) or !std.math.isPowerOfTwo(height))
            @compileError("Tile dimensions must be powers of two, so wrapping a cell into one is a bitwise AND.");
    }
    const ux = @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(x))), @bitCast(x)) & (width - 1);
    const uy = @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(y))), @bitCast(y)) & (height - 1);
    return @as(usize, @intCast(uy)) * width + @as(usize, @intCast(ux));
}

// vector types!
pub const Vec2i = @Vector(2, i64);
pub const Vec2u = @Vector(2, u64);
pub const Vec2f = @Vector(2, f64);
pub const Vec2f32 = @Vector(2, f32);
pub const Vec4u = @Vector(4, u64);
pub const Vec4f32 = @Vector(4, f32);
