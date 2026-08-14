//! Keeps the public mouse position values that the rest of the game reads, such as mining.
const std = @import("std");
const dw = @import("../root.zig");
const memory = dw.memory;
const main = dw.startup;
const logger = dw.logger;
const sprite = dw.sprite;
const world = dw.world;
const inventory = dw.inventory;

const CHUNK_SIZE = dw.CHUNK_SIZE;
const CHUNK_SIZE_SQ = dw.CHUNK_SIZE_SQ;
const SCREEN_WIDTH = dw.SCREEN_WIDTH;
const SCREEN_HEIGHT = dw.SCREEN_HEIGHT;

/// The system categories that can claim the mouse's click focus.
/// The categories stop cross-activation, such as a pointerdown in the inventory and a pointerup on an indicator.
/// Lower enum values win: none > canvas > clickables like inventory slots.
pub const ClickFocus = enum(u32) {
    /// No click is active.
    /// The cursor is free to hover over elements and change type.
    none,
    /// Click started on the world canvas (such as by mining a block).
    /// This beats every UI category, so an active drag cannot touch a menu.
    canvas,
    /// Click started specifically on an inventory slot.
    inventory,
    /// Click started specifically on an in-world indicator overlay such as above furnaces/cores.
    indicator,
    /// Click started specifically on a smelting menu panel.
    smelting,
    /// Click started specifically on a crafting menu panel.
    crafting,
    /// Click started specifically on the chest loot menu panel.
    loot,

    /// Returns the numerical priority of the focus state, where lower is more prioritized.
    pub fn priority(self: ClickFocus) u32 {
        return @intFromEnum(self);
    }

    /// Returns true if this focus state has a higher priority than another.
    pub fn takesPrecedenceOver(self: ClickFocus, other: ClickFocus) bool {
        return self.priority() < other.priority();
    }

    /// Determines if a specific UI category is permitted to interact with the mouse.
    /// Returns true if the mouse is idle (.none) or already focused on that exact category.
    pub inline fn permits(self: ClickFocus, category: ClickFocus) bool {
        return self == .none or self == category;
    }
};

/// The possible mouse cursor visual styles.
pub const CursorType = enum(u8) {
    /// Standard (default) arrow cursor.
    initial,
    /// Hand cursor with one pointing finger. Means something is clickable!
    pointer,
    /// Cursor that shows a drag is possible.
    grab,
    /// Cursor for active dragging.
    grabbing,

    /// Returns the numerical priority of the cursor style, where higher values override lower values.
    pub fn priority(self: CursorType) u8 {
        return @intFromEnum(self);
    }

    /// Returns true if this cursor has higher or equal priority than another.
    pub fn takesPrecedenceOver(self: CursorType, other: CursorType) bool {
        return self.priority() >= other.priority();
    }
};

/// The active category that currently owns the click action.
pub var click_focus: ClickFocus = .none;
/// The current visual style of the cursor.
/// Reset to `.initial` each render frame.
pub var cursor_type: CursorType = .initial;
/// The focus state right before the mouse button was released.
/// Stays valid for the rest of the frame.
pub var released_focus: ClickFocus = .none;

/// Determines if the mouse was just set to be down; reset via `clearFrameFlags()` at the end of the frame.
pub var just_mouse_down: bool = false;
/// Determines if the mouse was just released; reset via `clearFrameFlags()` at the end of the frame.
pub var just_mouse_up: bool = false;

/// Chunk the mouse is on; only updated when `updateMouseBlock()` is called.
/// Assume to be invalid if null.
pub var mouse_chunk_coord: ?world.Coordinate = null;
/// Subpixel of the chunk the mouse is on; only updated when `updateMouseBlock()` is called.
/// Assume to be invalid if null.
pub var mouse_subpixel: ?dw.utils.Vec2u = null;
/// X block location the mouse is on (within the chunk).
/// Assume to be invalid if `mouse_chunk` or `mouse_subpixel` are null.
pub var mouse_block_x: u4 = 0;
/// Y block location the mouse is on (within the chunk).
/// Assume to be invalid if `mouse_chunk` or `mouse_subpixel` are null.
pub var mouse_block_y: u4 = 0;
/// How many chunks the mouse sits from the player's own chunk, on each axis.
/// Assume to be invalid if `mouse_chunk_coord` is null.
pub var mouse_chunk_offset: [2]i64 = .{ 0, 0 };
/// Whether the mouse's block position changed.
/// An out-of-bounds coordinate sets this to true.
/// Reset in `handleMining()`, called from `handleTick()`.
pub var block_position_changed = true;

/// Point coordinate of the mouse (based on the UV).
/// Assume to be invalid if values are negative (both will be -1.0 if invalid).
pub var uv_position: dw.utils.Vec2f = .{ -1.0, -1.0 };

