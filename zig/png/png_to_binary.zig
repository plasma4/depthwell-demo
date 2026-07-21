const std = @import("std");
const Allocator = std.mem.Allocator;
const ColorRgba = @import("../internal/color_rgba.zig").ColorRgba;

pub const PngError = error{
    InvalidSignature,
    InvalidHeader,
    MissingHeader,
    MissingImageData,
    MissingPalette,
    UnsupportedBitDepth,
    UnsupportedColorType,
    UnsupportedInterlace,
    InvalidFilterType,
    DecompressionFailed,
    DataSizeMismatch,
    InvalidDimensions,
};

const HIGHEST_COLOR_TYPE: u8 = 6;
const ColorType = enum(u8) {
    grayscale = 0,
    rgb = 2,
    indexed = 3,
    grayscale_alpha = 4,
    rgba = 6,
};

pub const Bitmap = struct {
    width: u32,
    height: u32,
    pixels: []ColorRgba,
    allocator: Allocator,

    pub fn deinit(self: *Bitmap) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    /// Load a PNG file from disk.
    pub fn fromPngFile(allocator: Allocator, path: []const u8) !Bitmap {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const data = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
        defer allocator.free(data);

        return fromPngData(allocator, data);
    }

    /// Parse raw PNG file bytes into a `Bitmap`.
    pub fn fromPngData(allocator: Allocator, data: []const u8) !Bitmap {
        var idat_chunks = try std.ArrayListUnmanaged([]const u8).initCapacity(allocator, 10);

        // Validate the signature
        const png_sig = "\x89PNG\r\n\x1a\n";
        if (data.len < 8 or !std.mem.eql(u8, data[0..8], png_sig))
            return PngError.InvalidSignature;

        var pos: usize = 8;

        var width: u32 = 0;
        var height: u32 = 0;
        var color_type: ColorType = .rgba;
        var has_header = false;

        var palette: ?[]const u8 = null;
        var trns_data: ?[]const u8 = null;

        // Collect IDAT chunks
        defer idat_chunks.deinit(allocator);
        var total_idat_len: usize = 0;

        while (pos + 12 <= data.len) {
            const chunk_len = std.mem.readInt(u32, data[pos..][0..4], .big);
            const chunk_type = data[pos + 4 ..][0..4];
            pos += 8;

            const chunk_len_usize: usize = chunk_len;
            if (pos + chunk_len_usize + 4 > data.len) break;

            const chunk_data = data[pos .. pos + chunk_len_usize];

            if (eql4(chunk_type, "IHDR")) {
                if (chunk_len < 13) return PngError.InvalidHeader;
                width = std.mem.readInt(u32, chunk_data[0..4], .big);
                height = std.mem.readInt(u32, chunk_data[4..8], .big);
                const bit_depth = chunk_data[8];
                const ct = chunk_data[9];
                const interlace = chunk_data[12];

                if (width == 0 or height == 0) return PngError.InvalidDimensions;
                if (bit_depth != 8) return PngError.UnsupportedBitDepth;
                if (interlace != 0) return PngError.UnsupportedInterlace;

                if (ct > HIGHEST_COLOR_TYPE) {
                    return PngError.UnsupportedColorType;
                }
                color_type = @enumFromInt(ct);
                has_header = true;
            } else if (eql4(chunk_type, "PLTE")) {
                palette = chunk_data;
            } else if (eql4(chunk_type, "tRNS")) {
                trns_data = chunk_data;
            } else if (eql4(chunk_type, "IDAT")) {
                try idat_chunks.append(allocator, chunk_data); // TODO
                total_idat_len += chunk_len_usize;
            } else if (eql4(chunk_type, "IEND")) {
                break;
            }

            pos += chunk_len_usize + 4; // skip data + CRC
        }

        if (!has_header) return PngError.MissingHeader;
        if (color_type == .indexed and palette == null) return PngError.MissingPalette;
        if (idat_chunks.items.len == 0) return PngError.MissingImageData;

        // Concatenate IDAT data
        const compressed = try allocator.alloc(u8, total_idat_len);
        defer allocator.free(compressed);
        {
            var offset: usize = 0;
            for (idat_chunks.items) |chunk| {
                @memcpy(compressed[offset .. offset + chunk.len], chunk);
                offset += chunk.len;
            }
        }

        // Calculate stride
        const bpp: usize = switch (color_type) {
            .grayscale => 1,
            .rgb => 3,
            .indexed => 1,
            .grayscale_alpha => 2,
            .rgba => 4,
        };
        const w: usize = width;
        const h: usize = height;
        const stride = w * bpp;
        const raw_size = h * (1 + stride); // 1 filter byte per row

        // Decompress
        const raw = try allocator.alloc(u8, raw_size);
        defer allocator.free(raw);

        var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var reader: std.Io.Reader = .fixed(compressed);
        var decompressor = std.compress.flate.Decompress.init(
            &reader,
            .zlib,
            &flate_buffer,
        );

        decompressor.reader.readSliceAll(raw) catch
            return PngError.DecompressionFailed;

        // Unfilter
        var prev_row: ?[]u8 = null;
        for (0..h) |y| {
            const row_start = y * (1 + stride);
            const filter_byte = raw[row_start];
            const row = raw[row_start + 1 .. row_start + 1 + stride];

            switch (filter_byte) {
                0 => {}, // None
                1 => unfilterSub(row, bpp),
                2 => unfilterUp(row, prev_row),
                3 => unfilterAverage(row, prev_row, bpp),
                4 => unfilterPaeth(row, prev_row, bpp),
                else => return PngError.InvalidFilterType,
            }
            prev_row = row;
        }

        // Convert to RGBA
        const pixels = try allocator.alloc(ColorRgba, w * h);
        errdefer allocator.free(pixels);

        for (0..h) |y| {
            const row_start = y * (1 + stride) + 1; // skip filter byte
            const row = raw[row_start .. row_start + stride];
            for (0..w) |x| {
                const pi = y * w + x;
                switch (color_type) {
                    .rgba => {
                        const si = x * 4;
                        pixels[pi] = ColorRgba.init(row[si], row[si + 1], row[si + 2], row[si + 3]);
                    },
                    .rgb => {
                        const si = x * 3;
                        const r = row[si];
                        const g = row[si + 1];
                        const b = row[si + 2];
                        const a: u8 = if (trns_data) |t| blk: {
                            if (t.len >= 6) {
                                const tr = std.mem.readInt(u16, t[0..2], .big);
                                const tg = std.mem.readInt(u16, t[2..4], .big);
                                const tb = std.mem.readInt(u16, t[4..6], .big);
                                break :blk if (@as(u16, r) == tr and @as(u16, g) == tg and @as(u16, b) == tb) 0 else 255;
                            }
                            break :blk 255;
                        } else 255;
                        pixels[pi] = ColorRgba.init(r, g, b, a);
                    },
                    .grayscale => {
                        const v = row[x];
                        const a: u8 = if (trns_data) |t| blk: {
                            // tRNS for grayscale is a 2-byte big-endian value
                            if (t.len >= 2) {
                                const transparent_val = std.mem.readInt(u16, t[0..2], .big);
                                break :blk if (@as(u16, v) == transparent_val) 0 else 255;
                            }
                            break :blk 255;
                        } else 255;
                        pixels[pi] = ColorRgba.init(v, v, v, a);
                    },
                    .grayscale_alpha => {
                        const si = x * 2;
                        const v = row[si];
                        pixels[pi] = ColorRgba.init(v, v, v, row[si + 1]);
                    },
                    .indexed => {
                        const idx: usize = row[x];
                        const pal = palette.?;
                        if (idx * 3 + 2 < pal.len) {
                            const a: u8 = if (trns_data) |t|
                                (if (idx < t.len) t[idx] else 255)
                            else
                                255;
                            pixels[pi] = ColorRgba.init(pal[idx * 3], pal[idx * 3 + 1], pal[idx * 3 + 2], a);
                        } else {
                            pixels[pi].word = 0;
                        }
                    },
                }
            }
        }

        return Bitmap{
            .width = width,
            .height = height,
            .pixels = pixels,
            .allocator = allocator,
        };
    }

    /// Gets a pixel at `(x, y)`.
    pub fn getPixel(self: *const Bitmap, x: u32, y: u32) ColorRgba {
        if (x >= self.width or y >= self.height) return .transparent;
        return self.pixels[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
    }

    /// Sets a pixel at `(x, y)`.
    pub fn setPixel(self: *Bitmap, x: u32, y: u32, color: ColorRgba) void {
        if (x >= self.width or y >= self.height) return;
        self.pixels[@as(usize, y) * @as(usize, self.width) + @as(usize, x)] = color;
    }

    /// Average color of the entire image.
    pub fn averageColor(self: *const Bitmap) ColorRgba {
        return averageOfSlice(self.pixels);
    }

    /// Average gamma perceptual color of a rectangular region (clamped to image bounds).
    pub fn averageColorRect(self: *const Bitmap, rx: u32, ry: u32, rw: u32, rh: u32) ColorRgba {
        const x0: usize = @min(rx, self.width);
        const y0: usize = @min(ry, self.height);
        const x1: usize = @min(@as(usize, rx) + @as(usize, rw), self.width);
        const y1: usize = @min(@as(usize, ry) + @as(usize, rh), self.height);

        if (x0 >= x1 or y0 >= y1) return .transparent;

        var sum_r: u64 = 0;
        var sum_g: u64 = 0;
        var sum_b: u64 = 0;
        var sum_a: u64 = 0;
        var count: u64 = 0;

        for (y0..y1) |y| {
            const row = self.pixels[y * self.width + x0 .. y * self.width + x1];
            for (row) |px| {
                const r: u64 = px.channels.r;
                const g: u64 = px.channels.g;
                const b: u64 = px.channels.b;
                const a: u64 = px.channels.a;

                // Ensure u64 math throughout to prevent overflow
                sum_r += r * r * a;
                sum_g += g * g * a;
                sum_b += b * b * a;
                sum_a += a;
                count += 1;
            }
        }

        if (sum_a == 0) return .transparent;

        return ColorRgba.init(
            @intCast(std.math.sqrt(sum_r / sum_a)),
            @intCast(std.math.sqrt(sum_g / sum_a)),
            @intCast(std.math.sqrt(sum_b / sum_a)),
            @intCast(sum_a / count), // Average opacity of the area
        );
    }

    /// Alpha-weighted average (premultiplied).
    /// More perceptually correct when averaging sprites with transparency.
    pub fn averageColorWeighted(self: *const Bitmap) ColorRgba {
        return averageWeightedOfSlice(self.pixels);
    }

    /// Alpha-weighted average of a rectangular region.
    pub fn averageColorRectWeighted(self: *const Bitmap, rx: u32, ry: u32, rw: u32, rh: u32) ColorRgba {
        const x0: usize = @min(rx, self.width);
        const y0: usize = @min(ry, self.height);
        const x1: usize = @min(@as(usize, rx) + @as(usize, rw), self.width);
        const y1: usize = @min(@as(usize, ry) + @as(usize, rh), self.height);

        if (x0 >= x1 or y0 >= y1) return .transparent;

        const w: usize = self.width;
        var sum_r: u64 = 0;
        var sum_g: u64 = 0;
        var sum_b: u64 = 0;
        var sum_a: u64 = 0;

        for (y0..y1) |y| {
            const row = self.pixels[y * w + x0 .. y * w + x1];
            for (row) |px| {
                const a: u64 = px.channels.a;
                sum_r += @as(u64, px.channels.r) * a;
                sum_g += @as(u64, px.channels.g) * a;
                sum_b += @as(u64, px.channels.b) * a;
                sum_a += a;
            }
        }
        if (sum_a == 0) return .transparent;
        return ColorRgba.init(
            @intCast(sum_r / sum_a),
            @intCast(sum_g / sum_a),
            @intCast(sum_b / sum_a),
            @intCast(sum_a / ((x1 - x0) * (y1 - y0))),
        );
    }

    /// Average a flat pixel slice (whole image fast path).
    fn averageOfSlice(pixels: []const ColorRgba) ColorRgba {
        if (pixels.len == 0) return .transparent;
        var sum_r: u64 = 0;
        var sum_g: u64 = 0;
        var sum_b: u64 = 0;
        var sum_a: u64 = 0;
        for (pixels) |px| {
            sum_r += px.channels.r;
            sum_g += px.channels.g;
            sum_b += px.channels.b;
            sum_a += px.channels.a;
        }
        const n: u64 = pixels.len;
        return ColorRgba.init(
            @intCast(sum_r / n),
            @intCast(sum_g / n),
            @intCast(sum_b / n),
            @intCast(sum_a / n),
        );
    }

    fn averageWeightedOfSlice(pixels: []const ColorRgba) ColorRgba {
        if (pixels.len == 0) return .transparent;
        var sum_r: u64 = 0;
        var sum_g: u64 = 0;
        var sum_b: u64 = 0;
        var sum_a: u64 = 0;
        for (pixels) |px| {
            const a: u64 = px.channels.a;
            sum_r += @as(u64, px.channels.r) * a;
            sum_g += @as(u64, px.channels.g) * a;
            sum_b += @as(u64, px.channels.b) * a;
            sum_a += a;
        }
        if (sum_a == 0) return .transparent;
        return ColorRgba.init(
            @intCast(sum_r / sum_a),
            @intCast(sum_g / sum_a),
            @intCast(sum_b / sum_a),
            @intCast(sum_a / pixels.len),
        );
    }
};

fn unfilterSub(row: []u8, bpp: usize) void {
    for (bpp..row.len) |i| {
        row[i] = row[i] +% row[i - bpp];
    }
}

fn unfilterUp(row: []u8, prev: ?[]u8) void {
    const p = prev orelse return;
    for (0..row.len) |i| {
        row[i] = row[i] +% p[i];
    }
}

fn unfilterAverage(row: []u8, prev: ?[]u8, bpp: usize) void {
    for (0..row.len) |i| {
        const a_val: u16 = if (i >= bpp) row[i - bpp] else 0;
        const b_val: u16 = if (prev) |p| p[i] else 0;
        row[i] = row[i] +% @as(u8, @intCast((a_val + b_val) >> 1));
    }
}

fn unfilterPaeth(row: []u8, prev: ?[]u8, bpp: usize) void {
    for (0..row.len) |i| {
        const a: i16 = if (i >= bpp) @intCast(row[i - bpp]) else 0;
        const b: i16 = if (prev) |p| @intCast(p[i]) else 0;
        const c: i16 = if (i >= bpp and prev != null) @intCast(prev.?[i - bpp]) else 0;

        row[i] = row[i] +% paethPredictor(a, b, c);
    }
}

fn paethPredictor(a: i16, b: i16, c: i16) u8 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return @intCast(@as(u16, @bitCast(a)));
    if (pb <= pc) return @intCast(@as(u16, @bitCast(b)));
    return @intCast(@as(u16, @bitCast(c)));
}

