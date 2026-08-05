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

/// Uncached foundation evaluation. Call `resolveBaseFoundation()` instead outside of the cache itself.
fn computeBaseFoundation(cx: u64, cy: u64, bx: u4, by: u4) BaseFoundation {
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
    const structured = dw.structures.addStructures(sprite, wx, wy, game.getHashSeed(.structures));
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
    const structured = dw.structures.addStructures(base_sprite, wx, wy, memory.game.getHashSeed(.structures));
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
// - light and lighting_color are written only into the per-frame render scratch buffer (applyLighting()).
// - edge_flags, id_edge_flags, and waterlogged are recomputed from neighbor id+hp by the flag passes.

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
    modified: [MODIFIED_WORDS]u64 = @splat(0),
    /// Blocks whose descendant region holds a modification at some deeper depth, same bit layout as `modified`.
    /// Grown one depth per ascent by `markDescendantsFromChild()` and never cleared,
    /// which holds because ascent is read-only (see `isSpectating()`).
    descendants: [MODIFIED_WORDS]u64 = @splat(0),
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

    /// Whether block index `i` has a modification somewhere in its descendant region.
    pub inline fn hasDescendantMods(self: *const @This(), i: u8) bool {
        return (self.descendants[i >> 6] >> @as(u6, @truncate(i))) & 1 != 0;
    }

    /// Whether this entry says anything at all, either directly or about the depths below it.
    /// Both bitmaps matter: a marker-only entry is what carries a deep edit up through the layers.
    pub fn anySet(self: *const @This()) bool {
        for (self.modified, self.descendants) |m, d| {
            if (m | d != 0) return true;
        }
        return false;
    }

    /// The modified value at block index `i`, or null if that cell is still procedural.
    pub inline fn get(self: *const @This(), i: u8) ?ModCell {
        if (!self.isModified(i)) return null;
        return self.cells[self.rank(i)];
    }

    /// Replays every modified cell over a freshly generated chunk.
    /// The caller MUST then rerun the flag pass: replaying ids invalidates the generated edge/waterlogged flags.
    pub fn applyTo(self: *const @This(), chunk: *Chunk) void {
        var i: usize = 0;
        for (0..MODIFIED_WORDS) |w| {
            var bits = self.modified[w];
            while (bits != 0) : (i += 1) {
                const bit = @ctz(bits);
                bits &= bits - 1;
                self.cells[i].applyTo(&chunk.blocks[(w << 6) | bit]);
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
    /// Incremented whenever the CONTENT of the store changes, which `generation` does not track
    /// (that one only counts wipes). Anything that memoizes a value derived from a modified block
    /// keys on this, so an edit retires it. See `ancestor.ParentHoodCache`.
    content_generation: u64 = 0,
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
            .content_generation = self.content_generation +% 1,
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
        self.content_generation +%= 1;
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
        self.content_generation +%= 1;
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
        std.debug.assert(!isSpectating()); // of course, you can't modify if spectating the world!
        // A transition froze the layer its preview was generated from; editing it now would leave the
        // depth we land on disagreeing with the one we left (see `portal.beginTransition()`).
        std.debug.assert(!dw.portal.isActive());
        return .{ .entry = self.entries.at(self.reserve(key, .edit)) };
    }

    /// Why an entry is being opened, for `TRACE_NEW_ENTRIES`. The store itself does not care.
    const WriteKind = enum { edit, marker };

    /// Logs every chunk that becomes modified for the first time, and what opened it.
    /// A modification the player did not make is the signature of a generator that produces terrain out
    /// of equilibrium with the simulation, so this is the fastest way to catch one in the act.
    /// Debug builds only, and off by default because a session's normal mining floods it.
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
        dw.save.shadowEntryForSave(idx);
        // Every write to the store comes through here (`beginWrite()` and `markDescendant()` both),
        // so this is the one place a content change has to be announced.
        self.content_generation +%= 1;
        return idx;
    }

    /// Records that block `block_idx` of `key` has a modification below it.
    ///
    /// Deliberately outside `beginWrite()`: a marker is not a modification of the layer it sits on,
    /// so it is the one write an ascent is allowed to make.
    pub fn markDescendant(self: *@This(), key: DepthCoordinate, block_idx: u8) void {
        const entry = self.entries.at(self.reserve(key, .marker));
        entry.descendants[block_idx >> 6] |= @as(u64, 1) << @truncate(block_idx);
    }

    /// Rebuilds an entry straight from a save, bypassing the copy-on-write shadow (nothing can be mid-save during a load).
    /// `cells` must be in ascending block-index order and match `modified`.
    pub fn loadEntry(
        self: *@This(),
        key: DepthCoordinate,
        modified: [MODIFIED_WORDS]u64,
        descendants: [MODIFIED_WORDS]u64,
        cells: []const ModCell,
    ) !void {
        const idx = self.allocEntry();
        const entry: *ModEntry = self.entries.at(idx);
        entry.modified = modified;
        entry.descendants = descendants;
        entry.count = @intCast(cells.len);
        entry.cells = try self.allocator.alloc(ModCell, @max(cells.len, MIN_MOD_CELLS));
        @memcpy(entry.cells[0..cells.len], cells);
        try self.index.put(self.allocator, key, idx);
        self.content_generation +%= 1;
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

    /// Marks block `i` as modified and stores its value.
    pub inline fn setCell(self: ModWriter, i: u8, cell: ModCell) void {
        self.entry.setCellRaw(i, cell);
    }

    /// Captures a materialized block's authoritative fields as block `i`'s modified value.
    pub inline fn setBlock(self: ModWriter, i: u8, block: Block) void {
        self.entry.setCellRaw(i, .from(block));
    }
};

/// Stores and handles modifications of chunks across various depths.
/// Initialized in `main()`.
pub var mod_store: ModificationStore = .{};

/// One depth the player has ascended past, recording the block they went up through.
///
/// A descent derives its whole rebase frame from the target block's position (see `computeLayer()`),
/// so coming back down anywhere else would renumber every suffix at that depth and orphan every `mod_store` key below it.
/// Keeping the block means the way down is the way you came.
pub const AscentStep = struct {
    /// The chunk at the DEEPER depth to come back to, and where in it the player stood.
    ///
    /// Recorded rather than recomputed on purpose. A retrace must not re-derive the depth's rebase origins:
    /// those were fixed by the descent that first reached it,
    /// and re-deriving them from wherever the player happens to have wandered can land on different ones,
    /// `computeRetraceLayer()` reads the recorded frame back instead, exactly as `computeParentLayer()` does going the other way.
    suffix: Vec2u,
    quadrant: u2,
    /// Subpixels within `suffix`'s chunk. The invportal is only the way up; where you come back to is
    /// where you were standing.
    origin_pos: Vec2i,

    pub inline fn coord(self: @This()) Coordinate {
        return .{ .suffix = self.suffix, .quadrant = self.quadrant };
    }
};

/// Depths the player has ascended past, deepest last. Empty at the deepest depth ever visited.
/// Lives on `main_allocator` because it can be pushed or popped.
pub var ascent_stack: std.ArrayList(AscentStep) = .empty;

/// Whether the player is above the deepest depth they have reached, looking down at it.
pub inline fn isSpectating() bool {
    return ascent_stack.items.len != 0;
}

/// The deepest depth the player has reached, which is the only depth they may modify.
pub inline fn deepestDepth() u64 {
    return memory.game.depth + ascent_stack.items.len;
}

/// Whether there is a depth above the current one to ascend into.
pub inline fn canAscend() bool {
    return memory.game.depth > STARTING_ZOOM_TIMES;
}

/// The step a descent must retrace, or null when the player is already at their deepest depth.
pub inline fn retraceStep() ?AscentStep {
    return if (isSpectating()) ascent_stack.items[ascent_stack.items.len - 1] else null;
}

/// Drops the top ascent step, once the descent that retraced it has committed.
pub fn popAscentStep() void {
    std.debug.assert(isSpectating());
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

        // X Axis
        if (dx != 0) {
            const is_pos = dx > 0;
            const delta: u64 = if (is_pos) @intCast(dx) else @intCast(-%dx);
            const ov = if (is_pos) @addWithOverflow(res.suffix[0], delta) else @subWithOverflow(res.suffix[0], delta);
            if (ov[1] != 0) {
                if (depth < HORIZON_DEPTH) return null;
                // Past the horizon the quadrant bit IS the world's top coordinate bit, so a suffix that
                // runs off the OUTER quadrant has left the world: there is no quadrant to flip into.
                // Flipping anyway wraps the world edge to edge and hands back a coordinate 2^64 chunks away,
                // which `refineHorizonWindow()` reads as an enormous parent delta.
                if (is_pos == ((res.quadrant & 1) != 0)) return null;
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
                // Same world-edge rule as the X axis above, on the quadrant's Y bit.
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
    ///   a bit is set toward a neighbor that is a foundation (for solids) or solid-or-liquid (for liquids).
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
                    materializeChunk(&chunk_cache.chunks[slot], c.asDepthCoordinate(memory.game.depth));
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
                    materializeChunk(&chunk_cache.chunks[slot], c.asDepthCoordinate(memory.game.depth));
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

    // Add a very conservative minimum baseline for safety!
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
    /// NOTE: `@splat()` is for the DEFAULT only, where it is a comptime value. Clearing at runtime goes
    /// through `@memset()` instead (see `clear()`): assigning a whole array this size builds the value in
    /// the stack frame and copies it, which is both code waste and most of the frame in Debug.
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
    pub fn findIndex(self: *@This(), coord: Coordinate) ?usize {
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
    pub fn allocateIndex(self: *@This(), coord: Coordinate) usize {
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
        @memset(&self.keys, @splat(null));
        @memset(&self.clock_bits, 0);
        @memset(&self.hands, 0);
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

        for (&self.keys, 0..) |*set, set_idx| {
            for (set, 0..) |maybe_key, way| {
                const coord = maybe_key orelse continue;
                // A resident chunk is the SimBuffer's to own; the cached copy is allowed to lag it.
                if (SimBuffer.get(coord) != null) continue;
                materializeChunk(&scratch, coord.asDepthCoordinate(memory.game.depth));

                const cached = &self.chunks[set_idx * CHUNK_CACHE_WAYS + way];
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

/// Everything `refineHorizonWindow()` needs about one depth transition besides the previous window.
///
/// This is the AUTHORITATIVE per-depth record: roughly 24 bytes, against the window's 4 KiB.
/// It cannot be derived from anything else that is kept,
/// since the window is centered on where the player happened to be standing when they descended
/// and only this records that. Everything else about a window is a pure function of the seed,
/// the traces down to it, and `mod_store`, so a window is a CACHE and is never stored in a save
/// (see `QuadCache.getMaterials()`).
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

        // below or at HORIZON_DEPTH there's simply no coordinate rebasing
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
    .materials_path = .{},
    .materials_windows = .{},
    .ancestor_materials = undefined,
};

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

    const slot_index = chunk_cache.allocateIndex(coord);
    materializeChunk(&chunk_cache.chunks[slot_index], coord.asDepthCoordinate(memory.game.depth));
    return &chunk_cache.chunks[slot_index];
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
    // Asked BEFORE generating so the flag pass can be skipped when it is about to be redone below.
    // A bool rather than the entry itself: generation is a long call and nothing should hold a store
    // pointer across it.
    const modified = mod_store.contains(key);
    const is_base = key.depth == STARTING_ZOOM_TIMES;

    // The generator derives flags from the ids it just wrote. Replaying an edit changes those ids, so
    // those flags are dead the moment `applyTo()` runs; deriving them twice is pure waste.
    // The base depth is the exception: its decoration pass reads the flags while generating.
    generateChunkInner(chunk, key, if (modified and !is_base) .skip_flags else .derive_flags);

    const entry = mod_store.get(key);
    // Generation must never touch the store, or the flag pass skipped above would never be made up for.
    std.debug.assert((entry != null) == modified);
    if (entry) |e| {
        e.applyTo(chunk);
        // Only meaningful while looking down at a deeper depth; at the deepest depth the markers left
        // behind by an earlier ascent describe modifications that ARE this layer.
        if (isSpectating()) {
            for (0..CHUNK_SIZE_SQ) |idx| {
                chunk.blocks[idx].descendant_mods = e.hasDescendantMods(@intCast(idx));
            }
        }
    }

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

/// The cell one to the right of `bx`, crossing into the next chunk when it has to.
/// Null at the world edge, where there is nowhere for a pair's other half to go.
const RightCell = struct { coord: Coordinate, bx: u4 };
inline fn rightNeighborCell(coord: Coordinate, bx: u4) ?RightCell {
    if (bx < CHUNK_SIZE - 1) return .{ .coord = coord, .bx = bx + 1 };
    return .{ .coord = coord.move(.{ 1, 0 }) orelse return null, .bx = 0 };
}

/// Applies a block modification, changing the `Sprite` type and resetting `hp`. Mutates `mod_store` and caches in-place.
/// Returns whether `update_local_edge_flags` instantly removed the current block due to being in an invalid position.
///
/// `prev_block` is the block that occupied this cell BEFORE this action began.
/// The caller must pass the original block (for example, mining reads it before deleting).
pub fn modifyBlockType(coord: Coordinate, bx: u4, by: u4, new_sprite: Sprite, prev_block: Block) bool {
    // a block that spans two cells includes its right half
    var cell: struct { Coordinate, u4 } = .{ coord, bx };
    var sprite = new_sprite;
    var prev = prev_block;
    var second_cell: ?struct { Coordinate, u4 } = null;

    while (true) {
        const partner = sprite.pairedRight();
        writeBlockType(cell[0], cell[1], by, sprite, prev);
        if (partner == .none) break;

        const right = rightNeighborCell(cell[0], cell[1]) orelse break;

        // stop placement if the right cell is not empty in non-creative
        const right_block = getBlockAt(right.coord, right.bx, by, memory.game.depth);
        if (!dw.inventory.isInCreative() and !right_block.isEmpty()) break;

        // only place the right half if the block underneath it is solid
        const ny = @as(i32, by) + 1;
        const under_coord = if (ny >= CHUNK_SIZE) right.coord.moveY(1) else right.coord;
        if (under_coord) |uc| {
            const under_by: u4 = @intCast(@mod(ny, CHUNK_SIZE));
            const under_block = getBlockAt(uc, right.bx, under_by, memory.game.depth);
            if (!under_block.isSolid()) break;
        } else break;

        cell = .{ right.coord, right.bx };
        second_cell = cell;
        sprite = partner;
        prev = .empty;
    }

    // Update edge flags for both cells when a two-cell block is placed.
    if (second_cell) |c2| {
        _ = updateLocalEdgeFlags(c2[0], c2[1], by);
    }
    return updateLocalEdgeFlags(coord, bx, by);
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
        block.waterlogged = 0;
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
    b.waterlogged = 0;
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
    ascent_stack.clearRetainingCapacity();
    quad_cache.reset();
}

/// Where a depth increase leaves the player inside the block it descends into.
pub const LayerAnchor = enum {
    /// Keep the player where they visually are, so a zoom in place does not shift them.
    /// Only coherent when the target block is the one the player already stands in,
    /// since the landing position is derived from the player rather than from the block.
    player,
    /// Stand the player on the floor at the middle of the target block's child region.
    /// A portal descent uses this: the target block is the portal, not wherever the player happens to be,
    /// so deriving the landing from the player would drop them at an unrelated (possibly solid) spot.
    block_floor,
};

/// Subpixels from the player's center down to their feet; see `PLAYER_HITBOX_HEIGHT` use in `player.zig`.
const PLAYER_FEET_OFFSET = CHUNK_SIZE_SQ / 2;

/// Everything one depth change works out, kept apart from the act of applying it.
///
/// Splitting the two lets the same transition be installed more than once:
/// the portal animation installs it every frame as a throwaway so it can generate the target depth's
/// chunks while the committed world still sits at the old depth,
/// and installs it one last time when the animation commits.
/// Fields past `rebase` are only meaningful beyond `HORIZON_DEPTH`, where coordinates are rebased.
pub const LayerTransition = struct {
    /// The depth being entered: one deeper for `computeLayer()`, one shallower for `computeParentLayer()`.
    depth: u64,
    /// Player subpixel position inside the new chunk, already pivot-compensated.
    new_pos: Vec2i,
    player_chunk: Vec2u,
    player_quadrant: u2,
    max_possible_suffix: u64,

    /// Whether the rebase fields below carry meaning (false at or below `HORIZON_DEPTH`).
    rebase: bool = false,
    path_hashes: ChunkSeeds = undefined,
    /// Rebase origin recorded for `depth`; see `QuadCache.getOriginX()`.
    left_cell: u64 = 0,
    top_cell: u64 = 0,
    most_top: bool = true,
    most_bottom: bool = true,
    most_left: bool = true,
    most_right: bool = true,
    /// Only rebuilt once the horizon has a real ancestor depth to summarize.
    ancestor_materials: HorizonWindow = undefined,
    /// What that window is refined from; the authoritative per-depth record (see `HorizonTrace`).
    /// The trace this transition's window was built around, or null when it did not build one.
    ///
    /// Only a DESCENT into a depth for the first time derives a trace; an ascent and a retrace read the
    /// depth's window back out of `materials_path` and must leave the recorded trace exactly as it is.
    /// Optional rather than a sentinel because it is the authoritative record of the depth: writing an
    /// unset one back corrupts the horizon for that depth and every depth refined from it.
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
    // Every menu is bound to a block at the depth being left, and the loot menu WRITES to that block
    // when it is emptied, so a menu that survives the change would edit an unrelated cell at the new
    // depth. Closed here rather than at each caller: this is the one point every depth change routes
    // through, hotkeys included (`portal.beginTransition()` closes them earlier still, because the
    // animation has to hold them shut for its whole length).
    dw.indicators.closeAllMenus();

    if (keep_ancestors) clearCaches(false) else clearCaches(true);
    dw.inventory.dropped_items.clear(null);
    memory.game.teleport(null, t.new_pos); // make sure to teleport!
    installLayer(t);
}

/// Increases the game's depth by 1, invalidates caches, moves the player, and handles data modification.
/// `coord` is the chunk the portal is in or where the depth should take place.
/// `bx` and `by` represent the specific block within a chunk the zoom should be in.
pub fn pushLayer(parent_id: Sprite, coord: Coordinate, bx: u4, by: u4) void {
    _ = parent_id;
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
        const cell_x = left_cell + utils.intFromBool(u64, q_id % 2 == 1); // this new quadrant's absolute column
        const cell_y = top_cell + utils.intFromBool(u64, q_id >= 2); // this new quadrant's absolute row
        const old_q_id = utils.intFromBool(usize, cell_x >= ZOOM_FACTOR) + utils.intFromBool(usize, cell_y >= ZOOM_FACTOR) * 2; // parent quadrant it descends from
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
    // Largest top-left cell the recentered 2x2 window can sit on; matches `computeLayer()`.
    const highest_cell = (ZOOM_FACTOR - 1) * 2;

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
        state.edges.most_right = state.edges.most_right and left_cell == highest_cell;
        state.edges.most_top = state.edges.most_top and top_cell == 0;
        state.edges.most_bottom = state.edges.most_bottom and top_cell == highest_cell;
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
    const new_pos: Vec2i = .{
        cell_x * child_span + @divFloor(pos[0], ZOOM_FACTOR),
        cell_y * child_span + @divFloor(pos[1], ZOOM_FACTOR),
    };

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
/// Records the step on `ascent_stack`, which both puts the world into its read-only spectating mode and pins the block a later descent has to retrace.
/// The descendant markers are propagated first, while the deeper depth is still the current one and its parents are still one hop away.
pub fn popLayer() void {
    const g = &memory.game;
    // apply instantly
    applyAscent(computeParentLayer(g.getPlayerCoord(), g.player_pos), g.getPlayerCoord(), g.player_pos);
    // `commitLayer()` emptied the SimBuffer, so refill it around where the player landed before anything
    // reads it. Matches `retraceInstant()`; without it the world is momentarily absent, and an absent
    // chunk reads as solid to collision (see `getBlockPtr()`).
    SimBuffer.sync(g.getPlayerCoord());
    applyDescendantMarkersToSim();
}

/// Commits an already-computed ascent transition: rolls the deeper depth's modifications up into markers,
/// records the retrace step, and installs D-1. Shared by the instant `popLayer()` and the portal animation's commit,
/// so both leave the exact same state behind.
///
/// `origin_coord`/`origin_pos` are where at the DEEPER depth a later return should put the player:
/// where they were standing, not the block they rose through.
///
/// Asserts `t.depth == game.depth - 1` (the world is still at the depth being left).
pub fn applyAscent(t: LayerTransition, origin_coord: Coordinate, origin_pos: Vec2i) void {
    std.debug.assert(t.depth == memory.game.depth - 1);
    markDescendantsFromChild(memory.game.depth);

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
/// The only descent allowed while spectating (see `isSpectating()`).
///
/// The block only picks the depth's coordinate frame; the player is put back on the exact spot they left from,
/// so a return lands where they were rather than on the target block's floor.
/// Still spectating afterwards if more steps remain, since the depth reached is still above the deepest.
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

/// Sets `descendant_mods` on every resident `SimBuffer` chunk from its `mod_store` descendants bitmap.
pub fn applyDescendantMarkersToSim() void {
    var it = mod_store.index.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        if (key.depth != memory.game.depth) continue;
        const entry = mod_store.entries.at(kv.value_ptr.*);
        var any: u64 = 0;
        for (entry.descendants) |w| any |= w;
        if (any == 0) continue;

        const chunk = SimBuffer.get(key.asCoord()) orelse continue;
        for (0..CHUNK_SIZE_SQ) |i| {
            if (entry.hasDescendantMods(@intCast(i))) chunk.blocks[i].descendant_mods = true;
        }
    }
}

/// Rolls every modification at `child_depth` up into a descendant marker on its parent block.
///
/// Only ever one level: an entry at `child_depth` already summarises everything below it,
/// because this ran when that depth was itself ascended past.
fn markDescendantsFromChild(child_depth: u64) void {
    std.debug.assert(child_depth == memory.game.depth); // `getParent()` resolves against the live depth
    const parent_depth = child_depth - 1;

    // collect child keys first
    // entry ptrs stay valid because of SegmentedList
    var mark_arena = memory.makeArena();
    defer mark_arena.deinit();
    var children: std.ArrayList(DepthCoordinate) = .empty;

    var it = mod_store.index.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        if (key.depth != child_depth) continue;
        if (!mod_store.entries.at(kv.value_ptr.*).anySet()) continue;
        children.append(mark_arena.allocator(), key) catch memory.oom();
    }

    for (children.items) |key| {
        const entry = mod_store.get(key).?;
        for (0..CHUNK_SIZE_SQ) |i| {
            const idx: u8 = @intCast(i);
            if (!entry.isModified(idx) and !entry.hasDescendantMods(idx)) continue;
            const p = dw.ancestor.getParentInfo(key, @intCast(idx & (CHUNK_SIZE - 1)), @intCast(idx >> CHUNK_SIZE_LOG2));
            mod_store.markDescendant(
                p.coord.asDepthCoordinate(parent_depth),
                (@as(u8, p.by) << CHUNK_SIZE_LOG2) | p.bx,
            );
        }
    }
}

/// Works out the D to D+1 transition without leaving any lasting change behind.
/// `coord` is the chunk the portal is in or where the depth should take place.
/// `bx` and `by` represent the specific block within a chunk the zoom should be in.
///
/// The rebase math past `HORIZON_DEPTH` reads the very globals it derives (quadrant seeds, rebase origins, the ancestor grid),
/// so this installs the in-progress state while it works and restores it before returning.
/// Callers therefore observe no change; apply the result with `commitLayer()` or `installLayer()`.
pub fn computeLayer(coord: Coordinate, bx: u4, by: u4, anchor: LayerAnchor) LayerTransition {
    const depth = memory.game.depth + 1;
    const snapshot = snapshotLayer(depth);
    defer restoreLayer(snapshot);

    const scale_vec: Vec2i = .{ ZOOM_FACTOR, ZOOM_FACTOR }; // per-axis zoom multiplier for player subpixels
    // Magic vertical pivot compensation (384 for factor 4 and block size 256)
    const pivot_y: i64 = (ZOOM_FACTOR - 1) * dw.CHUNK_SIZE_SQ / 2;

    var new_pos: Vec2i = undefined;
    var chunk_offset: Vec2i = .{ 0, 0 }; // extra whole-chunk shift when the pivot pushes past a chunk edge

    switch (anchor) {
        .player => {
            // new_pos: zoomed player position wrapped into one chunk (low bits kept; mask the last 12 bits, 0-4095)
            new_pos = @mod(memory.game.player_pos * scale_vec, @as(Vec2i, @splat(dw.SUBPIXELS_IN_CHUNK))) + Vec2i{ 0, pivot_y };
            // safely shift the chunk downwards if the vertical pivot overflowed the chunk bounds!
            if (new_pos[1] >= dw.SUBPIXELS_IN_CHUNK) {
                new_pos[1] -= dw.SUBPIXELS_IN_CHUNK;
                chunk_offset[1] = 1;
            }
        },
        .block_floor => {
            // The block grows into a ZOOM_FACTOR-by-ZOOM_FACTOR region of child blocks.
            // Its low bits pick the region within the child chunk; the high bits picked the chunk itself (below),
            // so the two always agree no matter where the player was standing.
            const region: i64 = dw.CHUNK_SIZE_SQ * ZOOM_FACTOR; // subpixels the region spans per axis
            const cell_x: i64 = @intCast(bx % ZOOM_FACTOR);
            const cell_y: i64 = @intCast(by % ZOOM_FACTOR);
            new_pos = .{
                cell_x * region + @divExact(region, 2), // horizontally centered
                // player rests on the region's floor
                (cell_y + 1) * region - PLAYER_FEET_OFFSET - 1, // - 1 or else there's a permanent collision with the ground
            };
        },
    }

    var t: LayerTransition = .{
        .depth = depth,
        .new_pos = new_pos,
        .player_chunk = memory.game.player_chunk,
        .player_quadrant = @intCast(memory.game.player_quadrant),
        .max_possible_suffix = max_possible_suffix,
    };

    // The coordinate helpers below resolve quadrants against the depth being entered, not the one being left.
    memory.game.depth = depth;

    if (depth <= HORIZON_DEPTH) {
        // Get the child chunk the player lands in. Zooming by 4x shifts the suffix left 2 bits,
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

        t.player_chunk = target_coord.suffix;
        t.player_quadrant = target_coord.quadrant;

        // this is reached at depth 32 (64 bits)
        t.max_possible_suffix = getMaxSuffixAtDepth(depth);
        return t;
    }

    // Rebase case logic (depth > HORIZON_DEPTH)
    t.rebase = true;
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
    t.most_left = quad_cache.most_left;
    t.most_right = quad_cache.most_right;
    t.most_top = quad_cache.most_top;
    t.most_bottom = quad_cache.most_bottom;
    t.left_cell = left_cell_x;
    t.top_cell = top_cell_y;

    // seeds of the four parent quadrants to reseed from (world seed on the first rebase depth)
    const old_hashes: ChunkSeeds = if (depth == HORIZON_DEPTH + 1) .{ .value = @splat(memory.game.seed) } else quad_cache.path_hashes;
    quad_cache.path_hashes = stepQuadrantSeeds(old_hashes, depth, left_cell_x, top_cell_y);

    t.path_hashes = quad_cache.path_hashes;

    writeRebasePath(depth, left_cell_x, top_cell_y);
    quad_cache.origins_x[@intCast(depth % QuadCache.HISTORY_LEN)] = @intCast(left_cell_x);
    quad_cache.origins_y[@intCast(depth % QuadCache.HISTORY_LEN)] = @intCast(top_cell_y);
    quad_cache.historical_seeds[@intCast(depth % QuadCache.HISTORY_LEN)] = quad_cache.path_hashes;

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

    // installed (not just captured): the ancestor summary below reads the entered quadrant and suffix!
    memory.game.player_chunk = target_coord.suffix;
    memory.game.player_quadrant = target_coord.quadrant;
    max_possible_suffix = std.math.maxInt(u64);
    t.player_chunk = target_coord.suffix;
    t.player_quadrant = target_coord.quadrant;
    t.max_possible_suffix = max_possible_suffix;

    const target_horizon_depth = depth - dw.HORIZON_DEPTH;
    if (target_horizon_depth >= STARTING_ZOOM_TIMES) {
        const trace = traceHorizon(target_coord, new_pos, depth, @intCast(coord.quadrant));
        t.horizon_trace = trace;
        t.ancestor_materials = refineHorizonWindow(
            &quad_cache.ancestor_materials,
            trace,
            target_horizon_depth,
        );
        t.has_materials = true;
    }

    return t;
}

/// Walks a transition's landing up to the horizon, producing the trace its window is centered on.
///
/// Asserts `memory.game.depth == depth` already, since `getParent()` resolves quadrants against it.
fn traceHorizon(target_coord: Coordinate, new_pos: Vec2i, depth: u64, source_quadrant: u2) HorizonTrace {
    std.debug.assert(memory.game.depth == depth);

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

    return .{
        .suffix = trace_coord.suffix,
        .quadrant = @intCast(trace_coord.quadrant),
        .bx = t_bx,
        .by = t_by,
        .player_quadrant = target_coord.quadrant,
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
                if (mod_store.getCell(child_key, block_idx)) |cell| {
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
        max_possible_suffix = saved_suffix;
    }

    memory.game = .{};
    mod_store.init(testing.allocator);
    defer mod_store.deinit();

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
        max_possible_suffix = saved_suffix;
        quad_cache.materials_path.len = saved_len;
        quad_cache.materials_windows.len = saved_windows;
        quad_cache.left_path.len = saved_path;
        quad_cache.top_path.len = saved_path;
    }

    memory.game = .{};
    mod_store.init(testing.allocator);
    defer mod_store.deinit();

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
    defer memory.game = saved_game;

    memory.game = .{};
    mod_store.init(testing.allocator);
    defer mod_store.deinit();

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

    // The chunk keeps its place inside the parent: cell * span + pos / ZOOM_FACTOR.
    const span = @divExact(@as(i64, dw.SUBPIXELS_IN_CHUNK), ZOOM_FACTOR);
    try testing.expectEqual(@as(i64, 13 % ZOOM_FACTOR) * span + @divFloor(@as(i64, 1000), ZOOM_FACTOR), up.new_pos[0]);
    try testing.expectEqual(@as(i64, 21 % ZOOM_FACTOR) * span + @divFloor(@as(i64, 500), ZOOM_FACTOR), up.new_pos[1]);

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

test "markDescendantsFromChild: rolls a deep edit into a parent marker, idempotently" {
    const saved_game = memory.game;
    defer memory.game = saved_game;

    mod_store.init(testing.allocator);
    defer mod_store.deinit();
    ascent_stack.clearRetainingCapacity();

    memory.game = .{};
    memory.game.depth = 10; // <= HORIZON_DEPTH so getParent() is a pure shift, no quad_cache needed

    const child: DepthCoordinate = .{ .suffix = .{ 12, 8 }, .depth = 10, .quadrant = 0 };
    const block_idx: u8 = (3 << CHUNK_SIZE_LOG2) | 6; // by=3, bx=6
    mod_store.beginWrite(child).setCell(block_idx, .{ .id = .stone, .base_id = .none, .hp = 0 });

    const p = dw.ancestor.getParentInfo(child, 6, 3);
    const parent_key = p.coord.asDepthCoordinate(9);
    const parent_idx: u8 = (@as(u8, p.by) << CHUNK_SIZE_LOG2) | p.bx;

    markDescendantsFromChild(10);
    try testing.expect(mod_store.get(parent_key).?.hasDescendantMods(parent_idx));

    // A second pass (a re-ascent of the same route) must leave the marker exactly as it was.
    markDescendantsFromChild(10);
    try testing.expect(mod_store.get(parent_key).?.hasDescendantMods(parent_idx));
}

/// A distinct `ModCell` per block index, so a misplaced cell is always detectable.
fn testCell(i: u8) ModCell {
    return .{ .id = @enumFromInt(@as(u16, i) + 1), .base_id = @enumFromInt(@as(u16, i) + 300), .hp = i % 16 };
}

test "ModEntry: cells stay indexable by block index regardless of insertion order" {
    mod_store.init(testing.allocator);
    defer mod_store.deinit();

    const key: DepthCoordinate = .{ .suffix = .{ 1, 2 }, .depth = 7, .quadrant = 0 };

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
    mod_store.init(testing.allocator);
    defer mod_store.deinit();

    const key: DepthCoordinate = .{ .suffix = .{ 0, 0 }, .depth = 6, .quadrant = 3 };
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
    mod_store.init(testing.allocator);
    defer mod_store.deinit();

    const key: DepthCoordinate = .{ .suffix = .{ 9, 9 }, .depth = 8, .quadrant = 1 };
    mod_store.beginWrite(key).setCell(5, .{ .id = .none, .base_id = .none, .hp = 0 });
    mod_store.beginWrite(key).setCell(200, .{ .id = .water, .base_id = .none, .hp = 9 });

    var chunk: Chunk = undefined;
    for (&chunk.blocks) |*b| b.* = .makeBasicBlock(.stone, 0xABCD);

    mod_store.get(key).?.applyTo(&chunk);

    for (chunk.blocks, 0..) |b, i| {
        // seed is regenerated by the procedural pass, never stored, so replay must leave it untouched
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

test "coordinate consistency: a block is the same whatever route reached it" {
    const saved_game = memory.game;
    const saved_suffix = max_possible_suffix;
    defer {
        memory.game = saved_game;
        max_possible_suffix = saved_suffix;
        clearCaches(true);
    }

    memory.game = .{};
    var rng = seeding.ChaCha12.init(&seeding.mixBaseSeed(memory.game.seed, .seed2_init));
    for (&memory.game.seed2) |*v| v.* = rng.next();
    quad_cache.path_hashes.value[0] = memory.game.seed;

    mod_store.init(testing.allocator);
    defer mod_store.deinit();

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
    mod_store.beginWrite(parent_key).setCell(37, .{ .id = .lava_stone, .base_id = .none, .hp = 0 });
    mod_store.beginWrite(parent_key).setCell(38, .{ .id = .none, .base_id = .none, .hp = 0 });
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

test "a 2x1 pair is placed and validated as one unit" {
    const saved_game = memory.game;
    const saved_suffix = max_possible_suffix;
    defer {
        memory.game = saved_game;
        max_possible_suffix = saved_suffix;
        clearCaches(true);
    }

    memory.game = .{};
    var rng = seeding.ChaCha12.init(&seeding.mixBaseSeed(memory.game.seed, .seed2_init));
    for (&memory.game.seed2) |*v| v.* = rng.next();
    quad_cache.path_hashes.value[0] = memory.game.seed;
    memory.game.depth = STARTING_ZOOM_TIMES;
    max_possible_suffix = getMaxSuffixAtDepth(memory.game.depth);

    mod_store.init(testing.allocator);
    defer mod_store.deinit();
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

        for (0..CHUNK_SIZE - 1) |by| {
            for (0..CHUNK_SIZE - 1) |bx| {
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

    // Placing the left half alone must leave BOTH halves standing: each demands the other,
    // so a pass that validated the first before writing the second would clear the pair right back out.
    try testing.expect(!modifyBlockType(coord, at.bx, at.by, .moss_shrub1, .empty));

    const idx: u8 = @intCast(@as(usize, at.by) * CHUNK_SIZE + at.bx);
    const entry = mod_store.get(key) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Sprite.moss_shrub1, (entry.get(idx) orelse return error.TestUnexpectedResult).id);
    try testing.expectEqual(Sprite.moss_shrub1_right, (entry.get(idx + 1) orelse return error.TestUnexpectedResult).id);

    // And the world agrees, not just the store.
    materializeChunk(&chunk, key);
    try testing.expectEqual(Sprite.moss_shrub1, chunk.blocks[idx].id);
    try testing.expectEqual(Sprite.moss_shrub1_right, chunk.blocks[idx + 1].id);
}

test "coordinate consistency: refinement reads a coordinate, not a route" {
    const saved_game = memory.game;
    defer memory.game = saved_game;

    memory.game = .{};
    var rng = seeding.ChaCha12.init(&seeding.mixBaseSeed(memory.game.seed, .seed2_init));
    for (&memory.game.seed2) |*v| v.* = rng.next();
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
