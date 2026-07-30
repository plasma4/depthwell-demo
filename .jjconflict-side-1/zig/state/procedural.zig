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
const Vec2f32 = dw.utils.Vec2f32;
const Vec2u = dw.utils.Vec2u;
const Vec4u = dw.utils.Vec4u;
const WorldCoord = seeding.WorldCoord;

// Lots of values controllable by debug sliders here!
pub const dual_value_scale = TuningFloat(21.0);
pub const base_gem_odds = TuningFloat(0.25);
pub const procedural_cell_size = TuningFloat(1.0);
pub const fbm_scale = TuningFloat(1.0);
pub const density_min = TuningFloat(0.36);
pub const density_max = TuningFloat(0.94);
pub const hybrid_weight = TuningFloat(0.6);

const TerrainData = struct {
    sprite: Sprite = .none,
    /// Multiplies the cutoff for stone density.
    cutoff: f32,
    /// Acts as a biome selector.
    moisture: f32,
    /// Base sprite stone details.
    density: f32,
    /// Even finer base sprite details!
    density2: f32,
    /// Ore density.
    ore_density: f32,
    /// Controls whether certain rarer block types spawn.
    weirdness: f32,
};

/// Generates a block for seeding (based on previous procedural generation logic).
pub inline fn generateBaseProceduralSprite(d: *const TerrainData) Sprite {
    // check is_debug because these will always be off in non-dev
    // sprite IDs in this range create a heatmap
    if (dw.is_debug and USE_HEATMAP and !USE_ORE_HEATMAP)
        return @enumFromInt(65000 + @as(u20, @intFromFloat(d.density * 256.0)));

    const cutoff_density = d.density * d.cutoff;
    if (cutoff_density <= density_min.getF32() or d.density >= density_max.getF32()) {
        if (d.moisture >= 0.93 and d.moisture <= 0.94) return .purple_strange_stone;
        return .none;
    } else if (d.density <= 0.04 and d.moisture >= 0.3 and d.moisture <= 0.4) {
        return .blue_strange_stone;
    }

    if (d.moisture >= 0.98 and d.moisture <= 0.995)
        return if (d.density >= 0.2 and d.density <= 0.3) .pale_ancient_stone else .ancient_stone;
    if (d.moisture >= 0.93 and d.moisture <= 0.94) return .bright_red_stone;
    if (d.moisture >= 0.97) return .none;

    if (d.weirdness >= 0.6 and d.weirdness <= 0.9 and
        (d.density2 >= 0.88 and d.density2 <= 0.915 or d.density >= 0.88))
        return if (d.weirdness >= 0.73 or d.density2 >= 0.95) .molten_stone else .lava_stone;

    if (d.moisture >= 0.50 and d.density >= 0.53 and d.density <= 0.6)
        return if (d.weirdness >= 0.8) .lime_stone else .green_stone;

    if ((d.weirdness <= 0.55 or d.weirdness >= 0.93) and
        d.moisture >= 0.60 and d.moisture <= 0.72) return .blue_stone;
    if (d.weirdness <= 0.1 and d.density >= 0.40 and d.density >= 0.45 and d.density2 <= 0.55)
        return if (d.moisture >= 0.8) .pale_stone else .deep_blue_stone;

    if (d.moisture >= 0.20 and d.moisture <= 0.26)
        return if (d.weirdness >= 0.72 and d.weirdness <= 0.92) .more_mossy_stone else .mossy_stone;
    if (d.moisture >= 0.43 and d.moisture <= 0.535)
        return if (d.moisture <= 0.48 or d.density2 <= 0.08) .seagreen_stone else .green_stone;

    if (d.density2 <= 0.1) return .dark_stone;
    return .stone;
}

/// Uncached base-terrain evaluation with staged short-circuiting and domain warp sharing.
fn computeBaseSpriteType(
    chunk_x: u32,
    chunk_y: u32,
    block_x: u4,
    block_y: u4,
) TerrainData {
    const wx = chunk_x * 16 + block_x;
    const wy = chunk_y * 16 + block_y;

    const density_seed = memory.game.getHashSeed(.density);

    // Compute base density and capture domain warp vector for reuse
    var warp_vec: dw.utils.Vec2f32 = .{ 0.0, 0.0 };
    const density_val = getFbmValueWarp(
        density_seed,
        wx,
        wy,
        93.0,
        22.0,
        &warp_vec,
    );

    const cutoff_val = 0.75 + 0.3 * getHybridNoise(
        memory.game.getHashSeed(.cutoff),
        wx,
        wy,
        20.5,
    );

    const moisture_val = getFbmValue(
        memory.game.getHashSeed(.moisture),
        wx,
        wy,
        .{
            .cell_size = 375.0,
            .fbm_shift_size = 0.0,
            .use_worley_hybrid = false,
        },
    );

    var base_data: TerrainData = .{
        .density = density_val,
        .cutoff = cutoff_val,
        .moisture = moisture_val,
        .density2 = 0.0,
        .weirdness = 0.0,
        .ore_density = 0.0,
    };

    if (dw.is_debug and USE_HEATMAP and !USE_ORE_HEATMAP) {
        base_data.sprite = generateBaseProceduralSprite(&base_data);
        return base_data;
    }

    // start with fast air and special stone exit
    const cutoff_density = density_val * cutoff_val;
    if (cutoff_density <= density_min.getF32() or density_val >= density_max.getF32()) {
        if (moisture_val >= 0.93 and moisture_val <= 0.94) {
            base_data.sprite = .purple_strange_stone;
            return base_data;
        }
        base_data.sprite = .none;
        return base_data;
    } else if (density_val <= 0.04 and moisture_val >= 0.3 and moisture_val <= 0.4) {
        base_data.sprite = .blue_strange_stone;
        return base_data;
    }

    if (moisture_val >= 0.98 and moisture_val <= 0.995) {
        base_data.sprite = if (cutoff_val >= 0.2 and cutoff_val <= 0.3) .pale_ancient_stone else .ancient_stone;
        return base_data;
    }
    if (moisture_val >= 0.93 and moisture_val <= 0.955 and cutoff_val >= 0.6) {
        base_data.sprite = .bright_red_stone;
        return base_data;
    }
    if (moisture_val >= 0.97) {
        base_data.sprite = .none;
        return base_data;
    }

    // compute weirdness and density2 only when sprite selection requires them
    base_data.weirdness = getBillowNoise(
        memory.game.getHashSeed(.weirdness),
        wx,
        wy,
        140.8,
    );

    // reuse domain warp from density
    base_data.density2 = getFbmValuePrewarped(
        density_seed,
        wx,
        wy,
        16.5,
        warp_vec[0] * 2.0,
        warp_vec[1] * 2.0,
    );

    base_data.sprite = generateBaseProceduralSprite(&base_data);

    // compute ore_density now! base types are all stone so this is never wasteful
    base_data.ore_density = getFbmValue(
        memory.game.getHashSeed(.ore_density),
        wx,
        wy,
        .{
            .cell_size = 122.0,
            .fbm_shift_size = 0.0,
            .use_worley_hybrid = false,
        },
    );

    return base_data;
}

