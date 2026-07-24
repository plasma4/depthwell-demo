//! Handles fractal ancestry and lookup logic.
//! Contains the core procedural logic for infinite-depth zooming and recursive terrain logic, using various functions:
//! - `getInheritedMaterial()` traces the "block lineage" up to parent depths,
//!   preserving `mod_store` changes; caches results in `AncestorCache`.
//! - `applyAncestorLogic()` and slope logic create continuous sloped surfaces,
//!   based on parent blocks using bilinear 4-corner density
//! - Ancestor logic also uses noise masks, displaces blocks (`warpField()`),
//! and both inherits and produces new ores (`keepsInheritedOverlay()`) while thinning out older ones!
//!
//! Note that "ore" and "gem" are used interchangeably at times within this file.

const std = @import("std");
const dw = @import("../root.zig");
const memory = dw.memory;
const world = dw.world;
const procedural = dw.procedural;
const seeding = dw.seeding;

const Sprite = dw.Sprite;
const Block = memory.Block;
const Coordinate = world.Coordinate;
const Chunk = memory.Chunk;
const DepthCoordinate = world.DepthCoordinate;

const HORIZON_DEPTH = dw.HORIZON_DEPTH;
const STARTING_ZOOM_TIMES = dw.startup.STARTING_ZOOM_TIMES;

/// Returns true if discrete coordinates are no longer tracked at this depth,
/// (if so, the background `quad_cache` begins to be used).
pub inline fn isHorizonDepth(depth: u64) bool {
    // The floor is NEVER a horizon depth.
    if (depth <= STARTING_ZOOM_TIMES) return false;

    const horizon_limit = dw.HORIZON_DEPTH;
    // The horizon (H) kicks in once we are more than 32 + STARTING_ZOOM_TIMES layers deep.
    if (memory.game.depth < STARTING_ZOOM_TIMES + horizon_limit) return false;

    return (depth + horizon_limit) == memory.game.depth;
}

