//! Manages memory for WASM.
const std = @import("std");
const builtin = @import("builtin");
const logger = @import("logging.zig");
const ColorRGBA = @import("color_rgba.zig").ColorRGBA;
pub const is_wasm = builtin.target.cpu.arch == .wasm32 or builtin.target.cpu.arch == .wasm64;

// Only create an actual GPA instance if building for native.
var gpa = if (!is_wasm and !builtin.is_test)
    std.heap.GeneralPurposeAllocator(.{}){}
else
    struct {}{};

pub const allocator = if (is_wasm)
    std.heap.wasm_allocator
else if (builtin.is_test)
    std.testing.allocator
else
    gpa.allocator();

/// 64 bytes is a good alignment size.
pub const MAIN_ALIGN_BYTES: usize = 64;
/// 64 bytes for WebGPU alignment.
pub const GPU_ALIGN_BYTES: usize = 64;
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

/// Tightly packed data for a block to be sent to WebGPU.
const BlockInstance = extern struct {
    /// Position in screen-space pixels (after camera transform)
    location: @Vector(2, f32),
    /// Which sprite to use (index into texture atlas)
    sprite_id: u16,
    /// Edge flags: which neighbors are air (for edge darkening shader).
    /// Starts from top left, then middle left, and ending at bottom right (skipping itself).
    edge_flags: u8,
    /// Light level (0-255, shader interpretation TODO)
    light: u8,
    /// Per-block seed for procedural variation in shader. Separate from seeding when zooming in/time-based changes in lighting or shaders.
    variation_seed: u32,

    /// Returns x-coordinate of a block's location.
    pub inline fn x(self: anytype) f32 {
        return self.location[0];
    }
    /// Returns x-coordinate of a block's location.
    pub inline fn y(self: anytype) f32 {
        return self.location[1];
    }
};

/// Tightly packed data for a square particle to be sent to WebGPU.
const Particle = extern struct {
    position: @Vector(2, f32),
    d_position: @Vector(2, f32),
    color: ColorRGBA,
    size: f32,
    rotation: f32,
    d_rotation: f32,
};

// var particle_buffer: [MAX_PARTICLES]Memory.Particle = undefined;
// var particle_count: u32 = 0;

/// A dynamically expandable scratch buffer for fast one-time passing through of data like strings or temporary particle data. Assumes fully single-thread communication. A separate, smaller logging_buffer is used in memory.zig.
/// The initial, static scratch buffer. Guarantees zero-allocation startup and perfect SIMD alignment.
var default_scratch_buffer: [256 * MemorySizes.KiB]u8 align(MAIN_ALIGN_BYTES) = undefined;

pub var scratch_buffer: []align(MAIN_ALIGN_BYTES) u8 = &default_scratch_buffer;
var is_dynamic_scratch: bool = false;

/// Data is reserved for numbers or positions that are guaranteed to take a constant amount of memory, or pointers.
/// Important data is meant to be placed at the start with less important data later. See game_state_offsets in types.zig for export to JS.
pub const GameState = extern struct {
    /// Represents the player's position.
    player_pos: @Vector(2, f64) align(MAIN_ALIGN_BYTES) = .{ 0.0, 0.0 },
    /// Represents the camera's position.
    camera_pos: @Vector(2, f64) = .{ 0.0, 0.0 },
    /// Represents the camera's zoom scale.
    camera_scale: f64 = 1.0,
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
    seed: [8]u64 align(16) = std.mem.zeroes([8]u64),
};

/// The state of the current game.
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
    mem_ptr: *GameState,
    /// Additional properties for configuring the scratch buffer's meaning (with types.zig and commands.zig) if necessary.
    scratch_properties: [4]u64,
};

/// Global static instance of the layout so the pointer remains valid for JS. Starts near the start of a WASM page.
pub var mem: MemoryLayout align(MAIN_ALIGN_BYTES) = .{
    .scratch_ptr = 0, // pointer is set in main.zig's init
    .scratch_len = 0,
    .scratch_capacity = 0,
    .mem_ptr = &game,
    .scratch_properties = std.mem.zeroes([4]u64), // start with empty
};

