//! Handles structure generation logic and compile-time machinations for structures.
const std = @import("std");
const dw = @import("../root.zig");

const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;

pub const BasicRect = @import("structures/BasicRect.zig");
pub const Ancient = @import("structures/Ancient.zig");
pub const Pillar = @import("structures/Pillar.zig");
pub const Geode = @import("structures/Geode.zig");
pub const Tree = @import("structures/Tree.zig");

/// A struct list of all structures ordered by spawning priority.
pub const structures = .{
    BasicRect,
    Ancient,
    Pillar,
    Geode,
    Tree,
};

/// A simple axis-aligned bounding box.
pub const Rect = struct {
    x_start: i32,
    y_start: i32,
    x_end: i32,
    y_end: i32,
};

/// A structure's placed block: the sprite `id`, plus (for ore/gem overlays) the stone `base` the
/// structure wants beneath it. `base == .none` means "fall back to the natural terrain it replaced".
pub const StructureResult = struct { id: Sprite, base: Sprite = .none };

/// Comptime helper to find a structure's priority index directly from its type.
pub inline fn getStructureIndex(comptime T: type) usize {
    inline for (structures, 0..) |S, i| {
        if (S == T) return i;
    }
    @compileError("Structure " ++ @typeName(T) ++ " must be registered in the 'structures' tuple!");
}

/// Automatically extracts configurations from the registered types.
pub const Configs = blk: {
    @setEvalBranchQuota(50000);
    var confs: [structures.len]struct {
        spawn_area: u32,
        max_w: u32,
        max_h: u32,
        target_chance: f64,
    } = undefined;
    for (structures, 0..) |S, i| {
        confs[i] = .{
            .spawn_area = S.spawn_area,
            .max_w = S.max_w,
            .max_h = S.max_h,
            .target_chance = S.target_chance,
        };
    }
    break :blk confs;
};

/// Computes raw probabilities adjusted upwards to compensate for collisions.
pub const adjusted_chances = blk: {
    @setEvalBranchQuota(50000);
    var raw: [Configs.len]f64 = undefined;
    for (Configs, 0..) |conf, i| {
        var p_not_blocked: f64 = 1.0;
        for (0..i) |j| {
            const prev = Configs[j];
            const density_prev = prev.target_chance / @as(f64, @floatFromInt(prev.spawn_area * prev.spawn_area));
            const shadow_w = @as(f64, @floatFromInt(prev.max_w + conf.max_w - 1));
            const shadow_h = @as(f64, @floatFromInt(prev.max_h + conf.max_h - 1));
            const shadow_area = shadow_w * shadow_h;

            const p_blocked_by_prev = density_prev * shadow_area;
            p_not_blocked *= @max(0.0, 1.0 - p_blocked_by_prev);
        }
        if (p_not_blocked <= 0.0) {
            @compileError("Structure blocking probability is 100%; structure cannot spawn.");
        }
        const adjusted = conf.target_chance / p_not_blocked;
        raw[i] = @min(1.0, adjusted);
    }
    break :blk raw;
};

/// One memoized structure grid cell: its bounds and (lazily) whether it is blocked by a higher priority.
/// Keyed by (`cx`, `cy`, `seed`); `blocked` is null until first computed for that cell.
const StructCacheEntry = struct {
    cx: i32 = 0,
    cy: i32 = 0,
    seed: Vec2u = .{ 0, 0 },
    bounds: ?Rect = null,
    blocked: ?bool = null,
    occupied: bool = false,
};

/// Direct-mapped bounds/blocked cache, one bank per structure kind (slots must be a power of two).
/// A structure's bounds and blocked verdict are identical for every footprint cell and are also re-derived by lower kinds' priority scans,
/// so memoizing per grid cell collapses that repeated hashing to O(1).
/// Pure function of (cell, seed): the per-entry seed check self-invalidates on reseed, so no explicit clear.
const STRUCT_CACHE_SLOTS = 256;
var struct_cache: [structures.len][STRUCT_CACHE_SLOTS]StructCacheEntry = @splat(@splat(.{}));

/// Returns the (populated) cache entry for structure `kind` at grid cell (`cx`, `cy`), computing bounds on miss.
inline fn structCacheSlot(comptime kind: usize, cx: i32, cy: i32, struct_seed: Vec2u) *StructCacheEntry {
    const ux: u64 = @bitCast(@as(i64, cx));
    const uy: u64 = @bitCast(@as(i64, cy));
    const h = (ux *% 0x9E3779B97F4A7C15) ^ (uy *% 0x85EBCA77C2B2AE63);
    const e = &struct_cache[kind][@as(usize, @intCast((h >> 32) & (STRUCT_CACHE_SLOTS - 1)))];
    if (!(e.occupied and e.cx == cx and e.cy == cy and @reduce(.And, e.seed == struct_seed))) {
        e.* = .{
            .cx = cx,
            .cy = cy,
            .seed = struct_seed,
            .bounds = computeStructureBounds(kind, cx, cy, struct_seed),
            .occupied = true,
        };
    }
    return e;
}

/// Generic bounds retriever utilizing dynamic dispatch over the comptime structures tuple (memoized).
pub inline fn getStructureBounds(comptime kind: usize, cx: i32, cy: i32, struct_seed: Vec2u) ?Rect {
    return structCacheSlot(kind, cx, cy, struct_seed).bounds;
}