/// Set-associative chunk cache for chunk ancestors, indexed by distance from the current depth.
/// Fully cleared whenever the game depth changes (see `world.clearCaches()`).
///
/// Tiers are RELATIVE: tier 0 is the current depth (D), tier 1 its parent, down to the horizon (H) at tier `NUM_TIERS - 1`.
/// Relative indexing lets the hottest tiers sit at fixed slots so they can be sized larger.
/// - The two tiers nearest the player (`HOT_TIERS`) are often queried:
///   you can think to a 4x4 chunk "group" collapsing into one seed with D-1 and 16x16 chunk "groups" with D-2.
/// - Deeper tiers converge geometrically (each ~4x smaller footprint) and only need a small 8-slot buffer.
///   Really, you only need 4 to prevent quadrant boundary issues, but this provides a decent buffer.
///
/// This keeps the cache under ~2 MiB (vs 8 MiB uniform), fitting comfortably in L2/L3.
pub const AncestorCache = struct {
    /// Total relative tiers tracked: one per live depth from the current depth down to the horizon.
    /// The `+1` covers the single transition frame at `depth == HORIZON_DEPTH + STARTING_ZOOM_TIMES`,
    /// where the horizon would fall on the base depth but `isHorizonDepth()` excludes the base,
    /// leaving base..current = 33 depths live at once (one more than `HORIZON_DEPTH`).
    pub const NUM_TIERS = HORIZON_DEPTH + 1;
    /// Associativity shared by every tier. Power of two so the CLOCK hand wraps mod `WAYS` for free.
    pub const WAYS = 8;

    /// Tiers nearest the current depth that receive the wide, high-capacity layout.
    pub const HOT_TIERS = 2;
    /// Sets per hot tier. `HOT_SETS * WAYS` = 128 slots covers the ~50-chunk worst-case parent working set
    /// (at minimum zoom without overflowing any single 8-way set).
    pub const HOT_SETS = 16;
    /// Chunks stored per hot tier.
    pub const HOT_SIZE = HOT_SETS * WAYS;

    /// Remaining tiers past the hot ones; sized for the converged (deep) footprint only.
    pub const COLD_TIERS = NUM_TIERS - HOT_TIERS;
    /// A single set per cold tier; 8 slots is plenty for the converged footprint plus a
    /// quadrant-crossing buffer.
    pub const COLD_SETS = 1;
    /// Chunks stored per cold tier.
    pub const COLD_SIZE = COLD_SETS * WAYS;

    /// One CLOCK reference bit per way.
    const RefBits = std.meta.Int(.unsigned, WAYS);
    /// Index of a way within a set; doubles as the CLOCK hand (wraps mod `WAYS`).
    const WayIndex = std.math.Log2Int(RefBits);

    // Hot tiers (relative index 0..HOT_TIERS): wide and high-capacity.
    hot_keys: [HOT_TIERS][HOT_SETS][WAYS]DepthCoordinate = @splat(@splat(@splat(DepthCoordinate.invalid))),
    hot_chunks: [HOT_TIERS][HOT_SIZE]Chunk = undefined,
    hot_clock: [HOT_TIERS][HOT_SETS]RefBits = @splat(@splat(0)),
    hot_hand: [HOT_TIERS][HOT_SETS]WayIndex = @splat(@splat(0)),

    // Cold tiers: small single-set buffers.
    cold_keys: [COLD_TIERS][COLD_SETS][WAYS]DepthCoordinate = @splat(@splat(@splat(DepthCoordinate.invalid))),
    cold_chunks: [COLD_TIERS][COLD_SIZE]Chunk = undefined,
    cold_clock: [COLD_TIERS][COLD_SETS]RefBits = @splat(@splat(0)),
    cold_hand: [COLD_TIERS][COLD_SETS]WayIndex = @splat(@splat(0)),

    /// A single tier's storage as slices, so the associative logic is written once for hot and cold.
    const TierView = struct {
        keys: [][WAYS]DepthCoordinate,
        chunks: []Chunk,
        clock: []RefBits,
        hand: []WayIndex,

        /// Set-associative lookup; sets the CLOCK reference bit on a hit.
        fn get(self: TierView, key: DepthCoordinate, h: u64) ?*Chunk {
            const set_idx: usize = @intCast(h % self.keys.len);
            inline for (0..WAYS) |way| {
                const cache_key = self.keys[set_idx][way];
                if (cache_key.depth != 0 and cache_key.eql(key)) {
                    self.clock[set_idx] |= (@as(RefBits, 1) << way);
                    return &self.chunks[set_idx * WAYS + way];
                }
            }
            return null;
        }

        /// CLOCK second-chance eviction; installs `key` and returns its (to-be-written) slot.
        fn allocate(self: TierView, key: DepthCoordinate, h: u64) *Chunk {
            const set_idx: usize = @intCast(h % self.keys.len);
            var hand_val = self.hand[set_idx];
            while (true) {
                const way = hand_val;
                hand_val +%= 1; // wraps mod WAYS (power of two)

                const mask = @as(RefBits, 1) << way;
                if ((self.clock[set_idx] & mask) != 0) {
                    // Give second chance and clear reference bit.
                    self.clock[set_idx] &= ~mask;
                } else {
                    // Found eviction candidate.
                    self.keys[set_idx][way] = key;
                    self.clock[set_idx] |= mask;
                    self.hand[set_idx] = hand_val;
                    return &self.chunks[set_idx * WAYS + way];
                }
            }
        }
    };

    /// Maps a cache key to its tier distance from the current depth (0 = current depth).
    /// Callers guarantee the key sits above the horizon, so the distance is always < `NUM_TIERS`.
    inline fn relativeTier(depth: u64) usize {
        const rel = memory.game.depth - depth;
        std.debug.assert(rel < NUM_TIERS);
        return @intCast(rel);
    }

    /// Resolves the `TierView` for a relative tier, dispatching between hot and cold storage.
    fn tierView(self: *@This(), rel: usize) TierView {
        if (rel < HOT_TIERS) return .{
            .keys = &self.hot_keys[rel],
            .chunks = &self.hot_chunks[rel],
            .clock = &self.hot_clock[rel],
            .hand = &self.hot_hand[rel],
        };
        const c = rel - HOT_TIERS;
        return .{
            .keys = &self.cold_keys[c],
            .chunks = &self.cold_chunks[c],
            .clock = &self.cold_clock[c],
            .hand = &self.cold_hand[c],
        };
    }

    /// Retrieves a chunk by `DepthCoordinate`; searches the tier for that depth.
    /// Returns a mutable pointer.
    pub fn get(self: *@This(), key: DepthCoordinate) ?*Chunk {
        std.debug.assert(!isHorizonDepth(key.depth));
        return self.tierView(relativeTier(key.depth)).get(key, key.hash());
    }

    /// Allocates a slot in the appropriate tier based on depth and returns a mutable pointer.
    /// This allows `generateChunk()` to write directly into the cache memory.
    pub fn allocateSlot(self: *@This(), key: DepthCoordinate) *Chunk {
        std.debug.assert(!isHorizonDepth(key.depth));
        return self.tierView(relativeTier(key.depth)).allocate(key, key.hash());
    }

    /// Allocates a slot and inserts a chunk directly.
    pub fn insert(self: *@This(), key: DepthCoordinate, chunk: Chunk) *const Chunk {
        const slot = self.allocateSlot(key);
        slot.* = chunk;
        return slot;
    }

    /// Clears cache keys and clock reference data per tier without re-allocating chunk payloads.
    pub fn clear(self: *@This()) void {
        // small @splat()s: prevents a crash due to stack being consumed
        // keep in mind @splat() in Debug naively uses the stack frame here!
        for (0..HOT_TIERS) |i| {
            self.hot_keys[i] = @splat(@splat(DepthCoordinate.invalid));
            self.hot_clock[i] = @splat(0);
            self.hot_hand[i] = @splat(0);
        }
        for (0..COLD_TIERS) |i| {
            self.cold_keys[i] = @splat(@splat(DepthCoordinate.invalid));
            self.cold_clock[i] = @splat(0);
            self.cold_hand[i] = @splat(0);
        }
    }

    comptime {
        if (!std.math.isPowerOfTwo(WAYS)) @compileError("WAYS must be a power of two so the CLOCK hand wraps mod WAYS.");
        if (!std.math.isPowerOfTwo(HOT_SETS) or !std.math.isPowerOfTwo(COLD_SETS)) @compileError("Set counts must be powers of two for the hash modulo to distribute evenly.");
        if (HOT_TIERS + COLD_TIERS != NUM_TIERS) @compileError("Hot and cold tiers must partition NUM_TIERS.");
        // The whole point of the hot/cold split is to stay small; catch accidental blowups.
        // Currently HOT (2 x 128) + COLD (31 x 8) = ~1.97 MiB of chunk payload.
        const chunk_bytes = (HOT_TIERS * HOT_SIZE + COLD_TIERS * COLD_SIZE) * memory.CHUNK_BYTES;
        if (chunk_bytes > 2 * memory.MemorySizes.MiB) @compileError("AncestorCache chunk storage exceeds its 2 MiB budget.");
    }
};

