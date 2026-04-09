//! Small quality-of-life utility functions.

/// Returns an int (0 or 1) of type `T` from a boolean.
pub inline fn intFromBool(comptime T: type, condition: bool) T {
    return @as(T, @intCast(@intFromBool(condition)));
}
