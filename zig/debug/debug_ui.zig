//! Handles debug options for sliders and buttons, and contains functions to pass these to JS.
//! Only imported if `dw.is_debug` is true.
const std = @import("std");
const dw = @import("../root.zig");
const main = dw.startup;
const logger = dw.logger;
const memory = dw.memory;
const world = dw.world;
const player = dw.player;
const seeding = dw.seeding;
const procedural = dw.procedural;

/// Defines options for a single slider.
pub const SliderDef = struct {
    /// Label identifying the slider.
    name: []const u8,
    /// Minimum value.
    min: f64,
    /// Maximum value.
    max: f64,
    /// Pointer to the variable to change.
    val: *f64,
    /// Optional function to also call on slider state change.
    on_change: ?*const fn (f64) void = null,
    /// Whether to clear chunk-based caches.
    regen: bool = false,
};

/// Defines options for a single button.
pub const ButtonDef = struct {
    /// Text to put inside the button.
    name: []const u8,
    /// Optional function to also call on button press.
    action: ?*const fn () void = null,
    /// Optional pointer to a boolean to toggle on button press.
    toggle: ?*bool = null,
    /// Whether to clear chunk-based caches.
    regen: bool = false,
};

/// List of sliders (with a range that modifies a numeric variable)
pub const sliders = procedural_sliders ++ player_sliders ++ render_sliders;

const procedural_sliders = [_]SliderDef{
    .{
        .name = "Procedural scale",
        .min = 0.1,
        .max = 5.0,
        .val = &procedural.procedural_cell_size.value,
        .regen = true,
    },
    .{
        .name = "FBM (random domain warping) scale",
        .min = 0.2,
        .max = 5.0,
        .val = &procedural.fbm_scale.value,
        .regen = true,
    },
    .{
        .name = "FBM dual value scale size",
        .min = 4.0,
        .max = 32.0,
        .val = &procedural.dual_value_scale.value,
        .regen = true,
    },
    .{
        .name = "Minimum stone density cutoff",
        .min = 0.0,
        .max = 1.0,
        .val = &procedural.density_min.value,
        .regen = true,
    },
    .{
        .name = "Maximum stone density cutoff",
        .min = 0.0,
        .max = 1.0,
        .val = &procedural.density_max.value,
        .regen = true,
    },
    .{
        .name = "Hybrid procedural weight",
        .min = 0.0,
        .max = 1.0,
        .val = &procedural.hybrid_weight.value,
        .regen = true,
    },
    .{
        .name = "Odds for gems to spawn",
        .min = 0.0,
        .max = 1.0,
        .val = &procedural.base_gem_odds.value,
        .regen = true,
    },
};

const player_sliders = [_]SliderDef{
    .{
        .name = "Base player speed",
        .min = 0.1,
        .max = 10.0,
        .val = &player.PLAYER_BASE_SPEED,
    },
    .{
        .name = "Base player gravity",
        .min = 0.01,
        .max = 2.0,
        .val = &player.GRAVITY,
    },
    .{
        .name = "Jump force",
        .min = 1.0,
        .max = 50.0,
        .val = &player.JUMP_FORCE,
    },
    .{
        .name = "Friction (x-axis)",
        .min = 0.0,
        .max = 1.0,
        .val = &player.FRICTION_X,
    },
    .{
        .name = "Friction (y-axis)",
        .min = 0.0,
        .max = 1.0,
        .val = &player.FRICTION_Y,
    },
};

const render_sliders = [_]SliderDef{
    .{
        .name = "Wireframe opacity",
        .min = 0.0,
        .max = 1.0,
        .val = &dw.render.WIREFRAME_OPACITY,
    },
    .{
        .name = "Preview tile size",
        .min = 0.0,
        .max = 16.0,
        .val = &dw.entity.preview_tile_size,
    },
};

/// List of debug buttons that either execute functions or toggle booleans.
pub const buttons = [_]ButtonDef{
    // .{
    //     .name = "Teleport to edge",
    //     .action = teleportToEdge,
    // },
    .{
        .name = "Teleport randomly",
        .action = teleportRandomly,
    },
    .{
        .name = "Clear caches",
        .action = clearCaches,
    },
    // .{
    //     .name = "Sample worldgen odds",
    //     .action = dw.audit.sampleWorldAroundPlayer,
    // },
    .{
        .name = "Toggle creative",
        .toggle = &dw.inventory.IN_CREATIVE,
    },
    .{
        .name = "Toggle global light",
        .toggle = &dw.lighting.DEBUG_LIGHT,
    },
    // .{
    //     .name = "Toggle base heatmap",
    //     .toggle = &procedural.USE_BASE_HEATMAP,
    //     .regen = true,
    // },
    // .{
    //     .name = "Toggle ore heatmap",
    //     .toggle = &procedural.USE_ORE_HEATMAP,
    //     .regen = true,
    // },
};