pub var ancestor_cache: AncestorCache = .{};

/// Parent coordinate and block offset info.
pub const ParentInfo = struct {
    coord: Coordinate,
    bx: u4,
    by: u4,
};

/// Shifts the suffix and incorporates the local block position to find the exact parent chunk and block.
/// Child's depth is described in the `DepthCoordinate`.
pub fn getParentInfo(key: DepthCoordinate, bx: u4, by: u4) ParentInfo {
    // getParent handles the 3-bit rebase origin reconstruction and quadrant shifts for D > 32.
    const parent = key.getParent();
    const zoom_log2 = dw.ZOOM_LOG2;
    const blocks_per_parent = dw.BLOCKS_PER_PARENT;

    // The LSBs of the suffix determine which 4x4 quadrant of the parent chunk this child occupies.
    const lx: u4 = @intCast(key.suffix[0] & (dw.ZOOM_FACTOR - 1));
    const ly: u4 = @intCast(key.suffix[1] & (dw.ZOOM_FACTOR - 1));

    return .{
        .coord = parent.asCoord(),
        // Map child blocks to parent blocks by shifting the child block into parent-space
        // and offsetting it by the child chunk's position within the parent.
        .bx = (lx * blocks_per_parent) + (bx >> zoom_log2),
        .by = (ly * blocks_per_parent) + (by >> zoom_log2),
    };
}

/// Retrieves a full chunk at any depth, handling cache and procedural generation.
/// The cache holds materialized chunks (`mod_store` carries no block data of its own), so a hit already
/// includes the player's edits and a miss replays them as part of generating the slot.
pub fn getAncestorChunk(key: DepthCoordinate) *const Chunk {
    if (ancestor_cache.get(key)) |cached| return cached;

    const slot = ancestor_cache.allocateSlot(key);
    world.materializeChunk(slot, key);
    return slot;
}

/// Weight one solid parent block contributes to a corner of the child grid.
/// Four blocks meet at a corner, so a corner density runs 0 (open space) to 64 (fully buried).
const CORNER_UNIT = 16;
/// Density a child cell needs to stay solid before erosion is applied.
/// A flat surface puts its corners at exactly two of four blocks solid, so the threshold sits there.
const SLOPE_THRESHOLD = 2 * CORNER_UNIT;
/// Density between one cell of a face and the next:
/// the field climbs from a surface corner to a buried one across the parent's `BLOCKS_PER_PARENT` cells.
const CELL_DENSITY_STEP = (4 * CORNER_UNIT - SLOPE_THRESHOLD) / dw.BLOCKS_PER_PARENT;
/// How much density the erosion mask can subtract at full strength: spans 1.65 cell rows to break single-row horizontal plateau lock.
const EROSION_DEPTH = 1.65 * CELL_DENSITY_STEP;
/// Cell size of the coarsest erosion octave, in child blocks (a parent block is `BLOCKS_PER_PARENT` wide).
const EROSION_SCALE = 16.0;
/// Octaves of gouging. Each halves both cell size and weight, so this reaches down to `EROSION_SCALE / 4` child blocks:
const EROSION_OCTAVES = 3;
/// How strongly sharp, channel-carving noise affects erosion.
const GOUGE_WEIGHT = 1.24;
/// The mathematical average value of the sharp gouge noise.
const GOUGE_MEAN = GOUGE_WEIGHT / 2.0;
/// How strongly smooth, rolling noise affects erosion.
const UNDULATION_WEIGHT = 0.6;

/// Cell size of the coarse material warp octave, in child blocks.
const MATERIAL_WARP_SCALE = 11.2;
/// Scale multiplier for the second, finer layer of material noise.
const MATERIAL_WARP_LACUNARITY = 3.49;
/// The mix ratio between smooth curves and sharp creases for material borders.
const MATERIAL_CREASE_WEIGHT = 0.32;
/// Maximum distance (in parent block units) material can be dragged.
const MATERIAL_WARP_STRENGTH = 1.2;

/// Scale of coherent ore/gem thinning noise, in child block units.
const ORE_THINNING_SCALE = 3.0; // 0.75 parent blocks
/// Chance of an ore/gem still remaining from the previous depth after all warping/erosion interactions.
/// Not a hash; instead passed through a noise function.
const INHERITED_ORE_KEEP_CHANCE = 0.73;

/// Total block width of the world across one dimension.
const WORLD_BLOCKS_WIDE = @as(u32, dw.CHUNK_SIZE) << (STARTING_ZOOM_TIMES * dw.ZOOM_LOG2);

/// Mask for noise coordinates to stay within floating-point precision.
pub const NOISE_COORD_MASK: u64 = std.math.maxInt(u32);

