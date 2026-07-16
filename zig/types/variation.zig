//! Data-driven sprite variation and animation resolver through a giant rule table.
//!
//! `resolveVariant()` is called once per visible tile per render frame in `render/chunk.zig`,
//! producing the FINAL atlas sprite ID; the shader samples it directly with no further shifting.
//!
//! To add a variant: append one row to `rules`. Variant frames must be CONTIGUOUS atlas IDs
//! starting at the base sprite (base+0 .. base+count-1); the comptime check below enforces range.
//!
//! TODO: migrate this to be calculated on-GPU once SPIR-V support drops.
const std = @import("std");
const dw = @import("../root.zig");

const Sprite = dw.Sprite;
const Block = dw.memory.Block;

/// Edge-flag bit for "solid neighbor directly above" (see `types/types.zig` `EdgeFlags`).
const ABOVE_BIT: u8 = dw.types.EdgeFlags.getFlagBit(0, -1);

/// How a variant offset (added to the base sprite ID) is chosen.
pub const VariantKind = enum {
    /// 2x2 positional tiling by tile-coordinate parity: offset `((ty&1)<<1)|(tx&1)` (needs count 4).
    grid_2x2,
    /// 2-frame checkerboard by tile-coordinate parity: offset `(tx&1)^(ty&1)`.
    checkerboard,
    /// Seed-based pick of `0..count-1`, biased towards 0.
    /// Reads `ceil(log2 count)` seed bits; an out-of-range roll collapses to 0.
    seed_pick,
    /// Time-based cycling: offset `(frame / period_frames) % count`.
    animate,
    /// Liquid surface: offset 1 (top sprite) when no solid/liquid fully covers the block above.
    water_top,
};

/// One variation rule, applied to the sprite named in the `rules` table below.
pub const VariantRule = struct {
    kind: VariantKind,
    /// Number of contiguous atlas frames, including the base (must be >= 2).
    count: u8 = 2,
    /// `animate` only: render frames per displayed frame (must be >= 1).
    period_frames: u8 = 1,
};

/// The full variation database. Order does not matter; each sprite maps to at most one rule.
const rules = [_]struct { Sprite, VariantRule }{
    // "Plain" stone: 2x2 grid so it reads like a 32x32 texture instead of obviously tiling.
    .{ .stone, .{ .kind = .grid_2x2, .count = 4 } },
    // Edge stone alternates in a checkerboard.
    .{ .edge_stone, .{ .kind = .checkerboard, .count = 2 } },
    // 50% seed variation.
    .{ .bush, .{ .kind = .seed_pick, .count = 2 } },
    .{ .ceiling_flower, .{ .kind = .seed_pick, .count = 2 } },
    .{ .cornflower, .{ .kind = .seed_pick, .count = 2 } },
    // 3 frames, weighted 50% toward the base frame.
    .{ .mushroom, .{ .kind = .seed_pick, .count = 3 } },
    .{ .big_mushroom, .{ .kind = .seed_pick, .count = 3 } },
    // Liquid top surface (formerly special-cased inline in chunk.zig).
    .{ .water, .{ .kind = .water_top, .count = 2 } },

    // Campfire animation has 4 contiguous frames, advancing every 6 render frames.
    // There's a HARDCODED custom resolution to use the underwater variant if waterlogged.
    .{ .campfire, .{ .kind = .animate, .count = 4, .period_frames = 6 } },

    .{ .basic_core, .{ .kind = .animate, .count = 2, .period_frames = 17 } },
    .{ .core1, .{ .kind = .animate, .count = 2, .period_frames = 8 } },
    .{ .core2, .{ .kind = .animate, .count = 2, .period_frames = 7 } },
    .{ .core3, .{ .kind = .animate, .count = 2, .period_frames = 6 } },
    .{ .core4, .{ .kind = .animate, .count = 2, .period_frames = 5 } },
};

