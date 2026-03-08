const std = @import("std");
const memory = @import("memory.zig");
const seeding = @import("seeding.zig");

const Block = memory.Block;
const Chunk = memory.Chunk;
const CHUNK_SIZE = memory.CHUNK_SIZE;

/// Edge flags mapping strictly for ambient occlusion/visual tiling.
pub const EdgeFlags = struct {
    pub const TOP_LEFT: u8 = 0x01;
    pub const TOP: u8 = 0x02;
    pub const TOP_RIGHT: u8 = 0x04;
    pub const LEFT: u8 = 0x08;
    pub const RIGHT: u8 = 0x10;
    pub const BOTTOM_LEFT: u8 = 0x20;
    pub const BOTTOM: u8 = 0x40;
    pub const BOTTOM_RIGHT: u8 = 0x80;
};

// TODO profile performance of hashing, having a bunch of scale coords, see if theoretical/limit-testing gameplay is hampered due to memory issues.

/// Represents the physical and fractal coordinate of a chunk.
pub const ScaleCoord = struct {
    /// Optimized depth stack: packs 16 `u4` steps into a single `u64` for extremely fast hashing and memory density.
    depth_stack: []const u64 align(memory.MAIN_ALIGN_BYTES),
    pos: @Vector(2, i64),

    pub fn hash(self: ScaleCoord) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.sliceAsBytes(self.depth_stack));
        h.update(std.mem.asBytes(&self.pos));
        return h.final();
    }
};

/// TODO set to good value
pub const CHUNK_POOL_SIZE: u16 = 31 * 18 * 256;

pub const ChunkCache = struct {
    /// The actual memory pool of chunks
    pool: [CHUNK_POOL_SIZE]memory.Chunk = undefined,

    /// Maps ScaleCoord.hash() -> pool index
    lookup: std.AutoHashMap(u64, u16),

    // Index-based doubly-linked list for LRU caching
    // head = Most Recently Used, tail = Least Recently Used
    head: u16 = 0,
    tail: u16 = 0,
    next: [CHUNK_POOL_SIZE]u16 = undefined,
    prev: [CHUNK_POOL_SIZE]u16 = undefined,

    /// Parallel array to know which hash corresponds to which pool slot (for eviction)
    hashes: [CHUNK_POOL_SIZE]u64 = [_]u64{0} ** CHUNK_POOL_SIZE,
    /// Number of chunks currently in use
    count: u16 = 0,

    pub fn init(allocator: std.mem.Allocator) ChunkCache {
        return .{
            .lookup = std.AutoHashMap(u64, u16).init(allocator),
        };
    }

    pub fn deinit(self: *ChunkCache) void {
        self.lookup.deinit();
    }

    /// Moves an existing index to the Most Recently Used (MRU) position (head)
    fn moveToHead(self: *ChunkCache, index: u16) void {
        if (self.head == index) return; // Already at head

        // Detach from current position
        const p = self.prev[index];
        const n = self.next[index];

        if (self.tail == index) {
            self.tail = p;
        } else {
            self.prev[n] = p;
        }
        self.next[p] = n;

        // Push to head
        self.next[index] = self.head;
        self.prev[self.head] = index;
        self.head = index;
    }

    /// Retrieves a Chunk pointer if it exists, marking it as Most Recently Used.
    pub fn get(self: *ChunkCache, coord: ScaleCoord) ?*memory.Chunk {
        const h = coord.hash();
        if (self.lookup.get(h)) |index| {
            self.moveToHead(index);
            return &self.pool[index];
        }
        return null;
    }

    /// Allocates a new slot in the cache, evicting the LRU if necessary.
    /// Returns a pointer to the slot. You must manually generate the chunk into this pointer.
    pub fn claimSlot(self: *ChunkCache, coord: ScaleCoord) *memory.Chunk {
        const h = coord.hash();
        var index: u16 = 0;

        if (self.count < CHUNK_POOL_SIZE) {
            // Pool isn't full yet, take the next available slot
            index = self.count;
            self.count += 1;

            if (index == 0) {
                self.head = 0;
                self.tail = 0;
            } else {
                // Attach to head
                self.next[index] = self.head;
                self.prev[self.head] = index;
                self.head = index;
            }
        } else {
            // Evict Least Recently Used (tail)
            index = self.tail;

            // Remove old hash from lookup map
            const old_hash = self.hashes[index];
            _ = self.lookup.remove(old_hash);

            self.moveToHead(index);
        }

        // Register new hash
        self.lookup.put(h, index) catch @panic("LRU Cache HashMap OOM");
        self.hashes[index] = h;

        return &self.pool[index];
    }
};

