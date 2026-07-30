//! Handles colors, containing the ColorRgba struct and its tests.
const std = @import("std");
const builtin = @import("builtin");

test "correct color byte length" {
    try std.testing.expectEqual(32, @bitSizeOf(ColorRgba));
}

/// Represents a color. Note that WebGPU processes colors as `rgba16float` by default;
/// this data is used to determine similarity of blocks and is not color-space compliant.
pub const ColorRgba = extern union {
    /// Single-word access for quick equality checks. Assumes little-endian.
    word: u32,
    /// SIMD-ready vector access for RGBA components.
    v: [4]u8 align(4),
    /// Individual RGBA components through color channels.
    channels: packed struct(u32) {
        /// Red component of color (0-255).
        r: u8 = 0,
        /// Green component of color (0-255).
        g: u8 = 0,
        /// Blue component of color (0-255).
        b: u8 = 0,
        /// Alpha component of color (0-255).
        a: u8 = 0,
    },

    /// Creates a ColorRgba with the given Red, Green, Blue, and Alpha component values.
    pub inline fn init(r: u8, g: u8, b: u8, a: u8) ColorRgba {
        return .{ .channels = .{ .r = r, .g = g, .b = b, .a = a } };
    }

    // Fully transparent black.
    pub const transparent = ColorRgba.init(0, 0, 0, 0);
    // Fully opaque white.
    pub const white = ColorRgba.init(255, 255, 255, 255);
    // Fully opaque black.
    pub const black = ColorRgba.init(0, 0, 0, 255);

    /// Returns an approximation of brightness.
    pub fn luminance(self: ColorRgba) u8 {
        const r: u32 = self.channels.r;
        const g: u32 = self.channels.g;
        const b: u32 = self.channels.b;
        return @intCast((r * 54 + g * 183 + b * 19) >> 8);
    }

    /// Interpolates two colors linearly.
    pub fn mix(self: ColorRgba, other: ColorRgba, t: f32) ColorRgba {
        const amt: u16 = @intFromFloat(@round(t * 256.0));
        const rev: u16 = 256 - amt;

        // Perform math in vector space to prevent component-to-component bleed
        const v1: @Vector(4, u16) = self.v;
        const v2: @Vector(4, u16) = other.v;

        const mixed = (v1 * @as(@Vector(4, u16), @splat(rev)) +
            v2 * @as(@Vector(4, u16), @splat(amt))) >>
            @as(@Vector(4, u16), @splat(8));

        return .{ .v = @as(@Vector(4, u8), @intCast(mixed)) };
    }

    /// Determines similarity between two colors.
    pub fn getColorDistance(color_1: ColorRgba, color_2: ColorRgba) f32 {
        const v1: @Vector(4, f32) = @floatFromInt(@as(@Vector(4, u8), color_1.v));
        const v2: @Vector(4, f32) = @floatFromInt(@as(@Vector(4, u8), color_2.v));

        const diff = v1 - v2;
        const dist_sq = diff * diff;

        const r_mean = (v1[0] + v2[0]) / 2.0;

        const weight_r = 2.0 + (r_mean / 256.0);
        const weight_g = 4.0;
        const weight_b = 2.0 + ((255.0 - r_mean) / 256.0);

        return (weight_r * dist_sq[0]) + (weight_g * dist_sq[1]) + (weight_b * dist_sq[2]);
    }

    /// Checks for equality between two `ColorRgba` values.
    pub fn eql(self: ColorRgba, other: ColorRgba) bool {
        return self.word == other.word;
    }

    /// Hue in degrees [0, 360). Returns 0 for achromatic colors.
    pub fn hue(self: ColorRgba) u16 {
        const r: i32 = self.channels.r;
        const g: i32 = self.channels.g;
        const b: i32 = self.channels.b;
        const min_c = @min(r, g, b);
        const max_c = @max(r, g, b);
        const delta = max_c - min_c;
        if (delta == 0) return 0;

        var h: i32 = 0;
        if (max_c == r) {
            h = @divTrunc((g - b) * 60, delta);
        } else if (max_c == g) {
            h = @divTrunc((b - r) * 60, delta) + 120;
        } else {
            h = @divTrunc((r - g) * 60, delta) + 240;
        }
        if (h < 0) h += 360;
        return @intCast(h);
    }

    /// Saturation as 0-255 (HSV saturation scaled to byte range).
    pub fn saturation(self: ColorRgba) u8 {
        const min_c = @min(self.channels.r, self.channels.g, self.channels.b);
        const max_c = @max(self.channels.r, self.channels.g, self.channels.b);
        if (max_c == 0) return 0;
        return @intCast((@as(u16, max_c - min_c) * 255) / @as(u16, max_c));
    }

    /// Value (simply the maximum channel).
    pub fn maxChannel(self: ColorRgba) u8 {
        const rgb = @as(@Vector(4, u8), self.v) * @Vector(4, u8){ 1, 1, 1, 0 };
        return @reduce(.Max, rgb);
    }

    /// Lightness (average of min and max channels).
    pub fn lightness(self: ColorRgba) u8 {
        const min_c = @min(self.channels.r, self.channels.g, self.channels.b);
        const max_c = @max(self.channels.r, self.channels.g, self.channels.b);
        return @intCast((@as(u16, max_c) + min_c) / 2);
    }

    /// Perceived brightness using sRGB-approximate formula.
    /// Faster than luminance(), uses sqrt approximation.
    pub fn brightness(self: ColorRgba) u8 {
        // sqrt(0.299*R*R + 0.587*G*G + 0.114*B*B), integer approx
        const v_wide: @Vector(4, u32) = self.v;
        const v_sq = v_wide * v_wide;
        // weights: 77/256 is about 0.299, 150/256 is about 0.587, 29/256 is about 0.114
        const weights = @Vector(4, u32){ 77, 150, 29, 0 };
        const weighted = @reduce(.Add, v_sq * weights) >> 8;
        return @intCast(std.math.sqrt(weighted));
    }

    /// Is fully opaque?
    pub fn isOpaque(self: ColorRgba) bool {
        return self.channels.a == 255;
    }

    /// Isn't fully opaque or transparent?
    pub fn isTranslucent(self: ColorRgba) bool {
        return self.channels.a != 0 and self.channels.a != 255;
    }

    /// Is fully transparent?
    pub fn isTransparent(self: ColorRgba) bool {
        return self.channels.a == 0;
    }

    /// Inverts RGB while keeping alpha.
    pub fn invert(self: ColorRgba) ColorRgba {
        var result: ColorRgba = .{ .v = @as(@Vector(4, u8), @splat(255)) - self.v };
        result.channels.a = self.channels.a;
        return result;
    }

    /// Convert to grayscale using luminance while keeping alpha.
    pub fn toGrayscale(self: ColorRgba) ColorRgba {
        const l = self.luminance();
        return ColorRgba.init(l, l, l, self.channels.a);
    }

    /// Alpha-composite src over self (Porter-Duff "over" operator).
    pub fn compositeOver(self: ColorRgba, src: ColorRgba) ColorRgba {
        const sa: u32 = src.channels.a;
        const da: u32 = self.channels.a;
        const inv_sa: u32 = 255 - sa;

        const out_a = sa + ((da * inv_sa) / 255);
        if (out_a == 0) return ColorRgba.transparent;

        return ColorRgba.init(
            @intCast((src.channels.r * sa + (self.channels.r * da * inv_sa) / 255) / out_a),
            @intCast((src.channels.g * sa + (self.channels.g * da * inv_sa) / 255) / out_a),
            @intCast((src.channels.b * sa + (self.channels.b * da * inv_sa) / 255) / out_a),
            @intCast(out_a),
        );
    }

    /// Return color with modified alpha.
    pub fn withAlpha(self: ColorRgba, a: u8) ColorRgba {
        var res = self;
        res.channels.a = a;
        return res;
    }

    /// Simple average of two colors (no alpha weighting).
    pub fn average(self: ColorRgba, other: ColorRgba) ColorRgba {
        const v1: @Vector(4, u16) = self.v;
        const v2: @Vector(4, u16) = other.v;
        const avg = (v1 + v2) >> @as(@Vector(4, u16), @splat(1));
        return .{ .v = @as(@Vector(4, u8), @intCast(avg)) };
    }

    /// Converts a comptime hex code into a ColorRgba (as #ffffff or #ffffffff)
    pub fn fromHex(comptime html_hex: []const u8) ColorRgba {
        const hex = if (html_hex[0] == '#') html_hex[1..] else html_hex;

        if (hex.len != 6 and hex.len != 8) {
            @compileError("Hex string must be 6 or 8 characters (excluding #)");
        }

        // parse RGB components
        const r = std.fmt.parseInt(u8, hex[0..2], 16) catch @compileError("Red component is not valid hex.");
        const g = std.fmt.parseInt(u8, hex[2..4], 16) catch @compileError("Green component is not valid hex.");
        const b = std.fmt.parseInt(u8, hex[4..6], 16) catch @compileError("Blue component is not valid hex.");

        const a = if (hex.len == 8) // parse alpha
            std.fmt.parseInt(u8, hex[6..8], 16) catch @compileError("Alpha component is not valid hex.")
        else
            255;

        return ColorRgba.init(r, g, b, a);
    }

    /// Helper for converting an sRGB channel (0.0 - 1.0) to Linear sRGB.
    fn srgbToLinear(c: f32) f32 {
        if (c <= 0.04045) return c / 12.92;
        return std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
    }

    /// Converts this color to OKLCH (L, C, H in radians, A normalized to 0-1).
    /// Matches the conversion chain in `fs_entity()` in `src/shader.wgsl`,
    /// so the result can be used directly as an entity `lcha` tint over a white sprite.
    ///
    /// Works at both comptime and runtime.
    pub fn toOklch(self: ColorRgba) @Vector(4, f32) {
        const r_lin = srgbToLinear(@as(f32, @floatFromInt(self.channels.r)) / 255.0);
        const g_lin = srgbToLinear(@as(f32, @floatFromInt(self.channels.g)) / 255.0);
        const b_lin = srgbToLinear(@as(f32, @floatFromInt(self.channels.b)) / 255.0);

        // Convert to LMS
        const l_ = 0.4122214708 * r_lin + 0.5363325363 * g_lin + 0.0514459929 * b_lin;
        const m_ = 0.2119034982 * r_lin + 0.6806995451 * g_lin + 0.1073969566 * b_lin;
        const s_ = 0.0883024619 * r_lin + 0.2817188376 * g_lin + 0.6299787005 * b_lin;

        const l = std.math.cbrt(l_);
        const m = std.math.cbrt(m_);
        const s = std.math.cbrt(s_);

        // Now, change to OKLAB
        const lab_l = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s;
        const lab_a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
        const lab_b = 0.0259040371 * l + 0.7827717662 * m - 0.8086758031 * s;

        // Convert to OKLCH
        const oklch_chroma = @sqrt(lab_a * lab_a + lab_b * lab_b);
        const oklch_hue = std.math.atan2(lab_b, lab_a);

        return .{ lab_l, oklch_chroma, oklch_hue, @as(f32, @floatFromInt(self.channels.a)) / 255.0 };
    }

    /// Converts a hex code directly into OKLCH. Use like `comptime ColorRgba.hexToOklch("#ffffff")`.
    pub inline fn hexToOklch(comptime html_hex: []const u8) @Vector(4, f32) {
        comptime return ColorRgba.fromHex(html_hex).toOklch();
    }
};

