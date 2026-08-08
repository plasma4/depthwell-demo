//! CPU lighting pass over the visible block buffer. Resolves an OKLCH colour for every block and
//! writes it into the block's `light_l`, `light_c` and `light_h` channels (see `memory.BlockLight`).
//! `fs_tile()` in src/shader.wgsl then MULTIPLIES the sprite's own OKLAB lightness by the lightness,
//! and ADDS the chroma, so a coloured lamp tints a block without replacing its material.
//!
//! # How the colour survives a shortest-path flood
//!
//! Falloff is a property of the MEDIUM, not of the light's colour: air, stone and water each cost
//! what they cost no matter what shines through them. So one colourless cost grid serves every colour,
//! and the only thing that has to be per-colour is how much light arrives.
//!
//! Light is therefore split into `LANES` fixed hues, evenly spaced around the OKLAB hue circle.
//! A source states a hue and a saturation; `laneWeights()` turns that into one weight per lane, scaled
//! so the STRONGEST lane is always the full brightness. A white source lights all three lanes equally,
//! a pure violet source lights mostly one. Each lane then floods on its own over the shared cost grid,
//! and `resolveCell()` reads the colour back out of how the three lanes compare at that cell.
//!
//! Because every lane's field is continuous, so is their ratio, so hue varies smoothly across the map.
//! Two lamps of different colours blend through every hue between them, with no seam anywhere.
//! This is what the old two-channel version could not do: it picked a winner per cell, and the line
//! where the winner changed was visible.
//!
//! # What the flood itself does
//!
//! `floodLane()` is an inverted Dial's algorithm (bucketed Dijkstra): buckets are walked brightest to
//! dimmest, so each cell is finalized exactly once at its brightest value and overlapping sources cost
//! no extra relaxation. Light spreads to all 8 neighbors with a sqrt(2) diagonal cost, which
//! approximates a circular falloff.
//!
//! NOTE: In Debug builds, this code can be a significant contributor to lag.

const std = @import("std");
const dw = @import("../root.zig");
const memory = dw.memory;
const world = dw.world;

const Block = memory.Block;
const Sprite = dw.Sprite;
const BlockLight = memory.BlockLight;
const LightChannel = memory.LightChannel;
const LIGHT_MAX = memory.LIGHT_MAX;

/// Flood value that means "as bright as a block can be drawn"; anything above it clamps.
pub const MAX_LIGHT: u16 = 255;
/// Min baseline brightness for unlit cells.
pub const AMBIENT_LIGHT: u16 = 0;
/// Debug ambient light brightness if the debug boolean is enabled.
pub const AMBIENT_LIGHT_DEBUG: u16 = 192;

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

// ---------------------------------------------------------------------------
// Colour tuning. Everything an artist would want to turn is in this block.
// ---------------------------------------------------------------------------

/// OKLAB chroma that a fully saturated source adds at full lightness.
///
/// This is the ceiling on how far light can push a block's colour, and the single most important
/// value here. Past about 0.12 the result leaves sRGB and clips to a flat, plastic colour;
/// below about 0.04 every lamp reads as white. Mirror any change in `LIGHT_CHROMA_MAX` in
/// src/shader.wgsl, which does the actual adding.
pub const LIGHT_CHROMA_MAX: f32 = 0.09;

/// How far every source colour is pulled toward white before it is split into lanes, 0 to 1.
///
/// Fixes the fringe artifact: falloff is subtractive, so the weak lanes of a saturated source hit
/// zero before the strong one and the light gets MORE saturated the further it travels, which is
/// backwards. Raising this caps that drift, at the cost of less colourful lamps. Start at 0.15 if the
/// fringes bother you. Zero reproduces the old two-channel look exactly.
pub const CHROMA_WHITE_MIX: f32 = 0.0;

/// Hues in OKLAB radians, for the source table below. Named rather than inline so a palette change
/// is one edit, and so two sources meant to match cannot drift apart.
pub const Hue = struct {
    pub const fire: f32 = 1.19;
    pub const gold: f32 = 1.60;
    pub const green: f32 = 2.60;
    pub const cyan: f32 = 3.40;
    pub const violet: f32 = 5.40;
};

