//! Core datatypes, some of which bridge WASM and Zig, plus the scratch buffer.
//! Also holds a few shared structs and constants.
const std = @import("std");
const builtin = @import("builtin");
const dw = @import("root.zig");

const types = dw.types;
const logger = dw.logger;
const player = dw.player;
const seeding = dw.seeding;
const world = dw.world;

const Sprite = dw.Sprite;
const ColorRgba = dw.ColorRgba;
const Coordinate = dw.world.Coordinate;

const Vec2i = dw.utils.Vec2i;
const Vec2u = dw.utils.Vec2u;
const Vec2f = dw.utils.Vec2f;
const Vec2f32 = dw.utils.Vec2f32;
const Vec4f32 = dw.utils.Vec4f32;

const CHUNK_SIZE_LOG2 = dw.CHUNK_SIZE_LOG2;
const CHUNK_SIZE = dw.CHUNK_SIZE;
const CHUNK_SIZE_SQ = dw.CHUNK_SIZE_SQ;

const ZOOM_FACTOR = dw.ZOOM_FACTOR;

/// Represents a specific category a `[2]u64` slice of `memory.hash_seeds` represents.
/// Use `memory.getHashSeed()` to request said slice (`hash_seeds` automatically resizes at comptime).
///
/// NOTE: updating this changes the world every seed generates, but does NOT invalidate a save:
/// `hash_seeds` is derived from `GameState.seed`, never stored.
pub const SeedType = enum {
    /// Terrain (procedural) property.
    cutoff,
    /// Terrain (procedural) property.
    moisture,
    /// Terrain (procedural) property.
    density,
    /// Terrain (procedural) property.
    density2,
    /// Terrain (procedural) property.
    ore_density,
    /// Terrain (procedural) property.
    weirdness,
    /// Hash used for structure data at base depth for terrain.
    structures,
    /// Seed type that should EXCLUSIVELY be used for PRNG that does not affect gameplay/terrain generation.
    visual,
    /// Position-keyed hash for decorations that must stay consistent across chunk borders (such as hanging vines).
    vine1,
    /// Position-keyed hash for decorations that must stay consistent across chunk borders (such as hanging vines).
    vine2,
    /// Position-keyed hash for decorations that must stay consistent across chunk borders (such as hanging vines).
    vine3,
    /// Position-keyed hash for decorations that must stay consistent across chunk borders (such as hanging vines).
    vine4,
    /// Used for ore generation at base depth.
    ores1,
    /// Used for ore generation at base depth.
    ores2,
    /// Used for ore generation at base depth.
    ores3,
    /// Used for ore generation at base depth.
    ores4,
    /// Used for ore generation at base depth.
    ores5,
    /// Gem occurrence rolls. Separate from the `ores*` lanes on purpose:
    /// the roll and the ore fields are read at the SAME block,
    ///
    /// Appended rather than inserted, so every stream above keeps the `hash_seeds` slot it already had.
    gems,
};

/// Per-category hash lanes for `FastHash`, two `u64` per `SeedType`.
/// Fully derived from `GameState.seed` by `deriveHashSeeds()`, so it is NOT part of the save:
/// a load restores `seed` and then rebuilds this.
/// Every path that sets `GameState.seed` must call `deriveHashSeeds()` before generation runs.
pub var hash_seeds: [@typeInfo(SeedType).@"enum".fields.len * 2]u64 align(16) = @splat(0);

/// Rebuilds `hash_seeds` from the current `game.seed`.
/// Called by `startup.init()` for a new world and by `save.finalizeLoad()` for a loaded one.
pub fn deriveHashSeeds() void {
    var rng = seeding.ChaCha12.init(&seeding.mixBaseSeed(game.seed, .hash_seeds_init));
    for (&hash_seeds) |*s| s.* = rng.next();
}

/// Returns a `hash2d()` seed vector for procedural generation.
/// See `SeedType` definition for the possible categories and their purposes.
pub inline fn getHashSeed(comptime category: SeedType) @Vector(2, u64) {
    const index_start: usize = @as(usize, @intFromEnum(category)) * 2;
    return hash_seeds[index_start .. index_start + 2].*;
}

/// Longest seed string accepted, matching the host's generator and `seedFromBase26()`'s precondition.
pub const SEED_STRING_MAX = 100;

