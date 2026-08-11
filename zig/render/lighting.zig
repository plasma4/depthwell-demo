//! This code calculates light for the visible blocks; it writes an OKLCH color to each block!
//! Light loss depends on the medium (air/liquid/solid) and not on the light color; solid HP interpolates loss.
//!
//! Light is divided in to three fixed hues; hues are equal distances apart on the OKLAB hue circle.
//! The system calculates a weight for each lane and the strongest lane always has the maximum brightness!
//! Each lane floods through the shared cost grid; afterward the system reads the color back by comparing the lanes.
//!
//! The flood uses radix heaps to run Dijkstra's algorithm for each "color lane" (in OKLCH).
//! We represent light propagation as decay; a cell with high light has low decay.
//! The radix heap processes cells from lowest decay to highest decay.
//!
//! NOTE: This code lags in debug bulids!
const std = @import("std");
const dw = @import("../root.zig");
const memory = dw.memory;
const world = dw.world;

const Block = memory.Block;
const Sprite = dw.Sprite;
const BlockLight = memory.BlockLight;
const LightChannel = memory.LightChannel;
const LIGHT_MAX = memory.LIGHT_MAX;

/// The maximum brightness for block rendering.
pub const MAX_LIGHT: u16 = 255;
/// The lowest light level for unlit blocks.
pub const AMBIENT_LIGHT: u16 = 0;
/// The debug light level when global light is active.
pub const AMBIENT_LIGHT_DEBUG: u16 = 192;

/// Determine if light must be global.
pub var IS_LIGHT_GLOBAL = false;

/// The player light strength.
pub var PLAYER_LIGHT: u16 = 255;
/// The limit for the player light strength.
pub const MAX_PLAYER_LIGHT: u16 = 400;

/// The maximum possible light strength from any source.
pub const MAX_SOURCE_LIGHT: u16 = 400;

/// The limit for chroma values.
pub const LIGHT_CHROMA_MAX: f32 = 0.16;
/// The number of steps in a full hue turn.
pub const HUE_STEPS: u32 = @as(u32, LIGHT_MAX) + 1; // 64
/// The mix factor to pull colors toward white.
pub const CHROMA_WHITE_MIX: f32 = 0.0;

/// These are the OKLAB hue angles in radians.
pub const Hue = struct {
    pub const fire: f32 = 1.19;
    pub const gold: f32 = 1.60;
    pub const green: f32 = 2.60;
    pub const cyan: f32 = 3.40;
    pub const cyan_blue: f32 = 3.80;
    pub const violet: f32 = 5.40;
};

/// Defnes a source color through hue and chroma.
pub const LightColor = struct {
    /// The angle of the hue in radians.
    hue: f32,
    /// The saturation value from 0 to 1.
    chroma: f32,

    pub const white: LightColor = .{ .hue = 0, .chroma = 0 };
    /// This is the warm color of fire.
    pub const fire: LightColor = .{ .hue = Hue.fire, .chroma = 0.72 };
};

/// Describes a light emitter's strength and color (hue and chroma).
const Emission = struct {
    strength: u16 = 0,
    color: LightColor = .white,
};

/// Returns the light emission of a sprite (strength and color).
fn blockEmission(id: Sprite) Emission {
    return switch (id) {
        .campfire => .{ .strength = 240, .color = .fire },
        .forest_furnace, .lava_furnace => .{ .strength = 0, .color = .fire },
        .lava_stone, .molten_stone => .{ .strength = 60, .color = .fire },
        .portal => .{ .strength = 200, .color = .{ .hue = Hue.violet, .chroma = 0.75 } },
        .invportal => .{ .strength = 200, .color = .{ .hue = Hue.green, .chroma = 0.75 } },
        .white_plate => .{ .strength = 160, .color = .white },
        .electrit => .{ .strength = 100, .color = .{ .hue = Hue.gold, .chroma = 0.55 } },
        .twinklemoss => .{ .strength = 80, .color = .{ .hue = Hue.cyan_blue, .chroma = 0.45 } },
        else => .{},
    };
}

/// The color of the player light.
pub const PLAYER_COLOR: LightColor = .white;

/// The number of color lanes.
pub const LANES = 3;

