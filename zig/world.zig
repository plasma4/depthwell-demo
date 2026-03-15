//! Defines the architecture of the fractal world, which is a Segmented Fractal Coordinate System that uses a quad-cache for coordinates and corresponding seeds.

const std = @import("std");
const memory = @import("memory.zig");
const seeding = @import("seeding.zig");

const Chunk = memory.Chunk;
const Block = memory.Block;
const SPAN = memory.SPAN;

pub const WORLD_CHUNKS = 4096;
const PLAYER_EDGE: i64 = 4096 * memory.SPAN;

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

/// Default block with type Sprite.none
pub const AIR_BLOCK: Block = .{ .id = Sprite.none, .seed = 0, .light = 255, .hp = 0, .flags = 0 };

/// Represents a single zoom-level transition.
pub const PathNode = extern struct {
    /// The 512-bit seed resulting from this path step.
    seed: seeding.LayerSeed align(16),

    /// The ID of the block zoomed into.
    parent_block_id: u32,
    x: u32,
    y: u32,
};

/// Represents an infinitely scaling path through the fractal tree.
pub const CoordinatePath = struct {
    stack: std.ArrayList(PathNode),
    root_seed: seeding.LayerSeed,

    pub fn init(base_seed: seeding.LayerSeed) CoordinatePath {
        return .{
            .stack = std.ArrayList(PathNode),
            .root_seed = base_seed,
        };
    }

    pub fn deinit(self: *CoordinatePath) void {
        self.stack.deinit();
    }

    /// Returns the 512-bit seed for the CURRENT operating depth.
    pub fn get_current_seed(self: *const CoordinatePath) seeding.LayerSeed {
        if (self.stack.items.len == 0) return self.root_seed;
        return self.stack.getLast().seed;
    }
};

