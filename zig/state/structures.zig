//! Handles structure generation logic and compile-time machinations for structures.
//!
//! A placement is resolved in four fixed stages, and every structure opts into the ones it needs:
//! - ROLL: `target_chance` decides whether the cell even attempts a placement.
//! - ANCHOR: `getBounds()` picks the box, or the default jitter does it when the size is fixed.
//! - SEAT: `seat` slides the box down onto the terrain surface (optional).
//! - GATE: `constraints` accept or reject the finished box (optional).
//!
//! Stages 2-4 are retried together up to `attempts` times before the cell gives up.
//!
//! Required declarations:
//! - `spawn_area`: power of two, and >= `max_w`/`max_h` plus any `seat.max_drop`
//! - `max_w` / `max_h`: the FOOTPRINT size (seating depth is added automatically, so never add it here)
//! - `target_chance`: see the warning below
//! - `generate()`: the sprite for one block of the footprint, derived from the passed `bounds`
//!
//! Optional declarations:
//! - `getBounds()`: only when the box is not a plain `max_w`-by-`max_h` rectangle (say a rolled size).
//!   Omit it and the default jitter is used, which is what nearly every structure wants!
//! - `seat`: stands the structure on the ground; see `Seat`
//! - `constraints`: terrain rules over the footprint (comptime-sorted cheapest first)
//! - `attempts`: placements to try in a cell before giving up (default 1)
//! - `overlaps_self`: lets two placements of THIS kind overlap; see `hasSelfOverlap()`
//!
//! `target_chance` is a ROLL, not a density: seating and terrain rules throw most rolls away.
//! it's also sadly not possible to guess the odds of terrain rules throwing odds...only approximate with auditing.
//!
//! Small things that need no priority collision belong in `decorations.zig` instead, which is far cheaper:
//! every structure here costs structure below a collision scan so it's not great to stuff too much here.
//! A placement is anchored uniformly ANYWHERE in its `spawn_area` cell and may overhang into the neighboring cells.
//!
//! A rule that has to MOVE the box rather than merely judge it cannot be a `Constraint`,
//! because constraints are pure predicates over a box that is already final.
//! Standing on the ground is the common case of that, which is what `Seat` exists for.
//! `getBounds()` remains the escape hatch for anything else,
//! and rejecting there lets an expensive scan bail before the box is even complete.
//!
//! See `structures/Example.zig` for a heavily commented walkthrough of all of the above.
const std = @import("std");
const dw = @import("../root.zig");

const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;

/// A struct list of all structures ordered by spawning priority.
pub const structures = .{
    @import("structures/Tree.zig"),
    @import("structures/BasicRect.zig"),
    @import("structures/Ancient.zig"),
    @import("structures/Ancient2.zig"),
    @import("structures/Geode.zig"),
    @import("structures/Pillar.zig"),
    @import("structures/Portal.zig"),
    @import("structures/Chamber.zig"),
};

/// ASCII-art layout tables for fixed-shape structures; see `structures/template.zig`.
pub const template = @import("template.zig");
pub const Template = template.Template;

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
/// If `base` is `.none`, then `base_id` falls back to the natural terrain it replaced automatically.
pub const StructureResult = struct {
    id: Sprite,
    base: Sprite = .none,
    /// Starting water volume (0-15) for a waterloggable `id` placed inside a pool.
    /// A structure that puts a dry waterloggable block (like chests) in a row it also fills with water MUST set this to `Block.MAX_HP`,
    /// or the sim floods the cell on the chunk's first tick (wasting modification storage, basically).
    water_volume: u4 = 0,
};

/// Anchors one edge of a `Region` to the candidate's bounding box.
pub const Edge = struct {
    /// `start` is the box's left/top edge, `end` is its right/bottom edge (exclusive)
    at: enum { start, end } = .start,
    /// Determines whether this region shifts outward (negative) or inward (positive).
    off: i32 = 0,

    /// Resolves this edge against a candidate's bounds on one axis.
    pub inline fn resolve(self: Edge, start: i32, end: i32) i32 {
        return (if (self.at == .start) start else end) + self.off;
    }
};