comptime {
    if ((NOISE_COORD_MASK +% 1) % dw.CHUNK_SIZE != 0)
        @compileError("The noise period must be a power-of-two minus one.");
    // The mask must be able to take the exposed row of a face...
    if (EROSION_DEPTH <= 0.5 * CELL_DENSITY_STEP)
        @compileError("A full erosion mask cannot even reach a face's exposed cell row.");
    // ...and must not be able to take the row behind it, which is what holds erosion to one cell.
    if (INHERITED_ORE_KEEP_CHANCE <= 0 or INHERITED_ORE_KEEP_CHANCE >= 1)
        @compileError("Inherited ore keep chance must be strictly between zero and one.");
}

/// Determines whether a specified ore/gem deposit should remain.
inline fn keepsInheritedOverlay(
    noise_seed: dw.utils.Vec2u,
    wx: u64,
    wy: u64,
    lx: u4,
    ly: u4,
) bool {
    _ = lx;
    _ = ly;
    // if (INHERITED_ORE_KEEP_CHANCE < 1.0) {
    //     // guarantee at least 1 of the ore/gem survives
    //     const parent_hash = seeding.FastHash.hash2d(
    //         noise_seed,
    //         wx / dw.BLOCKS_PER_PARENT,
    //         wy / dw.BLOCKS_PER_PARENT,
    //     );
    //     const anchor_x: u4 = @intCast(parent_hash & (dw.BLOCKS_PER_PARENT - 1));
    //     const anchor_y: u4 = @intCast((parent_hash >> 2) & (dw.BLOCKS_PER_PARENT - 1));
    //     if (lx == anchor_x and ly == anchor_y) return true;
    // }

    const coherent_roll = procedural.getDualValueNoise(
        noise_seed,
        wx,
        wy,
        1.0 / ORE_THINNING_SCALE,
    )[0];

    return coherent_roll < INHERITED_ORE_KEEP_CHANCE;
}

/// Computes a continuous terrain erosion factor in [0, 1] using multi-octave ridged and undulating noise.
fn erosionMask(noise_seed: dw.utils.Vec2u, wx: u64, wy: u64) f32 {
    // Value noise, NOT a folded gradient field.
    var gouges: f32 = 0;
    var weight: f32 = 0;
    inline for (0..EROSION_OCTAVES) |octave| {
        const step: f32 = @floatFromInt(@as(u32, 1) << octave);
        const shift = @as(u64, octave) * 0x40383698ed; // large prime-y num
        const v = procedural.getDualValueNoise(
            noise_seed,
            wx +% shift,
            wy +% shift,
            step / EROSION_SCALE,
        )[0];

        // Folding at the midpoint turns a smooth field into narrow bands along its midpoint contour.
        const amplitude = 1.0 / step;
        gouges += amplitude * (1 - @abs(2 * v - 1));
        weight += amplitude;
    }

    // The coarse octave's second lane is the broad swell, and comes free with the call above.
    const undulation = procedural.getDualValueNoise(
        noise_seed,
        wx,
        wy,
        1.0 / (EROSION_SCALE * 2),
    )[1];

    // Both terms enter centered, so their weights set spread without dragging the average off the break-even point.
    const mask = 0.5 + GOUGE_WEIGHT * (gouges / weight - GOUGE_MEAN) + UNDULATION_WEIGHT * (undulation - 0.5);
    return std.math.clamp(mask, 0.0, 1.0);
}

/// Calculates density at parent block corners based on solid neighbors (ordered row-major, top-left to bottom-right).
fn cornerDensities(parent_block: Block, n: [8]Block) @Vector(4, f32) {
    // `isSolid()` rather than `isFoundation()`, so bedrock counts as the material it is. The two
    // differ only for edge stone, and reading the world border as open air would have the terrain
    // erode toward it exactly as if there were a cave out there.
    var solid: [8]f32 = undefined;
    for (n, 0..) |b, i| solid[i] = @floatFromInt(@intFromBool(b.isSolid()));
    const self_solid: f32 = @floatFromInt(@intFromBool(parent_block.isSolid()));

    return @as(@Vector(4, f32), .{
        self_solid + solid[0] + solid[1] + solid[3],
        self_solid + solid[1] + solid[2] + solid[4],
        self_solid + solid[3] + solid[5] + solid[6],
        self_solid + solid[4] + solid[6] + solid[7],
    }) * @as(@Vector(4, f32), @splat(CORNER_UNIT));
}

/// Determines whether terrain erosion carves away a child cell based on bilinear corner density and erosion noise.
fn carvesSlope(parent_block: Block, n: [8]Block, noise_seed: dw.utils.Vec2u, wx: u64, wy: u64, lx: u4, ly: u4) bool {
    var buried = true;
    for (n) |b| buried = buried and b.isSolid();
    if (buried) return false;

    const corners = cornerDensities(parent_block, n);

    // Domain-warp bilinear coordinates to perturb surface contours and eliminate axis-aligned rectangular steps
    const warp = warpField(noise_seed, wx, wy);
    const warp_offset_x = (warp[0] - 0.5) * 1.8;
    const warp_offset_y = (warp[1] - 0.5) * 1.8;

    const u = std.math.clamp((2.0 * @as(f32, @floatFromInt(lx)) + 1.0 + warp_offset_x) / 8.0, 0.0, 1.0);
    const v = std.math.clamp((2.0 * @as(f32, @floatFromInt(ly)) + 1.0 + warp_offset_y) / 8.0, 0.0, 1.0);
    const weights: @Vector(4, f32) = .{ (1 - u) * (1 - v), u * (1 - v), (1 - u) * v, u * v };

    // Continuous noise jitter breaks discrete corner density steps (16, 32, 48)
    const jitter = (procedural.getDualValueNoise(noise_seed, wx, wy, 1.0 / 7.0)[0] - 0.5) * (0.8 * CORNER_UNIT);
    const density = @reduce(.Add, corners * weights) + jitter;

    // Protect deep parent interiors based on continuous density field
    if (density >= 3.5 * CORNER_UNIT) return false;

    return density < SLOPE_THRESHOLD + erosionMask(noise_seed, wx, wy) * EROSION_DEPTH;
}

