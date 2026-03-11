const std = @import("std");
const memory = @import("memory.zig");
const world = @import("world.zig");
const seeding = @import("seeding.zig");

const Chunk = memory.Chunk;
const Block = memory.Block;
const CHUNK_SIZE = memory.CHUNK_SIZE;

pub const WORLD_CHUNKS = 4096;
const PLAYER_EDGE: i64 = 4096 * memory.CHUNK_SIZE;

// Sprite IDs
pub const SPRITE_VOID = 0;
pub const SPRITE_PLAYER = 1;
pub const SPRITE_EDGESTONE = 2;
pub const SPRITE_STONE = 3;
pub const SPRITE_GREENSTONE = 4;
pub const SPRITE_BLOODSTONE = 5;
pub const SPRITE_TORCH = 6;
pub const SPRITE_MUSHROOM = 7;

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

pub inline fn generate_initial_block(rng: *seeding.Xoshiro512, x: u64, y: u64) u20 {
    _ = x;
    _ = y;
    const entropy = rng.next();

    var block_id: u20 = SPRITE_VOID;
    if (entropy < odds_num(0.6)) {
        block_id = SPRITE_VOID;
    } else if (entropy < odds_num(0.95)) {
        block_id = SPRITE_STONE;
    } else if (entropy < odds_num(0.98)) {
        block_id = SPRITE_GREENSTONE;
    } else {
        block_id = SPRITE_BLOODSTONE;
    }
    return block_id;
}

pub const World = struct {
    alloc: std.mem.Allocator,
    path: CoordinatePath,
    chunk_cache: std.AutoHashMap(u64, *Chunk),
    macro_seed_cache: std.AutoHashMap(u64, seeding.LayerSeed),

    pub fn init(alloc: std.mem.Allocator, base_seed: seeding.LayerSeed) World {
        var self = World{
            .alloc = alloc,
            .path = .{
                .stack = std.ArrayList(PathNode).initCapacity(alloc, 4) catch unreachable,
                .root_seed = base_seed,
            },
            .chunk_cache = std.AutoHashMap(u64, *Chunk).init(alloc),
            .macro_seed_cache = std.AutoHashMap(u64, seeding.LayerSeed).init(alloc),
        };

        // Initial spawn: 3 layers deep at the center of the root sectors (8, 8)
        for (0..3) |_| {
            self.push_layer(8, 8, SPRITE_VOID);
        }
        return self;
    }

    pub fn deinit(self: *World) void {
        self.clear_caches();
        self.chunk_cache.deinit();
        self.macro_seed_cache.deinit();
        self.path.deinit();
    }

    /// Wipes the physical chunk cache. Called automatically when zooming in/out.
    pub fn clear_caches(self: *World) void {
        var it = self.chunk_cache.valueIterator();
        while (it.next()) |chunk_ptr| {
            self.alloc.destroy(chunk_ptr.*);
        }
        self.chunk_cache.clearRetainingCapacity();
        self.macro_seed_cache.clearRetainingCapacity();
    }

    /// Zooms IN to a specific block.
    pub fn push_layer(self: *World, target_x: u32, target_y: u32, parent_id: u20) void {
        const current_seed = self.path.get_current_seed();
        // Mix the coordinates of the block we are zooming into to create the new universe seed
        const new_seed = seeding.mix_512(current_seed, target_x, target_y);

        self.path.stack.append(self.alloc, .{
            .parent_block_id = parent_id,
            .x = target_x,
            .y = target_y,
            .seed = new_seed,
        }) catch @panic("OOM on path push");

        // The world has changed. Old chunks are invalid.
        self.clear_caches();
    }

    /// Zooms OUT to the parent layer.
    pub fn pop_layer(self: *World) void {
        if (self.path.stack.items.len > 0) {
            const last = self.path.stack.pop();
            // Restore the player's position in the parent world
            memory.game.active_chunk[0] = @intCast(last.x);
            memory.game.active_chunk[1] = @intCast(last.y);
            self.clear_caches();
            memory.game.grid_dirty = true;
        }
    }

    pub fn get_chunk(self: *World, cx: u64, cy: u64) *Chunk {
        const key = chunk_key(cx, cy);

        if (self.chunk_cache.get(key)) |c| return c;

        const chunk = self.alloc.create(Chunk) catch @panic("chunk alloc failed");

        // Generate chunk seed directly from the current layer seed and chunk coordinates
        const layer_seed = self.path.get_current_seed();
        const chunk_seed = seeding.mix_512(layer_seed, cx, cy);

        // depth is the number of layers currently on the stack.
        // You start at Depth 3, and World.init pushed 3 layers, this is 3.
        const current_depth: u32 = @intCast(self.path.stack.items.len);

        // Call generate_chunk with the 5 required arguments
        generate_chunk(chunk, chunk_seed, cx, cy, current_depth);

        self.chunk_cache.put(key, chunk) catch @panic("chunk cache put failed");
        return chunk;
    }

    pub inline fn chunk_key(cx: u64, cy: u64) u64 {
        // Hash the two u64s into a single u64 for the HashMap key
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&cx));
        hasher.update(std.mem.asBytes(&cy));
        return hasher.final();
    }

    /// Remixes the seeds down the chain
    fn recalculate_seeds_from(self: *World, start_index: usize) void {
        var i = start_index;
        while (i < self.path.stack.items.len) : (i += 1) {
            const prev_seed = if (i == 0) self.path.root_seed else self.path.stack.items[i - 1].seed;
            const node = &self.path.stack.items[i];
            node.seed = seeding.mix_512(prev_seed, node.x, node.y);
        }
    }
};