/// Non-pointer data (short known length) representing part of the game state.
/// Data is reserved for numbers or positions that are guaranteed to take a constant memory size.
///
/// Important data is meant to be placed at the start with less important data later.
/// Data can be rearranged or added, as long as -Dgen-enums regenerates TypeScript values.
/// See `game_state_offsets` in `types.zig` for enum export details.
pub const GameState = extern struct {
    /// Represents the player's subpixel position within the CURRENT chunk (0 to 4095), from the CENTER of the sprite.
    player_pos: Vec2i align(MAIN_ALIGN_BYTES) = .{ 0, 0 },
    /// The per-frame delta from this to `player_pos` is the raw movement, but is NOT the velocity:
    /// teleports move `player_pos` without contributing velocity.
    last_player_pos: Vec2i = .{ 0, 0 },
    /// Represents the player's active chunk coordinate (chunk they are currently in; excluding the quadrant part of a `Coordinate`).
    player_chunk: Vec2u = .{ 0, 0 },
    /// Represents the player's current movement velocity (subpixels).
    player_velocity: Vec2f = .{ 0, 0 },
    /// Absolute camera subpixel position (same space as `player_pos`); set equal to it on teleport.
    camera_pos: Vec2i = .{ 0, 0 },
    /// Previous-frame `camera_pos`. The per-frame camera movement is `camera_pos - last_camera_pos`.
    last_camera_pos: Vec2i = .{ 0, 0 },
    /// Represents the camera's zoom scale.
    camera_scale: f64 = player.STARTING_CAMERA_SCALE,
    /// Represents the camera's zoom scale change rate (multiplier, acts as derivative of camera_scale change).
    camera_scale_change: f64 = 1.0,
    /// Represents how many layers deep the player is. Automatically setup in `startup.zig`.
    depth: u64 = 0,

    /// Represents which quadrant (0-3) of the `quad_cache` the player is in (starts at 0 when depth is <= 16).
    /// (0: NW, 1: NE, 2: SW, 3: SE)
    player_quadrant: u8 = 0, // (is u8 for extern only)

    /// Current frame ID. 32-bit; expect wrap-arounds and access with powers-of-2 checks.
    frame: u32 align(4) = 0,

    /// The number of blocks the player has mined.
    blocks_mined: u64 = 0,

    // /// Represents if the grid needs to be recalculated/passed to WGSL.
    // grid_dirty: bool = true,
    // last_grid_min_bx: u32 = 0,
    // last_grid_min_by: u32 = 0,
    // last_player_chunk_x: u64 = 0,
    // last_player_chunk_y: u64 = 0,

    /// Represents the keys that were pressed THIS FRAME. (On the next frame, this will be reset to 0.)
    ///
    /// Example:
    /// ```zig
    /// logger.log(@src(), "{}", .{KeyBits.isSet(KeyBits.up, memory.game.keys_pressed_mask)}); // Gets if UP key was pressed this frame.
    /// ```
    keys_pressed_mask: u32 = 0,
    /// Represents the keys that are currently HELD DOWN.
    ///
    /// Example:
    /// ```zig
    /// logger.log(@src(), "{}", .{KeyBits.isSet(KeyBits.up, memory.game.keys_held_mask)}); // Gets if UP key is being held down.
    /// ```
    keys_held_mask: u32 = 0,

    /// The initial or "global" seed from which all generation starts.
    seed: seeding.Seed = .{},

    /// Chunk holding the portal that started the running descent (see `state/portal.zig`).
    /// Only meaningful while `portal_phase` is not idle; saved so a descent survives a reload.
    portal_chunk: Vec2u = .{ 0, 0 },

    /// Background animation clock, in logical ticks rather than wall time.
    /// Owned here, not by the JS host, so the portal descent can ease it to a standstill.
    /// A save also captures its exact value this way.
    bg_time: f64 = 0.0,

    /// Frames elapsed within the running portal descent; the animation is driven purely off this,
    /// which is what makes it deterministic and resumable after a load.
    portal_frame: u32 = 0,

    /// The running descent's `portal.Phase`, held as its integer tag so `GameState` stays `extern`.
    portal_phase: u8 = 0,
    /// Quadrant of `portal_chunk`.
    portal_quadrant: u8 = 0,
    /// Block within `portal_chunk` the descent zooms into.
    portal_bx: u8 = 0,
    portal_by: u8 = 0,

    /// The seed exactly as it was typed, kept so a world can be re-entered from the string alone.
    ///
    /// `seed` above is the derived 512-bit value.
    /// The mixing that produces it is bijective, but nothing here inverts it.
    /// Without this string a save can generate its world, but can never say which seed made it.
    /// That is the difference between a reproducible bug report and an unreproducible one.
    /// Only the first `seed_string_len` bytes are meaningful, and the rest stay zero.
    ///
    /// New fields belong at the END of `GameState`.
    /// `src/enums.ts` carries generated byte offsets for `seed` that the host writes through.
    /// A field inserted above them silently moves the target of those writes.
    seed_string: [SEED_STRING_MAX]u8 align(8) = @splat(0),
    /// Characters used in `seed_string`, never above `SEED_STRING_MAX`.
    seed_string_len: u8 = 0,

    /// The deepest depth the player has reached, called the FRONTIER.
    /// Never decreases for the life of a world.
    ///
    /// This is the timeline authority (see `world.isAboveFrontier()`).
    /// An edit at a depth below this value is local to that depth:
    /// deeper depths keep the material they inherited when they were made.
    /// Initialized in `startup.zig`, and raised by `world.commitLayer()`.
    max_depth_reached: u64 align(8) = 0,

    /// Records the seed string the world was created from.
    /// An oversized string truncates instead of failing.
    /// The derived `seed` is already in place by this point, and half a record beats none.
    pub fn setSeedString(self: *@This(), text: []const u8) void {
        const len = @min(text.len, SEED_STRING_MAX);
        self.seed_string = @splat(0);
        @memcpy(self.seed_string[0..len], text[0..len]);
        self.seed_string_len = @intCast(len);
    }

    /// The seed string, or an empty slice for a world made before one was recorded.
    pub fn getSeedString(self: *const @This()) []const u8 {
        return self.seed_string[0..self.seed_string_len];
    }

    /// Gets the player's current chunk location as a `Coordinate`.
    pub inline fn getPlayerCoord(self: *const @This()) Coordinate {
        return .{ .quadrant = @intCast(self.player_quadrant), .suffix = self.player_chunk };
    }

    /// Gets which (X-coordinate) block the player is "on" within a chunk.
    /// Based on the player's center, rounded down.
    pub inline fn getBlockXInChunk(self: *const @This()) u4 {
        return @intCast(@divTrunc(self.player_pos[0], CHUNK_SIZE_SQ));
    }
    /// Gets which (Y-coordinate) block the player is "on" within a chunk.
    /// Based on the player's center, rounded down.
    pub inline fn getBlockYInChunk(self: *const @This()) u4 {
        return @intCast(@divTrunc(self.player_pos[1], CHUNK_SIZE_SQ));
    }

    /// Teleports the player, resetting the player position and camera position,
    /// as well as movement constants such as gravity.
    ///
    /// Also fully clears caches.
    pub inline fn teleport(self: *@This(), coord: ?Coordinate, new_position: Vec2i) void {
        // Clears the airborne/jump bookkeeping too, not just the accumulator: arriving somewhere new
        // must not carry over a coyote window earned before the teleport.
        player.resetMotionState();
        self.player_velocity = .{ 0.0, 0.0 };
        if (coord) |c| {
            std.debug.assert(world.isInWorld(c, self.depth));
            self.player_quadrant = c.quadrant;
            self.player_chunk = c.suffix;
        }
        std.debug.assert(new_position[0] >= 0 and new_position[0] < dw.SUBPIXELS_IN_CHUNK);
        std.debug.assert(new_position[1] >= 0 and new_position[1] < dw.SUBPIXELS_IN_CHUNK);
        self.player_pos = new_position;
        self.last_player_pos = new_position;
        // Snap BOTH current and previous camera to the destination (preventing interpolation funnies).
        self.camera_pos = new_position;
        self.last_camera_pos = new_position;
        world.clearCaches(false);
    }

    /// Sets the player position within a chunk, and teleports the previous position too.
    /// Also clears the subpixel accumulation and the velocity.
    ///
    /// Considered dumb.
    /// Do not use it for movement: it does no frame interpolation, and it takes no
    /// `Coordinate`, so a quadrant change is wrong.
    /// It also fails to handle caches.
    ///
    /// Prefer `teleport()`, unless the player must move and the camera must not.
    pub inline fn setPlayerPosDumb(self: *@This(), new_position: Vec2i) void {
        player.subpixel_accum = .{ 0.0, 0.0 };
        self.player_velocity = .{ 0.0, 0.0 };
        self.player_pos = new_position;
        self.last_player_pos = new_position;
    }

    /// Sets the camera position within a chunk, teleporting the previous position as well.
    /// Do not use for movement; also clears subpixel accumulation; does NOT clear caches.
    ///
    /// It is probably better to use `teleport()`,
    /// unless you need the camera's position to change but not the player's.
    pub inline fn setCameraPosDumb(self: *@This(), new_position: Vec2i) void {
        player.subpixel_accum = .{ 0.0, 0.0 };
        self.camera_pos = new_position;
        self.last_camera_pos = new_position;
    }
};