/// A half-open box relative to the candidate's bounds; defaults to exactly the footprint.
/// The row directly below the box, for instance, is `.{ .y0 = .{ .at = .end }, .y1 = .{ .at = .end, .off = 1 } }`.
pub const Region = struct {
    /// Left edge, inclusive.
    x0: Edge = .{ .at = .start },
    /// Right edge, EXCLUSIVE: `.{ .at = .end }` is the first column past the footprint, not its last column.
    x1: Edge = .{ .at = .end },
    /// Top edge, inclusive.
    y0: Edge = .{ .at = .start },
    /// Bottom edge, EXCLUSIVE: `.{ .at = .end }` is the first row past the footprint, not its last row.
    y1: Edge = .{ .at = .end },

    /// Resolves all four edges against a candidate's bounds at once.
    pub inline fn resolve(self: Region, bounds: Rect) Rect {
        return .{
            .x_start = self.x0.resolve(bounds.x_start, bounds.x_end),
            .x_end = self.x1.resolve(bounds.x_start, bounds.x_end),
            .y_start = self.y0.resolve(bounds.y_start, bounds.y_end),
            .y_end = self.y1.resolve(bounds.y_start, bounds.y_end),
        };
    }
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
    /// Leftmost column profiled, inclusive.
    x0: Edge = .{ .at = .start },
    /// One past the rightmost column profiled, EXCLUSIVE.
    x1: Edge = .{ .at = .end },
    /// Row the ground is expected at; typically the first row below the box (`.{ .at = .end }`).
    row: Edge = .{ .at = .end },
    /// How many rows apart the highest and lowest surviving surfaces may be.
    /// 0 demands perfectly flat ground; raising it tolerates a gentle grade under the footprint.
    max_slope: i32 = 2,
    /// How far ABOVE `row` a column's surface may sit before that column fails.
    /// Ground this high means the structure digs into a rise, which reads fine, so this can be generous.
    max_rise: i32 = 3,
    /// How far BELOW `row` a column's surface may sit before that column fails.
    /// Ground this low leaves a visible gap under the structure so it appears to float:
    /// keep at 0 unless the structure has something to stand on.
    max_drop: i32 = 0,
};

/// Stands a structure on the ground: profiles the terrain under the jittered box and slides the box DOWN,
/// until its bottom row rests on the surface. Declared as a structure's `seat`.
///
/// This cannot be a `Constraint`, with an important distinction:
/// a constraint is a pure PREDICATE over a box that is already final,
/// while seating is a TRANSFORM that computes where the box belongs.
/// `checkConstraint()` returns a bool and has no way to move anything.
///
/// Because seating only ever moves the box DOWN, the anchor can never leave its own cell.
/// `max_drop` is added to the structure's `max_h` automatically when building `Configs`,
/// so a structure declares only its footprint height and never has to remember to include the slide.
pub const Seat = struct {
    /// How far DOWN the box may slide to meet the ground, in blocks.
    /// A candidate whose terrain surface is not within this reach is rejected outright.
    /// This is the single knob that trades placement frequency against how far a structure may sink.
    max_drop: i32,
    /// How many rows apart the profiled columns' surfaces may be. 0 demands perfectly flat ground.
    ///
    /// The box seats on the LOWEST surface found, never the highest, so a tolerated slope makes terrain
    /// intrude into the footprint (which the structure carves out, and which reads fine) rather than
    /// leaving a gap underneath (which makes the structure appear to float).
    max_slope: i32 = 0,
    /// Leftmost column profiled, inclusive. Defaults to the footprint's left edge.
    x0: Edge = .{ .at = .start },
    /// One past the rightmost column profiled, EXCLUSIVE. Defaults to the footprint's right edge.
    /// Narrow this when only part of the footprint needs ground, such as a structure with overhanging eaves.
    x1: Edge = .{ .at = .end },
};

