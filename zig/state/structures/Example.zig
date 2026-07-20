//! DELIBERATELY NOT REGISTERED in the `structures` tuple: this file is documentation that happens to compile,
//! so it must never occupy a spawn cell or cost the real structures a collision scan.
//! The test at the bottom is what keeps it honest; if this file stops compiling, the docs have rotted.
//!
//! Read this file top to bottom to learn the structure API. It builds one small hut and, along the way,
//! demonstrates every decision a real structure has to make. Comment density here is intentionally far
//! above the codebase norm, because the comments ARE the deliverable.
//!
//! The hut, drawn the way `Chamber.zig` draws its own header:
//!
//!     #########     <- roof
//!     #.......#
//!     #...c...#     <- chest on the floor, somewhere in the middle
//!     #.......#
//!     #########     <- floor, resting directly on the terrain surface
//!
//! `#` is wall, `.` is carved-out air, `c` is the chest.
const std = @import("std");
const dw = @import("../../root.zig");
const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;
const structures = @import("../structures.zig");
const Rect = structures.Rect;

// ---------------------------------------------------------------------------------------------------
// 1. THE FOUR REQUIRED DECLARATIONS
// ---------------------------------------------------------------------------------------------------

// Every structure lives on its own grid of square cells, `spawn_area` blocks on a side, covering the whole
// world. At most one placement of this kind is considered per cell. So `spawn_area` is the density dial:
// bigger cells mean the structure is rarer and more spread out, and it must be a power of two.
//
// The footprint may be anchored ANYWHERE in its cell (see `jitter()` below), which means it can overhang
// into the neighboring cell. structures.zig budgets for exactly one cell of overhang, which is why
// max_w and max_h may never exceed spawn_area. There is a comptime check for this in structures.zig.
pub const spawn_area: u32 = 32;

// The largest footprint this structure can ever occupy. structures.zig uses these to decide how far to
// scan back when asking "which candidate covers this block?", so they must be upper bounds, not typical
// values. Declaring them too small silently truncates the structure at chunk borders; too large just
// costs a slightly wider scan. When in doubt, round up.
//
// Here the hut is a fixed size, so these are exact. A structure whose getBounds() rolls a random size
// (see Geode.zig) must declare the maximum that roll can produce.
pub const max_w: u32 = size_x;
// Note the SNAP_DEPTH term. getBounds() below is allowed to slide the box downward to seat it on the
// ground, and that slide counts toward the vertical reach. Forgetting to add it here is a classic bug:
// the structure generates fine, then loses its bottom rows whenever it seats near a chunk boundary.
pub const max_h: u32 = size_y + SNAP_DEPTH;

// The odds a given cell even ATTEMPTS a placement. This is a ROLL, not a density.
//
// Read that again, because it is the single most misleading number in this API: terrain rules run AFTER
// this roll and throw most survivors away. A structure with target_chance 1.0 and a strict flatness rule
// can easily end up rarer than one with target_chance 0.05 and no rules at all. There is no closed form
// for the real density; the only way to know is to sample the world (see debug/audit.zig).
pub const target_chance: f64 = 1.0;

// Optional, defaults to 1. How many placements to try within a single cell before giving up on it.
//
// Only worth raising for a heavily gated structure. The hut needs flat ground, which is rare, so a single
// jitter draw per cell would waste nearly every cell it was offered. Retrying is cheap here because a
// doomed seating scan bails after a couple of columns. If your structure has no terrain rules, leave this
// at 1: extra attempts would just be extra work that always succeeds on the first try.
pub const attempts: u32 = 8;

/// Width of the hut, walls included.
const size_x: i32 = 9;
/// Height of the hut, roof and floor included.
const size_y: i32 = 5;

/// How far `getBounds()` may pull the box DOWN to seat it on the terrain.
/// Seating only ever moves the box down, never up, so the anchor can never leave its own cell.
const SNAP_DEPTH: i32 = 6;

// ---------------------------------------------------------------------------------------------------
// 2. EDGES AND REGIONS: THE THING EVERYONE GETS WRONG FIRST
// ---------------------------------------------------------------------------------------------------

