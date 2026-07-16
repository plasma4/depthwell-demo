//! Defines the architecture of the fractal world with various datatypes and edge flag logic.
const std = @import("std");
const dw = @import("../root.zig");
const SegmentedList = dw.SegmentedList;
const Sprite = dw.Sprite;
const utils = dw.utils;
const types = dw.types;
const memory = dw.memory;
const seeding = dw.seeding;
const procedural = dw.procedural;
const player = dw.player;
const water = dw.water;

const Vec2i = dw.utils.Vec2i;
const Vec2u = dw.utils.Vec2u;
const Vec2f = dw.utils.Vec2f;
const Chunk = memory.Chunk;
const Block = memory.Block;
const ChunkSeeds = seeding.ChunkSeeds;

const STARTING_ZOOM_TIMES = dw.startup.STARTING_ZOOM_TIMES;
const HORIZON_DEPTH = dw.HORIZON_DEPTH;
const CHUNK_SIZE = dw.CHUNK_SIZE;
const CHUNK_SIZE_SQ = dw.CHUNK_SIZE_SQ;
const CHUNK_SIZE_FLOAT = dw.CHUNK_SIZE_FLOAT;
const CHUNK_SIZE_LOG2 = dw.CHUNK_SIZE_LOG2;
const ZOOM_FACTOR = dw.ZOOM_FACTOR;

/// Final foundation sprite at an absolute base-depth block, plus the plain-stone base it grew from
/// (`base` is only meaningful when `id` is an ore/gem overlay) and the water a structure submerged it in
/// (only meaningful when `id` is waterloggable; see `StructureResult.water_volume`).
const BaseFoundation = struct { id: Sprite, base: Sprite, water_volume: u4 = 0 };

/// One memoized `resolveBaseFoundation()` result, keyed by absolute world block.
const FoundationCacheEntry = struct {
    wx: u32 = 0,
    wy: u32 = 0,
    data: BaseFoundation = undefined,
    occupied: bool = false,
};

/// Direct-mapped cache of `resolveBaseFoundation()` (must be a power of two).
/// Release-only, matching `procedural.getBaseSpriteType()`: debug drags the terrain sliders live.
const FOUNDATION_CACHE_SLOTS = 8192;
var foundation_cache: [FOUNDATION_CACHE_SLOTS]FoundationCacheEntry = @splat(.{});
/// Terrain identity the cache holds; a mismatch (reseed) drops every entry.
var foundation_cache_key: u64 = 0;

/// Direct-mapped slot for a world block; mixes the coords so adjacent blocks do not collide.
inline fn foundationCacheIndex(wx: u32, wy: u32) usize {
    const h = (@as(u64, wx) *% 0x9E3779B97F4A7C15) ^ (@as(u64, wy) *% 0x85EBCA77C2B2AE63);
    return @intCast((h >> 32) & (FOUNDATION_CACHE_SLOTS - 1));
}

/// Resolves the base-depth sprite at absolute chunk (`cx`, `cy`) + local block (`bx`, `by`), memoized.
/// Same as `generateBaseChunk()`: finds world-edge stone, base terrain, ore dispersal (stone only), then structures.
/// Decorations, however, are excluded.
///
/// Both the generator and its base-depth edge-flag halo call this,
/// so a neighbor recomputed for the halo carries the same ore id as the real chunk;
/// `id_edge_flags` then connects a vein to its continuation across the chunk border instead of cutting it off.
fn resolveBaseFoundation(cx: u64, cy: u64, bx: u4, by: u4) BaseFoundation {
    if (dw.is_debug) return computeBaseFoundation(cx, cy, bx, by);

    const wx: u32 = @intCast(cx * CHUNK_SIZE + bx);
    const wy: u32 = @intCast(cy * CHUNK_SIZE + by);

    const key = procedural.terrainGeneration();
    if (key != foundation_cache_key) {
        foundation_cache = @splat(.{});
        foundation_cache_key = key;
    }

    const entry = &foundation_cache[foundationCacheIndex(wx, wy)];
    if (entry.occupied and entry.wx == wx and entry.wy == wy) return entry.data;

    const data = computeBaseFoundation(cx, cy, bx, by);
    entry.* = .{ .wx = wx, .wy = wy, .data = data, .occupied = true };
    return data;
}

/// Uncached foundation evaluation. Call `resolveBaseFoundation()` instead outside of the cache itself.
inline fn computeBaseFoundation(cx: u64, cy: u64, bx: u4, by: u4) BaseFoundation {
    const max_suffix = getMaxSuffixAtDepth(STARTING_ZOOM_TIMES);
    const on_edge_x = (cx == 0 and bx < 2) or (cx == max_suffix and bx >= (CHUNK_SIZE - 2));
    const on_edge_y = (cy == 0 and by < 2) or (cy == max_suffix and by >= (CHUNK_SIZE - 2));
    if (on_edge_x or on_edge_y) return .{ .id = .edge_stone, .base = .none };

    const game = &memory.game;
    const base_data = procedural.getBaseSpriteType(@intCast(cx), @intCast(cy), bx, by);
    const wx: u32 = @intCast(cx * CHUNK_SIZE + bx);
    const wy: u32 = @intCast(cy * CHUNK_SIZE + by);

    var sprite = base_data.sprite;
    if (sprite.isStone()) sprite = procedural.addOresAndGems(
        base_data,
        wx,
        wy,
    );
    const structured = procedural.addStructures(sprite, wx, wy, game.getHashSeed(.structures));
    // A structure that places an overlay such as a Geode gem carries its own stone underlay;
    // fall back to the natural terrain only when it doesn't (.none).
    return .{
        .id = structured.id,
        .base = if (structured.base != .none) structured.base else base_data.sprite,
        .water_volume = structured.water_volume,
    };
}

/// Base-depth sprite at a world block, structures included but decorations excluded.
/// Exists for `debug/audit.zig`, which samples blocks directly rather than by chunk.
pub fn sampleBaseFoundation(wx: u32, wy: u32) Sprite {
    return resolveBaseFoundation(
        wx / CHUNK_SIZE,
        wy / CHUNK_SIZE,
        @intCast(wx % CHUNK_SIZE),
        @intCast(wy % CHUNK_SIZE),
    ).id;
}

/// Solid-only variant of `resolveBaseFoundation()` used by the vine ceiling scan.
/// Returns whether the cell is a foundation (a vine anchor/ceiling), skipping work that cannot change that.
///
/// No ore pass since they don't modify solidity/foundation property.
inline fn resolveFoundationSolid(cx: u64, cy: u64, bx: u4, by: u4) bool {
    const max_suffix = getMaxSuffixAtDepth(STARTING_ZOOM_TIMES);
    const on_edge_x = (cx == 0 and bx < 2) or (cx == max_suffix and bx >= (CHUNK_SIZE - 2));
    const on_edge_y = (cy == 0 and by < 2) or (cy == max_suffix and by >= (CHUNK_SIZE - 2));
    // edge_stone is solid but NOT a foundation, so a world border never anchors a vine
    if (on_edge_x or on_edge_y) return false;

    const base_data = procedural.getBaseSpriteType(@intCast(cx), @intCast(cy), bx, by);
    const wx: u32 = @intCast(cx * CHUNK_SIZE + bx);
    const wy: u32 = @intCast(cy * CHUNK_SIZE + by);
    const structured = procedural.addStructures(base_data.sprite, wx, wy, memory.game.getHashSeed(.structures));
    return structured.id.isFoundation();
}

/// Resolves the world cell `r` rows past this chunk in a column feature's growth direction:
/// - `.down`: `r` rows ABOVE row 0 (the ceiling scan for hanging features).
/// - `.up`: `r` rows BELOW the bottom row (the floor scan for rising features).
///
/// `valid` is false when that cell lies past the world edge, where nothing can anchor a feature.
const ColumnCellBeyond = struct { suffix: Vec2u = .{ 0, 0 }, by: u4 = 0, valid: bool = false };
inline fn columnCellBeyond(coord: Coordinate, r: u32, depth: u64, comptime dir: dw.decorations.GrowDir) ColumnCellBeyond {
    switch (dir) {
        .down => {
            const chunks_up: i32 = @intCast((r + CHUNK_SIZE - 1) / CHUNK_SIZE);
            const by: u4 = @intCast(@as(u32, @intCast(chunks_up)) * CHUNK_SIZE - r);
            const c = coord.moveAtDepth(.{ 0, -chunks_up }, depth) orelse return .{};
            return .{ .suffix = c.suffix, .by = by, .valid = true };
        },
        .up => {
            const chunks_down: i32 = @intCast((r - 1) / CHUNK_SIZE + 1);
            const by: u4 = @intCast((r - 1) % CHUNK_SIZE);
            const c = coord.moveAtDepth(.{ 0, chunks_down }, depth) orelse return .{};
            return .{ .suffix = c.suffix, .by = by, .valid = true };
        },
    }
}

/// Generates a starting chunk at depth `STARTING_ZOOM_TIMES`.
/// Is procedural and does not require all other chunks are pre-calculated.
/// As in, it does not use something like cellular noise that needs a whole map up front.
pub fn generateBaseChunk(chunk: *Chunk, coord: Coordinate) void {
    const depth = STARTING_ZOOM_TIMES;
    const chunk_seeds = quad_cache.getChunkSeeds(coord.asDepthCoordinate(depth));

    var rng_seed = seeding.ChaCha12.init(&chunk_seeds.value[3]); // Seed data only.

    const suffix = coord.suffix;
    const cx = suffix[0];
    const cy = suffix[1];
    for (0..CHUNK_SIZE) |block_y| {
        for (0..CHUNK_SIZE) |block_x| {
            const idx = block_x + block_y * CHUNK_SIZE;

            const bf = resolveBaseFoundation(cx, cy, @intCast(block_x), @intCast(block_y));
            const spec: memory.BlockSpec = .{
                .id = bf.id,
                // Overlay sprites remember the stone they replaced so the shader can composite them over it.
                .base_id = if (bf.id.isOverlay()) bf.base else .none,
                .seed = rng_seed.next(),
                .water_volume = bf.water_volume,
            };
            chunk.blocks[idx] = spec.compile();
        }
    }

    // Mod-blind on purpose: decorations are stamped below, and `materializeChunk()` re-derives these flags
    // with the player's edits overlaid once that is done.
    addEdgeFlags(chunk, coord, depth, null);

    // Decorate the base chunk here so that child depths inherit the results.
    // Hanging vines need the vine state entering each column from the chunk(s) above so they cross the border.
    const vine_seeds = computeVineSeeds(coord, depth);
    dw.decorations.stampChunk(chunk, cx, cy, &vine_seeds);

    resetEmptyEdgeFlags(chunk);
}

/// Computes the hanging-vine (spiral plant) state entering the top of each of this chunk's columns,
/// by deterministically tracing terrain in the chunk(s) directly above.
/// A vine cell can sit at most `Vine.MAX_LENGTH` blocks below its ceiling, so scanning that many rows up captures every ceiling that could feed a vine into row 0.
/// Terrain above is recomputed solidity-only via `resolveFoundationSolid()`
/// (matching how the neighbor chunk generated itself), keeping vines seamless across the border without caching neighbors.
fn computeVineSeeds(coord: Coordinate, depth: u64) [CHUNK_SIZE]dw.decorations.ColumnState {
    return computeColumnSeeds(dw.decorations.Vine.feature, coord, depth);
}

// Compile-time proof that the upward-growth paths (`columnCellBeyond(.up)` + `computeColumnSeeds`) type-check.
// No upward feature is live yet: to add one, declare a `.dir = .up` ColumnFeature in `decorations/`, add it to
// `decorations.columns`, and seed it here with `computeColumnSeeds(my_feature, coord, depth)`.
comptime {
    const up_probe: dw.decorations.ColumnFeature = .{
        .sprite = .spiral_plant,
        .dir = .up,
        .max_length = 12,
        .anchor_odds = 0.05,
        .grow_odds = 0.6,
        .salt = 0x9E3779B97F4A7C15,
    };
    _ = &struct {
        fn probe(coord: Coordinate, depth: u64) [CHUNK_SIZE]dw.decorations.ColumnState {
            return computeColumnSeeds(up_probe, coord, depth);
        }
    }.probe;
}

/// Sibling of `computeVineSeeds()`: computes entering `ColumnState` per column for a `ColumnFeature`
/// by tracing terrain in neighbor chunks along the growth direction.
fn computeColumnSeeds(comptime f: dw.decorations.ColumnFeature, coord: Coordinate, depth: u64) [CHUNK_SIZE]dw.decorations.ColumnState {
    comptime dw.decorations.assertColumnFeature(f);
    var seeds: [CHUNK_SIZE]dw.decorations.ColumnState = @splat(.{});
    const wx_col_base: u64 = coord.suffix[0] * CHUNK_SIZE;

    // Cache neighboring cells for each reach distance once to pull coordinate math out of the scan loop.
    // (cells[r - 1] corresponds to reach r)
    var cells: [f.max_length + 1]ColumnCellBeyond = undefined;
    inline for (&cells, 1..) |*cell, r| cell.* = columnCellBeyond(coord, r, depth, f.dir);

    // Scan pass (reach-outer) to find the nearest anchoring surface for each column.
    // Bails early once all columns anchor or reach limits are hit.
    var anchors: [CHUNK_SIZE]u32 = @splat(0); // 0 = unanchored
    var open: u32 = CHUNK_SIZE;
    for (&cells, 1..) |cell, r| {
        if (open == 0) break;
        if (!cell.valid) continue; // Skip out-of-bounds world edges
        for (0..CHUNK_SIZE) |bx| {
            if (anchors[bx] != 0) continue;
            if (resolveFoundationSolid(cell.suffix[0], cell.suffix[1], @intCast(bx), cell.by)) {
                anchors[bx] = @intCast(r);
                open -= 1;
            }
        }
    }

    // Replay the growth walk from the nearest anchor back toward this chunk's edge.
    for (0..CHUNK_SIZE) |bx| {
        const anchor_r = anchors[bx];
        if (anchor_r == 0) continue;

        var state: dw.decorations.ColumnState = .{};
        var rr: u32 = anchor_r;
        while (rr >= 1) : (rr -= 1) {
            const cell = cells[rr - 1];
            const wx = wx_col_base + bx;
            const wy: u64 = cell.suffix[1] * CHUNK_SIZE + cell.by;
            _ = dw.decorations.stepColumn(f, &state, wx, wy, rr == anchor_r);
        }
        seeds[bx] = state;
    }
    return seeds;
}

/// One authored cell: the only `Block` fields that cannot be recovered by regenerating the chunk.
/// Everything else in a `Block` is derived and is rebuilt by `materializeChunk()`:
/// - `seed` is `CHUNK_SIZE_SQ` deterministic draws in block-index order (`generateBaseChunk()`, `generateChunk()`).
/// - `light` and `lighting_color` are written only into the per-frame render scratch buffer (`applyLighting()`).
/// - `edge_flags`, `id_edge_flags`, and `waterlogged` are recomputed from neighbor `id`+`hp` by the flag passes.
/// - `group_x` and `group_y` are stamped during generation and cleared by any edit.
pub const ModCell = extern struct {
    id: Sprite,
    /// The underlay behind an overlay sprite. Authoritative, NOT derivable: `modifyBlockType()` picks it
    /// from the block that occupied the cell BEFORE the edit, so it depends on the order of past edits.
    base_id: Sprite,
    /// Mining progress for solids, water volume for liquids and waterloggable cells. Range 0-15 (`Block.MAX_HP`).
    hp: u8,

    /// Overwrites the authoritative fields of `block`, leaving every derived field for the flag passes.
    pub inline fn applyTo(self: @This(), block: *Block) void {
        block.id = self.id;
        block.base_id = self.base_id;
        block.hp = @intCast(self.hp);
        block.group_x = 0;
        block.group_y = 0;
    }

    /// Captures the authoritative fields of a materialized `Block`.
    pub inline fn from(block: Block) @This() {
        return .{ .id = block.id, .base_id = block.base_id, .hp = block.hp };
    }
};

/// Words in a `ModEntry.authored` bitmap (one bit per block in a chunk).
const AUTHORED_WORDS = CHUNK_SIZE_SQ / 64;
/// Capacity of a `ModEntry.cells` allocation on first write; doubles from there up to `CHUNK_SIZE_SQ`.
const MIN_MOD_CELLS = 8;