/// A light source's colour, as an author states it.
pub const LightColor = struct {
    /// Hue angle in OKLAB radians. Ignored when `chroma` is 0.
    hue: f32 = 0,
    /// Saturation, 0 (white) to 1 (as colourful as `LIGHT_CHROMA_MAX` allows).
    chroma: f32 = 0,

    pub const white: LightColor = .{};
    /// The warm glow of every flame. 0.72 is the value that reproduces the old hard-coded
    /// OKLAB shift of (a = 0.024, b = 0.060) exactly, so fire looks unchanged.
    pub const fire: LightColor = .{ .hue = Hue.fire, .chroma = 0.72 };
};

/// Everything one emitting block contributes.
const Emission = struct {
    strength: u16 = 0,
    color: LightColor = .white,
};

/// What each emitting sprite gives off. A sprite absent from here emits nothing.
fn blockEmission(id: Sprite) Emission {
    return switch (id) {
        .campfire => .{ .strength = CAMPFIRE_LIGHT, .color = .fire },
        .forest_furnace, .lava_furnace => .{ .strength = FURNACE_LIGHT, .color = .fire },
        .lava_stone, .molten_stone => .{ .strength = LAVA_LIGHT, .color = .fire },
        .portal, .invportal => .{ .strength = PORTAL_LIGHT, .color = .{ .hue = Hue.violet, .chroma = 0.85 } },
        .white_plate => .{ .strength = PLATE_LIGHT, .color = .white },
        .aquashard => .{ .strength = ORE_GEM_LIGHT, .color = .{ .hue = Hue.cyan, .chroma = 0.8 } },
        .electrit => .{ .strength = ORE_GEM_LIGHT, .color = .{ .hue = Hue.gold, .chroma = 0.65 } },
        .twinklemoss => .{ .strength = TWINKLEVINE_LIGHT, .color = .{ .hue = Hue.green, .chroma = 0.7 } },
        else => .{},
    };
}

/// The colour of the player's own lamp. Kept apart from `blockEmission()` because the player is not a
/// block, and because `miningLightAt()` deliberately ignores it (see `floodMiningLight()`).
pub const PLAYER_COLOR: LightColor = .white;

/// PREVIEW. Sweeps the player's lamp through every hue, one full turn per `HUE_CYCLE_SECONDS`.
///
/// The whole point of the lane split is that ARBITRARY colours mix, and nothing in the world emits an
/// arbitrary colour yet. Turning this on walks the lamp past a campfire's fixed orange through every
/// hue there is, which shows the mixing, the fringe saturation, and any banding in one pass.
/// Delete it, or the button in `debug/debug_ui.zig`, once real coloured sources exist.
pub var CYCLE_PLAYER_HUE = false;
/// Seconds the preview sweep takes to walk the whole hue circle.
const HUE_CYCLE_SECONDS: f64 = 12.0;

/// The player's lamp colour this frame; see `CYCLE_PLAYER_HUE`.
fn playerColor() LightColor {
    if (!dw.dev_menu or !CYCLE_PLAYER_HUE) return PLAYER_COLOR;
    const turns = memory.game.bg_time / HUE_CYCLE_SECONDS;
    return .{
        .hue = @floatCast((turns - @floor(turns)) * 2.0 * std.math.pi),
        .chroma = 0.85,
    };
}

// ---------------------------------------------------------------------------
// Lanes
// ---------------------------------------------------------------------------

/// Fixed hues light is split into. Three is the smallest number that can reach every hue: with two,
/// the colours between them would be reachable but the ones outside their arc would not.
/// Raising it costs one whole flood per lane and buys nothing, since three already span the circle.
pub const LANES = 3;

/// Unit vector of lane `k` on the OKLAB (a, b) plane. The lanes are evenly spaced, so they sum to zero,
/// which is exactly why three equal lanes read as achromatic.
fn laneAxis(comptime k: usize) [2]f32 {
    const angle = 2.0 * std.math.pi * @as(f32, @floatFromInt(k)) / @as(f32, LANES);
    return .{ @cos(angle), @sin(angle) };
}

