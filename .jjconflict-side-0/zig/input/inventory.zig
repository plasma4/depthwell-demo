//! Handles logic for inventory management and how it should be drawn.
const std = @import("std");
const dw = @import("../root.zig");
const memory = dw.memory;
const logger = dw.logger;
const sprite = dw.sprite;
const Sprite = sprite.Sprite;
const mouse = dw.mouse;
const palette = @import("../render/sprite_colors.zig");

const Vec2f32 = dw.utils.Vec2f32;
const Coordinate = dw.world.Coordinate;
const addEntity = dw.entity.addEntity;
const drawNumber = dw.entity.drawNumber;

/// Debug option, allowing for unlimited block placement.
/// Use the `isInCreative()` function in order to check for creative mode.
pub var IN_CREATIVE = false;
/// Debug option, changing whether to show all inventory item slots and items or not.
/// Use the `shouldShowAllItems()` function in order to check for this value correctly.
pub const SHOW_ALL_INVENTORY_ITEMS = false;
/// Determines how wide each row of the inventory is (how many slots per row).
pub const INVENTORY_WIDTH = 10;

/// How many frames (logical) before an item enters the player's inventory.
inline fn getMaxItemDropLifespan() u16 {
    return if (isInCreative()) 20 else 100;
}

/// Represents a single dropped item, including its type, position, and frames until addition to inventory.
const DroppedItem = struct {
    /// Which item is dropped.
    id: Sprite,
    /// Which chunk the dropped item is in.
    position: Coordinate,
    /// Which subpixel X-coordinate the dropped item is in within the chunk position.
    /// May be temporarily negative or above 4096.
    subpixel_x: i32,
    /// Which subpixel Y-coordinate the dropped item is in within the chunk position.
    /// May be temporarily negative or above 4096.
    subpixel_y: i32,
    /// The previous chunk coordinate of the dropped item.
    last_position: Coordinate,
    /// The subpixel X-coordinate of the dropped item for the previous frame.
    last_subpixel_x: i32,
    /// The subpixel Y-coordinate of the dropped item for the previous frame.
    last_subpixel_y: i32,
    /// How many frames before the item will be added to the player's inventory.
    frames_left: u16,
    /// Direction of sprite rotation.
    is_clockwise: bool,
};
pub var dropped_items: dw.Fifo(DroppedItem) = .{};

pub inline fn isInCreative() bool {
    return dw.is_debug and IN_CREATIVE;
}
pub inline fn shouldShowAllItems() bool {
    return dw.is_debug and (IN_CREATIVE or SHOW_ALL_INVENTORY_ITEMS);
}

/// Which row the selected sprite is in.
/// Used for finding which active slot should be used and navigated through Q and E keys.
pub var selected_row: u16 = 0;

/// Slice array type for possible slots.
pub const SlotBuffer = [sprite.item_sprite_count + 1]Sprite;

/// Current sprite selected to place.
/// A value of `.none` represents the pickaxe; `.unselected` represents nothing being chosen.
pub var selected_sprite: Sprite = .none;

/// Dense storage: index is `@intFromEnum(Sprite)`, value is the number of that item in the inventory.
pub var inventory_counts: [sprite.max_sprite_value + 1]u64 = @splat(0);

/// Animation progress for each potential slot. Always between 0 (idle) and 1 (fully triggered).
pub var inventory_anim_progress: [sprite.max_sprite_value + 1]f32 = @splat(0.0);

/// Animation progress for the wobble effect of text. Always between -1 and 1; 0 if idle.
pub var inventory_wobble_progress: [sprite.max_sprite_value + 1]f32 = @splat(0.0);

/// Selected sprite as of the previous frame, used to retrigger the name banner's ripple on change.
/// A value of `.none` represents the pickaxe. Set to `.unselected` to force refresh.
pub var last_named_sprite: Sprite = .unselected;
/// Ripple strength of the selected-item name banner. 1 on selection change, decaying to 0 (idle).
pub var name_wave: f32 = 0.0;
/// Free-running phase (radians) driving the name banner's traveling wave.
var name_phase: f32 = 0.0;

/// Resets the selected-item name banner's ripple animation to its idle, page-load state.
/// Called on load so a restored game doesn't inherit the previous session's banner phase.
pub fn resetNameBanner() void {
    last_named_sprite = .unselected;
    name_wave = 0.0;
    name_phase = 0.0;
}

