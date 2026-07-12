//! Handles structure generation logic and compile-time machinations for structures.
//!
//! Each structure in the `structures` tuple declares:
//! - `spawn_area` (power of two, and >= `max_w`/`max_h`), `max_w`, `max_h`, `target_chance`.
//! - `getBounds()` — where in its grid cell the candidate lands; use `jitter()` so the box is free to
//!   overhang the cell (see "Spawn grid" below).
//! - `generate()` — the sprite for one block of the footprint, derived from the passed `bounds`.
//! - `constraints` (OPTIONAL) — a declarative terrain rule list (`Constraint`): must it rest on ground?
//!   stay clear of a ceiling? lie flat? Evaluated ONCE per grid cell and memoized, so a structure may
//!   stack as many rules as it likes without the cost scaling by footprint area, and the rules are
//!   comptime-sorted cheapest-first so the expensive ones only run on candidates that survive the cheap ones.
//!
//! Spawn grid: a candidate is anchored uniformly ANYWHERE in its `spawn_area` cell and may overhang into
//! the neighboring cells. (Confining the box to its own cell would leave a `max_w`-wide band along every
//! cell edge that no structure origin can ever occupy — a visible periodic lattice, worst when the
//! structure is large relative to its cell.) The cost is that two same-kind candidates can now collide, so
//! `isBlockedBySameKind()` deterministically keeps the one in the lower (cy, cx) cell.
const std = @import("std");
const dw = @import("../root.zig");

const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;

pub const BasicRect = @import("structures/BasicRect.zig");
pub const Ancient = @import("structures/Ancient.zig");
pub const Pillar = @import("structures/Pillar.zig");
pub const Geode = @import("structures/Geode.zig");
pub const Chamber = @import("structures/Chamber.zig");
pub const Tree = @import("structures/Tree.zig");
pub const Shrub = @import("structures/Shrub.zig");
pub const Plant = @import("structures/Plant.zig");

/// A struct list of all structures ordered by spawning priority.
pub const structures = .{
    BasicRect,
    Ancient,
    Pillar,
    Geode,
    Chamber,
    Tree,
    Shrub,
    Plant,
};

/// A simple axis-aligned bounding box, in absolute world blocks. Half-open: `[start, end)`.
pub const Rect = struct {
    x_start: i32,
    y_start: i32,
    x_end: i32,
    y_end: i32,

    pub inline fn overlaps(self: Rect, other: Rect) bool {
        return self.x_start < other.x_end and self.x_end > other.x_start and
            self.y_start < other.y_end and self.y_end > other.y_start;
    }

    pub inline fn contains(self: Rect, wx: i32, wy: i32) bool {
        return wx >= self.x_start and wx < self.x_end and wy >= self.y_start and wy < self.y_end;
    }
};

/// A structure's placed block: the sprite `id`, plus (for ore/gem overlays) the stone `base` the
/// structure wants beneath it. `base == .none` means "fall back to the natural terrain it replaced".
pub const StructureResult = struct {
    id: Sprite,
    base: Sprite = .none,
    /// Starting water volume (0-15) for a waterloggable `id` placed inside a pool.
    /// A structure that puts a dry waterloggable block (a chest, a furnace) in a row it also fills with
    /// water MUST set this to `Block.MAX_HP`, or the sim floods the cell on the chunk's first tick and
    /// writes a modification entry for terrain the player never touched. See `BlockSpec.water_volume`.
    water_volume: u4 = 0,
};

/// Anchors one edge of a `Region` to the candidate's bounding box: `start` is the box's left/top edge,
/// `end` is its right/bottom edge (exclusive). `off` shifts outward (negative) or inward (positive).
pub const Edge = struct {
    at: enum { start, end } = .start,
    off: i32 = 0,

    /// Resolves this edge against a candidate's bounds on one axis.
    pub inline fn resolve(self: Edge, start: i32, end: i32) i32 {
        return (if (self.at == .start) start else end) + self.off;
    }
};

