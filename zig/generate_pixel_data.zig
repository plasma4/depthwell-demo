//! Regenerates `zig/render/sprite_colors.zig` from the exported sprite atlas at build time.
//!
//! For every 16x16 atlas tile, collects the UNIQUE fully-opaque texel colors from main.png,
//! converts each to OKLCH, and emits them as raw Zig arrays indexed CSR-style per tile.
//! Translucent-only tiles (such as leaves, which top out below full alpha) have no fully-opaque texel,
//! so those fall back to sampling the tile's most-opaque texels forced to full alpha.
//!
//! Guarded by a content hash of the PNG so this host tool is not rebuilt/rerun on unrelated changes.
const std = @import("std");

const Bitmap = @import("png/png_to_binary.zig").Bitmap;
const ColorRgba = @import("internal/color_rgba.zig").ColorRgba;

const MAIN_PNG_PATH = "public/assets/main.png";
const OUTPUT_PATH = "zig/render/sprite_colors.zig";

/// Atlas tile edge length in pixels (all sprites are 16x16).
const TILE_SIZE = 16;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    var main_bmp = try loadPng(init.io, allocator, MAIN_PNG_PATH);

    if (main_bmp.width % TILE_SIZE != 0 or main_bmp.height % TILE_SIZE != 0)
        return error.AtlasNotTileAligned;

    const tiles_x = main_bmp.width / TILE_SIZE;
    const tiles_y = main_bmp.height / TILE_SIZE;
    const tile_count = @as(usize, tiles_x) * @as(usize, tiles_y);

    // CSR layout: offsets[i]..offsets[i+1] is tile i's slice into the flat color list.
    var offsets = try allocator.alloc(u32, tile_count + 1);
    var all_colors = try std.ArrayListUnmanaged(ColorRgba).initCapacity(allocator, tile_count * 20);

    // Primary (mode) and secondary opaque colors per tile, white for fully-blank/missing tiles.
    var primary = try allocator.alloc(ColorRgba, tile_count);
    var secondary = try allocator.alloc(ColorRgba, tile_count);

    // Parallel scratch: dedup list plus per-color occurrence count (a 16x16 tile holds at most 256 unique colors).
    var unique: [TILE_SIZE * TILE_SIZE]ColorRgba = undefined;
    var counts: [TILE_SIZE * TILE_SIZE]u32 = undefined;

    offsets[0] = 0;
    for (0..tile_count) |tile| {
        const tx: u32 = @intCast((tile % tiles_x) * TILE_SIZE);
        const ty: u32 = @intCast((tile / tiles_x) * TILE_SIZE);

        var unique_len: usize = 0;
        for (0..TILE_SIZE) |py| {
            for (0..TILE_SIZE) |px| {
                const texel = main_bmp.getPixel(tx + @as(u32, @intCast(px)), ty + @as(u32, @intCast(py)));
                // Particles only sample fully-opaque texels; antialiased or empty ones are skipped.
                if (texel.isTransparent()) continue;
                appendUnique(&unique, &counts, &unique_len, texel);
            }
        }

        // Translucent-only tile (such as leaves): no fully-opaque texel exists,
        // so sample the most-opaque texels instead and force them opaque so the particles read as solid chips.
        if (unique_len == 0) {
            var max_alpha: u8 = 0;
            for (0..TILE_SIZE) |py| {
                for (0..TILE_SIZE) |px| {
                    const a = main_bmp.getPixel(tx + @as(u32, @intCast(px)), ty + @as(u32, @intCast(py))).channels.a;
                    max_alpha = @max(max_alpha, a);
                }
            }
            if (max_alpha > 0) {
                for (0..TILE_SIZE) |py| {
                    for (0..TILE_SIZE) |px| {
                        var texel = main_bmp.getPixel(tx + @as(u32, @intCast(px)), ty + @as(u32, @intCast(py)));
                        if (texel.channels.a != max_alpha) continue;
                        texel.channels.a = 255;
                        appendUnique(&unique, &counts, &unique_len, texel);
                    }
                }
            }
        }

        // Pick the primary (most common) and secondary (second most common) colors BEFORE sorting,
        // while `counts` still aligns with `unique`. Fully-blank tiles have no color at all, so fall back to opaque white.
        const pair = if (unique_len == 0)
            [2]ColorRgba{ ColorRgba.white, ColorRgba.white }
        else if (unique_len == 1)
            [2]ColorRgba{ unique[0], unique[0] }
        else blk: {
            var first_idx: usize = 0;
            for (1..unique_len) |i| {
                if (counts[i] > counts[first_idx]) {
                    first_idx = i;
                }
            }
            var second_idx: ?usize = null;
            for (0..unique_len) |i| {
                if (i == first_idx) continue;
                if (second_idx) |sec| {
                    if (counts[i] > counts[sec]) {
                        second_idx = i;
                    }
                } else {
                    second_idx = i;
                }
            }
            break :blk [2]ColorRgba{ unique[first_idx], unique[second_idx.?] };
        };

        primary[tile] = pair[0];
        secondary[tile] = pair[1];

        // Canonical ascending order keeps the generated file stable across pixel rearrangements.
        std.mem.sort(ColorRgba, unique[0..unique_len], {}, colorLessThan);
        try all_colors.appendSlice(allocator, unique[0..unique_len]);
        offsets[tile + 1] = @intCast(all_colors.items.len);
    }

    // u16 offsets keep the table compact; 256 unique colors per tile can't realistically overflow this,
    // but assert instead of silently truncating.
    if (all_colors.items.len > std.math.maxInt(u16)) return error.TooManyColors;

    // Render the generated Zig source.
    var bw = std.Io.Writer.Allocating.init(allocator);
    defer bw.deinit();
    const writer = &bw.writer;

    try writer.print(
        \\//! Auto-generated by `zig/generate_pixel_data.zig` (runs during `zig build`); do NOT edit by hand.
        \\//! Unique fully-opaque colors of every 16x16 sprite-atlas tile in main.png, converted to OKLCH
        \\//! (translucent-only tiles fall back to their most-opaque texels; see the generator).
        \\//! Each entry is (L, C, H in radians, A in 0-1) and can be used directly as an entity `lcha`
        \\//! tint over a white sprite such as `.particle`.
        \\const dw = @import("../root.zig");
        \\
        \\/// Number of 16x16 tiles in the sprite atlas (row-major, {d} per row).
        \\pub const TILE_COUNT: usize = {d};
        \\
        \\/// CSR offsets into `colors`: tile `i` owns `colors[tile_offsets[i]..tile_offsets[i + 1]]`.
        \\pub const tile_offsets = [TILE_COUNT + 1]u16{{
        \\
    , .{ tiles_x, tile_count });

    // 16 offsets per row; zig fmt column-aligns multi-element rows, so pad every cell to the widest offset
    // (the final one, since offsets are non-decreasing) plus a comma and a space.
    const cell_width = decimalWidth(offsets[tile_count]) + 2;
    for (offsets, 0..) |offset, i| {
        if (i % 16 == 0) try writer.writeAll("    ");
        if (i % 16 == 15 or i == offsets.len - 1) {
            try writer.print("{d},\n", .{offset});
        } else {
            try writer.print("{d},", .{offset});
            try writer.splatByteAll(' ', cell_width - decimalWidth(offset) - 1);
        }
    }

    try writer.print(
        \\}};
        \\
        \\/// Unique tile colors as OKLCH+alpha (see file docs). {d} colors total.
        \\pub const colors = [_][4]f32{{
        \\
    , .{all_colors.items.len});

    for (all_colors.items) |color| {
        const lcha = color.toOklch();
        try writer.print("    .{{ {d:.4}, {d:.4}, {d:.4}, {d:.4} }}, // #{x:0>6}\n", .{
            lcha[0],                    lcha[1], lcha[2], lcha[3],
            // RGB hex of the source color for debugging (word is little-endian ABGR)
            @byteSwap(color.word) >> 8,
        });
    }

    try writer.writeAll("};\n");

    try writer.writeAll(
        \\
        \\/// Single most common opaque color of each tile as OKLCH+alpha (see file docs); opaque white for blank tiles.
        \\/// Indexed by tile (entity id), so a UI element can tint text/icons with a sprite's signature color.
        \\pub const primary = [TILE_COUNT][4]f32{
        \\
    );

    for (primary) |color| {
        const lcha = color.toOklch();
        try writer.print("    .{{ {d:.4}, {d:.4}, {d:.4}, {d:.4} }}, // #{x:0>6}\n", .{
            lcha[0],                    lcha[1], lcha[2], lcha[3],
            @byteSwap(color.word) >> 8,
        });
    }
    try writer.writeAll("};\n");

    try writer.writeAll(
        \\
        \\/// Second most common opaque color of each tile as OKLCH+alpha (see file docs); opaque white for blank/single-color tiles.
        \\/// Indexed by tile (entity id), and falls back to the primary (only) color if a secondary color doesn't exist.
        \\pub const secondary = [TILE_COUNT][4]f32{
        \\
    );

    for (secondary) |color| {
        const lcha = color.toOklch();
        try writer.print("    .{{ {d:.4}, {d:.4}, {d:.4}, {d:.4} }}, // #{x:0>6}\n", .{
            lcha[0],                    lcha[1], lcha[2], lcha[3],
            @byteSwap(color.word) >> 8,
        });
    }
    try writer.writeAll("};\n");

    try writer.writeAll(
        \\
        \\const Sprite = dw.Sprite;
        \\/// The unique atlas colors of a sprite's tile as OKLCH+alpha tints (empty for unknown/blank tiles).
        \\pub fn colorsOf(s: Sprite) []const [4]f32 {
        \\    const tile = s.asEntity();
        \\    if (tile >= TILE_COUNT) return &.{};
        \\    return colors[tile_offsets[tile]..tile_offsets[tile + 1]];
        \\}
        \\/// The single most common opaque color of a sprite's tile as an OKLCH+alpha tint (opaque white for unknown tiles).
        \\pub fn primaryColorOf(s: Sprite) dw.utils.Vec4f32 {
        \\    const tile = s.asEntity();
        \\    if (tile >= TILE_COUNT) return .{ 1.0, 0.0, 0.0, 1.0 };
        \\    return primary[tile];
        \\}
        \\/// The second most common opaque color of a sprite's tile as an OKLCH+alpha tint (opaque white for unknown tiles).
        \\pub fn secondaryColorOf(s: Sprite) dw.utils.Vec4f32 {
        \\    const tile = s.asEntity();
        \\    if (tile >= TILE_COUNT) return .{ 1.0, 0.0, 0.0, 1.0 };
        \\    return secondary[tile];
        \\}
        \\
    );

    // Only touch the file when the content actually changes, so the dev file-watcher does not churn.
    const new_content = bw.written();
    const old_content = cwd.readFileAlloc(init.io, OUTPUT_PATH, allocator, .unlimited) catch "";
    if (!std.mem.eql(u8, new_content, old_content)) {
        try cwd.writeFile(init.io, .{ .sub_path = OUTPUT_PATH, .data = new_content });
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

/// Reads and decodes one PNG through the shared png_to_binary decoder.
fn loadPng(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Bitmap {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(data);
    return Bitmap.fromPngData(allocator, data);
}

/// Appends `color` to the tile's dedup scratch list, tallying occurrences in the parallel `counts` list
/// (a fresh color starts at 1; a repeat increments the existing entry).
fn appendUnique(unique: []ColorRgba, counts: []u32, unique_len: *usize, color: ColorRgba) void {
    for (unique[0..unique_len.*], counts[0..unique_len.*]) |seen, *count| {
        if (seen.eql(color)) {
            count.* += 1;
            return;
        }
    }
    unique[unique_len.*] = color;
    counts[unique_len.*] = 1;
    unique_len.* += 1;
}

fn colorLessThan(_: void, a: ColorRgba, b: ColorRgba) bool {
    return a.word < b.word;
}

/// Number of characters needed to print `value` in decimal.
fn decimalWidth(value: u32) usize {
    var width: usize = 1;
    var v = value;
    while (v >= 10) : (v /= 10) width += 1;
    return width;
}
