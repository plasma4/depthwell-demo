//! Debug-only sampler for worldgen odds, plus a live-state invariant checker (`verifySimInvariants()`).
//!
//! `target_chance` and terrain rules complicate statistics to the point where empirical/automated brute-forcing is needed.
//! Here we are. This code simply tests a region around the player.
//!
//! Three things get counted:
//! - structures: cells rolled, placements standing on valid terrain, and how many survived a rival
//! - decorations: anchors standing, and how many survived an overlapping anchor
//! - blocks: the sprite mix, which is the `ore odds` question
//!
//! Everything is sampled straight from world coordinates, so it never touches the chunk pipeline or the caches the game is using.
//! Column features (vines) are the one thing MISSING from the block mix:
//! a chain is walked down a column rather than resolved per block, so a single block cannot be asked about in isolation.
const std = @import("std");
const dw = @import("../root.zig");

const logger = dw.logger;
const memory = dw.memory;
const structures = dw.structures;
const decorations = dw.decorations;

const Sprite = dw.Sprite;

/// Blocks per axis sampled by `sampleWorldAroundPlayer()`.
const DEFAULT_SPAN: i32 = 2048;

/// Distinct sprites tracked in the block mix.
const MAX_TRACKED_SPRITES = 64;

/// Runs the audit on a region centered on the player's base-depth position, and logs the result.
/// Depth is ignored: everything here is a property of the base layer the whole fractal descends from.
///
/// Do note that this code WILL run faster in release!
pub fn sampleWorldAroundPlayer() void {
    if (!dw.dev_menu) return;

    const coord = memory.game.getPlayerCoord();
    const edge_margin_chunks: u64 = @intCast(std.math.divCeil(i32, DEFAULT_SPAN, dw.CHUNK_SIZE) catch unreachable);
    const max_suffix = dw.world.max_possible_suffix;
    if (coord.suffix[0] < edge_margin_chunks or coord.suffix[1] < edge_margin_chunks or
        coord.suffix[0] > max_suffix -| edge_margin_chunks or coord.suffix[1] > max_suffix -| edge_margin_chunks)
    {
        logger.quick("This test touches the world boundaries and WILL have skewed values.");
    }
    const center_x: i32 = @intCast(@min(coord.suffix[0] *| dw.CHUNK_SIZE, std.math.maxInt(i32)));
    const center_y: i32 = @intCast(@min(coord.suffix[1] *| dw.CHUNK_SIZE, std.math.maxInt(i32)));
    run(center_x - @divTrunc(DEFAULT_SPAN, 2), center_y - @divTrunc(DEFAULT_SPAN, 2), DEFAULT_SPAN);
}

/// Samples the `span`-by-`span` block region whose corner is (`x0`, `y0`) and logs tallied information.
pub fn run(x0: i32, y0: i32, span: i32) void {
    if (!dw.dev_menu) return;
    if (memory.game.depth != dw.startup.STARTING_ZOOM_TIMES) {
        logger.info(@src(), "can't run this when not at base depth!", .{});
    }

    const seed = memory.getHashSeed(.structures);
    const blocks: f64 = @floatFromInt(@as(i64, span) * @as(i64, span));
    const per_million = 1_000_000.0 / blocks; // fancy _ for fun

    logger.log(@src(), "worldgen audit: {d}x{d} blocks", .{ span, span });

    auditStructures(x0, y0, span, seed, per_million);
    auditDecorations(x0, y0, span, per_million);
    auditBlocks(x0, y0, span);
}