pub inline fn odds_num(probability: comptime_float) u64 {
    return @intFromFloat(probability * 18446744073709551616.0);
}

/// Generates a chunk using the specific sprite probabilities and mushroom rules.
pub fn generate_chunk(chunk: *Chunk, chunk_seed: seeding.LayerSeed, abs_cx: u64, abs_cy: u64, depth: u32) void {
    var rng = seeding.Xoshiro512.init(chunk_seed);

    // Calculate limits in blocks
    const world_limit_chunks: u64 = if (depth < CHUNK_SIZE) (@as(u64, 1) << @intCast(depth * std.math.log2(CHUNK_SIZE))) else std.math.maxInt(u64);
    const max_block: u64 = (world_limit_chunks * CHUNK_SIZE) - 1;

    for (0..CHUNK_SIZE) |ly| {
        for (0..CHUNK_SIZE) |lx| {
            const idx = ly * CHUNK_SIZE + lx;

            // Absolute block coordinates in the current world layer
            const gbx = (abs_cx * CHUNK_SIZE) + lx;
            const gby = (abs_cy * CHUNK_SIZE) + ly;

            // Edge of the world is stone
            if (gbx == 0 or gbx == max_block or gby == 0 or gby == max_block) {
                chunk.blocks[idx] = .{
                    .id = world.SPRITE_EDGESTONE,
                    .seed = 0,
                    .light = 255,
                    .hp = 0,
                    .flags = 0,
                };
                continue;
            }

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

    for (0..CHUNK_SIZE - 1) |ly| {
        for (0..CHUNK_SIZE) |lx| {
            const idx = ly * CHUNK_SIZE + lx;
            const block_below = chunk.blocks[(ly + 1) * CHUNK_SIZE + lx].id;

            if (chunk.blocks[idx].id == SPRITE_VOID and
                block_below != SPRITE_VOID and block_below != SPRITE_TORCH and block_below != SPRITE_MUSHROOM)
            {
                const entropy = rng.next();
                if (entropy < odds_num(0.3)) {
                    chunk.blocks[idx] = .{
                        .id = SPRITE_MUSHROOM,
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
//     return .{ world_x / CHUNK_SIZE, world_y / CHUNK_SIZE };
// }
