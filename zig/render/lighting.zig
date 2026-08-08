//! CPU lighting pass over the visible block buffer. Writes 0..255 brightness each block's `light` prop.
//! WGSL will then multiply the OKLAB lightness by `light / 255.0`; this logic handles both orange and white light types.
//!
//! Uses inverted Dial's algorithm (bucketed Dijkstra): each reachable cell is finalized exactly once at its brightest value,
//! so overlapping light sources cost no extra relaxation (makes performance linear with some acceptable memory cost).
//! Worst-case memory cost is reduced by using a dedicated arena that resets every time `applyLighting()` is called.
//!
//! Light spreads to all 8 neighbors with a sqrt(2) diagonal cost for an approximated circular falloff.
//! Based on the block type (air, solid, or liquid) and HP, the decay rate changes/interpolates as needed.
//!
//! NOTE: In Debug builds, this code can be a significant contributor to lag.

const std = @import("std");
const dw = @import("../root.zig");
const memory = dw.memory;
const world = dw.world;

const Block = memory.Block;
const Sprite = dw.Sprite;

/// Max brightness bound by `u8`.
pub const MAX_LIGHT: u8 = 255;
/// Min baseline brightness for unlit cells.
pub const AMBIENT_LIGHT: u8 = 0;
/// Debug ambient light brightness if the debug boolean is enabled.
pub const AMBIENT_LIGHT_DEBUG: u8 = 192;

/// Determines whether light should be global.
pub var IS_LIGHT_GLOBAL = false;

// Light strength values for various sources:
pub var PLAYER_LIGHT: u16 = 255;
pub const MAX_PLAYER_LIGHT: u16 = 400;
// ----
pub const CAMPFIRE_LIGHT: u16 = 240;
pub const FURNACE_LIGHT: u16 = AMBIENT_LIGHT;
pub const LAVA_LIGHT: u16 = 60;
// ----
pub const PORTAL_LIGHT: u16 = 200;
pub const PLATE_LIGHT: u16 = 160;
pub const ORE_GEM_LIGHT: u16 = 100; // some ores may glow
pub const TWINKLEVINE_LIGHT: u16 = 80;

// Orthogonal decay rates per block type. Air should always be the lowest (decays slowest)!
pub const AIR_FALLOFF: u16 = 12;
pub const SOLID_FALLOFF: u16 = 28;
pub const LIQUID_FALLOFF: u16 = SOLID_FALLOFF - 12;

/// Brightest possible seed value; bounds the number of Dial buckets.
const MAX_SOURCE: u16 = @max(
    MAX_PLAYER_LIGHT,
    CAMPFIRE_LIGHT,
    FURNACE_LIGHT,
    PORTAL_LIGHT,
    PLATE_LIGHT,
    ORE_GEM_LIGHT,
    TWINKLEVINE_LIGHT,
    LAVA_LIGHT,
);
const NUM_BUCKETS: usize = MAX_SOURCE + 1;

fn blockEmission(id: Sprite) u16 {
    return switch (id) {
        .campfire => CAMPFIRE_LIGHT,
        .forest_furnace, .lava_furnace => FURNACE_LIGHT,
        .portal, .invportal => PORTAL_LIGHT,
        .white_plate => PLATE_LIGHT,
        .aquashard, .electrit => ORE_GEM_LIGHT,
        .twinklemoss => TWINKLEVINE_LIGHT,
        .lava_stone, .molten_stone => LAVA_LIGHT,
        else => 0,
    };
}

/// Returns true if the block is a warm light source, which creates an orange light glow in the shader.
fn isOrangeSource(id: Sprite) bool {
    return switch (id) {
        .campfire => true,
        .forest_furnace, .lava_furnace => true,
        .lava_stone => true,
        else => false,
    };
}

comptime {
    // Orthogonal cost is stored per-cell as u8; every falloff must fit.
    std.debug.assert(SOLID_FALLOFF <= 255 and LIQUID_FALLOFF <= 255 and AIR_FALLOFF <= 255);
}

/// `ArenaAllocator` instance used for lighting logic.
var arena = memory.makeArena();
/// `Allocator` from `arena`.
var alloc = arena.allocator();