/// Resets all inventory items (unrelated to pickaxes), as well as the name banner animation.
pub fn reset() void {
    @memset(&inventory_counts, 0);
    selected_sprite = .none;
    selected_row = 0;
    resetNameBanner();
}

/// Logs data on what is inside the inventory.
pub fn logInventory() void {
    // .quick and {h} work best here as you don't have to do a bunch of work figuring out formatting
    logger.quick(.{ "{h}Inventory counts", inventory_counts });
    logger.quick(.{ "{h}Selected sprite", selected_sprite });
}

/// Increments the amount of an item (`Sprite` type) in the inventory, bypassing dropping.
pub fn addToInventory(id: Sprite, amount: u64) void {
    const idx = @intFromEnum(id);
    if (idx < inventory_counts.len) {
        inventory_counts[idx] += amount;
        if (inventory_wobble_progress[idx] == 0.0) inventory_wobble_progress[idx] = 1.0;
    }
}

/// Number of dropped item sprites that were created.
var item_count: u64 = 0;

/// Resolves drop strategies for a broken block and spawns the resulting items.
/// Eventually creates a `DroppedItem`.
pub fn dropItem(broken_sprite: Sprite, chunk: Coordinate, block_x: u4, block_y: u4) void {
    const props_data = sprite.getSpriteProps(broken_sprite);
    const drop_cfg = props_data.drops;

    switch (drop_cfg.strategy) {
        .none => {},
        .self => {
            dropSingleItem(broken_sprite, chunk, block_x, block_y);
        },
        .static => {
            for (drop_cfg.static_items) |item_id| {
                dropSingleItem(item_id, chunk, block_x, block_y);
            }
        },
        .dynamic => {
            if (drop_cfg.dynamic_fn) |func| {
                const items = func(chunk, block_x, block_y);
                for (items) |item_id| {
                    dropSingleItem(item_id, chunk, block_x, block_y);
                }
            }
        },
    }
}

/// Computes the relative offset in chunks from `from` to `to`.
/// Returns null if the coordinates are too far apart (over 4096 chunks) or cannot be resolved.
/// Should be used for non-critical logic like dropped items that would be sensitive to teleports.
pub fn getRelativeOffset(from: Coordinate, to: Coordinate) ?dw.utils.Vec2i {
    // Estimate closest wrapped distance
    const dx = @as(i64, @bitCast(to.suffix[0] -% from.suffix[0]));
    const dy = @as(i64, @bitCast(to.suffix[1] -% from.suffix[1]));

    // Sanity limit check
    if (@abs(dx) > 4096 or @abs(dy) > 4096) return null;

    // Verify using native quadrant-handling transitions
    if (from.move(.{ dx, dy })) |moved| {
        if (moved.eql(to)) {
            return .{ dx, dy };
        }
    }
    return null;
}

/// Creates an item drop animation and adds a `DroppedItem`.
fn dropSingleItem(id: Sprite, chunk: Coordinate, block_x: u4, block_y: u4) void {
    // Drop at the center of the block horizontally (+128), and the bottom vertically (+256)
    const px = @as(i32, block_x) * 256 + 128;
    const py = @as(i32, block_y) * 256 + 256;
    // use the visual seed: not secure, tied to specific block coordinate
    const seed = dw.seeding.FastHash.hash2d(
        memory.game.getHashSeed(.visual),
        memory.game.frame,
        item_count,
    );
    item_count +%= 1;
    addToInventory(id, 1);
    dropped_items.addOne(.{
        .id = id,
        .position = chunk,
        .subpixel_x = px + @as(i32, @intCast(seed % 128)) - 64,
        .subpixel_y = py + @as(i32, @intCast(seed / 128 % 128)) - 64,
        .last_position = chunk,
        .last_subpixel_x = px,
        .last_subpixel_y = py,
        .is_clockwise = (seed / (128 * 128) % 2 == 1),
        // monumentally silly code that determines how many frames a block should last
        .frames_left = getMaxItemDropLifespan() * 3 / 4 +
            @as(u16, @intCast((seed / (128 * 128 * 2)) % (getMaxItemDropLifespan() * 1 / 4))),
    }, dw.world.alloc) catch memory.oom();
}

