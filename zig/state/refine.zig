//! How a macro block becomes its own 4x4 child region one depth down.
//!
//! Terrain refines by carving and warping a density field (`ancestor.zig`), but a decoration is not
//! terrain: duplicating a bush into all 16 cells of its region gives 16 bushes, and duplicating a
//! chest gives 16 chests. Every sprite listed here instead states a PLAN for its region, and
//! `refineChild()` answers one cell of it:
//!
//! - `.single` — exactly one copy, like a portal landing (chests, furnaces, cores, lathes, portals).
//! - `.scatter` — 1 to `max_copies` copies along the region's anchor row, averaging `density`
//!   (bushes, rocks, flint, mushrooms, the 1x3 flower).
//! - `.chain` — a hanging chain (vines): deduped to a couple of columns and capped in LENGTH, so a
//!   20-block vine does not become an 80-block one.
//! - `.stamp` — a hard-coded macro shape spanning one or more parents (the 2x1 moss shrub becomes a
//!   little tree). The escape hatch for anything the three generic plans cannot say.
//!
//! Three properties hold for every plan, and they are what the rest of the engine relies on:
//!
//! 1. AT LEAST ONE copy survives (`.scatter` draws from 1, never 0), so a decoration never silently
//!    disappears as the player descends.
//! 2. Copies stand ON the surface the parent was anchored to. The plan places them against the
//!    region's floor/ceiling row, and `protectsSurfaceRow()` stops the terrain parent on the far side
//!    of that row from eroding it, exactly as `anchorsPortal()` protects a portal's landing.
//! 3. Every cell of a region agrees. All the randomness comes from ONE hash of the PARENT's world
//!    cell (`regionHash()`), never of the child cell, so the 16 cells cannot disagree about how many
//!    copies there are or where they sit.
//!
//! `DecorTag` is the other half of the story: a small provenance field carried in every `Block`,
//! which is how a refined cell remembers what it grew out of after its sprite stops saying so
//! (leaf stone in a shrub's canopy) and how a vine cell remembers how far it hangs below its ceiling.
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

// ---------------------------------------------------------------------------------------------
// Provenance tag
// ---------------------------------------------------------------------------------------------

/// What a block was refined out of, once its own sprite no longer says so.
///
/// Deliberately tiny (a `Block` has room for 10 bits, see `memory.Block.tag`) and NOT saved: a tag is
/// re-derived every time a chunk is generated, and a cell the player edits keeps the edit and loses
/// the tag (`world.ModCell` stores only what generation cannot recover).
pub const DecorKind = enum(u4) {
    /// No provenance; the overwhelmingly common case.
    none = 0,
    /// A cell of a hanging chain. `data` is how many cells below its ceiling this one sits
    /// (1 = directly below), which is what lets the next depth continue the chain and cap it.
    chain_run,
    /// Canopy of a stamped plant. `data` counts the depths the tag still applies (see `aged()`).
    plant_leaf,
    /// Trunk/stem of a stamped plant. `data` behaves as in `plant_leaf`.
    plant_trunk,
    /// Room for more kinds without touching the `Block` layout.
    _,
};

/// A `DecorKind` plus its 6 bits of kind-specific payload.
pub const DecorTag = packed struct(u10) {
    kind: DecorKind = .none,
    /// Kind-specific: a chain's run index, or the depths a plant tag has left. Saturates rather than
    /// wrapping, so a value of `DATA_MAX` means "at least this much".
    data: u6 = 0,

    /// Largest `data` value; a chain longer than this reads as exactly this long, which only ever
    /// makes the length cap fire sooner.
    pub const DATA_MAX: u6 = std.math.maxInt(u6);

    /// Saturating `data` constructor, so no caller has to think about the field's width.
    pub inline fn make(kind: DecorKind, data: u64) DecorTag {
        return .{ .kind = kind, .data = @intCast(@min(data, DATA_MAX)) };
    }

    /// The same tag one depth further down: a plant tag counts down and vanishes at zero, and
    /// everything else is dropped, since only a plan that re-states a tag may carry one.
    ///
    /// A chain's run is NOT aged here; it is recomputed from the parent's run by the chain plan,
    /// because a child's distance below the ceiling is four times its parent's, not one less.
    pub inline fn aged(self: DecorTag) DecorTag {
        return switch (self.kind) {
            .plant_leaf, .plant_trunk => if (self.data <= 1) .{} else .{ .kind = self.kind, .data = self.data - 1 },
            else => .{},
        };
    }

    /// Whether an ore or gem may NOT grow in this block.
    /// A shrub's canopy is stone at the next depth, and stone is where ore goes; this is what keeps
    /// a tree from sprouting copper for as long as it still reads as a tree.
    pub inline fn blocksOverlay(self: DecorTag) bool {
        return switch (self.kind) {
            .plant_leaf, .plant_trunk => true,
            else => false,
        };
    }
};