/// Returns the axis vector for a lane.
fn laneAxis(comptime k: usize) [2]f32 {
    const angle = 2.0 * std.math.pi * @as(f32, @floatFromInt(k)) / @as(f32, LANES);
    return .{ @cos(angle), @sin(angle) };
}

/// The maximum saturation value.
pub const CHROMA_GAMUT: f32 = @sqrt(3.0) / 2.0;

/// Splits a color into lane weights.
/// Each weight is between 0 and 1 and the largest weight is exactly 1.
fn laneWeights(color: LightColor) [LANES]f32 {
    const sat = @min(CHROMA_GAMUT, @max(0.0, color.chroma)) * (1.0 - CHROMA_WHITE_MIX);
    const target = [2]f32{ sat * @cos(color.hue), sat * @sin(color.hue) };

    var dots: [LANES]f32 = undefined;
    var largest: f32 = -std.math.floatMax(f32);
    inline for (0..LANES) |k| {
        const axis = laneAxis(k);
        dots[k] = (2.0 / 3.0) * (target[0] * axis[0] + target[1] * axis[1]);
        largest = @max(largest, dots[k]);
    }

    var out: [LANES]f32 = undefined;
    inline for (0..LANES) |k| out[k] = @min(1.0, @max(0.0, 1.0 - largest + dots[k]));
    return out;
}

/// Calculates the lane light strengths.
fn laneStrengths(e: Emission) [LANES]u16 {
    const weights = laneWeights(e.color);
    var out: [LANES]u16 = undefined;
    const strength: f32 = @floatFromInt(e.strength);
    inline for (0..LANES) |k| out[k] = @intFromFloat(@round(strength * weights[k]));
    return out;
}

// These are decay rates for each block type; air must have the lowest rate!
pub const AIR_FALLOFF: u16 = 12;
pub const SOLID_FALLOFF: u16 = 28;
pub const LIQUID_FALLOFF: u16 = SOLID_FALLOFF - 12;

comptime {
    // orthogonal cost is stored per-cell as u8
    std.debug.assert(SOLID_FALLOFF <= 255 and LIQUID_FALLOFF <= 255 and AIR_FALLOFF <= 255);
}

/// The arena allocator for the light calculations.
var arena = memory.makeArena();
/// The main allocator from the arena.
var alloc = arena.allocator();

/// Resets the arena allocator used for all the lighting calculations.
fn resetArena() void {
    if (!arena.reset(.retain_capacity)) memory.oom();
}

/// Returns the light cost for entering a block.
fn orthoCost(block: Block) u8 {
    if (block.isLiquid()) return @intCast(LIQUID_FALLOFF);

    // treat air blocks as if HP is 16 to smoothly interpolate lighting based on HP when mining!
    // solid blocks use their real HP value from 0 to 15
    const hp: u16 = if (block.isSolid()) block.hp else 16;

    const diff = SOLID_FALLOFF - AIR_FALLOFF;
    const decay = (@as(u32, diff) * hp + 8) / 16;
    var falloff: u16 = SOLID_FALLOFF - @as(u16, @intCast(decay));

    if (block.water.bits != 0) {
        falloff = @max(falloff, LIQUID_FALLOFF);
    }
    return @intCast(falloff);
}

/// Returns the diagonal step cost (an 8-sided polygon visually).
inline fn diagCost(ortho: u16) u16 {
    return (ortho * 181 + 64) >> 7;
}

/// Calculates the maximum reach distance in blocks.
fn maxAirReachBlocks() comptime_int {
    comptime {
        var brightness: u16 = MAX_SOURCE_LIGHT;
        var blocks: comptime_int = 0;
        const light = @min(AMBIENT_LIGHT, AMBIENT_LIGHT_DEBUG);
        while (brightness > AIR_FALLOFF and (brightness - AIR_FALLOFF) > light) {
            brightness -= AIR_FALLOFF;
            blocks += 1;
        }
        return blocks;
    }
}

/// The padding margin in chunks.
pub const CHUNK_MARGIN: u32 = @max(1, std.math.divCeil(
    u32,
    maxAirReachBlocks(),
    dw.CHUNK_SIZE,
) catch unreachable);