/// Sparse-to-dense lookup: sprite ID -> its rule, or null. One indexed load at runtime.
const variant_table: [dw.sprite.MAX_SPRITE_ID]?VariantRule = blk: {
    @setEvalBranchQuota(20000);
    var table: [dw.sprite.MAX_SPRITE_ID]?VariantRule = @splat(null);
    for (rules) |entry| {
        const base = @intFromEnum(entry[0]);
        const rule = entry[1];
        if (rule.count < 2) @compileError("VariantRule.count must be >= 2");
        if (rule.kind == .animate and rule.period_frames < 1) @compileError("animate period_frames must be >= 1");
        if (base + rule.count - 1 > dw.sprite.max_sprite_value)
            @compileError("Variant frames extend past the last sprite ID");
        table[base] = rule;
    }
    break :blk table;
};

// A variant could reserve the atlas IDs base+1 .. base+count-1 for its extra frames,
// all while nothing in the `Sprite` enum marks them as taken.
// So every ID inside a variant's span must either be unnamed, or an explicit frame of that same sprite
// (named with the base's tag as a prefix, like `campfire_2`).
comptime {
    @setEvalBranchQuota(200000);
    for (rules) |entry| {
        const base_name = @tagName(entry[0]);
        const base = @intFromEnum(entry[0]);
        for (base + 1..base + entry[1].count) |frame| {
            const name = std.enums.tagName(Sprite, @enumFromInt(frame)) orelse continue;
            if (!std.mem.startsWith(u8, name, base_name))
                @compileError("Sprite `" ++ name ++ "` sits inside `" ++ base_name ++ "`'s reserved variant frames; move it or shrink the variant.");
        }
    }
}

/// Bijective 32-bit mixer, identical to `murmurmix32` in `src/shader.wgsl`.
fn murmurmix32(number: u32) u32 {
    var h = @max(number, 1);
    h ^= h >> 16;
    h *%= 0x85ebca6b;
    h ^= h >> 13;
    h *%= 0xc2b2ae35;
    h ^= h >> 16;
    return h;
}

/// Picks a weighted variant offset from a block seed (see `seed_pick`).
fn seedPick(seed: u32, count: u8) u16 {
    const bits_needed = std.math.log2_int_ceil(u8, count);
    const mixed = murmurmix32(murmurmix32(seed));
    const mask = (@as(u32, 1) << @intCast(bits_needed)) - 1;
    const raw = (mixed >> 16) & mask;
    return if (raw >= count) 0 else @intCast(raw);
}

/// Resolves the final atlas sprite ID for a block, applying positional, seed-based, or time-based
/// (animation) variation. `tx`/`ty` are ABSOLUTE tile coordinates; `frame` is the current render frame.
/// Returns `block.id` unchanged when the sprite has no variation rule.
pub fn resolveVariant(block: Block, tx: u64, ty: u64, frame: u32) Sprite {
    var id = block.id;
    // special hardcode for campfire:
    if (id == .campfire and dw.water.getVolume(block) > 0) {
        id = .campfire_water;
    }

    return resolveSpriteVariant(
        id,
        block.seed,
        block.edge_flags,
        tx,
        ty,
        frame,
    );
}

pub fn resolveSpriteVariant(
    sprite: Sprite,
    seed: u32,
    edge_flags: u8,
    tx: u64,
    ty: u64,
    frame: u32,
) Sprite {
    const id = @intFromEnum(sprite);
    if (id >= dw.sprite.MAX_SPRITE_ID) return sprite;
    const rule = variant_table[id] orelse return sprite;

    const offset: u16 = switch (rule.kind) {
        .grid_2x2 => @intCast(((ty & 1) << 1) | (tx & 1)),
        .checkerboard => @intCast((tx & 1) ^ (ty & 1)),
        .seed_pick => seedPick(seed, rule.count),
        .animate => @intCast((frame / rule.period_frames) % rule.count),
        .water_top => if ((edge_flags & ABOVE_BIT) == 0) 1 else 0,
    };

    return @enumFromInt(id + offset);
}