/// Per structure kind: how many cells rolled a placement the terrain accepted, and how many of those a rival then beat.
///
/// `offset` is the mean anchor position within the cell against the uniform expectation.
/// A number that drifts says placements favor one corner of their cell, which would show up as a visible lattice.
fn auditStructures(x0: i32, y0: i32, span: i32, seed: dw.utils.Vec2u, per_million: f64) void {
    // Funnel: of every cell, how many survived each stage. The gaps between columns are the "attrition",
    // and the widest gap is the knob to reach for (a huge rolled->seated drop means the terrain gate makes the structure rare).
    // Note that won is post-collision, the rest pre-collision.
    logger.log(@src(), " {s:<10} {s:>6} {s:>8} {s:>8} {s:>8} {s:>8} {s:>6} {s:>10} {s:>14}", .{
        "structure",
        "chance",
        "cells",
        "anchored",
        "seated",
        "placed",
        "won",
        "per 1M",
        "offset (unif)",
    });

    inline for (0..structures.structures.len) |kind| {
        const S = structures.structures[kind];
        const area: i32 = @intCast(S.spawn_area);

        var cells: u64 = 0;
        // Cells that reached AT LEAST the given stage, so the row reads as a monotonic funnel.
        var anchored: u64 = 0;
        var seated: u64 = 0;
        var placed: u64 = 0;
        var won: u64 = 0;
        var sum_ox: f64 = 0;
        var sum_oy: f64 = 0;

        var cy = @divFloor(y0, area);
        while (cy <= @divFloor(y0 + span - 1, area)) : (cy += 1) {
            var cx = @divFloor(x0, area);
            while (cx <= @divFloor(x0 + span - 1, area)) : (cx += 1) {
                cells += 1;

                // Uncached, so the count is exact over the swept region regardless of cache eviction.
                const res = structures.resolveCellForAudit(kind, cx, cy, seed);
                switch (res.reached) {
                    .rejected => {},
                    .anchored => anchored += 1,
                    .seated => {
                        anchored += 1;
                        seated += 1;
                    },
                    .placed => {
                        anchored += 1;
                        seated += 1;
                        placed += 1;
                    },
                }

                // won also survives the priority/collision scan, which the funnel above does not model.
                const bounds = structures.acceptedBoundsForAudit(kind, cx, cy, seed) orelse continue;
                won += 1;
                sum_ox += @floatFromInt(bounds.x_start - cx * area);
                sum_oy += @floatFromInt(bounds.y_start - cy * area);
            }
        }

        const n: f64 = @floatFromInt(won);
        const uniform: f64 = @as(f64, @floatFromInt(area - 1)) / 2.0;
        logger.log(@src(), "{s:<10} {d:>6.3} {d:>8} {d:>8} {d:>8} {d:>8} {d:>6} {d:>10.1} {d:>5.1}/{d:.1} ({d:.1})", .{
            shortName(@typeName(S)),
            S.target_chance,
            cells,
            anchored,
            seated,
            placed,
            won,
            n * per_million,
            if (won > 0) sum_ox / n else 0,
            if (won > 0) sum_oy / n else 0,
            uniform,
        });
    }
}

/// Per decoration kind: anchors the terrain accepted, and how many survived an overlapping anchor of the same kind.
/// Decorations have no grid, so density is the only dial and this table IS the dial's readout.
fn auditDecorations(x0: i32, y0: i32, span: i32, per_million: f64) void {
    logger.log(@src(), "{s:<16} {s:>6} {s:>8} {s:>8} {s:>10}", .{ "decor", "chance", "standing", "placed", "per 1M" });

    const seed = memory.getHashSeed(.vine1);
    inline for (0..decorations.points.len) |kind| {
        const D = decorations.points[kind];

        var standing: u64 = 0;
        var placed: u64 = 0;
        var wy = y0;
        while (wy < y0 + span) : (wy += 1) {
            var wx = x0;
            while (wx < x0 + span) : (wx += 1) {
                if (!decorations.standsForAudit(kind, wx, wy, seed)) continue;
                standing += 1;
                if (decorations.anchoredForAudit(kind, wx, wy, seed)) placed += 1;
            }
        }

        logger.log(@src(), "{s:<16} {d:>6.3} {d:>8} {d:>8} {d:>10.1}", .{
            decorName(D),
            D.chance,
            standing,
            placed,
            @as(f64, @floatFromInt(placed)) * per_million,
        });
    }
}

/// The sprite mix of the region, most common first. The `block odds` readout:
/// what fraction of the world is stone, air, each ore, each gem.
fn auditBlocks(x0: i32, y0: i32, span: i32) void {
    var ids: [MAX_TRACKED_SPRITES]Sprite = @splat(.none);
    var counts: [MAX_TRACKED_SPRITES]u64 = @splat(0);
    var tracked: usize = 0;
    var total: u64 = 0;
    var dropped: u64 = 0;

    const decor_seed = memory.getHashSeed(.vine1);

    var wy = y0;
    while (wy < y0 + span) : (wy += 1) {
        var wx = x0;
        while (wx < x0 + span) : (wx += 1) {
            if (wx < 0 or wy < 0) continue;

            var sprite = dw.world.sampleBaseFoundation(@bitCast(wx), @bitCast(wy));
            if (sprite.isEmpty()) {
                if (decorations.resolve(@bitCast(wx), @bitCast(wy), decor_seed)) |d| sprite = d;
            }
            total += 1;

            const slot = for (ids[0..tracked], 0..) |id, i| {
                if (id == sprite) break i;
            } else blk: {
                if (tracked == MAX_TRACKED_SPRITES) {
                    dropped += 1;
                    break :blk null;
                }
                ids[tracked] = sprite;
                tracked += 1;
                break :blk tracked - 1;
            };
            if (slot) |i| counts[i] += 1;
        }
    }
    if (total == 0) return;

    // selection sort: tracked is tiny and this keeps the debug path allocation-free
    for (0..tracked) |i| {
        var best = i;
        for (i + 1..tracked) |j| {
            if (counts[j] > counts[best]) best = j;
        }
        std.mem.swap(u64, &counts[i], &counts[best]);
        std.mem.swap(Sprite, &ids[i], &ids[best]);
    }

    logger.log(@src(), "{s:<20} {s:>10} {s:>8}", .{ "sprite", "count", "share" });
    for (0..tracked) |i| {
        logger.log(@src(), "{s:<20} {d:>10} {d:>7.3}%", .{
            @tagName(ids[i]),
            counts[i],
            100.0 * @as(f64, @floatFromInt(counts[i])) / @as(f64, @floatFromInt(total)),
        });
    }
    if (dropped > 0) logger.err(@src(), "block mix truncated: more than {d} distinct sprites", .{MAX_TRACKED_SPRITES});
}

