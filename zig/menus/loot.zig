//! Chest loot menu: a 5x2 grid previewing the contents of the opened chest.
//!
//! Opening is routed through a chest's in-world indicator; see `render/indicators.zig`.
//! It calls `open()` with the chest's block position, so the menu knows WHICH chest backs it.
//!
//! Contents are seeded from the block position.
//! A click on any filled slot loots EVERYTHING at once.
const std = @import("std");
const dw = @import("../root.zig");
const util = @import("util.zig");

const Sprite = dw.Sprite;
const Vec2f = dw.utils.Vec2f;
const Vec2f32 = dw.utils.Vec2f32;
const mouse = dw.mouse;
const memory = dw.memory;
const world = dw.world;
const inventory = dw.inventory;
const seeding = dw.seeding;

/// Maximum item stacks a chest can hold (one 5x2 grid).
pub const MAX_LOOT = 10;
/// Fewest stacks a chest rolls.
const MIN_LOOT = 3;

/// One rollable chest drop: an inclusive count range and a relative pick weight.
const LootEntry = struct { item: Sprite, min: u32, max: u32, weight: u32 };

/// The chest drop pool.
/// Weights are relative, and a new row adds a drop.
const loot_table = [_]LootEntry{
    .{ .item = .wood, .min = 4, .max = 12, .weight = 20 },
    .{ .item = .leaves, .min = 3, .max = 8, .weight = 3 },
    .{ .item = .campfire, .min = 1, .max = 1, .weight = 4 },
    .{ .item = .copper_bar, .min = 2, .max = 6, .weight = 10 },
    .{ .item = .iron_bar, .min = 1, .max = 4, .weight = 7 },
    .{ .item = .silver_bar, .min = 1, .max = 3, .weight = 4 },
    .{ .item = .gold_bar, .min = 1, .max = 2, .weight = 2 },
    .{ .item = .quartz, .min = 1, .max = 3, .weight = 6 },
    .{ .item = .amethyst, .min = 1, .max = 2, .weight = 3 },
    .{ .item = .sapphire, .min = 1, .max = 1, .weight = 2 },
};

const total_weight = blk: {
    var sum: u64 = 0;
    for (loot_table) |e| sum += e.weight;
    break :blk sum;
};

/// Salt separating chest-loot rolls from every other consumer of the world seed.
const LOOT_SALT: u64 = 0xC4E5;

/// One filled (or empty, `.none`) loot slot.
const Stack = struct { item: Sprite = .none, count: u32 = 0 };

/// The rolled contents of the currently open chest; slots `[n..]` stay `.none`.
var stacks: [MAX_LOOT]Stack = @splat(.{});
/// Block position of the chest backing the menu; null while no chest is open.
var open_chest: ?dw.indicators.BlockRef = null;

const grid = util.Grid(.{ .len = MAX_LOOT, .cols = 5 });

/// Menu panel size/placement in UV space (top-left aligned), anchored to the bottom-center
/// so it never overlaps the furnace (bottom-left) or corecraft (bottom-right) panels.
const MENU_SIZE: Vec2f32 = grid.SIZE_UV;
const MENU_POS: Vec2f32 = .{ 0.5 - MENU_SIZE[0] / 2.0, 0.96 - MENU_SIZE[1] };

/// Whether the cursor is over the loot panel.
/// Always false while the menu is closed.
pub fn isHoveringOnMenu() bool {
    return util.isHovering(dw.indicators.menus.loot and open_chest != null, MENU_POS, MENU_SIZE);
}

/// Rolls and shows the contents of the chest at `ref`.
/// Called when its indicator toggles the menu open.
pub fn open(ref: dw.indicators.BlockRef) void {
    open_chest = ref;
    rollLoot(ref);
}

/// Forgets the open chest.
/// Called when the menu toggles closed, and during a reset.
pub fn close() void {
    open_chest = null;
}

/// Resets the state of the loot menu.
pub fn reset() void {
    close();
}