/// The modifications to a single chunk, as a sparse set of authored cells rather than a full `Chunk`.
/// Should ONLY be mutated through `ModificationStore.beginWrite()`: for saving functionality.
pub const ModEntry = struct {
    /// Cells whose value came from a player edit or the water sim rather than from procedural generation.
    /// Bit `i` (block index `by * CHUNK_SIZE + bx`) set means `cells[rank(i)]` holds that cell's value.
    authored: [AUTHORED_WORDS]u64 = @splat(0),
    /// Authored cells in ascending block-index order. The first `count` are live; the rest is spare capacity.
    cells: []ModCell = &.{},
    /// Live entries in `cells`. Always equals the population count of `authored`.
    count: u16 = 0,

    /// Number of authored cells below block index `i`, which is `i`'s position within `cells`.
    inline fn rank(self: *const @This(), i: u8) u16 {
        const word: usize = i >> 6;
        const bit: u6 = @truncate(i);
        var total: u16 = 0;
        for (self.authored[0..word]) |w| total += @popCount(w);
        const below: u64 = (@as(u64, 1) << bit) -% 1;
        return total + @popCount(self.authored[word] & below);
    }

    /// Whether block index `i` carries an authored value (as opposed to its procedural one).
    pub inline fn isAuthored(self: *const @This(), i: u8) bool {
        return (self.authored[i >> 6] >> @as(u6, @truncate(i))) & 1 != 0;
    }

    /// The authored value at block index `i`, or null if that cell is still procedural.
    pub inline fn get(self: *const @This(), i: u8) ?ModCell {
        if (!self.isAuthored(i)) return null;
        return self.cells[self.rank(i)];
    }

    /// Replays every authored cell over a freshly generated chunk.
    /// The caller MUST then rerun the flag pass: replaying ids invalidates the generated edge/waterlogged flags.
    pub fn applyTo(self: *const @This(), chunk: *Chunk) void {
        var i: usize = 0;
        for (0..AUTHORED_WORDS) |w| {
            var bits = self.authored[w];
            while (bits != 0) : (i += 1) {
                const bit = @ctz(bits);
                bits &= bits - 1;
                self.cells[i].applyTo(&chunk.blocks[(w << 6) | bit]);
            }
        }
    }

    /// Writes `cell` at block index `i`, marking it authored. File-private: reach it via `ModWriter.setCell()`.
    fn setCellRaw(self: *@This(), i: u8, cell: ModCell) void {
        const at = self.rank(i);
        if (self.isAuthored(i)) {
            self.cells[at] = cell;
            return;
        }

        if (self.count == self.cells.len) {
            const new_cap = if (self.cells.len == 0) MIN_MOD_CELLS else self.cells.len * 2;
            std.debug.assert(new_cap <= CHUNK_SIZE_SQ); // a chunk cannot author more cells than it has
            self.cells = mod_store.allocator.realloc(self.cells, new_cap) catch memory.oom();
        }

        // Keep `cells` in ascending block-index order so `rank()` indexes it directly.
        std.mem.copyBackwards(
            ModCell,
            self.cells[at + 1 .. self.count + 1],
            self.cells[at..self.count],
        );
        self.cells[at] = cell;
        self.authored[i >> 6] |= @as(u64, 1) << @truncate(i);
        self.count += 1;
    }
};

/// Stores and handles modifications of chunks. Functions across depths.
/// Uses `memory.main_allocator`, NOT the world arena (due to entry freeing being possible).
pub const ModificationStore = struct {
    /// Maps a chunk to its index in `entries`. Indices are stable for the life of the store
    /// (see `entries`), which the budgeted save snapshot relies on.
    index: std.HashMapUnmanaged(
        DepthCoordinate,
        usize,
        DepthCoordinateContext,
        std.hash_map.default_max_load_percentage,
    ) = .empty,

    /// Every modification entry. Can only be appended to so an index (and a pointer) into it stays valid across later insertions:
    /// `save.zig` freezes a plan of `entries` indices and resolves them frames later,
    /// and an entry can be mutated while another is created.
    entries: SegmentedList(ModEntry, 256) = .{},
    /// Indices in `entries` whose chunk was removed, ready to be handed out again.
    /// `entries` itself must never shrink (the save plan holds indices into it), so freed slots are recycled instead.
    free_entries: std.ArrayList(usize) = .empty,
    /// Incremented whenever `entries` is dropped (`init()`/`clear()`), invalidating any external index
    /// into it. A budgeted save snapshot compares this to detect a mid-save wipe and abort.
    generation: u64 = 0,
    allocator: std.mem.Allocator = undefined,
    /// Whether the containers below hold real allocations. Guards `deinit()` before the first `init()`.
    live: bool = false,

    /// Initializes in-place to avoid stack overflow problems. Frees anything a previous world left behind.
    pub fn init(self: *ModificationStore, allocator: std.mem.Allocator) void {
        self.deinit();
        self.* = .{ .allocator = allocator, .live = true, .generation = self.generation +% 1 };
    }

    /// Releases every allocation. Safe to call on a store that was never initialized.
    pub fn deinit(self: *ModificationStore) void {
        if (!self.live) return;
        var it = self.entries.iterator(0);
        while (it.next()) |e| self.allocator.free(e.cells);
        self.entries.deinit(self.allocator);
        self.index.deinit(self.allocator);
        self.free_entries.deinit(self.allocator);
        self.live = false;
    }

    /// Gets an existing modification entry for reading, or null if the chunk is unmodified.
    pub fn get(self: *const @This(), key: DepthCoordinate) ?*const ModEntry {
        const id = self.index.get(key) orelse return null;
        return self.entries.at(id);
    }

    /// The authored value at one block of one chunk, or null if that cell is still procedural.
    /// O(1): the fast path that lets ancestor lookups resolve a single block without materializing a chunk.
    pub fn getCell(self: *const @This(), key: DepthCoordinate, block_idx: u8) ?ModCell {
        const entry = self.get(key) orelse return null;
        return entry.get(block_idx);
    }

    /// Whether a chunk carries any modifications at all.
    pub fn contains(self: *const @This(), key: DepthCoordinate) bool {
        return self.index.contains(key);
    }

    /// Drops a chunk's modifications entirely, recycling its entry slot and cell block.
    /// The chunk reverts to pure procedural generation on its next materialization.
    pub fn remove(self: *@This(), key: DepthCoordinate) void {
        const kv = self.index.fetchRemove(key) orelse return;
        const entry = self.entries.at(kv.value);
        self.allocator.free(entry.cells);
        entry.* = .{};
        self.free_entries.append(self.allocator, kv.value) catch memory.oom();
    }

    /// Completely wipes all user modifications. Should be followed by `world.clearCaches(true)`.
    pub fn clear(self: *@This()) void {
        var it = self.entries.iterator(0);
        while (it.next()) |e| {
            self.allocator.free(e.cells);
            e.* = .{};
        }
        self.index.clearRetainingCapacity();
        self.entries.clearRetainingCapacity();
        self.free_entries.clearRetainingCapacity();
        self.generation +%= 1;
    }

    /// Reserves an entry slot, reusing a freed one when possible.
    fn allocEntry(self: *@This()) usize {
        if (self.free_entries.pop()) |idx| return idx;
        const idx = self.entries.len;
        const slot = self.entries.addOne(self.allocator) catch memory.oom();
        slot.* = .{};
        return idx;
    }

    /// Opens `key`'s entry for mutation, creating it if the chunk has never been modified.
    ///
    /// This is the ONLY way to mutate the store: it preserves the entry's pre-edit contents for an in-flight budgeted save before handing back a writer,
    /// so no call site can forget to.
    pub fn beginWrite(self: *@This(), key: DepthCoordinate) ModWriter {
        const idx = self.index.get(key) orelse blk: {
            const new_idx = self.allocEntry();
            self.index.put(self.allocator, key, new_idx) catch memory.oom();
            break :blk new_idx;
        };
        dw.save.shadowEntryForSave(idx);
        return .{ .entry = self.entries.at(idx) };
    }

    /// Rebuilds an entry straight from a save, bypassing the copy-on-write shadow (nothing can be mid-save during a load).
    /// `cells` must be in ascending block-index order and match `authored`.
    pub fn loadEntry(self: *@This(), key: DepthCoordinate, authored: [AUTHORED_WORDS]u64, cells: []const ModCell) !void {
        const idx = self.allocEntry();
        const entry = self.entries.at(idx);
        entry.authored = authored;
        entry.count = @intCast(cells.len);
        entry.cells = try self.allocator.alloc(ModCell, @max(cells.len, MIN_MOD_CELLS));
        @memcpy(entry.cells[0..cells.len], cells);
        try self.index.put(self.allocator, key, idx);
    }

    /// Total bytes of live `ModCell` payload, for the debug HUD.
    pub fn cellBytes(self: *const @This()) usize {
        var total: usize = 0;
        var it = self.entries.constIterator(0);
        while (it.next()) |e| total += e.cells.len * @sizeOf(ModCell);
        return total;
    }
};

/// A permit to mutate one `ModEntry`, obtained from `ModificationStore.beginWrite()`.
/// Its existence proves the entry was already shadowed for any in-flight save.
pub const ModWriter = struct {
    entry: *ModEntry,

    /// Marks block `i` as authored and stores its value.
    pub inline fn setCell(self: ModWriter, i: u8, cell: ModCell) void {
        self.entry.setCellRaw(i, cell);
    }

    /// Captures a materialized block's authoritative fields as block `i`'s authored value.
    pub inline fn setBlock(self: ModWriter, i: u8, block: Block) void {
        self.entry.setCellRaw(i, .from(block));
    }
};

/// Stores and handles modifications of chunks across various depths.
/// Initialized in `main()`.
pub var mod_store: ModificationStore = .{};

/// Represents a "coordinate", relative to a quad-cache. Stores an "active suffix" as well as the quadrant this coordinate belongs to.
pub const Coordinate = struct {
    /// Active suffix (stored as a vector).
    /// You can think of the active suffix like 32 u2s packed together for the X and Y coordinate.
    /// This can be merged with a correct `quad_cache` quadrant to produce a "complete" path (see `README.md` for more details).
    suffix: Vec2u,
    /// Quadrant ID (00: NW, 1: NE, 2: SW, 3: SE).
    quadrant: u2,

    /// Checks equality between two `Coordinate` values.
    pub inline fn eql(a: @This(), b: @This()) bool {
        return @reduce(.And, a.suffix == b.suffix) and
            a.quadrant == b.quadrant;
    }

    /// Pure 64-bit stateless hash.
    pub inline fn hash(self: @This()) u64 {
        const secret_0 = 0xa0761d6478bd642f;
        const secret_1 = 0xe7037ed1a0b428db;

        // Diffuse suffix using vector multiplication and folding
        var v = self.suffix;
        v *%= Vec2u{ secret_0, secret_1 };
        v ^= v >> @as(Vec2u, @splat(32));

        // Combine vector lanes with quadrant metadata
        // (a single bit flip is good enough for quality!)
        const combined = v[0] ^ v[1] ^ @as(u64, self.quadrant);

        // MurmurHash3 final mix
        var x = combined;
        x ^= x >> 30;
        x *%= 0xbf58476d1ce4e5b9;
        x ^= x >> 27;
        x *%= 0x94d049bb133111eb;
        x ^= x >> 31;
        return x;
    }

    /// Converts a `Coordinate` to a `DepthCoordinate`, provided that a depth is given.
    pub inline fn asDepthCoordinate(self: @This(), depth: u64) DepthCoordinate {
        return .{ .depth = depth, .quadrant = self.quadrant, .suffix = self.suffix };
    }

    /// Adds both an X and Y value, creating a new `Coordinate` and handling quadrants.
    /// Returns null if this change would exceed a quadrant's boundaries at the game's current depth.
    pub inline fn move(self: @This(), shift: Vec2i) ?Coordinate {
        return self.moveAtDepth(shift, memory.game.depth);
    }

    /// Adds both an X and Y value, creating a new `Coordinate` and handling quadrants for a specific depth.
    /// Returns null if this change would exceed boundaries.
    pub inline fn moveAtDepth(self: @This(), shift: Vec2i, depth: u64) ?Coordinate {
        const dx = shift[0];
        const dy = shift[1];
        if (dx == 0 and dy == 0) return self;
        var res = self;

        // X Axis
        if (dx != 0) {
            const is_pos = dx > 0;
            const delta: u64 = if (is_pos) @intCast(dx) else @intCast(-%dx);
            const ov = if (is_pos) @addWithOverflow(res.suffix[0], delta) else @subWithOverflow(res.suffix[0], delta);
            if (ov[1] != 0) {
                if (depth < HORIZON_DEPTH) return null;
                // if (is_pos == ((res.quadrant & 1) != 0)) return null;
                res.quadrant ^= 1;
            }

            if (is_pos and depth < HORIZON_DEPTH and ov[0] > getMaxSuffixAtDepth(depth)) return null;
            res.suffix[0] = ov[0];
        }

        // Y Axis
        if (dy != 0) {
            const is_pos = dy > 0;
            const delta: u64 = if (is_pos) @intCast(dy) else @intCast(-%dy);
            const ov = if (is_pos) @addWithOverflow(res.suffix[1], delta) else @subWithOverflow(res.suffix[1], delta);
            if (ov[1] != 0) {
                if (depth < HORIZON_DEPTH) return null;
                // if (is_pos == ((res.quadrant & 2) != 0)) return null;
                res.quadrant ^= 2;
            }

            if (is_pos and depth < HORIZON_DEPTH and ov[0] > getMaxSuffixAtDepth(depth)) return null;
            res.suffix[1] = ov[0];
        }
        return res;
    }

    /// Adds a certain X value, creating a new Coordinate and handling quadrants.
    /// Returns null if this change would exceed a quadrant's boundaries (or the game's when depth is <= 16).
    pub inline fn moveX(self: @This(), x: i64) ?Coordinate {
        return self.move(.{ x, 0 });
    }

    /// Adds a certain Y value, creating a new Coordinate and handling quadrants.
    /// Returns null if this change would exceed a quadrant's boundaries (or the game's when depth is <= 16).
    pub inline fn moveY(self: @This(), y: i64) ?Coordinate {
        return self.move(.{ 0, y });
    }
};

/// Stores what location a modification with an active suffix and quadrant, as well as its depth, to easily identify it.
///
/// This is useful for accessing ancestor history, like D->D-1->D-2->...->H.
/// (See `README.md` for more details on what D/H mean.)
pub const DepthCoordinate = struct {
    /// Represents an invalid `DepthCoordinate`, which has `depth` equal to 0.
    /// Semantically equivalent to null.
    pub const invalid: @This() = .{
        .depth = 0,
        .quadrant = 0,
        .suffix = .{ 0, 0 },
    };

    /// Active suffix (stored as a vector). Should not be set manually; must call `getParent()` to decrease the depth for depths beyond `HORIZON_DEPTH`.
    /// You can think of the active suffix like 32 `u2` values packed together for the X and Y coordinate.
    /// This coordinate can then be merged with the correct `quad_cache` quadrant to go all the way to H.
    suffix: Vec2u,
    /// The depth of the modification.
    depth: u64,
    /// Quadrant ID (00: NW, 1: NE, 2: SW, 3: SE).
    quadrant: u32,

    /// Pure 64-bit stateless hash.
    pub inline fn hash(self: @This()) u64 {
        const secret_0 = 0xa0761d6478bd642f;
        const secret_1 = 0xe7037ed1a0b428db;
        const secret_2 = 0x517cc1b727220a95;

        // Force scalar execution paths
        const x = (self.suffix[0] *% secret_0) ^ (self.suffix[0] >> 32);
        const y = (self.suffix[1] *% secret_1) ^ (self.suffix[1] >> 32);
        const z = (self.depth *% secret_2) ^ (self.depth >> 32);

        const combined = x ^ y ^ z ^ @as(u64, self.quadrant);

        // MurmurHash3 final mix
        var result = combined;
        result ^= result >> 30;
        result *%= 0xbf58476d1ce4e5b9;
        result ^= result >> 27;
        result *%= 0x94d049bb133111eb;
        result ^= result >> 31;
        return result;
    }

    /// Checks for equality between two `DepthCoordinate` values.
    pub inline fn eql(a: DepthCoordinate, b: DepthCoordinate) bool {
        return a.depth == b.depth and a.quadrant == b.quadrant and @reduce(.And, a.suffix == b.suffix);
    }

    /// Converts any `Coordinate` to a `DepthCoordinate` at the current depth.
    pub inline fn from(coord: Coordinate) @This() {
        return .{
            .suffix = coord.suffix,
            .quadrant = @intCast(coord.quadrant),
            .depth = memory.game.depth,
        };
    }

    /// Converts a `DepthCoordinate` to a `Coordinate`, removing information about depth.
    pub inline fn asCoord(key: @This()) Coordinate {
        return .{
            .suffix = key.suffix,
            .quadrant = @intCast(key.quadrant),
        };
    }

    /// Gets the correct location of D-1, in a `DepthCoordinate` format.
    /// Handles depth decrement, acting as the `pushLayer()` "inverse" for a `DepthCoordinate`.
    pub inline fn getParent(self: @This()) @This() {
        const parent_depth = self.depth - 1;
        const threshold = if (memory.game.depth <= dw.HORIZON_DEPTH)
            dw.HORIZON_DEPTH
        else
            memory.game.depth - dw.HORIZON_DEPTH;

        // No rebasing exists at or below the horizon so bit-shifting does the trick.
        if (self.depth <= dw.HORIZON_DEPTH) {
            const parent_quadrant: u32 = if (parent_depth < threshold) 0 else self.quadrant;
            return .{
                .suffix = self.suffix >> @splat(dw.ZOOM_LOG2),
                .depth = parent_depth,
                .quadrant = parent_quadrant,
            };
        }

        std.debug.assert(self.depth + dw.HORIZON_DEPTH >= memory.game.depth); // can't go to D-33

        // Rebase case! child_depth is larger than the horizon (> 32).
        // Recover the exact 3-bit rebase origin mapped to THIS depth transition.
        const origin_x = quad_cache.getOriginX(self.depth);
        const origin_y = quad_cache.getOriginY(self.depth);

        // The absolute cell within the parent QuadCache uses BOTH the origin offset AND the child's quadrant.
        const child_qx = self.quadrant % 2;
        const child_qy = self.quadrant / 2;

        const cell_x = origin_x + child_qx;
        const cell_y = origin_y + child_qy;

        // Parent quadrant is the macro-cell this child belonged to.
        const parent_qx = cell_x / ZOOM_FACTOR;
        const parent_qy = cell_y / ZOOM_FACTOR;
        var parent_quadrant: u32 = @intCast(parent_qx + parent_qy * 2);
        if (parent_depth < threshold) {
            parent_quadrant = 0;
        }

        // The top bits that "fell off" are the remainder!
        const top_x = cell_x % ZOOM_FACTOR;
        const top_y = cell_y % ZOOM_FACTOR;

        // Effectively, take the top X/Y cell bits, and add in the significant bits of the original suffix at the bottom.
        const shift: u6 = dw.HORIZON_DEPTH * dw.ZOOM_LOG2 - dw.ZOOM_LOG2;
        const px = (top_x << shift) | (self.suffix[0] >> dw.ZOOM_LOG2);
        const py = (top_y << shift) | (self.suffix[1] >> dw.ZOOM_LOG2);

        return .{
            .suffix = .{ px, py },
            .depth = parent_depth,
            .quadrant = parent_quadrant,
        };
    }
};

