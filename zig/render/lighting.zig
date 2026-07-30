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
// ---
pub const CAMPFIRE_LIGHT: u16 = 240;
pub const FURNACE_LIGHT: u16 = AMBIENT_LIGHT;
pub const LAVA_LIGHT: u16 = 60;
// ---
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
    player_buffer = std.array_list.Aligned(u16, .@"16").initCapacity(alloc, 2048) catch memory.oom();
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
/// High-precision per-cell light of the player alone: no ambient, no other source.
/// The white channel starts from this rather than from scratch, so isolating it costs no extra flood.
var player_buffer: std.array_list.Aligned(u16, .@"16") = undefined;

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
inline fn seed(light: []u16, buckets: *[NUM_BUCKETS]std.array_list.Aligned(u32, .@"16"), i: usize, x: u16, y: u16, val: u16, ambient: u16) void {
    if (val > light[i] and val > ambient) {
        light[i] = val;
        buckets[@as(usize, val)].append(alloc, packCoords(x, y)) catch memory.oom();
    }
}

/// Seeds the 2x2 cells surrounding the player using their continuous sub-pixel position.
/// Light drops off similar to Euclidean distance through the cell's own medium cost.
fn seedPlayerLight(
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
                    seed(light_white, buckets, i, @intCast(cx), @intCast(cy), val, ambient);
                }
            }
        }
    }
}

/// One single-channel Dial flood: process buckets brightest -> dimmest, relaxing 8 neighbors.
/// Because we descend and edge costs are strictly positive, appends only ever target strictly-lower
/// buckets, so each cell is finalized exactly once at its brightest value regardless of source count.
fn floodChannel(
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
                            buckets[@as(usize, nl)].append(alloc, packCoords(
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
    player_buffer.resize(alloc, out.len) catch memory.oom();

    const cost_slice = cost_buffer.items;
    const light_orange = orange_buffer.items;
    const light_white = white_buffer.items;
    const light_player = player_buffer.items;

    const ambient: u16 = if (dw.is_debug and IS_LIGHT_GLOBAL) AMBIENT_LIGHT_DEBUG else AMBIENT_LIGHT;

    // precompute per-cell cost, initialize the orange channel to ambient and the player channel to full dark,
    // then "seed" (add) the warm sources into their buckets!
    var sy: u16 = 0;
    var sx: u16 = 0;
    for (out, 0..) |block, i| {
        cost_slice[i] = orthoCost(block);
        light_orange[i] = ambient;
        light_player[i] = 0;

        const emission = blockEmission(block.id);
        if (emission > ambient and isOrangeSource(block.id)) {
            seed(light_orange, &buckets_orange, i, sx, sy, emission, ambient);
        }

        sx += 1;
        if (sx == wbw) {
            sx = 0;
            sy += 1;
        }
    }

    // The player alone (floored at zero rather than at ambient); this is used for miningLightAt() to disable mining
    seedPlayerLight(cost_slice, light_player, &buckets_white, w, h, 0, player_bx, player_by);
    floodChannel(cost_slice, light_player, &buckets_white, w, h, 0);

    // The white flood resumes from the player's result instead of starting over.
    // Dial finalizes a cell once, at its brightest value, having already relaxed its neighbors from it,
    // so a cell the player flood settled needs no bucket entry here: only a brighter source can revisit it,
    // and that source's own relaxation is what puts it back in a bucket.
    for (light_white, light_player) |*white, player| white.* = @max(ambient, player);
    for (&buckets_white) |*bk| bk.clearRetainingCapacity();

    sy = 0;
    sx = 0;
    for (out, 0..) |block, i| {
        const emission = blockEmission(block.id);
        if (emission > ambient and !isOrangeSource(block.id)) {
            seed(light_white, &buckets_white, i, sx, sy, emission, ambient);
        }

        sx += 1;
        if (sx == wbw) {
            sx = 0;
            sy += 1;
        }
    }

    // Two independent floods over the shared cost grid for each color!
    floodChannel(cost_slice, light_orange, &buckets_orange, w, h, ambient);
    floodChannel(cost_slice, light_white, &buckets_white, w, h, ambient);

    // Combine channels and write final u8 values clamped to MAX_LIGHT.
    for (out, light_orange, light_white) |*block, orange, white| {
        const max_light = @max(orange, white);
        block.light = @intCast(@min(max_light, @as(u16, MAX_LIGHT)));

        // this fixes an issue where orange light overtakes normal white light if ambient light is at max
        if (AMBIENT_LIGHT == 255 or (dw.is_debug and IS_LIGHT_GLOBAL and AMBIENT_LIGHT_DEBUG == 255)) continue;

        // block is orange if it receives more orange light than white, or is in the core radius (>= 255)
        const is_orange = orange >= white or orange >= 255;
        block.lighting_color = @intFromBool(is_orange and max_light > ambient);
    }
}

/// Player-only light of the window the live layer last lit, clamped to `MAX_LIGHT`.
/// Kept out of the lighting arena because the portal's preview pass floods that arena again after the live one,
/// which would leave this holding the light of a depth the player is not in yet.
var mining_light: std.ArrayList(u8) = .empty;
/// Window `mining_light` covers: its size in blocks,
/// and the chunk offsets of its top-left corner relative to the player's own chunk (`liveLayer()`'s origin).
var mining_window_w: i64 = 0;
var mining_window_h: i64 = 0;
var mining_origin_cx: i64 = 0;
var mining_origin_cy: i64 = 0;

/// Records the player-only light of the window `applyLighting()` just flooded, for `miningLightAt()`.
///
/// `origin_cx`/`origin_cy` are the window's top-left chunk offsets from the player's chunk,
/// which is the same frame of reference the mouse resolves its own block in.
/// ONLY the live layer may call this; a preview layer's blocks are at another depth entirely.
pub fn recordMiningLight(origin_cx: i64, origin_cy: i64, wb: u32, hb: u32) void {
    std.debug.assert(player_buffer.items.len == wb * hb);
    mining_light.resize(memory.main_allocator, wb * hb) catch memory.oom();
    for (mining_light.items, player_buffer.items) |*dst, light| {
        dst.* = @intCast(@min(light, @as(u16, MAX_LIGHT)));
    }
    mining_window_w = wb;
    mining_window_h = hb;
    mining_origin_cx = origin_cx;
    mining_origin_cy = origin_cy;
}

/// How much of the last frame's player light reached the block `chunk_dx`/`chunk_dy` chunks and (`bx`, `by`) blocks from the player's own chunk.
/// Is null when that block was outside the lit window, can only happen off-screen (the window is padded by `CHUNK_MARGIN`).
pub fn miningLightAt(chunk_dx: i64, chunk_dy: i64, bx: u4, by: u4) ?u8 {
    if (mining_light.items.len == 0) return null;
    const x = (chunk_dx - mining_origin_cx) * dw.CHUNK_SIZE + bx;
    const y = (chunk_dy - mining_origin_cy) * dw.CHUNK_SIZE + by;
    if (x < 0 or x >= mining_window_w or y < 0 or y >= mining_window_h) return null;
    return mining_light.items[@intCast(y * mining_window_w + x)];
}