/// Sets up lighting algorithm `ArrayList`s. Discards all invalidated pointers to prevent use-after-free corruption.
/// Called whenever `applyLighting()` is called to reset allocator.
fn resetArena() void {
    if (!arena.reset(.retain_capacity)) memory.oom();
    @memset(&buckets_orange, .empty);
    @memset(&buckets_white, .empty);

    cost_buffer = std.array_list.Aligned(u8, .@"16").initCapacity(alloc, 2048) catch memory.oom();
    orange_buffer = std.array_list.Aligned(u16, .@"16").initCapacity(alloc, 2048) catch memory.oom();
    white_buffer = std.array_list.Aligned(u16, .@"16").initCapacity(alloc, 2048) catch memory.oom();
}

/// Orthogonal per-step light cost for entering `block`. Fits in u8 (<= SOLID_FALLOFF).
/// Diagonals are derived from this at flood time via the fast sqrt(2) approximation.
fn orthoCost(block: Block) u8 {
    if (block.isLiquid()) return @intCast(LIQUID_FALLOFF);

    // Treat empty/air blocks as hp = 16, solid blocks use their actual hp value (0..15).
    const hp: u16 = if (block.isSolid()) block.hp else 16;

    // Linearly interpolate between SOLID_FALLOFF (hp = 0) and AIR_FALLOFF (hp = 16).
    const diff = SOLID_FALLOFF - AIR_FALLOFF;
    const decay = (@as(u32, diff) * hp + 8) / 16;
    var falloff: u16 = SOLID_FALLOFF - @as(u16, @intCast(decay));

    // Cap minimum at liquid falloff if the block is waterlogged.
    if (block.waterlogged != 0) {
        falloff = @max(falloff, LIQUID_FALLOFF);
    }
    return @intCast(falloff);
}

/// Fast, 100% accurate integer approximation of round(ortho * sqrt(2)) for diagonal steps.
inline fn diagCost(ortho: u16) u16 {
    return (ortho * 181 + 64) >> 7;
}

/// Simulates the worst-case (straight line, air) light path to find max reach distance in blocks.
fn maxAirReachBlocks() comptime_int {
    comptime {
        var brightness: u16 = MAX_SOURCE;
        var blocks: comptime_int = 0;
        const light = @min(AMBIENT_LIGHT, AMBIENT_LIGHT_DEBUG);
        while (brightness > AIR_FALLOFF and (brightness - AIR_FALLOFF) > light) {
            brightness -= AIR_FALLOFF;
            blocks += 1;
        }
        return blocks;
    }
}

/// Buffer padding margin (in chunks) to capture off-screen light bleed.
pub const CHUNK_MARGIN: u32 = @max(1, std.math.divCeil(
    u32,
    maxAirReachBlocks(),
    dw.CHUNK_SIZE,
) catch unreachable);

/// Precomputed orthogonal step cost per cell (u8 keeps the flood's neighbor reads cache-friendly).
var cost_buffer: std.array_list.Aligned(u8, .@"16") = undefined;
/// High-precision per-cell light, orange (warm) channel.
var orange_buffer: std.array_list.Aligned(u16, .@"16") = undefined;
/// High-precision per-cell light, white (player/plate) channel.
var white_buffer: std.array_list.Aligned(u16, .@"16") = undefined;

/// Dial buckets, one FIFO of packed coords per light level, for each channel.
var buckets_orange: [NUM_BUCKETS]std.array_list.Aligned(u32, .@"16") = undefined;
var buckets_white: [NUM_BUCKETS]std.array_list.Aligned(u32, .@"16") = undefined;

inline fn packCoords(x: u16, y: u16) u32 {
    return @as(u32, x) | (@as(u32, y) << 16);
}

inline fn unpackX(p: u32) u16 {
    return @as(u16, @intCast(p & 0xFFFF));
}

inline fn unpackY(p: u32) u16 {
    return @as(u16, @intCast(p >> 16));
}

/// Seeds a cell into a channel: raises its light to `val` and enqueues it into that value's bucket.
/// No-op if `val` does not improve the cell or does not clear ambient.
inline fn seed(a: std.mem.Allocator, light: []u16, buckets: *[NUM_BUCKETS]std.array_list.Aligned(u32, .@"16"), i: usize, x: u16, y: u16, val: u16, ambient: u16) void {
    if (val > light[i] and val > ambient) {
        light[i] = val;
        buckets[@as(usize, val)].append(a, packCoords(x, y)) catch memory.oom();
    }
}

