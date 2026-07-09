//! Handles lower-level procedural logic by handling debug constants (such as gem odds and FBM size) as well as noise-based functions.
//! Higher-level logic exists within `world.generateBaseChunk()`.
const std = @import("std");
const dw = @import("../root.zig");
const types = dw.types;
const logger = dw.logger;
const memory = dw.memory;
const seeding = dw.seeding;
const world = dw.world;

const POW_2_32 = seeding.POW_2_32;
const INV_POW_2_32 = seeding.INV_POW_2_32;
const POW_2_64 = seeding.POW_2_64;
const CHUNK_SIZE = dw.CHUNK_SIZE;

const Sprite = dw.Sprite;
const EdgeFlags = types.EdgeFlags;
const oddsNum = seeding.oddsNum;
const FastHash = seeding.FastHash;
const Seed = seeding.Seed;
const Vec2f = dw.utils.Vec2f;
const Vec2u = dw.utils.Vec2u;
const Vec4u = dw.utils.Vec4u;

// Lots of values controllable by debug sliders here!
pub const dual_value_scale = TuningFloat(16.0);
pub const base_gem_odds = TuningFloat(0.25);
pub const procedural_cell_size = TuningFloat(1.0);
pub const fbm_scale = TuningFloat(1.0);
pub const density_min = TuningFloat(0.36);
pub const density_max = TuningFloat(0.94);
pub const hybrid_weight = TuningFloat(0.6);

/// Generates a block for seeding (based on previous procedural generation logic).
/// The terms moisture/density are used extremely loosely here.
/// Moisture is over a larger area, acting as the "biome" for structure logic.
pub fn generateBaseProceduralSprite(moisture: f64, density: f64) Sprite {
    // check is_debug because these will always be off in non-dev
    // sprite IDs in this range create a heatmap
    if (dw.is_debug and USE_BASE_HEATMAP and !USE_ORE_HEATMAP)
        return @enumFromInt(65000 + @as(u20, @intFromFloat(moisture * 256.0)));
    if (dw.is_debug and USE_BASE_HEATMAP and USE_ORE_HEATMAP) return .stone;

    if (density <= density_min.getF32() or density >= density_max.getF32()) {
        if (moisture >= 0.93 and moisture <= 0.94) return .purple_strange_stone;
        return .none;
    } else if (density <= 0.04 and moisture >= 0.3 and moisture <= 0.4) {
        return .blue_strange_stone;
    }

    if (moisture >= 0.995) return .stone;
    if (moisture >= 0.98 and moisture < 0.995) return .ancient_stone;
    if (moisture >= 0.93 and moisture <= 0.94) return .red_stone;
    if (moisture >= 0.9) return .none;

    if (moisture >= 0.88 and moisture <= 0.92) return .lava_stone;
    if (moisture >= 0.50 and density >= 0.53 and density <= 0.6) return .green_stone;

    if (moisture >= 0.62 and density >= 0.83) return .seagreen_stone;
    if (moisture <= 0.55 and density >= 0.60 and density <= 0.72) return .blue_stone;
    if (density >= 0.40 and density <= 0.55) return .deep_blue_stone;

    if (moisture >= 0.20 and moisture <= 0.26) return .mossy_stone;
    return .stone;
}

/// Returns a struct with an a `value: f64` and `getF32()`.
/// Allows for numbers to act like variables in Debug mode and constant-fold in all Release modes.
inline fn TuningFloat(comptime default_value: f64) type {
    if (dw.is_debug) {
        return struct {
            pub var value: f64 = default_value;
            pub inline fn getF32() f32 {
                return @floatCast(value);
            }
        };
    } else {
        return struct {
            pub const value: f64 = default_value;
            pub inline fn getF32() f32 {
                return @floatCast(value);
            }
        };
    }
}

/// Returns a struct with an a `value: bool`. (TODO: switch to using this instead of current USE_...heatmap logic.)
/// Allows for booleans to act like variables in Debug mode and dead code elimination in all Release modes.
inline fn TuningBool(comptime default_value: bool) type {
    if (dw.is_debug) {
        return struct {
            pub var value: bool = default_value;
        };
    } else {
        return struct {
            pub const value: bool = default_value;
        };
    }
}

/// Determines whether to use a heatmap or not for base terrain. Ignored if `dw.is_debug` is false.
pub var USE_BASE_HEATMAP = false;
/// Determines whether to use a heatmap or not for ore generation. Ignored if `dw.is_debug` is false.
pub var USE_ORE_HEATMAP = false;

/// Configuration options passed to the FBM (Fractal Brownian Motion) and Worley
/// noise generation algorithm (`getFbmValue()`).
const TerrainOptions = struct {
    /// Controls the scale of the primary noise grid cells.
    /// Larger values stretch out the noise patterns.
    cell_size: comptime_float,

    /// The maximum offset distance applied during the FBM domain warping step.
    /// Higher values cause more severe "displacement" or squiggly distortion in the terrain.
    /// Setting this to 0 eliminates any distortion.
    fbm_shift_size: comptime_float,

    /// When true, stretches out the vertical sampling coordinates by a factor of 2 (horizontal stretching of 2x).
    horizontally_wide: bool = false,

    /// Determines whether the algorithm computes true Worley cellular noise metrics (F2 - F1 distance).
    ///
    /// - If true, performs an optimized 4-tap cellular distance check (essential for jagged cave walls or sharp ore veins).
    /// - If false, bypasses cellular logic entirely and falls back to a much faster, basic bilinear value noise interpolation.
    use_f2_f1: bool = true,
};

/// Temporary data produced during the first pass of structural generation.
const BaseTerrainData = struct {
    sprite: Sprite,
    moisture: f32,
    density: f32,
};

