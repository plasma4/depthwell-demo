//! Handles the start of the world (like blocks).
const std = @import("std");
const memory = @import("memory.zig");
const seeding = @import("seeding.zig");
const types = @import("types.zig");

/// The logical internal width.
const INTERNAL_WIDTH = 480;
// The logical internal height.
const INTERNAL_HEIGHT = 270;

const CHUNKS_AROUND_HORIZONTAL = 25; // 25 chunks in either direction (50 chunks total)
const CHUNKS_AROUND_VERTICAL = 25;

pub const MAX_CHUNKS = 16;
pub const CHUNK_SIZE = 16;
pub const BLOCKS_PER_CHUNK = CHUNK_SIZE * CHUNK_SIZE;

/// Logical coordinate of a chunk
pub const ChunkCoord = struct {
    x: i32,
    y: i32,
};

/// The data for a single chunk
pub const Chunk = struct {
    data: [BLOCKS_PER_CHUNK]types.TileData,
    is_dirty: bool = false,
};

// The global hash map storing our sparse chunks.
// Uses the general purpose allocator / WASM allocator from memory.zig
pub var chunk_map: std.AutoHashMap(ChunkCoord, Chunk) = undefined;

pub fn init() void {
    chunk_map = std.AutoHashMap(ChunkCoord, Chunk).init(memory.allocator);
}

/// Retrieves a chunk. If it doesn't exist, it generates it using the world seed.
pub fn getOrGenerateChunk(cx: i32, cy: i32) *Chunk {
    const coord = ChunkCoord{ .x = cx, .y = cy };

    if (chunk_map.getPtr(coord)) |existing_chunk| {
        return existing_chunk;
    }

    var new_chunk = Chunk{ .data = undefined };
    const chunk_seed = seeding.mixChunkSeed(memory.game.seed, cx, cy, 0);
    var prng = seeding.Xoshiro512.init(chunk_seed);

    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            const idx = y * CHUNK_SIZE + x;

            // Use the PRNG to make noise
            const rand_val = prng.next();
            const sprite: u8 = if (rand_val % 10 > 7) 1 else 0; // 20% chance of sprite 1

            new_chunk.data[idx] = .{
                .sprite_id = sprite,
                .edge_flags = 0,
                .light = @truncate(rand_val >> 8), // Grab pseudo-random light
                .variation = @truncate(rand_val >> 16),
            };
        }
    }

    // 4. Insert into the sparse map
    chunk_map.put(coord, new_chunk) catch @panic("OOM inserting chunk");
    return chunk_map.getPtr(coord).?;
}

/// Helper to get a tile at absolute world coordinates
pub fn getTileAt(world_x: i32, world_y: i32) ?types.TileData {
    // Floor division handles negative coordinates correctly
    const cx = @divFloor(world_x, CHUNK_SIZE);
    const cy = @divFloor(world_y, CHUNK_SIZE);

    const chunk = getOrGenerateChunk(cx, cy);

    // Modulo math to get local chunk coordinates (guaranteed 0 to CHUNK_SIZE-1)
    const local_x = @as(usize, @intCast(@mod(world_x, CHUNK_SIZE)));
    const local_y = @as(usize, @intCast(@mod(world_y, CHUNK_SIZE)));

    return chunk.data[local_y * CHUNK_SIZE + local_x];
}

/// Helper to determine if a block is solid for physics
pub fn isSolid(world_x: i32, world_y: i32) bool {
    if (getTileAt(world_x, world_y)) |tile| {
        return tile.sprite_id == 0; // Example: sprite 0 is solid stone
    }
    return false; // Out of bounds / void is air
}