inline fn packCoords(x: u16, y: u16) u32 {
    return @as(u32, x) | (@as(u32, y) << 16);
}

inline fn unpackX(p: u32) u16 {
    return @as(u16, @intCast(p & 0xFFFF));
}

inline fn unpackY(p: u32) u16 {
    return @as(u16, @intCast(p >> 16));
}

/// Acts as a priority queue with integer keys using a small number of buckets to store elements.
/// This data structure is faster than a standard Dial bucket sweep and uses `@clz()` (fancy optimization).
const RadixHeap = struct {
    const Entry = struct {
        key: u16,
        value: u32,
    };

    const BUCKETS_COUNT = 12;

    buckets: [BUCKETS_COUNT]std.ArrayList(Entry),
    t: u16,
    size: usize,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) RadixHeap {
        var self = RadixHeap{
            .buckets = undefined,
            .t = 0,
            .size = 0,
            .allocator = allocator,
        };
        inline for (0..BUCKETS_COUNT) |i| {
            self.buckets[i] = .empty;
        }
        return self;
    }

    fn insert(self: *RadixHeap, key: u16, value: u32) void {
        std.debug.assert(key >= self.t);
        const b_idx = self.getBucketIndex(key);
        self.buckets[b_idx].append(
            self.allocator,
            .{ .key = key, .value = value },
        ) catch memory.oom();
        self.size += 1;
    }

    fn getBucketIndex(self: *const RadixHeap, key: u16) usize {
        const diff = key ^ self.t;
        if (diff == 0) return 0;
        const bit = 16 - @clz(diff);
        return bit;
    }

    fn pop(self: *RadixHeap) ?Entry {
        if (self.size == 0) return null;

        if (self.buckets[0].items.len == 0) {
            var j: usize = 1;
            while (j < BUCKETS_COUNT) : (j += 1) {
                if (self.buckets[j].items.len > 0) break;
            }
            std.debug.assert(j < BUCKETS_COUNT);

            var min_key: u16 = std.math.maxInt(u16);
            for (self.buckets[j].items) |entry| {
                if (entry.key < min_key) {
                    min_key = entry.key;
                }
            }

            self.t = min_key;

            var temp: std.ArrayList(Entry) = .empty;
            const old_bucket = self.buckets[j];
            self.buckets[j] = temp;
            temp = old_bucket;

            for (temp.items) |entry| {
                const b_idx = self.getBucketIndex(entry.key);
                std.debug.assert(b_idx < j);
                self.buckets[b_idx].append(self.allocator, entry) catch memory.oom();
            }
            temp.deinit(self.allocator);
        }

        const entry = self.buckets[0].pop();
        self.size -= 1;
        return entry;
    }
};

/// Adds a cell to the heap and updates the decay grid if the new decay value is lower.
inline fn seed(heap: *RadixHeap, decay_grid: []u16, i: usize, x: u16, y: u16, decay_val: u16, max_decay: u16) void {
    if (decay_val < decay_grid[i] and decay_val < max_decay) {
        decay_grid[i] = decay_val;
        heap.insert(decay_val, packCoords(x, y));
    }
}

/// Seeds a point light source by converting the light strength into a decay value.
fn seedPointLight(
    heap: *RadixHeap,
    cost: []const u8,
    decay_grid: []u16,
    w: i32,
    h: i32,
    max_decay: u16,
    px: f32,
    py: f32,
    strength: u16,
) void {
    std.debug.assert(strength <= MAX_SOURCE_LIGHT);
    if (strength == 0) return;

    const source_decay = MAX_SOURCE_LIGHT - strength;
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
                const falloff: f32 = @floatFromInt(cost[i]);
                const drop: f32 = @round(@sqrt(dx * dx + dy * dy) * falloff);
                const decay_val: u16 = @intFromFloat(@as(f32, @floatFromInt(source_decay)) + drop);
                seed(heap, decay_grid, i, @intCast(cx), @intCast(cy), decay_val, max_decay);
            }
        }
    }
}