/// Most saturated colour three non-negative lanes can state without distorting it.
///
/// A lane cannot go negative, so what the lanes can reach is a HEXAGON with corners on the lane axes,
/// not a circle. Past this radius a hue that sits between two lanes would need a negative third lane,
/// and clamping that to zero pulls its saturation down: a violet lamp would come out less colourful
/// than a green one asked for the same chroma. Clamping to the hexagon's INSCRIBED circle instead
/// makes saturation mean the same thing at every hue, which is worth far more than the last 13%.
///
/// `LIGHT_CHROMA_MAX` is the value to raise if lamps come out too pale; this is not a tuning knob.
pub const CHROMA_GAMUT: f32 = @sqrt(3.0) / 2.0;

/// Splits a colour into one weight per lane, each 0 to 1, with the largest exactly 1.
///
/// Scaling to a largest-of-1 is what makes a violet lamp reach as far as a white one of the same
/// strength: the dominant lane always carries the full brightness, so the light's SHAPE never depends
/// on its colour. `resolveCell()` is the exact inverse of this, for any chroma up to `CHROMA_GAMUT`.
fn laneWeights(color: LightColor) [LANES]f32 {
    const sat = @min(CHROMA_GAMUT, @max(0.0, color.chroma)) * (1.0 - CHROMA_WHITE_MIX);
    const target = [2]f32{ sat * @cos(color.hue), sat * @sin(color.hue) };

    // Project the colour onto each lane. The 2/3 is what makes the projection round-trip:
    // three evenly spaced unit vectors satisfy sum(u_k * u_k^T) = (3/2) * I.
    var dots: [LANES]f32 = undefined;
    var largest: f32 = -std.math.floatMax(f32);
    inline for (0..LANES) |k| {
        const axis = laneAxis(k);
        dots[k] = (2.0 / 3.0) * (target[0] * axis[0] + target[1] * axis[1]);
        largest = @max(largest, dots[k]);
    }

    // Lift the whole set so the strongest lane lands on exactly 1.
    var out: [LANES]f32 = undefined;
    inline for (0..LANES) |k| out[k] = @min(1.0, @max(0.0, 1.0 - largest + dots[k]));
    return out;
}

/// Lane strengths of a source, ready to seed. Rounded, so a lane can never exceed `strength`
/// and the bucket bound below stays true.
fn laneStrengths(e: Emission) [LANES]u16 {
    const weights = laneWeights(e.color);
    var out: [LANES]u16 = undefined;
    const strength: f32 = @floatFromInt(e.strength);
    inline for (0..LANES) |k| out[k] = @intFromFloat(@round(strength * weights[k]));
    return out;
}

// Orthogonal decay rates per block type. Air should always be the lowest (decays slowest)!
pub const AIR_FALLOFF: u16 = 12;
pub const SOLID_FALLOFF: u16 = 28;
pub const LIQUID_FALLOFF: u16 = SOLID_FALLOFF - 12;

/// Brightest possible seed value, which is exactly what bounds the number of Dial buckets.
/// Every source in `blockEmission()` must be covered here, or `seed()` can index past the end of
/// `buckets`. Lane strengths never exceed the source strength, so listing the strengths is enough.
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

comptime {
    // Orthogonal cost is stored per-cell as u8; every falloff must fit.
    std.debug.assert(SOLID_FALLOFF <= 255 and LIQUID_FALLOFF <= 255 and AIR_FALLOFF <= 255);
}

/// `ArenaAllocator` instance used for lighting logic.
var arena = memory.makeArena();
/// `Allocator` from `arena`.
var alloc = arena.allocator();