/// Requests a mouse cursor type in a way that avoids UI races or similar issues.
/// The request only lands if the new type has a priority at or above the active one.
pub fn requestCursorType(new_type: CursorType) void {
    if (new_type.takesPrecedenceOver(cursor_type)) {
        cursor_type = new_type;
    }
}

/// Helper to try capturing a down click for a specific UI category.
/// Only sets `click_focus` if a pointerdown event was just fired and `is_hovered` is true.
///
/// Returns whether the "capture" was successful.
pub fn tryCaptureDown(category: ClickFocus, is_hovered: bool) bool {
    if (just_mouse_down and is_hovered) {
        if (click_focus == .none or click_focus == .canvas or click_focus == category) {
            click_focus = category;
            return true;
        }
    }
    return false;
}

/// Helper to check if a valid, click-up sequence finished on a specific UI element.
/// Verifies the click both started and ended on the specified category.
pub fn isClicked(category: ClickFocus, is_hovered: bool) bool {
    return just_mouse_up and released_focus == category and is_hovered;
}

/// Handles a fresh pointerdown across every interactive UI layer BEFORE world mining runs.
/// Must be called once per tick, ahead of `mining.handleMiningAndPlacing()` (see `state/tick.zig`).
///
/// `handleMouse()` optimistically sets `click_focus = .canvas` on pointerdown.
/// Without this pass, a first-frame click goes to whichever of the render and the logical tick runs first.
/// That is not a thing to leave to chance.
///
/// Categories are visited in enum order (highest priority first);
/// the first hovered layer claims the click, matching `ClickFocus` precedence.
pub fn processDownCaptures() void {
    if (!just_mouse_down) return;
    inline for (@typeInfo(ClickFocus).@"enum".fields) |field| {
        switch (@as(ClickFocus, @enumFromInt(field.value))) {
            // not interactive layers: .none is idle, .canvas is the fallback owner set on pointerdown
            .none, .canvas => {},
            .indicator => _ = tryCaptureDown(
                .indicator,
                dw.indicators.isHoveringIndicator(),
            ),
            .inventory => _ = tryCaptureDown(
                .inventory,
                inventory.getHoveredInventorySprite() != null,
            ),
            .smelting => _ = tryCaptureDown(
                .smelting,
                @import("../menus/furnace.zig").isHoveringOnMenu(),
            ),
            .crafting => _ = tryCaptureDown(
                .crafting,
                @import("../menus/corecraft.zig").isHoveringOnMenu(),
            ),
            .loot => _ = tryCaptureDown(
                .loot,
                @import("../menus/loot.zig").isHoveringOnMenu(),
            ),
            // intentionally non-exhaustive to catch errors
        }
    }
}

/// Handles mouse logic, where `x` and `y` values are between 0-1, acting like a UV over the whole canvas from HTML.
/// Action 0 (LEFT CLICK) : pointermove
/// Action 1 (LEFT CLICK) : pointerdown
/// Action 2 (LEFT CLICK) : pointerup
/// Action 3 (RIGHT CLICK): pointerdown
/// Action 4 (RIGHT CLICK): pointerup
/// Action 5 (INVALIDATE) : N/A (blur/resize happened)
pub fn handleMouse(x: f64, y: f64, action: u32) void {
    uv_position = .{ x, y };

    if (action == 1 or action == 3) {
        just_mouse_down = true;
        click_focus = .canvas;
    } else if (action == 2 or action == 4 or action == 5) {
        if (action == 2 or action == 4) {
            just_mouse_up = true;
            released_focus = click_focus;
        }
        click_focus = .none;
    }
    processDownCaptures();
}

/// Resets transient frame transition flags. Called at the end of `updateEntities()`.
pub fn clearFrameFlags() void {
    just_mouse_down = false;
    just_mouse_up = false;
    released_focus = .none;
}

