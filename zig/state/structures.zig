//! Handles structure generation logic and compile-time machinations for structures.
//!
//! Each structure in the `structures` tuple declares:
//! - `spawn_area` (power of two, and >= `max_w`/`max_h`), `max_w`, `max_h`, `target_chance`
//! - `getBounds()`: where in its grid cell the placement lands, or null to reject the cell outright;
//!   use `jitter()` so the box is free to overhang the cell
//! - `generate()`: the sprite for one block of the footprint, derived from the passed `bounds`
//! - `constraints` (optional): terrain rules over the footprint (comptime-sorted cheapest first)
//! - `attempts` (optional, default 1): placements to try in a cell before giving up
//!
//! `target_chance` is a ROLL, not a density: terrain rules throw most rolls away.
//! it's also sadly not possible to guess the odds of terrain rules throwing odds...only approximate with auditing.
//!
//! A rule a structure can check WHILE computing its bounds belongs in `getBounds()`, not in `constraints`:
//! rejecting there lets an expensive terrain scan bail early (see `Chamber.getBounds()`).
//!
//! A placement is anchored uniformly ANYWHERE in its `spawn_area` cell and may overhang into the neighboring cells.
//!
//! Small things that need no priority collision belong in `decorations.zig` instead, which is far cheaper:
//! every kind here costs every LOWER kind a collision scan, so this tuple wants to stay short.
const std = @import("std");
const dw = @import("../root.zig");

const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;

/// A struct list of all structures ordered by spawning priority.
pub const structures = .{
    @import("structures/BasicRect.zig"),
    @import("structures/Ancient.zig"),
    @import("structures/Pillar.zig"),
    @import("structures/Geode.zig"),
    @import("structures/Chamber.zig"),
    @import("structures/Tree.zig"),
};

/// A simple axis-aligned bounding box, in absolute world blocks. The rect will then be in `[start, end)`.
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

