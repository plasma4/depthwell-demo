//! Defines the architecture of the fractal world, which is a segmented fractal coordinate system that uses a quad-cache for coordinates and corresponding seeds.
const std = @import("std");
const memory = @import("memory.zig");
const logger = @import("logger.zig");
const types = @import("types.zig");
const seeding = @import("seeding.zig");

const Chunk = memory.Chunk;
const Block = memory.Block;
const SPAN = memory.SPAN;
const SPAN_LOG2 = memory.SPAN_LOG2;

/// The single instance of a `World`.
pub var state: World = undefined;

/// Sprite IDs, based on src/main.png
pub const Sprite = enum(u20) {
    none = 0,
    player = 1,
    edgestone = 2,
    stone = 3,
    greenstone = 4,
    bluestone = 5,
    bloodstone = 6,
    torch = 9,
    mushroom = 7,
    unchanged = 1048575,
};

/// Empty block of id Sprite.none
pub const AIR_BLOCK: Block = .{ .id = Sprite.none, .seed = 0, .light = 255, .hp = 0, .edge_flags = 0 };

/// 32-bit packed structure representing a single modified block within a chunk.
pub const BlockMod = packed struct(u32) {
    /// The type of the block being represented. (Defaults to a special sprite type that represents "same as what procedural generation would say".)
    id: Sprite = Sprite.unchanged,
    // /// X-coordinate of the modified block within the chunk.
    // x: u4,
    // /// Y-coordinate of the modified block within the chunk.
    // y: u4,
    /// How "mined" the block is. 0 is least mined, 15 is most mined. Unlike in other games like Terraria, this mined state is permanent and isn't "quietly undone" without player action.
    hp: u4,
};

/// A full 256-block (chunk) of modifications.
pub const ChunkMod = [memory.SPAN_SQ]BlockMod;

/// A 512-bit key for the ModificationStore.
/// Fits exactly into one 64-byte cache line.
pub const ModKey = extern struct {
    /// Represents 512 bits of data.
    seed: seeding.Seed align(memory.MAIN_ALIGN_BYTES), // aligned for cache size optimization

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
    // pub fn hash(self: @This(), key: ModKey) u64 {
    //     _ = self;
    //     // Fast "folding" of the 512-bit key into a 64-bit hash for the map.
    //     // This is extremely cheap and ensures all bits contribute to the bucket index.
    //     const s = key.seed;
    //     return s[0] ^ s[1] ^ s[2] ^ s[3] ^ s[4] ^ s[5] ^ s[6] ^ s[7];
    // }
    pub fn eql(self: @This(), a: ModKey, b: ModKey) bool {
        _ = self;
        // Zig optimizes this to SIMD if the target supports it.
        return std.mem.eql(u64, &a.seed, &b.seed);
    }
};

/// Constant-size buffer caching the simulation buffer. 512 KiB in size.
pub const SimBuffer = struct {
    chunks: [256]*memory.Chunk, // hard-capped to 256, representing a 16x16 area around the player

    /// Returns the chunk from the specified x and y.
    pub inline fn get_index(cx: u64, cy: u64) usize {
        return (@as(usize, cy & 0xF) << 4) | @as(usize, cx & 0xF);
    }

    /// Sets a chunk from the specified x and y to a new chunk.
    pub inline fn set_index(self: *@This(), new_chunk: *const memory.Chunk, cx: u64, cy: u64) void {
        self.chunks[(@as(usize, cy & 0xF) << 4) | @as(usize, cx & 0xF)] = new_chunk;
    }
};

/// Generates an initial block for seeding.
pub inline fn generate_initial_block(rng: *seeding.ChaCha12) Sprite {
    const entropy = rng.next();

    var block_id = Sprite.none;
    if (entropy < odds_num(0.3)) {
        block_id = Sprite.none;
    } else if (entropy < odds_num(0.9)) {
        block_id = Sprite.stone;
    } else if (entropy < odds_num(0.93)) {
        block_id = Sprite.greenstone;
    } else if (entropy < odds_num(0.95)) {
        block_id = Sprite.bluestone;
    } else {
        block_id = Sprite.bloodstone;
    }
    return block_id;
}