/// Adds larger structures across multiple blocks in a deterministic fashion.
/// Continues from steps 1-3 in `getBaseSpriteType()`.
///
/// 4. Disperses ores using Worley noise. Assumes that `isStone()` was checked before calling.
pub fn addStructures(
    starting_sprite: Sprite,
    wx: u32,
    wy: u32,
    struct_seed: Vec2u,
) dw.structures.StructureResult {
    return dw.structures.addStructures(starting_sprite, wx, wy, struct_seed);
}

/// One memoized base-terrain sample, keyed by absolute world block (`wx`, `wy`).
const BaseTerrainCacheEntry = struct {
    wx: u32 = 0,
    wy: u32 = 0,
    data: BaseTerrainData = undefined,
    occupied: bool = false,
};

/// Direct-mapped cache of `computeBaseSpriteType()` results (must be a power of two).
/// The same cell is recomputed many times per chunk gen (pass 1, the edge-flag halo, the vine scan, and structure terrain gates all resample it, plus overlap across neighbors), so memoizing removes that FBM redundancy: the dominant generation cost.
/// Release-only: in debug the `TuningFloat` sliders mutate FBM output live, so debug always recomputes.
const BASE_CACHE_SLOTS = 8192;
var base_terrain_cache: [BASE_CACHE_SLOTS]BaseTerrainCacheEntry = @splat(.{});
/// Current seed the cache holds; a mismatch (reseed) invalidates every entry at once.
var base_cache_key: u64 = 0;

/// Direct-mapped slot for a world block; mixes the coords so adjacent cells do not collide.
inline fn baseCacheIndex(wx: u32, wy: u32) usize {
    const h = (@as(u64, wx) *% 0x9E3779B97F4A7C15) ^ (@as(u64, wy) *% 0x85EBCA77C2B2AE63);
    return @intCast((h >> 32) & (BASE_CACHE_SLOTS - 1));
}

/// Returns a base sprite type, memoized in release (see `BASE_CACHE_SLOTS`). Does 3 passes:
///
/// 1. Generate an initial terrain density+moisture value using the seed vectors.
/// 2. Generate a block from those values.
/// 3. Generates larger structures with FBM Worley and valid placement checks.
pub fn getBaseSpriteType(
    chunk_x: u32,
    chunk_y: u32,
    block_x: u4,
    block_y: u4,
) BaseTerrainData {
    // Debug drags terrain sliders live, so caching would serve stale samples; always recompute there.
    if (dw.is_debug) return computeBaseSpriteType(chunk_x, chunk_y, block_x, block_y);

    const wx = chunk_x * 16 + block_x;
    const wy = chunk_y * 16 + block_y;

    const seed = memory.game.getHashSeed(.moisture);
    const key = seed[0] ^ seed[1];
    if (key != base_cache_key) {
        base_terrain_cache = @splat(.{});
        base_cache_key = key;
    }

    const entry = &base_terrain_cache[baseCacheIndex(wx, wy)];
    if (entry.occupied and entry.wx == wx and entry.wy == wy) return entry.data;

    const data = computeBaseSpriteType(chunk_x, chunk_y, block_x, block_y);
    entry.* = .{ .wx = wx, .wy = wy, .data = data, .occupied = true };
    return data;
}

/// Uncached base-terrain evaluation. Call `getBaseSpriteType()` instead outside of the cache itself.
fn computeBaseSpriteType(
    chunk_x: u32,
    chunk_y: u32,
    block_x: u4,
    block_y: u4,
) BaseTerrainData {
    const moisture = getFbmValue( // acts as a biome selector
        memory.game.getHashSeed(.moisture),
        chunk_x * 16 + block_x,
        chunk_y * 16 + block_y,
        .{
            .cell_size = 425.0, // very LARGE cells for biome generation
            .fbm_shift_size = 20.0, // minimize shift potential
            .horizontally_wide = false,
        },
    );
    const density = getFbmValue( // more granular density
        memory.game.getHashSeed(.density),
        chunk_x * 16 + block_x,
        chunk_y * 16 + block_y,
        .{
            .cell_size = 80.0, // smaller cells for cave terrain
            .fbm_shift_size = 24.0,
            .horizontally_wide = true,
            .use_f2_f1 = true,
        },
    );

    const sprite = generateBaseProceduralSprite(moisture, density);

    return .{
        .sprite = sprite,
        .moisture = moisture,
        .density = density,
    };
}

