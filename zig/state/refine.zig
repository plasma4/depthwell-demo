//! How a macro block becomes its own 4x4 child region one depth down.
//!
//! Terrain refines by carving and warping a density field (`ancestor.zig`), but a decoration is not
//! terrain: duplicating a bush into all 16 cells of its region gives 16 bushes, and duplicating a
//! chest gives 16 chests. Every sprite listed here instead states a PLAN for its region, and
//! `refineChild()` answers one cell of it:
//!
//! - `.single`: exactly one copy, like a portal landing (chests, furnaces, cores, lathes, portals).
//! - `.scatter`: 1 to `max_copies` copies along the region's anchor row, averaging `density`
//!   (bushes, rocks, flint, mushrooms, the 1x3 flower).
//! - `.chain`: a hanging chain (vines): deduped to a couple of columns and capped in total length
//!   (preventing edge flags/traversal freeze).
//! - `.stamp`: a hard-coded macro shape spanning one or more parents (the 2x1 moss shrub becomes a little tree).
//!   Should be extended for anything the three other generic options can't specify!
//!
//! Three properties hold to keep things procedurally interesting:
//! 1. AT LEAST ONE copy survives (`.scatter` will draw from 1),
//!    so a decoration never silently disappears as the player descends.
//! 2. Copies stand ON the surface the parent was anchored to. The plan places them against the region's floor/ceiling row,
//!    and `protectsSurfaceCell()` stops the terrain parent on the far side of that row from eroding it,
//!   exactly as `anchorsPortal()` protects a portal's landing.
//! 3. Every cell of a region agrees. All the randomness comes from ONE hash of the PARENT's world cell (`regionHash()`),
//!    never of the child cell, so the 4x4 cells can't disagree about how many copies there are or where they sit.
//!
//! `RefinedTag` is the other half of the story explains a block's origin!
const std = @import("std");
const dw = @import("../root.zig");
const memory = dw.memory;
const seeding = dw.seeding;

const Sprite = dw.Sprite;
const Block = memory.Block;
const BlockSpec = memory.BlockSpec;
const FastHash = seeding.FastHash;
const Vec2u = dw.utils.Vec2u;
const WorldCoord = seeding.WorldCoord;

const BLOCKS_PER_PARENT = dw.BLOCKS_PER_PARENT;
/// Region row that touches the parent's floor, and the one that touches its ceiling.
const FLOOR_ROW: u4 = BLOCKS_PER_PARENT - 1;
const CEILING_ROW: u4 = 0;

/// What a block was refined out of, once its own sprite no longer says so.
///
/// Deliberately tiny (a `Block` has room for 11 bits, see `memory.Block.tag`) and NOT saved: a tag is
/// re-derived every time a chunk is generated, and a cell the player edits keeps the edit and loses
/// the tag (`world.ModCell` stores only what generation cannot recover).
pub const RefinedKind = enum(u9) {
    /// No "origin" to care about; most common.
    none = 0,
    /// A cell of a hanging chain. `data` is how many cells below its ceiling this one sits
    /// (1 = directly below), which is what lets the next depth continue the chain and cap it.
    chain_run,
    /// Canopy of a stamped plant. `data` counts the depths the tag still applies (see `aged()`).
    plant_leaf,
    /// Trunk/stem of a stamped plant. `data` behaves as in `plant_leaf`.
    plant_trunk,
    _,
};

/// A `RefinedKind` plus its 6 bits of kind-specific payload.
pub const RefinedTag = packed struct(u15) {
    kind: RefinedKind = .none,
    /// Kind-specific: a chain's run index, or the depths a plant tag has left.
    /// Saturates rather than wrapping, so a value of `DATA_MAX` means "at least this much".
    data: u6 = 0,

    /// Largest `data` value; a chain longer than this reads as exactly this long,
    /// which only ever makes the length cap fire sooner.
    pub const DATA_MAX: u6 = std.math.maxInt(u6);

    /// Saturating `data` constructor, so no caller has to think about the field's width.
    pub inline fn make(kind: RefinedKind, data: u64) RefinedTag {
        return .{ .kind = kind, .data = @intCast(@min(data, DATA_MAX)) };
    }

    /// The same tag one depth further down: a plant tag counts down and vanishes at zero,
    /// and everything else is dropped, since only a plan that re-states a tag may carry one.
    ///
    /// A chain's run is NOT aged here; it is recomputed from the parent's run by the chain plan,
    /// because a child's distance below the ceiling is four times its parent's, not one less.
    pub inline fn aged(self: RefinedTag) RefinedTag {
        return switch (self.kind) {
            .plant_leaf, .plant_trunk => if (self.data <= 1) .{} else .{ .kind = self.kind, .data = self.data - 1 },
            else => .{},
        };
    }

    /// Whether an ore or gem may NOT grow in this block.
    /// A shrub's canopy is stone at the next depth, and stone is where ore goes;
    /// this is what keeps a tree from sprouting copper for as long as it still reads as a tree.
    pub inline fn blocksOverlay(self: RefinedTag) bool {
        return switch (self.kind) {
            .plant_leaf, .plant_trunk => true,
            else => false,
        };
    }
};

/// The surface a decoration is fixed to, which decides which row of its child region holds the copies
/// (and which neighbor has to be solid for any copy to exist at all).
pub const Surface = enum {
    /// Stands on a floor (`AnchorKind.floor`): copies grow UP from the region's bottom row.
    floor,
    /// Hangs from a ceiling (`AnchorKind.ceiling`): copies grow DOWN from the region's top row.
    ceiling,
    /// Hangs from a ceiling OR from more of itself (`AnchorKind.suspended`), i.e. a chain.
    suspended,

    /// Row of the child region a copy is anchored at.
    inline fn anchorRow(self: Surface) u4 {
        return switch (self) {
            .floor => FLOOR_ROW,
            .ceiling, .suspended => CEILING_ROW,
        };
    }

    /// Distance of region row `ly` from the anchor row, growing away from the surface.
    inline fn stackIndex(self: Surface, ly: u4) u4 {
        return switch (self) {
            .floor => FLOOR_ROW - ly,
            .ceiling, .suspended => ly,
        };
    }
};

/// Exactly one copy, wherever the parent's hash puts it.
pub const Single = struct {
    /// Cells of the copy, starting at the anchor row and stacking away from the surface.
    /// Empty means "one cell holding the parent's own evolved sprite".
    stack: []const Sprite = &.{},
    /// Which columns the copy may occupy.
    columns: Columns = .any,
};

/// A copy in every column of a fixed set: no hash, no count, the same shape in every region.
/// For a kind whose refined form IS a specific arrangement rather than a scattering of copies.
pub const Fixed = struct {
    /// Columns to fill. `.any` has no fixed meaning, so it is rejected at compile-time.
    columns: Columns,
    /// Cells of one copy, as in `Single.stack`.
    stack: []const Sprite = &.{},
};

/// How many copies a region gets.
///
/// Authored as a mean and a ceiling by `count()`, but STORED as the thresholds a draw walks, since a
/// rule is looked up at runtime and nothing about it can be a comptime value by then.
pub const Count = struct {
    /// Hard ceiling on copies per region; never zero, so a decoration cannot vanish.
    max: u4,
    /// Cumulative thresholds over 2^32; entry `i` is the chance the count is at most `i + 1`.
    /// Only the first `max` entries are read.
    thresholds: [BLOCKS_PER_PARENT]u32,
};