/// The state of the current game, containing pre-allocated properties.
pub var game: GameState = .{};

/// System-level allocator for pages (or testing allocator when running tests).
/// On WASM, this grows the linear heap.
/// On native, this requests pages from the OS.
/// Use as a backing for other allocators.
pub const page_allocator: std.mem.Allocator =
    if (builtin.is_test) std.testing.allocator else std.heap.page_allocator;

/// An instance of the general-purpose allocator (or testing allocator when running tests).
/// Use `makeArena()` to create an `ArenaAllocator` around this (WASM has no SMP allocator support).
pub const main_allocator: std.mem.Allocator =
    if (builtin.is_test)
        std.testing.allocator
    else if (builtin.single_threaded and (builtin.cpu.arch.isWasm() or builtin.os.tag == .linux))
        std.heap.brk_allocator
    else if (builtin.single_threaded)
        std.heap.c_allocator
    else
        std.heap.smp_allocator;

/// Creates an `ArenaAllocator` around the `page_allocator`.
/// Prefer the scratch buffer for a temporary calculation in a callee.
/// Store `len` in the caller, then read `scratch_ptr` again.
///
/// Example temporary usage:
/// ```zig
/// var arena = memory.makeArena();
/// const allocator = arena.allocator();
/// defer arena.deinit();
/// var list: std.ArrayList(u64) = .empty;
/// list.append(allocator, 12345) catch {};
/// ```
///
/// Alternative for repeated scratchpad use:
/// ```zig
/// var arena = memory.makeArena();
/// var alloc = arena.allocator();
/// fn resetArena() void {
///     if (!arena.reset(.retain_capacity)) memory.oom();
/// }
/// ```
pub fn makeArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(page_allocator);
}

/// Start the scratch buffer with 4 MiB when allocating for the first time.
const STARTING_SCRATCH_BUFFER_SIZE = 4 * MemorySizes.MiB;

/// 64 bytes is an all-round good alignment size in terms of cache pages.
pub const MAIN_ALIGN_BYTES: usize = 64;
/// Type-safe alignment for use with `std.mem.Allocator` functions.
/// Derived from `MAIN_ALIGN_BYTES`.
pub const MAIN_ALIGN = std.mem.Alignment.fromByteUnits(MAIN_ALIGN_BYTES);

/// Struct for various memory sizes.
pub const MemorySizes = struct {
    /// Represents 1,024 bytes.
    pub const KiB = 1024;
    /// Represents 1,024 * 1,024 bytes.
    pub const MiB = 1024 * 1024;
    /// Represents 1,024 * 1,024 * 1,024 bytes.
    pub const GiB = 1024 * 1024 * 1024;
    /// Represents the size of a WebAssembly page (64KiB).
    pub const wasm_page = 64 * 1024;
};

