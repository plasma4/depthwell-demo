//! Handles water logic, updating the physics and edge flags as necessary.
//! Water level goes from 0-15; the simulation keeps total water within the `SimBuffer` the same.
//!
//! A goal of the sweep is avoiding "water parity"!
//! This means a falling stream should split into alternating occupied/empty (or tiny-volume) vertical cells.
//! Mid-stream cells therefore pour at full rate (see the gravity phase of `tickWater()`)
//! to reduce parity occurrences, and airborne cells never spread laterally (hold until resting on support),
//! so a stream that momentarily backs up cannot spray sideways and cause more "damage".
//!
//! Parity can only be truly avoided for consistent sources and some amount of parity weirdness is acceptable,
//! especially if water is being placed and water still appears mostly locally/globally visually consistent.
const std = @import("std");
const dw = @import("../root.zig");
const memory = dw.memory;
const types = dw.types;
const world = dw.world;

const SimBuffer = world.SimBuffer;
const Sprite = dw.Sprite;
const Block = memory.Block;
const Chunk = memory.Chunk;

const MAX_HP = memory.Block.MAX_HP;
const CHUNK_SIZE = dw.CHUNK_SIZE;
const CHUNK_SIZE_LOG2 = dw.CHUNK_SIZE_LOG2;

const SIM_BUFFER_SIZE = dw.world.SIM_BUFFER_SIZE;
const SIM_BUFFER_WIDTH = world.SIM_BUFFER_WIDTH;
const SIM_GRID_SIZE = world.SIM_GRID_SIZE;
const SIM_GRID_SIZE_SQ = world.SIM_GRID_SIZE_SQ;
const SimIndexType = world.SimIndexType;

/// Water debugging check: when enabled, `tickWater()` asserts that the total water volume is stable in SimBuffer
/// (as in, no water gets added or deleted from the game).
/// May result in performance drops, especially in Debug (where this is intended to be used).
///
/// Only logs if an invalid state occurs.
pub const VERIFY_WATER_MASS = false;

/// Sums the water volume of every loaded `SimBuffer` chunk. Debug helper for `VERIFY_WATER_MASS`.
fn totalSimWater() u64 {
    var total: u64 = 0;
    for (&SimBuffer.keys, 0..) |key, sim_idx| {
        if (key == null) continue;
        for (&SimBuffer.sim_buffer_ptr[sim_idx].blocks) |b| total += getVolume(b);
    }
    return total;
}

/// Global bitset of active chunks in the current frame (16x16 chunk grid).
var active_chunks: std.StaticBitSet(SIM_BUFFER_SIZE) = undefined;
/// Per-cell "this cell has already taken its turn this tick" guard (prevents a cell moving twice in one sweep).
var water_updated: std.StaticBitSet(SIM_GRID_SIZE_SQ) = undefined;
/// Per-cell "this cell RECEIVED sideways water this tick" guard.
var lateral_received: std.StaticBitSet(SIM_GRID_SIZE_SQ) = undefined;
/// Bitset keeping track of which active chunks actually had water flow changes.
var chunks_to_update_flags: std.StaticBitSet(SIM_BUFFER_SIZE) = undefined;
/// Chunks queued by manual water placement for batched edge-flag recompute on next tick.
var pending_flag_chunks: std.StaticBitSet(SIM_BUFFER_SIZE) = std.StaticBitSet(SIM_BUFFER_SIZE).initEmpty();
/// Per-cell "the sim changed this cell's volume this tick" record, so phase 3 persists exactly the cells
/// it touched instead of writing back a whole chunk. Set only by `setVolumeAt()`.
var cells_changed: std.StaticBitSet(SIM_GRID_SIZE_SQ) = undefined;

/// Resets all water simulation states, clearing pending flag updates and tracking bitsets.
pub fn reset() void {
    pending_flag_chunks = .initEmpty();
    active_chunks = .initEmpty();
    water_updated = .initEmpty();
    lateral_received = .initEmpty();
    chunks_to_update_flags = .initEmpty();
    cells_changed = .initEmpty();
}

/// Queues a manually-placed water block's chunk plus its 4 orthogonal neighbors for a batched flag recompute.
/// Flags will resolve in the same tick.
pub fn queueWaterFlags(cx: SimIndexType, cy: SimIndexType) void {
    const idx = (@as(usize, cy) << world.SIM_WIDTH_LOG2) | cx;
    pending_flag_chunks.set(idx);
    if (cx > 0) pending_flag_chunks.set(idx - 1);
    if (cx < SIM_BUFFER_WIDTH - 1) pending_flag_chunks.set(idx + 1);
    if (cy > 0) pending_flag_chunks.set(idx - SIM_BUFFER_WIDTH);
    if (cy < SIM_BUFFER_WIDTH - 1) pending_flag_chunks.set(idx + SIM_BUFFER_WIDTH);
}

/// Volume a settled cell of OPEN water comes to rest at.
pub const RESTING_VOLUME: u4 = MAX_HP - 1;

/// Helper to get the volume of a block (0 to 15 for water/waterlogged blocks, 0 otherwise).
/// (Integer casting automatically enforces HP being within `u4` range.)
pub inline fn getVolume(ptr: Block) u4 {
    if (ptr.isLiquid()) {
        return @intCast(ptr.hp);
    }
    if (ptr.isWaterloggable()) {
        return @intCast(ptr.hp);
    }
    return 0;
}

