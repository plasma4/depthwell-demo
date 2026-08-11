//! Bakes sprite-layout constants into `src/shader.wgsl` at build time.
//!
//! Values are written as plain WGSL `const`s so they are part of the one shader source
//! (which survives minification as a nice bonus).
//!
//! Run automatically by `zig build` (see `generateShaderConstants` in build.zig),
//! guarded by a content hash of the files these values derive from so the host tool is not rebuilt on unrelated changes.
const std = @import("std");

/// Points to definitions from zig/root.zig.
pub const dw = @import("root.zig");

const Sprite = dw.Sprite;
const sprite = dw.sprite;
const Block = dw.memory.Block;

const SHADER_PATH = "src/shader.wgsl";
const START_MARKER = "// #CONSTANT REGION START, DO NOT MODIFY CONTENTS MANUALLY#";
const END_MARKER = "// #CONSTANT REGION END#";

/// One `memory.Block` field that `unpack_tile()` or `tile_light()` pulls out of the tile buffer.
///
/// The shader reads a field with one `extractBits()` on one 32-bit word,
/// so a field listed here must sit entirely inside `word`.
const BlockField = struct {
    /// WGSL constant name; `_OFF` and `_LEN` are appended to it.
    name: []const u8,
    /// Field name in `memory.Block`.
    field: []const u8,
    /// Word of `Block` the shader reads this field out of. See the `Block` doc comment.
    word: usize,
};

/// Every `Block` field the shader unpacks. `Block.seed` is absent on purpose:
/// the shader reads the whole of word1 as the seed, and `hp` folds into it.
const BLOCK_FIELDS = [_]BlockField{
    .{ .name = "BLOCK_ID", .field = "id", .word = 0 },
    .{ .name = "BLOCK_EDGE_FLAGS", .field = "edge_flags", .word = 0 },
    .{ .name = "BLOCK_LIGHT_L", .field = "light_l", .word = 0 },
    .{ .name = "BLOCK_HP", .field = "hp", .word = 1 },
    .{ .name = "BLOCK_BASE_ID", .field = "base_id", .word = 2 },
    .{ .name = "BLOCK_ID_EDGE_FLAGS", .field = "id_edge_flags", .word = 2 },
    .{ .name = "BLOCK_LIGHT_C", .field = "light_c", .word = 2 },
    .{ .name = "BLOCK_WATER", .field = "water", .word = 3 },
    .{ .name = "BLOCK_LIGHT_H", .field = "light_h", .word = 3 },
};

/// Bit offset of `f` inside its own word, and the width of the field.
fn blockFieldBits(comptime f: BlockField) struct { off: usize, len: usize } {
    const off = @bitOffsetOf(Block, f.field);
    const len = @bitSizeOf(@FieldType(Block, f.field));
    comptime {
        if (off / 32 != f.word or (off + len - 1) / 32 != f.word) @compileError(
            "Block." ++ f.field ++ " no longer fits inside word" ++
                std.fmt.comptimePrint("{d}", .{f.word}) ++
                "; the shader cannot read it with one extractBits().",
        );
    }
    return .{ .off = off % 32, .len = len };
}

pub fn main(init: std.process.Init) !void {
    var buffer: [512 * 1024]u8 = undefined;
    var alloc: std.heap.FixedBufferAllocator = .init(&buffer);
    const allocator = alloc.allocator();

    const cwd = std.Io.Dir.cwd();
    const src = try cwd.readFileAlloc(init.io, SHADER_PATH, allocator, .unlimited);

    const start = std.mem.indexOf(u8, src, START_MARKER) orelse return error.MissingStartMarker;
    const end = std.mem.indexOf(u8, src, END_MARKER) orelse return error.MissingEndMarker;
    if (end < start) return error.MarkersOutOfOrder;

    var bw = std.Io.Writer.Allocating.init(allocator);
    defer bw.deinit();
    const writer = &bw.writer;

    // Keep everything through the start-marker text, regenerate the body, then resume at the end marker.
    // TILES_PER_ROW/COLUMN stay f32 (used in float math below in the shader); the *_START are u32.
    try writer.writeAll(src[0 .. start + START_MARKER.len]);
    try writer.print(
        \\
        \\// Auto-generated from zig/types/sprite.zig by zig/update_shader.zig (runs during `zig build`).
        \\// Do NOT edit values between the markers by hand; edit the Sprite enum instead.
        \\const TILES_PER_ROW: f32 = {d}.0;
        \\const TILES_PER_COLUMN: f32 = {d}.0;
        \\const STONE_START: u32 = {d}u;
        \\const ORE_START: u32 = {d}u;
        \\const GEM_START: u32 = {d}u;
        \\const GEM_MASK_START: u32 = {d}u;
        \\const WATER_START: u32 = {d}u;
        \\
        \\// OKLAB chroma a fully saturated light source adds at full lightness.
        \\const LIGHT_CHROMA_MAX: f32 = {d};
        \\// Steps a full hue turn is divided into. Hue WRAPS, so the last step is one step before the first.
        \\const LIGHT_HUE_STEPS: f32 = {d}.0;
        \\// Largest value of a packed light channel.
        \\const LIGHT_CHANNEL_MAX: f32 = {d}.0;
        \\
        \\// Bit layout of memory.Block, taken from the struct itself.
        \\// Each offset is relative to the 32-bit word the field lives in, which the generator checks.
        \\
    , .{
        dw.getTilesPerRow(),
        dw.getTilesPerColumn(),
        sprite.STONE_START,
        sprite.ORE_START,
        sprite.GEM_START,
        sprite.MASK_START,
        @intFromEnum(Sprite.water),
        dw.lighting.LIGHT_CHROMA_MAX,
        dw.lighting.HUE_STEPS,
        dw.memory.LIGHT_MAX,
    });

    inline for (BLOCK_FIELDS) |f| {
        const bits = comptime blockFieldBits(f);
        try writer.print("const {s}_OFF: u32 = {d}u;\nconst {s}_LEN: u32 = {d}u;\n", .{
            f.name,
            bits.off,
            f.name,
            bits.len,
        });
    }
    try writer.writeAll(src[end..]);

    // Only touch the file when the content actually changes, so the dev file-watcher does not churn.
    const new_content = bw.written();
    if (!std.mem.eql(u8, new_content, src)) {
        try cwd.writeFile(init.io, .{ .sub_path = SHADER_PATH, .data = new_content });
    }

    // Update the content-hash cache so build.zig can skip rebuilding this tool next time!
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 4) return;
    const cache_root = args[1];
    const cache_path = args[2];
    const current_hash_hex = args[3];
    cwd.createDirPath(init.io, cache_root) catch {};
    cwd.writeFile(init.io, .{ .sub_path = cache_path, .data = current_hash_hex }) catch {};
}