/// Uncached bounds computation backing the cache. Call `getStructureBounds()` instead elsewhere.
inline fn computeStructureBounds(comptime kind: usize, cx: i32, cy: i32, struct_seed: Vec2u) ?Rect {
    const S = structures[kind];
    const area = S.spawn_area;
    const i_area = @as(i32, @intCast(area));
    const wx = @as(u32, @bitCast(cx * i_area));
    const wy = @as(u32, @bitCast(cy * i_area));
    var state = makeStructureHash(struct_seed, wx, wy, area, kind);

    if (state.getChance(adjusted_chances[kind])) {
        return S.getBounds(&state, cx, cy);
    }
    return null;
}

/// Creates a `HashState` given a seed, (base depth) coordinates, and power-of-two area where a structure may appear within.
pub inline fn makeStructureHash(
    struct_seed: Vec2u,
    wx: u32,
    wy: u32,
    structure_area: comptime_int,
    unique_id: comptime_int,
) HashState {
    std.debug.assert(std.math.isPowerOfTwo(structure_area));
    const struct_x_coord = wx / structure_area;
    const struct_y_coord: u64 = @intCast(wy / structure_area);

    const init_x = struct_x_coord + (struct_y_coord << 32);
    const init_y = @as(u64, unique_id) << 32;

    return .{
        .seed_vector = struct_seed,
        .x = init_x,
        .y = init_y,
    };
}

/// Creates a `HashState` given a seed and (base depth) coordinates to a block, as well as a unique ID.
pub inline fn makeBlockHash(
    struct_seed: Vec2u,
    wx: u32,
    wy: u32,
    unique_id: comptime_int,
) HashState {
    const init_x = wx + (@as(u64, wy) << 32);
    const init_y = @as(u64, std.math.maxInt(u32) - unique_id) << 32;

    return .{
        .seed_vector = struct_seed,
        .x = init_x,
        .y = init_y,
    };
}

/// Project bounds onto higher priority grids and evaluate if they intersect.
fn isBlockedByHigherPriority(comptime kind: usize, bounds: Rect, struct_seed: dw.utils.Vec2u) bool {
    inline for (0..kind) |h_kind| {
        const h_area = Configs[h_kind].spawn_area;
        const h_i_area = @as(i32, @intCast(h_area));

        const cx_min = @divFloor(bounds.x_start, h_i_area);
        const cx_max = @divFloor(bounds.x_end - 1, h_i_area);
        const cy_min = @divFloor(bounds.y_start, h_i_area);
        const cy_max = @divFloor(bounds.y_end - 1, h_i_area);

        var cy = cy_min;
        while (cy <= cy_max) : (cy += 1) {
            var cx = cx_min;
            while (cx <= cx_max) : (cx += 1) {
                if (getStructureBounds(h_kind, cx, cy, struct_seed)) |h_bounds| {
                    const overlap_x = bounds.x_start < h_bounds.x_end and bounds.x_end > h_bounds.x_start;
                    const overlap_y = bounds.y_start < h_bounds.y_end and bounds.y_end > h_bounds.y_start;
                    if (overlap_x and overlap_y) {
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

/// Generic bounds checking and generation delegator.
inline fn generateStructureForKind(
    comptime kind: usize,
    starting_sprite: Sprite,
    wx: u32,
    wy: u32,
    struct_seed: Vec2u,
) ?StructureResult {
    const S = structures[kind];
    const area = S.spawn_area;
    const i_area = @as(i32, @intCast(area));
    const i_wx = @as(i32, @bitCast(wx));
    const i_wy = @as(i32, @bitCast(wy));
    const cx = @divFloor(i_wx, i_area);
    const cy = @divFloor(i_wy, i_area);

    const entry = structCacheSlot(kind, cx, cy, struct_seed);
    if (entry.bounds) |bounds| {
        if (comptime kind > 0) {
            // blocked is identical for the whole footprint; compute once per grid cell and cache it
            const blocked = entry.blocked orelse blk: {
                const v = isBlockedByHigherPriority(kind, bounds, struct_seed);
                entry.blocked = v;
                break :blk v;
            };
            if (blocked) return null;
        }

        if (i_wx >= bounds.x_start and i_wx < bounds.x_end and i_wy >= bounds.y_start and i_wy < bounds.y_end) {
            var state = makeStructureHash(struct_seed, wx, wy, area, kind);
            _ = state.getChance(adjusted_chances[kind]);

            return S.generate(starting_sprite, wx, wy, cx, cy, bounds, &state, struct_seed);
        }
    }
    return null;
}

// pub fn addBasicRectStructure(
//     starting_sprite: Sprite,
//     wx: u32,
//     wy: u32,
//     struct_seed: Vec2u,
// ) ?Sprite {
//     return generateStructureForKind(0, starting_sprite, wx, wy, struct_seed);
// }

/// Unified entry point to iterate through structures in priority order.
pub fn addStructures(
    starting_sprite: Sprite,
    wx: u32,
    wy: u32,
    struct_seed: Vec2u,
) StructureResult {
    inline for (0..structures.len) |kind| {
        if (generateStructureForKind(kind, starting_sprite, wx, wy, struct_seed)) |result| {
            return result;
        }
    }
    return .{ .id = starting_sprite };
}
