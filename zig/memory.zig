//! Contains main data-types that bridge WASM and Zig, as well as scratch buffer logic. Also contains some structs and commonly used constants.
const std = @import("std");
const builtin = @import("builtin");
const logger = @import("logger.zig");
const ColorRGBA = @import("color_rgba.zig").ColorRGBA;
const seeding = @import("seeding.zig");
const world = @import("world.zig");
pub const is_wasm = builtin.target.cpu.arch == .wasm32 or builtin.target.cpu.arch == .wasm64;

/// Represents log2(SPAN).
pub const SPAN_LOG2: comptime_int = 4;
/// The main number (as an integer) representing the number of blocks in a chunk, number of pixels in a block, and number of subpixels in a pixel.
pub const SPAN: comptime_int = 16;
/// The main number (as a float) representing the number of blocks in a chunk, number of pixels in a block, and number of subpixels in a pixel.
pub const SPAN_FLOAT: comptime_float = 16.0;
/// An integer representing the number of subpixels in a block, pixels in a chunk, number of blocks in a chunk, number of pixels in a block, and number of possible subpixel positions within a pixel.
pub const SPAN_SQ: comptime_int = SPAN * SPAN;
/// A float representing the number of subpixels in a block, pixels in a chunk, number of blocks in a chunk, number of pixels in a block, and number of possible subpixel positions within a pixel.
pub const SPAN_FLOAT_SQ: comptime_float = SPAN_FLOAT * SPAN_FLOAT;
/// An integer representing the number of subpixels within a chunk. The player's X and Y coordinate should wrap around such that it is between 0 and this value (inclusive).
pub const SUBPIXELS_IN_CHUNK: comptime_int = SPAN * SPAN * SPAN;

pub const v2i64 = @Vector(2, i64);
pub const v2u64 = @Vector(2, u64);
pub const v2f64 = @Vector(2, f64);

// Only create an actual GPA instance if building for native.
var gpa = if (!is_wasm and !builtin.is_test)
    std.heap.GeneralPurposeAllocator(.{}){}
else
    struct {};

pub const allocator = if (is_wasm)
    std.heap.wasm_allocator
else if (builtin.is_test)
    std.testing.allocator
else
    gpa.allocator();

/// Start the scratch buffer with 256 KiB when allocating for the first time.
const STARTING_SCRATCH_BUFFER_SIZE = 256 * MemorySizes.KiB;

/// 64 bytes is ana all-round good alignment size.
pub const MAIN_ALIGN_BYTES: usize = 64;
/// Type-safe alignment for use with `std.mem.Allocator` functions.
/// Derived from `MAIN_ALIGN_BYTES`.
pub const MAIN_ALIGN = std.mem.Alignment.fromByteUnits(MAIN_ALIGN_BYTES);
/// Type-safe alignment for use with `std.mem.Allocator` functions.
/// Derived from `MAIN_ALIGN_BYTES`.
pub const GPU_ALIGN = std.mem.Alignment.fromByteUnits(MAIN_ALIGN_BYTES);

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

/// A single block within a chunk.
pub const Block = packed struct {
    /// Internal sprite ID.
    id: world.Sprite,
    /// The brightness of the tile.
    light: u8,
    /// How "mined" the block is. 0 is least mined, 15 is most mined.
    hp: u4,

    /// Per-block seed for procedural variation in the shader.
    seed: u24,
    /// Edge flags: which neighbors are air (for edge-darkening and culling).
    /// Starts from top left, then middle left, and ending at bottom right (skipping itself).
    flags: u8,
};

/// 16x16 fixed grid of blocks.
pub const Chunk = struct {
    blocks: [SPAN_SQ]Block,
    // /// 256 bits representing which blocks have been modified from the base procedural generation.
    // modified_mask: [4]u64,

    pub inline fn getIndex(x: u4, y: u4) u8 {
        return (@as(u8, y) << 4) | @as(u8, x);
    }
};

