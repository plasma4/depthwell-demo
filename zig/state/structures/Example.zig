//! DELIBERATELY NOT REGISTERED in the `structures` tuple:
//! this file is documentation of structures and a comprehensive example.
//! The test at the bottom is what keeps it honest; if this file stops compiling, the docs have rotted.
//!
//! Hut:
//!     #########     <- roof
//!     #.......#
//!     #.......#     <- chest on the floor, somewhere in the middle
//!     #.c.....#
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

/// Every structure lives on its own grid of square cells, `spawn_area` block width that tiles across the world.
/// At most one placement of this kind is considered per cell and this must be a power-of-two.
///
/// The footprint may be anchored ANYWHERE in its cell (see `jitter()` below), which means it can overhang
/// into the neighboring cell. structures.zig budgets for exactly one cell of overhang, which is why
/// `max_w` and `max_h` may never exceed `spawn_area`. There is a comptime check for this in structures.zig.
pub const spawn_area: u32 = 32;

/// The largest (if there's size variation) footprint this structure can ever occupy.
pub const max_w: u32 = size_x;
/// FOOTPRINT height, nothing else. If the structure also declares a `seat`, structures.zig adds that
/// slide depth automatically when it computes the vertical reach, so never add it here yourself.
pub const max_h: u32 = size_y;

/// The odds a given cell even ATTEMPTS a placement. This is a ROLL, not a density.
///
/// Terrain rules rules run AFTER this roll and (probably) throw most survivors away.
/// Ground odds in practice, can only be estimated heuristically so see `debug/audit.zig`.
pub const target_chance: f64 = 1.0;

/// Optional, defaults to 1. How many placements to try within a single cell before giving up on it.
///
/// Only worth raising for a heavily gated structure. This structure wants flat ground, which is rare,
/// so a single jitter draw per cell would waste nearly every cell it was offered.
/// Retrying is cheap here because a doomed seating scan bails after a couple of columns.
/// If there aren't terrain rules then don't include this variable.
pub const attempts: u32 = 8;

/// Width of the hut, walls included.
const size_x: i32 = 9;
/// Height of the hut, roof and floor included.
const size_y: i32 = 5;

/// SEAT: stands the hut on the ground.
///
/// This one declaration replaces what used to be a hand-written column-profiling loop in getBounds(),
/// a `SNAP_DEPTH` constant, a `+ SNAP_DEPTH` term in max_h, and two "my corners rest on solid terrain"
/// constraints. All of that is now implied.
///
/// Seating cannot be a Constraint, and the reason is the useful thing to remember: a constraint is a pure
/// PREDICATE over a box that is already final, whereas seating is a TRANSFORM that decides where the box
/// goes. checkConstraint() returns a bool and has no way to move anything.
///
/// `max_slope` defaults to 0, demanding perfectly flat ground, which is what a flat-bottomed building wants.
pub const seat: structures.Seat = .{ .max_drop = 6 };

// A Region is a box expressed RELATIVE to the candidate's footprint,
// so a rule can be written once and still mean the right thing wherever the structure lands.
// Each of its four sides is an Edge:
// pick which side of the footprint to anchor to (.start or .end), then offset from there.
//
// Note that .end is EXCLUSIVE, so:
//   - the footprint itself             .{}                                       (all four defaults)
//   - the single row directly below it .{ .y0 = .{ .at = .end },
//                                        .y1 = .{ .at = .end, .off = 1 } }
//   - the single row directly above it .{ .y0 = .{ .at = .start, .off = -1 },
//                                        .y1 = .{ .at = .start } }
//   - the bottom row OF the footprint  .{ .y0 = .{ .at = .end, .off = -1 },
//                                        .y1 = .{ .at = .end } }
// See structures.zig for definitions of Region/Level.

/// Every rule here is ANDed, and runs only once the box is final (post-seating).
/// Source order does NOT matter: structures.zig sorts them cheapest-first at compile time, by how many
/// terrain samples each costs, so the 1-sample tests always run before the 30-sample ones.
///
/// Terrain INSIDE the footprint is deliberately left unconstrained. The hut carves out whatever it lands on,
/// so demanding the interior already be empty would reject almost every otherwise fine spot.
///
/// WHERE DOES A RULE GO? Ask what the rule needs to DO:
/// - it has to move the box       -> `seat`, or getBounds() for anything seating cannot express
/// - it only judges a final box   -> here
/// Notice how short this list became once `seat` existed: the corner-support rules this file used to
/// carry are implied by seating, and writing them anyway would just re-sample terrain that already passed.
pub const constraints = [_]structures.Constraint{
    // A roof pressed into rock reads as a wall rather than a building, so the row above must be open.
    .{ .empty = .{
        .y0 = .{ .at = .start, .off = -1 },
        .y1 = .{ .at = .start },
    } },

    // The remaining Constraint variants, for reference:
    // - .solid / .empty: every block of a Region must (or must not) be solid base terrain.
    // - .level: profiles every column in a span and demands the ground be flat enough to build on.
    //   Use this to REQUIRE flat ground under a box you are not moving; use seat when you want the box
    //   moved onto that ground. Its window is deliberately asymmetric (max_rise is forgiving, max_drop
    //   should stay 0, because ground below the box leaves a gap and the structure appears to float).
    // - .custom: an escape hatch taking the whole Rect. Always sorted last, since its cost is opaque.
    //   Reach for it only when the vocabulary above genuinely cannot express the rule.
};