/// Calls `addEntity()` for each element in `dropped_items`, handling camera pan logic.
pub fn addDroppedItemsAsEntities(time_diff: f64) void {
    @setFloatMode(.optimized);
    _ = time_diff;
    const Context = struct {
        fn render_item(_: void, item: *DroppedItem) void {
            const player_coord = memory.game.getPlayerCoord();

            // Resolve relative chunk positions safely using the move-validation helper
            const prev_offset = getRelativeOffset(player_coord, item.last_position) orelse return;
            const curr_offset = getRelativeOffset(player_coord, item.position) orelse return;

            const prev_item_sp_x = prev_offset[0] * 4096 + @as(i64, item.last_subpixel_x);
            const prev_item_sp_y = prev_offset[1] * 4096 + @as(i64, item.last_subpixel_y);

            const curr_item_sp_x = curr_offset[0] * 4096 + @as(i64, item.subpixel_x);
            const curr_item_sp_y = curr_offset[1] * 4096 + @as(i64, item.subpixel_y);

            // Position interpolation uses the +1.0-shifted fraction; zoom below uses the raw one. See dw.chunks.current_dt.
            const dt = dw.chunks.current_dt + 1.0;
            const interp_item_sp_x = @as(f64, @floatFromInt(prev_item_sp_x)) +
                @as(f64, @floatFromInt(curr_item_sp_x - prev_item_sp_x)) * dt;
            const interp_item_sp_y = @as(f64, @floatFromInt(prev_item_sp_y)) +
                @as(f64, @floatFromInt(curr_item_sp_y - prev_item_sp_y)) * dt;

            // Camera interpolated position
            const cam_vel_x = memory.game.camera_pos[0] - memory.game.last_camera_pos[0];
            const cam_vel_y = memory.game.camera_pos[1] - memory.game.last_camera_pos[1];

            // Base the camera on last_camera_pos so items track the world (item position above also interpolates prev->curr).
            const interp_cam_x = @as(f64, @floatFromInt(memory.game.last_camera_pos[0])) + (@as(f64, @floatFromInt(cam_vel_x)) * dt);
            const interp_cam_y = @as(f64, @floatFromInt(memory.game.last_camera_pos[1])) + (@as(f64, @floatFromInt(cam_vel_y)) * dt);

            const delta_x_sp = interp_item_sp_x - interp_cam_x;
            const delta_y_sp = interp_item_sp_y - interp_cam_y;

            // Zoom bases on the current camera_scale, so it takes the RAW fraction (dt - 1.0), not the shifted one.
            const interpolated_zoom = memory.game.camera_scale * std.math.pow(f64, memory.game.camera_scale_change, dt - 1.0);

            // Translate subpixels offset to screen space (1 pixel becomes 16 subpixels!)
            const screen_x: f32 = @floatCast(@as(f64, dw.SCREEN_WIDTH_HALF) + delta_x_sp * (interpolated_zoom / 16.0));
            const screen_y: f32 = @floatCast(@as(f64, dw.SCREEN_HEIGHT_HALF) + delta_y_sp * (interpolated_zoom / 16.0));

            const half_lifespan = getMaxItemDropLifespan() / 2;
            const life_fraction = @min(@as(f32, @floatFromInt(item.frames_left)) / half_lifespan, 1.0);
            // Shrink as it approaches player
            const item_size = if (life_fraction == 1.0) 16.0 else 4.0 + 12.0 * life_fraction;
            const rotation_mult: f32 = if (item.is_clockwise) 1 else -1;
            // Rotate as it flies (so peak)
            const rotation: f32 = if (life_fraction == 1.0) 0.0 else @as(f32, @floatFromInt(half_lifespan - item.frames_left)) *
                (std.math.pi / @as(f32, half_lifespan)) * rotation_mult;

            addEntity(.{
                .sprite = item.id,
                .position = .{ screen_x, screen_y },
                .size = item_size * @as(f32, @floatCast(interpolated_zoom)),
                .rotation = rotation,
                .lcha = .{ 1.0, 0.0, 0.0, @min(life_fraction * 1.8 - 0.8, 0.6) * @as(f32, if (item.id == .water) 0.4 else 1.0) },
            });
        }
    };

    dropped_items.forEach({}, Context.render_item);
}

