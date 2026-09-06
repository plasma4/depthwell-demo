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

/// Matches `procedural.zig`'s base terrain cache size and sweep pattern; see `BASE_CACHE_TILE_H` there
/// for why the window is 8 chunk rows tall rather than the 2 the edge-flag halo alone would need.
const FOUNDATION_CACHE_TILE_W = SIM_GRID_SIZE;
const FOUNDATION_CACHE_TILE_H = CHUNK_SIZE * 8;
/// Direct-mapped cache of `resolveBaseFoundation()` (a power of two by construction).
const FOUNDATION_CACHE_SLOTS = FOUNDATION_CACHE_TILE_W * FOUNDATION_CACHE_TILE_H;
var foundation_cache: [FOUNDATION_CACHE_SLOTS]FoundationCacheEntry = @splat(.{});
/// Terrain identity the cache holds; a mismatch (reseed or a debug slider) drops every entry.
/// See `procedural.terrainGeneration()`.
var foundation_cache_key: u64 = 0;

comptime {
    // Static WASM memory, like the base terrain cache it mirrors.
    if (@sizeOf(@TypeOf(foundation_cache)) > memory.MemorySizes.MiB)
        @compileError("The base foundation cache exceeds its 1 MiB budget.");
}

/// Direct-mapped slot for a world block. Tiled rather than hashed, so a chunk and the halo around it
/// cannot evict each other at all; see `dw.utils.tileIndex()`.
inline fn foundationCacheIndex(wx: u32, wy: u32) usize {
    return utils.tileIndex(FOUNDATION_CACHE_TILE_W, FOUNDATION_CACHE_TILE_H, wx, wy);
}

/// Resolves the base-depth sprite at absolute chunk (`cx`, `cy`) + local block (`bx`, `by`), memoized.
/// Same as `generateBaseChunk()`: finds world-edge stone, base terrain, ore dispersal (stone only), then structures.
/// Decorations, however, are excluded.
///
/// Both the generator and its base-depth edge-flag halo call this,
/// so a neighbor recomputed for the halo carries the same ore id as the real chunk;
/// `id_edge_flags` then connects a vein to its continuation across the chunk border instead of cutting it off.
fn resolveBaseFoundation(cx: u64, cy: u64, bx: u4, by: u4) BaseFoundation {
    const wx: u32 = @intCast(cx * CHUNK_SIZE + bx);
    const wy: u32 = @intCast(cy * CHUNK_SIZE + by);

    const key = procedural.terrainGeneration();
    if (key != foundation_cache_key) {
        // @memset, not `= @splat(.{})`: an array this large would be built as a stack temporary first.
        @memset(&foundation_cache, .{});
        foundation_cache_key = key;
    }

    const entry = &foundation_cache[foundationCacheIndex(wx, wy)];
    if (entry.occupied and entry.wx == wx and entry.wy == wy) return entry.data;

    const data = computeBaseFoundation(cx, cy, bx, by);
    entry.* = .{ .wx = wx, .wy = wy, .data = data, .occupied = true };
    return data;
}

