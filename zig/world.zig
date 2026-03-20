//! Defines the architecture of the fractal world, which is a segmented fractal coordinate system that uses a quad-cache for coordinates and corresponding seeds.
const std = @import("std");
const memory = @import("memory.zig");
const logger = @import("logger.zig");
const seeding = @import("seeding.zig");

const Chunk = memory.Chunk;
const Block = memory.Block;
const SPAN = memory.SPAN;

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
};

/// Empty block of id Sprite.none
pub const AIR_BLOCK: Block = .{ .id = Sprite.none, .seed = 0, .light = 255, .hp = 0, .flags = 0 };

/// A 128-bit key for the ModificationStore. TODO finish
pub const ModKey = struct {
    /// The rolling hash representing the path at a specific depth.
    path_hash: [2]u64,
    /// The chunk coordinates at that depth.
    cx: u64,
    cy: u64,

    pub fn eql(self: @This(), other: @This()) bool {
        return self.path_hash[0] == other.path_hash[0] and
            self.path_hash[1] == other.path_hash[1] and
            self.cx == other.cx and self.cy == other.cy;
    }
};

/// Hash map context for ModKey.
pub const ModKeyContext = struct {
    pub fn hash(self: @This(), key: ModKey) u64 {
        _ = self;
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&key.path_hash));
        h.update(std.mem.asBytes(&key.cx));
        h.update(std.mem.asBytes(&key.cy));
        return h.final();
    }
    pub fn eql(self: @This(), a: ModKey, b: ModKey) bool {
        _ = self;
        return a.eql(b);
    }
};

/// Constant-size buffer caching the simulation buffer.
pub const SimBuffer = struct {
    chunks: [256]?*memory.Chunk, // hard-capped to 256

    /// Returns the chunk from the specified x and y.
    pub inline fn get_index(cx: u64, cy: u64) usize {
        return (@as(usize, cy & 0xF) << 4) | @as(usize, cx & 0xF);
    }

    /// Sets a chunk from the specified x and y to a new chunk.
    pub inline fn set_index(self: *SimBuffer, new_chunk: *const memory.Chunk, cx: u64, cy: u64) void {
        self.chunks[(@as(usize, cy & 0xF) << 4) | @as(usize, cx & 0xF)] = new_chunk;
    }
};

/// Generates an initial block for seeding.
pub inline fn generate_initial_blocks(rng: *seeding.Xoshiro512) Sprite {
    const entropy = rng.next();

    var block_id = Sprite.none;
    if (entropy < odds_num(0.6)) {
        block_id = Sprite.none;
    } else if (entropy < odds_num(0.95)) {
        block_id = Sprite.stone;
    } else if (entropy < odds_num(0.97)) {
        block_id = Sprite.greenstone;
    } else if (entropy < odds_num(0.99)) {
        block_id = Sprite.bluestone;
    } else {
        block_id = Sprite.bloodstone;
    }
    return block_id;
}

