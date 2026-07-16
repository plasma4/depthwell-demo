//! Contains important datatypes, some of which bridge WASM and Zig, as well as scratch buffer logic. Also contains some structs and commonly used constants.
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

/// Represents a specific category a `[2]u64` slice of `memory.game.seed2` represents.
/// Use `memory.game.getHashSeed()` to request said slice.
pub const SeedType = enum {
    /// Determines the moisture property at base depth for terrain.
    moisture,
    /// Determines the density property at base depth for terrain.
    density,
    /// Hash used for structure data at base depth for terrain.
    structures,
    /// Seed type that should EXCLUSIVELY be used for PRNG that does not affect gameplay/terrain generation.
    visual,
    /// Position-keyed hash for decorations that must stay consistent across chunk borders (such as hanging vines).
    decorations1,
    /// Position-keyed hash for decorations that must stay consistent across chunk borders (such as hanging vines).
    decorations2,
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
};

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
    /// Represents how many layers deep the player is. Automatically setup in startup.zig.
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

    /// Second seed based on the original `seed` value: derived from `ChaCha12` for use in `FastHash`.
    /// Derived from the base `seed` automatically, regardless of array length.
    seed2: [32]u64 align(16) = @splat(0),

    /// Returns a `hash2d()` seed vector for procedural generation.
    /// See `SeedType` definition for the possible categories and their purposes.
    pub inline fn getHashSeed(self: *const @This(), comptime category: SeedType) @Vector(2, u64) {
        const index_start: usize = @as(usize, @intFromEnum(category)) * 2;
        return self.seed2[index_start .. index_start + 2].*;
    }

    /// Gets the player's current chunk location as a `Coordinate`.
    pub inline fn getPlayerCoord(self: *const @This()) Coordinate {
        return .{ .quadrant = @intCast(self.player_quadrant), .suffix = self.player_chunk };
    }

    /// Gets which (X-coordinate) block the player is "on" within a chunk. Based on the player's center, rounded down.
    pub inline fn getBlockXInChunk(self: *const @This()) u4 {
        return @intCast(@divTrunc(self.player_pos[0], CHUNK_SIZE_SQ));
    }
    /// Gets which (Y-coordinate) block the player is "on" within a chunk. Based on the player's center, rounded down.
    pub inline fn getBlockYInChunk(self: *const @This()) u4 {
        return @intCast(@divTrunc(self.player_pos[1], CHUNK_SIZE_SQ));
    }

    /// Teleports the player, resetting the player position and camera position, as well as movement constants such as gravity.
    ///
    /// Also fully clears caches.
    pub inline fn teleport(self: *@This(), coord: ?Coordinate, new_position: Vec2i) void {
        player.subpixel_accum = .{ 0.0, 0.0 };
        self.player_velocity = .{ 0.0, 0.0 };
        if (coord) |c| {
            self.player_quadrant = c.quadrant;
            self.player_chunk = c.suffix;
        }
        self.player_pos = new_position;
        self.last_player_pos = new_position;
        // Snap BOTH current and previous camera to the destination (preventing interpolation funnies).
        self.camera_pos = new_position;
        self.last_camera_pos = new_position;
        world.clearCaches(false);
    }

    /// Sets the player position within a chunk, teleporting the previous position as well. Also clears subpixel accumulation/velocity.
    /// Considered dumb. Do not use for movement, as this neither does frame interpolation nor takes `Coordinate` input for correct quadrant changes.
    ///
    /// It is probably better to use `teleport()`, unless you need the player position to change but not the camera.
    /// This function also fails to handle caches properly.
    pub inline fn setPlayerPosDumb(self: *@This(), new_position: Vec2i) void {
        player.subpixel_accum = .{ 0.0, 0.0 };
        self.player_velocity = .{ 0.0, 0.0 };
        self.player_pos = new_position;
        self.last_player_pos = new_position;
    }

    /// Sets the camera position within a chunk, teleporting the previous position as well.
    /// Do not use for movement. Also clears subpixel accumulation.
    ///
    /// It is probably better to use `teleport()`, unless you need the camera position to change but not the player.
    /// This function also fails to handle caches properly.
    pub inline fn setCameraPosDumb(self: *@This(), new_position: Vec2i) void {
        player.subpixel_accum = .{ 0.0, 0.0 };
        self.camera_pos = new_position;
        self.last_camera_pos = new_position;
    }
};

/// The state of the current game, containing pre-allocated properties.
pub var game: GameState = .{};