/// Helper to set the volume (`hp`) of a block, modifying other properties as needed.
pub inline fn setVolume(ptr: *Block, vol: u32) void {
    const capped: u4 = @intCast(@min(vol, MAX_HP));
    if (vol == 0) {
        if (ptr.isWaterloggable()) {
            ptr.hp = 0;
        } else {
            ptr.id = .none;
            ptr.hp = 0;
            ptr.edge_flags = 0xFF;
            ptr.id_edge_flags = 0xFF;
            ptr.water = .dry;
        }
    } else {
        if (ptr.isWaterloggable()) {
            ptr.hp = capped;
        } else {
            ptr.id = .water;
            ptr.hp = capped;
        }
    }
}

/// `setVolume()` plus the bookkeeping that lets phase 3 persist only the cells the sim actually moved.
/// `grid_idx` is the cell's index in the `SIM_GRID_SIZE`-by-`SIM_GRID_SIZE` sim grid (`ry * SIM_GRID_SIZE + rx`).
///
/// Every volume change inside `tickWater()` MUST go through this rather than `setVolume()`: a cell that
/// moves without being recorded here is dropped from `mod_store` and reverts to its procedural volume the
/// next time its chunk is materialized.
inline fn setVolumeAt(ptr: *Block, vol: u32, grid_idx: usize) void {
    setVolume(ptr, vol);
    cells_changed.set(grid_idx);
}

/// Backing integer of `Block.water`, and the exact width of every view of it.
/// Keep in sync with `unpack_tile()` in src/shader.wgsl, which reads bits 0-10 of word3.
pub const WaterBits = u11;

/// What a block knows about the water around it, in the shape its own kind wants it.
///
/// One field of `Block`, read three ways. The block's `id` decides which view is live and nothing
/// else does, so the views deliberately agree on bit 0: "is there water directly above me?" can be
/// asked without knowing the kind at all, which is what the shader's submersion test does.
///
/// The union never grows past `WaterBits`. A view that needs more than that does not belong here.
pub const WaterState = packed union {
    /// The whole field as one integer, for the paths that only copy, compare, or clear it.
    bits: WaterBits,
    /// View for a liquid block.
    liquid: Liquid,
    /// View for a solid or waterloggable block.
    solid: Solid,
    /// View for a plant. Not written by anything yet; see `Plant`.
    plant: Plant,

    /// Nothing around this block holds water. The state every block generates in.
    pub const dry: WaterState = .{ .bits = 0 };

    /// A liquid only has to know whether more liquid sits directly above it,
    /// which is what decides whether it draws a surface or a full body.
    pub const Liquid = packed struct(WaterBits) {
        /// Liquid of any depth directly above.
        above: bool = false,
        _unused: u10 = 0,
    };

    /// Everything the shader needs to draw the water AROUND a block that is not itself liquid.
    /// Presence on the left or right is implied by a nonzero volume, so neither needs its own bit.
    /// The shader interpolates the water surface across the block between the two volumes.
    pub const Solid = packed struct(WaterBits) {
        /// Water of any depth directly above; fully submerges the block.
        above: bool = false,
        /// A FULL liquid block directly below (at `MAX_HP`).
        below: bool = false,
        /// An adjacent water surface is exposed to air, so it ripples.
        ripple: bool = false,
        /// Volume of the liquid to the left, 0 for none.
        left_volume: u4 = 0,
        /// Volume of the liquid to the right, 0 for none.
        right_volume: u4 = 0,
    };

    /// TODO: the gardening mechanic will write this. A plant cares about the water it has TAKEN UP,
    /// not about the water beside it, so it wants a different question answered than `Solid` does.
    /// Nothing reads or writes it yet, and a plant still uses the `solid` view until it does.
    pub const Plant = packed struct(WaterBits) {
        /// The one bit every view shares; see `WaterState`.
        above: bool = false,
        /// TODO: how wet the soil under this plant is, 0 for bone dry.
        moisture: u4 = 0,
        /// TODO: progress toward the next growth stage.
        age: u6 = 0,
    };

    /// Whether water sits directly above, whichever view is live. See `WaterState`.
    pub inline fn submerged(self: WaterState) bool {
        return self.liquid.above;
    }

    /// Whether the two states are the same bit for bit. A union has no `==`.
    pub inline fn eql(self: WaterState, other: WaterState) bool {
        return self.bits == other.bits;
    }
};

comptime {
    // The shared bit 0 that `submerged()` and the shader both depend on.
    const probe: WaterState = .{ .solid = .{ .above = true } };
    if (!probe.liquid.above or !probe.plant.above or probe.bits != 1)
        @compileError("Every WaterState view must put `above` in bit 0; see WaterState.");
}

/// The water state of a block, from the neighbors around it. Returns the `solid` view,
/// which is the one every non-liquid block uses (a liquid reads bit 0 of it as `liquid.above`).
pub fn getWaterFlags(
    top_nb: ?Block,
    bottom_nb: ?Block,
    left_nb: ?Block,
    right_nb: ?Block,
    above_left_nb: ?Block,
    above_right_nb: ?Block,
) WaterState {
    var state: WaterState.Solid = .{};

    if (top_nb) |top| {
        // Any water above (liquid or a waterlogged decor, at any depth) fully submerges the block.
        if (getVolume(top) > 0) state.above = true;
    }

    if (bottom_nb) |bottom| {
        if (bottom.isLiquid() and getVolume(bottom) == MAX_HP) state.below = true;
    }

    if (left_nb) |left| {
        if (left.isLiquid()) {
            state.left_volume = @intCast(getVolume(left));
            if (above_left_nb == null or (!above_left_nb.?.isSolid() and !above_left_nb.?.isLiquid())) {
                state.ripple = true;
            }
        }
    }

    if (right_nb) |right| {
        if (right.isLiquid()) {
            state.right_volume = @intCast(getVolume(right));
            if (above_right_nb == null or (!above_right_nb.?.isSolid() and !above_right_nb.?.isLiquid())) {
                state.ripple = true;
            }
        }
    }

    return .{ .solid = state };
}