/// One channel of a block's resolved light.
/// See `BlockLight` for what the three of them mean.
/// Six bits each for the L, C, and H channels.
pub const LightChannel = u6;
/// Largest `LightChannel` value.
/// Every channel maps 0..this onto the top of its own range.
pub const LIGHT_MAX: LightChannel = std.math.maxInt(LightChannel);

/// The light one block receives, as OKLCH, quantized the way `Block` stores it.
///
/// Lightness MULTIPLIES the sprite's own OKLAB lightness.
/// So 0 is pitch black, and `LIGHT_MAX` leaves the sprite alone.
///
/// Chroma and hue are ADDED in OKLAB, so a colored lamp tints a block instead of
/// replacing its material.
/// Stone under a violet lamp still reads as stone.
///
/// `render/lighting.zig` produces these, and `fs_tile()` in `src/shader.wgsl` consumes them.
pub const BlockLight = struct {
    /// 0..`LIGHT_MAX` onto 0..1.
    l: LightChannel = 0,
    /// 0..`LIGHT_MAX` onto 0..`lighting.LIGHT_CHROMA_MAX`, in OKLAB units.
    c: LightChannel = 0,
    /// A full turn in `lighting.HUE_STEPS` WRAPPING steps, so the value after the last
    /// is the first again.
    /// Meaningless when `c` is 0.
    h: LightChannel = 0,

    /// Full, untinted light: what a block carries before any lighting pass has run on it.
    pub const full: BlockLight = .{ .l = LIGHT_MAX };
    /// No light at all.
    pub const none: BlockLight = .{};
};