/// Executes updates for `DroppedItem` entities once every logical frame.
/// Interpolation occurs when rendering.
pub fn tickDroppedItems() void {
    // (ticks happen at 60fps)
    @setFloatMode(.optimized);
    const Context = struct {
        fn update(_: void, item: *DroppedItem) void {
            if (item.frames_left == 0) return;
            item.last_position = item.position;
            item.last_subpixel_x = item.subpixel_x;
            item.last_subpixel_y = item.subpixel_y;

            const player_coord = memory.game.getPlayerCoord();

            // Delete the item if it exceeds 4096 chunks or cannot be resolved
            const offset = getRelativeOffset(player_coord, item.position) orelse {
                item.frames_left = 0;
                return;
            };

            const item_sp_x_float: f64 = @floatFromInt(offset[0] * 4096 + @as(i64, item.subpixel_x));
            const item_sp_y_float: f64 = @floatFromInt(offset[1] * 4096 + @as(i64, item.subpixel_y));

            const target_sp_x = memory.game.player_pos[0];
            const target_sp_y = memory.game.player_pos[1];

            // Magnetic factor (per frame) gradually increases to 100% as frames run out
            const factor = 0.96 / std.math.pow(f64, @as(f64, @floatFromInt(item.frames_left)), 0.8) + 0.04;

            const next_sp_x = item_sp_x_float +
                (@as(f64, @floatFromInt(target_sp_x)) - item_sp_x_float) * factor;
            const next_sp_y = item_sp_y_float +
                (@as(f64, @floatFromInt(target_sp_y)) - item_sp_y_float) * factor;

            const chunk_dx = @as(i64, @intFromFloat(@floor(next_sp_x / 4096.0)));
            const chunk_dy = @as(i64, @intFromFloat(@floor(next_sp_y / 4096.0)));

            if (player_coord.move(.{ chunk_dx, chunk_dy })) |new_coord| {
                item.position = new_coord;
            }

            const rem_x = next_sp_x - @as(f64, @floatFromInt(chunk_dx)) * 4096.0;
            const rem_y = next_sp_y - @as(f64, @floatFromInt(chunk_dy)) * 4096.0;
            item.subpixel_x = @intFromFloat(rem_x);
            item.subpixel_y = @intFromFloat(rem_y);

            item.frames_left -= 1;
        }
    };

    dropped_items.forEach({}, Context.update);

    // Filter and collect items that reached their target at the head of the FIFO
    while (dropped_items.count > 0) {
        const head_item = &dropped_items.buf[dropped_items.head];
        if (head_item.frames_left == 0) {
            // addToInventory(head_item.id);
            _ = dropped_items.pop();
        } else {
            break;
        }
    }
}

/// Decrements the amount of an item in the inventory by 1.
/// Returns whether the removal was successful (as in, if there was at least one item, and the decrement worked).
pub fn removeFromInventory(id: Sprite) bool {
    if (id.isEmpty() or id == .unselected) return false;

    const idx = @intFromEnum(id);
    if (!isInCreative()) {
        const to_remove = if (id == .water) memory.Block.MAX_HP else 1;
        if (idx >= inventory_counts.len or inventory_counts[idx] < to_remove) return false;
        inventory_counts[idx] -= to_remove;

        // if we used the last one, remove it immediately!
        // the amount of water that the player has is rendered by dividing by 15, so this checks out
        if (inventory_counts[idx] < to_remove and selected_sprite == id) {
            selected_sprite = .unselected;
        }
    }
    if (inventory_wobble_progress[idx] == 0.0) inventory_wobble_progress[idx] = -1.0;

    return true;
}

/// Whether `s` occupies a slot right now: the single predicate every slot walk shares, so the palette,
/// the selection index, and the hover test can never disagree about which slot is which.
inline fn hasSlot(s: Sprite) bool {
    if (s.isEmpty()) return false;
    // The right half of a 2x1 pair is placed BY its left half, never chosen;
    // showing it would offer a block that deletes itself the moment it lands (see `world.modifyBlockType()`).
    if (s.isPairedRight()) return false;

    // if we're showing all items, is this item actually placeable?
    if (shouldShowAllItems()) return s.isInWorld();
    // we're not showing all items, does the player have at least one of these?
    // water is stored at x15 internally, so a full block's worth is the minimum that can be placed
    const owned = inventory_counts[@intFromEnum(s)];
    return owned > 0 and (s != .water or owned >= memory.Block.MAX_HP);
}

