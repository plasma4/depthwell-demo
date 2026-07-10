//! Draws the furnace smelting menu and handles its drag-and-drop smelting logic.
//!
//! Smelting state is GLOBAL (shared by all furnaces);
//! the in-world furnace indicators only toggle `dw.indicators.menus.furnace` (whether this menu is open).
//!
//! Because ore forms of metals are useless, the interaction is can be extremely simple.
//! Dragging an ore from the inventory onto the input slot loads ALL of that ore at once!
const std = @import("std");
const dw = @import("../root.zig");

const Sprite = dw.Sprite;
const Vec2f = dw.utils.Vec2f;
const Vec2f32 = dw.utils.Vec2f32;
const addEntity = dw.entity.addEntity;
const addEntitySized = dw.entity.addEntitySized;
const drawNumber = dw.entity.drawNumber;
const toSize = dw.entity.toSizeUv;
const mouse = dw.mouse;
const inventory = dw.inventory;

/// Number of bars in the progress bar (must be a at least 8).
const SMELTING_STEPS = 10;
/// Logic ticks spent on each progress unit.
const FRAMES_PER_STEP = 2;
/// Total ticks to smelt one loaded batch.
const TOTAL_PROGRESS = SMELTING_STEPS * FRAMES_PER_STEP;

/// Menu panel placement and size in UV space (top-left aligned).
/// Single-sourced so `draw()` and the `isHoveringMenu()` hit test can never drift apart.
const MENU_POS: Vec2f32 = .{ 0.02, 0.75 };
const MENU_SIZE: Vec2f32 = toSize(0.3) * Vec2f32{ 1.0, 0.5 };

/// Round-rect hitbox covering the whole menu panel, in viewport pixels.
fn menuHitbox() dw.geometry.Shape {
    const px_scale: Vec2f = .{ dw.SCREEN_WIDTH, dw.SCREEN_HEIGHT };
    return dw.geometry.Shape.roundSquare(
        .{ @as(f64, MENU_POS[0]) * px_scale[0], @as(f64, MENU_POS[1]) * px_scale[1] },
        @as(f64, MENU_SIZE[0]) * px_scale[0],
        0.05,
    );
}

/// Whether the cursor is over a menu panel (such as furnace smelting). Always false while the menu is closed.
/// Used by `mouse.processDownCaptures()` to keep pointerdown from falling through to the world.
pub fn isHoveringOnMenu() bool {
    if (!dw.indicators.menus.furnace) return false;
    return menuHitbox().contains(mouse.uv_position * Vec2f{ dw.SCREEN_WIDTH, dw.SCREEN_HEIGHT });
}

/// Ore currently loaded in the input slot (`.none` if empty).
var loaded_ore: Sprite = .none;
/// How many ore units are loaded.
var loaded_count: u32 = 0;
/// Bar type sitting in the output slot (`.none` if empty).
var output_bar: Sprite = .none;
/// How many bars are in the output slot.
var output_count: u32 = 0;
/// Smelting progress for the current batch, from 0 to `TOTAL_PROGRESS`.
var smelting_progress: u16 = 0;

/// Smoothed render position (viewport px) of the dragged-ore icon, giving it a slight trailing lag.
/// Negative when no drag is active.
var drag_pos_px: Vec2f = .{ -1.0, -1.0 };
/// Mouse UV from the previous frame, used to gauge drag speed for the wiggle.
var last_drag_uv: Vec2f = .{ -1.0, -1.0 };

/// Resets the state of the furnace menu.
pub fn reset() void {
    loaded_ore = .none;
    loaded_count = 0;
    output_bar = .none;
    output_count = 0;
    smelting_progress = 0;
}

/// Furnace state (input/output slots + batch progress) for saving.
pub const SaveState = struct {
    loaded_ore: Sprite,
    loaded_count: u32,
    output_bar: Sprite,
    output_count: u32,
    smelting_progress: u16,
};

/// Exports furnace state properties.
pub fn getSaveState() SaveState {
    return .{
        .loaded_ore = loaded_ore,
        .loaded_count = loaded_count,
        .output_bar = output_bar,
        .output_count = output_count,
        .smelting_progress = smelting_progress,
    };
}

/// Restores furnace state from a save.
pub fn setSaveState(s: SaveState) void {
    loaded_ore = s.loaded_ore;
    loaded_count = s.loaded_count;
    output_bar = s.output_bar;
    output_count = s.output_count;
    smelting_progress = s.smelting_progress;
}

/// Advances smelting. Only called while the menu is open (see `state/tick.zig`),
/// so closing the menu pauses smelting. Holds at 0 whenever nothing is loaded.
pub fn updateSmelting() void {
    if (loaded_ore == .none or loaded_count == 0) {
        smelting_progress = 0;
        return;
    }

    // There's at least 1 bar being smelted.
    smelting_progress += 1;
    if (smelting_progress >= TOTAL_PROGRESS) {
        // Smelt one bar!
        const bar = loaded_ore.oreToBar();
        // If the output already holds a different bar type, flush it to the inventory first.
        if (output_bar != .none and output_bar != bar) {
            inventory.addToInventory(output_bar, output_count);
            output_count = 0;
        }

        output_bar = bar;
        output_count += 1;
        loaded_count -= 1;
        if (loaded_count == 0) loaded_ore = .none;
        smelting_progress = 0;

        // play the furnace smelting sound
        dw.sound.playSound(
            7,
            1.0,
            0.2,
            0.4,
        );
    }
}