// A `Region` is a box expressed RELATIVE to the candidate's footprint, so a rule can be written once and
// still mean the right thing wherever the structure lands. Each of its four sides is an `Edge`: pick which
// side of the footprint to anchor to (`.start` or `.end`), then offset from there.
//
// The trap: `.end` is EXCLUSIVE. `.{ .at = .end }` names the first row PAST the footprint, not its last
// row. So:
//
//   - the footprint itself             .{}                                       (all four defaults)
//   - the single row directly below it .{ .y0 = .{ .at = .end },
//                                        .y1 = .{ .at = .end, .off = 1 } }
//   - the single row directly above it .{ .y0 = .{ .at = .start, .off = -1 },
//                                        .y1 = .{ .at = .start } }
//   - the bottom row OF the footprint  .{ .y0 = .{ .at = .end, .off = -1 },
//                                        .y1 = .{ .at = .end } }
//
// Per-field docs live on `Region` and `Level` in structures.zig; they are the normative reference, and
// this file deliberately does not restate them.

/// The ground line: the row the terrain's topmost solid block must land on.
/// It is the row directly BELOW the box, which is what makes the hut stand ON the ground rather than sink
/// into it. Seating the box so its own last row coincided with the surface would bury that row a block deep.
const ground_row: structures.Edge = .{ .at = .end };

// ---------------------------------------------------------------------------------------------------
// 3. CONSTRAINTS: TERRAIN RULES
// ---------------------------------------------------------------------------------------------------

// Every rule here is ANDed. Source order does NOT matter: structures.zig sorts them cheapest-first at
// compile time (by how many terrain samples each costs), so a 1-sample "is there ground under me" test
// always runs before a 30-sample "is my whole interior clear" one. Write them in whatever order reads best.
//
// Terrain INSIDE the footprint is deliberately left unconstrained. The hut carves out whatever it lands on,
// so demanding the interior already be empty would reject almost every otherwise fine spot.
//
// WHERE TO PUT A RULE: if the rule is something you can check WHILE computing bounds, put it in getBounds()
// instead. Rejecting there lets an expensive scan bail early, and it lets `attempts` retry immediately.
// Use `constraints` for rules that only make sense once the final box is known.
pub const constraints = [_]structures.Constraint{
    // Both bottom corners rest on solid terrain. One sample each, and between them they kill every
    // mid-air candidate before any wider scan gets a chance to run.
    .{ .solid = .{
        .x0 = .{ .at = .start },
        .x1 = .{ .at = .start, .off = 1 },
        .y0 = ground_row,
        .y1 = .{ .at = .end, .off = 1 },
    } },
    .{ .solid = .{
        .x0 = .{ .at = .end, .off = -1 },
        .x1 = .{ .at = .end },
        .y0 = ground_row,
        .y1 = .{ .at = .end, .off = 1 },
    } },
    // A roof pressed into rock reads as a wall rather than a building, so the row above must be open.
    .{ .empty = .{
        .y0 = .{ .at = .start, .off = -1 },
        .y1 = .{ .at = .start },
    } },
    // The remaining Constraint variants, for reference:
    //
    //   .level  - profiles every column in a span and demands the ground be flat enough to build on.
    //             Its window is deliberately asymmetric (max_rise is forgiving, max_drop should stay 0,
    //             because ground below the box leaves a visible gap and the structure appears to float).
    //             The hut does its flatness check inside getBounds() instead, so it can bail early.
    //
    //   .custom - an escape hatch taking the whole Rect. Always sorted last, since its cost is opaque.
    //             Reach for it only when the vocabulary above genuinely cannot express the rule.
};

// ---------------------------------------------------------------------------------------------------
// 4. getBounds(): WHERE THE FOOTPRINT LANDS
// ---------------------------------------------------------------------------------------------------