/// Adds 1 to the path as if the ArrayList represented one giant number. Performs allocation; the caller should deinit the path eventually.
fn carry_path(path: *const std.ArrayList(u64)) std.ArrayList(u64) {
    const new_path = path.clone(memory.allocator) catch @panic("carry alloc for QuadCache coordinates failed");
    var carry: u1 = 1;

    for (new_path.items) |*word| {
        // add_res is { .value = result, .overflow = 0 or 1 }
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
    path_hashes: [4][16]seeding.Seed align(memory.MAIN_ALIGN_BYTES),
    /// Stores the leftmost QuadCache's X-coordinate.
    left_path: std.ArrayList(u64),
    /// Stores the topmost QuadCache's Y-coordinate.
    top_path: std.ArrayList(u64),
    /// The block IDs for each of the 4 places the QuadCache represents.
    ancestor_materials: [4]Sprite,

    // These 4 properties are used to determine if a QuadCache is at the very edge of the world for chunk gen
    most_top: bool = true,
    most_bottom: bool = true,
    most_left: bool = true,
    most_right: bool = true,

    /// Returns a seed from the lineage history (0 is current later, 15 is D-15.)
    pub inline fn get_lineage_seed(self: *const @This(), quadrant: u2, lookback: u4) seeding.Seed {
        return self.path_hashes[quadrant][lookback];
    }

    /// Returns the X-coordinate path of a specific quadrant. Unreachable call if path is empty (if depth is not > 16).
    pub inline fn get_quadrant_path_x(self: *const @This(), quadrant: u2) std.ArrayList(u64) {
        return if (quadrant % 2 == 0) self.left_path else carry_path(&self.left_path);
    }

    /// Returns the Y-coordinate path of a specific quadrant. Unreachable call if path is empty (if depth is not > 16).
    pub inline fn get_quadrant_path_y(self: *const @This(), quadrant: u2) std.ArrayList(u64) {
        return if (quadrant < 2) self.top_path else carry_path(&self.top_path);
    }

    /// Deallocates a temporary instance of a QuadCache path.
    pub inline fn cleanup_path(self: *const @This(), path: std.ArrayList(u64)) void {
        // Memory comparison is safe because QuadCache will never be de-initialized, top_left_path is always non-empty (so nothing weird), and there's no multicore/async shenanigans here.
        if (self.left_path.items.ptr != path.items.ptr and self.top_path.items.ptr != path.items.ptr) {
            path.deinit(memory.allocator);
        }
    }

    /// Returns the 512-bit seed of a specified quadrant.
    pub inline fn get_quadrant_seed(self: *const @This(), quadrant: u2) seeding.Seed {
        if (memory.game.depth <= 16) return memory.game.seed;
        return self.get_lineage_seed(quadrant, 0);
    }

    /// Resolves the chunk seeds. If depth > 16, uses the quadrant seeds.
    pub inline fn get_chunk_seeds(self: *const @This(), coord: memory.Coordinate) [4]seeding.Seed {
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

/// The "fractal lineage sparse set" that stores all modifications. Modifications of "higher" D-values are prioritized, and lower D-values are used for backgrounds/procedural generation; at any depth D, individual blocks are still individual blocks. (See `README.md` for depth's meaning and more details.)
///
/// Reading performance is an amortized O(1) due only needing to consider block sizes between depth D-15 to D.
///
/// Writing performance is an amortized O(1) due to needing to find a `HashMap.
///
/// Increasing depth is, surprisingly, an O(1) operation due to a lack of culling (to show a "spectator view" on death), and storing where things are with a 256-bit ModKey and assuming that collisions are impossible.
///
/// Space complexity is O(n) based on the number of modified chunks. Even if all modifications are reversed, each modified chunk still takes up 1KiB in history, plus additional index memory (so slightly more).
pub const FLSS = struct {
    /// Dense, fragmentation-free storage of all chunk modifications.
    history: std.ArrayList(ChunkMod),
    /// Maps a coordinate (u64) to an index in the `history` array.
    index: std.AutoHashMap(ModKey, u64), // 64-bit "pointer" to prevent headaches between Memory32/64/native.

    pub fn init(alloc: std.mem.Allocator) FLSS {
        return .{
            .history = std.ArrayList(ChunkMod).init(alloc),
            .index = std.AutoHashMap(ModKey, u64).init(alloc),
        };
    }

    /// Appends a modification.
    pub fn put_modification(self: *@This(), key: ModKey, mod: BlockMod) !void {
        const result = try self.index.getOrPut(key);
        if (!result.found_existing) {
            // New chunk modified. Append a new 256-block array to the history.
            const new_idx = @as(u64, @intCast(self.history.items.len));
            var new_data = std.mem.zeroes(ChunkMod);
            new_data.mods[0] = mod;
            try self.history.append(new_data);
            result.value_ptr.* = new_idx;
        } else {
            // Chunk already modified, so update existing array!
            const idx = result.value_ptr.*;
            var data = &self.history.items[idx];

            // Overwrite existing block if it exists, otherwise append
            var found = false;
            for (0..data.count) |i| {
                if (data.mods[i].x == mod.x and data.mods[i].y == mod.y) {
                    data.mods[i] = mod;
                    found = true;
                    break;
                }
            }
            if (!found and data.count < 256) {
                data.mods[data.count] = mod;
                data.count += 1;
            }
        }
    }
};

pub const CachedChunk = struct {
    x: u64,
    y: u64,
    depth: u64,
    quadrant: u32,
    chunk_ptr: ?*memory.Chunk = null,
};

/// Stores the blocks and state of the world of Depthwell.
pub const World = struct {
    /// Allocator used in the World.
    alloc: std.mem.Allocator,
    /// A SimBuffer with 256 chunks that is cached to prevent constant recalculations (effectively centered around the player and constantly rearranged). TODO actual shifting logic along with chunk_cache, of course
    sim_buffer: SimBuffer,
    /// A super simple LRU that stores chunks accessed recently, particularly useful for edge flags and temporary logic like sim_buffer shifting that could potentially exceed the `SimBuffer`'s boundaries. Stores just 64 chunks, and checked after the SimBuffer through linear search. TODO, implement and add search features.
    chunk_cache: [64]CachedChunk,
    /// Actual raw chunk data stored in the chunk_cache.
    chunk_cache_data: [64]*memory.Chunk,
    /// The QuadCache that stores information about the 4 quadrants and their seeds.
    quad_cache: QuadCache,
    /// Represents the answer to the question "what is the largest possible suffix value"? 15 at depth 1, 255 at depth 2, capped at 2**64-1 at depth 16 and beyond.
    max_possible_suffix: u64 = 0,

    pub fn init(alloc: std.mem.Allocator) World {
        return .{
            .alloc = alloc,
            .sim_buffer = undefined,
            .quad_cache = .{
                .path_hashes = undefined,
                .left_path = std.ArrayList(u64){
                    .items = &[_]u64{},
                    .capacity = 0,
                },
                .top_path = std.ArrayList(u64){
                    .items = &[_]u64{},
                    .capacity = 0,
                },
                .ancestor_materials = .{Sprite.none} ** 4,
            },
            .chunk_cache = undefined,
            .chunk_cache_data = undefined,
            // .modification_store = std.HashMap(ModKey, memory.ModifiedChunk, ModKeyContext, 80).init(alloc),
        };
    }

    pub fn get_chunk(self: *const @This(), coord: memory.Coordinate) *memory.Chunk {
        // logger.write(3, .{ "{h}Chunk requested", coord });
        // TODO figure out this whole allocation and SimBuffer/chunk_cache usage business
        const chunk = self.alloc.create(memory.Chunk) catch @panic("chunk alloc failed");
        self.generate_chunk(chunk, coord);
        return chunk;
    }

    /// Generates a whole chunk (considering modifications), given a pointer to where the chunk should be stored and coordinates.
    pub fn generate_chunk(self: *const @This(), chunk: *memory.Chunk, coord: memory.Coordinate) void {
        const chunk_seed = self.quad_cache.get_chunk_seeds(coord);
        var rng1 = seeding.ChaCha12.init(chunk_seed[0]); // Block generation.
        const rng2 = seeding.ChaCha12.init(chunk_seed[1]);
        const rng3 = seeding.ChaCha12.init(chunk_seed[2]);
        var rng4 = seeding.ChaCha12.init(chunk_seed[3]); // Visual touches only.

        _ = rng2;
        _ = rng3;

        const cx = coord.suffix[0];
        const cy = coord.suffix[1];
        const quadrant_edge_details = self.quad_cache.get_quadrant_edge_details(coord.quadrant);
        for (0..SPAN) |ly| {
            for (0..SPAN) |lx| {
                const idx = (ly * SPAN) + lx;

                // TODO make this work with quadcache to still work for edges
                const is_absolute_edge_x = (cx == 0 and lx == 0 and quadrant_edge_details.most_left) or (cx == state.max_possible_suffix and lx == 15 and quadrant_edge_details.most_right);
                const is_absolute_edge_y = (cy == 0 and ly == 0 and quadrant_edge_details.most_top) or (cy == state.max_possible_suffix and ly == 15 and quadrant_edge_details.most_bottom);
                if (is_absolute_edge_x or is_absolute_edge_y) {
                    chunk.blocks[idx] = make_basic_block(.edgestone);
                    // This does mean there are fewer .next() calls but this doesn't matter here
                    continue;
                }

                const block_id = generate_initial_block(&rng1);
                const entropy = rng4.next();
                chunk.blocks[idx] = .{
                    .id = block_id,
                    .light = @truncate(entropy),
                    .seed = @truncate(entropy >> 8),
                    .hp = 15,
                    .edge_flags = 0, // will be updated in second pass
                };
            }
        }

        for (0..SPAN) |ly| {
            for (0..SPAN) |lx| {
                const idx = (ly * SPAN) + lx;
                if (chunk.blocks[idx].id == .none) continue; // air doesn't need edge flags
                // TODO edge flags across differing chunks!

                var flags: u8 = 0;
                const sly: i32 = @intCast(ly);
                const slx: i32 = @intCast(lx);

                // Check the 8 neighbors
                comptime var dy: i32 = -1;
                inline while (dy <= 1) : (dy += 1) {
                    comptime var dx: i32 = -1;
                    inline while (dx <= 1) : (dx += 1) {
                        if (dx == 0 and dy == 0) continue;

                        const ny = sly + dy;
                        const nx = slx + dx;

                        // Bounds check: Stay within this chunk
                        if (ny >= 0 and ny < SPAN and nx >= 0 and nx < SPAN) {
                            const neighbor_idx = @as(usize, @intCast(ny * SPAN + nx));
                            if (chunk.blocks[neighbor_idx].id != .none) {
                                flags |= types.EdgeFlags.get_flag_bit(dx, dy);
                            }
                        }
                    }
                }
                chunk.blocks[idx].edge_flags = flags;
            }
        }
    }

    /// The 16-step ascendent projection read loop thingy
    /// Called when the SimBuffer generates a chunk.
    pub fn get_effective_modification(self: *@This(), cx: u64, cy: u64) ?*ChunkMod {
        var search_cx = cx;
        var search_cy = cy;

        // Start from current depth (0) and look up to 15 ancestors
        // We use the cached path_stack so we don't have to reverse hashes
        const max_lookback = @min(16, memory.game.depth);

        for (0..max_lookback) |i| {
            const key = ModKey{
                .path_hash = self.quad_cache.TODO[i],
                .cx = search_cx,
                .cy = search_cy,
            };

            if (self.mod_store.index.get(key)) |idx| {
                return &self.mod_store.history.items[idx];
            }

            // Move to parent coordinate: shift off the lowest 4 bits (the block coordinates)
            search_cx >>= 4;
            search_cy >>= 4;
        }
        return null;
    }

    /// Handles entering a portal.
    /// `coord` is the chunk the portal is in.
    pub fn push_layer(self: *@This(), parent_id: Sprite, coord: memory.Coordinate, bx: u4, by: u4) void {
        _ = parent_id;
        memory.game.depth += 1;

        // Mask the last 12 bits (0-4095)
        const player_mask: i64 = SPAN * SPAN * SPAN - 1;
        const new_pos: memory.v2i64 = .{
            (memory.game.player_pos[0] << SPAN_LOG2) & player_mask,
            (memory.game.player_pos[1] << SPAN_LOG2) & player_mask,
        };
        memory.game.player_velocity = .{ 0, 0 };
        memory.game.set_player_pos(new_pos);
        memory.game.set_camera_pos(new_pos);

        if (memory.game.depth <= 16) {
            // Base phase: We are just filling up the 64-bit Suffix. No rebasing needed yet.
            memory.game.player_chunk[0] = (coord.suffix[0] << SPAN_LOG2) | bx;
            memory.game.player_chunk[1] = (coord.suffix[1] << SPAN_LOG2) | by;
            // TODO most top/left/bottom/right logic
            // Push path hash to stack now! TODO verify+complete all this
            // self.push_path_to_stack(self.quad_cache.get_lineage_seed(memory.game.get_player_coord().quadrant, 0)); // Pushes current down, adds to top

            // Update the maximum possible suffix value here using some fancy bit-shifting logic
            self.max_possible_suffix = if (memory.game.depth < 16)
                (@as(u64, 1) << @intCast(memory.game.depth * memory.SPAN_LOG2)) - 1
            else
                std.math.maxInt(u64);

            return;
        }

        // Extract the 4 bits that are about to fall off the edge of the u64 Suffix
        // const overflow_x = coord.suffix[0] >> 60;
        // const overflow_y = coord.suffix[1] >> 60;

        // Mix these overflow bits into the new PathHash
        // TODO figure out quadrant stuff
        // const new_path_hash = seeding.mix_chunk_seed(self.quad_cache.get_quadrant_seed(quadrant: u2), .{ overflow_x, overflow_y });
        // self.push_path_to_stack(new_path_hash);

        // Place the new top-left quadrant between max(d1, d2, d3, d4), where d1-d4 represent how many chunks it would take from the coord to the edge of the world if just travelling up, down, left, and right. Basically, make the QuadCache work for as long as possible by placing it "sort of centered", while making sure to cap it (TODO explain this more clearly)
        const ideal_center: u64 = 0x80000000_00000000;

        // TODO the actual QuadCache array readjustment
        // TODO logic to "clamp" the quadrant so it doesn't go past world bounds, no overflowing, or cap logic fixes this automatically
        memory.game.player_chunk[0] = ideal_center;
        memory.game.player_chunk[1] = ideal_center;
    }

    /// Helper to maintain the sliding window of hashes for fast lookups
    fn push_path_to_stack(self: *@This(), new_hash: seeding.Seed) void {
        // Shift everything down 1
        var i: usize = 15;
        while (i > 0) : (i -= 1) {
            self.path_stack[i] = self.path_stack[i - 1];
        }
        // Insert new current path at index 0
        self.path_stack[0] = new_hash;
    }
};

/// Multiplies a float by 2**64, returning an integer x such that a random u64 value has its probability to be less than x equal to the chance variable.
pub inline fn odds_num(chance: comptime_float) u64 {
    return @intFromFloat(chance * 18446744073709551616.0);
}

pub inline fn make_basic_block(sprite_type: Sprite) Block {
    return .{
        .id = sprite_type,
        .seed = 0,
        .light = 255,
        .hp = 0,
        .edge_flags = 0,
    };
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