/// Fractional bits kept when a world coordinate is placed on a noise lattice.
/// 32 leaves the smoothest scale in use (a cell tens of blocks wide) millions of steps per block,
/// so the interpolant is continuous well past anything the eye can resolve.
const LATTICE_FRAC_BITS = 32;
/// Largest lattice frequency, in cells per block, the fixed-point placement can represent.
/// Bounds `step` at `2^(LATTICE_FRAC_BITS + 4)`, which is what caps `k` in `latticeAxis()`.
const MAX_INV_SCALE = 16.0;
/// Bit position a world coordinate is split at for the lattice multiply (see `latticeAxis()`).
const SPLIT_BIT = 32;
/// Significant bits kept in the lattice step's mantissa, also from `latticeAxis()`.
/// An `f32` scale carries exactly this many, which is what makes the split of `step` lossless.
const STEP_MANT_BITS = 24;

comptime {
    // the high half of the coordinate must survive its own partial product, and so must the low half.
    if (seeding.WORLD_COORD_BITS - SPLIT_BIT + STEP_MANT_BITS > 64)
        @compileError("A split world coordinate's high half overflows its partial product.");
    if (SPLIT_BIT + STEP_MANT_BITS > 64)
        @compileError("A split world coordinate's low half overflows its partial product.");
    // Recombining shifts right by `LATTICE_FRAC_BITS - k`, and that is only exact within the low half.
    if (LATTICE_FRAC_BITS > SPLIT_BIT)
        @compileError("The lattice fraction must fit below the split, or recombining loses its carry.");
}

/// One axis of a world coordinate placed on a noise lattice.
const LatticeAxis = struct {
    /// Hash inputs for the two interpolated corners, already folded to 64 bits.
    corners: [2]u64,
    /// Position within the cell, in [0, 1).
    t: f32,

    /// Hash input for the cell `offset` steps along this axis (0 or 1, the two interpolated corners).
    inline fn corner(self: @This(), comptime offset: u1) u64 {
        return self.corners[offset];
    }
};

