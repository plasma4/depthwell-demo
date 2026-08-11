//! Handles fractal ancestry and lookup logic.
//! Contains the core procedural logic for infinite-depth zooming and recursive terrain logic, using various functions:
//! - `getInheritedMaterial()` traces the "block lineage" up to parent depths,
//!   preserving `mod_store` changes; caches results in `AncestorCache`.
//! - `applyAncestorLogic()` and slope logic create continuous sloped surfaces,
//!   based on parent blocks using bilinear 4-corner density
//! - Ancestor logic also uses noise masks, displaces blocks (`warpField()`),
//! and both inherits and produces new ores.
//! `keepsInheritedOverlay()` splits the two kinds apart:
//! an ore spreads with the vein around it, and a gem barely spreads at all.
//!
//! Note that "ore" and "gem" are used interchangeably at times within this file.
const std = @import("std");
const dw = @import("../root.zig");
const memory = dw.memory;
const world = dw.world;
const procedural = dw.procedural;
const seeding = dw.seeding;
const WorldCoord = seeding.WorldCoord;

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
///   this is like a 4x4 chunk "group" collapsing into one seed with D-1 and 16x16 at D-2, and so on!
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
    /// Sets per hot tier. `HOT_SETS * WAYS` = 128 slots covers the ~50-chunk worst-case parent working set.
    /// (at minimum zoom without overflowing any single 8-way set).
    pub const HOT_SETS = 16;
    /// Chunks stored per hot tier.
    pub const HOT_SIZE = HOT_SETS * WAYS;

    /// Remaining tiers past the hot ones; sized for the converged (deep) footprint only.
    pub const COLD_TIERS = NUM_TIERS - HOT_TIERS;
    /// A single set per cold tier;
    /// 8 slots is plenty for the converged footprint plus a quadrant-crossing buffer.
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
        for (0..HOT_TIERS) |i| {
            @memset(&self.hot_keys[i], @splat(DepthCoordinate.invalid));
            @memset(&self.hot_clock[i], 0);
            @memset(&self.hot_hand[i], 0);
        }
        for (0..COLD_TIERS) |i| {
            @memset(&self.cold_keys[i], @splat(DepthCoordinate.invalid));
            @memset(&self.cold_clock[i], 0);
            @memset(&self.cold_hand[i], 0);
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
    world.materializeInheritedChunk(slot, key);
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
/// Density a thin parent gets back as its own body, at full strength (see `carvesSlope()`).
const BODY_BIAS = 1.25 * CORNER_UNIT;
/// Mean corner density at which a parent gets its full `BODY_BIAS`.
/// One solid block with nothing around it, which is as unsupported as a parent can be.
const BODY_SUPPORT_FULL = CORNER_UNIT;
/// Mean corner density at which the body bias is gone. Sits above a one-block-thick wall (`2 * CORNER_UNIT`)
/// so walls still thicken a little, and below any real surface, whose slopes must stay the density field's business.
const BODY_SUPPORT_NONE = 2.5 * CORNER_UNIT;

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

/// Chance an ORE cell keeps its ore when NO neighbor of its parent held the same ore.
///
/// Read as a threshold on the thinning noise, NOT as a percentage:
/// value noise piles up around its midpoint, so a threshold of 0.5 keeps about half the cells
/// and the ends move the count far less than the middle does.
const ORE_KEEP_ALONE = 0.30;
/// Extra threshold an ore cell gains as its parent's own neighbors fill in around it
/// (see `overlaySupport()`).
///
/// `ORE_KEEP_ALONE + ORE_KEEP_SUPPORT` is above 1 on purpose:
/// a cell buried inside a vein keeps its ore unconditionally, so a big deposit stays a solid mass
/// while the rim of the same deposit frays.
const ORE_KEEP_SUPPORT = 0.75;

/// Cells an inherited GEM keeps out of its region's 16, on average, counting the anchor.
/// This is THE gem knob; the chance below follows from it.
const GEM_COPIES_MEAN = 2.0;
/// Cells of a region that are not the anchor.
const NON_ANCHOR_CELLS = dw.BLOCKS_PER_PARENT * dw.BLOCKS_PER_PARENT - 1;
/// Chance each non-anchor cell keeps the gem. A flat hash rather than the thinning noise:
/// a gem is a speck, and a coherent field would make a region keep all of them or none.
const GEM_KEEP_CHANCE = (GEM_COPIES_MEAN - 1.0) / @as(comptime_float, NON_ANCHOR_CELLS);

/// Chance that one corner of a fully enclosed empty parent fills.
const INFILL_CORNER_CHANCE = 0.5;

/// Total block width of the world across one dimension.
const WORLD_BLOCKS_WIDE = @as(u32, dw.CHUNK_SIZE) << (STARTING_ZOOM_TIMES * dw.ZOOM_LOG2);

/// One axis of a block's absolute position at its own depth, as a full-width `WorldCoord`.
/// Used to prevent any procedural visual cycling; there's a max of 2**69 blocks per axis at any depth.
///
/// `quadrant_bit` is that axis' bit of `Coordinate.quadrant`;
/// arguments sorted from most to least significant (as if this was a `u69`).
inline fn worldBlock(quadrant_bit: u1, chunk: u64, block: u4) WorldCoord {
    const chunk_index = (@as(WorldCoord, quadrant_bit) << 64) | chunk;
    return chunk_index * dw.CHUNK_SIZE + block;
}

/// Bounds (inclusive) of the core that a solid parent ALWAYS keeps at the next depth:
/// the center `BLOCKS_PER_PARENT / 2` square of its child region, so a 2x2 out of the standard 4x4.
///
/// (See diagram below: `o` is optional, `R` is required; this is meant for standard dupe-able solids.)
/// ```
/// o o o o
/// o R R o
/// o R R o
/// o o o o
/// ```
const CORE_MIN: u4 = dw.BLOCKS_PER_PARENT / 2 - 1;
const CORE_MAX: u4 = dw.BLOCKS_PER_PARENT / 2;

/// Whether a child cell sits in the core its parent may never lose (see `CORE_MIN`).
inline fn isParentCore(lx: u4, ly: u4) bool {
    return lx >= CORE_MIN and lx <= CORE_MAX and ly >= CORE_MIN and ly <= CORE_MAX;
}

/// Whether a child cell can't be carved; true if the block is the 2x2 core,
/// OR if we want horizonta/vertical arms.
inline fn isProtectedCell(n: [8]Block, lx: u4, ly: u4) bool {
    const core_x = lx >= CORE_MIN and lx <= CORE_MAX;
    const core_y = ly >= CORE_MIN and ly <= CORE_MAX;

    if (core_x and core_y) return true;
    // Neighbor 1 is above, 3 left, 4 right, 6 below (due to edge flags)
    if (core_x) return if (ly < CORE_MIN) n[1].isSolid() else n[6].isSolid();
    if (core_y) return if (lx < CORE_MIN) n[3].isSolid() else n[4].isSolid();
    // The region's corners belong to the silhouette, not to the guarantee.
    return false;
}

comptime {
    // The mask must be able to take the exposed row of a face.
    if (EROSION_DEPTH <= 0.5 * CELL_DENSITY_STEP)
        @compileError("A full erosion mask cannot even reach a face's exposed cell row.");
    // How far past that row it reaches is free, since the core guard, not the mask, is what stops it.
    if (dw.BLOCKS_PER_PARENT % 2 != 0)
        @compileError("A parent's child region needs an even width for its core to sit at the center.");
    if (ORE_KEEP_ALONE <= 0 or ORE_KEEP_ALONE >= 1)
        @compileError("An ore with no support must still be able to both keep and lose a cell.");
    if (ORE_KEEP_ALONE + ORE_KEEP_SUPPORT < 1)
        @compileError("A fully buried ore cell must keep its ore, or a big deposit gets holes.");
    if (GEM_COPIES_MEAN < 1 or GEM_COPIES_MEAN > 1 + NON_ANCHOR_CELLS)
        @compileError("A gem keeps its anchor cell, so its mean sits in [1, region size].");
    if (INFILL_CORNER_CHANCE <= 0 or INFILL_CORNER_CHANCE >= 1)
        @compileError("An infill corner chance must let a corner both fill and stay empty.");
}

/// Returns a foundation donor for an empty parent corner that blocks enclose.
/// Decorations can enclose a hole but cannot become an infill block.
fn enclosedInfillSource(n: [8]Block, lx: u4, ly: u4) ?Block {
    if (lx != 0 and lx != dw.BLOCKS_PER_PARENT - 1) return null;
    if (ly != 0 and ly != dw.BLOCKS_PER_PARENT - 1) return null;
    for (n) |block| if (block.isEmpty() or block.isLiquid()) return null;

    const index: usize = if (ly == 0)
        if (lx == 0) 0 else 2
    else if (lx == 0)
        5
    else
        7;
    if (n[index].isFoundation()) return n[index];
    for (n) |block| if (block.isFoundation()) return block;
    return null;
}

/// Returns the support terrain for an empty macro child corner.
/// A floor macro uses its floor.
/// A ceiling macro uses its ceiling.
/// A suspended macro has no fixed terrain support.
fn macroInfillSource(
    surface: dw.refine.Surface,
    n: [8]Block,
    lx: u4,
    ly: u4,
) ?Block {
    if (lx != 0 and lx != dw.BLOCKS_PER_PARENT - 1) return null;
    if (ly != 0 and ly != dw.BLOCKS_PER_PARENT - 1) return null;

    const support = switch (surface) {
        .floor => n[6],
        .ceiling => n[1],
        .suspended => return null,
    };
    return if (support.isFoundation()) support else null;
}

/// Returns a safe block specification for an infill cell.
/// Only overlays can carry a `base_id`.
inline fn infillSpec(source: Block, seed: u64) memory.BlockSpec {
    return .{
        .id = source.id,
        .base_id = if (source.id.isOverlay()) source.base_id else .none,
        .seed = seed,
        .tag = source.tag.aged(),
    };
}

/// Returns true when this enclosed corner fills.
inline fn infillsCorner(noise_seed: dw.utils.Vec2u, wx: WorldCoord, wy: WorldCoord) bool {
    return seeding.FastHash.hash2dWorld(noise_seed, wx +% INFILL_SALT, wy -% INFILL_SALT) <=
        seeding.oddsNum(INFILL_CORNER_CHANCE);
}

const INFILL_SALT: u64 = 0xA24BAED4963EE407;

/// How much of a parent's own neighborhood backs one child cell,
/// from 0 (an isolated parent) to 1 (a parent buried in the same overlay).
///
/// The 3x3 parent neighborhood is read as a coarse density field:
/// 1 where a neighbor holds the same overlay, 0 where it does not, and 1 at the center.
/// The 16 child cells sample it bilinearly, so a cell that faces more of its own vein keeps
/// its ore more often than a cell that faces bare stone.
/// This is what makes a vein grow ALONG itself instead of into a square.
///
/// Reads the neighbor blocks rather than the parent's `id_edge_flags`, because the material warp
/// can hand a cell an overlay its own parent never had (see `warpedMaterial()`).
/// Neighbors are row-major with the center removed, so index 1 is above and 6 below.
fn overlaySupport(n: [8]Block, overlay: Sprite, lx: u4, ly: u4) f32 {
    var same: [8]f32 = undefined;
    inline for (0..8) |i| same[i] = if (n[i].id == overlay) 1.0 else 0.0;

    // Four blocks meet at each corner of the region: the parent itself, two edge neighbors, and one
    // diagonal. The parent holds the overlay by definition, hence the constant 1.
    const top_left = (1.0 + same[1] + same[3] + same[0]) * 0.25;
    const top_right = (1.0 + same[1] + same[4] + same[2]) * 0.25;
    const bottom_left = (1.0 + same[6] + same[3] + same[5]) * 0.25;
    const bottom_right = (1.0 + same[6] + same[4] + same[7]) * 0.25;

    // Cell centers, so the two outer columns and rows never sit exactly on a corner.
    const inv: f32 = 1.0 / @as(f32, dw.BLOCKS_PER_PARENT);
    const u = (@as(f32, @floatFromInt(lx)) + 0.5) * inv;
    const v = (@as(f32, @floatFromInt(ly)) + 0.5) * inv;

    const top = top_left + (top_right - top_left) * u;
    const bottom = bottom_left + (bottom_right - bottom_left) * u;
    return top + (bottom - top) * v;
}

/// Whether one child cell keeps the ore or gem its parent held.
///
/// The two kinds behave differently on purpose:
/// - An ORE spreads. Its threshold rises with `overlaySupport()`, so a lone nugget frays into a
///   ragged clump and a wide vein comes through whole.
/// - A GEM barely spreads. It keeps `GEM_COPIES_MEAN` cells of 16, so a gem stays a find.
///
/// Both kinds keep an ANCHOR cell, so no deposit is ever wiped out by a descent.
/// The anchor sits inside the parent's core (`isProtectedCell()`), the one part of a region the
/// slope carve may never take, so the guarantee cannot be undone later in the same pass.
inline fn keepsInheritedOverlay(
    overlay: Sprite,
    n: [8]Block,
    noise_seed: dw.utils.Vec2u,
    wx: WorldCoord,
    wy: WorldCoord,
    lx: u4,
    ly: u4,
) bool {
    const parent_hash = seeding.FastHash.hash2dWorld(
        noise_seed,
        wx / dw.BLOCKS_PER_PARENT,
        wy / dw.BLOCKS_PER_PARENT,
    );
    const anchor_x: u4 = CORE_MIN + @as(u4, @intCast(parent_hash & 1));
    const anchor_y: u4 = CORE_MIN + @as(u4, @intCast((parent_hash >> 1) & 1));
    if (lx == anchor_x and ly == anchor_y) return true;

    if (overlay.isGem()) {
        // A separate stream from the anchor, or the two would agree cell for cell.
        const roll = seeding.FastHash.hash2dWorld(noise_seed, wx +% GEM_SALT, wy -% GEM_SALT);
        return roll < seeding.oddsNum(GEM_KEEP_CHANCE);
    }

    const coherent_roll = procedural.getDualValueNoiseFixed(
        noise_seed,
        wx,
        wy,
        1.0 / ORE_THINNING_SCALE,
    )[0];
    return coherent_roll < ORE_KEEP_ALONE + ORE_KEEP_SUPPORT * overlaySupport(n, overlay, lx, ly);
}

/// Keeps the gem draw off every other hash stream this file takes from `noise_seed`.
const GEM_SALT: u64 = 0x632BE59BD9B4E019;

/// Computes a continuous terrain erosion factor in [0, 1] using multi-octave ridged and undulating noise.
fn erosionMask(noise_seed: dw.utils.Vec2u, wx: WorldCoord, wy: WorldCoord) f32 {
    // Value noise, NOT a folded gradient field.
    var gouges: f32 = 0;
    var weight: f32 = 0;
    inline for (0..EROSION_OCTAVES) |octave| {
        const step: f32 = @floatFromInt(@as(u32, 1) << octave);
        const shift = @as(u64, octave) * 0x40383698ed; // large prime-y num
        const v = procedural.getDualValueNoiseFixed(
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
    const undulation = procedural.getDualValueNoiseFixed(
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

/// Half-width of the corner jitter, in density units. Bounds the jitter term at `+/-` this,
/// which is what lets `carvesSlope()` answer without sampling it when the corners already decide.
const JITTER_SPAN = 0.4 * CORNER_UNIT;

/// If true, a block is deleted based on bilinear corner density and erosion noise.
///
/// `warp` is the cell's own `warpField()`, passed in rather than sampled here:
/// `applyAncestorLogic()` needs the same vector for `warpedMaterial()`,
/// and the two MUST be the same sample or the carved silhouette and the material it is cut from disagree.
fn carvesSlope(
    parent_block: Block,
    n: [8]Block,
    noise_seed: dw.utils.Vec2u,
    warp: dw.utils.Vec2f32,
    wx: WorldCoord,
    wy: WorldCoord,
    lx: u4,
    ly: u4,
) bool {
    // The core and its bridges outrank every density and erosion term below; see `CORE_MIN`.
    if (isProtectedCell(n, lx, ly)) return false;

    var buried = true;
    for (n) |b| buried = buried and b.isSolid();
    if (buried) return false;

    const corners = cornerDensities(parent_block, n);

    // Domain-warped bilinear coordinates perturb surface contours and remove axis-aligned rectangular steps.
    const warp_offset_x = (warp[0] - 0.5) * 1.8;
    const warp_offset_y = (warp[1] - 0.5) * 1.8;

    const u = std.math.clamp(
        (2.0 * @as(f32, @floatFromInt(lx)) + 1.0 + warp_offset_x) / 8.0,
        0.0,
        1.0,
    );
    const v = std.math.clamp(
        (2.0 * @as(f32, @floatFromInt(ly)) + 1.0 + warp_offset_y) / 8.0,
        0.0,
        1.0,
    );
    const weights: @Vector(4, f32) = .{ (1 - u) * (1 - v), u * (1 - v), (1 - u) * v, u * v };

    // horizontal/vertical groups of blocks on their own look lonely so we give them "supports" if you will
    const support = @reduce(.Add, corners) * 0.25;
    const body = std.math.clamp(
        (BODY_SUPPORT_NONE - support) / (BODY_SUPPORT_NONE - BODY_SUPPORT_FULL),
        0.0,
        1.0,
    );

    // Everything the noise below can still move the verdict by is bounded, so the bounds are tested
    // FIRST and the samples are only paid for where they can change the answer.
    // The two terms are the jitter (`+/- JITTER_SPAN`) and the erosion mask
    // (from 0-1 so it can only ever raise the carve threshold by at most `EROSION_DEPTH`).
    const settled = @reduce(.Add, corners * weights) + BODY_BIAS * body;
    // Carves whatever either sample says.
    if (settled + JITTER_SPAN < SLOPE_THRESHOLD) return true;
    // Solid whatever either sample says: too deep inside the parent for the mask to reach.
    if (settled - JITTER_SPAN >= @max(3.5 * CORNER_UNIT, SLOPE_THRESHOLD + EROSION_DEPTH)) return false;

    // Continuous noise jitter!
    const jitter = (procedural.getDualValueNoiseFixed(
        noise_seed,
        wx,
        wy,
        1.0 / 7.0,
    )[0] - 0.5) * (2 * JITTER_SPAN);

    const density = settled + jitter;

    // Protect deep parent interiors based on continuous density field
    if (density >= 3.5 * CORNER_UNIT) return false;

    // Same bounds again, now that the jitter is known: the mask is worth 4 more noise samples
    // only in the band where it decides.
    if (density < SLOPE_THRESHOLD) return true;
    if (density >= SLOPE_THRESHOLD + EROSION_DEPTH) return false;

    return density < SLOPE_THRESHOLD + erosionMask(noise_seed, wx, wy) * EROSION_DEPTH;
}

/// Generates a 2D material displacement vector combining coarse directional drift and fine creased noise.
fn warpField(noise_seed: dw.utils.Vec2u, wx: WorldCoord, wy: WorldCoord) dw.utils.Vec2f32 {
    const half: dw.utils.Vec2f32 = @splat(0.5);
    const coarse = procedural.getDualValueNoiseFixed(
        noise_seed,
        wx,
        wy,
        1.0 / MATERIAL_WARP_SCALE,
    );
    const fine = procedural.getDualValueNoiseFixed(
        noise_seed,
        wx,
        wy,
        MATERIAL_WARP_LACUNARITY / MATERIAL_WARP_SCALE,
    );

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

    // isFoundation() also rejects edge stone, which must never bleed inward!
    return if (source.isFoundation()) source else parent_block;
}

/// A liquid parent's level as seen by the child at row `ly` of its region.
/// For example, a block of water at HP = 11 would turn into the following HP water values at D+1:
/// ```
/// 0 0 0 0
/// 3 3 3 3
/// 4 4 4 4
/// 4 4 4 4
/// ```
fn inheritedLiquidVolume(parent_volume: u4, ly: u4) u4 {
    if (parent_volume >= dw.water.RESTING_VOLUME) return memory.Block.MAX_HP;

    const max: u32 = memory.Block.MAX_HP;
    // height of the surface above the region's floor, in the same units, scaled to the region
    const level: u32 = @as(u32, parent_volume) * dw.BLOCKS_PER_PARENT;
    const rows_below: u32 = dw.BLOCKS_PER_PARENT - 1 - ly; // full rows of this column beneath the cell
    return @intCast(@min(max, level -| rows_below * max));
}

/// Whether this parent block is the surface a portal is anchored to:
/// the floor directly under a `.portal`, or the ceiling directly over an `.invportal`.
/// Neighbors are row-major with the center removed, so index 1 is above and index 6 below.
inline fn anchorsPortal(parent_neighbors: [8]Block) bool {
    return parent_neighbors[1].id == .portal or parent_neighbors[6].id == .invportal;
}

/// The two seed streams every cell of one chunk shares:
/// the chunk's own seed material, and the per-depth, per-quadrant noise lane.
///
/// Both are pure functions of the `DepthCoordinate`, and `applyAncestorLogic()` runs once per BLOCK,
/// so resolving them per block repeated one set-associative lookup plus a `mixChunkSeeds()` 256 times a chunk.
const ChunkNoise = struct {
    /// Feeds the per-block hash that becomes `Block.seed`.
    hash_lane: dw.utils.Vec2u,
    /// Feeds every terrain noise field this depth evaluates.
    noise_seed: dw.utils.Vec2u,
};

/// Single-entry memo of `chunkNoise()`. One entry is enough: generation walks a chunk to completion
/// before it moves to the next, and a miss costs exactly what the uncached path always cost.
/// `world.clearCaches()` drops it, since a reseed leaves the same key naming different seeds.
var chunk_noise_key: DepthCoordinate = DepthCoordinate.invalid;
var chunk_noise_value: ChunkNoise = undefined;

/// Drops the `chunkNoise()` memo. Call whenever the seeds behind a `DepthCoordinate` may have changed.
pub fn clearChunkNoise() void {
    chunk_noise_key = DepthCoordinate.invalid;
}

fn chunkNoise(key: DepthCoordinate) ChunkNoise {
    if (chunk_noise_key.depth != 0 and chunk_noise_key.eql(key)) return chunk_noise_value;

    const quadrant_seed = world.quad_cache.getQuadrantSeed(@intCast(key.quadrant), key.depth);
    chunk_noise_value = .{
        .hash_lane = world.seedLane(key),
        .noise_seed = .{
            seeding.NoiseMix.lane(quadrant_seed.value[0], key.depth),
            seeding.NoiseMix.lane(quadrant_seed.value[1], ~key.depth),
        },
    };
    chunk_noise_key = key;
    return chunk_noise_value;
}

/// Makes one child `BlockSpec` from one parent block and its eight neighbors.
///
/// `parent_block` is the source at the shallower depth.
/// `bx` and `by` select one of its `BLOCKS_PER_PARENT` by `BLOCKS_PER_PARENT` children.
/// An empty result is air.
///
/// Processing order:
/// 1. An empty parent usually stays empty. An enclosed corner can receive nearby foundation terrain.
/// 2. Edge stone, planned blocks, liquids, and other non-foundation blocks use their own rules.
/// 3. A foundation child can carve into air. A portal or a planned child can protect its required cell.
/// 4. A surviving foundation child selects its material, then ages its refinement tag.
/// 5. An overlay keeps or loses its underlay. Other stone can evolve and receive an ore or gem.
///
/// The order is required. Geometry decides whether the child exists before material logic can change it.
pub fn applyAncestorLogic(
    parent_block: Block,
    parent_neighbors: [8]Block,
    key: DepthCoordinate,
    bx: u4,
    by: u4,
) memory.BlockSpec {
    const parent_sprite = parent_block.id;

    // Empty parents do not create terrain. Only an enclosed outer corner can borrow foundation terrain.
    if (parent_sprite.isEmpty()) {
        const lx: u4 = @intCast(bx % dw.BLOCKS_PER_PARENT);
        const ly: u4 = @intCast(by % dw.BLOCKS_PER_PARENT);
        const source = enclosedInfillSource(parent_neighbors, lx, ly) orelse return .{};
        const chunk_noise = chunkNoise(key);
        const wx = worldBlock(@intCast(key.quadrant % 2), key.suffix[0], bx);
        const wy = worldBlock(@intCast(key.quadrant / 2), key.suffix[1], by);
        if (!infillsCorner(chunk_noise.noise_seed, wx, wy)) return .{};
        return infillSpec(source, seeding.FastHash.hash2d(chunk_noise.hash_lane, bx, by));
    }
    const chunk_noise = chunkNoise(key);
    const noise_hash_2 = seeding.FastHash.hash2d(chunk_noise.hash_lane, bx, by);
    if (parent_sprite == .edge_stone)
        return .{ .id = parent_sprite, .seed = noise_hash_2 };

    // Waterlogged parents pass their water volume to every waterloggable child.
    const inherited_water: u4 = if (parent_sprite.isWaterloggable()) parent_block.hp else 0;

    const lx: u4 = @intCast(bx % dw.BLOCKS_PER_PARENT);
    const ly: u4 = @intCast(by % dw.BLOCKS_PER_PARENT);
    const noise_seed = chunk_noise.noise_seed;
    const wx = worldBlock(@intCast(key.quadrant % 2), key.suffix[0], bx);
    const wy = worldBlock(@intCast(key.quadrant / 2), key.suffix[1], by);

    // One context gives plans and evolutions the same parent, neighbors, child position, and water.
    const cell: dw.refine.Context = .{
        .parent = parent_block,
        .neighbors = parent_neighbors,
        .noise_seed = noise_seed,
        .wx = wx,
        .wy = wy,
        .lx = lx,
        .ly = ly,
        .seed = noise_hash_2,
        .water = inherited_water,
    };

    // A planned block describes its child region instead of copying into all sixteen cells.
    // If the plan leaves an enclosed corner empty, supporting terrain can fill only that corner.
    if (dw.refine.ruleFor(parent_sprite)) |rule| {
        const refined = dw.refine.refineChild(rule, cell);
        if (refined.id != .none) return refined;

        const source = macroInfillSource(rule.surface, parent_neighbors, lx, ly) orelse return refined;
        if (!infillsCorner(noise_seed, wx, wy)) return refined;
        return infillSpec(source, noise_hash_2);
    }

    if (parent_sprite.isLiquid()) {
        // A liquid below liquid stays full. Otherwise it divides by child row.
        if (parent_neighbors[1].id.isLiquid()) {
            return .{
                .id = dw.refine.evolve(parent_sprite, cell).id,
                .seed = noise_hash_2,
                .water_volume = memory.Block.MAX_HP,
            };
        }

        const volume = inheritedLiquidVolume(parent_block.hp, ly);
        if (volume == 0) return .{};
        return .{
            .id = dw.refine.evolve(parent_sprite, cell).id,
            .seed = noise_hash_2,
            .water_volume = volume,
        };
    }

    // Other non-foundation blocks copy as one child per cell. They do not carve or warp terrain.
    if (!parent_sprite.isFoundation()) {
        return .{
            .id = dw.refine.evolve(parent_sprite, cell).id,
            .seed = noise_hash_2,
            .water_volume = inherited_water,
        };
    }

    // Only foundation terrain reaches this point. It supplies a surface that carving can reshape.
    // No later step can make air solid. A player can safely remain in a carved child cell.

    // Decide geometry before material. Portal landings and planned child cells protect only the cells they need.
    // The same warp sample drives both carving and material selection, so their boundary stays coherent.
    const warp = warpField(noise_seed, wx, wy);
    if (!anchorsPortal(parent_neighbors) and
        !dw.refine.protectsSurfaceCell(parent_neighbors, noise_seed, wx, wy, lx, ly) and
        carvesSlope(parent_block, parent_neighbors, noise_seed, warp, wx, wy, lx, ly)) return .{};

    // The child survived. Select its source material from this parent or a warped neighbor.
    const source = warpedMaterial(parent_block, parent_neighbors, warp, lx, ly);

    // The material source owns the tag. Aging makes temporary plant provenance expire with depth.
    const tag = source.tag.aged();

    // An overlay is valid only on confirmed solid terrain. It either remains or returns to its underlay.
    const is_overlay = source.id.isOverlay() or parent_sprite.isOverlay();
    if (is_overlay) {
        const overlay_id = if (source.id.isOverlay()) source.id else parent_sprite;

        // Resolve the underlay even when the overlay arrived through a warped neighbor.
        const raw_base = if (source.id.isOverlay()) source.base_id else parent_block.base_id;
        const base_id: Sprite = if (raw_base != .none)
            raw_base
        else if (!parent_sprite.isOverlay())
            parent_sprite
        else
            .stone;

        if (!keepsInheritedOverlay(overlay_id, parent_neighbors, noise_seed, wx, wy, lx, ly)) {
            return .{
                .id = base_id,
                .seed = noise_hash_2,
                .water_volume = inherited_water,
                .tag = tag,
            };
        }
        return .{
            .id = overlay_id,
            .base_id = base_id,
            .seed = noise_hash_2,
            .water_volume = inherited_water,
            .tag = tag,
        };
    }

    // Evolve the selected material, not necessarily the original parent material.
    // `refine.evolve()` owns evolution odds and support rules such as a vine's ceiling.
    const evolution = dw.refine.evolve(source.id, cell);
    var evolved_sprite: Sprite = evolution.id;
    var child_tag = tag;
    // A fresh chain records its distance from the ceiling for its next refinement.
    if (evolution.chain_run) |run| child_tag = .make(.chain_run, run);

    if (source.id.isStone()) {
        const ore_density = procedural.getDualValueNoiseFixed(
            noise_seed,
            wx,
            wy,
            1.0 / 23.0,
        )[0];
        if (procedural.disperseOre(
            source.id,
            ore_density,
            wx,
            wy,
            key.depth,
            .fromChunkSeed(noise_seed),
            tag,
        )) |ore| {
            evolved_sprite = ore;
        }
    }

    if (evolved_sprite == .blue_strange_stone and warp[0] > 0.7) evolved_sprite = .blue_stone;

    // A new overlay keeps the selected material as its underlay.
    const base_id: Sprite = if (evolved_sprite.isOverlay())
        (if (source.base_id != .none) source.base_id else source.id)
    else
        .none;

    // The child keeps its visual seed and its surviving provenance tag.
    return .{
        .id = evolved_sprite,
        .base_id = base_id,
        .seed = noise_hash_2,
        .tag = child_tag,
    };
}

/// A parent block and its 8 neighbors, as `applyAncestorLogic()` wants them.
pub const ParentHood = struct {
    parent: Block,
    neighbors: [8]Block align(8),
};

/// Cache of one parent cell and its eight neighbors.
///
/// Sixteen children share one parent. They need only nine parent resolutions, not sixteen groups of nine.
///
/// Four ways let adjacent parent cells remain cached during one chunk generation pass.
const ParentHoodCache = struct {
    /// Sets, chosen so a chunk's worth of parent cells (16 across a chunk edge, plus the halo)
    /// stays resident through one generation pass.
    const SETS = 64;
    /// Ways per set. 4 covers the 2x2 parent cells a child chunk's own region spans, plus a halo cell.
    const WAYS = 4;

    const Entry = struct {
        key: DepthCoordinate = DepthCoordinate.invalid,
        bx: u4 = 0,
        by: u4 = 0,
        hood: ParentHood = undefined,
    };

    entries: [SETS][WAYS]Entry = @splat(@splat(.{})),
    /// Round-robin victim per set. No CLOCK here: the access pattern is a sweep, not a working set,
    /// so recency buys nothing over plain rotation.
    hand: [SETS]std.math.Log2Int(std.meta.Int(.unsigned, WAYS)) = @splat(0),
    comptime {
        if (!std.math.isPowerOfTwo(SETS) or !std.math.isPowerOfTwo(WAYS))
            @compileError("ParentHoodCache set and way counts must be powers of two.");
        // A parent region is BLOCKS_PER_PARENT wide, so a child chunk spans this many parent cells per axis;
        // the cache is pointless if one chunk's sweep cannot hold its own row of them.
        if (SETS * WAYS < (dw.CHUNK_SIZE / dw.BLOCKS_PER_PARENT) * (dw.CHUNK_SIZE / dw.BLOCKS_PER_PARENT))
            @compileError("ParentHoodCache is too small to hold one child chunk's parent cells.");
    }

    inline fn setOf(key: DepthCoordinate, bx: u4, by: u4) usize {
        return @intCast((key.hash() ^ (@as(u64, by) << 4) ^ bx) % SETS);
    }

    fn get(self: *@This(), key: DepthCoordinate, bx: u4, by: u4) ?*const ParentHood {
        const set = &self.entries[setOf(key, bx, by)];
        for (set) |*e| {
            if (e.key.depth != 0 and e.bx == bx and e.by == by and e.key.eql(key)) return &e.hood;
        }
        return null;
    }

    fn put(self: *@This(), key: DepthCoordinate, bx: u4, by: u4, hood: ParentHood) void {
        const idx = setOf(key, bx, by);
        const way = self.hand[idx];
        self.hand[idx] +%= 1; // wraps mod WAYS (power of two)
        self.entries[idx][way] = .{ .key = key, .bx = bx, .by = by, .hood = hood };
    }

    pub fn clear(self: *@This()) void {
        for (&self.entries) |*set| {
            for (set) |*e| e.key = DepthCoordinate.invalid;
        }
        @memset(&self.hand, 0);
    }
};

var parent_hood_cache: ParentHoodCache = .{};

/// Drops the parent neighborhood memo. Called by `world.clearCaches()`.
pub fn clearParentHoods() void {
    parent_hood_cache.clear();
}

/// The parent block at (`parent_key`, `bx`, `by`) and its 8 neighbors, row-major with the center removed.
/// Border cells read as `world_edge_block`: air out there would have the terrain erode toward it.
fn resolveParentHood(parent_key: DepthCoordinate, bx: u4, by: u4) ParentHood {
    var hood: ParentHood = .{
        .parent = getInheritedMaterial(parent_key, bx, by),
        .neighbors = undefined,
    };
    const coord = parent_key.asCoord();

    var n_idx: usize = 0;
    var dy: i32 = -1;
    while (dy <= 1) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            if (dx == 0 and dy == 0) continue;

            const lx = @as(i32, @intCast(bx)) + dx;
            const ly = @as(i32, @intCast(by)) + dy;
            const chunk_off_x = @divFloor(lx, dw.CHUNK_SIZE);
            const chunk_off_y = @divFloor(ly, dw.CHUNK_SIZE);

            // moveAtDepth() returns null only at the world border, where it should be edge_stone
            // (see world.world_edge_block for why air here would be corrosive)
            const target_nc = coord.moveAtDepth(
                .{ chunk_off_x, chunk_off_y },
                parent_key.depth,
            ) orelse {
                hood.neighbors[n_idx] = world.world_edge_block;
                n_idx += 1;
                continue;
            };

            // This uses AncestorCache!
            hood.neighbors[n_idx] = getInheritedMaterial(
                target_nc.asDepthCoordinate(parent_key.depth),
                @intCast(@mod(lx, dw.CHUNK_SIZE)),
                @intCast(@mod(ly, dw.CHUNK_SIZE)),
            );
            n_idx += 1;
        }
    }
    return hood;
}

/// `resolveParentHood()` through the memo; see `ParentHoodCache`.
///
/// A hood is memoized across player edits, and must stay that way.
/// `parent_key.depth` is always below `memory.game.depth`, so it is always below the frontier,
/// and a depth below the frontier can no longer gain an edit that travels down (see `world.legacy_store`).
/// The hoods are therefore fixed while the frontier is, and `world.clearCaches()` covers the moment it moves.
fn parentHood(parent_key: DepthCoordinate, bx: u4, by: u4) ParentHood {
    // The structural half of the invariant above. The other half is `game.depth <= max_depth_reached`,
    // which `world.commitLayer()` keeps.
    std.debug.assert(parent_key.depth < memory.game.depth);
    if (parent_hood_cache.get(parent_key, bx, by)) |hit| return hit.*;

    const hood = resolveParentHood(parent_key, bx, by);
    parent_hood_cache.put(parent_key, bx, by, hood);
    return hood;
}

/// Recursively traces the lineage of a single block type up to parent depths, overlaying player modifications.
/// Accesses and potentially modifies `ancestor_cache`.
pub fn getInheritedMaterial(key: DepthCoordinate, bx: u4, by: u4) Block {
    const target_depth = key.depth;
    const block_idx = (@as(usize, by) << dw.CHUNK_SIZE_LOG2) | bx;

    if (target_depth == memory.game.depth) {
        // current depth is SimBuffer's job
        if (world.getCachedChunk(key)) |chunk| return chunk.blocks[block_idx];
    } else {
        // isHorizonDepth() is false at the base depth, so the base branch below still owns it
        if (isHorizonDepth(target_depth)) return world.getBlockAt(
            key.asCoord(),
            bx,
            by,
            target_depth,
        );
        // cache hit! no need to check mod_store or elsewhere
        if (ancestor_cache.get(key)) |cached| return cached.blocks[block_idx];
    }

    // the base depth has no parent to inherit from, so just materialize
    if (target_depth == STARTING_ZOOM_TIMES) {
        const slot = ancestor_cache.allocateSlot(key);
        world.materializeInheritedChunk(slot, key);
        return slot.blocks[block_idx];
    }

    // Memoized on the PARENT cell, which all `BLOCKS_PER_PARENT` squared children of a region share;
    // see `ParentHoodCache`.
    const p = getParentInfo(key, bx, by);
    const hood = parentHood(p.coord.asDepthCoordinate(target_depth - 1), p.bx, p.by);

    var block = applyAncestorLogic(hood.parent, hood.neighbors, key, bx, by).compile();
    // `inheritedCell()`, not `mod_store`: an edit made after this depth was left stays at this depth.
    if (world.inheritedCell(key, @intCast(block_idx))) |cell| cell.applyTo(&block);
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

test "infill: decorations can enclose but cannot donate" {
    const stone: Block = .makeBasicBlock(.stone, 1);
    const enclosed: [8]Block = @splat(stone);
    try testing.expect(enclosedInfillSource(enclosed, 0, 0) != null);

    var portal_neighbor = enclosed;
    portal_neighbor[1] = .makeBasicBlock(.portal, 2);
    const source = enclosedInfillSource(portal_neighbor, 0, 0).?;
    try testing.expect(source.isFoundation());
    try testing.expect(source.id != .portal);

    var open = enclosed;
    open[1] = .empty;
    try testing.expect(enclosedInfillSource(open, 0, 0) == null);
}

test "infill: floor and ceiling macros use their support terrain" {
    const stone: Block = .makeBasicBlock(.stone, 1);
    var neighbors: [8]Block = @splat(.empty);

    neighbors[6] = stone;
    try testing.expectEqual(stone.id, macroInfillSource(.floor, neighbors, 0, 0).?.id);
    try testing.expect(macroInfillSource(.ceiling, neighbors, 0, 0) == null);

    neighbors[1] = stone;
    try testing.expectEqual(stone.id, macroInfillSource(.ceiling, neighbors, 3, 0).?.id);
    try testing.expect(macroInfillSource(.suspended, neighbors, 3, 0) == null);

    neighbors[6] = .makeBasicBlock(.portal, 2);
    try testing.expect(macroInfillSource(.floor, neighbors, 0, 3) == null);
}

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
            const warp = warpField(seed, wx, wy);
            if (carvesSlope(parent_block, n, seed, warp, wx, wy, lx, ly)) return true;
        }
    }
    return false;
}

test "liquid refinement keeps the surface level and settles downward" {
    const max: u32 = memory.Block.MAX_HP;

    // A parent two thirds full puts its surface two thirds up the region, not at its ceiling.
    try testing.expectEqual(@as(u4, 0), inheritedLiquidVolume(11, 0));
    try testing.expectEqual(@as(u4, 14), inheritedLiquidVolume(11, 1));
    try testing.expectEqual(@as(u4, 15), inheritedLiquidVolume(11, 2));
    try testing.expectEqual(@as(u4, 15), inheritedLiquidVolume(11, 3));

    // A SETTLED parent is full water even though it sits below MAX_HP, so it must refine to solid water.
    // Otherwise the top row empties, and that empty row compounds one depth at a time.
    for (dw.water.RESTING_VOLUME..max + 1) |v| {
        for (0..dw.BLOCKS_PER_PARENT) |ly| {
            try testing.expectEqual(
                @as(u4, memory.Block.MAX_HP),
                inheritedLiquidVolume(@intCast(v), @intCast(ly)),
            );
        }
    }

    for (0..dw.water.RESTING_VOLUME) |v| {
        const parent: u4 = @intCast(v);
        var total: u32 = 0;
        var previous: u4 = 0;
        for (0..dw.BLOCKS_PER_PARENT) |ly| {
            // ly counts DOWN the region, so volume may only grow:
            // a column that is fuller higher up would fall the instant the sim ran.
            const volume = inheritedLiquidVolume(parent, @intCast(ly));
            try testing.expect(volume >= previous);
            previous = volume;
            total += volume;
        }

        // verify correct new water amount
        try testing.expectEqual(@as(u32, parent) * dw.BLOCKS_PER_PARENT, total);
    }
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

test "slope carve: a parent always keeps its core, and only its core is unconditional" {
    // The worst case there is: a lone block with nothing solid around it,
    // so every corner of its region reads one solid neighbor and the density field wants the whole thing gone.
    const parent: Block = .makeBasicBlock(.stone, 11);
    const alone: [8]Block = @splat(.empty);

    var carved_outside = false;
    for (0..dw.BLOCKS_PER_PARENT) |ly| {
        for (0..dw.BLOCKS_PER_PARENT) |lx| {
            const carves = carvesAnywhere(parent, alone, @intCast(lx), @intCast(ly));
            if (isParentCore(@intCast(lx), @intCast(ly))) {
                // A descent onto this block has to have something to land on.
                try testing.expect(!carves);
            } else if (carves) carved_outside = true;
        }
    }

    // ...and the guard has to be a floor, not a blanket: the rest of the region must still erode,
    // or every block in the world squares off into its full 4x4 and the slopes disappear.
    try testing.expect(carved_outside);
}

test "slope carve: solid neighbors stay joined across the border they share" {
    // Verify that line of blocks look joined together at D+1.
    const parent: Block = .makeBasicBlock(.stone, 12345);
    const solid: Block = .makeBasicBlock(.stone, 56789);

    // .{ neighbor index, its opposite, whether the pair meets along x }
    const pairs = .{
        .{ 4, 3, true }, // east / west
        .{ 3, 4, true },
        .{ 6, 1, false }, // south / north
        .{ 1, 6, false },
    };

    inline for (pairs) |pair| {
        var n: [8]Block = @splat(.empty);
        n[pair[0]] = solid;

        // the border this parent shares with that neighbor: the far edge on the meeting axis
        const near_edge = pair[0] == 3 or pair[0] == 1;
        const edge: u4 = if (near_edge) 0 else dw.BLOCKS_PER_PARENT - 1;

        var joined: usize = 0;
        for (CORE_MIN..CORE_MAX + 1) |along| {
            const lx: u4 = if (pair[2]) edge else @intCast(along);
            const ly: u4 = if (pair[2]) @intCast(along) else edge;
            try testing.expect(!carvesAnywhere(parent, n, lx, ly));
            joined += 1;
        }
        // both parents contribute this many cells, so the join is as thick as the core itself
        try testing.expectEqual(@as(usize, dw.BLOCKS_PER_PARENT / 2), joined);

        // the opposite border has no neighbor to reach, so it stays part of the erodible silhouette
        try testing.expect(!isProtectedCell(
            n,
            if (pair[2]) (if (near_edge) dw.BLOCKS_PER_PARENT - 1 else 0) else CORE_MIN,
            if (pair[2]) CORE_MIN else (if (near_edge) dw.BLOCKS_PER_PARENT - 1 else 0),
        ));
    }
}

test "erosion mask: centered on break-even, and spread wide enough to commit" {
    // GOUGE_MEAN is measured from the noise, so it has to be pinned here: if the mask drifts off center it erodes uniformly,
    // which is visually identical to not eroding at all. The spread matters just as much,
    // since a mask hugging its midpoint frays every cell equally.
    const seed: dw.utils.Vec2u = .{ 2345623456, 9090909090 };
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
    // Edge stone stays edge stone!
    const parent: Block = .makeBasicBlock(.stone, 7);
    const border: [8]Block = @splat(world.world_edge_block);
    for (0..4) |ly| {
        for (0..4) |lx| {
            try testing.expect(!carvesAnywhere(parent, border, @intCast(lx), @intCast(ly)));
        }
    }

    // ...and a face that meets the border on one side keeps the cells along it.
    var half = border;
    for (half[0..3]) |*b| b.* = .empty;
    const corners = cornerDensities(parent, half);
    try testing.expect(@reduce(.Min, corners) > 0);
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

    const left = testNeighborhood(left_map, 44444);
    const right = testNeighborhood(right_map, 55555);
    const left_corners = cornerDensities(left[0], left[1]);
    const right_corners = cornerDensities(right[0], right[1]);

    // The left parent's right corners are the right parent's left corners; if these ever disagree,
    // the two parents draw different surfaces and the terrain splits along their shared border.
    try testing.expectEqual(left_corners[1], right_corners[0]);
    try testing.expectEqual(left_corners[3], right_corners[2]);
}

test "material warp: a cell keeps its own material unless the warp reaches a neighbor" {
    const grid = testNeighborhood(
        .{@as([3]bool, @splat(true))} ** 3,
        3,
    );
    var neighbors = grid[1];
    for (&neighbors) |*b| b.* = .makeBasicBlock(.iron, 0);

    // dead center of the warp field: no drag, so every cell answers with its own parent!
    const centered: dw.utils.Vec2f32 = .{ 0.5, 0.5 };
    for (0..4) |ly| {
        for (0..4) |lx| {
            const source = warpedMaterial(
                grid[0],
                neighbors,
                centered,
                @intCast(lx),
                @intCast(ly),
            );
            try testing.expectEqual(grid[0].id, source.id);
        }
    }

    // Directionally warped left: near cells cross into the neighbor, far cells remain in the parent.
    const pulled: dw.utils.Vec2f32 = .{ 0.25, 0.5 };
    try testing.expectEqual(
        Sprite.iron,
        warpedMaterial(grid[0], neighbors, pulled, 0, 1).id,
    );
    try testing.expectEqual(
        grid[0].id,
        warpedMaterial(grid[0], neighbors, pulled, 3, 1).id,
    );
}

/// Cells of one parent's region that keep the parent's overlay.
fn sweepOverlay(overlay: Sprite, n: [8]Block, noise_seed: dw.utils.Vec2u, px: u64, py: u64) usize {
    var kept: usize = 0;
    for (0..dw.BLOCKS_PER_PARENT) |ly| {
        for (0..dw.BLOCKS_PER_PARENT) |lx| {
            if (keepsInheritedOverlay(
                overlay,
                n,
                noise_seed,
                px * dw.BLOCKS_PER_PARENT + lx,
                py * dw.BLOCKS_PER_PARENT + ly,
                @intCast(lx),
                @intCast(ly),
            )) kept += 1;
        }
    }
    return kept;
}

test "a gem keeps one cell plus a couple, and an ore keeps far more" {
    const noise_seed: dw.utils.Vec2u = .{ 0x243f6a8885a308d3, 0x13198a2e03707344 };
    const alone: [8]Block = @splat(.empty);
    const N = 4000;

    var gem_total: usize = 0;
    for (0..N) |i| {
        const kept = sweepOverlay(.quartz, alone, noise_seed, 17, i);
        try testing.expect(kept >= 1); // the anchor never leaves
        gem_total += kept;
    }
    const gem_mean = @as(f64, @floatFromInt(gem_total)) / @as(f64, N);
    try testing.expectApproxEqAbs(@as(f64, GEM_COPIES_MEAN), gem_mean, 0.1);

    // an ore has no neighbors here either, and still spreads over a good part of its region!
    var ore_total: usize = 0;
    for (0..N) |i| ore_total += sweepOverlay(.copper, alone, noise_seed, 17, i);
    const ore_mean = @as(f64, @floatFromInt(ore_total)) / @as(f64, N);
    try testing.expect(ore_mean > gem_mean * 2.0);
}

test "an ore spreads with the vein around it, and a buried one keeps every cell" {
    const noise_seed: dw.utils.Vec2u = .{ 0x9e3779b97f4a7c15, 0xbf58476d1ce4e5b9 };
    const N = 2000;

    const alone: [8]Block = @splat(.empty);
    var vein: [8]Block = @splat(.empty);
    vein[3] = .makeBasicBlock(.copper, 1); // left
    vein[4] = .makeBasicBlock(.copper, 2); // right
    const buried: [8]Block = @splat(.makeBasicBlock(.copper, 3));

    var totals: [3]usize = @splat(0);
    for (0..N) |i| {
        totals[0] += sweepOverlay(.copper, alone, noise_seed, 40, i);
        totals[1] += sweepOverlay(.copper, vein, noise_seed, 40, i);
        // a parent surrounded by its own ore is past the threshold everywhere, so nothing is lost
        try testing.expectEqual(
            @as(usize, dw.BLOCKS_PER_PARENT * dw.BLOCKS_PER_PARENT),
            sweepOverlay(.copper, buried, noise_seed, 40, i),
        );
        totals[2] += dw.BLOCKS_PER_PARENT * dw.BLOCKS_PER_PARENT;
    }
    // more of the parent's own ore around it means more of it survives
    try testing.expect(totals[0] < totals[1]);
    try testing.expect(totals[1] < totals[2]);
}

test "overlay support runs from an isolated parent to a buried one" {
    const alone: [8]Block = @splat(.empty);
    const buried: [8]Block = @splat(.makeBasicBlock(.copper, 1));

    for (0..dw.BLOCKS_PER_PARENT) |ly| {
        for (0..dw.BLOCKS_PER_PARENT) |lx| {
            const low = overlaySupport(alone, .copper, @intCast(lx), @intCast(ly));
            const high = overlaySupport(buried, .copper, @intCast(lx), @intCast(ly));
            try testing.expectApproxEqAbs(@as(f32, 0.25), low, 0.001);
            try testing.expectApproxEqAbs(@as(f32, 1.0), high, 0.001);
        }
    }

    // with ore only to the left, the left column of the region is better supported than the right!
    var left_only: [8]Block = @splat(.empty);
    left_only[3] = .makeBasicBlock(.copper, 1);
    try testing.expect(
        overlaySupport(left_only, .copper, 0, 1) > overlaySupport(left_only, .copper, 3, 1),
    );
}
