//! Handles entities and stores functions relating on how to add them.
const std = @import("std");
const dw = @import("../root.zig");
const SegmentedList = dw.SegmentedList;
const memory = dw.memory;
const sprite = dw.sprite;
const ColorRgba = dw.ColorRgba;
const inventory = dw.inventory;

const CHUNK_SIZE = dw.CHUNK_SIZE;
const Entity = memory.Entity;
const WGSLEntity = memory.WGSLEntity;
const Vec2f32 = dw.utils.Vec2f32;

const NUMBER_START = sprite.NUMBER_START;
const CHARACTER_START = NUMBER_START + 10;

/// Scale of tiles in the small chunk preview.
pub var preview_tile_size: f64 = 0.0;

/// Extra spacing between number characters.
const spacing = 0.25;
/// Pre-calculated widths of every number sprite from 0 to 9.
const NUMBER_WIDTHS: [10]f32 = .{
    0.5625 + spacing,
    0.375 + spacing,
    0.5625 + spacing,
    0.5625 + spacing,
    0.75 + spacing,
    0.5625 + spacing,
    0.5625 + spacing,
    0.5625 + spacing,
    0.5625 + spacing,
    0.5625 + spacing,
};

/// List of monospace characters starting from
const MONOSPACE_CHARS = "!\"%$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz(|)~";
/// Width of each character relative to the font size (6/16).
const CHARACTER_WIDTH_FRACTION: f32 = 6.0 / 16.0;

/// Current number of entities (reset every frame).
pub var entity_count: u64 = 0;

/// Updates all entities by adding them to the scratch buffer. Does not actually inform JS by calling `handleVisibleEntities()`.
/// Every entity needs a position, size, rotation, LCHA, and sprite associated with it.
/// Some properties are optional with defaults (size, rotation, LCHA).
pub fn updateEntities(time_diff: f64) void {
    memory.scratchReset();
    // we're doing a new pass of drawing entities, clear anything before
    entity_count = 0;

    inventory.addDroppedItemsAsEntities(time_diff); // pass in delta time in ms

    // The player is a world-space entity (see render/chunk.zig for its grid-aligned position).
    dw.player.drawPlayerEntity();

    // advance and draw particles (under all UI overlays)
    dw.particles.draw();

    // draw indicators (icons above certain sprites)
    dw.indicators.drawIndicators();
    @import("../menus/furnace.zig").draw();
    @import("../menus/corecraft.zig").draw();
    @import("../menus/loot.zig").draw();

    // draw the inventory items/all items if in creative
    inventory.drawInventory(time_diff);

    // update mouse type logic and reset for next render frame
    dw.render.dispatchMouseType();
    dw.mouse.cursor_type = .initial;
    dw.mouse.clearFrameFlags();

    // draw chunk preview at the front
    if (dw.is_debug and preview_tile_size > 0.0) {
        dw.chunk_preview.drawChunkPreview();
    }

    const blocks_mined = memory.game.blocks_mined;

    // draw progress bar of mined block count
    // const width = 40;
    // dw.progress.drawBar(
    //     width,
    //     @min(blocks_mined, 40),
    //     .{ 0.04, 0.01 },
    //     0.4,
    //     .top_left_uv,
    //     .{ 1.0, 0.1, -1.3, 1.0 }, // high chroma, starts from pink/red
    // );

    // also draw string showing progress
    // draws info on # of chunks and data usage

    var buf: [128]u8 = undefined;
    const store = &dw.world.mod_store;

    const msg = if (dw.is_debug)
        std.fmt.bufPrint(
            &buf,
            "{d} block{s} mined | mods: {d} chunk{s} / {d:.2}KB",
            .{
                blocks_mined,
                if (blocks_mined == 1) "" else "s",
                store.index.count(),
                if (store.index.count() == 1) "" else "s",
                @as(f64, @floatFromInt(store.cellBytes())) / 1000.0,
            },
        ) catch unreachable
    else
        std.fmt.bufPrint(
            &buf,
            "{d} block{s} mined",
            .{ blocks_mined, if (blocks_mined == 1) "" else "s" },
        ) catch unreachable;

    dw.entity.drawString(msg, .{ 19.5, 8.5 }, .{
        .font_size = 7.5,
        .lcha = .{ 0.45, 0.04, 1.8, 1.0 },
    });
    dw.entity.drawString(msg, .{ 20.0, 9.0 }, .{
        .font_size = 7.5,
        .lcha = .{ 0.85, 0.08, 1.8, 1.0 },
    });

    memory.setScratchProp(0, entity_count);
    // entity rendering is dispatched to JS right after this function completes
}