/// Places one axis of a world coordinate on a lattice of `1 / inv_scale` blocks per cell.
inline fn latticeAxis(v: WorldCoord, inv_scale: f32) LatticeAxis {
    std.debug.assert(inv_scale > 0 and inv_scale <= MAX_INV_SCALE);
    // rounded, so the lattice a caller asks for is reproduced to within one part in 2^32 per block
    const step: u64 = @intFromFloat(@round(@as(f64, inv_scale) * (1 << LATTICE_FRAC_BITS)));
    // a scale so fine that a whole block fits inside one lattice step has no cells left to interpolate!
    std.debug.assert(step != 0);

    // step as m << k. this is lossless: step came from an f32, so below its top STEP_MANT_BITS bits it's all zeroes.
    const width = 64 - @clz(step);
    const k: u6 = if (width > STEP_MANT_BITS) @intCast(width - STEP_MANT_BITS) else 0;
    const m = step >> k;
    std.debug.assert(m << k == step);
    const shift: u6 = LATTICE_FRAC_BITS - k;

    const low_half: u64 = @truncate(v & ((1 << SPLIT_BIT) - 1));
    const low_product = low_half *% m;
    // the fraction only ever reads below the split, so it is done either way!
    const frac: u32 = @truncate((low_product & ((@as(u64, 1) << shift) - 1)) << k);
    const t = @as(f32, @floatFromInt(frac)) * INV_POW_2_32;

    // every coordinate short of 2^32 leaves the whole high-order path dead
    // that is the entire base depth, which is where most samples are taken
    const high_half: u64 = @truncate(v >> SPLIT_BIT);
    if (high_half == 0) {
        const cell = low_product >> shift;
        return .{ .corners = .{ cell, cell +% 1 }, .t = t };
    }

    const high_product = high_half *% m;
    // The cell index needs up to 73 bits, so it is carried as an explicit low/high pair
    const cell_low = (high_product << k) +% (low_product >> shift);
    const cell_high = (if (k == 0) 0 else high_product >> @intCast(64 - @as(u7, k))) +
        @intFromBool(cell_low < (high_product << k));

    // foldWorld() open-coded, so that the two corners share one multiply.
    // Stepping the low half over its own boundary carries into the high half,
    // and a fold of one more high unit is exactly one more FOLD_MULTIPLIER.
    const folded = cell_high *% seeding.FOLD_MULTIPLIER;
    const next_low = cell_low +% 1;
    const next_folded = folded +% (seeding.FOLD_MULTIPLIER & (0 -% @as(u64, @intFromBool(next_low == 0))));
    return .{ .corners = .{ cell_low ^ folded, next_low ^ next_folded }, .t = t };
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

/// Returns a struct with an a `value: bool`.
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

// When checking these heatmap values, ALWAYS add `dw.is_debug and USE_HEATMAP...` to the check.

/// Determines whether to use a heatmap or not for terrain.
/// Ignored if `dw.is_debug` is false; must also be true if `USE_ORE_HEATMAP` is true.
pub var USE_HEATMAP = false;
/// Determines whether to use a heatmap or not for ore generation.
/// Ignored if `dw.is_debug` is false.
pub var USE_ORE_HEATMAP = false;

/// Configuration options passed to terrain noise generation (`getFbmValue()`).
const TerrainOptions = struct {
    /// Controls scale of primary noise grid cells.
    cell_size: comptime_float,

    /// Maximum offset applied during domain warping step.
    fbm_shift_size: comptime_float,

    /// Stretches vertical sampling coordinates by factor of 2 when true.
    horizontally_wide: bool = false,

    /// Uses a fast Worley-like cell distance check when true, or bilinear Perlin FBM when false.
    use_worley_hybrid: bool = true,
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
    data: TerrainData = undefined,
    occupied: bool = false,
};

/// Block window one full sweep of the cache covers, in blocks (see `dw.utils.tileIndex()`).
/// Shaped to the chunk sweep that fills it, exactly like (and for the same reason as) the foundation cache in `world.zig`:
/// one full sweep row wide, two chunk rows tall,
/// so the edge-flag halo of a chunk still finds the neighbor row above it rather than re-deriving terrain for all of it.
const BASE_CACHE_TILE_W = dw.world.SIM_GRID_SIZE;
const BASE_CACHE_TILE_H = dw.CHUNK_SIZE * 2;
/// Direct-mapped cache of `computeBaseSpriteType()` results (a power of two by construction).
/// The same cell is recomputed many times per chunk gen (pass 1, the edge-flag halo, the vine scan,
/// and structure terrain gates all resample it, plus overlap across neighbors),
/// so memoizing removes FBM redundancy (the dominant generation cost).
/// Release-only: in debug the `TuningFloat` sliders mutate FBM output live, so debug always recomputes.
const BASE_CACHE_SLOTS = BASE_CACHE_TILE_W * BASE_CACHE_TILE_H;
var base_terrain_cache: [BASE_CACHE_SLOTS]BaseTerrainCacheEntry = @splat(.{});
/// Current seed the cache holds; a mismatch (reseed) invalidates every entry at once.
var base_cache_key: u64 = 0;

/// Identity of the terrain every cache downstream of it holds; a mismatch drops the cache.
/// Release-only, like the caches themselves: debug recomputes, since the sliders mutate output live.
pub inline fn terrainGeneration() u64 {
    const seed = memory.game.getHashSeed(.moisture);
    return seed[0] ^ seed[1];
}

/// Direct-mapped slot for a world block. Tiled rather than hashed, so a whole chunk pass is
/// conflict-free instead of merely unlikely to collide; see `dw.utils.tileIndex()`.
inline fn baseCacheIndex(wx: u32, wy: u32) usize {
    return dw.utils.tileIndex(BASE_CACHE_TILE_W, BASE_CACHE_TILE_H, wx, wy);
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
) TerrainData {
    // Debug drags terrain sliders live, so caching would serve stale samples; just recompute for simplicity.
    if (dw.is_debug) return computeBaseSpriteType(chunk_x, chunk_y, block_x, block_y);

    const wx = chunk_x * 16 + block_x;
    const wy = chunk_y * 16 + block_y;

    const seed = memory.game.getHashSeed(.moisture);
    const key = seed[0] ^ seed[1];
    if (key != base_cache_key) {
        // @memset, not `= @splat(.{})`: an array this large would be built as a stack temporary first.
        @memset(&base_terrain_cache, .{});
        base_cache_key = key;
    }

    const entry = &base_terrain_cache[baseCacheIndex(wx, wy)];
    if (entry.occupied and entry.wx == wx and entry.wy == wy) return entry.data;

    const data = computeBaseSpriteType(chunk_x, chunk_y, block_x, block_y);
    entry.* = .{ .wx = wx, .wy = wy, .data = data, .occupied = true };
    return data;
}

/// A comptime row in the ore palette. Evaluated at base depth and recursive refinement layers.
/// Called "ore dispersal", but really works for both gems and ores.
const OreDispersal = struct {
    sprite: Sprite,
    min_depth_offset: u8,
    scale: f32,
    octaves: u2 = 2,
    hybrid_weight: f32,
    warp_strength: f32,
    val_min: f32,
    val_max: f32,
    min_density: f32,
    max_density: f32,
    seed_lane: u3,

    // contextual visual filters
    forbidden_stone: Sprite = .none,
    required_stone: Sprite = .none,
    is_gem: bool = false,
    gem_chance_scale: f32 = 1.0,
};

/// List of rules for ore and gem dispersals.
/// Window widths (val_max - val_min) directly control ore rarity to match audit counts.
///
/// No ore/gem rule should exist outside density range [0.20, 0.90].
const ORE_DISPERSALS = [_]OreDispersal{
    .{
        .sprite = .copper,
        .min_depth_offset = 0,
        .scale = 12,
        .octaves = 2,
        .hybrid_weight = 0.20,
        .warp_strength = 0.80,
        .val_min = 0.46,
        .val_max = 0.51,
        .min_density = 0.42,
        .max_density = 0.62,
        .seed_lane = 0,
    },
    .{
        .sprite = .iron,
        .min_depth_offset = 0,
        .scale = 10,
        .octaves = 2,
        .hybrid_weight = 0.35,
        .warp_strength = 0.75,
        .val_min = 0.55,
        .val_max = 0.58,
        .min_density = 0.40,
        .max_density = 0.57,
        .seed_lane = 1,
        .forbidden_stone = .blue_strange_stone,
    },
    .{
        .sprite = .silver,
        .min_depth_offset = 0,
        .scale = 12,
        .octaves = 2,
        .hybrid_weight = 0.25,
        .warp_strength = 0.65,
        .val_min = 0.20,
        .val_max = 0.26,
        .min_density = 0.30,
        .max_density = 0.435,
        .seed_lane = 2,
    },
    .{
        .sprite = .gold,
        .min_depth_offset = 1,
        .scale = 11,
        .octaves = 2,
        .hybrid_weight = 0.30,
        .warp_strength = 0.65,
        .val_min = 0.30,
        .val_max = 0.36,
        .min_density = 0.60,
        .max_density = 0.71,
        .seed_lane = 0,
    },
    .{
        .sprite = .nickel,
        .min_depth_offset = 2,
        .scale = 6,
        .octaves = 2,
        .hybrid_weight = 0.55,
        .warp_strength = 0.80,
        .val_min = 0.78,
        .val_max = 0.795,
        .min_density = 0.40,
        .max_density = 0.65,
        .seed_lane = 1,
    },
    .{
        .sprite = .quartz,
        .min_depth_offset = 0,
        .scale = 9,
        .octaves = 2,
        .hybrid_weight = 0.45,
        .warp_strength = 0.70,
        .val_min = 0.15,
        .val_max = 0.24,
        .min_density = 0.30,
        .max_density = 0.58,
        .seed_lane = 3,
        .is_gem = true,
        .gem_chance_scale = 0.34,
    },
    .{
        .sprite = .sapphire,
        .min_depth_offset = 1,
        .scale = 13,
        .octaves = 2,
        .hybrid_weight = 0.40,
        .warp_strength = 0.60,
        .val_min = 0.75,
        .val_max = 0.85,
        .min_density = 0.30,
        .max_density = 0.56,
        .seed_lane = 4,
        .forbidden_stone = .deep_blue_stone,
        .is_gem = true,
        .gem_chance_scale = 0.65,
    },
    .{
        .sprite = .emerald,
        .min_depth_offset = 1,
        .scale = 10,
        .octaves = 2,
        .hybrid_weight = 0.50,
        .warp_strength = 0.70,
        .val_min = 0.45,
        .val_max = 0.48,
        .min_density = 0.34,
        .max_density = 0.62,
        .seed_lane = 3,
        .is_gem = true,
        .gem_chance_scale = 0.86,
    },
    .{
        .sprite = .cobalt,
        .min_depth_offset = 2,
        .scale = 14,
        .octaves = 2,
        .hybrid_weight = 0.30,
        .warp_strength = 0.55,
        .val_min = 0.94,
        .val_max = 0.98,
        .min_density = 0.52,
        .max_density = 0.90,
        .seed_lane = 2,
    },
    .{
        .sprite = .ruby,
        .min_depth_offset = 2,
        .scale = 11,
        .octaves = 2,
        .hybrid_weight = 0.60,
        .warp_strength = 0.65,
        .val_min = 0.22,
        .val_max = 0.24,
        .min_density = 0.26,
        .max_density = 0.54,
        .seed_lane = 4,
        .is_gem = true,
        .gem_chance_scale = 1.0,
    },
    .{
        .sprite = .aquashard,
        .min_depth_offset = 2,
        .scale = 16,
        .octaves = 2,
        .hybrid_weight = 0.45,
        .warp_strength = 0.50,
        .val_min = 0.40,
        .val_max = 0.45,
        .min_density = 0.20,
        .max_density = 0.48,
        .seed_lane = 2,
        .is_gem = true,
        .gem_chance_scale = 0.50,
    },
    .{
        .sprite = .amethyst,
        .min_depth_offset = 0,
        .scale = 10,
        .octaves = 2,
        .hybrid_weight = 0.65,
        .warp_strength = 0.60,
        .val_min = 0.10,
        .val_max = 0.40,
        .min_density = 0.28,
        .max_density = 0.55,
        .seed_lane = 3,
        .forbidden_stone = .deep_blue_stone,
        .is_gem = true,
        .gem_chance_scale = 0.70,
    },
    .{
        .sprite = .electrit,
        .min_depth_offset = 3,
        .scale = 28,
        .octaves = 2,
        .hybrid_weight = 0.70,
        .warp_strength = 0.45,
        .val_min = 0.84,
        .val_max = 0.85,
        .min_density = 0.34,
        .max_density = 0.52,
        .seed_lane = 4,
        .is_gem = true,
        .gem_chance_scale = 0.30,
    },
};

comptime {
    @setEvalBranchQuota(1e6);
    for (ORE_DISPERSALS, 0..) |rule, i| {
        // basic bound and range sanity checks
        if (rule.octaves == 0) @compileError("Every ore dispersal needs at least one octave.");
        if (rule.scale <= 0) @compileError("Ore scale must be strictly positive.");
        if (rule.val_min >= rule.val_max) @compileError("Ore value window bounds must be strictly ordered (val_min < val_max).");
        if (rule.val_min < 0 or rule.val_max > 1) @compileError("Ore value window bounds must be normalized in [0, 1].");
        if (rule.min_density >= rule.max_density) @compileError("Ore density bounds must be strictly ordered (min_density < max_density).");
        if (rule.min_density < 0 or rule.max_density > 1) @compileError("Ore density bounds must be normalized in [0, 1].");
        if (rule.hybrid_weight < 0 or rule.hybrid_weight > 1) @compileError("Ore hybrid weights must be normalized in [0, 1].");
        if (rule.warp_strength < 0 or rule.warp_strength > 1) @compileError("Ore warp strengths must be normalized in [0, 1].");
        if (rule.gem_chance_scale <= 0) @compileError("Gem chance scale must be strictly positive.");

        // stone filter logical contradictions
        if (rule.required_stone != .none and rule.forbidden_stone != .none and rule.required_stone == rule.forbidden_stone) {
            @compileError("Ore rule cannot have identical required_stone and forbidden_stone.");
        }

        // complete priority shadowing checks against earlier rules
        for (ORE_DISPERSALS[0..i]) |earlier| {
            const same_lane = (earlier.seed_lane == rule.seed_lane);
            const same_noise_config = (earlier.scale == rule.scale and earlier.octaves == rule.octaves and
                earlier.hybrid_weight == rule.hybrid_weight and earlier.warp_strength == rule.warp_strength);
            const depth_subsumed = (earlier.min_depth_offset <= rule.min_depth_offset);
            const density_subsumed = (earlier.min_density <= rule.min_density and earlier.max_density >= rule.max_density);
            const val_subsumed = (earlier.val_min <= rule.val_min and earlier.val_max >= rule.val_max);
            const gem_subsumed = (!earlier.is_gem or (rule.is_gem and earlier.gem_chance_scale >= rule.gem_chance_scale));

            const stone_subsumed = b: {
                if (earlier.required_stone != .none and earlier.required_stone != rule.required_stone) break :b false;
                if (earlier.forbidden_stone != .none and earlier.forbidden_stone == rule.required_stone) break :b false;
                break :b true;
            };

            if (same_lane and same_noise_config and depth_subsumed and density_subsumed and val_subsumed and gem_subsumed and stone_subsumed) {
                @compileError("An ore dispersal rule is completely shadowed by an earlier rule on the same seed lane and can never trigger.");
            }
        }
    }
}

// per-lane domain offsets that keep each lane's warp field independent of the others.
// these were generated through (`openssl prime -generate -bits 40`).
const ORE_LANE_STEP_X: u64 = 944637515351;
const ORE_LANE_STEP_Y: u64 = 1089013738927;

comptime {
    if (ORE_LANE_STEP_X == ORE_LANE_STEP_Y)
        @compileError("The two axes need different steps, or a lane offset only ever moves diagonally.");
}

/// Comptime `rule`: every scale, weight, and octave count below then folds into its call site,
/// including the lattice step split inside each noise sample (see `getDualValueNoiseFixed()`).
inline fn oreField(seed: Vec2u, x: WorldCoord, y: WorldCoord, comptime lane: u3, comptime rule: OreDispersal) f32 {
    const inv_scale = 1.0 / rule.scale;
    // fast domain warping
    const warp = getDualValueNoiseFixed(
        seed,
        x +% ORE_LANE_STEP_X * @as(u64, lane), // * before +%, this works out
        y +% ORE_LANE_STEP_Y * @as(u64, lane),
        inv_scale * 0.4,
    );
    const warp_amt = rule.scale * rule.warp_strength;
    const warp_x: i64 = @intFromFloat((warp[0] - 0.5) * warp_amt);
    const warp_y: i64 = @intFromFloat((warp[1] - 0.5) * warp_amt);
    // The warp displaces the sample by a handful of blocks, so wrapping arithmetic is all it needs:
    // the lattice reads a displaced coordinate exactly the same way it reads an undisplaced one.
    const sample_x = x +% @as(WorldCoord, @bitCast(@as(i128, warp_x)));
    const sample_y = y +% @as(WorldCoord, @bitCast(@as(i128, warp_y)));

    var value: f32 = 0;
    // Both the octave weight and their total are fixed by the rule, so the normalization is a constant.
    comptime var weight: f32 = 0;

    inline for (0..rule.octaves) |octave| {
        const freq: u64 = 1 << octave;
        const amp: f32 = 1.0 / @as(f32, @floatFromInt(freq));
        const n = getDualValueNoiseFixed(
            seed,
            sample_x *% freq +% octave *% 7919,
            sample_y *% freq +% octave *% 104729,
            inv_scale * @as(f32, @floatFromInt(freq)),
        )[octave & 1];

        const ridged = 1.0 - @abs(2.0 * n - 1.0);
        value += amp * (n * (1.0 - rule.hybrid_weight) + ridged * rule.hybrid_weight);
        weight += amp;
    }
    return value / weight;
}

/// Returns a newly formed ore, if the host and depth gate permit one.
///
/// `host_tag` is the host block's provenance (`refine.RefinedTag`): stone that is still standing in for something else,
/// such as the canopy of a refined shrub, grows no ore for as long as the tag lasts.
/// Base-depth callers have no provenance to state and pass `.{}`.
pub fn disperseOre(
    host: Sprite,
    density: f32,
    x: WorldCoord,
    y: WorldCoord,
    depth: u64,
    seed: Vec2u,
    host_tag: dw.refine.RefinedTag,
) ?Sprite {
    if (!host.isStone()) return null;
    if (host_tag.blocksOverlay()) return null;

    // fast global exit: no ore/gem rule exists outside density range [0.20, 0.90]
    if (density < 0.20 or density > 0.90) return null;

    // The gem roll is shared by every gem rule, so it is computed AT MOST ONCE per block.
    // The noise fields are NOT shareable: each rule warps and folds the domain with its own scale/weights,
    // so a field is only ever read by the one rule that asked for it.
    var gem_roll_cache: ?f32 = null;

    inline for (ORE_DISPERSALS) |rule| {
        // A labeled block, not `continue`: leaving an unrolled iteration early is RUNTIME control
        // flow, which `continue` (comptime, it picks the next iteration to compile) cannot express.
        next_rule: {
            // first, do depth+host stone filters
            if (depth < dw.startup.STARTING_ZOOM_TIMES + rule.min_depth_offset) break :next_rule;
            if (rule.forbidden_stone != .none and host == rule.forbidden_stone) break :next_rule;
            if (rule.required_stone != .none and host != rule.required_stone) break :next_rule;

            // now add contextural density overrides (example extra "biome" rules)
            var min_d = rule.min_density;
            var max_d = rule.max_density;
            if (rule.sprite == .gold and host == .lava_stone) min_d = 0.52;
            if (rule.sprite == .silver and host == .blue_strange_stone) {
                min_d = 0.18;
                max_d = 0.20;
            }

            if (density < min_d or density > max_d) break :next_rule;

            // gem roll check (this gate also improves perf; less seed evaluations!)
            if (rule.is_gem) {
                const gem_roll = gem_roll_cache orelse b: {
                    const roll = FastHash.float2d_32(seed, seeding.foldWorld(x), seeding.foldWorld(y));
                    gem_roll_cache = roll;
                    break :b roll;
                };

                const purple_boost: f32 = if (host == .purple_strange_stone) 1.33 else 1.0;
                const target_odds = base_gem_odds.getF32() * rule.gem_chance_scale * purple_boost;
                if (gem_roll > target_odds) break :next_rule;
            }

            const val = oreField(seed, x, y, rule.seed_lane, rule);
            if (val >= rule.val_min and val <= rule.val_max) return rule.sprite;
        }
    }

    return null;
}

/// Applies the comptime ore palette to a base-depth stone block.
pub fn addOresAndGems(base_data: TerrainData, x: u32, y: u32) Sprite {
    if (dw.is_debug and USE_HEATMAP and USE_ORE_HEATMAP) {
        const field = oreField(memory.game.getHashSeed(.ores1), x, y, 0, ORE_DISPERSALS[0]);
        return @enumFromInt(65000 + @as(u20, @intFromFloat(field * 256.0)));
    }

    return disperseOre(
        base_data.sprite,
        base_data.ore_density,
        x,
        y,
        dw.startup.STARTING_ZOOM_TIMES,
        memory.game.getHashSeed(.ores1),
        .{}, // base-depth terrain has no provenance to stand in the way
    ) orelse base_data.sprite;
}

test "ore dispersal produces deposits at base and recursive depths" {
    const seed: Vec2u = .{ 0x123456789ABCDEF0, 0x0FEDCBA987654321 };
    var base_count: usize = 0;
    var deep_count: usize = 0;

    for (0..256) |y| {
        for (0..256) |x| {
            if (disperseOre(.stone, 0.5, x, y, dw.startup.STARTING_ZOOM_TIMES, seed, .{})) |ore| {
                base_count += 1;
                _ = ore;
            }
            if (disperseOre(.stone, 0.5, x, y, dw.startup.STARTING_ZOOM_TIMES + 3, seed, .{}) != null) deep_count += 1;

            // A block still standing in for a shrub's canopy grows nothing, whatever the field says.
            try std.testing.expect(disperseOre(
                .stone,
                0.5,
                x,
                y,
                dw.startup.STARTING_ZOOM_TIMES + 3,
                seed,
                .make(.plant_leaf, 2),
            ) == null);
        }
    }

    try std.testing.expect(base_count > 0);
    try std.testing.expect(deep_count > 0);
}

test "noise resolves the whole world, not a 32-bit window of it" {
    const seed: Vec2u = .{ 0x243f6a8885a308d3, 0x13198a2e03707344 };
    const scale = 1.0 / 7.0;

    // Two points a power of two apart, at the sizes the coordinate used to be masked or truncated to.
    // Each of these used to name the SAME lattice cell as the origin, which is what made the world
    // repeat; a coordinate this size also no longer survives an f64 product.
    const origin: WorldCoord = 1 << 68 | 12345;
    for ([_]WorldCoord{ 1 << 32, 1 << 53, 1 << 64 }) |period| {
        const here = getDualValueNoise(seed, origin, origin, scale);
        const away = getDualValueNoise(seed, origin +% period, origin, scale);
        try std.testing.expect(here[0] != away[0]);
    }

    // ...and the field still varies block to block out there, rather than quantizing to one value per f64 step.
    // A run this short lands in at most a couple of cells, so it is a lower bound.
    var distinct: usize = 0;
    var previous: f32 = -1;
    for (0..16) |i| {
        const v = getDualValueNoise(seed, origin + i, origin, scale)[0];
        if (v != previous) distinct += 1;
        previous = v;
    }
    try std.testing.expect(distinct >= 8);
}

test "lattice cells stay adjacent across a fold boundary" {
    // Crossing 2^64 is where the fold changes bands. Cells must keep sharing corners across it,
    // or the terrain tears along a line: the corner one cell up must equal the next cell's own corner.
    const scale = 1.0 / 4.0; // 4 blocks per cell, so a cell boundary is easy to straddle
    const boundary: WorldCoord = @as(WorldCoord, 1) << 64;
    for ([_]WorldCoord{ boundary - 8, boundary - 4, boundary, boundary + 4 }) |v| {
        const here = latticeAxis(v, scale);
        const next = latticeAxis(v + 4, scale);
        try std.testing.expectEqual(here.corner(1), next.corner(0));
    }

    // The fraction is a real position within the cell, not a rounded one.
    const quarter = latticeAxis(boundary + 1, scale);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), quarter.t, 1e-6);
}