test "hex codes" {
    // Standard 6-character hex (no #)
    const c1 = comptime ColorRgba.fromHex("123456");
    try std.testing.expectEqual(@as(u8, 0x12), c1.channels.r);
    try std.testing.expectEqual(@as(u8, 0x34), c1.channels.g);
    try std.testing.expectEqual(@as(u8, 0x56), c1.channels.b);
    try std.testing.expectEqual(@as(u8, 255), c1.channels.a);

    // 6-character hex
    const c2 = comptime ColorRgba.fromHex("#ff0000");
    try std.testing.expectEqual(@as(u8, 255), c2.channels.r);
    try std.testing.expectEqual(@as(u8, 0), c2.channels.g);
    try std.testing.expectEqual(@as(u8, 0), c2.channels.b);
    try std.testing.expectEqual(@as(u8, 255), c2.channels.a);

    // 8-character hex
    const c3 = comptime ColorRgba.fromHex("#00fF0080");
    try std.testing.expectEqual(@as(u8, 0), c3.channels.r);
    try std.testing.expectEqual(@as(u8, 255), c3.channels.g);
    try std.testing.expectEqual(@as(u8, 0), c3.channels.b);
    try std.testing.expectEqual(@as(u8, 128), c3.channels.a);

    // Standard black and white hex strings against constants
    const white = comptime ColorRgba.fromHex("#fFfFfF");
    try std.testing.expect(white.eql(ColorRgba.white));

    const black = comptime ColorRgba.fromHex("000000");
    try std.testing.expect(black.eql(ColorRgba.black));
}

