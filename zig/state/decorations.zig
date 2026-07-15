//! All decoration placement, in one priority order.
//! - a POINT decoration has a fixed `size_x`-by-`size_y` footprint growing right and down from its anchor
//! - a COLUMN feature is a variable-length chain hanging off a surface (`Vine`)
//!
//! Anything with a real footprint, a priority collision, or a region-wide terrain gate belongs in `structures.zig`.
const std = @import("std");
const dw = @import("../root.zig");
const structures = @import("structures.zig");

const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;
const Chunk = dw.memory.Chunk;
const Rect = structures.Rect;
const Constraint = structures.Constraint;
const CHUNK_SIZE = dw.CHUNK_SIZE;

pub const Vine = @import("decorations/Vine.zig");

/// Column features, stamped before any point decoration.
pub const columns = .{Vine.feature};

/// Point decorations in priority order; the first to claim a block wins it.
/// Taller/wider kinds go first, so ground clutter cannot steal a cell out from under a multi-block footprint.
pub const points = .{
    @import("decorations/Plant.zig"),
    @import("decorations/Shrub.zig"),
    FloorDecor(.bush, 0.030),
    FloorDecor(.rock, 0.030),
    FloorDecor(.small_tree, 0.013),
    FloorDecor(.mushroom, 0.020),
    FloorDecor(.campfire, 0.005),
    FloorDecor(.forest_furnace, 0.006),
    FloorDecor(.lava_furnace, 0.004),
    FloorDecor(.basic_core, 0.012),
    CeilingDecor(.ceiling_flower, 0.15),
};

/// A 1x1 decoration standing on the ground: very common!
pub fn FloorDecor(comptime sprite: Sprite, comptime odds: f64) type {
    return struct {
        pub const name = @tagName(sprite);
        pub const size_x: i32 = 1;
        pub const size_y: i32 = 1;
        pub const chance: f64 = odds;
        pub const constraints = [_]Constraint{
            .{ .solid = .{ .y0 = .{ .at = .end }, .y1 = .{ .at = .end, .off = 1 } } },
            .{ .empty = .{} },
        };
        pub fn generate(local_x: i32, local_y: i32, state: *HashState) ?Sprite {
            _ = local_x;
            _ = local_y;
            _ = state;
            return sprite;
        }
    };
}

/// A 1x1 decoration hanging from a ceiling.
pub fn CeilingDecor(comptime sprite: Sprite, comptime odds: f64) type {
    return struct {
        pub const name = @tagName(sprite);
        pub const size_x: i32 = 1;
        pub const size_y: i32 = 1;
        pub const chance: f64 = odds;
        pub const constraints = [_]Constraint{
            .{ .solid = .{ .y0 = .{ .at = .start, .off = -1 }, .y1 = .{ .at = .start } } },
            .{ .empty = .{} },
        };
        pub fn generate(local_x: i32, local_y: i32, state: *HashState) ?Sprite {
            _ = local_x;
            _ = local_y;
            _ = state;
            return sprite;
        }
    };
}

/// The terrain a decoration stands on: the foundation left AFTER structures.
fn foundationSolid(wx: i32, wy: i32) bool {
    if (wx < 0 or wy < 0 or wx > structures.MAX_WORLD_BLOCK or wy > structures.MAX_WORLD_BLOCK) return false;
    return dw.world.sampleBaseFoundation(@bitCast(wx), @bitCast(wy)).isFoundation();
}

/// Each point decoration's `constraints`, sorted cheapest-first.
const constraint_table: [points.len][]const Constraint = blk: {
    var table: [points.len][]const Constraint = @splat(&.{});
    for (points, 0..) |D, i| {
        if (@hasDecl(D, "constraints")) {
            table[i] = structures.sortConstraints(&D.constraints, D.size_x, D.size_y);
        }
    }
    break :blk table;
};

comptime {
    for (points, 0..) |D, i| {
        if (D.size_x < 1 or D.size_y < 1)
            @compileError(@typeName(points[i]) ++ ": a decoration must occupy at least one block.");
    }
}

/// The footprint an anchor at (`ax`, `ay`) would claim.
inline fn footprint(comptime kind: usize, ax: i32, ay: i32) Rect {
    const D = points[kind];
    return .{ .x_start = ax, .y_start = ay, .x_end = ax + D.size_x, .y_end = ay + D.size_y };
}

