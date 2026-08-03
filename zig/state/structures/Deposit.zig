//! A loose-material deposit: sand, gravel, or clay in a small rounded blob.
//!
//! ```
//!    .DD.
//!   DDDDD
//!    DDD.
//! ```
//!
//! Three things make this different from every other structure here:
//!
//! 1. It is a REGION, not an object. One coarse noise field decides where deposits are possible at
//!    all and a second grid decides which material a stretch of country holds, so deposits arrive in
//!    clusters of one material. Both are read per grid CELL, never per block (`regionMaterial()`).
//! 2. It is SMALL and DENSE rather than large and rare. `spawn_area` is one chunk wide and
//!    `target_chance` is 1, so nothing is thrown away at the roll; the region field and the terrain
//!    rules below are the only things that thin deposits out.
//! 3. Each material claims different cells, which is what makes the four read as different substances:
//!    - `.fill` (sand, gravel) takes rock, and takes open space that has a floor under it.
//!    - `.crust` (clay, red clay) takes ONLY rock that already touches open space, so a clay deposit
//!      is always a visible lining on a cave wall and never a buried pocket the player cannot find.
//!    Sand additionally SLUMPS: see `columnSlump()`.
//!
//! Lowest priority in `structures.structures` on purpose: an overlapping placement of any other kind
//! removes the deposit, which reads as "no sand right where the ruin is" and never as a buried ruin.
const dw = @import("../../root.zig");
const HashState = dw.seeding.HashState;
const Vec2u = dw.utils.Vec2u;
const Sprite = dw.Sprite;
const structures = @import("../structures.zig");
const Rect = structures.Rect;

pub const spawn_area: u32 = 8;

/// Two deposits of one region draw the same material, so overlapping placements are indistinguishable
/// from one larger blob. Without this, the same-kind rank rule deleted about half of them; see
/// `structures.hasSelfOverlap()`.
pub const overlaps_self = true;
pub const max_w: u32 = MAX_DIAMETER;
pub const max_h: u32 = MAX_DIAMETER;

/// Every cell that the region field permits tries a deposit. The terrain rules in `generate()` do all
/// of the thinning, so there is nothing to gain from rejecting a cell before its box even exists.
pub const target_chance: f64 = 1.0;

/// Smallest and largest blob bounding box, in blocks. The blob is inscribed in the box.
/// Deliberately close to `spawn_area`: overlap is free here (`overlaps_self`), so a blob as wide as
/// its own cell is what turns a lattice of small lumps into continuous drifts of material.
const MIN_DIAMETER: i32 = 4;
const MAX_DIAMETER: i32 = 8;

/// Rows below an open cell that are searched for a floor to settle on.
/// The search reads BASE terrain, so deposited material never supports more of itself,
/// which bounds a pile to this many rows above the original floor.
const SETTLE_REACH: i32 = 4;
/// How far above the air cutoff a cell may sit and still count as "near the surface".
///
/// This reads the SAME `density * cutoff` the terrain used to decide solid-versus-air, so it asks
/// "how close is this cell to being a cave?" rather than "how many blocks away is one?". That is one
/// cached terrain lookup instead of a scan: a 22-probe vertical search here cost more than the rest
/// of the deposit put together, since a deeply buried cell had to run every probe to say no.
///
/// Raising it buries deposits deeper and makes them commoner; this and `REGION_THRESHOLD` are the
/// two density knobs.
const SURFACE_BAND: f32 = 0.15;
/// Most rows a sand blob may slide down to meet a void beneath it; see `columnSlump()`.
const MAX_SLUMP: i32 = 4;

/// Blocks per cell of the field that decides where deposits are possible.
/// Far larger than `spawn_area`, so one region covers many cells and reads as a stretch of country.
const REGION_CELL: f32 = 512.0;
/// Region field value a cell must reach to hold a deposit at all.
/// Raising this shrinks the deposit-bearing share of the world; this is the main density knob.
const REGION_THRESHOLD: f32 = 0.30;

/// Blocks per cell of the grid that picks the material. A power of two, and deliberately not a
/// multiple of `REGION_CELL`, so material borders do not sit on region borders.
/// A hash rather than a field, because a field concentrates around its middle and would leave the
/// first and last material of `MATERIALS` almost unreachable.
const MATERIAL_CELL: comptime_int = 1024;
/// Namespace for the material hash, kept clear of the `kind`-derived ids `structures.zig` uses.
const MATERIAL_HASH_ID: comptime_int = 900;

/// Blocks per cell of the noise that wobbles the blob outline.
/// Comparable to the blob itself, so a deposit reads as an irregular lump rather than an ellipse.
const WOBBLE_CELL: f32 = 5.0;
/// Squared normalized radius the outline sits at with no wobble, and how far the wobble moves it.
/// The sum stays at or below 1, so the blob never reaches the bounding box and no cell edge shows.
const EDGE_BASE: f32 = 0.88;
const EDGE_WOBBLE: f32 = 0.12;

