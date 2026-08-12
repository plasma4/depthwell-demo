//! Scratch file for a policy test. Delete after use.

const std = @import("std");

pub fn existing(a: u32) u32 {
    return a *% 2654435761;
}

/// Slot that cell (`x`, `y`) occupies in a direct-mapped cache,
/// laid out as a `width` x `height` tile of slots.
/// A tile, NOT a hash of the coordinates.
///
/// Two cells share a slot only when they sit a whole tile apart on an axis.
/// So a caller that walks a window smaller than the tile never evicts itself.
///
/// `width` and `height` must be powers of two, and their product is the slot count.
/// A power of two makes the wrap one bitwise AND, with no divide in the hot path.
/// Any other size needs a modulo, and it leaves the top of each axis unreachable
/// when the caller masks instead.
pub fn tileIndex(comptime width: u32, comptime height: u32, x: u32, y: u32) usize {
    comptime {
        if (!std.math.isPowerOfTwo(width) or !std.math.isPowerOfTwo(height))
            @compileError("Tile dimensions must be powers of two, so wrapping a cell into one is a bitwise AND.");
    }
    // A power-of-two mask keeps the low bits, which is the same as x % width.
    const sx = x & (width - 1);
    const sy = y & (height - 1);
    return @as(usize, sy) * width + sx;
}