/// Removes every unit of `ore` from the inventory and returns how many there were.
/// In creative mode the supply is infinite, so a fixed batch is returned without decrementing.
fn takeAllFromInventory(ore: Sprite) u32 {
    if (inventory.isInCreative()) return 100;
    const idx = @intFromEnum(ore);
    const n = inventory.inventory_counts[idx];
    inventory.inventory_counts[idx] = 0;
    if (inventory.selected_sprite == ore) inventory.selected_sprite = .none;
    return @intCast(n);
}

/// Loads all of `ore` from the inventory into the input slot, resetting progress instantly.
/// Any previously-loaded ore of a different type is returned to the inventory first.
fn loadOre(ore: Sprite) void {
    if (loaded_ore != .none and loaded_ore != ore) {
        inventory.addToInventory(loaded_ore, loaded_count);
        loaded_count = 0;
    }
    const got = takeAllFromInventory(ore);
    if (got == 0) return;
    loaded_ore = ore;
    loaded_count += got;
    smelting_progress = 0; // adding to the input resets the bar
}

/// Returns any loaded ore back to the inventory and resets progress instantly.
fn returnLoadedOre() void {
    if (loaded_ore == .none) return;
    inventory.addToInventory(loaded_ore, loaded_count);
    loaded_ore = .none;
    loaded_count = 0;
    smelting_progress = 0; // removing from the input resets the bar
}

/// Collects the finished bars from the output slot into the inventory.
fn collectOutput() void {
    if (output_bar == .none or output_count == 0) return;
    inventory.addToInventory(output_bar, output_count);
    output_bar = .none;
    output_count = 0;
}

/// Builds a centered round-square hitbox in viewport pixels.
fn slotHitbox(center_px: Vec2f, size: f64) dw.geometry.Shape {
    return .roundSquare(center_px - @as(Vec2f, @splat(size / 2.0)), size, 0.2);
}

/// Draws the ore currently being dragged from the inventory toward the input slot with lag and wiggle effects.
fn drawDragIcon(mouse_px: Vec2f) void {
    const dragged = inventory.selected_sprite;
    // A drag is "active" while the button is held (focus persists on the inventory) over an ore
    if (mouse.click_focus != .inventory or !dragged.isOre() or mouse.uv_position[0] < 0.0) {
        drag_pos_px = .{ -1.0, -1.0 };
        last_drag_uv = mouse.uv_position;
        return;
    }

    // Cursor speed this frame (in UV), scaling the wiggle amplitude
    const uv_speed: f64 = if (last_drag_uv[0] < 0.0) 0.0 else blk: {
        const d = mouse.uv_position - last_drag_uv;
        break :blk @sqrt(d[0] * d[0] + d[1] * d[1]);
    };
    last_drag_uv = mouse.uv_position;

    // Ease the rendered position toward the cursor!
    if (drag_pos_px[0] < 0.0) {
        drag_pos_px = mouse_px;
    } else {
        drag_pos_px += (mouse_px - drag_pos_px) * @as(Vec2f, @splat(0.5));
    }

    // Sine-wave wiggle effect that changes based no drag speed
    const frame: f32 = @floatFromInt(dw.memory.game.frame);
    const wiggle_amount: f32 = @min(@as(f32, @floatCast(uv_speed)) * 14.0, 1.0);
    const wiggle: f32 = @sin(frame * 0.6) * wiggle_amount; // radians

    // Fan out 1-3 copies based on how much of the ore is held.
    const held = if (inventory.isInCreative()) @as(u64, 3) else inventory.inventory_counts[@intFromEnum(dragged)];
    const copies: usize = @intCast(@min(@max(held, 1), 3));

    // Pre-determined offsets (viewport px): back-left, back-right, then the front (centered) copy.
    // Drawing back-to-front layers the centered copy on top.
    const offsets = [3]Vec2f{ .{ -3.0, -2.0 }, .{ 3.0, -2.0 }, .{ 0.0, 0.0 } };
    const start = 3 - copies;

    var i: usize = start;
    while (i < 3) : (i += 1) {
        const is_front = (i == 2);
        const off = offsets[i];
        addEntity(.{
            .sprite = dragged,
            .position = .{ @floatCast(drag_pos_px[0] + off[0]), @floatCast(drag_pos_px[1] + off[1]) },
            .size = if (is_front) 16.0 else 14.0,
            .rotation = wiggle,
            // Partial opacity; the front copy is a touch more opaque so the stack reads clearly.
            .lcha = .{ 1.0, 0.0, 0.0, if (is_front) 0.8 else 0.6 },
        });
    }
}

