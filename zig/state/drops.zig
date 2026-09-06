//! Block-drop resolution: handles how a destroyed block turns into item sprites.
//! `SpriteProps.drops` holds a `DropConfig`; data gets consumed in `input/inventory.zig`.
const std = @import("std");
const dw = @import("../root.zig");

const memory = dw.memory;
const Sprite = dw.Sprite;
const Coordinate = dw.world.Coordinate;

/// Strategy to resolve block drop items upon destruction.
/// Works for all (valid) sprite types.
pub const DropStrategy = enum {
    /// Drops itself if `.isItem()` returns true.
    self,
    /// Guaranteed to drop nothing.
    none,
    /// Drops a predetermined list of static items.
    static,
    /// Runs a custom function to determine drops.
    dynamic,
};

/// Type signature for deterministic coordinate-based drop calculations.
pub const DropFn = *const fn (coord: Coordinate, bx: u4, by: u4) []const Sprite;

/// Configuration defining how a block drops items.
pub const DropConfig = struct {
    strategy: DropStrategy = .self,
    static_items: []const Sprite = &.{},
    dynamic_fn: ?DropFn = null,
};

/// What a bush drops, and how often relative to the other rows.
/// Odds automatically adjust to 100%.
const bush_drops = dw.seeding.WeightedPicker([]const Sprite, &.{
    .{ .value = &.{.ruby_candy}, .weight = 5 },
    .{ .value = &.{.splittyfruit}, .weight = 10 },
    .{ .value = &.{.teal_lemon_fruit}, .weight = 15 },
    .{ .value = &.{.blemon_fruit}, .weight = 15 },
    .{ .value = &.{.copperfruit}, .weight = 15 },
    .{ .value = &.{.ploopus1}, .weight = 10 },
    .{ .value = &.{.ploopus2}, .weight = 10 },
    .{ .value = &.{.divato}, .weight = 10 },
    .{ .value = &.{.circuspin}, .weight = 6 },
    .{ .value = &.{.bacon}, .weight = 4 },
});

/// Custom `dynamic_fn` handlers referenced by `DropConfig` entries in the sprite rule table.
pub const DropHandlers = struct {
    /// Converts a bush drop to various fruits based on world coordinates and seeds.
    pub fn bushDrop(coord: Coordinate, bx: u4, by: u4) []const Sprite {
        const depth = memory.game.depth;
        const key = coord.asDepthCoordinate(depth);
        const chunk_seeds = dw.world.quad_cache.getChunkSeeds(key);

        // Deterministic hash based on the absolute block coordinate in the world
        const abs_x = coord.suffix[0] *% 16 + bx; // (no +% needed)
        const abs_y = coord.suffix[1] *% 16 + by;
        const seed_val = dw.seeding.FastHash.hash2d(
            chunk_seeds.value[3].value[0..2].*,
            abs_x,
            abs_y,
        );

        return bush_drops.pick(seed_val);
    }
};