/// A half-open box relative to the candidate's bounds; defaults to exactly the footprint.
/// The row directly below the box, for instance, is `.{ .y0 = .{ .at = .end }, .y1 = .{ .at = .end, .off = 1 } }`.
pub const Region = struct {
    x0: Edge = .{ .at = .start },
    x1: Edge = .{ .at = .end },
    y0: Edge = .{ .at = .start },
    y1: Edge = .{ .at = .end },
};

/// Ground-flatness rule: profiles every column in `[x0, x1)` for its ground surface (see `surfaceY()`) and
/// demands the profile be level enough to build a flat-bottomed structure on.
///
/// The window is deliberately ASYMMETRIC, because the two directions do not look alike:
/// - ground ABOVE `row` (`max_rise`) just means the structure digs into a rise, which reads fine.
/// - ground BELOW `row` (`max_drop`) leaves a visible gap under the structure — it floats. Keep it at 0
///   unless the structure has something to stand on.
///
/// A column whose surface falls outside `[row - max_rise, row + max_drop]` fails outright, and the surfaces
/// that do land inside must all fit within one `max_slope`-tall band.
pub const Level = struct {
    x0: Edge = .{ .at = .start },
    x1: Edge = .{ .at = .end },
    /// Row the ground is expected at; typically the first row below the box (`.{ .at = .end }`).
    row: Edge = .{ .at = .end },
    max_slope: i32 = 2,
    max_rise: i32 = 3,
    max_drop: i32 = 0,
};

/// One terrain rule a candidate must satisfy to be placed. All rules in a structure's `constraints` list
/// are ANDed; order in the source does not matter, since they are sorted by sample cost at compile time.
pub const Constraint = union(enum) {
    /// Every block of the region must be solid base terrain.
    solid: Region,
    /// Every block of the region must be non-solid base terrain (air, or a liquid).
    empty: Region,
    /// The ground under the region must be flat; see `Level`.
    level: Level,
    /// Escape hatch for a rule the vocabulary above cannot express. Always sorted last.
    custom: *const fn (Rect) bool,
};

/// Tests the BASE terrain (pre-ore, pre-structure) for a foundation block at absolute world block (`wx`, `wy`).
/// The shared primitive every terrain constraint is built from.
/// World coordinates are `u32` and wrap, so the `i32` arguments are reinterpreted rather than sign-extended.
pub inline fn baseSolid(wx: i32, wy: i32) bool {
    const uwx: u32 = @bitCast(wx);
    const uwy: u32 = @bitCast(wy);
    return dw.procedural.getBaseSpriteType(
        uwx / dw.CHUNK_SIZE,
        uwy / dw.CHUNK_SIZE,
        @intCast(uwx % dw.CHUNK_SIZE),
        @intCast(uwy % dw.CHUNK_SIZE),
    ).sprite.isFoundation();
}

/// Finds the ground surface of column `wx`: the topmost row in `[y_from, y_to]` that is solid base terrain
/// with open space directly above it. Null when the column has no surface in that window (solid all the way
/// through, or empty all the way through), which reads as "no floor here".
/// Costs `y_to - y_from + 2` terrain samples, so keep the window tight.
pub fn surfaceY(wx: i32, y_from: i32, y_to: i32) ?i32 {
    std.debug.assert(y_to >= y_from);
    var above_solid = baseSolid(wx, y_from - 1);
    var y = y_from;
    while (y <= y_to) : (y += 1) {
        const solid = baseSolid(wx, y);
        if (solid and !above_solid) return y;
        above_solid = solid;
    }
    return null;
}