test "the split lattice multiply agrees with a plain 128-bit one" {
    // `latticeAxis()` avoids a 128-bit multiply by splitting the coordinate and the step. That is an
    // optimization ONLY: it must reproduce the obvious implementation exactly, at every scale in use
    // and across the whole 69-bit coordinate range, or the terrain silently changes shape.
    const scales = [_]f32{ 1.0 / 375.0, 1.0 / 93.75, 1.0 / 21.0, 1.0 / 7.0, 1.0 / 3.0, 1.0, 2.0, MAX_INV_SCALE };
    const limit = @as(WorldCoord, 1) << seeding.WORLD_COORD_BITS;

    var state: u64 = 0x9E3779B97F4A7C15;
    for (0..4096) |i| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        // Small coordinates take the fast path, the rest take the wide one, and the last few sit at
        // the very top of the range where the high half is widest.
        const v: WorldCoord = switch (i % 4) {
            0 => state & 0xFFFFFFFF,
            1 => state,
            2 => @as(WorldCoord, state) % limit,
            else => limit - 1 - (state & 0xFFFF),
        };

        for (scales) |scale| {
            const step: u64 = @intFromFloat(@round(@as(f64, scale) * (1 << LATTICE_FRAC_BITS)));
            const scaled = @as(WorldCoord, v) *% step;
            const cell = scaled >> LATTICE_FRAC_BITS;

            const axis = latticeAxis(v, scale);
            try std.testing.expectEqual(seeding.foldWorld(cell), axis.corner(0));
            try std.testing.expectEqual(seeding.foldWorld(cell +% 1), axis.corner(1));
            try std.testing.expectEqual(
                @as(f32, @floatFromInt(@as(u32, @truncate(scaled)))) * INV_POW_2_32,
                axis.t,
            );
        }
    }
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
fn getBilinearValueNoise(seed_vector: Vec2u, x: WorldCoord, y: WorldCoord, cell_size: f32) f32 {
    const ax = latticeAxis(x, 1.0 / cell_size);
    const ay = latticeAxis(y, 1.0 / cell_size);

    const u = fade(ax.t);
    const v = fade(ay.t);

    // Vectorized 4-tap lookup
    const ix0 = ax.corner(0);
    const ix1 = ax.corner(1);
    const iy0 = ay.corner(0);
    const iy1 = ay.corner(1);
    const vx: Vec4u = .{ ix0, ix1, ix0, ix1 };
    const vy: Vec4u = .{ iy0, iy0, iy1, iy1 };
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

/// Evaluates terrain noise value normalized to range [0, 1].
/// Chooses FBM+perlin noise when `use_worley_hybrid` is false, and Worley-like (with some FBM+dual value noise mixed in).
fn getFbmValue(seed_vector: Vec2u, x: u32, y: u32, options: TerrainOptions) f32 {
    if (comptime !options.use_worley_hybrid) {
        return fbm(
            getPerlinNoiseFixed,
            seed_vector,
            x,
            y,
            options.cell_size,
            3,
        );
    }

    var unused_warp: dw.utils.Vec2f32 = .{ 0.0, 0.0 };
    return getFbmValueWarp(seed_vector, x, y, options.cell_size, options.fbm_shift_size, &unused_warp);
}

/// Evaluates Worley FBM noise and outputs the unscaled domain warp vector for reuse.
fn getFbmValueWarp(
    seed_vector: Vec2u,
    x: u32,
    y: u32,
    comptime cell_size_base: f32,
    fbm_shift_size: f32,
    out_warp: *dw.utils.Vec2f32,
) f32 {
    const fbm_octaves = 3;
    var warp_x: f32 = 0;
    var warp_y: f32 = 0;

    var freq: u64 = 1;
    var amp: f32 = fbm_shift_size;

    const inv_fbm_scale = 1.0 / fbm_scale.getF32();
    const inv_dual_value_scale = 1.0 / dual_value_scale.getF32();
    amp *= inv_fbm_scale;

    if (amp > 0) {
        inline for (0..fbm_octaves) |_| {
            const n = getDualValueNoiseTuned(
                seed_vector,
                x * freq,
                y * freq,
                inv_dual_value_scale,
            );
            warp_x += n[0] * amp;
            warp_y += n[1] * amp;
            amp *= 0.55;
            freq *%= 2;
        }
        out_warp.* = .{ warp_x / fbm_shift_size, warp_y / fbm_shift_size };
    }

    return getFbmValuePrewarped(seed_vector, x, y, cell_size_base, warp_x, warp_y);
}

/// Evaluates Worley cellular noise using an explicit domain warp offset.
fn getFbmValuePrewarped(
    seed_vector: Vec2u,
    x: u32,
    y: u32,
    comptime cell_size_base: f32,
    warp_x: f32,
    warp_y: f32,
) f32 {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);

    const cell_size = cell_size_base * procedural_cell_size.getF32();
    const inv_cell_size = 1.0 / cell_size;
    const h_stretch = 1.5;
    const cell_w = cell_size * h_stretch;
    const inv_cell_w = 1.0 / cell_w;

    const wx = fx + warp_x;
    const wy = fy + warp_y;

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
/// Prefer `getDualValueNoiseFixed()` whenever the scale is a constant.
pub fn getDualValueNoise(seed: Vec2u, x: WorldCoord, y: WorldCoord, inv_scale: f32) dw.utils.Vec2f32 {
    return dualValueNoise(seed, x, y, inv_scale);
}

/// `getDualValueNoise()` with the lattice scale fixed at compile-time. Same field, same values.
pub inline fn getDualValueNoiseFixed(
    seed: Vec2u,
    x: WorldCoord,
    y: WorldCoord,
    comptime inv_scale: f32,
) dw.utils.Vec2f32 {
    return dualValueNoise(seed, x, y, inv_scale);
}

/// Function that decides whether to use `getDualValueNoise()` or its fixed-scale variant if in debug.
inline fn getDualValueNoiseTuned(seed: Vec2u, x: WorldCoord, y: WorldCoord, inv_scale: f32) dw.utils.Vec2f32 {
    if (dw.is_debug) return getDualValueNoise(seed, x, y, inv_scale);
    return getDualValueNoiseFixed(seed, x, y, inv_scale);
}

/// Shared body of both dual-value entry points; `inline` so a comptime `inv_scale` stays comptime.
inline fn dualValueNoise(seed: Vec2u, x: WorldCoord, y: WorldCoord, inv_scale: f32) dw.utils.Vec2f32 {
    const ax = latticeAxis(x, inv_scale);
    const ay = latticeAxis(y, inv_scale);

    // Use fade curves
    const u = fade(ax.t);
    const v = fade(ay.t);

    // Prepare 4 corners: (x0, y0), (x0+1, y0), (x0, y0+1), (x0+1, y0+1)
    const x0 = ax.corner(0);
    const x1 = ax.corner(1);
    const y0 = ay.corner(0);
    const y1 = ay.corner(1);
    const vx: Vec4u = .{ x0, x1, x0, x1 };
    const vy: Vec4u = .{ y0, y0, y1, y1 };

    // Generate 4 values all at once!
    const h_vec = FastHash.hash2d_4x(seed, vx, vy);

    var result: dw.utils.Vec2f32 = .{ 0, 0 };
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
        result[i] = nx0 + v * (nx1 - nx0);
    }
    return result;
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

inline fn lattice(seed_vector: Vec2u, x: WorldCoord, y: WorldCoord, cell_size: f32) Lattice {
    const ax = latticeAxis(x, 1.0 / cell_size);
    const ay = latticeAxis(y, 1.0 / cell_size);
    const x0 = ax.corner(0);
    const x1 = ax.corner(1);
    const y0 = ay.corner(0);
    const y1 = ay.corner(1);
    const vx: Vec4u = .{ x0, x1, x0, x1 };
    const vy: Vec4u = .{ y0, y0, y1, y1 };
    return .{
        .x0 = x0,
        .y0 = y0,
        .tx = ax.t,
        .ty = ay.t,
        .u = fade(ax.t),
        .v = fade(ay.t),
        .h = FastHash.hash2d_4x(seed_vector, vx, vy),
    };
}

/// Perlin gradient noise. Interpolates corner gradient dot-products instead of raw values,
/// removing value-noise plateaus for smooth, continuous slopes.
///
/// Use for: organic, flowing hills/valleys.
/// Prefer `getPerlinNoiseFixed()` whenever the cell size is a constant.
pub inline fn getPerlinNoise(seed_vector: Vec2u, x: WorldCoord, y: WorldCoord, cell_size: f32) f32 {
    return perlinNoise(seed_vector, x, y, cell_size);
}

/// `getPerlinNoise()` with the cell size fixed at compile-time; see `getDualValueNoiseFixed()`
/// for what that buys. Same field, same values.
pub inline fn getPerlinNoiseFixed(
    seed_vector: Vec2u,
    x: WorldCoord,
    y: WorldCoord,
    comptime cell_size: f32,
) f32 {
    return perlinNoise(seed_vector, x, y, cell_size);
}

/// Shared body of both Perlin entry points; `inline` so a comptime `cell_size` stays comptime.
inline fn perlinNoise(seed_vector: Vec2u, x: WorldCoord, y: WorldCoord, cell_size: f32) f32 {
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
pub fn getSimplexNoise(seed_vector: Vec2u, x: u64, y: u64, cell_size: f32) f32 {
    const xin = @as(f64, @floatFromInt(x)) / @as(f64, cell_size);
    const yin = @as(f64, @floatFromInt(y)) / @as(f64, cell_size);

    const s = (xin + yin) * @as(f64, F2);
    const i_f = @floor(xin + s);
    const j_f = @floor(yin + s);
    const t = (i_f + j_f) * @as(f64, G2);
    const x0_64 = xin - (i_f - t);
    const y0_64 = yin - (j_f - t);
    const x0: f32 = @floatCast(x0_64);
    const y0: f32 = @floatCast(y0_64);

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

/// Generic fractal Brownian motion: stack `octaves` of any candidate noise at halving amplitude and cell size.
pub inline fn fbm(
    comptime noiseFn: anytype,
    seed_vector: Vec2u,
    x: WorldCoord,
    y: WorldCoord,
    comptime cell_size: f32,
    comptime octaves: u32,
) f32 {
    var sum: f32 = 0;
    comptime var norm: f32 = 0;
    inline for (0..octaves) |octave| {
        const amp: f32 = 1.0 / @as(f32, @floatFromInt(@as(u32, 1) << octave));
        sum += amp * (noiseFn(seed_vector, x, y, cell_size * amp) - 0.5);
        norm += amp;
    }
    return std.math.clamp(sum / norm + 0.5, 0.0, 1.0);
}