/// A structure's placed block: the sprite `id`, plus (for ore/gem overlays) the stone `base` the structure wants beneath it.
/// If `base` is `.none`, that means "fall back to the natural terrain it replaced".
pub const StructureResult = struct {
    id: Sprite,
    base: Sprite = .none,
    /// Starting water volume (0-15) for a waterloggable `id` placed inside a pool.
    /// A structure that puts a dry waterloggable block (like chests) in a row it also fills with water MUST set this to `Block.MAX_HP`,
    /// or the sim floods the cell on the chunk's first tick (wasting modification storage, basically).
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

/// Ground-flatness rule: profiles every column in `[x0, x1)` for its ground surface (see `surfaceY()`)
/// and demands the profile be level enough to build a flat-bottomed structure on.
///
/// The window is deliberately ASYMMETRIC, because the two directions do not look alike:
/// - ground ABOVE `row` (`max_rise`) just means the structure digs into a rise, which reads fine.
/// - ground BELOW `row` (`max_drop`) leaves a visible gap under the structure so it floats:
///  keep this at 0 unless the structure has something to stand on.
///
/// A column whose surface falls outside `[row - max_rise, row + max_drop]` fails outright,
/// and the surfaces that do land inside must all fit within one `max_slope`-tall band.
pub const Level = struct {
    x0: Edge = .{ .at = .start },
    x1: Edge = .{ .at = .end },
    /// Row the ground is expected at; typically the first row below the box (`.{ .at = .end }`).
    row: Edge = .{ .at = .end },
    max_slope: i32 = 2,
    max_rise: i32 = 3,
    max_drop: i32 = 0,
};

/// One terrain rule a candidate must satisfy to be placed. All rules in a structure's `constraints` list are ANDed;
/// order in the source does not matter, since they are sorted by sample cost at compile-time.
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

/// Highest valid block coordinate on either axis at base depth (the base world is a square of
/// `getMaxSuffixAtDepth(STARTING_ZOOM_TIMES) + 1` chunks). See `baseSolid()` for why this matters.
pub const MAX_WORLD_BLOCK: i32 = blk: {
    const max_chunk = dw.world.getMaxSuffixAtDepth(dw.startup.STARTING_ZOOM_TIMES);
    break :blk @intCast((max_chunk + 1) * dw.CHUNK_SIZE - 1);
};

/// Tests the BASE terrain (pre-ore, pre-structure) for a foundation block at absolute world block (`wx`, `wy`).
///
/// Probing OUTSIDE the world is routine, not exceptional: a constraint reaches a row above its box,
/// a seating scan reaches rows below it, and `isBeaten()` resolves the candidate in (`cx - 1`, `cy - 1`)
///
/// Bounds being `i32` easily traps what would otherwise be an integer overflow (a bit hacky).
pub inline fn baseSolid(wx: i32, wy: i32) bool {
    if (wx < 0 or wy < 0 or wx > MAX_WORLD_BLOCK or wy > MAX_WORLD_BLOCK) return false;

    const uwx: u32 = @bitCast(wx);
    const uwy: u32 = @bitCast(wy);
    return dw.procedural.getBaseSpriteType(
        uwx / dw.CHUNK_SIZE,
        uwy / dw.CHUNK_SIZE,
        @intCast(uwx % dw.CHUNK_SIZE),
        @intCast(uwy % dw.CHUNK_SIZE),
    ).sprite.isFoundation();
}

/// Finds the ground surface of column `wx`: the topmost row in `[y_from, y_to]` that is solid base terrain with open space directly above it.
/// Null when the column has no surface in that window (solid all the way through, or empty all the way through), which reads as "no floor here".
/// Costs `y_to - y_from + 2` terrain samples, so keep the window tight.
pub fn surfaceY(wx: i32, y_from: i32, y_to: i32) ?i32 {
    return surfaceYWith(baseSolid, wx, y_from, y_to);
}

/// `surfaceY()` against an arbitrary terrain probe.
pub fn surfaceYWith(comptime probe: anytype, wx: i32, y_from: i32, y_to: i32) ?i32 {
    std.debug.assert(y_to >= y_from);
    var above_solid = probe(wx, y_from - 1);
    var y = y_from;
    while (y <= y_to) : (y += 1) {
        const solid = probe(wx, y);
        if (solid and !above_solid) return y;
        above_solid = solid;
    }
    return null;
}

/// Anchors a `w`-by-`h` footprint uniformly anywhere in the grid cell (`cx`, `cy`), overhang included.
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
fn checkConstraint(comptime probe: anytype, comptime c: Constraint, bounds: Rect) bool {
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
                    if (probe(x, y) != want_solid) return false;
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
                const surface = surfaceYWith(probe, x, row - lv.max_rise, row + lv.max_drop) orelse return false;
                highest = @min(highest, surface);
                lowest = @max(lowest, surface);
                if (lowest - highest > lv.max_slope) return false;
            }
            return true;
        },
        .custom => |func| return func(bounds),
    }
}

/// Terrain samples a rule's costs, used to sort the list cheapest-first at compile-time.
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

/// Sorts a rule list cheapest-first, so the 1-sample "is there ground under me" test kills a candidate
/// before the 30-sample "is my whole shaft clear" one ever runs. Shared with `decorations.zig`.
pub fn sortConstraints(comptime list: []const Constraint, comptime w: i32, comptime h: i32) []const Constraint {
    comptime {
        @setEvalBranchQuota(50000);
        var sorted: [list.len]Constraint = list[0..list.len].*;
        for (1..sorted.len) |a| {
            var j = a;
            while (j > 0 and constraintCost(sorted[j - 1], w, h) > constraintCost(sorted[j], w, h)) : (j -= 1) {
                std.mem.swap(Constraint, &sorted[j - 1], &sorted[j]);
            }
        }
        const frozen = sorted;
        return &frozen;
    }
}

/// Runs every rule in `list` against `bounds`, testing terrain through `probe`. Shared with `decorations.zig`.
pub inline fn satisfies(comptime probe: anytype, comptime list: []const Constraint, bounds: Rect) bool {
    inline for (list) |c| {
        if (!checkConstraint(probe, c, bounds)) return false;
    }
    return true;
}

