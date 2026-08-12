//! This module controls procedural logic for debug constants and noise functions.
//! Higher-level logic is in `world.generateBaseChunk()`.
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
const Vec4f32 = dw.utils.Vec4f32;
const Vec4u = dw.utils.Vec4u;
const WorldCoord = seeding.WorldCoord;

// debug slider values!
pub const dual_value_scale = TuningFloat(30.4);
pub const base_gem_odds = TuningFloat(0.25);
pub const procedural_cell_size = TuningFloat(1.0);
pub const fbm_scale = TuningFloat(1.0);
pub const density_min = TuningFloat(0.28);
pub const density_max = TuningFloat(0.94);
pub const hybrid_weight = TuningFloat(0.6);

/// Result of Worley noise evaluation containing density value and visual cell hash.
pub const WorleyResult = struct {
    value: f32,
    cell_hash: u64,
};

/// Everything downstream of the terrain rules reads out of a base terrain sample.
///
/// The intermediate noise fields do NOT live here.
/// They belong to `TerrainSampler`, which is a stack value,
/// so the memoized sample stays small enough to keep the cache in a few hundred KiB.
const TerrainData = struct {
    /// stone or air the terrain rules chose
    sprite: Sprite = .none,
    /// ore field density, and zero where no ore rule can reach the block
    ore_density: f32 = 0,
};

/// Sprite index of the first heatmap tile.
/// The heatmap occupies 256 tiles above it, one per density bucket.
const HEATMAP_BASE = 65000;

/// The noise fields of one base-depth world block, each calculated on demand.
///
/// `classifyTerrain()` reads every field through this type,
/// so a rule which a block never reaches costs that block nothing:
/// air pays for neither the island probe nor the detail octaves.
const TerrainSampler = struct {
    wx: u32,
    wy: u32,
    /// seed lane shared by the density field, its detail octave, and the island probe
    density_seed: Vec2u,
    /// domain warp of the density sample, reused by the detail octave
    warp: Vec2f32,
    /// hash of the Worley cell the density sample landed in
    cell_hash: u64,

    /// multiplies the cutoff for stone density
    cutoff: f32,
    /// selects the biome
    moisture: f32,
    /// base density for stone details
    density: f32,

    /// secondary density for fine stone details, valid once `detail()` ran
    density2: f32 = 0,
    /// controls rare block spawns, valid once `detail()` ran
    weirdness: f32 = 0,
    /// tagged island sprite, valid once `island()` ran
    island_sprite: Sprite = .none,

    /// True once a block passed the cheap air and extreme-density rules.
    /// A block which those rules settled can never host an ore,
    /// so `computeBaseSpriteType()` reads this to skip the ore field.
    deep: bool = false,
    detail_ready: bool = false,
    island_ready: bool = false,

    /// Draws the three fields every terrain rule needs.
    fn init(wx: u32, wy: u32) TerrainSampler {
        const density_seed = memory.getHashSeed(.density);

        var warp: Vec2f32 = .{ 0.0, 0.0 };
        const density_res = getFbmValueWarp(density_seed, wx, wy, 93.0, 28.0, &warp);

        return .{
            .wx = wx,
            .wy = wy,
            .density_seed = density_seed,
            .warp = warp,
            .cell_hash = density_res.cell_hash,
            .density = density_res.value,
            .cutoff = 0.75 + 0.3 * getHybridNoise(memory.getHashSeed(.cutoff), wx, wy, 20.5),
            .moisture = fbm(getPerlinNoiseFixed, memory.getHashSeed(.moisture), wx, wy, 375.0, 3),
        };
    }

    /// Draws the two fields the fine stone rules need.
    fn detail(self: *TerrainSampler) void {
        if (self.detail_ready) return;
        self.detail_ready = true;

        self.weirdness = getBillowNoise(memory.getHashSeed(.weirdness), self.wx, self.wy, 140.8);
        // reuse the density sample's domain warp instead of drawing a second one
        self.density2 = getFbmValuePrewarped(
            self.density_seed,
            self.wx,
            self.wy,
            16.5,
            self.warp[0] * 2.0,
            self.warp[1] * 2.0,
        ).value;
    }

    /// Resolves the island tag of the Worley cell, which costs a second warped sample.
    fn island(self: *TerrainSampler) Sprite {
        if (!self.island_ready) {
            self.island_ready = true;
            self.island_sprite = getIslandSprite(self.cell_hash, self.wx, self.wy, self.density_seed);
        }
        return self.island_sprite;
    }
};

/// Determine the tagged island sprite from `cell_hash`.
inline fn getIslandSprite(cell_hash: u64, wx: u32, wy: u32, density_seed: Vec2u) Sprite {
    const roll = @as(f32, @floatFromInt(@as(u32, @truncate(cell_hash ^ (cell_hash >> 32))))) * INV_POW_2_32;
    if (roll <= 0.34) {
        if (!isTopSurface(wx, wy, density_seed)) return .none;
        if (roll <= 0.20) {
            return .sand;
        } else if (roll <= 0.28) {
            return .clay;
        } else {
            return .red_clay;
        }
    } else if (roll <= 0.36) {
        return if (isTopSurface(wx, wy, density_seed)) .none else .diorite;
    }
    return .none;
}

/// Chooses the base sprite of a block from its terrain fields.
///
/// The rules run in one order and in one place.
/// Each group of them sits directly after the sample it is the first to need,
/// so the order is also the cost order.
fn classifyTerrain(s: *TerrainSampler) Sprite {
    // dev_menu mode replaces every rule with a density heatmap
    if (dw.dev_menu and USE_HEATMAP and !USE_ORE_HEATMAP)
        return @enumFromInt(HEATMAP_BASE + @as(u16, @intFromFloat(s.density * 256.0)));

    // air, plus the two stones which only appear at the density extremes
    const cutoff_density = s.density * s.cutoff;
    if (cutoff_density <= density_min.getF32() or s.density >= density_max.getF32())
        return if (isWithin(s.moisture, 0.93, 0.94)) .purple_strange_stone else .none;
    if (s.density <= 0.04 and isWithin(s.moisture, 0.3, 0.4)) return .blue_strange_stone;

    // the wettest bands, which need no field beyond moisture and cutoff
    if (isWithin(s.moisture, 0.98, 0.995))
        return if (isWithin(s.cutoff, 0.2, 0.3)) .pale_ancient_stone else .ancient_stone;
    if (isWithin(s.moisture, 0.93, 0.955) and s.cutoff >= 0.6) return .bright_red_stone;
    if (s.moisture >= 0.97) return .none;

    s.deep = true;

    // a tagged island caps a surface, so it wins over every stone rule below
    if (s.moisture <= 0.63) {
        const tagged = s.island();
        if (tagged != .none) return tagged;
    }
    if (isWithin(s.moisture, 0.93, 0.94)) return .bright_red_stone;

    s.detail();

    if (isWithin(s.weirdness, 0.6, 0.9) and (isWithin(s.density2, 0.88, 0.915) or s.density >= 0.88))
        return if (s.weirdness >= 0.73 or s.density2 >= 0.95) .molten_stone else .lava_stone;

    if (s.moisture >= 0.50 and isWithin(s.density, 0.53, 0.6))
        return if (s.weirdness >= 0.8) .lime_stone else .green_stone;

    if ((s.weirdness <= 0.55 or s.weirdness >= 0.93) and isWithin(s.moisture, 0.60, 0.72))
        return .blue_stone;
    if (s.weirdness <= 0.1 and s.density >= 0.45 and s.density2 <= 0.55)
        return if (s.moisture >= 0.8) .pale_stone else .deep_blue_stone;

    if (isWithin(s.moisture, 0.20, 0.26))
        return if (isWithin(s.weirdness, 0.72, 0.92)) .more_mossy_stone else .mossy_stone;
    if (isWithin(s.moisture, 0.43, 0.535))
        return if (s.moisture <= 0.48 or s.density2 <= 0.08) .seagreen_stone else .green_stone;

    if (s.density2 <= 0.1) return .dark_stone;
    return .stone;
}