/// Decides where in the cell this candidate sits, or returns null to reject the cell outright.
///
/// Always route through `jitter()`. It anchors the footprint uniformly ANYWHERE in the cell, overhang
/// included. Drawing an origin from `[0, spawn_area - w)` instead would seem more natural but blanks out
/// a band along every cell edge, which makes the spawn lattice visible as a regular grid in the world.
pub fn getBounds(state: *HashState, cx: i32, cy: i32) ?Rect {
    var bounds = structures.jitter(state, cx, cy, spawn_area, size_x, size_y);
    const line = ground_row.resolve(bounds.y_start, bounds.y_end);

    // Walk every column looking for the terrain surface, and demand they all agree. This is the flatness
    // rule, done here rather than as a `.level` constraint so a bad candidate dies on its first or second
    // column instead of paying for a full profile.
    var surface: ?i32 = null;
    var x = bounds.x_start;
    while (x < bounds.x_end) : (x += 1) {
        // A column with no surface in reach is either open air or solid rock all the way down.
        // Either way the box has nothing to rest on, so the whole candidate is rejected.
        const column = structures.surfaceY(x, line, line + SNAP_DEPTH) orelse return null;
        if (surface) |s| {
            if (column != s) return null; // uneven ground
        } else surface = column;
    }

    // Slide the box down so its bottom row sits exactly on the surface we found.
    // This is the movement `max_h` had to budget for with SNAP_DEPTH.
    const seat = surface.? - line;
    bounds.y_start += seat;
    bounds.y_end += seat;
    return bounds;
}

// ---------------------------------------------------------------------------------------------------
// 5. generate(): ONE BLOCK AT A TIME, AND THE CONTRACT THAT MAKES IT WORK
// ---------------------------------------------------------------------------------------------------

// generate() is called once per block, and it must be a PURE function of its arguments. structures.zig
// re-derives `state` from scratch for every single block, so two blocks only agree about the structure
// they belong to if they both walk the hash stream the same way.
//
// That gives one non-obvious rule, and it is the rule most likely to bite you:
//
//   ANY DECISION SHARED ACROSS THE FOOTPRINT MUST BE DRAWN BEFORE ANY POSITION-DEPENDENT BRANCH.
//
// "Which stone is this hut built from" is shared by every wall block, so all of those blocks must reach
// that draw having consumed exactly the same amount of the stream. Draw it at the top, unconditionally.
// If you instead drew it inside `if (is_wall)`, the interior blocks would skip the draw, and the next
// value they pulled would be misaligned against what the wall blocks pulled.
//
// The two randomness patterns you actually need, both already used in Geode.zig:
//
//   CORRELATED (one value for the whole structure): draw from `state`, the candidate-level stream.
//     Every block of this candidate re-derives the same stream and, obeying the rule above, reads the same
//     value. Geode picks its whole shell colour this way.
//
//   UNCORRELATED (each block rolls independently): draw from `makeBlockHash(struct_seed, wx, wy, id)`,
//     which is keyed on the block's own coordinates. Geode scatters gems through its core this way.
//     The `id` argument is a comptime namespace tag; give each independent use its own so two unrelated
//     rolls in the same structure cannot end up correlated with each other.
//
// Beware: because makeBlockHash is keyed on wx/wy, it is exactly the WRONG tool for a shared decision.

/// Unique id for this file's uncorrelated per-block rolls.
/// Values only need to be distinct from the other rolls in the same structure.
const SPECKLE_ROLL_ID = 0;

pub fn generate(
    starting_sprite: Sprite,
    wx: u32,
    wy: u32,
    cx: i32,
    cy: i32,
    bounds: Rect,
    state: *HashState,
    struct_seed: Vec2u,
) ?structures.StructureResult {
    // The cell coordinates are already baked into `state` by structures.zig, and this structure has no
    // use for the terrain sprite it is replacing.
    _ = starting_sprite;
    _ = cx;
    _ = cy;

    // CORRELATED DRAW, taken first and unconditionally, per the contract above.
    // Every block of this hut sees the same answer, so the whole building matches.
    const wall: Sprite = if (state.getChance(0.5)) .stone else .pink_stone;

    // Also correlated: which column the chest stands in. Drawn here rather than lower down for the same
    // reason, even though only one block will ever act on it.
    const chest_x = 1 + state.getLimit(i32, size_x - 2);

    // Convert absolute world coordinates into coordinates local to the footprint.
    const local_x = @as(i32, @bitCast(wx)) - bounds.x_start;
    const local_y = @as(i32, @bitCast(wy)) - bounds.y_start;

    // Returning null means "this block is not mine": structures.zig then offers the block to the next
    // structure down the priority list, and failing that leaves the natural terrain alone.
    //
    // This check is mandatory. A candidate is consulted for every block in its BOUNDING BOX, and for
    // blocks in neighboring cells its box may overhang into, so generate() is routinely asked about
    // blocks outside its own shape. Keep it first: it is the hot path.
    if (local_x < 0 or local_y < 0 or local_x >= size_x or local_y >= size_y) return null;

    const is_edge = local_x == 0 or local_x == size_x - 1 or
        local_y == 0 or local_y == size_y - 1;

    if (is_edge) {
        // UNCORRELATED DRAW: speckle a few wall blocks with the other stone, independently per block.
        // Note this is a fresh hash keyed on wx/wy, NOT a draw from `state`, so it cannot desynchronise
        // the shared decisions above no matter which blocks reach it.
        var block_state = structures.makeBlockHash(struct_seed, wx, wy, SPECKLE_ROLL_ID);
        if (block_state.getChance(0.1)) {
            return .{ .id = if (wall == .stone) .pink_stone else .stone };
        }
        return .{ .id = wall };
    }

    // The chest sits on the floor, in the column chosen above.
    if (local_x == chest_x and local_y == size_y - 2) {
        // A dry waterloggable block placed in a row the structure also floods MUST set water_volume, or
        // the fluid sim floods the cell on the chunk's first tick. This hut never places water, so 0 is
        // correct here; see `StructureResult` in structures.zig for when it is not.
        return .{ .id = .chest };
    }

    // Everything else is carved out. `.none` is an explicit "make this air", which is NOT the same as
    // returning null: null defers to whatever was already there, `.none` actively clears it.
    return .{ .id = .none };
}