/// Each structure's `constraints`, sorted cheapest-first (empty for structures with no terrain rules).
const constraint_table: [structures.len][]const Constraint = blk: {
    var table: [structures.len][]const Constraint = @splat(&.{});
    for (structures, 0..) |S, i| {
        if (@hasDecl(S, "constraints")) table[i] = sortConstraints(&S.constraints, S.max_w, S.max_h);
    }
    break :blk table;
};

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
        attempts: u32,
    } = undefined;
    for (structures, 0..) |S, i| {
        confs[i] = .{
            .spawn_area = S.spawn_area,
            .max_w = S.max_w,
            .max_h = S.max_h,
            .target_chance = S.target_chance,
            // Placements to try before giving up on a cell. Only worth raising for a heavily gated kind,
            // where one shot at a valid spot per cell is almost always wasted (see `Chamber`).
            .attempts = if (@hasDecl(S, "attempts")) S.attempts else 1,
        };
    }
    break :blk confs;
};

// A candidate may overhang its cell by at most one cell, which is what bounds every neighborhood scan here
// (and the 2x2 candidate sweep in `generateStructureForKind()`) to a fixed, tiny size.
comptime {
    for (Configs, 0..) |conf, i| {
        if (!std.math.isPowerOfTwo(conf.spawn_area))
            @compileError(@typeName(structures[i]) ++ ": spawn_area must be a power of two.");
        if (conf.max_w > conf.spawn_area or conf.max_h > conf.spawn_area)
            @compileError(@typeName(structures[i]) ++ ": max_w/max_h must not exceed spawn_area, or a structure could overhang past the neighboring cell.");
    }
}