/// Generates ores over certain types of blocks, returning a sprite type (possibly changed to an ore type).
/// Continues from step 4 in `getStructureBlock()`.
///
/// 5. Disperses ores using Worley noise. Assumes that `isStone()` was checked before calling.
pub fn addOresAndGems(
    base_data: BaseTerrainData,
    x: u32,
    y: u32,
) Sprite {
    var s = base_data.sprite;
    const game = &memory.game;

    // Generate new density for ores with a DIFFERENT set of 4 seed vectors (sent as args!)
    const v1 = getFbmValue( // smaller cells, less FBM variation
        game.getHashSeed(.ores1),
        x,
        y,
        .{
            .cell_size = 21.0,
            .fbm_shift_size = 8.0,
            .horizontally_wide = false,
            .use_f2_f1 = true,
        },
    );
    const v2 = getFbmValue( // larger cells, much more FBM variation
        game.getHashSeed(.ores2),
        x,
        y,
        .{
            .cell_size = 36.0,
            .fbm_shift_size = 60.0,
            .horizontally_wide = false,
            .use_f2_f1 = true,
        },
    );

    // sprite IDs in this range use a neat heatmap (using only the first variation value), overriding normal ore logic
    if (dw.is_debug and USE_ORE_HEATMAP) return @enumFromInt(65000 + @as(u20, @intFromFloat(v1 * 256.0)));

    if (base_data.density >= 0.45 and base_data.density <= 0.65) {
        // Generate various ore types
        s = selectSprite(
            .{ s, .copper },
            true,
            .{ v2, 0.0, 0.04 },
        );
        s = selectSprite(
            .{ s, .copper },
            true,
            .{ v2, 0.9, 0.93 },
        );
        if (s == .copper) return s;

        s = selectSprite(
            .{ s, .iron },
            base_data.sprite != .blue_strange_stone,
            .{ v1, 0.55, 0.595 },
        );
        if (s == .iron) return s;

        s = selectSprite(
            .{ s, .silver },
            base_data.density <= 0.48,
            .{ v1, 0.2, 0.25 },
        );
        s = selectSprite(
            .{ s, .silver },
            base_data.sprite == .blue_strange_stone,
            .{ v1, 0.18, 0.2 },
        );
        if (s == .silver) return s;

        s = selectSprite(
            .{ s, .gold },
            base_data.density >= 0.63 or (base_data.density >= 0.59 and base_data.sprite == .lava_stone),
            .{ v2, 0.3, 0.36 },
        );
        if (s == .gold) return s;

        s = selectSprite(
            .{ s, .nickel },
            true,
            .{ v2, 0.58, 0.595 },
        );
        if (s == .nickel) return s;

        s = selectSprite(
            .{ s, .cobalt },
            v2 > 0.7,
            .{ v1, 0.94, 0.98 },
        );
        if (s == .cobalt) return s;
    } else {
        // Logic for generating gems
        const gem_v2_bound: f32 = if (s == .purple_strange_stone) 0.4 else 0.3;
        if (base_data.density >= 0.3 and base_data.density <= 0.5 and v2 >= 0.1 and v2 <= gem_v2_bound) {
            const random_value = FastHash.float2d(game.getHashSeed(.ores3), @intCast(x), @intCast(y));

            if (random_value <= base_gem_odds.value) {
                const v3 = getFbmValue(
                    game.getHashSeed(.ores4),
                    y,
                    x,
                    .{
                        .cell_size = 35.0,
                        .fbm_shift_size = 0.0,
                        .horizontally_wide = false,
                        .use_f2_f1 = false,
                    },
                );
                const v4 = getFbmValue(
                    game.getHashSeed(.ores5),
                    y,
                    x,
                    .{
                        .cell_size = 45.0,
                        .fbm_shift_size = 18.0,
                        .horizontally_wide = false,
                        .use_f2_f1 = false,
                    },
                );

                s = selectSprite(
                    .{ s, .quartz },
                    v4 <= 0.24 and random_value <= 0.34 * base_gem_odds.value,
                    null,
                );
                if (s == .quartz) return s;

                if (s != .deep_blue_stone) { // this stone type has too much visual similarity
                    s = selectSprite(
                        .{ s, .amethyst },
                        v3 <= 0.4 and random_value <= 0.7 * base_gem_odds.value,
                        null,
                    );
                    if (s == .amethyst) return s;

                    s = selectSprite(
                        .{ s, .sapphire },
                        v3 >= 0.75 and random_value <= 0.65 * base_gem_odds.value,
                        null,
                    );
                    if (s == .sapphire) return s;
                }

                s = selectSprite(
                    .{ s, .emerald },
                    v4 >= 0.45 and v4 <= 0.48 and random_value <= 0.86 * base_gem_odds.value,
                    null,
                );
                if (s == .emerald) return s;

                s = selectSprite(
                    .{ s, .ruby },
                    v3 >= 0.22 and v3 <= 0.24,
                    null,
                );
                if (s == .ruby) return s;

                s = selectSprite(
                    .{ s, .electrit },
                    v3 >= 0.84 and v3 <= 0.85,
                    null,
                );
                if (s == .ruby) return s;
            }
        }
    }

    return s;
}

/// Represents 3 values: `v`, `min`, and `max`.
const ValueRange = struct { f32, f32, f32 };

/// Represents 2 sprites: `old_sprite` and `new_sprite`.
const SpritePair = struct { Sprite, Sprite };

/// Reads like a sentence: returns the new sprite if condition holds and v is between min and max, but the old sprite otherwise.
///
/// Technical definition: returns the second `Sprite` in the pair if `condition` is satisfied `range[0]` falls within `range[1]`.
/// Returns the first `Sprite` otherwise.
///
/// Example usage:
/// ```zig
/// // Returns iron if density is larger than 0.6 AND my_value is between 0.6 and 0.7 (inclusive), and stone otherwise.
/// Sprite sprite = cw(.iron, my_density >= 0.6, my_value, 0.6, 0.7, .stone);
/// ```
pub inline fn selectSprite(sprites: SpritePair, condition: bool, range: ?ValueRange) Sprite {
    const old_sprite = sprites[0];
    const new_sprite = sprites[1];
    if (range) |val| {
        const v = val[0];
        const min = val[1];
        const max = val[2];
        std.debug.assert(min <= max);
        return if (condition and v >= min and v <= max) new_sprite else old_sprite;
    } else {
        return if (condition) new_sprite else old_sprite;
    }
}

/// Returns true if `v` is between `min` and `max` (inclusive).
pub inline fn isWithin(v: f32, min: comptime_float, max: comptime_float) bool {
    if (max <= min) @compileError("Maximum value must be larger than minimum value.");
    return v >= min and v <= max; // inclusive may mean more aggressive LLVM optimizations when inlining, for free
}

/// Vertical growth direction of a hash-anchored column feature, selecting both its anchoring surface and
/// the direction the world column is traversed by `world.computeColumnSeeds()`/`applyColumnFeature()`.
pub const GrowDir = enum {
    /// Hangs DOWN from a ceiling (foundation above), such as hanging vines. Columns are walked top -> bottom.
    down,
    /// Rises UP from a floor (foundation below), such as reeds/sapling trunks. Columns are walked bottom -> top.
    up,
};