/// Separates the deposit streams from the structure placement stream they are derived from.
/// Full-width random odd words, as in `procedural.ORE_LANE_SEEDS`.
const REGION_LANE: [2]u64 = .{ 0x3d94c8b6e2715fa9, 0xc17a2fd58b436e9d };
const MATERIAL_LANE: [2]u64 = .{ 0x8e5b13cad7602f95, 0x2b6fd9430ec5a871 };

/// Which cells of its blob a material claims.
const Mode = enum {
    /// Takes rock, and takes open space that has a floor within `SETTLE_REACH` below it.
    fill,
    /// Takes ONLY rock that already touches open space: a lining, never a buried pocket.
    crust,
};

/// A region's substance: what it places and how it decides which cells to place in.
const Material = struct { sprite: Sprite, mode: Mode };

/// Materials a region can be made of, each with its share out of `MATERIAL_TOTAL`.
/// This is the table to edit to change how common one substance is relative to the others;
/// `REGION_THRESHOLD` changes how common deposits are overall.
const MATERIALS = [_]struct { Sprite, u32, Mode }{
    .{ .sand, 40, .fill },
    .{ .clay, 26, .crust },
    .{ .gravel, 24, .fill },
    .{ .red_clay, 10, .crust },
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
var memo_material: ?Material = null;
var memo_occupied: bool = false;

/// The material cell (`cx`, `cy`) belongs to, or null where the region field rejects deposits.
/// Both fields are read at the cell's center, so every block of one cell agrees.
fn regionMaterial(cx: i32, cy: i32) ?Material {
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

    const material: ?Material = if (presence < REGION_THRESHOLD) null else blk: {
        var state = structures.makeStructureHash(
            seed ^ @as(Vec2u, MATERIAL_LANE),
            wx,
            wy,
            MATERIAL_CELL,
            MATERIAL_HASH_ID,
        );
        var roll = state.getLimit(u32, MATERIAL_TOTAL);
        inline for (MATERIALS) |m| {
            if (roll < m[1]) break :blk .{ .sprite = m[0], .mode = m[2] };
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

/// How far a sand blob slides DOWN in column `wx`: the open base-terrain rows directly under the box.
///
/// This is the whole of "sand has settled", and it costs nothing at runtime beyond a few cached
/// terrain probes. Shifting the SHAPE by a per-column amount shears the blob onto whatever is under
/// it, so sand pours into a void and drapes over a ledge, with no falling simulation, no
/// `mod_store` writes, and no state that has to converge over later ticks.
///
/// Per COLUMN rather than per block on purpose: a per-block offset would tear the blob into specks
/// wherever the drop changed between neighboring rows.
fn columnSlump(wx: i32, bounds: Rect) i32 {
    var drop: i32 = 0;
    while (drop < MAX_SLUMP) : (drop += 1) {
        if (structures.baseSolid(wx, bounds.y_end + drop)) break;
    }
    return drop;
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

/// Whether a cell shares a side with open base terrain, which is what `.crust` demands of every block
/// it places. Four probes, so it is cheap enough to ask per block.
fn touchesOpen(wx: i32, wy: i32) bool {
    return !structures.baseSolid(wx - 1, wy) or !structures.baseSolid(wx + 1, wy) or
        !structures.baseSolid(wx, wy - 1) or !structures.baseSolid(wx, wy + 1);
}

/// Whether a cell sits close enough to the terrain's own air cutoff to count as near a surface.
/// Out-of-world cells answer false, exactly as `structures.baseSolid()` treats them.
fn nearSurface(wx: i32, wy: i32) bool {
    if (wx < 0 or wy < 0 or wx > structures.MAX_WORLD_BLOCK or wy > structures.MAX_WORLD_BLOCK) return false;
    const uwx: u32 = @bitCast(wx);
    const uwy: u32 = @bitCast(wy);
    const d = dw.procedural.getBaseSpriteType(
        uwx / dw.CHUNK_SIZE,
        uwy / dw.CHUNK_SIZE,
        @intCast(uwx % dw.CHUNK_SIZE),
        @intCast(uwy % dw.CHUNK_SIZE),
    );
    return d.density * d.cutoff <= dw.procedural.density_min.getF32() + SURFACE_BAND;
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
    const solid = starting_sprite.isFoundation();

    // Cheapest rejections first. `covers()` costs a noise sample, and with `overlaps_self` several
    // candidates ask about the same block, so anything that can say no from a cached terrain lookup
    // has to run before the shape does.
    switch (material.mode) {
        .crust => {
            // Rock only, and only where it is already open to the air. A buried clay pocket is
            // invisible until something else happens to cut it open, so it is simply not placed.
            if (!solid or !touchesOpen(i_wx, i_wy)) return null;
        },
        .fill => if (!nearSurface(i_wx, i_wy)) return null,
    }

    // Only sand settles; clay and gravel sit where the rock they replaced was.
    const slump = if (material.sprite == .sand) columnSlump(i_wx, bounds) else 0;
    if (!covers(i_wx, i_wy - slump, bounds)) return null;

    // Open space becomes material only where something below can hold it up.
    if (material.mode == .fill and !solid and !hasFloorBelow(i_wx, i_wy)) return null;
    return .{ .id = material.sprite };
}