pub fn draw() void {
    @setFloatMode(.optimized);
    // The menu is only visible/interactive while opened via a furnace indicator.
    if (!dw.indicators.menus.furnace) return;

    const px_scale: Vec2f = .{ dw.SCREEN_WIDTH, dw.SCREEN_HEIGHT };

    const menu_pos = MENU_POS;
    const menu_size = MENU_SIZE;
    const menu_center: Vec2f32 = menu_pos + menu_size / Vec2f32{ 2.0, 2.0 };

    // Slot centers, in UV and in viewport pixels.
    const input_uv: Vec2f32 = menu_center - Vec2f32{ 0.1, 0.0 };
    const output_uv: Vec2f32 = menu_center + Vec2f32{ 0.1, 0.0 };
    const input_px: Vec2f = .{ @as(f64, input_uv[0]) * px_scale[0], @as(f64, input_uv[1]) * px_scale[1] };
    const output_px: Vec2f = .{ @as(f64, output_uv[0]) * px_scale[0], @as(f64, output_uv[1]) * px_scale[1] };

    const SLOT_SIZE: f64 = 20.0;
    const ITEM_SIZE: f32 = 16.0;

    const mouse_px: Vec2f = mouse.uv_position * px_scale;
    const input_hitbox = slotHitbox(input_px, SLOT_SIZE);
    const output_hitbox = slotHitbox(output_px, SLOT_SIZE);

    // .smelting down-capture is claimed centrally in mouse.processDownCaptures() (via isHoveringMenu),
    // so by here click_focus already reflects whether this click started on the menu panel.
    const over_input = input_hitbox.contains(mouse_px);
    const over_output = output_hitbox.contains(mouse_px);

    // Drop: a drag that started in the inventory and released over the input slot loads the ore.
    if (over_input and mouse.just_mouse_up and mouse.released_focus == .inventory and inventory.selected_sprite.isOre()) {
        loadOre(inventory.selected_sprite);
    }

    // Menu-internal clicks: take ore back out, or collect finished bars.
    if (over_input and loaded_ore != .none) {
        if (mouse.click_focus.permits(.smelting)) mouse.requestCursorType(.pointer);
        if (mouse.isClicked(.smelting, true)) returnLoadedOre();
    }
    if (over_output and output_bar != .none) {
        if (mouse.click_focus.permits(.smelting)) mouse.requestCursorType(.pointer);
        if (mouse.isClicked(.smelting, true)) collectOutput();
    }

    addEntitySized(.{ // menu background panel (top-left aligned, UV space)
        .sprite = .rectangle,
        .position = menu_pos,
        .size = menu_size,
        .lcha = .{ 0.26, 0.2, 3.2, 1.0 },
    });

    // Slot frames.
    inline for (.{ input_px, output_px }) |slot_px| {
        addEntity(.{
            .sprite = .wood_icon,
            .position = .{ @floatCast(slot_px[0]), @floatCast(slot_px[1]) },
            .size = @floatCast(SLOT_SIZE),
            .lcha = .{ 0.65, -0.08, 0.0, 1.0 },
        });
    }

    // Loaded ore+count goes in the input slot
    if (loaded_ore != .none) {
        addEntity(.{
            .sprite = loaded_ore,
            .position = .{ @floatCast(input_px[0]), @floatCast(input_px[1]) },
            .size = ITEM_SIZE,
        });

        // draw amount and shadow
        drawNumber(loaded_count, .{
            @floatCast(input_px[0] + 2.4),
            @floatCast(input_px[1] + 4.4),
        }, .{
            .font_size = 6.0,
            .lcha = .{ 0.30, 0.22, 1.0, 0.8 },
        });
        drawNumber(loaded_count, .{
            @floatCast(input_px[0] + 3.0),
            @floatCast(input_px[1] + 5.0),
        }, .{
            .font_size = 6.0,
            .lcha = .{ 0.85, 0.30, 1.2, 1.0 },
        });
    }

    // Finished bars+count goes in the output slot
    if (output_bar != .none) {
        addEntity(.{
            .sprite = output_bar,
            .position = .{ @floatCast(output_px[0]), @floatCast(output_px[1]) },
            .size = ITEM_SIZE,
        });
        drawNumber(output_count, .{ @floatCast(output_px[0] + 2.4), @floatCast(output_px[1] + 4.4) }, .{
            .font_size = 6.0,
            .lcha = .{ 0.30, 0.22, 1.6, 0.8 },
        });
        drawNumber(output_count, .{ @floatCast(output_px[0] + 3.0), @floatCast(output_px[1] + 5.0) }, .{
            .font_size = 6.0,
            .lcha = .{ 0.85, 0.30, 1.8, 1.0 },
        });
    }

    // Progress bar between the slots.
    dw.progress.drawBar(
        SMELTING_STEPS,
        @intCast(smelting_progress / FRAMES_PER_STEP),
        menu_center,
        0.15,
        .center_uv,
        .{ 1.04, 0.12, -0.6, 1.0 },
    );

    // Dragged-ore icon follows the cursor on top of everything else.
    drawDragIcon(mouse_px);
}