/// A `Sprite` id and its packed properties, ready for the GPU or for a cache.
///
/// Field order keeps every field inside one aligned 32-bit word.
/// So `unpack_tile()` in `src/shader.wgsl` reads each one with a single `extractBits()`:
/// - word0: `id` | `edge_flags` | `light_l`
/// - word1: `hp` | `seed` (the shader reads the whole word as seed0, so `hp` is folded into the seed for free)
/// - word2: `base_id` | `id_edge_flags` | `light_c`
/// - word3: `water` | `tag` | `light_h` (the shader reads `water` and `light_h`, never `tag`)
///
/// The three light channels are split across three words on purpose.
/// 18 bits do not fit in any one word beside what already lives there,
/// and the shader pays one `extractBits()` either way.
pub const Block = packed struct(u128) {
    /// A block with an `id` of `none`.
    pub const empty: Block = .makeBasicBlock(.none, 0);

    /// Maximum value for `hp`.
    /// `hp` is a `u4`, sharing word1's low bits with `seed`, and MUST stay 0-15.
    /// The atlas has exactly 16 HP masks, and the water volume simulation assumes 0-15.
    pub const MAX_HP: u4 = 15;

    /// The primary sprite: the overlay/block itself (such as the ore rather than the block beneath).
    id: Sprite,
    /// Edge flags: explains details for neighbors (for both shader and procedural generation).
    /// Starts from top left, then middle left, and ending at bottom right (skipping itself).
    /// See `types/types.zig` for more details on correspondence.
    ///
    /// - A 1 bit for a solid block ordinarily indicates an edge with an adjacent solid block.
    /// - A 1 bit for a liquid block means that there is either solid or liquid adjacent.
    ///
    /// Edge flags must be reset to 255 for decorations (non-blocks or liquids) after a final decoration pass.
    edge_flags: u8,
    /// Lightness of the light reaching this block; see `BlockLight.l`.
    light_l: LightChannel = 0,
    /// Unused portion of word0.
    _pad0: u2 = 0,

    /// Dual-purpose field depending on block type (range 0-15, see `MAX_HP`):
    /// - For solid blocks: how "mined" the block is (0 means unmined, 15 is most mined).
    /// - For liquid (water) and decoration blocks: the water volume level from 0 to 15.
    hp: u4,
    /// Per-block seed for procedural variation in the shader.
    /// Any seed value here should be considered poor and insecure.
    seed: u28,

    /// The background tile behind an overlay sprite, such as the stone an ore grew inside.
    /// `.none` means "no underlay", and the shader then draws `id` alone.
    /// The `.none` case is the default for a block that is not an ore or a gem!
    base_id: Sprite = .none,
    /// Same-sprite edge flags, in the same bit order as `edge_flags`.
    /// A bit is set when the neighbor's `id` equals this block's `id`.
    /// Drives the ore overlay mask so a vein reads as connected only to itself.
    /// Follows the same 0xFF reset rule as `edge_flags` for decorations/air.
    id_edge_flags: u8 = 0,
    /// Chroma of the light reaching this block; see `BlockLight.c`.
    light_c: LightChannel = 0,
    /// Unused portion of word2.
    _pad2: u2 = 0,

    /// The water around this block, in the shape its own kind wants it.
    /// See `water.WaterState`, which explains why `id` is what picks the view.
    water: dw.water.WaterState = .dry,

    /// What this block was refined out of, once its own `id` no longer says so.
    /// That is the canopy of a shrub that is now leaf stone,
    /// or how far a vine cell hangs below its ceiling.
    /// See `refine.RefinedTag`.
    ///
    /// Derived, like the flag fields.
    /// Regeneration rebuilds it, `ModCell` does not store it,
    /// and a cell the player edits keeps the edit and loses the tag.
    /// The shader never reads it; it reads `water` below this field and `light_h` above it.
    tag: dw.refine.RefinedTag = .{},
    /// Hue of the light reaching this block; see `BlockLight.h`.
    light_h: LightChannel = 0,

    /// Makes a simple block of a certain type, with full light and no derived edge flags or mine level.
    /// An `edge_stone` block uses the `0xFF` non-participating edge sentinel.
    /// Uses the BOTTOM 32 bits from `seed_bits` to place into `seed`.
    pub inline fn makeBasicBlock(sprite_type: Sprite, seed_bits: u64) Block {
        return .{
            .id = sprite_type,
            .hp = if (sprite_type.isLiquid()) MAX_HP else 0,
            .edge_flags = if (sprite_type == .edge_stone) 0xFF else 0,
            .id_edge_flags = if (sprite_type == .edge_stone) 0xFF else 0,
            .light_l = LIGHT_MAX,
            .seed = @truncate(seed_bits),
            .water = .dry,
        };
    }

    /// The light this block currently carries.
    pub inline fn getLight(self: @This()) BlockLight {
        return .{ .l = self.light_l, .c = self.light_c, .h = self.light_h };
    }

    /// Writes all three light channels at once, so no caller can set two of the three and forget one.
    pub inline fn setLight(self: *@This(), value: BlockLight) void {
        self.light_l = value.l;
        self.light_c = value.c;
        self.light_h = value.h;
    }

    /// Determines if the sprite's type is one that should interact with the edge flags and procedural generation.
    /// This returns false for edge stone, unlike `isSolid()`.
    pub inline fn isFoundation(self: @This()) bool {
        return self.id.isFoundation();
    }

    /// Determines if a sprite-type is digging. Hard-coded.
    pub inline fn isInWorld(self: @This()) bool {
        return self.id.isInWorld();
    }

    /// Determines if the block's type is solid for physics and terrain geometry.
    /// This returns true for edge stone, unlike `isFoundation()`.
    pub inline fn isSolid(self: @This()) bool {
        return self.id.isSolid();
    }

    /// Determines if the block's type is a liquid (such as water).
    pub inline fn isLiquid(self: @This()) bool {
        return self.id.isLiquid();
    }

    /// Determines if the block's type is `none` (air/void).
    pub inline fn isEmpty(self: @This()) bool {
        return self.id.isEmpty();
    }

    /// Determines if the block is stone (or a variation). Excludes edge stone.
    pub inline fn isStone(self: @This()) bool {
        return self.id.isStone();
    }

    /// Determines if the block is an ore.
    pub inline fn isOre(self: @This()) bool {
        return self.id.isOre();
    }

    /// Determines if the block is a gem.
    pub inline fn isGem(self: @This()) bool {
        return self.id.isGem();
    }

    /// Returns the cascade anchoring rules for this block.
    pub inline fn anchor(self: @This()) dw.sprite.AnchorKind {
        return self.id.anchor();
    }

    /// Determines if the block is a heatmap (types 65000-65256).
    pub inline fn isHeatmap(self: @This()) bool {
        return self.id.isHeatmap();
    }

    /// Returns whether a block is empty (air), a liquid, or a waterloggable decoration.
    /// Precondition: the block's sprite type is valid.
    pub inline fn isFlowable(self: @This()) bool {
        return self.id.isFlowable();
    }

    /// Returns whether a block is a valid decoration block.
    /// Precondition: the block's sprite type is valid.
    pub inline fn isDecor(self: @This()) bool {
        return self.id.isDecor();
    }

    /// Determines whether the sprite should use a digging sound effect.
    pub inline fn isDigged(self: @This()) bool {
        return self.id.isDigged();
    }

    /// Returns whether a block lets water flow through it and stores directional waterlogging (decor/crafter).
    /// Precondition: the block's sprite type is valid.
    pub inline fn isWaterloggable(self: @This()) bool {
        return self.id.isWaterloggable();
    }

    /// Returns whether a block is mined instantly like decor despite being solid (such as leaves).
    /// Precondition: the block's sprite type is valid.
    pub inline fn isInstantMine(self: @This()) bool {
        return self.id.isInstantMine();
    }
};

/// Chunk/procedural generation information that can be converted to `Block` via `compile()`.
/// Deliberately excludes render/simulation state (light, edge flags, waterlogging), which later passes own.
pub const BlockSpec = struct {
    id: Sprite = .none,
    /// Underlying tile for overlay sprites (ores/gems); `.none` means no underlay.
    base_id: Sprite = .none,
    /// Uses the BOTTOM 32 bits when compiled into `Block.seed`.
    seed: u64 = 0,
    /// Starting water volume (0-15) for a waterloggable cell generated inside a pool,
    /// or for a liquid cell that is only partly full.
    /// Meaningless for a solid, whose `hp` is mining progress and always generates at 0.
    ///
    /// Zero on a LIQUID means "unspecified", and fills the cell to `MAX_HP`,
    /// which is what `makeBasicBlock()` does.
    /// Only a "partial" liquid states a volume, so the default suits every other caller.
    ///
    /// A cell generated at the wrong volume is NOT at equilibrium.
    /// The sim corrects it on the chunk's first tick.
    /// That dirties the chunk and writes a modification entry with no player involvement.
    water_volume: u4 = 0,
    /// Provenance to carry into the block; see `Block.tag`.
    tag: dw.refine.RefinedTag = .{},

    /// Compiles the spec into a packed `Block` (max light, no edge flags or mine level, matching `makeBasicBlock()`).
    pub inline fn compile(self: @This()) Block {
        var block: Block = .makeBasicBlock(self.id, self.seed);
        block.base_id = self.base_id;
        block.tag = self.tag;
        if (self.id.isLiquid()) {
            if (self.water_volume != 0) block.hp = self.water_volume;
        } else if (self.id.isWaterloggable()) block.hp = self.water_volume;
        return block;
    }
};