/// Context for the `DepthCoordinate` (providing hashing and equality checks).
pub const DepthCoordinateContext = struct {
    /// Basic hash function for modifications. Equality is checked if hashes are identical as a fallback.
    pub inline fn hash(self: @This(), key: DepthCoordinate) u64 {
        _ = self;
        return key.hash();
    }

    /// Checks for equality between two `DepthCoordinate` values.
    pub inline fn eql(self: @This(), a: DepthCoordinate, b: DepthCoordinate) bool {
        _ = self;
        return a.depth == b.depth and a.quadrant == b.quadrant and @reduce(.And, a.suffix == b.suffix);
    }
};

/// Width of the simulation buffer.
pub const SIM_BUFFER_WIDTH = 16;
/// Size of the simulation buffer (`SIM_BUFFER_WIDTH` squared).
pub const SIM_BUFFER_SIZE = SIM_BUFFER_WIDTH * SIM_BUFFER_WIDTH;
/// Represents log2(SIM_BUFFER_WIDTH).
pub const SIM_WIDTH_LOG2 = std.math.log2(SIM_BUFFER_WIDTH);
/// Width of the simulation buffer in blocks.
pub const SIM_GRID_SIZE = SIM_BUFFER_WIDTH * CHUNK_SIZE;
/// Square size of the simulation buffer block grid (total blocks).
pub const SIM_GRID_SIZE_SQ = SIM_GRID_SIZE * SIM_GRID_SIZE;

/// Represents the integer type needed to represent indexes inside the simulation buffer.
pub const SimIndexType = std.meta.Int(.unsigned, SIM_WIDTH_LOG2);

/// A combined pool of SimBuffer and chunk cache data.
var chunk_pool: [SIM_BUFFER_SIZE + CHUNK_CACHE_SIZE]Chunk = undefined;

comptime {
    if (!std.math.isPowerOfTwo(SIM_BUFFER_WIDTH)) @compileError("Sim buffer width must be a positive power of 2.");
}

/// The simulation buffer containing 16x16 chunks, centered around the player.
pub const SimBuffer = struct {
    /// Size of the outside ring `precacheChunks()` uses.
    const RING_SIZE = 4 * SIM_BUFFER_WIDTH + 4;
    const RING_OFFSETS = blk: {
        var offs: [RING_SIZE]Vec2i = undefined;
        var i: usize = 0;
        const half_width = @as(i64, SIM_BUFFER_WIDTH) / 2;
        const min_off = -half_width - 1;
        const max_off = half_width;
        // Top and bottom rows (2 * (SIM_BUFFER_WIDTH + 2) chunks total)
        var x: i64 = min_off;
        while (x <= max_off) : (x += 1) {
            offs[i] = .{ x, min_off };
            i += 1;
            offs[i] = .{ x, max_off };
            i += 1;
        }
        // Left and right columns (avoiding corners already covered)
        var y: i64 = min_off + 1;
        while (y <= max_off - 1) : (y += 1) {
            offs[i] = .{ min_off, y };
            i += 1;
            offs[i] = .{ max_off, y };
            i += 1;
        }
        break :blk offs;
    };
    var bg_scan_id: usize = 0;

    pub const sim_buffer_ptr: *[SIM_BUFFER_SIZE]Chunk = chunk_pool[CHUNK_CACHE_SIZE..][0..SIM_BUFFER_SIZE];
    pub var keys: [SIM_BUFFER_SIZE]?Coordinate = @splat(null);

    /// Tracks chunks that MAY contain water per physical slot.
    /// Set on chunk load, manual placement (`markWater()`), and flow expansion.
    /// Also cleared lazily during `tickWater()` when a chunk is found fully drained.
    pub var has_water: std.StaticBitSet(SIM_BUFFER_SIZE) = std.StaticBitSet(SIM_BUFFER_SIZE).initEmpty();

    /// Tracks water chunks at equilibrium (sleeping) that can skip simulation.
    /// Settled automatically when a chunk produces no active flow.
    /// Only cleared/woken up by new flow, manual changes (`wake()`), or chunk (re)loads.
    pub var water_settled: std.StaticBitSet(SIM_BUFFER_SIZE) = std.StaticBitSet(SIM_BUFFER_SIZE).initEmpty();

    /// The coordinate corresponding to the chunk at the "logical" (0, 0) of the 16x16 window.
    var origin: ?Coordinate = null;
    var ring_x: SimIndexType = 0;
    var ring_y: SimIndexType = 0;

    /// Mask for the 16x16 buffer.
    const SIM_MASK = SIM_BUFFER_WIDTH - 1;

    /// Resets the `SimBuffer` completely, clearing tracking, ring buffer offsets, and background scanners.
    pub fn reset() void {
        keys = @splat(null);
        has_water = std.StaticBitSet(SIM_BUFFER_SIZE).initEmpty();
        water_settled = std.StaticBitSet(SIM_BUFFER_SIZE).initEmpty();
        origin = null;
        ring_x = 0;
        ring_y = 0;
        bg_scan_id = 0;
    }

    /// Returns the internal index into the chunk array.
    pub inline fn getIndex(cx: SimIndexType, cy: SimIndexType) usize {
        const rx = (ring_x +% cx) & SIM_MASK;
        const ry = (ring_y +% cy) & SIM_MASK;
        return (@as(usize, ry) << SIM_WIDTH_LOG2) | rx;
    }

    /// Attempts to retrieve a chunk from the buffer, returning null if non-existent.
    pub fn get(coord: Coordinate) ?*Chunk {
        const og = origin orelse return null;
        const dx = coord.suffix[0] -% og.suffix[0];
        const dy = coord.suffix[1] -% og.suffix[1];

        if ((dx | dy) < SIM_BUFFER_WIDTH) {
            const id = getIndex(@intCast(dx), @intCast(dy));
            if (keys[id]) |k| {
                if (k.eql(coord)) return &sim_buffer_ptr[id];
            }
        }
        return null;
    }

    /// Clears the whole `SimBuffer`, invalidating previous data.
    pub inline fn clear() void {
        keys = @splat(null);
        has_water = std.StaticBitSet(SIM_BUFFER_SIZE).initEmpty();
        water_settled = std.StaticBitSet(SIM_BUFFER_SIZE).initEmpty();
        origin = null;
        ring_x = 0;
        ring_y = 0;
    }

    /// Wakes the loaded slot holding `coord` and its 4 orthogonal neighbors (clears their settled bit),
    /// so the water simulation re-evaluates them. Called whenever a block is modified near water.
    pub fn wake(coord: Coordinate) void {
        const og = origin orelse return;
        const dx = coord.suffix[0] -% og.suffix[0];
        const dy = coord.suffix[1] -% og.suffix[1];
        if ((dx | dy) >= SIM_BUFFER_WIDTH) return;
        const cx: SimIndexType = @intCast(dx);
        const cy: SimIndexType = @intCast(dy);
        water_settled.unset(getIndex(cx, cy));
        if (cx > 0) water_settled.unset(getIndex(cx - 1, cy));
        if (cx < SIM_BUFFER_WIDTH - 1) water_settled.unset(getIndex(cx + 1, cy));
        if (cy > 0) water_settled.unset(getIndex(cx, cy - 1));
        if (cy < SIM_BUFFER_WIDTH - 1) water_settled.unset(getIndex(cx, cy + 1));
    }

    /// Scans a chunk for any water/waterlogged block. Used to (re)initialize `has_water` on chunk load
    /// and to lazily re-evaluate the flag for dirtied chunks during `water.tickWater`.
    pub fn chunkHasWater(chunk: *const Chunk) bool {
        for (&chunk.blocks) |b| {
            if (b.isLiquid() or water.getVolume(b) > 0) return true;
        }
        return false;
    }

    /// Reads a block relative to `(bx, by)` in `chunk` (coordinate `coord`) WITHOUT side effects:
    /// in-chunk reads hit `chunk`, cross-chunk reads hit only the loaded SimBuffer. Returns null when
    /// the neighbor falls in a chunk that is not currently resident (or past the world edge), so the
    /// caller can skip validating that block instead of triggering procedural regeneration.
    fn getResidentNeighbor(coord: Coordinate, chunk: *const Chunk, bx: u4, by: u4, ndx: i32, ndy: i32) ?Block {
        const nx = @as(i32, bx) + ndx;
        const ny = @as(i32, by) + ndy;
        if (nx >= 0 and nx < CHUNK_SIZE and ny >= 0 and ny < CHUNK_SIZE) {
            return chunk.blocks[(@as(usize, @intCast(ny)) << CHUNK_SIZE_LOG2) | @as(usize, @intCast(nx))];
        }
        const dcx: i64 = if (nx < 0) -1 else if (nx >= CHUNK_SIZE) 1 else 0;
        const dcy: i64 = if (ny < 0) -1 else if (ny >= CHUNK_SIZE) 1 else 0;
        const ncoord = coord.move(.{ dcx, dcy }) orelse return null;
        const nchunk = get(ncoord) orelse return null;
        const lx: usize = @intCast(nx & (CHUNK_SIZE - 1)); // wraps -1 -> 15, 16 -> 0 (CHUNK_SIZE is a power of two)
        const ly: usize = @intCast(ny & (CHUNK_SIZE - 1));
        return nchunk.blocks[(ly << CHUNK_SIZE_LOG2) | lx];
    }

    /// For testing: Scans every loaded chunk and verifies:
    /// - each block's `edge_flags` is a possible state given its neighborhood.
    /// - all sprites pass `isInWorld()`.
    /// Returns true when all checked blocks are consistent.
    ///
    /// Rules enforced for edge flags (see `updateVisibleChunks()`/`recalcEdgeFlags()`):
    /// - A block that is neither a foundation nor a liquid (decoration, edge stone) must carry the reset sentinel `0xFF`.
    /// - A foundation/liquid block's flags must equal the recomputed value:
    ///   a bit is set toward a neighbor that is a foundation (for solids) or solid-or-liquid (for liquids).
    /// - Air is ignored.
    ///
    /// Blocks whose 8 neighbors are not all resident in the loaded window are skipped, since their
    /// flags were derived from cache/procedural data this side-effect-free scan cannot reproduce.
    /// O(loaded_chunks * 256 * 8); performs no allocation. Intended for debug assertions/tests.
    pub fn validateSimBuffer() bool {
        var all_valid = true;
        for (keys, 0..) |maybe_key, slot| {
            const coord = maybe_key orelse continue;
            const chunk = &sim_buffer_ptr[slot];
            for (0..CHUNK_SIZE) |by| {
                for (0..CHUNK_SIZE) |bx| {
                    const block = chunk.blocks[(by << CHUNK_SIZE_LOG2) | bx];
                    if (block.isInWorld()) {
                        dw.logger.err(@src(), "Not-in-world sprite type found: {s}", .{@tagName(block.id)});
                        all_valid = false;
                    }
                    if (block.isEmpty()) continue;

                    const participates = block.isFoundation() or block.isLiquid();
                    if (!participates) {
                        if (block.edge_flags != 0xFF) {
                            reportInvalidEdge(coord, @intCast(bx), @intCast(by), block.edge_flags, 0xFF);
                            all_valid = false;
                        }
                        continue;
                    }

                    var expected: u8 = 0;
                    var all_resident = true;
                    inline for ([_]i32{ -1, 0, 1 }) |ndy| {
                        inline for ([_]i32{ -1, 0, 1 }) |ndx| {
                            // center (self) is comptime-skipped; only probe while all neighbors so far are resident
                            if ((ndx != 0 or ndy != 0) and all_resident) {
                                if (getResidentNeighbor(coord, chunk, @intCast(bx), @intCast(by), ndx, ndy)) |n| {
                                    const set = if (block.isLiquid()) n.isSolid() or n.isLiquid() else n.isFoundation();
                                    if (set) expected |= types.EdgeFlags.getFlagBit(ndx, ndy);
                                } else all_resident = false;
                            }
                        }
                    }
                    if (!all_resident) continue;

                    if (block.edge_flags != expected) {
                        reportInvalidEdge(coord, @intCast(bx), @intCast(by), block.edge_flags, expected);
                        all_valid = false;
                    }
                }
            }
        }
        return all_valid;
    }

    /// Logs a single edge-flag mismatch found by `checkEdgeFlags()` (debug builds only).
    fn reportInvalidEdge(coord: Coordinate, bx: u4, by: u4, got: u8, expected: u8) void {
        if (!dw.is_debug) return;
        dw.logger.err(@src(), "Invalid edge flags at chunk {any} block ({d}, {d}): got 0b{b:0>8}, expected 0b{b:0>8}", .{ coord, bx, by, got, expected });
    }

    /// Marks the loaded slot holding `coord` (if any) as containing water, so `tickWater()` keeps it
    /// active. Used when water is placed manually (`modifyBlockType()`) outside the simulation.
    pub fn markWater(coord: Coordinate) void {
        const og = origin orelse return;
        const dx = coord.suffix[0] -% og.suffix[0];
        const dy = coord.suffix[1] -% og.suffix[1];
        if ((dx | dy) < SIM_BUFFER_WIDTH) {
            const id = getIndex(@intCast(dx), @intCast(dy));
            if (keys[id]) |k| {
                if (k.eql(coord)) has_water.set(id);
            }
        }
    }

    /// Helper to safely step an origin coordinate, returning the furthest possible coordinate
    /// if a game boundary is hit (when Coordinate.move returns null).
    fn getClampedMove(coord: Coordinate, dx: i64, dy: i64) Coordinate {
        // Fast path: attempt direct move
        if (coord.move(.{ dx, dy })) |target| return target;

        // Slow path: step-clamping (only for hard world boundaries)
        var curr = coord;
        inline for (.{ 0, 1 }) |axis| {
            var remaining = if (axis == 0) dx else dy;
            while (remaining != 0) {
                const step = std.math.sign(remaining);
                const next = if (axis == 0) curr.moveX(step) else curr.moveY(step);
                if (next) |n| {
                    curr = n;
                    remaining -= step;
                } else break;
            }
        }
        return curr;
    }

    /// Synchronizes the buffer to center on the provided coordinate/position.
    /// Safely handles shifts exceeding 1 chunk per frame via `shift`.
    pub inline fn sync(coord: Coordinate, shift: Vec2i) void {
        const half_width = @as(i64, SIM_BUFFER_WIDTH) / 2;
        const og = origin orelse {
            fullRefresh(getClampedMove(coord, -half_width, -half_width));
            return;
        };

        // Small shift: slide the window by `shift` without rebuilding it.
        // incrementalRefresh() advances ring_x/ring_y by exactly `shift`, so it is only valid when the origin also advances by exactly `shift`.
        // At a world edge (depth < HORIZON_DEPTH) the origin move clamps to fewer chunks, which would desync the ring from the origin and make get() map every resident chunk to the wrong slot
        // (all lookups then miss) until the next fullRefresh(). Fall back to a full refresh in that case so the two never drift apart.
        // TODO: is there a better way to do things?
        if (@abs(shift[0]) < SIM_BUFFER_WIDTH and @abs(shift[1]) < SIM_BUFFER_WIDTH) {
            if (shift[0] != 0 or shift[1] != 0) {
                if (og.move(shift) != null) {
                    incrementalRefresh(shift[0], shift[1]);
                } else {
                    fullRefresh(getClampedMove(coord, -half_width, -half_width));
                }
            }
            return;
        }

        // Teleport or large jump fallback
        const target_origin = getClampedMove(coord, -half_width, -half_width);
        if (!og.eql(target_origin)) fullRefresh(target_origin);
    }

    /// Completely invalidates the current buffer state and rebuilds it from scratch centered around a brand-new origin.
    /// Typically triggered upon world initialization, player teleportation, or high-velocity threshold jumps.
    fn fullRefresh(new_origin: Coordinate) void {
        origin = new_origin;
        ring_x = 0;
        ring_y = 0;

        for (0..SIM_BUFFER_WIDTH) |cy| {
            for (0..SIM_BUFFER_WIDTH) |cx| {
                const id = (cy << SIM_WIDTH_LOG2) | cx;
                if (new_origin.move(.{ @intCast(cx), @intCast(cy) })) |cell_coord| {
                    keys[id] = cell_coord;
                    writeChunkSimless(&sim_buffer_ptr[id], cell_coord);
                    has_water.setValue(id, chunkHasWater(&sim_buffer_ptr[id]));
                    water_settled.unset(id); // a freshly loaded chunk must settle at least once
                } else {
                    keys[id] = null;
                    has_water.unset(id);
                }
            }
        }
    }

    /// Shifts the tracking window incrementally by a certain amount of chunks (internal).
    /// Mutates the ring buffer offsets to avoid expensive memory copying,
    /// and replaces ONLY the rows or columns that have newly entered the 16x16 boundary window.
    ///
    /// PRECONDITION: `origin.move(.{dx, dy})` must not clamp (caller `sync()` guarantees this). ring_x/ring_y
    /// advance by the full `dx`/`dy` here, so a clamped origin move would desync them from the origin.
    fn incrementalRefresh(dx: i64, dy: i64) void {
        const old_origin = origin.?;
        const new_origin = getClampedMove(old_origin, dx, dy);
        origin = new_origin;

        ring_x = @intCast((@as(u32, ring_x) +% @as(u32, @bitCast(@as(i32, @intCast(dx))))) & SIM_MASK);
        ring_y = @intCast((@as(u32, ring_y) +% @as(u32, @bitCast(@as(i32, @intCast(dy))))) & SIM_MASK);

        const adx: usize = @intCast(@abs(dx));
        const ady: usize = @intCast(@abs(dy));

        // Refresh new columns
        if (dx != 0) {
            for (0..SIM_BUFFER_WIDTH) |cy_log| {
                for (0..adx) |i| {
                    // New columns are at the leading edge in the direction of travel
                    const cx_log: u4 = if (dx > 0)
                        @intCast(SIM_BUFFER_WIDTH - adx + i)
                    else
                        @intCast(i);
                    const id = getIndex(@intCast(cx_log), @intCast(cy_log));
                    if (new_origin.move(.{ @intCast(cx_log), @intCast(cy_log) })) |cell_coord| {
                        keys[id] = cell_coord;
                        writeChunkSimless(&sim_buffer_ptr[id], cell_coord);
                        has_water.setValue(id, chunkHasWater(&sim_buffer_ptr[id]));
                        water_settled.unset(id); // a freshly loaded chunk must settle at least once
                    } else {
                        keys[id] = null;
                        has_water.unset(id);
                    }
                }
            }
        }

        // Refresh new rows (avoid double-refreshing corners)
        if (dy != 0) {
            for (0..SIM_BUFFER_WIDTH) |cx_log| {
                for (0..ady) |i| {
                    const cy_log: u4 = if (dy > 0)
                        @intCast(SIM_BUFFER_WIDTH - ady + i)
                    else
                        @intCast(i);
                    const id = getIndex(@intCast(cx_log), @intCast(cy_log));
                    if (new_origin.move(.{ @intCast(cx_log), @intCast(cy_log) })) |cell_coord| {
                        keys[id] = cell_coord;
                        writeChunkSimless(&sim_buffer_ptr[id], cell_coord);
                        has_water.setValue(id, chunkHasWater(&sim_buffer_ptr[id]));
                        water_settled.unset(id); // a freshly loaded chunk must settle at least once
                    } else {
                        keys[id] = null;
                        has_water.unset(id);
                    }
                }
            }
        }
    }

    /// Background caching heuristic: scans the boundary immediately outside the 16x16 chunk in the
    /// direction of movement and creates it in `chunk_cache` before the player reaches it.
    ///
    /// Generates `default_amount` chunks when called (suggested value of 1-2).
    /// It is recommended to set a higher `max_amount` (suggested value of ~4, so more budget is available in high-velocity falling situations).
    pub fn precacheChunks(
        player_coord: Coordinate,
        velocity: Vec2f,
        default_amount: comptime_int,
        max_amount: comptime_int,
    ) void {
        if (default_amount < 1 or max_amount < 1) {
            @compileError("Amount of chunks to generate in the background must be positive!");
        }
        const game = &memory.game;
        var generated_count: u32 = 0;

        // Determine primary sweep direction based on highest absolute velocity
        const vx = velocity[0];
        const vy = velocity[1];
        const budget: u32 = if (vx * vx + vy * vy < 500.0) default_amount else max_amount;

        const half_width = @as(i64, SIM_BUFFER_WIDTH) / 2;
        const min_off = -half_width - 1;

        // Priority target based on movement
        const tx: i64 = if (vx > 1.0) half_width else if (vx < -1.0) min_off else (if (game.frame % 2 == 0) half_width else min_off);
        const ty: i64 = if (vy > 1.0) half_width else if (vy < -1.0) min_off else half_width; // Default downward for gravity

        // Check the three chunks in the primary direction of travel
        const targets = if (@abs(vy) > @abs(vx))
            [_]Vec2i{ .{ 0, ty }, .{ -1, ty }, .{ 1, ty } } // Vertical lead
        else
            [_]Vec2i{ .{ tx, 0 }, .{ tx, -1 }, .{ tx, 1 } }; // Horizontal lead

        for (targets) |off| {
            if (generated_count >= budget) break;
            if (player_coord.move(off)) |c| {
                if (get(c) == null and chunk_cache.findIndex(c) == null) {
                    const slot = chunk_cache.allocateIndex(c);
                    generateChunk(&chunk_cache.chunks[slot], c.asDepthCoordinate(memory.game.depth));
                    generated_count += 1;
                }
            }
        }

        // Standard ring sweep for remaining budget
        var checked: usize = 0;
        while (generated_count < budget and checked < RING_SIZE) : (checked += 1) {
            const off = RING_OFFSETS[bg_scan_id];
            bg_scan_id = (bg_scan_id + 1) % RING_SIZE;
            if (player_coord.move(off)) |c| {
                if (get(c) == null and chunk_cache.findIndex(c) == null) {
                    const slot = chunk_cache.allocateIndex(c);
                    generateChunk(&chunk_cache.chunks[slot], c.asDepthCoordinate(memory.game.depth));
                    generated_count += 1;
                }
            }
        }
    }
};