/// Comptime description of a decoration grown by a stateful vertical walk down a single world column
/// (hanging vines, floor reeds, dripstone, ...). The state machine in `stepColumn()` is identical for both
/// directions: it anchors on any foundation and grows into the empty cells past it; only the traversal order
/// and the cross-border seed scan flip with `dir`. Purely position-hashed, so a feature resolves identically
/// on both sides of any chunk border with no neighbor-chunk state.
pub const ColumnFeature = struct {
    /// Block written into an empty cell the feature claims.
    sprite: Sprite,
    /// Growth direction; also decides traversal order in the caller.
    dir: GrowDir,
    /// Longest run past the anchor, in blocks. Bounds the cross-border scan to this many rows.
    /// Must stay < 2 * CHUNK_SIZE so the scan only ever reaches the two neighbor chunks in that direction.
    max_length: u32,
    /// Chance the feature spawns in the cell immediately past its anchoring surface.
    anchor_odds: f64,
    /// Chance the feature extends one more cell past its previous segment.
    grow_odds: f64,
    /// Position-hash seed category for the anchor roll.
    anchor_seed: memory.SeedType = .decorations1,
    /// Position-hash seed category for the growth roll.
    grow_seed: memory.SeedType = .decorations2,
    /// Comptime salt XORed into every roll so two features sharing a `SeedType` never anchor on the same cells.
    /// Keep 0 for the original hanging vine so its determinism is unchanged.
    salt: u64 = 0,
};

/// Compile-time invariant check for a `ColumnFeature`. Call from a comptime block per instance/use.
pub fn assertColumnFeature(comptime f: ColumnFeature) void {
    if (f.max_length >= 2 * CHUNK_SIZE)
        @compileError("ColumnFeature.max_length must stay < 2 * CHUNK_SIZE so the cross-border scan reaches at most the two neighbor chunks.");
}

/// Carried state for a column feature's walk down (or up) a single world column.
/// Seeded across the chunk border by `world.computeColumnSeeds()`, then advanced per cell by `stepColumn()`.
pub const ColumnState = struct {
    /// The feature is currently growing and has reached the cell adjacent to the one being evaluated.
    alive: bool = false,
    /// Cells past the anchoring surface so far (1 = directly adjacent to it); capped by `ColumnFeature.max_length`.
    depth: u32 = 0,
};

/// True if the surface at world (wx, wy) anchors feature `f` in the cell directly past it.
inline fn columnAnchorHit(comptime f: ColumnFeature, wx: u64, wy: u64) bool {
    return FastHash.hash2d(memory.game.getHashSeed(f.anchor_seed), wx ^ f.salt, wy) <= oddsNum(f.anchor_odds);
}

/// True if feature `f` extends into the empty cell at world (wx, wy).
inline fn columnGrowHit(comptime f: ColumnFeature, wx: u64, wy: u64) bool {
    return FastHash.hash2d(memory.game.getHashSeed(f.grow_seed), wx ^ f.salt, wy) <= oddsNum(f.grow_odds);
}

/// Advances feature `f`'s state machine by one cell while scanning a world column in its growth direction.
/// `is_solid` marks a foundation cell, which acts as an anchoring surface for anything growing past it.
/// Returns true when the feature should occupy this (empty) cell.
pub fn stepColumn(comptime f: ColumnFeature, state: *ColumnState, wx: u64, wy: u64, is_solid: bool) bool {
    comptime assertColumnFeature(f);
    if (is_solid) {
        // this foundation cell anchors any feature growing directly past it
        state.alive = columnAnchorHit(f, wx, wy);
        state.depth = 0;
        return false;
    }
    if (!state.alive) return false;
    state.depth += 1;
    // depth 1 (directly past the surface) is governed solely by the anchor roll;
    // deeper cells each roll an independent growth continuation, capped at max_length.
    if (state.depth > 1 and (state.depth > f.max_length or !columnGrowHit(f, wx, wy))) {
        state.alive = false;
        return false;
    }
    return true;
}

/// The original hanging vine (spiral plant), expressed as a downward `ColumnFeature`.
/// `salt = 0` and the historic `.decorations1`/`.decorations2` seeds keep its output bit-identical.
pub const vine_feature: ColumnFeature = .{
    .sprite = .spiral_plant,
    .dir = .down,
    .max_length = 20,
    .anchor_odds = 0.02,
    .grow_odds = 0.7,
};

/// Longest a hanging vine may extend below its ceiling anchor, in blocks. Retained for external references.
pub const MAX_VINE_LENGTH: u32 = vine_feature.max_length;

/// Back-compat alias/wrappers so existing vine call sites need no changes.
pub const VineState = ColumnState;
pub fn stepVine(state: *ColumnState, wx: u64, wy: u64, is_solid: bool) bool {
    return stepColumn(vine_feature, state, wx, wy, is_solid);
}