/// Cross-checks live-state invariants over the loaded `SimBuffer` and the modification store,
/// logging any violations!
/// (Different from `VERIFY_WATER_MASS` in state/water.zig which guards per-tick conservation instead.)
///
/// Checked here (each invariant is documented at its owning definition):
/// - `ModEntry.count` equals the population count of `ModEntry.modified` and fits its capacity
///   (which may be any size up to `CHUNK_SIZE_SQ`: `loadEntry()` allocates exact-size).
/// - a loaded chunk holding any water has its `SimBuffer.has_water` bit set
///   (the bit is a lazy superset, so the reverse is allowed).
/// - dry, non-foundation, non-liquid, non-waterloggable cells (air and plain decorations)
///   keep the `0xFF` edge-flag sentinels so the shader skips erosion on them.
pub fn verifySimInvariants() void {
    if (!dw.dev_menu) return;

    var bad_entries: u64 = 0;
    for ([_]*const dw.world.ModificationStore{ &dw.world.mod_store, &dw.world.legacy_store }, 0..) |store, store_id| {
        const name = if (store_id == 0) "mod" else "legacy";
        var entry_idx: usize = 0;
        // iterator stuff is kinda cool
        var it = store.entries.constIterator(0);
        while (it.next()) |e| : (entry_idx += 1) {
            var pop: u32 = 0;
            for (e.modified) |w| pop += @popCount(w);
            if (pop != e.count or e.count > e.cells.len or e.cells.len > dw.CHUNK_SIZE_SQ) {
                logger.err(@src(), "{s} entry {d} desynced: popcount {d}, count {d}, capacity {d}", .{
                    name,
                    entry_idx,
                    pop,
                    e.count,
                    e.cells.len,
                });
                bad_entries += 1;
            }
        }
    }

    // A frozen value only exists for a depth the player has already descended past.
    // One at or below the frontier means a capture ran when it should not have (see world.captureLegacy()).
    var legacy_keys = dw.world.legacy_store.index.iterator();
    while (legacy_keys.next()) |kv| {
        if (kv.key_ptr.depth >= dw.world.frontier()) {
            logger.err(@src(), "legacy entry at depth {d} is not below the frontier {d}", .{
                kv.key_ptr.depth,
                dw.world.frontier(),
            });
            bad_entries += 1;
        }
    }

    var water_unmarked: u64 = 0;
    var sentinel_violations: u64 = 0;
    const SimBuffer = dw.world.SimBuffer;
    for (&SimBuffer.keys, 0..) |key, slot| {
        if (key == null) continue;
        const chunk = &SimBuffer.sim_buffer_ptr[slot];

        var holds_water = false;
        for (&chunk.blocks) |*b| {
            if (b.isLiquid() or dw.water.getVolume(b.*) > 0) holds_water = true;

            const sprite = b.id;
            if (dw.water.getVolume(b.*) == 0 and !dw.world.shouldHaveEdgeFlags(sprite) and
                !sprite.isLiquid() and !sprite.isWaterloggable())
            {
                if (b.edge_flags != 0xFF or b.id_edge_flags != 0xFF) sentinel_violations += 1;
            }
        }
        if (holds_water and !SimBuffer.has_water.isSet(slot)) water_unmarked += 1;
    }

    if (bad_entries + water_unmarked + sentinel_violations == 0) {
        logger.log(@src(), "invariant audit: clean ({d} mod entries, {d} frozen, loaded SimBuffer slots scanned)", .{
            dw.world.mod_store.index.count(),
            dw.world.legacy_store.index.count(),
        });
    } else {
        logger.err(@src(), "invariant audit: {d} mod entries desynced, {d} watery chunks unmarked, {d} edge-flag sentinel violations", .{
            bad_entries,
            water_unmarked,
            sentinel_violations,
        });
    }
}

/// A decoration's own own `name` if it declares one or the `@typeName()` of it.
inline fn decorName(comptime D: type) []const u8 {
    return if (@hasDecl(D, "name")) D.name else shortName(@typeName(D));
}

/// Trims `a.b.ActualName` down to `ActualName`.
inline fn shortName(comptime full: []const u8) []const u8 {
    comptime {
        var start: usize = 0;
        for (full, 0..) |c, i| {
            if (c == '.') start = i + 1;
        }
        const trimmed = full[start..].*;
        return &trimmed;
    }
}