/// One to `max` copies, averaging `density`.
///
/// The count is `1 + Binomial(max - 1, p)` with `p = (density - 1) / (max - 1)`,
/// which puts the mean at exactly `density` and never leaves `[1, max]`.
/// `density` is THE tuning knob: raise it for clutter, lower it toward 1 to thin a decoration out as the player descends.
pub fn count(comptime density: f32, comptime max: u4) Count {
    comptime {
        if (max == 0) @compileError("A decoration must keep at least one copy per region.");
        if (max > BLOCKS_PER_PARENT)
            @compileError("A region has only `BLOCKS_PER_PARENT` columns to put copies in.");
        if (density < 1.0 or density > @as(f32, @floatFromInt(max)))
            @compileError("A copy density must sit in [1, max].");
    }
    return .{ .max = max, .thresholds = countThresholds(density, max) };
}

/// One to `copies.max` copies spread along the anchor row.
pub const Scatter = struct {
    copies: Count,
    /// Cells of one copy, as in `Single.stack`.
    stack: []const Sprite = &.{},
};

/// A chain hanging off a ceiling: a few columns wide, each column its own length.
pub const Chain = struct {
    /// Band a column's reach is drawn from, in child blocks measured from the ceiling.
    min_length: u32,
    max_length: u32,
    /// Columns the chain occupies; up to 4 columns for multi-strand mutated clusters.
    copies: Count = count(2.5, 4),
};

/// A hard-coded plant shape, for anything the generic plans cannot express.
/// The pattern is read as a picture: `'.'` empty, `'T'` trunk, `'L'` leaf.
pub const Stamp = struct {
    /// Rows top to bottom. Each row must be `BLOCKS_PER_PARENT * halves` characters wide, and there
    /// must be exactly `BLOCKS_PER_PARENT` of them (the shape spans one parent vertically).
    rows: []const []const u8,
    /// Horizontal slice this sprite draws: 0 is the leftmost parent of the shape.
    /// Each parent of a multi-parent shape gets its own rule with its own `half`.
    half: u2 = 0,
    /// Parents the shape spans horizontally. A 2x1 shrub spans 2.
    halves: u2 = 1,
    /// Leaf palette; one entry is picked per cell from the shape's own hash, so a given plant always
    /// looks the same but two plants differ.
    leaves: []const Sprite = &.{ .lime_stone, .bright_green_stone },
    trunk: Sprite = .wood,
    /// Depths the canopy's `plant_leaf` tag survives, i.e. how long ores stay out of it.
    tag_ttl: u6 = 2,
};

/// What a sprite's region becomes.
pub const Plan = union(enum) {
    fixed: Fixed,
    single: Single,
    scatter: Scatter,
    chain: Chain,
    stamp: Stamp,
};

/// One sprite's refinement.
pub const Rule = struct {
    surface: Surface,
    plan: Plan,

    /// Cells of one copy, for the plans that place copies by column, or null for the ones that place
    /// their cells themselves.
    inline fn stack(self: Rule) ?[]const Sprite {
        return switch (self.plan) {
            .fixed => |s| s.stack,
            .single => |s| s.stack,
            .scatter => |s| s.stack,
            else => null,
        };
    }
};

/// A floor decoration that keeps its own sprite: the ordinary case (bush, rock, flint).
fn floorScatter(comptime density: f32, comptime max_copies: u4) Rule {
    return .{ .surface = .floor, .plan = .{ .scatter = .{ .copies = count(density, max_copies) } } };
}

/// An installation: one per region, floor-anchored, never duplicated.
const floor_single: Rule = .{ .surface = .floor, .plan = .{ .single = .{} } };

/// A portal's landing pad, which must stay inside the 2x1 area a descent drops the player onto.
const portal_single: Rule = .{ .surface = .floor, .plan = .{ .single = .{ .columns = .center_one } } };
const invportal_single: Rule = .{ .surface = .ceiling, .plan = .{ .single = .{ .columns = .center_one } } };

/// The two big mushrooms a mushroom becomes, in the middle of its region. Fixed, not rolled: this is
/// the shape of a refined mushroom, and it stays that shape at every depth.
const mushroom_pair: Rule = .{ .surface = .floor, .plan = .{ .fixed = .{
    .columns = .center_both,
    .stack = &[_]Sprite{.big_mushroom},
} } };

/// The 1x3 flower, rebuilt from its base upward. Only the parent standing ON the floor refines
/// (`surfaceMet()` fails for the stem and the flower above it), so one flower makes one or two
/// flowers rather than three stacked fragments.
const flower_stack = [_]Sprite{ .plant_stem, .plant_stem, .cornflower };
const flower_rule: Rule = .{ .surface = .floor, .plan = .{ .scatter = .{
    .copies = count(1.6, 2),
    .stack = &flower_stack,
} } };

/// The little tree a 2x1 moss shrub becomes: a 2-wide trunk on the floor under a canopy.
const SHRUB_ROWS = [_][]const u8{
    ".LLLLLL.",
    "LLLLLLLL",
    ".LLTTLL.",
    "...TT...",
};

inline fn shrubStamp(half: u2, wood_type: Sprite) Rule {
    return .{ .surface = .floor, .plan = .{ .stamp = .{
        .rows = &SHRUB_ROWS,
        .half = half,
        .halves = 2,
        .trunk = wood_type,
    } } };
}

/// Every sprite that refines by plan rather than by duplication.
/// A sprite absent from this table and not handled by `ancestor.applyAncestorLogic()` still fills its
/// whole region, which is only ever right for terrain.
const rules = [_]struct { Sprite, Rule }{
    // Ground clutter: thins toward a couple of copies per region.
    .{ .bush, floorScatter(2.2, 3) },
    .{ .rock, floorScatter(2.0, 3) },
    .{ .purple_rock, floorScatter(1.6, 3) },
    .{ .flint, floorScatter(1.8, 3) },
    .{ .small_tree, floorScatter(1.5, 2) },
    // A mushroom becomes two big mushrooms in the middle of its region, and a big mushroom keeps doing
    // the same: the pair IS the refined shape, so it is fixed rather than rolled.
    .{ .mushroom, mushroom_pair },
    .{ .big_mushroom, floorScatter(1.4, 2) }, // TODO: add "mushroom tree" sprites and shape instead

    // The flower's two sprites share one rule; only its base ever stands on a floor.
    .{ .cornflower, flower_rule },
    .{ .plant_stem, flower_rule },

    .{ .ceiling_flower, .{
        .surface = .ceiling,
        .plan = .{ .scatter = .{ .copies = count(1.8, 3) } },
    } },

    // Installations: one and only one, like a portal.
    .{ .chest, floor_single },
    .{ .campfire, floor_single },
    .{ .forest_furnace, floor_single },
    .{ .lava_furnace, floor_single },
    .{ .lathe, floor_single },
    .{ .basic_core, floor_single },
    .{ .core1, floor_single },
    .{ .core2, floor_single },
    .{ .core3, floor_single },
    .{ .core4, floor_single },
    .{ .portal, portal_single },
    .{ .invportal, invportal_single },

    // The 2x1 shrub becomes one 8x4 tree, split across the two parents that made it.
    .{ .moss_shrub1, shrubStamp(0, .wood) },
    .{ .moss_shrub1_right, shrubStamp(1, .wood) },
    .{ .moss_shrub2, shrubStamp(0, .purple_stone) },
    .{ .moss_shrub2_right, shrubStamp(1, .purple_stone) },
};

