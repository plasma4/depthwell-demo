//! Small quality-of-life utility functions.
pub inline fn intFromBool(comptime T: type, condition: bool) T {
    return @as(T, @intCast(@intFromBool(condition)));
}
