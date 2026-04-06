//! Defines the architecture of the fractal world, which is a segmented fractal coordinate system that uses a quad-cache for coordinates and corresponding seeds.
const std = @import("std");
const utils = @import("utils.zig");
const memory = @import("memory.zig");
const logger = @import("logger.zig");
const types = @import("types.zig");
const seeding = @import("seeding.zig");
const procedural = @import("procedural.zig");

const Chunk = memory.Chunk;
const Block = memory.Block;
const Coordinate = memory.Coordinate;
const SPAN = memory.SPAN;
const SPAN_SQ = memory.SPAN_SQ;
const SPAN_FLOAT = memory.SPAN_FLOAT;
const SPAN_LOG2 = memory.SPAN_LOG2;

/// Sprite IDs, based on src/main.png
pub const Sprite = enum(u20) {
    none = 0,
    player = 1,
    edge_stone = 2,
    stone = 3,
    green_stone = 4,
    iron = 5,
    silver = 6,
    gold = 7,
    spiral_plant = 10,
    ceiling_flower = 11,
    mushroom = 12,
    torch = 14,
    unchanged = 1048575,
};

/// Empty block of id `Sprite.none`
pub const AIR_BLOCK: Block = .{
    .id = .none,
    .seed = 0,
    .light = 0,
    .hp = 0,
    .edge_flags = 255,
};

/// 32-bit packed structure representing a single modified block within a chunk.
pub const BlockMod = packed struct(u32) {
    /// The type of the block being represented. (Defaults to a special sprite type that represents "same as what procedural generation would say".)
    id: Sprite = Sprite.unchanged,
    /// The edge flags. TODO decide if we want modifications to actually update edge flags or if these should be updated dynamically.
    edge_flags: u8 = undefined,
    /// How "mined" the block is. 0 is least mined, 15 is most mined. Unlike in other games like Terraria, this mined state is permanent and isn't "quietly undone" without player action.
    hp: u4 = undefined,
};

/// A full 256-block (chunk) of modifications.
pub const ChunkMod = [SPAN_SQ]BlockMod;

/// Arena for long-lasting data.
pub var world_arena = memory.make_arena();
const allocator = world_arena.allocator();

/// A 512-bit key for the ModificationStore.
/// Fits exactly into one 64-byte cache line.
pub const ModKey = extern struct {
    /// Represents 512 bits of data.
    seed: seeding.Seed, // aligned for cache size optimization

    pub fn init(base_seed: seeding.Seed, cx: u64, cy: u64) ModKey {
        var key = ModKey{ .seed = base_seed };
        // Safe bijection as Blake3 output is uniformly distributed.
        // XORing spatial data preserves entropy!
        key.seed[0] ^= cx;
        key.seed[1] ^= cy;
        return key;
    }
};

pub const ModKeyContext = struct {
    pub fn eql(self: @This(), a: ModKey, b: ModKey) bool {
        _ = self;
        // Zig optimizes this to SIMD if the target supports it.
        return std.mem.eql(u64, &a.seed, &b.seed);
    }
};

const SIM_BUFFER_WIDTH = 16;
const SIM_BUFFER_SIZE = SIM_BUFFER_WIDTH * SIM_BUFFER_WIDTH;
const CHUNK_CACHE_SIZE = 128;
const CHUNK_POOL_SIZE = SIM_BUFFER_SIZE + CHUNK_CACHE_SIZE;

/// A combined pool of SimBuffer and chunk cache data.
var chunk_pool: [CHUNK_POOL_SIZE]memory.Chunk = undefined;

pub const SimBuffer = struct {
    const sim_buffer_ptr: *[SIM_BUFFER_SIZE]memory.Chunk = chunk_pool[CHUNK_CACHE_SIZE..][0..SIM_BUFFER_SIZE];

    /// Returns the chunk from the specified x and y.
    pub inline fn get_index(cx: u64, cy: u64) usize {
        return (cy / SIM_BUFFER_WIDTH) * SIM_BUFFER_WIDTH + cx % SIM_BUFFER_WIDTH;
    }

    /// Sets a chunk from the specified x and y to the chunk instance given.
    pub inline fn set_index(chunk: *const memory.Chunk, cx: u64, cy: u64) void {
        sim_buffer_ptr[get_index(cx, cy)] = chunk;
    }
};