/// Adds 1 to the path as if the ArrayList represented one giant number. Performs allocation.
fn carry_path(path: std.ArrayList(u64)) std.ArrayList(u64) {
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

/// A static 2x2 grid of seeds updated ONLY upon portal entry.
pub const QuadCache = struct {
    /// The 4 seeds for the quadrants (0: NW, 1: NE, 2: SW, 3: SE).
    seeds: [4]seeding.LayerSeed align(memory.MAIN_ALIGN_BYTES),
    /// Stores the leftmost QuadCache's X-coordinate.
    left_path: std.ArrayList(u64),
    /// Stores the topmost QuadCache's Y-coordinate.
    top_path: std.ArrayList(u64),
    /// The block IDs for each of the 4 places the QuadCache represents.
    ancestor_materials: [4]Sprite,
    /// Whether the cache is currently populated.
    is_valid: bool,

    /// Returns the X-coordinate path of a specific quadrant. Unreachable call if path is empty (if depth is not > 16).
    pub inline fn get_quadrant_path_x(self: *const QuadCache, quadrant: u2) std.ArrayList(u64) {
        return if (quadrant % 2 == 0) self.left_path else carry_path(self.left_path);
    }

    /// Returns the Y-coordinate path of a specific quadrant. Unreachable call if path is empty (if depth is not > 16).
    pub inline fn get_quadrant_path_y(self: *const QuadCache, quadrant: u2) std.ArrayList(u64) {
        return if (quadrant >= 2) self.left_path else carry_path(self.left_path);
    }

    /// Returns the 512-bit seed of a specified quadrant.
    pub inline fn get_quadrant_seed(self: *const QuadCache, quadrant: u2) seeding.LayerSeed {
        return self.seeds[quadrant];
    }

    /// Resolves the chunk seed. If depth > 16, uses the quadrant seeds.
    pub inline fn get_chunk_seed(self: *const QuadCache, coord: memory.Coordinate) seeding.LayerSeed {
        return seeding.mix_chunk_seed(self.get_quadrant_seed(coord.quadrant), coord.suffix);
    }
};

/// Stores the blocks and state of the world of Depthwell.
pub const World = struct {
    /// Allocator used in the World.
    alloc: std.mem.Allocator,
    /// The constant SimBuffer of 256 chunks that is cached to prevent constant recalculations.
    chunk_cache: SimBuffer,
    /// The QuadCache that stores information about the 4 quadrants and their seeds.
    quad_cache: QuadCache,
    /// Stores modifications of chunks.
    modification_store: std.HashMap(ModKey, memory.ModifiedChunk, ModKeyContext, 80),

    pub fn init(alloc: std.mem.Allocator, base_seed: seeding.LayerSeed) World {
        return .{
            .alloc = alloc,
            .chunk_cache = undefined,
            .quad_cache = .{
                .seeds = .{ base_seed, base_seed, base_seed, base_seed },
                .left_path = std.ArrayList(u64){
                    .items = &[_]u64{},
                    .capacity = 0,
                },
                .top_path = std.ArrayList(u64){
                    .items = &[_]u64{},
                    .capacity = 0,
                },
                .ancestor_materials = .{Sprite.none} ** 4,
                .is_valid = false,
            },
            .modification_store = std.HashMap(ModKey, memory.ModifiedChunk, ModKeyContext, 80).init(alloc),
        };
    }

    pub fn get_chunk(self: *const World, coord: memory.Coordinate) *memory.Chunk {
        // logger.write(3, .{ "{h}Chunk requested", coord });
        // TODO figure out this whole allocation business
        const chunk = self.alloc.create(memory.Chunk) catch @panic("chunk alloc failed");
        self.generate_chunk(chunk, coord);
        return chunk;
    }

    /// Generates a whole chunk (considering modifications), given a pointer to where the chunk should be and coordinates.
    pub fn generate_chunk(self: *const World, chunk: *memory.Chunk, coord: memory.Coordinate) void {
        const chunk_seed = self.quad_cache.get_chunk_seed(coord);
        var rng = seeding.Xoshiro512.init(chunk_seed);
        const has_boundary = memory.game.depth < 15;
        const world_limit: u64 = get_world_limit() * 16;

        const max_block: u64 = if (has_boundary) (world_limit - 1) else 0;
        const cx = coord.suffix[0];
        const cy = coord.suffix[1];
        for (0..SPAN) |ly| {
            for (0..SPAN) |lx| {
                const idx = (ly * SPAN) + lx;
                const gbx = (cx * SPAN) + lx;
                const gby = (cy * SPAN) + ly;

                // TODO make this work with quadcache to still work for edges
                if (has_boundary and (gbx == 0 or gbx == max_block or gby == 0 or gby == max_block)) {
                    chunk.blocks[idx] = .{ .id = Sprite.edgestone, .seed = 0, .light = 255, .hp = 0, .flags = 0 };
                    continue;
                }

                const block_id = generate_initial_blocks(&rng);
                const entropy = rng.next();
                chunk.blocks[idx] = .{
                    .id = block_id,
                    .seed = @truncate(entropy >> 20),
                    .light = 255,
                    .hp = 15,
                    .flags = 0,
                };
            }
        }
    }

    /// Moves the world state one level deeper into a specific block.
    pub fn push_layer(self: *World, parent_id: Sprite, coord: memory.Coordinate) void {
        _ = parent_id;
        _ = coord;
        _ = self;
        memory.game.depth += 1;

        // If a prefix is necessary, compute the 4 quadrants derived from the new layer.
        // TODO get this to actually logically make sense in terms of seed-pushing with portals
        if (memory.game.depth > 16) {
            // Update the layer seed by mixing the current seed with the portal coordinates.
            // TODO also update parent_id+top_left_path
            // const seed = self.quad_cache.get_quadrant_seed(coord.quadrant);

            // self.quad_cache.seeds[0] = seeding.mix_coordinate_seed(seed, 0, 0);
            // self.quad_cache.seeds[1] = seeding.mix_coordinate_seed(seed, 1, 0);
            // self.quad_cache.seeds[2] = seeding.mix_coordinate_seed(seed, 0, 1);
            // self.quad_cache.seeds[3] = seeding.mix_coordinate_seed(seed, 1, 1);
            // self.quad_cache.is_valid = true;
        }
    }
};

/// Multiplies a float by 2**64, returning an integer x such that a random next() value generated by XorShift512** has its probability to be less than x equal to the chance variable.
pub inline fn odds_num(chance: comptime_float) u64 {
    return @intFromFloat(chance * 18446744073709551616.0);
}

pub inline fn get_world_limit() u64 {
    return if (memory.game.depth < SPAN)
        (@as(u64, 1) << @intCast(memory.game.depth * memory.SPAN_LOG2))
    else
        std.math.maxInt(u64);
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
