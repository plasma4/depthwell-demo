//! Crafting menu opened by in-world core indicators (.core_off / .core1-.core4).
//!
//! Opening is toggled by clicking a core's indicator, which flips `dw.indicators.menus.corecraft`.
//! This menu is INDEPENDENT of the furnace menu: both can be open at once (see render/indicators.zig).
//!
//! Recipes are a plain comptime table (`recipes`): add a row to add a craft.
//! Hovering over a slot reveals its inputs (what you need to craft), and clicking a craftable slot produces a new item!
const std = @import("std");
const dw = @import("../root.zig");

const Sprite = dw.Sprite;
const Vec2f = dw.utils.Vec2f;
const Vec2f32 = dw.utils.Vec2f32;
const addEntity = dw.entity.addEntity;
const addEntitySized = dw.entity.addEntitySized;
const drawNumber = dw.entity.drawNumber;
const mouse = dw.mouse;
const inventory = dw.inventory;

/// A single input requirement (or the output) of a recipe.
const Ingredient = struct { item: Sprite, count: u32 };

/// One craft: a list of input items+quantities producing a single output item+quantity.
const Recipe = struct { inputs: []const Ingredient, output: Ingredient };

/// The recipe database. The grid layout and panel size automatically resize based on the length of this.
const recipes = [_]Recipe{
    .{
        .inputs = &.{
            .{ .item = .wood, .count = 3 },
            .{ .item = .leaves, .count = 2 },
        },
        .output = .{ .item = .campfire, .count = 1 },
    },
    // Comptime placeholder slot for the dynamic pickaxe upgrades
    .{
        .inputs = &.{},
        .output = .{ .item = .pickaxe, .count = 1 },
    },
};

// Grid layout (viewport pixels). The panel sizes itself to hold recipes.len slots,
// with each recipe wrapping at COLS.
const COLS: usize = 5;
const SLOT: f64 = 18.0;
const GAP: f64 = 7.0;
const PAD_X: f64 = 10.0;
const TOP_PAD: f64 = 18.0; // room for the title icon above the grid
const BOT_PAD: f64 = 8.0;

const ROWS: usize = (recipes.len + COLS - 1) / COLS;
const grid_cols: usize = @min(COLS, recipes.len);
const content_w: f64 = @as(f64, @floatFromInt(grid_cols)) * SLOT +
    @as(f64, @floatFromInt(grid_cols -| 1)) * GAP;
const content_h: f64 = @as(f64, @floatFromInt(ROWS)) * SLOT +
    @as(f64, @floatFromInt(ROWS -| 1)) * GAP;
const PANEL_W_PX: f64 = content_w + 2 * PAD_X;
const PANEL_H_PX: f64 = content_h + TOP_PAD + BOT_PAD;

/// Menu panel size/placement in UV space (top-left aligned), anchored to the bottom-right so it never overlaps the bottom-left furnace panel.
/// Single-sourced so drawing and hit-testing can't drift apart.
const MENU_SIZE: Vec2f32 = .{
    @floatCast(PANEL_W_PX / dw.SCREEN_WIDTH),
    @floatCast(PANEL_H_PX / dw.SCREEN_HEIGHT),
};
const MENU_POS: Vec2f32 = .{
    @floatCast(0.98 - PANEL_W_PX / dw.SCREEN_WIDTH),
    @floatCast(0.96 - PANEL_H_PX / dw.SCREEN_HEIGHT),
};

/// Number color for a satisfied requirement / the output count.
const NUM_OK: dw.utils.Vec4f32 = .{ 0.78, 0.19, 1.2, 1.0 };
/// Number color for an unmet input requirement (red).
const NUM_RED: dw.utils.Vec4f32 = .{ 0.62, 0.35, 0.5, 1.0 };

/// Round-rect hitbox covering the whole menu panel, in viewport pixels.
fn menuHitbox() dw.geometry.Shape {
    const px_scale: Vec2f = .{ dw.SCREEN_WIDTH, dw.SCREEN_HEIGHT };
    return dw.geometry.Shape.roundSquare(
        .{ @as(f64, MENU_POS[0]) * px_scale[0], @as(f64, MENU_POS[1]) * px_scale[1] },
        @as(f64, MENU_SIZE[0]) * px_scale[0],
        0.05,
    );
}

/// Whether the cursor is over the corecraft panel. Always false while the menu is closed.
/// Used by `mouse.processDownCaptures()` to keep pointerdown from falling through to the world.
pub fn isHoveringOnMenu() bool {
    if (!dw.indicators.menus.corecraft) return false;
    return menuHitbox().contains(mouse.uv_position * Vec2f{ dw.SCREEN_WIDTH, dw.SCREEN_HEIGHT });
}