/// Anchors a `w` x `h` footprint uniformly anywhere in grid cell (`cx`, `cy`), overhang included.
/// Every structure's `getBounds()` should route through this: an origin drawn from `[0, spawn_area - w)`
/// instead would blank out a band along each cell edge and make the spawn lattice visible.
pub inline fn jitter(state: *HashState, cx: i32, cy: i32, area: u32, w: i32, h: i32) Rect {
    const i_area = @as(i32, @intCast(area));
    const x_start = cx * i_area + @as(i32, @intCast(state.getLimit(u32, area)));
    const y_start = cy * i_area + @as(i32, @intCast(state.getLimit(u32, area)));
    return .{
        .x_start = x_start,
        .y_start = y_start,
        .x_end = x_start + w,
        .y_end = y_start + h,
    };
}

/// Runs one terrain rule against a candidate's bounds.
fn checkConstraint(comptime c: Constraint, bounds: Rect) bool {
    switch (c) {
        .solid, .empty => |region| {
            const want_solid = c == .solid;
            const x0 = region.x0.resolve(bounds.x_start, bounds.x_end);
            const x1 = region.x1.resolve(bounds.x_start, bounds.x_end);
            const y0 = region.y0.resolve(bounds.y_start, bounds.y_end);
            const y1 = region.y1.resolve(bounds.y_start, bounds.y_end);
            var y = y0;
            while (y < y1) : (y += 1) {
                var x = x0;
                while (x < x1) : (x += 1) {
                    if (baseSolid(x, y) != want_solid) return false;
                }
            }
            return true;
        },
        .level => |lv| {
            const x0 = lv.x0.resolve(bounds.x_start, bounds.x_end);
            const x1 = lv.x1.resolve(bounds.x_start, bounds.x_end);
            const row = lv.row.resolve(bounds.y_start, bounds.y_end);

            var highest: i32 = std.math.maxInt(i32);
            var lowest: i32 = std.math.minInt(i32);
            var x = x0;
            while (x < x1) : (x += 1) {
                const surface = surfaceY(x, row - lv.max_rise, row + lv.max_drop) orelse return false;
                highest = @min(highest, surface);
                lowest = @max(lowest, surface);
                if (lowest - highest > lv.max_slope) return false;
            }
            return true;
        },
        .custom => |func| return func(bounds),
    }
}

/// Terrain samples a rule costs, used to sort the list cheapest-first at compile time.
/// Spans whose two edges share an anchor have a fixed size; the rest are bounded by the footprint.
fn constraintCost(comptime c: Constraint, comptime w: i32, comptime h: i32) usize {
    const spanOf = struct {
        fn f(a: Edge, b: Edge, full: i32) i32 {
            return if (a.at == b.at) @max(0, b.off - a.off) else @max(0, full + b.off - a.off);
        }
    }.f;
    return switch (c) {
        .solid, .empty => |r| @intCast(spanOf(r.x0, r.x1, w) * spanOf(r.y0, r.y1, h)),
        .level => |lv| @intCast(spanOf(lv.x0, lv.x1, w) * (lv.max_rise + lv.max_drop + 2)),
        .custom => std.math.maxInt(usize), // opaque, so assume the worst and run it last
    };
}

/// Each structure's `constraints`, sorted cheapest-first (empty for structures with no terrain rules).
const constraint_table: [structures.len][]const Constraint = blk: {
    @setEvalBranchQuota(50000);
    var table: [structures.len][]const Constraint = @splat(&.{});

    for (structures, 0..) |S, i| {
        if (!@hasDecl(S, "constraints")) continue;
        var sorted: [S.constraints.len]Constraint = S.constraints;
        for (1..sorted.len) |a| {
            var j = a;
            while (j > 0 and constraintCost(sorted[j - 1], S.max_w, S.max_h) >
                constraintCost(sorted[j], S.max_w, S.max_h)) : (j -= 1)
            {
                std.mem.swap(Constraint, &sorted[j - 1], &sorted[j]);
            }
        }
        const frozen = sorted;
        table[i] = &frozen;
    }
    break :blk table;
};