/// Sibling of `getWaterFlags()` for the halo Sprites of base chunk generation.
/// Procedural water blocks default to full HP, so adjacent volumes are stored as `MAX_HP`.
pub fn getWaterloggedStateSprites(
    top_nb: Sprite,
    bottom_nb: Sprite,
    left_nb: Sprite,
    right_nb: Sprite,
    above_left_nb: Sprite,
    above_right_nb: Sprite,
) WaterState {
    var state: WaterState.Solid = .{};

    if (top_nb.isLiquid()) state.above = true;
    if (bottom_nb.isLiquid()) state.below = true;
    if (left_nb.isLiquid()) {
        state.left_volume = MAX_HP;
        if (!above_left_nb.isSolid() and !above_left_nb.isLiquid()) state.ripple = true;
    }
    if (right_nb.isLiquid()) {
        state.right_volume = MAX_HP;
        if (!above_right_nb.isSolid() and !above_right_nb.isLiquid()) state.ripple = true;
    }

    return .{ .solid = state };
}

/// Computes the water volume for a cell dynamically.
/// Supports cross-chunk reads via horizontal offsets (`bx` of -1 or 16).
inline fn getVolumeLocal(
    curr: *Chunk,
    left: ?*Chunk,
    right: ?*Chunk,
    bx: i32,
    by: i32,
) u32 {
    if (bx >= 0 and bx < CHUNK_SIZE) {
        return getVolume(curr.blocks[@as(usize, @intCast((by << CHUNK_SIZE_LOG2) | bx))]);
    } else if (bx < 0) {
        const l = left orelse return 0;
        return getVolume(l.blocks[@as(usize, @intCast((by << CHUNK_SIZE_LOG2) | (bx + CHUNK_SIZE)))]);
    } else {
        const r = right orelse return 0;
        return getVolume(r.blocks[@as(usize, @intCast((by << CHUNK_SIZE_LOG2) | (bx - CHUNK_SIZE)))]);
    }
}

/// Helper to quickly fetch a `Chunk` pointer from `SimBuffer` coordinates.
inline fn getChunkPtr(cx: u4, cy: u4) ?*Chunk {
    const idx = world.SimBuffer.getIndex(cx, cy);
    if (world.SimBuffer.keys[idx] == null) return null;
    return &world.SimBuffer.sim_buffer_ptr[idx];
}

/// Gets pointer to a local block with center and orthogonal chunks.
fn getLocalBlockPtr(
    curr: ?*Chunk,
    left: ?*Chunk,
    right: ?*Chunk,
    top: ?*Chunk,
    bottom: ?*Chunk,
    bx: i32,
    by: i32,
) ?*Block {
    if (bx >= 0 and bx < CHUNK_SIZE and by >= 0 and by < CHUNK_SIZE) {
        const c = curr orelse return null;
        return &c.blocks[@as(usize, @intCast((by << CHUNK_SIZE_LOG2) | bx))];
    }
    if (bx < 0) {
        if (bx >= -@as(i32, CHUNK_SIZE) and by >= 0 and by < CHUNK_SIZE) {
            const l = left orelse return null;
            return &l.blocks[@as(usize, @intCast((by << CHUNK_SIZE_LOG2) | (bx + CHUNK_SIZE)))];
        }
    } else if (bx >= CHUNK_SIZE) {
        if (bx < 2 * CHUNK_SIZE and by >= 0 and by < CHUNK_SIZE) {
            const r = right orelse return null;
            return &r.blocks[@as(usize, @intCast((by << CHUNK_SIZE_LOG2) | (bx - CHUNK_SIZE)))];
        }
    } else if (by < 0) {
        if (by >= -@as(i32, CHUNK_SIZE) and bx >= 0 and bx < CHUNK_SIZE) {
            const t = top orelse return null;
            return &t.blocks[@as(usize, @intCast(((by + CHUNK_SIZE) << CHUNK_SIZE_LOG2) | bx))];
        }
    } else if (by >= CHUNK_SIZE) {
        if (by < 2 * CHUNK_SIZE and bx >= 0 and bx < CHUNK_SIZE) {
            const b = bottom orelse return null;
            return &b.blocks[@as(usize, @intCast(((by - CHUNK_SIZE) << CHUNK_SIZE_LOG2) | bx))];
        }
    }
    return null;
}

/// Recomputes one cell's edge flags and packed `waterlogged` neighbor volumes from the chunk-local window.
/// Shared core of `updateWaterEdgeFlags()` (single cell) and `updateChunkWaterFlags()` (whole chunk).
/// A missing neighbor (outside the loaded `SimBuffer`) is treated as present so border cells never erode open.
/// Resolves the edge flag bit that one of the eight neighbors of a cell contributes,
/// or 0 when that neighbor sets no bit.
/// A missing neighbor always sets its bit, so border cells never erode open.
///
/// NOTE: `dx` and `dy` are `comptime` so `getFlagBit()` folds to a single constant,
/// but the function is deliberately NOT `inline`:
/// the 3x3 unroll in `applyCellWaterFlags()` would otherwise paste eight copies of the packed `Block` accessors into one function,
/// and LLVM cost is quadratic in basic-block count.
fn neighborEdgeBit(
    comptime dx: i32,
    comptime dy: i32,
    curr: *Chunk,
    left: ?*Chunk,
    right: ?*Chunk,
    top: ?*Chunk,
    bottom: ?*Chunk,
    bx: i32,
    by: i32,
    src_is_liquid: bool,
) u8 {
    const nb = getLocalBlockPtr(curr, left, right, top, bottom, bx + dx, by + dy) orelse
        return types.EdgeFlags.getFlagBit(dx, dy);

    const is_solid_or_liquid = nb.isSolid() or nb.isLiquid() or getVolume(nb.*) > 0;
    if ((!src_is_liquid and world.shouldHaveEdgeFlags(nb.id)) or (src_is_liquid and is_solid_or_liquid)) {
        return types.EdgeFlags.getFlagBit(dx, dy);
    }
    return 0;
}