/// Configuration for drawing a number.
pub const TextConfig = struct {
    /// The light, chroma, hue, and opacity components (HSL + alpha).
    /// L (lightness) and alpha components are multiplied by the sprite's color in WebGPU.
    /// H (hue, in radians) and C (chroma) are shifted additively.
    lcha: dw.utils.Vec4f32 = memory.DEFAULT_ENTITY_LCHA,
    /// The font size of the text.
    font_size: f32 = 16.0,
    /// The rotation of the text.
    rotation: f32 = 0.0,
    /// Whether text is rendered from left-to-right (defaults to true; as in, left-aligned text).
    ltr: bool = true,
};

/// Draws an unsigned integer by creating entities; should NEVER be called outside of `updateEntities()`.
pub fn drawNumber(
    number: u64,
    position: Vec2f32,
    options: TextConfig,
) void {
    const lcha = options.lcha;
    const font_size = options.font_size;
    const rotation = options.rotation;
    const ltr = options.ltr;

    // Fast path for zero-rotation cases
    if (rotation == 0.0) {
        drawNumberFast(number, position, options);
        return;
    }

    if (number == 0) {
        addEntity(.{
            .sprite = @enumFromInt(NUMBER_START),
            .lcha = lcha,
            .position = position,
            .size = font_size,
            .rotation = rotation,
        });
        return;
    }

    var digits: [20]u8 = undefined;
    var count: usize = 0;
    var n = number;

    while (n > 0) : (n /= 10) {
        digits[count] = @intCast(n % 10);
        count += 1;
    }

    // Precompute trig for the entire string
    const cos_r = @cos(rotation);
    const sin_r = @sin(rotation);

    // Track the relative X offset from the pivot point
    var rel_x: f32 = 0.0;

    if (ltr) {
        // Initial shift for LTR logic
        rel_x -= NUMBER_WIDTHS[@intCast(digits[count - 1])] * font_size;

        var i: usize = count;
        while (i > 0) {
            i -= 1;
            const digit = digits[i];
            rel_x += NUMBER_WIDTHS[@intCast(digit)] * font_size;

            // Rotate the relative offset vector (rel_x, 0)
            const rotated_offset: Vec2f32 = .{ rel_x * cos_r, rel_x * sin_r };

            addEntity(.{
                .sprite = @enumFromInt(NUMBER_START + digit),
                .lcha = lcha,
                .position = position + rotated_offset,
                .size = font_size,
                .rotation = rotation,
            });
        }
    } else {
        for (digits[0..count]) |digit| {
            const rotated_offset: Vec2f32 = .{ rel_x * cos_r, rel_x * sin_r };

            addEntity(.{
                .sprite = @enumFromInt(NUMBER_START + digit),
                .lcha = lcha,
                .position = position + rotated_offset,
                .size = font_size,
                .rotation = rotation,
            });
            rel_x -= NUMBER_WIDTHS[@intCast(digit)] * font_size;
        }
    }
}

/// Optimized version of draw_number for when rotation is exactly 0.
fn drawNumberFast(number: u64, position: Vec2f32, options: TextConfig) void {
    std.debug.assert(options.rotation == 0);
    const lcha = options.lcha;
    const font_size = options.font_size;
    const ltr = options.ltr;

    if (number == 0) {
        addEntity(.{
            .sprite = @enumFromInt(NUMBER_START),
            .lcha = lcha,
            .position = position,
            .size = font_size,
        });
        return;
    }

    var digits: [20]u8 = undefined;
    var count: usize = 0;
    var n = number;

    while (n > 0) : (n /= 10) {
        digits[count] = @intCast(n % 10);
        count += 1;
    }

    var current_pos = position;

    if (ltr) {
        current_pos[0] -= NUMBER_WIDTHS[@intCast(digits[count - 1])] * font_size;
        var i: usize = count;
        while (i > 0) {
            i -= 1;
            const digit = digits[i];
            current_pos[0] += NUMBER_WIDTHS[@intCast(digit)] * font_size;

            addEntity(.{
                .sprite = @enumFromInt(NUMBER_START + digit),
                .lcha = lcha,
                .position = current_pos,
                .size = font_size,
            });
        }
    } else {
        for (digits[0..count]) |digit| {
            addEntity(.{
                .sprite = @enumFromInt(NUMBER_START + digit),
                .lcha = lcha,
                .position = current_pos,
                .size = font_size,
            });
            current_pos[0] -= NUMBER_WIDTHS[@intCast(digit)] * font_size;
        }
    }
}