/// Seeds the 2x2 cells surrounding the player using their continuous sub-pixel position.
/// Light drops off similar to Euclidean distance through the cell's own medium cost.
fn seedPlayerLight(
    a: std.mem.Allocator,
    cost: []const u8,
    light_white: []u16,
    buckets: *[NUM_BUCKETS]std.array_list.Aligned(u32, .@"16"),
    w: i32,
    h: i32,
    ambient: u16,
    px: f32,
    py: f32,
) void {
    const cx0: i32 = @intFromFloat(@floor(px - 0.5));
    const cy0: i32 = @intFromFloat(@floor(py - 0.5));

    inline for (0..2) |oy| {
        inline for (0..2) |ox| {
            const cx = cx0 + @as(i32, ox);
            const cy = cy0 + @as(i32, oy);
            if (cx >= 0 and cx < w and cy >= 0 and cy < h) {
                const i: usize = @intCast(cy * w + cx);
                const dx = px - (@as(f32, @floatFromInt(cx)) + 0.5);
                const dy = py - (@as(f32, @floatFromInt(cy)) + 0.5);
                // use the cell's own medium rate, not air
                const falloff: f32 = @floatFromInt(cost[i]);
                const drop = @round(@sqrt(dx * dx + dy * dy) * falloff);
                if (@as(f32, PLAYER_LIGHT) > drop) {
                    const val: u16 = @intFromFloat(@as(f32, PLAYER_LIGHT) - drop);
                    seed(a, light_white, buckets, i, @intCast(cx), @intCast(cy), val, ambient);
                }
            }
        }
    }
}

/// One single-channel Dial flood: process buckets brightest -> dimmest, relaxing 8 neighbors.
/// Because we descend and edge costs are strictly positive, appends only ever target strictly-lower
/// buckets, so each cell is finalized exactly once at its brightest value regardless of source count.
fn floodChannel(
    a: std.mem.Allocator,
    cost: []const u8,
    light: []u16,
    buckets: *[NUM_BUCKETS]std.array_list.Aligned(u32, .@"16"),
    w: i32,
    h: i32,
    ambient: u16,
) void {
    var b: u16 = MAX_SOURCE;
    while (b > ambient) : (b -= 1) {
        const bucket_id: usize = @intCast(b);
        // Nothing appends to buckets[b] once we reach level b (relaxation only writes lower levels),
        // so this backing slice is stable for the duration of the inner loop.
        const items = buckets[bucket_id].items;
        for (items) |pc| {
            const x = @as(i32, unpackX(pc));
            const y = @as(i32, unpackY(pc));
            const idx: usize = @intCast(y * w + x);

            // Skip stale entries: this cell was later relaxed to a brighter bucket and already handled.
            if (light[idx] != b) continue;

            inline for ([_][2]i32{
                .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
                .{ -1, 0 },  .{ 1, 0 },  .{ -1, 1 },
                .{ 0, 1 },   .{ 1, 1 },
            }) |d| {
                const nx = x + d[0];
                const ny = y + d[1];
                if (nx >= 0 and nx < w and ny >= 0 and ny < h) {
                    const ni: usize = @intCast(ny * w + nx);
                    const oc: u16 = cost[ni];
                    const c: u16 = if (d[0] != 0 and d[1] != 0) diagCost(oc) else oc;
                    if (b > c) {
                        const nl = b - c;
                        if (nl > light[ni]) {
                            light[ni] = nl;
                            buckets[@as(usize, nl)].append(a, packCoords(
                                @intCast(nx),
                                @intCast(ny),
                            )) catch memory.oom();
                        }
                    }
                }
            }
        }
    }
}

