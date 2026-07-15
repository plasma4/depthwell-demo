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

const SHADER_PATH = "src/shader.wgsl";
const START_MARKER = "// #CONSTANT REGION, DO NOT MODIFY MANUALLY#";
const END_MARKER = "// #CONSTANT REGION END#";

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
        \\// Auto-generated from zig/types/sprite.zig by zig/generate_shader.zig (runs during `zig build`).
        \\// Do NOT edit values between the markers by hand; edit the Sprite enum instead.
        \\const TILES_PER_ROW: f32 = {d}.0;
        \\const TILES_PER_COLUMN: f32 = {d}.0;
        \\const STONE_START: u32 = {d}u;
        \\const ORE_START: u32 = {d}u;
        \\const GEM_START: u32 = {d}u;
        \\const GEM_MASK_START: u32 = {d}u;
        \\const WATER_START: u32 = {d}u;
        \\
    , .{
        dw.getTilesPerRow(),
        dw.getTilesPerColumn(),
        sprite.STONE_START,
        sprite.ORE_START,
        sprite.GEM_START,
        sprite.MASK_START,
        @intFromEnum(Sprite.water),
    });
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