/// Generates decorative blocks (such as mushrooms or ceiling plants).
/// Continues from step 5 in `addOres()`.
///
/// Hanging vines (spiral plant) are traced per column and cross chunk borders seamlessly: `vine_seeds[bx]`
/// carries the vine state entering the top of each column from `world.computeVineSeeds()`.
/// `chunk_x`/`chunk_y` are this chunk's base-depth suffix coords, used for absolute world positions.
///
/// 6. Adds blocks, primarily decorations, that require certain anchor types (`AnchorKind` in types/sprite.zig).
pub fn addDecorations(
    target_chunk: *memory.Chunk,
    rng_decor: *seeding.ChaCha12,
    chunk_x: u64,
    chunk_y: u64,
    vine_seeds: *const [CHUNK_SIZE]VineState,
) void {
    // First, we handle blocks with a floor anchor kind.
    for (0..CHUNK_SIZE) |block_y| {
        var forced_next_sprite_type: Sprite = .none; // .none means nothing is forced
        for (0..CHUNK_SIZE) |block_x| {
            const idx = block_x + block_y * CHUNK_SIZE;
            var block = &target_chunk.blocks[idx];
            if (forced_next_sprite_type != .none) {
                // semantically, .none makes sense, simply an alternative to optional type
                block.id = forced_next_sprite_type;
                forced_next_sprite_type = .none;
                continue;
            }

            if (!block.isEmpty()) continue;
            // Check calculated bitmask directly to avoid isAdjacentBlockSolid logic discrepancies
            if ((block.edge_flags & types.EdgeFlags.BOTTOM) != 0) {
                const val = rng_decor.next();

                // Only initiate 2x1 tree placement on even columns to prevent asymmetric overwrites
                if (block_x % 2 == 0 and block_x != CHUNK_SIZE - 1) {
                    const other_block_x = block_x + 1;
                    const other_block = &target_chunk.blocks[other_block_x + block_y * CHUNK_SIZE];
                    if (other_block.isEmpty() and ((other_block.edge_flags & types.EdgeFlags.BOTTOM) != 0)) {
                        if (val >= oddsNum(0.98)) {
                            block.id = .moss_shrub1;
                            forced_next_sprite_type = .moss_shrub1_right;
                            continue;
                        } else if (val >= oddsNum(0.97)) {
                            block.id = .moss_shrub2;
                            forced_next_sprite_type = .moss_shrub2_right;
                            continue;
                        }
                    }
                }

                if (val <= oddsNum(0.030)) {
                    block.id = .bush;
                } else if (val <= oddsNum(0.060)) {
                    block.id = .rock;
                } else if (val <= oddsNum(0.073)) {
                    block.id = .small_tree;
                } else if (val <= oddsNum(0.093)) {
                    block.id = .mushroom;
                } else if (val <= oddsNum(0.098)) {
                    block.id = .campfire;
                } else if (val <= oddsNum(0.104)) {
                    block.id = .forest_furnace;
                } else if (val <= oddsNum(0.108)) {
                    block.id = .lava_furnace;
                } else if (val <= oddsNum(0.120)) {
                    block.id = .basic_core;
                }
            }
        }
    }

    // fused vine + ceiling-flower pass: one top-to-bottom walk per column instead of two full sweeps.
    // vines are position-hashed so they cross borders seamlessly; the flower is rolled after the vine step and
    // gated on emptiness so a vine keeps priority. flowers now consume rng_decor column-major (was row-major),
    // which reshuffles which cells flower but stays deterministic.
    for (0..CHUNK_SIZE) |block_x| {
        var state = vine_seeds[block_x];
        const wx: u64 = chunk_x * CHUNK_SIZE + block_x;
        for (0..CHUNK_SIZE) |block_y| {
            var block = &target_chunk.blocks[block_x + block_y * CHUNK_SIZE];
            const wy: u64 = chunk_y * CHUNK_SIZE + block_y;

            const place_vine = stepColumn(vine_feature, &state, wx, wy, block.isFoundation());
            if (place_vine and block.isEmpty()) {
                block.id = vine_feature.sprite;
                continue;
            }
            if (!block.isEmpty()) continue;
            // Direct bitmask query to bypass isAdjacentBlockSolid inconsistencies
            if ((block.edge_flags & types.EdgeFlags.TOP) != 0 and rng_decor.next() <= oddsNum(0.15)) {
                block.id = .ceiling_flower;
            }
        }
    }

    // final pass to reset edge flags for blocks that should NOT be eroded
    // update: now logic is in chunk.zig
    // for (0..dw.CHUNK_SIZE_SQ) |id| {
    //     var block = &target_chunk.blocks[id];
    //     if (!block.isFoundation()) block.edge_flags = 0xFF;
    // }
}

/// Stamps a `ColumnFeature` into `target_chunk`, walking each column in the feature's growth direction with
/// the per-column state that entered this chunk (`seeds[bx]`, from `world.computeColumnSeeds()`).
/// Writes only into empty cells so a feature never clobbers a floor/ceiling decoration it passes through.
/// Downward features walk top -> bottom; upward features walk bottom -> top (see `GrowDir`).
pub fn applyColumnFeature(
    comptime f: ColumnFeature,
    target_chunk: *memory.Chunk,
    seeds: *const [CHUNK_SIZE]ColumnState,
    chunk_x: u64,
    chunk_y: u64,
) void {
    comptime assertColumnFeature(f);
    for (0..CHUNK_SIZE) |block_x| {
        var state = seeds[block_x];
        const wx: u64 = chunk_x * CHUNK_SIZE + block_x;
        for (0..CHUNK_SIZE) |i| {
            // enter from the anchoring side: top for downward growth, bottom for upward growth
            const block_y = switch (f.dir) {
                .down => i,
                .up => CHUNK_SIZE - 1 - i,
            };
            var block = &target_chunk.blocks[block_x + block_y * CHUNK_SIZE];
            const wy: u64 = chunk_y * CHUNK_SIZE + block_y;
            const place = stepColumn(f, &state, wx, wy, block.isFoundation());
            if (place and block.isEmpty()) block.id = f.sprite;
        }
    }
}

// Keep the generic stamper analyzed for both directions even though live vines fuse with the flower pass.
comptime {
    _ = &applyColumnFeature;
}