/// Generates a 2D material displacement vector combining coarse directional drift and fine creased noise.
fn warpField(noise_seed: dw.utils.Vec2u, wx: u64, wy: u64) dw.utils.Vec2f32 {
    const half: dw.utils.Vec2f32 = @splat(0.5);
    const coarse = procedural.getDualValueNoise(noise_seed, wx, wy, 1.0 / MATERIAL_WARP_SCALE);
    const fine = procedural.getDualValueNoise(noise_seed, wx, wy, MATERIAL_WARP_LACUNARITY / MATERIAL_WARP_SCALE);

    const creased = @abs(fine - half) * @as(dw.utils.Vec2f32, @splat(2));
    return coarse * @as(dw.utils.Vec2f32, @splat(1 - MATERIAL_CREASE_WEIGHT)) +
        creased * @as(dw.utils.Vec2f32, @splat(MATERIAL_CREASE_WEIGHT));
}

/// Selects material from a 3x3 parent neighborhood using continuous 2D domain warping.
fn warpedMaterial(parent_block: Block, n: [8]Block, warp: dw.utils.Vec2f32, lx: u4, ly: u4) Block {
    const center = (dw.BLOCKS_PER_PARENT - 1.0) / 2.0;

    const fx = (@as(f32, @floatFromInt(lx)) - center) / dw.BLOCKS_PER_PARENT + (warp[0] - 0.5) * 2 * MATERIAL_WARP_STRENGTH;
    const fy = (@as(f32, @floatFromInt(ly)) - center) / dw.BLOCKS_PER_PARENT + (warp[1] - 0.5) * 2 * MATERIAL_WARP_STRENGTH;

    const ox: i32 = @intFromFloat(@round(std.math.clamp(fx, -1, 1)));
    const oy: i32 = @intFromFloat(@round(std.math.clamp(fy, -1, 1)));
    if (ox == 0 and oy == 0) return parent_block;

    // Row-major 3x3 index with the center removed, matching the neighbor order.
    const raw = (oy + 1) * 3 + (ox + 1);
    const source = n[@intCast(raw - @intFromBool(raw > 4))];

    // `isFoundation()` also rejects edge stone, which must never bleed inward.
    return if (source.isFoundation()) source else parent_block;
}