/// 16x16 fixed grid of blocks. Each chunk is 4KiB in size.
pub const Chunk = struct {
    blocks: [CHUNK_SIZE_SQ]Block align(MAIN_ALIGN_BYTES),

    /// Gets a specific block within the 16x16 chunk.
    pub inline fn getBlock(self: @This(), x: u4, y: u4) Block {
        return self.blocks[(@as(usize, y) << CHUNK_SIZE_LOG2) | @as(usize, x)];
    }
};

/// Bytes of block data in one `Chunk` (`CHUNK_SIZE_SQ` * 16 = 4096).
/// Chunk-cache layouts (such as `AncestorCache`) budget their footprint in multiples of this.
pub const CHUNK_BYTES = CHUNK_SIZE_SQ * @sizeOf(Block);

/// Data for a single particle (converted to `WGSLEntity` before sending to WGSL).
pub const Particle = struct {
    /// Current position (based on internal viewport).
    position: Vec2f32,

    /// Velocity vector for position.
    d_position: Vec2f32,

    /// The color of the particle (alpha is multiplied by time and how long the particle lasts).
    color: ColorRgba,
    /// The size of the particle.
    size: f32,
    /// The opacity of the particle (based on time start/end).
    opacity: f32,

    /// The rotation of the particle (radians).
    rotation: f32,
    /// The rate of change of rotation of the particle (radians).
    d_rotation: f32,

    /// The time at which the particle spawned in from (performance.now()).
    time_start: f64,

    /// The time at which the particle will disappear.
    time_end: f64,
};

/// Default LCHA configuration to result in the same colors as the original sprite after mask.
pub const DEFAULT_ENTITY_LCHA: Vec4f32 = .{ 1.0, 0.0, 0.0, 1.0 };

/// Entity data (before being sent to WGSL, using internal viewport).
/// Allows for size, rotation, and OKLCH + alpha (opacity) changes to any chosen sprite.
pub const Entity = struct {
    /// The light, chroma, hue, and opacity components (HSL + alpha).
    /// L (lightness) and alpha components are multiplied by the sprite's color in WebGPU.
    /// H (hue, in radians) and C (chroma) are shifted additively.
    lcha: Vec4f32 = DEFAULT_ENTITY_LCHA,

    /// Current center position of the sprite (based on internal viewport).
    position: Vec2f32,

    /// The size of the entity (based on internal viewport). Square shape.
    /// Flip in the X-axis only by setting this to a negative value.
    size: f32 = 16.0,

    /// The rotation of the entity (radians).
    rotation: f32 = 0.0,

    /// The sprite type of the entity to use.
    sprite: Sprite = .none,
};

/// Describes two properties:
/// - Whether the `position` property in a `SizedEntity` references the top left or center of an entity.
/// - Whether `position` and `size` are scaled based on the UV or internal viewport coordinates.
pub const PositionType = enum {
    top_left_uv,
    center_uv,
    top_left_viewport,
    center_viewport,
};

/// Alternative representation of entity data (before being sent to WGSL).
/// Allows for size, rotation, and OKLCH + alpha (opacity) changes to any chosen sprite.
pub const SizedEntity = struct {
    /// The light, chroma, hue, and opacity components (HSL + alpha).
    /// L (lightness) and alpha components are multiplied by the sprite's color in WebGPU.
    /// H (hue, in radians) and C (chroma) are shifted additively.
    lcha: Vec4f32 = DEFAULT_ENTITY_LCHA,

    /// Current center position of the sprite.
    position: Vec2f32,

    /// The size of the entity.
    /// Unlike `Entity`, allows for both X and Y scaling.
    size: Vec2f32,

    /// Type of coordinates to use.
    /// By default, `position` is the top left, in UV-based coordinates.
    system: PositionType = .top_left_uv,

    /// The rotation of the entity (radians).
    rotation: f32 = 0.0,

    /// The sprite type of the entity to use.
    sprite: Sprite = .none,
};

/// Tightly packed data for a entity to be sent directly to WGSL (using UV coordinates).
/// Allows for size, rotation, and OKLCH + alpha (opacity) changes to any chosen sprite.
pub const WGSLEntity = extern struct {
    /// The light, chroma, hue, and opacity components (HSL + alpha).
    /// L (lightness) and alpha components are multiplied by the sprite's color in WebGPU.
    /// H (hue) and C (chroma) are shifted additively in radians.
    lcha: Vec4f32 align(16),

    /// Current center position of the sprite (based on UV, not the internal viewport).
    position: Vec2f32,

    /// The width and height of the entity (based on UV, not the internal viewport).
    size: Vec2f32,

    /// The rotation of the entity (radians).
    rotation: f32,

    /// The ID of the entity (sprite type).
    id: u32,
};

/// A growable scratch buffer for a one-time pass of data, such as a string or particle data.
/// Assumes fully single-thread communication.
/// `logger.zig` keeps a separate, smaller `logging_buffer`.
///
/// Treat the contents as corrupt as soon as any other function that can write the
/// scratch buffer runs.
/// It is a temporary "handshake" between Zig and TypeScript, nothing more.
pub var scratch_buffer: []align(MAIN_ALIGN_BYTES) u8 = &[_]u8{};
var is_dynamic_scratch: bool = false;