/// Quintic fade 6t^5 - 15t^4 + 10t^3 (Perlin's smootherstep): zero 1st AND 2nd derivative at 0/1.
inline fn fade(t: f32) f32 {
    // Alternative: -20t^7 + 70t^6 - 84t^5 + 35t^4.
    // const u = tx * tx * tx * tx * (tx * (tx * (35.0 - 20.0 * tx) - 84.0) + 70.0);
    // const v = ty * ty * ty * ty * (ty * (ty * (35.0 - 20.0 * ty) - 84.0) + 70.0);
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

/// A highly optimized bilinear value noise implementation.
/// Bypasses domain warping and multi-tap cellular distance lookups entirely.
///
/// Use for: basic, boring but fast noise.
fn getBilinearValueNoise(seed_vector: Vec2u, x: u32, y: u32, cell_size: f32) f32 {
    const fx = @as(f32, @floatFromInt(x)) / cell_size;
    const fy = @as(f32, @floatFromInt(y)) / cell_size;

    const x0 = @floor(fx);
    const y0 = @floor(fy);
    const tx = fx - x0;
    const ty = fy - y0;

    const ix0: u64 = @intFromFloat(x0);
    const iy0: u64 = @intFromFloat(y0);

    const u = fade(tx);
    const v = fade(ty);

    // Vectorized 4-tap lookup
    const vx: Vec4u = .{ ix0, ix0 +% 1, ix0, ix0 +% 1 };
    const vy: Vec4u = .{ iy0, iy0, iy0 +% 1, iy0 +% 1 };
    const h = FastHash.hash2d_4x(seed_vector, vx, vy);

    // Fast u32 to f32 vector conversion
    const truncated: @Vector(4, u32) = @truncate(h);
    const floats: @Vector(4, f32) = @floatFromInt(truncated);
    const v_vec = floats * @as(@Vector(4, f32), @splat(INV_POW_2_32));

    const v00 = v_vec[0];
    const v10 = v_vec[1];
    const v01 = v_vec[2];
    const v11 = v_vec[3];

    const nx0 = v00 + u * (v10 - v00);
    const nx1 = v01 + u * (v11 - v01);
    return nx0 + v * (nx1 - nx0);
}

/// Returns a value between 0-1, used as a terrain starting point for the default depth of 3.
/// Note that if F2-F1 calculations are not requested, `getPerlinNoise()` is called after FBM.
/// If F2-F1 calculations are requested, then Worley noise is used instead.
///
/// Use for: terraced blocks, cellular clusters, and erosion basins.
fn getFbmValue(seed_vector: Vec2u, x: u32, y: u32, comptime options: TerrainOptions) f32 {
    if (!options.use_f2_f1) {
        // Excellent for sharp branching networks and rich ore veins
        return fbm(getPerlinNoise, seed_vector, x, y, options.cell_size, 3);
    }

    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(if (options.horizontally_wide) y * 2 else y);

    const h_stretch = 1.5;
    const fbm_octaves = 3;
    var warp_x: f32 = 0;
    var warp_y: f32 = 0;

    var freq: u64 = 1;
    var amp: f32 = options.fbm_shift_size;

    const inv_fbm_scale = 1.0 / fbm_scale.getF32();
    const inv_dual_value_scale = 1.0 / dual_value_scale.getF32();
    amp *= inv_fbm_scale;

    if (amp > 0) {
        inline for (0..fbm_octaves) |_| {
            const n = getDualValueNoise(seed_vector, x * freq, y * freq, inv_dual_value_scale);
            warp_x += n[0] * amp;
            warp_y += n[1] * amp;
            amp *= 0.55; // 55%, not 50%!
            freq *%= 2;
        }
    }

    const cell_size = options.cell_size * procedural_cell_size.getF32();
    const inv_cell_size = 1.0 / cell_size;
    const cell_w = cell_size * h_stretch;
    const inv_cell_w = 1.0 / cell_w;

    const wx = fx + warp_x;
    const wy = fy + warp_y;

    // Fast division-free float-to-int mapping
    const cx_f = @floor(wx * inv_cell_w);
    const cy_f = @floor(wy * inv_cell_size);
    const cx_i: i64 = @intFromFloat(cx_f);
    const cy_i: i64 = @intFromFloat(cy_f);

    var d1_sq = std.math.inf(f32);
    var d2_sq = std.math.inf(f32);

    // Vectorized 4-tap Worley grid search
    const ox_vec: Vec4u = .{ 0, 0, 1, 1 };
    const oy_vec: Vec4u = .{ 0, 1, 0, 1 };
    const cur_x_vec: Vec4u = @bitCast(@as(@Vector(4, i64), @splat(cx_i)) + @as(@Vector(4, i64), @bitCast(ox_vec)));
    const cur_y_vec: Vec4u = @bitCast(@as(@Vector(4, i64), @splat(cy_i)) + @as(@Vector(4, i64), @bitCast(oy_vec)));

    const h_vec = FastHash.hash2d_4x(seed_vector, cur_x_vec, cur_y_vec);

    const truncated_x: @Vector(4, u32) = @truncate(h_vec);
    const truncated_y: @Vector(4, u32) = @truncate(h_vec >> @splat(32));

    const off_x_vec = @as(@Vector(4, f32), @floatFromInt(truncated_x)) * @as(@Vector(4, f32), @splat(INV_POW_2_32));
    const off_y_vec = @as(@Vector(4, f32), @floatFromInt(truncated_y)) * @as(@Vector(4, f32), @splat(INV_POW_2_32));

    const cx_f_vec: @Vector(4, f32) = .{
        @floatFromInt(cx_i),
        @floatFromInt(cx_i),
        @floatFromInt(cx_i + 1),
        @floatFromInt(cx_i + 1),
    };
    const cy_f_vec: @Vector(4, f32) = .{
        @floatFromInt(cy_i),
        @floatFromInt(cy_i + 1),
        @floatFromInt(cy_i),
        @floatFromInt(cy_i + 1),
    };

    const px_vec = (cx_f_vec + off_x_vec) * @as(@Vector(4, f32), @splat(cell_w));
    const py_vec = (cy_f_vec + off_y_vec) * @as(@Vector(4, f32), @splat(cell_size));

    const dx_vec = @as(@Vector(4, f32), @splat(wx)) - px_vec;
    const dy_vec = @as(@Vector(4, f32), @splat(wy)) - py_vec;
    const dist_sq_vec = dx_vec * dx_vec + dy_vec * dy_vec;

    inline for (0..4) |i| {
        const dist_sq = dist_sq_vec[i];
        if (dist_sq < d1_sq) {
            d2_sq = d1_sq;
            d1_sq = dist_sq;
        } else if (dist_sq < d2_sq) {
            d2_sq = dist_sq;
        }
    }

    return @min((@sqrt(d2_sq) - @sqrt(d1_sq)) * inv_cell_size, 1.0);
}

/// Returns two independent noise values (32-bit float) using vectorized 4-corner value noise.
///
/// Use for: distorting other noise functions.
fn getDualValueNoise(seed: Vec2u, x: u64, y: u64, inv_scale: f32) dw.utils.Vec2f32 {
    const fx_raw = @as(f32, @floatFromInt(x)) * inv_scale;
    const fy_raw = @as(f32, @floatFromInt(y)) * inv_scale;

    const x0_f = @floor(fx_raw);
    const y0_f = @floor(fy_raw);
    const x0: u64 = @intFromFloat(x0_f);
    const y0: u64 = @intFromFloat(y0_f);

    const tx = fx_raw - x0_f;
    const ty = fy_raw - y0_f;

    // Use fade curves
    const u = fade(tx);
    const v = fade(ty);

    // Prepare 4 corners: (x0, y0), (x0+1, y0), (x0, y0+1), (x0+1, y0+1)
    const vx: Vec4u = .{ x0, x0 +% 1, x0, x0 +% 1 };
    const vy: Vec4u = .{ y0, y0, y0 +% 1, y0 +% 1 };

    // Generate 4 values all at once!
    const h_vec = FastHash.hash2d_4x(seed, vx, vy);

    var res: dw.utils.Vec2f32 = .{ 0, 0 };

    inline for (0..2) |i| {
        const shift: u6 = @intCast(i * 32);
        const shifted = h_vec >> @as(Vec4u, @splat(shift));
        const truncated: @Vector(4, u32) = @truncate(shifted);
        const floats: @Vector(4, f32) = @floatFromInt(truncated);
        const v_vec = floats * @as(@Vector(4, f32), @splat(INV_POW_2_32));

        const v00 = v_vec[0];
        const v10 = v_vec[1];
        const v01 = v_vec[2];
        const v11 = v_vec[3];

        const nx0 = v00 + u * (v10 - v00);
        const nx1 = v01 + u * (v11 - v01);
        res[i] = nx0 + v * (nx1 - nx0);
    }
    return res;
}

/// Normalization factor to push Perlin's ~[-0.71, 0.71] range toward [-1, 1].
pub const PERLIN_NORM: f32 = @sqrt(2.0);

/// Maps a 64-bit hash to a value in [0, 1).
inline fn hashToUnit(h: u64) f32 {
    return @as(f32, @floatFromInt(h)) / POW_2_64;
}

/// 8-direction gradient dot product (classic Perlin gradient set). The low 3 hash bits select the direction;
/// the 4 cardinal + 4 diagonal set is cheap and visually isotropic enough for 2D.
inline fn grad2(h: u64, dx: f32, dy: f32) f32 {
    return switch (@as(u3, @truncate(h))) {
        0 => dx + dy,
        1 => dx - dy,
        2 => -dx + dy,
        3 => -dx - dy,
        4 => dx,
        5 => -dx,
        6 => dy,
        7 => -dy,
    };
}

/// Shared grid setup holding cell coordinates, fractional progression, and pre-computed hashes.
const Lattice = struct {
    x0: u64,
    y0: u64,
    tx: f32,
    ty: f32,
    u: f32,
    v: f32,
    h: Vec4u,
};

inline fn lattice(seed_vector: Vec2u, x: u32, y: u32, cell_size: f32) Lattice {
    const fx = @as(f32, @floatFromInt(x)) / cell_size;
    const fy = @as(f32, @floatFromInt(y)) / cell_size;
    const x0_f = @floor(fx);
    const y0_f = @floor(fy);
    const x0: u64 = @intFromFloat(x0_f);
    const y0: u64 = @intFromFloat(y0_f);
    const tx = fx - x0_f;
    const ty = fy - y0_f;
    const vx: Vec4u = .{ x0, x0 +% 1, x0, x0 +% 1 };
    const vy: Vec4u = .{ y0, y0, y0 +% 1, y0 +% 1 };
    return .{
        .x0 = x0,
        .y0 = y0,
        .tx = tx,
        .ty = ty,
        .u = fade(tx),
        .v = fade(ty),
        .h = FastHash.hash2d_4x(seed_vector, vx, vy),
    };
}

/// Perlin gradient noise. Interpolates corner gradient dot-products instead of raw values,
/// removing value-noise plateaus for smooth, continuous slopes.
///
/// Use for: organic, flowing hills/valleys.
pub fn getPerlinNoise(seed_vector: Vec2u, x: u32, y: u32, cell_size: f32) f32 {
    const l = lattice(seed_vector, x, y, cell_size);
    const n00 = grad2(l.h[0], l.tx, l.ty);
    const n10 = grad2(l.h[1], l.tx - 1.0, l.ty);
    const n01 = grad2(l.h[2], l.tx, l.ty - 1.0);
    const n11 = grad2(l.h[3], l.tx - 1.0, l.ty - 1.0);
    const nx0 = n00 + l.u * (n10 - n00);
    const nx1 = n01 + l.u * (n11 - n01);
    const raw = (nx0 + l.v * (nx1 - nx0)) * PERLIN_NORM;
    return std.math.clamp(raw * 0.5 + 0.5, 0.0, 1.0);
}

/// Sharp ridged noise (`(1 - |perlin|)^2`).
/// Folds the gradient field at zero into crisp ridge lines, then squares to thin them.
///
/// Use for: sharp branching ridges, mineral veins, and fracture lines.
pub fn getRidgedNoise(seed_vector: Vec2u, x: u32, y: u32, cell_size: f32) f32 {
    const signed = getPerlinNoise(seed_vector, x, y, cell_size) * 2.0 - 1.0;
    const r = 1.0 - @abs(signed);
    return r * r;
}

/// Billow noise; effectively `|perlin|`. Bunches the field into rounded puff shapes.
/// Look: cloud/cauliflower clumps and lumpy pockets.
pub fn getBillowNoise(seed_vector: Vec2u, x: u32, y: u32, cell_size: f32) f32 {
    const signed = getPerlinNoise(seed_vector, x, y, cell_size) * 2.0 - 1.0;
    return @abs(signed);
}

/// Hybrid value+gradient. Shares a single set of 4 corner hashes between a value-noise term and gradient term,
/// lerping between them via `hybrid_weight`.
///
/// Use for: biome-related logic.
pub fn getHybridNoise(seed_vector: Vec2u, x: u32, y: u32, cell_size: f32) f32 {
    const l = lattice(seed_vector, x, y, cell_size);

    // Value term calculation
    const v00 = hashToUnit(l.h[0]);
    const v10 = hashToUnit(l.h[1]);
    const v01 = hashToUnit(l.h[2]);
    const v11 = hashToUnit(l.h[3]);
    const val = (v00 + l.u * (v10 - v00)) + l.v * ((v01 + l.u * (v11 - v01)) - (v00 + l.u * (v10 - v00)));

    // Gradient term calculation
    const g00 = grad2(l.h[0], l.tx, l.ty);
    const g10 = grad2(l.h[1], l.tx - 1.0, l.ty);
    const g01 = grad2(l.h[2], l.tx, l.ty - 1.0);
    const g11 = grad2(l.h[3], l.tx - 1.0, l.ty - 1.0);
    const gx0 = g00 + l.u * (g10 - g00);
    const gx1 = g01 + l.u * (g11 - g01);
    const grad = std.math.clamp((gx0 + l.v * (gx1 - gx0)) * PERLIN_NORM * 0.5 + 0.5, 0.0, 1.0);

    const w = hybrid_weight.getF32();
    return val + w * (grad - val);
}

/// Approximate normalization factor for 2D simplex (~70x scaling).
pub const SIMPLEX_NORM: f32 = 70.0;

const F2: f32 = @sqrt(3.0) - 1.0 / 2.0;
const G2: f32 = (3.0 - @sqrt(3.0)) / 6.0;

/// 2D simplex noise. Samples a skewed triangular lattice (3 contributions, radial falloff)
/// to eliminate axis-aligned directional bias.
///
/// Use for: organic, isotropic flow.
pub fn getSimplexNoise(seed_vector: Vec2u, x: u32, y: u32, cell_size: f32) f32 {
    const xin = @as(f32, @floatFromInt(x)) / cell_size;
    const yin = @as(f32, @floatFromInt(y)) / cell_size;

    const s = (xin + yin) * F2;
    const i_f = @floor(xin + s);
    const j_f = @floor(yin + s);
    const t = (i_f + j_f) * G2;
    const x0 = xin - (i_f - t);
    const y0 = yin - (j_f - t);

    // Coordinate check to evaluate which triangular region is sampled
    const off_x: f32 = if (x0 > y0) 1.0 else 0.0;
    const off_y: f32 = if (x0 > y0) 0.0 else 1.0;

    const x1 = x0 - off_x + G2;
    const y1 = y0 - off_y + G2;
    const x2 = x0 - 1.0 + 2.0 * G2;
    const y2 = y0 - 1.0 + 2.0 * G2;

    const ii: u64 = @bitCast(@as(i64, @intFromFloat(i_f)));
    const jj: u64 = @bitCast(@as(i64, @intFromFloat(j_f)));
    const vx: Vec4u = .{ ii, ii +% @as(u64, @intFromFloat(off_x)), ii +% 1, 0 };
    const vy: Vec4u = .{ jj, jj +% @as(u64, @intFromFloat(off_y)), jj +% 1, 0 };
    const h = FastHash.hash2d_4x(seed_vector, vx, vy);

    var n: f32 = 0;
    inline for (.{
        .{ x0, y0, 0 },
        .{ x1, y1, 1 },
        .{ x2, y2, 2 },
    }) |c| {
        const cx = c[0];
        const cy = c[1];
        var tt = 0.5 - cx * cx - cy * cy;
        if (tt > 0) {
            tt *= tt;
            n += tt * tt * grad2(h[c[2]], cx, cy);
        }
    }
    const raw = n * SIMPLEX_NORM;
    return std.math.clamp(raw * 0.5 + 0.5, 0.0, 1.0);
}

/// Generic fractal Brownian motion: stack `octaves` of any candidate noise at halving amplitude and
/// cell size.
pub inline fn fbm(
    comptime noiseFn: fn (Vec2u, u32, u32, f32) f32,
    seed_vector: Vec2u,
    x: u32,
    y: u32,
    cell_size: f32,
    comptime octaves: u32,
) f32 {
    var sum: f32 = 0;
    var amp: f32 = 1.0;
    var norm: f32 = 0;
    var cs: f32 = cell_size;
    inline for (0..octaves) |_| {
        sum += amp * (noiseFn(seed_vector, x, y, cs) - 0.5);
        norm += amp;
        amp *= 0.5;
        cs *= 0.5;
    }
    return std.math.clamp(sum / norm + 0.5, 0.0, 1.0);
}