test "color modification" {
    // A color equal to rgb(8, 240, 0).
    var test_color = comptime ColorRgba.fromHex("#08f000");
    test_color.channels.a -|= 16; // saturating subtraction
    try std.testing.expectEqual(0xef, test_color.channels.a);

    try std.testing.expectEqual(0x08, test_color.channels.r);
    test_color.channels.r -|= 12;
    try std.testing.expectEqual(0x00, test_color.channels.r);

    try std.testing.expectEqual(0xf0, test_color.channels.g);
    test_color.channels.g +|= 3; // saturating addition
    try std.testing.expectEqual(0xf3, test_color.channels.g);
    test_color.channels.g +|= 16;
    try std.testing.expectEqual(0xff, test_color.channels.g);
}

test "perceptual luminance" {
    const pure_green = ColorRgba.init(0, 255, 0, 255);
    const pure_blue = ColorRgba.init(0, 0, 255, 255);

    const lum_g = pure_green.luminance();
    const lum_b = pure_blue.luminance();

    try std.testing.expect(lum_g > lum_b * 9);
}

test "luminance calculation" {
    const gray = ColorRgba.init(100, 100, 100, 255);
    try std.testing.expectEqual(@as(u8, 100), gray.luminance());

    const black = ColorRgba.black;
    try std.testing.expectEqual(@as(u8, 0), black.luminance());

    const custom = ColorRgba.init(10, 20, 30, 255);
    try std.testing.expectEqual(@as(u8, 18), custom.luminance());
}