/// Evaluates every terrain rule of `kind` against a candidate, cheapest rule first.
inline fn satisfiesConstraints(comptime kind: usize, bounds: Rect) bool {
    inline for (constraint_table[kind]) |c| {
        if (!checkConstraint(c, bounds)) return false;
    }
    return true;
}

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

// A candidate may overhang its cell by at most one cell, which is what bounds every neighborhood scan
// here (and the 2x2 candidate sweep in `generateStructureForKind()`) to a fixed, tiny size.
comptime {
    for (Configs, 0..) |conf, i| {
        if (!std.math.isPowerOfTwo(conf.spawn_area))
            @compileError(@typeName(structures[i]) ++ ": spawn_area must be a power of two.");
        if (conf.max_w > conf.spawn_area or conf.max_h > conf.spawn_area)
            @compileError(@typeName(structures[i]) ++ ": max_w/max_h must not exceed spawn_area, or a structure could overhang past the neighboring cell.");
    }
}

/// Computes raw probabilities adjusted upwards to compensate for collisions.
/// Two shadows eat into a structure's target density: higher-priority kinds (which suppress it outright)
/// and its OWN kind (overhang means two adjacent candidates can collide, and the later cell loses).
/// Terrain `constraints` are NOT modelled here (they are data-dependent), so a gated structure always lands
/// under its `target_chance`: treat the dial as an upper bound and measure the result.
pub const adjusted_chances = blk: {
    @setEvalBranchQuota(50000);
    var raw: [Configs.len]f64 = undefined;
    for (Configs, 0..) |conf, i| {
        // Expected number of candidates colliding with this one. Survival is modelled as exp(-lambda)
        // rather than 1 - lambda: the linear form goes NEGATIVE once a shadow is dense enough to hold
        // several candidates at once, which is exactly where a large structure on a tight grid lives.
        var lambda: f64 = 0.0;
        for (0..i) |j| {
            const prev = Configs[j];
            const density_prev = prev.target_chance / @as(f64, @floatFromInt(prev.spawn_area * prev.spawn_area));
            const shadow_w = @as(f64, @floatFromInt(prev.max_w + conf.max_w - 1));
            const shadow_h = @as(f64, @floatFromInt(prev.max_h + conf.max_h - 1));
            lambda += density_prev * shadow_w * shadow_h;
        }

        // Same-kind collisions: a candidate is lost when an EARLIER-ordered cell's candidate overlaps it,
        // which is half of its own overlap shadow.
        const density_self = conf.target_chance / @as(f64, @floatFromInt(conf.spawn_area * conf.spawn_area));
        const self_shadow = @as(f64, @floatFromInt((2 * conf.max_w - 1) * (2 * conf.max_h - 1))) * 0.5;
        lambda += density_self * self_shadow;

        // `lambda` counts CANDIDATES, but only candidates that pass their terrain rules actually block
        // (see `placedBounds()`), and terrain acceptance is unknowable at compile time. So lambda badly
        // overestimates for any gated structure, and an uncapped compensation would drive every dense
        // structure's chance to 1.0 -- silently turning `target_chance` into a dead knob. Cap the boost.
        const boost = @min(1.0 / @exp(-lambda), MAX_COMPENSATION);
        raw[i] = @min(1.0, conf.target_chance * boost);
    }
    break :blk raw;
};

/// Ceiling on how far `adjusted_chances` may raise a structure's roll to compensate for collisions.
/// Keeps `target_chance` a meaningful dial; past this, use `spawn_area` to change density.
const MAX_COMPENSATION: f64 = 2.0;

/// One memoized structure grid cell: its bounds and (lazily) whether the candidate is suppressed by a
/// colliding structure or rejected by its own terrain constraints. Keyed by (`cx`, `cy`, `seed`);
/// `blocked`/`fits` stay null until first computed for that cell.
const StructCacheEntry = struct {
    cx: i32 = 0,
    cy: i32 = 0,
    seed: Vec2u = .{ 0, 0 },
    bounds: ?Rect = null,
    blocked: ?bool = null,
    fits: ?bool = null,
    occupied: bool = false,
};