/// Returns a pointer to a block in the active 256x256 SimBuffer grid.
/// Treat out of bounds or inactive chunks as solid.
pub inline fn getSimBlockPtr(x: i32, y: i32) ?*Block {
    if (x < 0 or x >= SIM_GRID_SIZE or y < 0 or y >= SIM_GRID_SIZE) return null;
    const ux: usize = @intCast(x);
    const uy: usize = @intCast(y);
    const cx: SimIndexType = @intCast(ux / CHUNK_SIZE);
    const cy: SimIndexType = @intCast(uy / CHUNK_SIZE);
    const bx: std.meta.Int(.unsigned, CHUNK_SIZE_LOG2) = @intCast(ux % CHUNK_SIZE);
    const by: std.meta.Int(.unsigned, CHUNK_SIZE_LOG2) = @intCast(uy % CHUNK_SIZE);
    const chunk_idx = SimBuffer.getIndex(cx, cy);
    if (SimBuffer.keys[chunk_idx] == null) return null;
    const chunk = &SimBuffer.sim_buffer_ptr[chunk_idx];
    return &chunk.blocks[(@as(usize, by) << CHUNK_SIZE_LOG2) | bx];
}

/// The safe cache size is dynamically calculated based on minimum zoom and screen resolution.
/// Also handles chunks considered by `SimBuffer` already and adds some buffer room.
const CHUNK_CACHE_SIZE: usize = blk: {
    const W: f64 = @floatFromInt(dw.SCREEN_WIDTH);
    const H: f64 = @floatFromInt(dw.SCREEN_HEIGHT);
    const Z: f64 = player.CAMERA_MIN_ZOOM;

    // Per-side border, in chunks, of the render/lighting window (see `chunk.zig` and
    // `lighting.CHUNK_MARGIN`): `margin` chunks each side for light bleed, plus 1 for the
    // floor-alignment straddle. Must track CHUNK_MARGIN so widening light range grows the cache.
    const margin: f64 = @floatFromInt(dw.lighting.CHUNK_MARGIN);
    const border = 2.0 * margin + 1.0;

    // Maximum possible visible chunk grid dimensions (at the most zoomed-out camera scale).
    const C_w = @ceil(W / (256.0 * Z)) + border;
    const C_h = @ceil(H / (256.0 * Z)) + border;

    // Provision for the ENTIRE visible window,
    // rather than only the part that spills outside the SimBuffer with a significant extra buffer.
    const windowed = (C_w + 2.0) * (C_h + 2.0);
    const raw_cache_size = windowed * 2.0 + 32.0;

    const integer_cache_size: usize = @intFromFloat(@ceil(raw_cache_size));
    const aligned_size = ((integer_cache_size + (CHUNK_CACHE_WAYS - 1)) / CHUNK_CACHE_WAYS) * CHUNK_CACHE_WAYS;

    // Conservative minimum baseline (also the floor for tiny screens / high zoom).
    break :blk @max(aligned_size, 256);
};

/// Ways that the cache is split (must be a power of two).
/// Modifying this WILL break things.
const CHUNK_CACHE_WAYS = 4;
const CHUNK_CACHE_SETS = CHUNK_CACHE_SIZE / CHUNK_CACHE_WAYS;

/// A static cache that caches chunks when a generation is attempted.
pub const ChunkCache = struct {
    /// Keys storing `Coordinate` values structured as a 4-way set-associative cache.
    ///
    /// NOTE: We use `@splat()` rather than `@memset()` because Zig might currently compile @memset() naively with many zeroes, even in ReleaseSmall
    /// Simply perfoming assignment rather than `@memset(&myData, @splat(0))` is also a tad easier and will be optimized; it just requires that in Debug, the stack isn't fully taken up.
    keys: [CHUNK_CACHE_SETS][CHUNK_CACHE_WAYS]?Coordinate = @splat(@splat(null)),
    /// Chunks referenced by `keys` at the current depth.
    chunks: *[CHUNK_CACHE_SIZE]Chunk = chunk_pool[0..CHUNK_CACHE_SIZE],

    // crazy int-type creation tech (unused for simplicity)
    // const WaysBitType = std.meta.Int(.unsigned, CHUNK_CACHE_WAYS);
    // const WaysIndexType = std.meta.Int(.unsigned, std.math.log2(CHUNK_CACHE_WAYS));

    /// Data for clock data structure implementation per set.
    clock_bits: [CHUNK_CACHE_SETS]u4 = @splat(0),
    /// Where the hand is located in the clock data structure per set.
    hands: [CHUNK_CACHE_SETS]u2 = @splat(0),

    /// Finds the index of a `Coordinate` in the cache, marking it as "recently used."
    /// Returns null if non-existent.
    pub inline fn findIndex(self: *@This(), coord: Coordinate) ?usize {
        const h = coord.hash();
        const set_idx: usize = @intCast(h % CHUNK_CACHE_SETS);

        inline for (0..CHUNK_CACHE_WAYS) |way| {
            if (self.keys[set_idx][way]) |k| {
                if (k.eql(coord)) {
                    self.clock_bits[set_idx] |= (@as(u4, 1) << way);
                    return set_idx * CHUNK_CACHE_WAYS + way;
                }
            }
        }
        return null;
    }

    /// Evicts an entry using the clock algorithm and returns the index for the new `Coordinate` inside the cache.
    pub inline fn allocateIndex(self: *@This(), coord: Coordinate) usize {
        const h = coord.hash();
        const set_idx: usize = @intCast(h % CHUNK_CACHE_SETS);
        var hand_val = self.hands[set_idx];

        while (true) {
            const way = hand_val;
            hand_val +%= 1;

            const mask = @as(u4, 1) << way;
            if ((self.clock_bits[set_idx] & mask) != 0) {
                self.clock_bits[set_idx] &= ~mask;
            } else {
                self.keys[set_idx][way] = coord;
                self.clock_bits[set_idx] |= mask;
                self.hands[set_idx] = hand_val;
                return set_idx * CHUNK_CACHE_WAYS + way;
            }
        }
    }

    /// Clears the whole `ChunkCache`, invalidating previous data.
    pub inline fn clear(self: *@This()) void {
        self.keys = @splat(@splat(null));
        self.clock_bits = @splat(0);
        self.hands = @splat(0);
    }
};

pub var chunk_cache: ChunkCache = .{};

const QuadrantEdgeDetails = struct {
    most_top: bool,
    most_bottom: bool,
    most_left: bool,
    most_right: bool,
};