/// Sparse-to-dense lookup: sprite ID -> its rule, or null. One indexed load at runtime.
const rule_table: [dw.sprite.MAX_SPRITE_ID]?Rule = blk: {
    @setEvalBranchQuota(50000);
    var table: [dw.sprite.MAX_SPRITE_ID]?Rule = @splat(null);

    for (rules) |entry| {
        const id = @intFromEnum(entry[0]);
        if (table[id] != null)
            @compileError("Sprite `" ++ @tagName(entry[0]) ++ "` has two refinement rules.");
        table[id] = entry[1];
    }

    for (dw.decorations.columns) |feature| {
        const id = @intFromEnum(feature.sprite);
        if (table[id] != null)
            @compileError("Column feature `" ++ @tagName(feature.sprite) ++ "` also has an explicit refinement rule.");

        const base_len = feature.max_length;
        // min length ranges from 9 to 16 based on 2x previous length
        const min_len: u32 = @min(@max(base_len * 2, 9), 16);
        // max length scales up to 4x previous length, capped at RefinedTag.DATA_MAX (63)
        const max_len: u32 = @min(base_len * 4, @as(u32, RefinedTag.DATA_MAX));

        if (max_len > RefinedTag.DATA_MAX)
            @compileError("Column feature `" ++ @tagName(feature.sprite) ++ "`'s capped length does not fit a `RefinedTag`.");

        table[id] = .{ .surface = .suspended, .plan = .{ .chain = .{
            .min_length = min_len,
            .max_length = max_len,
            .copies = count(2.5, 4),
        } } };
    }

    break :blk table;
};

comptime {
    @setEvalBranchQuota(50000);
    for (rule_table, 0..) |maybe_rule, id| {
        const rule = maybe_rule orelse continue;
        const sprite: Sprite = @enumFromInt(id);

        const expected: ?Surface = switch (sprite.anchor()) {
            .floor => .floor,
            .ceiling => .ceiling,
            .suspended => .suspended,
            .none => null,
        };
        if (expected) |surface| {
            if (rule.surface != surface)
                @compileError("Sprite `" ++ @tagName(sprite) ++ "`'s refinement surface disagrees with its `anchor`.");
        }

        switch (rule.plan) {
            .fixed => {},
            .scatter => {},
            .chain => |c| {
                if (c.max_length == 0) @compileError("A chain must be able to reach at least one cell.");
                if (c.min_length > c.max_length) @compileError("Chain min_length cannot exceed max_length.");
            },
            .single => {},
            .stamp => |s| {
                if (s.rows.len != BLOCKS_PER_PARENT)
                    @compileError("A stamp must be exactly `BLOCKS_PER_PARENT` rows tall.");
                if (s.halves == 0) @compileError("A stamp spans at least one parent.");
                if (s.half >= s.halves) @compileError("A stamp's `half` must name one of its `halves`.");
                if (s.leaves.len == 0) @compileError("A stamp needs at least one leaf sprite.");
                for (s.rows) |row| {
                    if (row.len != BLOCKS_PER_PARENT * @as(usize, s.halves))
                        @compileError("Every stamp row must be `BLOCKS_PER_PARENT * halves` wide.");
                    for (row) |c| switch (c) {
                        '.', 'L', 'T' => {},
                        else => @compileError("A stamp cell must be '.', 'L', or 'T'."),
                    };
                }
            },
        }

        if (rule.stack()) |cells| {
            if (cells.len > BLOCKS_PER_PARENT)
                @compileError("Sprite `" ++ @tagName(sprite) ++ "`'s stack is taller than one region.");
        }
    }
}

/// The refinement rule for `sprite`, or null when it refines as terrain does.
pub inline fn ruleFor(sprite: Sprite) ?Rule {
    const id = @intFromEnum(sprite);
    if (id < dw.sprite.MAX_SPRITE_ID) return rule_table[id];
    return null;
}

/// Check whether a cell in region row `ly` can hold `sprite` based on the parent neighbors.
///
/// Use this for a block that arrives by EVOLUTION, not by plan.
/// A normal hanging evolution changes one ceiling row into vine, and terrain fills the whole region.
/// Without this check, a vein can become a wall or a line of vine that hangs in the air.
/// Only the row that touches the required surface may take the sprite, and only when that surface exists.
///
/// Sprites with no plan are terrain. They always return true.
pub inline fn canEvolveInto(sprite: Sprite, n: [8]Block, ly: u4) bool {
    const rule = ruleFor(sprite) orelse return true;
    return switch (rule.surface) {
        .floor => ly == FLOOR_ROW and n[6].isSolid(),
        .ceiling, .suspended => ly == CEILING_ROW and n[1].isSolid(),
    };
}

/// Whether `sprite`'s plan is a hanging chain, so a cell holding a fresh one starts a chain's run.
pub inline fn startsChain(sprite: Sprite) bool {
    const rule = ruleFor(sprite) orelse return false;
    return rule.plan == .chain;
}

/// What one cell of a refined region ends up holding, once the odds and the gate have both spoken.
pub const Evolved = struct {
    /// The sprite the cell takes: the evolution, or the sprite it started as.
    id: Sprite,
    /// A fresh chain's distance from its ceiling. Null means this is not a fresh chain cell.
    /// A moss sprout can begin with two cells, so this is not always one.
    chain_run: ?u64 = null,
};

/// Resolves a sprite's `Evolution` for ONE child cell: roll the odds, then ask the anchor gate.
///
/// The single door every refinement path goes through, terrain and plan alike.
/// Adding a kind's odds is then a table entry in `sprite.zig` and nothing else,
/// and a rule that has to hold for every path (a vine needing a ceiling, a fresh chain starting its run at 1)
/// is stated here once rather than at each caller.
///
/// A sprite with no `Evolution` comes back unchanged, so this is safe to call on anything.
pub fn evolve(source: Sprite, ctx: Context) Evolved {
    if ((source == .mossy_stone or source == .more_mossy_stone) and rollsMossDecay(source, ctx))
        return .{ .id = .stone };
    if (source == .more_mossy_stone) return evolveMossSprout(ctx);

    const ev = source.evolution() orelse return .{ .id = source };
    if (!rollsEvolution(ev, ctx)) return .{ .id = source };
    // The gate reads the PARENT's neighbors: what a hanging or standing sprite needs is a property of
    // the region it lands in, not of the cell's own children.
    if (!canEvolveInto(ev.into, ctx.neighbors, ctx.ly)) return .{ .id = source };
    return .{ .id = ev.into, .chain_run = if (startsChain(ev.into)) 1 else null };
}

/// Fraction of either moss variant that returns to plain stone at each depth.
const MOSS_DECAY_CHANCE = 0.22;
/// Fraction of moss columns that begin a hanging vine.
const MOSS_SPROUT_CHANCE = 0.60;
/// Fraction of moss columns that begin with a second vine cell.
const MOSS_TALL_SPROUT_CHANCE = 0.22;

/// Resolves the moss branch with a separate hash stream from its spread roll.
///
/// Moss becomes plain stone in small holes. This prevents a moss band from staying unbroken
/// as it descends. `more_mossy_stone` uses one roll per parent column, so its two-cell sprout
/// either decays together or stays supported.
fn rollsMossDecay(source: Sprite, ctx: Context) bool {
    const decay_x, const decay_y = if (source == .more_mossy_stone) blk: {
        const px, const py = ctx.parentCell();
        break :blk .{ px +% ctx.lx, py };
    } else .{ ctx.wx, ctx.wy };
    const roll = FastHash.float2d_32(
        ctx.noise_seed,
        seeding.foldWorld(decay_x +% @intFromEnum(Salt.moss_decay)),
        seeding.foldWorld(decay_y -% @intFromEnum(Salt.moss_decay)),
    );
    return roll < MOSS_DECAY_CHANCE;
}