/// Represents a "coordinate", relative to a quad-cache. Stores an "active suffix" as well as the quadrant this coordinate belongs to.
pub const Coordinate = packed struct {
    // Active suffix (stored as a vector). You can think of the active suffix like 16 u4s packed together for the X and Y coordinate that can be merged with the correct QuadCache quadrant to produce a "complete" path (see README.md for more details).
    suffix: v2u64,
    /// Quadrant ID (00: NW, 1: NE, 2: SW, 3: SE).
    quadrant: u2,
    /// TODO determine if we actually want funny 3D stuff to happen (256 possible subpixel states and 256 possible important states, maybe)
    influence: u16 = 0,
};

/// Dense storage for a modified chunk.
pub const ModifiedChunk = struct {
    /// 256 bits representing which blocks have been modified.
    /// Bit index corresponds to (y * 16 + x).
    modified_mask: [4]u64,
    /// The specific modified block IDs. Only indices with a 1 in `modified_mask` are valid.
    blocks: [SPAN_SQ]world.Sprite,

    /// Helper to check if a specific local block is modified
    pub inline fn is_modified(self: *const @This(), lx: u4, ly: u4) bool {
        const index = (@as(u8, ly) << 4) | @as(u8, lx);
        const slot = index >> 6;
        const bit = @as(u6, @truncate(index));
        return (self.modified_mask[slot] & (@as(u64, 1) << bit)) != 0;
    }
};

/// Tightly packed data for a square particle to be sent to WebGPU.
const Particle = packed struct {
    /// Current position.
    position: @Vector(2, f32),

    /// Velocity vector for position.
    d_position: @Vector(2, f32),

    /// The color of the particle (alpha is multiplied by time and how long the particle lasts)
    color: ColorRGBA,
    /// The size of the particle
    size: u24,
    /// The opacity of the particle (based on time start/end)
    opacity: u8,

    /// The rotation of the particle (radians)
    rotation: f32,
    /// The rate of change of rotation of the particle (radians)
    d_rotation: f32,

    /// The time at which the particle spawned in from (performance.now()).
    time_start: f64,

    /// The time at which the particle will disappear.
    time_end: f64,
};

/// A dynamically expandable scratch buffer for fast one-time passing through of data like strings or temporary particle data. Assumes fully single-thread communication. A separate, smaller logging_buffer is used in logger.zig.
/// Information in the scratch buffer should be assumed to be corrupted as soon as any other function that could modify the scratch buffer is called and thought of as a temporary "handshake" between Zig and TypeScript.
pub var scratch_buffer: []align(MAIN_ALIGN_BYTES) u8 = &[_]u8{};
var is_dynamic_scratch: bool = false;

/// Non-pointer data (short known length) representing part of the game state.
/// Data is reserved for numbers or positions that are guaranteed to take a constant amount of memory, or pointers.
/// Important data is meant to be placed at the start with less important data later. Data can be rearranged, but requires using the --Dgen-enums for pointer locations to be reflected in TypeScript. See game_state_offsets in types.zig for enum export details.
pub const GameState = extern struct {
    /// Represents the player's subpixel position within the CURRENT chunk (0 to 4095).
    player_pos: v2i64 align(MAIN_ALIGN_BYTES) = .{ 256, 256 },
    /// Represents the player's position. Importantly, this is not necessarily equal to the player's velocity, as this handles teleports!
    last_player_pos: v2i64 = .{ 256, 256 },
    /// Represents the player's active chunk coordinate.
    player_chunk: v2u64 = .{ 0, 0 },
    /// Represents the player's current movement.
    player_velocity: v2f64 = .{ 0, 0 },
    /// Represents the camera's position.
    camera_pos: v2i64 = .{ 256, 256 },
    /// Represents the camera's movement in a frame (derivative of camera_pos).
    last_camera_pos: v2i64 = .{ 256, 256 },
    /// Represents the camera's zoom scale.
    camera_scale: f64 = 1.0,
    /// Represents the camera's zoom scale change rate (multiplier, acts as derivative of camera_scale change).
    camera_scale_change: f64 = 1.0,
    /// Represents how many layers deep the player is (defaults to 3).
    depth: u64 = 0,

    /// Represents which quadrant (0-3) of the QuadCache the player is in (starts at 0 when depth is <= 16).
    player_quadrant: u32 = 0,

    /// Represents where the player should be rendered for WGSL.
    player_screen_offset: @Vector(2, f32) = .{ 0, 0 },

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
    /// const logger = @import("logger.zig");
    /// const memory = @import("memory.zig");
    /// const KeyBits = @import("types.zig").KeyBits;
    /// logger.log(@src(), "{}", .{KeyBits.isSet(KeyBits.up, memory.game.keys_pressed_mask)}); // Gets if UP key was pressed this frame.
    /// ```
    keys_pressed_mask: u32 = 0,
    /// Represents the keys that are currently HELD DOWN.
    ///
    /// Example:
    /// ```zig
    /// const logger = @import("logger.zig");
    /// const memory = @import("memory.zig");
    /// const KeyBits = @import("types.zig").KeyBits;
    /// logger.log(@src(), "{}", .{KeyBits.isSet(KeyBits.up, memory.game.keys_held_mask)}); // Gets if UP key is being held down.
    /// ```
    keys_held_mask: u32 = 0,

    /// The initial or "global" seed from which all generation starts.
    seed: seeding.Seed align(16) = std.mem.zeroes(seeding.Seed),
};