pub const ChunkCache = struct {
    var cache_keys: [CHUNK_CACHE_SIZE]?Coordinate = [_]?Coordinate{null} ** CHUNK_CACHE_SIZE;
    var cache_chunk_data: *[CHUNK_CACHE_SIZE]memory.Chunk = chunk_pool[0..CHUNK_CACHE_SIZE];

    // Clock metadata
    var cache_clock_bits: std.StaticBitSet(CHUNK_CACHE_SIZE) = std.StaticBitSet(CHUNK_CACHE_SIZE).initEmpty();
    var cache_hand: usize = 0;

    /// Retrieves a chunk if it exists, marking it as "recently used"
    pub fn get(coord: Coordinate) ?*memory.Chunk {
        for (&cache_keys, 0..) |maybe_key, i| {
            if (maybe_key) |k| {
                if (k.eql(coord)) {
                    cache_clock_bits.set(i); // give it a second chance (ref_bit becomes 1)
                    return &cache_chunk_data[i];
                }
            }
        }
        return null;
    }

    pub fn allocate_slot(coord: Coordinate) *memory.Chunk {
        while (true) {
            const idx = cache_hand;
            cache_hand = (cache_hand + 1) % CHUNK_CACHE_SIZE;

            if (cache_clock_bits.isSet(idx)) {
                // Give second chance: clear bit and move hand
                cache_clock_bits.setValue(idx, false);
            } else {
                // Found a "victim" (either null key or ref_bit was 0)
                cache_keys[idx] = coord;
                cache_clock_bits.set(idx); // Mark as recently used
                return &cache_chunk_data[idx];
            }
        }
    }

    /// Inserts a chunk using the clock algorithm to find an eviction candidate.
    pub fn insert(coord: Coordinate, chunk: memory.Chunk) *memory.Chunk {
        while (true) {
            const idx = cache_hand;

            // Advance the hand for next time
            cache_hand = (cache_hand + 1) % CHUNK_CACHE_SIZE;

            // Clock logic: second chance if ref_bit is 1, otherwise evict
            if (cache_clock_bits.isSet(idx)) {
                cache_clock_bits.setValue(idx, false);
            } else {
                cache_keys[idx] = coord;
                cache_chunk_data[idx] = chunk;
                cache_clock_bits.set(idx); // new entries start with ref bit as 1
                return &cache_chunk_data[idx];
            }
        }
    }

    pub fn clear() void {
        @memset(&cache_keys, null); // reset all keys
        cache_clock_bits = std.StaticBitSet(CHUNK_CACHE_SIZE).initEmpty(); // clear bitset
        cache_hand = 0; // reset hand
    }
};

/// UNUSED DUE TO BEING UNNECESSARY. Adds 1 to the path as if the `SegmentedList` represented one giant number. Performs allocation; the caller should deinit the path eventually using `world_arena`.
fn carry_path(path: *const std.SegmentedList(u64)) std.SegmentedList(u64) {
    const new_path = path.clone(world_arena.allocator()) catch @panic("carry alloc for QuadCache coordinates failed");
    world_arena.reset(.retain_capacity); // TODO decide
    var carry: u1 = 1;

    for (new_path.items) |*word| {
        const add_res = @addWithOverflow(word.*, @as(u64, carry));
        word.* = add_res[0];
        carry = add_res[1];

        if (carry == 0) break;
    }

    // If we still have a carry after the loop, the coordinate grew. However, this is NOT POSSIBLE because the quadrant logic should specifically disallow this (impl TODO)
    if (carry == 1) {
        unreachable;
    }

    return new_path;
}

const QuadrantEdgeDetails = struct {
    most_top: bool,
    most_bottom: bool,
    most_left: bool,
    most_right: bool,
};