/// Begins an irregular one- or two-cell vine sprout below a mossy ceiling.
///
/// Both rows use one column roll from the parent cell. Thus a lower vine always has its
/// supporting top cell, and its `chain_run` stays correct when the chain refines again.
fn evolveMossSprout(ctx: Context) Evolved {
    if (!ctx.neighbors[1].isSolid() or ctx.ly > 1) return .{ .id = .more_mossy_stone };

    const px, const py = ctx.parentCell();
    const roll = FastHash.float2d_32(
        ctx.noise_seed,
        seeding.foldWorld(px +% ctx.lx +% @intFromEnum(Salt.moss_sprout)),
        seeding.foldWorld(py -% @intFromEnum(Salt.moss_sprout)),
    );
    if (roll >= MOSS_SPROUT_CHANCE) return .{ .id = .more_mossy_stone };
    if (ctx.ly == 1 and roll >= MOSS_TALL_SPROUT_CHANCE) return .{ .id = .more_mossy_stone };

    return .{ .id = .spiralvine, .chain_run = ctx.ly + 1 };
}

/// Multiplier on the blob field before it biases the roll.
/// Value noise piles up around its midpoint, so the raw field only nudges the odds;
/// stretching it (and letting the ends clamp) is what turns that nudge into a patch with a soft edge.
const BLOB_CONTRAST = 2.2;

/// Whether this cell takes its sprite's evolution.
///
/// `chance` is honored exactly in expectation whether or not the cells clump:
/// the blob field biases the roll symmetrically about its own midpoint,
/// and the bias is bounded by how much the odds can absorb before reaching 0 or 1,
/// so averaging the local odds over the world gives `chance` back.
/// Only the ARRANGEMENT changes. That bound is why the field cannot make a patch fully solid:
/// a `chance` of 0.2 varies between 0 and 0.4 across the field, never 0 and 1.
fn rollsEvolution(ev: dw.sprite.Evolution, ctx: Context) bool {
    if (ev.chance >= 1.0) return true;

    const roll = FastHash.float2d_32(
        ctx.noise_seed,
        seeding.foldWorld(ctx.wx +% @intFromEnum(Salt.evolution)),
        seeding.foldWorld(ctx.wy -% @intFromEnum(Salt.evolution)),
    );
    if (ev.blob == 0) return roll < ev.chance;

    const field = dw.procedural.getDualValueNoise(ctx.noise_seed, ctx.wx, ctx.wy, 1.0 / ev.blob)[1];
    const span = 2.0 * @min(ev.chance, 1.0 - ev.chance);
    const bias = std.math.clamp((field - 0.5) * BLOB_CONTRAST, -0.5, 0.5) * span;
    return roll < ev.chance - bias;
}

/// Whether this exact child cell is a surface a refined decoration is about to land on.
///
/// That surface is a PROMISE: the neighboring region places a copy against it unconditionally, so the
/// carve may not take it. The promise is per CELL, not per row: a region holds at most a few copies,
/// so preserving all `BLOCKS_PER_PARENT` cells of a row raises ground and looks visually boring.
/// Both sides read the columns from `surfaceColumns()`,
/// which is what keeps "where the copy goes" and "where the ground stays" from drifting apart.
///
/// Neighbors are row-major with the center removed, so index 1 is above and 6 below.
pub fn protectsSurfaceCell(
    n: [8]Block,
    noise_seed: Vec2u,
    wx: WorldCoord,
    wy: WorldCoord,
    lx: u4,
    ly: u4,
) bool {
    // Only the two rows that touch a neighboring region can be anything's surface.
    if (ly != CEILING_ROW and ly != FLOOR_ROW) return false;

    const px = wx / BLOCKS_PER_PARENT;
    const py = wy / BLOCKS_PER_PARENT;

    if (ly == CEILING_ROW) {
        const above = n[1];
        if (ruleFor(above.id)) |rule| {
            if (rule.surface == .floor and
                claimsColumn(surfaceColumns(rule, above, noise_seed, px, py -% 1), lx)) return true;
        }
    }
    if (ly == FLOOR_ROW) {
        const below = n[6];
        if (ruleFor(below.id)) |rule| {
            // A chain only hangs from THIS parent when it is the top of its chain; deeper cells of a
            // chain are held up by the chain itself and ask nothing of the rock beside them.
            const hangs_here = rule.surface != .suspended or
                below.tag.kind != .chain_run or below.tag.data <= 1;
            if (rule.surface != .floor and hangs_here and
                claimsColumn(surfaceColumns(rule, below, noise_seed, px, py +% 1), lx)) return true;
        }
    }
    return false;
}

/// Everything one child cell needs to know to answer its own refinement.
pub const Context = struct {
    /// The parent block being refined, which carries its own `tag`, `hp`, and sprite.
    parent: Block,
    /// The parent's 8 neighbors, row-major with the center removed (see `protectsSurfaceCell()`).
    neighbors: [8]Block,
    /// Per-depth, per-quadrant noise seed; the same one the terrain carve uses.
    noise_seed: Vec2u,
    /// The CHILD cell's absolute world block position, at the child's own depth.
    wx: WorldCoord,
    wy: WorldCoord,
    /// The child cell's position inside its 4x4 region.
    lx: u4,
    ly: u4,
    /// Cosmetic per-block seed for the shader.
    seed: u64,
    /// Water volume the parent was submerged in, for waterloggable copies.
    water: u4,

    /// The parent's own world cell: the child's position divided by the region size.
    /// EVERY region-wide decision hashes this, which is what makes the 16 cells agree.
    inline fn parentCell(self: Context) struct { WorldCoord, WorldCoord } {
        return .{ self.wx / BLOCKS_PER_PARENT, self.wy / BLOCKS_PER_PARENT };
    }
};

/// Independent hash streams over one parent cell. Distinct salts, so two decisions never correlate.
const Salt = enum(u64) {
    /// Copy count and the column draw.
    layout = 0,
    /// Per-cell cosmetic choices inside a stamp.
    stamp = 0x9E3779B97F4A7C15,
    /// How far each column of a chain reaches.
    reach = 0xD1B54A32D192ED03,
    /// Whether a cell takes its sprite's evolution. Per CELL, not per region: a mottled vein is the
    /// point, and sharing the carve's stream would tie a cell's material to its shape.
    evolution = 0x2545F4914F6CDD1D,
    /// Whether ordinary moss returns to stone instead of spreading.
    moss_decay = 0x6E624EB7F2076C4E,
    /// Which columns in a moss region begin a one- or two-cell vine sprout.
    moss_sprout = 0xBF58476D1CE4E5B9,
};

/// One region-wide hash: a pure function of the PARENT's cell, so no two cells of a region disagree.
inline fn regionHash(noise_seed: Vec2u, px: WorldCoord, py: WorldCoord, comptime salt: Salt) u64 {
    return FastHash.hash2dWorld(noise_seed, px +% @intFromEnum(salt), py -% @intFromEnum(salt));
}

/// Whether the surface this plan anchors to is actually there.
///
/// The dedupe rule that makes the 1x3 flower work: of its three parents, only the one standing on
/// solid ground refines, and the two above it vanish instead of each rebuilding the whole flower.
/// A chain does NOT come through here; what it needs above depends on its run, so `chainChild()` owns that check.
inline fn surfaceMet(rule: Rule, ctx: Context) bool {
    return switch (rule.surface) {
        .floor => ctx.neighbors[6].isSolid(),
        // A suspended plan that is not a chain would still need a real ceiling, so the two agree here.
        .ceiling, .suspended => ctx.neighbors[1].isSolid(),
    };
}

/// Which columns of the region a plan may use.
pub const Columns = enum {
    /// Any of the region's columns, drawn from the parent's hash.
    any,
    /// ONE of the two center columns, drawn from the parent's hash:
    /// half of the 2x1 area a portal descent lands the player on.
    center_one,
    /// BOTH center columns, always.
    center_both,

    /// The mask of a choice that does not depend on a hash, or null when it does.
    inline fn fixedMask(self: Columns) ?ColumnMask {
        return switch (self) {
            .center_both => (@as(ColumnMask, 1) << CENTER_LEFT) | (@as(ColumnMask, 1) << CENTER_RIGHT),
            .any, .center_one => null,
        };
    }
};