/// A static 2x2 grid of seeds only updated when depth increases or game startup.
pub const QuadCache = struct {
    pub const PATH_PREALLOC_SIZE = 256;
    pub const SEED_CACHE_SIZE = 256; // TODO: evaluate why making this large causes a crash
    pub const SEED_CACHE_WAYS = 4;
    pub const SEED_CACHE_SETS = SEED_CACHE_SIZE / SEED_CACHE_WAYS;

    /// Ring length of the per-depth rolling buffers below, indexed by `depth % HISTORY_LEN`.
    /// Must exceed `HORIZON_DEPTH` so a live depth D and its horizon ancestor D-`HORIZON_DEPTH` don't collide.
    pub const HISTORY_LEN = 64;

    comptime {
        if (!std.math.isPowerOfTwo(HISTORY_LEN)) @compileError("HISTORY_LEN must be a power of two so depth % HISTORY_LEN is a mask.");
        // A depth and its horizon ancestor (D - HORIZON_DEPTH) are both live and must not share a slot.
        if (HISTORY_LEN <= HORIZON_DEPTH) @compileError("HISTORY_LEN must exceed HORIZON_DEPTH to keep live depths from aliasing.");
    }

    // Rolling buffers for the sliding window, indexed by `depth % HISTORY_LEN`.
    origins_x: [HISTORY_LEN]u3 = @splat(0),
    origins_y: [HISTORY_LEN]u3 = @splat(0),
    historical_seeds: [HISTORY_LEN]seeding.ChunkSeeds = undefined,

    /// The 512-bit hashes for the 4 active quadrants (sequentially from D to D-31).
    /// (0: NW, 1: NE, 2: SW, 3: SE)
    path_hashes: ChunkSeeds align(memory.MAIN_ALIGN_BYTES),
    /// The 4-by-4 material grid representing the "event horizon" at H (D-32).
    /// The inner 2-by-2 (indices [1..2][1..2]) corresponds to the active quadrants.
    ancestor_materials: [4][4]Block,

    /// A list representing the prefix stack of the top left quadrant's X-coordinate.
    /// NOT for use with ancestory logic.
    left_path: SegmentedList(u64, PATH_PREALLOC_SIZE),
    /// A list representing the prefix stack of the top left quadrant's Y-coordinate.
    /// NOT for use with ancestory logic.
    top_path: SegmentedList(u64, PATH_PREALLOC_SIZE),

    // These 4 properties are used to determine if a QuadCache is at the very edge of the world for chunk gen/zooming in.
    most_top: bool = true,
    most_bottom: bool = true,
    most_left: bool = true,
    most_right: bool = true,

    /// 4-way set-associative cache keys.
    seed_cache_keys: [SEED_CACHE_SETS][SEED_CACHE_WAYS]DepthCoordinate = @splat(@splat(DepthCoordinate.invalid)),
    /// Cached seed values corresponding to `seed_cache_keys`.
    seed_cache_values: [SEED_CACHE_SIZE]seeding.ChunkSeeds = undefined,
    /// Data for clock per set.
    seed_clock_bits: [SEED_CACHE_SETS]u4 = @splat(0),
    /// Clock hand per set.
    seed_hand: [SEED_CACHE_SETS]u2 = @splat(0),

    /// Resets the `SimBuffer` completely, clearing tracking, ring buffer offsets, and background scanners.
    /// Precondition: the world arena MUST be reset to prevent memory leaks!
    pub fn reset(self: *@This()) void {
        self.left_path = .{};
        self.top_path = .{};
        self.most_top = true;
        self.most_bottom = true;
        self.most_left = true;
        self.most_right = true;
    }

    /// Gets the rebase origin X for a given depth (which is asserted to be > `HORIZON_DEPTH`).
    pub inline fn getOriginX(self: *const @This(), depth: u64) u64 {
        std.debug.assert(depth > dw.HORIZON_DEPTH);
        const idx = depth - dw.HORIZON_DEPTH - 1;
        const slot: usize = @intCast(idx / 21);
        const shift: u6 = @intCast((idx % 21) * 3);
        return (self.left_path.at(slot).* >> shift) & 7;
    }

    /// Gets the rebase origin Y for a given depth (which is asserted to be > `HORIZON_DEPTH`).
    pub inline fn getOriginY(self: *const @This(), depth: u64) u64 {
        std.debug.assert(depth > dw.HORIZON_DEPTH);
        const idx = depth - dw.HORIZON_DEPTH - 1;
        const slot: usize = @intCast(idx / 21);
        const shift: u6 = @intCast((idx % 21) * 3);
        return (self.top_path.at(slot).* >> shift) & 7;
    }

    /// Gets the `ancestor_materials` sprite for a specific quadrant.
    /// Asserts the current game depth is large enough for ancestor materials to be valid.
    pub inline fn getQuadrantSpriteAncestor(self: *const @This(), quadrant: u2) Sprite {
        std.debug.assert(memory.game.depth > HORIZON_DEPTH);
        return self.ancestor_materials[1 + (quadrant >> 1)][1 + quadrant % 2];
    }

    /// Returns the 512-bit seed of a specified quadrant (or the global seed if the current depth is <= HORIZON_DEPTH).
    pub inline fn getQuadrantSeed(self: *const @This(), quadrant: u2, depth: u64) seeding.Seed {
        std.debug.assert(memory.game.depth > HORIZON_DEPTH or quadrant == 0);
        if (depth == memory.game.depth) {
            return self.path_hashes.value[quadrant];
        }

        // Below or at HORIZON_DEPTH there is no coordinate rebasing.
        if (depth <= dw.HORIZON_DEPTH) {
            return memory.game.seed;
        }

        return self.historical_seeds[@intCast(depth % HISTORY_LEN)].value[quadrant];
    }

    /// Resolves a chunk's 4 seeds. If depth > 32 (horizon), uses the quadrant seeds.
    /// Uses a 4-way set-associative cache to optimize fractal generation and boundary checks.
    ///
    /// See definition of `ChunkSeeds` for specific meanings.
    pub fn getChunkSeeds(self: *@This(), key: DepthCoordinate) ChunkSeeds {
        const h = key.hash();
        const set_idx: usize = @intCast(h % SEED_CACHE_SETS);

        inline for (0..SEED_CACHE_WAYS) |way| {
            const cache_key = self.seed_cache_keys[set_idx][way];
            if (cache_key.depth != 0 and cache_key.eql(key)) {
                self.seed_clock_bits[set_idx] |= (@as(u4, 1) << way);
                return self.seed_cache_values[set_idx * SEED_CACHE_WAYS + way];
            }
        }

        const seed = self.getQuadrantSeed(@intCast(key.quadrant), key.depth);
        const chunk_seeds = seeding.mixChunkSeeds(
            seed,
            key.suffix,
            key.depth,
        );

        var hand_val = self.seed_hand[set_idx];
        while (true) {
            const way = hand_val;
            hand_val +%= 1;

            const mask = @as(u4, 1) << way;
            if ((self.seed_clock_bits[set_idx] & mask) != 0) {
                self.seed_clock_bits[set_idx] &= ~mask;
            } else {
                self.seed_cache_keys[set_idx][way] = key;
                self.seed_cache_values[set_idx * SEED_CACHE_WAYS + way] = chunk_seeds;
                self.seed_clock_bits[set_idx] |= mask;
                self.seed_hand[set_idx] = hand_val;
                return chunk_seeds;
            }
        }
    }

    /// Returns details on a specific quadrant and what "edges" of the world it touches.
    pub inline fn getQuadrantEdgeDetails(self: *const @This(), quadrant: u2, depth: u64) QuadrantEdgeDetails {
        if (depth <= HORIZON_DEPTH) {
            return .{
                .most_top = true,
                .most_bottom = true,
                .most_left = true,
                .most_right = true,
            };
        }
        return .{
            .most_top = quadrant < 2 and self.most_top,
            .most_bottom = quadrant >= 2 and self.most_bottom,
            .most_left = (quadrant % 2 == 0) and self.most_left,
            .most_right = (quadrant % 2 == 1) and self.most_right,
        };
    }
};

/// The QuadCache that stores information about the 4 quadrants and their history.
pub var quad_cache: QuadCache = .{
    .path_hashes = undefined,
    .left_path = .{}, // easiest to do prealloc with larger stack size in case
    .top_path = .{},
    .ancestor_materials = undefined,
};

/// Represents the answer to the question "what is the largest possible suffix value"?
/// 15 at depth 1, 255 at depth 2, capped at 2**64-1 at depth 16 and beyond.
pub var max_possible_suffix: u64 = 0;

/// Gets the maximum possible suffix at a certain depth (see `max_possible_suffix` for details on meaning).
pub inline fn getMaxSuffixAtDepth(depth: u64) u64 {
    if (depth >= dw.HORIZON_DEPTH) return std.math.maxInt(u64);
    return (@as(u64, 1) << @intCast(depth * dw.ZOOM_LOG2)) - 1;
}

/// `ArenaAllocator` instance used for the world.
pub var arena = memory.makeArena();
/// `Allocator` from `arena`.
pub var alloc = arena.allocator();

/// Creates a new instance of a `Chunk` where specified, given a coordinate. Copies over from cache if possible.
pub fn writeChunk(chunk: *Chunk, coord: Coordinate) void {
    if (SimBuffer.get(coord)) |cached_ptr| {
        chunk.* = cached_ptr.*;
        return;
    }
    writeChunkSimless(chunk, coord);
}

/// Same as `writeChunk()`, but avoids checking `SimBuffer` first.
pub fn writeChunkSimless(chunk: *Chunk, coord: Coordinate) void {
    if (chunk_cache.findIndex(coord)) |i| {
        chunk.* = chunk_cache.chunks[i];
        return;
    }

    const slot_index = chunk_cache.allocateIndex(coord);
    materializeChunk(&chunk_cache.chunks[slot_index], coord.asDepthCoordinate(memory.game.depth));
    chunk.* = chunk_cache.chunks[slot_index];
}

/// Gets a new instance of a `Chunk` at the current depth.
pub inline fn getChunk(coord: Coordinate) Chunk {
    var chunk: Chunk = undefined;
    writeChunk(&chunk, coord);
    return chunk;
}

/// Builds the chunk the player actually sees: procedural generation, then every authored cell replayed on top,
/// then a flag recompute (replaying ids invalidates the flags the generator derived).
///
/// This is the ONLY way a `mod_store` entry should become a `Chunk`; the store holds no block data of its own.
pub fn materializeChunk(chunk: *Chunk, key: DepthCoordinate) void {
    generateChunk(chunk, key);

    const entry = mod_store.get(key);
    if (entry) |e| e.applyTo(chunk);

    if (key.depth != STARTING_ZOOM_TIMES) {
        if (entry != null) addEdgeFlagsFractal(chunk, key);
        return;
    }

    const hood: ModNeighborhood = .collect(key);
    if (!hood.any) return;

    addEdgeFlags(chunk, key.asCoord(), key.depth, &hood);
    resetEmptyEdgeFlags(chunk);
}

/// An empty cell carries no edges. Run after any pass that may have emptied one.
fn resetEmptyEdgeFlags(chunk: *Chunk) void {
    for (0..CHUNK_SIZE_SQ) |idx| {
        const block = &chunk.blocks[idx];
        if (block.isEmpty()) {
            block.edge_flags = 0xFF;
            block.id_edge_flags = 0xFF;
        }
    }
}

/// Does not go through the cache, as its goal is to generate chunks from scratch;
/// branches into base procedural generation or fractal scaling depending on depth.
///
/// Purely procedural: modifications are NOT applied here. Use `materializeChunk()` for the chunk the player actually sees.
pub fn generateChunk(chunk: *Chunk, key: DepthCoordinate) void {
    if (key.depth == STARTING_ZOOM_TIMES) {
        generateBaseChunk(chunk, key.asCoord());
        return;
    }

    const chunk_seeds = quad_cache.getChunkSeeds(key);
    var rng4 = seeding.ChaCha12.init(&chunk_seeds.value[3]);

    const parent_neighborhood = dw.ancestor.getAncestorNeighborhood(key);
    for (0..CHUNK_SIZE) |block_y| {
        for (0..CHUNK_SIZE) |block_x| {
            const idx = block_x + block_y * CHUNK_SIZE;

            const py = (block_y / ZOOM_FACTOR) + 1;
            const px = (block_x / ZOOM_FACTOR) + 1;

            const parent_sprite = parent_neighborhood[py][px];

            // Extract the 8 neighbors from our 6x6 parent neighborhood matrix
            const neighbors: [8]Block align(8) = .{
                parent_neighborhood[py - 1][px - 1],
                parent_neighborhood[py - 1][px],
                parent_neighborhood[py - 1][px + 1],
                parent_neighborhood[py][px - 1],
                parent_neighborhood[py][px + 1],
                parent_neighborhood[py + 1][px - 1],
                parent_neighborhood[py + 1][px],
                parent_neighborhood[py + 1][px + 1],
            };

            var spec = dw.ancestor.applyAncestorLogic(
                parent_sprite,
                neighbors,
                key,
                @intCast(block_x),
                @intCast(block_y),
            );
            spec.seed = rng4.next();
            chunk.blocks[idx] = spec.compile();
        }
    }

    addEdgeFlagsFractal(chunk, key);
}

/// Gets an already materialized chunk without triggering any generation.
/// Every cache it consults holds post-modification blocks, so a hit already carries the player's edits.
pub fn getCachedChunk(key: DepthCoordinate) ?*const Chunk {
    if (key.depth == memory.game.depth) {
        if (SimBuffer.get(key.asCoord())) |cached_ptr| {
            return cached_ptr;
        }
        if (chunk_cache.findIndex(key.asCoord())) |i| {
            return &chunk_cache.chunks[i];
        }
        return null;
    }
    return dw.ancestor.ancestor_cache.get(key);
}

/// The `mod_store` entries of a chunk and its 8 neighbors, indexed by chunk offset (`[dx + 1][dy + 1]`,
/// so the chunk itself sits at `[1][1]`).
///
/// Collected once per-chunk rather than once per halo cell: the border touches the same neighbor chunk up to
/// 16 times in a row, and a per-cell lookup would repeat that hash for every one of them.
///
/// Holding `*const ModEntry` across the flag pass is safe: `entries` is a `SegmentedList` (pointer-stable),
/// and nothing the pass reaches mutates the store.
const ModNeighborhood = struct {
    entries: [3][3]?*const ModEntry = @splat(@splat(null)),
    /// Whether ANY of the nine chunks carries an edit. False lets the caller skip the re-derive outright,
    /// which is the common case and the reason an unmodified world pays nothing for this.
    any: bool = false,

    fn collect(key: DepthCoordinate) ModNeighborhood {
        var result: ModNeighborhood = .{};
        if (mod_store.index.count() == 0) return result;

        const coord = key.asCoord();
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const nc = coord.moveAtDepth(.{ dx, dy }, key.depth) orelse continue;
                const entry = mod_store.get(nc.asDepthCoordinate(key.depth)) orelse continue;
                result.entries[@intCast(dx + 1)][@intCast(dy + 1)] = entry;
                result.any = true;
            }
        }
        return result;
    }

    inline fn at(self: *const @This(), dx: i32, dy: i32) ?*const ModEntry {
        return self.entries[@intCast(dx + 1)][@intCast(dy + 1)];
    }
};

/// Adds edge flags to an already generated chunk using a stack-safe halo buffer.
/// Intentionally does NOT skip non-foundation blocks, so every cell carries usable flags.
///
/// `mods` overlays the player's edits onto the neighbor blocks in the halo. Null while GENERATING, which keeps
/// generation a pure function of the seed; `materializeChunk()` then re-derives the flags with the edits in.
fn addEdgeFlags(target_chunk: *Chunk, coord: Coordinate, depth: u64, mods: ?*const ModNeighborhood) void {
    var halo: [18][18]Sprite = undefined;

    // Fill the center 16x16 from our already generated blocks
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            halo[y + 1][x + 1] = target_chunk.blocks[y * CHUNK_SIZE + x].id;
        }
    }

    const is_base = (depth == STARTING_ZOOM_TIMES);

    // Fill the 1-pixel border (72 pixels total)
    var hy: i32 = -1;
    while (hy <= CHUNK_SIZE) : (hy += 1) {
        var hx: i32 = -1;
        while (hx <= CHUNK_SIZE) : (hx += 1) {
            if (hx >= 0 and hx < CHUNK_SIZE and hy >= 0 and hy < CHUNK_SIZE) continue;

            const ndx = @divFloor(hx, @as(i32, CHUNK_SIZE));
            const ndy = @divFloor(hy, @as(i32, CHUNK_SIZE));
            const lx: u4 = @intCast(@mod(hx, @as(i32, CHUNK_SIZE)));
            const ly: u4 = @intCast(@mod(hy, @as(i32, CHUNK_SIZE)));

            // At base depth we recompute the neighbor deterministically rather than read a cached neighbor chunk,
            // so the halo never depends on how far a neighbor happens to have been generated.
            // resolveBaseFoundation() includes the ore pass, so id_edge_flags matches the adjacent chunk's ore across the border.
            if (is_base) {
                const target_nc = coord.moveAtDepth(.{ ndx, ndy }, depth) orelse {
                    halo[@intCast(hy + 1)][@intCast(hx + 1)] = .none;
                    continue;
                };
                var id = resolveBaseFoundation(target_nc.suffix[0], target_nc.suffix[1], lx, ly).id;

                // The neighbor resolved above is procedural, so it is blind to the player: a block mined in the
                // chunk next door would never open up THIS chunk's border. Overlay the edit, but only once
                // generation is over (`mods` is null during it), so generation stays a pure function of the seed.
                if (mods) |m| {
                    if (m.at(ndx, ndy)) |entry| {
                        const block_idx: u8 = @intCast(@as(usize, ly) * CHUNK_SIZE + lx);
                        if (entry.get(block_idx)) |cell| id = cell.id;
                    }
                }

                halo[@intCast(hy + 1)][@intCast(hx + 1)] = id;
                continue;
            }

            // Fallback for non-base depths (fractal inheritance calculations)
            const target_nc = coord.moveAtDepth(.{ ndx, ndy }, depth) orelse {
                halo[@intCast(hy + 1)][@intCast(hx + 1)] = .none;
                continue;
            };

            halo[@intCast(hy + 1)][@intCast(hx + 1)] = dw.ancestor.getInheritedMaterial(
                target_nc.asDepthCoordinate(depth),
                lx,
                ly,
            ).id;
        }
    }

    // Calculate flags using the static halo buffer
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            var flags: u8 = 0;
            const current_sprite = halo[@intCast(y + 1)][@intCast(x + 1)];

            const left_nb = halo[@intCast(y + 1)][@intCast(x)];
            const right_nb = halo[@intCast(y + 1)][@intCast(x + 2)];
            const top_nb = halo[@intCast(y)][@intCast(x + 1)];
            const bottom_nb = halo[@intCast(y + 2)][@intCast(x + 1)];
            const above_left_nb = halo[@intCast(y)][@intCast(x)];
            const above_right_nb = halo[@intCast(y)][@intCast(x + 2)];

            const state = water.getWaterloggedStateSprites(top_nb, bottom_nb, left_nb, right_nb, above_left_nb, above_right_nb);

            // Same-sprite flags are computed for ALL foundation blocks (one extra compare per neighbor);
            // restrict to isOre()/isGem() here if that ever becomes worth the branch.
            var id_flags: u8 = 0;
            inline for (.{ -1, 0, 1 }) |dy| {
                inline for (.{ -1, 0, 1 }) |dx| {
                    if (dx == 0 and dy == 0) continue;
                    const sprite = halo[@intCast(y + @as(usize, 1 + dy))][@intCast(x + @as(usize, 1 + dx))];

                    const is_solid_or_liquid = sprite.isSolid() or sprite.isLiquid();
                    if ((!current_sprite.isLiquid() and shouldHaveEdgeFlags(sprite)) or (current_sprite.isLiquid() and is_solid_or_liquid)) {
                        flags |= types.EdgeFlags.getFlagBit(dx, dy);
                    }
                    if (sprite == current_sprite) {
                        id_flags |= types.EdgeFlags.getFlagBit(dx, dy);
                    }
                }
            }

            target_chunk.blocks[y * CHUNK_SIZE + x].edge_flags = flags;
            target_chunk.blocks[y * CHUNK_SIZE + x].id_edge_flags = id_flags;
            target_chunk.blocks[y * CHUNK_SIZE + x].waterlogged = state.flags;
        }
    }
}