/// Evaluates child block evolution from its parent block and 8 parent neighbors.
/// Handles water volume propagation, slope carving, material warping, and ore dispersal.
pub fn applyAncestorLogic(
    parent_block: Block,
    parent_neighbors: [8]Block,
    key: DepthCoordinate,
    bx: u4,
    by: u4,
) memory.BlockSpec {
    const parent_sprite = parent_block.id;
    // const parent_seed = parent_block.seed;

    if (parent_sprite.isEmpty()) return .{};
    const seeds = world.quad_cache.getChunkSeeds(key);
    const noise_hash_2 = seeding.FastHash.hash2d(
        .{ seeds.value[0].value[2], seeds.value[0].value[3] },
        bx,
        by,
    );
    if (parent_sprite == .edge_stone)
        return .{ .id = parent_sprite, .seed = noise_hash_2 };

    // A submerged waterloggable parent must stay submerged in its children. Generating them dry leaves the
    // pool out of equilibrium, so the sim floods them on the chunk's first tick and writes a modification
    // entry for terrain the player never touched. On a waterloggable block, `hp` IS its water volume.
    // (Liquids need no propagation: `BlockSpec.compile()` already fills a liquid id to `MAX_HP`.)
    const inherited_water: u4 = if (parent_sprite.isWaterloggable()) parent_block.hp else 0;

    // Inherit plant still!
    if (parent_sprite == .spiralvine)
        return .{ .id = .spiralvine, .seed = noise_hash_2, .water_volume = inherited_water };

    if (parent_sprite == .mushroom) {
        // Only make specific sub-blocks of a mushroom parent become big mushroom!
        return if ((bx % 4 == 1 or bx % 4 == 2) and by % 4 == 3)
            .{ .id = .big_mushroom, .seed = noise_hash_2, .water_volume = inherited_water }
        else
            .{}; // bypass edges logic too
    }

    // Fallback for all other non-foundation blocks (decorations, chests, furnaces, liquids, etc.)
    if (!parent_sprite.isFoundation()) {
        return .{ .id = parent_sprite.evolvesTo(), .seed = noise_hash_2, .water_volume = inherited_water };
    }

    // Foundations from here on: only they carry a surface for the carve to shape.
    // Nothing below may turn air into a solid, since the player could be standing in it.
    const lx: u4 = @intCast(bx % dw.BLOCKS_PER_PARENT);
    const ly: u4 = @intCast(by % dw.BLOCKS_PER_PARENT);

    // Every noise field below reads global child coordinates under one quadrant-wide seed,
    // so chunk identity never enters and the fields line up across chunk borders.
    // The depth is folded in to stop a parent's field from repeating verbatim in the children drawn on top of it.
    const quadrant_seed = world.quad_cache.getQuadrantSeed(@intCast(key.quadrant), key.depth);
    const noise_seed: dw.utils.Vec2u = .{ quadrant_seed.value[0] ^ key.depth, quadrant_seed.value[1] };
    const wx = ((@as(u64, key.suffix[0]) *% dw.CHUNK_SIZE) +% bx) & NOISE_COORD_MASK;
    const wy = ((@as(u64, key.suffix[1]) *% dw.CHUNK_SIZE) +% by) & NOISE_COORD_MASK;

    // Geometry FIRST!
    if (carvesSlope(parent_block, parent_neighbors, noise_seed, wx, wy, lx, ly)) return .{};

    // Now, resolve material domain warping for solid cells.
    const warp = warpField(noise_seed, wx, wy);
    const source = warpedMaterial(parent_block, parent_neighbors, warp, lx, ly);

    // Evaluate overlay retention on confirmed solid terrain
    const is_overlay = source.id.isOverlay() or parent_sprite.isOverlay();
    if (is_overlay) {
        const overlay_id = if (source.id.isOverlay()) source.id else parent_sprite;
        const base_id = if (source.id.isOverlay()) source.base_id else parent_block.base_id;

        if (!keepsInheritedOverlay(noise_seed, wx, wy, lx, ly)) {
            return .{ .id = base_id, .seed = noise_hash_2, .water_volume = inherited_water };
        }
        return .{
            .id = overlay_id,
            .base_id = base_id,
            .seed = noise_hash_2,
            .water_volume = inherited_water,
        };
    }

    var evolved_sprite: Sprite = source.id.evolvesTo();

    if (source.id.isStone()) {
        const ore_density = procedural.getDualValueNoise(
            noise_seed,
            wx,
            wy,
            1.0 / 23.0,
        )[0];
        if (procedural.disperseOre(source.id, ore_density, wx, wy, key.depth, noise_seed)) |ore| {
            evolved_sprite = ore;
        }
    }

    if (evolved_sprite == .blue_strange_stone and warp[0] > 0.7) evolved_sprite = .blue_stone;

    // preserve "underlay"
    const base_id: Sprite = if (evolved_sprite.isOverlay())
        (if (source.base_id != .none) source.base_id else source.id)
    else
        .none;

    // done! pass down the noise hash as well.
    return .{ .id = evolved_sprite, .base_id = base_id, .seed = noise_hash_2 };
}

/// Recursively traces the lineage of a single block type up to parent depths, overlaying player modifications.
/// Accesses and potentially modifies `ancestor_cache`.
pub fn getInheritedMaterial(key: DepthCoordinate, bx: u4, by: u4) Block {
    const target_depth = key.depth;
    if (target_depth == STARTING_ZOOM_TIMES) {
        const block_idx = (@as(usize, by) << dw.CHUNK_SIZE_LOG2) | bx;

        // A cache hit is already materialized (mods overlaid by `materializeChunk()`), so no separate
        // `mod_store` lookup is needed: a miss replays the edits as part of generating the slot.
        if (ancestor_cache.get(key)) |cached| return cached.blocks[block_idx];

        const slot = ancestor_cache.allocateSlot(key);
        world.materializeChunk(slot, key);
        return slot.blocks[block_idx];
    }

    if (isHorizonDepth(target_depth)) {
        return world.getBlockAt(key.asCoord(), bx, by, target_depth);
    }

    const block_idx = (@as(usize, by) << dw.CHUNK_SIZE_LOG2) | bx;

    // A cache hit is already materialized (mods overlaid).
    if (ancestor_cache.get(key)) |cached| return cached.blocks[block_idx];

    const p = getParentInfo(key, bx, by);
    const parent_block = getInheritedMaterial(p.coord.asDepthCoordinate(target_depth - 1), p.bx, p.by);

    // Fetch the 3x3 boundary of the parent block to pass to our ancestor logic
    var neighbors: [8]Block align(8) = undefined;
    var n_idx: usize = 0;

    var dy: i32 = -1;
    while (dy <= 1) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            if (dx == 0 and dy == 0) continue;

            const lx = @as(i32, @intCast(p.bx)) + dx;
            const ly = @as(i32, @intCast(p.by)) + dy;
            const chunk_off_x = @divFloor(lx, dw.CHUNK_SIZE);
            const chunk_off_y = @divFloor(ly, dw.CHUNK_SIZE);

            // `moveAtDepth()` returns null only at the world border, where bedrock is the truthful
            // answer; see `world.world_edge_block` for why air here would be corrosive.
            const target_nc = p.coord.moveAtDepth(
                .{ chunk_off_x, chunk_off_y },
                target_depth - 1,
            ) orelse {
                neighbors[n_idx] = world.world_edge_block;
                n_idx += 1;
                continue;
            };

            // This uses AncestorCache!
            neighbors[n_idx] = getInheritedMaterial(
                target_nc.asDepthCoordinate(target_depth - 1),
                @intCast(@mod(lx, dw.CHUNK_SIZE)),
                @intCast(@mod(ly, dw.CHUNK_SIZE)),
            );
            n_idx += 1;
        }
    }

    var block = applyAncestorLogic(parent_block, neighbors, key, bx, by).compile();
    if (world.mod_store.getCell(key, @intCast(block_idx))) |cell| cell.applyTo(&block);
    return block;
}

