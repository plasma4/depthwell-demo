//! Multi-tile "assembly" logic: an assembly is a rectangular group of tiles that is treated as one unit
//! (but stored as a single generic base `Sprite` in every cell, potentially across `Chunk`s).
//! Each cell records its position within the footprint in `Block.group_x`/`group_y`,
//! and the final per-cell atlas frame is resolved at RENDER time by the `.group` variant (see `zig/types/variation.zig`).
//!
//! No need to register single-tile blocks; can't have assemblies larger than 15x15.
const std = @import("std");
const dw = @import("../root.zig");

const Sprite = dw.Sprite;
const Block = dw.memory.Block;
const Chunk = dw.memory.Chunk;
const CHUNK_SIZE = dw.CHUNK_SIZE;

/// A rectangular assembly footprint, in tiles. `w`/`h` must be 1...15 (fits `Block.group_x`/`group_y`).
pub const Footprint = struct {
    w: u4 = 1,
    h: u4 = 1,

    /// Number of atlas frames the footprint spans (one per cell); must equal the tile's `.group` variant count.
    pub inline fn frameCount(self: Footprint) u16 {
        return @as(u16, self.w) * self.h;
    }
};

/// Registry entry: the base (top-left) sprite stored in every footprint cell, plus its size.
const AssemblyRule = struct { Sprite, Footprint };

/// All registered multi-tile assemblies. Add a row here plus a matching `.group` variation rule.
const rules = [_]AssemblyRule{
    // 2x1 big trees: left/right frames resolved at render (group_w = 2 in variation.zig).
    // .{ .moss_shrub1, .{ .w = 2, .h = 1 } },
    // .{ .moss_shrub2, .{ .w = 2, .h = 1 } },
};

/// Dense sprite -> footprint LUT; unregistered ids default to a 1x1 (single-tile) footprint.
const footprint_table: [dw.sprite.MAX_SPRITE_ID]Footprint = blk: {
    @setEvalBranchQuota(20000);
    var table: [dw.sprite.MAX_SPRITE_ID]Footprint = @splat(.{});
    for (rules) |rule| {
        table[@intFromEnum(rule[0])] = rule[1];
    }
    break :blk table;
};

/// Returns the footprint of a stored sprite, or a 1x1 footprint for single-tile / invalid sprites.
pub inline fn footprintOf(sprite: Sprite) Footprint {
    const id = @intFromEnum(sprite);
    if (id >= dw.sprite.MAX_SPRITE_ID) return .{};
    return footprint_table[id];
}

/// Whether a stored sprite spans more than one tile (has a registered multi-tile footprint).
pub inline fn isMultiTile(sprite: Sprite) bool {
    const f = footprintOf(sprite);
    return f.w > 1 or f.h > 1;
}

/// Given any cell of an assembly, the delta from this cell back to the group's top-left origin.
/// Returns `(-group_x, -group_y)`; add to a cell coordinate to reach the footprint origin.
/// Used by support checks and group-aware cascade so a multi-tile group breaks as a unit.
pub inline fn originDelta(block: Block) struct { dx: i32, dy: i32 } {
    return .{ .dx = -@as(i32, block.group_x), .dy = -@as(i32, block.group_y) };
}

/// Stamps an assembly's tiles into a single chunk's block array during generation.
/// `ox`/`oy` are the top-left LOCAL cell; the whole footprint MUST fit within [0, CHUNK_SIZE).
/// Preserves each cell's existing seed; only sets `id` and the footprint position fields.
pub fn stampChunk(chunk: *Chunk, ox: usize, oy: usize, base: Sprite) void {
    const f = footprintOf(base);
    std.debug.assert(ox + f.w <= CHUNK_SIZE and oy + f.h <= CHUNK_SIZE);
    var dy: usize = 0;
    while (dy < f.h) : (dy += 1) {
        var dx: usize = 0;
        while (dx < f.w) : (dx += 1) {
            const b = &chunk.blocks[(oy + dy) * CHUNK_SIZE + (ox + dx)];
            b.id = base;
            b.group_x = @intCast(dx);
            b.group_y = @intCast(dy);
        }
    }
}

// Cross-check each registered footprint against its render `.group` variant so the stored (group_x, group_y) can never index past the sprite's atlas frames.
comptime {
    @setEvalBranchQuota(20000);
    for (rules) |rule| {
        const base = rule[0];
        const f = rule[1];
        if (f.w < 1 or f.h < 1) @compileError("Assembly footprint dimensions must be >= 1");
        const variant = dw.variation.ruleFor(base) orelse
            @compileError("Multi-tile assembly base " ++ @tagName(base) ++ " needs a `.group` variation rule");
        if (variant.kind != .group)
            @compileError("Assembly base " ++ @tagName(base) ++ " must use VariantKind.group");
        if (variant.group_w != f.w)
            @compileError("Assembly base " ++ @tagName(base) ++ " group_w must equal footprint width");
        if (variant.count != f.frameCount())
            @compileError("Assembly base " ++ @tagName(base) ++ " variant count must equal w*h footprint frames");
    }
}