/// Runs Dijkstra's algorithm for one lane.
/// Uses the radix heap to pop the cell with the minimum decay.
fn floodLane(
    cost: []const u8,
    decay_grid: []u16,
    heap: *RadixHeap,
    w: i32,
    h: i32,
    max_decay: u16,
) void {
    while (heap.pop()) |entry| {
        const u_decay = entry.key;
        const pc = entry.value;
        const x = @as(i32, unpackX(pc));
        const y = @as(i32, unpackY(pc));
        const idx: usize = @intCast(y * w + x);

        if (decay_grid[idx] != u_decay) continue;

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
                const n_decay = u_decay + c;
                if (n_decay < decay_grid[ni] and n_decay < max_decay) {
                    decay_grid[ni] = n_decay;
                    heap.insert(n_decay, packCoords(@intCast(nx), @intCast(ny)));
                }
            }
        }
    }
}

/// Maps a light value to the channel type!
inline fn quantizeLightness(value: u16) LightChannel {
    const clamped: u32 = @min(value, MAX_LIGHT);
    return @intCast((clamped * LIGHT_MAX + MAX_LIGHT / 2) / MAX_LIGHT);
}

/// Calculates the light color of a cell from the lane values.
fn resolveCell(lanes: [LANES]u16) BlockLight {
    var strongest: u16 = 0;
    inline for (0..LANES) |k| strongest = @max(strongest, lanes[k]);
    if (strongest == 0) return .none;

    const lightness = quantizeLightness(strongest);

    var equal = true;
    inline for (1..LANES) |k| equal = equal and (lanes[k] == lanes[0]);
    if (equal) return .{ .l = lightness };

    const scale = 1.0 / @as(f32, @floatFromInt(strongest));
    var vec = [2]f32{ 0, 0 };
    inline for (0..LANES) |k| {
        const axis = laneAxis(k);
        const share = @as(f32, @floatFromInt(lanes[k])) * scale;
        vec[0] += share * axis[0];
        vec[1] += share * axis[1];
    }

    const magnitude = @min(1.0, @sqrt(vec[0] * vec[0] + vec[1] * vec[1]));
    if (magnitude <= 0.0) return .{ .l = lightness };

    var angle = std.math.atan2(vec[1], vec[0]);
    if (angle < 0) angle += 2.0 * std.math.pi;
    const hue_fraction = angle / (2.0 * std.math.pi);

    const steps: f32 = @floatFromInt(HUE_STEPS);
    const hue_step = @as(u32, @intFromFloat(@round(hue_fraction * steps))) % HUE_STEPS;

    return .{
        .l = lightness,
        .c = @intFromFloat(@round(magnitude * @as(f32, @floatFromInt(LIGHT_MAX)))),
        .h = @intCast(hue_step),
    };
}

/// Calculates light values for all visible blocks.
pub fn applyLighting(out: []Block, wb: u32, hb: u32, player_bx: f32, player_by: f32) void {
    @setFloatMode(.optimized);
    resetArena();
    const w: i32 = @intCast(wb);
    const h: i32 = @intCast(hb);
    const wbw: u16 = @intCast(wb);

    const cost_slice = alloc.alignedAlloc(u8, memory.MAIN_ALIGN, out.len) catch memory.oom();
    var lane_decay: [LANES][]u16 = undefined;
    inline for (0..LANES) |k| {
        lane_decay[k] = alloc.alignedAlloc(u16, memory.MAIN_ALIGN, out.len) catch memory.oom();
    }

    var lane_heap: [LANES]RadixHeap = undefined;
    inline for (0..LANES) |k| {
        lane_heap[k] = RadixHeap.init(alloc);
    }

    const ambient: u16 = if (dw.dev_menu and IS_LIGHT_GLOBAL) AMBIENT_LIGHT_DEBUG else AMBIENT_LIGHT;
    const max_decay = MAX_SOURCE_LIGHT - ambient;

    var sy: u16 = 0;
    var sx: u16 = 0;
    for (out, 0..) |block, i| {
        cost_slice[i] = orthoCost(block);
        inline for (0..LANES) |k| lane_decay[k][i] = max_decay;

        const emission = blockEmission(block.id);
        if (emission.strength > ambient) {
            const strengths = laneStrengths(emission);
            inline for (0..LANES) |k| {
                const decay_val = MAX_SOURCE_LIGHT - strengths[k];
                seed(&lane_heap[k], lane_decay[k], i, sx, sy, decay_val, max_decay);
            }
        }

        sx += 1;
        if (sx == wbw) {
            sx = 0;
            sy += 1;
        }
    }

    const player_strengths = laneStrengths(.{ .strength = PLAYER_LIGHT, .color = PLAYER_COLOR });
    inline for (0..LANES) |k| {
        seedPointLight(
            &lane_heap[k],
            cost_slice,
            lane_decay[k],
            w,
            h,
            max_decay,
            player_bx,
            player_by,
            player_strengths[k],
        );
    }

    inline for (0..LANES) |k| {
        floodLane(cost_slice, lane_decay[k], &lane_heap[k], w, h, max_decay);
    }

    for (out, 0..) |*block, i| {
        var lanes: [LANES]u16 = undefined;
        inline for (0..LANES) |k| lanes[k] = MAX_SOURCE_LIGHT - lane_decay[k][i];
        block.setLight(resolveCell(lanes));
    }
}