/// Drops every allocation the previous pass made, so a frame starts from an empty arena.
/// The arena keeps its pages, so the grids below cost a bump each rather than a real allocation.
///
/// Every pointer into the arena dies here, the buckets included, which is why they are reset with it.
fn resetArena() void {
    if (!arena.reset(.retain_capacity)) memory.oom();
    for (&buckets) |*lane| @memset(lane, .empty);
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

    // Cap minimum at liquid falloff if the block has water around it.
    if (block.water.bits != 0) {
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

/// Dial buckets, one FIFO of packed coords per light level, per lane.
/// Reset every pass by `resetArena()`, which owns the memory they append into.
var buckets: [LANES]Buckets = undefined;

/// One lane's worth of Dial buckets.
const Buckets = [NUM_BUCKETS]std.array_list.Aligned(u32, .@"16");

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
inline fn seed(a: std.mem.Allocator, light: []u16, bucket_list: *Buckets, i: usize, x: u16, y: u16, val: u16, ambient: u16) void {
    if (val > light[i] and val > ambient) {
        light[i] = val;
        bucket_list[@as(usize, val)].append(a, packCoords(x, y)) catch memory.oom();
    }
}

/// Seeds ONE lane from a point source at the continuous position (`px`, `py`), covering the 2x2 cells
/// it straddles. Light drops off similar to Euclidean distance through each cell's own medium cost.
///
/// `strength` is that lane's share of the source, which is the only thing colour changes here:
/// `applyLighting()` passes a different share per lane, and `floodMiningLight()` passes the whole
/// source to one lane because mining reach must not depend on the lamp's colour.
fn seedPointLight(
    a: std.mem.Allocator,
    cost: []const u8,
    light: []u16,
    bucket_list: *Buckets,
    w: i32,
    h: i32,
    ambient: u16,
    px: f32,
    py: f32,
    strength: u16,
) void {
    // A brighter source than the buckets were sized for would seed past the end of `bucket_list`,
    // so every upgrade that raises `PLAYER_LIGHT` must raise `MAX_PLAYER_LIGHT` with it.
    std.debug.assert(strength <= MAX_SOURCE);
    if (strength == 0) return;

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
                if (@as(f32, @floatFromInt(strength)) > drop) {
                    const val: u16 = @intFromFloat(@as(f32, @floatFromInt(strength)) - drop);
                    seed(a, light, bucket_list, i, @intCast(cx), @intCast(cy), val, ambient);
                }
            }
        }
    }
}