/// Calculates the base terrain sample of one world block, with no cache.
fn computeBaseSpriteType(wx: u32, wy: u32) TerrainData {
    var sampler: TerrainSampler = .init(wx, wy);
    const sprite = classifyTerrain(&sampler);

    return .{
        .sprite = sprite,
        .ore_density = if (sampler.deep)
            fbm(getPerlinNoiseFixed, memory.getHashSeed(.ore_density), wx, wy, 122.0, 3)
        else
            0,
    };
}

/// Checks if a block is near the top surface of an island.
inline fn isTopSurface(wx: u32, wy: u32, density_seed: Vec2u) bool {
    // add surface depth noise variation
    const depth_noise = getPerlinNoiseFixed(density_seed, wx, wy, 6.3);
    const check_offset: u32 = @intFromFloat(1.3 + depth_noise * 0.8);
    const check_y = if (wy >= check_offset) wy - check_offset else 0;

    // sample density above block to detect open space
    var warp_above: Vec2f32 = .{ 0.0, 0.0 };
    const res_above = getFbmValueWarp(
        density_seed,
        wx,
        check_y,
        93.0,
        22.0,
        &warp_above,
    );

    // open space threshold above block
    return res_above.value <= 0.27;
}

/// Number of fractional bits used when a coordinate is placed on a noise lattice.
/// 32 bits provides smooth continuous interpolation at all scales.
const LATTICE_FRAC_BITS = 32;
/// Maximum lattice frequency in cells per block for fixed-point placement.
/// This value limits the step size and caps k in latticeAxis().
const MAX_INV_SCALE = 16.0;
/// Bit position where a coordinate splits for lattice multiplication.
const SPLIT_BIT = 32;
/// Mantissa bits kept in the lattice step.
/// An f32 carries 24 bits, which keeps step splitting exact.
const STEP_MANT_BITS = 24;

/// Maximum bits for base-depth block coordinates.
/// Base depth is enclosed by edge stone, which sets a fixed bound.
pub const BASE_WORLD_BLOCK_BITS: comptime_int =
    dw.startup.STARTING_ZOOM_TIMES * dw.ZOOM_LOG2 + dw.CHUNK_SIZE_LOG2;

/// Maximum coordinate magnitude in bits where f32 stays precise within 1/16 block.
/// At 18 bits, precision gap reaches 1/32 block where quantization becomes visible.
const F32_PLACEMENT_LIMIT_BITS = 18;

/// Enables float placement for Worley noise when coordinates fit in f32 precision.
///
/// Fixed-point placement works at all world sizes.
/// Float placement is faster and gives identical results within the base-depth coordinate range.
const WORLEY_FLOAT_PLACEMENT = BASE_WORLD_BLOCK_BITS <= F32_PLACEMENT_LIMIT_BITS;

/// Maximum coordinate bit width accepted by latticeAxis().
///
/// This limit prevents overflow during split multiplication in 64-bit integers.
/// Octave scaling consumes headroom between this bound and WORLD_COORD_BITS.
const LATTICE_INPUT_BITS: comptime_int = 64 - STEP_MANT_BITS + SPLIT_BIT;

comptime {
    // verify split coordinate multiplication does not overflow 64 bits
    if (seeding.WORLD_COORD_BITS > LATTICE_INPUT_BITS)
        @compileError("A split world coordinate's high half overflows its partial product.");
    if (SPLIT_BIT + STEP_MANT_BITS > 64)
        @compileError("A split world coordinate's low half overflows its partial product.");
    // verify fraction shift stays within lower half
    if (LATTICE_FRAC_BITS > SPLIT_BIT)
        @compileError("The lattice fraction must fit below the split, or recombining loses its carry.");
}

/// Stores one coordinate axis placed on a noise lattice.
///
/// Precalculates interpolated corners for noise sampling.
/// Stores cell position to allow backward steps during Worley noise searches.
const LatticeAxis = struct {
    /// folded hash inputs for current and adjacent cells
    corners: [2]u64,
    /// lower 64 bits of cell index
    cell_low: u64,
    /// upper cell index multiplied by FOLD_MULTIPLIER
    folded: u64,
    /// cell position in range [0, 1)
    t: f32,

    /// Calculates folded hash input for an offset cell.
    ///
    /// Stepping across cell boundaries updates the folded hash using addition
    /// instead of multiplication.
    inline fn corner(self: @This(), comptime offset: comptime_int) u64 {
        if (offset < -1 or offset > 1) @compileError("A lattice corner is at most one cell away.");
        if (offset >= 0) return self.corners[offset];
        const low = self.cell_low -% 1;
        const step = seeding.FOLD_MULTIPLIER & (0 -% @as(u64, @intFromBool(low > self.cell_low)));
        return low ^ (self.folded -% step);
    }
};

/// Maps coordinate axis to lattice with step size equal to 1 / inv_scale
inline fn latticeAxis(v: WorldCoord, inv_scale: f32) LatticeAxis {
    std.debug.assert(inv_scale > 0 and inv_scale <= MAX_INV_SCALE);
    // calculate fixed-point step size for scale
    const step: u64 = @intFromFloat(@round(@as(f64, inv_scale) * (1 << LATTICE_FRAC_BITS)));
    // verify step size is not zero
    std.debug.assert(step != 0);

    // convert step to m << k format without precision loss
    const width = 64 - @clz(step);
    const k: u6 = if (width > STEP_MANT_BITS) @intCast(width - STEP_MANT_BITS) else 0;
    const m = step >> k;
    std.debug.assert(m << k == step);
    const shift: u6 = LATTICE_FRAC_BITS - k;

    const low_half: u64 = @truncate(v & ((1 << SPLIT_BIT) - 1));
    const low_product = low_half *% m;
    // calculate fractional position inside cell
    const frac: u32 = @truncate((low_product & ((@as(u64, 1) << shift) - 1)) << k);
    const t = @as(f32, @floatFromInt(frac)) * INV_POW_2_32;

    // fast path for coordinates under 2^32
    const high_half: u64 = @truncate(v >> SPLIT_BIT);
    if (high_half == 0) {
        const cell = low_product >> shift;
        return .{ .corners = .{ cell, cell +% 1 }, .cell_low = cell, .folded = 0, .t = t };
    }

    const high_product = high_half *% m;
    // calculate split cell index and carry bits
    const cell_low = (high_product << k) +% (low_product >> shift);
    const cell_high = (if (k == 0) 0 else high_product >> @intCast(64 - @as(u7, k))) +
        @intFromBool(cell_low < (high_product << k));

    // fold cell indices with shared multiplication
    const folded = cell_high *% seeding.FOLD_MULTIPLIER;
    const next_low = cell_low +% 1;
    const next_folded = folded +% (seeding.FOLD_MULTIPLIER & (0 -% @as(u64, @intFromBool(next_low == 0))));
    return .{
        .corners = .{ cell_low ^ folded, next_low ^ next_folded },
        .cell_low = cell_low,
        .folded = folded,
        .t = t,
    };
}