/// Adds edge flags for deeper depths by applying seeding logic.
fn addEdgeFlagsFractal(target_chunk: *Chunk, key: DepthCoordinate) void {
    var halo: [18][18]Block = undefined;

    // Fast memory copy for the center 16x16 blocks
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            halo[y + 1][x + 1] = target_chunk.blocks[y * CHUNK_SIZE + x];
        }
    }

    const getBlockHelper = struct {
        inline fn func(k: DepthCoordinate, rx: i32, ry: i32) Block {
            const ndx = @divFloor(rx, CHUNK_SIZE);
            const ndy = @divFloor(ry, CHUNK_SIZE);
            const lx: u4 = @intCast(@mod(rx, CHUNK_SIZE));
            const ly: u4 = @intCast(@mod(ry, CHUNK_SIZE));
            const nc = k.asCoord().moveAtDepth(.{ ndx, ndy }, k.depth) orelse return .empty;
            if (getCachedChunk(nc.asDepthCoordinate(k.depth))) |cached_chunk| {
                return cached_chunk.getBlock(lx, ly);
            }
            return dw.ancestor.getInheritedMaterial(nc.asDepthCoordinate(k.depth), lx, ly);
        }
    }.func;

    // Fill the 1-pixel border of the halo (exactly 68 evaluations)
    var hy: i32 = -1;
    while (hy <= CHUNK_SIZE) : (hy += 1) {
        var hx: i32 = -1;
        while (hx <= CHUNK_SIZE) : (hx += 1) {
            if (hx >= 0 and hx < CHUNK_SIZE and hy >= 0 and hy < CHUNK_SIZE) continue;
            halo[@intCast(hy + 1)][@intCast(hx + 1)] = getBlockHelper(key, hx, hy);
        }
    }

    // Process center blocks using local halo reads
    for (0..CHUNK_SIZE) |block_y| {
        for (0..CHUNK_SIZE) |block_x| {
            const idx = block_x + block_y * CHUNK_SIZE;
            const current_block = &target_chunk.blocks[idx];
            const current_sprite = current_block.id;
            if (current_sprite.isEmpty()) continue;

            // Define coordinates as signed types to allow signed offset arithmetic
            const ly: i32 = @intCast(block_y + 1);
            const lx: i32 = @intCast(block_x + 1);

            const left_nb = halo[@intCast(ly)][@intCast(lx - 1)];
            const right_nb = halo[@intCast(ly)][@intCast(lx + 1)];
            const top_nb = halo[@intCast(ly - 1)][@intCast(lx)];
            const bottom_nb = halo[@intCast(ly + 1)][@intCast(lx)];
            const above_left_nb = halo[@intCast(ly - 1)][@intCast(lx - 1)];
            const above_right_nb = halo[@intCast(ly - 1)][@intCast(lx + 1)];

            const state = water.getWaterFlags(top_nb, bottom_nb, left_nb, right_nb, above_left_nb, above_right_nb);

            // Same-sprite flags computed for ALL foundation blocks (see `addEdgeFlags()` for the toggle note).
            var flags: u8 = 0;
            var id_flags: u8 = 0;
            inline for (.{ -1, 0, 1 }) |dy| {
                inline for (.{ -1, 0, 1 }) |dx| {
                    if (dx == 0 and dy == 0) continue;
                    const block = halo[@intCast(ly + dy)][@intCast(lx + dx)];
                    const sprite = block.id;
                    const is_solid_or_liquid = sprite.isSolid() or sprite.isLiquid();
                    if ((!current_sprite.isLiquid() and shouldHaveEdgeFlags(sprite)) or (current_sprite.isLiquid() and is_solid_or_liquid)) {
                        flags |= types.EdgeFlags.getFlagBit(dx, dy);
                    }
                    if (sprite == current_sprite) {
                        id_flags |= types.EdgeFlags.getFlagBit(dx, dy);
                    }
                }
            }
            current_block.edge_flags = flags;
            current_block.id_edge_flags = id_flags;
            current_block.waterlogged = state.flags;
        }
    }
}

/// Returns whether a sprite should have edge flag logic applied to it and be considered a "solid" by edge flag code.
/// More specifically, this by default returns `isFoundation()` and determines if a block should:
/// - Have solid-like edge flag calculations applied to it (default).
/// - As an adjacent block, become considered as a "solid" and changing edge flags of adjacent blocks.
///
/// This may be modified for testing as necessary and is different from the final result in `dw.chunks.updateVisibleChunks()`.
pub inline fn shouldHaveEdgeFlags(sprite: Sprite) bool {
    return sprite.isFoundation();
}

/// Returns whether both sprites are liquids and should therefore use liquid-adjacent edge flags instead.
inline fn isBothLiquid(sprite_a: Sprite, sprite_b: Sprite) bool {
    return sprite_a.isLiquid() and sprite_b.isLiquid();
}

/// Applies a block modification, changing the `Sprite` type and resetting `hp`. Mutates `mod_store` and caches in-place.
/// Returns whether `update_local_edge_flags` instantly removed the current block due to being in an invalid position.
///
/// `prev_block` is the block that occupied this cell BEFORE this action began.
/// The caller must pass the original block (for example, mining reads it before deleting).
pub fn modifyBlockType(coord: Coordinate, bx: u4, by: u4, new_sprite: Sprite, prev_block: Block) bool {
    const key = DepthCoordinate.from(coord);
    const idx: u8 = @intCast(@as(usize, by) * CHUNK_SIZE + bx);

    const initial_hp: u4 = if (new_sprite.isLiquid()) Block.MAX_HP else 0;
    if (new_sprite.isLiquid()) {
        // also emit some faaancy particles
        if (dw.mouse.getMouseBlockCenterPx()) |center| {
            @setFloatMode(.optimized);
            dw.particles.spawnSpriteBurst(
                .water,
                center,
                .{
                    .count = @intCast(dw.particles.seed.next() % 8 + 1),
                },
            );
        }
    }

    // Determine the overlay's underlay from what was here before,
    // so replacing (say) a blue_stone block with gold keeps showing blue_stone behind the ore mask
    // Priority: inherit a previous overlay's underlay, else grow inside the previous solid block, else fall back to plain stone.
    // Non-ore/gem placements carry no underlay.
    const new_base: Sprite = if (new_sprite.isOverlay())
        (if (prev_block.base_id != .none) prev_block.base_id else if (prev_block.isFoundation()) prev_block.id else .stone)
    else
        .none;

    // Single-cell placement: assembly offset is always the origin (0, 0).
    // A future multi-tile placeable will stamp the whole footprint here (see dw.assembly.stampChunk).
    // (TODO)
    mod_store.beginWrite(key).setCell(idx, .{ .id = new_sprite, .base_id = new_base, .hp = initial_hp });

    if (SimBuffer.get(coord)) |sim_chunk| {
        const block: *Block = &sim_chunk.blocks[idx];
        block.id = new_sprite;
        block.base_id = new_base;
        block.hp = initial_hp;
        block.edge_flags = 0xFF;
        block.id_edge_flags = 0xFF;
        block.waterlogged = 0;
        block.group_x = 0;
        block.group_y = 0;
    }

    // Placing water must register the slot so the optimized `tickWater` scan picks it up.
    if (new_sprite.isLiquid()) SimBuffer.markWater(coord);
    // Any block change near water can let it flow again, so wake the surrounding chunks (sleep/wake).
    SimBuffer.wake(coord);

    if (chunk_cache.findIndex(coord)) |index| {
        const block: *Block = &chunk_cache.chunks[index].blocks[idx];
        block.id = new_sprite;
        block.base_id = new_base;
        block.hp = initial_hp;
        block.edge_flags = 0xFF;
        block.id_edge_flags = 0xFF;
        block.waterlogged = 0;
        block.group_x = 0;
        block.group_y = 0;
    }

    return updateLocalEdgeFlags(coord, bx, by);
}

/// Resets one block's fields to the "empty cell" sentinels (id + underlay + hp + edge/waterlog + assembly offset).
/// Leaves `seed` alone: it is a property of the cell, not of what occupies it.
///
/// Must agree field-for-field with the `ModCell` `internalClearBlock()` stores, so a cleared cell reads
/// the same whether it comes from a live cache or from `materializeChunk()`.
inline fn clearBlockFields(b: *Block) void {
    b.id = .none;
    b.base_id = .none;
    b.hp = 0;
    b.edge_flags = 0xFF;
    b.id_edge_flags = 0xFF;
    b.waterlogged = 0;
    b.group_x = 0;
    b.group_y = 0;
}

/// Clears a single cell to empty across `mod_store`, `SimBuffer`, and `chunk_cache` (no drop, no worklist).
/// Used by the anchor cascade and multi-tile group breaking; safe to call outside the worklist loop.
fn internalClearBlock(target_coord: Coordinate, lbx: u4, lby: u4) void {
    const block_id: u8 = @intCast(@as(usize, lby) * CHUNK_SIZE + lbx);
    const key = DepthCoordinate.from(target_coord);
    mod_store.beginWrite(key).setCell(block_id, .{ .id = .none, .base_id = .none, .hp = 0 });
    if (SimBuffer.get(target_coord)) |sc| clearBlockFields(&sc.blocks[block_id]);
    if (chunk_cache.findIndex(target_coord)) |index| clearBlockFields(&chunk_cache.chunks[index].blocks[block_id]);
}

/// Resolves a possibly out-of-chunk cell offset (`cx`, `cy`, relative to `coord`) into a concrete chunk coordinate and local cell,
/// or null past the world edge. Footprints are <= 15x15, so at most one chunk step in each axis is ever needed
/// (adjacent-chunk access, as the lighting halo already does).
const CellRef = struct { coord: Coordinate, lx: u4, ly: u4 };
inline fn resolveCell(coord: Coordinate, cx: i32, cy: i32) ?CellRef {
    if (cx >= 0 and cx < CHUNK_SIZE and cy >= 0 and cy < CHUNK_SIZE) {
        return .{ .coord = coord, .lx = @intCast(cx), .ly = @intCast(cy) };
    }
    const ndx = @divFloor(cx, CHUNK_SIZE);
    const ndy = @divFloor(cy, CHUNK_SIZE);
    const nc = coord.move(.{ ndx, ndy }) orelse return null;
    return .{ .coord = nc, .lx = @intCast(@mod(cx, CHUNK_SIZE)), .ly = @intCast(@mod(cy, CHUNK_SIZE)) };
}

/// True while `updateLocalEdgeFlags()` is draining `flag_worklist`;
/// guards `clearAssemblyRest()` against re-entering that drain (which would clear the worklist mid-iteration).
var in_edge_flag_update = false;

/// Clears every cell of `block`'s multi-tile assembly EXCEPT (`bx`, `by`). Does not drop items (the caller drops once).
/// Since the caller already removed the cell a group breaks as one unit. No-op for single-tile blocks.
/// `block` must be the pre-removal snapshot; its group_x/group_y locate the origin.
///
/// Edge-flag refresh: when called from inside the cascade drain (`in_edge_flag_update`),
/// cleared siblings are queued onto `flag_worklist` for that same drain; otherwise each is refreshed directly.
pub fn clearAssemblyRest(coord: Coordinate, bx: u4, by: u4, block: Block) void {
    const f = dw.assembly.footprintOf(block.id);
    if (f.w <= 1 and f.h <= 1) return;
    const ox = @as(i32, bx) - block.group_x;
    const oy = @as(i32, by) - block.group_y;
    var dy: i32 = 0;
    while (dy < f.h) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < f.w) : (dx += 1) {
            const cx = ox + dx;
            const cy = oy + dy;
            if (cx == @as(i32, bx) and cy == @as(i32, by)) continue; // caller cleared the origin cell
            const cell = resolveCell(coord, cx, cy) orelse continue;
            internalClearBlock(cell.coord, cell.lx, cell.ly);
            if (in_edge_flag_update) {
                flag_worklist.append(alloc, .{ .coord = cell.coord, .bx = cell.lx, .by = cell.ly }) catch memory.oom();
            } else {
                _ = updateLocalEdgeFlags(cell.coord, cell.lx, cell.ly);
            }
        }
    }
}

/// Custom type for edge flag information that stores a `Coordinate` and block within the chunk.
pub const UpdateItem = struct { coord: Coordinate, bx: u4, by: u4 };

/// Max amount of edge flags to check before exiting. If 0, never exits.
const CHECK_LIMIT = 0;
/// Dedicated worklist for local edge flag updating.
/// Not optimized (general-purpose); expects correct adjacent edge flags for reasonable performance,
/// and special anchor types like `suspended` to not create extremely long chains.
pub var flag_worklist: std.ArrayList(UpdateItem) = undefined;

/// Memoized 5x5 block window around one worklist cell, in cell coordinates relative to `coord`
/// (so an entry may live in a neighboring chunk; `get()` resolves that).
///
/// NOTE: The drain mutates blocks as it goes, so every write MUST be mirrored here!
/// This means calling `drop()` after writing a cell's flags, and `reset()` after any block is cleared.
const BlockWindow = struct {
    const SPAN = 5;
    const HALF: i32 = SPAN / 2;

    coord: Coordinate,
    /// Center cell, in `coord`-local block coordinates.
    bx: i32,
    by: i32,
    cells: [SPAN * SPAN]?Block = @splat(null),

    fn init(coord: Coordinate, bx: u4, by: u4) BlockWindow {
        return .{ .coord = coord, .bx = bx, .by = by };
    }

    /// Index of (`cx`, `cy`) within the window, or null when it falls outside the 5x5.
    inline fn indexOf(self: *const BlockWindow, cx: i32, cy: i32) ?usize {
        const wx = cx - self.bx + HALF;
        const wy = cy - self.by + HALF;
        if (wx < 0 or wx >= SPAN or wy < 0 or wy >= SPAN) return null;
        return @intCast(wy * SPAN + wx);
    }

    /// Reads the block at (`cx`, `cy`), which may sit outside `coord` and is then resolved into the neighboring chunk
    /// (clamped to `coord` at the world edge, as the cascade has always done).
    fn get(self: *BlockWindow, cx: i32, cy: i32) Block {
        const slot = self.indexOf(cx, cy);
        if (slot) |i| {
            if (self.cells[i]) |cached| return cached;
        }

        const in_chunk = cx >= 0 and cx < CHUNK_SIZE and cy >= 0 and cy < CHUNK_SIZE;
        const target = if (in_chunk)
            self.coord
        else
            self.coord.move(.{ @divFloor(cx, CHUNK_SIZE), @divFloor(cy, CHUNK_SIZE) }) orelse self.coord;
        const block = getBlockAt(target, @intCast(@mod(cx, CHUNK_SIZE)), @intCast(@mod(cy, CHUNK_SIZE)), memory.game.depth);

        if (slot) |i| self.cells[i] = block;
        return block;
    }

    /// Forgets one cell, after its flags were rewritten.
    inline fn drop(self: *BlockWindow, cx: i32, cy: i32) void {
        if (self.indexOf(cx, cy)) |i| self.cells[i] = null;
    }

    /// Forgets everything, after a clear that may have touched cells beyond this window (an assembly).
    inline fn reset(self: *BlockWindow) void {
        self.cells = @splat(null);
    }
};