/// The region's center column pair, matching the landing area a descent needs.
const CENTER_LEFT: u4 = BLOCKS_PER_PARENT / 2 - 1;
const CENTER_RIGHT: u4 = BLOCKS_PER_PARENT / 2;

comptime {
    if (CENTER_RIGHT != CENTER_LEFT + 1)
        @compileError("The center columns must be adjacent, since they are one 2x1 landing area.");
    if (BLOCKS_PER_PARENT < 4)
        @compileError("A region needs a center column pair and a row to stand on.");
    if (BLOCKS_PER_PARENT > 16)
        @compileError("A column mask is a `u16`; widen `ColumnMask` before growing a region.");
}

/// One bit per column of the region.
const ColumnMask = std.meta.Int(.unsigned, BLOCKS_PER_PARENT);

/// Whether `mask` claims region column `lx`.
inline fn claimsColumn(mask: ColumnMask, lx: u4) bool {
    return (mask >> @intCast(lx)) & 1 != 0;
}

/// The binomial distribution behind `Count`, as cumulative thresholds over 2^32.
/// Entry `i` is the chance the count is at most `i + 1`, so a draw walks to the first one it is under.
fn countThresholds(comptime density: f32, comptime max: u4) [BLOCKS_PER_PARENT]u32 {
    var out: [BLOCKS_PER_PARENT]u32 = @splat(std.math.maxInt(u32));
    if (max == 1) return out;

    const n = max - 1;
    const p: f64 = (@as(f64, density) - 1.0) / @as(f64, @floatFromInt(n));

    var cumulative: f64 = 0;
    for (0..max) |k| {
        // binomial pmf, built by plain multiplication so nothing needs factorials or a pow()
        var term: f64 = 1;
        for (0..k) |i| term = term * @as(f64, @floatFromInt(n - i)) / @as(f64, @floatFromInt(i + 1)) * p;
        for (0..n - k) |_| term *= 1 - p;
        cumulative += term;
        out[k] = @intFromFloat(@min(cumulative, 1.0) * @as(f64, std.math.maxInt(u32)));
    }
    // The last threshold must be saturated, or a draw above it would fall through to no count at all.
    out[max - 1] = std.math.maxInt(u32);
    return out;
}

/// Number of copies to place, drawn from `h`'s low 32 bits.
inline fn drawCount(h: u64, copies: Count) u4 {
    const draw: u32 = @truncate(h);
    for (copies.thresholds[0..copies.max], 1..) |threshold, n| {
        if (draw <= threshold) return @intCast(n);
    }
    return copies.max; // the last threshold is saturated, so this is unreachable in practice
}

/// `n` DISTINCT columns, as a mask, drawn from `h`'s high bits.
///
/// A partial Fisher-Yates shuffle: distinct by construction, and unbiased enough that a column never
/// reads as favored (`h` is a finalized hash, so the modulo's bias is on the order of 2^-60).
fn drawColumns(h: u64, n: u4, columns: Columns) ColumnMask {
    if (columns.fixedMask()) |mask| return mask;
    if (columns == .center_one) {
        // One 2x1 landing area, so the choice is only ever which of its two columns.
        // Kept bit-for-bit the same as the portal placement this replaced.
        return @as(ColumnMask, 1) << (if (h & 1 == 0) CENTER_LEFT else CENTER_RIGHT);
    }

    // fancy compile-time type stuff!
    const ColumnIndex = std.math.Log2Int(ColumnMask);
    var pool: [BLOCKS_PER_PARENT]ColumnIndex = undefined;
    for (&pool, 0..) |*c, i| c.* = @intCast(i);

    var bits = h >> 32;
    var mask: ColumnMask = 0;
    var left: u64 = BLOCKS_PER_PARENT;
    for (0..n) |i| {
        const pick = i + @as(usize, @intCast(bits % left));
        bits /= left;
        mask |= @as(ColumnMask, 1) << pool[pick];
        pool[pick] = pool[i];
        left -= 1;
    }
    return mask;
}

comptime {
    var needed: f64 = 0;
    for (1..BLOCKS_PER_PARENT + 1) |i| needed += std.math.log2(@as(f64, @floatFromInt(i)));
    if (needed > 32) @compileError("A column shuffle needs more bits than half a hash provides.");
}

/// Columns of a parent's own region that its plan claims on the anchor row.
///
/// The ONE place columns are decided. `refineChild()` reads it for the parent being refined, and
/// `protectsSurfaceCell()` reads it for a NEIGHBORING parent, so the two can never disagree about which cells a copy needs.
/// A pure function of the parent's cell, its plan, and its tag.
fn surfaceColumns(rule: Rule, parent: Block, noise_seed: Vec2u, px: WorldCoord, py: WorldCoord) ColumnMask {
    switch (rule.plan) {
        .fixed => |f| return f.columns.fixedMask().?, // `.any` is rejected at compile-time
        .single => |s| return drawColumns(regionHash(noise_seed, px, py, .layout), 1, s.columns),
        .scatter => |s| {
            const h = regionHash(noise_seed, px, py, .layout);
            return drawColumns(h, drawCount(h, s.copies), .any);
        },
        .chain => |c| {
            // Hashed on the CEILING the chain hangs from (`run` cells up)
            const run: u64 = if (parent.tag.kind == .chain_run and parent.tag.data > 0) parent.tag.data else 1;
            const h = regionHash(noise_seed, px, py -% run, .layout);
            return drawColumns(h, drawCount(h, c.copies), .any);
        },
        .stamp => |s| {
            // A stamp's picture already says which columns reach the surface.
            var mask: ColumnMask = 0;
            const row = s.rows[rule.surface.anchorRow()];
            for (0..BLOCKS_PER_PARENT) |i| {
                if (row[@as(usize, s.half) * BLOCKS_PER_PARENT + i] != '.') mask |= @as(ColumnMask, 1) << @intCast(i);
            }
            return mask;
        },
    }
}

/// Answers ONE cell of a refined region. Returns an empty spec for a cell no copy claims.
///
/// Precondition: `rule` is `ruleFor(ctx.parent.id)`, and `ctx.lx`/`ctx.ly` are the cell's position
/// inside the parent's region (`wx % BLOCKS_PER_PARENT`, `wy % BLOCKS_PER_PARENT`).
pub fn refineChild(rule: Rule, ctx: Context) BlockSpec {
    switch (rule.plan) {
        .stamp => |s| return stampChild(s, ctx),
        .chain => |c| return chainChild(c, rule, ctx),
        .fixed, .single, .scatter => {
            if (!surfaceMet(rule, ctx)) return .{};
            const px, const py = ctx.parentCell();
            const mask = surfaceColumns(rule, ctx.parent, ctx.noise_seed, px, py);
            return placeStack(rule, rule.stack().?, mask, ctx);
        },
    }
}

/// Writes the cell of a `.single`/`.scatter` copy that lands here, if one does.
fn placeStack(rule: Rule, stack: []const Sprite, mask: ColumnMask, ctx: Context) BlockSpec {
    if (!claimsColumn(mask, ctx.lx)) return .{};

    const index = rule.surface.stackIndex(ctx.ly);
    // An empty stack means one cell of the parent's own evolved sprite.
    if (stack.len == 0) {
        if (index != 0) return .{};
        return spec(evolve(ctx.parent.id, ctx).id, ctx, .{});
    }
    if (index >= stack.len) return .{};
    return spec(stack[index], ctx, .{});
}