/// Fetches a 6x6 parent block neighborhood at parent depth (`key.depth - 1`) for generator evaluation.
pub fn getAncestorNeighborhood(key: DepthCoordinate) [6][6]Block {
    var result: [6][6]Block = undefined;
    const parent_depth = key.depth - 1;

    const p_info_origin = getParentInfo(key, 0, 0);
    const start_px = @as(i32, @intCast(p_info_origin.bx)) - 1;
    const start_py = @as(i32, @intCast(p_info_origin.by)) - 1;

    for (0..6) |y_idx| {
        for (0..6) |x_idx| {
            const lx = start_px + @as(i32, @intCast(x_idx));
            const ly = start_py + @as(i32, @intCast(y_idx));
            const chunk_off_x = @divFloor(lx, 16);
            const chunk_off_y = @divFloor(ly, 16);

            // Only the world border can fail here; bedrock, never air (`world.world_edge_block`).
            const target_nc = p_info_origin.coord.moveAtDepth(
                .{ chunk_off_x, chunk_off_y },
                parent_depth,
            ) orelse {
                result[y_idx][x_idx] = world.world_edge_block;
                continue;
            };

            if (isHorizonDepth(parent_depth)) {
                result[y_idx][x_idx] = world.getBlockAt(
                    target_nc,
                    @intCast(@mod(lx, 16)),
                    @intCast(@mod(ly, 16)),
                    parent_depth,
                );
                continue;
            }

            // Fetch parent chunk pointer and immediately extract block to avoid stack copies
            const chunk_ptr = getAncestorChunk(target_nc.asDepthCoordinate(parent_depth));
            result[y_idx][x_idx] = chunk_ptr.blocks[
                (@as(usize, @intCast(@mod(ly, 16))) << 4) |
                    @as(usize, @intCast(@mod(lx, 16)))
            ];
        }
    }
    return result;
}

const testing = std.testing;

/// Builds a parent block and its 8 row-major neighbors out of a 3x3 solidity map,
/// giving every cell a distinct seed so the corner jitter actually varies.
fn testNeighborhood(solid: [3][3]bool, seed_base: u64) struct { Block, [8]Block } {
    var center: Block = undefined;
    var n: [8]Block = undefined;
    var i: usize = 0;
    for (0..3) |y| {
        for (0..3) |x| {
            // Seeds must depend on the cell's position in the world, not its slot in this array,
            // so two overlapping neighborhoods agree on the blocks they share.
            const seed = seed_base +% @as(u64, y) *% 31 +% x;
            const block: Block = .makeBasicBlock(if (solid[y][x]) .stone else .none, seed);
            if (x == 1 and y == 1) center = block else {
                n[i] = block;
                i += 1;
            }
        }
    }
    return .{ center, n };
}

/// Sweeps every noise cell the erosion field can offer, so a "never carved" claim covers the whole
/// field rather than whichever offset one arbitrary position happens to land on.
fn carvesAnywhere(parent_block: Block, n: [8]Block, lx: u4, ly: u4) bool {
    const seed: dw.utils.Vec2u = .{ 0x243f6a8885a308d3, 0x13198a2e03707344 };
    // Sweeps whole parents, since a cell's position inside its parent is fixed by `lx`/`ly`.
    for (0..24) |py| {
        for (0..24) |px| {
            const wx = px * dw.BLOCKS_PER_PARENT + lx;
            const wy = py * dw.BLOCKS_PER_PARENT + ly;
            if (carvesSlope(parent_block, n, seed, wx, wy, lx, ly)) return true;
        }
    }
    return false;
}

test "slope carve: a fully enclosed block is never touched" {
    const all_solid: [3]bool = @splat(true);
    const buried = testNeighborhood(.{all_solid} ** 3, 1000);
    for (0..4) |ly| {
        for (0..4) |lx| {
            try testing.expect(!carvesAnywhere(buried[0], buried[1], @intCast(lx), @intCast(ly)));
        }
    }
}

test "slope carve: a flat face frays, and never deeper than its exposed row" {
    // The mask has to make a difference BETWEEN neighboring parents. A field that moves every parent
    // by the same amount removes just as much rock and reads as a face that never moved at all,
    // which is exactly the failure this pins down.
    const all_solid: [3]bool = @splat(true);
    const all_air: [3]bool = @splat(false);
    const wall = testNeighborhood(.{ all_air, all_solid, all_solid }, 1000);
    const seed: dw.utils.Vec2u = .{ 0x243f6a8885a308d3, 0x13198a2e03707344 };

    // Sampled along a noise lattice line on purpose. A folded gradient field peaks on exactly these
    // lines, and this is where that shows up: as a regular grid of erosion printed on the terrain.
    var frayed: usize = 0;
    var intact: usize = 0;
    for (0..512) |px| {
        const wx = px * dw.BLOCKS_PER_PARENT;
        if (carvesSlope(wall[0], wall[1], seed, wx, 0, 0, 0)) frayed += 1 else intact += 1;

        // Everything behind the exposed row stays, including the deep cells on the side columns:
        // taking those would notch the face on the parent grid rather than erode it.
        for (1..4) |ly| {
            try testing.expect(!carvesSlope(wall[0], wall[1], seed, wx, ly, 0, @intCast(ly)));
        }
    }

    // Both outcomes have to be common; either one dominating means the mask is not shaping anything.
    try testing.expect(frayed > 512 / 4);
    try testing.expect(intact > 512 / 4);
}