/// Updates the block/chunk the mouse is in for logic.
pub fn updateMouseLocation() void {
    if (uv_position[0] < 0) {
        mouse_chunk_coord = null;
        mouse_subpixel = null;
        return; // position must be invalid!
    }

    const game = &memory.game;
    const screen_dx = (uv_position[0] - 0.5) * SCREEN_WIDTH;
    const screen_dy = (uv_position[1] - 0.5) * SCREEN_HEIGHT;

    const world_dx = screen_dx / game.camera_scale * CHUNK_SIZE; // 1 pixel = 16 subpixels
    const world_dy = screen_dy / game.camera_scale * CHUNK_SIZE;

    const target_sx = game.camera_pos[0] + @as(i64, @intFromFloat(@round(world_dx)));
    const target_sy = game.camera_pos[1] + @as(i64, @intFromFloat(@round(world_dy)));

    const old_coord = mouse_chunk_coord;
    const chunk_offset_x = @divFloor(target_sx, dw.SUBPIXELS_IN_CHUNK);
    const chunk_offset_y = @divFloor(target_sy, dw.SUBPIXELS_IN_CHUNK);

    const player_coord = game.getPlayerCoord();
    if (player_coord.move(.{ chunk_offset_x, chunk_offset_y })) |coord| {
        mouse_chunk_coord = coord;
        mouse_chunk_offset = .{ chunk_offset_x, chunk_offset_y };

        const lx = @mod(target_sx, dw.SUBPIXELS_IN_CHUNK); // no need to use % trick, @mod optimizes down to & instruction
        const ly = @mod(target_sy, dw.SUBPIXELS_IN_CHUNK);
        mouse_subpixel = .{ @intCast(lx), @intCast(ly) };

        const old_x = mouse_block_x;
        const old_y = mouse_block_y;
        mouse_block_x = @intCast(@divFloor(lx, CHUNK_SIZE_SQ));
        mouse_block_y = @intCast(@divFloor(ly, CHUNK_SIZE_SQ));
        block_position_changed =
            mouse_block_x != old_x or
            mouse_block_y != old_y or
            !(old_coord != null and world.Coordinate.eql(coord, old_coord.?));
    } else {
        mouse_chunk_coord = null;
        mouse_subpixel = null;
        block_position_changed = true; // prevent funny edge cases
    }
}

/// Screen-space center of the block the mouse is over, in viewport pixels.
/// Offsets the mouse's own screen position by its subpixel distance to the block center,
/// so only `camera_scale` is needed (no camera interpolation).
///
/// Precondition: `updateMouseLocation()` has been called; null when the mouse is outside the world.
pub fn getMouseBlockCenterPx() ?dw.utils.Vec2f32 {
    const sub = mouse_subpixel orelse return null;

    // block center within the chunk, in subpixels
    const center_x: f64 = @floatFromInt(@as(u32, mouse_block_x) * CHUNK_SIZE_SQ + CHUNK_SIZE_SQ / 2);
    const center_y: f64 = @floatFromInt(@as(u32, mouse_block_y) * CHUNK_SIZE_SQ + CHUNK_SIZE_SQ / 2);

    // 1 screen pixel = CHUNK_SIZE subpixels at camera_scale 1 (see updateMouseLocation())
    const px_per_subpixel = memory.game.camera_scale / CHUNK_SIZE;
    return .{
        @floatCast(uv_position[0] * SCREEN_WIDTH + (center_x - @as(f64, @floatFromInt(sub[0]))) * px_per_subpixel),
        @floatCast(uv_position[1] * SCREEN_HEIGHT + (center_y - @as(f64, @floatFromInt(sub[1]))) * px_per_subpixel),
    };
}

/// Gets what block the mouse is over (assuming `updateMouseLocation()` has been called).
/// Returns null if no block is being hovered over.
/// Takes into account sprite hitbox sizes, such as for mushrooms.
pub fn getMouseBlock() ?memory.Block {
    if (mouse_chunk_coord) |chunk| {
        const block = world.getChunk(chunk).getBlock(mouse_block_x, mouse_block_y);
        const s = block.id;

        // get more intuitive pixel location of the mouse within a sprite, from 0-15
        const loc = (mouse_subpixel.? / dw.utils.Vec2u{ dw.CHUNK_SIZE, dw.CHUNK_SIZE }) %
            dw.utils.Vec2u{ dw.CHUNK_SIZE, dw.CHUNK_SIZE };

        const hitbox = s.props().hitbox;
        // create smaller hitboxes for some decor sprites (with a little bit of leniency involved still)
        if (hitbox == .square_bottom_decor and (loc[0] < 3 or loc[0] >= 13 or loc[1] <= 3)) {
            // some sprites small tree don't take up full horizontal space
            return null;
        } else if (hitbox == .small_bottom_decor and loc[1] <= 9) {
            // if your mouse is over the TOP PART of the mushroom block then that's not part of its "hitbox"
            return null;
        }
        if (hitbox == .large_bottom_decor and loc[1] <= 5) {
            // similar to mushroom but greater valid area, such as for bushes
            return null;
        } else if (hitbox == .ceiling_decor and loc[1] >= 9) {
            // for ceiling flower, it's invalid if your mouse is over the BOTTOM PART instead
            return null;
        } else if (hitbox == .thin_strip and (loc[0] < 4 or loc[0] >= 12)) {
            // plant is fully vertical
            // allow x=0,1,2,3 or 12,13,14,15
            return null;
        }

        // any other type of block returns true by default!
        return block;
    }
    return null;
}
