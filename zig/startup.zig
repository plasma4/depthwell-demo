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

/// Sets the player's spawn randomly when `STARTING_ZOOM_TIMES` is positive.
const SET_PLAYER_SPAWN_RANDOMLY = true;

/// Sets the number of times `push_layer` is called in `startup.init()`.
/// If set to n, the game starts at a scale of `4^n` chunks wide in each dimension.
pub const STARTING_ZOOM_TIMES = 13;

comptime {
    // bit of yapping analysis
    // floating-point precision starts to affect procedural generation noticeably around:
    // - 48 bits for f64 (53 bits precision total, implicit leading bit)
    // - 20 bits for f32 (24 bits precision total, including implicit leading bit)
    // for f64: this occurs when STARTING_ZOOM_TIMES = 22, for a 4 ** (2 + 22) world block width, jitter/clamping at 1/32nd occurs
    // for f32: this occurs when STARTING_ZOOM_TIMES = 8, for a 4 ** (2 + 8) world block width, jitter/clamping to ~1/16th occurs
    // decreasing STARTING_ZOOM_TIMES by just one makes the jitter 4x less so generally anything less than that is safe

    // f32->f64 lowers perf significantly so instead we would rather eliminate f32 entirely and use integers
    // rather than the engine's. see procedural.WORLEY_FLOAT_PLACEMENT:
    // - at 7 and below, the Worley pass converts the coordinate to f32 directly, because it is still exact there
    // - at 8 and above, it places the sample in fixed point instead, which never quantizes at any world size
    //   (costs ~5% of computeBaseSpriteType(), so it stays off until it is actually needed)
    // both routes agree to f32 rounding wherever both are valid, so crossing 7 changes the world's SIZE and not the world

    // what binds now is integer width, not mantissa width: `structures.MAX_WORLD_BLOCK` is an i32
    // (deliberately, it is what traps out-of-world structure probes), so a 4 ** (2 + 14) world overflows it.
    // 13 is verified to build and pass the suite; going past it means widening the structure pass to i64.
    if (STARTING_ZOOM_TIMES > 13) {
        @compileError("STARTING_ZOOM_TIMES must be less than or equal to 13; structures.MAX_WORLD_BLOCK is an i32 and overflows past it!");
    } else if (STARTING_ZOOM_TIMES < 0) {
        @compileError("STARTING_ZOOM_TIMES must be positive to allow for 1 full chunk to generate!");
    }
}

/// Whether `init()` has already been called (from `main()` the first time).
var alreadyStarted = false;

/// Resets various datatypes and allocators after an instance of the game has already started.
/// (Restores the seed value though!)
fn resetAfterStart() void {
    if (!world.arena.reset(.retain_capacity)) memory.oom();
    // string must travel with seed produced!
    const saved_seed = memory.game.seed;
    const saved_seed_string = memory.game.seed_string;
    const saved_seed_string_len = memory.game.seed_string_len;
    memory.game = .{};
    memory.game.seed = saved_seed;
    memory.game.seed_string = saved_seed_string;
    memory.game.seed_string_len = saved_seed_string_len;

    @import("menus/furnace.zig").reset();
    @import("menus/corecraft.zig").reset();
    @import("menus/loot.zig").reset();
    dw.particles.reset();
    world.SimBuffer.reset();
    dw.water.reset();
    // Seeded here (as well as from the loaded seed in `save.finalizeLoad()`) so it is never left undefined:
    // this path runs for both a new world and an import, including one that fails.
    dw.chunks.shake_seed = seeding.ChaCha12.init(&seeding.mixBaseSeed(memory.game.seed, .screen_shake));
    // Frees the descent's preview buffer; `memory.game` above already cleared its saved fields.
    dw.portal.reset();
    dw.player.resetSoftlockFade();

    // dropped item ring buffer lives in the world arena reset above; detach instead of freeing
    dw.inventory.dropped_items = .{};
    dw.inventory.reset();

    dw.mining.reset();

    world.clearCaches(true);
    world.initArenaAllocatedStructures();
}