/// System-level allocator for pages (or testing allocator when running tests).
/// On WASM, this grows the linear heap. On native, this requests pages from the OS.
/// Use as a backing for other allocators.
pub const page_allocator: std.mem.Allocator =
    if (builtin.is_test) std.testing.allocator else std.heap.page_allocator;

/// An instance of the general-purpose allocator (or testing allocator when running tests).
/// Use `makeArena()` to create an `ArenaAllocator` around this (WASM has no SMP allocator support).
pub const main_allocator: std.mem.Allocator =
    if (builtin.is_test) std.testing.allocator else if (builtin.single_threaded) std.heap.brk_allocator else std.heap.smp_allocator;

/// Creates an `ArenaAllocator` around the `page_allocator`.
/// It is usually preferable when possible to utilize the scratch buffer for temporary calculations through a callee,
/// store `len` from the caller, and re-access `scratch_ptr`.
///
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

/// Contains a `Sprite` id and various packed properties; ready to be sent to the GPU or stored in caches.
/// Field order keeps every field inside one aligned 32-bit word so the shader (`unpack_tile()` in src/shader.wgsl) extracts each with a single per-word `extractBits()`:
/// - word0: `id` | `edge_flags` | `light`
/// - word1: `hp` | `seed` (the shader reads the whole word as seed0, so `hp` is folded into the seed for free)
/// - word2: `base_id` | `id_edge_flags` | `lighting_color`
/// - word3: `waterlogged` | `_pad`
pub const Block = packed struct(u128) {
    /// A block with an `id` of `none`.
    pub const empty: Block = .makeBasicBlock(.none, 0);

    /// Maximum value for `hp`. `hp` is a `u4` (sharing word1's low bits with `seed`) and MUST stay 0-15:
    /// the atlas has exactly 16 HP masks and the water volume simulation assumes 0-15.
    pub const MAX_HP: u4 = 15;

    /// The primary sprite: the overlay/block itself (such as the ore rather than the block beneath).
    id: Sprite,
    /// Edge flags: explains details for neighbors (for both shader and procedural generation).
    /// Starts from top left, then middle left, and ending at bottom right (skipping itself).
    /// See `types/types.zig` for more details on correspondence.
    ///
    /// - A 1 bit for a solid block ordinarily indicates an edge with an adjacent solid block.
    /// - A 1 bit for a liquid block means that there is either solid or liquid adjacent.
    /// Edge flags must be reset to 255 for decorations (non-blocks or liquids) after a final decoration pass.
    edge_flags: u8,
    /// The brightness of the tile.
    light: u8,

    /// Dual-purpose field depending on block type (range 0-15, see `MAX_HP`):
    /// - For solid blocks: how "mined" the block is (0 means unmined, 15 is most mined).
    /// - For liquid (water) and decoration blocks: the water volume level from 0 to 15.
    hp: u4,
    /// Per-block seed for procedural variation in the shader.
    /// Any seed value here should be considered poor and insecure.
    seed: u28,

    /// The underlying background tile behind an overlay sprite (such as the stone an ore/gem grew inside).
    /// `.none` means "no underlay"; the shader then renders `id` alone (the common case for non-ore/gem blocks).
    base_id: Sprite = .none,
    /// Same-sprite edge flags (same bit order as `edge_flags`): a bit is set when the neighbor's `id` equals this block's `id`.
    /// Drives the ore overlay mask so a vein reads as connected only to itself.
    /// Follows the same 0xFF reset rule as `edge_flags` for decorations/air.
    id_edge_flags: u8 = 0,
    /// Type of color lighting should use.
    /// - 0: default white
    /// - 1: warm orange glow
    lighting_color: u8 = 0,

    /// Packed directional waterlogging field (bits 0-10 used; see `WaterloggedState` in zig/state/water.zig).
    /// - For liquid blocks: only bit 0 is read (liquid directly above).
    /// - For non-liquid blocks: encodes the surrounding water for the shader's surface fill and interpolation.
    ///   - bit 0: top (water of any depth directly above; fully submerges/fills the block)
    ///   - bit 1: bottom (full liquid block directly below at HP=15)
    ///   - bit 2: top ripple cutoff (adjacent water surface is exposed to air)
    ///   - bits 3-6: left adjacent liquid volume (0-15; 0 means no liquid to the left)
    ///   - bits 7-10: right adjacent liquid volume (0-15; 0 means no liquid to the right)
    waterlogged: u12 = 0,
    /// Unused portion of block data.
    _pad: u20 = 0,

    /// Makes a simple block of a certain type, with max light and no edge flags and mine level.
    /// Uses the BOTTOM 32 bits from `seed_bits` to place into `seed`.
    pub inline fn makeBasicBlock(sprite_type: Sprite, seed_bits: u64) Block {
        return .{
            .id = sprite_type,
            .hp = if (sprite_type.isLiquid()) MAX_HP else 0,
            .edge_flags = 0,
            .light = 255,
            .seed = @truncate(seed_bits),
            .waterlogged = 0,
        };
    }

    /// Determines if the sprite's type is one that should interact with the edge flags and procedural generation.
    /// This returns false for edge stone, unlike `isSolid()`. Assumes invalid block types are impossible.
    pub inline fn isFoundation(self: @This()) bool {
        return self.id.isFoundation();
    }

    /// Determines if the sprite's type is a valid block that could exist in any chunk.
    /// Separate from `isItem()`. Includes the empty block, and excludes entities.
    ///
    /// If properties are wrong here, invalid (or unnamed) enums may appear and wreak havoc.
    pub inline fn isInWorld(self: @This()) bool {
        return self.id.isInWorld();
    }

    /// Determines if the block's type is considered solid, and should interact with the physics, player, and edge flags.
    /// This returns true for edge stone, unlike `isSolid()`.
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

    /// Extracts the evolved form of this block at compile-time.
    /// If it doesn't evolve, returns the original sprite type!
    pub inline fn evolvesTo(self: @This()) Sprite {
        return self.id.evolvesTo();
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
    /// Starting water volume (0-15) for a waterloggable cell generated inside a pool.
    /// Ignored for liquids (`makeBasicBlock()` already fills them to `MAX_HP`) and meaningless for solids,
    /// whose `hp` is mining progress and always generates at 0.
    /// A waterloggable cell generated dry inside full water is NOT at equilibrium: the sim floods it on the
    /// first tick, which dirties the chunk and creates a modification entry with no player involvement.
    water_volume: u4 = 0,

    /// Compiles the spec into a packed `Block` (max light, no edge flags or mine level, matching `makeBasicBlock()`).
    pub inline fn compile(self: @This()) Block {
        var block: Block = .makeBasicBlock(self.id, self.seed);
        block.base_id = self.base_id;
        if (!self.id.isLiquid() and self.id.isWaterloggable()) block.hp = self.water_volume;
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

    /// Type of coordinates to use. Defaults to `position` representing top left and with UV-based coordinates.
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

/// A dynamically expandable scratch buffer for fast one-time passing through of data like strings or temporary particle data.
/// Assumes fully single-thread communication. A separate, smaller logging_buffer is used in logger.zig.
///
/// Information in the scratch buffer should be assumed to be corrupted as soon as any other function that could modify the scratch buffer is called and thought of as a temporary "handshake" between Zig and TypeScript.
pub var scratch_buffer: []align(MAIN_ALIGN_BYTES) u8 = &[_]u8{};
var is_dynamic_scratch: bool = false;

/// The layout structure shared with TypeScript. The MemoryLayout instance will not change locations, but its properties may.
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
    /// Information in the scratch properties should be assumed to be corrupted as soon as any other function that could modify the scratch buffer is called.
    /// This array should be thought of as a temporary "handshake" to trade information between Zig and TypeScript. Consider utilizing function arguments instead when sending data to Zig.
    scratch_properties: [20]u64,
};

/// Global static instance of the layout so the pointer remains valid for JS. Starts near the start of a WASM page.
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
/// Entities are written back-to-back with no padding so that JS can read them as a flat `entity_count * 48` block.
/// The scratch base is 64-aligned and 48 is a multiple of 16, so every entity stays 16-byte aligned (matching `WGSLEntity`'s alignment)
/// without any per-call alignment bookkeeping.
///
/// Precondition: called from an aligned start (such as right after `scratchReset()`), as the tight packing relies on the
/// running `scratch_len` being a multiple of `@sizeOf(WGSLEntity)`.
pub inline fn scratchPushEntity() *WGSLEntity {
    const off: usize = @intCast(mem.scratch_len);
    // Ensures capacity (and grows/relocates the buffer if needed); its aligned bump is overwritten below.
    _ = scratchAlloc(@sizeOf(WGSLEntity));
    mem.scratch_len = off + @sizeOf(WGSLEntity);
    // Derive the pointer from `scratch_buffer.ptr` AFTER the potential grow so it can never be stale.
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

/// Resets the scratch offset for the next frame/operation. (JS doesn't call this and instead uses handy functions in engine.ts.)
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