/// A compile-time lookup table mapping ASCII characters to their index in `MONOSPACE_CHARS`.
/// `-1` represents an invalid character.
/// `-2` represents a space character (valid but skipped during rendering).
const CHAR_MAP: [256]i16 = blk: {
    @setEvalBranchQuota(2000);
    var map = [_]i16{-1} ** 256;
    map[' '] = -2;
    for (MONOSPACE_CHARS, 0..) |char, index| {
        map[char] = @intCast(index);
    }
    break :blk map;
};

/// Draws a single monospace character.
pub fn drawCharacter(
    char: u8,
    position: Vec2f32,
    options: TextConfig,
) void {
    const char_index = CHAR_MAP[char];
    std.debug.assert(char_index != -1);

    if (char_index == -2) {
        return;
    }

    const sprite_id: u32 = CHARACTER_START + @as(u32, @intCast(char_index));
    addEntity(.{
        .sprite = @enumFromInt(sprite_id),
        .lcha = options.lcha,
        .position = position,
        .size = options.font_size,
        .rotation = options.rotation,
    });
}

/// Draws a single-line monospace string with rotation and LTR/RTL support.
/// Fast-paths to `drawStringFast()` if there is no rotation.
pub fn drawString(
    string: []const u8,
    position: Vec2f32,
    options: TextConfig,
) void {
    if (string.len == 0) return;

    if (options.rotation == 0.0) {
        drawStringFast(string, position, options);
        return;
    }

    const font_size = options.font_size;
    const rotation = options.rotation;
    const ltr = options.ltr;
    const char_advance = CHARACTER_WIDTH_FRACTION * font_size;

    const cos_r = @cos(rotation);
    const sin_r = @sin(rotation);

    var rel_x: f32 = 0.0;

    if (ltr) {
        for (string) |char| {
            const char_index = CHAR_MAP[char];
            std.debug.assert(char_index != -1);

            if (char_index != -2) {
                const rotated_offset: Vec2f32 = .{ rel_x * cos_r, rel_x * sin_r };
                const sprite_id: u32 = CHARACTER_START + @as(u32, @intCast(char_index));
                addEntity(.{
                    .sprite = @enumFromInt(sprite_id),
                    .lcha = options.lcha,
                    .position = position + rotated_offset,
                    .size = font_size,
                    .rotation = rotation,
                });
            }
            rel_x += char_advance;
        }
    } else {
        var i: usize = string.len;
        while (i > 0) {
            i -= 1;
            const char = string[i];
            const char_index = CHAR_MAP[char];
            std.debug.assert(char_index != -1);

            if (char_index != -2) {
                const rotated_offset: Vec2f32 = .{ rel_x * cos_r, rel_x * sin_r };
                const sprite_id: u32 = CHARACTER_START + @as(u32, @intCast(char_index));
                addEntity(.{
                    .sprite = @enumFromInt(sprite_id),
                    .lcha = options.lcha,
                    .position = position + rotated_offset,
                    .size = font_size,
                    .rotation = rotation,
                });
            }
            rel_x -= char_advance;
        }
    }
}