/// One memoized structure grid cell: the placement that stands there (terrain rules already applied) and,
/// lazily, whether an overlapping candidate outranks it.
/// Keyed by (`cx`, `cy`, `seed`); `blocked` stays null until first computed for that cell.
const StructCacheEntry = struct {
    cx: i32 = 0,
    cy: i32 = 0,
    seed: Vec2u = .{ 0, 0 },
    bounds: ?Rect = null,
    blocked: ?bool = null,
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

/// The placement that stands in cell (`cx`, `cy`), or null: the roll, the box, and the terrain rules,
/// all resolved together and memoized.
///
/// Terrain is settled HERE rather than in a later pass, because a rejected placement can then simply be
/// retried (see `attempts`). It also means every `bounds` in the cache is one that would really be built,
/// which is what lets the collision scan trust it.
pub inline fn getStructureBounds(comptime kind: usize, cx: i32, cy: i32, struct_seed: Vec2u) ?Rect {
    return structCacheSlot(kind, cx, cy, struct_seed).bounds;
}

/// Uncached resolution backing the cache. Call `getStructureBounds()` instead elsewhere.
inline fn computeStructureBounds(comptime kind: usize, cx: i32, cy: i32, struct_seed: Vec2u) ?Rect {
    @setEvalBranchQuota(20000); // `getChance()` comptime-searches for a rational approximation of the odds
    const S = structures[kind];
    var state = makeStructureHash(struct_seed, cellOriginX(kind, cx), cellOriginY(kind, cy), S.spawn_area, kind);
    if (!state.getChance(S.target_chance)) return null;

    // Each attempt draws fresh jitter from the same stream, so a gated kind gets several shots at a valid
    // spot in its cell instead of one. `generate()` reads an INDEPENDENT stream, so it neither knows nor
    // cares how many draws were burned here.
    inline for (0..Configs[kind].attempts) |_| {
        if (S.getBounds(&state, cx, cy)) |bounds| {
            if (satisfies(baseSolid, constraint_table[kind], bounds)) return bounds;
        }
    }
    return null;
}

inline fn cellOriginX(comptime kind: usize, cx: i32) u32 {
    return @bitCast(cx * @as(i32, @intCast(structures[kind].spawn_area)));
}

inline fn cellOriginY(comptime kind: usize, cy: i32) u32 {
    return @bitCast(cy * @as(i32, @intCast(structures[kind].spawn_area)));
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
/// A candidate anchored anywhere in its cell reaches at most `max - 1` blocks past the anchor,
/// so the scan must start one structure-length before `from`.
inline fn cellRange(comptime area: i32, comptime max: i32, from: i32, to: i32) struct { lo: i32, hi: i32 } {
    return .{ .lo = @divFloor(from - (max - 1), area), .hi = @divFloor(to, area) };
}

/// A cell's tie-break rank against other cells of its own kind. Hash-derived, so no direction is favored.
inline fn cellRank(comptime kind: usize, cx: i32, cy: i32, struct_seed: Vec2u) u64 {
    var state = makeStructureHash(
        struct_seed,
        cellOriginX(kind, cx),
        cellOriginY(kind, cy),
        structures[kind].spawn_area,
        kind + 2 * structures.len,
    );
    return state.getRaw();
}

/// Whether an overlapping placement outranks this one.
///
/// Collapses what used to be two separate rules into one scan, because both ask the same question:
/// - a higher-priority KIND always wins (that ordering is the point of the tuple)
/// - two placements of the SAME kind (which overhang makes possible) are settled by `cellRank()`
fn isBeaten(comptime kind: usize, cx: i32, cy: i32, bounds: Rect, struct_seed: Vec2u) bool {
    const my_rank = cellRank(kind, cx, cy, struct_seed);

    inline for (0..kind + 1) |other| {
        const area = @as(i32, @intCast(Configs[other].spawn_area));
        const xs = cellRange(area, @intCast(Configs[other].max_w), bounds.x_start, bounds.x_end - 1);
        const ys = cellRange(area, @intCast(Configs[other].max_h), bounds.y_start, bounds.y_end - 1);

        var ncy = ys.lo;
        while (ncy <= ys.hi) : (ncy += 1) {
            var ncx = xs.lo;
            while (ncx <= xs.hi) : (ncx += 1) {
                if (other == kind) {
                    if (ncx == cx and ncy == cy) continue;
                    // equal ranks fall back to cell order, so the verdict stays a total order either way
                    const rank = cellRank(kind, ncx, ncy, struct_seed);
                    const wins = rank > my_rank or
                        (rank == my_rank and (ncy < cy or (ncy == cy and ncx < cx)));
                    if (!wins) continue;
                }
                if (getStructureBounds(other, ncx, ncy, struct_seed)) |rival| {
                    if (bounds.overlaps(rival)) return true;
                }
            }
        }
    }
    return false;
}

/// The placement in cell (`cx`, `cy`) that actually gets built: it stands on valid terrain AND nothing
/// outranks it. Everything about it is a property of the CELL, never of the block asking, so it is memoized.
///
/// Never holds a cache POINTER across the scan: `isBeaten()` re-enters `structCacheSlot()`
/// for neighboring cells of this same kind, which share this bank and can evict this very slot.
inline fn acceptedBounds(comptime kind: usize, cx: i32, cy: i32, struct_seed: Vec2u) ?Rect {
    const bounds = structCacheSlot(kind, cx, cy, struct_seed).bounds orelse return null;

    const blocked = structCacheSlot(kind, cx, cy, struct_seed).blocked orelse blk: {
        const v = isBeaten(kind, cx, cy, bounds, struct_seed);
        structCacheSlot(kind, cx, cy, struct_seed).blocked = v;
        break :blk v;
    };
    return if (blocked) null else bounds;
}

/// `acceptedBounds()` for `debug/audit.zig`, which needs the placement itself rather than a block's sprite.
pub inline fn acceptedBoundsForAudit(comptime kind: usize, cx: i32, cy: i32, struct_seed: Vec2u) ?Rect {
    return acceptedBounds(kind, cx, cy, struct_seed);
}

/// Draws one block of an accepted placement.
///
/// Keyed on the CANDIDATE's cell, never the block's own: a structure may overhang into the next cell,
/// and keying on the block would hand its far half a different roll.
///
/// The stream is INDEPENDENT of the one `computeStructureBounds()` drew from (a separate `unique_id` namespace).
/// Stops a structure's own choices from correlating with its jitter offset and `attempts` complexity creating issues.
inline fn generateFrom(
    comptime kind: usize,
    candidate: Candidate,
    starting_sprite: Sprite,
    wx: u32,
    wy: u32,
    struct_seed: Vec2u,
) ?StructureResult {
    const S = structures[kind];
    var state = makeStructureHash(
        struct_seed,
        cellOriginX(kind, candidate.cx),
        cellOriginY(kind, candidate.cy),
        S.spawn_area,
        kind + structures.len,
    );
    return S.generate(
        starting_sprite,
        wx,
        wy,
        candidate.cx,
        candidate.cy,
        candidate.bounds,
        &state,
        struct_seed,
    );
}

/// An accepted candidate reaching into a chunk: its cell (needed to replay the hash) and its footprint.
const Candidate = struct { cx: i32, cy: i32, bounds: Rect };

/// Upper bound on how many cells of one kind can reach a single chunk along one axis.
/// A candidate reaches `max - 1` blocks past its anchor, so the scan starts that far before the chunk.
fn maxCellsPerAxis(comptime area: i32, comptime max: i32) usize {
    return @intCast(@divFloor(dw.CHUNK_SIZE - 2 + max, area) + 2);
}

/// Slots reserved per kind in a `ChunkCandidates`. Sized from the worst kind so the build loop can never overrun.
const MAX_CHUNK_CANDIDATES: usize = blk: {
    var m: usize = 0;
    for (Configs) |c| {
        const area: i32 = @intCast(c.spawn_area);
        m = @max(m, maxCellsPerAxis(area, @intCast(c.max_w)) * maxCellsPerAxis(area, @intCast(c.max_h)));
    }
    break :blk m;
};

/// Every candidate that can claim a block of one chunk, resolved once for the whole chunk.
const ChunkCandidates = struct {
    chunk_x: i32 = 0,
    chunk_y: i32 = 0,
    seed: Vec2u = .{ 0, 0 },
    occupied: bool = false,
    counts: [structures.len]u8 = @splat(0),
    /// Per kind, in the same (cy, cx) cell order the per-block scan used to walk, so the first candidate
    /// containing a block is still the one that wins.
    list: [structures.len][MAX_CHUNK_CANDIDATES]Candidate = undefined,
};

/// Direct-mapped context cache (slots must be a power of two).
/// Sized so a chunk AND its neighbors stay resident: the edge-flag halo walks a chunk's border cell by cell,
/// alternating between the left and right neighbor chunk on every row, so a single-entry memo would thrash.
const CHUNK_CTX_SLOTS = 64;
var chunk_ctx: [CHUNK_CTX_SLOTS]ChunkCandidates = @splat(.{});

inline fn chunkCtxIndex(chunk_x: i32, chunk_y: i32) usize {
    const ux: u64 = @bitCast(@as(i64, chunk_x));
    const uy: u64 = @bitCast(@as(i64, chunk_y));
    const h = (ux *% 0x9E3779B97F4A7C15) ^ (uy *% 0x85EBCA77C2B2AE63);
    return @intCast((h >> 32) & (CHUNK_CTX_SLOTS - 1));
}

/// Resolves every kind's candidates for one chunk. Safe to hold `ctx` across: nothing reachable from here
/// re-enters this cache (terrain sampling reads BASE terrain, which is upstream of structures).
fn buildChunkCandidates(ctx: *ChunkCandidates, chunk_x: i32, chunk_y: i32, struct_seed: Vec2u) void {
    ctx.chunk_x = chunk_x;
    ctx.chunk_y = chunk_y;
    ctx.seed = struct_seed;
    ctx.occupied = true;

    const x0 = chunk_x * dw.CHUNK_SIZE;
    const y0 = chunk_y * dw.CHUNK_SIZE;
    const chunk_rect: Rect = .{
        .x_start = x0,
        .y_start = y0,
        .x_end = x0 + dw.CHUNK_SIZE,
        .y_end = y0 + dw.CHUNK_SIZE,
    };

    inline for (0..structures.len) |kind| {
        const area = @as(i32, @intCast(Configs[kind].spawn_area));
        const xs = cellRange(area, @intCast(Configs[kind].max_w), x0, x0 + dw.CHUNK_SIZE - 1);
        const ys = cellRange(area, @intCast(Configs[kind].max_h), y0, y0 + dw.CHUNK_SIZE - 1);

        var n: usize = 0;
        var cy = ys.lo;
        while (cy <= ys.hi) : (cy += 1) {
            var cx = xs.lo;
            while (cx <= xs.hi) : (cx += 1) {
                // reject a candidate that misses this chunk BEFORE paying for collision/terrain checks
                const raw = structCacheSlot(kind, cx, cy, struct_seed).bounds orelse continue;
                if (!raw.overlaps(chunk_rect)) continue;

                if (acceptedBounds(kind, cx, cy, struct_seed)) |bounds| {
                    std.debug.assert(n < MAX_CHUNK_CANDIDATES);
                    ctx.list[kind][n] = .{ .cx = cx, .cy = cy, .bounds = bounds };
                    n += 1;
                }
            }
        }
        ctx.counts[kind] = @intCast(n);
    }
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
    const chunk_x = @divFloor(i_wx, dw.CHUNK_SIZE);
    const chunk_y = @divFloor(i_wy, dw.CHUNK_SIZE);

    const ctx = &chunk_ctx[chunkCtxIndex(chunk_x, chunk_y)];
    if (!(ctx.occupied and ctx.chunk_x == chunk_x and ctx.chunk_y == chunk_y and
        @reduce(.And, ctx.seed == struct_seed)))
    {
        buildChunkCandidates(ctx, chunk_x, chunk_y, struct_seed);
    }

    inline for (0..structures.len) |kind| {
        for (ctx.list[kind][0..ctx.counts[kind]]) |candidate| {
            if (!candidate.bounds.contains(i_wx, i_wy)) continue;
            if (generateFrom(
                kind,
                candidate,
                starting_sprite,
                wx,
                wy,
                struct_seed,
            )) |result| {
                return result;
            }
        }
    }
    return .{ .id = starting_sprite };
}

const testing = std.testing;

/// Reference implementation of `addStructures()`: resolves the covering candidate from scratch for every single block.
/// Exists only to validate prepass for testing (see below).
fn addStructuresPerBlock(starting_sprite: Sprite, wx: u32, wy: u32, struct_seed: Vec2u) StructureResult {
    const i_wx = @as(i32, @bitCast(wx));
    const i_wy = @as(i32, @bitCast(wy));

    inline for (0..structures.len) |kind| {
        const area = @as(i32, @intCast(Configs[kind].spawn_area));
        const xs = cellRange(area, @intCast(Configs[kind].max_w), i_wx, i_wx);
        const ys = cellRange(area, @intCast(Configs[kind].max_h), i_wy, i_wy);

        var cy = ys.lo;
        while (cy <= ys.hi) : (cy += 1) {
            var cx = xs.lo;
            while (cx <= xs.hi) : (cx += 1) {
                if (acceptedBounds(kind, cx, cy, struct_seed)) |bounds| {
                    if (!bounds.contains(i_wx, i_wy)) continue;
                    const candidate: Candidate = .{ .cx = cx, .cy = cy, .bounds = bounds };
                    if (generateFrom(
                        kind,
                        candidate,
                        starting_sprite,
                        wx,
                        wy,
                        struct_seed,
                    )) |result| {
                        return result;
                    }
                }
            }
        }
    }
    return .{ .id = starting_sprite };
}

test "the per-chunk candidate prepass agrees with a per-block scan, block for block" {
    const memory = dw.memory;
    memory.game.seed = .{};
    var rng = dw.seeding.ChaCha12.init(&dw.seeding.mixBaseSeed(memory.game.seed, .seed2_init));
    for (&memory.game.seed2) |*v| v.* = rng.next();

    const struct_seed = memory.game.getHashSeed(.structures);

    // Spans many chunks in both axes, so candidates that overhang a chunk border are exercised on both sides.
    var wy: u32 = 0;
    while (wy < 320) : (wy += 1) {
        var wx: u32 = 0;
        while (wx < 320) : (wx += 1) {
            const fast = addStructures(.stone, wx, wy, struct_seed);
            const reference = addStructuresPerBlock(.stone, wx, wy, struct_seed);
            try testing.expectEqual(reference, fast);
        }
    }
}