/// Generates an initial block for seeding (TODO replace with fancy perlin and other functions)
pub inline fn generate_initial_block(rng: *seeding.Xoshiro512, x: u64, y: u64) Sprite {
    _ = x;
    _ = y;
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

/// Defines the size of a macro-region in chunks.
/// Shift 8 = 256 chunks (4,096 blocks). A 2x2 cache covers a 512x512 chunk area.
const MACRO_SHIFT: u6 = 8;
const MACRO_MASK: u64 = (1 << MACRO_SHIFT) - 1;

/// A 2x2 grid of 512-bit macro-seeds.
pub const QuadCache = struct {
    origin_x: u64,
    origin_y: u64,
    seeds: [4]seeding.LayerSeed,
    /// Indicates if the cache has been initialized for the current layer.
    is_valid: bool,

    /// Retrieves the $O(1)$ chunk seed, rebuilding the cache safely if the chunk is out of bounds.
    pub fn get_chunk_seed(self: *QuadCache, layer_seed: seeding.LayerSeed, cx: u64, cy: u64) seeding.LayerSeed {
        const mx = cx >> MACRO_SHIFT;
        const my = cy >> MACRO_SHIFT;

        // Unsigned wrapping subtraction. If mx < origin_x, it wraps to maxInt(u64),
        // which is > 1, immediately triggering a rebuild.
        const rel_x = mx -% self.origin_x;
        const rel_y = my -% self.origin_y;

        if (!self.is_valid or rel_x > 1 or rel_y > 1) {
            self.rebuild(layer_seed, mx, my);
            // Re-evaluate relative positions after rebuild (they will now be 0)
            const new_rel_x = mx -% self.origin_x;
            const new_rel_y = my -% self.origin_y;
            const index = (new_rel_y * 2) + new_rel_x;
            return seeding.mix_chunk_seed(self.seeds[@as(usize, @intCast(index))], cx & MACRO_MASK, cy & MACRO_MASK);
        }

        const index = (rel_y * 2) + rel_x;
        return seeding.mix_chunk_seed(self.seeds[@as(usize, @intCast(index))], cx & MACRO_MASK, cy & MACRO_MASK);
    }

    /// Calculates the 4 Macro-Seeds covering the 2x2 grid originating at (mx, my).
    fn rebuild(self: *QuadCache, layer_seed: seeding.LayerSeed, mx: u64, my: u64) void {
        self.origin_x = mx;
        self.origin_y = my;

        self.seeds[0] = seeding.mix_macro_seed_blake3(layer_seed, mx, my);
        self.seeds[1] = seeding.mix_macro_seed_blake3(layer_seed, mx +% 1, my);
        self.seeds[2] = seeding.mix_macro_seed_blake3(layer_seed, mx, my +% 1);
        self.seeds[3] = seeding.mix_macro_seed_blake3(layer_seed, mx +% 1, my +% 1);

        self.is_valid = true;
    }
};

pub const World = struct {
    alloc: std.mem.Allocator,
    path: CoordinatePath,
    chunk_cache: std.AutoHashMap(u64, *Chunk),
    quad_cache: QuadCache,

    pub fn init(alloc: std.mem.Allocator, base_seed: seeding.LayerSeed) World {
        var self = World{
            .alloc = alloc,
            .path = .{
                .stack = std.ArrayList(PathNode).initCapacity(alloc, 4) catch unreachable,
                .root_seed = base_seed,
            },
            .chunk_cache = std.AutoHashMap(u64, *Chunk).init(alloc),
            .quad_cache = .{
                .origin_x = 0,
                .origin_y = 0,
                .seeds = undefined,
                .is_valid = false,
            },
        };

        // Initial spawn: 3 layers deep
        for (0..3) |_| {
            self.push_layer(0, 0, Sprite.none);
        }
        return self;
    }

    pub fn deinit(self: *World) void {
        self.clear_caches();
        self.chunk_cache.deinit();
        self.path.deinit();
    }

    /// Wipes the physical chunk cache and invalidates the Quad-Cache.
    pub fn clear_caches(self: *World) void {
        var it = self.chunk_cache.valueIterator();
        while (it.next()) |chunk_ptr| {
            self.alloc.destroy(chunk_ptr.*);
        }
        self.chunk_cache.clearRetainingCapacity();
        self.quad_cache.is_valid = false;
    }

    pub fn get_chunk(self: *World, cx: u64, cy: u64) *Chunk {
        const key = chunk_key(cx, cy);
        if (self.chunk_cache.get(key)) |c| return c;

        const chunk = self.alloc.create(Chunk) catch @panic("chunk alloc failed");
        const current_depth = memory.game.current_depth;
        const layer_seed = self.path.get_current_seed();

        // Fetch the perfectly avalanched chunk seed via the O(1) quad-cache lookup
        const chunk_seed = self.quad_cache.get_chunk_seed(layer_seed, cx, cy);
        generate_chunk(chunk, chunk_seed, cx, cy, current_depth);

        self.chunk_cache.put(key, chunk) catch @panic("chunk cache put failed");
        return chunk;
    }

    pub inline fn chunk_key(cx: u64, cy: u64) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&cx));
        hasher.update(std.mem.asBytes(&cy));
        return hasher.final();
    }

    /// Zooms IN to a specific block.
    pub fn push_layer(self: *World, target_x: u32, target_y: u32, parent_id: Sprite) void {
        const current_seed = self.path.get_current_seed();
        // Mix the coordinates of the block we are zooming into to create the new universe seed
        const new_seed = seeding.mix_macro_seed_blake3(current_seed, target_x, target_y);

        self.path.stack.append(self.alloc, .{
            .parent_block_id = @intFromEnum(parent_id),
            .x = target_x,
            .y = target_y,
            .seed = new_seed,
        }) catch @panic("OOM on path push");

        // The world has changed. Old chunks are invalid.
        self.clear_caches();
    }

    /// Zooms OUT to the parent layer.
    pub fn pop_layer(self: *World) void {
        if (memory.game.current_depth > 0) {
            const last = self.path.stack.pop();
            // Restore the player's position in the parent world
            memory.game.active_chunk[0] = @intCast(last.x);
            memory.game.active_chunk[1] = @intCast(last.y);
            self.clear_caches();
            memory.game.grid_dirty = true;
        }
    }

    /// Remixes the seeds down the chain
    fn recalculate_seeds_from(self: *World, start_index: usize) void {
        var i = start_index;
        while (i < self.path.stack.items.len) : (i += 1) {
            const prev_seed = if (i == 0) self.path.root_seed else self.path.stack.items[i - 1].seed;
            const node = &self.path.stack.items[i];
            node.seed = seeding.mix_coordinate(prev_seed, node.x, node.y);
        }
    }
};