/// A static 2x2 grid of seeds only updated on entering a portal/game startup. See `README.md` for a more detailed and intuitive explanation for what this does.
pub const QuadCache = struct {
    /// The 256-bit hashes for the 4 active quadrants, used for modifications across 16 depths (sequentially from D to D-15). (0: NW, 1: NE, 2: SW, 3: SE)
    path_hashes: [4][SPAN]seeding.Seed align(memory.MAIN_ALIGN_BYTES),
    /// Stores the leftmost QuadCache's X-coordinate.
    left_path: std.SegmentedList(u64, 4096),
    /// Stores the topmost QuadCache's Y-coordinate.
    top_path: std.SegmentedList(u64, 4096),
    /// The block IDs for each of the 4 places the QuadCache represents.
    ancestor_materials: [4]Sprite,

    // These 4 properties are used to determine if a QuadCache is at the very edge of the world for chunk gen/zooming in
    most_top: bool = true,
    most_bottom: bool = true,
    most_left: bool = true,
    most_right: bool = true,

    /// Returns a seed from the lineage history (0 is current later, 15 is D-15.)
    pub inline fn get_lineage_seed(self: *const @This(), quadrant: u2, lookback: u4) seeding.Seed {
        return self.path_hashes[quadrant][lookback];
    }

    // /// Returns the X-coordinate path of a specific quadrant. Unreachable call if path is empty (if depth is not > 16). Call `cleanup_path` afterward.
    // pub inline fn get_quadrant_path_x(self: *const @This(), quadrant: u2) std.SegmentedList(u64) {
    //     return if (quadrant % 2 == 0) self.left_path else carry_path(&self.left_path);
    // }

    // /// Returns the Y-coordinate path of a specific quadrant. Unreachable call if path is empty (if depth is not > 16). Call `cleanup_path` afterward.
    // pub inline fn get_quadrant_path_y(self: *const @This(), quadrant: u2) std.SegmentedList(u64) {
    //     return if (quadrant < 2) self.top_path else carry_path(&self.top_path);
    // }

    // /// Deallocates a temporary instance of a QuadCache path. (THIS DOESN'T WORK WITH ARENA)
    // pub inline fn cleanup_path(self: *const @This(), path: std.SegmentedList(u64)) void {
    //     // Memory comparison is safe because QuadCache will never be de-initialized, top_left_path is always non-empty (so nothing weird), and there's no multicore/async shenanigans here.
    //     if (self.left_path.items.ptr != path.items.ptr and self.top_path.items.ptr != path.items.ptr) {
    //         path.deinit(world_arena);
    //     }
    // }

    /// Returns the 512-bit seed of a specified quadrant.
    pub inline fn get_quadrant_seed(self: *const @This(), quadrant: u2) seeding.Seed {
        if (memory.game.depth <= 16) return memory.game.seed;
        return self.get_lineage_seed(quadrant, 0);
    }

    /// Resolves the chunk seeds. If depth > 16, uses the quadrant seeds.
    pub inline fn get_chunk_seeds(self: *const @This(), coord: Coordinate) [4]seeding.Seed {
        return seeding.mix_chunk_seeds(self.get_quadrant_seed(coord.quadrant), coord.suffix);
    }

    /// Returns details on a specific quadrant and what "edges" of the world it touches.
    pub inline fn get_quadrant_edge_details(self: *const @This(), quadrant: u2) QuadrantEdgeDetails {
        // Quadrant IDs for reference: 00: NW, 1: NE, 2: SW, 3: SE
        if (memory.game.depth <= 16) {
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

/// The QuadCache that stores information about the 4 quadrants and their seeds.
pub var quad_cache: QuadCache = .{
    .path_hashes = undefined,
    .left_path = std.SegmentedList(u64, 4096){},
    .top_path = std.SegmentedList(u64, 4096){},
    .ancestor_materials = .{Sprite.none} ** 4,
};

/// Represents the answer to the question "what is the largest possible suffix value"? 15 at depth 1, 255 at depth 2, capped at 2**64-1 at depth 16 and beyond.
pub var max_possible_suffix: u64 = 0;

/// Temporary storage data for calculations. (In order: chunk above, to the left, to the right, below)
var edge_flags_data: [9]memory.Chunk = undefined;
/// Allocator used for the world.
var alloc = std.mem.Allocator;

/// Creates a new instance of a `Chunk` where specified, given a coordinate. Copies over from cache if possible. Does not update edge flags.
pub fn write_chunk(chunk: *memory.Chunk, coord: Coordinate) void {
    // logger.write(3, .{ "{h}Chunk requested", coord });
    // TODO use SimBuffer

    if (ChunkCache.get(coord)) |cached_ptr| { // see if it's in the cache, if it's not in SimBuffer
        chunk.* = cached_ptr.*; // Copy from cache to caller
        return;
    }

    const new_slot_ptr = ChunkCache.allocate_slot(coord); // we must create the chunk now
    generate_chunk(new_slot_ptr, coord); // generate the data in the cache's memory
    chunk.* = new_slot_ptr.*; // make a copy for a result
    // TODO handle new modification logic when the time comes
}

/// Creates a new instance of a `Chunk`. Does not update edge flags.
pub inline fn get_chunk(coord: Coordinate) memory.Chunk {
    var chunk: memory.Chunk = undefined;
    write_chunk(&chunk, coord);
    return chunk;
}

/// Internal function to generate a whole chunk (considering modifications), given a pointer to where the chunk should be stored and coordinates. Does not go through the cache.
fn generate_chunk(chunk: *memory.Chunk, coord: Coordinate) void {
    const chunk_seeds = quad_cache.get_chunk_seeds(coord);
    const rng1 = seeding.ChaCha12.init(chunk_seeds[0]); // Block generation.
    const rng3 = seeding.ChaCha12.init(chunk_seeds[2]);
    var rng4 = seeding.ChaCha12.init(chunk_seeds[3]); // Visual touches only.

    _ = rng1;
    _ = rng3;

    const cx = coord.suffix[0];
    const cy = coord.suffix[1];
    const quadrant_edge_details = quad_cache.get_quadrant_edge_details(coord.quadrant);

    for (0..SPAN) |block_y| {
        for (0..SPAN) |block_x| {
            const id = (block_y * SPAN) + block_x;

            // simple edge-of-the-world solid block logic
            const is_absolute_edge_x = (cx == 0 and block_x < 2 and quadrant_edge_details.most_left) or (cx == max_possible_suffix and block_x >= (SPAN - 2) and quadrant_edge_details.most_right);
            const is_absolute_edge_y = (cy == 0 and block_y < 2 and quadrant_edge_details.most_top) or (cy == max_possible_suffix and block_y >= (SPAN - 2) and quadrant_edge_details.most_bottom);
            if (is_absolute_edge_x or is_absolute_edge_y) {
                chunk.blocks[id] = Block.make_basic_block(.edge_stone, rng4.next());
                // This does mean there are fewer PRNG .next() calls but this doesn't matter here
                continue;
            }

            // Use density to influence block generation
            const density = procedural.get_value_noise(chunk_seeds[1], @as(f64, @floatFromInt(block_x)) / SPAN, @as(f64, @floatFromInt(block_y)) / SPAN);
            chunk.blocks[id] = Block.make_basic_block(
                procedural.generate_initial_block(0.0, density, 0.0),
                rng4.next(),
            ); // edge flags updated in second pass
        }
    }
}

/// Adds edge flags to an already generated chunk. Requests adjacent chunks in a 3x3.
pub fn add_edge_flags(target_chunk: *memory.Chunk, coord: Coordinate) void {
    // Since getting chunks is way more expensive than branch mispredictions,
    // having lazy-fetch logic is almost certainly faster here :)
    var neighbors: [9]?*const memory.Chunk = .{null} ** 9;
    neighbors[4] = target_chunk; // center chunk is always available

    // Interior blocks (1..15) never go out of bounds, working with the same chunk!
    for (1..SPAN - 1) |ly| {
        for (1..SPAN - 1) |lx| {
            const id = ly * SPAN + lx;
            if (!should_participate_in_edge_flags(target_chunk.blocks[id].id)) {
                target_chunk.blocks[id].edge_flags = 0xFF; // prevent erosion/edge darkening
                continue;
            }

            var flags: u8 = 0;
            inline for (.{ -1, 0, 1 }) |dy| {
                inline for (.{ -1, 0, 1 }) |dx| {
                    if (dx == 0 and dy == 0) continue;
                    const nx = @as(usize, @intCast(@as(i32, @intCast(lx)) + dx));
                    const ny = @as(usize, @intCast(@as(i32, @intCast(ly)) + dy));
                    if (should_participate_in_edge_flags(target_chunk.blocks[ny * 16 + nx].id)) {
                        flags |= types.EdgeFlags.get_flag_bit(dx, dy);
                    }
                }
            }
            target_chunk.blocks[id].edge_flags = flags;
        }
    }

    // Edge blocks (row 0, row 15, col 0, col 15), save neighbor chunk logic for here
    for (0..SPAN) |ly| {
        for (0..SPAN) |lx| {
            if (lx >= 1 and lx < SPAN - 1 and ly >= 1 and ly < SPAN - 1) continue;

            const id = ly * SPAN + lx;
            if (!is_solid(target_chunk.blocks[id].id)) {
                target_chunk.blocks[id].edge_flags = 0xFF; // prevent erosion/edge darkening
                continue;
            }

            var flags: u8 = 0;
            inline for (.{ -1, 0, 1 }) |dy| {
                inline for (.{ -1, 0, 1 }) |dx| {
                    if (dx == 0 and dy == 0) continue;

                    const nx = @as(i32, @intCast(lx)) + dx;
                    const ny = @as(i32, @intCast(ly)) + dy;

                    const block_is_solid = if (nx >= 0 and nx < 16 and ny >= 0 and ny < 16)
                        is_solid(target_chunk.blocks[@as(usize, @intCast(ny * 16 + nx))].id)
                    else blk: {
                        const neighbor_x = @as(usize, @intCast(@mod(nx, 16)));
                        const neighbor_y = @as(usize, @intCast(@mod(ny, 16)));
                        // Determine which of the 9 chunks in our grid to sample
                        const grid_x = if (nx < 0) @as(usize, 0) else if (nx >= 16) @as(usize, 2) else 1;
                        const grid_y = if (ny < 0) @as(usize, 0) else if (ny >= 16) @as(usize, 2) else 1;
                        const idx = grid_y * 3 + grid_x;

                        if (neighbors[idx] == null) {
                            @branchHint(.unlikely); // each neighbor fetched at most once
                            const neighbor_coord = coord.move(.{ @as(i64, @intCast(grid_x)) - 1, @as(i64, @intCast(grid_y)) - 1 });
                            edge_flags_data[idx] = if (neighbor_coord) |c| get_chunk(c) else std.mem.zeroes(memory.Chunk);
                            neighbors[idx] = &edge_flags_data[idx];
                        }
                        break :blk is_solid(neighbors[idx].?.blocks[neighbor_y * 16 + neighbor_x].id);
                    };

                    if (block_is_solid) flags |= types.EdgeFlags.get_flag_bit(dx, dy);
                }
            }
            target_chunk.blocks[id].edge_flags = flags;
        }
    }
}

/// Determines if a block should interact with the edge flags.
pub inline fn should_participate_in_edge_flags(sprite: Sprite) bool {
    return switch (sprite) {
        .none,
        .spiral_plant,
        .torch,
        .edge_stone,
        .mushroom,
        => false,
        else => true,
    };
}

/// Determines if a block is considered solid, and should interact with the physics, player, and edge flags.
pub inline fn is_solid(sprite: Sprite) bool {
    return switch (sprite) {
        .none,
        .spiral_plant,
        .torch,
        .mushroom,
        => false,
        else => true,
    };
}

// /// The 16-step ascendent projection read loop thingy
// /// Called when the SimBuffer generates a chunk.
// pub fn get_effective_modification(self: *@This(), cx: u64, cy: u64) ?*ChunkMod {
//     var search_cx = cx;
//     var search_cy = cy;

//     // Start from current depth (0) and look up to 15 ancestors
//     // We use the cached path_stack so we don't have to reverse hashes
//     const max_lookback = @min(16, memory.game.depth);

//     for (0..max_lookback) |i| {
//         const key = ModKey{
//             .path_hash = quad_cache.TODO[i],
//             .cx = search_cx,
//             .cy = search_cy,
//         };

//         if (mod_store.index.get(key)) |id| {
//             return &mod_store.history.items[id];
//         }

//         // Move to parent coordinate: shift off the lowest 4 bits (the block coordinates)
//         search_cx >>= 4;
//         search_cy >>= 4;
//     }
//     return null;
// }

/// Handles increasing the depth.
/// `coord` is the chunk the portal is in. `bx` and `by` represent the specific block within a chunk the zoom should be in.
pub fn push_layer(parent_id: Sprite, coord: Coordinate, bx: u4, by: u4) void {
    _ = parent_id;
    memory.game.depth += 1;
    const depth = memory.game.depth;

    // Mask the last 12 bits (0-4095)
    memory.game.player_velocity = .{ 0, 0 };

    const player_mask: i64 = SPAN * SPAN * SPAN - 1;
    const new_pos: memory.v2i64 = .{
        (memory.game.player_pos[0] << SPAN_LOG2) & player_mask,
        (memory.game.player_pos[1] << SPAN_LOG2) & player_mask,
    };
    memory.game.set_player_pos(new_pos);
    memory.game.set_camera_pos(new_pos);
    // TODO migrate to this logic when implementing portals instead
    // memory.game.set_player_pos(.{ 2048, 2048 });
    // memory.game.set_camera_pos(.{ 2048, 2048 });

    // TODO also clear SimBuffer
    ChunkCache.clear();

    if (depth <= 16) {
        // Just filling up the 64-bit suffix. No rebasing needed yet.
        memory.game.player_chunk[0] = (coord.suffix[0] << SPAN_LOG2) | bx;
        memory.game.player_chunk[1] = (coord.suffix[1] << SPAN_LOG2) | by;

        // Update the maximum possible suffix value here using some fancy bit-shifting logic
        max_possible_suffix = if (depth == 16)
            std.math.maxInt(u64)
        else
            (@as(u64, 1) << @intCast(depth * SPAN_LOG2)) - 1;

        return;
    }

    // Here, we use a fixed-point rebasing algorithm.
    // Basically, our goal is to maximize the distance the player has to go before the game crashes (from being unable to represent a Coordinate using a valid quadrant).
    // We can consider this problem on depth increase (handled in this function) as turning the ordinary 2x2 grid of "cells" (4 quadrants) into a 32x32 grid instead (since we are increasing by a depth, this makes logical sense).
    // We're trying to "select" which cell should be our top left one with this algorithm.

    // Using the coordinate, we determine which cell in the current 32x32 grid the player is. Call this cell's coordinates (x, y). In this cell, we find which corner the player is closest to (using coordinate and bx/by as tie-breaker).
    // If the player is on the left half of a cell, we shift the window left by 1 (subtract 1).
    // If they are on the right half, we keep the window aligned with the cell (no subtraction).

    // This ensures the player always has at least 1 cell of padding in all directions before hitting the edge of the 2x2 QuadCache.
    // We also clamp both axes for the new cell's coordinates to be between 0 and 30, so the 2x2 window doesn't exceed the parent's 32x32 bounds.

    // The actual implementation applies all this logic by doing a bunch of management work between the "prefix" (big SegmentedList) and "suffix" (coordinate of the player), and updates the quadrant of where the player is as necessary. We want to select the right prefix, and move the player to the correct quadrant and position.

    // identify the bits falling off the top (the "oldest" part of the suffix that will get merged into the QC path)
    const shift = 64 - SPAN_LOG2; // 60
    const top_x = coord.suffix[0] >> shift;
    const top_y = coord.suffix[1] >> shift;

    // determine if the player is in the left/top half of the new zoomed-in area
    // do this by masking out the top 4 bits to look at the remaining 60 bits of precision
    const midpoint: u64 = 1 << (shift - 1);
    const is_more_left = (coord.suffix[0] & 0x0FFFFFFF_FFFFFFFF) < midpoint;
    const is_more_top = (coord.suffix[1] & 0x0FFFFFFF_FFFFFFFF) < midpoint;

    const parent_quadrant_x = utils.intFromBool(u64, (memory.game.player_quadrant % 2) != 0); // old quadrant
    const parent_quadrant_y = utils.intFromBool(u64, (memory.game.player_quadrant / 2) != 0);
    const naive_cell_x = (parent_quadrant_x << SPAN_LOG2) | top_x; // value from 0-31 that does not consider the midpoint calculation
    const naive_cell_y = (parent_quadrant_y << SPAN_LOG2) | top_y;

    // determine the origin for the NEW QuadCache window relative to the OLD origin
    // subtract 1 if the player is in the left or top half to keep them centered.
    const highest_possible_top_left_cell = (SPAN - 1) * 2; // a mouthful!
    var left_cell_x: u64 = naive_cell_x -| utils.intFromBool(u64, is_more_left); // saturating subtraction effectively acts as @max(n, 0) without @as casting
    var top_cell_y: u64 = naive_cell_y -| utils.intFromBool(u64, is_more_top);
    left_cell_x = @min(left_cell_x, highest_possible_top_left_cell); // clamp (explained above in the big comment section)
    top_cell_y = @min(top_cell_y, highest_possible_top_left_cell);

    // update edge flags used in generate_chunk()
    quad_cache.most_left = quad_cache.most_left and left_cell_x == 0;
    quad_cache.most_right = quad_cache.most_right and left_cell_x == highest_possible_top_left_cell;
    quad_cache.most_top = quad_cache.most_top and top_cell_y == 0;
    quad_cache.most_bottom = quad_cache.most_bottom and top_cell_y == highest_possible_top_left_cell;

    var parent_seeds: [4]seeding.Seed = undefined; // save older seeds
    inline for (0..4) |i| parent_seeds[i] = quad_cache.path_hashes[i][0];

    const SPAN_MASK = SPAN - 1; // 0xF

    // update the seed lineage for all 4 quadrants
    inline for (0..4) |q_id| {
        const slice = &quad_cache.path_hashes[q_id];
        std.mem.copyBackwards(seeding.Seed, slice[1..SPAN], slice[0 .. SPAN - 1]);

        const cell_x = left_cell_x + utils.intFromBool(u64, q_id % 2 == 1);
        const cell_y = top_cell_y + utils.intFromBool(u64, q_id >= 2);

        // map this cell back to the specific parent quadrant (0-3)
        const old_q_id = utils.intFromBool(usize, cell_x >= SPAN) + utils.intFromBool(usize, cell_y >= SPAN) * 2;

        slice[0] = seeding.mix_coordinate_seed(
            parent_seeds[old_q_id],
            cell_x & SPAN_MASK,
            cell_y & SPAN_MASK,
        );
    }

    // update the prefix path (which is a SegmentedList)
    if ((depth - (SPAN + 1)) % SPAN == 0) {
        quad_cache.left_path.append(world_arena.allocator(), left_cell_x) catch @panic("quad-cache append failed");
        quad_cache.top_path.append(world_arena.allocator(), top_cell_y) catch @panic("quad-cache append failed");
    } else {
        // quad_cache.left_path.len - 1 = (depth - 1) / 16 - 1
        const last_path_index: usize = @intCast((depth - 1) / 16 - 1);
        const l_ptr: *u64 = quad_cache.left_path.at(last_path_index);
        const t_ptr: *u64 = quad_cache.top_path.at(last_path_index);

        // Remove the | SPAN_MASK which was forcing bits to 1111
        l_ptr.* = (l_ptr.* << SPAN_LOG2) + left_cell_x;
        t_ptr.* = (t_ptr.* << SPAN_LOG2) + top_cell_y;
    }

    // finalize player state
    memory.game.player_chunk[0] = (coord.suffix[0] << SPAN_LOG2) | bx;
    memory.game.player_chunk[1] = (coord.suffix[1] << SPAN_LOG2) | by;

    const quadrant_x = naive_cell_x - left_cell_x;
    const quadrant_y = naive_cell_y - top_cell_y;
    memory.game.player_quadrant = @intCast(quadrant_x + (quadrant_y * 2));
}

// /// Helper to maintain the sliding window of hashes for fast lookups
// fn push_path_to_stack(self: *@This(), new_hash: seeding.Seed) void {
//     // Shift everything down 1
//     var i: usize = 15;
//     while (i > 0) : (i -= 1) {
//         path_stack[i] = path_stack[i - 1];
//     }
//     // Insert new current path at index 0
//     path_stack[0] = new_hash;
// }

/// Multiplies a float by 2**64, returning an integer x such that a random u64 value has its probability to be less than x equal to the chance variable.
pub inline fn odds_num(chance: comptime_float) u64 {
    return @intFromFloat(chance * 18446744073709551616.0);
}

// /// Convert screen pixels to a world block coordinate
// pub fn screen_to_world(screen_x: f64, screen_y: f64, viewport_w: f64, viewport_h: f64, cam_x: f64, cam_y: f64, zoom: f64) @Vector(2, f64) {
//     const target_chunk_offset_x = @divFloor(world_subpixel_x, 4096);
//     const target_chunk_offset_y = @divFloor(world_subpixel_y, 4096);

//     const target_chunk_x = game.player_chunk[0] +% @as(u64, @bitCast(target_chunk_offset_x));
//     const target_chunk_y = game.player_chunk[1] +% @as(u64, @bitCast(target_chunk_offset_y));

//     const block_x = @divFloor(@mod(world_subpixel_x, 4096), 256);
//     const block_y = @divFloor(@mod(world_subpixel_y, 4096), 256);

//     // Returns exact block coordinate. @floor() this to get the integer block index.
//     return .{ world_x / SPAN, world_y / SPAN };
// }
