//! Handles fractal ancestry and lookup logic.
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

/// Returns whether the specified depth is far enough from the current player depth that discrete coordinates are no longer tracked.
/// At this boundary, chunk-level detail is replaced by the global `quad_cache` 4x4 background grid.
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

    /// Clears the `AncestorCache` and resets clock data.
    /// Resets per tier (small aggregate assignments) rather than one whole-array `@splat` to avoid
    /// building a huge temporary on the 512 KiB shadow stack. Chunk payloads are left as-is; they are
    /// overwritten on allocate.
    pub fn clear(self: *@This()) void {
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
/// Density a child cell needs to stay solid.
///
/// A flat surface puts its corners at exactly two of four blocks solid, which is why the threshold
/// sits there: the first row of cells inside the surface samples an eighth of the way toward the
/// buried corners, clearing it by `SURFACE_MARGIN`.
const SLOPE_THRESHOLD = 2 * CORNER_UNIT;
/// How far the first cell row inside a flat surface clears `SLOPE_THRESHOLD` by.
/// Bilinear sampling puts that row an eighth of the way from a surface corner (32) to a buried one (64).
const SURFACE_MARGIN = (4 * CORNER_UNIT - SLOPE_THRESHOLD) / 8;
/// Density at which a cell counts as interior. No noise may carve a cell whose unshaped density
/// reaches this, which is what bounds every field below to the outer skin of the terrain.
/// A flat face puts its second cell row at 44 and its third at 52, so this also sets how far a face
/// can travel in one depth: two cells.
const INTERIOR_DENSITY = 3 * CORNER_UNIT;
/// Bilinear weight a cell in the corner of the 4x4 draws from the corner it sits nearest.
/// Cell centers land on eighths, so that cell sits at (1/8, 1/8) and takes (7/8)^2 from it.
const CORNER_CELL_WEIGHT = (7.0 / 8.0) * (7.0 / 8.0);
/// How far the erosion noise may push the surface, in density units.
/// This is the fine detail on top of the shape `CORNER_NOISE_AMPLITUDE` decides.
const EROSION_AMPLITUDE = 1.5 * SURFACE_MARGIN;
/// Cell size of the erosion noise, in child blocks (a parent block is `BLOCKS_PER_PARENT` wide).
/// Deliberately not a multiple of `BLOCKS_PER_PARENT` so its features do not line up with the parent grid.
const EROSION_SCALE = 7.0;
/// How far the macro noise may move a corner of the terrain, in density units.
///
/// Large on purpose: at 2 units per cell of surface travel, this is what lets a face pull back or
/// lean over a whole run of blocks instead of sitting exactly where the block counts put it.
/// `INTERIOR_DENSITY` still caps the actual travel at two cells per depth.
const CORNER_NOISE_AMPLITUDE = 12.0;
/// Cell size of the macro corner noise, in PARENT blocks, so its features span many child blocks.
///
/// One octave per depth is correct and deliberate: the world is self-similar, so the octave added at
/// the parent's depth arrives already baked into the corner counts, and the octave added here becomes
/// the coarse one for the children. Descending therefore accumulates a full fBm of slope detail
/// without any depth ever reading past its own parent.
const CORNER_NOISE_SCALE = 6.0;
/// Cell size of the material warp noise, in child blocks.
const MATERIAL_WARP_SCALE = 11.0;
/// How far the warp may drag a material border, in parent blocks.
///
/// A cell center already sits up to 0.375 parent blocks off center, so anything under 1.125 rounds
/// no further than the immediate 3x3 of parents that the lookup has on hand.
/// Under 0.125 the warp can never reach a neighbor at all and material simply stops crossing.
const MATERIAL_WARP_STRENGTH = 0.5;
/// Period of every noise field here, in child blocks.
///
/// Global child coordinates run to 2^64 at depth, far past the 2^24 where an `f32` still resolves
/// single blocks, so they are masked into range first. The cost is one seam per million blocks,
/// which is much cheaper than losing all sub-cell precision everywhere.
/// Must stay a multiple of `BLOCKS_PER_PARENT` so masked child coordinates still divide down onto
/// the parent lattice `cornerNoise()` addresses, and a multiple of `CHUNK_SIZE` so the seam falls on
/// a chunk border rather than through one.
const NOISE_PERIOD_MASK = (1 << 20) - 1;

comptime {
    if ((NOISE_PERIOD_MASK + 1) % dw.CHUNK_SIZE != 0)
        @compileError("The noise period must be a whole number of chunks so its seam falls on a chunk border.");
}

/// Macro noise offset at each of the parent block's four corners, in density units.
///
/// `px`/`py` are the parent block's top left corner in global PARENT block units, so a corner is
/// addressed by its own position in the world and nothing else. Every block touching that corner
/// therefore hashes the identical point and gets the identical offset, which is the only reason a
/// field this large can move the terrain without tearing it at a block, chunk, or parent border.
///
/// Offsetting corners rather than cells is what produces slopes instead of nibbles: pulling one
/// corner in while the next stays put tilts the whole surface running between them, and because the
/// field is smooth over `CORNER_NOISE_SCALE` parent blocks, that tilt is shared by a long run of
/// neighbors and reads as one macro slope.
fn cornerNoise(noise_seed: dw.utils.Vec2u, px: u64, py: u64) @Vector(4, f32) {
    const inv_scale = 1.0 / CORNER_NOISE_SCALE;
    const offsets: @Vector(4, f32) = .{
        procedural.getDualValueNoise(noise_seed, px, py, inv_scale)[0],
        procedural.getDualValueNoise(noise_seed, px +% 1, py, inv_scale)[0],
        procedural.getDualValueNoise(noise_seed, px, py +% 1, inv_scale)[0],
        procedural.getDualValueNoise(noise_seed, px +% 1, py +% 1, inv_scale)[0],
    };
    return (offsets - @as(@Vector(4, f32), @splat(0.5))) * @as(@Vector(4, f32), @splat(2 * CORNER_NOISE_AMPLITUDE));
}

/// Densities at the parent block's four corners, ordered top left, top right, bottom left, bottom right.
///
/// A corner counts how many of the four parent blocks touching it are foundations. Any block sharing
/// that corner counts the same four, so neighboring parents always agree on the surface running
/// between them: no seed, no coordinate, and no chunk identity enters the count, which is what keeps
/// the result seamless across block, chunk, and quadrant borders alike.
/// Neighbors are row-major from the top left (see `Block.edge_flags`), skipping the center.
fn cornerDensities(parent_block: Block, n: [8]Block) @Vector(4, f32) {
    var solid: [8]f32 = undefined;
    for (n, 0..) |b, i| solid[i] = @floatFromInt(@intFromBool(b.isFoundation()));
    const self_solid: f32 = @floatFromInt(@intFromBool(parent_block.isFoundation()));

    return @as(@Vector(4, f32), .{
        self_solid + solid[0] + solid[1] + solid[3],
        self_solid + solid[1] + solid[2] + solid[4],
        self_solid + solid[3] + solid[5] + solid[6],
        self_solid + solid[4] + solid[6] + solid[7],
    }) * @as(@Vector(4, f32), @splat(CORNER_UNIT));
}

/// Returns whether the slope carve removes this cell of a solid parent's 4x4 child grid.
///
/// The parent's terrain is described by its four corners rather than by the block itself, and a cell
/// survives when the bilinear sample of those corners clears `SLOPE_THRESHOLD`. Shared corners make
/// a run of blocks resolve into one continuous surface: flat where the neighbors are flat, and
/// sloped at whatever angle the corner counts imply where the terrain turns.
///
/// Two noise fields then displace that surface, both keyed to global position so either side of any
/// border samples them identically: `cornerNoise()` moves the corners for macro shape, and a finer
/// per-cell field roughens what is left. Neither may touch a cell whose unshaped density has already
/// reached `INTERIOR_DENSITY`, which confines all of it to the outer two cells of the skin.
///
/// A solid parent can therefore never be erased outright, and the two rules that guarantee it are
/// deliberately written against the same constant so they cannot drift apart:
/// a block whose densest cell reaches `INTERIOR_DENSITY` keeps at least that cell, and a block whose
/// densest cell does not is a delicate feature (a one-block wall, an isolated nub) with no interior
/// to erode into, so it is left exactly as its counts describe.
fn carvesSlope(parent_block: Block, n: [8]Block, noise_seed: dw.utils.Vec2u, wx: u64, wy: u64, lx: u4, ly: u4) bool {
    // `lx`/`ly` are where `wx`/`wy` sit inside their parent; the corner math below subtracts one from
    // the other to recover the parent lattice, so a mismatched pair would silently shift the field.
    std.debug.assert(wx % dw.BLOCKS_PER_PARENT == lx and wy % dw.BLOCKS_PER_PARENT == ly);

    // A fully buried block sits at 64 everywhere and cannot be pushed under the threshold, so skip it.
    var buried = true;
    for (n) |b| buried = buried and b.isFoundation();
    if (buried) return false;

    const corners = cornerDensities(parent_block, n);

    // Cell centers land on eighths of the parent block: 1, 3, 5, 7.
    const u = (2 * @as(f32, @floatFromInt(lx)) + 1) / 8;
    const v = (2 * @as(f32, @floatFromInt(ly)) + 1) / 8;
    const weights: @Vector(4, f32) = .{ (1 - u) * (1 - v), u * (1 - v), (1 - u) * v, u * v };

    // Lower bound on the block's densest cell: the cell nearest the fullest corner draws
    // `CORNER_CELL_WEIGHT` of its density from that corner and the rest from corners no smaller than
    // the minimum. If even that cannot reach the interior, no cell in the block can, and the block
    // has no interior to erode into.
    const peak = CORNER_CELL_WEIGHT * @reduce(.Max, corners) + (1 - CORNER_CELL_WEIGHT) * @reduce(.Min, corners);
    if (peak < INTERIOR_DENSITY) return false;
    if (@reduce(.Add, corners * weights) >= INTERIOR_DENSITY) return false;

    // Corner positions in global parent block units; the parent's own corner is the child's cell
    // position with its offset inside the parent removed, scaled back down.
    // `NOISE_PERIOD_MASK` is a multiple of `BLOCKS_PER_PARENT`, so dividing already-masked child
    // coordinates lands on the same parent lattice everyone else derives.
    const shaped = corners + cornerNoise(
        noise_seed,
        (wx - lx) / dw.BLOCKS_PER_PARENT,
        (wy - ly) / dw.BLOCKS_PER_PARENT,
    );
    const erosion = procedural.getDualValueNoise(noise_seed, wx, wy, 1.0 / EROSION_SCALE)[0];

    return @reduce(.Add, shaped * weights) + (erosion - 0.5) * 2 * EROSION_AMPLITUDE < SLOPE_THRESHOLD;
}

/// Picks which of the 3x3 parent blocks hands this child cell its material.
///
/// The cell's offset from its parent's center is dragged around by a smooth 2D warp and then rounded
/// back onto the parent grid: cells near the middle of a parent always keep their own material,
/// while cells near a border can cross into a neighbor. A smooth warp is what makes an ore vein's
/// border come out as a coherent wiggle instead of the per-cell dither an independent random roll
/// gives, and keying it to global coordinates keeps both sides of a border warping identically.
/// Falls back to the parent itself whenever the warp lands on air, decor, or the world edge.
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

/// Applies deterministic logic to a child block based on its parent and 8 parent neighbors.
/// Returns a `memory.BlockSpec` (temp procedural information) that can be compiled to `Block` later.
/// Correctly determines the child's `seed` property when returning it if the block is not empty.
/// Decorations are applied afterward in `procedural.applyAncestorDecorations()`. TODO: actually add this!
/// TODO: also add culling system for invalid decor block configurations in ancestor, determine how to deal with spiral plant
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

    // Every noise field below reads global child coordinates under one quadrant-wide seed, so chunk
    // identity never enters and the fields line up across chunk borders. The depth is folded in to
    // stop a parent's field from repeating verbatim in the children drawn on top of it.
    const quadrant_seed = world.quad_cache.getQuadrantSeed(@intCast(key.quadrant), key.depth);
    const noise_seed: dw.utils.Vec2u = .{ quadrant_seed.value[0] ^ key.depth, quadrant_seed.value[1] };
    const wx = ((key.suffix[0] *% dw.CHUNK_SIZE) +% bx) & NOISE_PERIOD_MASK;
    const wy = ((key.suffix[1] *% dw.CHUNK_SIZE) +% by) & NOISE_PERIOD_MASK;

    if (carvesSlope(parent_block, parent_neighbors, noise_seed, wx, wy, lx, ly)) return .{};

    // Shape and material are decided separately: the carve above says whether the cell is terrain at
    // all, and the warp below says which neighboring vein it belongs to.
    const warp = procedural.getDualValueNoise(noise_seed, wx, wy, 1.0 / MATERIAL_WARP_SCALE);
    const source = warpedMaterial(parent_block, parent_neighbors, warp, lx, ly);
    var evolved_sprite: Sprite = source.id.evolvesTo();

    // The warp field doubles as the patchiness of the strange stone, keeping its blue patches
    // coherent instead of scattering single blocks through the vein.
    if (evolved_sprite == .blue_strange_stone and warp[0] > 0.7) evolved_sprite = .blue_stone;

    // Ores/gems keep the parent's underlay so veins stay visually consistent across zooms (plain stone fallback).
    const base_id: Sprite = if (evolved_sprite.isOverlay())
        (if (source.base_id != .none) source.base_id else .stone)
    else
        .none;

    // Return the new spec, passing the hash down as the new seed for the next generation.
    return .{ .id = evolved_sprite, .base_id = base_id, .seed = noise_hash_2 };
}