test "erosion mask: centered on break-even, and spread wide enough to commit" {
    // `GOUGE_MEAN` is measured from the noise, so it has to be pinned here: if the mask drifts off
    // center it erodes uniformly, which is visually identical to not eroding at all. The spread
    // matters just as much, since a mask hugging its midpoint frays every cell equally.
    const seed: dw.utils.Vec2u = .{ 0x243f6a8885a308d3, 0x13198a2e03707344 };
    var sum: f64 = 0;
    var sum_sq: f64 = 0;
    const side = 200;
    for (0..side) |y| {
        for (0..side) |x| {
            const m = erosionMask(seed, @intCast(x), @intCast(y));
            sum += m;
            sum_sq += m * m;
        }
    }

    const count = side * side;
    const mean = sum / count;
    const deviation = @sqrt(sum_sq / count - mean * mean);
    try testing.expect(@abs(mean - 0.5) < 0.06);
    try testing.expect(deviation > 0.15);
}

test "slope carve: terrain never erodes toward the world border" {
    // The border is bedrock, not open air. The moment it reads as air again, a block sitting against
    // the edge of the world erodes into it, and since an empty ancestor can only ever produce empty
    // descendants, that emptiness spreads inward one step at every depth with no way back.
    const parent: Block = .makeBasicBlock(.stone, 7);
    const border: [8]Block = @splat(world.world_edge_block);
    for (0..4) |ly| {
        for (0..4) |lx| {
            try testing.expect(!carvesAnywhere(parent, border, @intCast(lx), @intCast(ly)));
        }
    }

    // And a face that meets the border on one side keeps the cells along it.
    var half = border;
    for (half[0..3]) |*b| b.* = .empty;
    const corners = cornerDensities(parent, half);
    try testing.expect(@reduce(.Min, corners) > 0);
}

test "slope carve: every parent keeps its 2x2 shell" {
    // Across every arrangement of neighbors, so no combination of density and mask can cost a
    // parent its block.
    for (0..256) |mask| {
        var n: [8]Block = undefined;
        for (&n, 0..) |*b, i| {
            b.* = .makeBasicBlock(if (mask & (@as(usize, 1) << @intCast(i)) != 0) .stone else .none, i);
        }
        const parent: Block = .makeBasicBlock(.stone, 99);

        for (1..3) |ly| {
            for (1..3) |lx| {
                try testing.expect(!carvesAnywhere(parent, n, @intCast(lx), @intCast(ly)));
            }
        }
    }
}

test "slope carve: neighboring parents agree on the corners they share" {
    // A 4x3 strip of terrain; the two center columns are the parents under test.
    const map: [3][4]bool = .{
        .{ false, false, true, true },
        .{ true, true, true, false },
        .{ true, false, true, true },
    };
    var left_map: [3][3]bool = undefined;
    var right_map: [3][3]bool = undefined;
    for (0..3) |y| {
        left_map[y] = map[y][0..3].*;
        right_map[y] = map[y][1..4].*;
    }

    const left = testNeighborhood(left_map, 500);
    const right = testNeighborhood(right_map, 501);
    const left_corners = cornerDensities(left[0], left[1]);
    const right_corners = cornerDensities(right[0], right[1]);

    // The left parent's right corners are the right parent's left corners; if these ever disagree,
    // the two parents draw different surfaces and the terrain splits along their shared border.
    try testing.expectEqual(left_corners[1], right_corners[0]);
    try testing.expectEqual(left_corners[3], right_corners[2]);
}

test "material warp: a cell keeps its own material unless the warp reaches a neighbor" {
    const grid = testNeighborhood(.{@as([3]bool, @splat(true))} ** 3, 3);
    var neighbors = grid[1];
    for (&neighbors) |*b| b.* = .makeBasicBlock(.iron, 0);

    // Dead center of the warp field: no drag, so every cell answers with its own parent.
    const centered: dw.utils.Vec2f32 = .{ 0.5, 0.5 };
    for (0..4) |ly| {
        for (0..4) |lx| {
            const source = warpedMaterial(grid[0], neighbors, centered, @intCast(lx), @intCast(ly));
            try testing.expectEqual(grid[0].id, source.id);
        }
    }

    // Fully warped left: the cells on that side cross into the neighbor, the far side does not.
    const pulled: dw.utils.Vec2f32 = .{ 0.0, 0.5 };
    try testing.expectEqual(Sprite.iron, warpedMaterial(grid[0], neighbors, pulled, 0, 1).id);
    try testing.expectEqual(grid[0].id, warpedMaterial(grid[0], neighbors, pulled, 3, 1).id);
}