/// Direct-mapped bounds/blocked cache, one bank per structure kind (slots must be a power of two).
/// A structure's bounds and verdicts are identical for every footprint cell and are also re-derived by lower kinds' priority scans,
/// so memoizing per grid cell collapses that repeated hashing (and all terrain sampling) to O(1).
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
    @setEvalBranchQuota(20000); // `getChance()` comptime-searches for a rational approximation of the odds
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

/// Cell range (inclusive) of kind `kind` whose candidates could reach world span [`from`, `to`] on one axis.
/// A candidate anchored anywhere in its cell reaches at most `max - 1` blocks past the anchor, so the scan
/// must start one structure-length before `from`.
inline fn cellRange(comptime area: i32, comptime max: i32, from: i32, to: i32) struct { lo: i32, hi: i32 } {
    return .{ .lo = @divFloor(from - (max - 1), area), .hi = @divFloor(to, area) };
}

/// Bounds of the candidate in cell (`cx`, `cy`), but only if it would actually stand there: a candidate the
/// terrain rejects must not cast a shadow. (A `target_chance` near 1.0 means nearly every cell HAS a
/// candidate, so blocking on mere existence would let a structure that almost never places -- the chamber --
/// blanket-suppress every lower-priority kind in the world.)
///
/// Deliberately ignores whether that candidate is itself blocked: `fits` depends only on terrain, so this
/// stays non-recursive and cannot chain across cells. The cost is over-suppression in the rare case where
/// the blocker was itself blocked.
inline fn placedBounds(comptime kind: usize, cx: i32, cy: i32, struct_seed: Vec2u) ?Rect {
    const entry = structCacheSlot(kind, cx, cy, struct_seed);
    const bounds = entry.bounds orelse return null;
    if (comptime constraint_table[kind].len == 0) return bounds;

    const fits = entry.fits orelse blk: {
        const v = satisfiesConstraints(kind, bounds);
        entry.fits = v;
        break :blk v;
    };
    return if (fits) bounds else null;
}

/// Project bounds onto higher priority grids and evaluate if they intersect.
fn isBlockedByHigherPriority(comptime kind: usize, bounds: Rect, struct_seed: Vec2u) bool {
    inline for (0..kind) |h_kind| {
        const h_area = @as(i32, @intCast(Configs[h_kind].spawn_area));
        const h_max_w = @as(i32, @intCast(Configs[h_kind].max_w));
        const h_max_h = @as(i32, @intCast(Configs[h_kind].max_h));

        const xs = cellRange(h_area, h_max_w, bounds.x_start, bounds.x_end - 1);
        const ys = cellRange(h_area, h_max_h, bounds.y_start, bounds.y_end - 1);

        var cy = ys.lo;
        while (cy <= ys.hi) : (cy += 1) {
            var cx = xs.lo;
            while (cx <= xs.hi) : (cx += 1) {
                if (placedBounds(h_kind, cx, cy, struct_seed)) |h_bounds| {
                    if (bounds.overlaps(h_bounds)) return true;
                }
            }
        }
    }
    return false;
}

/// Resolves a collision between two candidates of the SAME kind, which overhang made possible.
/// The cell that comes first in (cy, cx) order wins, so the verdict never depends on which block is being
/// queried. A candidate suppressed this way is judged purely on the OTHER candidate's existence, not on
/// whether that one survives its own checks: that keeps the rule non-recursive and stable.
fn isBlockedBySameKind(comptime kind: usize, cx: i32, cy: i32, bounds: Rect, struct_seed: Vec2u) bool {
    var ncy = cy - 1;
    while (ncy <= cy + 1) : (ncy += 1) {
        var ncx = cx - 1;
        while (ncx <= cx + 1) : (ncx += 1) {
            const earlier = ncy < cy or (ncy == cy and ncx < cx);
            if (!earlier) continue;
            if (placedBounds(kind, ncx, ncy, struct_seed)) |other| {
                if (bounds.overlaps(other)) return true;
            }
        }
    }
    return false;
}