const PLAYER_LIGHT_REACH: i32 = MAX_PLAYER_LIGHT / AIR_FALLOFF;
const MINING_RADIUS: i32 = PLAYER_LIGHT_REACH + 1;
const MINING_SPAN: usize = @intCast(2 * MINING_RADIUS + 1);

var mining_light: [MINING_SPAN * MINING_SPAN]u8 = @splat(0);
var mining_cost: [MINING_SPAN * MINING_SPAN]u8 = @splat(0);
var mining_scratch: [MINING_SPAN * MINING_SPAN]u16 = @splat(0);

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

var mining_arena = memory.makeArena();
var mining_alloc = mining_arena.allocator();

inline fn miningIndex(dx: i64, dy: i64) ?usize {
    if (dx < -MINING_RADIUS or dx > MINING_RADIUS or dy < -MINING_RADIUS or dy > MINING_RADIUS) return null;
    return @intCast((dy + MINING_RADIUS) * @as(i64, MINING_SPAN) + (dx + MINING_RADIUS));
}

/// Floods the player's own light over the area around them.
fn floodMiningLight() void {
    const game = &memory.game;
    if (!mining_arena.reset(.retain_capacity)) memory.oom();

    var heap = RadixHeap.init(mining_alloc);
    @memset(&mining_scratch, MAX_SOURCE_LIGHT);

    // Fill the cost grid chunk by chunk rather than block by block, so a chunk is resolved once.
    // An unreachable chunk (past the world edge) reads as solid!
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

            const chunk_x0 = cx * dw.CHUNK_SIZE - base_bx;
            const chunk_y0 = cy * dw.CHUNK_SIZE - base_by;
            const lx_end = @min(dw.CHUNK_SIZE - 1, MINING_RADIUS - chunk_x0);
            const ly_end = @min(dw.CHUNK_SIZE - 1, MINING_RADIUS - chunk_y0);

            var ly = @max(0, -MINING_RADIUS - chunk_y0);
            while (ly <= ly_end) : (ly += 1) {
                var lx = @max(0, -MINING_RADIUS - chunk_x0);
                while (lx <= lx_end) : (lx += 1) {
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

    const subpixels_per_block: f32 = @floatFromInt(dw.CHUNK_SIZE_SQ);
    const frac_x = @as(f32, @floatFromInt(game.player_pos[0])) / subpixels_per_block - @as(f32, @floatFromInt(base_bx));
    const frac_y = @as(f32, @floatFromInt(game.player_pos[1])) / subpixels_per_block - @as(f32, @floatFromInt(base_by));
    const px = @as(f32, @floatFromInt(MINING_RADIUS)) + frac_x;
    const py = @as(f32, @floatFromInt(MINING_RADIUS)) + frac_y;

    const span: i32 = @intCast(MINING_SPAN);
    seedPointLight(&heap, &mining_cost, &mining_scratch, span, span, MAX_SOURCE_LIGHT, px, py, PLAYER_LIGHT);
    floodLane(&mining_cost, &mining_scratch, &heap, span, span, MAX_SOURCE_LIGHT);

    for (&mining_light, mining_scratch) |*dst, decay| {
        const light = MAX_SOURCE_LIGHT - decay;
        dst.* = @intCast(@min(light, @as(u16, MAX_LIGHT)));
    }
    mining_key = currentMiningKey();
}

/// Calculates the mining light value for a given (relative) chunk and block location.
pub fn miningLightAt(chunk_dx: i64, chunk_dy: i64, bx: u4, by: u4) u8 {
    const key = currentMiningKey();
    if (mining_key == null or !mining_key.?.eql(key)) floodMiningLight();

    const dx = chunk_dx * dw.CHUNK_SIZE + bx - key.bx;
    const dy = chunk_dy * dw.CHUNK_SIZE + by - key.by;
    const i = miningIndex(dx, dy) orelse return 0;
    return mining_light[i];
}

/// Invalidates the current mining light cache.
pub fn invalidateMiningLight() void {
    mining_key = null;
}

const testing = std.testing;

fn roundTrip(color: LightColor, strength: u16) BlockLight {
    return resolveCell(laneStrengths(.{ .strength = strength, .color = color }));
}

test "a colored source reaches exactly as far as a white one" {
    for ([_]f32{ 0.0, 0.25, 0.5, 0.75, 1.0 }) |chroma| {
        var hue: f32 = 0.0;
        while (hue < 2.0 * std.math.pi) : (hue += 0.2) {
            const lanes = laneStrengths(.{ .strength = 240, .color = .{ .hue = hue, .chroma = chroma } });
            var strongest: u16 = 0;
            for (lanes) |v| strongest = @max(strongest, v);
            try testing.expectEqual(@as(u16, 240), strongest);
        }
    }
}

test "white light stays achromatic" {
    const got = roundTrip(.white, 200);
    try testing.expectEqual(@as(LightChannel, 0), got.c);
    const lanes = laneStrengths(.{ .strength = 200, .color = .white });
    try testing.expectEqual(lanes[0], lanes[1]);
    try testing.expectEqual(lanes[1], lanes[2]);
}

test "a source's hue survives the trip through the lanes" {
    const tolerance = 2.0 * (2.0 * std.math.pi / @as(f32, @floatFromInt(HUE_STEPS)));
    for ([_]f32{ Hue.fire, Hue.gold, Hue.green, Hue.cyan, Hue.cyan_blue, Hue.violet }) |hue| {
        const got = roundTrip(.{ .hue = hue, .chroma = 0.8 }, 255);
        const recovered = @as(f32, @floatFromInt(got.h)) /
            @as(f32, @floatFromInt(HUE_STEPS)) * 2.0 * std.math.pi;

        var delta = @abs(recovered - hue);
        if (delta > std.math.pi) delta = 2.0 * std.math.pi - delta;
        try testing.expect(delta <= tolerance);
    }
}

test "chroma survives the trip at every hue inside the gamut" {
    var hue: f32 = 0.0;
    while (hue < 2.0 * std.math.pi) : (hue += 0.1) {
        for ([_]f32{ 0.25, 0.5, CHROMA_GAMUT }) |chroma| {
            const got = roundTrip(.{ .hue = hue, .chroma = chroma }, 255);
            const recovered = @as(f32, @floatFromInt(got.c)) / @as(f32, @floatFromInt(LIGHT_MAX));
            try testing.expectApproxEqAbs(chroma * (1.0 - CHROMA_WHITE_MIX), recovered, 0.03);
        }
    }
}

test "chroma past the gamut clamps instead of bending the hue" {
    const inside = roundTrip(.{ .hue = Hue.violet, .chroma = CHROMA_GAMUT }, 255);
    const past = roundTrip(.{ .hue = Hue.violet, .chroma = 1.0 }, 255);
    try testing.expectEqual(inside.c, past.c);
    try testing.expectEqual(inside.h, past.h);
}

test "a lane below ambient washes the tint out instead of keeping it" {
    const dim = resolveCell(.{ 255, 192, 192 });
    const dark = resolveCell(.{ 255, 0, 0 });
    try testing.expect(dim.c < dark.c);
    try testing.expectEqual(dim.h, dark.h);
}