// ---------------------------------------------------------------------------------------------------
// 6. THE TEST THAT KEEPS THIS FILE HONEST
// ---------------------------------------------------------------------------------------------------

const testing = std.testing;

test "Example structure stays compilable and self-consistent" {
    // The declarations structures.zig requires, checked the way its own comptime block would if this file
    // were registered. Keeping these here is what lets the file stay out of the spawn tuple safely.
    try testing.expect(std.math.isPowerOfTwo(spawn_area));
    try testing.expect(max_w <= spawn_area);
    try testing.expect(max_h <= spawn_area);
    try testing.expect(target_chance >= 0.0 and target_chance <= 1.0);

    // The constraint sorter must accept this list and preserve its length.
    const sorted = comptime structures.sortConstraints(&constraints, max_w, max_h);
    try testing.expectEqual(constraints.len, sorted.len);

    // generate() is pure, so it can be exercised without any world state. A hand-built HashState and a
    // hand-built Rect are enough; note getBounds() is NOT called here, since it samples real terrain.
    const bounds: Rect = .{ .x_start = 0, .y_start = 0, .x_end = size_x, .y_end = size_y };
    const seed: Vec2u = .{ 0x1234, 0x5678 };

    // A block outside the footprint must be declined, so the next structure down can claim it.
    {
        var state: HashState = .{ .seed_vector = seed, .x = 0, .y = 0 };
        try testing.expectEqual(
            @as(?structures.StructureResult, null),
            generate(.stone, @bitCast(size_x), 0, 0, 0, bounds, &state, seed),
        );
    }

    // The corner is always wall, and every block of the footprint must be claimed.
    {
        var state: HashState = .{ .seed_vector = seed, .x = 0, .y = 0 };
        const corner = generate(.stone, 0, 0, 0, 0, bounds, &state, seed);
        try testing.expect(corner != null);
    }

    // The contract from section 5, asserted rather than merely described: every block of the footprint
    // re-derives the stream independently, so they must all agree on the correlated wall sprite.
    // If someone moves a shared draw behind a positional branch, this is what catches it.
    var wall_seen: ?Sprite = null;
    var y: u32 = 0;
    while (y < size_y) : (y += 1) {
        var x: u32 = 0;
        while (x < size_x) : (x += 1) {
            const on_edge = x == 0 or x == size_x - 1 or y == 0 or y == size_y - 1;
            if (!on_edge) continue;

            var state: HashState = .{ .seed_vector = seed, .x = 0, .y = 0 };
            const result = generate(.stone, x, y, 0, 0, bounds, &state, seed);
            try testing.expect(result != null);

            // Speckled blocks legitimately differ, so only count the majority sprite.
            var probe: HashState = structures.makeBlockHash(seed, x, y, SPECKLE_ROLL_ID);
            if (probe.getChance(0.1)) continue;

            if (wall_seen) |w| {
                try testing.expectEqual(w, result.?.id);
            } else wall_seen = result.?.id;
        }
    }
    try testing.expect(wall_seen != null);
}
