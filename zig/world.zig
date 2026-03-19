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

/// A 128-bit key for the ModificationStore.
pub const ModKey = struct {
    hash: [2]u64,

    pub fn eql(self: @This(), other: @This()) bool {
        return self.hash[0] == other.hash[0] and self.hash[1] == other.hash[1];
    }
};

/// Hash map context for ModKey.
pub const ModKeyContext = struct {
    pub fn hash(self: @This(), key: ModKey) u64 {
        _ = self;
        return key.hash[0] ^ key.hash[1];
    }
    pub fn eql(self: @This(), a: ModKey, b: ModKey) bool {
        _ = self;
        return a.eql(b);
    }
};

/// Generates an initial block for seeding.
pub inline fn generate_initial_block(rng: *seeding.Xoshiro512, x: u64, y: u64, depth: u64) Sprite {
    _ = x;
    _ = y;
    _ = depth;
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

/// A static 2x2 grid of seeds updated ONLY upon portal entry.
pub const QuadCache = struct {
    /// The 4 seeds for the quadrants (0: NW, 1: NE, 2: SW, 3: SE).
    seeds: [4]seeding.LayerSeed align(64),
    /// The 512-bit seed of the current active layer.
    active_layer_seed: seeding.LayerSeed,
    /// The rolling 128-bit hash representing the path taken through the fractal.
    /// Used as the prefix for ModKeys.
    path_hash: [2]u64,
    /// The initial seed from the start of the game.
    root_seed: seeding.LayerSeed,
    /// The block IDs of the 4 ancestor macro-regions.
    ancestor_materials: [4]Sprite,
    /// Whether the cache is currently populated.
    is_valid: bool,

    /// Resolves the chunk seed. If depth > 16, uses the 4-way rebased quadrant seeds.
    pub fn get_chunk_seed(self: *const QuadCache, cx: u64, cy: u64, depth: u64) seeding.LayerSeed {
        if (depth <= 16) {
            // Root Era: Coordinates are within the span of the root seed.
            return seeding.mix_chunk_seed(self.root_seed, cx, cy, depth);
        } else {
            // Coordinates are rebased around 2^63.
            // Select quadrant based on the MSB of the u64 suffix.
            const qx: u1 = @intCast(cx >> 63);
            const qy: u1 = @intCast(cy >> 63);
            const qid = (@as(u2, qy) << 1) | qx;
            return seeding.mix_chunk_seed(self.seeds[qid], cx, cy, depth);
        }
    }
};

/// Stores the blocks and state of the world of Depthwell.
pub const World = struct {
    alloc: std.mem.Allocator,
    chunk_cache: std.AutoHashMap(u64, *memory.Chunk),
    quad_cache: QuadCache,
    modification_store: std.HashMap(ModKey, memory.ModifiedChunk, ModKeyContext, 80),

    pub fn init(alloc: std.mem.Allocator, base_seed: seeding.LayerSeed) World {
        return .{
            .alloc = alloc,
            .chunk_cache = std.AutoHashMap(u64, *memory.Chunk).init(alloc),
            .quad_cache = .{
                .seeds = undefined,
                .active_layer_seed = base_seed,
                .path_hash = .{ 0, 0 },
                .root_seed = base_seed,
                .ancestor_materials = .{Sprite.none} ** 4,
                .is_valid = false,
            },
            .modification_store = std.HashMap(ModKey, memory.ModifiedChunk, ModKeyContext, 80).init(alloc),
        };
    }

    pub fn deinit(self: *World) void {
        self.clear_caches();
        self.chunk_cache.deinit();
        self.modification_store.deinit();
    }

    pub fn clear_caches(self: *World) void {
        var it = self.chunk_cache.valueIterator();
        while (it.next()) |chunk_ptr| {
            self.alloc.destroy(chunk_ptr.*);
        }
        self.chunk_cache.clearRetainingCapacity();
        self.quad_cache.is_valid = false;
    }

    pub fn get_chunk(self: *World, cx: u64, cy: u64) *memory.Chunk {
        // logger.write(3, .{ "{h}Chunk requested", memory.v2u64{ cx, cy } });
        const key = chunk_key(cx, cy);
        if (self.chunk_cache.get(key)) |c| return c;

        const chunk = self.alloc.create(memory.Chunk) catch @panic("chunk alloc failed");
        const depth = memory.game.depth;

        const chunk_seed = self.quad_cache.get_chunk_seed(cx, cy, depth);
        generate_chunk(chunk, chunk_seed, cx, cy, depth);

        // TODO: Modification injection using ModKey lookup here
        self.chunk_cache.put(key, chunk) catch @panic("chunk cache put failed");
        return chunk;
    }

    pub inline fn chunk_key(cx: u64, cy: u64) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&cx));
        hasher.update(std.mem.asBytes(&cy));
        return hasher.final();
    }

    /// Moves the world state one level deeper into a specific block.
    pub fn push_layer(self: *World, target_x: u64, target_y: u64, parent_id: Sprite) void {
        _ = parent_id;

        // Update the layer seed by mixing the current seed with the portal coordinates.
        const new_seed = seeding.mix_macro_seed_blake3(self.quad_cache.active_layer_seed, target_x, target_y);
        self.quad_cache.active_layer_seed = new_seed;

        // Update the rolling 128-bit path hash for unique modification lookups.
        var hasher = std.hash.Wyhash.init(self.quad_cache.path_hash[0]);
        hasher.update(std.mem.asBytes(&target_x));
        hasher.update(std.mem.asBytes(&target_y));
        self.quad_cache.path_hash[1] = self.quad_cache.path_hash[0];
        self.quad_cache.path_hash[0] = hasher.final();

        memory.game.depth += 1;

        // If Prefix Era, compute the 4 quadrants derived from the new layer.
        if (memory.game.depth > 16) {
            self.quad_cache.seeds[0] = seeding.mix_macro_seed_blake3(new_seed, 0, 0);
            self.quad_cache.seeds[1] = seeding.mix_macro_seed_blake3(new_seed, 1, 0);
            self.quad_cache.seeds[2] = seeding.mix_macro_seed_blake3(new_seed, 0, 1);
            self.quad_cache.seeds[3] = seeding.mix_macro_seed_blake3(new_seed, 1, 1);
            self.quad_cache.is_valid = true;
        }

        self.clear_caches();
    }
};

/// Multiplies a float by 2**64, returning an integer x such that a random next() value generated by XorShift512** has its probability to be less than x equal to the chance variable.
pub inline fn odds_num(chance: comptime_float) u64 {
    return @intFromFloat(chance * 18446744073709551616.0);
}

pub inline fn get_world_limit(depth: u64) u64 {
    return if (depth < SPAN)
        (@as(u64, 1) << @intCast(depth * memory.SPAN_LOG2))
    else
        std.math.maxInt(u64);
}

/// Generates a whole chunk (considering modifications), given a pointer to where the chunk should be, seed, coordinates, and depth.
pub fn generate_chunk(chunk: *memory.Chunk, chunk_seed: seeding.LayerSeed, cx: u64, cy: u64, depth: u64) void {
    var rng = seeding.Xoshiro512.init(chunk_seed);
    const has_boundary = depth < 15;
    const world_limit: u64 = get_world_limit(depth) * 16;

    const max_block: u64 = if (has_boundary) (world_limit - 1) else 0;

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

            const block_id = generate_initial_block(&rng, gbx, gby, depth);
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