/// Initializes the game, resets datatypes, and sets up seeding and spawn logic!
///
/// Set `new_game` to false to only call `resetAfterStart()`, without setting up the world and seeding.
/// (This is used when importing a save.)
pub fn init(new_game: bool) void {
    dw.save.in_tick = false; // a rebuilt world is coherent again after a mid-tick trap
    if (alreadyStarted or !new_game) {
        alreadyStarted = true;
        resetAfterStart();
        if (!new_game) return;
    } else {
        alreadyStarted = true;
        logger.log(@src(), "Hello from Zig!", .{});
        world.initArenaAllocatedStructures();
    }

    const seed = memory.game.seed;
    memory.deriveHashSeeds();

    // Start off by determining where the player starts off exactly with layer pushing
    dw.sound.seed = seeding.ChaCha12.init(&seeding.mixBaseSeed(seed, .sound));
    dw.particles.seed = seeding.ChaCha12.init(&seeding.mixBaseSeed(seed, .particles));
    dw.chunks.shake_seed = seeding.ChaCha12.init(&seeding.mixBaseSeed(seed, .screen_shake));

    // Offset the background's animation clock by up to two minutes so two worlds never open on the same frame of it!
    const BG_PHASE_SPREAD_MS = 120_000;
    memory.game.bg_time = @as(f64, @floatFromInt(
        seeding.mixBaseSeed(seed, .background).value[0] % BG_PHASE_SPREAD_MS,
    )) / 1000.0;

    var rng = seeding.ChaCha12.init(&seeding.mixBaseSeed(seed, .startup_layers));
    for (0..STARTING_ZOOM_TIMES) |_| {
        // Set the player position to somewhere random in the current chunk
        if (SET_PLAYER_SPAWN_RANDOMLY) memory.game.setPlayerPosDumb(.{
            @intCast(rng.next() & (dw.SUBPIXELS_IN_CHUNK - 1)),
            @intCast(rng.next() & (dw.SUBPIXELS_IN_CHUNK - 1)),
        });

        world.pushLayer(
            memory.game.getPlayerCoord(),
            memory.game.getBlockXInChunk(), // convert a subpixel (0-4095) in a chunk to a block in a chunk (0-15)
            memory.game.getBlockYInChunk(),
        );
    }

    world.quad_cache.path_hashes.value[0] = memory.game.seed;

    if (SET_PLAYER_SPAWN_RANDOMLY) {
        findSafeSpawn();
        // findSafeSpawn() fills the live buffer before it selects this position!
        _ = dw.player.escapeSolid();
    }
}

/// Maximum chunk distance from the spawn center that the loaded window can contain.
const SPAWN_SEARCH_RADIUS_CHUNKS: i64 = @intCast(world.SIM_BUFFER_WIDTH / 2);

/// Finds a safe grounded spawn in the loaded simulation window.
///
/// This fills and scans at most one `SimBuffer` window.
/// It must not generate an unbounded spiral of chunks during a new game or debug teleport.
/// The later `escapeSolid()` check handles the rare case where this window has no grounded cell.
pub fn findSafeSpawn() void {
    const game = &memory.game;
    const start_coord = game.getPlayerCoord();

    // The fixed window is the complete spawn-search budget. Reads below are resident only.
    // At a normal centered window, the radius-8 positive edge is one chunk past its half-open side.
    // `SimBuffer.get()` returns null there without generation. At a clamped world edge, that coordinate can be resident.
    world.SimBuffer.sync(start_coord);

    var radius: i64 = 0;
    while (radius <= SPAWN_SEARCH_RADIUS_CHUNKS) : (radius += 1) {
        var cy: i64 = -radius;
        while (cy <= radius) : (cy += 1) {
            var cx: i64 = -radius;
            while (cx <= radius) : (cx += 1) {
                if (@max(@abs(cx), @abs(cy)) != radius) continue;
                const coord = start_coord.move(.{ cx, cy }) orelse continue;
                const chunk = world.SimBuffer.get(coord) orelse continue;

                var y: usize = 0;
                while (y < CHUNK_SIZE - 1) : (y += 1) {
                    const row = y * CHUNK_SIZE;
                    const below_row = (y + 1) * CHUNK_SIZE;

                    for (0..CHUNK_SIZE) |x| {
                        if (!chunk.blocks[row + x].isEmpty() or !chunk.blocks[below_row + x].isSolid()) continue;

                        game.player_quadrant = coord.quadrant;
                        game.player_chunk = coord.suffix;
                        game.setPlayerPosDumb(.{
                            @as(i64, @intCast(x)) * CHUNK_SIZE_SQ + (CHUNK_SIZE_SQ / 2),
                            @as(i64, @intCast(y)) * CHUNK_SIZE_SQ + (CHUNK_SIZE_SQ / 2) - 1,
                        });
                        game.setCameraPosDumb(game.player_pos);
                        return;
                    }
                }
            }
        }
    }

    // The correction probe will move an improbable blocked fallback position.
    game.setPlayerPosDumb(.{ 2048, 2048 });
}