/// Returns a struct with an a `value: f64`.
/// Allows for booleans to act like variables when the debug UI is built.
inline fn TuningFloat(comptime default_value: f64) type {
    if (dw.dev_menu) {
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
/// Allows for booleans to act like variables when the debug UI is built.
inline fn TuningBool(comptime default_value: bool) type {
    if (dw.dev_menu) {
        return struct {
            pub var value: bool = default_value;
        };
    } else {
        return struct {
            pub const value: bool = default_value;
        };
    }
}

// When checking these heatmap values, ALWAYS guard with dw.dev_menu.

/// Enables terrain heatmap when dev menu are active.
/// If ore heatmap is enabled then USE_HEATMAP must be true!
pub var USE_HEATMAP = false;
/// Enables ore heatmap when dev menu are active.
/// If ore heatmap is enabled then USE_HEATMAP must be true!
pub var USE_ORE_HEATMAP = false;

/// Memoized base terrain sample for a world block.
///
/// The sprite and the ore density are stored flat rather than as a `TerrainData`,
/// which lets the padding beside the sprite hold `occupied` and keeps the entry at 16 bytes.
const BaseTerrainCacheEntry = struct {
    wx: u32 = 0,
    wy: u32 = 0,
    sprite: Sprite = .none,
    occupied: bool = false,
    ore_density: f32 = 0,
};

comptime {
    // verify the entry keeps its packed size, since the cache holds tens of thousands of them
    if (@sizeOf(BaseTerrainCacheEntry) != 16)
        @compileError("A base terrain cache entry must stay 16 bytes; a wider one doubles the cache's miss rate.");
}

/// Block dimensions for terrain cache tiles.
///
/// The cache covers one simulation row width and 8 chunk rows height.
/// This height prevents cache thrashing during structure generation scans.
const BASE_CACHE_TILE_W = dw.world.SIM_GRID_SIZE;
const BASE_CACHE_TILE_H = dw.CHUNK_SIZE * 8;
/// Direct-mapped cache for base terrain samples.
/// Saves calculated terrain data to prevent repeated FBM noise computations.
const BASE_CACHE_SLOTS = BASE_CACHE_TILE_W * BASE_CACHE_TILE_H;
var base_terrain_cache: [BASE_CACHE_SLOTS]BaseTerrainCacheEntry = @splat(.{});

comptime {
    // verify terrain cache fits within memory limit
    if (@sizeOf(@TypeOf(base_terrain_cache)) > 2 * memory.MemorySizes.MiB)
        @compileError("The base terrain cache exceeds its 2 MiB budget.");
}
/// current cache version key used for cache invalidation
var base_cache_key: u64 = 0;

/// Epoch counter for tuning parameter changes.
/// Updating tuning parameters increments this value and invalidates cached samples.
pub var tuning_epoch: u64 = 0;

/// Increments tuning epoch counter to invalidate terrain caches.
pub fn invalidateTuning() void {
    if (dw.dev_menu) tuning_epoch +%= 1;
}

/// Returns version key for current world seed and tuning state.
pub inline fn terrainGeneration() u64 {
    const seed = memory.getHashSeed(.moisture);
    if (dw.dev_menu) {
        return (seed[0] ^ seed[1]) +% tuning_epoch;
    }
    return seed[0] ^ seed[1];
}

/// Calculates cache index for a block position using tile mapping.
inline fn baseCacheIndex(wx: u32, wy: u32) usize {
    return dw.utils.tileIndex(BASE_CACHE_TILE_W, BASE_CACHE_TILE_H, wx, wy);
}

/// Returns pointer to memoized terrain sample.
///
/// The pointer becomes invalid on subsequent terrain cache accesses.
/// Copy required fields immediately.
inline fn baseTerrainSlot(chunk_x: u32, chunk_y: u32, block_x: u4, block_y: u4) *const BaseTerrainCacheEntry {
    const wx = chunk_x * CHUNK_SIZE + block_x;
    const wy = chunk_y * CHUNK_SIZE + block_y;

    const key = terrainGeneration();
    if (key != base_cache_key) {
        // clear cache entries on key mismatch
        @memset(&base_terrain_cache, .{});
        base_cache_key = key;
    }

    const entry = &base_terrain_cache[baseCacheIndex(wx, wy)];
    if (!(entry.occupied and entry.wx == wx and entry.wy == wy)) {
        const data = computeBaseSpriteType(wx, wy);
        entry.* = .{
            .wx = wx,
            .wy = wy,
            .sprite = data.sprite,
            .ore_density = data.ore_density,
            .occupied = true,
        };
    }
    return entry;
}

/// Returns base terrain data for block coordinates.
/// Calculates density, moisture, and base sprite type.
pub fn getBaseSpriteType(
    chunk_x: u32,
    chunk_y: u32,
    block_x: u4,
    block_y: u4,
) TerrainData {
    const entry = baseTerrainSlot(chunk_x, chunk_y, block_x, block_y);
    return .{ .sprite = entry.sprite, .ore_density = entry.ore_density };
}

/// Returns base terrain sprite for block coordinates without copying a full sample.
pub fn getBaseSprite(chunk_x: u32, chunk_y: u32, block_x: u4, block_y: u4) Sprite {
    return baseTerrainSlot(chunk_x, chunk_y, block_x, block_y).sprite;
}

/// Maximum depth marker indicating unlimited depth.
const NO_DEPTH_LIMIT: u8 = 255;

/// Defines depth limits and probability falloff for ore generation.
const DepthCurve = struct {
    /// minimum depth offset for rule activation
    min_depth: u8 = 0,
    /// maximum depth offset for rule activation
    max_depth: u8 = NO_DEPTH_LIMIT,
    /// probability multiplier per depth step
    falloff: f32 = 1.0,
    /// minimum window scale floor
    floor: f32 = 0.1,
    /// depth offset for peak generation frequency
    peak_offset: u8 = 0,
    peak_boost: f32 = 1.0,
    /// half-width range for peak boost in depth steps
    peak_width: u8 = 1,
};

/// Defines noise parameters and depth rules for ore and gem generation.
const OreDispersal = struct {
    sprite: Sprite,
    depth: DepthCurve = .{},
    scale: f32,
    octaves: u2 = 2,
    hybrid_weight: f32,
    warp_strength: f32,
    val_min: f32,
    val_max: f32,
    min_density: f32,
    max_density: f32,
    seed_lane: u3,

    // stone filter requirements
    forbidden_stone: Sprite = .none,
    required_stone: Sprite = .none,
    gem_chance_scale: f32 = 1.0,
};

/// Rules for ore and gem generation.
/// All rules must operate within density range [0.20, 0.90].
const ORE_DISPERSALS = [_]OreDispersal{
    .{
        .sprite = .copper,
        .depth = .{},
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
        .depth = .{},
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
        .depth = .{},
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
        .depth = .{ .min_depth = 1 },
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
        .depth = .{ .min_depth = 2 },
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
        .depth = .{},
        .scale = 9,
        .octaves = 2,
        .hybrid_weight = 0.45,
        .warp_strength = 0.70,
        .val_min = 0.15,
        .val_max = 0.24,
        .min_density = 0.30,
        .max_density = 0.58,
        .seed_lane = 3,
        .forbidden_stone = .diorite,
        .gem_chance_scale = 0.34,
    },
    .{
        .sprite = .sapphire,
        .depth = .{ .min_depth = 1 },
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
        .gem_chance_scale = 0.65,
    },
    .{
        .sprite = .emerald,
        .depth = .{ .min_depth = 1 },
        .scale = 10,
        .octaves = 2,
        .hybrid_weight = 0.50,
        .warp_strength = 0.70,
        .val_min = 0.45,
        .val_max = 0.48,
        .min_density = 0.34,
        .max_density = 0.62,
        .seed_lane = 3,
        .gem_chance_scale = 0.86,
    },
    .{
        .sprite = .cobalt,
        .depth = .{ .min_depth = 2 },
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
        .depth = .{ .min_depth = 2 },
        .scale = 11,
        .octaves = 2,
        .hybrid_weight = 0.60,
        .warp_strength = 0.65,
        .val_min = 0.22,
        .val_max = 0.24,
        .min_density = 0.26,
        .max_density = 0.54,
        .seed_lane = 4,
        .gem_chance_scale = 1.0,
    },
    .{
        .sprite = .aquashard,
        .depth = .{ .min_depth = 2 },
        .scale = 16,
        .octaves = 2,
        .hybrid_weight = 0.45,
        .warp_strength = 0.50,
        .val_min = 0.40,
        .val_max = 0.45,
        .min_density = 0.20,
        .max_density = 0.34,
        .seed_lane = 2,
        .gem_chance_scale = 0.50,
    },
    .{
        .sprite = .amethyst,
        .depth = .{},
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
        .gem_chance_scale = 0.70,
    },
    .{
        .sprite = .electrit,
        .depth = .{ .min_depth = 3 },
        .scale = 28,
        .octaves = 2,
        .hybrid_weight = 0.70,
        .warp_strength = 0.45,
        .val_min = 0.84,
        .val_max = 0.85,
        .min_density = 0.34,
        .max_density = 0.52,
        .seed_lane = 4,
        .gem_chance_scale = 0.30,
    },
};

comptime {
    @setEvalBranchQuota(1e6);
    for (ORE_DISPERSALS, 0..) |rule, i| {
        // verify rule bounds and parameters
        if (rule.octaves == 0) @compileError("Every ore dispersal needs at least one octave.");
        if (seeding.WORLD_COORD_BITS + @as(comptime_int, rule.octaves) - 1 > LATTICE_INPUT_BITS)
            @compileError("An ore dispersal's octave stack scales a world coordinate past what the lattice's split multiply can carry.");
        if (rule.octaves > ORE_OCTAVE_SEEDS.len)
            @compileError("An ore dispersal has more octaves than there is octave seed material for.");
        if (rule.scale <= 0) @compileError("Ore scale must be strictly positive.");
        if (rule.val_min >= rule.val_max) @compileError("Ore value window bounds must be strictly ordered (val_min < val_max).");
        if (rule.val_min < 0 or rule.val_max > 1) @compileError("Ore value window bounds must be normalized in [0, 1].");
        if (rule.min_density >= rule.max_density) @compileError("Ore density bounds must be strictly ordered (min_density < max_density).");
        if (rule.min_density < 0 or rule.max_density > 1) @compileError("Ore density bounds must be normalized in [0, 1].");
        if (rule.hybrid_weight < 0 or rule.hybrid_weight > 1) @compileError("Ore hybrid weights must be normalized in [0, 1].");
        if (rule.warp_strength < 0 or rule.warp_strength > 1) @compileError("Ore warp strengths must be normalized in [0, 1].");
        if (rule.gem_chance_scale <= 0) @compileError("Gem chance scale must be strictly positive.");

        // verify stone filter parameters
        if (rule.required_stone != .none and rule.forbidden_stone != .none and rule.required_stone == rule.forbidden_stone) {
            @compileError("Ore rule cannot have identical required_stone and forbidden_stone.");
        }

        // verify rule is not shadowed by an earlier rule
        for (ORE_DISPERSALS[0..i]) |earlier| {
            const same_lane = (earlier.seed_lane == rule.seed_lane);
            const same_noise_config = (earlier.scale == rule.scale and earlier.octaves == rule.octaves and
                earlier.hybrid_weight == rule.hybrid_weight and earlier.warp_strength == rule.warp_strength);
            const depth_subsumed = (earlier.depth.min_depth <= rule.depth.min_depth);
            const density_subsumed = (earlier.min_density <= rule.min_density and earlier.max_density >= rule.max_density);
            const val_subsumed = (earlier.val_min <= rule.val_min and earlier.val_max >= rule.val_max);
            const gem_subsumed = (!earlier.sprite.isGem() or (earlier.sprite.isGem() and earlier.gem_chance_scale >= rule.gem_chance_scale));

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

/// Holds independent seed vectors for ore fields and gem rolls.
pub const OreSeeds = struct {
    /// field seed vector
    field: Vec2u,
    /// gem seed vector
    gem: Vec2u,

    /// returns seed streams for base depth terrain
    pub inline fn atBaseDepth() OreSeeds {
        return .{
            .field = memory.getHashSeed(.ores1),
            .gem = memory.getHashSeed(.gems),
        };
    }

    /// returns seed streams derived from chunk seed
    pub inline fn fromChunkSeed(seed: Vec2u) OreSeeds {
        return .{ .field = seed, .gem = seed ^ @as(Vec2u, GEM_STREAM_MASK) };
    }
};

/// XOR mask used to derive gem stream from chunk seed.
const GEM_STREAM_MASK: [2]u64 = .{ 0x6c5a3f81e0b7d925, 0xa93e17c4582df6b3 };

/// Defines host-specific density overrides for ores.
const DensityOverride = struct { sprite: Sprite, host: Sprite, min: f32, max: f32 };
const DENSITY_OVERRIDES = [_]DensityOverride{
    .{ .sprite = .gold, .host = .lava_stone, .min = 0.52, .max = 0.71 },
    .{ .sprite = .silver, .host = .blue_strange_stone, .min = 0.18, .max = 0.20 },
};

/// Minimum and maximum density range enclosing all ore rules.
const DENSITY_GATE: struct { min: f32, max: f32 } = blk: {
    var lo: f32 = 1.0;
    var hi: f32 = 0.0;
    for (ORE_DISPERSALS) |rule| {
        lo = @min(lo, rule.min_density);
        hi = @max(hi, rule.max_density);
        for (DENSITY_OVERRIDES) |o| {
            if (o.sprite != rule.sprite) continue;
            lo = @min(lo, o.min);
            hi = @max(hi, o.max);
        }
    }
    break :blk .{ .min = lo, .max = hi };
};

comptime {
    // verify density override sprites exist in rules
    for (DENSITY_OVERRIDES) |o| {
        var found = false;
        for (ORE_DISPERSALS) |rule| {
            if (rule.sprite == o.sprite) found = true;
        }
        if (!found) @compileError("A density override names a sprite that no ore dispersal rule places.");
        if (o.min >= o.max) @compileError("Density override bounds must be strictly ordered.");
    }
}

/// Defines calculated value window for an ore rule at current depth.
const DepthWindow = struct {
    val_min: f32 = 0,
    val_max: f32 = 0,
    /// indicates if rule is active at current depth
    live: bool = false,
};

/// Calculates value window for a rule at target depth.
fn evaluateDepthCurve(comptime rule: OreDispersal, depth: u64) DepthWindow {
    const base = dw.startup.STARTING_ZOOM_TIMES;
    const first = base + @as(u64, rule.depth.min_depth);
    if (depth < first) return .{};
    if (rule.depth.max_depth != NO_DEPTH_LIMIT and depth > base + @as(u64, rule.depth.max_depth)) return .{};

    const steps: f32 = @floatFromInt(depth - first);
    const falloff = std.math.clamp(rule.depth.falloff, 0.0, 1.0);
    var scale = @max(std.math.pow(f32, falloff, steps), rule.depth.floor);

    // apply peak boost taper if depth is within peak range
    if (rule.depth.peak_boost != 1.0) {
        const offset: i64 = @as(i64, @intCast(depth)) - @as(i64, base);
        const distance = @abs(offset - @as(i64, rule.depth.peak_offset));
        const width: i64 = @max(1, rule.depth.peak_width);
        if (distance < width) {
            const taper = 1.0 - @as(f32, @floatFromInt(distance)) / @as(f32, @floatFromInt(width));
            scale *= 1.0 + (rule.depth.peak_boost - 1.0) * taper;
        }
    }

    if (scale <= 0.0) return .{};

    // scale window width around center point
    const center = (rule.val_min + rule.val_max) * 0.5;
    const half = (rule.val_max - rule.val_min) * 0.5 * scale;
    if (half <= 0.0) return .{};
    return .{ .val_min = center - half, .val_max = center + half, .live = true };
}

/// Cached depth windows for all ore dispersal rules.
var depth_windows: [ORE_DISPERSALS.len]DepthWindow = @splat(.{});
var depth_windows_depth: ?u64 = null;

/// Density bounds for active rules at current depth.
var depth_density_min: f32 = 1.0;
var depth_density_max: f32 = 0.0;

/// Refreshes depth windows and active density bounds for specified depth.
fn refreshDepthWindows(depth: u64) void {
    var lo: f32 = 1.0;
    var hi: f32 = 0.0;
    inline for (ORE_DISPERSALS, 0..) |rule, i| {
        const window = evaluateDepthCurve(rule, depth);
        depth_windows[i] = window;
        if (window.live) {
            lo = @min(lo, rule.min_density);
            hi = @max(hi, rule.max_density);
            inline for (DENSITY_OVERRIDES) |o| {
                if (comptime o.sprite == rule.sprite) {
                    lo = @min(lo, o.min);
                    hi = @max(hi, o.max);
                }
            }
        }
    }
    depth_density_min = lo;
    depth_density_max = hi;
    depth_windows_depth = depth;
}

inline fn depthWindows(depth: u64) *const [ORE_DISPERSALS.len]DepthWindow {
    if (dw.dev_menu or depth_windows_depth != depth) refreshDepthWindows(depth);
    return &depth_windows;
}

/// Clears cached depth window data.
pub fn resetDepthWindows() void {
    depth_windows_depth = null;
}

/// Seed XOR constants for independent ore field lanes.
const ORE_LANE_SEEDS: [8][2]u64 = .{
    .{ 0xb7f1cfa12450e9f9, 0x176c164a9f199a98 },
    .{ 0x1c3d2d40e60a737b, 0x8b7d7caca6ed228b },
    .{ 0x55f120d0551ae197, 0x29715923ebd1ff25 },
    .{ 0xaf487e87cf54a607, 0x805520a776a4eaaf },
    .{ 0x164be9dae1cdfe41, 0x7cfa3b4c2323b05d },
    .{ 0xc1cdeb9a1bbc84c3, 0xbb3f8c4cd49bd8ce },
    .{ 0xd92f2a2b09a9ea01, 0xd017c873ecec90e7 },
    .{ 0x5a92a612e519eb78, 0x4b7c049be9f4db4f },
};

/// Seed XOR constants for noise octaves.
const ORE_OCTAVE_SEEDS: [4][2]u64 = .{
    .{ 0x0000000000000000, 0x0000000000000000 },
    .{ 0x98a4f70f98ec57f3, 0x73eac76ed50e3b40 },
    .{ 0x75b81dac07fd3343, 0x545acc54663237ae },
    .{ 0x9397c188bcd8b549, 0x2df9b8307df48403 },
};

comptime {
    // combine seed tables for validation
    const ALL_SEEDS = ORE_LANE_SEEDS ++ ORE_OCTAVE_SEEDS;

    for (ALL_SEEDS, 0..) |a, i| {
        const is_lane = i < ORE_LANE_SEEDS.len;
        const table_name = if (is_lane) "ORE_LANE_SEEDS" else "ORE_OCTAVE_SEEDS";
        const idx = if (is_lane) i else i - ORE_LANE_SEEDS.len;

        // skip first octave
        if (!is_lane and idx == 0) continue;

        // verify first word popcount
        const pc1 = @popCount(a[0]);
        if (pc1 < 28 or pc1 > 36) {
            @compileError(std.fmt.comptimePrint(
                "{s}[{d}][0] has popcount {d}, expected 28-36 inclusive.",
                .{ table_name, idx, pc1 },
            ));
        }

        // verify second word popcount
        const pc2 = @popCount(a[1]);
        if (pc2 < 28 or pc2 > 36) {
            @compileError(std.fmt.comptimePrint(
                "{s}[{d}][1] has popcount {d}, expected 28-36 inclusive.",
                .{ table_name, idx, pc2 },
            ));
        }

        // verify seed words are unique
        for (ALL_SEEDS[0..i], 0..) |b, prev_i| {
            if (a[0] == b[0] or a[1] == b[1]) {
                const prev_is_lane = prev_i < ORE_LANE_SEEDS.len;
                const prev_name = if (prev_is_lane) "ORE_LANE_SEEDS" else "ORE_OCTAVE_SEEDS";
                const prev_idx = if (prev_is_lane) prev_i else prev_i - ORE_LANE_SEEDS.len;

                @compileError(std.fmt.comptimePrint(
                    "Ore seed collision: {s}[{d}] collides with {s}[{d}]",
                    .{ table_name, idx, prev_name, prev_idx },
                ));
            }
        }
    }
}

/// Calculates normalized noise field value for an ore rule.
///
/// Deliberately NOT `inline`: `lane` and `rule` are `comptime`,
/// so Zig already makes one specialization per rule and nothing is lost.
/// `disperseOre()` unrolls 13 rules, and inlining a whole FBM evaluation into each copy
/// made that one function large enough to dominate the Debug build.
///
/// LLVM cost-per-func is quadratic in basic-block count, and `ReleaseFast` inlines this again anyway!
fn oreField(seed: Vec2u, x: WorldCoord, y: WorldCoord, comptime lane: u3, comptime rule: OreDispersal) f32 {
    const inv_scale = 1.0 / rule.scale;
    // derive lane seed
    const lane_seed = seed ^ @as(Vec2u, ORE_LANE_SEEDS[lane]);

    // calculate domain warp
    const warp = getDualValueNoiseFixed(lane_seed, x, y, inv_scale * 0.4);
    const warp_amt = rule.scale * rule.warp_strength;
    const warp_x: i64 = @intFromFloat((warp[0] - 0.5) * warp_amt);
    const warp_y: i64 = @intFromFloat((warp[1] - 0.5) * warp_amt);
    // apply domain warp to coordinates
    const sample_x = shiftWorld(x, warp_x);
    const sample_y = shiftWorld(y, warp_y);

    var value: f32 = 0;
    // evaluate noise octaves
    comptime var weight: f32 = 0;

    inline for (0..rule.octaves) |octave| {
        const amp: f32 = 1.0 / @as(f32, @floatFromInt(@as(u32, 1) << octave));
        // evaluate octave value
        const n = getDualValueNoiseFixed(
            lane_seed ^ @as(Vec2u, ORE_OCTAVE_SEEDS[octave]),
            sample_x << octave,
            sample_y << octave,
            inv_scale * @as(f32, @floatFromInt(@as(u32, 1) << octave)),
        )[octave & 1];

        const ridged = 1.0 - @abs(2.0 * n - 1.0);
        value += amp * (n * (1.0 - rule.hybrid_weight) + ridged * rule.hybrid_weight);
        weight += amp;
    }
    return value / weight;
}

/// Evaluates ore and gem generation for a stone block.
/// Returns sprite type if generation conditions are satisfied.
pub fn disperseOre(
    host: Sprite,
    density: f32,
    x: WorldCoord,
    y: WorldCoord,
    depth: u64,
    seeds: OreSeeds,
    host_tag: dw.refine.RefinedTag,
) ?Sprite {
    const seed = seeds.field;
    if (!host.isStone()) return null;
    if (host_tag.blocksOverlay()) return null;

    // check global density gate
    if (density < DENSITY_GATE.min or density > DENSITY_GATE.max) return null;

    // resolve depth windows and check active density bounds
    var gem_roll_cache: ?f32 = null;
    const windows = depthWindows(depth);

    // check active depth density bounds
    if (density < depth_density_min or density > depth_density_max) return null;

    inline for (ORE_DISPERSALS, 0..) |rule, ri| {
        next_rule: {
            // check depth and stone type requirements
            const window = windows[ri];
            if (!window.live) break :next_rule;
            if (rule.forbidden_stone != .none and host == rule.forbidden_stone) break :next_rule;
            if (rule.required_stone != .none and host != rule.required_stone) break :next_rule;

            // apply host density overrides
            var min_d = rule.min_density;
            var max_d = rule.max_density;
            inline for (DENSITY_OVERRIDES) |o| {
                if (comptime o.sprite == rule.sprite) {
                    if (host == o.host) {
                        min_d = o.min;
                        max_d = o.max;
                    }
                }
            }

            if (density < min_d or density > max_d) break :next_rule;

            // check gem roll probability
            if (rule.sprite.isGem()) {
                const gem_roll = gem_roll_cache orelse b: {
                    const roll = FastHash.float2d_32(seeds.gem, seeding.foldWorld(x), seeding.foldWorld(y));
                    gem_roll_cache = roll;
                    break :b roll;
                };

                const purple_boost: f32 = if (host == .purple_strange_stone) 1.33 else 1.0;
                const target_odds = base_gem_odds.getF32() * rule.gem_chance_scale * purple_boost;
                if (gem_roll > target_odds) break :next_rule;
            }

            const val = oreField(seed, x, y, rule.seed_lane, rule);
            if (val >= window.val_min and val <= window.val_max) return rule.sprite;
        }
    }

    return null;
}

/// Generates ores and gems for base depth terrain.
pub fn addOresAndGems(base_data: TerrainData, x: WorldCoord, y: WorldCoord) Sprite {
    if (dw.dev_menu and USE_HEATMAP and USE_ORE_HEATMAP) {
        const field = oreField(OreSeeds.atBaseDepth().field, x, y, 0, ORE_DISPERSALS[0]);
        return @enumFromInt(65000 + @as(u20, @intFromFloat(field * 256.0)));
    }

    return disperseOre(
        base_data.sprite,
        base_data.ore_density,
        x,
        y,
        dw.startup.STARTING_ZOOM_TIMES,
        .atBaseDepth(),
        .{},
    ) orelse base_data.sprite;
}

test "ore dispersal produces deposits at base and recursive depths" {
    // verify ore generation at base and recursive depths
    const seed: Vec2u = .{ 0x123456789ABCDEF0, 0x0FEDCBA987654321 };
    var base_count: usize = 0;
    var deep_count: usize = 0;

    for (0..256) |y| {
        for (0..256) |x| {
            if (disperseOre(.stone, 0.5, x, y, dw.startup.STARTING_ZOOM_TIMES, .fromChunkSeed(seed), .{})) |ore| {
                base_count += 1;
                _ = ore;
            }
            if (disperseOre(.stone, 0.5, x, y, dw.startup.STARTING_ZOOM_TIMES + 3, .fromChunkSeed(seed), .{}) != null) deep_count += 1;

            // verify refined tags block ore generation
            try std.testing.expect(disperseOre(
                .stone,
                0.5,
                x,
                y,
                dw.startup.STARTING_ZOOM_TIMES + 3,
                .fromChunkSeed(seed),
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

    // verify wide coordinates do not repeat values
    const origin: WorldCoord = 1 << 68 | 12345;
    for ([_]WorldCoord{ 1 << 32, 1 << 53, 1 << 64 }) |period| {
        const here = getDualValueNoise(seed, origin, origin, scale);
        const away = getDualValueNoise(seed, origin +% period, origin, scale);
        try std.testing.expect(here[0] != away[0]);
    }

    // verify precision across adjacent coordinates
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
    // verify cell adjacency across 2^64 coordinate boundary
    const scale = 1.0 / 4.0;
    const boundary: WorldCoord = @as(WorldCoord, 1) << 64;
    for ([_]WorldCoord{ boundary - 8, boundary - 4, boundary, boundary + 4 }) |v| {
        const here = latticeAxis(v, scale);
        const next = latticeAxis(v + 4, scale);
        try std.testing.expectEqual(here.corner(1), next.corner(0));
    }

    // verify fractional cell position
    const quarter = latticeAxis(boundary + 1, scale);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), quarter.t, 1e-6);
}

test "the split lattice multiply agrees with a plain 128-bit one" {
    // verify split lattice multiply matches 128-bit calculation
    const scales = [_]f32{ 1.0 / 375.0, 1.0 / 93.75, 1.0 / 21.0, 1.0 / 7.0, 1.0 / 3.0, 1.0, 2.0, MAX_INV_SCALE };
    const limit = @as(WorldCoord, 1) << seeding.WORLD_COORD_BITS;

    var state: u64 = 0x9E3779B97F4A7C15;
    for (0..4096) |i| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        // generate coordinates across small, medium, and large ranges
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

/// Returns true when value is between minimum and maximum bounds.
pub inline fn isWithin(v: f32, min: comptime_float, max: comptime_float) bool {
    if (max <= min) @compileError("Maximum value must be larger than minimum value.");
    return v >= min and v <= max;
}

/// Calculates quintic smootherstep fade curve.
inline fn fade(t: f32) f32 {
    // Alternative: -20t^7 + 70t^6 - 84t^5 + 35t^4.
    // const u = tx * tx * tx * tx * (tx * (tx * (35.0 - 20.0 * tx) - 84.0) + 70.0);
    // const v = ty * ty * ty * ty * (ty * (ty * (35.0 - 20.0 * ty) - 84.0) + 70.0);
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

/// Calculates Worley FBM noise and writes domain warp vector.
fn getFbmValueWarp(
    seed_vector: Vec2u,
    x: WorldCoord,
    y: WorldCoord,
    comptime cell_size_base: f32,
    fbm_shift_size: f32,
    out_warp: *Vec2f32,
) WorleyResult {
    const fbm_octaves = 3;
    var warp_x: f32 = 0;
    var warp_y: f32 = 0;

    var amp: f32 = fbm_shift_size;
    const inv_dual_value_scale = 1.0 / dual_value_scale.getF32();

    if (fbm_shift_size > 0) {
        inline for (0..fbm_octaves) |octave| {
            const n = getDualValueNoiseTuned(
                seed_vector,
                x << octave,
                y << octave,
                inv_dual_value_scale,
            );
            warp_x += n[0] * amp;
            warp_y += n[1] * amp;
            amp *= 0.50; // halve the amplitude of this octave
        }
        out_warp.* = .{ warp_x / fbm_shift_size, warp_y / fbm_shift_size };
    }

    return getFbmValuePrewarped(seed_vector, x, y, cell_size_base, warp_x, warp_y);
}

/// Splits warp offset into integer block displacement and fractional remainder.
const WarpSplit = struct {
    /// integer block displacement
    blocks: i64,
    /// fractional block remainder in range [0, 1)
    frac: f32,
};

inline fn splitWarp(warp: f32) WarpSplit {
    const whole = @floor(warp);
    return .{ .blocks = @intFromFloat(whole), .frac = warp - whole };
}

/// Adds signed block offset to world coordinate.
inline fn shiftWorld(v: WorldCoord, blocks: i64) WorldCoord {
    return v +% @as(WorldCoord, @bitCast(@as(i128, blocks)));
}

/// Stores three candidate cells and fractional offset for one warped Worley axis.
const WorleyAxis = struct {
    /// hash inputs for adjacent cells
    corners: [3]u64,
    /// cell position in range [0, 1)
    t: f32,
    /// fractional warp offset
    frac: f32,

    inline fn corner(self: @This(), comptime offset: comptime_int) u64 {
        return self.corners[offset + 1];
    }
};

/// Candidate cell offsets for Worley search.
const WORLEY_OFFSETS = [_]comptime_int{ -1, 0, 1 };
/// Total candidate cell count for Worley search.
const WORLEY_TAPS = WORLEY_OFFSETS.len * WORLEY_OFFSETS.len;

/// The (`x`, `y`) cell offset of each Worley tap, in tap order.
/// One table drives the hash gather and the distance pass,
/// so the two can never disagree about which cell a tap belongs to.
const WORLEY_TAP_CELLS: [WORLEY_TAPS][2]i2 = blk: {
    var cells: [WORLEY_TAPS][2]i2 = undefined;
    var tap = 0;
    for (WORLEY_OFFSETS) |oy| {
        for (WORLEY_OFFSETS) |ox| {
            cells[tap] = .{ ox, oy };
            tap += 1;
        }
    }
    break :blk cells;
};

/// Bits each unit fraction packed in a Worley cell hash occupies.
/// Three fractions fit in one hash: the feature point's x, its y, and the cell weight.
const WORLEY_FIELD_BITS = 21;
const INV_WORLEY_FIELD: f32 = 1.0 / @as(f32, 1 << WORLEY_FIELD_BITS);

comptime {
    // verify the three packed fields fit in one hash
    if (3 * WORLEY_FIELD_BITS > 64) @compileError("A Worley cell hash cannot hold three fields this wide.");
}

/// Reads packed field `index` out of a Worley cell hash as a fraction in [0, 1).
inline fn hashField(h: u64, comptime index: u2) f32 {
    const bits: u21 = @truncate(h >> (@as(u6, index) * WORLEY_FIELD_BITS));
    return @as(f32, @floatFromInt(bits)) * INV_WORLEY_FIELD;
}

/// Maps warped coordinate axis to candidate cells.
inline fn placeWorley(comptime float_placement: bool, v: WorldCoord, inv_cell: f32, warp: f32) WorleyAxis {
    if (comptime float_placement) {
        // convert coordinate to float when fits in f32 precision
        const w = @as(f32, @floatFromInt(@as(u32, @intCast(v)))) + warp;
        const cell_f = @floor(w * inv_cell);
        const cell: u64 = @bitCast(@as(i64, @intFromFloat(cell_f)));
        return .{
            .corners = .{ cell -% 1, cell, cell +% 1 },
            .t = w * inv_cell - cell_f,
            .frac = 0.0,
        };
    }
    const s = splitWarp(warp);
    const axis = latticeAxis(shiftWorld(v, s.blocks), inv_cell);
    return .{
        .corners = .{ axis.corner(-1), axis.corner(0), axis.corner(1) },
        .t = axis.t,
        .frac = s.frac,
    };
}

/// Calculates Worley cellular noise using domain warp offsets.
fn getFbmValuePrewarped(
    seed_vector: Vec2u,
    x: WorldCoord,
    y: WorldCoord,
    comptime cell_size_base: f32,
    warp_x: f32,
    warp_y: f32,
) WorleyResult {
    return worleyValue(WORLEY_FLOAT_PLACEMENT, seed_vector, x, y, cell_size_base, warp_x, warp_y);
}

/// Calculates Worley cellular noise with explicit placement route.
fn worleyValue(
    comptime float_placement: bool,
    seed_vector: Vec2u,
    x: WorldCoord,
    y: WorldCoord,
    comptime cell_size_base: f32,
    warp_x: f32,
    warp_y: f32,
) WorleyResult {
    const cell_size = cell_size_base * procedural_cell_size.getF32();
    const inv_cell_size = 1.0 / cell_size;
    const h_stretch = 1.5;
    const cell_w = cell_size * h_stretch;
    const inv_cell_w = 1.0 / cell_w;

    // map warped axes to candidate cells
    const ax = placeWorley(float_placement, x, inv_cell_w, warp_x);
    const ay = placeWorley(float_placement, y, inv_cell_size, warp_y);

    // hash the 3x3 candidate grid, four cells per vector lookup and the ninth on its own
    var hashes: [WORLEY_TAPS]u64 = undefined;
    inline for (0..WORLEY_TAPS / 4) |group| {
        var cx: Vec4u = undefined;
        var cy: Vec4u = undefined;
        inline for (0..4) |i| {
            const tap = WORLEY_TAP_CELLS[group * 4 + i];
            cx[i] = ax.corner(tap[0]);
            cy[i] = ay.corner(tap[1]);
        }
        const h = FastHash.hash2d_4x(seed_vector, cx, cy);
        inline for (0..4) |i| hashes[group * 4 + i] = h[i];
    }
    inline for (WORLEY_TAPS - WORLEY_TAPS % 4..WORLEY_TAPS) |i| {
        const tap = WORLEY_TAP_CELLS[i];
        hashes[i] = FastHash.hash2d(seed_vector, ax.corner(tap[0]), ay.corner(tap[1]));
    }

    // Measure every candidate first, then reduce.
    // The measurement carries no dependency between taps, so it vectorizes;
    // folding it into the reduction below would serialize nine divisions.
    var dist_sq: [WORLEY_TAPS]f32 = undefined;
    inline for (0..WORLEY_TAPS) |i| {
        const tap = WORLEY_TAP_CELLS[i];
        const off_x = hashField(hashes[i], 0);
        const off_y = hashField(hashes[i], 1);

        // a non-uniform cell scale keeps the cells from reading as a grid
        const cell_weight = 0.6 + 0.9 * hashField(hashes[i], 2);

        const dx_span = (ax.t - @as(f32, tap[0]) - off_x) * cell_w;
        const dy_span = (ay.t - @as(f32, tap[1]) - off_y) * cell_size;
        const dx = if (comptime float_placement) dx_span else dx_span + ax.frac;
        const dy = if (comptime float_placement) dy_span else dy_span + ay.frac;

        dist_sq[i] = (dx * dx + dy * dy) / (cell_weight * cell_weight);
    }

    // keep the two nearest feature points; their gap is the cell edge signal
    var d1_sq = std.math.inf(f32);
    var d2_sq = std.math.inf(f32);
    var best_hash: u64 = 0;
    inline for (0..WORLEY_TAPS) |i| {
        if (dist_sq[i] < d1_sq) {
            d2_sq = d1_sq;
            d1_sq = dist_sq[i];
            best_hash = hashes[i];
        } else if (dist_sq[i] < d2_sq) {
            d2_sq = dist_sq[i];
        }
    }

    const raw = @min((@sqrt(d2_sq) - @sqrt(d1_sq)) * inv_cell_size, 1.0);
    return .{ .value = raw, .cell_hash = best_hash };
}

/// Calculates two independent value noise components.
pub fn getDualValueNoise(seed: Vec2u, x: WorldCoord, y: WorldCoord, inv_scale: f32) Vec2f32 {
    return dualValueNoise(seed, x, y, inv_scale);
}

/// Calculates dual value noise with fixed compile-time scale.
pub inline fn getDualValueNoiseFixed(
    seed: Vec2u,
    x: WorldCoord,
    y: WorldCoord,
    comptime inv_scale: f32,
) Vec2f32 {
    return dualValueNoise(seed, x, y, inv_scale);
}

/// Selects dual value noise variant based on dev menu state.
inline fn getDualValueNoiseTuned(seed: Vec2u, x: WorldCoord, y: WorldCoord, inv_scale: f32) Vec2f32 {
    if (dw.dev_menu) return getDualValueNoise(seed, x, y, inv_scale);
    return getDualValueNoiseFixed(seed, x, y, inv_scale);
}

inline fn dualValueNoise(seed: Vec2u, x: WorldCoord, y: WorldCoord, inv_scale: f32) Vec2f32 {
    const l = lattice(seed, x, y, inv_scale);
    // the two components read opposite halves of the same four hashes
    return .{
        bilerp(unitFloats(l.h, 0), l.u, l.v),
        bilerp(unitFloats(l.h, 1), l.u, l.v),
    };
}

/// Normalization factor for perlin noise range.
pub const PERLIN_NORM: f32 = @sqrt(2.0);

/// Calculates dot product for perlin gradient direction.
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

/// One noise cell: the sample's position inside it, its fade weights, and its four corner hashes.
/// Every lattice noise function in this file is built out of this plus one of the readers below.
const Lattice = struct {
    /// sample position inside the cell on each axis, in [0, 1)
    tx: f32,
    ty: f32,
    /// faded interpolation weights of `tx` and `ty`
    u: f32,
    v: f32,
    /// corner hashes, ordered `v00`, `v10`, `v01`, `v11`
    h: Vec4u,
};

/// Places a sample on a lattice of cells `1 / inv_scale` blocks wide and hashes its four corners.
inline fn lattice(seed_vector: Vec2u, x: WorldCoord, y: WorldCoord, inv_scale: f32) Lattice {
    const ax = latticeAxis(x, inv_scale);
    const ay = latticeAxis(y, inv_scale);
    const x0 = ax.corner(0);
    const x1 = ax.corner(1);
    const y0 = ay.corner(0);
    const y1 = ay.corner(1);
    return .{
        .tx = ax.t,
        .ty = ay.t,
        .u = fade(ax.t),
        .v = fade(ay.t),
        .h = FastHash.hash2d_4x(seed_vector, .{ x0, x1, x0, x1 }, .{ y0, y0, y1, y1 }),
    };
}

/// Interpolates a cell's four corner values, ordered `v00`, `v10`, `v01`, `v11`.
inline fn bilerp(c: Vec4f32, u: f32, v: f32) f32 {
    const nx0 = c[0] + u * (c[1] - c[0]);
    const nx1 = c[2] + u * (c[3] - c[2]);
    return nx0 + v * (nx1 - nx0);
}

/// Maps one 32-bit half of four corner hashes to unit floats.
/// The two halves are independent, which is what lets one lookup drive two noise fields.
inline fn unitFloats(h: Vec4u, comptime half: u1) Vec4f32 {
    const shifted = h >> @as(Vec4u, @splat(@as(u64, half) * 32));
    const truncated: @Vector(4, u32) = @truncate(shifted);
    const floats: Vec4f32 = @floatFromInt(truncated);
    return floats * @as(Vec4f32, @splat(INV_POW_2_32));
}

/// Maps four corner hashes to unit floats across their full width.
inline fn unitFloatsWide(h: Vec4u) Vec4f32 {
    const floats: Vec4f32 = @floatFromInt(h);
    return floats * @as(Vec4f32, @splat(1.0 / @as(f32, POW_2_64)));
}

/// Interpolates a cell's four corner gradients and normalizes the result to [0, 1].
inline fn gradLerp(l: Lattice) f32 {
    const g: Vec4f32 = .{
        grad2(l.h[0], l.tx, l.ty),
        grad2(l.h[1], l.tx - 1.0, l.ty),
        grad2(l.h[2], l.tx, l.ty - 1.0),
        grad2(l.h[3], l.tx - 1.0, l.ty - 1.0),
    };
    return std.math.clamp(bilerp(g, l.u, l.v) * PERLIN_NORM * 0.5 + 0.5, 0.0, 1.0);
}

/// Calculates Perlin gradient noise.
pub inline fn getPerlinNoise(seed_vector: Vec2u, x: WorldCoord, y: WorldCoord, cell_size: f32) f32 {
    return perlinNoise(seed_vector, x, y, cell_size);
}

/// Calculates Perlin gradient noise with fixed compile-time cell size.
pub inline fn getPerlinNoiseFixed(
    seed_vector: Vec2u,
    x: WorldCoord,
    y: WorldCoord,
    comptime cell_size: f32,
) f32 {
    return perlinNoise(seed_vector, x, y, cell_size);
}

inline fn perlinNoise(seed_vector: Vec2u, x: WorldCoord, y: WorldCoord, cell_size: f32) f32 {
    return gradLerp(lattice(seed_vector, x, y, 1.0 / cell_size));
}

/// Calculates billow noise from Perlin gradient field.
pub fn getBillowNoise(seed_vector: Vec2u, x: WorldCoord, y: WorldCoord, cell_size: f32) f32 {
    const signed = getPerlinNoise(seed_vector, x, y, cell_size) * 2.0 - 1.0;
    return @abs(signed);
}

/// Calculates hybrid value and gradient noise.
pub fn getHybridNoise(seed_vector: Vec2u, x: WorldCoord, y: WorldCoord, cell_size: f32) f32 {
    const l = lattice(seed_vector, x, y, 1.0 / cell_size);

    // one corner lookup feeds both halves of the mix
    const val = bilerp(unitFloatsWide(l.h), l.u, l.v);
    const grad = gradLerp(l);
    return val + hybrid_weight.getF32() * (grad - val);
}

/// Normalization factor for simplex noise.
pub const SIMPLEX_NORM: f32 = 70.0;

const F2: f32 = @sqrt(3.0) - 1.0 / 2.0;
const G2: f32 = (3.0 - @sqrt(3.0)) / 6.0;

/// Calculates 2D simplex noise.
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

    // select simplex triangle region
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

/// Calculates fractal Brownian motion using octave noise functions.
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

test "Worley placement keeps sub-block resolution at any world size" {
    // verify Worley fixed-point placement precision
    const seed: Vec2u = .{ 0x452821e638d01377, 0xbe5466cf34e90c6c };
    const origin: WorldCoord = 1 << 34;

    var distinct: usize = 0;
    var previous: f32 = -1;
    for (0..16) |i| {
        const res = worleyValue(false, seed, origin + i, origin, 93.0, 0.0, 0.0);
        if (res.value != previous) distinct += 1;
        previous = res.value;
    }
    try std.testing.expect(distinct >= 12);

    // verify field continuity
    var worst: f32 = 0;
    for (0..64) |i| {
        const a = worleyValue(false, seed, origin + i, origin, 93.0, 0.0, 0.0).value;
        const b = worleyValue(false, seed, origin + i + 1, origin, 93.0, 0.0, 0.0).value;
        worst = @max(worst, @abs(a - b));
    }
    try std.testing.expect(worst < 0.25);
}

test "an ore lane is not a translated copy of another lane" {
    // verify ore lanes generate distinct noise fields
    const seed: Vec2u = .{ 0x9216d5d98979fb1b, 0xd1310ba698dfb5ac };
    const rule = ORE_DISPERSALS[0];
    var equal: usize = 0;
    for (0..512) |i| {
        const p: WorldCoord = 1000 + i * 7;
        if (oreField(seed, p, p, 0, rule) == oreField(seed, p, p, 1, rule)) equal += 1;
    }
    try std.testing.expect(equal < 8);
}

test "both Worley placement routes describe the same field" {
    // verify float and fixed-point placement agreement
    const seed: Vec2u = .{ 0x452821e638d01377, 0xbe5466cf34e90c6c };
    for (0..200) |yy| for (0..200) |xx| {
        const x: WorldCoord = 5000 + xx * 3;
        const y: WorldCoord = 7000 + yy * 3;
        const a = worleyValue(
            true,
            seed,
            x,
            y,
            93.0,
            3.25,
            -7.75,
        ).value;
        const b = worleyValue(
            false,
            seed,
            x,
            y,
            93.0,
            3.25,
            -7.75,
        ).value;
        try std.testing.expectApproxEqAbs(a, b, 1e-4);
    };
}