/// Executes a bucketed Dijkstra light flood over the visible lbock array.
/// Writes the final per-block `light` (0..255) and `lighting_color` (orange flag).
pub fn applyLighting(out: []Block, wb: u32, hb: u32, player_bx: f32, player_by: f32) void {
    resetArena();
    const w: i32 = @intCast(wb);
    const h: i32 = @intCast(hb);
    const wbw: u16 = @intCast(wb);

    // Recycle scratch: retain capacity, reset contents below.
    for (&buckets_orange) |*bk| bk.clearRetainingCapacity();
    for (&buckets_white) |*bk| bk.clearRetainingCapacity();
    cost_buffer.resize(alloc, out.len) catch memory.oom();
    orange_buffer.resize(alloc, out.len) catch memory.oom();
    white_buffer.resize(alloc, out.len) catch memory.oom();

    const cost_slice = cost_buffer.items;
    const light_orange = orange_buffer.items;
    const light_white = white_buffer.items;

    const ambient: u16 = if (dw.dev_menu and IS_LIGHT_GLOBAL) AMBIENT_LIGHT_DEBUG else AMBIENT_LIGHT;

    // Single reset pass: precompute per-cell cost, initialize both channels to ambient
    // then, "seed" (add) light-emitting blocks into their channel's appropriate buckets.
    var sy: u16 = 0;
    var sx: u16 = 0;
    for (out, 0..) |block, i| {
        cost_slice[i] = orthoCost(block);
        light_orange[i] = ambient;
        light_white[i] = ambient;

        const emission = blockEmission(block.id);
        if (emission > ambient) {
            if (isOrangeSource(block.id)) {
                seed(alloc, light_orange, &buckets_orange, i, sx, sy, emission, ambient);
            } else {
                seed(alloc, light_white, &buckets_white, i, sx, sy, emission, ambient);
            }
        }

        sx += 1;
        if (sx == wbw) {
            sx = 0;
            sy += 1;
        }
    }

    // Seed the continuous player source into the white channel.
    // This one is interpolated between logic ticks so the light does not snap block to block;
    // anything that has to AGREE with the simulation reads `miningLightAt()` instead, never this.
    seedPlayerLight(alloc, cost_slice, light_white, &buckets_white, w, h, ambient, player_bx, player_by);

    // Two independent floods over the shared cost grid for each color!
    floodChannel(alloc, cost_slice, light_orange, &buckets_orange, w, h, ambient);
    floodChannel(alloc, cost_slice, light_white, &buckets_white, w, h, ambient);

    // Combine channels and write final u8 values clamped to MAX_LIGHT.
    for (out, light_orange, light_white) |*block, orange, white| {
        const max_light = @max(orange, white);
        block.light = @intCast(@min(max_light, @as(u16, MAX_LIGHT)));

        // this fixes an issue where orange light overtakes normal white light if ambient light is at max
        if (AMBIENT_LIGHT == 255 or (dw.dev_menu and IS_LIGHT_GLOBAL and AMBIENT_LIGHT_DEBUG == 255)) continue;

        // block is orange if it receives more orange light than white, or is in the core radius (>= 255)
        const is_orange = orange >= white or orange >= 255;
        block.lighting_color = @intFromBool(is_orange and max_light > ambient);
    }
}

// This is the end of render (visual-only) light logic.
// ----
// This is the start, now, of logic for the player's ability to mine.
// Based on actual PLAYER_LIGHT and visual light decay values.

/// Farthest a player-lit block can be, in blocks: the brightest possible player source (`MAX_PLAYER_LIGHT`)
/// spending the cheapest possible cost per step (`AIR_FALLOFF`).
const PLAYER_LIGHT_REACH: i32 = MAX_PLAYER_LIGHT / AIR_FALLOFF;
/// Half-width of the flooded window: the reach, plus the one block the player's 2x2 seed straddles into.
/// Nothing outside it can take any of the player's light, so clipping the flood at the window loses none:
/// a path that leaves the window has already spent more than `MAX_PLAYER_LIGHT` getting there.
const MINING_RADIUS: i32 = PLAYER_LIGHT_REACH + 1;
/// Window edge in blocks, centered on the block the player stands in.
const MINING_SPAN: usize = @intCast(2 * MINING_RADIUS + 1);

/// Player-only light (no ambient, no other source) of the window around the player, clamped to `MAX_LIGHT`.
/// Indexed by `miningIndex()`; only describes the world `mining_key` was recorded for.
var mining_light: [MINING_SPAN * MINING_SPAN]u8 = @splat(0);
/// Cost grid the window was flooded over, and the high-precision light it was flooded into.
var mining_cost: [MINING_SPAN * MINING_SPAN]u8 = @splat(0);
var mining_scratch: [MINING_SPAN * MINING_SPAN]u16 = @splat(0);