/// Recalculates edge flags for a specific block its 8 neighbors.
/// Returns whether the current block was removed due to being in an invalid position.
///
/// NOTE: This function creates an initial lag spike on first call in Debug, but problems vanish in Release and assuming a valid flags state, this function is effectively instant.
fn updateLocalEdgeFlags(coord: Coordinate, bx: u4, by: u4) bool {
    flag_worklist.append(alloc, .{
        .coord = coord,
        .bx = bx,
        .by = by,
    }) catch memory.oom();
    defer flag_worklist.clearRetainingCapacity();

    // Mark the drain active so clearAssemblyRest() (reached from the cascade below) queues onto this worklist instead of re-entering the drain.
    // Nested calls keep it set until the outermost returns.
    const was_updating = in_edge_flag_update;
    in_edge_flag_update = true;
    defer in_edge_flag_update = was_updating;

    var original_block_broken = false;
    var checks_done: usize = 0; // prevent running out of memory
    while (flag_worklist.pop()) |item| {
        if (CHECK_LIMIT != 0 and checks_done >= CHECK_LIMIT) break;
        checks_done += 1;

        var window: BlockWindow = .init(item.coord, item.bx, item.by);

        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const nx = @as(i32, item.bx) + dx;
                const ny = @as(i32, item.by) + dy;

                var target_coord = item.coord;
                if (nx < 0 or nx >= CHUNK_SIZE or ny < 0 or ny >= CHUNK_SIZE) {
                    target_coord = item.coord.move(.{ @divFloor(nx, CHUNK_SIZE), @divFloor(ny, CHUNK_SIZE) }) orelse continue;
                }

                const lbx: u4 = @intCast(@mod(nx, CHUNK_SIZE));
                const lby: u4 = @intCast(@mod(ny, CHUNK_SIZE));
                const block_id = @as(usize, lby) * CHUNK_SIZE + lbx;
                const current_block = window.get(nx, ny);
                const current_sprite = current_block.id;
                if (current_sprite.isLiquid()) {
                    // Defer this water block's edge-flag recompute to the next tick which batches in chunks.
                    // Also register the slot's water so the optimized active-chunk scan picks it up!
                    if (SimBuffer.origin) |og| {
                        const dcx = target_coord.suffix[0] -% og.suffix[0];
                        const dcy = target_coord.suffix[1] -% og.suffix[1];
                        if (dcx < SIM_BUFFER_WIDTH and dcy < SIM_BUFFER_WIDTH) {
                            SimBuffer.has_water.set(SimBuffer.getIndex(@intCast(dcx), @intCast(dcy)));
                            dw.water.queueWaterFlags(@intCast(dcx), @intCast(dcy));
                        }
                    }
                }

                // Cascade: a block whose declared neighbors (`Sprite.supports()`, built from the rule table in types/sprite.zig)
                // are no longer there cannot rest here, so it breaks.
                var broken = false;
                for (current_sprite.supports()) |req| {
                    const neighbor = window.get(nx + req.dx, ny + req.dy).id;
                    const satisfied = switch (req.kind) {
                        .solid => neighbor.isSolid(),
                        .solid_or_self => neighbor.isSolid() or neighbor == current_sprite,
                        .exact => neighbor == req.sprite,
                    };
                    if (!satisfied) {
                        broken = true;
                        break;
                    }
                }

                if (broken) {
                    if (item.bx == bx and item.by == by and item.coord.eql(coord)) original_block_broken = true;
                    // water already drops in modifyBlockHp()
                    if (current_sprite != .water) dw.inventory.dropItem(current_sprite, target_coord, lbx, lby);

                    // Internal block modification to avoid recursion.
                    internalClearBlock(target_coord, lbx, lby);
                    // Multi-tile assemblies break as a unit so an unsupported group never leaves halves.
                    clearAssemblyRest(target_coord, lbx, lby, current_block);
                    window.reset();

                    flag_worklist.append(alloc, .{ // use append() instead of at() to prevent panics
                        .coord = target_coord,
                        .bx = lbx,
                        .by = lby,
                    }) catch memory.oom();
                    continue;
                }

                if (!shouldHaveEdgeFlags(current_sprite) and !current_sprite.isLiquid() and !current_sprite.isWaterloggable()) continue;

                // Recalculate flags for foundation blocks
                var flags: u8 = 0;
                var id_flags: u8 = 0;
                var waterlogged: water.WaterloggedFlags = 0;

                const left_nb = window.get(nx - 1, ny);
                const right_nb = window.get(nx + 1, ny);
                const top_nb = window.get(nx, ny - 1);
                const bottom_nb = window.get(nx, ny + 1);
                const above_left_nb = window.get(nx - 1, ny - 1);
                const above_right_nb = window.get(nx + 1, ny - 1);

                const state = water.getWaterFlags(top_nb, bottom_nb, left_nb, right_nb, above_left_nb, above_right_nb);

                if (!shouldHaveEdgeFlags(current_sprite) and !current_sprite.isLiquid()) {
                    flags = 0xFF;
                    id_flags = 0xFF;
                    if (current_sprite.isWaterloggable()) {
                        waterlogged = state.flags;
                    }
                } else {
                    waterlogged = state.flags;

                    // Recalculate edge flags (same-sprite flags for all foundation blocks; see `addEdgeFlags()`)
                    inline for (.{ -1, 0, 1 }) |ndy| {
                        inline for (.{ -1, 0, 1 }) |ndx| {
                            if (ndx == 0 and ndy == 0) continue;
                            const neighbor_block = window.get(nx + ndx, ny + ndy);

                            const is_solid_or_liquid = neighbor_block.isSolid() or neighbor_block.isLiquid();
                            if ((!current_sprite.isLiquid() and shouldHaveEdgeFlags(neighbor_block.id)) or (current_sprite.isLiquid() and is_solid_or_liquid)) {
                                flags |= types.EdgeFlags.getFlagBit(ndx, ndy);
                            }
                            if (neighbor_block.id == current_sprite) {
                                id_flags |= types.EdgeFlags.getFlagBit(ndx, ndy);
                            }
                        }
                    }
                }

                // Most cells the cascade sweeps are unaffected; skipping the identical rewrite avoids two store lookups.
                if (current_block.edge_flags == flags and
                    current_block.id_edge_flags == id_flags and
                    current_block.waterlogged == waterlogged) continue;
                window.drop(nx, ny);

                // Only the materialized caches are patched: flags are derived state, so `mod_store` does not store them,
                // and `refreshDerivedFlags()` rebuilds them from the replayed ids on the next materialization.
                if (SimBuffer.get(target_coord)) |c| {
                    c.blocks[block_id].edge_flags = flags;
                    c.blocks[block_id].id_edge_flags = id_flags;
                    c.blocks[block_id].waterlogged = waterlogged;
                }
                if (chunk_cache.findIndex(target_coord)) |index| {
                    chunk_cache.chunks[index].blocks[block_id].edge_flags = flags;
                    chunk_cache.chunks[index].blocks[block_id].id_edge_flags = id_flags;
                    chunk_cache.chunks[index].blocks[block_id].waterlogged = waterlogged;
                }
            }
        }
    }

    return original_block_broken;
}

/// Increases a block's `hp` by a specified amount (making it more mined).
/// If the new `hp` becomes larger than 15, the sprite is mined.
/// If `hp_to_add` is 0, the sprite is instantly mined. Returns if the block became/was type `none`.
pub fn modifyBlockHp(coord: Coordinate, bx: u4, by: u4, block: Block, hp_to_add: u4) bool {
    const key = DepthCoordinate.from(coord);
    const id: u8 = @intCast(@as(usize, by) * CHUNK_SIZE + bx);

    const overflow_hp = @addWithOverflow(hp_to_add, block.hp); // overflows past 15, so the block should be deleted
    if (overflow_hp[1] == 1 or hp_to_add == 0 or !block.isSolid()) {
        // The block should be deleted (mined)!
        if (block.isEmpty()) return true;
        for (0..dw.water.getVolume(block)) |_| {
            dw.inventory.dropItem(
                .water,
                coord,
                bx,
                by,
            );
        }

        if (block.isFoundation()) memory.game.blocks_mined +%= 1;
        dw.inventory.dropItem(
            block.id,
            coord,
            bx,
            by,
        );

        mod_store.beginWrite(key).setCell(id, .{ .id = .none, .base_id = .none, .hp = 0 });

        // Update caches so changes appear immediately
        if (SimBuffer.get(coord)) |sim_chunk| clearBlockFields(&sim_chunk.blocks[id]);
        if (chunk_cache.findIndex(coord)) |index| clearBlockFields(&chunk_cache.chunks[index].blocks[id]);

        _ = updateLocalEdgeFlags(coord, bx, by);
        // Removing a block opens space that sleeping (settled) water may now flow into, so wake the surrounding chunks.
        // (without this, water above/beside a freshly mined block stays frozen until something happens.)
        SimBuffer.wake(coord);
        return true;
    } else {
        const new_hp: u4 = overflow_hp[0];
        mod_store.beginWrite(key).setCell(id, .{ .id = block.id, .base_id = block.base_id, .hp = new_hp });

        if (SimBuffer.get(coord)) |sim_chunk| {
            sim_chunk.blocks[id].hp = new_hp;
        }
        if (chunk_cache.findIndex(coord)) |index| {
            chunk_cache.chunks[index].blocks[id].hp = new_hp;
        }
    }
    return false;
}

/// Basic lookup to find a block's `Sprite` type for flag calculation.
/// Checks caches, then modifications, then falls back to procedural logic.
/// Ensures that we do not accidentally read `SimBuffer` data if checking an ancestor depth!
pub fn getBlockAt(coord: Coordinate, lx: u4, ly: u4, depth: u64) Block {
    if (depth == memory.game.depth) { // easy!
        if (SimBuffer.get(coord)) |chunk| return chunk.blocks[(@as(usize, ly) << CHUNK_SIZE_LOG2) | lx];
        if (chunk_cache.findIndex(coord)) |i| {
            return chunk_cache.chunks[i].blocks[(@as(usize, ly) << CHUNK_SIZE_LOG2) | lx];
        }

        const slot_index = chunk_cache.allocateIndex(coord);
        materializeChunk(&chunk_cache.chunks[slot_index], DepthCoordinate.from(coord));
        return chunk_cache.chunks[slot_index].blocks[(@as(usize, ly) << CHUNK_SIZE_LOG2) | lx];
    }

    if (memory.game.depth >= dw.HORIZON_DEPTH) {
        const horizon_depth = memory.game.depth - dw.HORIZON_DEPTH;
        if (depth == horizon_depth) {
            // Evaluates where within the H (D-32) active event horizon query corresponds to, bypassing standard `getInheritedMaterial` calls.
            var center_coord = memory.game.getPlayerCoord().asDepthCoordinate(memory.game.depth);
            var t_bx = memory.game.getBlockXInChunk();
            var t_by = memory.game.getBlockYInChunk();
            while (center_coord.depth > horizon_depth) {
                const p = dw.ancestor.getParentInfo(center_coord, t_bx, t_by);
                center_coord = p.coord.asDepthCoordinate(center_coord.depth - 1);
                t_bx = p.bx;
                t_by = p.by;
            }

            const shift_amt: u7 = if (horizon_depth >= dw.HORIZON_DEPTH) dw.HORIZON_DEPTH * dw.ZOOM_LOG2 else @intCast(horizon_depth * dw.ZOOM_LOG2);

            const p_qx: i128 = coord.quadrant % 2;
            const old_qx: i128 = center_coord.quadrant % 2;
            const abs_chunk_x_p: i128 = (p_qx << shift_amt) | @as(i128, coord.suffix[0]);
            const abs_chunk_x_old: i128 = (old_qx << shift_amt) | @as(i128, center_coord.suffix[0]);
            const diff_chunk_x: i64 = @intCast(std.math.clamp(abs_chunk_x_p - abs_chunk_x_old, -2, 2));

            const p_qy: i128 = coord.quadrant / 2;
            const old_qy: i128 = center_coord.quadrant / 2;
            const abs_chunk_y_p: i128 = (p_qy << shift_amt) | @as(i128, coord.suffix[1]);
            const abs_chunk_y_old: i128 = (old_qy << shift_amt) | @as(i128, center_coord.suffix[1]);
            const diff_chunk_y: i64 = @intCast(std.math.clamp(abs_chunk_y_p - abs_chunk_y_old, -2, 2));

            const diff_block_x = diff_chunk_x * 16 + @as(i64, lx) - @as(i64, t_bx);
            const diff_block_y = diff_chunk_y * 16 + @as(i64, ly) - @as(i64, t_by);

            // Use offset 1 to center queries within the 4x4 fallback buffer
            const x_idx = diff_block_x + 1 + @as(i64, memory.game.player_quadrant % 2);
            const y_idx = diff_block_y + 1 + @as(i64, memory.game.player_quadrant / 2);

            if (x_idx >= 0 and x_idx < 4 and y_idx >= 0 and y_idx < 4) {
                return quad_cache.ancestor_materials[@intCast(y_idx)][@intCast(x_idx)];
            }
            return .empty;
        }
    }

    // not the current depth ):
    // use this function, which also checks ancestor_cache
    return dw.ancestor.getInheritedMaterial(
        coord.asDepthCoordinate(depth),
        lx,
        ly,
    );
}

/// Clears various data-structure caches that can easily be regenerated.
pub fn clearCaches(comptime clear_ancestors: bool) void {
    SimBuffer.clear();
    chunk_cache.clear();
    quad_cache.seed_clock_bits = @splat(0);
    quad_cache.seed_hand = @splat(0);
    quad_cache.seed_cache_keys = @splat(@splat(DepthCoordinate.invalid));

    if (clear_ancestors) dw.ancestor.ancestor_cache.clear();
}

/// Re-initializes all structures allocated in the world arena.
/// Must be called whenever `world.arena` is reset or during init.
///
/// `mod_store` is rebuilt here too, but on `memory.main_allocator` rather than the arena:
/// it frees entries and recycles cell blocks as the player edits, which an arena cannot do.
/// Its `init()` releases the previous world's allocations itself.
pub fn initArenaAllocatedStructures() void {
    flag_worklist = std.ArrayList(UpdateItem).initCapacity(alloc, 256) catch memory.oom();
    mod_store.init(memory.main_allocator);
    quad_cache.reset();
}