test "mix interpolation" {
    const red = ColorRgba.init(255, 0, 0, 255);
    const blue = ColorRgba.init(0, 0, 255, 255);

    const start = red.mix(blue, 0.0);
    try std.testing.expectEqual(red.channels.r, start.channels.r);
    try std.testing.expectEqual(red.channels.b, start.channels.b);

    const end = red.mix(blue, 1.0);
    try std.testing.expectEqual(blue.channels.r, end.channels.r);
    try std.testing.expectEqual(blue.channels.b, end.channels.b);

    const mid = red.mix(blue, 0.5);
    try std.testing.expect(mid.channels.r >= 127 and mid.channels.r <= 128);
    try std.testing.expect(mid.channels.b >= 127 and mid.channels.b <= 128);
    try std.testing.expectEqual(@as(u8, 0), mid.channels.g);
}

test "color distance" {
    const c1 = ColorRgba.init(255, 0, 0, 255);
    const c2 = ColorRgba.init(255, 0, 0, 255);
    // Distance to self should ALWAYS be 0
    try std.testing.expectEqual(0.0, ColorRgba.getColorDistance(c1, c2));
    const c3 = ColorRgba.init(0, 0, 0, 255);
    const dist = ColorRgba.getColorDistance(c1, c3);

    // Distance should be quite large here
    try std.testing.expect(dist > 100000.0 and dist < 1000000.0);
}

test "packed layout integrity" {
    const color = ColorRgba.init(0xAA, 0xBB, 0xCC, 0xDD);
    const as_u32: u32 = color.word;

    // check endian-ness
    if (builtin.cpu.arch.endian() == .little) {
        try std.testing.expectEqual(@as(u32, 0xDDCCBBAA), as_u32);
    } else {
        // Expect little-endian, this should be impossible.
        unreachable;
    }
}

test "eql" {
    const c1 = ColorRgba.init(10, 20, 30, 40);
    const c2 = ColorRgba.init(10, 20, 30, 40);
    const c3 = ColorRgba.init(11, 20, 30, 40);

    try std.testing.expect(c1.eql(c2));
    try std.testing.expect(!c1.eql(c3));
}

test "hue" {
    // Primary / Secondary colors
    try std.testing.expectEqual(@as(u16, 0), ColorRgba.init(255, 0, 0, 255).hue());
    try std.testing.expectEqual(@as(u16, 120), ColorRgba.init(0, 255, 0, 255).hue());
    try std.testing.expectEqual(@as(u16, 240), ColorRgba.init(0, 0, 255, 255).hue());
    try std.testing.expectEqual(@as(u16, 60), ColorRgba.init(255, 255, 0, 255).hue()); // yellow
    try std.testing.expectEqual(@as(u16, 300), ColorRgba.init(255, 0, 255, 255).hue()); // magenta

    // Achromatic colors should return 0
    try std.testing.expectEqual(@as(u16, 0), ColorRgba.white.hue());
    try std.testing.expectEqual(@as(u16, 0), ColorRgba.black.hue());
}

test "saturation" {
    try std.testing.expectEqual(@as(u8, 255), ColorRgba.init(255, 0, 0, 255).saturation());
    try std.testing.expectEqual(@as(u8, 0), ColorRgba.white.saturation());
    try std.testing.expectEqual(@as(u8, 0), ColorRgba.black.saturation());

    // (100 * 255) / 200 becomes 127 when rounding down
    try std.testing.expectEqual(@as(u8, 127), ColorRgba.init(200, 100, 100, 255).saturation());
}