fn applyCellWaterFlags(
    curr: *Chunk,
    left: ?*Chunk,
    right: ?*Chunk,
    top: ?*Chunk,
    bottom: ?*Chunk,
    bx: i32,
    by: i32,
) void {
    const ptr = &curr.blocks[@as(usize, @intCast((by << CHUNK_SIZE_LOG2) | bx))];
    if (getVolume(ptr.*) == 0 and !world.shouldHaveEdgeFlags(ptr.id)) return;

    var flags: u8 = 0;
    var water_state: WaterState = .dry;

    if (ptr.isEmpty()) {
        flags = 0xFF;
    } else {
        const left_ptr = getLocalBlockPtr(curr, left, right, top, bottom, bx - 1, by);
        const right_ptr = getLocalBlockPtr(curr, left, right, top, bottom, bx + 1, by);
        const top_ptr = getLocalBlockPtr(curr, left, right, top, bottom, bx, by - 1);
        const bottom_ptr = getLocalBlockPtr(curr, left, right, top, bottom, bx, by + 1);
        const above_left_ptr = getLocalBlockPtr(curr, left, right, top, bottom, bx - 1, by - 1);
        const above_right_ptr = getLocalBlockPtr(curr, left, right, top, bottom, bx + 1, by - 1);

        const left_nb = if (left_ptr) |b| b.* else null;
        const right_nb = if (right_ptr) |b| b.* else null;
        const top_nb = if (top_ptr) |b| b.* else null;
        const bottom_nb = if (bottom_ptr) |b| b.* else null;
        const above_left_nb = if (above_left_ptr) |b| b.* else null;
        const above_right_nb = if (above_right_ptr) |b| b.* else null;

        water_state = getWaterFlags(top_nb, bottom_nb, left_nb, right_nb, above_left_nb, above_right_nb);

        const src_is_liquid = ptr.isLiquid();
        inline for (.{ -1, 0, 1 }) |dy| {
            inline for (.{ -1, 0, 1 }) |dx| {
                if (dx == 0 and dy == 0) continue;
                flags |= neighborEdgeBit(dx, dy, curr, left, right, top, bottom, bx, by, src_is_liquid);
            }
        }
    }

    ptr.edge_flags = flags;
    ptr.water = water_state;
}

/// Recalculates water edge flags and packages neighbor heights using the local cache.
pub fn updateWaterEdgeFlags(x: i32, y: i32) void {
    if (x < 0 or x >= SIM_GRID_SIZE or y < 0 or y >= SIM_GRID_SIZE) return;
    const cx: SimIndexType = @intCast(@divTrunc(x, CHUNK_SIZE));
    const cy: SimIndexType = @intCast(@divTrunc(y, CHUNK_SIZE));
    const bx: i32 = @intCast(@mod(x, CHUNK_SIZE));
    const by: i32 = @intCast(@mod(y, CHUNK_SIZE));

    const curr = getChunkPtr(cx, cy) orelse return;
    const left = if (cx > 0) getChunkPtr(cx - 1, cy) else null;
    const right = if (cx < SIM_BUFFER_WIDTH - 1) getChunkPtr(cx + 1, cy) else null;
    const top = if (cy > 0) getChunkPtr(cx, cy - 1) else null;
    const bottom = if (cy < SIM_BUFFER_WIDTH - 1) getChunkPtr(cx, cy + 1) else null;

    applyCellWaterFlags(curr, left, right, top, bottom, bx, by);
}

/// Single-pass water flags for whole chunk groups.
fn updateChunkWaterFlags(
    curr: ?*Chunk,
    left: ?*Chunk,
    right: ?*Chunk,
    top: ?*Chunk,
    bottom: ?*Chunk,
) void {
    const c = curr orelse return;
    var by: i32 = 0;
    while (by < CHUNK_SIZE) : (by += 1) {
        var bx: i32 = 0;
        while (bx < CHUNK_SIZE) : (bx += 1) {
            applyCellWaterFlags(c, left, right, top, bottom, bx, by);
        }
    }
}

/// Recalculates solid neighbor edge flags when water is created or destroyed.
fn notifyNeighborEdgeFlags(rx: i32, ry: i32) void {
    var dy: i32 = -1;
    while (dy <= 1) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            if (dx == 0 and dy == 0) continue;
            const nx = rx + dx;
            const ny = ry + dy;
            const neighbor = world.getSimBlockPtr(nx, ny);
            if (neighbor) |nb| {
                if (nb.isSolid() and !nb.isLiquid()) {
                    var flags: u8 = 0;
                    var ndy: i32 = -1;
                    while (ndy <= 1) : (ndy += 1) {
                        var ndx: i32 = -1;
                        while (ndx <= 1) : (ndx += 1) {
                            if (ndx == 0 and ndy == 0) continue;
                            const n_nb = world.getSimBlockPtr(nx + ndx, ny + ndy);
                            if (n_nb) |block| {
                                if (block.isSolid() or block.isLiquid() or getVolume(block) > 0) {
                                    flags |= types.EdgeFlags.getFlagBit(ndx, ndy);
                                }
                            } else {
                                flags |= types.EdgeFlags.getFlagBit(ndx, ndy);
                            }
                        }
                    }
                    nb.edge_flags = flags;
                }
            }
        }
    }
}