/// Uncached foundation evaluation.
/// Call `resolveBaseFoundation()` instead outside of the cache itself.
fn computeBaseFoundation(cx: u64, cy: u64, bx: u4, by: u4) BaseFoundation {
    const max_suffix = getMaxSuffixAtDepth(STARTING_ZOOM_TIMES);
    const on_edge_x = (cx == 0 and bx < 2) or (cx == max_suffix and bx >= (CHUNK_SIZE - 2));
    const on_edge_y = (cy == 0 and by < 2) or (cy == max_suffix and by >= (CHUNK_SIZE - 2));
    if (on_edge_x or on_edge_y) return .{ .id = .edge_stone, .base = .none };

    const base_data = procedural.getBaseSpriteType(
        @intCast(cx),
        @intCast(cy),
        bx,
        by,
    );
    const wx: u32 = @intCast(cx * CHUNK_SIZE + bx);
    const wy: u32 = @intCast(cy * CHUNK_SIZE + by);

    var sprite = base_data.sprite;
    if (sprite.isStone()) sprite = procedural.addOresAndGems(
        base_data,
        wx,
        wy,
    );

    const structured = dw.structures.addStructures(
        sprite,
        wx,
        wy,
        memory.getHashSeed(.structures),
    );
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
fn resolveFoundationSolid(cx: u64, cy: u64, bx: u4, by: u4) bool {
    const max_suffix = getMaxSuffixAtDepth(STARTING_ZOOM_TIMES);
    const on_edge_x = (cx == 0 and bx < 2) or (cx == max_suffix and bx >= (CHUNK_SIZE - 2));
    const on_edge_y = (cy == 0 and by < 2) or (cy == max_suffix and by >= (CHUNK_SIZE - 2));
    // edge_stone is solid but NOT a foundation, so a world border never anchors a vine
    if (on_edge_x or on_edge_y) return false;

    const base_sprite = procedural.getBaseSprite(@intCast(cx), @intCast(cy), bx, by);
    const wx: u32 = @intCast(cx * CHUNK_SIZE + bx);
    const wy: u32 = @intCast(cy * CHUNK_SIZE + by);
    const structured = dw.structures.addStructures(base_sprite, wx, wy, memory.getHashSeed(.structures));
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
    addEdgeFlags(chunk, coord.asDepthCoordinate(depth), null);

    // Decorate the base chunk here so that child depths inherit the results.
    // Column features need the state entering each column from the chunk(s) above so their chains cross the border.
    const column_seeds = computeColumnFeatureSeeds(coord.asDepthCoordinate(depth));
    dw.decorations.stampChunk(chunk, cx, cy, &column_seeds);

    resetEmptyEdgeFlags(chunk);
}

/// Computes the entering `ColumnState` per column for every column feature,
/// so each hanging chain crosses the chunk border seamlessly.
/// Feature `i`'s seeds land in slot `i`, matching how `decorations.stampColumns()` indexes them.
fn computeColumnFeatureSeeds(key: DepthCoordinate) [dw.decorations.columns.len][CHUNK_SIZE]dw.decorations.ColumnState {
    var seeds: [dw.decorations.columns.len][CHUNK_SIZE]dw.decorations.ColumnState = undefined;
    inline for (dw.decorations.columns, 0..) |feature, i| {
        seeds[i] = computeColumnSeeds(feature, key);
    }
    return seeds;
}

/// Computes entering `ColumnState` per column for a single `ColumnFeature`
/// by deterministically tracing terrain in the chunk(s) directly along its growth direction.
/// A cell can sit at most `f.max_length` blocks past its anchoring surface,
/// so scanning that many rows captures every surface that could feed a chain into row 0.
/// Terrain beyond is recomputed solidity-only via `resolveFoundationSolid()` (matching how the neighbor chunk generated itself),
/// keeping chains seamless across the border without caching neighbors.
fn computeColumnSeeds(comptime f: dw.decorations.ColumnFeature, key: DepthCoordinate) [CHUNK_SIZE]dw.decorations.ColumnState {
    comptime dw.decorations.validateColumnFeature(f);

    const coord = key.asCoord();
    const depth = key.depth;
    const wx_col_base: u64 = coord.suffix[0] * CHUNK_SIZE;
    var seeds: [CHUNK_SIZE]dw.decorations.ColumnState = @splat(.{});

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

// Everything else in a Block is derived and is rebuilt by materializeChunk(), hence why ModCell is so simple!
// - seed gets regenerated in block-index order (generateBaseChunk(), generateChunk()).
// - the three light channels are written only into the per-frame render scratch buffer (applyLighting()).
// - edge_flags, id_edge_flags, and water are recomputed from neighbor id+hp by the flag passes.

/// One modified cell: the only `Block` fields that cannot be recovered by regenerating the chunk.
/// In other words, only holds the "authoritative" fields within a block that can't be re-derived.
pub const ModCell = extern struct {
    id: Sprite,
    /// The underlay behind an overlay sprite.
    /// Can't be derived because the player can place a solid block,
    /// then replace it with an ore (setting the base ID to the modified block)!
    base_id: Sprite,
    /// Mining progress for solids, water volume for liquids and waterloggable cells. Range 0-15 (`Block.MAX_HP`).
    hp: u8,

    /// Overwrites the authoritative fields of a block, leaving derived fields for flag passes.
    pub inline fn applyTo(self: @This(), block: *Block) void {
        block.id = self.id;
        block.base_id = self.base_id;
        block.hp = @intCast(self.hp);
    }

    /// Captures the authoritative fields of a materialized `Block`.
    pub inline fn from(block: Block) @This() {
        return .{ .id = block.id, .base_id = block.base_id, .hp = block.hp };
    }
};

/// Words in a `ModEntry.modified` bitmap (one bit per block in a chunk).
const MODIFIED_WORDS = CHUNK_SIZE_SQ / 64;
/// Capacity of a `ModEntry.cells` allocation on first write; doubles from there up to `CHUNK_SIZE_SQ`.
const MIN_MOD_CELLS = 8;

/// The modifications to a single chunk, as a sparse set of modified cells rather than a full `Chunk`.
/// Should ONLY be mutated through `ModificationStore.beginWrite()`: for saving functionality.
pub const ModEntry = struct {
    /// Cells whose value came from a player edit or water simulation rather than from procedural generation.
    /// Bit `i` (block index `by * CHUNK_SIZE + bx`) set means `cells[rank(i)]` holds that cell's value.
    ///
    /// NOTE: intentional simplistic choice to not use `StaticBitSet`:
    /// `u64` consistency+rank() access just make it not worth
    modified: [MODIFIED_WORDS]u64 = @splat(0),
    /// Modified cells in ascending block-index order. The first `count` are live; the rest is spare capacity.
    cells: []ModCell = &.{},
    /// Live entries in `cells`. Always equals the population count of `modified`.
    count: u16 = 0,

    /// Number of modified cells below block index `i`, which is `i`'s position within `cells`.
    inline fn rank(self: *const @This(), i: u8) u16 {
        const word: usize = i >> 6;
        const bit: u6 = @truncate(i);
        var total: u16 = 0;
        for (self.modified[0..word]) |w| total += @popCount(w);
        const below: u64 = (@as(u64, 1) << bit) -% 1;
        return total + @popCount(self.modified[word] & below);
    }

    /// Whether block index `i` carries an modified value (as opposed to its procedural one).
    pub inline fn isModified(self: *const @This(), i: u8) bool {
        return (self.modified[i >> 6] >> @as(u6, @truncate(i))) & 1 != 0;
    }

    /// Whether this entry says anything at all.
    pub fn anySet(self: *const @This()) bool {
        for (self.modified) |m| {
            if (m != 0) return true;
        }
        return false;
    }

    /// The modified value at block index `i`, or null if that cell is still procedural.
    pub inline fn get(self: *const @This(), i: u8) ?ModCell {
        if (!self.isModified(i)) return null;
        return self.cells[self.rank(i)];
    }

    /// Replays every modified cell over a freshly generated chunk.
    /// The caller MUST then rerun the flag pass: replaying ids invalidates the generated edge and water flags.
    ///
    /// A replayed cell also takes a FRESH `Block.seed` from `seedLane()`.
    /// `ModCell` does not store a seed, so a cell keeps whatever the generator left there,
    /// and an empty cell is left with a seed of zero at every recursive depth
    /// (`ancestor.applyAncestorLogic()` returns early for air).
    /// Without this, every block the player builds into open space picks the same
    /// seed-driven variant (see `variation.seedPick()`).
    pub fn applyTo(self: *const @This(), chunk: *Chunk, key: DepthCoordinate) void {
        const lane = seedLane(key);
        var i: usize = 0;
        for (0..MODIFIED_WORDS) |w| {
            var bits = self.modified[w];
            while (bits != 0) : (i += 1) {
                const bit = @ctz(bits);
                bits &= bits - 1;
                const index = (w << 6) | bit;
                const block = &chunk.blocks[index];
                self.cells[i].applyTo(block);
                block.seed = @truncate(seeding.FastHash.hash2d(
                    lane,
                    index & (CHUNK_SIZE - 1),
                    index >> CHUNK_SIZE_LOG2,
                ));
            }
        }
    }

    /// Writes `cell` at block index `i`, marking it modified. File-private: reach it via `ModWriter.setCell()`.
    fn setCellRaw(self: *@This(), i: u8, cell: ModCell) void {
        const at = self.rank(i);
        if (self.isModified(i)) {
            self.cells[at] = cell;
            return;
        }

        if (self.count == self.cells.len) {
            std.debug.assert(self.count < CHUNK_SIZE_SQ); // a chunk cannot author more cells than it has
            // loadEntry() allocates exact-size capacities, so doubling must clamp: a save-loaded
            // entry can otherwise double past CHUNK_SIZE_SQ while unmodified cells remain.
            const new_cap = @min(@max(self.cells.len * 2, MIN_MOD_CELLS), CHUNK_SIZE_SQ);
            self.cells = mod_store.allocator.realloc(self.cells, new_cap) catch memory.oom();
        }

        // Keep cells in ascending block-index order so rank() indexes right!
        std.mem.copyBackwards(
            ModCell,
            self.cells[at + 1 .. self.count + 1],
            self.cells[at..self.count],
        );
        self.cells[at] = cell;
        self.modified[i >> 6] |= @as(u64, 1) << @truncate(i);
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
        self.* = .{
            .allocator = allocator,
            .live = true,
            .generation = self.generation +% 1,
        };
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

    /// The modified value at one block of one chunk, or null if that cell is still procedural.
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
        const entry: *ModEntry = self.entries.at(kv.value);
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
    /// This is the ONLY correct way to mutate the store!
    /// This preserves the entry's pre-edit contents for an in-flight budgeted save before handing back a writer.
    pub fn beginWrite(self: *@This(), key: DepthCoordinate) ModWriter {
        // sanity: not in animation, not in impossible depth
        std.debug.assert(!dw.portal.isActive());
        std.debug.assert(key.depth <= frontier());
        return .{
            .entry = self.entries.at(self.reserve(key, .edit)),
            .key = key,
            // shallower than the frontier this depth is frozen for its descendants,
            // so each cell must give up its inherited value before the edit lands.
            .capture_legacy = self == &mod_store and key.depth < frontier(),
        };
    }

    /// `beginWrite()` without the legacy capture or the transition guards.
    /// Only `captureLegacy()` and the save loader may use this.
    fn beginWriteRaw(self: *@This(), key: DepthCoordinate) ModWriter {
        return .{ .entry = self.entries.at(self.reserve(key, .edit)), .key = key };
    }

    /// Why an entry is being opened, for `TRACE_NEW_ENTRIES`. The store itself does not care.
    const WriteKind = enum { edit };

    /// Logs every chunk that becomes modified for the first time, and what opened it.
    /// Debug builds only.
    const TRACE_NEW_ENTRIES = false;

    /// `entries` index for `key`, creating the entry if new, with any in-flight save's copy preserved.
    fn reserve(self: *@This(), key: DepthCoordinate, comptime kind: WriteKind) usize {
        const idx = self.index.get(key) orelse blk: {
            const new_idx = self.allocEntry();
            self.index.put(self.allocator, key, new_idx) catch memory.oom();
            if (dw.dev_menu and TRACE_NEW_ENTRIES) dw.logger.info(
                @src(),
                "new ChunkMod ({s}) at depth {d}, quadrant {d}, suffix {d}/{d}",
                .{ @tagName(kind), key.depth, key.quadrant, key.suffix[0], key.suffix[1] },
            );
            break :blk new_idx;
        };
        dw.save.shadowEntryForSave(self == &legacy_store, idx);
        return idx;
    }

    /// Rebuilds an entry straight from a save, bypassing the copy-on-write shadow (nothing can be mid-save during a load).
    /// `cells` must be in ascending block-index order and match `modified`.
    pub fn loadEntry(
        self: *@This(),
        key: DepthCoordinate,
        modified: [MODIFIED_WORDS]u64,
        cells: []const ModCell,
    ) !void {
        const idx = self.allocEntry();
        const entry: *ModEntry = self.entries.at(idx);
        entry.modified = modified;
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

/// A "permit" to mutate one `ModEntry`, obtained from `ModificationStore.beginWrite()`.
/// Its existence proves the entry was already shadowed for any in-flight save.
pub const ModWriter = struct {
    // (abstractions and types do be cool like this sometimes)
    entry: *ModEntry,
    /// The chunk being written, which `captureLegacy()` needs to resolve the cell being replaced.
    key: DepthCoordinate,
    /// Whether each cell must be frozen into `legacy_store` before the edit lands.
    capture_legacy: bool = false,

    /// Marks block `i` as modified and stores its value.
    pub inline fn setCell(self: ModWriter, i: u8, cell: ModCell) void {
        if (self.capture_legacy) captureLegacy(self.key, i);
        self.entry.setCellRaw(i, cell);
    }

    /// Captures a materialized block's authoritative fields as block `i`'s modified value.
    pub inline fn setBlock(self: ModWriter, i: u8, block: Block) void {
        if (self.capture_legacy) captureLegacy(self.key, i);
        self.entry.setCellRaw(i, .from(block));
    }
};

/// Stores and handles modifications of chunks across various depths.
/// Initialized in `main()`.
pub var mod_store: ModificationStore = .{};

/// The material each cell had when its depth stopped being the frontier.
///
/// A cell can need two values at once:
/// the one the deeper depths inherited, and the one its own depth shows now.
/// `mod_store` holds the second; this holds the first.
/// A cell enters here on its FIRST edit shallower than the frontier, and is never written again.
///
/// Only ancestor lookups read this (see `inheritedCell()`).
/// It is invisible to the depth it belongs to, which is what makes each depth its own world.
pub var legacy_store: ModificationStore = .{};

/// One rebuilt chunk, so a run of captures inside the same chunk pays for one materialization.
/// Only ever read for cells `mod_store` says nothing about, so the edits it replays are irrelevant
/// and the only thing that can retire it is the terrain itself changing (see `clearLegacyScratch()`).
var legacy_scratch: Chunk align(memory.MAIN_ALIGN_BYTES) = undefined;
var legacy_scratch_key: DepthCoordinate = DepthCoordinate.invalid;

/// Drops the `captureLegacy()` scratch. Called by `clearCaches()`, since a depth change or a reseed
/// leaves the same key naming different terrain.
fn clearLegacyScratch() void {
    legacy_scratch_key = DepthCoordinate.invalid;
}

/// Freezes block `i` of `key` into `legacy_store`, if it is not frozen already.
///
/// The captured value is the cell as of the last moment its depth was the frontier:
/// its `mod_store` value when it has one, and its procedural value when it does not.
///
/// Neither of those is read from the RESIDENT chunk, and that is the whole point.
/// Every hand edit writes the store before it touches the chunk, so the two agree there,
/// but the water simulation moves volume through the resident chunks for a whole tick and persists
/// the cells it moved only afterwards. By then the chunk holds this tick's move, and freezing from it
/// would send one tick of water down to depths that were formed before the water ever got there.
fn captureLegacy(key: DepthCoordinate, i: u8) void {
    if (legacy_store.get(key)) |e| {
        if (e.isModified(i)) return; // frozen already, and a frozen cell never changes
    }
    if (mod_store.getCell(key, i)) |cell| {
        legacy_store.beginWriteRaw(key).setCell(i, cell);
        return;
    }
    if (!(legacy_scratch_key.depth != 0 and legacy_scratch_key.eql(key))) {
        materializeChunk(&legacy_scratch, key);
        legacy_scratch_key = key;
    }
    legacy_store.beginWriteRaw(key).setCell(i, .from(legacy_scratch.blocks[i]));
}

/// The value one cell contributes to the DEEPER depths, or null when it is still procedural.
///
/// The one lookup every ancestor path must use, so the two call sites cannot drift.
/// A frozen value wins over the live one.
/// An edit made after the depth was left is local to that depth.
/// It must not travel deeper.
pub inline fn inheritedCell(key: DepthCoordinate, block_idx: u8) ?ModCell {
    // Almost every session never edits shallower than the frontier, so this keeps the store off the hot path.
    if (legacy_store.index.count() != 0) {
        if (legacy_store.getCell(key, block_idx)) |cell| return cell;
    }
    return mod_store.getCell(key, block_idx);
}

/// One depth the player has ascended past, recording the block they ascended through.
///
/// A descent derives its whole rebase frame from the block it descends into (see `computeLayer()`).
/// Descending anywhere else would renumber every suffix at that depth,
/// which orphans every deeper `mod_store` key.
/// Keeping the block means the way deeper is the way you came.
pub const AscentStep = struct {
    /// The chunk at the DEEPER depth to come back to, and where in it the player stood.
    ///
    /// Recorded rather than recomputed on purpose.
    /// The depth's rebase origins were fixed by the descent that first reached it.
    /// Re-deriving them from wherever the player has since wandered can land on different ones.
    /// `computeRetraceLayer()` reads the recorded frame back,
    /// exactly as `computeParentLayer()` does going the other way.
    suffix: Vec2u,
    quadrant: u2,
    /// Subpixels within `suffix`'s chunk: the stand position on the portal block itself.
    /// A return puts the player back on the portal they went up through, at both ends of the move.
    origin_pos: Vec2i,

    pub inline fn coord(self: @This()) Coordinate {
        return .{ .suffix = self.suffix, .quadrant = self.quadrant };
    }
};

/// Depths the player has ascended past, deepest last. Empty at the deepest depth ever visited.
/// Lives on `main_allocator` because it can be pushed or popped.
pub var ascent_stack: std.ArrayList(AscentStep) = .empty;

/// Whether a recorded ascent step is available to descend back through.
///
/// This is the ONLY descent while shallower than the frontier.
/// A fresh descent frame would renumber every suffix below and orphan its `mod_store` keys
/// (see `AscentStep`).
pub inline fn canRetrace() bool {
    return ascent_stack.items.len != 0;
}

/// The deepest depth the player has reached: the FRONTIER.
///
/// Floored at the current depth, which can never be deeper than the deepest one reached.
/// Read this rather than `max_depth_reached` directly:
/// the floor holds the invariant even when the depth is set without a `commitLayer()`.
pub inline fn frontier() u64 {
    return @max(memory.game.max_depth_reached, memory.game.depth);
}

/// Whether the current depth is shallower than the frontier, so its edits stay local to it.
///
/// The player has already descended past this depth,
/// so the deeper depths hold the material they inherited at that moment.
/// See `legacy_store` for how that material is kept.
pub inline fn isShallowerThanFrontier() bool {
    return memory.game.depth < frontier();
}

/// The deepest depth the player has reached.
/// Retrace is the only descent from shallower than the frontier, so this also equals
/// `game.depth + ascent_stack.items.len` during play.
pub inline fn deepestDepth() u64 {
    return frontier();
}

/// Whether there is a shallower depth to ascend into.
pub inline fn canAscend() bool {
    return memory.game.depth > STARTING_ZOOM_TIMES;
}

/// The step a descent must retrace, or null when the player is already at their deepest depth.
pub inline fn retraceStep() ?AscentStep {
    return if (canRetrace()) ascent_stack.items[ascent_stack.items.len - 1] else null;
}

/// Drops the top ascent step, once the descent that retraced it has committed.
pub fn popAscentStep() void {
    std.debug.assert(canRetrace());
    _ = ascent_stack.pop();
}

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
    pub fn moveAtDepth(self: @This(), shift: Vec2i, depth: u64) ?Coordinate {
        const dx = shift[0];
        const dy = shift[1];
        if (dx == 0 and dy == 0) return self;
        var res = self;

        // X axis
        if (dx != 0) {
            const is_pos = dx > 0;
            const delta: u64 = if (is_pos) @intCast(dx) else @intCast(-%dx);
            const ov = if (is_pos) @addWithOverflow(res.suffix[0], delta) else @subWithOverflow(res.suffix[0], delta);
            if (ov[1] != 0) {
                // world-edge :(
                if (depth < HORIZON_DEPTH) return null;
                if (is_pos == ((res.quadrant & 1) != 0)) return null;
                res.quadrant ^= 1;
            }

            if (is_pos and depth < HORIZON_DEPTH and ov[0] > getMaxSuffixAtDepth(depth)) return null;
            res.suffix[0] = ov[0];
        }

        // Y axis
        if (dy != 0) {
            const is_pos = dy > 0;
            const delta: u64 = if (is_pos) @intCast(dy) else @intCast(-%dy);
            const ov = if (is_pos) @addWithOverflow(res.suffix[1], delta) else @subWithOverflow(res.suffix[1], delta);
            if (ov[1] != 0) {
                if (depth < HORIZON_DEPTH) return null;
                // world-edge :(
                if (is_pos == ((res.quadrant & 2) != 0)) return null;
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
    pub fn hash(self: @This()) u64 {
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
    pub fn getParent(self: @This()) @This() {
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

/// A combined pool of `SimBuffer` and `ChunkCache` data.
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
        @memset(&keys, null);
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
    pub fn clear() void {
        @memset(&keys, null);
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
    ///   a terrain bit is set toward a foundation neighbor, and a liquid bit is set toward a solid-or-liquid neighbor.
    /// - Air is ignored.
    ///
    /// Blocks whose 8 neighbors are not all resident in the loaded window are skipped, since their
    /// flags were derived from cache/procedural data this side-effect-free scan cannot reproduce.
    /// O(loaded_chunks * 256 * 8); performs no allocation. Intended for debug assertions/tests.
    /// Mismatches `validateAgainstMaterialization()` reports before it gives up, so one badly diverged
    /// chunk cannot flood the console with 256 lines.
    const MAX_DIVERGENCE_REPORTS = 24;

    /// Checks the invariant that makes eviction safe: a resident chunk must equal what
    /// `materializeChunk()` would rebuild for the same coordinate.
    ///
    /// This is what lets a chunk leave the window and come back unchanged. Everything the simulation
    /// does has to reach `mod_store`, because the live copy is discarded the moment the window scrolls
    /// past it and `writeChunkSimless()` rebuilds it from generation plus modifications. A cell that
    /// diverges here is one the sim moved without recording, and it will visibly revert (then be redone,
    /// then revert) as the chunk cycles in and out of the buffer.
    ///
    /// Compares only the authoritative fields a `ModCell` carries; light and edge flags are derived per
    /// frame and are expected to differ.
    pub fn validateAgainstMaterialization() bool {
        var scratch: Chunk = undefined;
        var reports: usize = 0;

        for (keys, 0..) |maybe_key, slot| {
            const coord = maybe_key orelse continue;
            materializeChunk(&scratch, coord.asDepthCoordinate(memory.game.depth));

            for (0..CHUNK_SIZE_SQ) |i| {
                const live = sim_buffer_ptr[slot].blocks[i];
                const rebuilt = scratch.blocks[i];
                if (live.id == rebuilt.id and live.hp == rebuilt.hp and live.base_id == rebuilt.base_id) continue;

                if (reports >= MAX_DIVERGENCE_REPORTS) return false;
                reports += 1;
                dw.logger.err(
                    @src(),
                    "SimBuffer diverges from materialization at chunk ({d},{d}) q{d} block ({d},{d}): live {s} hp={d} / rebuilt {s} hp={d}",
                    .{
                        coord.suffix[0],      coord.suffix[1],
                        coord.quadrant,       i & (CHUNK_SIZE - 1),
                        i >> CHUNK_SIZE_LOG2, @tagName(live.id),
                        live.hp,              @tagName(rebuilt.id),
                        rebuilt.hp,
                    },
                );
            }
        }
        return reports == 0;
    }

    pub fn validateSimBuffer() bool {
        var all_valid = true;
        for (keys, 0..) |maybe_key, slot| {
            const coord = maybe_key orelse continue;
            const chunk = &sim_buffer_ptr[slot];
            for (0..CHUNK_SIZE) |by| {
                for (0..CHUNK_SIZE) |bx| {
                    const block = chunk.blocks[(by << CHUNK_SIZE_LOG2) | bx];
                    // Air is the one cell that legitimately carries no world sprite, so it is skipped
                    // BEFORE the test rather than reported by it.
                    if (block.isEmpty()) continue;
                    if (!block.isInWorld()) {
                        dw.logger.err(@src(), "Not-in-world sprite type found: {s}", .{@tagName(block.id)});
                        all_valid = false;
                    }

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
        if (!dw.dev_menu) return;
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

    /// Where the window belongs for a player standing in `coord`: centered on them,
    /// then pulled back inside the world by `getClampedMove()`.
    ///
    /// A player at a world edge (or any player at all, once the world is narrower than the window)
    /// keeps asking for the same clamped origin no matter how far they walk,
    /// which is what lets `sync()` recognize that there is nothing to do.
    fn desiredOrigin(coord: Coordinate) Coordinate {
        const half_width = @as(i64, SIM_BUFFER_WIDTH) / 2;
        return getClampedMove(coord, -half_width, -half_width);
    }

    /// Synchronizes the buffer to center on the provided coordinate, sliding the window when it can
    /// and rebuilding it only when the two origins are too far apart to share any chunk.
    ///
    /// Derived from `coord` alone rather than from how far the player moved:
    /// a step the world edge refuses moves the player without moving the window,
    /// and rebuilding on every one of those regenerates the whole window for nothing
    /// (the pathological case being a world smaller than the window, where the origin never moves at all).
    pub fn sync(coord: Coordinate) void {
        const target = desiredOrigin(coord);
        const og = origin orelse {
            fullRefresh(target);
            return;
        };
        if (og.eql(target)) return;

        // Wrapping subtraction, so a suffix that crossed a quadrant still reads as the small delta it is.
        // `moveAtDepth()` below is what actually proves the delta: it must land exactly on `target`
        // without clamping, which is `incrementalRefresh()`'s precondition.
        const dx: i64 = @bitCast(target.suffix[0] -% og.suffix[0]);
        const dy: i64 = @bitCast(target.suffix[1] -% og.suffix[1]);
        if (@abs(dx) < SIM_BUFFER_WIDTH and @abs(dy) < SIM_BUFFER_WIDTH) {
            if (og.moveAtDepth(.{ dx, dy }, memory.game.depth)) |moved| {
                if (moved.eql(target)) {
                    incrementalRefresh(dx, dy);
                    return;
                }
            }
        }

        // Teleport or large jump fallback
        fullRefresh(target);
    }

    /// Completely invalidates the current buffer state and rebuilds it from scratch centered around a brand-new origin.
    /// Typically triggered upon world initialization, player teleportation, or high-velocity threshold jumps.
    fn fullRefresh(new_origin: Coordinate) void {
        openWindowAt(new_origin);
        fillMissing();
    }

    /// Points the window at `new_origin` and empties every slot WITHOUT generating anything.
    pub fn openWindowAt(new_origin: Coordinate) void {
        origin = new_origin;
        ring_x = 0;
        ring_y = 0;
        @memset(&keys, null);
        has_water = std.StaticBitSet(SIM_BUFFER_SIZE).initEmpty();
        water_settled = std.StaticBitSet(SIM_BUFFER_SIZE).initEmpty();
    }

    /// Adopts a ready-made chunk, if `coord` lands inside the open window. Returns whether it was taken.
    /// Precondition: `chunk` must be materialized (generation plus any modifications),
    /// exactly as `writeChunkSimless()` would have produced it.
    pub fn install(coord: Coordinate, chunk: *const Chunk) bool {
        const og = origin orelse return false;
        const dx = coord.suffix[0] -% og.suffix[0];
        const dy = coord.suffix[1] -% og.suffix[1];
        if ((dx | dy) >= SIM_BUFFER_WIDTH) return false;
        if (og.moveAtDepth(.{ @intCast(dx), @intCast(dy) }, memory.game.depth)) |expected| {
            if (!expected.eql(coord)) return false;
        } else return false;

        const id = getIndex(@intCast(dx), @intCast(dy));
        keys[id] = coord;
        sim_buffer_ptr[id] = chunk.*;
        has_water.setValue(id, chunkHasWater(&sim_buffer_ptr[id]));
        water_settled.unset(id); // a freshly loaded chunk must settle at least once
        return true;
    }

    /// Rebuilds the window around `center`, adopting every chunk `source` can supply and generating only the rest.
    /// `source` should be a struct and simply have a `get(c: Coordinate) ?*const Chunk` method.
    pub fn refreshAdopting(center: Coordinate, source: anytype) void {
        const half_width = @as(i64, SIM_BUFFER_WIDTH) / 2;
        openWindowAt(getClampedMove(center, -half_width, -half_width));
        const og = origin orelse return;

        for (0..SIM_BUFFER_WIDTH) |cy| {
            for (0..SIM_BUFFER_WIDTH) |cx| {
                const cell = og.move(.{ @intCast(cx), @intCast(cy) }) orelse continue;
                if (source.get(cell)) |chunk| _ = install(cell, chunk);
            }
        }
        fillMissing();
    }

    /// Generates every slot still empty in the open window. A no-op for slots already `install()`ed.
    pub fn fillMissing() void {
        const og = origin orelse return;
        for (0..SIM_BUFFER_WIDTH) |cy| {
            for (0..SIM_BUFFER_WIDTH) |cx| {
                const id = getIndex(@intCast(cx), @intCast(cy));
                if (keys[id] != null) continue;
                if (og.move(.{ @intCast(cx), @intCast(cy) })) |cell_coord| {
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
    /// Precondition: `origin.move(.{dx, dy})` must not clamp (caller `sync()` guarantees this).
    /// Ring X/Y advance by the full `dx`/`dy` here, so a clamped origin move would desync them from the origin.
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
    /// Fills slots with `materializeChunk()`, never bare `generateChunk()`:
    /// every consumer of `chunk_cache` (`writeChunkSimless()`, `getCachedChunk()`, `getBlockAt()`)
    /// treats a hit as post-modification data, so a purely procedural slot silently reverts
    /// the player's edits for as long as it survives eviction.
    ///
    /// - Generates at least `default_amount` chunks when called.
    /// - A higher `max_amount` can help during high-movement situations
    ///   (suggested value of ~2, so more budget is available in high-velocity falling situations).
    ///
    /// Finding the terminal velocity can help: every chunk moved diagonally means up to 33 chunks need to be regenerated near the edge.
    /// At a worst-case terminal fall around 30 blocks/sec and assuming a similar horizontal move speed (for worst-case chunk stradding),
    /// that's two blocks per frame for each axis and "1/4th chunk" per frame needs to be generated.
    /// Considering all this, a maximum of 1 chunk is needed to be precached per frame,
    /// at least so that amortized gradual chunk generation around the `SimBuffer` doesn't result in frame drops/
    pub inline fn precacheChunks(
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
                    _ = chunk_cache.fill(c);
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
                    _ = chunk_cache.fill(c);
                    generated_count += 1;
                }
            }
        }
    }
};

/// Returns a pointer to a block in the active 256x256 SimBuffer grid.
/// Treat out of bounds or inactive chunks as solid.
pub fn getSimBlockPtr(x: i32, y: i32) ?*Block {
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

/// Widest render window, in chunks, that the camera can ask for.
///
/// The window is the visible chunk grid at the most zoomed-out camera scale (`CAMERA_MIN_ZOOM`),
/// plus the border `rasterizeLayer()` adds: `CHUNK_MARGIN` chunks each side for light bleed,
/// plus 1 for the floor-alignment straddle.
/// This must track `lighting.CHUNK_MARGIN`, so widening the light range grows the cache.
///
/// A portal ASCENT is the one thing that reaches past this. `portal.zoomFactor()` pulls the live layer
/// out until `portal.coverCurve()` hides it, which caps that layer's window at
/// `(ZOOM_FACTOR / OVERLAY_ZOOM)^2` (about 7) times the area here.
const CHUNK_WINDOW = blk: {
    const W: f64 = @floatFromInt(dw.SCREEN_WIDTH);
    const H: f64 = @floatFromInt(dw.SCREEN_HEIGHT);
    const Z: f64 = player.CAMERA_ZOOM_MIN;

    const margin: f64 = @floatFromInt(dw.lighting.CHUNK_MARGIN);
    const border = 2.0 * margin + 1.0;

    // The 2 extra chunks an axis are for the readers that probe just outside the window:
    // precacheChunks(), the mining light grid, and the collision scan.
    break :blk .{
        .w = @as(usize, @intFromFloat(@ceil(W / (256.0 * Z)) + border + 2.0)),
        .h = @as(usize, @intFromFloat(@ceil(H / (256.0 * Z)) + border + 2.0)),
    };
};

/// Tile the cache wraps a chunk coordinate into, in chunks. Powers of two, and each axis is at least
/// as wide as `CHUNK_WINDOW`, which is what makes the whole window collision-free.
const CHUNK_CACHE_TILE_W = std.math.ceilPowerOfTwoAssert(usize, CHUNK_WINDOW.w);
const CHUNK_CACHE_TILE_H = std.math.ceilPowerOfTwoAssert(usize, CHUNK_WINDOW.h);
/// Slot count of the direct-mapped chunk cache (a power of two by construction).
const CHUNK_CACHE_SIZE: usize = CHUNK_CACHE_TILE_W * CHUNK_CACHE_TILE_H;

comptime {
    // The window must FIT the tile on both axes, or two visible chunks share a slot and each one
    // evicts the other every frame; see the `ChunkCache` header.
    if (CHUNK_CACHE_TILE_W < CHUNK_WINDOW.w or CHUNK_CACHE_TILE_H < CHUNK_WINDOW.h)
        @compileError("The chunk cache tile must cover the widest render window on both axes.");
}

/// A static cache holding every chunk the renderer touches that the `SimBuffer` does not own.
///
/// DIRECT-MAPPED AND TILED, not hashed: the slot IS the chunk position, wrapped into a
/// `CHUNK_CACHE_TILE_W` x `CHUNK_CACHE_TILE_H` tile (see `dw.utils.tileIndex()`).
/// Two chunks share a slot only when they sit a whole tile apart on an axis, and the tile is wider than
/// the widest window, so no two chunks that are visible at the same time can ever collide.
///
/// This layout is not an optimization, it is the only one that works here.
/// The renderer rescans the SAME rectangle in the SAME order every frame. Against a hashed
/// set-associative cache, that is the pattern that defeats a clock or LRU policy outright:
/// total capacity says nothing, because any set that happens to draw 5 window chunks for its 4 ways
/// misses on EVERY access forever, and a chunk miss is a full `materializeChunk()`.
/// Doubling capacity only makes such a set rarer; a tile removes it.
pub const ChunkCache = struct {
    /// Coordinate resident in each slot, indexed by `slotOf()`.
    ///
    /// NOTE: `@splat()` is for the DEFAULT only, where it is a comptime value. Clearing at runtime goes
    /// through `@memset()` instead (see `clear()`): assigning a whole array this size builds the value in
    /// the stack frame and copies it, which is both code waste and most of the frame in Debug.
    keys: [CHUNK_CACHE_SIZE]?Coordinate = @splat(null),
    /// Chunks referenced by `keys` at the current depth.
    chunks: *[CHUNK_CACHE_SIZE]Chunk = chunk_pool[0..CHUNK_CACHE_SIZE],

    /// The one slot a `Coordinate` can ever occupy.
    ///
    /// The quadrant is deliberately NOT mixed in. Past the horizon the quadrant bit is the coordinate's
    /// top bit, and below it a quadrant is `max_suffix + 1` chunks wide, which is a multiple of the tile
    /// on both axes. So the low bits run continuously across a quadrant edge either way,
    /// and two chunks that neighbor each other across one land in neighboring slots.
    inline fn slotOf(coord: Coordinate) usize {
        return utils.tileIndex(CHUNK_CACHE_TILE_W, CHUNK_CACHE_TILE_H, coord.suffix[0], coord.suffix[1]);
    }

    /// Finds the index of a `Coordinate` in the cache.
    /// Returns null if non-existent.
    pub fn findIndex(self: *@This(), coord: Coordinate) ?usize {
        const slot = slotOf(coord);
        if (self.keys[slot]) |k| {
            if (k.eql(coord)) return slot;
        }
        return null;
    }

    /// Materializes `coord` into the slot it maps to, evicting whatever held it, and returns the index.
    ///
    /// The key is claimed AFTER the chunk is built, which is the same order every other cache here writes
    /// in and is load-bearing rather than stylistic. The cache is direct-mapped, so a nested fill of any
    /// coordinate a whole tile away lands on this very slot; claiming the key first would let that nested
    /// fill finish, then let this one overwrite the blocks underneath it, leaving the key naming one chunk
    /// while the data belongs to another. Nothing in generation re-enters this cache today, and writing
    /// the key last means nothing has to keep proving it.
    pub fn fill(self: *@This(), coord: Coordinate) usize {
        const slot = slotOf(coord);
        materializeChunk(&self.chunks[slot], coord.asDepthCoordinate(memory.game.depth));
        self.keys[slot] = coord;
        return slot;
    }

    /// Clears the whole `ChunkCache`, invalidating previous data.
    pub inline fn clear(self: *@This()) void {
        @memset(&self.keys, null);
    }

    /// The `SimBuffer.validateAgainstMaterialization()` invariant, for the cache one ring further out:
    /// a cached chunk must equal what `materializeChunk()` rebuilds for the same coordinate.
    ///
    /// Anything that fills a slot without replaying `mod_store` diverges here,
    /// and a diverged slot is authoritative for every reader until it happens to be evicted,
    /// so the block flickers between its edited and its procedural form as the cache churns.
    pub fn validateAgainstMaterialization(self: *@This()) bool {
        var scratch: Chunk = undefined;
        var reports: usize = 0;

        for (&self.keys, 0..) |maybe_key, slot| {
            const coord = maybe_key orelse continue;
            // A resident chunk is the SimBuffer's to own; the cached copy is allowed to lag it.
            if (SimBuffer.get(coord) != null) continue;
            materializeChunk(&scratch, coord.asDepthCoordinate(memory.game.depth));

            const cached = &self.chunks[slot];
            for (0..CHUNK_SIZE_SQ) |i| {
                const live = cached.blocks[i];
                const rebuilt = scratch.blocks[i];
                if (live.id == rebuilt.id and live.hp == rebuilt.hp and live.base_id == rebuilt.base_id) continue;

                if (reports >= SimBuffer.MAX_DIVERGENCE_REPORTS) return false;
                reports += 1;
                dw.logger.err(
                    @src(),
                    "ChunkCache diverges from materialization at chunk ({d},{d}) q{d} block ({d},{d}): cached {s} hp={d} / rebuilt {s} hp={d}",
                    .{
                        coord.suffix[0],      coord.suffix[1],
                        coord.quadrant,       i & (CHUNK_SIZE - 1),
                        i >> CHUNK_SIZE_LOG2, @tagName(live.id),
                        live.hp,              @tagName(rebuilt.id),
                        rebuilt.hp,
                    },
                );
            }
        }
        return reports == 0;
    }
};

pub var chunk_cache: ChunkCache = .{};

const QuadrantEdgeDetails = struct {
    most_top: bool,
    most_bottom: bool,
    most_left: bool,
    most_right: bool,
};

/// The horizon material window: `ANCESTOR_GRID` blocks square, the sole record of material at H.
pub const HorizonWindow = [QuadCache.ANCESTOR_GRID][QuadCache.ANCESTOR_GRID]Block;

/// Everything `refineHorizonWindow()` needs about one depth change, besides the previous window.
///
/// This is the AUTHORITATIVE per-depth record: about 24 bytes, against the window's 4 KiB.
/// Nothing else that is kept can produce it,
/// because only this records where the player stood when they descended, which the window is centered on.
/// A window itself is a pure function of the seed, the traces down to it, and `mod_store`.
/// So a window is a CACHE, and it is never saved (see `QuadCache.getMaterials()`).
pub const HorizonTrace = struct {
    /// Chunk at H (`depth - HORIZON_DEPTH`) the window is centered on, and the block within it.
    suffix: Vec2u,
    quadrant: u2,
    bx: u4,
    by: u4,
    /// Quadrant the player entered `depth` in.
    player_quadrant: u2,
    /// Quadrant of the chunk descended from, one depth up.
    source_quadrant: u2,
};

/// A static 2x2 grid of seeds only updated during when depth increase or game startup.
pub const QuadCache = struct {
    /// Width of the `ancestor_materials` window, in blocks at H.
    ///
    /// Sized by what generation asks of it, not by what fits. A chunk at H+1 needs a 6x6 block window at H
    /// (`ancestor.getAncestorNeighborhood()`), and the chunks generated around it shift that window by `BLOCKS_PER_PARENT` each,
    /// so the union runs well past 6. A window too small to answer is not a smaller world, it is `panicUnresolvedAncestor()`.
    pub const ANCESTOR_GRID = 16;
    /// First index of the active 2x2, which keeps the live quadrants centered in the window.
    pub const ANCESTOR_CENTER = ANCESTOR_GRID / 2 - 1;

    comptime {
        // odd sizes cannot hold the 2x2 centered, and anything under 8 cannot cover one chunk's 6x6 parent window
        // well, with room for the neighboring chunks that shift it
        if (ANCESTOR_GRID % 2 != 0 or ANCESTOR_GRID < 8)
            @compileError("ANCESTOR_GRID must be even and at least 8 to hold a centered 2x2 plus a chunk's parent window.");
    }

    pub const PATH_PREALLOC_SIZE = 256;

    /// Traces held inline before `materials_path` reaches for the arena.
    /// A trace is tiny, so covering a deep run outright costs under 2 KiB and spares the heap entirely.
    pub const MATERIALS_PREALLOC = 64;
    /// Checkpoints held inline. Each is a whole `HorizonWindow`, so this stays small on purpose;
    /// it covers `MATERIALS_PREALLOC` depths at the current stride either way.
    pub const MATERIALS_WINDOW_PREALLOC = 4;
    // NOTE: making this cache too large results in crashes due to naive copying in Debug.
    pub const SEED_CACHE_SIZE = 256;
    pub const SEED_CACHE_WAYS = 4;
    pub const SEED_CACHE_SETS = SEED_CACHE_SIZE / SEED_CACHE_WAYS;

    /// Ring length of the per-depth rolling buffers below, indexed by `depth % HISTORY_LEN`.
    /// Must exceed `HORIZON_DEPTH` so a live depth D and its horizon ancestor H (D-32) don't collide.
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
    /// The material grid representing the "event horizon" at H (D-32), `ANCESTOR_GRID` blocks square.
    /// The central 2-by-2 (at `ANCESTOR_CENTER`) corresponds to the active quadrants.
    ancestor_materials: [ANCESTOR_GRID][ANCESTOR_GRID]Block,

    /// A list representing the prefix stack of the top left quadrant's X-coordinate.
    /// NOT for use with ancestory logic.
    left_path: SegmentedList(u64, PATH_PREALLOC_SIZE),
    /// A list representing the prefix stack of the top left quadrant's Y-coordinate.
    /// NOT for use with ancestory logic.
    top_path: SegmentedList(u64, PATH_PREALLOC_SIZE),

    /// What each rebased depth's horizon window is refined from, indexed by `materialsSlot()`.
    /// The authoritative record: roughly 24 bytes a depth, and the only part of the horizon that is saved.
    materials_path: SegmentedList(HorizonTrace, MATERIALS_PREALLOC),

    /// Rebuilt horizon windows, one every `MATERIALS_CHECKPOINT_STRIDE` slots of `materials_path`.
    ///
    /// Purely a memo of `getMaterials()`, so it is never saved and truncating it can only cost time.
    /// The refinement is a chain, and replaying it from the base is O(depth);
    /// a checkpoint every stride bounds that at `MATERIALS_CHECKPOINT_STRIDE` refinements
    /// for `4 KiB / MATERIALS_CHECKPOINT_STRIDE` bytes a depth.
    materials_windows: SegmentedList(HorizonWindow, MATERIALS_WINDOW_PREALLOC),

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
    /// Precondition: the world arena MUST be reset to prevent memory leaks/odd issues!
    pub fn reset(self: *@This()) void {
        self.left_path = .{};
        self.top_path = .{};
        self.materials_path = .{};
        self.materials_windows = .{};
        self.most_top = true;
        self.most_bottom = true;
        self.most_left = true;
        self.most_right = true;
    }

    /// First depth whose `ancestor_materials` is recorded,
    /// matching the depth `computeLayer()` starts building the grid.
    pub const MATERIALS_START_DEPTH = HORIZON_DEPTH + STARTING_ZOOM_TIMES;

    /// `materials_path` index for `depth`, or null when that depth records no grid.
    pub inline fn materialsSlot(depth: u64) ?usize {
        if (depth < MATERIALS_START_DEPTH) return null;
        return @intCast(depth - MATERIALS_START_DEPTH);
    }

    /// Slots between rebuilt window checkpoints. A power of two only so the arithmetic stays cheap;
    /// the value itself trades `4 KiB / stride` bytes a depth against that many refinements per rebuild.
    pub const MATERIALS_CHECKPOINT_STRIDE = 16;

    comptime {
        if (!std.math.isPowerOfTwo(MATERIALS_CHECKPOINT_STRIDE))
            @compileError("MATERIALS_CHECKPOINT_STRIDE must be a power of two.");
    }

    /// Number of checkpoints that stay valid once the trace at `slot` changes.
    /// A checkpoint holds the window at its own base slot, so it survives exactly while that base was
    /// refined BEFORE `slot`.
    inline fn checkpointsBelow(slot: usize) usize {
        if (slot == 0) return 0;
        return (slot - 1) / MATERIALS_CHECKPOINT_STRIDE + 1;
    }

    /// Writes the horizon window for `depth` into `out`, or returns false if that depth records none.
    ///
    /// The only way back to a window an ascent needs, since the refinement is not invertible.
    /// Rebuilt by replaying `refineHorizonWindow()` from the nearest checkpoint,
    /// so it costs at most `MATERIALS_CHECKPOINT_STRIDE` refinements and never appears on a per-frame path.
    ///
    /// Rebuilding rather than storing is what makes the horizon SELF-HEALING: a window is a pure function
    /// of the seed, the traces above it and `mod_store`, so fixing a bug in the refinement repairs every
    /// existing save, where a stored window would carry the bad terrain forever.
    pub fn getMaterials(self: *@This(), depth: u64, out: *HorizonWindow) bool {
        const slot = materialsSlot(depth) orelse return false;
        if (slot >= self.materials_path.len) return false;

        // The base window is generated outright and ignores what it is handed,
        // so starting from bedrock rather than undefined costs one memset and keeps this defined.
        var grid: HorizonWindow = @splat(@splat(world_edge_block));
        var i: usize = 0;

        const checkpoint = slot / MATERIALS_CHECKPOINT_STRIDE;
        if (checkpoint < self.materials_windows.len) {
            grid = self.materials_windows.at(checkpoint).*;
            i = checkpoint * MATERIALS_CHECKPOINT_STRIDE + 1; // the checkpoint IS its own base slot
        }

        while (i <= slot) : (i += 1) {
            const d = MATERIALS_START_DEPTH + i;
            grid = refineHorizonWindow(&grid, self.materials_path.at(i).*, d - HORIZON_DEPTH);

            // Every stride boundary this walk crosses is a checkpoint the next rebuild can start from.
            // Only ever appended in order, so a slot's checkpoint is built from the traces below it.
            if (i % MATERIALS_CHECKPOINT_STRIDE == 0 and
                i / MATERIALS_CHECKPOINT_STRIDE == self.materials_windows.len)
            {
                self.materials_windows.append(alloc, grid) catch memory.oom();
            }
        }

        out.* = grid;
        return true;
    }

    /// Drops every checkpoint that a change to `slot`'s trace would invalidate.
    /// Free to be over-eager: a dropped checkpoint costs refinements, never correctness.
    pub fn invalidateMaterialsFrom(self: *@This(), slot: usize) void {
        self.materials_windows.len = @min(self.materials_windows.len, checkpointsBelow(slot));
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
        return self.ancestor_materials[ANCESTOR_CENTER + (quadrant >> 1)][ANCESTOR_CENTER + quadrant % 2];
    }

    /// Returns the 512-bit seed of a specified quadrant (or the global seed if the current depth is <= HORIZON_DEPTH).
    ///
    /// A depth is reached by exactly one of the three branches below depending on where the player happens to be standing,
    /// so ALL of them have to answer the same thing for the same depth,
    /// or a block would generate differently depending on the route the player took to look at it.
    ///
    /// Below the horizon that is the world seed, and above it the recorded rebase path (see
    /// `computeLayer()`, which only steps `path_hashes` past `HORIZON_DEPTH`).
    pub inline fn getQuadrantSeed(self: *const @This(), quadrant: u2, depth: u64) seeding.Seed {
        std.debug.assert(memory.game.depth > HORIZON_DEPTH or quadrant == 0);
        if (depth == memory.game.depth) {
            // verify seeds are the same and make sense
            // if (depth <= dw.HORIZON_DEPTH)
            //     std.debug.assert(std.mem.eql(u64, &self.path_hashes.value[quadrant].value, &memory.game.seed.value));
            return self.path_hashes.value[quadrant];
        }

        // At or shallower than HORIZON_DEPTH there's simply no coordinate rebasing.
        if (depth <= dw.HORIZON_DEPTH) {
            return memory.game.seed;
        }

        // The ring aliases every HISTORY_LEN depths, so only a depth inside the live
        // window names its own slot. A caller outside the window would read another
        // depth's seeds and generate a different world for the same address.
        std.debug.assert(depth < memory.game.depth);
        std.debug.assert(memory.game.depth - depth <= dw.HORIZON_DEPTH);
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
    .materials_path = .{},
    .materials_windows = .{},
    .ancestor_materials = undefined,
};

/// The `hash2d()` lane a chunk draws every `Block.seed` from.
///
/// One definition, so a replayed player edit (`ModEntry.applyTo()`) and the terrain beside it
/// (`ancestor.chunkNoise()`) pick their render variants out of the same stream.
/// `Block.seed` is cosmetic only, so this lane is deliberately the weakest of the chunk's four.
pub fn seedLane(key: DepthCoordinate) Vec2u {
    const seeds = quad_cache.getChunkSeeds(key);
    return .{ seeds.value[0].value[2], seeds.value[0].value[3] };
}

/// Represents the answer to the question "what is the largest possible suffix value"?
/// 15 at depth 1, 255 at depth 2, capped at 2**64-1 at depth 16 and beyond.
///
/// Invariant: this ALWAYS equals `getMaxSuffixAtDepth(memory.game.depth)` (the initial 0 is depth 0's edge),
/// asserted on every depth change in `installLayer()`.
pub var max_possible_suffix: u64 = 0;

/// Gets the maximum possible suffix at a certain depth (see `max_possible_suffix` for details on meaning).
pub inline fn getMaxSuffixAtDepth(depth: u64) u64 {
    if (depth >= dw.HORIZON_DEPTH) return std.math.maxInt(u64);
    return (@as(u64, 1) << @intCast(depth * dw.ZOOM_LOG2)) - 1;
}

/// Whether the world at `depth` actually has the chunk `coord` names.
///
/// Past `HORIZON_DEPTH` the suffix uses its full width and the quadrant carries the top bit,
/// so every value names a real chunk and only `Coordinate.moveAtDepth()` can tell you that you left.
///
/// Worth asserting wherever the PLAYER's chunk is written: it is the frame every other world coordinate
/// is measured from, so a chunk off the world displaces the whole visible world instead of failing outright.
pub inline fn isInWorld(coord: Coordinate, depth: u64) bool {
    const max = getMaxSuffixAtDepth(depth);
    return coord.suffix[0] <= max and coord.suffix[1] <= max;
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

    chunk.* = chunk_cache.chunks[chunk_cache.fill(coord)];
}

/// Gets a new instance of a `Chunk` at the current depth.
pub inline fn getChunk(coord: Coordinate) Chunk {
    var chunk: Chunk = undefined;
    writeChunk(&chunk, coord);
    return chunk;
}

/// The chunk at the current depth, IN PLACE: resident if it already is, generated into `chunk_cache` if not.
///
/// A `Chunk` is `memory.CHUNK_BYTES` (4 KiB), so `getChunk()`/`writeChunk()` copy that much every call.
/// Readers that only want to look at blocks should come through here instead.
///
/// The pointer is only valid until the next generation: it may point into a `chunk_cache` slot, and the
/// clock can hand that same slot to another coordinate. Read what you need, then let it go.
pub fn getChunkPtr(coord: Coordinate) *const Chunk {
    if (SimBuffer.get(coord)) |resident| return resident;
    if (chunk_cache.findIndex(coord)) |i| return &chunk_cache.chunks[i];

    return &chunk_cache.chunks[chunk_cache.fill(coord)];
}

/// Builds the chunk the player actually sees: procedural generation, then every modified cell replayed on top,
/// then a flag recompute (replaying ids invalidates the flags the generator derived).
///
/// This is the ONLY way a `mod_store` entry should become a `Chunk`; the store holds no block data of its own.
///
/// WHY THIS IS SPLIT FROM `generateChunk()`, and must stay split:
/// `generateChunk()` is the world's DEFINITION and has to be a pure function of the seed alone.
/// Every child depth is derived from its parent, so a generator that could see a modification would
/// bake that modification into the terrain of every depth below it, and the same block would then
/// generate differently depending on whether the player had happened to mine near it. `mod_store`
/// stays a separate OVERLAY replayed on top, which is also what lets a save hold a handful of edited
/// cells instead of the chunks, and what lets a worldgen fix repair an existing save.
pub fn materializeChunk(chunk: *Chunk, key: DepthCoordinate) void {
    materializeChunkInner(chunk, key, .live);
}

/// `materializeChunk()` for a chunk that serves as an ANCESTOR of a deeper depth.
///
/// Replays the frozen values over the live ones, exactly as `inheritedCell()` chooses between them,
/// so the whole-chunk route and the cell-by-cell route agree.
/// A chunk built by this must never reach the player: it is the depth as its descendants remember it.
pub fn materializeInheritedChunk(chunk: *Chunk, key: DepthCoordinate) void {
    materializeChunkInner(chunk, key, .inherited);
}

/// Which of the two stores a materialization replays.
/// `.inherited` replays `mod_store` and then `legacy_store` ON TOP, since a frozen value wins.
const StoreView = enum { live, inherited };

fn materializeChunkInner(chunk: *Chunk, key: DepthCoordinate, comptime view: StoreView) void {
    // Asked BEFORE generating so the flag pass can be skipped when it is about to be redone below.
    // A bool rather than the entry itself: generation is a long call and nothing should hold a store
    // pointer across it.
    const frozen = view == .inherited and legacy_store.contains(key);
    const modified = mod_store.contains(key) or frozen;
    const is_base = key.depth == STARTING_ZOOM_TIMES;

    // The generator derives flags from the ids it just wrote. Replaying an edit changes those ids, so
    // those flags are dead the moment `applyTo()` runs; deriving them twice is pure waste.
    // The base depth is the exception: its decoration pass reads the flags while generating.
    generateChunkInner(chunk, key, if (modified and !is_base) .skip_flags else .derive_flags);

    const entry = mod_store.get(key);
    // Generation must never touch the store, or the flag pass skipped above would never be made up for.
    std.debug.assert((entry != null) == (mod_store.contains(key)));
    if (entry) |e| e.applyTo(chunk, key);
    // A frozen value beats the live one, so it goes on last.
    if (frozen) legacy_store.get(key).?.applyTo(chunk, key);

    if (!is_base) {
        // Exactly the pass `generateChunkInner()` was told to skip, now that the ids are final.
        if (modified) addEdgeFlagsFractal(chunk, key);
        return;
    }

    const hood: ModNeighborhood = .collect(key);
    if (!hood.any) return;

    addEdgeFlags(chunk, key, &hood);
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

/// Whether `generateChunkInner()` finishes with the edge-flag pass, or leaves it to its caller.
///
/// Only `materializeChunk()` may skip it, and only because it derives the flags itself right after
/// replaying the modifications. A chunk that leaves here with `.skip_flags` and never gets a flag
/// pass carries whatever the last chunk in that memory happened to have.
const FlagPass = enum { derive_flags, skip_flags };

/// Does not go through the cache, as its goal is to generate chunks from scratch;
/// branches into base procedural generation or fractal scaling depending on depth.
///
/// Purely procedural: modifications are NOT applied here. Use `materializeChunk()` for the chunk the player actually sees.
pub fn generateChunk(chunk: *Chunk, key: DepthCoordinate) void {
    generateChunkInner(chunk, key, .derive_flags);
}

/// `generateChunk()` with the trailing flag pass made optional; see `FlagPass`.
///
/// `flags` is a runtime parameter on purpose: a comptime one would emit the whole generation body
/// twice for one predictable branch per chunk.
fn generateChunkInner(chunk: *Chunk, key: DepthCoordinate, flags: FlagPass) void {
    if (key.depth == STARTING_ZOOM_TIMES) {
        // Always flagged, whatever the caller asked: `decorations.stampChunk()` reads the flags to
        // find the surfaces it anchors to, so the base pass cannot defer them.
        generateBaseChunk(chunk, key.asCoord());
        return;
    }

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

            // The seed `applyAncestorLogic()` picks is authoritative and must NOT be overwritten here:
            // `getInheritedMaterial()` derives the same block without going through this loop, and a
            // stream-ordered seed would disagree with it depending only on whether the ancestor cache
            // happened to hold the chunk, which the same block's appearance must never depend on.
            chunk.blocks[idx] = dw.ancestor.applyAncestorLogic(
                parent_sprite,
                neighbors,
                key,
                @intCast(block_x),
                @intCast(block_y),
            ).compile();
        }
    }

    if (flags == .derive_flags) addEdgeFlagsFractal(chunk, key);
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

/// Returns a block for the current-depth edge halo.
/// Cached chunks already carry their live edit.
/// An uncached inherited block needs the live `mod_store` value because
/// `legacy_store` applies only below its own depth.
fn getLiveFractalHaloBlock(key: DepthCoordinate, bx: u4, by: u4) Block {
    std.debug.assert(key.depth == memory.game.depth);
    if (getCachedChunk(key)) |cached_chunk| return cached_chunk.getBlock(bx, by);

    var block = dw.ancestor.getInheritedMaterial(key, bx, by);
    if (mod_store.index.count() != 0) {
        const block_idx: u8 = @intCast((@as(usize, by) << CHUNK_SIZE_LOG2) | bx);
        if (mod_store.getCell(key, block_idx)) |cell| cell.applyTo(&block);
    }
    return block;
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
/// `mods` overlays the player's edits onto the neighbor blocks in the halo. Null while GENERATING,
/// for determinism. Later on, `materializeChunk()` re-derives the flags with edits.
fn addEdgeFlags(target_chunk: *Chunk, key: DepthCoordinate, mods: ?*const ModNeighborhood) void {
    const coord = key.asCoord();
    const depth = key.depth;
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
                // chunk next door would never open up THIS chunk's border. Overlay the edit, but only once generation is over
                // (`mods` is null during it), so generation stays a pure function of the seed.
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

    // Every neighbor test below asks the same two questions of a halo cell, and a cell is a neighbor of
    // up to 8 others, so the sprite rule table is read once per cell here instead of 8 times below.
    var halo_flagworthy: [18][18]bool = undefined;
    var halo_solid_or_liquid: [18][18]bool = undefined;
    for (0..18) |hy2| {
        for (0..18) |hx2| {
            const s = halo[hy2][hx2];
            halo_flagworthy[hy2][hx2] = shouldHaveEdgeFlags(s);
            halo_solid_or_liquid[hy2][hx2] = s.isSolid() or s.isLiquid();
        }
    }

    // Calculate flags using the static halo buffer
    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            var flags: u8 = 0;
            const current_sprite = halo[@intCast(y + 1)][@intCast(x + 1)];
            if (current_sprite == .edge_stone) {
                const block = &target_chunk.blocks[y * CHUNK_SIZE + x];
                block.edge_flags = 0xFF;
                block.id_edge_flags = 0xFF;
                block.water = .dry;
                continue;
            }

            const left_nb = halo[@intCast(y + 1)][@intCast(x)];
            const right_nb = halo[@intCast(y + 1)][@intCast(x + 2)];
            const top_nb = halo[@intCast(y)][@intCast(x + 1)];
            const bottom_nb = halo[@intCast(y + 2)][@intCast(x + 1)];
            const above_left_nb = halo[@intCast(y)][@intCast(x)];
            const above_right_nb = halo[@intCast(y)][@intCast(x + 2)];

            const state = water.getWaterloggedStateSprites(
                top_nb,
                bottom_nb,
                left_nb,
                right_nb,
                above_left_nb,
                above_right_nb,
            );

            // Same-sprite flags are computed for ALL foundation blocks (one extra compare per neighbor);
            // restrict to isOre()/isGem() here if that ever becomes worth the branch.
            const current_liquid = current_sprite.isLiquid();
            var id_flags: u8 = 0;
            inline for (.{ -1, 0, 1 }) |dy| {
                inline for (.{ -1, 0, 1 }) |dx| {
                    if (dx == 0 and dy == 0) continue;
                    const hy2 = @as(usize, 1 + dy) + y;
                    const hx2 = @as(usize, 1 + dx) + x;

                    const connects = if (current_liquid) halo_solid_or_liquid[hy2][hx2] else halo_flagworthy[hy2][hx2];
                    if (connects) flags |= types.EdgeFlags.getFlagBit(dx, dy);
                    if (halo[hy2][hx2] == current_sprite) {
                        id_flags |= types.EdgeFlags.getFlagBit(dx, dy);
                    }
                }
            }

            target_chunk.blocks[y * CHUNK_SIZE + x].edge_flags = flags;
            target_chunk.blocks[y * CHUNK_SIZE + x].id_edge_flags = id_flags;
            target_chunk.blocks[y * CHUNK_SIZE + x].water = state;
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
            const neighbor_key = nc.asDepthCoordinate(k.depth);
            if (neighbor_key.depth == memory.game.depth) {
                return getLiveFractalHaloBlock(neighbor_key, lx, ly);
            }
            if (getCachedChunk(neighbor_key)) |cached_chunk| {
                return cached_chunk.getBlock(lx, ly);
            }
            return dw.ancestor.getInheritedMaterial(neighbor_key, lx, ly);
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

    // Read the sprite rule table once per halo cell rather than once per (cell, neighbor) pair;
    // see the matching pass in `addEdgeFlags()`.
    var halo_sprite: [18][18]Sprite = undefined;
    var halo_flagworthy: [18][18]bool = undefined;
    var halo_solid_or_liquid: [18][18]bool = undefined;
    for (0..18) |hy2| {
        for (0..18) |hx2| {
            const s = halo[hy2][hx2].id;
            halo_sprite[hy2][hx2] = s;
            halo_flagworthy[hy2][hx2] = shouldHaveEdgeFlags(s);
            halo_solid_or_liquid[hy2][hx2] = s.isSolid() or s.isLiquid();
        }
    }

    // Process center blocks using local halo reads
    for (0..CHUNK_SIZE) |block_y| {
        for (0..CHUNK_SIZE) |block_x| {
            const idx = block_x + block_y * CHUNK_SIZE;
            const current_block = &target_chunk.blocks[idx];
            const current_sprite = current_block.id;
            if (current_sprite.isEmpty()) continue;
            if (current_sprite == .edge_stone) {
                current_block.edge_flags = 0xFF;
                current_block.id_edge_flags = 0xFF;
                current_block.water = .dry;
                continue;
            }

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
            const current_liquid = current_sprite.isLiquid();
            var flags: u8 = 0;
            var id_flags: u8 = 0;
            inline for (.{ -1, 0, 1 }) |dy| {
                inline for (.{ -1, 0, 1 }) |dx| {
                    if (dx == 0 and dy == 0) continue;
                    const hy2: usize = @intCast(ly + dy);
                    const hx2: usize = @intCast(lx + dx);

                    const connects = if (current_liquid) halo_solid_or_liquid[hy2][hx2] else halo_flagworthy[hy2][hx2];
                    if (connects) flags |= types.EdgeFlags.getFlagBit(dx, dy);
                    if (halo_sprite[hy2][hx2] == current_sprite) {
                        id_flags |= types.EdgeFlags.getFlagBit(dx, dy);
                    }
                }
            }
            current_block.edge_flags = flags;
            current_block.id_edge_flags = id_flags;
            current_block.water = state;
        }
    }
}

/// Returns whether a sprite participates in terrain edge flag calculations.
/// This controls its own terrain flags and its effect on adjacent terrain.
/// Liquids use their own edge rule.
pub inline fn shouldHaveEdgeFlags(sprite: Sprite) bool {
    return sprite.isFoundation();
}

/// Returns whether both sprites are liquids and should therefore use liquid-adjacent edge flags instead.
inline fn isBothLiquid(sprite_a: Sprite, sprite_b: Sprite) bool {
    return sprite_a.isLiquid() and sprite_b.isLiquid();
}

/// The cell one to the right of `bx`, crossing into the next chunk when it has to.
/// Null at the world edge, where there is nowhere for a pair's other half to go.
const RightCell = struct { coord: Coordinate, bx: u4 };
inline fn rightNeighborCell(coord: Coordinate, bx: u4) ?RightCell {
    if (bx < CHUNK_SIZE - 1) return .{ .coord = coord, .bx = bx + 1 };
    return .{ .coord = coord.move(.{ 1, 0 }) orelse return null, .bx = 0 };
}

const BlockTypeCell = struct {
    coord: Coordinate,
    bx: u4,
    sprite: Sprite,
    prev: Block,
};

/// Exact cells a `modifyBlockType()` action will write before support validation.
const BlockTypePlan = struct {
    first: BlockTypeCell,
    second: ?BlockTypeCell = null,
};

/// Result of a `modifyBlockType()` request.
pub const ModifyBlockTypeResult = enum {
    /// The requested primary block stayed in the world.
    placed,
    /// Support validation removed the requested primary block after it was written.
    collapsed,
    /// Normal-play safety rejected a placement before any world state changed.
    rejected_softlock,
};

/// Works out the exact primary and paired cells that a block placement will write.
fn planBlockTypeChange(coord: Coordinate, bx: u4, by: u4, new_sprite: Sprite, prev_block: Block) BlockTypePlan {
    var plan: BlockTypePlan = .{
        .first = .{ .coord = coord, .bx = bx, .sprite = new_sprite, .prev = prev_block },
    };

    const partner = new_sprite.pairedRight();
    if (partner == .none) return plan;

    const right = rightNeighborCell(coord, bx) orelse return plan;
    const right_block = getBlockAt(right.coord, right.bx, by, memory.game.depth);
    if (!dw.inventory.isInCreative() and !right_block.isEmpty()) return plan;

    // Only place the right half if the block underneath it is solid.
    const ny = @as(i32, by) + 1;
    const under_coord = if (ny >= CHUNK_SIZE) right.coord.moveY(1) else right.coord;
    const uc = under_coord orelse return plan;
    const under_by: u4 = @intCast(@mod(ny, CHUNK_SIZE));
    const under_block = getBlockAt(uc, right.bx, under_by, memory.game.depth);
    if (!under_block.isSolid()) return plan;

    plan.second = .{ .coord = right.coord, .bx = right.bx, .sprite = partner, .prev = .empty };
    return plan;
}

/// Applies a block modification, changing the `Sprite` type and resetting `hp`.
///
/// Normal-play callers must use this function for every placement.
/// It gives `player.permitsPlacement()` the exact cells that will persist before it writes `mod_store`.
/// `prev_block` is the block that occupied the primary cell before this action began.
/// The caller must pass the original block when mining replaces a cell.
pub fn modifyBlockType(
    coord: Coordinate,
    bx: u4,
    by: u4,
    new_sprite: Sprite,
    prev_block: Block,
) ModifyBlockTypeResult {
    const plan = planBlockTypeChange(coord, bx, by, new_sprite, prev_block);

    if (!dw.inventory.isInCreative()) {
        var pending: [2]player.PendingPlacement = .{
            .{ .coord = plan.first.coord, .bx = plan.first.bx, .by = by, .sprite = plan.first.sprite },
            undefined,
        };
        var pending_len: usize = 1;
        if (plan.second) |second| {
            pending[pending_len] = .{ .coord = second.coord, .bx = second.bx, .by = by, .sprite = second.sprite };
            pending_len += 1;
        }
        if (!player.permitsPlacement(pending[0..pending_len])) return .rejected_softlock;
    }

    writeBlockType(plan.first.coord, plan.first.bx, by, plan.first.sprite, plan.first.prev);
    if (plan.second) |second| {
        writeBlockType(second.coord, second.bx, by, second.sprite, second.prev);
        _ = updateLocalEdgeFlags(second.coord, second.bx, by);
    }
    return if (updateLocalEdgeFlags(coord, bx, by)) .collapsed else .placed;
}

/// The write half of `modifyBlockType()`: updates `mod_store` and every live cache, WITHOUT validating
/// the result. Only `modifyBlockType()` should call this, and it must always follow up with
/// `updateLocalEdgeFlags()`, or an unsupported block stays in the world until something else touches it.
fn writeBlockType(coord: Coordinate, bx: u4, by: u4, new_sprite: Sprite, prev_block: Block) void {
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

    // Determine the overlay's underlay from what was here before (with fallback to plain stone),
    // so replacing (say) a stone block with gold keeps showing that stone type behind the ore mask
    const new_base: Sprite = if (new_sprite.isOverlay())
        (if (prev_block.base_id != .none) prev_block.base_id else if (prev_block.isFoundation()) prev_block.id else .stone)
    else
        .none;

    mod_store.beginWrite(key).setCell(idx, .{
        .id = new_sprite,
        .base_id = new_base,
        .hp = initial_hp,
    });

    if (SimBuffer.get(coord)) |sim_chunk| {
        const block: *Block = &sim_chunk.blocks[idx];
        block.id = new_sprite;
        block.base_id = new_base;
        block.hp = initial_hp;
        block.edge_flags = 0xFF;
        block.id_edge_flags = 0xFF;
        block.water = .dry;
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
        block.water = .dry;
    }
}

/// Resets one block's fields to the "empty cell" sentinels (id + underlay + hp + edge/waterlog).
/// Leaves `seed` and `tag` alone: both are properties of the CELL, not of what occupies it, and
/// `materializeChunk()` likewise keeps the generated ones when it replays an edit over them.
/// A cell's provenance therefore never depends on whether the player has touched it.
///
/// Must agree field-for-field with the `ModCell` `internalClearBlock()` stores, so a cleared cell reads
/// the same whether it comes from a live cache or from `materializeChunk()`.
inline fn clearBlockFields(b: *Block) void {
    b.id = .none;
    b.base_id = .none;
    b.hp = 0;
    b.edge_flags = 0xFF;
    b.id_edge_flags = 0xFF;
    b.water = .dry;
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

    /// Forgets everything, after a clear so no stale copy of the removed cell lingers in the window.
    inline fn reset(self: *BlockWindow) void {
        @memset(&self.cells, null);
    }
};

/// Resolves the edge flag bit and the same-sprite flag bit
/// that one of the eight neighbors of a cell contributes.
///
/// `ndx` and `ndy` are `comptime` so `getFlagBit()` folds to a single constant,
/// but the function is deliberately NOT `inline`:
/// the 3x3 unroll in `updateLocalEdgeFlags()` would otherwise paste eight copies into one function,
/// and LLVM cost is quadratic in basic-block count.
fn neighborFlagBits(
    comptime ndx: i32,
    comptime ndy: i32,
    window: *BlockWindow,
    nx: i32,
    ny: i32,
    current_sprite: Sprite,
    src_is_liquid: bool,
) struct { edge: u8, id: u8 } {
    const neighbor_block = window.get(nx + ndx, ny + ndy);
    const bit = types.EdgeFlags.getFlagBit(ndx, ndy);

    const is_solid_or_liquid = neighbor_block.isSolid() or neighbor_block.isLiquid();
    const takes_edge = (!src_is_liquid and shouldHaveEdgeFlags(neighbor_block.id)) or
        (src_is_liquid and is_solid_or_liquid);

    return .{
        .edge = if (takes_edge) bit else 0,
        .id = if (neighbor_block.id == current_sprite) bit else 0,
    };
}

/// Recalculates edge flags for a specific block its 8 neighbors.
/// Returns whether the current block was removed due to being in an invalid position.
///
/// NOTE: This function creates an initial lag spike on first call in Debug,
/// but problems vanish in Release and assuming a valid flags state, this function is effectively instant.
fn updateLocalEdgeFlags(coord: Coordinate, bx: u4, by: u4) bool {
    flag_worklist.append(alloc, .{
        .coord = coord,
        .bx = bx,
        .by = by,
    }) catch memory.oom();
    defer flag_worklist.clearRetainingCapacity();

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
                    if (current_sprite != .water) dw.inventory.dropItem(
                        current_sprite,
                        target_coord,
                        lbx,
                        lby,
                    );

                    // Internal block modification to avoid recursion.
                    internalClearBlock(target_coord, lbx, lby);
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
                var water_state: water.WaterState = .dry;

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
                        water_state = state;
                    }
                } else {
                    water_state = state;

                    // Recalculate edge flags (same-sprite flags for all foundation blocks; see `addEdgeFlags()`)
                    const src_is_liquid = current_sprite.isLiquid();
                    inline for (.{ -1, 0, 1 }) |ndy| {
                        inline for (.{ -1, 0, 1 }) |ndx| {
                            if (ndx == 0 and ndy == 0) continue;
                            const bits = neighborFlagBits(ndx, ndy, &window, nx, ny, current_sprite, src_is_liquid);
                            flags |= bits.edge;
                            id_flags |= bits.id;
                        }
                    }
                }

                // Most cells the cascade sweeps are unaffected; skipping the identical rewrite avoids two store lookups.
                if (current_block.edge_flags == flags and
                    current_block.id_edge_flags == id_flags and
                    current_block.water.eql(water_state)) continue;
                window.drop(nx, ny);

                // Only the materialized caches are patched: flags are derived state, so `mod_store` does not store them,
                // and `refreshDerivedFlags()` rebuilds them from the replayed ids on the next materialization.
                if (SimBuffer.get(target_coord)) |c| {
                    c.blocks[block_id].edge_flags = flags;
                    c.blocks[block_id].id_edge_flags = id_flags;
                    c.blocks[block_id].water = water_state;
                }
                if (chunk_cache.findIndex(target_coord)) |index| {
                    chunk_cache.chunks[index].blocks[block_id].edge_flags = flags;
                    chunk_cache.chunks[index].blocks[block_id].id_edge_flags = id_flags;
                    chunk_cache.chunks[index].blocks[block_id].water = water_state;
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

/// Edge stone block type for the edge of the world. At `STARTING_ZOOM_TIMES`,
/// the bordering 2 blocks of the world are edge stone.
///
/// This is ONLY for coordinates that genuinely have no chunk.
/// Lookups that fail should use `panicUnresolvedAncestor()` instead of quietly becoming terrain.
pub const world_edge_block: Block = .makeBasicBlock(.edge_stone, 0);

/// Crash for an ancestor block that exists in the world but that the window cannot hold.
/// Reaching here means `QuadCache.ANCESTOR_GRID` is too small for what generation now asks of it.
pub fn panicUnresolvedAncestor() noreturn {
    @panic("Ancestor lookup fell outside the horizon window; raise QuadCache.ANCESTOR_GRID.");
}

/// Basic lookup to find a block's `Sprite` type for flag calculation.
/// Checks caches, then modifications, then falls back to procedural logic.
/// Ensures that we do not accidentally read `SimBuffer` data if checking an ancestor depth!
pub fn getBlockAt(coord: Coordinate, lx: u4, ly: u4, depth: u64) Block {
    if (depth == memory.game.depth) { // easy!
        return getChunkPtr(coord).blocks[(@as(usize, ly) << CHUNK_SIZE_LOG2) | lx];
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

            // center queries on the active quadrants within the window.
            const x_idx = diff_block_x + QuadCache.ANCESTOR_CENTER + @as(i64, memory.game.player_quadrant % 2);
            const y_idx = diff_block_y + QuadCache.ANCESTOR_CENTER + @as(i64, memory.game.player_quadrant / 2);

            // The window is the ONLY record of material at H, so a query it cannot represent has no
            // answer at all. It used to be given air, which is the worst possible guess: the caller
            // is generating terrain from this, and air here erases every depth that descends from it.
            const grid: i64 = QuadCache.ANCESTOR_GRID;
            if (x_idx < 0 or x_idx >= grid or y_idx < 0 or y_idx >= grid) panicUnresolvedAncestor();
            return quad_cache.ancestor_materials[@intCast(y_idx)][@intCast(x_idx)];
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

/// Clears various data caches that can easily be regenerated.
pub fn clearCaches(comptime clear_ancestors: bool) void {
    SimBuffer.clear();
    chunk_cache.clear();
    dw.lighting.invalidateMiningLight();
    @memset(&quad_cache.seed_clock_bits, 0);
    @memset(&quad_cache.seed_hand, 0);
    @memset(&quad_cache.seed_cache_keys, @splat(DepthCoordinate.invalid));
    dw.ancestor.clearChunkNoise();
    dw.ancestor.clearParentHoods();
    clearLegacyScratch();

    // A debug slider changes what the terrain functions answer without changing the seed, so the
    // memoized terrain has to go with it. Bumping the epoch retires every entry of the base terrain
    // and foundation caches at once (see `procedural.terrainGeneration()`); release cannot reach this.
    procedural.invalidateTuning();

    // Nothing to do for the structure banks: every entry carries the seed AND the terrain generation
    // it was resolved under, so a reseed or a slider retires it on its next read.

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
    legacy_store.init(memory.main_allocator);
    ascent_stack.clearRetainingCapacity();
    quad_cache.reset();
}

/// Where a descent puts the player inside the block it descends into.
pub const LayerAnchor = enum {
    /// Keep the player where they are on screen, so a zoom in place does not move them.
    /// Reads the player position and not the block,
    /// so it is only correct when the block is the one the player already stands in.
    player,
    /// Stand the player on the floor in the middle of the block's child region.
    /// A portal descent uses this.
    /// Its block is the portal, which the player is not always inside.
    block_floor,
};

/// Subpixels from the player's center down to their feet; see `PLAYER_HITBOX_HEIGHT` use in `player.zig`.
const PLAYER_FEET_OFFSET = CHUNK_SIZE_SQ / 2;

/// Everything one depth change works out, kept apart from the act of applying it.
///
/// The split lets the same transition be installed more than once.
/// The portal animation installs it every frame as a throwaway.
/// That generates the new depth's chunks while the committed world still sits at the old depth.
/// Fields past `rebase` mean nothing at or before `HORIZON_DEPTH`, where no rebase happens.
pub const LayerTransition = struct {
    /// The depth being entered: one deeper for `computeLayer()`, one shallower for `computeParentLayer()`.
    depth: u64,
    /// Player subpixel position inside the new chunk, pivot included.
    new_pos: Vec2i,
    player_chunk: Vec2u,
    player_quadrant: u2,
    max_possible_suffix: u64,

    /// Whether the fields below carry meaning (false at or before `HORIZON_DEPTH`).
    rebase: bool = false,
    path_hashes: ChunkSeeds = undefined,
    /// Top-left cell of the rebase window for `depth`; see `QuadCache.getOriginX()`.
    left_cell: u64 = 0,
    top_cell: u64 = 0,
    most_top: bool = true,
    most_bottom: bool = true,
    most_left: bool = true,
    most_right: bool = true,
    /// The horizon window for `depth`.
    /// Only built once the horizon has a real ancestor depth to summarize.
    ancestor_materials: HorizonWindow = undefined,
    /// The trace the window above was refined from, or null when this transition built no window.
    ///
    /// Only a first DESCENT into a depth derives a trace.
    /// An ascent and a retrace read the depth's window back out of `materials_path`,
    /// so they must leave the recorded trace exactly as it is.
    /// Writing an unset one back corrupts the horizon for that depth and every depth refined from it.
    horizon_trace: ?HorizonTrace = null,
    has_materials: bool = false,
};

/// The exact slice of global state `installLayer()` overwrites, captured so a preview install can be undone.
///
/// This mirrors `installLayer()` field for field: if one gains a write, the other MUST gain a capture,
/// or a preview would leak D+1 state into the live D world.
pub const LayerSnapshot = struct {
    depth: u64,
    player_chunk: Vec2u,
    player_quadrant: u8,
    max_possible_suffix: u64,
    path_hashes: ChunkSeeds,
    /// `depth % QuadCache.HISTORY_LEN`: the single rolling-buffer slot a transition writes.
    ring: usize,
    origin_x: u3,
    origin_y: u3,
    historical_seed: ChunkSeeds,
    ancestor_materials: [QuadCache.ANCESTOR_GRID][QuadCache.ANCESTOR_GRID]Block,
    most_top: bool,
    most_bottom: bool,
    most_left: bool,
    most_right: bool,
    /// Length of both path lists, so an append made by the install can be dropped.
    path_len: usize,
    path_slot: usize,
    /// Whether `path_slot` already existed (and so must be restored rather than truncated away).
    path_slot_live: bool,
    path_left: u64,
    path_top: u64,
    /// Length of `materials_path`, so an append made by the install can be dropped.
    materials_len: usize,
    materials_slot: usize,
    /// Whether `materials_slot` already existed (and so must be restored rather than truncated away).
    materials_slot_live: bool,
    materials_prev: HorizonTrace,
};

/// Records the rebase origin cell for `depth` in the packed path lists (21 3-bit cells per u64).
/// Only the first cell of a fresh slot grows the list; every other write patches an existing slot,
/// so a re-descent cannot corrupt earlier depths.
fn writeRebasePath(depth: u64, left_cell: u64, top_cell: u64) void {
    const path_start_depth = dw.HORIZON_DEPTH + 1; // first depth that records a rebase path entry
    if (depth < path_start_depth) return;

    const path_idx = depth - path_start_depth; // 0-based index of this depth in the path history
    const slot: usize = @intCast(path_idx / 21); // packed-array slot (21 3-bit cells per u64)
    const bit_shift: u6 = @intCast((path_idx % 21) * 3); // bit offset of this cell within its slot

    if (bit_shift == 0 and slot >= quad_cache.left_path.len) {
        quad_cache.left_path.append(alloc, left_cell) catch memory.oom();
        quad_cache.top_path.append(alloc, top_cell) catch memory.oom();
    } else {
        const cell_mask = @as(u64, 0b111) << bit_shift;
        const lx: *u64 = quad_cache.left_path.at(slot);
        lx.* = (lx.* & ~cell_mask) | (left_cell << bit_shift);
        const ty: *u64 = quad_cache.top_path.at(slot);
        ty.* = (ty.* & ~cell_mask) | (top_cell << bit_shift);
    }
}

/// Records what `depth`'s horizon window is recovered from, appending a fresh slot or patching an
/// existing one, exactly like `writeRebasePath()`. A retraced descent must not grow the list.
///
/// Precondition: depths are recorded in order, so the slot is never more than one past the end.
/// That holds because the only way to reach a depth is through the depth above it.
fn writeMaterialsPath(depth: u64, trace: HorizonTrace) void {
    const slot = QuadCache.materialsSlot(depth) orelse return;
    std.debug.assert(slot <= quad_cache.materials_path.len);

    if (slot == quad_cache.materials_path.len) {
        quad_cache.materials_path.append(alloc, trace) catch memory.oom();
    } else {
        quad_cache.materials_path.at(slot).* = trace;
    }
    // Every window at or past this slot was refined through the trace just written.
    quad_cache.invalidateMaterialsFrom(slot);
}

/// Captures the state a transition into `next_depth` would overwrite, for `restoreLayer()`.
pub fn snapshotLayer(next_depth: u64) LayerSnapshot {
    const ring: usize = @intCast(next_depth % QuadCache.HISTORY_LEN);
    std.debug.assert(quad_cache.left_path.len == quad_cache.top_path.len);

    // we save a LOT of things!
    var snapshot: LayerSnapshot = .{
        .depth = memory.game.depth,
        .player_chunk = memory.game.player_chunk,
        .player_quadrant = memory.game.player_quadrant,
        .max_possible_suffix = max_possible_suffix,
        .path_hashes = quad_cache.path_hashes,
        .ring = ring,
        .origin_x = quad_cache.origins_x[ring],
        .origin_y = quad_cache.origins_y[ring],
        .historical_seed = quad_cache.historical_seeds[ring],
        .ancestor_materials = quad_cache.ancestor_materials,
        .most_top = quad_cache.most_top,
        .most_bottom = quad_cache.most_bottom,
        .most_left = quad_cache.most_left,
        .most_right = quad_cache.most_right,
        .path_len = quad_cache.left_path.len,
        .path_slot = 0,
        .path_slot_live = false,
        .path_left = 0,
        .path_top = 0,
        .materials_len = quad_cache.materials_path.len,
        .materials_slot = 0,
        .materials_slot_live = false,
        .materials_prev = undefined,
    };

    if (next_depth > dw.HORIZON_DEPTH) {
        const slot: usize = @intCast((next_depth - dw.HORIZON_DEPTH - 1) / 21);
        snapshot.path_slot = slot;
        if (slot < quad_cache.left_path.len) {
            snapshot.path_slot_live = true;
            snapshot.path_left = quad_cache.left_path.at(slot).*;
            snapshot.path_top = quad_cache.top_path.at(slot).*;
        }
    }

    if (QuadCache.materialsSlot(next_depth)) |slot| {
        snapshot.materials_slot = slot;
        if (slot < quad_cache.materials_path.len) {
            snapshot.materials_slot_live = true;
            snapshot.materials_prev = quad_cache.materials_path.at(slot).*;
        }
    }
    return snapshot;
}

/// Puts back everything `snapshotLayer()` captured, undoing a preview install exactly.
pub fn restoreLayer(snapshot: LayerSnapshot) void {
    memory.game.depth = snapshot.depth;
    memory.game.player_chunk = snapshot.player_chunk;
    memory.game.player_quadrant = snapshot.player_quadrant;
    max_possible_suffix = snapshot.max_possible_suffix;

    quad_cache.path_hashes = snapshot.path_hashes;
    quad_cache.origins_x[snapshot.ring] = snapshot.origin_x;
    quad_cache.origins_y[snapshot.ring] = snapshot.origin_y;
    quad_cache.historical_seeds[snapshot.ring] = snapshot.historical_seed;
    quad_cache.ancestor_materials = snapshot.ancestor_materials;
    quad_cache.most_top = snapshot.most_top;
    quad_cache.most_bottom = snapshot.most_bottom;
    quad_cache.most_left = snapshot.most_left;
    quad_cache.most_right = snapshot.most_right;

    // A fresh slot only ever appends at the end, so dropping the length is enough to forget it.
    if (snapshot.path_slot_live) {
        quad_cache.left_path.at(snapshot.path_slot).* = snapshot.path_left;
        quad_cache.top_path.at(snapshot.path_slot).* = snapshot.path_top;
    }
    quad_cache.left_path.len = snapshot.path_len;
    quad_cache.top_path.len = snapshot.path_len;

    if (snapshot.materials_slot_live) {
        quad_cache.materials_path.at(snapshot.materials_slot).* = snapshot.materials_prev;
    }
    quad_cache.materials_path.len = snapshot.materials_len;
}

/// Writes a computed transition into the globals that chunk generation reads.
///
/// Deliberately does NOT clear caches, drop items, or move the player: `commitLayer()` owns those.
/// This is the half the portal animation installs (and then undoes with `restoreLayer()`)
/// so it can generate D+1 chunks while the committed world is still sitting at D.
pub fn installLayer(t: LayerTransition) void {
    // Both are the contract every reader downstream assumes: `max_possible_suffix` IS the depth's edge
    // (`chunk.rasterizeLayer()` and the debug teleport bound themselves with it), and the player's chunk
    // is the origin every other coordinate is walked from.
    std.debug.assert(t.max_possible_suffix == getMaxSuffixAtDepth(t.depth));
    std.debug.assert(isInWorld(.{ .suffix = t.player_chunk, .quadrant = t.player_quadrant }, t.depth));

    memory.game.depth = t.depth;
    memory.game.player_chunk = t.player_chunk;
    memory.game.player_quadrant = t.player_quadrant;
    max_possible_suffix = t.max_possible_suffix;
    if (!t.rebase) return;

    quad_cache.path_hashes = t.path_hashes;
    quad_cache.most_top = t.most_top;
    quad_cache.most_bottom = t.most_bottom;
    quad_cache.most_left = t.most_left;
    quad_cache.most_right = t.most_right;

    const ring: usize = @intCast(t.depth % QuadCache.HISTORY_LEN);
    quad_cache.origins_x[ring] = @intCast(t.left_cell);
    quad_cache.origins_y[ring] = @intCast(t.top_cell);
    quad_cache.historical_seeds[ring] = t.path_hashes;
    writeRebasePath(t.depth, t.left_cell, t.top_cell);

    if (t.has_materials) {
        quad_cache.ancestor_materials = t.ancestor_materials;
        // Only a first descent into this depth derives a trace. An ascent and a retrace READ the depth's
        // window back (`QuadCache.getMaterials()`), so the slot already holds the trace that produced it
        // and rewriting it would replace the depth's authoritative record with one that was never built.
        if (t.horizon_trace) |trace| writeMaterialsPath(t.depth, trace);
    }
}

/// Applies a transition for real: drops the world's caches and loose items, moves the player, and installs it.
///
/// `keep_ancestors` retains the `AncestorCache` across the change.
/// A portal descent has just spent its whole length generating D+1 chunks,
/// which filled that cache with the very D parents the new depth needs,
/// and tiered them relative to D+1 already (the preview installs that depth while it generates).
pub fn commitLayer(t: LayerTransition, keep_ancestors: bool) void {
    // prevent menu interactions (such as obtaining chest items deleting the chest) from corrupting
    dw.indicators.closeAllMenus();

    if (keep_ancestors) clearCaches(false) else clearCaches(true);
    dw.inventory.dropped_items.clear(null);
    memory.game.teleport(null, t.new_pos); // make sure to teleport!
    installLayer(t);

    // (increase max depth reached: the depth just left is now frozen for its descendants):
    // later edits go to legacy_store
    if (t.depth > memory.game.max_depth_reached) memory.game.max_depth_reached = t.depth;
}

/// Increases the game's depth by 1, invalidates caches, moves the player, and handles data modification.
/// `coord` is the chunk the portal is in or where the depth should take place.
/// `bx` and `by` represent the specific block within a chunk the zoom should be in.
pub fn pushLayer(coord: Coordinate, bx: u4, by: u4) void {
    commitLayer(computeLayer(coord, bx, by, .player), false);
}

/// Reseeds the four quadrants for `depth` from its parent's seeds and the rebase origin it landed on.
///
/// A pure function of `(parent, depth, left_cell, top_cell)`, which is what lets `replayQuadrantSeeds()`
/// rebuild any depth's seeds from the recorded origin path instead of from `quad_cache.historical_seeds`,
/// whose ring aliases once an ascent runs deeper than `HISTORY_LEN`.
fn stepQuadrantSeeds(parent: ChunkSeeds, depth: u64, left_cell: u64, top_cell: u64) ChunkSeeds {
    var next: ChunkSeeds = undefined;
    inline for (0..4) |q_id| {
        // Cell this quadrant covers, 0 to 7 per axis (see computeLayer step 3 for what a cell is).
        const cell_x = left_cell + utils.intFromBool(u64, q_id % 2 == 1);
        const cell_y = top_cell + utils.intFromBool(u64, q_id >= 2);
        // Which of the parent's two quadrant columns and rows that cell came out of.
        const old_q_id = utils.intFromBool(usize, cell_x >= ZOOM_FACTOR) + utils.intFromBool(usize, cell_y >= ZOOM_FACTOR) * 2;
        next.value[q_id] = seeding.mixCoordinateSeed(
            parent.value[old_q_id],
            @intCast(cell_x % ZOOM_FACTOR),
            @intCast(cell_y % ZOOM_FACTOR),
            depth,
        );
    }
    return next;
}

/// The rebase state at `depth`, rebuilt from the recorded origin path rather than read back from the rolling buffers.
///
/// Both fields here are accumulations down the path: the seeds chain through `stepQuadrantSeeds()`,
/// and the edge flags are `and`-folds.
const RebaseState = struct {
    hashes: ChunkSeeds,
    edges: QuadrantEdgeDetails,
};

/// Replays the recorded rebase path down to `depth`. Asserts `depth > HORIZON_DEPTH`.
fn replayRebaseState(depth: u64) RebaseState {
    std.debug.assert(depth > dw.HORIZON_DEPTH);
    // Last cell the window's top-left corner can sit on. Same value as in computeLayer step 3.
    const max_origin_cell = ZOOM_FACTOR * 2 - 2;

    var state: RebaseState = .{
        .hashes = .{ .value = @splat(memory.game.seed) },
        .edges = .{ .most_top = true, .most_bottom = true, .most_left = true, .most_right = true },
    };

    var d: u64 = dw.HORIZON_DEPTH + 1;
    while (d <= depth) : (d += 1) {
        const left_cell = quad_cache.getOriginX(d);
        const top_cell = quad_cache.getOriginY(d);
        state.hashes = stepQuadrantSeeds(state.hashes, d, left_cell, top_cell);
        state.edges.most_left = state.edges.most_left and left_cell == 0;
        state.edges.most_right = state.edges.most_right and left_cell == max_origin_cell;
        state.edges.most_top = state.edges.most_top and top_cell == 0;
        state.edges.most_bottom = state.edges.most_bottom and top_cell == max_origin_cell;
    }
    return state;
}

/// Where a player stands inside block (`bx`, `by`) of a chunk: horizontally centered, standing on the floor!
pub fn blockStandPos(bx: u4, by: u4) Vec2i {
    return .{
        @as(i64, bx) * CHUNK_SIZE_SQ + @divExact(CHUNK_SIZE_SQ, 2),
        (@as(i64, by) + 1) * CHUNK_SIZE_SQ - PLAYER_FEET_OFFSET - 1, // - 1 or else there's a permanent collision with the ground
    };
}

/// Snaps a landing onto the block it falls in, using `blockStandPos()`.
///
/// An ascent scales the player's POINT down but not the player.
/// A raw scaled point puts the feet part-way up a cell and the head in the cell ABOVE it,
/// so the landing reads as blocked by a cell the player never came up through.
/// The player is under one block tall, so one cell always has room for the whole hitbox.
pub fn snapToBlock(pos: Vec2i) Vec2i {
    return blockStandPos(
        @intCast(@divFloor(pos[0], CHUNK_SIZE_SQ)),
        @intCast(@divFloor(pos[1], CHUNK_SIZE_SQ)),
    );
}

/// Works out the D to D-1 transition that carries the point `pos` inside chunk `coord` up a layer.
///
/// The straight scale-down: a child chunk covers `SUBPIXELS_IN_CHUNK / ZOOM_FACTOR` of its parent,
/// and the point keeps its place inside that.
///
/// Everything else the new depth needs is read back rather than derived
/// Leaves no lasting change behind, exactly like `computeLayer()`; apply it with `applyAscent()`.
pub fn computeParentLayer(coord: Coordinate, pos: Vec2i) LayerTransition {
    const g = &memory.game;
    const depth = g.depth - 1;
    // The base layer is generated rather than inherited, so it has no parent to ascend into.
    std.debug.assert(depth >= STARTING_ZOOM_TIMES);
    std.debug.assert(pos[0] >= 0 and pos[0] < dw.SUBPIXELS_IN_CHUNK);
    std.debug.assert(pos[1] >= 0 and pos[1] < dw.SUBPIXELS_IN_CHUNK);

    const child_key = coord.asDepthCoordinate(g.depth);
    const parent_coord = child_key.getParent().asCoord();

    // Which of the parent's ZOOM_FACTOR-by-ZOOM_FACTOR child chunks this one is.
    const cell_x: i64 = @intCast(child_key.suffix[0] & (ZOOM_FACTOR - 1));
    const cell_y: i64 = @intCast(child_key.suffix[1] & (ZOOM_FACTOR - 1));

    // Subpixels one child chunk covers inside its parent. The scaled point cannot leave the parent chunk:
    // cell is at most ZOOM_FACTOR - 1 and pos / ZOOM_FACTOR stays under one span.
    const child_span: i64 = @divExact(@as(i64, dw.SUBPIXELS_IN_CHUNK), ZOOM_FACTOR);
    const scaled: Vec2i = .{
        cell_x * child_span + @divFloor(pos[0], ZOOM_FACTOR),
        cell_y * child_span + @divFloor(pos[1], ZOOM_FACTOR),
    };
    // The player keeps its size across the change while a block gets 4x bigger,
    // so the landing sits in the block the scaled point falls in (see `snapToBlock()`).
    const new_pos = snapToBlock(scaled);

    var t: LayerTransition = .{
        .depth = depth,
        .new_pos = new_pos,
        .player_chunk = parent_coord.suffix,
        .player_quadrant = parent_coord.quadrant,
        .max_possible_suffix = getMaxSuffixAtDepth(depth),
    };

    if (depth <= HORIZON_DEPTH) return t;

    t.rebase = true;
    t.left_cell = quad_cache.getOriginX(depth);
    t.top_cell = quad_cache.getOriginY(depth);

    const state = replayRebaseState(depth);
    t.path_hashes = state.hashes;
    t.most_top = state.edges.most_top;
    t.most_bottom = state.edges.most_bottom;
    t.most_left = state.edges.most_left;
    t.most_right = state.edges.most_right;

    // Rebuilt from the recorded traces rather than recomputed, so `horizon_trace` stays null:
    // this depth's trace was fixed by the descent that first reached it (see `LayerTransition`).
    t.has_materials = quad_cache.getMaterials(depth, &t.ancestor_materials);
    return t;
}

/// Decreases the game's depth by 1, moving the player into the block they were standing in.
///
/// Records the step on `ascent_stack`, which pins the block a later descent has to retrace.
pub fn popLayer() void {
    const g = &memory.game;
    // apply instantly
    applyAscent(computeParentLayer(g.getPlayerCoord(), g.player_pos), g.getPlayerCoord(), g.player_pos);
    // `commitLayer()` emptied the SimBuffer, so refill it around where the player landed before anything
    // reads it. Matches `retraceInstant()`; without it the world is momentarily absent, and an absent
    // chunk reads as solid to collision (see `getBlockPtr()`).
    SimBuffer.sync(g.getPlayerCoord());
}

/// Commits an already-computed ascent transition: rolls the deeper depth's modifications up into markers,
/// records the retrace step, and installs D-1. Shared by the instant `popLayer()` and the portal animation's commit,
/// so both leave the exact same state behind.
///
/// `origin_coord`/`origin_pos` are where at the DEEPER depth a later return should put the player:
/// the portal block they rose through.
///
/// Asserts `t.depth == game.depth - 1` (the world is still at the depth being left).
pub fn applyAscent(t: LayerTransition, origin_coord: Coordinate, origin_pos: Vec2i) void {
    std.debug.assert(t.depth == memory.game.depth - 1);

    ascent_stack.append(memory.main_allocator, .{
        .suffix = origin_coord.suffix,
        .quadrant = origin_coord.quadrant,
        .origin_pos = origin_pos,
    }) catch memory.oom();

    commitLayer(t, false);
}

/// Works out the D to D+1 transition that walks one recorded ascent back.
///
/// The exact mirror of `computeParentLayer()`: every field is READ BACK rather than recomputed.
/// The depth's coordinate frame was fixed by the descent that first reached it, and a return must not disturb it,
/// so the rebase origins come from `left_path`/`top_path`, the seeds from replaying those,
/// and the horizon window from `materials_path`. Nothing here depends on where the player wandered,
/// which is what lets the step record a landing spot rather than a block to re-enter.
pub fn computeRetraceLayer(step: AscentStep) LayerTransition {
    const depth = memory.game.depth + 1;
    var t: LayerTransition = .{
        .depth = depth,
        .new_pos = step.origin_pos,
        .player_chunk = step.suffix,
        .player_quadrant = step.quadrant,
        .max_possible_suffix = getMaxSuffixAtDepth(depth),
    };

    if (depth <= HORIZON_DEPTH) return t;

    t.rebase = true;
    t.left_cell = quad_cache.getOriginX(depth);
    t.top_cell = quad_cache.getOriginY(depth);

    const state = replayRebaseState(depth);
    t.path_hashes = state.hashes;
    t.most_top = state.edges.most_top;
    t.most_bottom = state.edges.most_bottom;
    t.most_left = state.edges.most_left;
    t.most_right = state.edges.most_right;

    t.has_materials = quad_cache.getMaterials(depth, &t.ancestor_materials);
    return t;
}

/// Instantly descends back through the block the player last ascended past, popping the ascent stack.
/// The only descent allowed from depths shallower than the frontier (see `canRetrace()`).
///
/// The block picks the depth's coordinate frame AND the landing spot,
/// so a return lands on the portal that the ascent went up through.
/// Still shallower than the frontier afterwards if more steps remain.
pub fn retraceInstant() void {
    // No preview warmed the ancestor cache here (unlike the animated return),
    // and its entries are tiered relative to the old depth, so they must be dropped rather than kept.
    commitLayer(computeRetraceLayer(retraceStep().?), false);
    popAscentStep();
    SimBuffer.sync(memory.game.getPlayerCoord());
}

/// Commits an already-computed return transition, popping the ascent stack.
/// Allows for animation.
pub fn commitRetrace(t: LayerTransition) void {
    commitLayer(t, true);
    popAscentStep();
}

/// Works out the D to D+1 transition without leaving any lasting change behind.
/// `coord` is the chunk that holds the block being descended into,
/// and (`bx`, `by`) is that block inside it.
///
/// Past `HORIZON_DEPTH` the rebase math reads the very globals it derives:
/// the quadrant seeds, the rebase origins, and the ancestor grid.
/// So this installs the in-progress state while it works, and puts it back before it returns.
/// Callers see no change; apply the result with `commitLayer()` or `installLayer()`.
pub fn computeLayer(coord: Coordinate, bx: u4, by: u4, anchor: LayerAnchor) LayerTransition {
    const new_depth = memory.game.depth + 1;
    const snapshot = snapshotLayer(new_depth);
    defer restoreLayer(snapshot); // neat use of Zig semantics!

    // A point keeps its place in the world, so its subpixel offset inside a chunk grows ZOOM_FACTOR times!
    const scale_vec: Vec2i = .{ ZOOM_FACTOR, ZOOM_FACTOR };

    // The world scales but the player does not. player_pos is the player's CENTER,
    // while the point that must stay on the same surface is the FEET (PLAYER_FEET_OFFSET below the center).
    // Scaled feet are ZOOM_FACTOR * (center + offset), so the new center is
    // ZOOM_FACTOR * center + (ZOOM_FACTOR - 1) * offset. That second term is the pivot: 384 subpixels.
    // Without it the player lands 1.5 blocks too high and falls.
    const pivot_y: i64 = (ZOOM_FACTOR - 1) * PLAYER_FEET_OFFSET;

    var new_pos: Vec2i = undefined;
    var chunk_offset: Vec2i = .{ 0, 0 }; // whole-chunk shift, when the pivot pushes past the chunk edge

    switch (anchor) {
        .player => {
            // Scale the player position and keep only the part inside one chunk. The whole chunks it
            // crossed are already accounted for by the suffix bits taken from bx and by further below.
            new_pos = @mod(memory.game.player_pos * scale_vec, @as(Vec2i, @splat(dw.SUBPIXELS_IN_CHUNK))) + Vec2i{ 0, pivot_y };
            // The pivot can push the player out of the bottom of the chunk. Move them a chunk down.
            if (new_pos[1] >= dw.SUBPIXELS_IN_CHUNK) {
                new_pos[1] -= dw.SUBPIXELS_IN_CHUNK;
                chunk_offset[1] = 1;
            }
        },
        .block_floor => {
            // The block becomes a ZOOM_FACTOR by ZOOM_FACTOR region of blocks in the child chunk.
            // The low bits of bx and by pick that region, and the high bits pick the child chunk
            // itself further below, so the two agree wherever the player was standing.
            const region: i64 = dw.CHUNK_SIZE_SQ * ZOOM_FACTOR; // subpixels the region spans per axis
            const cell_x: i64 = @intCast(bx % ZOOM_FACTOR);
            const cell_y: i64 = @intCast(by % ZOOM_FACTOR);
            new_pos = .{
                cell_x * region + @divExact(region, 2), // horizontally centered
                // Feet on the region's floor. The - 1 keeps them out of the floor block itself.
                (cell_y + 1) * region - PLAYER_FEET_OFFSET - 1,
            };
        },
    }

    var t: LayerTransition = .{
        .depth = new_depth,
        .new_pos = new_pos,
        .player_chunk = memory.game.player_chunk,
        .player_quadrant = @intCast(memory.game.player_quadrant),
        .max_possible_suffix = max_possible_suffix,
    };

    // The coordinate helpers below resolve quadrants against the depth being entered, not the one being left.
    memory.game.depth = new_depth;

    // The suffix of the chunk the player lands in. One depth step multiplies every chunk address by
    // ZOOM_FACTOR, which is a ZOOM_LOG2-bit left shift of the suffix. The freed low bits name which
    // of the ZOOM_FACTOR child chunks holds the block: a chunk is CHUNK_SIZE blocks wide and each
    // child covers CHUNK_SIZE / ZOOM_FACTOR of them, so bx >> (CHUNK_SIZE_LOG2 - ZOOM_LOG2) is it.
    const landing_suffix: Vec2u = .{
        (coord.suffix[0] *% ZOOM_FACTOR) | (bx >> (CHUNK_SIZE_LOG2 - dw.ZOOM_LOG2)),
        (coord.suffix[1] *% ZOOM_FACTOR) | (by >> (CHUNK_SIZE_LOG2 - dw.ZOOM_LOG2)),
    };

    if (new_depth <= HORIZON_DEPTH) {
        // Before the horizon the suffix still has room for the new path step, so nothing falls off
        // the top and there is no rebase. The quadrant is always 0 here.
        var landing: Coordinate = .{
            .suffix = landing_suffix,
            .quadrant = @intCast(memory.game.player_quadrant),
        };
        if (chunk_offset[1] != 0) {
            landing = landing.moveAtDepth(chunk_offset, new_depth) orelse landing;
        }

        t.player_chunk = landing.suffix;
        t.player_quadrant = landing.quadrant;

        // Stops growing at depth 32, where a suffix is a full 64 bits.
        t.max_possible_suffix = getMaxSuffixAtDepth(new_depth);
        return t;
    }

    // Past the horizon the suffix is full, so a descent must REBASE.
    // Two words, used for the rest of this walk:
    //
    //   cell    one suffix worth of chunks, 2^64 wide. The address space at D+1 is 8 cells per axis:
    //           ZOOM_FACTOR child cells for each of the 2 quadrant columns at D.
    //   window  the 2 by 2 cells that the four quadrants at D+1 can name. left_cell and top_cell
    //           name its top-left cell, so each of them runs from 0 to 6.
    //
    // A chunk address at D is quadrant_x * 2^64 + suffix_x, which needs 65 bits. Zooming multiplies
    // it by ZOOM_FACTOR and adds the child index, which needs 67: two more than the window can name.
    // The rebase is the choice of WHICH 2 of the 8 cells to keep. That 3-bit choice per axis is what
    // goes into the prefix stack, and it replaces the top path step the suffix just lost.
    t.rebase = true;

    // Bit position of the suffix's top path step: HORIZON_DEPTH steps of ZOOM_LOG2 bits, minus the
    // one step being read. 32 * 2 - 2 = 62.
    const top_step_shift = dw.HORIZON_DEPTH * dw.ZOOM_LOG2 - dw.ZOOM_LOG2;
    const cell_offset_mask = (@as(u64, 1) << top_step_shift) - 1; // the bits under the top step

    // Step 1: which of the 8 cells the landing chunk falls in.
    // The quadrant picks one group of ZOOM_FACTOR cells, and the top path step picks one inside it.
    const parent_quadrant_x = utils.intFromBool(u64, (memory.game.player_quadrant % 2) != 0);
    const parent_quadrant_y = utils.intFromBool(u64, (memory.game.player_quadrant / 2) != 0);
    const landing_cell_x = parent_quadrant_x * ZOOM_FACTOR + (coord.suffix[0] >> top_step_shift);
    const landing_cell_y = parent_quadrant_y * ZOOM_FACTOR + (coord.suffix[1] >> top_step_shift);

    // Step 2: which half of that cell it falls in. Everything scales by the same ZOOM_FACTOR, so the
    // parent's own low suffix bits answer this before the zoom.
    const half_cell: u64 = 1 << (top_step_shift - 1);
    const in_left_half = (coord.suffix[0] & cell_offset_mask) < half_cell;
    const in_top_half = (coord.suffix[1] & cell_offset_mask) < half_cell;

    // Step 3: place the window so the landing chunk sits near its center. Take the cell to the left
    // when the chunk is in the left half of its own cell, and the cell above when it is in the top
    // half. The chunk then ends up within half a cell of the window center, which leaves at least
    // 2^63 chunks of travel in every direction before an address runs out.
    // The saturating subtract and the clamp hold the window inside the 8 cells. They only fire at
    // the edge of the address space, where the neighbor cell to take does not exist.
    const max_origin_cell = ZOOM_FACTOR * 2 - 2; // 8 cells per axis, and the window is 2 of them
    var left_cell_x: u64 = landing_cell_x -| utils.intFromBool(u64, in_left_half);
    var top_cell_y: u64 = landing_cell_y -| utils.intFromBool(u64, in_top_half);
    left_cell_x = @min(left_cell_x, max_origin_cell);
    top_cell_y = @min(top_cell_y, max_origin_cell);

    // Step 4: world edges. The window still touches the left edge of the world only if EVERY rebase
    // so far kept it against cell 0, so these are and-folds down the whole descent path.
    quad_cache.most_left = quad_cache.most_left and left_cell_x == 0;
    quad_cache.most_right = quad_cache.most_right and left_cell_x == max_origin_cell;
    quad_cache.most_top = quad_cache.most_top and top_cell_y == 0;
    quad_cache.most_bottom = quad_cache.most_bottom and top_cell_y == max_origin_cell;
    t.most_left = quad_cache.most_left;
    t.most_right = quad_cache.most_right;
    t.most_top = quad_cache.most_top;
    t.most_bottom = quad_cache.most_bottom;
    t.left_cell = left_cell_x;
    t.top_cell = top_cell_y;

    // Step 5: reseed the four quadrants from the four they descend from. A new quadrant is named by
    // its absolute cell, so its seed does not depend on the route taken here (see stepQuadrantSeeds).
    // The first rebase depth has no rebased parent, so it starts from the world seed.
    const old_hashes: ChunkSeeds = if (new_depth == HORIZON_DEPTH + 1) .{ .value = @splat(memory.game.seed) } else quad_cache.path_hashes;
    quad_cache.path_hashes = stepQuadrantSeeds(old_hashes, new_depth, left_cell_x, top_cell_y);

    t.path_hashes = quad_cache.path_hashes;

    // Step 6: record the window origin. The prefix stack keeps it forever, and the rolling buffers
    // answer for the depths that are still live (see QuadCache.getOriginX).
    writeRebasePath(new_depth, left_cell_x, top_cell_y);
    quad_cache.origins_x[@intCast(new_depth % QuadCache.HISTORY_LEN)] = @intCast(left_cell_x);
    quad_cache.origins_y[@intCast(new_depth % QuadCache.HISTORY_LEN)] = @intCast(top_cell_y);
    quad_cache.historical_seeds[@intCast(new_depth % QuadCache.HISTORY_LEN)] = quad_cache.path_hashes;

    // Step 7: the landing chunk. Its quadrant is where it fell inside the window, 0 or 1 per axis.
    // Its suffix is the one built above, whose lost top step is exactly what step 1 read out.
    const window_x = landing_cell_x - left_cell_x;
    const window_y = landing_cell_y - top_cell_y;
    var landing: Coordinate = .{
        .suffix = landing_suffix,
        .quadrant = @intCast(window_x + (window_y * 2)),
    };
    if (chunk_offset[1] != 0) {
        landing = landing.moveAtDepth(chunk_offset, new_depth) orelse landing;
    }

    // Installed, and not only recorded: the horizon window below reads the entered quadrant and suffix.
    memory.game.player_chunk = landing.suffix;
    memory.game.player_quadrant = landing.quadrant;
    max_possible_suffix = std.math.maxInt(u64); // every suffix bit is addressable past the horizon
    t.player_chunk = landing.suffix;
    t.player_quadrant = landing.quadrant;
    t.max_possible_suffix = max_possible_suffix;

    // Step 8: the horizon. H sits HORIZON_DEPTH shallower than the depth being entered, so it moved
    // one depth deeper too, and its window is one refinement step from the window before it.
    const depth_at_horizon = new_depth - dw.HORIZON_DEPTH;
    if (depth_at_horizon >= STARTING_ZOOM_TIMES) {
        const trace = traceHorizon(landing, new_pos, new_depth, @intCast(coord.quadrant));
        t.horizon_trace = trace;
        t.ancestor_materials = refineHorizonWindow(
            &quad_cache.ancestor_materials,
            trace,
            depth_at_horizon,
        );
        t.has_materials = true;
    }

    return t;
}

/// Walks a transition's landing up to the horizon, producing the trace its window is centered on.
///
/// Asserts `memory.game.depth == depth`, since `getParent()` resolves quadrants against it.
fn traceHorizon(landing_coord: Coordinate, new_pos: Vec2i, depth: u64, source_quadrant: u2) HorizonTrace {
    std.debug.assert(memory.game.depth == depth);

    // Walk HORIZON_DEPTH parents up, block by block, to the exact block at H the landing came out of.
    var trace_coord = landing_coord.asDepthCoordinate(depth);
    var t_bx: u4 = @intCast(@divTrunc(new_pos[0], dw.CHUNK_SIZE_SQ));
    var t_by: u4 = @intCast(@divTrunc(new_pos[1], dw.CHUNK_SIZE_SQ));

    var i: u32 = 0;
    while (i < HORIZON_DEPTH) : (i += 1) {
        const p = dw.ancestor.getParentInfo(trace_coord, t_bx, t_by);
        trace_coord = p.coord.asDepthCoordinate(trace_coord.depth - 1);
        t_bx = p.bx;
        t_by = p.by;
    }

    return .{
        .suffix = trace_coord.suffix,
        .quadrant = @intCast(trace_coord.quadrant),
        .bx = t_bx,
        .by = t_by,
        .player_quadrant = landing_coord.quadrant,
        .source_quadrant = source_quadrant,
    };
}

/// Refines the horizon window one depth: `prev` is the window at `target_horizon_depth - 1`,
/// and the returned window is the one at `target_horizon_depth`.
///
/// Reads only `prev`, `trace` and the procedural world, never `quad_cache.ancestor_materials`.
/// That independence is the whole point: it is what lets `QuadCache.getMaterials()` rebuild a window that was
/// never stored, by feeding this its own previous output (pinned by a test).
///
/// Installs `depth - 1` while it works and puts the game depth back before returning.
fn refineHorizonWindow(prev: *const HorizonWindow, trace: HorizonTrace, target_horizon_depth: u64) HorizonWindow {
    const depth = target_horizon_depth + HORIZON_DEPTH;
    var next: HorizonWindow = undefined;

    const trace_coord: DepthCoordinate = .{
        .suffix = trace.suffix,
        .quadrant = trace.quadrant,
        .depth = target_horizon_depth,
    };
    const t_bx = trace.bx;
    const t_by = trace.by;

    // Temporarily restore the old depth so parent coordinate lookups at depth D-33 (which are below the new horizon but were the active horizon at depth D-1)
    // to correctly resolve quadrant IDs relative to the old threshold D-33, aligning perfectly with the previous window!
    const saved_depth = memory.game.depth;
    memory.game.depth = depth - 1;
    defer memory.game.depth = saved_depth;

    var old_trace_coord = trace_coord;
    var old_t_bx = t_bx;
    var old_t_by = t_by;
    if (target_horizon_depth > STARTING_ZOOM_TIMES) {
        const pp = dw.ancestor.getParentInfo(trace_coord, t_bx, t_by);
        old_trace_coord = pp.coord.asDepthCoordinate(old_trace_coord.depth - 1);
        old_t_bx = pp.bx;
        old_t_by = pp.by;
    }

    const qx: i32 = @intCast(trace.player_quadrant % 2);
    const qy: i32 = @intCast(trace.player_quadrant / 2);
    const shift_amt: u7 = if (old_trace_coord.depth >= dw.HORIZON_DEPTH) dw.HORIZON_DEPTH * dw.ZOOM_LOG2 else @intCast(old_trace_coord.depth * dw.ZOOM_LOG2);
    const old_qx = @as(i128, old_trace_coord.quadrant % 2);
    const old_qy = @as(i128, old_trace_coord.quadrant / 2);

    for (0..QuadCache.ANCESTOR_GRID) |y_idx| {
        for (0..QuadCache.ANCESTOR_GRID) |x_idx| {
            const delta_bx: i32 = @as(i32, @intCast(x_idx)) - QuadCache.ANCESTOR_CENTER - qx;
            const delta_by: i32 = @as(i32, @intCast(y_idx)) - QuadCache.ANCESTOR_CENTER - qy;
            const absolute_bx: i32 = @as(i32, @intCast(t_bx)) + delta_bx;
            const absolute_by: i32 = @as(i32, @intCast(t_by)) + delta_by;
            const chunk_dx = @divFloor(absolute_bx, 16);
            const chunk_dy = @divFloor(absolute_by, 16);
            const local_bx: u4 = @intCast(@mod(absolute_bx, 16));
            const local_by: u4 = @intCast(@mod(absolute_by, 16));

            if (trace_coord.asCoord().moveAtDepth(.{ chunk_dx, chunk_dy }, target_horizon_depth)) |nc| {
                const child_key = nc.asDepthCoordinate(target_horizon_depth);
                if (target_horizon_depth == STARTING_ZOOM_TIMES) {
                    // the base window is generated outright, so prev is not read at all here:
                    // that is what gives a replay somewhere to start from.
                    next[y_idx][x_idx] = dw.ancestor.getInheritedMaterial(child_key, local_bx, local_by);
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

                    var p_neighbors: [8]Block align(8) = @splat(.empty);

                    const px_idx = diff_chunk_x * 16 + @as(i64, p.bx) - @as(i64, old_t_bx) + QuadCache.ANCESTOR_CENTER + @as(i64, trace.source_quadrant % 2);
                    const py_idx = diff_chunk_y * 16 + @as(i64, p.by) - @as(i64, old_t_by) + QuadCache.ANCESTOR_CENTER + @as(i64, trace.source_quadrant / 2);

                    // The window is a WINDOW onto a larger world, not an island in a void, so anything off its edge
                    // is edge-extended rather than read as air.
                    const grid_max = prev.len - 1;

                    // A cell's parent sits at most `ANCESTOR_GRID / 2 / BLOCKS_PER_PARENT` blocks from the window's
                    // center, so every lookup here (and its 3x3 ring) lands well inside the window.
                    // Leaving it means the lineage itself is wrong, and the clamp below would then quietly fill the
                    // whole layer from one edge cell: a dead, uniform world with nothing to point at.
                    // Asserted rather than trusted, because that failure has no other symptom.
                    std.debug.assert(px_idx >= 1 and px_idx < @as(i64, @intCast(grid_max)));
                    std.debug.assert(py_idx >= 1 and py_idx < @as(i64, @intCast(grid_max)));

                    const gx = std.math.clamp(px_idx, 0, @as(i64, @intCast(grid_max)));
                    const gy = std.math.clamp(py_idx, 0, @as(i64, @intCast(grid_max)));
                    const parent_block = prev[@intCast(gy)][@intCast(gx)];

                    // Populate neighbors for applyAncestorLogic() from the previous window
                    var n_idx: usize = 0;
                    var ndy: i32 = -1;
                    while (ndy <= 1) : (ndy += 1) {
                        var ndx: i32 = -1;
                        while (ndx <= 1) : (ndx += 1) {
                            if (ndx == 0 and ndy == 0) continue;
                            const nx = std.math.clamp(px_idx + ndx, 0, @as(i64, @intCast(grid_max)));
                            const ny = std.math.clamp(py_idx + ndy, 0, @as(i64, @intCast(grid_max)));
                            p_neighbors[n_idx] = prev[@intCast(ny)][@intCast(nx)];
                            n_idx += 1;
                        }
                    }

                    // keep tracing the materials back...
                    next[y_idx][x_idx] = dw.ancestor.applyAncestorLogic(
                        parent_block,
                        p_neighbors,
                        child_key,
                        local_bx,
                        local_by,
                    ).compile();
                }

                // the traces above are purely procedural, so the player's edit at this exact cell (if any) wins
                const block_idx: u8 = @intCast((@as(usize, local_by) << 4) | local_bx);
                // `inheritedCell()`, as in `ancestor.getInheritedMaterial()`: this trace feeds deeper depths.
                if (inheritedCell(child_key, block_idx)) |cell| {
                    cell.applyTo(&next[y_idx][x_idx]);
                }
                // forced world edge
            } else next[y_idx][x_idx] = world_edge_block;
        }
    }
    return next;
}

const testing = std.testing;

test "moveAtDepth: the world ends at the outer quadrants rather than wrapping" {
    const depth = HORIZON_DEPTH + 1; // past the horizon, where the quadrant IS the top coordinate bit
    const max = std.math.maxInt(u64);

    // Crossing INWARD flips into the neighboring quadrant, which is the whole reason the bit exists.
    const inward = (Coordinate{ .suffix = .{ max, 0 }, .quadrant = 0 }).moveAtDepth(.{ 1, 0 }, depth).?;
    try testing.expectEqual(@as(u2, 1), inward.quadrant);
    try testing.expectEqual(@as(u64, 0), inward.suffix[0]);

    // Crossing OUTWARD leaves the world: flipping the bit anyway would wrap edge to edge and hand back
    // a coordinate 2^64 chunks away, which `refineHorizonWindow()` reads as an enormous parent delta.
    try testing.expectEqual(
        @as(?Coordinate, null),
        (Coordinate{ .suffix = .{ max, 0 }, .quadrant = 1 }).moveAtDepth(.{ 1, 0 }, depth),
    );
    try testing.expectEqual(
        @as(?Coordinate, null),
        (Coordinate{ .suffix = .{ 0, 0 }, .quadrant = 0 }).moveAtDepth(.{ -1, 0 }, depth),
    );

    // The Y axis answers on its own bit, so a bottom-right chunk cannot fall out of the world's floor.
    try testing.expectEqual(
        @as(?Coordinate, null),
        (Coordinate{ .suffix = .{ 0, max }, .quadrant = 3 }).moveAtDepth(.{ 0, 1 }, depth),
    );
    try testing.expectEqual(
        @as(?Coordinate, null),
        (Coordinate{ .suffix = .{ 0, 0 }, .quadrant = 1 }).moveAtDepth(.{ 0, -1 }, depth),
    );
}

test "chunk cache: no two chunks of one render window can share a slot" {
    // The property the tile exists for. A window that outgrows the tile does not merely run a little
    // colder: the renderer rescans the same rectangle every frame, so a colliding pair regenerates
    // BOTH chunks every frame, for as long as the camera holds still.
    var seen = std.AutoHashMap(usize, Coordinate).init(testing.allocator);
    defer seen.deinit();

    // A corner start, so the window straddles a quadrant edge in both axes as well as a tile edge.
    const base: u64 = std.math.maxInt(u64) - CHUNK_WINDOW.w / 2;
    for (0..CHUNK_WINDOW.h) |gy| {
        for (0..CHUNK_WINDOW.w) |gx| {
            const coord: Coordinate = .{
                .suffix = .{ base +% gx, base +% gy },
                .quadrant = 0,
            };
            const slot = ChunkCache.slotOf(coord);
            if (try seen.fetchPut(slot, coord)) |clash| {
                std.debug.print("slot {d}: ({d},{d}) collides with ({d},{d})\n", .{
                    slot,                  coord.suffix[0],
                    coord.suffix[1],       clash.value.suffix[0],
                    clash.value.suffix[1],
                });
                return error.WindowChunksShareASlot;
            }
        }
    }
}

test "the horizon window can hold every block a chunk's generation asks of it" {
    const per_chunk_window = 6;
    const neighbor_shift = dw.BLOCKS_PER_PARENT; // one chunk over at H+1 is this many blocks at H
    const needed = per_chunk_window + 2 * neighbor_shift;
    try testing.expect(QuadCache.ANCESTOR_GRID >= needed);

    // The active 2x2 has to sit centered, with the same room on both sides.
    try testing.expectEqual(
        QuadCache.ANCESTOR_CENTER,
        QuadCache.ANCESTOR_GRID - (QuadCache.ANCESTOR_CENTER + 2),
    );
}

test "computeLayer: works out a transition without disturbing the live world" {
    const saved_game = memory.game;
    const saved_suffix = max_possible_suffix;
    defer {
        memory.game = saved_game;
        memory.deriveHashSeeds();
        max_possible_suffix = saved_suffix;
    }

    memory.game = .{};
    memory.game.depth = 4; // comfortably below HORIZON_DEPTH, so no rebase is involved
    memory.game.player_chunk = .{ 3, 5 };
    memory.game.player_pos = .{ 1000, 2000 };
    max_possible_suffix = getMaxSuffixAtDepth(memory.game.depth);
    quad_cache.path_hashes.value[0] = memory.game.seed;

    const before = memory.game;
    const before_suffix = max_possible_suffix;
    const before_path_len = quad_cache.left_path.len;

    const t = computeLayer(memory.game.getPlayerCoord(), 2, 7, .player);

    try testing.expectEqual(before.depth, memory.game.depth);
    try testing.expectEqual(before.player_chunk, memory.game.player_chunk);
    try testing.expectEqual(before.player_quadrant, memory.game.player_quadrant);
    try testing.expectEqual(before.player_pos, memory.game.player_pos);
    try testing.expectEqual(before_suffix, max_possible_suffix);
    try testing.expectEqual(before_path_len, quad_cache.left_path.len);
    try testing.expectEqual(before_path_len, quad_cache.top_path.len);

    // The transition itself still describes the depth being entered.
    try testing.expectEqual(before.depth + 1, t.depth);
    try testing.expectEqual(getMaxSuffixAtDepth(before.depth + 1), t.max_possible_suffix);
    // Zooming by ZOOM_FACTOR shifts the suffix left, with the block's top bits filling the low bits.
    try testing.expectEqual(
        @as(u64, 3) * ZOOM_FACTOR + (2 >> (CHUNK_SIZE_LOG2 - dw.ZOOM_LOG2)),
        t.player_chunk[0],
    );
}

test "computeLayer: a block_floor landing leaves the feet clear of the floor" {
    const saved_game = memory.game;
    const saved_suffix = max_possible_suffix;
    defer {
        memory.game = saved_game;
        memory.deriveHashSeeds();
        max_possible_suffix = saved_suffix;
    }

    memory.game = .{};
    memory.game.depth = 4; // below HORIZON_DEPTH, so no rebase is involved
    memory.game.player_chunk = .{ 3, 5 };
    max_possible_suffix = getMaxSuffixAtDepth(memory.game.depth);
    quad_cache.path_hashes.value[0] = memory.game.seed;

    const region: i64 = CHUNK_SIZE_SQ * ZOOM_FACTOR;
    for (0..CHUNK_SIZE) |raw_bx| {
        for (0..CHUNK_SIZE) |raw_by| {
            const bx: u4 = @intCast(raw_bx);
            const by: u4 = @intCast(raw_by);
            const t = computeLayer(memory.game.getPlayerCoord(), bx, by, .block_floor);

            const cell_x: i64 = @intCast(bx % ZOOM_FACTOR);
            const cell_y: i64 = @intCast(by % ZOOM_FACTOR);

            // Horizontally centered in the block's child region.
            try testing.expectEqual(cell_x * region + @divExact(region, 2), t.new_pos[0]);

            // Player inside the region, never on the boundary that belongs to the floor below it.
            const feet = t.new_pos[1] + CHUNK_SIZE_SQ / 2;
            try testing.expect(feet >= cell_y * region);
            try testing.expect(feet < (cell_y + 1) * region);

            // The landing must stay inside the chunk, since `player_pos` is chunk-relative.
            try testing.expect(t.new_pos[1] >= 0 and t.new_pos[1] < dw.SUBPIXELS_IN_CHUNK);
        }
    }
}

test "horizon window: a replay from the base reproduces every stored window" {
    // verify replay chaining works as intended
    const saved_game = memory.game;
    const saved_suffix = max_possible_suffix;
    defer {
        memory.game = saved_game;
        memory.deriveHashSeeds();
        max_possible_suffix = saved_suffix;
    }

    memory.game = .{};
    mod_store.init(testing.allocator);
    defer mod_store.deinit();
    legacy_store.init(testing.allocator);
    defer legacy_store.deinit();

    // A handful of arbitrary but fixed traces, standing in for a descent path.
    const traces = [_]HorizonTrace{
        .{ .suffix = .{ 4, 7 }, .quadrant = 0, .bx = 3, .by = 9, .player_quadrant = 0, .source_quadrant = 0 },
        .{ .suffix = .{ 17, 29 }, .quadrant = 1, .bx = 11, .by = 2, .player_quadrant = 1, .source_quadrant = 0 },
        .{ .suffix = .{ 70, 118 }, .quadrant = 1, .bx = 6, .by = 14, .player_quadrant = 3, .source_quadrant = 1 },
    };

    // Forward pass, exactly as `installLayer()` would accumulate it on the way down.
    var stepwise: [traces.len]HorizonWindow = undefined;
    var running: HorizonWindow = @splat(@splat(world_edge_block));
    for (traces, 0..) |trace, i| {
        const d = QuadCache.MATERIALS_START_DEPTH + i;
        running = refineHorizonWindow(&running, trace, d - HORIZON_DEPTH);
        stepwise[i] = running;
    }

    // Replay pass, exactly as `getMaterials()` rebuilds it: from the base, every time, for each depth.
    for (0..traces.len) |target| {
        var replayed: HorizonWindow = @splat(@splat(world_edge_block));
        for (0..target + 1) |i| {
            const d = QuadCache.MATERIALS_START_DEPTH + i;
            replayed = refineHorizonWindow(&replayed, traces[i], d - HORIZON_DEPTH);
        }
        for (0..QuadCache.ANCESTOR_GRID) |y| {
            for (0..QuadCache.ANCESTOR_GRID) |x| {
                try testing.expectEqual(stepwise[target][y][x], replayed[y][x]);
            }
        }
    }
}

test "horizon trace: only a first descent records one" {
    // `installLayer()` stamps `horizon_trace` into `materials_path`, which is the authoritative record
    // of a depth. An ascent and a retrace REBUILD their window from that record, so if either of them
    // reported a trace it would write one that was never derived, and every depth refined from it would
    // regenerate as void or as fill. Nothing about that failure is visible until the world is entered.
    const ascent: LayerTransition = .{
        .depth = 40,
        .new_pos = .{ 0, 0 },
        .player_chunk = .{ 0, 0 },
        .player_quadrant = 0,
        .max_possible_suffix = 0,
    };
    try testing.expectEqual(@as(?HorizonTrace, null), ascent.horizon_trace);

    // Writing an unset trace must be impossible to express rather than merely avoided by convention,
    // so the field stays optional and `writeMaterialsPath()` keeps taking a plain `HorizonTrace`.
    try testing.expectEqual(HorizonTrace, @typeInfo(@FieldType(LayerTransition, "horizon_trace")).optional.child);
    try testing.expectEqual(HorizonTrace, @typeInfo(@TypeOf(writeMaterialsPath)).@"fn".params[1].type.?);
}

test "horizon window: a checkpointed rebuild matches replaying from the base" {
    // The checkpoints are what keep `getMaterials()` off an O(depth) walk, so they have to be
    // indistinguishable from one. Long enough to cross two stride boundaries, since the first
    // checkpoint is the easy case.
    const saved_game = memory.game;
    const saved_suffix = max_possible_suffix;
    const saved_len = quad_cache.materials_path.len;
    const saved_windows = quad_cache.materials_windows.len;
    const saved_path = quad_cache.left_path.len;
    defer {
        memory.game = saved_game;
        memory.deriveHashSeeds();
        max_possible_suffix = saved_suffix;
        quad_cache.materials_path.len = saved_len;
        quad_cache.materials_windows.len = saved_windows;
        quad_cache.left_path.len = saved_path;
        quad_cache.top_path.len = saved_path;
    }

    memory.game = .{};
    mod_store.init(testing.allocator);
    defer mod_store.deinit();
    legacy_store.init(testing.allocator);
    defer legacy_store.deinit();

    const count = 2 * QuadCache.MATERIALS_CHECKPOINT_STRIDE + 3;
    quad_cache.materials_windows.len = 0;
    quad_cache.materials_path.len = 0;

    // The refinement resolves parent quadrants through the recorded rebase origins, so every depth it
    // touches needs a path slot to read. All-zero origins are as valid a descent as any.
    quad_cache.left_path.len = 0;
    quad_cache.top_path.len = 0;
    while (quad_cache.left_path.len * 21 < QuadCache.MATERIALS_START_DEPTH + count) {
        quad_cache.left_path.append(alloc, 0) catch unreachable;
        quad_cache.top_path.append(alloc, 0) catch unreachable;
    }
    for (0..count) |i| {
        // Arbitrary but fixed, and varied enough that a wrong starting window cannot coincide.
        quad_cache.materials_path.append(alloc, .{
            .suffix = .{ i *% 37 + 4, i *% 61 + 9 },
            .quadrant = @intCast(i % 4),
            .bx = @intCast((i * 5) % 16),
            .by = @intCast((i * 11) % 16),
            .player_quadrant = @intCast((i / 2) % 4),
            .source_quadrant = @intCast((i / 3) % 4),
        }) catch unreachable;
    }

    // Walking depths in order is what actually fills the checkpoints, so later targets read one back
    // rather than replaying, which is the case under test.
    for (0..count) |target| {
        var from_checkpoint: HorizonWindow = undefined;
        try testing.expect(quad_cache.getMaterials(QuadCache.MATERIALS_START_DEPTH + target, &from_checkpoint));

        var from_base: HorizonWindow = @splat(@splat(world_edge_block));
        for (0..target + 1) |i| {
            const d = QuadCache.MATERIALS_START_DEPTH + i;
            from_base = refineHorizonWindow(&from_base, quad_cache.materials_path.at(i).*, d - HORIZON_DEPTH);
        }

        for (0..QuadCache.ANCESTOR_GRID) |y| {
            for (0..QuadCache.ANCESTOR_GRID) |x| {
                try testing.expectEqual(from_base[y][x], from_checkpoint[y][x]);
            }
        }
    }

    // Every stride boundary the walk crossed left a checkpoint behind.
    try testing.expectEqual(
        (count - 1) / QuadCache.MATERIALS_CHECKPOINT_STRIDE + 1,
        quad_cache.materials_windows.len,
    );

    // Rewriting a trace must drop the checkpoints refined through it, and keep the ones below.
    quad_cache.invalidateMaterialsFrom(QuadCache.MATERIALS_CHECKPOINT_STRIDE + 1);
    try testing.expectEqual(@as(usize, 2), quad_cache.materials_windows.len);
    quad_cache.invalidateMaterialsFrom(0);
    try testing.expectEqual(@as(usize, 0), quad_cache.materials_windows.len);
}

test "refineHorizonWindow: leaves the game depth exactly as it found it" {
    // It installs depth - 1 to resolve parent quadrants against the old threshold.
    // A transition computes several of these in a row, so leaking that install would shift every later lookup.
    const saved_game = memory.game;
    defer {
        memory.game = saved_game;
        memory.deriveHashSeeds();
    }

    memory.game = .{};
    mod_store.init(testing.allocator);
    defer mod_store.deinit();
    legacy_store.init(testing.allocator);
    defer legacy_store.deinit();

    memory.game.depth = 61;
    const before = memory.game.depth;
    var grid: HorizonWindow = @splat(@splat(world_edge_block));
    grid = refineHorizonWindow(&grid, .{
        .suffix = .{ 2, 3 },
        .quadrant = 0,
        .bx = 5,
        .by = 5,
        .player_quadrant = 0,
        .source_quadrant = 0,
    }, STARTING_ZOOM_TIMES);
    try testing.expectEqual(before, memory.game.depth);
}

test "computeParentLayer: scales a point into its parent chunk with no pivot" {
    // The transform an ascent is built on. It must be the plain scale-down and nothing else!
    const saved_game = memory.game;
    const saved_suffix = max_possible_suffix;
    defer {
        memory.game = saved_game;
        memory.deriveHashSeeds();
        max_possible_suffix = saved_suffix;
    }

    memory.game = .{};
    const test_depth = @max(11, STARTING_ZOOM_TIMES + 1);
    memory.game.depth = test_depth;
    memory.game.player_chunk = .{ 13, 21 };
    max_possible_suffix = getMaxSuffixAtDepth(memory.game.depth);
    quad_cache.path_hashes.value[0] = memory.game.seed;

    const up = computeParentLayer(memory.game.getPlayerCoord(), .{ 1000, 500 });

    try testing.expectEqual(test_depth - 1, up.depth);
    // Zooming out shifts the suffix right by one cell.
    try testing.expectEqual(@as(Vec2u, .{ 3, 5 }), up.player_chunk);

    // The chunk keeps its place inside the parent: cell * span + pos / ZOOM_FACTOR,
    // then the landing snaps onto the block that point falls in (see `snapToBlock()`).
    const span = @divExact(@as(i64, dw.SUBPIXELS_IN_CHUNK), ZOOM_FACTOR);
    const scaled: Vec2i = .{
        @as(i64, 13 % ZOOM_FACTOR) * span + @divFloor(@as(i64, 1000), ZOOM_FACTOR),
        @as(i64, 21 % ZOOM_FACTOR) * span + @divFloor(@as(i64, 500), ZOOM_FACTOR),
    };
    try testing.expectEqual(snapToBlock(scaled), up.new_pos);
    // The snap must not move the landing out of the block the point was in.
    try testing.expectEqual(@divFloor(scaled[0], CHUNK_SIZE_SQ), @divFloor(up.new_pos[0], CHUNK_SIZE_SQ));
    try testing.expectEqual(@divFloor(scaled[1], CHUNK_SIZE_SQ), @divFloor(up.new_pos[1], CHUNK_SIZE_SQ));

    // The landing must stay inside the parent chunk, since `player_pos` is chunk-relative.
    try testing.expect(up.new_pos[0] >= 0 and up.new_pos[0] < dw.SUBPIXELS_IN_CHUNK);
    try testing.expect(up.new_pos[1] >= 0 and up.new_pos[1] < dw.SUBPIXELS_IN_CHUNK);
}

test "AscentStep: a return reads the frame back rather than recomputing it" {
    // A depth's rebase origins are fixed by the descent that first reached it;
    // if a return recomputed them from wherever the player wandered to, it could land on different ones,
    // renumbering every suffix at that depth and orphaning its mod_store keys.
    const saved_game = memory.game;
    const saved_suffix = max_possible_suffix;
    defer {
        memory.game = saved_game;
        memory.deriveHashSeeds();
        max_possible_suffix = saved_suffix;
    }
    ascent_stack.clearRetainingCapacity();

    memory.game = .{};
    const test_depth = @max(11, STARTING_ZOOM_TIMES + 1);
    memory.game.depth = test_depth;
    memory.game.player_chunk = .{ 13, 21 };
    memory.game.player_pos = .{ 1000, 500 };
    max_possible_suffix = getMaxSuffixAtDepth(memory.game.depth);
    quad_cache.path_hashes.value[0] = memory.game.seed;

    const child_coord = memory.game.getPlayerCoord();
    const child_depth = memory.game.depth;
    const child_pos = memory.game.player_pos;

    // Rise through an inverted portal somewhere else in the chunk:
    // where the player STOOD is what a return has to come back to, not the block they went up through.
    const through = blockStandPos(6, 9);
    const up = computeParentLayer(child_coord, through);
    try testing.expect(!std.mem.eql(u8, std.mem.asBytes(&through), std.mem.asBytes(&child_pos)));

    const step: AscentStep = .{
        .suffix = child_coord.suffix,
        .quadrant = child_coord.quadrant,
        .origin_pos = child_pos,
    };

    // Stand at the parent, then retrace.
    memory.game.depth = up.depth;
    memory.game.player_chunk = up.player_chunk;
    memory.game.player_quadrant = up.player_quadrant;
    memory.game.player_pos = up.new_pos;
    max_possible_suffix = up.max_possible_suffix;

    const down = computeRetraceLayer(step);

    try testing.expectEqual(child_depth, down.depth);
    try testing.expectEqual(child_coord.suffix, down.player_chunk);
    try testing.expectEqual(child_coord.quadrant, down.player_quadrant);
    // back exactly where the player stood, not where the inverted portal was!
    try testing.expectEqual(child_pos, down.new_pos);
}

/// A distinct `ModCell` per block index, so a misplaced cell is always detectable.
fn testCell(i: u8) ModCell {
    return .{ .id = @enumFromInt(@as(u16, i) + 1), .base_id = @enumFromInt(@as(u16, i) + 300), .hp = i % 16 };
}

/// Puts the player at `depth` so a storage test can write there.
///` beginWrite()` refuses a depth deeper than the frontier, and these tests use arbitrary keys.
pub fn testEnterDepth(depth: u64) void {
    memory.game.depth = depth;
    memory.game.max_depth_reached = depth;
}

test "ModEntry: cells stay indexable by block index regardless of insertion order" {
    const saved_game = memory.game;
    defer {
        memory.game = saved_game;
        memory.deriveHashSeeds();
    }
    mod_store.init(testing.allocator);
    defer mod_store.deinit();
    legacy_store.init(testing.allocator);
    defer legacy_store.deinit();

    const key: DepthCoordinate = .{ .suffix = .{ 1, 2 }, .depth = 7, .quadrant = 0 };
    testEnterDepth(key.depth);

    // Insert scrambled so every insert lands in the middle of the packed array and exercises the shift!
    var n: u32 = 0;
    while (n < CHUNK_SIZE_SQ) : (n += 1) {
        const i: u8 = @intCast((n *% 97) % CHUNK_SIZE_SQ);
        mod_store.beginWrite(key).setCell(i, testCell(i));

        const entry = mod_store.get(key).?;
        try testing.expectEqual(@as(u16, @intCast(n + 1)), entry.count);
        // cells must remain sorted by block index, which is what makes rank() a valid lookup
        var prev: i32 = -1;
        var seen: u16 = 0;
        for (0..CHUNK_SIZE_SQ) |b| {
            if (!entry.isModified(@intCast(b))) continue;
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

test "ModEntry: unmodified cells read as null and rewrites do not grow the entry" {
    const saved_game = memory.game;
    defer {
        memory.game = saved_game;
        memory.deriveHashSeeds();
    }
    mod_store.init(testing.allocator);
    defer mod_store.deinit();
    legacy_store.init(testing.allocator);
    defer legacy_store.deinit();

    const key: DepthCoordinate = .{ .suffix = .{ 0, 0 }, .depth = 6, .quadrant = 3 };
    testEnterDepth(key.depth);
    const modified = [_]u8{ 0, 1, 63, 64, 65, 127, 128, 200, 255 };

    for (modified) |i| mod_store.beginWrite(key).setCell(i, testCell(i));

    const entry = mod_store.get(key).?;
    try testing.expectEqual(@as(u16, modified.len), entry.count);
    for (0..CHUNK_SIZE_SQ) |i| {
        const idx: u8 = @intCast(i);
        const expected = std.mem.indexOfScalar(u8, &modified, idx) != null;
        try testing.expectEqual(expected, entry.get(idx) != null);
    }

    // Overwriting an already-modified cell must replace it, not insert a duplicate.
    mod_store.beginWrite(key).setCell(64, .{
        .id = .stone,
        .base_id = .none,
        .hp = 3,
    });
    try testing.expectEqual(@as(u16, modified.len), entry.count);
    try testing.expectEqual(Sprite.stone, entry.get(64).?.id);
}

test "ModEntry: applyTo overwrites exactly the modified cells" {
    const saved_game = memory.game;
    defer {
        memory.game = saved_game;
        memory.deriveHashSeeds();
    }
    mod_store.init(testing.allocator);
    defer mod_store.deinit();
    legacy_store.init(testing.allocator);
    defer legacy_store.deinit();

    const key: DepthCoordinate = .{ .suffix = .{ 9, 9 }, .depth = 8, .quadrant = 0 };
    testEnterDepth(key.depth);
    mod_store.beginWrite(key).setCell(5, .{ .id = .none, .base_id = .none, .hp = 0 });
    mod_store.beginWrite(key).setCell(200, .{ .id = .water, .base_id = .none, .hp = 9 });

    var chunk: Chunk = undefined;
    for (&chunk.blocks) |*b| b.* = .makeBasicBlock(.stone, 0xABCD);

    mod_store.get(key).?.applyTo(&chunk, key);

    const lane = seedLane(key);
    for (chunk.blocks, 0..) |b, i| {
        switch (i) {
            5, 200 => {
                // A replayed cell takes a fresh position-hashed seed, since `ModCell` stores none
                // and the cell under it may have generated as air (seed zero).
                const want: u28 = @truncate(seeding.FastHash.hash2d(
                    lane,
                    i & (CHUNK_SIZE - 1),
                    i >> CHUNK_SIZE_LOG2,
                ));
                try testing.expectEqual(want, b.seed);
            },
            // Everything the replay does not touch keeps the seed the generator gave it.
            else => try testing.expectEqual(@as(u28, 0xABCD), b.seed),
        }
        switch (i) {
            5 => try testing.expectEqual(Sprite.none, b.id),
            200 => {
                try testing.expectEqual(Sprite.water, b.id);
                try testing.expectEqual(@as(u4, 9), b.hp);
            },
            else => try testing.expectEqual(Sprite.stone, b.id),
        }
    }

    // Two cells of one chunk must not agree on a variant just because both were placed by hand.
    try testing.expect(chunk.blocks[5].seed != chunk.blocks[200].seed);
}

test "ModificationStore: remove drops the chunk and recycles its slot" {
    const saved_game = memory.game;
    defer {
        memory.game = saved_game;
        memory.deriveHashSeeds();
    }
    mod_store.init(testing.allocator);
    defer mod_store.deinit();
    legacy_store.init(testing.allocator);
    defer legacy_store.deinit();

    const a: DepthCoordinate = .{ .suffix = .{ 1, 1 }, .depth = 6, .quadrant = 0 };
    testEnterDepth(a.depth);
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

/// Fields of a `Block` that generation is authoritative for: what the world IS,
/// rather than what a pass later derives from its neighbors (edge/waterlog flags) or what the renderer overwrites (light).
const AuthoritativeCell = struct {
    id: Sprite,
    base_id: Sprite,
    hp: u4,
    seed: u28,
    tag: dw.refine.RefinedTag,

    fn of(b: Block) AuthoritativeCell {
        return .{ .id = b.id, .base_id = b.base_id, .hp = b.hp, .seed = b.seed, .tag = b.tag };
    }
};

test "edge flags: edge stone stays separate at a recursive cross-chunk seam" {
    const saved_game = memory.game;
    const saved_suffix = max_possible_suffix;
    defer {
        memory.game = saved_game;
        memory.deriveHashSeeds();
        max_possible_suffix = saved_suffix;
        clearCaches(true);
    }

    memory.game = .{};
    memory.deriveHashSeeds();
    quad_cache.path_hashes.value[0] = memory.game.seed;

    mod_store.init(testing.allocator);
    defer mod_store.deinit();
    legacy_store.init(testing.allocator);
    defer legacy_store.deinit();

    // This is the inherited inner face of the two-cell base-depth outer wall at D15.
    const depth = STARTING_ZOOM_TIMES + 2;
    memory.game.depth = depth;
    memory.game.max_depth_reached = depth;
    max_possible_suffix = getMaxSuffixAtDepth(depth);
    clearCaches(true);

    const wall_coord: Coordinate = .{ .suffix = .{ 1, 4 }, .quadrant = 0 };
    const terrain_coord: Coordinate = .{ .suffix = .{ 2, 4 }, .quadrant = 0 };
    var wall_chunk: Chunk = undefined;
    var terrain_chunk: Chunk = undefined;
    materializeChunk(&wall_chunk, wall_coord.asDepthCoordinate(depth));
    materializeChunk(&terrain_chunk, terrain_coord.asDepthCoordinate(depth));

    const wall = wall_chunk.blocks[CHUNK_SIZE - 1];
    const terrain = terrain_chunk.blocks[0];
    try testing.expectEqual(Sprite.edge_stone, wall.id);
    try testing.expect(wall.isSolid());
    try testing.expect(!wall.isFoundation());
    try testing.expect(terrain.isFoundation());
    try testing.expect(!shouldHaveEdgeFlags(.edge_stone));
    try testing.expectEqual(@as(u8, 0xFF), wall.edge_flags);
    try testing.expectEqual(@as(u8, 0xFF), wall.id_edge_flags);
    try testing.expectEqual(@as(u8, 0xFF), world_edge_block.edge_flags);
    try testing.expectEqual(@as(u8, 0xFF), world_edge_block.id_edge_flags);
    try testing.expect((terrain.edge_flags & types.EdgeFlags.LEFT) == 0);
    try testing.expect((terrain.id_edge_flags & types.EdgeFlags.LEFT) == 0);
}

test "edge flags: current halo overlays a live edit before cache fill" {
    const saved_game = memory.game;
    const saved_suffix = max_possible_suffix;
    defer {
        memory.game = saved_game;
        memory.deriveHashSeeds();
        max_possible_suffix = saved_suffix;
        clearCaches(true);
    }

    memory.game = .{};
    memory.deriveHashSeeds();
    quad_cache.path_hashes.value[0] = memory.game.seed;

    mod_store.init(testing.allocator);
    defer mod_store.deinit();
    legacy_store.init(testing.allocator);
    defer legacy_store.deinit();

    const depth = STARTING_ZOOM_TIMES + 2;
    memory.game.depth = depth;
    memory.game.max_depth_reached = depth + 1;
    max_possible_suffix = getMaxSuffixAtDepth(depth);
    clearCaches(true);

    const source_coord: Coordinate = .{ .suffix = .{ 2, 4 }, .quadrant = 0 };
    const neighbor_coord: Coordinate = .{ .suffix = .{ 3, 4 }, .quadrant = 0 };
    const source_key = source_coord.asDepthCoordinate(depth);
    const neighbor_key = neighbor_coord.asDepthCoordinate(depth);
    const source_idx = CHUNK_SIZE - 1;
    const neighbor_idx = 0;

    var source_before: Chunk = undefined;
    var neighbor_before: Chunk = undefined;
    materializeChunk(&source_before, source_key);
    materializeChunk(&neighbor_before, neighbor_key);
    try testing.expect(source_before.blocks[source_idx].isFoundation());
    try testing.expect(neighbor_before.blocks[neighbor_idx].isFoundation());
    clearCaches(true);

    // At an ascended depth, this write freezes the procedural value for descendants.
    mod_store.beginWrite(neighbor_key).setCell(neighbor_idx, .{
        .id = .none,
        .base_id = .none,
        .hp = 0,
    });
    try testing.expect(legacy_store.getCell(neighbor_key, neighbor_idx) != null);
    try testing.expectEqual(Sprite.none, mod_store.getCell(neighbor_key, neighbor_idx).?.id);
    clearCaches(true);

    // The neighbor is absent from every current-depth cache here.
    var uncached: Chunk = undefined;
    materializeChunk(&uncached, source_key);
    try testing.expect((uncached.blocks[source_idx].edge_flags & types.EdgeFlags.RIGHT) == 0);

    // Loading that same neighbor must not change the source chunk's derived edge mask.
    const cached_neighbor = getChunkPtr(neighbor_coord);
    try testing.expectEqual(Sprite.none, cached_neighbor.blocks[neighbor_idx].id);
    var cached: Chunk = undefined;
    materializeChunk(&cached, source_key);
    try testing.expectEqual(uncached.blocks[source_idx].edge_flags, cached.blocks[source_idx].edge_flags);
    try testing.expect((cached.blocks[source_idx].edge_flags & types.EdgeFlags.RIGHT) == 0);
}

test "coordinate consistency: a block is the same whatever route reached it" {
    const saved_game = memory.game;
    const saved_suffix = max_possible_suffix;
    defer {
        memory.game = saved_game;
        memory.deriveHashSeeds();
        max_possible_suffix = saved_suffix;
        clearCaches(true);
    }

    memory.game = .{};
    memory.deriveHashSeeds();
    quad_cache.path_hashes.value[0] = memory.game.seed;

    mod_store.init(testing.allocator);
    defer mod_store.deinit();
    legacy_store.init(testing.allocator);
    defer legacy_store.deinit();

    // Two depths of refinement above the base, so the ancestry is a chain rather than a single step.
    const depth = STARTING_ZOOM_TIMES + 2;
    memory.game.depth = depth;
    max_possible_suffix = getMaxSuffixAtDepth(depth);
    clearCaches(true);

    const coord: Coordinate = .{ .suffix = .{ 37, 52 }, .quadrant = 0 };
    const key = coord.asDepthCoordinate(depth);

    // Route A: the whole chunk at once, from a 6x6 parent neighborhood.
    var whole: Chunk = undefined;
    generateChunk(&whole, key);

    // Route B: one cell at a time up the ancestry,
    // every cache dropped between cells so no lookup can be answered by something an earlier route left behind!
    for (0..CHUNK_SIZE) |by| {
        for (0..CHUNK_SIZE) |bx| {
            clearCaches(true);
            const cell = dw.ancestor.getInheritedMaterial(key, @intCast(bx), @intCast(by));
            try testing.expectEqual(
                AuthoritativeCell.of(whole.blocks[by * CHUNK_SIZE + bx]),
                AuthoritativeCell.of(cell),
            );
        }
    }

    // route C: the same chunk seen from one depth deeper, where it is somebody's ancestor rather than the live layer.
    // this is the branch switch in getQuadrantSeed() and the flag passes run too,
    // so the whole block (derived fields included) has to match.
    memory.game.depth = depth + 1;
    max_possible_suffix = getMaxSuffixAtDepth(depth + 1);
    clearCaches(true);
    const as_ancestor = dw.ancestor.getAncestorChunk(key);
    for (0..CHUNK_SIZE_SQ) |i| {
        try testing.expectEqual(whole.blocks[i], as_ancestor.blocks[i]);
    }

    // ...and again with an edit in the ANCESTRY, since the two routes replay mod_store at different points:
    // route A through its parent chunk's materialization, route B cell by cell as it recurses!
    memory.game.depth = depth;
    max_possible_suffix = getMaxSuffixAtDepth(depth);
    const parent_key = key.getParent().asCoord().asDepthCoordinate(depth - 1);
    // The edit has to be frontier-era to reach the depth below it. An edit made after the player
    // descended past the parent stays at the parent (see `legacy_store`), which is a different test.
    testEnterDepth(depth - 1);
    mod_store.beginWrite(parent_key).setCell(37, .{ .id = .lava_stone, .base_id = .none, .hp = 0 });
    mod_store.beginWrite(parent_key).setCell(38, .{ .id = .none, .base_id = .none, .hp = 0 });
    testEnterDepth(depth);
    clearCaches(true);

    var edited: Chunk = undefined;
    generateChunk(&edited, key);
    for (0..CHUNK_SIZE) |by| {
        for (0..CHUNK_SIZE) |bx| {
            clearCaches(true);
            const cell = dw.ancestor.getInheritedMaterial(key, @intCast(bx), @intCast(by));
            try testing.expectEqual(
                AuthoritativeCell.of(edited.blocks[by * CHUNK_SIZE + bx]),
                AuthoritativeCell.of(cell),
            );
        }
    }
}

test "placement guard blocks self-encasement and keeps pairs coherent" {
    const saved_game = memory.game;
    const saved_suffix = max_possible_suffix;
    const saved_pickaxe = dw.mining.pickaxe_type;
    const saved_structure_tool = dw.mining.has_structure_tool;
    const saved_creative = dw.inventory.IN_CREATIVE;
    defer {
        memory.game = saved_game;
        memory.deriveHashSeeds();
        max_possible_suffix = saved_suffix;
        dw.mining.pickaxe_type = saved_pickaxe;
        dw.mining.has_structure_tool = saved_structure_tool;
        dw.inventory.IN_CREATIVE = saved_creative;
        clearCaches(true);
    }

    memory.game = .{};
    memory.deriveHashSeeds();
    quad_cache.path_hashes.value[0] = memory.game.seed;
    memory.game.depth = STARTING_ZOOM_TIMES;
    max_possible_suffix = getMaxSuffixAtDepth(memory.game.depth);

    mod_store.init(testing.allocator);
    defer mod_store.deinit();
    legacy_store.init(testing.allocator);
    defer legacy_store.deinit();
    flag_worklist = try std.ArrayList(UpdateItem).initCapacity(testing.allocator, 256);
    defer {
        flag_worklist.deinit(testing.allocator);
        flag_worklist = .empty;
    }
    clearCaches(true);

    // Hunt for somewhere with room for both halves and ground under both of them.
    var chunk: Chunk = undefined;
    var coord: Coordinate = undefined;
    var key: DepthCoordinate = undefined;
    var spot: ?struct { bx: u4, by: u4 } = null;
    var search: u64 = 40;
    while (search < 60 and spot == null) : (search += 1) {
        coord = .{ .suffix = .{ search, 40 }, .quadrant = 0 };
        key = coord.asDepthCoordinate(memory.game.depth);
        materializeChunk(&chunk, key);

        for (1..CHUNK_SIZE - 1) |by| {
            for (1..CHUNK_SIZE - 1) |bx| {
                const here = chunk.blocks[by * CHUNK_SIZE + bx];
                const right = chunk.blocks[by * CHUNK_SIZE + bx + 1];
                const under = chunk.blocks[(by + 1) * CHUNK_SIZE + bx];
                const under_right = chunk.blocks[(by + 1) * CHUNK_SIZE + bx + 1];
                if (here.isEmpty() and right.isEmpty() and under.isSolid() and under_right.isSolid()) {
                    spot = .{ .bx = @intCast(bx), .by = @intCast(by) };
                    break;
                }
            }
            if (spot != null) break;
        }
    }
    const at = spot orelse return error.TestUnexpectedResult; // 20 chunks with no ledge at all is a bug
    std.debug.assert(at.bx > 0 and at.bx < CHUNK_SIZE - 1 and at.by > 0 and at.by < CHUNK_SIZE - 1);

    // The full hitbox fits in the empty cell. A solid replacement must be refused before it writes the store.
    memory.game.player_quadrant = coord.quadrant;
    memory.game.player_chunk = coord.suffix;
    memory.game.player_pos = .{
        @as(i64, at.bx) * CHUNK_SIZE_SQ + CHUNK_SIZE_SQ / 2,
        @as(i64, at.by) * CHUNK_SIZE_SQ + 100,
    };
    SimBuffer.sync(memory.game.getPlayerCoord());
    try testing.expectEqual(
        ModifyBlockTypeResult.rejected_softlock,
        modifyBlockType(coord, at.bx, at.by, .stone, .empty),
    );
    try testing.expect(mod_store.get(key) == null);

    // Three unbreakable gems leave a one-cell cardinal exit. The fourth must not close it.
    dw.mining.pickaxe_type = .stone;
    dw.mining.has_structure_tool = false;
    dw.inventory.IN_CREATIVE = false;
    const lower_by: u4 = @intCast(@as(u5, at.by) + 1);
    const ring = [_]struct { bx: u4, by: u4 }{
        .{ .bx = at.bx - 1, .by = at.by },
        .{ .bx = at.bx + 1, .by = at.by },
        .{ .bx = at.bx, .by = at.by - 1 },
    };
    for (ring) |cell| {
        mod_store.beginWrite(key).setCell(@intCast(@as(usize, cell.by) * CHUNK_SIZE + cell.bx), .{
            .id = .amethyst,
            .base_id = .stone,
            .hp = 0,
        });
    }
    const lower_idx: u8 = @intCast(@as(usize, lower_by) * CHUNK_SIZE + at.bx);
    mod_store.beginWrite(key).setCell(lower_idx, .{ .id = .none, .base_id = .none, .hp = 0 });
    clearCaches(true);
    SimBuffer.sync(memory.game.getPlayerCoord());

    try testing.expectEqual(
        ModifyBlockTypeResult.rejected_softlock,
        modifyBlockType(coord, at.bx, lower_by, .amethyst, .empty),
    );
    try testing.expectEqual(Sprite.none, mod_store.getCell(key, lower_idx).?.id);

    // A portal correction moves a player out of the equivalent completed four-gem cage.
    const trapped_pos = memory.game.player_pos;
    mod_store.beginWrite(key).setCell(lower_idx, .{ .id = .amethyst, .base_id = .stone, .hp = 0 });
    clearCaches(true);
    SimBuffer.sync(memory.game.getPlayerCoord());
    try testing.expect(player.escapeSolid());
    try testing.expect(@reduce(.Or, memory.game.player_pos != trapped_pos));
    // The player arrives standing, not falling. The landing is clear and one subpixel lower collides.
    try testing.expect(!player.isColliding(memory.game.player_pos[0], memory.game.player_pos[1]));
    try testing.expect(player.isColliding(memory.game.player_pos[0], memory.game.player_pos[1] + 1));
    memory.game.player_quadrant = coord.quadrant;
    memory.game.player_chunk = coord.suffix;
    memory.game.player_pos = trapped_pos;
    memory.game.last_player_pos = trapped_pos;
    memory.game.camera_pos = trapped_pos;
    memory.game.last_camera_pos = trapped_pos;

    // A portal is non-solid, but it makes this last breakable exit support unbreakable.
    mod_store.beginWrite(key).setCell(lower_idx, .{ .id = .stone, .base_id = .none, .hp = 0 });
    clearCaches(true);
    SimBuffer.sync(memory.game.getPlayerCoord());
    const center_idx: u8 = @intCast(@as(usize, at.by) * CHUNK_SIZE + at.bx);
    try testing.expectEqual(Sprite.amethyst, getBlockAt(coord, at.bx - 1, at.by, memory.game.depth).id);
    try testing.expectEqual(Sprite.amethyst, getBlockAt(coord, at.bx + 1, at.by, memory.game.depth).id);
    try testing.expectEqual(Sprite.amethyst, getBlockAt(coord, at.bx, at.by - 1, memory.game.depth).id);
    try testing.expectEqual(Sprite.stone, getBlockAt(coord, at.bx, lower_by, memory.game.depth).id);
    try testing.expect(player.isColliding(memory.game.player_pos[0] - CHUNK_SIZE_SQ, memory.game.player_pos[1]));
    try testing.expect(player.isColliding(memory.game.player_pos[0] + CHUNK_SIZE_SQ, memory.game.player_pos[1]));
    try testing.expect(player.isColliding(memory.game.player_pos[0], memory.game.player_pos[1] - CHUNK_SIZE_SQ));
    try testing.expect(player.isColliding(memory.game.player_pos[0], memory.game.player_pos[1] + CHUNK_SIZE_SQ));
    const portal_pending = [_]player.PendingPlacement{
        .{ .coord = coord, .bx = at.bx, .by = at.by, .sprite = .portal },
    };
    try testing.expect(!player.permitsPlacement(&portal_pending));
    try testing.expectEqual(
        ModifyBlockTypeResult.rejected_softlock,
        modifyBlockType(coord, at.bx, at.by, .portal, .empty),
    );
    try testing.expect(mod_store.getCell(key, center_idx) == null);

    // The pair case below needs its original procedural ledge, not the synthetic test cage.
    mod_store.clear();
    legacy_store.clear();
    clearCaches(true);

    // Placing the left half alone must leave BOTH halves standing: each demands the other,
    // so a pass that validated the first before writing the second would clear the pair right back out.
    try testing.expectEqual(
        ModifyBlockTypeResult.placed,
        modifyBlockType(coord, at.bx, at.by, .moss_shrub1, .empty),
    );

    const idx: u8 = @intCast(@as(usize, at.by) * CHUNK_SIZE + at.bx);
    const entry = mod_store.get(key) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Sprite.moss_shrub1, (entry.get(idx) orelse return error.TestUnexpectedResult).id);
    try testing.expectEqual(Sprite.moss_shrub1_right, (entry.get(idx + 1) orelse return error.TestUnexpectedResult).id);

    // And the world agrees, not just the store.
    materializeChunk(&chunk, key);
    try testing.expectEqual(Sprite.moss_shrub1, chunk.blocks[idx].id);
    try testing.expectEqual(Sprite.moss_shrub1_right, chunk.blocks[idx + 1].id);
}

test "frozen ancestry: an edit made after a depth is left never reaches the depths deeper than it" {
    const saved_game = memory.game;
    const saved_suffix = max_possible_suffix;
    defer {
        memory.game = saved_game;
        memory.deriveHashSeeds();
        max_possible_suffix = saved_suffix;
        clearCaches(true);
    }

    memory.game = .{};
    memory.deriveHashSeeds();
    quad_cache.path_hashes.value[0] = memory.game.seed;

    mod_store.init(testing.allocator);
    defer mod_store.deinit();
    legacy_store.init(testing.allocator);
    defer legacy_store.deinit();

    const depth = STARTING_ZOOM_TIMES + 2;
    const coord: Coordinate = .{ .suffix = .{ 37, 52 }, .quadrant = 0 };
    const key = coord.asDepthCoordinate(depth);

    memory.game.depth = depth;
    max_possible_suffix = getMaxSuffixAtDepth(depth);
    const parent_key = key.getParent().asCoord().asDepthCoordinate(depth - 1);
    const parent_idx: u8 = 37;

    // The player is at the parent, which is the deepest depth reached: this edit shapes what comes below.
    testEnterDepth(depth - 1);
    max_possible_suffix = getMaxSuffixAtDepth(depth - 1);
    mod_store.beginWrite(parent_key).setCell(parent_idx, .{ .id = .lava_stone, .base_id = .none, .hp = 0 });
    try testing.expectEqual(@as(usize, 0), legacy_store.index.count()); // frontier edits never freeze

    // Descend. The child inherits the edit.
    testEnterDepth(depth);
    max_possible_suffix = getMaxSuffixAtDepth(depth);
    clearCaches(true);
    var inherited: Chunk = undefined;
    generateChunk(&inherited, key);

    // Go back up and undo the edit. The parent is shallower than the frontier now, so this stays at the parent.
    memory.game.depth = depth - 1;
    max_possible_suffix = getMaxSuffixAtDepth(depth - 1);
    mod_store.beginWrite(parent_key).setCell(parent_idx, .{ .id = .stone, .base_id = .none, .hp = 0 });
    try testing.expectEqual(@as(usize, 1), legacy_store.index.count()); // the old value was frozen

    // The parent itself shows the new value...
    try testing.expectEqual(Sprite.stone, mod_store.getCell(parent_key, parent_idx).?.id);
    // ...while everything "below" it still sees the value it inherited.
    try testing.expectEqual(Sprite.lava_stone, inheritedCell(parent_key, parent_idx).?.id);

    // And the child regenerates byte for byte the same, however many times the parent is edited.
    memory.game.depth = depth;
    max_possible_suffix = getMaxSuffixAtDepth(depth);
    clearCaches(true);
    var again: Chunk = undefined;
    generateChunk(&again, key);
    for (0..CHUNK_SIZE_SQ) |i| try testing.expectEqual(inherited.blocks[i], again.blocks[i]);

    // A second edit at the parent must not overwrite the frozen value.
    memory.game.depth = depth - 1;
    mod_store.beginWrite(parent_key).setCell(parent_idx, .{ .id = .none, .base_id = .none, .hp = 0 });
    try testing.expectEqual(Sprite.lava_stone, inheritedCell(parent_key, parent_idx).?.id);
}

test "frozen ancestry: an edit shallower than the frontier is playable at its own depth" {
    const saved_game = memory.game;
    defer {
        memory.game = saved_game;
        memory.deriveHashSeeds();
    }

    memory.game = .{};
    mod_store.init(testing.allocator);
    defer mod_store.deinit();
    legacy_store.init(testing.allocator);
    defer legacy_store.deinit();

    // A deep ascent: the frontier stays far below, and the shallow depth is still fully writable.
    const shallow = STARTING_ZOOM_TIMES + 1;
    memory.game.depth = shallow;
    memory.game.max_depth_reached = shallow + 100;
    try testing.expect(isShallowerThanFrontier());

    const key: DepthCoordinate = .{ .suffix = .{ 3, 4 }, .depth = shallow, .quadrant = 0 };
    try testing.expectEqual(@as(u64, shallow + 100), frontier());

    // A cell that was never modified freezes as its procedural value, so deeper depths keep it.
    mod_store.beginWrite(key).setCell(11, .{ .id = .sand, .base_id = .none, .hp = 0 });
    try testing.expectEqual(Sprite.sand, mod_store.getCell(key, 11).?.id);
    try testing.expect(legacy_store.getCell(key, 11) != null);
    try testing.expect(legacy_store.getCell(key, 11).?.id != .sand);
}

test "coordinate consistency: refinement reads a coordinate, not a route" {
    const saved_game = memory.game;
    defer {
        memory.game = saved_game;
        memory.deriveHashSeeds();
    }

    memory.game = .{};
    memory.deriveHashSeeds();
    quad_cache.path_hashes.value[0] = memory.game.seed;
    memory.game.depth = STARTING_ZOOM_TIMES + 1;

    // A decoration on a floor, which is the case that reads the most context: the plan hashes the parent's cell,
    // and the terrain beneath it protects the cells the plan claims.
    const parent: Block = .makeBasicBlock(.bush, 1234);
    var neighbors: [8]Block = @splat(.empty);
    neighbors[6] = .makeBasicBlock(.stone, 5678);
    neighbors[7] = .makeBasicBlock(.stone, 91011);

    const key = (Coordinate{ .suffix = .{ 9, 14 }, .quadrant = 0 }).asDepthCoordinate(memory.game.depth);
    var first: [CHUNK_SIZE_SQ]Block = undefined;
    for (0..CHUNK_SIZE) |by| {
        for (0..CHUNK_SIZE) |bx| {
            first[by * CHUNK_SIZE + bx] =
                dw.ancestor.applyAncestorLogic(parent, neighbors, key, @intCast(bx), @intCast(by)).compile();
        }
    }

    // Same inputs, walked backwards and with the caches dropped: the answers cannot move.
    clearCaches(true);
    var by: usize = CHUNK_SIZE;
    while (by > 0) {
        by -= 1;
        var bx: usize = CHUNK_SIZE;
        while (bx > 0) {
            bx -= 1;
            const again = dw.ancestor.applyAncestorLogic(parent, neighbors, key, @intCast(bx), @intCast(by)).compile();
            try testing.expectEqual(first[by * CHUNK_SIZE + bx], again);
        }
    }
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

    // Every ancestor strictly inside the live window (H, D) must read back its own marker through the public accessor:
    // proof the read index tracks the write index and no two live depths alias a slot.
    const horizon = memory.game.depth - HORIZON_DEPTH;
    var read_d: u64 = horizon + 1;
    while (read_d < memory.game.depth) : (read_d += 1) {
        for (0..4) |q| {
            const got = quad_cache.getQuadrantSeed(@intCast(q), read_d);
            try testing.expectEqual(read_d *% 4 + q, got.value[0]);
        }
    }
}
