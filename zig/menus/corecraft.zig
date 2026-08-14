//! Crafting menu opened by in-world core indicators (.core_off / .core1-.core4).
//!
//! Opening is toggled by clicking a core's indicator, which flips `dw.indicators.menus.corecraft`.
//! This menu is INDEPENDENT of the furnace menu: both can be open at once (see render/indicators.zig).
//!
//! Recipes are a plain comptime table (`recipes`): add a row to add a craft.
//! Hovering over a slot reveals its inputs (what you need to craft), and clicking a craftable slot produces a new item!
const std = @import("std");
const dw = @import("../root.zig");
const util = @import("util.zig");

const Sprite = dw.Sprite;
const Vec2f = dw.utils.Vec2f;
const Vec2f32 = dw.utils.Vec2f32;
const addEntity = dw.entity.addEntity;
const addEntitySized = dw.entity.addEntitySized;
const drawNumber = dw.entity.drawNumber;
const mouse = dw.mouse;
const inventory = dw.inventory;

/// A single input requirement (or the output) of a recipe.
const Ingredient = struct { item: Sprite, count: u32 = 1 };

/// One craft: a list of input items+quantities producing a single output item+quantity.
const Recipe = struct { inputs: []const Ingredient, output: Ingredient };

/// The recipe database: what "comes out" for a given set of inputs.
/// An output count of 1 is implied.
/// The grid layout and the panel size follow the length of this table.
const recipes = [_]Recipe{
    .{
        .inputs = &.{
            .{ .item = .wood, .count = 3 },
            .{ .item = .leaves, .count = 2 },
        },
        .output = .{ .item = .campfire },
    },
    // placeholder slot for the dynamic pickaxe upgrades
    .{
        .inputs = &.{},
        .output = .{ .item = .pickaxe },
    },
};

/// Slot grid: the panel sizes itself to hold `recipes.len` slots, wrapping at 5 columns.
const grid = util.Grid(.{ .len = recipes.len, .cols = 5 });

/// Menu panel size/placement in UV space (top-left aligned),
/// anchored to the bottom-right so it never overlaps the bottom-left furnace panel.
const MENU_SIZE: Vec2f32 = grid.SIZE_UV;
const MENU_POS: Vec2f32 = .{ 0.98 - MENU_SIZE[0], 0.96 - MENU_SIZE[1] };

/// Number color for a satisfied requirement / the output count.
const NUM_OK: dw.utils.Vec4f32 = .{ 0.78, 0.19, 1.2, 1.0 };
/// Number color for an unmet input requirement (red).
const NUM_RED: dw.utils.Vec4f32 = .{ 0.62, 0.35, 0.5, 1.0 };

/// Whether the cursor is over the corecraft panel.
/// Always false while the menu is closed.
pub fn isHoveringOnMenu() bool {
    return util.isHovering(dw.indicators.menus.corecraft, MENU_POS, MENU_SIZE);
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

/// Consumes a craftable recipe's inputs and grants its output.
/// Asserts that the recipe is craftable.
fn doCraft(recipe: Recipe) void {
    std.debug.assert(canCraft(recipe));
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
    dw.sound.playSound(10, 1.0, 0.3, 0.1);
}

/// Draws the input requirements of the hovered recipe as a row just above the panel.
fn drawRequirements(recipe: Recipe) void {
    const panel_px = dw.entity.uvToViewport(MENU_POS);
    const panel_center_x = panel_px[0] + dw.entity.uvToViewport(MENU_SIZE)[0] / 2.0;
    const row_y = panel_px[1] - 12.0;

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
        util.drawCount(in.count, .{ cx + 3.0, row_y + 4.5 }, color, 1.0);
    }
}

pub fn draw() void {
    @setFloatMode(.optimized);
    // The menu is only visible/interactive while opened via a core indicator.
    if (!dw.indicators.menus.corecraft) return;

    const mouse_px = util.mousePx();

    // Background panel.
    addEntitySized(.{
        .sprite = .rectangle,
        .position = MENU_POS,
        .size = MENU_SIZE,
        // blue!
        .lcha = .{ 0.52, 0.22, 3.8, 1.0 },
    });

    // Draw a little craft/hammer icon.
    const title_px = grid.titleCenterPx(MENU_POS);
    addEntity(.{
        .sprite = .craft,
        .position = .{ @floatCast(title_px[0]), @floatCast(title_px[1]) },
        .size = 12.0,
    });

    var hovered: ?Recipe = null;
    for (0..recipes.len) |i| {
        const recipe = getRecipe(i);
        if (recipe.output.item == .none) continue;

        const center = grid.slotCenterPx(MENU_POS, i);
        const craftable = canCraft(recipe);
        const over = util.slotHitbox(center, grid.SLOT).contains(mouse_px);
        if (over) {
            hovered = recipe;
            // Pointer on any hovered slot (it is interactive and shows a tooltip);
            // craft only actually fires when the recipe is affordable.
            if (mouse.click_focus.permits(.crafting)) mouse.requestCursorType(.pointer);
            if (craftable and mouse.isClicked(.crafting, true)) doCraft(recipe);
        }

        // Draw the background where the item rests in.
        addEntity(.{
            .sprite = .wood_frame,
            .position = .{ @floatCast(center[0] - 1.6), @floatCast(center[1] - 1.6) },
            .size = @as(f32, @floatCast(grid.SLOT)),
            // Looks blue
            .lcha = .{ 0.3, 0.06, 3.0, 1.0 },
        });
        addEntity(.{
            .sprite = .wood_frame,
            .position = .{ @floatCast(center[0]), @floatCast(center[1]) },
            .size = @as(f32, @floatCast(grid.SLOT)),
            // Looks blue
            .lcha = .{ 0.9, 0.15, 3.0, 1.0 },
        });

        // Draw the actual item now...

        var item = recipe.output.item;
        if (item == .pickaxe) {
            // Draw the better pickaxe type they are crafting.
            item = @enumFromInt(@intFromEnum(Sprite.pickaxe) + @intFromEnum(dw.mining.pickaxe_type) + 1);
        }

        addEntity(.{
            .sprite = item,
            .position = .{ @floatCast(center[0]), @floatCast(center[1]) },
            .size = @as(f32, @floatCast(grid.SLOT - 4.0)),
            .lcha = .{ 1.0, if (craftable) 0.0 else -1.0, 0.0, 1.0 },
        });
        // Draw quantity (only shown when craft produces more than one).
        if (recipe.output.count > 1) {
            util.drawCount(recipe.output.count, .{ center[0] + 3.0, center[1] + 5.0 }, NUM_OK, if (craftable) 1.0 else 0.75);
        }
    }

    // Requirements tooltip for the hovered recipe, drawn last so it sits above the slots.
    if (hovered) |recipe| drawRequirements(recipe);
}