/// Runs a single frame of the (mass-conserving) water simulation for blocks within the `SimBuffer`.
/// The chunk neighborhood that one water cell can reach,
/// resolved once per chunk instead of once per cell.
/// Only `curr` is always present; the others are `null` at the simulation buffer edge.
const Neighborhood = struct {
    curr: *Chunk,
    left: ?*Chunk,
    right: ?*Chunk,
    top: ?*Chunk,
    bottom: ?*Chunk,
    chunk_x: i32,
    chunk_y: i32,
    chunk_idx: usize,
};

/// Moves the water in one cell of `hood.curr` down and then sideways.
/// Split out of `tickWater()` and deliberately NOT `inline`:
/// LLVM cost per function is quadratic in basic-block count,
/// so folding this body back into the four nested sweep loops made the Debug build much slower to compile.
/// `ReleaseFast` inlines it again, so runtime does not change.
///
/// `bx` counts along the row in sweep order.
/// The real block column is `rbx`, which reverses on odd rows.
fn simulateCell(
    hood: *const Neighborhood,
    bx: i32,
    by: i32,
    dirty_chunks: *std.StaticBitSet(SIM_BUFFER_SIZE),
) void {
    const curr = hood.curr;
    const left = hood.left;
    const right = hood.right;
    const top = hood.top;
    const bottom = hood.bottom;
    const chunk_idx = hood.chunk_idx;

    // Horizontal sweep direction alternates by ROW parity, not by frame parity:
    // a per-frame flip makes the whole surface visibly slosh left/right every tick,
    // while a fixed per-row direction keeps lateral flow fair with no temporal flicker.
    const rbx = if ((by & 1) == 0) bx else (CHUNK_SIZE - 1) - bx;
    const rx = hood.chunk_x * CHUNK_SIZE + rbx;
    const ry = hood.chunk_y * CHUNK_SIZE + by;
    const idx = @as(usize, @intCast(ry)) * SIM_GRID_SIZE + @as(usize, @intCast(rx));

    if (water_updated.isSet(idx)) return;

    const block_ptr = &curr.blocks[@as(usize, @intCast((by << CHUNK_SIZE_LOG2) | rbx))];
    var src_vol = getVolume(block_ptr.*);
    if (src_vol == 0) return;

    water_updated.set(idx);

    const down_ptr = if (by < CHUNK_SIZE - 1)
        &curr.blocks[@as(usize, @intCast(((by + 1) << CHUNK_SIZE_LOG2) | rbx))]
    else if (bottom) |b|
        &b.blocks[@as(usize, @intCast(rbx))]
    else
        null;

    // Gravity first: pour into the cell below.
    // Full rate into empty space AND into a destination that is itself still falling
    // (its own below can accept water) so streams merge with mid-air droplets,
    // instead of just braking on them and splitting into parity columns (see the file header).
    // The 4-units-per-tick cap only throttles pouring onto a resting pool surface.
    if (down_ptr) |dp| {
        if (dp.isFlowable()) {
            const dest_vol = getVolume(dp.*);
            if (dest_vol < MAX_HP) {
                const available = MAX_HP - dest_vol;
                const is_free_fall = dp.id == .none;
                const cap: u32 = if (is_free_fall)
                    MAX_HP
                else if (getLocalBlockPtr(curr, left, right, top, bottom, rbx, by + 2)) |below_dest|
                    (if (below_dest.isFlowable() and getVolume(below_dest.*) < MAX_HP) MAX_HP else 4)
                else
                    4;
                const amt = @min(@min(src_vol, available), cap);

                setVolumeAt(block_ptr, src_vol - amt, idx);
                // down_ptr is non-null only when a cell below exists, so idx + SIM_GRID_SIZE is in range.
                setVolumeAt(dp, dest_vol + amt, idx + SIM_GRID_SIZE);

                dirty_chunks.set(chunk_idx);
                if (by == CHUNK_SIZE - 1 and bottom != null) {
                    dirty_chunks.set(chunk_idx + SIM_BUFFER_WIDTH);
                }

                src_vol = getVolume(block_ptr.*);
                if (src_vol == 0) return;
            }
        }
    }

    // Lateral flow only happens once the cell can no longer fall, and never from a
    // cell that already received sideways water this tick (stops chain teleports).
    const down_blocked = if (down_ptr) |dp| (!dp.isFlowable() or getVolume(dp.*) >= MAX_HP) else true;
    if (!down_blocked) return;
    if (lateral_received.isSet(idx)) return;

    // Spreading additionally requires RESTING: sitting on something unflowable, or on a
    // full cell that is itself supported. A mid-air cell whose below is only momentarily
    // full (a falling stream backing up for one tick) must hold instead, or the leftover
    // sprays sideways into the alternating parity shelves described in the file header.
    const resting = if (down_ptr) |dp| blk: {
        if (!dp.isFlowable()) break :blk true;
        // down_blocked means dp is full here; resting depends on what dp sits on.
        const dp2 = getLocalBlockPtr(curr, left, right, top, bottom, rbx, by + 2);
        break :blk if (dp2) |b| (!b.isFlowable() or getVolume(b.*) >= MAX_HP) else true;
    } else true;
    if (!resting) return;

    spreadSideways(hood, rbx, by, idx, block_ptr, src_vol, dirty_chunks);
}