// ---------------------------------------------------------------------------------------------
// Rules
// ---------------------------------------------------------------------------------------------

/// The surface a decoration is fixed to, which decides which row of its child region holds the copies
/// and which neighbor has to be solid for any copy to exist at all.
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
/// The count is `1 + Binomial(max - 1, p)` with `p = (density - 1) / (max - 1)`, which puts the mean
/// at exactly `density` and never leaves `[1, max]`. `density` is THE tuning knob: raise it for
/// clutter, lower it toward 1 to thin a decoration out as the player descends.
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

/// A chain hanging off a ceiling, deduped in width and capped in length.
pub const Chain = struct {
    /// Longest run, in child blocks, measured from the ceiling.
    /// The world is 4x larger each depth, so leaving this at the parent's own `max_length` keeps a
    /// vine the same number of BLOCKS long rather than letting it grow 4x with every descent.
    max_length: u32,
    /// Columns the chain occupies; 1 keeps it single-file.
    copies: Count = count(1.3, 2),
};

/// A hard-coded macro shape, for anything the generic plans cannot express.
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
    single: Single,
    scatter: Scatter,
    chain: Chain,
    stamp: Stamp,
};

/// One sprite's refinement.
pub const Rule = struct {
    surface: Surface,
    plan: Plan,

    /// Copies of a `.single`/`.scatter` plan, or null for the plans that place cells themselves.
    inline fn stack(self: Rule) ?[]const Sprite {
        return switch (self.plan) {
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
const portal_single: Rule = .{ .surface = .floor, .plan = .{ .single = .{ .columns = .center_pair } } };
const invportal_single: Rule = .{ .surface = .ceiling, .plan = .{ .single = .{ .columns = .center_pair } } };

/// The 1x3 flower, rebuilt from its base upward. Only the parent standing ON the floor refines
/// (`surfaceMet()` fails for the stem and the flower above it), so one flower makes one or two
/// flowers rather than three stacked fragments.
const flower_stack = [_]Sprite{ .plant_stem, .plant_stem, .cornflower };
const flower_rule: Rule = .{ .surface = .floor, .plan = .{ .scatter = .{
    .copies = count(1.6, 2),
    .stack = &flower_stack,
} } };

/// The little tree a 2x1 moss shrub becomes: a 2-wide trunk on the floor under a canopy.
/// Tunable freely; both halves read the same picture, so they cannot disagree.
const SHRUB_ROWS = [_][]const u8{
    ".LLLLLL.",
    "LLLLLLLL",
    ".LLTTLL.",
    "...TT...",
};

fn shrubStamp(comptime half: u2) Rule {
    return .{ .surface = .floor, .plan = .{ .stamp = .{
        .rows = &SHRUB_ROWS,
        .half = half,
        .halves = 2,
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
    .{ .mushroom, .{ .surface = .floor, .plan = .{ .scatter = .{
        .copies = count(2.0, 3),
        .stack = &[_]Sprite{.big_mushroom},
    } } } },
    .{ .big_mushroom, floorScatter(1.5, 2) },

    // The flower's two sprites share one rule; only its base ever stands on a floor.
    .{ .cornflower, flower_rule },
    .{ .plant_stem, flower_rule },

    .{ .ceiling_flower, .{ .surface = .ceiling, .plan = .{ .scatter = .{ .copies = count(1.8, 3) } } } },

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
    .{ .moss_shrub1, shrubStamp(0) },
    .{ .moss_shrub1_right, shrubStamp(1) },
    .{ .moss_shrub2, shrubStamp(0) },
    .{ .moss_shrub2_right, shrubStamp(1) },
};

/// How much longer, in blocks, a chain may reach than the same chain at the base depth.
///
/// 1 keeps a vine the same number of blocks long at every depth, which is what makes the cost of
/// refining one O(1): a cell reads its parent's run index rather than walking up to the ceiling.
/// Raising it costs nothing per cell, it just lets vines lengthen as the world grows;
/// `DecorTag.DATA_MAX` bounds how far it can go.
const CHAIN_LENGTH_MULTIPLIER = 1;

/// Sparse-to-dense lookup: sprite ID -> its rule, or null. One indexed load at runtime.
///
/// Chain rules are appended from `decorations.columns` rather than written out, so a vine added to
/// `decorations/vines.zig` is capped and deduped without anyone remembering to come back here.
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

        const cap = feature.max_length * CHAIN_LENGTH_MULTIPLIER;
        // A run has to be representable, or a cell would forget how far down it hangs. Saturating only
        // ever ends a chain early, but silently: better to say so here.
        if (cap > DecorTag.DATA_MAX)
            @compileError("Column feature `" ++ @tagName(feature.sprite) ++ "`'s capped length does not fit a `DecorTag`.");

        table[id] = .{ .surface = .suspended, .plan = .{ .chain = .{ .max_length = cap } } };
    }

    break :blk table;
};

comptime {
    @setEvalBranchQuota(50000);
    for (rule_table, 0..) |maybe_rule, id| {
        const rule = maybe_rule orelse continue;
        const sprite: Sprite = @enumFromInt(id);

        // The plan places copies against a surface, so the sprite must agree about which one it is,
        // or the copies would sit on a row nothing anchors them to and the cascade would clear them.
        // `AnchorKind.none` is not a disagreement: a sprite may state its support through
        // `SpriteProps.requires` instead, as `plant_stem` does (solid OR more stem below).
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
            .scatter => {},
            .chain => |c| {
                if (c.max_length == 0) @compileError("A chain must be able to reach at least one cell.");
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

        // A stack has to fit the region, or its top cells would land in the parent above.
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

/// Whether `sprite` refines into copies that rest on a floor directly below it.
pub inline fn standsOnFloor(sprite: Sprite) bool {
    const rule = ruleFor(sprite) orelse return false;
    return rule.surface == .floor;
}

/// Whether `sprite` refines into copies that hang from a ceiling directly above it.
pub inline fn hangsFromCeiling(sprite: Sprite) bool {
    const rule = ruleFor(sprite) orelse return false;
    return rule.surface == .ceiling or rule.surface == .suspended;
}

/// Whether the child cell at region row `ly` is a surface a refined decoration is about to land on.
///
/// That surface is a PROMISE: the decoration's own region places copies against it unconditionally,
/// so the carve may not take it, exactly as `ancestor.anchorsPortal()` protects a landing pad.
/// Only the single row that touches the decoration is protected, so the rest of the parent still erodes.
///
/// Neighbors are row-major with the center removed, so index 1 is above and 6 below.
pub inline fn protectsSurfaceRow(n: [8]Block, ly: u4) bool {
    if (ly == CEILING_ROW and standsOnFloor(n[1].id)) return true;
    if (ly == FLOOR_ROW and hangsFromCeiling(n[6].id)) return true;
    return false;
}

// ---------------------------------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------------------------------

/// Everything one child cell needs to know to answer its own refinement.
pub const Context = struct {
    /// The parent block being refined, which carries its own `tag`, `hp`, and sprite.
    parent: Block,
    /// The parent's 8 neighbors, row-major with the center removed (see `protectsSurfaceRow()`).
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
};

/// One region-wide hash: a pure function of the PARENT's cell, so no two cells of a region disagree.
inline fn regionHash(noise_seed: Vec2u, px: WorldCoord, py: WorldCoord, comptime salt: Salt) u64 {
    return FastHash.hash2dWorld(noise_seed, px +% @intFromEnum(salt), py -% @intFromEnum(salt));
}

/// Whether the surface this plan anchors to is actually there.
///
/// The dedupe rule that makes the 1x3 flower work: of its three parents, only the one standing on
/// solid ground refines, and the two above it vanish instead of each rebuilding the whole flower.
/// For a chain, the ceiling may equally be more chain, exactly as `AnchorKind.suspended` says.
inline fn surfaceMet(rule: Rule, ctx: Context) bool {
    return switch (rule.surface) {
        .floor => ctx.neighbors[6].isSolid(),
        .ceiling => ctx.neighbors[1].isSolid(),
        .suspended => ctx.neighbors[1].isSolid() or ctx.neighbors[1].id == ctx.parent.id,
    };
}

/// Which columns of the region a plan may use.
pub const Columns = enum {
    /// Any of the region's columns.
    any,
    /// The two center columns only, which is the 2x1 area a portal descent lands the player on.
    center_pair,
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
inline fn drawColumns(h: u64, n: u4, columns: Columns) ColumnMask {
    if (columns == .center_pair) {
        // One 2x1 landing area, so the choice is only ever which of its two columns.
        // Kept bit-for-bit the same as the portal placement this replaced.
        return @as(ColumnMask, 1) << (if (h & 1 == 0) CENTER_LEFT else CENTER_RIGHT);
    }

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
    // `drawColumns()` consumes `log2(BLOCKS_PER_PARENT!)` bits of the high half of one hash.
    var needed: f64 = 0;
    for (1..BLOCKS_PER_PARENT + 1) |i| needed += std.math.log2(@as(f64, @floatFromInt(i)));
    if (needed > 32) @compileError("A column shuffle needs more bits than half a hash provides.");
}

/// Answers ONE cell of a refined region. Returns an empty spec for a cell no copy claims.
///
/// Precondition: `rule` is `ruleFor(ctx.parent.id)`, and `ctx.lx`/`ctx.ly` are the cell's position
/// inside the parent's region (`wx % BLOCKS_PER_PARENT`, `wy % BLOCKS_PER_PARENT`).
pub fn refineChild(rule: Rule, ctx: Context) BlockSpec {
    switch (rule.plan) {
        .stamp => |s| return stampChild(s, ctx),
        .chain => |c| return chainChild(c, ctx),
        .single => |s| {
            if (!surfaceMet(rule, ctx)) return .{};
            const px, const py = ctx.parentCell();
            const h = regionHash(ctx.noise_seed, px, py, .layout);
            return placeStack(rule, s.stack, drawColumns(h, 1, s.columns), ctx);
        },
        .scatter => |s| {
            if (!surfaceMet(rule, ctx)) return .{};
            const px, const py = ctx.parentCell();
            const h = regionHash(ctx.noise_seed, px, py, .layout);
            return placeStack(rule, s.stack, drawColumns(h, drawCount(h, s.copies), .any), ctx);
        },
    }
}

/// Writes the cell of a `.single`/`.scatter` copy that lands here, if one does.
inline fn placeStack(rule: Rule, stack: []const Sprite, mask: ColumnMask, ctx: Context) BlockSpec {
    if (!claimsColumn(mask, ctx.lx)) return .{};

    const index = rule.surface.stackIndex(ctx.ly);
    // An empty stack means one cell of the parent's own evolved sprite.
    if (stack.len == 0) {
        if (index != 0) return .{};
        return spec(ctx.parent.id.evolvesTo(), ctx, .{});
    }
    if (index >= stack.len) return .{};
    return spec(stack[index], ctx, .{});
}

/// A block of `id` at this cell, carrying the parent's water and the given provenance.
inline fn spec(id: Sprite, ctx: Context, tag: DecorTag) BlockSpec {
    return .{
        .id = id,
        .seed = ctx.seed,
        .water_volume = if (id.isWaterloggable()) ctx.water else 0,
        .tag = tag,
    };
}

/// One cell of a hanging chain.
///
/// The run index is the whole trick. A parent cell that sits `r` cells below its ceiling covers child
/// runs `4(r-1) + 1 .. 4r`, so a child knows its own distance from the ceiling without walking
/// anything, and the cap can then bite at a fixed number of BLOCKS instead of scaling with depth.
/// It also locates the ceiling itself (`r` cells up), which is the one cell every parent of a chain
/// agrees on, so hashing it is what keeps the chain in the same columns the whole way down.
fn chainChild(c: Chain, ctx: Context) BlockSpec {
    if (!surfaceMet(.{ .surface = .suspended, .plan = .{ .chain = c } }, ctx)) return .{};

    // A generated chain cell always carries its run, but a cell that never grew as one does not:
    // `mossy_stone` EVOLVES into vine, and the player can place vine outright. Both are read as the
    // top of a fresh chain, which can only ever make the cap fire sooner.
    const parent_run: u64 = if (ctx.parent.tag.kind == .chain_run and ctx.parent.tag.data > 0)
        ctx.parent.tag.data
    else
        1;

    const run = (parent_run - 1) * BLOCKS_PER_PARENT + ctx.ly + 1;
    if (run > c.max_length) return .{};

    const px, const py = ctx.parentCell();
    // The ceiling this chain hangs from, in parent cells. Wrapping is correct and required: a
    // coordinate is a position in a 2^69 space, and only its consistency across the chain matters.
    const ceiling_y = py -% parent_run;
    const h = regionHash(ctx.noise_seed, px, ceiling_y, .layout);
    if (!claimsColumn(drawColumns(h, drawCount(h, c.copies), .any), ctx.lx)) return .{};

    return spec(ctx.parent.id.evolvesTo(), ctx, .make(.chain_run, run));
}

/// One cell of a hard-coded macro shape.
///
/// Every parent of the shape reads the same picture, so coherence is free. The floor check reads BOTH
/// halves' floors (a shape is only ever as stable as its worst-supported parent), so the halves can
/// never disagree about whether the shape exists.
fn stampChild(s: Stamp, ctx: Context) BlockSpec {
    if (!stampFloorMet(s, ctx)) return .{};

    const x = @as(usize, s.half) * BLOCKS_PER_PARENT + ctx.lx;
    const cell = s.rows[ctx.ly][x];
    if (cell == '.') return .{};

    // Hashed on the shape's LEFTMOST parent, so both halves pick from one stream and the cell offset
    // inside the shape decides the rest: one plant is internally consistent, two plants differ.
    const px, const py = ctx.parentCell();
    const origin_x = px -% s.half;
    const h = regionHash(ctx.noise_seed, origin_x, py, .stamp);
    const cell_hash = seeding.NoiseMix.lane(h, x * BLOCKS_PER_PARENT + ctx.ly);

    if (cell == 'T') return spec(s.trunk, ctx, .make(.plant_trunk, s.tag_ttl));
    const leaf = s.leaves[@intCast(cell_hash % s.leaves.len)];
    return spec(leaf, ctx, .make(.plant_leaf, s.tag_ttl));
}

/// Whether every parent of a stamped shape has a floor. Reads this parent's own floor plus its
/// neighbor's, which is all a 2-parent shape needs and is symmetric between the halves.
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
    const report = sweepRegion(.plant_stem, base, on_floor, 8, 9);
    // one or two flowers, each three cells tall
    try testing.expect(report.filled == 3 or report.filled == 6);
    try testing.expectEqual(report.filled / 3, report.anchored_columns);

    // The stem and flower above the base sit on more plant, so they contribute nothing.
    try testing.expectEqual(@as(usize, 0), sweepRegion(.plant_stem, base, on_stem, 8, 8).filled);
    try testing.expectEqual(@as(usize, 0), sweepRegion(.cornflower, .makeBasicBlock(.cornflower, 6), on_stem, 8, 7).filled);
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

    // A portal keeps its landing inside the 2x1 area a descent drops the player onto.
    const rule = ruleFor(.portal).?;
    for (0..256) |py| {
        const mask = drawColumns(regionHash(.{ 1, 2 }, 4, py, .layout), 1, rule.plan.single.columns);
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

    // A chain 3 parents long: every parent must land its cells in the SAME columns, or the vine
    // breaks into diagonal fragments.
    var first_columns: ?usize = null;
    for (1..4) |run| {
        const parent = blk: {
            var b: Block = .makeBasicBlock(.spiralvine, 4);
            b.tag = .make(.chain_run, run);
            break :blk b;
        };
        const neighbors = if (run == 1) under_ceiling else under_vine;
        // the vine hangs down the column, so the parent cell's y advances with the run
        const report = sweepRegion(.spiralvine, parent, neighbors, 5, 100 + run);
        const columns = report.filled / BLOCKS_PER_PARENT;
        try testing.expect(columns >= 1 and columns <= 2);
        if (first_columns) |expected| try testing.expectEqual(expected, columns);
        first_columns = columns;
    }

    // Past the cap the chain simply ends, rather than growing 4x with the world.
    const deep = blk: {
        var b: Block = .makeBasicBlock(.spiralvine, 4);
        b.tag = .make(.chain_run, cap);
        break :blk b;
    };
    try testing.expectEqual(@as(usize, 0), sweepRegion(.spiralvine, deep, under_vine, 5, 200).filled);
}

test "the shrub's two halves draw one coherent tree" {
    var neighbors: [8]Block = @splat(.empty);
    neighbors[5] = .makeBasicBlock(.stone, 1);
    neighbors[6] = .makeBasicBlock(.stone, 2);
    neighbors[7] = .makeBasicBlock(.stone, 3);

    const left = sweepRegion(.moss_shrub1, .makeBasicBlock(.moss_shrub1, 4), neighbors, 10, 20);
    const right = sweepRegion(.moss_shrub1_right, .makeBasicBlock(.moss_shrub1_right, 5), neighbors, 11, 20);

    // Both halves fill exactly the cells their half of the picture asks for.
    var expected_left: usize = 0;
    var expected_right: usize = 0;
    for (SHRUB_ROWS) |row| {
        for (row[0..BLOCKS_PER_PARENT]) |c| expected_left += @intFromBool(c != '.');
        for (row[BLOCKS_PER_PARENT..]) |c| expected_right += @intFromBool(c != '.');
    }
    try testing.expectEqual(expected_left, left.filled);
    try testing.expectEqual(expected_right, right.filled);

    // Its canopy is tagged, which is what keeps ore out of the tree for the next two depths.
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
    try testing.expectEqual(DecorKind.plant_leaf, canopy.tag.kind);
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
        sweepRegion(.moss_shrub1, .makeBasicBlock(.moss_shrub1, 4), half_floor, 10, 20).filled,
    );
}