/// Traces the lineage of a single block type. Target depth is described in the `DepthCoordinate`.
///
/// A modified chunk does NOT force a full materialization here: the lineage trace stays procedural,
/// and the player's edit is overlaid on the single cell that was asked for.
/// Cached chunks are already materialized, so they need no overlay.
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

            const target_nc = p.coord.moveAtDepth(
                .{ chunk_off_x, chunk_off_y },
                target_depth - 1,
            ) orelse {
                // neighbors[n_idx] = if (target_depth - 1 == STARTING_ZOOM_TIMES) .edge_stone else .none;
                neighbors[n_idx] = .empty;
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

/// Fetches a 6x6 neighborhood of parent IDs for the generator. Requires a specific depth and location.
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

            const target_nc = p_info_origin.coord.moveAtDepth(
                .{ chunk_off_x, chunk_off_y },
                parent_depth,
            ) orelse {
                result[y_idx][x_idx] = .empty;
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

test "slope carve: a buried block is never touched and a face never erodes past its skin" {
    const all_solid: [3]bool = @splat(true);
    const all_air: [3]bool = @splat(false);
    const buried = testNeighborhood(.{all_solid} ** 3, 1000);
    const wall = testNeighborhood(.{ all_air, all_solid, all_solid }, 1000);

    for (0..4) |ly| {
        for (0..4) |lx| {
            try testing.expect(!carvesAnywhere(buried[0], buried[1], @intCast(lx), @intCast(ly)));

            // The wall's two exposed rows are meant to erode. The two under them reach
            // `INTERIOR_DENSITY`, so no combination of noise may reach them.
            if (ly < 2) continue;
            try testing.expect(!carvesAnywhere(wall[0], wall[1], @intCast(lx), @intCast(ly)));
        }
    }
}

test "slope carve: no solid parent can be erased outright" {
    // Every arrangement of neighbors, so the two survival rules are checked against each other:
    // a block with a buried corner keeps the cell nearest it, and a thin one keeps its core.
    for (0..256) |mask| {
        var n: [8]Block = undefined;
        for (&n, 0..) |*b, i| {
            b.* = .makeBasicBlock(if (mask & (@as(usize, 1) << @intCast(i)) != 0) .stone else .none, i);
        }
        const parent: Block = .makeBasicBlock(.stone, 99);

        var survivors: usize = 0;
        for (0..4) |ly| {
            for (0..4) |lx| {
                if (!carvesAnywhere(parent, n, @intCast(lx), @intCast(ly))) survivors += 1;
            }
        }
        try testing.expect(survivors > 0);
    }
}

test "slope carve: an outer corner rounds off without eating the block" {
    // Solid to the bottom right, so the top left of the 4x4 sits outside the surface and the bottom
    // right sits well inside it, whatever the noise does.
    const corner = testNeighborhood(.{
        .{ false, false, true },
        .{ false, true, true },
        .{ true, true, true },
    }, 7);
    const seed: dw.utils.Vec2u = .{ 0x243f6a8885a308d3, 0x13198a2e03707344 };
    try testing.expect(carvesSlope(corner[0], corner[1], seed, 0, 0, 0, 0));
    try testing.expect(!carvesAnywhere(corner[0], corner[1], 3, 3));
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

    // The macro field has to line up on those same shared corners, including across the wrap where
    // one parent sits at the end of the noise period and its neighbor at the start.
    const seed: dw.utils.Vec2u = .{ 0x243f6a8885a308d3, 0x13198a2e03707344 };
    for ([_]u64{ 40, (NOISE_PERIOD_MASK + 1) / dw.BLOCKS_PER_PARENT - 1 }) |px| {
        const here = cornerNoise(seed, px, 12);
        const next = cornerNoise(seed, px +% 1, 12);
        try testing.expectEqual(here[1], next[0]);
        try testing.expectEqual(here[3], next[2]);
    }
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