/// Optimized drawer for single-line strings when rotation is exactly 0.
fn drawStringFast(
    string: []const u8,
    position: Vec2f32,
    options: TextConfig,
) void {
    std.debug.assert(options.rotation == 0.0);
    const font_size = options.font_size;
    const ltr = options.ltr;
    const char_advance = CHARACTER_WIDTH_FRACTION * font_size;

    var current_pos = position;

    if (ltr) {
        for (string) |char| {
            const char_index = CHAR_MAP[char];
            std.debug.assert(char_index != -1);

            if (char_index != -2) {
                const sprite_id: u32 = CHARACTER_START + @as(u32, @intCast(char_index));
                addEntity(.{
                    .sprite = @enumFromInt(sprite_id),
                    .lcha = options.lcha,
                    .position = current_pos,
                    .size = font_size,
                });
            }
            current_pos[0] += char_advance;
        }
    } else {
        var i: usize = string.len;
        while (i > 0) {
            i -= 1;
            const char = string[i];
            const char_index = CHAR_MAP[char];
            std.debug.assert(char_index != -1);

            if (char_index != -2) {
                const sprite_id: u32 = CHARACTER_START + @as(u32, @intCast(char_index));
                addEntity(.{
                    .sprite = @enumFromInt(sprite_id),
                    .lcha = options.lcha,
                    .position = current_pos,
                    .size = font_size,
                });
            }
            current_pos[0] -= char_advance;
        }
    }
}

/// Configuration for `drawStringWave()`: a horizontally laid-out string whose glyphs ripple
/// vertically and transition colors toward the end.
pub const WaveConfig = struct {
    /// Base OKLCH+alpha tint of the leftmost glyph.
    starting_lcha: dw.utils.Vec4f32 = memory.DEFAULT_ENTITY_LCHA,
    /// Target OKLCH+alpha tint reached at the final glyph, ramped linearly from `lcha`.
    ending_lcha: dw.utils.Vec4f32 = memory.DEFAULT_ENTITY_LCHA,
    /// The font size of the text.
    font_size: f32 = 16.0,
    /// Traveling-wave phase in radians; advance it over time to animate the ripple.
    phase: f32 = 0.0,
    /// Peak vertical displacement in viewport px (0 disables the ripple).
    amplitude: f32 = 0.0,
    /// Radians of phase added per glyph, setting the wavelength of the ripple.
    wave_step: f32 = 0.6,
};

/// Draws a left-to-right monospace string whose characters ride a vertical sine ripple with gradient effect.
/// Used for the selected-item name; never rotates.
pub fn drawStringWave(
    string: []const u8,
    position: Vec2f32,
    config: WaveConfig,
) void {
    if (string.len == 0) return;
    const char_advance = CHARACTER_WIDTH_FRACTION * config.font_size;
    const last: f32 = @floatFromInt(@max(string.len - 1, 1));

    var current_x = position[0];
    for (string, 0..) |char, i| {
        const char_index = CHAR_MAP[char];
        std.debug.assert(char_index != -1);

        if (char_index != -2) {
            const frac = @as(f32, @floatFromInt(i)) / last;

            // Linearly interpolate each channel (L, C, H, A) from config.lcha to config.ending_lcha
            var lcha: dw.utils.Vec4f32 = undefined;
            inline for (0..4) |j| {
                lcha[j] = config.starting_lcha[j] + (config.ending_lcha[j] - config.starting_lcha[j]) * frac;
            }

            const y = position[1] + config.amplitude *
                @sin(config.phase + config.wave_step * @as(f32, @floatFromInt(i)));

            addEntity(.{
                .sprite = @enumFromInt(CHARACTER_START + @as(u32, @intCast(char_index))),
                .lcha = lcha,
                .position = .{ current_x, y },
                .size = config.font_size,
            });
        }
        current_x += char_advance;
    }
}

/// Draws a multi-line string. Each newline character offsets downwards by `line_height_factor * font_size`.
/// Supports rotation by rotating the vertical line offset vector.
pub fn drawMultiline(
    string: []const u8,
    position: Vec2f32,
    line_height_factor: f32,
    options: TextConfig,
) void {
    if (string.len == 0) return;

    const font_size = options.font_size;
    const rotation = options.rotation;

    var lines = std.mem.splitScalar(u8, string, '\n');
    var line_idx: usize = 0;

    const cos_r = @cos(rotation);
    const sin_r = @sin(rotation);

    while (lines.next()) |raw_line| {
        // Handle carriage returns from CRLF endings
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;

        const rel_y = @as(f32, @floatFromInt(line_idx)) * line_height_factor * font_size;

        // Rotate the vertical layout vector [0, rel_y]
        const line_offset = Vec2f32{ -rel_y * sin_r, rel_y * cos_r };
        const line_position = position + line_offset;

        drawString(line, line_position, options);
        line_idx += 1;
    }
}