/// Resets the state of the corecraft menu.
pub fn reset() void {}

/// How many of `item` the player has available (infinite in creative).
inline fn availableCount(item: Sprite) u64 {
    if (inventory.isInCreative()) return std.math.maxInt(u64);
    return inventory.inventory_counts[@intFromEnum(item)];
}

/// Dynamically returns the appropriate recipe for the next pickaxe tier.
fn getPickaxeRecipe() Recipe {
    const current = dw.mining.pickaxe_type;
    return switch (current) {
        .stone => .{
            .inputs = &[_]Ingredient{
                .{ .item = .copper_bar, .count = 8 },
            },
            .output = .{ .item = .pickaxe, .count = 1 },
        },
        .bronze => .{
            .inputs = &[_]Ingredient{
                .{ .item = .iron_bar, .count = 10 },
            },
            .output = .{ .item = .pickaxe, .count = 1 },
        },
        .iron => .{
            .inputs = &[_]Ingredient{
                .{ .item = .silver_bar, .count = 12 },
            },
            .output = .{ .item = .pickaxe, .count = 1 },
        },
        .silver => .{
            .inputs = &[_]Ingredient{
                .{ .item = .gold_bar, .count = 14 },
            },
            .output = .{ .item = .pickaxe, .count = 1 },
        },
        .gold => .{
            .inputs = &[_]Ingredient{},
            .output = .{ .item = .none, .count = 0 },
        },
    };
}

/// Resolves either static or dynamically evaluated recipes.
fn getRecipe(idx: usize) Recipe {
    if (idx == 0) {
        return recipes[0];
    } else {
        return getPickaxeRecipe();
    }
}

/// Whether every input of `recipe` is currently satisfied by the inventory.
fn canCraft(recipe: Recipe) bool {
    if (recipe.output.item == .none) return false;
    for (recipe.inputs) |in| {
        if (availableCount(in.item) < in.count) return false;
    }
    return true;
}

/// Consumes a craftable recipe's inputs and grants its output. Assumes `canCraft(recipe)`.
fn doCraft(recipe: Recipe) void {
    if (!inventory.isInCreative()) {
        for (recipe.inputs) |in| {
            inventory.inventory_counts[@intFromEnum(in.item)] -= in.count;
        }
    }

    if (recipe.output.item == .pickaxe) {
        dw.mining.upgradePickaxe();
    } else if (recipe.output.count > 0) {
        inventory.addToInventory(recipe.output.item, recipe.output.count);
    }
    dw.sound.playSound(7, 1.0, 0.3, 0.1);
}

/// Builds a centered round-square hitbox in viewport pixels.
fn slotHitbox(center_px: Vec2f, size: f64) dw.geometry.Shape {
    return .roundSquare(center_px - @as(Vec2f, @splat(size / 2.0)), size, 0.2);
}

/// Draws a number with a shadow!
fn drawCount(count: u64, center_px: Vec2f, color: dw.utils.Vec4f32, alpha: f32) void {
    const pos: Vec2f32 = .{ @floatCast(center_px[0]), @floatCast(center_px[1]) };
    // Shadow: same digits, darker, nudged down-right; then the colored copy on top.
    drawNumber(count, pos + Vec2f32{ 0.6, 0.6 }, .{
        .font_size = 6.0,
        .lcha = .{ 0.16, 0.1, color[2], 0.75 * alpha },
    });
    drawNumber(count, pos, .{
        .font_size = 6.0,
        .lcha = .{ color[0], color[1], color[2], color[3] * alpha },
    });
}

/// The pixel center of recipe slot `i` within the grid.
fn slotCenterPx(i: usize) Vec2f {
    const px_scale: Vec2f = .{ dw.SCREEN_WIDTH, dw.SCREEN_HEIGHT };
    const panel_left = @as(f64, MENU_POS[0]) * px_scale[0];
    const panel_top = @as(f64, MENU_POS[1]) * px_scale[1];
    const col: f64 = @floatFromInt(i % COLS);
    const row: f64 = @floatFromInt(i / COLS);
    return .{
        panel_left + PAD_X + SLOT / 2.0 + col * (SLOT + GAP),
        panel_top + TOP_PAD + SLOT / 2.0 + row * (SLOT + GAP),
    };
}