/// The layout structure shared with TypeScript.
/// The `MemoryLayout` instance never moves, but its properties can change.
pub const MemoryLayout = extern struct {
    /// 64-bit integeric pointer to the scratch buffer.
    scratch_ptr: u64 align(MAIN_ALIGN_BYTES),
    /// The current length or offset used within the scratch buffer.
    scratch_len: u64,
    /// The total capacity of the fixed scratch buffer (starts off at 4 MiB).
    scratch_capacity: u64,
    /// 64-bit integeric pointer to the GameState.
    game_ptr: u64,
    /// Additional properties for sending additional (numeric, pointer, or short fixed-length) properties.
    /// Treat the contents as corrupt as soon as any other function that can write the
    /// scratch buffer runs.
    /// This array is a temporary "handshake" to trade information between Zig and TypeScript.
    /// Prefer function arguments when you send data to Zig.
    scratch_properties: [20]u64,
};

/// Global static instance of the layout, so the pointer stays valid for JS.
/// It starts near the start of a WASM page.
pub var mem: MemoryLayout align(MAIN_ALIGN_BYTES) = .{
    .scratch_ptr = 0, // pointer is set in startup.zig's init
    .scratch_len = 0,
    .scratch_capacity = 0,
    .game_ptr = 0,
    .scratch_properties = undefined, // start with empty
};

/// Returns the pointer to the memory layout for TypeScript to consume.
pub fn getMemoryLayoutPtr() *align(MAIN_ALIGN_BYTES) const MemoryLayout {
    mem.scratch_ptr = @intFromPtr(scratch_buffer.ptr);
    mem.game_ptr = @intFromPtr(&game);
    return &mem;
}