/// Helper to get the list of sprites currently in the inventory. Creates a temporary buffer in the stack.
/// Always starts with .none, followed by owned foundation sprites sorted by ID.
/// Requires a buffer to prevent dangling pointer (from local array) issues.
pub fn getSpritesInInventory(buffer: *SlotBuffer) []Sprite {
    var count: usize = 1;
    buffer[0] = .none; // slot 0 (pickaxe) must always exist

    // foundation_sprites is already sorted by enum ID because of how it's generated in types/sprite.zig
    // `if`, not a `continue`: leaving an unrolled iteration early is comptime control flow.
    inline for (sprite.possible_item_sprites) |s| {
        if (hasSlot(s)) {
            buffer[count] = s;
            count += 1;
        }
    }

    return buffer[0..count];
}

/// Gets the index of `selected_sprite` in the active slots.
pub fn getSelectedIndex() u16 {
    if (selected_sprite.isEmpty() or selected_sprite == .unselected) return 0;
    var count: usize = 1;
    inline for (sprite.possible_item_sprites) |s| {
        if (hasSlot(s)) {
            if (s == selected_sprite) return @intCast(count);
            count += 1;
        }
    }

    // This shouldn't be possible, unless something bad happened or `SHOW_ALL_INVENTORY_ITEMS` got toggled!
    selected_sprite = .none;
    selected_row = 0;
    return 0;
}

/// Returns the sprite being hovered if the mouse is within any inventory slot hitbox.
pub fn getHoveredInventorySprite() ?Sprite {
    var buffer: SlotBuffer = undefined;
    const active_slots = getSpritesInInventory(&buffer);

    const base_size = 16.0;
    const spacing = 1.25 * base_size;
    const mouse_pos = mouse.uv_position * dw.utils.Vec2f{ dw.SCREEN_WIDTH, dw.SCREEN_HEIGHT };

    for (active_slots, 0..) |active_sprite, i| {
        const col: f32 = @floatFromInt(i % INVENTORY_WIDTH);
        const row: f32 = @floatFromInt(i / INVENTORY_WIDTH);

        const inventory_pos: Vec2f32 = .{ 32 + col * spacing, 32 + row * spacing };

        // Same background sizing logic as drawInventory()
        const is_empty = active_sprite.isEmpty();
        const is_selected = active_sprite == selected_sprite;
        const bg_size: f32 = if (is_selected) base_size * 1.125 else if (is_empty) base_size * 0.9 else base_size;
        const bg_pos = inventory_pos - Vec2f32{ bg_size / 4.0, bg_size / 4.0 };

        const hitbox: dw.geometry.Shape = .roundSquare(
            bg_pos - Vec2f32{ bg_size / 2.0, bg_size / 2.0 },
            bg_size,
            0.2,
        );

        if (hitbox.contains(mouse_pos)) {
            if (active_sprite == .none) {
                // reset pickaxe text animation that shows stats
                if (dw.inventory.name_wave == 0.0 and dw.inventory.last_named_sprite == .none) dw.inventory.last_named_sprite = .unselected;
            }
            return active_sprite;
        }
    }

    return null;
}

