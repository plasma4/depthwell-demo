//! Block-drop resolution: handles how a destroyed block turns into item sprites.
//! `SpriteProps.drops` holds a `DropConfig`; data gets consumed in `input/inventory.zig`.
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

/// Custom `dynamic_fn` handlers referenced by `DropConfig` entries in the sprite rule table.
pub const DropHandlers = struct {
    /// Converts a bush drop to various fruits based on world coordinates and seeds.
    pub fn bushDrop(coord: Coordinate, bx: u4, by: u4) []const Sprite {
        const oddsNum = dw.seeding.oddsNum;
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

        const roll = seed_val;
        if (roll <= oddsNum(0.05)) {
            return &[_]Sprite{.ruby_candy};
        } else if (roll <= oddsNum(0.15)) {
            return &[_]Sprite{.splittyfruit};
        } else if (roll <= oddsNum(0.30)) {
            return &[_]Sprite{.teal_lemon_fruit};
        } else if (roll <= oddsNum(0.45)) {
            return &[_]Sprite{.blemon_fruit};
        } else if (roll <= oddsNum(0.60)) {
            return &[_]Sprite{.copperfruit};
        } else if (roll <= oddsNum(0.70)) {
            return &[_]Sprite{.ploopus1};
        } else if (roll <= oddsNum(0.80)) {
            return &[_]Sprite{.ploopus2};
        } else if (roll <= oddsNum(0.90)) {
            return &[_]Sprite{.divato};
        } else if (roll <= oddsNum(0.96)) {
            return &[_]Sprite{.circuspin};
        } else {
            return &[_]Sprite{.bacon};
        }
    }
};
