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
    /// No special rule.
    default,
    /// 2x2 positional tiling by tile-coordinate parity: offset `((ty&1)<<1)|(tx&1)` (needs count 4).
    grid_2x2,
    /// 2-frame checkerboard by tile-coordinate parity: offset `(tx&1)^(ty&1)`.
    checkerboard,
    /// 2-frame horizontal parity: offset `tx & 1`.
    x_parity,
    /// 2-frame vertical parity: offset `ty & 1`.
    y_parity,
    /// Seed-based pick of `0..count-1`, biased towards 0.
    /// Reads `ceil(log2 count)` seed bits; an out-of-range roll collapses to 0.
    random,
    /// Time-based cycling: offset `(frame / period_frames) % count`.
    animate,
};

/// Edge-matching rule matching a 3x3 neighbor pattern.
pub const EdgeRule = struct {
    /// 3x3 ascii pattern.
    /// `'#'` = solid neighbor, `'.'` = air/open, `'?'` = wildcard
    pattern: []const u8,
    /// Base sprite offset applied when pattern matches.
    offset: u16,
    /// Variation strategy for matching tiles.
    kind: VariantKind = .grid_2x2,
    /// Number of sub-variant frames.
    count: u8 = 1,
};

/// One variation rule, applied to the sprite named in the `rules` table below.
pub const VariantRule = struct {
    kind: VariantKind = .default,
    /// Number of contiguous atlas frames, including the base (must be >= 2).
    count: u8 = 2,
    /// `animate` only: render frames per displayed frame (must be >= 1).
    period_frames: u8 = 1,
    /// Edge pattern rules evaluated in priority order.
    edge_rules: []const EdgeRule = &.{},
};

/// The full variation database. Order does not matter; each sprite maps to at most one rule.
const rules = [_]struct { Sprite, VariantRule }{
    // "Plain" stone: 2x2 grid so it reads like a 32x32 texture instead of obviously tiling.
    .{ .stone, .{ .kind = .grid_2x2, .count = 4 } },
    .{ .diorite, .{ .kind = .x_parity, .count = 2 } },
    // Edge stone alternates in a checkerboard.
    .{ .edge_stone, .{ .kind = .checkerboard, .count = 2 } },
    // seed variations! (non-uniform; read VariantKind definition!)
    .{ .bush, .{ .kind = .random, .count = 2 } },
    .{ .rock, .{ .kind = .random, .count = 2 } },
    .{ .aqua_stone, .{ .kind = .random, .count = 2 } },
    .{ .ceiling_flower, .{ .kind = .random, .count = 4 } },
    .{ .cornflower, .{ .kind = .random, .count = 2 } },
    .{ .mushroom, .{ .kind = .random, .count = 3 } },
    .{ .big_mushroom, .{ .kind = .random, .count = 3 } },

    // new dirt autotiling rules using 3x3 neighbor patterns
    .{
        .dirt,
        .{
            .count = 4,
            .edge_rules = &.{
                // top dirt: open neighbor above
                .{
                    .pattern =
                    \\ ? . ?
                    \\ ? X ?
                    \\ ? ? ?
                    ,
                    .offset = 2,
                    .count = 2,
                    .kind = .x_parity,
                },
                // center dirt: solid neighbor below
                .{
                    .pattern =
                    \\ ? ? ?
                    \\ ? X ?
                    \\ ? # ?
                    ,
                    .offset = 1,
                    .count = 1,
                },
            },
        },
    },
    .{
        .red_dirt,
        .{
            .count = 4,
            .edge_rules = &.{
                // top dirt: open neighbor above
                .{
                    .pattern =
                    \\ ? . ?
                    \\ ? X ?
                    \\ ? ? ?
                    ,
                    .offset = 2,
                    .count = 2,
                    .kind = .x_parity,
                },
                // center dirt: solid neighbor below
                .{
                    .pattern =
                    \\ ? ? ?
                    \\ ? X ?
                    \\ ? # ?
                    ,
                    .offset = 1,
                    .count = 1,
                },
            },
        },
    },

    // Campfire animation has 4 contiguous frames, advancing every 6 render frames.
    // There's a HARDCODED custom resolveVariant() check to use the underwater variant if waterlogged!
    .{ .campfire, .{ .kind = .animate, .count = 4, .period_frames = 6 } },
    // needed for custom variant
    .{ .campfire_water, .{ .kind = .animate, .count = 4, .period_frames = 7 } },

    .{ .basic_core, .{ .kind = .animate, .count = 2, .period_frames = 17 } },
    .{ .core1, .{ .kind = .animate, .count = 2, .period_frames = 8 } },
    .{ .core2, .{ .kind = .animate, .count = 2, .period_frames = 7 } },
    .{ .core3, .{ .kind = .animate, .count = 2, .period_frames = 6 } },
    .{ .core4, .{ .kind = .animate, .count = 2, .period_frames = 5 } },
};

/// Compiled edge pattern evaluated against runtime edge_flags.
pub const CompiledEdgeRule = struct {
    mask: u8,
    value: u8,
    offset: u16,
    kind: VariantKind,
    count: u8,
};

