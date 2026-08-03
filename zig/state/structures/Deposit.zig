//! A loose-material deposit: sand, gravel, or clay in a rounded blob.
//!
//! ```
//!    .DDD.
//!   DDDDDDD
//!   DDDDDD.
//!    .DD.
//! ```
//!
//! Two things make this different from every other structure here:
//!
//! 1. It is a REGION, not an object. One coarse noise field decides both whether a cell may hold a
//!    deposit and which material it holds, so deposits arrive in clusters of one material rather
//!    than one at a time. The field is read per grid CELL, never per block (see `regionMaterial()`).
//! 2. It claims open space as well as rock. Rock inside the blob simply becomes the material;
//!    open space becomes it only where a floor sits within `SETTLE_REACH` rows below,
//!    so a deposit piles onto a cave floor instead of hanging in the air.
//!
//! Lowest priority in `structures.structures` on purpose: an overlapping placement of any other kind
//! removes the whole deposit, which reads as "no sand right where the ruin is" and never as a
//! half-buried ruin.
const dw = @import("../../root.zig");
const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;
const structures = @import("../structures.zig");
const Rect = structures.Rect;

pub const spawn_area: u32 = 64;
pub const max_w: u32 = MAX_DIAMETER;
pub const max_h: u32 = MAX_DIAMETER;

/// Roll per grid cell, before the region field thins it out.
/// The field rejects most of the world, so this sits high; see `debug/audit.zig` for the real rate.
pub const target_chance: f64 = 0.75;

/// Smallest and largest blob bounding box, in blocks. The blob itself is inscribed in the box.
const MIN_DIAMETER: i32 = 9;
const MAX_DIAMETER: i32 = 22;

/// Rows below an open cell that are searched for a floor to settle on.
/// The search reads BASE terrain, so deposited material never supports more of itself,
/// which is what bounds a pile to this many rows above the original floor.
const SETTLE_REACH: i32 = 5;

/// Blocks per cell of the field that decides where deposits are possible.
/// Far larger than `spawn_area`, so one region covers many cells and reads as a stretch of country.
const REGION_CELL: f32 = 512.0;
/// Blocks per cell of the grid that picks the material. A power of two, and deliberately not a
/// multiple of `REGION_CELL`, so material borders do not sit on region borders.
/// A hash rather than a field, because a field concentrates around its middle and would leave the
/// first and last material of `MATERIALS` almost unreachable.
const MATERIAL_CELL: comptime_int = 1024;
/// Namespace for the material hash, kept clear of the `kind`-derived ids `structures.zig` uses.
const MATERIAL_HASH_ID: comptime_int = 900;
/// Region field value a cell must reach to hold a deposit at all.
/// Raising this shrinks the deposit-bearing share of the world.
const REGION_THRESHOLD: f32 = 0.54;

/// Blocks per cell of the noise that wobbles the blob outline.
const WOBBLE_CELL: f32 = 6.0;
/// Squared normalized radius the outline sits at with no wobble, and how far the wobble moves it.
/// The sum stays at or below 1, so the blob never reaches the bounding box and no cell edge shows.
const EDGE_BASE: f32 = 0.75;
const EDGE_WOBBLE: f32 = 0.25;

/// Separates the deposit streams from the structure placement stream they are derived from.
/// Full-width random odd words, as in `procedural.ORE_LANE_SEEDS`.
const REGION_LANE: [2]u64 = .{ 0x3d94c8b6e2715fa9, 0xc17a2fd58b436e9d };
const MATERIAL_LANE: [2]u64 = .{ 0x8e5b13cad7602f95, 0x2b6fd9430ec5a871 };

/// Materials a region can be made of, each with its share out of `MATERIAL_TOTAL`.
const MATERIALS = [_]struct { Sprite, u32 }{
    .{ .sand, 45 },
    .{ .clay, 25 },
    .{ .gravel, 22 },
    .{ .red_clay, 8 },
};

const MATERIAL_TOTAL: u32 = blk: {
    var sum: u32 = 0;
    for (MATERIALS) |m| sum += m[1];
    break :blk sum;
};

/// Single-entry memo of the region fields. `generate()` runs per BLOCK while the fields answer per
/// CELL, and a chunk pass asks about the same handful of cells in a row, so one entry hits nearly
/// every time. Keyed on `procedural.terrainGeneration()` as well, since a reseed leaves the same
/// cell naming a different region.
var memo_cx: i32 = 0;
var memo_cy: i32 = 0;
var memo_generation: u64 = 0;
var memo_material: ?Sprite = null;
var memo_occupied: bool = false;