/// A block of `id` at this cell, carrying the parent's water and the given provenance.
inline fn spec(id: Sprite, ctx: Context, tag: RefinedTag) BlockSpec {
    return .{
        .id = id,
        .seed = ctx.seed,
        .water_volume = if (id.isWaterloggable()) ctx.water else 0,
        .tag = tag,
    };
}

/// How far one COLUMN of a chain reaches, in blocks below its ceiling.
///
/// Uses a primary strand anchor and distance-based mutation falloff to produce organic,
/// stepped vine curtains (e.g. main strand of 24, side strands of 14, 10, 5).
fn columnReach(c: Chain, noise_seed: Vec2u, px: WorldCoord, ceiling_y: WorldCoord, lx: u4) u64 {
    if (c.max_length == 0) return 0;
    if (c.max_length <= c.min_length) return c.min_length;

    const h_reach = regionHash(noise_seed, px, ceiling_y, .reach);
    const span = c.max_length - c.min_length + 1;
    const r_primary = c.min_length + (h_reach % span);

    // Pick primary longest strand column for this ceiling anchor (0..3)
    const primary_col: u4 = @intCast((h_reach >> 8) & 3);
    const dist: u4 = if (lx >= primary_col) lx - primary_col else primary_col - lx;
    if (dist == 0) return r_primary;

    // Side strand mutation falloff based on column distance from primary strand
    const col_h = seeding.NoiseMix.lane(h_reach, lx);
    const norm: u64 = col_h % 100; // 0..99

    const pct: u64 = switch (dist) {
        1 => 45 + (35 * norm) / 100, // 45% .. 79% of primary length
        2 => 25 + (30 * norm) / 100, // 25% .. 54% of primary length
        else => 15 + (20 * norm) / 100, // 15% .. 34% of primary length
    };

    const side_reach = (r_primary * pct) / 100;
    return @max(side_reach, 1);
}

/// One cell of a hanging chain.
///
/// The run index shows the distance from the ceiling.
/// A parent cell at distance `r` covers child runs `4(r-1) + 1` to `4r`.
/// This gives the ceiling position and the child position without a search.
/// Hashing the ceiling position keeps the columns aligned.
fn chainChild(c: Chain, rule: Rule, ctx: Context) BlockSpec {
    // a generated chain cell always carries its run, but a cell that never grew as one does not:
    // more_mossy_stone EVOLVES into vine, AND the player can place vine outright.
    // both are read as the top of a fresh chain, which lets the cap fire
    const parent_run: u64 = if (ctx.parent.tag.kind == .chain_run and ctx.parent.tag.data > 0)
        ctx.parent.tag.data
    else
        1;

    // A chain HANGS, so what it needs above depends on where in the chain this parent sits!
    const supported = if (parent_run == 1)
        ctx.neighbors[1].isSolid()
    else
        ctx.neighbors[1].id == ctx.parent.id;
    if (!supported) return .{};

    const px, const py = ctx.parentCell();
    if (!claimsColumn(surfaceColumns(rule, ctx.parent, ctx.noise_seed, px, py), ctx.lx)) return .{};

    const run = (parent_run - 1) * BLOCKS_PER_PARENT + ctx.ly + 1;
    if (run > columnReach(c, ctx.noise_seed, px, py -% parent_run, ctx.lx)) return .{};

    // Already inside a chain, so the run below is authoritative over anything `evolve()` would start.
    return spec(evolve(ctx.parent.id, ctx).id, ctx, .make(.chain_run, run));
}

/// One cell of a hard-coded macro shape.
///
/// Every parent of the shape reads the same picture, so coherence is free.
/// The floor check reads BOTH halves' floors (a shape is only ever as stable as its worst-supported parent),
/// so the halves can never disagree about whether the shape exists.
fn stampChild(s: Stamp, ctx: Context) BlockSpec {
    if (!stampFloorMet(s, ctx)) return .{};

    const x = @as(usize, s.half) * BLOCKS_PER_PARENT + ctx.lx;
    const cell = s.rows[ctx.ly][x];
    if (cell == '.') return .{};

    // Hashed on the shape's LEFTMOST parent, so both halves pick from one stream and the cell offset inside the shape decides the rest:
    // one plant is internally consistent, two plants differ.
    const px, const py = ctx.parentCell();
    const origin_x = px -% s.half;
    const h = regionHash(ctx.noise_seed, origin_x, py, .stamp);
    const cell_hash = seeding.NoiseMix.lane(h, x * BLOCKS_PER_PARENT + ctx.ly);

    if (cell == 'T') return spec(s.trunk, ctx, .make(.plant_trunk, s.tag_ttl));
    const leaf = s.leaves[@intCast(cell_hash % s.leaves.len)];
    return spec(leaf, ctx, .make(.plant_leaf, s.tag_ttl));
}

/// Whether every parent of a stamped shape has a floor. Reads this parent's own floor plus its neighbor's,
/// which is all a 2-parent shape needs and is symmetric between the halves.
inline fn stampFloorMet(s: Stamp, ctx: Context) bool {
    if (!ctx.neighbors[6].isSolid()) return false; // directly below
    if (s.halves == 1) return true;
    // below-left (5) and below-right (7): the floor under the neighboring half of the shape.
    return if (s.half == 0) ctx.neighbors[7].isSolid() else ctx.neighbors[5].isSolid();
}

const testing = std.testing;

/// Sweeps a region's worth of cells, counting the copies a plan places and where they sit.
const RegionReport = struct {
    /// Cells claimed, by sprite.
    filled: usize = 0,
    /// Distinct columns claimed on the anchor row.
    anchored_columns: usize = 0,
    /// Whether any claimed cell sits off the anchor row's stack.
    stray: bool = false,
};

fn sweepRegion(sprite: Sprite, parent: Block, neighbors: [8]Block, px: u64, py: u64) RegionReport {
    const rule = ruleFor(sprite).?;
    const seed: Vec2u = .{ 0x243f6a8885a308d3, 0x13198a2e03707344 };
    var report: RegionReport = .{};

    for (0..BLOCKS_PER_PARENT) |ly| {
        for (0..BLOCKS_PER_PARENT) |lx| {
            const out = refineChild(rule, .{
                .parent = parent,
                .neighbors = neighbors,
                .noise_seed = seed,
                .wx = px * BLOCKS_PER_PARENT + lx,
                .wy = py * BLOCKS_PER_PARENT + ly,
                .lx = @intCast(lx),
                .ly = @intCast(ly),
                .seed = 7,
                .water = 0,
            });
            if (out.id == .none) continue;
            report.filled += 1;
            if (ly == rule.surface.anchorRow()) report.anchored_columns += 1;
        }
    }
    return report;
}

test "a floor decoration keeps between one and max copies, always on its floor" {
    var neighbors: [8]Block = @splat(.empty);
    neighbors[6] = .makeBasicBlock(.stone, 1); // the floor it stands on
    neighbors[7] = .makeBasicBlock(.stone, 2);
    const parent: Block = .makeBasicBlock(.bush, 3);

    var histogram: [4]usize = @splat(0);
    for (0..600) |py| {
        for (0..4) |px| {
            const report = sweepRegion(.bush, parent, neighbors, px, py);
            try testing.expect(report.filled >= 1 and report.filled <= 3);
            // a 1x1 copy only ever sits on the anchor row
            try testing.expectEqual(report.filled, report.anchored_columns);
            histogram[report.filled] += 1;
        }
    }

    // ...and the count really is spread across the range rather than pinned at one value.
    for (1..4) |copies| try testing.expect(histogram[copies] > 0);
    const total = histogram[1] + histogram[2] + histogram[3];
    const mean = (@as(f64, @floatFromInt(histogram[1])) + 2 * @as(f64, @floatFromInt(histogram[2])) +
        3 * @as(f64, @floatFromInt(histogram[3]))) / @as(f64, @floatFromInt(total));
    try testing.expect(@abs(mean - 2.2) < 0.15); // `.bush`'s density
}