/// Allocates memory in WASM that JS can write to.
pub fn wasmAlloc(len: usize) ?[*]u8 {
    const slice = main_allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

/// Frees memory allocated via wasm_alloc.
pub fn wasmFree(ptr: [*]u8, len: usize) void {
    main_allocator.free(ptr[0..len]);
}

/// Calls `@panic()` for an out-of-memory issue.
/// Use with `catch memory.oom()` when performing an allocation.
pub fn oom() noreturn {
    @branchHint(.cold);
    @panic("Ran out of memory when attempting to perform an allocation!");
}

/// Determines if scratch_buffer has at least `len` additional available capacity while aligning with `MAIN_ALIGN`.
/// If not, expands with the system's page allocator.
/// Does NOT set the `scratch_len` property; only allocates sufficiently (using `scratch_capacity`).
pub fn scratchAlloc(len: usize) [*]u8 {
    const base_addr = @intFromPtr(scratch_buffer.ptr);
    const current_used: usize = @intCast(mem.scratch_len);
    const current_addr = base_addr + current_used;
    const aligned_addr = std.mem.alignForward(usize, current_addr, MAIN_ALIGN_BYTES);
    const new_scratch_len = (aligned_addr - base_addr) + len;

    if (!is_dynamic_scratch or new_scratch_len > scratch_buffer.len) {
        @branchHint(.cold);
        return growScratchBuffer(len, new_scratch_len);
    }

    // Fits in existing buffer already, fast!
    mem.scratch_len = @intCast(new_scratch_len);
    return @ptrFromInt(aligned_addr);
}

/// Internal function to grow the scratch buffer.
fn growScratchBuffer(len: usize, new_scratch_len: usize) [*]u8 {
    const current_used: usize = @intCast(mem.scratch_len);

    // Final capacity becomes 256KiB, 1.5x growth, or the requested length, whichever is largest.
    const growth_150_percent = scratch_buffer.len + (scratch_buffer.len >> 1);
    // const clamped_growth = @min(growth_150_percent, scratch_buffer.len + (32 * MemorySizes.MiB));
    const new_cap = @max(STARTING_SCRATCH_BUFFER_SIZE, growth_150_percent, new_scratch_len);

    if (!is_dynamic_scratch) {
        @branchHint(.cold);
        scratch_buffer = page_allocator.alignedAlloc(u8, MAIN_ALIGN, new_cap) catch oom();
        is_dynamic_scratch = true;
    } else {
        scratch_buffer = page_allocator.realloc(scratch_buffer, new_cap) catch oom();
    }

    // Update JS metadata
    mem.scratch_ptr = @intFromPtr(scratch_buffer.ptr);
    mem.scratch_capacity = scratch_buffer.len;

    // Re-calculate the return pointer based on the new base address
    const updated_base = @intFromPtr(scratch_buffer.ptr);
    const updated_aligned = std.mem.alignForward(usize, updated_base + current_used, MAIN_ALIGN_BYTES);
    mem.scratch_len = @intCast((updated_aligned - updated_base) + len);
    return @ptrFromInt(updated_aligned);
}

/// Pushes one tightly-packed `WGSLEntity` (48-byte stride) into the scratch buffer and returns a pointer to it.
///
/// Entities are written back-to-back with no padding.
/// So JS reads them as a flat `entity_count * 48` block.
///
/// The scratch base is 64-aligned and 48 is a multiple of 16.
/// So every entity stays 16-byte aligned, which is what `WGSLEntity` needs,
/// with no per-call alignment bookkeeping.
///
/// Precondition: called from an aligned start (such as right after `scratchReset()`),
/// as the tight packing relies on the running `scratch_len` being a multiple of `@sizeOf(WGSLEntity)`.
pub inline fn scratchPushEntity() *WGSLEntity {
    const off: usize = @intCast(mem.scratch_len);
    // Makes sure of the capacity, growing or moving the buffer if needed. Its aligned bump is overwritten below.
    _ = scratchAlloc(@sizeOf(WGSLEntity));
    mem.scratch_len = off + @sizeOf(WGSLEntity);
    // Derive the pointer from scratch_buffer.ptr AFTER the possible grow, so it can never be stale.
    return @ptrCast(@alignCast(scratch_buffer.ptr + off));
}

/// Allocates a typed slice in the scratch buffer (aligned).
/// This is the ideal fast way to write structural data (like chunks) directly into the buffer if length is known up front.
pub inline fn scratchAllocSlice(comptime T: type, count: usize) []T {
    const byte_count = count * @sizeOf(T);
    const ptr = scratchAlloc(byte_count);
    return @as([*]T, @ptrCast(@alignCast(ptr)))[0..count];
}

/// Views the entire used portion of the scratch buffer as a single typed slice.
/// Note: This will error if `mem.scratch_len` is not an exact multiple of `@sizeOf(T)`.
///
/// Only use this if the entire frame's scratch buffer contains a single data type.
pub inline fn scratchAsSlice(comptime T: type) []T {
    const bytes = scratch_buffer[0..mem.scratch_len];
    return std.mem.bytesAsSlice(T, bytes);
}

/// Runs a set of tests (which should be called from JS) for the scratch allocation. (See `root.zig` for export logic.)
pub fn runScratchAllocTests() void {
    scratchReset();

    // Force starting scratch allocation (if it hadn't existed already).
    const len1 = 100;
    _ = scratchAlloc(len1);

    const heap_cap = scratch_buffer.len;
    const current_used = std.mem.alignForward(usize, @intCast(mem.scratch_len), MAIN_ALIGN_BYTES);
    if (STARTING_SCRATCH_BUFFER_SIZE < len1 or scratch_buffer.len != STARTING_SCRATCH_BUFFER_SIZE) @panic("Scratch buffer length does not match starting buffer size");

    if (heap_cap <= current_used) @panic("Bootstrap failed to provide excess capacity");
    const rem = heap_cap - current_used;

    // Fill to the exact amount of capacity
    _ = scratchAlloc(rem);
    if (scratch_buffer.len != heap_cap) @panic("Buffer expanded before reaching capacity");
    logger.log(@src(), "Requested {d} bytes successfully without buffer expansion.", .{rem});

    // force expansion and reallocate
    const len_exp = 64;
    _ = scratchAlloc(len_exp);

    if (scratch_buffer.len <= heap_cap) @panic("Buffer failed to grow after exceeding capacity");
    if (mem.scratch_ptr != @intFromPtr(scratch_buffer.ptr)) @panic("JS pointer desync");

    scratchReset();
    logger.log(@src(), "Scratch tests passed! Final capacity: {d} bytes.", .{scratch_buffer.len});
}

/// Resets the scratch offset for the next frame or operation.
/// JS does not call this; it uses the helpers in `engine.ts` instead.
pub inline fn scratchReset() void {
    mem.scratch_len = 0;
}

/// Sets a scratch property (uses generic compile-time inferences).
pub inline fn setScratchProp(index: usize, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .float => mem.scratch_properties[index] = @bitCast(@as(f64, @floatCast(value))),
        .int => |int_info| {
            if (int_info.signedness == .signed) {
                mem.scratch_properties[index] = @bitCast(@as(i64, @intCast(value)));
            } else {
                mem.scratch_properties[index] = @as(u64, @intCast(value));
            }
        },
        .comptime_float => mem.scratch_properties[index] = @bitCast(@as(f64, value)),
        .comptime_int => mem.scratch_properties[index] = @bitCast(@as(i64, value)),
        else => @compileError("Unsupported type for set_scratch_prop: " ++ @typeName(T)),
    }
}

/// Gets a scratch property as u64.
pub inline fn getScratchProp(index: usize) u64 {
    return mem.scratch_properties[index];
}

/// Gets a scratch property as i64.
pub inline fn getSignedScratchProp(index: usize) i64 {
    return @bitCast(mem.scratch_properties[index]);
}

/// Gets a scratch property as f64.
pub inline fn getFloatScratchProp(index: usize) f64 {
    return @bitCast(mem.scratch_properties[index]);
}

comptime {
    if (STARTING_SCRATCH_BUFFER_SIZE <= 0 or (STARTING_SCRATCH_BUFFER_SIZE % @alignOf(@TypeOf(scratch_buffer)) != 0)) {
        @compileError("Buffer size must be a positive multiple of its alignment.");
    }
    if (MAIN_ALIGN_BYTES < 16 or (MAIN_ALIGN_BYTES % 16 > 0)) {
        @compileError("MAIN_ALIGN_BYTES should be a positive multiple of 16 for SIMD alignment.");
    }
    if (@sizeOf(Block) != 16) {
        @compileError("Memory size for each block should be 16 bytes.");
    }
    if (@sizeOf(Chunk) != CHUNK_BYTES) {
        @compileError("Chunk must be exactly CHUNK_BYTES with no trailing padding.");
    }
    if (@sizeOf(WGSLEntity) != 48) {
        @compileError("WGSL entity must be 48 bytes!");
    }
}