pub inline fn odds_num(probability: comptime_float) u64 {
    return @intFromFloat(probability * 18446744073709551616.0);
}

/// Generates a chunk using the specific sprite probabilities and mushroom rules.
pub fn generate_chunk(chunk: *Chunk, chunk_seed: seeding.LayerSeed, abs_cx: u64, abs_cy: u64, depth: u32) void {
    var rng = seeding.Xoshiro512.init(chunk_seed);

    // Calculate limits safely. depth 15 is the hard limit for u64 block math (1 << 60 * 16 = 2^64).
    const has_boundary = depth < 15;
    const world_limit_blocks: u64 = if (has_boundary) (@as(u64, 1) << @intCast(depth * 4)) else 0;
    const max_block: u64 = if (has_boundary) (world_limit_blocks - 1) else 0;

    for (0..SPAN) |ly| {
        for (0..SPAN) |lx| {
            const idx = ly * SPAN + lx;
            const gbx = (abs_cx * SPAN) + lx;
            const gby = (abs_cy * SPAN) + ly;

            // Hard boundary check for finite worlds
            if (has_boundary) {
                if (gbx == 0 or gbx == max_block or gby == 0 or gby == max_block) {
                    chunk.blocks[idx] = .{ .id = Sprite.edgestone, .seed = 0, .light = 255, .hp = 0, .flags = 0 };
                    continue;
                }
            }

            // Normal generation logic...
            const block_id = generate_initial_block(&rng, gbx, gby);
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

    for (0..SPAN - 1) |ly| {
        for (0..SPAN) |lx| {
            const idx = ly * SPAN + lx;
            const block_below = chunk.blocks[(ly + 1) * SPAN + lx].id;

            if (chunk.blocks[idx].id == Sprite.none and
                block_below != Sprite.none and block_below != Sprite.torch and block_below != Sprite.mushroom)
            {
                const entropy = rng.next();
                if (entropy < odds_num(0.3)) {
                    chunk.blocks[idx] = .{
                        .id = Sprite.mushroom,
                        .seed = @truncate(entropy >> 20),
                        .light = 255,
                        .hp = 1,
                        .flags = 0,
                    };
                }
            }
        }
    }

    chunk.modified_mask = .{ 0, 0, 0, 0 };
}

// /// Convert screen pixels to a world block coordinate
// pub fn screen_to_world(screen_x: f64, screen_y: f64, viewport_w: f64, viewport_h: f64, cam_x: f64, cam_y: f64, zoom: f64) @Vector(2, f64) {
//     const target_chunk_offset_x = @divFloor(world_subpixel_x, 4096);
//     const target_chunk_offset_y = @divFloor(world_subpixel_y, 4096);

//     const target_chunk_x = game.active_chunk[0] +% @as(u64, @bitCast(target_chunk_offset_x));
//     const target_chunk_y = game.active_chunk[1] +% @as(u64, @bitCast(target_chunk_offset_y));

//     const block_x = @divFloor(@mod(world_subpixel_x, 4096), 256);
//     const block_y = @divFloor(@mod(world_subpixel_y, 4096), 256);

//     // Returns exact block coordinate. @floor() this to get the integer block index.
//     return .{ world_x / SPAN, world_y / SPAN };
// }