/// One lane's Dial flood: process buckets brightest -> dimmest, relaxing 8 neighbors.
/// Because we descend and edge costs are strictly positive, appends only ever target strictly-lower
/// buckets, so each cell is finalized exactly once at its brightest value regardless of source count.
///
/// TEMPORARY. This is the plain bucket sweep, kept so the colour pipeline around it runs and can be
/// looked at. It walks every level from `MAX_SOURCE` down to `ambient` whether or not anything sits
/// there, which is `MAX_SOURCE` empty probes per lane per frame, and three lanes now pay it instead
/// of two. The radix heap replaces exactly this function and nothing else around it:
/// same signature, same contract, `log2(MAX_SOURCE)` buckets instead of `MAX_SOURCE`.
fn floodLane(
    a: std.mem.Allocator,
    cost: []const u8,
    light: []u16,
    bucket_list: *Buckets,
    w: i32,
    h: i32,
    ambient: u16,
) void {
    var b: u16 = MAX_SOURCE;
    while (b > ambient) : (b -= 1) {
        const bucket_id: usize = @intCast(b);
        // Nothing appends to bucket_list[b] once we reach level b (relaxation only writes lower
        // levels), so this backing slice is stable for the duration of the inner loop.
        const items = bucket_list[bucket_id].items;
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
                            bucket_list[@as(usize, nl)].append(a, packCoords(
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

/// Steps a full hue turn is divided into. One more than `LIGHT_MAX`, because hue wraps:
/// the step after the last one is the first one again. Mirrored by `LIGHT_HUE_STEPS` in src/shader.wgsl.
pub const HUE_STEPS: u32 = @as(u32, LIGHT_MAX) + 1;

/// Quantizes a flood value onto a `LightChannel`. Values above `MAX_LIGHT` clamp rather than wrap,
/// so a cell standing on top of a source is simply full brightness.
inline fn quantizeLightness(value: u16) LightChannel {
    const clamped: u32 = @min(value, MAX_LIGHT);
    return @intCast((clamped * LIGHT_MAX + MAX_LIGHT / 2) / MAX_LIGHT);
}

/// Reads one cell's three lane values back out as a colour. The exact inverse of `laneWeights()`.
///
/// Lightness is the STRONGEST lane, which is what makes a coloured light reach exactly as far as a
/// white one. Chroma and hue come from how the other two lanes compare to it: three equal lanes point
/// nowhere and give white, and one lane alone points straight at its own hue and gives full chroma.
fn resolveCell(lanes: [LANES]u16) BlockLight {
    var strongest: u16 = 0;
    inline for (0..LANES) |k| strongest = @max(strongest, lanes[k]);
    if (strongest == 0) return .none;

    const lightness = quantizeLightness(strongest);

    // Fast path for the common cell: equal lanes are achromatic, so skip the trig entirely.
    // Every ambient-only cell and every white-lit cell lands here.
    var equal = true;
    inline for (1..LANES) |k| equal = equal and (lanes[k] == lanes[0]);
    if (equal) return .{ .l = lightness };

    // Sum the lane axes, each weighted by that lane's share of the strongest.
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

    // atan2 returns -pi..pi, and the block stores a full turn.
    var angle = std.math.atan2(vec[1], vec[0]);
    if (angle < 0) angle += 2.0 * std.math.pi;
    const hue_fraction = angle / (2.0 * std.math.pi);

    // Hue is CIRCULAR, so it quantizes onto `HUE_STEPS` steps that WRAP rather than onto 0..LIGHT_MAX
    // that clamp: a hue rounding up to a full turn is the same hue as zero, and no code point is wasted.
    const steps: f32 = @floatFromInt(HUE_STEPS);
    const hue_step = @as(u32, @intFromFloat(@round(hue_fraction * steps))) % HUE_STEPS;

    return .{
        .l = lightness,
        .c = @intFromFloat(@round(magnitude * @as(f32, @floatFromInt(LIGHT_MAX)))),
        .h = @intCast(hue_step),
    };
}

/// Floods every lane over the visible block array and writes each block's resolved OKLCH light.
/// See the file header for how the lanes carry colour through a shortest-path flood.
pub fn applyLighting(out: []Block, wb: u32, hb: u32, player_bx: f32, player_by: f32) void {
    resetArena();
    const w: i32 = @intCast(wb);
    const h: i32 = @intCast(hb);
    const wbw: u16 = @intCast(wb);

    // Orthogonal step cost per cell (u8 keeps the flood's neighbor reads cache-friendly), then the
    // high-precision light of each lane. All of it lives in the arena `resetArena()` just cleared.
    const cost_slice = alloc.alignedAlloc(u8, memory.MAIN_ALIGN, out.len) catch memory.oom();
    var lane_light: [LANES][]u16 = undefined;
    inline for (0..LANES) |k| {
        lane_light[k] = alloc.alignedAlloc(u16, memory.MAIN_ALIGN, out.len) catch memory.oom();
    }

    const ambient: u16 = if (dw.dev_menu and IS_LIGHT_GLOBAL) AMBIENT_LIGHT_DEBUG else AMBIENT_LIGHT;

    // Single reset pass: precompute per-cell cost, set every lane to ambient (which is achromatic
    // precisely because all the lanes get the same value), then seed each emitting block.
    var sy: u16 = 0;
    var sx: u16 = 0;
    for (out, 0..) |block, i| {
        cost_slice[i] = orthoCost(block);
        inline for (0..LANES) |k| lane_light[k][i] = ambient;

        const emission = blockEmission(block.id);
        if (emission.strength > ambient) {
            const strengths = laneStrengths(emission);
            inline for (0..LANES) |k| {
                seed(alloc, lane_light[k], &buckets[k], i, sx, sy, strengths[k], ambient);
            }
        }

        sx += 1;
        if (sx == wbw) {
            sx = 0;
            sy += 1;
        }
    }

    // Seed the continuous player source. This one is interpolated between logic ticks so the light
    // does not snap block to block; anything that has to AGREE with the simulation reads
    // `miningLightAt()` instead, never this.
    const player_strengths = laneStrengths(.{ .strength = PLAYER_LIGHT, .color = playerColor() });
    inline for (0..LANES) |k| {
        seedPointLight(
            alloc,
            cost_slice,
            lane_light[k],
            &buckets[k],
            w,
            h,
            ambient,
            player_bx,
            player_by,
            player_strengths[k],
        );
    }

    // One independent flood per lane, all of them over the SAME cost grid, which is what keeps the
    // grid hot in cache and what makes a lane cost only as much ground as its own light covers.
    inline for (0..LANES) |k| {
        floodLane(alloc, cost_slice, lane_light[k], &buckets[k], w, h, ambient);
    }

    for (out, 0..) |*block, i| {
        var lanes: [LANES]u16 = undefined;
        inline for (0..LANES) |k| lanes[k] = lane_light[k][i];
        block.setLight(resolveCell(lanes));
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
var buckets_mining: Buckets = undefined;

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
    // ONE lane, seeded with the player's whole strength and no colour at all. Mining reach is a
    // gameplay quantity, so it must answer the same whatever the lamp is tinted; a coloured lane
    // split here would quietly shorten the reach of every lamp that is not white.
    seedPointLight(mining_alloc, &mining_cost, &mining_scratch, &buckets_mining, span, span, 0, px, py, PLAYER_LIGHT);
    floodLane(mining_alloc, &mining_cost, &mining_scratch, &buckets_mining, span, span, 0);

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

// ---------------------------------------------------------------------------
// Tests. These cover the colour half only: the split into lanes and the read back out of them.
// Neither depends on the flood, so they keep holding when `floodLane()` is replaced.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// What `resolveCell()` recovers from a source seeded at `strength`, with no travel in between.
fn roundTrip(color: LightColor, strength: u16) BlockLight {
    return resolveCell(laneStrengths(.{ .strength = strength, .color = color }));
}

test "a coloured source reaches exactly as far as a white one" {
    // The strongest lane IS the brightness, so the light's shape never depends on its colour.
    // If this breaks, saturated lamps quietly light a smaller room than white ones.
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
    // Equal lanes must take the fast path in `resolveCell()` rather than fall into the trig.
    const lanes = laneStrengths(.{ .strength = 200, .color = .white });
    try testing.expectEqual(lanes[0], lanes[1]);
    try testing.expectEqual(lanes[1], lanes[2]);
}

test "a source's hue survives the trip through the lanes" {
    // Quantization bounds the error: hue lands on one of `HUE_STEPS`, so half a step is the floor.
    const tolerance = 2.0 * (2.0 * std.math.pi / @as(f32, @floatFromInt(HUE_STEPS)));
    for ([_]f32{ Hue.fire, Hue.gold, Hue.green, Hue.cyan, Hue.violet }) |hue| {
        const got = roundTrip(.{ .hue = hue, .chroma = 0.8 }, 255);
        const recovered = @as(f32, @floatFromInt(got.h)) /
            @as(f32, @floatFromInt(HUE_STEPS)) * 2.0 * std.math.pi;

        // Compare on the circle: 0 and 2pi are the same hue.
        var delta = @abs(recovered - hue);
        if (delta > std.math.pi) delta = 2.0 * std.math.pi - delta;
        try testing.expect(delta <= tolerance);
    }
}

test "chroma survives the trip at every hue inside the gamut" {
    // The point of `CHROMA_GAMUT`: saturation must mean the same thing whatever the hue, so a violet
    // lamp is exactly as colourful as a green one asked for the same chroma. Tolerance covers the
    // rounding of the lane strengths and of `c` itself, which is one part in `LIGHT_MAX`.
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
    // Asking for more saturation than the lanes can state must cost saturation only. If it moved the
    // hue, a source would drift toward the nearest lane as it got more colourful.
    const inside = roundTrip(.{ .hue = Hue.violet, .chroma = CHROMA_GAMUT }, 255);
    const past = roundTrip(.{ .hue = Hue.violet, .chroma = 1.0 }, 255);
    try testing.expectEqual(inside.c, past.c);
    try testing.expectEqual(inside.h, past.h);
}

test "the campfire still shifts OKLAB by the (0.024, 0.060) it always did" {
    // The one look this rewrite had to preserve exactly, since every existing screenshot has fire in it.
    const got = roundTrip(.fire, CAMPFIRE_LIGHT);
    const chroma = @as(f32, @floatFromInt(got.c)) / @as(f32, @floatFromInt(LIGHT_MAX)) * LIGHT_CHROMA_MAX;
    const hue = @as(f32, @floatFromInt(got.h)) / @as(f32, @floatFromInt(HUE_STEPS)) * 2.0 * std.math.pi;
    try testing.expectApproxEqAbs(@as(f32, 0.024), chroma * @cos(hue), 0.004);
    try testing.expectApproxEqAbs(@as(f32, 0.060), chroma * @sin(hue), 0.004);
}

test "a lane below ambient washes the tint out instead of keeping it" {
    // Ambient is achromatic and floors every lane, so a saturated source in a brightly lit room
    // reads as a weak tint rather than as a full-strength one. Global light must not turn violet.
    const dim = resolveCell(.{ 255, 192, 192 });
    const dark = resolveCell(.{ 255, 0, 0 });
    try testing.expect(dim.c < dark.c);
    try testing.expectEqual(dim.h, dark.h);
}