/// Exposes the tile data directly to JS/WebGPU. Cast to [*]u32 to give array<u32>
pub fn get_tile_ptr(chunk: *Chunk) [*]u32 {
    return @as([*]u32, @ptrCast(&chunk.blocks));
}

/// Generates the raw procedural data for a chunk, given its coordinate and the world's root seed.
pub fn generate_chunk(chunk: *Chunk, coord: ScaleCoord) void {
    const chunk_seed = mixScaleCoord(memory.game.seed, coord);
    var rng = seeding.Xoshiro512.init(chunk_seed);

    for (0..256) |idx| {
        // We call next() to get a fresh 64-bit entropy pool for THIS specific block
        const entropy = rng.next();

        // Extract pieces of the entropy for different block properties
        // This is extremely robust and avoids "pattern bleeding"
        var sprite_id: u20 = @truncate(entropy % 16); // bits 0..19
        const variation: u24 = @truncate(entropy >> 20); // bits 20..43
        // const dark_val: u6 = @truncate(entropy >> 44); // bits 44..50
        const dark_val: u6 = 0;
        if (sprite_id >= 12) sprite_id = 0;
        if (sprite_id >= 10) sprite_id = 1;

        chunk.blocks[idx] = .{
            .id = sprite_id,
            .seed = variation,
            .light = 255 - @as(u8, @intCast(dark_val)),
            .hp = 15,
            .flags = 0, // Calculated in Pass 2
        };
    }
    recalculate_edge_flags(chunk);
}

/// Recalculates visual edge flags by checking neighboring block IDs.
pub fn recalculate_edge_flags(chunk: *Chunk) void {
    const neighbors = [_]struct { dx: i32, dy: i32, flag: u8 }{
        .{ .dx = -1, .dy = -1, .flag = EdgeFlags.TOP_LEFT },
        .{ .dx = 0, .dy = -1, .flag = EdgeFlags.TOP },
        .{ .dx = 1, .dy = -1, .flag = EdgeFlags.TOP_RIGHT },
        .{ .dx = -1, .dy = 0, .flag = EdgeFlags.LEFT },
        .{ .dx = 1, .dy = 0, .flag = EdgeFlags.RIGHT },
        .{ .dx = -1, .dy = 1, .flag = EdgeFlags.BOTTOM_LEFT },
        .{ .dx = 0, .dy = 1, .flag = EdgeFlags.BOTTOM },
        .{ .dx = 1, .dy = 1, .flag = EdgeFlags.BOTTOM_RIGHT },
    };

    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            const idx = y * CHUNK_SIZE + x;
            const current_sprite = chunk.blocks[idx].id;
            var flags: u8 = 0;

            for (neighbors) |n| {
                const nx: i32 = @as(i32, @intCast(x)) + n.dx;
                const ny: i32 = @as(i32, @intCast(y)) + n.dy;

                // Edges of the chunk count as "different" for now.
                // In a true engine, you would read from adjacent chunks if available.
                if (nx < 0 or nx >= CHUNK_SIZE or ny < 0 or ny >= CHUNK_SIZE) {
                    flags |= n.flag;
                } else {
                    const neighbor_idx: usize = @intCast(ny * @as(i32, CHUNK_SIZE) + nx);
                    if (chunk.blocks[neighbor_idx].id != current_sprite) {
                        flags |= n.flag;
                    }
                }
            }

            chunk.blocks[idx].flags = flags;
        }
    }
}

/// Internal helper to securely mix the X/Y coordinates and unbounded depth path into the RNG seed.
fn mixScaleCoord(base_seed: [8]u64, coord: ScaleCoord) [8]u64 {
    // Note: Assuming seeding.staffordMix13 exists and acts as a strong u64 -> u64 hash step
    var state = base_seed;

    // Mix positional data
    state[0] +%= seeding.staffordMix13(@bitCast(coord.pos[0]));
    state[1] +%= seeding.staffordMix13(@bitCast(coord.pos[1]));

    // Mix depth stack (Since depth_stack is now[]const u64, it's blazing fast)
    var state_idx: usize = 2;
    for (coord.depth_stack) |packed_depth_block| {
        state[state_idx % 8] +%= seeding.staffordMix13(packed_depth_block);
        state_idx += 1;
    }

    // Final diffusion to spread the entropy
    const old = state;
    inline for (0..8) |i| {
        state[i] = seeding.staffordMix13(old[i] ^ old[(i + 1) % 8]);
    }

    return state;
}