/// Deterministically fills `stacks` from the world seed and the chest's block position.
fn rollLoot(ref: dw.indicators.BlockRef) void {
    stacks = @splat(.{});

    var chest_seed = seeding.mixChunkSeeds(
        world.quad_cache.getQuadrantSeed(ref.coord.quadrant, memory.game.depth),
        .{
            ref.coord.suffix[0] *% dw.CHUNK_SIZE +% ref.bx,
            ref.coord.suffix[1] *% dw.CHUNK_SIZE +% ref.by,
        },
        memory.game.depth,
    ).value[0];
    var rng = seeding.ChaCha12.init(&chest_seed);

    const n: usize = @intCast(MIN_LOOT + rng.next() % (MAX_LOOT - MIN_LOOT + 1));
    var filled_slots: usize = 0;

    for (0..n) |_| {
        var roll = rng.next() % total_weight;
        const entry = for (loot_table) |e| {
            if (roll < e.weight) break e;
            roll -= e.weight;
        } else unreachable;

        const rolled_count = entry.min + @as(u32, @intCast(rng.next() % (entry.max - entry.min + 1)));

        // Check if the item type already exists in our filled slots
        var merged = false;
        for (stacks[0..filled_slots]) |*stack| {
            if (stack.item == entry.item) {
                stack.count += rolled_count;
                merged = true;
                break;
            }
        }

        // If it's a new item, assign it to the next empty slot
        if (!merged and filled_slots < MAX_LOOT) {
            stacks[filled_slots] = .{
                .item = entry.item,
                .count = rolled_count,
            };
            filled_slots += 1;
        }
    }
}

/// Grants every stack, removes the chest block into a particle burst, and closes the menu.
fn lootAll(ref: dw.indicators.BlockRef) void {
    for (stacks) |stack| {
        if (stack.item != .none) inventory.addToInventory(stack.item, stack.count);
    }

    dw.particles.spawnSpriteBurst(.chest, dw.indicators.blockScreenPx(ref.coord, ref.bx, ref.by), .{
        .count = @intCast(40 + dw.particles.seed.next() % 16),
        .speed_max = 2.2,
    });

    const prev = world.getBlockAt(ref.coord, ref.bx, ref.by, memory.game.depth);
    _ = world.modifyBlockType(ref.coord, ref.bx, ref.by, .none, prev);
    dw.sound.playSound(10, 1.0, 0.3, 0.1);

    dw.indicators.menus.loot = false;
    close();
}

pub fn draw() void {
    @setFloatMode(.optimized);
    // The menu is only visible/interactive while opened via a chest indicator.
    if (!dw.indicators.menus.loot) return;
    const ref = open_chest orelse {
        // An open flag without a backing chest, such as right after a load, has nothing to show.
        dw.indicators.menus.loot = false;
        return;
    };

    const mouse_px = util.mousePx();

    // Background panel:
    dw.entity.addEntitySized(.{
        .sprite = .rectangle,
        .position = MENU_POS,
        .size = MENU_SIZE,
        // Warm chest brown.
        .lcha = .{ 0.45, 0.12, 1.2, 1.0 },
    });

    // Title icon: the chest itself.
    const title = grid.titleCenterPx(MENU_POS);
    dw.entity.addEntity(.{
        .sprite = .chest,
        .position = .{ @floatCast(title[0]), @floatCast(title[1]) },
        .size = 12.0,
    });

    for (stacks, 0..) |stack, i| {
        const center = grid.slotCenterPx(MENU_POS, i);

        // Slot frame (also drawn under empty slots so the grid shape reads).
        dw.entity.addEntity(.{
            .sprite = .wood_frame,
            .position = .{ @floatCast(center[0]), @floatCast(center[1]) },
            .size = @as(f32, @floatCast(grid.SLOT)),
            .lcha = .{ 0.65, -0.08, 0.0, 1.0 },
        });
        if (stack.item == .none) continue;

        if (util.slotHitbox(center, grid.SLOT).contains(mouse_px)) {
            if (mouse.click_focus.permits(.loot)) mouse.requestCursorType(.pointer);
            // One click takes everything: the chest empties as a unit.
            if (mouse.isClicked(.loot, true)) {
                lootAll(ref);
                return;
            }
        }

        dw.entity.addEntity(.{
            .sprite = stack.item,
            .position = .{ @floatCast(center[0]), @floatCast(center[1]) },
            .size = @as(f32, @floatCast(grid.SLOT - 4.0)),
        });
        if (stack.count > 1) {
            util.drawCount(stack.count, .{ center[0] + 3.0, center[1] + 5.0 }, .{ 0.78, 0.19, 1.2, 1.0 }, 1.0);
        }
    }
}