/// Increases the game's depth by 1, invalidates caches, moves the player, and handles data modification.
/// `coord` is the chunk the portal is in or where the depth should take place.
/// `bx` and `by` represent the specific block within a chunk the zoom should be in.
pub fn pushLayer(parent_id: Sprite, coord: Coordinate, bx: u4, by: u4) void {
    _ = parent_id;
    clearCaches(true);
    dw.inventory.dropped_items.clear(null);
    memory.game.depth += 1;
    const depth = memory.game.depth;

    const scale_vec: Vec2i = .{ ZOOM_FACTOR, ZOOM_FACTOR }; // per-axis zoom multiplier for player subpixels
    // Magic vertical pivot compensation (384 for factor 4 and block size 256)
    const pivot_y: i64 = (ZOOM_FACTOR - 1) * dw.CHUNK_SIZE_SQ / 2;

    // new_pos: zoomed player position wrapped into one chunk (low bits kept; mask the last 12 bits, 0-4095)
    var new_pos: Vec2i = @mod(memory.game.player_pos * scale_vec, @as(Vec2i, @splat(dw.SUBPIXELS_IN_CHUNK))) + Vec2i{ 0, pivot_y };
    var chunk_offset: Vec2i = .{ 0, 0 }; // extra whole-chunk shift when the pivot pushes past a chunk edge

    // Safely shift the chunk downwards if the vertical pivot overflowed the chunk bounds!
    if (new_pos[1] >= dw.SUBPIXELS_IN_CHUNK) {
        new_pos[1] -= dw.SUBPIXELS_IN_CHUNK;
        chunk_offset[1] = 1;
    }
    memory.game.teleport(null, new_pos); // make sure to teleport!

    if (depth <= HORIZON_DEPTH) {
        // target_coord: child chunk the player lands in. Zooming by 4x shifts the suffix left 2 bits,
        // and the top bits of the block offset (bx, by) fill the freed low suffix bits.
        var target_coord: Coordinate = .{
            .suffix = .{
                (coord.suffix[0] *% ZOOM_FACTOR) | (bx >> (CHUNK_SIZE_LOG2 - dw.ZOOM_LOG2)),
                (coord.suffix[1] *% ZOOM_FACTOR) | (by >> (CHUNK_SIZE_LOG2 - dw.ZOOM_LOG2)),
            },
            .quadrant = @intCast(memory.game.player_quadrant),
        };
        if (chunk_offset[1] != 0) {
            target_coord = target_coord.moveAtDepth(chunk_offset, depth) orelse target_coord;
        }

        memory.game.player_chunk = target_coord.suffix;
        memory.game.player_quadrant = target_coord.quadrant;

        // Max possible suffix is reached at depth 32 (64 bits).
        max_possible_suffix = getMaxSuffixAtDepth(depth);
        return;
    }

    // Rebase case logic (depth > HORIZON_DEPTH)
    const shift = dw.HORIZON_DEPTH * dw.ZOOM_LOG2 - dw.ZOOM_LOG2; // bit position of the suffix's top (post-zoom) cell index (full lane width minus one cell)
    const top_x = coord.suffix[0] >> shift; // which of the ZOOM_FACTOR columns the target sits in
    const top_y = coord.suffix[1] >> shift; // which of the ZOOM_FACTOR rows the target sits in
    const midpoint: u64 = 1 << (shift - 1); // half a cell, used to decide which side of it we lean to
    const is_more_left = (coord.suffix[0] & ((@as(u64, 1) << shift) - 1)) < midpoint; // in the left half of its cell
    const is_more_top = (coord.suffix[1] & ((@as(u64, 1) << shift) - 1)) < midpoint; // in the top half of its cell

    const parent_quadrant_x = utils.intFromBool(u64, (memory.game.player_quadrant % 2) != 0); // parent quadrant's x bit
    const parent_quadrant_y = utils.intFromBool(u64, (memory.game.player_quadrant / 2) != 0); // parent quadrant's y bit
    const naive_cell_x = (parent_quadrant_x * ZOOM_FACTOR) | top_x; // target column in the 2x-wide parent grid
    const naive_cell_y = (parent_quadrant_y * ZOOM_FACTOR) | top_y; // target row in the 2x-wide parent grid

    const highest_possible_top_left_cell = (ZOOM_FACTOR - 1) * 2; // clamp so the 2x2 window stays in bounds
    var left_cell_x: u64 = naive_cell_x -| utils.intFromBool(u64, is_more_left); // left column of the recentered 2x2 window
    var top_cell_y: u64 = naive_cell_y -| utils.intFromBool(u64, is_more_top); // top row of the recentered 2x2 window
    left_cell_x = @min(left_cell_x, highest_possible_top_left_cell);
    top_cell_y = @min(top_cell_y, highest_possible_top_left_cell);

    quad_cache.most_left = quad_cache.most_left and left_cell_x == 0;
    quad_cache.most_right = quad_cache.most_right and left_cell_x == highest_possible_top_left_cell;
    quad_cache.most_top = quad_cache.most_top and top_cell_y == 0;
    quad_cache.most_bottom = quad_cache.most_bottom and top_cell_y == highest_possible_top_left_cell;

    // seeds of the four parent quadrants to reseed from (world seed on the first rebase depth)
    const old_hashes: ChunkSeeds = if (depth == HORIZON_DEPTH + 1) .{ .value = @splat(memory.game.seed) } else quad_cache.path_hashes;

    inline for (0..4) |q_id| {
        const cell_x = left_cell_x + utils.intFromBool(u64, q_id % 2 == 1); // this new quadrant's absolute column
        const cell_y = top_cell_y + utils.intFromBool(u64, q_id >= 2); // this new quadrant's absolute row
        const old_q_id = utils.intFromBool(usize, cell_x >= ZOOM_FACTOR) + utils.intFromBool(usize, cell_y >= ZOOM_FACTOR) * 2; // parent quadrant it descends from
        quad_cache.path_hashes.value[q_id] = seeding.mixCoordinateSeed(
            old_hashes.value[old_q_id],
            @intCast(cell_x % ZOOM_FACTOR),
            @intCast(cell_y % ZOOM_FACTOR),
            depth,
        );
    }

    const path_start_depth = dw.HORIZON_DEPTH + 1; // first depth that records a rebase path entry
    if (depth >= path_start_depth) {
        const path_idx = depth - path_start_depth; // 0-based index of this depth in the path history
        const slot: usize = @intCast(path_idx / 21); // packed-array slot (21 3-bit cells per u64)
        const bit_shift: u6 = @intCast((path_idx % 21) * 3); // bit offset of this cell within its slot
        if (bit_shift == 0) {
            quad_cache.left_path.append(alloc, left_cell_x) catch memory.oom();
            quad_cache.top_path.append(alloc, top_cell_y) catch memory.oom();
        } else {
            quad_cache.left_path.at(slot).* |= (left_cell_x << bit_shift);
            quad_cache.top_path.at(slot).* |= (top_cell_y << bit_shift);
        }

        quad_cache.origins_x[@intCast(depth % QuadCache.HISTORY_LEN)] = @intCast(left_cell_x);
        quad_cache.origins_y[@intCast(depth % QuadCache.HISTORY_LEN)] = @intCast(top_cell_y);
        quad_cache.historical_seeds[@intCast(depth % QuadCache.HISTORY_LEN)] = quad_cache.path_hashes;
    }

    // finalize player state
    const quadrant_x = naive_cell_x - left_cell_x; // target's x position (0/1) inside the recentered window
    const quadrant_y = naive_cell_y - top_cell_y; // target's y position (0/1) inside the recentered window
    var target_coord: Coordinate = .{
        .suffix = .{
            (coord.suffix[0] *% ZOOM_FACTOR) | (bx >> (CHUNK_SIZE_LOG2 - dw.ZOOM_LOG2)),
            (coord.suffix[1] *% ZOOM_FACTOR) | (by >> (CHUNK_SIZE_LOG2 - dw.ZOOM_LOG2)),
        },
        .quadrant = @intCast(quadrant_x + (quadrant_y * 2)),
    };
    if (chunk_offset[1] != 0) {
        target_coord = target_coord.moveAtDepth(chunk_offset, depth) orelse target_coord;
    }

    memory.game.player_chunk = target_coord.suffix;
    memory.game.player_quadrant = target_coord.quadrant;
    max_possible_suffix = std.math.maxInt(u64);

    const target_horizon_depth = depth - dw.HORIZON_DEPTH;
    if (target_horizon_depth >= STARTING_ZOOM_TIMES) {
        var next_materials: [4][4]Block = undefined;

        // Ancestor at H = D - HORIZON_DEPTH. Find the exact block we are located in to summarize the region correctly.
        var trace_coord = target_coord.asDepthCoordinate(depth);
        var t_bx: u4 = @intCast(@divTrunc(new_pos[0], dw.CHUNK_SIZE_SQ));
        var t_by: u4 = @intCast(@divTrunc(new_pos[1], dw.CHUNK_SIZE_SQ));

        var i: u32 = 0;
        while (i < HORIZON_DEPTH) : (i += 1) {
            const p = dw.ancestor.getParentInfo(trace_coord, t_bx, t_by);
            trace_coord = p.coord.asDepthCoordinate(trace_coord.depth - 1);
            t_bx = p.bx;
            t_by = p.by;
        }

        // Temporarily restore the old depth so parent coordinate lookups at depth D-33 (which are below the new horizon but were the active horizon at depth D-1)
        // to correctly resolve quadrant IDs relative to the old threshold D-33, aligning perfectly with quad_cache.ancestor_materials.
        memory.game.depth = depth - 1;
        defer memory.game.depth = depth;

        var old_trace_coord = trace_coord;
        var old_t_bx = t_bx;
        var old_t_by = t_by;
        if (target_horizon_depth > STARTING_ZOOM_TIMES) {
            const pp = dw.ancestor.getParentInfo(trace_coord, t_bx, t_by);
            old_trace_coord = pp.coord.asDepthCoordinate(old_trace_coord.depth - 1);
            old_t_bx = pp.bx;
            old_t_by = pp.by;
        }

        const qx: i32 = @intCast(memory.game.player_quadrant % 2);
        const qy: i32 = @intCast(memory.game.player_quadrant / 2);
        const shift_amt: u7 = if (old_trace_coord.depth >= dw.HORIZON_DEPTH) dw.HORIZON_DEPTH * dw.ZOOM_LOG2 else @intCast(old_trace_coord.depth * dw.ZOOM_LOG2);
        const old_qx = @as(i128, old_trace_coord.quadrant % 2);
        const old_qy = @as(i128, old_trace_coord.quadrant / 2);

        for (0..4) |y_idx| {
            for (0..4) |x_idx| {
                const delta_bx: i32 = @as(i32, @intCast(x_idx)) - 1 - qx;
                const delta_by: i32 = @as(i32, @intCast(y_idx)) - 1 - qy;
                const absolute_bx: i32 = @as(i32, @intCast(t_bx)) + delta_bx;
                const absolute_by: i32 = @as(i32, @intCast(t_by)) + delta_by;
                const chunk_dx = @divFloor(absolute_bx, 16);
                const chunk_dy = @divFloor(absolute_by, 16);
                const local_bx: u4 = @intCast(@mod(absolute_bx, 16));
                const local_by: u4 = @intCast(@mod(absolute_by, 16));

                if (trace_coord.asCoord().moveAtDepth(.{ chunk_dx, chunk_dy }, target_horizon_depth)) |nc| {
                    const child_key = nc.asDepthCoordinate(target_horizon_depth);
                    if (target_horizon_depth == STARTING_ZOOM_TIMES) {
                        next_materials[y_idx][x_idx] = dw.ancestor.getInheritedMaterial(child_key, local_bx, local_by);
                    } else {
                        const p = dw.ancestor.getParentInfo(child_key, local_bx, local_by);
                        const p_qx_128: i128 = p.coord.quadrant % 2;
                        const p_qy_128: i128 = p.coord.quadrant / 2;

                        const abs_chunk_x_p: i128 = (p_qx_128 << shift_amt) | @as(i128, p.coord.suffix[0]);
                        const abs_chunk_x_old: i128 = (old_qx << shift_amt) | @as(i128, old_trace_coord.suffix[0]);
                        const diff_chunk_x: i64 = @intCast(std.math.clamp(abs_chunk_x_p - abs_chunk_x_old, -2, 2));

                        const abs_chunk_y_p: i128 = (p_qy_128 << shift_amt) | @as(i128, p.coord.suffix[1]);
                        const abs_chunk_y_old: i128 = (old_qy << shift_amt) | @as(i128, old_trace_coord.suffix[1]);
                        const diff_chunk_y: i64 = @intCast(std.math.clamp(abs_chunk_y_p - abs_chunk_y_old, -2, 2));

                        var parent_block: Block = .empty;
                        var p_neighbors: [8]Block align(8) = @splat(.empty);

                        const px_idx = diff_chunk_x * 16 + @as(i64, p.bx) - @as(i64, old_t_bx) + 1 + @as(i64, coord.quadrant % 2);
                        const py_idx = diff_chunk_y * 16 + @as(i64, p.by) - @as(i64, old_t_by) + 1 + @as(i64, coord.quadrant / 2);

                        if (px_idx >= 0 and px_idx < 4 and py_idx >= 0 and py_idx < 4) {
                            parent_block = quad_cache.ancestor_materials[@intCast(py_idx)][@intCast(px_idx)];

                            // Populate neighbors for applyAncestorLogic from the current 4x4 ancestor grid
                            var n_idx: usize = 0;
                            var ndy: i32 = -1;
                            while (ndy <= 1) : (ndy += 1) {
                                var ndx: i32 = -1;
                                while (ndx <= 1) : (ndx += 1) {
                                    if (ndx == 0 and ndy == 0) continue;
                                    const nx = px_idx + ndx;
                                    const ny = py_idx + ndy;

                                    if (nx >= 0 and nx < 4 and ny >= 0 and ny < 4) {
                                        p_neighbors[n_idx] = quad_cache.ancestor_materials[@intCast(ny)][@intCast(nx)];
                                    } else {
                                        p_neighbors[n_idx] = .empty;
                                    }
                                    n_idx += 1;
                                }
                            }
                        }

                        // keep tracing the materials back...
                        next_materials[y_idx][x_idx] = dw.ancestor.applyAncestorLogic(
                            parent_block,
                            p_neighbors,
                            child_key,
                            local_bx,
                            local_by,
                        ).compile();
                    }

                    // The traces above are purely procedural, so the player's edit at this exact cell (if any) wins.
                    const block_idx: u8 = @intCast((@as(usize, local_by) << 4) | local_bx);
                    if (mod_store.getCell(child_key, block_idx)) |cell| {
                        cell.applyTo(&next_materials[y_idx][x_idx]);
                    }
                } else next_materials[y_idx][x_idx] = .empty;
            }
        }

        quad_cache.ancestor_materials = next_materials;
    }
}

const testing = std.testing;

/// A distinct `ModCell` per block index, so a misplaced cell is always detectable.
fn testCell(i: u8) ModCell {
    return .{ .id = @enumFromInt(@as(u16, i) + 1), .base_id = @enumFromInt(@as(u16, i) + 300), .hp = i % 16 };
}

test "ModEntry: cells stay indexable by block index regardless of insertion order" {
    mod_store.init(testing.allocator);
    defer mod_store.deinit();

    const key: DepthCoordinate = .{ .suffix = .{ 1, 2 }, .depth = 7, .quadrant = 0 };

    // Insert scrambled (a stride coprime with 256 hits every index exactly once)
    // so every insert lands in the middle of the packed array and exercises the shift.
    var n: u32 = 0;
    while (n < CHUNK_SIZE_SQ) : (n += 1) {
        const i: u8 = @intCast((n *% 97) % CHUNK_SIZE_SQ);
        mod_store.beginWrite(key).setCell(i, testCell(i));

        const entry = mod_store.get(key).?;
        try testing.expectEqual(@as(u16, @intCast(n + 1)), entry.count);
        // `cells` must remain sorted by block index, which is what makes rank() a valid lookup.
        var prev: i32 = -1;
        var seen: u16 = 0;
        for (0..CHUNK_SIZE_SQ) |b| {
            if (!entry.isAuthored(@intCast(b))) continue;
            try testing.expect(@as(i32, @intCast(b)) > prev);
            try testing.expectEqual(entry.cells[seen], entry.get(@intCast(b)).?);
            prev = @intCast(b);
            seen += 1;
        }
        try testing.expectEqual(entry.count, seen);
    }

    const entry = mod_store.get(key).?;
    for (0..CHUNK_SIZE_SQ) |i| {
        try testing.expectEqual(testCell(@intCast(i)), entry.get(@intCast(i)).?);
    }
}

test "ModEntry: unauthored cells read as null and rewrites do not grow the entry" {
    mod_store.init(testing.allocator);
    defer mod_store.deinit();

    const key: DepthCoordinate = .{ .suffix = .{ 0, 0 }, .depth = 6, .quadrant = 3 };
    const authored = [_]u8{ 0, 1, 63, 64, 65, 127, 128, 200, 255 };

    for (authored) |i| mod_store.beginWrite(key).setCell(i, testCell(i));

    const entry = mod_store.get(key).?;
    try testing.expectEqual(@as(u16, authored.len), entry.count);
    for (0..CHUNK_SIZE_SQ) |i| {
        const idx: u8 = @intCast(i);
        const expected = std.mem.indexOfScalar(u8, &authored, idx) != null;
        try testing.expectEqual(expected, entry.get(idx) != null);
    }

    // Overwriting an already-authored cell must replace it, not insert a duplicate.
    mod_store.beginWrite(key).setCell(64, .{ .id = .stone, .base_id = .none, .hp = 3 });
    try testing.expectEqual(@as(u16, authored.len), entry.count);
    try testing.expectEqual(Sprite.stone, entry.get(64).?.id);
}

test "ModEntry: applyTo overwrites exactly the authored cells" {
    mod_store.init(testing.allocator);
    defer mod_store.deinit();

    const key: DepthCoordinate = .{ .suffix = .{ 9, 9 }, .depth = 8, .quadrant = 1 };
    mod_store.beginWrite(key).setCell(5, .{ .id = .none, .base_id = .none, .hp = 0 });
    mod_store.beginWrite(key).setCell(200, .{ .id = .water, .base_id = .none, .hp = 9 });

    var chunk: Chunk = undefined;
    for (&chunk.blocks) |*b| b.* = .makeBasicBlock(.stone, 0xABCD);

    mod_store.get(key).?.applyTo(&chunk);

    for (chunk.blocks, 0..) |b, i| {
        // `seed` is regenerated by the procedural pass, never stored, so replay must leave it untouched.
        try testing.expectEqual(@as(u28, 0xABCD), b.seed);
        switch (i) {
            5 => try testing.expectEqual(Sprite.none, b.id),
            200 => {
                try testing.expectEqual(Sprite.water, b.id);
                try testing.expectEqual(@as(u4, 9), b.hp);
            },
            else => try testing.expectEqual(Sprite.stone, b.id),
        }
    }
}

test "ModificationStore: remove drops the chunk and recycles its slot" {
    mod_store.init(testing.allocator);
    defer mod_store.deinit();

    const a: DepthCoordinate = .{ .suffix = .{ 1, 1 }, .depth = 6, .quadrant = 0 };
    const b: DepthCoordinate = .{ .suffix = .{ 2, 2 }, .depth = 6, .quadrant = 0 };

    mod_store.beginWrite(a).setCell(10, testCell(10));
    try testing.expect(mod_store.contains(a));
    try testing.expectEqual(@as(usize, 1), mod_store.entries.len);

    mod_store.remove(a);
    try testing.expect(!mod_store.contains(a));
    try testing.expectEqual(@as(?ModCell, null), mod_store.getCell(a, 10));

    // The freed slot is handed out again instead of appending, so `entries` does not grow.
    mod_store.beginWrite(b).setCell(20, testCell(20));
    try testing.expectEqual(@as(usize, 1), mod_store.entries.len);
    try testing.expectEqual(testCell(20), mod_store.getCell(b, 20).?);
    try testing.expectEqual(@as(?ModCell, null), mod_store.getCell(b, 10));
}

test "QuadCache: historical seed reads back the depth it was written for" {
    const LEN = QuadCache.HISTORY_LEN;
    // Sit deep enough that a full horizon-wide window of ancestor depths is simultaneously live.
    memory.game.depth = HORIZON_DEPTH * 3;
    defer memory.game.depth = 0;

    // A depth+quadrant marker only in value[0], stamped exactly where pushLayer() writes it.
    var d: u64 = HORIZON_DEPTH + 1;
    while (d <= memory.game.depth) : (d += 1) {
        for (0..4) |q| quad_cache.historical_seeds[@intCast(d % LEN)].value[q].value[0] = d *% 4 + q;
    }

    // Every ancestor strictly inside the live window (H, D) must read back its own marker through the
    // public accessor: proof the read index tracks the write index and no two live depths alias a slot.
    const horizon = memory.game.depth - HORIZON_DEPTH;
    var read_d: u64 = horizon + 1;
    while (read_d < memory.game.depth) : (read_d += 1) {
        for (0..4) |q| {
            const got = quad_cache.getQuadrantSeed(@intCast(q), read_d);
            try testing.expectEqual(read_d *% 4 + q, got.value[0]);
        }
    }
}