/// The state of the current game, containing pre-allocated properties.
pub var game: GameState = .{};

/// The layout structure shared with TypeScript. The MemoryLayout instance will not change locations, but its properties may.
pub const MemoryLayout = extern struct {
    /// Pointer to the scratch buffer.
    scratch_ptr: u64 align(MAIN_ALIGN_BYTES),
    /// The current length or offset used within the scratch buffer.
    scratch_len: u64,
    /// The total capacity of the fixed scratch buffer (4MB).
    scratch_capacity: u64,
    /// Pointer to the GameState. (Can safely be pointer instead of u64 as it is the LAST property.)
    game_ptr: u64,
    /// Additional properties for sending additional (pointer or short fixed-length) properties. Information in the scratch properties should be assumed to be corrupted as soon as any other function that could modify the scratch buffer is called and thought of as a temporary "handshake" between Zig and TypeScript.
    scratch_properties: [20]u64,
};

/// Global static instance of the layout so the pointer remains valid for JS. Starts near the start of a WASM page.
pub var mem: MemoryLayout align(MAIN_ALIGN_BYTES) = .{
    .scratch_ptr = 0, // pointer is set in main.zig's init
    .scratch_len = 0,
    .scratch_capacity = 0,
    .game_ptr = 0,
    .scratch_properties = std.mem.zeroes([20]u64), // start with empty
};

/// Returns the pointer to the memory layout for TypeScript to consume.
pub fn get_memory_layout_ptr() *align(MAIN_ALIGN_BYTES) const MemoryLayout {
    mem.scratch_ptr = @intFromPtr(&scratch_buffer);
    mem.game_ptr = @intFromPtr(&game);
    return &mem;
}