/// The anchor's private hash stream, keyed on its world position alone.
inline fn anchorState(comptime kind: usize, ax: i32, ay: i32, seed: Vec2u) HashState {
    return structures.makeBlockHash(seed, @bitCast(ax), @bitCast(ay), kind);
}

/// Whether a decoration of `kind` would stand with its anchor at (`ax`, `ay`):
/// it rolled, and the terrain under its footprint accepts it.
/// Says nothing about whether another anchor beats it (see `anchored()`).
fn stands(comptime kind: usize, ax: i32, ay: i32, seed: Vec2u) bool {
    @setEvalBranchQuota(20000); // `getChance()` comptime-searches for a rational approximation of the odds
    var state = anchorState(kind, ax, ay, seed);
    if (!state.getChance(points[kind].chance)) return false;
    return structures.satisfies(foundationSolid, constraint_table[kind], footprint(kind, ax, ay));
}

/// Whether (`ax`, `ay`) is the anchor a decoration of `kind` actually grows from.
///
/// Two anchors of one kind within a footprint of each other would interleave their halves,
/// so the one up and to the left wins.
/// Non-recursive, exactly as `structures.isBeaten()` is: a rival is judged on whether IT would stand,
/// never on whether it is itself beaten. Free for a 1x1 kind, which has no shadow to check.
fn anchored(comptime kind: usize, ax: i32, ay: i32, seed: Vec2u) bool {
    const D = points[kind];
    if (!stands(kind, ax, ay, seed)) return false;

    var dy: i32 = -(D.size_y - 1);
    while (dy <= 0) : (dy += 1) {
        var dx: i32 = -(D.size_x - 1);
        while (dx <= 0) : (dx += 1) {
            if (dx == 0 and dy == 0) continue;
            if (stands(kind, ax + dx, ay + dy, seed)) return false;
        }
    }

    // A multi-cell kind must own its WHOLE footprint or it renders as a fragment.
    // A 1x1 kind cannot fragment, so it skips the scan (priority order already hides it).
    if ((D.size_x > 1 or D.size_y > 1) and beatenByHigher(kind, ax, ay, seed)) return false;
    return true;
}

/// Whether a higher-priority decoration renders over any cell of `kind`'s footprint anchored at (`ax`, `ay`).
///
/// The decoration analogue of `structures.isBeaten()`: an outranked candidate steps aside rather than leave a half-drawn fragment.
/// Bounded, not unbounded-recursive: it consults only strictly-higher kinds,
/// and `anchored()` on those recurses into still-higher kinds only, so the kind index strictly decreases to 0.
fn beatenByHigher(comptime kind: usize, ax: i32, ay: i32, seed: Vec2u) bool {
    if (kind == 0) return false; // nothing outranks the first kind
    const D = points[kind];
    var fy: i32 = 0;
    while (fy < D.size_y) : (fy += 1) {
        var fx: i32 = 0;
        while (fx < D.size_x) : (fx += 1) {
            const cx = ax + fx;
            const cy = ay + fy;
            inline for (0..kind) |hk| {
                const H = points[hk];
                var oy: i32 = 0;
                while (oy < H.size_y) : (oy += 1) {
                    var ox: i32 = 0;
                    while (ox < H.size_x) : (ox += 1) {
                        const hax = cx - ox;
                        const hay = cy - oy;
                        if (!anchored(hk, hax, hay, seed)) continue;
                        var state = anchorState(hk, hax, hay, seed);
                        _ = state.getChance(H.chance); // replay so `generate()` continues the anchor's stream
                        if (H.generate(ox, oy, &state) != null) return true;
                    }
                }
            }
        }
    }
    return false;
}

/// The point decoration at block (`wx`, `wy`), or null if nothing claims it.
///
/// Walks every anchor whose footprint could reach this block, in kind priority order,
/// so a tall plant claims its own base before a bush can.
/// Costs one hash per candidate anchor in the common case, since the roll fails long before any terrain is touched.
pub fn resolve(wx: u32, wy: u32, seed: Vec2u) ?Sprite {
    const bx = @as(i32, @bitCast(wx));
    const by = @as(i32, @bitCast(wy));

    inline for (points, 0..) |D, kind| {
        var oy: i32 = 0;
        while (oy < D.size_y) : (oy += 1) {
            var ox: i32 = 0;
            while (ox < D.size_x) : (ox += 1) {
                const ax = bx - ox;
                const ay = by - oy;
                if (anchored(kind, ax, ay, seed)) {
                    var state = anchorState(kind, ax, ay, seed);
                    _ = state.getChance(D.chance); // replay, so `generate()` continues the anchor's stream
                    if (D.generate(ox, oy, &state)) |sprite| return sprite;
                }
            }
        }
    }
    return null;
}