/// Draws the input requirements of the hovered recipe as a row just above the panel.
fn drawRequirements(recipe: Recipe) void {
    const px_scale: Vec2f = .{ dw.SCREEN_WIDTH, dw.SCREEN_HEIGHT };
    const panel_center_x = (@as(f64, MENU_POS[0]) + @as(f64, MENU_SIZE[0]) / 2.0) * px_scale[0];
    const row_y = @as(f64, MENU_POS[1]) * px_scale[1] - 12.0;

    const k: f64 = @floatFromInt(recipe.inputs.len);
    const CELL: f64 = 26.0;
    const start_x = panel_center_x - (k - 1.0) * CELL / 2.0;

    for (recipe.inputs, 0..) |in, idx| {
        const cx = start_x + @as(f64, @floatFromInt(idx)) * CELL;

        // Low-opacity selected-inventory frame centered below the inputs (not the wood variant).
        addEntity(.{
            .sprite = .inventory_selected,
            .position = .{ @floatCast(cx), @floatCast(row_y) },
            .size = 22.0,
            .lcha = .{ 1.0, 0.0, 0.0, 0.7 },
        });
        addEntity(.{
            .sprite = in.item,
            .position = .{ @floatCast(cx), @floatCast(row_y) },
            .size = 14.0,
        });
        const have = availableCount(in.item);
        const color = if (have < in.count) NUM_RED else NUM_OK;
        drawCount(in.count, .{ cx + 3.0, row_y + 4.5 }, color, 1.0);
    }
}

pub fn draw() void {
    @setFloatMode(.optimized);
    // The menu is only visible/interactive while opened via a core indicator.
    if (!dw.indicators.menus.corecraft) return;

    const px_scale: Vec2f = .{ dw.SCREEN_WIDTH, dw.SCREEN_HEIGHT };
    const mouse_px: Vec2f = mouse.uv_position * px_scale;

    // Background panel.
    addEntitySized(.{
        .sprite = .rectangle,
        .position = MENU_POS,
        .size = MENU_SIZE,
        // blue!
        .lcha = .{ 0.52, 0.22, 3.8, 1.0 },
    });

    // Title icon centered near the top; brighter once a powered core is nearby.
    const title_px: Vec2f = .{
        (@as(f64, MENU_POS[0]) + @as(f64, MENU_SIZE[0]) / 2.0) * px_scale[0],
        @as(f64, MENU_POS[1]) * px_scale[1] + 9.0,
    };
    addEntity(.{
        .sprite = .craft,
        .position = .{ @floatCast(title_px[0]), @floatCast(title_px[1]) },
        .size = 12.0,
    });

    var hovered: ?Recipe = null;
    for (0..recipes.len) |i| {
        const recipe = getRecipe(i);
        if (recipe.output.item == .none) continue;

        const center = slotCenterPx(i);
        const craftable = canCraft(recipe);
        const over = slotHitbox(center, SLOT).contains(mouse_px);
        if (over) {
            hovered = recipe;
            // Pointer on any hovered slot (it is interactive and shows a tooltip);
            // craft only actually fires when the recipe is affordable.
            if (mouse.click_focus.permits(.crafting)) mouse.requestCursorType(.pointer);
            if (craftable and mouse.isClicked(.crafting, true)) doCraft(recipe);
        }

        // Draw the background where the item rests in.
        addEntity(.{
            .sprite = .wood_icon,
            .position = .{ @floatCast(center[0] - 1.6), @floatCast(center[1] - 1.6) },
            .size = @as(f32, @floatCast(SLOT)),
            // looks blue!
            .lcha = .{ 0.3, 0.06, 3.0, 1.0 },
        });
        addEntity(.{
            .sprite = .wood_icon,
            .position = .{ @floatCast(center[0]), @floatCast(center[1]) },
            .size = @as(f32, @floatCast(SLOT)),
            // looks blue!
            .lcha = .{ 0.9, 0.15, 3.0, 1.0 },
        });

        // Draw the actual item now...

        var item = recipe.output.item;
        if (item == .pickaxe) {
            // draw the better pickaxe type they are crafting
            item = @enumFromInt(@intFromEnum(Sprite.pickaxe) + @intFromEnum(dw.mining.pickaxe_type) + 1);
        }

        addEntity(.{
            .sprite = item,
            .position = .{ @floatCast(center[0]), @floatCast(center[1]) },
            .size = @as(f32, @floatCast(SLOT - 4.0)),
            .lcha = .{ 1.0, if (craftable) 0.0 else -1.0, 0.0, 1.0 },
        });
        // Draw quantity (only shown when it makes more than one).
        if (recipe.output.count > 1) {
            drawCount(recipe.output.count, .{ center[0] + 3.0, center[1] + 5.0 }, NUM_OK, if (craftable) 1.0 else 0.75);
        }
    }

    // Requirements tooltip for the hovered recipe, drawn last so it sits above the slots.
    if (hovered) |recipe| drawRequirements(recipe);
}