/// The material cell (`cx`, `cy`) belongs to, or null where the region field rejects deposits.
/// Both fields are read at the cell's center, so every block of one cell agrees.
fn regionMaterial(cx: i32, cy: i32) ?Sprite {
    const generation = dw.procedural.terrainGeneration();
    if (memo_occupied and memo_cx == cx and memo_cy == cy and memo_generation == generation) {
        return memo_material;
    }

    const half = @as(i32, @intCast(spawn_area)) / 2;
    const wx: u32 = @bitCast(cx * @as(i32, @intCast(spawn_area)) + half);
    const wy: u32 = @bitCast(cy * @as(i32, @intCast(spawn_area)) + half);

    const seed = dw.memory.game.getHashSeed(.structures);
    const presence = dw.procedural.getPerlinNoiseFixed(
        seed ^ @as(Vec2u, REGION_LANE),
        wx,
        wy,
        REGION_CELL,
    );

    const material: ?Sprite = if (presence < REGION_THRESHOLD) null else blk: {
        var state = structures.makeStructureHash(
            seed ^ @as(Vec2u, MATERIAL_LANE),
            wx,
            wy,
            MATERIAL_CELL,
            MATERIAL_HASH_ID,
        );
        var roll = state.getLimit(u32, MATERIAL_TOTAL);
        inline for (MATERIALS) |m| {
            if (roll < m[1]) break :blk m[0];
            roll -= m[1];
        }
        unreachable; // the shares sum to MATERIAL_TOTAL, so a roll below it always lands
    };

    memo_cx = cx;
    memo_cy = cy;
    memo_generation = generation;
    memo_material = material;
    memo_occupied = true;
    return material;
}

/// The blob's own shape: an ellipse inscribed in `bounds` whose outline is pushed in and out by a
/// smooth noise field, so no two deposits share a silhouette.
fn covers(wx: i32, wy: i32, bounds: Rect) bool {
    const rx = @as(f32, @floatFromInt(bounds.x_end - bounds.x_start)) * 0.5;
    const ry = @as(f32, @floatFromInt(bounds.y_end - bounds.y_start)) * 0.5;

    const dx = (@as(f32, @floatFromInt(wx - bounds.x_start)) + 0.5) / rx - 1.0;
    const dy = (@as(f32, @floatFromInt(wy - bounds.y_start)) + 0.5) / ry - 1.0;
    const radius_sq = dx * dx + dy * dy;
    // Nothing past the inscribed ellipse can be inside, whatever the wobble says.
    if (radius_sq > 1.0) return false;

    const wobble = dw.procedural.getDualValueNoiseFixed(
        dw.memory.game.getHashSeed(.structures) ^ @as(Vec2u, REGION_LANE),
        @as(u32, @bitCast(wx)),
        @as(u32, @bitCast(wy)),
        1.0 / WOBBLE_CELL,
    )[0];
    return radius_sq <= EDGE_BASE + EDGE_WOBBLE * (wobble * 2.0 - 1.0);
}

/// Whether an open cell has a floor near enough below it to hold loose material.
/// Reads BASE terrain (`structures.baseSolid()`), which is what the whole structure pass is gated on.
fn hasFloorBelow(wx: i32, wy: i32) bool {
    var dy: i32 = 1;
    while (dy <= SETTLE_REACH) : (dy += 1) {
        if (structures.baseSolid(wx, wy + dy)) return true;
    }
    return false;
}

/// Rolls the box, or rejects the cell outright where the region field holds no deposits.
/// Rejecting here rather than in `generate()` is what keeps a barren cell from being cached as a
/// placement that then draws nothing.
pub fn getBounds(state: *HashState, cx: i32, cy: i32) ?Rect {
    if (regionMaterial(cx, cy) == null) return null;
    const w = state.getRange(i32, MIN_DIAMETER, MAX_DIAMETER + 1);
    const h = state.getRange(i32, MIN_DIAMETER, MAX_DIAMETER + 1);
    return structures.jitter(state, cx, cy, spawn_area, w, h);
}

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
    _ = state;
    _ = struct_seed;

    const material = regionMaterial(cx, cy) orelse return null;
    const i_wx = @as(i32, @bitCast(wx));
    const i_wy = @as(i32, @bitCast(wy));
    if (!covers(i_wx, i_wy, bounds)) return null;

    // Rock inside the blob simply becomes the material.
    if (starting_sprite.isFoundation()) return .{ .id = material };

    // Open space becomes it only where something below can hold it up.
    if (!hasFloorBelow(i_wx, i_wy)) return null;
    return .{ .id = material };
}