/// Adds a single entity to the `entities` array by adding a UV-based `WGSLEntity` to the scratch buffer.
pub fn addRawEntity(entity: WGSLEntity) void {
    @setFloatMode(.optimized);
    if (entity.size[0] == 0.0 or entity.size[1] == 0.0) return;
    if (entity.lcha[3] <= 0.0) return;

    // Viewport-based culling (accounting for rotation). Use @abs since a horizontal flip negates size.x.
    const half_diag = @abs(entity.size) * @as(Vec2f32, @splat(if (entity.rotation == 0.0) 0.5 else 1.0 / @sqrt(2.0)));
    const min_x = entity.position[0] - half_diag[0];
    const max_x = entity.position[0] + half_diag[0];
    const min_y = entity.position[1] - half_diag[1];
    const max_y = entity.position[1] + half_diag[1];

    if (max_x < 0.0 or min_x > dw.SCREEN_WIDTH or max_y < 0.0 or min_y > dw.SCREEN_HEIGHT) {
        return;
    }

    entity_count += 1;
    const wgsl_entity = memory.scratchPushEntity();
    wgsl_entity.* = entity;
    // dw.logger.quick(.{ "{h}Entity ID", (@intFromPtr(wgsl_entity) - memory.mem.scratch_ptr) / @sizeOf(WGSLEntity) });
}

/// Adds a single entity to the `entities` array by adding a UV-based `WGSLEntity` to the scratch buffer.
/// No-op if the sprite type is `none`.
pub fn addEntity(entity: Entity) void {
    @setFloatMode(.optimized);
    if (entity.sprite.isEmpty()) return;
    @call(.always_inline, addRawEntity, .{WGSLEntity{
        .lcha = entity.lcha,
        .position = entity.position /
            Vec2f32{ dw.SCREEN_WIDTH, dw.SCREEN_HEIGHT },
        .size = .{
            entity.size / dw.SCREEN_WIDTH,
            @abs(entity.size) / dw.SCREEN_HEIGHT,
        },
        .rotation = entity.rotation,
        .id = sprite.Sprite.asEntity(entity.sprite),
    }});
}

/// Adds a single entity to the `entities` array by adding a UV-based `WGSLEntity` to the scratch buffer.
/// No-op if the sprite type is `none`.
pub fn addEntitySized(entity: memory.SizedEntity) void {
    @setFloatMode(.optimized);
    if (entity.sprite.isEmpty()) return;

    // See PositionType def for an explanation of these "magic formulas"
    const possible_positions: [4]Vec2f32 = .{
        entity.position + entity.size / Vec2f32{ 2.0, 2.0 },
        entity.position,
        (entity.position + entity.size / Vec2f32{ 2.0, 2.0 }) / Vec2f32{ dw.SCREEN_WIDTH, dw.SCREEN_HEIGHT },
        entity.position / Vec2f32{ dw.SCREEN_WIDTH, dw.SCREEN_HEIGHT },
    };

    @call(.always_inline, addRawEntity, .{WGSLEntity{
        .lcha = entity.lcha,
        .position = possible_positions[@intFromEnum(entity.system)],
        .size = if (entity.system == .top_left_viewport or entity.system == .center_viewport)
            entity.size /
                Vec2f32{ dw.SCREEN_WIDTH, dw.SCREEN_HEIGHT }
        else
            entity.size,
        .rotation = entity.rotation,
        .id = sprite.Sprite.asEntity(entity.sprite),
    }});
}

/// Converts a horizontal width of a sprite to a square within UV coordinates.
pub inline fn toSizeUv(horizontal_width: f32) Vec2f32 {
    return @as(Vec2f32, @splat(horizontal_width)) *
        Vec2f32{ 1, @as(comptime_float, dw.SCREEN_WIDTH) /
            @as(comptime_float, dw.SCREEN_HEIGHT) };
}

/// Converts viewport (logical pixel, 480x270) coordinates to UV (0-1) ones.
pub inline fn viewportToUv(viewport: Vec2f32) Vec2f32 {
    return viewport / Vec2f32{ dw.SCREEN_WIDTH, dw.SCREEN_HEIGHT };
}

/// Converts UV (0-1) coordinates to viewport (logical pixel, 480x270) ones.
pub inline fn uvToViewport(uv: Vec2f32) Vec2f32 {
    return uv * Vec2f32{ dw.SCREEN_WIDTH, dw.SCREEN_HEIGHT };
}
