//! Contains initialization and render update functions.
//! See `root.zig` for exporting these functions (and others) to WASM.
const std = @import("std");
const dw = @import("root.zig");
const memory = dw.memory;
const sprite = dw.sprite;
const logger = dw.logger;
const seeding = dw.seeding;
const world = dw.world;
const player = dw.player;

const CHUNK_SIZE = dw.CHUNK_SIZE;
const CHUNK_SIZE_SQ = dw.CHUNK_SIZE_SQ;
const CHUNK_SIZE_FLOAT = dw.CHUNK_SIZE_FLOAT;
const SUBPIXELS_IN_CHUNK = dw.SUBPIXELS_IN_CHUNK;

/// Sets the number of times the `push_layer` function is called in `startup.init()`.
/// If set to n, the game will start off by being n ** ZOOM_FACTOR chunks in either dimension.
pub const STARTING_ZOOM_TIMES = 4;
/// Sets the player's spawn randomly (if `STARTING_ZOOM_TIMES` is positive).
const SET_PLAYER_SPAWN_RANDOMLY = true;

comptime {
    // technically, floating-point inaccuracies start to ~3% influence procedural generation at STARTING_ZOOM_TIMES = 7
    // since the max coordinate from a block perspective is 2 ^ (7 * ZOOM_LOG2 + 4) and 2 ^ (7 * ZOOM_LOG2) from a chunk perspective
    // that ends up meaning that you're using 18 of 23 bits of precision in f32
    // any more than that would be pretty bad, probably; 3% precision jitter is pretty much negligible

    // note that setting STARTING_ZOOM_TIMES to 0 or 1 may result in fully empty or boring chunks
    if (STARTING_ZOOM_TIMES < 0 or STARTING_ZOOM_TIMES > 7) {
        @compileError("STARTING_ZOOM_TIMES must be between 0 and 7 to prevent floating point or logic issues!");
    }
}

/// Whether `init()` has already been called (from `main()` the first time).
var alreadyStarted = false;

/// Resets various datatypes and allocators after an instance of the game has already started.
/// (Restores the seed value though!)
fn resetAfterStart() void {
    if (!world.arena.reset(.retain_capacity)) memory.oom();
    const saved_seed = memory.game.seed;
    memory.game = .{};
    memory.game.seed = saved_seed;

    @import("menus/furnace.zig").reset();
    @import("menus/corecraft.zig").reset();
    dw.particles.reset();
    world.SimBuffer.reset();
    dw.water.reset();
    // dropped item ring buffer lives in the world arena reset above; detach instead of freeing
    dw.inventory.dropped_items = .{};

    dw.inventory.reset();

    // Clear paths in quad_cache to prevent depth piling up on reset/reseed

    world.clearCaches(true);
    world.initArenaAllocatedStructures();
}

/// Initializes the game, resets datatypes, and sets up seeding and spawn logic!
/// Use `skip_setup` to only call `resetAfterStart()`.
pub fn init(skip_setup: bool) void {
    if (alreadyStarted or skip_setup) {
        alreadyStarted = true;
        resetAfterStart();
        if (skip_setup) return;
    } else {
        alreadyStarted = true;
        logger.log(@src(), "Hello from Zig!", .{});
        world.initArenaAllocatedStructures();
    }

    const seed = memory.game.seed;
    var temp_seed = seeding.ChaCha12.init(&seeding.mixBaseSeed(seed, 1));
    inline for (&memory.game.seed2) |*s| {
        s.* = temp_seed.next();
    }

    // Start off by determining where the player starts off exactly with layer pushing
    dw.sound.seed = seeding.ChaCha12.init(&seeding.mixBaseSeed(seed, 2));
    dw.particles.seed = seeding.ChaCha12.init(&seeding.mixBaseSeed(seed, 3));

    var rng = seeding.ChaCha12.init(&seeding.mixBaseSeed(seed, 100));
    for (0..STARTING_ZOOM_TIMES) |_| {
        // Set the player position to somewhere random in the current chunk
        if (SET_PLAYER_SPAWN_RANDOMLY) memory.game.setPlayerPosDumb(.{
            @intCast(rng.next() & (dw.SUBPIXELS_IN_CHUNK - 1)),
            @intCast(rng.next() & (dw.SUBPIXELS_IN_CHUNK - 1)),
        });

        world.pushLayer(
            .none,
            memory.game.getPlayerCoord(),
            memory.game.getBlockXInChunk(), // convert a subpixel (0-4095) in a chunk to a block in a chunk (0-15)
            memory.game.getBlockYInChunk(),
        );
    }

    world.quad_cache.path_hashes.value[0] = memory.game.seed;

    if (SET_PLAYER_SPAWN_RANDOMLY) {
        findSafeSpawn();
        // world.SimBuffer.sync(memory.game.getPlayerCoord(), .{ 16, 16 });
    }
}

const SPAWN_CHECK_SIZE = 32;

/// Searches for a safe grounded spawn point by spiraling through CHUNKS
/// and scanning all blocks within those chunks.
pub fn findSafeSpawn() void {
    const game = &memory.game;
    const start_coord = game.getPlayerCoord();

    var chunk: memory.Chunk = undefined; // temp buffer for performance

    // Spiral parameters (on increments of chunks)
    var side_len: i64 = 1;
    var dx: i64 = 1;
    var dy: i64 = 0;
    var segment_passed: i64 = 0;
    var cx: i64 = 0;
    var cy: i64 = 0;

    // check a diamond area, in case there's some weird issues
    var i: u32 = 0;
    while (@abs(cx) + @abs(cy) < (SPAWN_CHECK_SIZE * 2)) {
        if (start_coord.move(.{ cx, cy })) |nc| {
            world.writeChunk(&chunk, nc);

            // Scan the chunk for a "safe" spot!
            var y: usize = 0;
            while (y < CHUNK_SIZE - 1) : (y += 1) {
                const row = y * CHUNK_SIZE;
                const column = (y + 1) * CHUNK_SIZE;

                for (0..CHUNK_SIZE) |x| {
                    const block = chunk.blocks[row + x];
                    const block_below = chunk.blocks[column + x];

                    if (block.isEmpty() and block_below.isSolid()) {
                        // Found a valid floor!
                        game.player_quadrant = nc.quadrant;
                        game.player_chunk = nc.suffix;

                        game.setPlayerPosDumb(.{
                            @as(i64, @intCast(x)) * CHUNK_SIZE_SQ + (CHUNK_SIZE_SQ / 2),
                            @as(i64, @intCast(y)) * CHUNK_SIZE_SQ + (CHUNK_SIZE_SQ / 2) - 1, // -1 or you have to jump to move
                        });

                        game.setCameraPosDumb(game.player_pos);
                        return;
                    }
                }
            }

            i += 1; // increment i for next loop iter
        }

        // Update spiral to next CHUNK
        cx += dx;
        cy += dy;
        segment_passed += 1;
        if (segment_passed >= side_len) {
            segment_passed = 0;
            const temp = dx;
            dx = -dy;
            dy = temp;
            if (dy == 0) side_len += 1;
        }
    }

    // Fallback: If no ground found in nearby chunks, center in current chunk
    game.setPlayerPosDumb(.{ 2048, 2048 });
}