/// Everything the flooded window is a function of, besides the blocks themselves.
/// A query that does not match re-floods, so the window can never describe a place the player has left:
/// the tick alone would not catch a teleport, which moves the player without advancing it.
const MiningKey = struct {
    frame: u32,
    depth: u64,
    coord: world.Coordinate,
    bx: u4,
    by: u4,

    fn eql(a: MiningKey, b: MiningKey) bool {
        return a.frame == b.frame and a.depth == b.depth and
            a.bx == b.bx and a.by == b.by and a.coord.eql(b.coord);
    }
};

/// What `mining_light` currently holds, or null when it holds nothing usable.
var mining_key: ?MiningKey = null;

/// The window `mining_light` would be flooded for right now.
fn currentMiningKey() MiningKey {
    const game = &memory.game;
    return .{
        .frame = game.frame,
        .depth = game.depth,
        .coord = game.getPlayerCoord(),
        .bx = game.getBlockXInChunk(),
        .by = game.getBlockYInChunk(),
    };
}

/// Buckets and arena of the mining flood, kept apart from the render pass's so that neither can
/// reset the allocator out from under the other, whatever order a frame and a tick land in.
var mining_arena = memory.makeArena();
var mining_alloc = mining_arena.allocator();
var buckets_mining: [NUM_BUCKETS]std.array_list.Aligned(u32, .@"16") = undefined;

/// Window index of the block (`dx`, `dy`) blocks from the one the player stands in, or null when that
/// block is out of the window (which, per `MINING_RADIUS`, means the player's light cannot reach it).
inline fn miningIndex(dx: i64, dy: i64) ?usize {
    if (dx < -MINING_RADIUS or dx > MINING_RADIUS or dy < -MINING_RADIUS or dy > MINING_RADIUS) return null;
    return @intCast((dy + MINING_RADIUS) * @as(i64, MINING_SPAN) + (dx + MINING_RADIUS));
}