/// Returns the pointer to the memory layout for TypeScript to consume.
pub fn get_memory_layout_ptr() *align(MAIN_ALIGN_BYTES) const MemoryLayout {
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
pub fn scratch_alloc(len: usize) ?[*]u8 {
    const base_addr = @intFromPtr(scratch_buffer.ptr);
    const current_addr = base_addr + @as(usize, @intCast(mem.scratch_len));
    const aligned_addr = std.mem.alignForward(usize, current_addr, MAIN_ALIGN_BYTES);
    const new_scratch_len = (aligned_addr - base_addr) + len;

    // Fast path: fits in the current contiguous buffer.
    if (new_scratch_len <= scratch_buffer.len) {
        @branchHint(.likely);
        mem.scratch_len = @intCast(new_scratch_len);
        return @ptrFromInt(aligned_addr);
    }

    // Expansion: memory and pointers will move, and capacity will increase.
    // Expand an extra 50% of current length, up to +32MiB (or new scratch length, whichever is higher).
    const growth_1_5 = scratch_buffer.len + (scratch_buffer.len / 2);
    const clamped_growth = @min(growth_1_5, scratch_buffer.len + (32 * MemorySizes.MiB));
    const new_cap = @max(clamped_growth, new_scratch_len);
    const scratch_length_usize: usize = @intCast(mem.scratch_len);

    if (!is_dynamic_scratch) {
        // Transition from static array to heap. This technically requires memory to grow twice because it's not an in-place copy.
        const new_slice = allocator.alignedAlloc(u8, MAIN_ALIGN, new_cap) catch return null;
        @memcpy(new_slice[0..scratch_length_usize], scratch_buffer[0..scratch_length_usize]);
        scratch_buffer = new_slice;
        is_dynamic_scratch = true;
    } else {
        // Use realloc to allow the allocator to grow in-place if possible (this also keeps alignment).
        scratch_buffer = allocator.realloc(scratch_buffer, new_cap) catch return null;
    }

    // Update JS state
    mem.scratch_ptr = @intFromPtr(scratch_buffer.ptr);
    mem.scratch_capacity = scratch_buffer.len;

    // Recalculate based on potentially new base pointer
    const updated_base = @intFromPtr(scratch_buffer.ptr);
    const updated_aligned = std.mem.alignForward(usize, updated_base + scratch_length_usize, MAIN_ALIGN_BYTES);
    mem.scratch_len = @intCast((updated_aligned - updated_base) + len);

    return @ptrFromInt(updated_aligned);
}

/// Runs a set of tests (which should be called from JS) for the scratch allocation. (See root.zig for export logic.)
pub fn run_scratch_allocation_tests() void {
    scratch_reset();

    const initial_capacity = scratch_buffer.len;

    // Allocate initial chunk and track its offset (we use offsets because pointers dangle on expansion!)
    _ = scratch_alloc(100) orelse @panic("Alloc 1 failed");
    const offset1 = 0;
    @memset(scratch_buffer[offset1..100], 0xAA); // first allocation memory value

    // Request the exact fit necessary
    const current_len: usize = @intCast(mem.scratch_len);
    const current_addr = @intFromPtr(scratch_buffer.ptr) + current_len;
    const aligned_addr = std.mem.alignForward(usize, current_addr, MAIN_ALIGN_BYTES);
    const padding = aligned_addr - current_addr;
    const remaining = initial_capacity - current_len - padding;

    _ = scratch_alloc(remaining) orelse @panic("Alloc 2 failed");
    const offset2 = current_len + padding;
    @memset(scratch_buffer[offset2 .. offset2 + remaining], 0xBB); // second allocation memory value

    // Verify it did not prematurely expand
    if (scratch_buffer.len != initial_capacity) {
        @panic("Buffer expanded prematurely");
    }

    // Force expansion
    const ptr3 = scratch_alloc(64) orelse @panic("Alloc 3 (expansion) failed");
    @memset(ptr3[0..64], 0xCC); // third allocation memory value

    if (scratch_buffer.len <= initial_capacity) {
        @panic("Buffer did not expand when exceeding capacity");
    }

    if (mem.scratch_ptr != @intFromPtr(scratch_buffer.ptr)) {
        @panic("JS memory pointer was not successfully updated");
    }

    for (scratch_buffer[offset1..100]) |val| {
        if (val != 0xAA) @panic("Slice 1 value corrupted after expansion");
    }
    for (scratch_buffer[offset2 .. offset2 + remaining]) |val| {
        if (val != 0xBB) @panic("Slice 2 value corrupted after expansion");
    }
    for (ptr3[0..64]) |val| {
        if (val != 0xCC) @panic("Slice 3 value corrupted");
    }

    // Cleanup so state is cleanly reset for the next frame
    scratch_reset();
    if (mem.scratch_len != 0) @panic("Scratch buffer's reported data length was not reset");
    logger.log(@src(), "Scratch allocation tests passed! Capacity of scratch_buffer grew from {d} to {d} bytes.", .{ initial_capacity, scratch_buffer.len });
}

/// Allocates space in scratch buffer and copies the provided data into it if necessary.
pub inline fn scratch_copy(data: []const u8) ?[*]u8 {
    const ptr = scratch_alloc(data.len) orelse return null;
    @memcpy(ptr[0..data.len], data);
    return ptr;
}

/// Resets the scratch offset for the next frame/operation. (JS doesn't call this and instead uses handy functions in engine.ts.)
pub inline fn scratch_reset() void {
    mem.scratch_len = 0;
}

const _ = {
    if (MAIN_ALIGN_BYTES < 16 || (MAIN_ALIGN_BYTES % 16 > 0)) {
        @compileError("MAIN_ALIGN_BYTES should be a positive multiple of 16 for SIMD alignment.");
    }
    if (GPU_ALIGN_BYTES < 64 || (GPU_ALIGN_BYTES % 64 > 0)) {
        @compileError("GPU_ALIGN_BYTES should be a positive multiple of 64 for WebGPU alignment.");
    }
};