inline fn eql4(a: *const [4]u8, comptime b: *const [4]u8) bool {
    return std.mem.readInt(u32, a, .big) == comptime std.mem.readInt(u32, b, .big);
}

const testing_alloc = std.testing.allocator;
test "solid red 4x4" {
    // @embedFile resolves relative to the current .zig file!
    const png_data = @embedFile("./red_4x4_rgba.png");
    var bmp = try Bitmap.fromPngData(testing_alloc, png_data);
    defer bmp.deinit();

    try std.testing.expectEqual(@as(u32, 4), bmp.width);
    try std.testing.expectEqual(@as(u32, 4), bmp.height);
    try std.testing.expectEqual(@as(usize, 16), bmp.pixels.len);

    for (bmp.pixels) |px| {
        try std.testing.expectEqual(ColorRgba.init(255, 0, 0, 255), px);
    }

    const avg = bmp.averageColor();
    try std.testing.expectEqual(@as(u8, 255), avg.channels.r);
    try std.testing.expectEqual(@as(u8, 0), avg.channels.g);
    try std.testing.expectEqual(@as(u8, 0), avg.channels.b);
    try std.testing.expectEqual(@as(u8, 255), avg.channels.a);
}

test "rectangular gradient 4x2 averages" {
    // Image colors from left-to-right are rgba(0, 0, 0, 255), rgba(85, 85, 85, 255), rgba(170, 170, 170, 255), rgba(255, 255, 255, 255)
    const png_data = @embedFile("test_gradient.png");
    var bmp = try Bitmap.fromPngData(testing_alloc, png_data);
    defer bmp.deinit();

    try std.testing.expectEqual(@as(u32, 4), bmp.width);
    try std.testing.expectEqual(@as(u32, 2), bmp.height);

    const tl = bmp.getPixel(0, 0);
    try std.testing.expectEqual(@as(u8, 0), tl.channels.r);
    try std.testing.expectEqual(@as(u8, 0), tl.channels.g);
    try std.testing.expectEqual(@as(u8, 0), tl.channels.b);

    const tr = bmp.getPixel(3, 0);
    try std.testing.expectEqual(@as(u8, 255), tr.channels.r);
    try std.testing.expectEqual(@as(u8, 255), tr.channels.g);
    try std.testing.expectEqual(@as(u8, 255), tr.channels.b);

    var avg = bmp.averageColorRect(1, 0, 1, 2);
    try std.testing.expectEqual(@as(u8, 85), avg.channels.r);
    try std.testing.expectEqual(@as(u8, 85), avg.channels.g);
    try std.testing.expectEqual(@as(u8, 85), avg.channels.b);

    avg = bmp.averageColorRect(0, 1, 4, 1);
    try std.testing.expectEqual(@as(u8, 159), avg.channels.r);
    try std.testing.expectEqual(@as(u8, 159), avg.channels.g);
    try std.testing.expectEqual(@as(u8, 159), avg.channels.b);

    avg = bmp.averageColorRect(0, 0, 2, 1);
    try std.testing.expectEqual(@as(u8, 60), avg.channels.r);
    try std.testing.expectEqual(@as(u8, 60), avg.channels.g);
    try std.testing.expectEqual(@as(u8, 60), avg.channels.b);
}

test "indexed 2x2" {
    const png_data = @embedFile("test_indexed.png");
    var bmp = try Bitmap.fromPngData(testing_alloc, png_data);
    defer bmp.deinit();

    try std.testing.expectEqual(@as(u32, 2), bmp.width);
    try std.testing.expectEqual(@as(u32, 2), bmp.height);

    try std.testing.expect(bmp.getPixel(0, 0).eql(ColorRgba.init(255, 0, 0, 255)));
    try std.testing.expect(bmp.getPixel(1, 0).eql(ColorRgba.init(0, 255, 0, 255)));
    try std.testing.expect(bmp.getPixel(0, 1).eql(ColorRgba.init(0, 0, 255, 255)));
    try std.testing.expect(bmp.getPixel(1, 1).isTransparent());
}

test "alpha weighted average" {
    const png_data = @embedFile("test_alpha.png");
    var bmp = try Bitmap.fromPngData(testing_alloc, png_data);
    defer bmp.deinit();

    const wavg = bmp.averageColorWeighted();
    const avg = bmp.averageColor();

    try std.testing.expect(wavg.channels.a > 0);
    try std.testing.expect(avg.channels.b > wavg.channels.b or avg.channels.r != wavg.channels.r);
}