/// Bounds/collision/terrain checking and generation delegator for one candidate cell.
inline fn tryCandidate(
    comptime kind: usize,
    starting_sprite: Sprite,
    wx: u32,
    wy: u32,
    cx: i32,
    cy: i32,
    struct_seed: Vec2u,
) ?StructureResult {
    const S = structures[kind];

    // Never hold a cache POINTER across a scan. `isBlockedBySameKind()` re-enters `structCacheSlot()` for
    // neighboring cells of this same kind, which share this bank and can evict this very slot -- a held
    // pointer would then be reading and writing some other cell's entry. So copy out, scan, re-acquire.
    const bounds = structCacheSlot(kind, cx, cy, struct_seed).bounds orelse return null;
    if (!bounds.contains(@bitCast(wx), @bitCast(wy))) return null;

    // Both verdicts are properties of the CANDIDATE, so they are computed once per grid cell and reused by
    // every block of the footprint (a per-block `constraints` pass would re-run the terrain noise ~w*h times).
    const blocked = structCacheSlot(kind, cx, cy, struct_seed).blocked orelse blk: {
        const v = isBlockedBySameKind(kind, cx, cy, bounds, struct_seed) or
            (kind > 0 and isBlockedByHigherPriority(kind, bounds, struct_seed));
        structCacheSlot(kind, cx, cy, struct_seed).blocked = v;
        break :blk v;
    };
    if (blocked) return null;

    if (comptime constraint_table[kind].len > 0) {
        // safe to hold: `satisfiesConstraints()` only samples terrain, and never touches this cache
        const entry = structCacheSlot(kind, cx, cy, struct_seed);
        const fits = entry.fits orelse blk: {
            const v = satisfiesConstraints(kind, bounds);
            entry.fits = v;
            break :blk v;
        };
        if (!fits) return null;
    }

    // Hash from the CANDIDATE's cell, never from the block's own: a structure may overhang into the next
    // cell, and keying on the block would hand its far half a different roll (a `moss_shrub2` left with a
    // `moss_shrub1_right` right). This matches the stream `computeStructureBounds()` drew `bounds` from.
    const i_area = @as(i32, @intCast(S.spawn_area));
    var state = makeStructureHash(struct_seed, @bitCast(cx * i_area), @bitCast(cy * i_area), S.spawn_area, kind);
    _ = state.getChance(adjusted_chances[kind]);
    return S.generate(starting_sprite, wx, wy, cx, cy, bounds, &state, struct_seed);
}

/// Unified entry point to iterate through structures in priority order.
pub fn addStructures(
    starting_sprite: Sprite,
    wx: u32,
    wy: u32,
    struct_seed: Vec2u,
) StructureResult {
    const i_wx = @as(i32, @bitCast(wx));
    const i_wy = @as(i32, @bitCast(wy));

    inline for (0..structures.len) |kind| {
        const area = @as(i32, @intCast(Configs[kind].spawn_area));
        // Overhang means the covering candidate may be anchored in a cell up or left of this block's own.
        const xs = cellRange(area, @intCast(Configs[kind].max_w), i_wx, i_wx);
        const ys = cellRange(area, @intCast(Configs[kind].max_h), i_wy, i_wy);

        var cy = ys.lo;
        while (cy <= ys.hi) : (cy += 1) {
            var cx = xs.lo;
            while (cx <= xs.hi) : (cx += 1) {
                if (tryCandidate(kind, starting_sprite, wx, wy, cx, cy, struct_seed)) |result| {
                    return result;
                }
            }
        }
    }
    return .{ .id = starting_sprite };
}