test "value and lightness" {
    const c = ColorRgba.init(50, 128, 10, 255);

    // Value = max channel
    try std.testing.expectEqual(@as(u8, 128), c.maxChannel());

    // Lightness = (max + min) / 2 = (128 + 10) / 2 = 69
    try std.testing.expectEqual(@as(u8, 69), c.lightness());

    try std.testing.expectEqual(@as(u8, 255), ColorRgba.white.maxChannel());
    try std.testing.expectEqual(@as(u8, 255), ColorRgba.white.lightness());

    try std.testing.expectEqual(@as(u8, 0), ColorRgba.black.maxChannel());
    try std.testing.expectEqual(@as(u8, 0), ColorRgba.black.lightness());
}

test "brightness" {
    try std.testing.expectEqual(@as(u8, 255), ColorRgba.white.brightness());
    try std.testing.expectEqual(@as(u8, 0), ColorRgba.black.brightness());

    // sqrt((255^2 * 150) >> 8) = 195
    try std.testing.expectEqual(@as(u8, 195), ColorRgba.init(0, 255, 0, 255).brightness());
}

test "opacity checks" {
    try std.testing.expect(ColorRgba.white.isOpaque());
    try std.testing.expect(!ColorRgba.white.isTransparent());

    const trans = ColorRgba.init(0, 0, 0, 0);
    try std.testing.expect(trans.isTransparent());
    try std.testing.expect(!trans.isOpaque());

    const partial = ColorRgba.init(0, 0, 0, 128);
    try std.testing.expect(!partial.isOpaque());
    try std.testing.expect(!partial.isTransparent());
}

test "invert and grayscale" {
    const c = ColorRgba.init(50, 100, 150, 200);

    const inv = c.invert();
    try std.testing.expectEqual(@as(u8, 205), inv.channels.r);
    try std.testing.expectEqual(@as(u8, 155), inv.channels.g);
    try std.testing.expectEqual(@as(u8, 105), inv.channels.b);
    try std.testing.expectEqual(@as(u8, 200), inv.channels.a);

    const gray = c.toGrayscale();
    const l = c.luminance();
    try std.testing.expectEqual(l, gray.channels.r);
    try std.testing.expectEqual(l, gray.channels.g);
    try std.testing.expectEqual(l, gray.channels.b);
    try std.testing.expectEqual(@as(u8, 200), gray.channels.a);
}

test "composite_over" {
    const bg = ColorRgba.init(255, 0, 0, 255); // Solid red
    const fg = ColorRgba.init(0, 0, 255, 127); // Semi-transparent blue

    const blended = bg.compositeOver(fg);
    try std.testing.expectEqual(@as(u8, 128), blended.channels.r);
    try std.testing.expectEqual(@as(u8, 0), blended.channels.g);
    try std.testing.expectEqual(@as(u8, 127), blended.channels.b);
    try std.testing.expectEqual(@as(u8, 255), blended.channels.a);

    // Solid foreground over solid background
    const fg_solid = ColorRgba.init(0, 255, 0, 255);
    const blended_solid = bg.compositeOver(fg_solid);
    try std.testing.expectEqual(fg_solid.channels.r, blended_solid.channels.r);
    try std.testing.expectEqual(fg_solid.channels.g, blended_solid.channels.g);
    try std.testing.expectEqual(fg_solid.channels.b, blended_solid.channels.b);
    try std.testing.expectEqual(fg_solid.channels.a, blended_solid.channels.a);

    // Foreground over transparent background
    const bg_transparent = ColorRgba.init(0, 0, 0, 0);
    const blended_over_transparent = bg_transparent.compositeOver(fg_solid);
    try std.testing.expectEqual(fg_solid.channels.r, blended_over_transparent.channels.r);
}

test "with_alpha and average" {
    const c1 = ColorRgba.white;
    const c2 = c1.withAlpha(128);
    try std.testing.expectEqual(@as(u8, 255), c2.channels.r);
    try std.testing.expectEqual(@as(u8, 128), c2.channels.a);

    const a1 = ColorRgba.init(10, 20, 30, 40);
    const a2 = ColorRgba.init(30, 40, 50, 60);
    const avg = a1.average(a2);
    try std.testing.expectEqual(@as(u8, 20), avg.channels.r);
    try std.testing.expectEqual(@as(u8, 30), avg.channels.g);
    try std.testing.expectEqual(@as(u8, 40), avg.channels.b);
    try std.testing.expectEqual(@as(u8, 50), avg.channels.a);
}