/// Decides whether a slope of exactly 1 unit may still move one unit sideways.
/// Such a move is allowed only when it cascades,
/// which means the cell BEYOND the destination is lower still,
/// or when a full and unconfined source tops off a neighbor that sits under a solid block.
/// This grinds leftover slope-1 staircases into near-flat pools without oscillating.
///
/// Returns at most one unit, on at most one side.
/// Split out of `spreadSideways()` and NOT `inline` for the same build-time reason.
fn cascadeSide(
    hood: *const Neighborhood,
    rbx: i32,
    by: i32,
    src_vol: u32,
    left_vol: u32,
    right_vol: u32,
    diff_left: u32,
    diff_right: u32,
) struct { left: u32, right: u32 } {
    const curr = hood.curr;
    const left = hood.left;
    const right = hood.right;
    const top = hood.top;
    const bottom = hood.bottom;
    const rx = hood.chunk_x * CHUNK_SIZE + rbx;
    const ry = hood.chunk_y * CHUNK_SIZE + by;

    // A full, unconfined source may also top off a neighbor sitting directly under a solid block,
    // so confined cells rest at 15 instead of 14.
    // The source must not be confined itself or two capped cells would ping-pong.
    const src_confined = if (getLocalBlockPtr(curr, left, right, top, bottom, rbx, by - 1)) |a| !a.isFlowable() else false;
    const topup_ok = src_vol == MAX_HP and !src_confined;
    var casc_left = false;
    var casc_right = false;
    if (diff_left == 1 and rx > 0 and
        !lateral_received.isSet(@as(usize, @intCast(ry)) * SIM_GRID_SIZE + @as(usize, @intCast(rx - 1))))
    {
        if (getLocalBlockPtr(curr, left, right, top, bottom, rbx - 2, by)) |far| {
            if (far.isFlowable() and getVolume(far.*) < left_vol) casc_left = true;
        }
        if (!casc_left and topup_ok) {
            if (getLocalBlockPtr(curr, left, right, top, bottom, rbx - 1, by - 1)) |a| {
                if (!a.isFlowable()) casc_left = true;
            }
        }
    }
    if (diff_right == 1 and rx < SIM_GRID_SIZE - 1 and
        !lateral_received.isSet(@as(usize, @intCast(ry)) * SIM_GRID_SIZE + @as(usize, @intCast(rx + 1))))
    {
        if (getLocalBlockPtr(curr, left, right, top, bottom, rbx + 2, by)) |far| {
            if (far.isFlowable() and getVolume(far.*) < right_vol) casc_right = true;
        }
        if (!casc_right and topup_ok) {
            if (getLocalBlockPtr(curr, left, right, top, bottom, rbx + 1, by - 1)) |a| {
                if (!a.isFlowable()) casc_right = true;
            }
        }
    }
    if (casc_left and casc_right) {
        // Prefer the side whose far cell sits lower; ties follow the row sweep.
        const far_l = getVolumeLocal(curr, left, right, rbx - 2, by);
        const far_r = getVolumeLocal(curr, left, right, rbx + 2, by);
        if (far_l < far_r) {
            casc_right = false;
        } else if (far_r < far_l or (by & 1) == 0) {
            casc_left = false;
        } else {
            casc_right = false;
        }
    }

    if (casc_left) return .{ .left = 1, .right = 0 };
    if (casc_right) return .{ .left = 0, .right = 1 };
    return .{ .left = 0, .right = 0 };
}

/// Equalizes one resting cell with its two side neighbors.
/// Split out of `simulateCell()` for the same build-time reason, and NOT `inline`.
///
/// Precondition: the caller checked that the cell cannot fall and is resting,
/// and that it did not receive lateral water this tick.
fn spreadSideways(
    hood: *const Neighborhood,
    rbx: i32,
    by: i32,
    idx: usize,
    block_ptr: *Block,
    src_vol: u32,
    dirty_chunks: *std.StaticBitSet(SIM_BUFFER_SIZE),
) void {
    const curr = hood.curr;
    const left = hood.left;
    const right = hood.right;
    const chunk_idx = hood.chunk_idx;
    const rx = hood.chunk_x * CHUNK_SIZE + rbx;
    const ry = hood.chunk_y * CHUNK_SIZE + by;

    const left_ptr = if (rbx > 0)
        &curr.blocks[@as(usize, @intCast((by << CHUNK_SIZE_LOG2) | (rbx - 1)))]
    else if (left) |l|
        &l.blocks[@as(usize, @intCast((by << CHUNK_SIZE_LOG2) | (CHUNK_SIZE - 1)))]
    else
        null;

    const right_ptr = if (rbx < CHUNK_SIZE - 1)
        &curr.blocks[@as(usize, @intCast((by << CHUNK_SIZE_LOG2) | (rbx + 1)))]
    else if (right) |r|
        &r.blocks[@as(usize, @intCast((by << CHUNK_SIZE_LOG2) | 0))]
    else
        null;

    var left_ok = false;
    var right_ok = false;
    var left_vol: u32 = 0;
    var right_vol: u32 = 0;

    const src_press = getVolumeLocal(curr, left, right, rbx, by);
    var left_press: u32 = 0;
    var right_press: u32 = 0;

    if (left_ptr) |b| {
        if (b.isFlowable()) {
            left_press = getVolumeLocal(curr, left, right, rbx - 1, by);
            if (left_press < src_press) {
                left_ok = true;
                left_vol = getVolume(b.*);
            }
        }
    }
    if (right_ptr) |b| {
        if (b.isFlowable()) {
            right_press = getVolumeLocal(curr, left, right, rbx + 1, by);
            if (right_press < src_press) {
                right_ok = true;
                right_vol = getVolume(b.*);
            }
        }
    }

    // Equalize with strictly-lower neighbors, moving up to `diff / 2` (capped at 4) units per side per tick.
    // A difference of 1 only flows when the move cascades (the cell beyond the destination is lower still),
    // which grinds leftover slope-1 staircases into near-flat pools without oscillating.
    const diff_left = if (left_ok) src_press - left_press else 0;
    const diff_right = if (right_ok) src_press - right_press else 0;

    var flow_left: u32 = 0;
    var flow_right: u32 = 0;

    if (diff_left > 1 or diff_right > 1) {
        flow_left = if (diff_left > 1) @min(diff_left / 2, 4) else 0;
        flow_right = if (diff_right > 1) @min(diff_right / 2, 4) else 0;

        const total_flow = flow_left + flow_right;
        if (total_flow > src_vol - 1) {
            const scale = @as(f32, @floatFromInt(src_vol - 1)) / @as(f32, @floatFromInt(total_flow));
            flow_left = @intFromFloat(@as(f32, @floatFromInt(flow_left)) * scale);
            flow_right = @intFromFloat(@as(f32, @floatFromInt(flow_right)) * scale);
            // Truncation can zero BOTH sides (a 2-unit spike flanked by two lower
            // cells would never move); nudge 1 unit toward the deeper drop instead.
            if (flow_left == 0 and flow_right == 0 and src_vol >= 2) {
                if (diff_left > diff_right or (diff_left == diff_right and (by & 1) != 0)) {
                    flow_left = 1;
                } else {
                    flow_right = 1;
                }
            }
        }

        if (left_ok) flow_left = @min(flow_left, MAX_HP - left_vol);
        if (right_ok) flow_right = @min(flow_right, MAX_HP - right_vol);
    } else if (diff_left == 1 or diff_right == 1) {
        const casc = cascadeSide(hood, rbx, by, src_vol, left_vol, right_vol, diff_left, diff_right);
        flow_left = casc.left;
        flow_right = casc.right;
    }

    if (flow_left > 0 or flow_right > 0) {
        setVolumeAt(block_ptr, src_vol - (flow_left + flow_right), idx);
        dirty_chunks.set(chunk_idx);

        if (flow_left > 0) {
            // left_ptr is non-null only when rbx > 0 or a left chunk exists, so rx > 0.
            const left_idx = @as(usize, @intCast(ry)) * SIM_GRID_SIZE + @as(usize, @intCast(rx - 1));
            setVolumeAt(left_ptr.?, left_vol + flow_left, left_idx);
            if (rbx > 0) {
                dirty_chunks.set(chunk_idx);
            } else if (left != null) {
                dirty_chunks.set(chunk_idx - 1);
            }
            lateral_received.set(left_idx);
        }
        if (flow_right > 0) {
            // right_ptr is non-null only when a cell to the right exists, so rx + 1 is in range.
            const right_idx = @as(usize, @intCast(ry)) * SIM_GRID_SIZE + @as(usize, @intCast(rx + 1));
            setVolumeAt(right_ptr.?, right_vol + flow_right, right_idx);
            if (rbx < CHUNK_SIZE - 1) {
                dirty_chunks.set(chunk_idx);
            } else if (right != null) {
                dirty_chunks.set(chunk_idx + 1);
            }
            lateral_received.set(right_idx);
        }
    }
}