/// Fills every empty cell of a freshly generated base chunk with its decoration.
///
/// Columns first, then points, and neither ever overwrites an occupied cell.
/// Reads no edge flags: a decoration probes terrain itself, so it neither depends on nor perturbs them,
/// which is what keeps a neighbor's edits from shuffling this chunk's decorations.
pub fn stampChunk(chunk: *Chunk, cx: u64, cy: u64, column_seeds: *const [CHUNK_SIZE]ColumnState) void {
    stampColumns(chunk, cx, cy, column_seeds);

    const seed = dw.memory.game.getHashSeed(.decorations1);
    for (0..CHUNK_SIZE) |block_y| {
        for (0..CHUNK_SIZE) |block_x| {
            const block = &chunk.blocks[block_x + block_y * CHUNK_SIZE];
            if (!block.isEmpty()) continue;

            const wx: u32 = @intCast(cx * CHUNK_SIZE + block_x);
            const wy: u32 = @intCast(cy * CHUNK_SIZE + block_y);
            if (resolve(wx, wy, seed)) |sprite| block.id = sprite;
        }
    }
}

/// Walks each column top-to-bottom, advancing every column feature's state machine one cell at a time.
/// `column_seeds` carries the state entering row 0 from the chunk(s) above, so a chain crosses the border.
fn stampColumns(chunk: *Chunk, cx: u64, cy: u64, column_seeds: *const [CHUNK_SIZE]ColumnState) void {
    for (0..CHUNK_SIZE) |block_x| {
        const wx: u64 = cx * CHUNK_SIZE + block_x;

        inline for (columns, 0..) |feature, i| {
            // one carried state per feature; only `Vine` exists today, so the seeds array is its alone
            var state = if (i == 0) column_seeds[block_x] else ColumnState{};

            for (0..CHUNK_SIZE) |block_y| {
                const block = &chunk.blocks[block_x + block_y * CHUNK_SIZE];
                const wy: u64 = cy * CHUNK_SIZE + block_y;

                if (stepColumn(feature, &state, wx, wy, block.isFoundation()) and block.isEmpty()) {
                    block.id = feature.sprite;
                }
            }
        }
    }
}

/// Which way a chain grows off its anchoring surface. Also fixes the order the column is walked.
pub const GrowDir = enum {
    /// Hangs DOWN from a ceiling (foundation above), such as hanging vines. Columns are walked top -> bottom.
    down,
    /// Rises UP from a floor (foundation below), such as reeds. Columns are walked bottom -> top.
    up,
};

/// A variable-length chain growing off a surface: it anchors with `anchor_odds`,
/// then each further cell continues with `grow_odds` until it misses or hits `max_length`.
pub const ColumnFeature = struct {
    /// Block written into an empty cell the feature claims.
    sprite: Sprite,
    /// Growth direction; also decides traversal order in the caller.
    dir: GrowDir,
    /// Longest run past the anchor, in blocks. Bounds the cross-border scan to this many rows.
    /// Must stay < 2 * CHUNK_SIZE so the scan only ever reaches the two neighbor chunks in that direction.
    max_length: u32,
    /// Odds a surface cell anchors the chain in the cell directly past it.
    anchor_odds: f64,
    /// Odds a live chain extends one more cell.
    grow_odds: f64,
    /// Seeds the anchor and grow rolls, so two features never share a hash.
    anchor_seed: dw.memory.SeedType = .decorations1,
    grow_seed: dw.memory.SeedType = .decorations2,
    /// Mixed into the position hash, so two features with the same seeds still differ.
    salt: u64 = 0,
};

pub fn assertColumnFeature(comptime f: ColumnFeature) void {
    if (f.max_length >= 2 * CHUNK_SIZE)
        @compileError("ColumnFeature.max_length must stay < 2 * CHUNK_SIZE so the cross-border scan reaches at most the two neighbor chunks.");
}