/// Teleports to the top left quadrant. Then, tries to find a valid spawn point.
fn teleportToEdge() void {
    memory.game.teleport(
        .{ .quadrant = 0, .suffix = .{ 0, 0 } },
        .{ dw.CHUNK_SIZE_SQ * 5 / 2, dw.CHUNK_SIZE_SQ * 5 / 2 },
    );
    main.findSafeSpawn();
}

fn clearCaches() void {
    dw.world.clearCaches(true);
}

/// Internal random number for teleport PRNG.
/// This is for debugging only and should NOT be used for gameplay.
var teleport_rand: u64 = std.math.maxInt(u64);
/// Teleports to a random valid coordinate (chunk) within the same quadrant. Then, tries to find a valid spawn point.
/// This is for debugging only and should NOT be used for gameplay.
fn teleportRandomly() void {
    const game = &memory.game;

    // select a random location X/Y through hashing
    const s = seeding.mixBaseSeed(game.seed, teleport_rand);
    const h1 = seeding.FastHash.hash2d(
        s.value[0..2].*, // peer type resolution helps out here
        @intCast(game.player_pos[0]),
        @intCast(game.player_pos[1]),
    );
    const h2 = seeding.FastHash.hash2d(
        s.value[2..4].*,
        @intCast(game.player_pos[0]),
        @intCast(game.player_pos[1]),
    );
    teleport_rand -%= 1;

    game.teleport(
        .{ .quadrant = 0, .suffix = .{
            h1 & world.max_possible_suffix,
            h2 & world.max_possible_suffix,
        } },
        .{ 2048, 2048 },
    );
    main.findSafeSpawn();
}

/// Handles a slider change to a new specified value.
pub fn changeSlider(id: u32, val: f64) void {
    if (id >= sliders.len and id < 0) @panic("Slider ID invalid!");
    if (sliders.len == 0) return;
    const s = sliders[id];
    s.val.* = val;
    if (s.on_change) |func| {
        func(val);
    }
    if (s.regen) {
        world.clearCaches(true);
    }
}

/// Handles the action or toggle of a button press.
pub fn clickButton(id: u32) void {
    if (id >= buttons.len and id < 0) @panic("Button ID invalid!");

    const b = buttons[id];
    if (b.action) |func| {
        func();
    }
    if (b.toggle) |value| {
        value.* = !value.*;
    }
    if (b.regen) {
        world.clearCaches(true);
    }
}

/// Build debug UI metadata by exporting a JSON string to the scratch buffer.
pub fn buildMetadata() void {
    var arena = memory.makeArena();
    defer arena.deinit();

    var out: std.Io.Writer.Allocating = .init(arena.allocator());

    var ws: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{},
    };

    // Start root object
    ws.beginObject() catch return;

    // Now, add "sliders" field and start array
    ws.objectField("sliders") catch return;
    ws.beginArray() catch return;

    for (sliders, 0..) |s, i| {
        const value = s.val.*;
        if (value < s.min or value > s.max) @panic("A slider definition contains out-of-bounds minimum or maximum!");
        ws.beginObject() catch return;

        ws.objectField("id") catch return;
        ws.write(i) catch return;

        ws.objectField("name") catch return;
        ws.write(s.name) catch return;

        ws.objectField("min") catch return;
        ws.write(s.min) catch return;

        ws.objectField("max") catch return;
        ws.write(s.max) catch return;

        ws.objectField("val") catch return;
        ws.write(value) catch return;

        ws.endObject() catch return;
    }
    ws.endArray() catch return;

    // Add "buttons" field and start array
    ws.objectField("buttons") catch return;
    ws.beginArray() catch return;
    for (buttons, 0..) |b, i| {
        ws.beginObject() catch return;
        ws.objectField("id") catch return;
        ws.write(i) catch return;
        ws.objectField("name") catch return;
        ws.write(b.name) catch return;
        ws.endObject() catch return;
    }
    ws.endArray() catch return;

    ws.endObject() catch return; // Finish!

    const written = out.written();
    memory.scratchReset();
    const scratch_ptr = memory.scratchAlloc(written.len);
    @memcpy(scratch_ptr[0..written.len], written);
}
