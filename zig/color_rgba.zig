//! Handles colors, containing ColorRGBA struct and its tests.
const std = @import("std");
const builtin = @import("builtin");

/// Represents a color. Note that WebGPU processes colors as rgba16float;
/// this data is used to determine similarity of blocks and is not color-space compliant.
pub const ColorRGBA = extern union {
    /// Single-word access for quick equality checks.
    word: u32,
    /// SIMD-ready vector access. Subject to different values based on endianness.
    v: @Vector(4, u8),
    /// Access individual RGBA components through channels.
    channels: extern struct {
        /// Red component of color (0-255).
        r: u8 = 0,
        /// Green component of color (0-255).
        g: u8 = 0,
        /// Blue component of color (0-255).
        b: u8 = 0,
        /// Alpha component of color (0-255).
        a: u8 = 0,
    },

    // Fully opaque white.
    pub const white = ColorRGBA{ .channels = .{ .r = 255, .g = 255, .b = 255, .a = 255 } };
    // Fully opaque black.
    pub const black = ColorRGBA{ .channels = .{ .r = 0, .g = 0, .b = 0, .a = 255 } };

    /// Returns (R+G+B) / 3
    pub fn luminance(self: ColorRGBA) u8 {
        // Scaled weights to 256 (approximate)
        const weights = @Vector(4, u32){ 54, 183, 19, 0 };
        const v_u32: @Vector(4, u32) = self.v;
        const weighted = v_u32 * weights;

        return @intCast(@reduce(.Add, weighted) >> 8);
    }

    /// Interpolates two colors linearly.
    pub inline fn mix(self: ColorRGBA, other: ColorRGBA, t: f32) ColorRGBA {
        const amt: u16 = @intFromFloat(@round(t * 256.0));
        const rev: u16 = 256 - amt;

        // Perform math in vector space to prevent component-to-component bleed
        const v1: @Vector(4, u16) = self.v;
        const v2: @Vector(4, u16) = other.v;

        const mixed = (v1 * @as(@Vector(4, u16), @splat(rev)) + v2 * @as(@Vector(4, u16), @splat(amt))) >> @as(@Vector(4, u16), @splat(8));

        return .{ .v = @intCast(mixed) };
    }

    /// Determines similarity between two colors.
    pub fn get_color_distance(color_1: ColorRGBA, color_2: ColorRGBA) f32 {
        const v1: @Vector(4, f32) = @floatFromInt(color_1.v);
        const v2: @Vector(4, f32) = @floatFromInt(color_2.v);

        const diff = v1 - v2;
        const dist_sq = diff * diff;

        const r_mean = (v1[0] + v2[0]) / 2.0;

        const weight_r = 2.0 + (r_mean / 256.0);
        const weight_g = 4.0;
        const weight_b = 2.0 + ((255.0 - r_mean) / 256.0);

        return (weight_r * dist_sq[0]) + (weight_g * dist_sq[1]) + (weight_b * dist_sq[2]);
    }

    pub fn eql(self: ColorRGBA, other: ColorRGBA) bool {
        return self.word == other.word;
    }

    /// Hue in degrees [0, 360). Returns 0 for achromatic colors.
    pub fn hue(self: ColorRGBA) u16 {
        const r: i32 = self.channels.r;
        const g: i32 = self.channels.g;
        const b: i32 = self.channels.b;
        const max_c = @max(r, @max(g, b));
        const min_c = @min(r, @min(g, b));
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
    pub fn saturation(self: ColorRGBA) u8 {
        const max_c = @max(self.channels.r, @max(self.channels.g, self.channels.b));
        const min_c = @min(self.channels.r, @min(self.channels.g, self.channels.b));
        if (max_c == 0) return 0;
        return @intCast((@as(u16, max_c - min_c) * 255) / @as(u16, max_c));
    }

    /// Value (HSV) — simply the maximum channel.
    pub fn max_channel(self: ColorRGBA) u8 {
        const rgb = @as(@Vector(4, u8), self.v) * @Vector(4, u8){ 1, 1, 1, 0 };
        return @reduce(.Max, rgb);
    }

    /// Lightness (HSL) — average of max and min channels.
    pub fn lightness(self: ColorRGBA) u8 {
        const max_c = @max(self.channels.r, @max(self.channels.g, self.channels.b));
        const min_c = @min(self.channels.r, @min(self.channels.g, self.channels.b));
        return @intCast((@as(u16, max_c) + min_c) / 2);
    }

    /// Perceived brightness using sRGB-approximate formula.
    /// Faster than luminance(), uses sqrt approximation.
    pub fn brightness(self: ColorRGBA) u8 {
        // sqrt(0.299*R² + 0.587*G² + 0.114*B²), integer approx
        const v_wide: @Vector(4, u32) = self.v;
        const v_sq = v_wide * v_wide;
        // weights: 77/256 ≈ 0.299, 150/256 ≈ 0.587, 29/256 ≈ 0.114
        const weights = @Vector(4, u32){ 77, 150, 29, 0 };
        const weighted = @reduce(.Add, v_sq * weights) >> 8;
        return @intCast(std.math.sqrt(weighted));
    }

    /// Is fully opaque?
    pub fn isOpaque(self: ColorRGBA) bool {
        return self.channels.a == 255;
    }

    /// Is fully transparent?
    pub fn isTransparent(self: ColorRGBA) bool {
        return self.channels.a == 0;
    }

    /// Invert RGB, keep alpha.
    pub fn invert(self: ColorRGBA) ColorRGBA {
        var res = ColorRGBA{ .v = @as(@Vector(4, u8), @splat(255)) - self.v };
        res.channels.a = self.channels.a;
        return res;
    }

    /// Convert to grayscale using luminance, keep alpha.
    pub fn toGrayscale(self: ColorRGBA) ColorRGBA {
        const l = self.luminance();
        return .{ .channels = .{ .r = l, .g = l, .b = l, .a = self.channels.a } };
    }

    /// Alpha-composite src over self (Porter-Duff "over" operator).
    pub fn compositeOver(self: ColorRGBA, src: ColorRGBA) ColorRGBA {
        const sa: u32 = src.channels.a;
        const da: u32 = self.channels.a;
        const inv_sa: u32 = 255 - sa;

        const out_a = sa + ((da * inv_sa) / 255);
        if (out_a == 0) return .{ .word = 0 };

        return .{
            .channels = .{
                .r = @intCast((src.channels.r * sa + (self.channels.r * da * inv_sa) / 255) / out_a),
                .g = @intCast((src.channels.g * sa + (self.channels.g * da * inv_sa) / 255) / out_a),
                .b = @intCast((src.channels.b * sa + (self.channels.b * da * inv_sa) / 255) / out_a),
                .a = @intCast(out_a),
            },
        };
    }

    /// Return color with modified alpha.
    pub fn withAlpha(self: ColorRGBA, a: u8) ColorRGBA {
        var res = self;
        res.channels.a = a;
        return res;
    }

    /// Simple average of two colors (no alpha weighting).
    pub fn average(self: ColorRGBA, other: ColorRGBA) ColorRGBA {
        const v1: @Vector(4, u16) = self.v;
        const v2: @Vector(4, u16) = other.v;
        const avg = (v1 + v2) >> @as(@Vector(4, u16), @splat(1));
        return .{ .v = @intCast(avg) };
    }

    /// Converts a comptime hex code into a ColorRGBA (as #ffffff or #ffffffff)
    pub fn fromHex(comptime html_hex: []const u8) ColorRGBA {
        const hex = if (html_hex[0] == '#') html_hex[1..] else html_hex;

        if (hex.len != 6 and hex.len != 8) {
            @compileError("Hex string must be 6 or 8 characters (excluding #)");
        }

        // parse RGB components
        const r = std.fmt.parseInt(u8, hex[0..2], 16) catch unreachable;
        const g = std.fmt.parseInt(u8, hex[2..4], 16) catch unreachable;
        const b = std.fmt.parseInt(u8, hex[4..6], 16) catch unreachable;

        const a = if (hex.len == 8) // parse alpha
            std.fmt.parseInt(u8, hex[6..8], 16) catch unreachable
        else
            255;

        return .{ .channels = .{ .r = r, .g = g, .b = b, .a = a } };
    }
};

test "ColorRGBA fromHex" {
    // Standard 6-character hex (no #)
    const c1 = comptime ColorRGBA.fromHex("123456");
    try std.testing.expectEqual(@as(u8, 0x12), c1.channels.r);
    try std.testing.expectEqual(@as(u8, 0x34), c1.channels.g);
    try std.testing.expectEqual(@as(u8, 0x56), c1.channels.b);
    try std.testing.expectEqual(@as(u8, 255), c1.channels.a);

    // 6-character hex
    const c2 = comptime ColorRGBA.fromHex("#ff0000");
    try std.testing.expectEqual(@as(u8, 255), c2.channels.r);
    try std.testing.expectEqual(@as(u8, 0), c2.channels.g);
    try std.testing.expectEqual(@as(u8, 0), c2.channels.b);
    try std.testing.expectEqual(@as(u8, 255), c2.channels.a);

    // 8-character hex
    const c3 = comptime ColorRGBA.fromHex("#00fF0080");
    try std.testing.expectEqual(@as(u8, 0), c3.channels.r);
    try std.testing.expectEqual(@as(u8, 255), c3.channels.g);
    try std.testing.expectEqual(@as(u8, 0), c3.channels.b);
    try std.testing.expectEqual(@as(u8, 128), c3.channels.a);

    // Standard black and white hex strings against constants
    const white = comptime ColorRGBA.fromHex("#fFfFfF");
    try std.testing.expect(white.eql(ColorRGBA.white));

    const black = comptime ColorRGBA.fromHex("000000");
    try std.testing.expect(black.eql(ColorRGBA.black));
}

test "ColorRGBA color modification" {
    // A color equal to rgb(8, 240, 0).
    var test_color = comptime ColorRGBA.fromHex("#08f000");
    test_color.channels.a -|= 16; // saturating subtraction
    try std.testing.expectEqual(test_color.channels.a, 0xef);

    try std.testing.expectEqual(test_color.channels.r, 0x08);
    test_color.channels.r -|= 12;
    try std.testing.expectEqual(test_color.channels.r, 0x00);

    try std.testing.expectEqual(test_color.channels.g, 0xf0);
    test_color.channels.g +|= 3; // saturating addition
    try std.testing.expectEqual(test_color.channels.g, 0xf3);
    test_color.channels.g +|= 16;
    try std.testing.expectEqual(test_color.channels.g, 0xff);
}

test "ColorRGBA perceptual luminance" {
    const pure_green = ColorRGBA{ .channels = .{ .r = 0, .g = 255, .b = 0, .a = 255 } };
    const pure_blue = ColorRGBA{ .channels = .{ .r = 0, .g = 0, .b = 255, .a = 255 } };

    const lum_g = pure_green.luminance();
    const lum_b = pure_blue.luminance();

    try std.testing.expect(lum_g > lum_b * 9);
}

test "ColorRGBA luminance calculation" {
    const grey = ColorRGBA{ .channels = .{ .r = 100, .g = 100, .b = 100, .a = 255 } };
    try std.testing.expectEqual(@as(u8, 100), grey.luminance());

    const black = ColorRGBA.black;
    try std.testing.expectEqual(@as(u8, 0), black.luminance());

    const custom = ColorRGBA{ .channels = .{ .r = 10, .g = 20, .b = 30, .a = 255 } };
    try std.testing.expectEqual(@as(u8, 18), custom.luminance());
}

test "ColorRGBA mix interpolation" {
    const red = ColorRGBA{ .channels = .{ .r = 255, .g = 0, .b = 0, .a = 255 } };
    const blue = ColorRGBA{ .channels = .{ .r = 0, .g = 0, .b = 255, .a = 255 } };

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

test "ColorRGBA color distance" {
    const c1 = ColorRGBA{ .channels = .{ .r = 255, .g = 0, .b = 0, .a = 255 } };
    const c2 = ColorRGBA{ .channels = .{ .r = 255, .g = 0, .b = 0, .a = 255 } };
    // Distance to self should ALWAYS be 0
    try std.testing.expectApproxEqAbs(0.0, ColorRGBA.get_color_distance(c1, c2), 0.001);
    const c3 = ColorRGBA{ .channels = .{ .r = 0, .g = 0, .b = 0, .a = 255 } };
    const dist = ColorRGBA.get_color_distance(c1, c3);

    // Distance should be quite large here
    try std.testing.expect(dist > 100000.0 and dist < 1000000.0);
}

test "ColorRGBA packed layout integrity" {
    // Ensure bitCast works as expected for your mix function logic
    const color = ColorRGBA{ .channels = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } };
    const as_u32: u32 = color.word;

    if (builtin.cpu.arch.endian() == .little) {
        try std.testing.expectEqual(@as(u32, 0xDDCCBBAA), as_u32);
    } else {
        // Expect little-endian.
        unreachable;
    }
}

test "ColorRGBA eql" {
    const c1 = ColorRGBA{ .channels = .{ .r = 10, .g = 20, .b = 30, .a = 40 } };
    const c2 = ColorRGBA{ .channels = .{ .r = 10, .g = 20, .b = 30, .a = 40 } };
    const c3 = ColorRGBA{ .channels = .{ .r = 11, .g = 20, .b = 30, .a = 40 } };

    try std.testing.expect(c1.eql(c2));
    try std.testing.expect(!c1.eql(c3));
}

test "ColorRGBA hue" {
    // Primary / Secondary colors
    try std.testing.expectEqual(@as(u16, 0), (ColorRGBA{ .channels = .{ .r = 255, .g = 0, .b = 0, .a = 255 } }).hue());
    try std.testing.expectEqual(@as(u16, 120), (ColorRGBA{ .channels = .{ .r = 0, .g = 255, .b = 0, .a = 255 } }).hue());
    try std.testing.expectEqual(@as(u16, 240), (ColorRGBA{ .channels = .{ .r = 0, .g = 0, .b = 255, .a = 255 } }).hue());
    try std.testing.expectEqual(@as(u16, 60), (ColorRGBA{ .channels = .{ .r = 255, .g = 255, .b = 0, .a = 255 } }).hue()); // Yellow
    try std.testing.expectEqual(@as(u16, 300), (ColorRGBA{ .channels = .{ .r = 255, .g = 0, .b = 255, .a = 255 } }).hue()); // Magenta

    // Achromatic colors should return 0
    try std.testing.expectEqual(@as(u16, 0), ColorRGBA.white.hue());
    try std.testing.expectEqual(@as(u16, 0), ColorRGBA.black.hue());
}

test "ColorRGBA saturation" {
    try std.testing.expectEqual(@as(u8, 255), (ColorRGBA{ .channels = .{ .r = 255, .g = 0, .b = 0, .a = 255 } }).saturation());
    try std.testing.expectEqual(@as(u8, 0), ColorRGBA.white.saturation());
    try std.testing.expectEqual(@as(u8, 0), ColorRGBA.black.saturation());

    // Max is 200, Min is 100. Saturation = (100 * 255) / 200 = 127.5 -> truncated to 127
    try std.testing.expectEqual(@as(u8, 127), (ColorRGBA{ .channels = .{ .r = 200, .g = 100, .b = 100, .a = 255 } }).saturation());
}

test "ColorRGBA value and lightness" {
    const c = ColorRGBA{ .channels = .{ .r = 50, .g = 128, .b = 10, .a = 255 } };

    // Value = max channel
    try std.testing.expectEqual(@as(u8, 128), c.max_channel());

    // Lightness = (max + min) / 2 = (128 + 10) / 2 = 69
    try std.testing.expectEqual(@as(u8, 69), c.lightness());

    try std.testing.expectEqual(@as(u8, 255), ColorRGBA.white.max_channel());
    try std.testing.expectEqual(@as(u8, 255), ColorRGBA.white.lightness());

    try std.testing.expectEqual(@as(u8, 0), ColorRGBA.black.max_channel());
    try std.testing.expectEqual(@as(u8, 0), ColorRGBA.black.lightness());
}

test "ColorRGBA brightness" {
    try std.testing.expectEqual(@as(u8, 255), ColorRGBA.white.brightness());
    try std.testing.expectEqual(@as(u8, 0), ColorRGBA.black.brightness());

    // Pure green: sqrt((255^2 * 150) >> 8) = sqrt(38100) = 195.19 -> 195
    try std.testing.expectEqual(@as(u8, 195), (ColorRGBA{ .channels = .{ .r = 0, .g = 255, .b = 0, .a = 255 } }).brightness());
}

test "ColorRGBA opacity checks" {
    try std.testing.expect(ColorRGBA.white.isOpaque());
    try std.testing.expect(!ColorRGBA.white.isTransparent());

    const trans = ColorRGBA{ .channels = .{ .r = 0, .g = 0, .b = 0, .a = 0 } };
    try std.testing.expect(trans.isTransparent());
    try std.testing.expect(!trans.isOpaque());

    const partial = ColorRGBA{ .channels = .{ .r = 0, .g = 0, .b = 0, .a = 128 } };
    try std.testing.expect(!partial.isOpaque());
    try std.testing.expect(!partial.isTransparent());
}

test "ColorRGBA invert and toGrayscale" {
    const c = ColorRGBA{ .channels = .{ .r = 50, .g = 100, .b = 150, .a = 200 } };

    const inv = c.invert();
    try std.testing.expectEqual(@as(u8, 205), inv.channels.r);
    try std.testing.expectEqual(@as(u8, 155), inv.channels.g);
    try std.testing.expectEqual(@as(u8, 105), inv.channels.b);
    try std.testing.expectEqual(@as(u8, 200), inv.channels.a); // Alpha must be maintained

    const grey = c.toGrayscale();
    const l = c.luminance();
    try std.testing.expectEqual(l, grey.channels.r);
    try std.testing.expectEqual(l, grey.channels.g);
    try std.testing.expectEqual(l, grey.channels.b);
    try std.testing.expectEqual(@as(u8, 200), grey.channels.a); // Alpha must be maintained
}

test "ColorRGBA compositeOver" {
    const bg = ColorRGBA{ .channels = .{ .r = 255, .g = 0, .b = 0, .a = 255 } }; // Solid red
    const fg = ColorRGBA{ .channels = .{ .r = 0, .g = 0, .b = 255, .a = 127 } }; // Semi-transparent blue

    const blended = bg.compositeOver(fg);
    try std.testing.expectEqual(@as(u8, 128), blended.channels.r);
    try std.testing.expectEqual(@as(u8, 0), blended.channels.g);
    try std.testing.expectEqual(@as(u8, 127), blended.channels.b);
    try std.testing.expectEqual(@as(u8, 255), blended.channels.a);

    // Solid foreground over solid background
    const fg_solid = ColorRGBA{ .channels = .{ .r = 0, .g = 255, .b = 0, .a = 255 } };
    const blended_solid = bg.compositeOver(fg_solid);
    try std.testing.expectEqual(fg_solid.channels.r, blended_solid.channels.r);
    try std.testing.expectEqual(fg_solid.channels.g, blended_solid.channels.g);
    try std.testing.expectEqual(fg_solid.channels.b, blended_solid.channels.b);
    try std.testing.expectEqual(fg_solid.channels.a, blended_solid.channels.a);

    // Foreground over transparent background
    const bg_transparent = ColorRGBA{ .channels = .{ .r = 0, .g = 0, .b = 0, .a = 0 } };
    const blended_over_transparent = bg_transparent.compositeOver(fg_solid);
    try std.testing.expectEqual(fg_solid.channels.r, blended_over_transparent.channels.r);
}

test "ColorRGBA withAlpha and average" {
    const c1 = ColorRGBA.white;
    const c2 = c1.withAlpha(128);
    try std.testing.expectEqual(@as(u8, 255), c2.channels.r);
    try std.testing.expectEqual(@as(u8, 128), c2.channels.a);

    const a1 = ColorRGBA{ .channels = .{ .r = 10, .g = 20, .b = 30, .a = 40 } };
    const a2 = ColorRGBA{ .channels = .{ .r = 30, .g = 40, .b = 50, .a = 60 } };
    const avg = a1.average(a2);
    try std.testing.expectEqual(@as(u8, 20), avg.channels.r);
    try std.testing.expectEqual(@as(u8, 30), avg.channels.g);
    try std.testing.expectEqual(@as(u8, 40), avg.channels.b);
    try std.testing.expectEqual(@as(u8, 50), avg.channels.a);
}