pub fn tickWater() void {
    // Phase 1: begin by collecting chunks that hold water and have not settled; skip the whole tick if none.
    active_chunks = std.StaticBitSet(SIM_BUFFER_SIZE).initEmpty();

    var cy: SimIndexType = 0;
    while (true) : (cy += 1) {
        var cx: SimIndexType = 0;
        while (true) : (cx += 1) {
            const chunk_idx = (@as(usize, cy) << world.SIM_WIDTH_LOG2) | cx;
            const sim_idx = SimBuffer.getIndex(cx, cy);
            if (SimBuffer.keys[sim_idx] == null) {
                if (cx == SIM_BUFFER_WIDTH - 1) break;
                continue;
            }

            if (SimBuffer.has_water.isSet(sim_idx) and !SimBuffer.water_settled.isSet(sim_idx)) {
                active_chunks.set(chunk_idx);
            }

            if (cx == SIM_BUFFER_WIDTH - 1) break;
        }
        if (cy == SIM_BUFFER_WIDTH - 1) break;
    }

    if (active_chunks.count() == 0) return;
    water_updated = .initEmpty();
    lateral_received = .initEmpty();
    chunks_to_update_flags = .initEmpty();
    cells_changed = .initEmpty();

    chunks_to_update_flags.setUnion(pending_flag_chunks);
    pending_flag_chunks = std.StaticBitSet(SIM_BUFFER_SIZE).initEmpty();

    const water_before: u64 = if (VERIFY_WATER_MASS) totalSimWater() else 0;

    var dirty_chunks = std.StaticBitSet(SIM_BUFFER_SIZE).initEmpty();

    // Phase 2: sweep active chunks bottom-up so falling water moves one cell per tick without being double-moved
    // (the water_updated bitset guards cells that already took their turn)
    var chunk_y: i32 = SIM_BUFFER_WIDTH - 1;
    while (chunk_y >= 0) : (chunk_y -= 1) {
        var chunk_x: i32 = 0;
        while (chunk_x < SIM_BUFFER_WIDTH) : (chunk_x += 1) {
            const chunk_idx = (@as(usize, @intCast(chunk_y)) << world.SIM_WIDTH_LOG2) | @as(usize, @intCast(chunk_x));

            if (!active_chunks.isSet(chunk_idx)) continue;

            const curr = getChunkPtr(@intCast(chunk_x), @intCast(chunk_y)) orelse continue;
            const left = if (chunk_x > 0) getChunkPtr(@intCast(chunk_x - 1), @intCast(chunk_y)) else null;
            const right = if (chunk_x < SIM_BUFFER_WIDTH - 1) getChunkPtr(@intCast(chunk_x + 1), @intCast(chunk_y)) else null;
            const top = if (chunk_y > 0) getChunkPtr(@intCast(chunk_x), @intCast(chunk_y - 1)) else null;
            const bottom = if (chunk_y < SIM_BUFFER_WIDTH - 1) getChunkPtr(@intCast(chunk_x), @intCast(chunk_y + 1)) else null;

            const hood: Neighborhood = .{
                .curr = curr,
                .left = left,
                .right = right,
                .top = top,
                .bottom = bottom,
                .chunk_x = chunk_x,
                .chunk_y = chunk_y,
                .chunk_idx = chunk_idx,
            };

            var by: i32 = CHUNK_SIZE - 1;
            while (by >= 0) : (by -= 1) {
                var bx: i32 = 0;
                while (bx < CHUNK_SIZE) : (bx += 1) {
                    simulateCell(&hood, bx, by, &dirty_chunks);
                }
            }
        }
    }

    if (VERIFY_WATER_MASS) {
        const water_after = totalSimWater();
        if (water_after != water_before) {
            dw.logger.err(@src(), "Water mass NOT conserved in tickWater: {d} -> {d}", .{ water_before, water_after });
        }
    }

    // Phase 3: active chunks with no movement settle (skipped by future ticks until disturbed);
    // dirty chunks are copied back to the mod store/cache and unsettle themselves plus neighbors.
    var act_it = active_chunks.iterator(.{});
    while (act_it.next()) |idx| {
        if (!dirty_chunks.isSet(idx)) {
            const ax: SimIndexType = @intCast(idx & (SIM_BUFFER_WIDTH - 1));
            const ay: SimIndexType = @intCast(idx >> world.SIM_WIDTH_LOG2);
            SimBuffer.water_settled.set(SimBuffer.getIndex(ax, ay));
        }
    }

    var dirty_it = dirty_chunks.iterator(.{});
    while (dirty_it.next()) |idx| {
        const dy: SimIndexType = @intCast(idx >> world.SIM_WIDTH_LOG2);
        const dx: SimIndexType = @intCast(idx & (SIM_BUFFER_WIDTH - 1));
        const sim_idx = SimBuffer.getIndex(dx, dy);
        const coord = SimBuffer.keys[sim_idx] orelse continue;

        const key = world.DepthCoordinate.from(coord);
        const sim_chunk = &SimBuffer.sim_buffer_ptr[sim_idx];

        SimBuffer.has_water.setValue(sim_idx, SimBuffer.chunkHasWater(sim_chunk));

        // Persist only the cells this tick actually moved.
        const writer = world.mod_store.beginWrite(key);
        const cached = world.chunk_cache.findIndex(coord);
        for (0..CHUNK_SIZE) |by| {
            const row_base = (@as(usize, dy) * CHUNK_SIZE + by) * SIM_GRID_SIZE + @as(usize, dx) * CHUNK_SIZE;
            for (0..CHUNK_SIZE) |bx| {
                if (!cells_changed.isSet(row_base + bx)) continue;
                const block_idx: u8 = @intCast((by << CHUNK_SIZE_LOG2) | bx);
                const block = sim_chunk.blocks[block_idx];
                writer.setBlock(block_idx, block);
                if (cached) |cache_idx| {
                    world.chunk_cache.chunks[cache_idx].blocks[block_idx] = block;
                }
            }
        }

        chunks_to_update_flags.set(idx);
        if (dx > 0) chunks_to_update_flags.set(idx - 1);
        if (dx < SIM_BUFFER_WIDTH - 1) chunks_to_update_flags.set(idx + 1);
        if (dy > 0) chunks_to_update_flags.set(idx - SIM_BUFFER_WIDTH);
        if (dy < SIM_BUFFER_WIDTH - 1) chunks_to_update_flags.set(idx + SIM_BUFFER_WIDTH);

        SimBuffer.water_settled.unset(sim_idx);
        if (dx > 0) SimBuffer.water_settled.unset(SimBuffer.getIndex(dx - 1, dy));
        if (dx < SIM_BUFFER_WIDTH - 1) SimBuffer.water_settled.unset(SimBuffer.getIndex(dx + 1, dy));
        if (dy > 0) SimBuffer.water_settled.unset(SimBuffer.getIndex(dx, dy - 1));
        if (dy < SIM_BUFFER_WIDTH - 1) SimBuffer.water_settled.unset(SimBuffer.getIndex(dx, dy + 1));
    }

    // Phase 4: recompute edge/waterlogged flags for every chunk touched this tick.
    recomputeFlagsFor(&chunks_to_update_flags);
}

