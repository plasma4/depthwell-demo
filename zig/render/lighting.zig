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
pub const AMBIENT_LIGHT_DEBUG: u8 = 255;

pub var DEBUG_LIGHT = false;

// Light strength values for various sources:
pub const PLAYER_LIGHT: u16 = 300;
// ---
pub const CAMPFIRE_LIGHT: u16 = 240;
pub const FURNACE_LIGHT: u16 = 80;
// ---
pub const PLATE_LIGHT: u16 = 160;
pub const LAVA_LIGHT: u16 = 60;

// Orthogonal decay rates per block type. Air should always be the lowest (decays slowest)!
// Logic is optimized and dependent around air falloff being 10 and solid falloff being 26.
pub const AIR_FALLOFF: u16 = 10;
pub const SOLID_FALLOFF: u16 = 26;
pub const LIQUID_FALLOFF: u16 = 18;

/// Brightest possible seed value; bounds the number of Dial buckets.
const MAX_SOURCE: u16 = @max(PLAYER_LIGHT, @max(CAMPFIRE_LIGHT, @max(FURNACE_LIGHT, PLATE_LIGHT)));
const NUM_BUCKETS: usize = MAX_SOURCE + 1;

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
    buckets_orange = @splat(.empty);
    buckets_white = @splat(.empty);

    cost_buffer = std.array_list.Aligned(u8, .@"16").initCapacity(alloc, 2048) catch memory.oom();
    orange_buffer = std.array_list.Aligned(u16, .@"16").initCapacity(alloc, 2048) catch memory.oom();
    white_buffer = std.array_list.Aligned(u16, .@"16").initCapacity(alloc, 2048) catch memory.oom();
}

inline fn blockEmission(id: Sprite) u16 {
    return switch (id) {
        .campfire => CAMPFIRE_LIGHT,
        .forest_furnace, .lava_furnace => CAMPFIRE_LIGHT,
        .white_plate => PLATE_LIGHT,
        .lava_stone => LAVA_LIGHT,
        else => 0,
    };
}

/// Returns true if the block is a warm light source, which creates an orange light glow in the shader.
inline fn isOrangeSource(id: Sprite) bool {
    return switch (id) {
        .campfire => true,
        .forest_furnace, .lava_furnace => true,
        .lava_stone => true,
        else => false,
    };
}

/// Orthogonal per-step light cost for entering `block`. Fits in u8 (<= SOLID_FALLOFF).
/// Diagonals are derived from this at flood time via the fast sqrt(2) approximation.
inline fn orthoCost(block: Block) u8 {
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
        var brightest_possible_source: u16 = @max(PLAYER_LIGHT, @max(CAMPFIRE_LIGHT, PLATE_LIGHT));
        var blocks: comptime_int = 0;
        const light = @min(AMBIENT_LIGHT, AMBIENT_LIGHT_DEBUG);
        while (brightest_possible_source > AIR_FALLOFF and (brightest_possible_source - AIR_FALLOFF) > light) {
            brightest_possible_source -= AIR_FALLOFF;
            blocks += 1;
        }
        return blocks;
    }
}

/// Buffer padding margin (in chunks) to capture off-screen light bleed.
pub const CHUNK_MARGIN: u32 = @max(1, std.math.divCeil(u32, maxAirReachBlocks(), dw.CHUNK_SIZE) catch unreachable);

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
inline fn seed(light: []u16, buckets: *[NUM_BUCKETS]std.array_list.Aligned(u32, .@"16"), i: usize, x: u16, y: u16, val: u16, ambient: u16) void {
    if (val > light[i] and val > ambient) {
        light[i] = val;
        buckets[@as(usize, val)].append(alloc, packCoords(x, y)) catch memory.oom();
    }
}

/// Seeds the 2x2 cells surrounding the player using their continuous sub-pixel position.
/// Light drops off similar to Euclidean distance through the cell's own medium cost.
inline fn seedPlayerLight(
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

    const cost_slice = cost_buffer.items;
    const light_orange = orange_buffer.items;
    const light_white = white_buffer.items;

    const ambient: u16 = if (dw.is_debug and DEBUG_LIGHT) AMBIENT_LIGHT_DEBUG else AMBIENT_LIGHT;

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
                seed(light_orange, &buckets_orange, i, sx, sy, emission, ambient);
            } else {
                seed(light_white, &buckets_white, i, sx, sy, emission, ambient);
            }
        }

        sx += 1;
        if (sx == wbw) {
            sx = 0;
            sy += 1;
        }
    }

    // Seed the continuous player source into the white channel.
    seedPlayerLight(cost_slice, light_white, &buckets_white, w, h, ambient, player_bx, player_by);

    // Two independent floods over the shared cost grid for each color!
    floodChannel(cost_slice, light_orange, &buckets_orange, w, h, ambient);
    floodChannel(cost_slice, light_white, &buckets_white, w, h, ambient);

    // Combine channels and write final u8 values clamped to MAX_LIGHT.
    for (out, light_orange, light_white) |*block, orange, white| {
        const max_light = @max(orange, white);
        block.light = @intCast(@min(max_light, @as(u16, MAX_LIGHT)));

        // this fixes an issue where orange light overtakes normal white light if ambient light is at max
        if (AMBIENT_LIGHT == 255 or (dw.is_debug and DEBUG_LIGHT and AMBIENT_LIGHT_DEBUG == 255)) continue;

        // block is orange if it receives more orange light than white, or is in the core radius (>= 255).
        const is_orange = orange >= white or orange >= 255;
        block.lighting_color = @intFromBool(is_orange and max_light > ambient);
    }
}