/// Floods the player's own light over the window around them, from committed simulation state only:
/// the block they stand in, their subpixel position within it, and the blocks currently in the world.
/// No interpolation, no camera, no zoom, so every tick answers the same regardless of frame rate.
fn floodMiningLight() void {
    const game = &memory.game;
    if (!mining_arena.reset(.retain_capacity)) memory.oom();
    @memset(&buckets_mining, .empty);
    @memset(&mining_scratch, 0);

    // Fill the cost grid chunk by chunk rather than block by block, so a chunk is resolved once.
    // An unreachable chunk (past the world edge) reads as solid, which is what the world edge is.
    const player_coord = game.getPlayerCoord();
    const base_bx: i32 = game.getBlockXInChunk();
    const base_by: i32 = game.getBlockYInChunk();
    const min_cx = @divFloor(base_bx - MINING_RADIUS, dw.CHUNK_SIZE);
    const max_cx = @divFloor(base_bx + MINING_RADIUS, dw.CHUNK_SIZE);
    const min_cy = @divFloor(base_by - MINING_RADIUS, dw.CHUNK_SIZE);
    const max_cy = @divFloor(base_by + MINING_RADIUS, dw.CHUNK_SIZE);

    var scratch_chunk: memory.Chunk align(memory.MAIN_ALIGN_BYTES) = undefined;
    var cy = min_cy;
    while (cy <= max_cy) : (cy += 1) {
        var cx = min_cx;
        while (cx <= max_cx) : (cx += 1) {
            const chunk: ?*const memory.Chunk = blk: {
                const coord = player_coord.move(.{ cx, cy }) orelse break :blk null;
                if (world.SimBuffer.get(coord)) |loaded| break :blk loaded;
                world.writeChunkSimless(&scratch_chunk, coord);
                break :blk &scratch_chunk;
            };

            // Player-relative block offset of this chunk's own (0, 0), so only the part of the chunk
            // that lands inside the window is walked. The corner chunks are mostly outside it.
            const chunk_x0 = cx * dw.CHUNK_SIZE - base_bx;
            const chunk_y0 = cy * dw.CHUNK_SIZE - base_by;
            const lx_end = @min(dw.CHUNK_SIZE - 1, MINING_RADIUS - chunk_x0);
            const ly_end = @min(dw.CHUNK_SIZE - 1, MINING_RADIUS - chunk_y0);

            var ly = @max(0, -MINING_RADIUS - chunk_y0);
            while (ly <= ly_end) : (ly += 1) {
                var lx = @max(0, -MINING_RADIUS - chunk_x0);
                while (lx <= lx_end) : (lx += 1) {
                    // `.?` rather than a skip: the ranges above are exactly the in-window part.
                    const i = miningIndex(chunk_x0 + lx, chunk_y0 + ly).?;
                    mining_cost[i] = if (chunk) |c|
                        orthoCost(c.blocks[@intCast((ly << dw.CHUNK_SIZE_LOG2) | lx)])
                    else
                        @intCast(SOLID_FALLOFF);
                }
            }
        }
    }

    if (dw.dev_menu) {
        const probe_dx: i32 = 3;
        const probe_dy: i32 = -5;
        const abs_x = base_bx + probe_dx;
        const abs_y = base_by + probe_dy;
        if (player_coord.move(.{
            @divFloor(abs_x, dw.CHUNK_SIZE),
            @divFloor(abs_y, dw.CHUNK_SIZE),
        })) |probe_coord| {
            const probe = world.getBlockAt(
                probe_coord,
                @intCast(@mod(abs_x, dw.CHUNK_SIZE)),
                @intCast(@mod(abs_y, dw.CHUNK_SIZE)),
                game.depth,
            );
            std.debug.assert(mining_cost[miningIndex(probe_dx, probe_dy).?] == orthoCost(probe));
        }
    }

    // The player's own position within their block, in window-cell units: the block they stand in sits at MINING_RADIUS,
    // and the subpixel remainder places them continuously inside it.
    const subpixels_per_block: f32 = @floatFromInt(dw.CHUNK_SIZE_SQ);
    const frac_x = @as(f32, @floatFromInt(game.player_pos[0])) / subpixels_per_block - @as(f32, @floatFromInt(base_bx));
    const frac_y = @as(f32, @floatFromInt(game.player_pos[1])) / subpixels_per_block - @as(f32, @floatFromInt(base_by));
    const px = @as(f32, @floatFromInt(MINING_RADIUS)) + frac_x;
    const py = @as(f32, @floatFromInt(MINING_RADIUS)) + frac_y;

    const span: i32 = @intCast(MINING_SPAN);
    seedPlayerLight(mining_alloc, &mining_cost, &mining_scratch, &buckets_mining, span, span, 0, px, py);
    floodChannel(mining_alloc, &mining_cost, &mining_scratch, &buckets_mining, span, span, 0);

    for (&mining_light, mining_scratch) |*dst, light| {
        dst.* = @intCast(@min(light, @as(u16, MAX_LIGHT)));
    }
    mining_key = currentMiningKey();
}

/// How much of the player's OWN light reaches the block `chunk_dx`/`chunk_dy` chunks and (`bx`, `by`)
/// blocks from the player's chunk, on the current logic tick. Zero past the window, where no light reaches.
///
/// Floods on demand and memoizes for the rest of the tick, so a tick that never asks never pays,
/// and one that asks twice gets the same answer both times.
/// Only valid to call from logic (`handleTick()`), where `game.frame` and the player position agree.
pub fn miningLightAt(chunk_dx: i64, chunk_dy: i64, bx: u4, by: u4) u8 {
    const key = currentMiningKey();
    if (mining_key == null or !mining_key.?.eql(key)) floodMiningLight();

    const dx = chunk_dx * dw.CHUNK_SIZE + bx - key.bx;
    const dy = chunk_dy * dw.CHUNK_SIZE + by - key.by;
    const i = miningIndex(dx, dy) orelse return 0;
    return mining_light[i];
}

/// Drops the memoized mining light, forcing the next query to flood again.
/// The key catches the player moving; this is for the world changing under a player who did not,
/// which `world.clearCaches()` is the one thing that does.
pub fn invalidateMiningLight() void {
    mining_key = null;
}
