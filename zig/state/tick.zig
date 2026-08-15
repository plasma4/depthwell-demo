//! Contains logic to handle tick updates.
const dw = @import("../root.zig");
const inventory = dw.inventory;
const memory = dw.memory;
const KeyBits = dw.KeyBits;

/// Sets if the Z key should increase the depth recursively until D=32 is reached.
var DEBUG_RECURSIVELY_INCREASE_DEPTH = false;
const MAX_AUTO_DEPTH = 32;

/// Nominal logical ticks per second, which `logic_speed` is scaled against
/// (see `logicLoop()` in `src/main.ts`). Used to convert ticks into real seconds.
const TICK_RATE: f64 = 60.0;

/// The root of ALL actions that need to be handled every logical tick.
pub fn handleTick(logic_speed: f64, iterations: u32) void {
    var buffer: inventory.SlotBuffer = undefined;
    const active_slots = inventory.getSpritesInInventory(&buffer);

    // handles M and 0 cases, see code in function for details
    if (KeyBits.isSet(KeyBits.inventory_up, memory.game.keys_pressed_mask)) inventory.selected_row -|= 1;
    if (KeyBits.isSet(KeyBits.inventory_down, memory.game.keys_pressed_mask)) inventory.selected_row += 1;
    if (KeyBits.isSet(KeyBits.mine, memory.game.keys_pressed_mask)) {
        inventory.selected_row = 0;
        inventory.selected_sprite = .none;
    } else {
        const selected_column = KeyBits.getNumber(memory.game.keys_held_mask);
        if (!(inventory.selected_sprite == .unselected and selected_column == 65535)) {
            const INVENTORY_WIDTH = inventory.INVENTORY_WIDTH;
            const slot_len = active_slots.len;
            const current_column = inventory.getSelectedIndex() % INVENTORY_WIDTH;
            inventory.selected_row = @min(
                @as(u16, @intCast(slot_len / INVENTORY_WIDTH)), // zeroth row holds 10 slots, so this works out
                inventory.selected_row,
            );
            if (inventory.selected_row == 0 and selected_column == 0) {
                // reset pickaxe text animation that shows stats
                if (dw.inventory.name_wave == 0.0 and dw.inventory.last_named_sprite == .none) dw.inventory.last_named_sprite = .unselected;
            }
            // get index of selected sprite by checking already selected sprite type
            var selected_id = inventory.selected_row * INVENTORY_WIDTH +
                if (selected_column == 65535) current_column else selected_column;

            // Only allow this selection if the slot actually exists
            if (selected_id >= slot_len) {
                if (selected_id >= INVENTORY_WIDTH) {
                    selected_id -= INVENTORY_WIDTH;
                    inventory.selected_row -= 1;
                }
            } else {
                inventory.selected_sprite = active_slots[selected_id];
            }
        }
    }

    // TODO: in prod, add is_debug here!
    if (DEBUG_RECURSIVELY_INCREASE_DEPTH and memory.game.depth < MAX_AUTO_DEPTH) {
        dw.world.pushLayer(
            memory.game.getPlayerCoord(),
            memory.game.getBlockXInChunk(), // convert a subpixel (0-4095) in a chunk to a block in a chunk (0-15)
            memory.game.getBlockYInChunk(),
        );
        if (memory.game.depth == MAX_AUTO_DEPTH) {
            dw.logger.quick(.{ "{h}Position", memory.game.getPlayerCoord().asDepthCoordinate(memory.game.depth) });
            DEBUG_RECURSIVELY_INCREASE_DEPTH = false;
        }
    }

    // The (inverted) portal indicators are the real way to change depth (see state/portal.zig);
    // these hotkeys stay as a way to skip straight there, and are ignored mid-animation so they
    // cannot push a second transition during one.
    const can_hotkey_depth = dw.dev_menu and !dw.portal.isActive();

    // Z key increases depth. Above the frontier it "retraces" back to already accessed depths!
    // At the frontier it "pushes" a fresh layer and suffix updates accordingly.
    const just_increased_depth = can_hotkey_depth and
        KeyBits.isSet(KeyBits.increase_depth, memory.game.keys_pressed_mask);
    if (just_increased_depth) {
        if (dw.world.canRetrace()) {
            dw.world.retraceInstant();
        } else {
            dw.world.pushLayer(
                memory.game.getPlayerCoord(),
                memory.game.getBlockXInChunk(), // convert a subpixel (0-4095) in a chunk to a block in a chunk (0-15)
                memory.game.getBlockYInChunk(),
            );
        }

        dw.mining.selected_hp = 255;
        dw.mouse.mouse_chunk_coord = null;
    }

    // X: decrease depth (ascend), instantly. The depth left behind becomes frozen for its
    // descendants, but stays fully playable (see world.isAboveFrontier()).
    const just_decreased_depth = can_hotkey_depth and
        !just_increased_depth and
        dw.world.canAscend() and
        KeyBits.isSet(KeyBits.decrease_depth, memory.game.keys_pressed_mask);
    if (just_decreased_depth) {
        dw.world.popLayer();
        dw.mining.selected_hp = 255;
        dw.mouse.mouse_chunk_coord = null;
    }
    const changed_depth = just_increased_depth or just_decreased_depth;

    // update particles
    dw.particles.tick(iterations);

    // Iterations may be > 1 if FPS is low as a correction factor.
    for (0..iterations) |_| {
        dw.player.tickSoftlockFade();
        const descending = dw.portal.isActive(); // portal animation override stuff
        memory.game.bg_time += (logic_speed / TICK_RATE) * dw.portal.backgroundRate();

        if (descending) {
            dw.portal.tick();
        } else {
            // Smelting only advances while the furnace menu is open (paused otherwise).
            if (dw.indicators.menus.furnace) @import("../menus/furnace.zig").updateSmelting();

            // mouse block and mining/placing logic all updated in this function!
            // Every depth plays the same way. An edit above the frontier stays at its own depth
            // (see world.legacy_store), so nothing below it can change
            if (!changed_depth) dw.mining.handleMiningAndPlacing(logic_speed);

            dw.player.move(logic_speed); // logic that moves the player/camera based on keys
            dw.player.tickAnimation(); // advance player sprite animation + facing on the logic tick
            dw.water.tickWater(); // fluid sim

            inventory.tickDroppedItems(); // process item animation ticks and inventory collection!
        }

        memory.game.frame +%= 1;
    }

    // Generate chunks around the SimBuffer in the background.
    dw.world.SimBuffer.precacheChunks(
        memory.game.getPlayerCoord(),
        memory.game.player_velocity,
        2,
        4,
    );
}