/// Requires a structure to be walled in by solid terrain, to a tunable degree, whatever its SHAPE.
///
/// The problem this solves: "surrounded by rock" is easy for a rectangle and awkward for anything else.
/// A bounding box around a circle tests the wrong blocks (its corners are far outside the disc),
/// and hand-writing a halo per shape does not scale as structures are added.
///
/// So the structure hands over its own shape and the halo is derived from it:
/// - walk the region (by default the footprint grown one block on every side)
/// - a block the shape does NOT occupy but which touches one it DOES is a halo block
/// - count the halo blocks that are open (non-solid); the OPEN FRACTION must fall in `[min_open, max_open]`
///
/// The fraction is a band, not a ceiling, which is what lets a structure be DELIBERATELY breached:
/// a geode wants to be mostly buried yet never perfectly sealed, so a player can spot it (see `Geode.zig`).
///
/// `covers()` is the same shape predicate `generate()` already implements, so declaring it is usually just
/// factoring out a test that exists anyway.
pub const Encase = struct {
    /// Shape test in ABSOLUTE world blocks, so it can be called for halo blocks outside the footprint.
    /// Must agree with `generate()` about which blocks the structure occupies, or the halo tests the wrong ring.
    covers: *const fn (wx: i32, wy: i32, bounds: Rect) bool,
    /// Least fraction of the halo that must be OPEN. 0 permits a perfect seal.
    /// Above 0 it REQUIRES a breach, so the structure only spawns where it pokes out of the rock.
    min_open: f32 = 0,
    /// Most of the halo that may be open before the structure reads as "floating in a cave" and is rejected.
    /// 1 permits any amount of exposure.
    max_open: f32 = 0,

    /// Area searched for halo blocks. The default grows the footprint by one on every side,
    /// which is exactly the ring a footprint-sized shape can touch.
    region: Region = .{
        .x0 = .{ .at = .start, .off = -1 },
        .x1 = .{ .at = .end, .off = 1 },
        .y0 = .{ .at = .start, .off = -1 },
        .y1 = .{ .at = .end, .off = 1 },
    },
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
    /// The structure must be walled in by solid terrain to a tunable degree; see `Encase`.
    encase: Encase,
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
/// a seating scan reaches rows below it, and `isBeaten()` resolves the candidate in (`cx - 1`, `cy - 1`).
///
/// Bounds being `i32` easily traps what would otherwise be an integer overflow (a bit hacky).
pub fn baseSolid(wx: i32, wy: i32) bool {
    if (wx < 0 or wy < 0 or wx > MAX_WORLD_BLOCK or wy > MAX_WORLD_BLOCK) return false;

    const uwx: u32 = @bitCast(wx);
    const uwy: u32 = @bitCast(wy);
    return dw.procedural.getBaseSprite(
        uwx / dw.CHUNK_SIZE,
        uwy / dw.CHUNK_SIZE,
        @intCast(uwx % dw.CHUNK_SIZE),
        @intCast(uwy % dw.CHUNK_SIZE),
    ).isFoundation();
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
    var above_solid = probeSolid(probe(wx, y_from - 1));
    var y = y_from;
    while (y <= y_to) : (y += 1) {
        const solid = probeSolid(probe(wx, y));
        if (solid and !above_solid) return y;
        above_solid = solid;
    }
    return null;
}

/// Anchors a `w`-by-`h` footprint uniformly anywhere in the grid cell (`cx`, `cy`), overhang included.
/// Every structure's `getBounds()` should route through this: an origin drawn from `[0, spawn_area - w)`
/// instead would blank out a band along each cell edge and make the spawn lattice visible.
pub fn jitter(state: *HashState, cx: i32, cy: i32, area: u32, w: i32, h: i32) Rect {
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

/// Reads one terrain probe's answer as "this block is a foundation".
/// A probe answers with a `Sprite` or with a `bool`, and every rule has to accept both.
inline fn probeSolid(sample: anytype) bool {
    return if (@TypeOf(sample) == bool) sample else sample.isFoundation();
}

/// Reads one terrain probe's answer as "this block is strictly air or a liquid".
inline fn probeEmpty(sample: anytype) bool {
    return if (@TypeOf(sample) == bool) !sample else (sample == .none or sample.isEmpty());
}

/// Tests every block of `rect` and fails on the first block `accepts` rejects.
inline fn everyBlock(comptime probe: anytype, comptime accepts: anytype, rect: Rect) bool {
    var y = rect.y_start;
    while (y < rect.y_end) : (y += 1) {
        var x = rect.x_start;
        while (x < rect.x_end) : (x += 1) {
            if (!accepts(probe(x, y))) return false;
        }
    }
    return true;
}

/// Runs one terrain rule against a candidate's bounds.
inline fn checkConstraint(comptime probe: anytype, comptime c: Constraint, bounds: Rect) bool {
    switch (c) {
        .solid => |region| return everyBlock(probe, probeSolid, region.resolve(bounds)),
        .empty => |region| return everyBlock(probe, probeEmpty, region.resolve(bounds)),

        .level => |lv| {
            const x0 = lv.x0.resolve(bounds.x_start, bounds.x_end);
            const x1 = lv.x1.resolve(bounds.x_start, bounds.x_end);
            const row = lv.row.resolve(bounds.y_start, bounds.y_end);

            var highest: i32 = std.math.maxInt(i32);
            var lowest: i32 = std.math.minInt(i32);
            var x = x0;
            while (x < x1) : (x += 1) {
                const surface = surfaceYWith(
                    probe,
                    x,
                    row - lv.max_rise,
                    row + lv.max_drop,
                ) orelse return false;
                highest = @min(highest, surface);
                lowest = @max(lowest, surface);
                if (lowest - highest > lv.max_slope) return false;
            }
            return true;
        },
        .encase => |en| {
            const area = en.region.resolve(bounds);

            var open: u32 = 0;
            var total: u32 = 0;
            var y = area.y_start;
            while (y < area.y_end) : (y += 1) {
                // A row slides a three-wide window along, so each column's shape test is done once
                // instead of once for itself and twice more as its neighbors' left and right taps.
                var left = en.covers(area.x_start - 1, y, bounds);
                var here = en.covers(area.x_start, y, bounds);
                var x = area.x_start;
                while (x < area.x_end) : (x += 1) {
                    const right = en.covers(x + 1, y, bounds);
                    defer {
                        left = here;
                        here = right;
                    }

                    // Blocks the structure occupies are its own business; only the ring around it is tested.
                    if (here) continue;
                    const touches_shape = left or right or
                        en.covers(x, y - 1, bounds) or en.covers(x, y + 1, bounds);
                    if (!touches_shape) continue;
                    total += 1;
                    if (probeEmpty(probe(x, y))) open += 1;
                }
            }
            if (total == 0) return en.min_open == 0; // no halo at all counts as fully sealed
            const frac = @as(f32, @floatFromInt(open)) / @as(f32, @floatFromInt(total));
            return frac >= en.min_open and frac <= en.max_open;
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
        // Walks the full region calling covers() up to 5x per block, so it is pricey for filled shapes:
        // the interior is rescanned to find the boundary. Weight it well above a plain span scan.
        .encase => |en| @intCast(spanOf(en.region.x0, en.region.x1, w) *
            spanOf(en.region.y0, en.region.y1, h) * 5),
        .custom => std.math.maxInt(usize), // opaque, so assume the worst and run it last
    };
}

/// Rejects a rule whose own numbers cannot describe a box, before it ever runs.
///
/// `Level` in particular feeds `surfaceYWith()`, which asserts its window is not inverted.
/// A negative reach there would only show up as a Debug-only assert on the one candidate that hits it.
fn validateConstraint(comptime c: Constraint) void {
    switch (c) {
        .solid, .empty, .custom => {},
        .level => |lv| {
            if (lv.max_rise < 0 or lv.max_drop < 0)
                @compileError("A level rule's max_rise/max_drop are reaches, so neither may be negative.");
            if (lv.max_slope < 0)
                @compileError("A level rule's max_slope is a height difference, so it may not be negative.");
        },
        .encase => |en| {
            if (en.min_open < 0 or en.max_open > 1)
                @compileError("An encase rule's open fractions must be normalized in [0, 1].");
            if (en.min_open > en.max_open)
                @compileError("An encase rule's open band is inverted, so no halo can ever satisfy it.");
        },
    }
}

/// Sorts a structure constraint list cheapest-first. Shared with `decorations.zig`.
pub fn sortConstraints(comptime list: []const Constraint, comptime w: i32, comptime h: i32) []const Constraint {
    comptime {
        @setEvalBranchQuota(1e6);
        for (list) |c| validateConstraint(c);
        var sorted: [list.len]Constraint = list[0..list.len].*;
        // basic insertion sort
        if (sorted.len >= 2) {
            for (1..sorted.len) |a| {
                var j = a;
                while (j > 0 and constraintCost(sorted[j - 1], w, h) > constraintCost(sorted[j], w, h)) : (j -= 1) {
                    std.mem.swap(Constraint, &sorted[j - 1], &sorted[j]);
                }
            }
        }
        const frozen = sorted;
        return &frozen;
    }
}

/// Slides `bounds` down onto the terrain surface per `s`, or returns null when the ground cannot hold it.
///
/// The reference row is the one directly BELOW the box (`y_end` is exclusive),
/// which is what makes a structure stand ON the ground instead of sinking into it:
/// seating so the box's own last row coincided with the surface would bury that row a block deep.
///
/// Costs `(x1 - x0) * (max_drop + 2)` terrain samples in the worst-case,
/// but a candidate over unsuitable ground normally dies on its first or second column.
fn seatBounds(comptime s: Seat, bounds: Rect) ?Rect {
    const line = bounds.y_end;
    const x0 = s.x0.resolve(bounds.x_start, bounds.x_end);
    const x1 = s.x1.resolve(bounds.x_start, bounds.x_end);

    var highest: i32 = std.math.maxInt(i32);
    var lowest: i32 = std.math.minInt(i32);
    var x = x0;
    while (x < x1) : (x += 1) {
        // A column with no surface in reach is either open air or solid rock all the way down.
        // Either way the box has nothing to rest on, so the whole candidate is rejected.
        const surface = surfaceY(x, line, line + s.max_drop) orelse return null;
        highest = @min(highest, surface);
        lowest = @max(lowest, surface);
        if (lowest - highest > s.max_slope) return null;
    }

    // Seat on the lowest surface so no column is left floating; see `Seat.max_slope`.
    const drop = lowest - line;
    return .{
        .x_start = bounds.x_start,
        .y_start = bounds.y_start + drop,
        .x_end = bounds.x_end,
        .y_end = bounds.y_end + drop,
    };
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
        // Vertical REACH, not footprint height: a seated structure may sit up to `max_drop` rows below its anchor,
        // and every scan that asks "which candidate could cover this block?" has to see that far.
        const seat_drop: u32 = if (@hasDecl(S, "seat")) @intCast(S.seat.max_drop) else 0;
        confs[i] = .{
            .spawn_area = S.spawn_area,
            .max_w = S.max_w,
            .max_h = S.max_h + seat_drop,
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
            @compileError(@typeName(structures[i]) ++ ": max_w/max_h (plus any seat.max_drop) must not exceed spawn_area, or a structure could overhang past the neighboring cell.");
        if (@hasDecl(structures[i], "seat") and structures[i].seat.max_drop < 0)
            @compileError(@typeName(structures[i]) ++ ": seat.max_drop must not be negative; seating only ever moves a box down.");
        if (@hasDecl(structures[i], "seat") and structures[i].seat.max_slope < 0)
            @compileError(@typeName(structures[i]) ++ ": seat.max_slope must not be negative.");
    }
}

/// One memoized structure grid cell: the placement that stands there (terrain rules already applied) and,
/// lazily, whether an overlapping candidate outranks it.
/// Keyed by (`cx`, `cy`, `seed`); `blocked` stays null until first computed for that cell.
const StructCacheEntry = struct {
    cx: i32 = 0,
    cy: i32 = 0,
    seed: Vec2u = .{ 0, 0 },
    /// Terrain identity the placement was gated against (`procedural.terrainGeneration()`).
    /// The structure seed alone cannot see a debug slider moving the ground a placement stands on.
    generation: u64 = 0,
    bounds: ?Rect = null,
    blocked: ?bool = null,
    occupied: bool = false,
};

/// Grid-cell window one full sweep of a bank covers (see `dw.utils.tileIndex()`).
/// A cell is `spawn_area` blocks wide,
/// so even the smallest kind's tile spans far more world than one generation pass touches.
const STRUCT_CACHE_TILE = 32;
/// Direct-mapped bounds/blocked cache, one bank per structure kind (a power of two by construction).
/// A structure's bounds and verdicts are identical for every footprint cell and re-derived by later structures' priority scans,
///
/// so memoizing per grid cell collapses that repeated hashing (and all terrain sampling) to O(1).
/// Pure function of (cell, seed): the per-entry seed check self-invalidates on reseed, so no explicit clear.
/// The `i32` cx/cy size is okay because it's at base depth!
const STRUCT_CACHE_SLOTS = STRUCT_CACHE_TILE * STRUCT_CACHE_TILE;
var struct_cache: [structures.len][STRUCT_CACHE_SLOTS]StructCacheEntry = @splat(@splat(.{}));

/// Returns the (populated) cache entry for structure `kind` at grid cell (`cx`, `cy`), computing bounds on miss.
fn structCacheSlot(comptime kind: usize, cx: i32, cy: i32, struct_seed: Vec2u) *StructCacheEntry {
    const generation = dw.procedural.terrainGeneration();
    const e = &struct_cache[kind][dw.utils.tileIndex(STRUCT_CACHE_TILE, STRUCT_CACHE_TILE, cx, cy)];
    if (!(e.occupied and e.cx == cx and e.cy == cy and
        e.generation == generation and @reduce(.And, e.seed == struct_seed)))
    {
        e.* = .{
            .cx = cx,
            .cy = cy,
            .seed = struct_seed,
            .generation = generation,
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
pub fn getStructureBounds(comptime kind: usize, cx: i32, cy: i32, struct_seed: Vec2u) ?Rect {
    return structCacheSlot(kind, cx, cy, struct_seed).bounds;
}

/// How far a cell's placement got, in order. The whole point of the enum is `audit.zig`'s funnel:
/// counting how many cells die at each stage turns "why is this so rare?" into a number per stage.
/// - `rejected`: the `target_chance` roll failed; the cell never even tried.
/// - `anchored`: a box was placed, but seating (if any) then failed on every attempt.
/// - `seated`: a box seated, but a constraint rejected it on every attempt.
/// - `placed`: a box passed every stage. This is the returned bounds.
/// A cell is judged at the FURTHEST stage any of its attempts reached.
pub const Stage = enum { rejected, anchored, seated, placed };

/// A resolved cell: the box that would stand there (or null), and how far it got for the funnel.
pub const CellResolution = struct { bounds: ?Rect, reached: Stage };

/// The full ROLL -> ANCHOR -> SEAT -> GATE pipeline for one cell, uncached and side-effect-free.
/// Backs both `computeStructureBounds()` (which keeps only `bounds`) and `audit.zig` (which keeps `reached`).
fn resolveCell(comptime kind: usize, cx: i32, cy: i32, struct_seed: Vec2u) CellResolution {
    @setEvalBranchQuota(20000); // `getChance()` comptime-searches for a rational approximation of the odds
    const S = structures[kind];
    var state = makeStructureHash(
        struct_seed,
        cellOriginX(kind, cx),
        cellOriginY(kind, cy),
        S.spawn_area,
        kind,
    );
    if (!state.getChance(S.target_chance)) return .{ .bounds = null, .reached = .rejected };

    var reached: Stage = .anchored; // passing the roll guarantees at least one anchor below

    // Each attempt draws fresh jitter from the same stream,
    // so a gated kind gets several shots at a valid spot in its cell instead of one.
    // generate() reads an INDEPENDENT stream, so it neither knows nor cares how many draws were burned here.
    //
    // A runtime loop on purpose: the body does not use the index, and every comptime branch inside resolves
    // the same way each pass, so `inline for` would only unroll identical code `attempts` times (30x for the
    // portal), bloating codegen for nothing.
    for (0..Configs[kind].attempts) |_| {
        // ANCHOR: a structure only writes getBounds() when its box is not a plain max_w-by-max_h rect.
        const anchored: ?Rect = if (@hasDecl(S, "getBounds"))
            S.getBounds(&state, cx, cy)
        else
            jitter(&state, cx, cy, S.spawn_area, S.max_w, S.max_h);

        if (anchored) |raw| {
            // SEAT, then GATE. Seating runs first because a constraint judges the FINAL box,
            // and an unseated box is not final: gating before the slide would test the wrong rows entirely.
            const seated: ?Rect = if (@hasDecl(S, "seat")) seatBounds(S.seat, raw) else raw;
            if (seated) |bounds| {
                if (@intFromEnum(Stage.seated) > @intFromEnum(reached)) reached = .seated;
                if (satisfies(baseSolid, constraint_table[kind], bounds)) {
                    return .{ .bounds = bounds, .reached = .placed };
                }
            }
        }
    }
    return .{ .bounds = null, .reached = reached };
}

/// Uncached resolution backing the cache. Call `getStructureBounds()` instead elsewhere.
fn computeStructureBounds(comptime kind: usize, cx: i32, cy: i32, struct_seed: Vec2u) ?Rect {
    return resolveCell(kind, cx, cy, struct_seed).bounds;
}

/// `resolveCell()` for `debug/audit.zig`'s funnel, which needs the stage rather than a cached box.
pub fn resolveCellForAudit(comptime kind: usize, cx: i32, cy: i32, struct_seed: Vec2u) CellResolution {
    return resolveCell(kind, cx, cy, struct_seed);
}

inline fn cellOriginX(comptime kind: usize, cx: i32) u32 {
    return @bitCast(cx * @as(i32, @intCast(structures[kind].spawn_area)));
}

inline fn cellOriginY(comptime kind: usize, cy: i32) u32 {
    return @bitCast(cy * @as(i32, @intCast(structures[kind].spawn_area)));
}

/// Creates a `HashState` given a seed, (base depth) coordinates,
/// and power-of-two area where a structure may appear within.
pub fn makeStructureHash(
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
pub fn makeBlockHash(
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
fn cellRank(comptime kind: usize, cx: i32, cy: i32, struct_seed: Vec2u) u64 {
    var state = makeStructureHash(
        struct_seed,
        cellOriginX(kind, cx),
        cellOriginY(kind, cy),
        structures[kind].spawn_area,
        kind + 2 * structures.len,
    );
    return state.getRaw();
}

/// Whether a kind lets two of its OWN placements overlap instead of settling them by rank.
///
/// Off by default, and it must stay off for anything shaped: two overlapping trees interleave into one unreadable blob.
/// Exists for a REGION-like kind (see `structures/Deposit.zig`), where every placement in a neighborhood draws the same material,
/// so two overlapping blobs are indistinguishable from one larger one!
///
/// This only relaxes the SAME-kind rule; every other kind still outranks it exactly as before.
inline fn hasSelfOverlap(comptime kind: usize) bool {
    const S = structures[kind];
    return @hasDecl(S, "overlaps_self") and S.overlaps_self;
}

/// Whether an overlapping placement outranks this one.
///
/// Collapses what used to be two separate rules into one scan, because both ask the same question:
/// - a higher-priority KIND always wins (that ordering is the point of the tuple)
/// - two placements of the SAME kind (which overhang makes possible) are settled by `cellRank()`,
///   unless the kind opted out through `hasSelfOverlap()`
fn isBeaten(comptime kind: usize, cx: i32, cy: i32, bounds: Rect, struct_seed: Vec2u) bool {
    // (inlining this has been tested to improve perf;
    // also comptime kind forces multiple function signatures anyway)
    const allows_self = comptime hasSelfOverlap(kind);
    const my_rank = if (allows_self) 0 else cellRank(kind, cx, cy, struct_seed);

    inline for (0..kind + 1) |other| {
        // comptime-known both ways, so a kind that opted out never emits the scan at all!
        if (other == kind and allows_self) continue;
        const area = @as(i32, @intCast(Configs[other].spawn_area));
        const xs = cellRange(
            area,
            @intCast(Configs[other].max_w),
            bounds.x_start,
            bounds.x_end - 1,
        );
        const ys = cellRange(
            area,
            @intCast(Configs[other].max_h),
            bounds.y_start,
            bounds.y_end - 1,
        );

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
fn acceptedBounds(comptime kind: usize, cx: i32, cy: i32, struct_seed: Vec2u) ?Rect {
    const slot = structCacheSlot(kind, cx, cy, struct_seed);
    const bounds = slot.bounds orelse return null;
    // The settled case is the common one and it reads the slot exactly once.
    if (slot.blocked) |blocked| return if (blocked) null else bounds;

    const verdict = isBeaten(kind, cx, cy, bounds, struct_seed);
    // `slot` is stale past this point, so the verdict is written through a fresh lookup.
    structCacheSlot(kind, cx, cy, struct_seed).blocked = verdict;
    return if (verdict) null else bounds;
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
fn generateFrom(
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

comptime {
    // `ChunkCandidates.counts` is a u8 per kind, so a wider bound would wrap instead of overflowing loudly.
    if (MAX_CHUNK_CANDIDATES > std.math.maxInt(u8))
        @compileError("A kind can reach one chunk from more cells than ChunkCandidates.counts can hold.");
}

/// Every candidate that can claim a block of one chunk, resolved once for the whole chunk.
const ChunkCandidates = struct {
    chunk_x: i32 = 0,
    chunk_y: i32 = 0,
    seed: Vec2u = .{ 0, 0 },
    /// Terrain identity these candidates were accepted under; see `StructCacheEntry.generation`.
    generation: u64 = 0,
    occupied: bool = false,
    counts: [structures.len]u8 = @splat(0),
    /// Per kind, in the same (cy, cx) cell order the per-block scan used to walk, so the first candidate
    /// containing a block is still the one that wins.
    list: [structures.len][MAX_CHUNK_CANDIDATES]Candidate = undefined,
};

/// Covers one full `SimBuffer` sweep.
/// Tiled into 9 distinct slots per 3x3 neighborhood to prevent 64-slot hash thrashing during edge-halo walks.
/// Sized 1 row wide by 4 rows tall so bulk left-to-right passes retain all required neighbor chunks.
const CHUNK_CTX_TILE_W = dw.world.SIM_BUFFER_WIDTH;
const CHUNK_CTX_TILE_H = 4;
const CHUNK_CTX_SLOTS = CHUNK_CTX_TILE_W * CHUNK_CTX_TILE_H;
var chunk_ctx: [CHUNK_CTX_SLOTS]ChunkCandidates = @splat(.{});

comptime {
    // The 3x3 guarantee above: three consecutive rows/columns must land in three distinct slots.
    if (CHUNK_CTX_TILE_W < 3 or CHUNK_CTX_TILE_H < 3) @compileError("Context tile must span a chunk's whole 3x3 neighborhood.");
}

inline fn chunkCtxIndex(chunk_x: i32, chunk_y: i32) usize {
    return dw.utils.tileIndex(CHUNK_CTX_TILE_W, CHUNK_CTX_TILE_H, chunk_x, chunk_y);
}

/// Resolves every kind's candidates for one chunk. Safe to hold `ctx` across: nothing reachable from here
/// re-enters this cache (terrain sampling reads BASE terrain, which is upstream of structures).
fn buildChunkCandidates(ctx: *ChunkCandidates, chunk_x: i32, chunk_y: i32, struct_seed: Vec2u) void {
    ctx.chunk_x = chunk_x;
    ctx.chunk_y = chunk_y;
    ctx.seed = struct_seed;
    ctx.generation = dw.procedural.terrainGeneration();
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
        const xs = cellRange(
            area,
            @intCast(Configs[kind].max_w),
            x0,
            x0 + dw.CHUNK_SIZE - 1,
        );
        const ys = cellRange(
            area,
            @intCast(Configs[kind].max_h),
            y0,
            y0 + dw.CHUNK_SIZE - 1,
        );

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
        ctx.generation == dw.procedural.terrainGeneration() and
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