test "a decoration whose surface vanished refines into nothing" {
    const parent: Block = .makeBasicBlock(.bush, 3);
    const nothing: [8]Block = @splat(.empty);
    try testing.expectEqual(@as(usize, 0), sweepRegion(.bush, parent, nothing, 12, 34).filled);
}

test "only the flower's base rebuilds it, and it rebuilds the whole shaft" {
    var on_floor: [8]Block = @splat(.empty);
    on_floor[6] = .makeBasicBlock(.stone, 1);
    var on_stem: [8]Block = @splat(.empty);
    on_stem[6] = .makeBasicBlock(.plant_stem, 1);

    const base: Block = .makeBasicBlock(.plant_stem, 5);
    const report = sweepRegion(
        .plant_stem,
        base,
        on_floor,
        8,
        9,
    );
    // one or two flowers, each three cells tall
    try testing.expect(report.filled == 3 or report.filled == 6);
    try testing.expectEqual(report.filled / 3, report.anchored_columns);

    // the stem and flower above the base sit on more plant, so they contribute nothing
    try testing.expectEqual(@as(usize, 0), sweepRegion(
        .plant_stem,
        base,
        on_stem,
        8,
        8,
    ).filled);
    try testing.expectEqual(@as(usize, 0), sweepRegion(
        .cornflower,
        .makeBasicBlock(.cornflower, 6),
        on_stem,
        8,
        7,
    ).filled);
}

test "an installation is never duplicated" {
    var neighbors: [8]Block = @splat(.empty);
    neighbors[6] = .makeBasicBlock(.stone, 1);
    for ([_]Sprite{ .chest, .forest_furnace, .campfire, .lathe, .portal }) |sprite| {
        for (0..64) |py| {
            const report = sweepRegion(sprite, .makeBasicBlock(sprite, 9), neighbors, 3, py);
            try testing.expectEqual(@as(usize, 1), report.filled);
        }
    }

    // a portal keeps its landing inside the 2x1 area a descent drops the player onto
    const rule = ruleFor(.portal).?;
    for (0..256) |py| {
        const mask = drawColumns(
            regionHash(.{ 1, 2 }, 4, py, .layout),
            1,
            rule.plan.single.columns,
        );
        try testing.expect(mask == (1 << CENTER_LEFT) or mask == (1 << CENTER_RIGHT));
    }
}

test "a chain stays single-file, capped, and in the same columns the whole way down" {
    const cap = ruleFor(.spiralvine).?.plan.chain.max_length;
    var under_ceiling: [8]Block = @splat(.empty);
    under_ceiling[6] = .empty;
    under_ceiling[1] = .makeBasicBlock(.stone, 1); // the ceiling

    var under_vine: [8]Block = @splat(.empty);
    under_vine[1] = .makeBasicBlock(.spiralvine, 2);

    for (1..4) |run| {
        const parent = blk: {
            var b: Block = .makeBasicBlock(.spiralvine, 4);
            b.tag = .make(.chain_run, run);
            break :blk b;
        };
        const neighbors = if (run == 1) under_ceiling else under_vine;
        const report = sweepRegion(.spiralvine, parent, neighbors, 5, 100 + run);
        const columns = report.filled / BLOCKS_PER_PARENT;
        try testing.expect(columns >= 1 and columns <= 4);
    }

    // past the cap the chain simply ends, rather than growing 4x with the world
    const deep = blk: {
        var b: Block = .makeBasicBlock(.spiralvine, 4);
        b.tag = .make(.chain_run, cap);
        break :blk b;
    };
    try testing.expectEqual(@as(usize, 0), sweepRegion(
        .spiralvine,
        deep,
        under_vine,
        5,
        200,
    ).filled);
}

test "a chain hangs from rock or not at all" {
    var under_vine: [8]Block = @splat(.empty);
    under_vine[1] = .makeBasicBlock(.spiralvine, 2);

    // The top of a chain sitting under MORE chain is not anchored to anything: this is vine inherited from more_mossy_stone,
    // and letting it through is what drew lines down the middle of open caves.
    const untagged: Block = .makeBasicBlock(.spiralvine, 4);
    try testing.expectEqual(@as(usize, 0), sweepRegion(
        .spiralvine,
        untagged,
        under_vine,
        5,
        100,
    ).filled);

    // Nothing above at all is just as unanchored, whatever the run says.
    const nothing: [8]Block = @splat(.empty);
    const mid_chain = blk: {
        var b: Block = .makeBasicBlock(.spiralvine, 4);
        b.tag = .make(.chain_run, 3);
        break :blk b;
    };
    try testing.expectEqual(@as(usize, 0), sweepRegion(
        .spiralvine,
        mid_chain,
        nothing,
        5,
        100,
    ).filled);
    try testing.expectEqual(@as(usize, 0), sweepRegion(
        .spiralvine,
        untagged,
        nothing,
        5,
        100,
    ).filled);

    // ...and a floor is not a ceiling: a chain never stands on the ground.
    var on_floor: [8]Block = @splat(.empty);
    on_floor[6] = .makeBasicBlock(.stone, 1);
    try testing.expectEqual(@as(usize, 0), sweepRegion(
        .spiralvine,
        untagged,
        on_floor,
        5,
        100,
    ).filled);
}

test "an evolution into a hanging block still needs a ceiling" {
    // mossy_stone evolves into vine. Terrain fills its whole region,
    // so this is the check that keeps a vein of it from becoming a wall of vine with nothing above it.
    var under_rock: [8]Block = @splat(.empty);
    under_rock[1] = .makeBasicBlock(.stone, 1);
    const nothing: [8]Block = @splat(.empty);

    // Only the row against the ceiling, and only when a ceiling is there.
    try testing.expect(canEvolveInto(.spiralvine, under_rock, CEILING_ROW));
    for (1..BLOCKS_PER_PARENT) |ly| {
        try testing.expect(!canEvolveInto(.spiralvine, under_rock, @intCast(ly)));
    }
    for (0..BLOCKS_PER_PARENT) |ly| {
        try testing.expect(!canEvolveInto(.spiralvine, nothing, @intCast(ly)));
    }

    // Terrain is not a macro block, so nothing here constrains it.
    for (0..BLOCKS_PER_PARENT) |ly| {
        try testing.expect(canEvolveInto(.lava_stone, nothing, @intCast(ly)));
    }
    try testing.expect(startsChain(.spiralvine) and startsChain(.twinklemoss));
    try testing.expect(!startsChain(.bush) and !startsChain(.lava_stone));
}