/// Draws the inventory slots, wrapping into new rows every 10 items.
pub fn drawInventory(time_diff: f64) void {
    @setFloatMode(.optimized); // safe here, tis all rendering/mouse logic
    const menus = &dw.indicators.menus;
    var buffer: SlotBuffer = undefined;
    const active_slots = getSpritesInInventory(&buffer);
    // logger.quick(.{ dw.mining.selected_hp, inventory_counts });

    const wobble_decay_speed: f32 = 2.0; // controls wobble decay speed
    const wobble_speed: f32 = 10.0; // multiplier of sine of wobble for for values from -1 to 1
    const wobble_size: f32 = 1.0; // how many radians to rotate to the right or left
    const wobble_animation_length: f32 = 800.0; // controls wobble animation ms length
    const size_animation_length: f32 = 200.0; // item/background size animation change ms length
    const base_size = 16.0; // base size of inventory sprites
    const spacing = 1.25 * base_size; // spacing between sprites (must be at least base_size)

    var hovered_inventory_sprite: ?Sprite = null;
    for (active_slots, 0..) |active_sprite, i| {
        // For each slot, find the sprite ID, handle animations, and draw sprite and its shadow
        const acts_as_pickaxe = active_sprite.isEmpty();
        const id = @intFromEnum(active_sprite);
        const is_selected = active_sprite == selected_sprite;

        const target: f32 = if (is_selected) 1.0 else 0.0;
        const animation_speed = @as(f32, @floatCast(time_diff)) / size_animation_length;

        if (inventory_anim_progress[id] < target) {
            inventory_anim_progress[id] = @min(target, inventory_anim_progress[id] + animation_speed);
        } else if (inventory_anim_progress[id] > target) {
            inventory_anim_progress[id] = @max(target, inventory_anim_progress[id] - animation_speed);
        }

        const t_eased = easeBack(inventory_anim_progress[id]);
        const size_normal: f32 = 10.0 / 16.0 * base_size;
        const size_selected: f32 = 12.0 / 16.0 * base_size;
        const current_size = size_normal + (size_selected - size_normal) * t_eased;

        const col: f32 = @floatFromInt(i % INVENTORY_WIDTH);
        const row: f32 = @floatFromInt(i / INVENTORY_WIDTH);

        const inventory_pos: Vec2f32 = .{ 32 + col * spacing, 32 + row * spacing };

        // Background sizing (using is_selected directly for instant feedback on bg)
        const bg_size: f32 = if (is_selected) base_size * 1.125 else if (acts_as_pickaxe) base_size * 0.9 else base_size;
        const bg_pos = inventory_pos - Vec2f32{ bg_size / 4.0, bg_size / 4.0 };

        // replace with pickaxe for UI
        const rendered_sprite: Sprite = if (acts_as_pickaxe)
            @enumFromInt(@intFromEnum(Sprite.pickaxe) + @intFromEnum(dw.mining.pickaxe_type))
        else
            active_sprite;

        addEntity(.{
            .sprite = if (menus.furnace and active_sprite.isOre())
                .inventory_selected_orange
                // make greener if it's in the world, but not an item
            else if (is_selected) .inventory_selected else .inventory,
            .position = bg_pos,
            .size = bg_size,
            .lcha = if (shouldShowAllItems() and !rendered_sprite.isItem())
                .{ 1.0, -0.03, -1.3, 1.0 }
            else
                memory.DEFAULT_ENTITY_LCHA,
        });

        const pos = inventory_pos - Vec2f32{ current_size / 4.0, current_size / 4.0 } - Vec2f32{ 1.0, 1.0 };
        inline for (.{ 0, 1 }) |shadow_i| { // use array literal to make it comptime
            addEntity(.{ // item shadow
                .sprite = rendered_sprite,
                .position = pos - Vec2f32{
                    @cos(std.math.pi / 4.5 - 0.05 * col) * (shadow_i + 1) * 0.8,
                    @sin(std.math.pi / 4.5 - 0.05 * col) * (shadow_i + 1) * 0.8,
                },
                .size = current_size,
                // a little bit of chroma addition and variation here!
                // the shadow is more like the original sprite for stone sprites and much more bland otherwise
                .lcha = .{
                    (if (rendered_sprite.isStone()) (0.9 - shadow_i * 0.15) else (0.7 - shadow_i * 0.15)), // lightness mult
                    0.03 + 0.02 * shadow_i, // a side effect of this is that perfectly gray sprites' shadows become more red
                    0.0, // no hue shift
                    0.4, // opacity
                },
            });
        }

        addEntity(.{ // actual item
            .sprite = rendered_sprite,
            .position = pos,
            .size = current_size,
        });

        const hitbox: dw.geometry.Shape = .roundSquare(
            bg_pos - Vec2f32{ bg_size / 2.0, bg_size / 2.0 },
            bg_size,
            0.2,
        );
        if (hitbox.contains(mouse.uv_position * dw.utils.Vec2f{ dw.SCREEN_WIDTH, dw.SCREEN_HEIGHT })) {
            hovered_inventory_sprite = active_sprite;
        }
    }

    // Only the furnace uses ore dragging, so the drag cursor is furnace-only (crafting has no drag).
    if (mouse.click_focus == .inventory and menus.furnace) {
        mouse.requestCursorType(.grabbing);
    }
    if (hovered_inventory_sprite) |s| {
        // .inventory down-capture is already claimed centrally in mouse.processDownCaptures();
        // this is mainly for slot focus detection
        if (mouse.tryCaptureDown(.inventory, true)) {
            selected_sprite = s;
            selected_row = getSelectedIndex() / 10;
        }

        if (mouse.click_focus.permits(.inventory)) {
            mouse.requestCursorType(if (menus.furnace) .grab else .pointer);
        }
    }

    // Second pass for numbers to ensure they are at the top of inventory rendering
    for (active_slots, 0..) |active_sprite, i| {
        if (active_sprite.isEmpty()) continue;

        const id = @intFromEnum(active_sprite);
        const t_eased = easeBack(inventory_anim_progress[id]);

        const dt = @as(f32, @floatCast(time_diff)) / wobble_animation_length; // delta time in ms
        const wobble_progress = inventory_wobble_progress[id];
        if (wobble_progress != 0) {
            if (inventory_wobble_progress[id] > 0) {
                inventory_wobble_progress[id] = @max(0.0, inventory_wobble_progress[id] - dt * wobble_decay_speed);
            } else {
                inventory_wobble_progress[id] = @min(0.0, inventory_wobble_progress[id] + dt * wobble_decay_speed);
            }
        }
        const size_normal: f32 = 10.0 / 16.0 * base_size;
        const size_selected: f32 = 12.0 / 16.0 * base_size;
        const current_size = size_normal + (size_selected - size_normal) * t_eased;
        const size_vec: Vec2f32 = .{ current_size, current_size };

        const col: f32 = @floatFromInt(i % INVENTORY_WIDTH);
        const row: f32 = @floatFromInt(i / INVENTORY_WIDTH);

        const inventory_pos: Vec2f32 = .{ 32 + col * spacing, 32 + row * spacing };
        const pos = inventory_pos -
            size_vec / Vec2f32{ base_size / 4.0, base_size / 4.0 } -
            Vec2f32{ base_size / 16.0, base_size / 16.0 };

        // number automatically resizes to be smaller for large values!
        var count = inventory_counts[@intFromEnum(active_sprite)];
        if (active_sprite == .water) count /= 15;
        const digit_count_minus_one: f32 = if (count == 0) 1 else std.math.log10_int(count);
        const number_size = base_size * (1.0 + 0.3 * wobble_progress) / (@max(3.0, digit_count_minus_one + 0.5));

        // calculate wobble angle with sine wave (angle is in radians)
        // if the item is implied to be more common (more digit count in the number), then wobble less!
        const item_wobble = inventory_wobble_progress[id];
        const wobble_angle = std.math.sin(item_wobble * wobble_speed) *
            item_wobble * wobble_size / (digit_count_minus_one + 1.0);

        // wrap and convert hue to f32
        // hue is affected by ID in active slots AND wobble angles!
        const color_hue: f32 = @floatCast(@rem(@as(f64, @floatFromInt(i)) * 0.2 - @abs(wobble_angle * 2.0), std.math.tau));

        if (!isInCreative()) {
            drawNumber( // shadow of inventory number
                count,
                pos + Vec2f32{ base_size / 3.5, base_size / 3.5 },
                .{
                    .lcha = .{ 0.5, 0.2, color_hue, 0.8 },
                    .font_size = number_size,
                    .ltr = false,
                    .rotation = wobble_angle, // text wobbles when you mine something!
                },
            );

            drawNumber( // actual value
                count,
                pos + Vec2f32{ base_size / 3.2, base_size / 3.2 },
                .{
                    .lcha = .{ 0.9, 0.2, color_hue, 1.0 },
                    .font_size = number_size,
                    .ltr = false,
                    .rotation = wobble_angle,
                },
            );
        }
    }

    drawSelectedName(time_diff);
}