/// Carried state for a column feature's walk down (or up) a single world column.
/// Seeded across the chunk border by `world.computeColumnSeeds()`, then advanced per cell by `stepColumn()`.
pub const ColumnState = struct {
    /// The feature is currently growing and has reached the cell adjacent to the one being evaluated.
    alive: bool = false,
    /// Cells past the anchoring surface so far (1 = directly adjacent to it); capped by `max_length`.
    depth: u32 = 0,
};

/// True if the surface at world (`wx`, `wy`) anchors feature `f` in the cell directly past it.
inline fn columnAnchorHit(comptime f: ColumnFeature, wx: u64, wy: u64) bool {
    const hash = dw.seeding.FastHash.hash2d(dw.memory.game.getHashSeed(f.anchor_seed), wx ^ f.salt, wy);
    return hash <= dw.seeding.oddsNum(f.anchor_odds);
}

/// True if feature `f` extends into the empty cell at world (`wx`, `wy`).
inline fn columnGrowHit(comptime f: ColumnFeature, wx: u64, wy: u64) bool {
    const hash = dw.seeding.FastHash.hash2d(dw.memory.game.getHashSeed(f.grow_seed), wx ^ f.salt, wy);
    return hash <= dw.seeding.oddsNum(f.grow_odds);
}

/// Advances feature `f`'s state machine by one cell while scanning a world column in its growth direction.
/// `is_solid` marks a foundation cell, which acts as an anchoring surface for anything growing past it.
/// Returns true when the feature should occupy this (empty) cell.
pub fn stepColumn(comptime f: ColumnFeature, state: *ColumnState, wx: u64, wy: u64, is_solid: bool) bool {
    comptime assertColumnFeature(f);
    if (is_solid) {
        // this foundation cell anchors any feature growing directly past it
        state.alive = columnAnchorHit(f, wx, wy);
        state.depth = 0;
        return false;
    }
    if (!state.alive) return false;
    state.depth += 1;
    // depth 1 (directly past the surface) is governed solely by the anchor roll
    // deeper cells each roll an independent growth continuation, capped at max_length
    if (state.depth > 1 and (state.depth > f.max_length or !columnGrowHit(f, wx, wy))) {
        state.alive = false;
        return false;
    }
    return true;
}

/// `stands()` for `debug/audit.zig`, which counts anchors rather than sprites.
pub inline fn standsForAudit(comptime kind: usize, ax: i32, ay: i32, seed: Vec2u) bool {
    return stands(kind, ax, ay, seed);
}

/// `anchored()` for `debug/audit.zig`.
pub inline fn anchoredForAudit(comptime kind: usize, ax: i32, ay: i32, seed: Vec2u) bool {
    return anchored(kind, ax, ay, seed);
}

const testing = std.testing;

test "a multi-block decoration owns its whole footprint" {
    const memory = dw.memory;
    memory.game.seed = .{};
    var rng = dw.seeding.ChaCha12.init(&dw.seeding.mixBaseSeed(memory.game.seed, 1));
    for (&memory.game.seed2) |*v| v.* = rng.next();
    const seed = memory.game.getHashSeed(.decorations1);

    var checked: usize = 0;
    inline for (points, 0..) |D, kind| {
        if (D.size_x > 1 or D.size_y > 1) {
            var ay: i32 = 0;
            while (ay < 700) : (ay += 1) {
                var ax: i32 = 0;
                while (ax < 700) : (ax += 1) {
                    if (!anchored(kind, ax, ay, seed)) continue;
                    checked += 1;

                    var oy: i32 = 0;
                    while (oy < D.size_y) : (oy += 1) {
                        var ox: i32 = 0;
                        while (ox < D.size_x) : (ox += 1) {
                            var state = anchorState(kind, ax, ay, seed);
                            _ = state.getChance(D.chance);
                            const mine = D.generate(ox, oy, &state).?;
                            const won = resolve(@bitCast(ax + ox), @bitCast(ay + oy), seed).?;
                            try testing.expectEqual(mine, won);
                        }
                    }
                }
            }
        }
    }
    try testing.expect(checked > 0); // the sweep must actually find some, or it proves nothing
}