test "an evolution's odds hold over the world, and only its arrangement changes" {
    const seed: Vec2u = .{ 0x9e3779b97f4a7c15, 0xbf58476d1ce4e5b9 };
    const N = 400;

    // Both kinds are terrain (no plan), so the anchor gate passes and only the roll is under test.
    inline for (.{
        .{ Sprite.lava_stone, 0.2 }, // blobbed
        .{ Sprite.mossy_stone, 0.688 }, // spread plus the independent return-to-stone roll
    }) |case| {
        const src: Sprite = case[0];
        var converted: usize = 0;
        // Neighbor pairs, which is what separates a patch from static:
        // for independent rolls the chance a converted cell's neighbor converted is just the conversion rate itself.
        var pairs: usize = 0;
        var prev_row: [N]bool = @splat(false);

        for (0..N) |y| {
            var left = false;
            for (0..N) |x| {
                const ctx: Context = .{
                    .parent = .empty,
                    .neighbors = @splat(.empty),
                    .noise_seed = seed,
                    .wx = @intCast(x),
                    .wy = @intCast(y),
                    .lx = 0,
                    .ly = 0,
                    .seed = 0,
                    .water = 0,
                };
                const took = evolve(src, ctx).id != src;
                if (took) {
                    converted += 1;
                    if (left) pairs += 1;
                    if (prev_row[x]) pairs += 1;
                }
                left = took;
                prev_row[x] = took;
            }
        }

        const rate = @as(f64, @floatFromInt(converted)) / @as(f64, N * N);
        const neighbor_rate = @as(f64, @floatFromInt(pairs)) / (2.0 * @as(f64, @floatFromInt(converted)));
        const want: f64 = case[1];
        try testing.expect(@abs(rate - want) < 0.01);

        if (src.evolution().?.blob == 0) {
            // Static: a converted cell says nothing about its neighbors.
            try testing.expect(@abs(neighbor_rate - rate) < 0.02);
        } else {
            // Patches: converted cells find each other far more often than chance.
            try testing.expect(neighbor_rate > rate * 1.3);
        }
    }
}

test "moss sprouts have irregular one- and two-cell starts" {
    const seed: Vec2u = .{ 0x9e3779b97f4a7c15, 0xbf58476d1ce4e5b9 };
    var under_rock: [8]Block = @splat(.empty);
    under_rock[1] = .makeBasicBlock(.stone, 1);

    var none: usize = 0;
    var short: usize = 0;
    var tall: usize = 0;
    for (0..100) |py| {
        for (0..BLOCKS_PER_PARENT) |lx| {
            const child_x = @as(WorldCoord, @intCast(lx));
            const top = evolve(.more_mossy_stone, .{
                .parent = .makeBasicBlock(.more_mossy_stone, 1),
                .neighbors = under_rock,
                .noise_seed = seed,
                .wx = child_x,
                .wy = @intCast(py * BLOCKS_PER_PARENT),
                .lx = @intCast(lx),
                .ly = 0,
                .seed = 0,
                .water = 0,
            });
            const lower = evolve(.more_mossy_stone, .{
                .parent = .makeBasicBlock(.more_mossy_stone, 1),
                .neighbors = under_rock,
                .noise_seed = seed,
                .wx = child_x,
                .wy = @intCast(py * BLOCKS_PER_PARENT + 1),
                .lx = @intCast(lx),
                .ly = 1,
                .seed = 0,
                .water = 0,
            });
            if (top.id != .spiralvine) {
                try testing.expectEqual(top.id, lower.id);
                none += 1;
            } else if (lower.id == .spiralvine) {
                try testing.expectEqual(@as(?u64, 1), top.chain_run);
                try testing.expectEqual(@as(?u64, 2), lower.chain_run);
                tall += 1;
            } else {
                try testing.expectEqual(@as(?u64, 1), top.chain_run);
                short += 1;
            }
        }
    }

    try testing.expect(none > 0 and short > 0 and tall > 0);
}

test "the terrain only pushes up under the cells a decoration really lands on" {
    const seed: Vec2u = .{ 0x243f6a8885a308d3, 0x13198a2e03707344 };
    var above_bush: [8]Block = @splat(.empty);
    above_bush[1] = .makeBasicBlock(.bush, 9); // a bush sits on top of this parent

    // The protected cells must be exactly the columns the bush's own region claims:
    // no more (which would flatten the ground under every bush) and no fewer (which would drop the bush into a hole).
    var protected_total: usize = 0;
    for (0..64) |py| {
        const wy = (py + 1) * BLOCKS_PER_PARENT; // row 0 of this parent's region
        var protected: usize = 0;
        for (0..BLOCKS_PER_PARENT) |lx| {
            const wx = 7 * BLOCKS_PER_PARENT + lx;
            if (protectsSurfaceCell(above_bush, seed, wx, wy, @intCast(lx), 0)) protected += 1;
            // rows that touch nothing are never protected
            for (1..BLOCKS_PER_PARENT) |ly| {
                try testing.expect(!protectsSurfaceCell(
                    above_bush,
                    seed,
                    wx,
                    wy + ly,
                    @intCast(lx),
                    @intCast(ly),
                ));
            }
        }

        const claimed = sweepRegion(.bush, .makeBasicBlock(.bush, 9), blk: {
            var n: [8]Block = @splat(.empty);
            n[6] = .makeBasicBlock(.stone, 1); // give the bush its floor so it actually places
            n[7] = .makeBasicBlock(.stone, 2);
            break :blk n;
        }, 7, py).filled;
        try testing.expectEqual(claimed, protected);
        try testing.expect(protected < BLOCKS_PER_PARENT); // never the whole row
        protected_total += protected;
    }
    try testing.expect(protected_total > 0);

    // plain terrain above and below protects nothing at all
    const plain: [8]Block = @splat(.makeBasicBlock(.stone, 3));
    for (0..BLOCKS_PER_PARENT) |lx| {
        for (0..BLOCKS_PER_PARENT) |ly| {
            try testing.expect(!protectsSurfaceCell(
                plain,
                seed,
                40 + lx,
                40 + ly,
                @intCast(lx),
                @intCast(ly),
            ));
        }
    }
}

test "the shrub's two halves draw one coherent tree" {
    var neighbors: [8]Block = @splat(.empty);
    neighbors[5] = .makeBasicBlock(.stone, 1);
    neighbors[6] = .makeBasicBlock(.stone, 2);
    neighbors[7] = .makeBasicBlock(.stone, 3);

    const left = sweepRegion(
        .moss_shrub1,
        .makeBasicBlock(.moss_shrub1, 4),
        neighbors,
        10,
        20,
    );
    const right = sweepRegion(
        .moss_shrub1_right,
        .makeBasicBlock(.moss_shrub1_right, 5),
        neighbors,
        11,
        20,
    );

    // Both halves fill exactly the cells their half of the picture asks for.
    var expected_left: usize = 0;
    var expected_right: usize = 0;
    for (SHRUB_ROWS) |row| {
        for (row[0..BLOCKS_PER_PARENT]) |c| expected_left += @intFromBool(c != '.');
        for (row[BLOCKS_PER_PARENT..]) |c| expected_right += @intFromBool(c != '.');
    }
    try testing.expectEqual(expected_left, left.filled);
    try testing.expectEqual(expected_right, right.filled);

    // Its canopy is tagged; tree should have no ore for the next two depths
    const rule = ruleFor(.moss_shrub1).?;
    const canopy = refineChild(rule, .{
        .parent = .makeBasicBlock(.moss_shrub1, 4),
        .neighbors = neighbors,
        .noise_seed = .{ 1, 2 },
        .wx = 10 * BLOCKS_PER_PARENT + 1,
        .wy = 20 * BLOCKS_PER_PARENT + 1,
        .lx = 1,
        .ly = 1,
        .seed = 7,
        .water = 0,
    });
    try testing.expectEqual(RefinedKind.plant_leaf, canopy.tag.kind);
    try testing.expect(canopy.tag.blocksOverlay());

    // The tag survives exactly two more depths, then the stone is ordinary stone again.
    const d2 = canopy.tag.aged();
    try testing.expect(d2.blocksOverlay());
    try testing.expect(!d2.aged().blocksOverlay());
}

test "a stamped shape needs both halves' floors" {
    var half_floor: [8]Block = @splat(.empty);
    half_floor[6] = .makeBasicBlock(.stone, 1);
    // the right half's floor is missing, so neither half draws
    try testing.expectEqual(
        @as(usize, 0),
        sweepRegion(
            .moss_shrub1,
            .makeBasicBlock(.moss_shrub1, 4),
            half_floor,
            10,
            20,
        ).filled,
    );
}