/// Draws the selected item's name in a banner above the inventory, tinted based on the sprite's most common colors.
/// Text has a vertical ripple effect that retriggers whenever the selection changes and has a neat gradient effect.
fn drawSelectedName(time_diff: f64) void {
    const sprite_to_name = selected_sprite;
    if (sprite_to_name != last_named_sprite) {
        last_named_sprite = sprite_to_name;
        name_wave = 1.0;
    }

    const dt: f32 = @floatCast(time_diff);
    const ripple_length_ms: f32 = if (sprite_to_name.isEmpty()) 2000.0 else 1200.0; // 2 seconds for pickaxe, 1.2s otherwise
    const phase_speed: f32 = 0.008; // radians of traveling-wave phase per ms
    name_wave = @max(0.0, name_wave - dt / ripple_length_ms);
    name_phase += dt * phase_speed;

    if (sprite_to_name == .unselected) return;

    // Display name: the enum tag with underscores shown as spaces; the empty slot is the pickaxe.
    const name = if (sprite_to_name.isEmpty()) blk: {
        var buf: [128]u8 = undefined;
        var stats_buf: [64]u8 = undefined;
        const stats_str = std.fmt.bufPrint(
            &stats_buf,
            " (speed {d}, strength {d})",
            .{ dw.mining.mining_speed, dw.mining.mining_strength },
        ) catch "";

        // from 1.0 to 0.9: stats "progress" for pickaxe goes from 0.0 to 1.0
        // from 0.1 to 0.0: goes from 1.0 to 0.0
        const progress: f32 = if (name_wave > 0.9)
            (1.0 - name_wave) / 0.1
        else if (name_wave < 0.1)
            name_wave / 0.1
        else
            1.0;

        const chars_to_show: usize = @intFromFloat(@round(progress * @as(f32, @floatFromInt(stats_str.len))));
        break :blk std.fmt.bufPrint(
            &buf,
            "pickaxe{s}",
            .{stats_str[0..chars_to_show]},
        ) catch "pickaxe";
    } else sprite_to_name.getName();

    // Tint from the sprite's signature color; the empty slot borrows the equipped pickaxe tile.
    const rendered: Sprite = if (sprite_to_name.isEmpty())
        @enumFromInt(@intFromEnum(Sprite.pickaxe) + @intFromEnum(dw.mining.pickaxe_type))
    else
        sprite_to_name;

    const primary = palette.primaryColorOf(rendered);
    const secondary = palette.secondaryColorOf(rendered);

    const font_size: f32 = 10.0;
    const amplitude = name_wave * 1.5; // peak ripple displacement in px
    const origin: Vec2f32 = .{ 20.0, 14.0 };

    const prim_hue = @rem(primary[2], std.math.tau);
    const second_hue = @rem(secondary[2], std.math.tau);
    var delta = second_hue - prim_hue;

    // Map the difference to the range (-pi, pi) to find the shortest path
    if (delta > std.math.pi) {
        delta -= std.math.tau;
    } else if (delta < -std.math.pi) {
        delta += std.math.tau;
    }

    // Unroll the secondary hue so it is continuous relative to prim_hue
    const target_second_hue = prim_hue + delta;

    // Establish bounds for hue interpolation based on the shortest path
    const hue1 = @min(prim_hue, target_second_hue);
    const hue2 = @max(prim_hue, target_second_hue);

    const prim_light = primary[0];
    const second_light = secondary[0];
    const light1 = @max(@min(prim_light, second_light), 0.4);
    const light2 = @max(@max(prim_light, second_light), 0.4);

    dw.entity.drawStringWave(
        name,
        origin - Vec2f32{ 0.6, 0.6 },
        .{
            .starting_lcha = .{ light1 * 0.35, primary[1] * 1.2, hue1 - 0.2, 0.7 },
            .ending_lcha = .{ light2 * 0.4, secondary[1] * 1.2, hue2, 0.7 },
            .font_size = font_size,
            .phase = name_phase,
            .amplitude = amplitude,
        },
    );
    dw.entity.drawStringWave(
        name,
        origin,
        .{
            .starting_lcha = .{ light1 * 1.05, primary[1] * 1.1, hue1, 1.0 },
            .ending_lcha = .{ light2 * 1.25, secondary[1] * 1.2, hue2 + 0.2, 1.0 },
            .font_size = font_size,
            .phase = name_phase,
            .amplitude = amplitude,
        },
    );
}

/// Back easing function (time-based)
/// Has a slight negative dip before smoothing to the target.
fn easeBack(target: f32) f32 {
    const a = 1.70158;
    const b = a + 1.0;
    return b * target * target * target - a * target * target; // cubic func
}