/// Compiled rule payload stored in lookup table.
pub const CompiledRule = struct {
    kind: VariantKind,
    count: u8,
    period_frames: u8,
    edge_rules: [4]CompiledEdgeRule = undefined,
    edge_rules_len: u8 = 0,
};

/// Parses 3x3 pattern string into bitmask and value mask.
fn parsePattern(pattern_str: []const u8) struct { mask: u8, value: u8 } {
    var mask: u8 = 0;
    var value: u8 = 0;
    var idx: usize = 0;

    for (pattern_str) |ch| {
        if (ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t') continue;
        if (idx >= 9) break;

        if (idx != 4) {
            const col: i8 = @as(i8, @intCast(idx % 3)) - 1;
            const row: i8 = @as(i8, @intCast(idx / 3)) - 1;
            const bitmask = dw.types.EdgeFlags.getFlagBit(col, row);

            switch (ch) {
                '#', '1', 'S' => {
                    mask |= bitmask;
                    value |= bitmask;
                },
                '.', '0', 'A' => {
                    mask |= bitmask;
                },
                '?', '*', 'X' => {},
                else => @compileError("invalid character in edge pattern"),
            }
        }
        idx += 1;
    }

    if (idx != 9) @compileError("edge pattern must contain 9 cells");
    return .{ .mask = mask, .value = value };
}

/// Sparse-to-dense lookup: sprite ID -> its compiled rule, or null. One indexed load at runtime.
const variant_table: [dw.sprite.MAX_SPRITE_ID]?CompiledRule = blk: {
    @setEvalBranchQuota(20000);
    var table: [dw.sprite.MAX_SPRITE_ID]?CompiledRule = @splat(null);
    for (rules) |entry| {
        const base = @intFromEnum(entry[0]);
        const rule = entry[1];
        if (rule.kind == .animate and rule.period_frames < 1) @compileError("animate period_frames must be >= 1");

        var compiled = CompiledRule{
            .kind = rule.kind,
            .count = rule.count,
            .period_frames = rule.period_frames,
            .edge_rules_len = @intCast(rule.edge_rules.len),
        };

        if (rule.edge_rules.len > 4) @compileError("maximum 4 edge rules allowed per sprite");

        for (rule.edge_rules, 0..) |edge, i| {
            const parsed = parsePattern(edge.pattern);
            compiled.edge_rules[i] = .{
                .mask = parsed.mask,
                .value = parsed.value,
                .offset = edge.offset,
                .kind = edge.kind,
                .count = edge.count,
            };
        }

        table[base] = compiled;
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
        const rule = entry[1];

        var max_span: u16 = rule.count;
        for (rule.edge_rules) |edge| {
            const span = edge.offset + edge.count;
            if (span > max_span) max_span = span;
        }

        if (base + max_span - 1 > dw.sprite.max_sprite_value)
            @compileError("Variant frames extend past the last sprite ID");

        for (base + 1..base + max_span) |frame| {
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

/// Picks a weighted variant offset from a block seed (see `random`).
fn seedPick(seed: u32, count: u8) u16 {
    const bits_needed = std.math.log2_int_ceil(u8, count);
    const mixed = murmurmix32(murmurmix32(seed));
    const mask = (@as(u32, 1) << @intCast(bits_needed)) - 1;
    const raw = (mixed >> 16) & mask;
    return if (raw >= count) 0 else @intCast(raw);
}

/// Resolves the final atlas sprite ID for a block, applying positional, seed-based, or time-based (animation) variation.
/// `tx`/`ty` are ABSOLUTE tile coordinates; `frame` is the current render frame.
/// Returns `block.id` unchanged when the sprite has no variation rule.
pub fn resolveVariant(block: Block, tx: u64, ty: u64, frame: u32) Sprite {
    // while spectating, a block flagged as holding a deeper modification is drawn as a solid marker
    if (block.descendant_mods) return .inventory_selected_orange;

    var id = block.id;
    // special hardcode for campfire
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

    var base_offset: u16 = 0;
    var active_kind = rule.kind;
    var active_count = rule.count;

    // evaluate edge rules in priority order
    for (rule.edge_rules[0..rule.edge_rules_len]) |edge| {
        if ((edge_flags & edge.mask) == edge.value) {
            base_offset = edge.offset;
            active_kind = edge.kind;
            active_count = edge.count;
            break;
        }
    }

    if (active_count <= 1) return @enumFromInt(id + base_offset);

    // calculate variant offset
    const sub_offset: u16 = switch (active_kind) {
        .grid_2x2 => @intCast(((ty & 1) << 1) | (tx & 1)),
        .checkerboard => @intCast((tx & 1) ^ (ty & 1)),
        .x_parity => @intCast(tx & 1),
        .y_parity => @intCast(ty & 1),
        .random => seedPick(seed, active_count),
        .animate => @intCast((frame / rule.period_frames) % active_count),
        .default => 0,
    };

    return @enumFromInt(id + base_offset + sub_offset);
}