// ANCHOR: there is deliberately no getBounds() here.
//
// The hut is a plain size_x-by-size_y rectangle, so structures.zig's default jitter already does the job!
// Only write getBounds() when the box is something the defaults cannot express, which in practice means a size rolled at runtime
// (Geode.zig rolls a radius, Ancient.zig rolls two).
//
// Anything written should be routed through jitter(). It anchors the footprint uniformly ANYWHERE in the cell, overhang included.
// Drawing an origin from [0, spawn_area - w) instead would seem more natural but blanks out a band along every cell edge,
// which makes the spawn lattice visible as a regular grid in the world (would be kinda sad with such complex seed logic).

// generate() is called once per block, and it must be a PURE function of its arguments.
// structures.zig re-derives state from scratch for every single block,
// so two blocks only agree about the structure they belong to if they both walk the hash stream identically.
//
// This means that ANY (hash) decision that is shared across multiple blocks (correlated) MUST guarantee uniform control flow.
// Generally, a good rule of thumb is to move all of these hashes to the start of the fn;
// otherwise this is the source of weird miscorrelation bugs.
//
// - CORRELATED (one value for the whole structure): draw from state, the candidate-level stream.
//   The geode structure does this for the stone types.
//
// - UNCORRELATED (each block rolls independently): draw from makeBlockHash(struct_seed, wx, wy, id),
//   which is keyed on the block's own coordinates. Geodes scatter gems through its core this way.
//
// Beware: because makeBlockHash() is keyed on wx/wy, it is exactly the WRONG tool for a shared decision.

/// Unique ID for this file's uncorrelated per-block rolls.
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
    // The cell coordinates are already baked into `state` by structures.zig,
    // and this structure has doesn't use the base terrain sprite it is replacing.
    _ = starting_sprite;
    _ = cx;
    _ = cy;

    // CORRELATED DRAW, taken first and unconditionally, per the contract above.
    // Every block of this hut sees the same answer, so the whole building matches.

    // A few tips on performance: dual value noise alone is insanely expensive
    // and getChance()/getting any 1-64-bit values cost less than a division.

    // getChance() also consumes way fewer bits for power-of-two near values
    // and is heavily optimized.
    const wall: Sprite = if (state.getChance(0.5)) .stone else .pink_stone;

    // Also correlated: which column the chest stands in. Drawn here rather than lower down for the same reason!
    // (We can let LLVM do the hard work of rearranging if applicable/simple, keeping in mind state fns are inlined.)
    const chest_x = 1 + state.getLimit(i32, size_x - 2);

    // Convert absolute world coordinates into coordinates local to the footprint.
    const local_x = @as(i32, @bitCast(wx)) - bounds.x_start;
    const local_y = @as(i32, @bitCast(wy)) - bounds.y_start;

    // Returning null means "this block is not mine" so it can be offered to future structures.
    // This check is mandatory. A candidate is consulted for every block in its BOUNDING BOX,
    // and for blocks in neighboring cells its box may overhang into,
    // so generate() is routinely asked about blocks outside its own shape. A hot path.
    if (local_x < 0 or local_y < 0 or local_x >= size_x or local_y >= size_y) return null;

    const is_edge = local_x == 0 or local_x == size_x - 1 or
        local_y == 0 or local_y == size_y - 1;

    if (is_edge) {
        // UNCORRELATED DRAW: speckle a few wall blocks with the other stone, independently per block.
        var block_state = structures.makeBlockHash(struct_seed, wx, wy, SPECKLE_ROLL_ID);
        if (block_state.getChance(0.1)) {
            return .{ .id = if (wall == .stone) .pink_stone else .stone };
        }
        return .{ .id = wall };
    }

    // The chest sits on the floor/bottom row, in the column chosen above.
    if (local_x == chest_x and local_y == size_y - 2) {
        // A dry waterloggable block placed in a row the structure also floods MUST set water_volume,
        // or the fluid sim floods the cell on the chunk's first tick (modification waste).
        // This hut never places water, so 0 is correct here; see StructureResult in structures.zig for when it is not.
        return .{ .id = .chest };
    }

    // Everything else is carved out. `.none` is an explicit "make this air", which is NOT the same as returning null:
    // null defers to whatever was already there, `.none` actively clears it.
    return .{ .id = .none };
}

const testing = std.testing;

test "Example structure stays compilable and self-consistent" {
    // The declarations structures.zig requires, checked the way its own comptime block would if this file were registered.
    // Keeping these here is what lets the file stay out of the spawn tuple safely.
    try testing.expect(std.math.isPowerOfTwo(spawn_area));
    try testing.expect(max_w <= spawn_area);
    try testing.expect(max_h <= spawn_area);
    try testing.expect(target_chance >= 0.0 and target_chance <= 1.0);

    // The constraint sorter must accept this list and preserve its length.
    const sorted = comptime structures.sortConstraints(&constraints, max_w, max_h);
    try testing.expectEqual(constraints.len, sorted.len);

    // generate() is pure, so it can be exercised without any world state.
    // A hand-built HashState and a hand-built Rect are enough;
    // note getBounds() is NOT called here, since it samples real terrain.
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

    // Verify every block of the footprint re-derives the stream independently,
    // so they must all agree on the correlated wall sprite.
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

            // speckled blocks legitimately differ, so only count the majority sprite.
            var probe: HashState = structures.makeBlockHash(seed, x, y, SPECKLE_ROLL_ID);
            if (probe.getChance(0.1)) continue;

            if (wall_seen) |w| {
                try testing.expectEqual(w, result.?.id);
            } else wall_seen = result.?.id;
        }
    }
    try testing.expect(wall_seen != null);
}