/// Recomputes water/edge flags for every resident chunk set in `chunks`.
fn recomputeFlagsFor(chunks: *const std.StaticBitSet(SIM_BUFFER_SIZE)) void {
    var it = chunks.iterator(.{});
    while (it.next()) |idx| {
        const cx: SimIndexType = @intCast(idx & (SIM_BUFFER_WIDTH - 1));
        const cy: SimIndexType = @intCast(idx >> world.SIM_WIDTH_LOG2);
        if (SimBuffer.keys[SimBuffer.getIndex(cx, cy)] == null) continue;

        updateChunkWaterFlags(
            getChunkPtr(cx, cy),
            if (cx > 0) getChunkPtr(cx - 1, cy) else null,
            if (cx < SIM_BUFFER_WIDTH - 1) getChunkPtr(cx + 1, cy) else null,
            if (cy > 0) getChunkPtr(cx, cy - 1) else null,
            if (cy < SIM_BUFFER_WIDTH - 1) getChunkPtr(cx, cy + 1) else null,
        );
    }
}

/// Resolves everything `queueWaterFlags()` has queued immediately, instead of on the next tick.
///
/// Loading needs this: a frame can render before the first tick ever runs,
/// and the flags a save carries may be the stale ones from between a block change and its batched recompute
/// (see `finalizeLoad()`), which draws every queued water cell full for exactly one frame.
pub fn flushPendingFlags() void {
    recomputeFlagsFor(&pending_flag_chunks);
    pending_flag_chunks = std.StaticBitSet(SIM_BUFFER_SIZE).initEmpty();
}
