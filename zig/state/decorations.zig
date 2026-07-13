//! Position-hashed decorations: the cheap tier, for small things that do not need to out-rank a structure.
//!
//! A structure asks "does any CANDIDATE cover this block", which needs a grid, a collision scan against every
//! higher-priority kind, and a cache to make that affordable. A decoration instead asks "is one of the few
//! blocks that could ANCHOR me actually an anchor" -- a couple of hashes and some (already cached) terrain
//! probes, with no grid, no collision scan and no cache of its own.
//!
//! That is only possible because the roll is keyed on the anchor's world position rather than drawn from a
//! per-chunk RNG stream (the way `addDecorations()` does it). A position-keyed roll is addressable: a block
//! can ask about an anchor in the chunk next door without replaying that chunk. Cross-chunk coherence, which
//! `structures.zig` needs its whole grid for, comes out free.
//!
//! Put anything <= a few blocks here. Anything with a real footprint, a priority collision or a region-wide
//! terrain gate belongs in `structures.zig`.
//!
//! Each decoration declares:
//! - `size_x`, `size_y`: the footprint an anchor claims, growing right and down from it
//! - `chance`: odds that a given block anchors one, BEFORE `constraints` run
//! - `constraints` (optional): terrain rules over the footprint, same vocabulary as a structure's
//! - `generate()`: the sprite at a local offset within the footprint, or null to leave the block alone
const std = @import("std");
const dw = @import("../root.zig");
const structures = @import("structures.zig");

const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;
const Rect = structures.Rect;
const Constraint = structures.Constraint;

/// Decorations in priority order; the first one to claim a block wins it.
pub const decorations = .{
    @import("decorations/Shrub.zig"),
    @import("decorations/Plant.zig"),
};

/// Each decoration's `constraints`, sorted cheapest-first.
const constraint_table: [decorations.len][]const Constraint = blk: {
    var table: [decorations.len][]const Constraint = @splat(&.{});
    for (decorations, 0..) |D, i| {
        if (@hasDecl(D, "constraints")) table[i] = structures.sortConstraints(&D.constraints, D.size_x, D.size_y);
    }
    break :blk table;
};

comptime {
    for (decorations, 0..) |D, i| {
        if (D.size_x < 1 or D.size_y < 1)
            @compileError(@typeName(decorations[i]) ++ ": a decoration must occupy at least one block.");
    }
}

/// The footprint an anchor at (`ax`, `ay`) would claim.
inline fn footprint(comptime kind: usize, ax: i32, ay: i32) Rect {
    const D = decorations[kind];
    return .{ .x_start = ax, .y_start = ay, .x_end = ax + D.size_x, .y_end = ay + D.size_y };
}

/// The anchor's private hash stream, keyed on its world position alone.
inline fn anchorState(comptime kind: usize, ax: i32, ay: i32, seed: Vec2u) HashState {
    return structures.makeBlockHash(seed, @bitCast(ax), @bitCast(ay), kind);
}

/// Whether a decoration of `kind` would stand with its anchor at (`ax`, `ay`): it rolled, and the terrain
/// under its footprint accepts it. Says nothing about whether another anchor beats it (see `anchored()`).
fn stands(comptime kind: usize, ax: i32, ay: i32, seed: Vec2u) bool {
    @setEvalBranchQuota(20000); // `getChance()` comptime-searches for a rational approximation of the odds
    var state = anchorState(kind, ax, ay, seed);
    if (!state.getChance(decorations[kind].chance)) return false;
    return structures.satisfies(constraint_table[kind], footprint(kind, ax, ay));
}

/// Whether (`ax`, `ay`) is the anchor a decoration of `kind` actually grows from.
///
/// Two anchors of one kind within a footprint of each other would interleave their halves, so the one up and
/// to the left wins. Non-recursive, exactly as `structures.isBeaten()` is: a rival is judged on whether IT
/// would stand, never on whether it is itself beaten.
fn anchored(comptime kind: usize, ax: i32, ay: i32, seed: Vec2u) bool {
    const D = decorations[kind];
    if (!stands(kind, ax, ay, seed)) return false;

    var dy: i32 = -(D.size_y - 1);
    while (dy <= 0) : (dy += 1) {
        var dx: i32 = -(D.size_x - 1);
        while (dx <= 0) : (dx += 1) {
            if (dx == 0 and dy == 0) continue;
            if (stands(kind, ax + dx, ay + dy, seed)) return false;
        }
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

/// The decoration sprite at block (`wx`, `wy`), or null if nothing claims it.
///
/// Walks the few anchors whose footprint could reach this block, nearest-first, so a decoration is drawn by
/// whichever anchor owns it. Costs one hash per candidate anchor in the common case, since the roll fails
/// long before any terrain is touched.
pub fn resolve(wx: u32, wy: u32, seed: Vec2u) ?Sprite {
    const bx = @as(i32, @bitCast(wx));
    const by = @as(i32, @bitCast(wy));

    inline for (decorations, 0..) |D, kind| {
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