/// Allocates memory in WASM that JS can write to.
pub fn wasm_alloc(len: usize) ?[*]u8 {
    const slice = allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

/// Frees memory allocated via wasm_alloc.
pub fn wasm_free(ptr: [*]u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

/// Determines if scratch_buffer has at least len capacity. If not, expands with the system allocator. Does NOT set the length property; only allocates sufficiently.
/// TODO scratch_free_and_alloc function(?)
pub fn scratch_alloc(len: usize) ?[*]u8 {
    const base_addr = @intFromPtr(scratch_buffer.ptr);
    const current_addr = base_addr + @as(usize, @intCast(mem.scratch_len));
    const aligned_addr = std.mem.alignForward(usize, current_addr, MAIN_ALIGN_BYTES);
    const new_scratch_len = (aligned_addr - base_addr) + len;

    if (!is_dynamic_scratch or new_scratch_len > scratch_buffer.len) {
        @branchHint(.cold);
        const growth_150_percent = scratch_buffer.len + (scratch_buffer.len >> 1);
        const clamped_growth = @min(growth_150_percent, scratch_buffer.len + (32 * MemorySizes.MiB));

        // Final capacity: (256KiB, 1.5x growth, the requested length), whichever is greater.
        const new_cap = @max(@max(STARTING_SCRATCH_BUFFER_SIZE, clamped_growth), new_scratch_len);
        const current_used: usize = @intCast(mem.scratch_len);

        if (!is_dynamic_scratch) {
            scratch_buffer = allocator.alignedAlloc(u8, MAIN_ALIGN, new_cap) catch return null;
            is_dynamic_scratch = true;
        } else {
            scratch_buffer = allocator.realloc(scratch_buffer, new_cap) catch return null;
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

    // Fits in existing buffer already, fast!
    mem.scratch_len = @intCast(new_scratch_len);
    return @ptrFromInt(aligned_addr);
}

/// Allocates a typed slice in the scratch buffer.
/// This is the ideal way to write structural data (like `Particle`) directly into the buffer.
pub fn scratch_alloc_slice(comptime T: type, count: usize) ?[]T {
    const byte_count = count * @sizeOf(T);
    const ptr = scratch_alloc(byte_count) orelse return null;
    return @as([*]T, @ptrCast(@alignCast(ptr)))[0..count];
}

/// Views the entirely used portion of the scratch buffer as a single typed slice.
/// Note: This will panic if `mem.scratch_len` is not an exact multiple of `@sizeOf(T)`.
/// Only use this if the entire frame's scratch buffer contains a single data type.
pub fn scratch_as_slice(comptime T: type) []T {
    const bytes = scratch_buffer[0..mem.scratch_len];
    return std.mem.bytesAsSlice(T, bytes);
}

/// Runs a set of tests (which should be called from JS) for the scratch allocation. (See root.zig for export logic.)
pub fn run_scratch_allocation_tests() void {
    scratch_reset();

    // Force 0-to-256KiB scratch allocation.
    const len1 = 100;
    _ = scratch_alloc(len1) orelse @panic("Bootstrap allocation failed");

    const heap_cap = scratch_buffer.len;
    const current_used = std.mem.alignForward(usize, @intCast(mem.scratch_len), MAIN_ALIGN_BYTES);
    if (STARTING_SCRATCH_BUFFER_SIZE < len1 or scratch_buffer.len != STARTING_SCRATCH_BUFFER_SIZE) @panic("Scratch buffer length does not match starting buffer size");

    if (heap_cap <= current_used) @panic("Bootstrap failed to provide excess capacity");
    const rem = heap_cap - current_used;

    // Fill to the exact amount of capacity
    _ = scratch_alloc(rem) orelse @panic("Fill allocation failed");
    if (scratch_buffer.len != heap_cap) @panic("Buffer expanded before reaching capacity");
    logger.log(@src(), "Requested {d} bytes successfully without buffer expansion.", .{rem});

    // force expansion and reallocate
    const len_exp = 64;
    _ = scratch_alloc(len_exp) orelse @panic("Expansion allocation failed");

    if (scratch_buffer.len <= heap_cap) @panic("Buffer failed to grow after exceeding capacity");
    if (mem.scratch_ptr != @intFromPtr(scratch_buffer.ptr)) @panic("JS pointer desync");

    scratch_reset();
    logger.log(@src(), "Scratch tests passed! Final capacity: {d} bytes.", .{scratch_buffer.len});
}

/// Resets the scratch offset for the next frame/operation. (JS doesn't call this and instead uses handy functions in engine.ts.)
pub inline fn scratch_reset() void {
    mem.scratch_len = 0;
}

/// Sets a scratch property (uses generic compile-time inferences).
pub inline fn set_scratch_prop(index: usize, value: anytype) void {
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
pub inline fn get_scratch_prop(index: usize) u64 {
    return mem.scratch_properties[index];
}

/// Gets a scratch property as i64.
pub inline fn get_scratch_prop_signed(index: usize) i64 {
    return @bitCast(mem.scratch_properties[index]);
}

/// Gets a scratch property as f64.
pub inline fn get_scratch_prop_float(index: usize) f64 {
    return @bitCast(mem.scratch_properties[index]);
}

const _ = {
    if (STARTING_SCRATCH_BUFFER_SIZE <= 0 || (STARTING_SCRATCH_BUFFER_SIZE % @alignOf(@TypeOf(scratch_buffer)) != 0)) {
        @compileError("Buffer size must be a positive multiple of its alignment.");
    }
    if (MAIN_ALIGN_BYTES < 16 || (MAIN_ALIGN_BYTES % 16 > 0)) {
        @compileError("MAIN_ALIGN_BYTES should be a positive multiple of 16 for SIMD alignment.");
    }
    if (@sizeOf(Block) != 8) {
        @compileError("Memory size for each block should be 8 bytes.");
    }
};
