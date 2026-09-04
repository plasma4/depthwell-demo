//! Handles mining and placing blocks, and tool strength logic.
const std = @import("std");
const dw = @import("../root.zig");
const sprite = dw.sprite;
const Sprite = sprite.Sprite;
const memory = dw.memory;
const inventory = dw.inventory;
const world = dw.world;
const mouse = dw.mouse;

/// How far the player has progressed to increase `hp`.
pub var mining_progress: u64 = 0;

/// How much the player increases `mining_progress` every tick.
/// Must always be positive.
pub var mining_speed: u64 = 8;

/// How much `hp` the tool takes off the block every time `mining_progress` reaches the block's strength.
/// Mining progress accumulates by `mining_speed` every logical tick.
/// Must always be positive.
pub var mining_strength: u4 = 1;

/// Current selected block's HP.
/// Usually 0-15, and 255 when the block is empty.
pub var selected_hp: u8 = 0;

/// Frame for mining (for sound effects); reset when not mining for long enough with `not_mining_frame`.
pub var mining_frame: u64 = 0;

/// Frame count for not mining.
pub var not_mining_frame: u64 = 0;

/// Type of pickaxe equipped.
pub var pickaxe_type: Tools = .stone;

/// Resets all tool data.
pub fn reset() void {
    pickaxe_type = .stone;
    mining_progress = 0;
    mining_speed = 8;
    mining_strength = 1;
    mining_frame = 0;
    selected_hp = 0;
    not_mining_frame = 0;
}

/// List of tools.
pub const Tools = enum {
    stone,
    bronze,
    iron,
    silver,
    gold,
};

/// Table for specific tool properties.
pub const pickaxe_table: std.EnumArray(Tools, ToolProps) = .init(.{
    .stone = .{ .speed = 8, .strength = 1, .capabilities = .t0 },
    .bronze = .{ .speed = 11, .strength = 1, .capabilities = .t1 },
    .iron = .{ .speed = 15, .strength = 1, .capabilities = .t1 },
    .silver = .{ .speed = 12, .strength = 2, .capabilities = .t2 },
    .gold = .{ .speed = 20, .strength = 2, .capabilities = .t3 },
});

/// Struct representing a tool's ability to mine certain types of blocks, or requirements for a block to be mined.
pub const MiningCapabilities = packed struct(u16) {
    /// Tier 0 (lowest-tier, base pickaxe).
    pub const t0: @This() = .{ .tier = 0 };
    /// Tier 1 (can mine basic ores and gems).
    pub const t1: @This() = .{ .tier = 1 };
    /// Tier 2 (less basic).
    pub const t2: @This() = .{ .tier = 2 };
    /// Tier 3 (can mine more advanced gems).
    pub const t3: @This() = .{ .tier = 3 };
    /// Tier 4 (unused).
    pub const t4: @This() = .{ .tier = 4 };
    /// Tier 5 (unused).
    pub const t5: @This() = .{ .tier = 5 };

    /// What tier the tool is (higher is better, and means more blocks can be mined).
    tier: u3 = 0,
    /// (future feature)
    is_chisel: bool = false,

    _pad: u12 = 0,

    /// Returns true if this set of capabilities meets all the requirements.
    pub fn satisfies(self: @This(), reqs: @This()) bool {
        if (self.tier < reqs.tier) return false;
        if (reqs.is_chisel and !self.is_chisel) return false;
        return true;
    }
};

pub const ToolProps = struct {
    /// How much the player increases `mining_progress` every tick.
    speed: u64,
    /// How much `hp` the tool takes off the block every time `mining_progress` reaches the block's strength.
    /// Mining progress accumulates by `mining_speed` every logical tick.
    strength: u4,
    /// Qualitative special properties of this pickaxe
    capabilities: MiningCapabilities = .{},
};

/// Promotes the pickaxe to the next tier, updating active speed and strength values.
pub fn upgradePickaxe() void {
    const next_type: Tools = switch (pickaxe_type) {
        .stone => .bronze,
        .bronze => .iron,
        .iron => .silver,
        .silver => .gold,
        .gold => .gold,
    };
    if (next_type != pickaxe_type) {
        pickaxe_type = next_type;
        const props = pickaxe_table.get(next_type);
        mining_speed = props.speed;
        mining_strength = props.strength;
    }

    // if the pickaxe is selected, we want to do the wobbly animation!
    if (dw.inventory.last_named_sprite == .none) dw.inventory.last_named_sprite = .unselected;
}

/// Evaluates whether a given pickaxe is capable of mining a specific block sprite.
pub fn canMine(tool_type: Tools, target_sprite: Sprite) bool {
    const pickaxe = pickaxe_table.get(tool_type);
    const block_props = sprite.getSpriteProps(target_sprite);

    // Check capability compatibility and tier minimum requirements
    return pickaxe.capabilities.satisfies(block_props.required_capabilities);
}

/// Returns whether the active tools can remove this block.
///
/// `coord`, `bx`, and `by` identify `block` in the live world.
/// This applies pickaxe capability and installation protection rules.
/// It does not apply cursor range or light, because callers can supply their own reach rule.
/// The bounded escape search mines one cardinal block at a time, so its light follows the player.
pub fn canBreak(coord: world.Coordinate, bx: u4, by: u4, block: memory.Block) bool {
    return canBreakWithLookup({}, liveBlockAt, coord, bx, by, block);
}

/// Returns whether the active tools can remove `block` with a supplied current-depth block lookup.
///
/// `block_at()` must return the same world state that contains `block`, or `null` when unavailable.
/// This lets the softlock probe include a placement that has not yet written to `mod_store`.
/// An unavailable support is conservatively not breakable.
/// Cursor range and light are still outside this rule.
pub fn canBreakWithLookup(
    context: anytype,
    comptime block_at: anytype,
    coord: world.Coordinate,
    bx: u4,
    by: u4,
    block: memory.Block,
) bool {
    if (inventory.isInCreative()) return true;
    if (!canMine(pickaxe_type, block.id)) return false;
    const protected = if (!has_structure_tool)
        restsOnProtectedInstallationWithLookup(context, block_at, coord, bx, by)
    else
        false;
    return canBreakWithSupport(block, protected);
}

/// Returns whether the active tools can remove `block` with a known support result.
///
/// `protected_support` is `null` when the support cells are unavailable.
/// This has the same tool and installation rules as `canBreakWithLookup()`.
/// It lets a bounded world probe reuse its resident-cell cache for both the target and support.
pub fn canBreakWithSupport(block: memory.Block, protected_support: ?bool) bool {
    if (inventory.isInCreative()) return true;
    if (!canMine(pickaxe_type, block.id)) return false;
    if (!has_structure_tool and (protected_support orelse return false)) return false;

    var strength = getSpriteStrength(block.id) orelse return false;
    if (has_structure_tool and isToolBreakable(block.id)) strength = STRUCTURE_STRENGTH;
    return strength != std.math.maxInt(u64);
}

/// Returns whether an installation makes its floor or ceiling support require the structure tool.
///
/// This is true only for an unmineable floor- or ceiling-anchored sprite.
pub inline fn protectsSupport(sprite_type: Sprite) bool {
    const anchor = sprite_type.anchor();
    return (anchor == .floor or anchor == .ceiling) and
        sprite.getSpriteProps(sprite_type).strength == sprite.UNMINEABLE_STRENGTH;
}

/// Reads a live block for `canBreak()`.
fn liveBlockAt(_: void, coord: world.Coordinate, bx: u4, by: u4) ?memory.Block {
    return world.getBlockAt(coord, bx, by, memory.game.depth);
}

/// Least player-lit a block may be and still be mineable, on the same 0-255 scale as `Block.light`.
/// Deliberately measured against JUST the player's light (see `lighting.miningLightAt()`).
pub const MIN_MINING_LIGHT: u8 = 48;

/// Whether the block the mouse is over is lit well enough by the player to be mined.
/// Reads the logic-tick flood, never the rendered light, so the answer cannot vary with frame rate.
fn isLitForMining() bool {
    return dw.lighting.miningLightAt(
        mouse.mouse_chunk_offset[0],
        mouse.mouse_chunk_offset[1],
        mouse.mouse_block_x,
        mouse.mouse_block_y,
    ) >= MIN_MINING_LIGHT;
}

/// Whether the player holds a special tool that can remove otherwise-unmineable installations
/// (crafters, strength `UNMINEABLE_STRENGTH`) and the block structures rest on.
///
/// TODO: I'll have to decide, do we make a pickaxe-strong-enough or hybrid upgrade system instead.
pub var has_structure_tool: bool = false;
const STRUCTURE_STRENGTH = 1000;

/// Updates mining and placing blocks. Should be called from `handleTick()`.
/// `logic_speed` should be 1 at a 60FPS default and is unrelated to frame drop correction.
pub fn handleMiningAndPlacing(logic_speed: f64) void {
    mouse.updateMouseLocation(); // update to get correct mouse position data

    if (mouse.block_position_changed) {
        mouse.block_position_changed = false;
        mining_progress = 0;
    }

    // Only allow mining if the click focus is currently dedicated to the world canvas.
    // This prevents drag-clicks from bleeding into mining actions.
    if (mouse.click_focus != .canvas) {
        selected_hp = 255;
        return;
    }

    mouse.updateMouseLocation(); // update to get correct mouse position data

    const sprite_type = inventory.selected_sprite;
    if (sprite_type == .unselected) {
        selected_hp = 255;
        return;
    }

    const mouse_block = mouse.getMouseBlock();
    if (mouse_block) |block| {
        // Don't mine a block of the same type you're trying to place!
        if (sprite_type != .none and block.id == sprite_type) {
            selected_hp = 0;
            mining_progress = 0;
            return;
        }

        var is_protected = false;
        // Is this a structure? do NOT let either the structure or the anchor of the structure (usually the block below) be broken
        if (!inventory.isInCreative() and !has_structure_tool and !block.isEmpty() and
            restsOnProtectedInstallation(
                mouse.mouse_chunk_coord.?,
                mouse.mouse_block_x,
                mouse.mouse_block_y,
            ))
        {
            is_protected = true;
        }

        // Are we breaking something, or placing into empty air?
        const in_creative = inventory.isInCreative();
        if (sprite_type.isEmpty() or !block.isEmpty()) {
            // mining or replacing case
            mining_progress += if (logic_speed == 1.0)
                mining_speed
            else
                @as(u64, @intFromFloat(@as(f64, @floatFromInt(mining_speed)) * logic_speed));

            const can_mine_block = in_creative or canBreak(
                mouse.mouse_chunk_coord.?,
                mouse.mouse_block_x,
                mouse.mouse_block_y,
                block,
            );
            const near_enough = in_creative or isLitForMining();

            var strength = getSpriteStrength(block.id) orelse std.math.maxInt(u64);
            if (has_structure_tool and isToolBreakable(block.id)) strength = STRUCTURE_STRENGTH;

            // If the pickaxe lacks the qualifications to mine the block, make it unmineable.
            // darkness gates the same way: the swing is refused!
            if (!can_mine_block or !near_enough) {
                strength = std.math.maxInt(u64);
            }

            const unmineable = !in_creative and strength == std.math.maxInt(u64);

            // Chip particles and play sounds while actively mining
            if (!block.isEmpty() and strength > 0) {
                {
                    // spawn particles visually!
                    if (near_enough) {
                        if (mouse.getMouseBlockCenterPx()) |center| {
                            const power: f32 = @floatFromInt(@intFromEnum(pickaxe_type));
                            if (unmineable) {
                                // consistent spawn speed
                                if (memory.game.frame % 10 == 0) {
                                    dw.particles.spawnSpriteBurst(
                                        block.id,
                                        center,
                                        .{ .count = 1 },
                                    );
                                }
                            } else {
                                // better pickaxes chip more often and in bigger "clusters" in terms of particle FX!
                                dw.particles.maybeSpawnSpriteBurst(
                                    0.15 + 0.06 * power,
                                    block.id,
                                    center,
                                    .{ .count = 5 + @as(usize, @intFromEnum(pickaxe_type)) * 2 },
                                );
                            }
                        }
                    }
                }

                {
                    // time for more sound effect logic!
                    // Instant-mine blocks (such as leaves) collect like decor so we use the soft sound
                    if (block.isFoundation() and !block.isInstantMine()) {
                        @setFloatMode(.optimized);
                        const FRAMES_PER_SOUND = if (in_creative)
                            3
                        else
                            std.math.clamp(240 / @max((mining_speed - 1), 1) + 1, 4, 30);
                        not_mining_frame = 0;
                        // create a mining sound every so often!
                        if (in_creative or mining_frame % FRAMES_PER_SOUND == 0)
                            dw.sound.playSound(
                                // play 3 possible mining/digging sounds if mineable, the "can't mine" high-frequency sound if truly unmineable,
                                // or the other "can't mine" sound if the player is too far away to reach
                                if (unmineable)
                                    if (!is_protected and near_enough) 11 else 12
                                else if (block.isDigged())
                                    @intCast((mining_frame / FRAMES_PER_SOUND) % 3 + 4)
                                else
                                    @intCast((mining_frame / FRAMES_PER_SOUND) % 3 + 1),
                                if (in_creative) 1 else (0.4 + 0.6 * @as(f32, @floatFromInt(mining_strength))),
                                0.2,
                                if (block.isGem()) 0.7 else if (block.isOre()) 0.55 else 0.45,
                            );
                        mining_frame +%= 1;
                    } else {
                        not_mining_frame +%= 1;
                        if (not_mining_frame == 60) mining_frame = 0;
                        selected_hp = 255;
                    }
                }
            }

            if (in_creative or (strength != std.math.maxInt(u64) and mining_progress >= strength)) {
                mining_progress = 0;
                // sprite type being none check also prevents unneeded memory waste with data update
                const was_deleted = block.isEmpty() or world.modifyBlockHp(
                    mouse.mouse_chunk_coord.?, // mouse block successful, this must be valid then!
                    mouse.mouse_block_x,
                    mouse.mouse_block_y,
                    block,
                    // instantly mine (0 value special-case in modifyBlockHp()) if block type has no strength
                    if (!in_creative and strength > 0) mining_strength else 0,
                );

                if (was_deleted) {
                    if (!block.isEmpty()) {
                        {
                            // block was deleted, reset not-mining-timer and play a sound if it was decor!
                            not_mining_frame = 0;
                            if (strength == 0) {
                                dw.sound.playSound(
                                    7 + (memory.game.frame % 2),
                                    0.3, // 30% volume
                                    0.1,
                                    0.3,
                                );
                            }
                        }

                        { // The block broke: burst of its own colors, larger with better pickaxes.
                            if (mouse.getMouseBlockCenterPx()) |center| {
                                dw.particles.spawnSpriteBurst(block.id, center, .{
                                    .count = 20,
                                    .speed_max = 2.4,
                                });
                            }
                        }

                        // Only auto-replace if the block being mined is different from the held item.
                        if (sprite_type.isInWorld()) {
                            if (inventory.removeFromInventory(sprite_type, inventory.placementUnits(sprite_type))) { // make sure it's possible to use
                                switch (world.modifyBlockType(
                                    mouse.mouse_chunk_coord.?, // mouse block successful already
                                    mouse.mouse_block_x,
                                    mouse.mouse_block_y,
                                    sprite_type,
                                    block, // pre-mined block seeds the ore's underlay/base
                                )) {
                                    .placed => {},
                                    .collapsed => {
                                        // The anchor cascade returned the item as a drop.
                                        inventory.selected_sprite = sprite_type;
                                    },
                                    .rejected_softlock => {
                                        // No world write happened, so return the consumed placement item directly.
                                        inventory.addToInventory(sprite_type, inventory.placementUnits(sprite_type));
                                        inventory.selected_sprite = sprite_type;
                                    },
                                }

                                mining_progress = 0;
                                selected_hp = 0;
                                return;
                            }
                        }
                    }

                    selected_hp = 255;
                } else if (block.isLiquid()) {
                    selected_hp = block.hp + mining_strength;
                }
            }
        } else if (is_protected) {
            selected_hp = 255;
            mining_progress = 0;
        } else if (block.isEmpty() and (in_creative or isLitForMining())) {
            // placing into empty air!
            if (inventory.removeFromInventory(sprite_type, inventory.placementUnits(sprite_type))) {
                switch (world.modifyBlockType(
                    mouse.mouse_chunk_coord.?,
                    mouse.mouse_block_x,
                    mouse.mouse_block_y,
                    sprite_type,
                    block, // empty here (placing into air), so ores fall back to a plain-stone underlay
                )) {
                    .placed => dw.sound.playSound(
                        9,
                        if (sprite_type.isFoundation()) 0.75 else 0.2,
                        0.1,
                        0.2,
                    ),
                    .collapsed => {
                        // The anchor cascade returned the item as a drop.
                        inventory.selected_sprite = sprite_type;
                    },
                    .rejected_softlock => {
                        // No world write happened, so return the consumed placement item directly.
                        inventory.addToInventory(sprite_type, inventory.placementUnits(sprite_type));
                        inventory.selected_sprite = sprite_type;
                    },
                }
                selected_hp = 0;
                mining_progress = 0;
            }
        } else if (sprite_type == .water and block.isLiquid() and block.hp < memory.Block.MAX_HP and
            (in_creative or isLitForMining()))
        {
            // Pouring into a cell that already holds water tops it up to full.
            // Only the units that fit are charged, so the pour neither creates nor destroys water.
            // Without this the click falls through to collection and a partly full cell can never be filled.
            const needed: u64 = memory.Block.MAX_HP - block.hp;
            if (inventory.removeFromInventory(.water, needed)) {
                switch (world.modifyBlockType(
                    mouse.mouse_chunk_coord.?,
                    mouse.mouse_block_x,
                    mouse.mouse_block_y,
                    sprite_type,
                    block,
                )) {
                    .placed => dw.sound.playSound(9, 0.2, 0.1, 0.2),
                    .collapsed => inventory.selected_sprite = sprite_type,
                    .rejected_softlock => {
                        inventory.addToInventory(.water, needed);
                        inventory.selected_sprite = sprite_type;
                    },
                }
                selected_hp = 0;
                mining_progress = 0;
            }
        }
    }
}

/// Returns how "strong" a `Sprite` is; how much mining_progress must be contributed to increase `hp` of a block.
fn getSpriteStrength(s: Sprite) ?u64 {
    const props = sprite.getSpriteProps(s);
    if (!props.in_world) return null;
    // Unmineable installations (crafters) are honored BEFORE the solidity check so a non-solid
    // crafter is not misread as instant-mineable. A future tool may still remove these (see mineSite).
    if (props.strength == sprite.UNMINEABLE_STRENGTH) return sprite.UNMINEABLE_STRENGTH;
    if (!props.solid or props.instant_mine) return 0;
    if (props.strength == 0) return null;
    return props.strength;
}

/// Whether only the structure tool can remove a block.
/// That means an installation flagged `UNMINEABLE_STRENGTH`.
/// A permanently unmineable block, such as edge stone, returns null above instead.
inline fn isToolBreakable(s: Sprite) bool {
    return sprite.getSpriteProps(s).strength == sprite.UNMINEABLE_STRENGTH;
}

/// Whether the cell at (bx, by) supports a protected installation and so cannot be dug out without the structure tool.
fn restsOnProtectedInstallation(coord: world.Coordinate, bx: u4, by: u4) bool {
    return restsOnProtectedInstallationWithLookup({}, liveBlockAt, coord, bx, by) orelse true;
}

/// Tests installation support with a supplied current-depth block lookup.
///
/// `block_at()` must include every pending block change that can affect a support rule.
/// It returns `null` when the supporting cells are unavailable.
fn restsOnProtectedInstallationWithLookup(
    context: anytype,
    comptime block_at: anytype,
    coord: world.Coordinate,
    bx: u4,
    by: u4,
) ?bool {
    const above = if (by > 0)
        block_at(context, coord, bx, by - 1) orelse return null
    else blk: {
        const above_coord = coord.moveY(-1) orelse return false;
        break :blk block_at(context, above_coord, bx, dw.CHUNK_SIZE - 1) orelse return null;
    };
    if (above.anchor() == .floor and protectsSupport(above.id)) return true;

    const below = if (by < dw.CHUNK_SIZE - 1)
        block_at(context, coord, bx, by + 1) orelse return null
    else blk: {
        const below_coord = coord.moveY(1) orelse return false;
        break :blk block_at(context, below_coord, bx, 0) orelse return null;
    };
    return below.anchor() == .ceiling and protectsSupport(below.id);
}

test "canBreakWithLookup protects a pending installation support" {
    const saved_pickaxe = pickaxe_type;
    const saved_structure_tool = has_structure_tool;
    const saved_creative = inventory.IN_CREATIVE;
    defer {
        pickaxe_type = saved_pickaxe;
        has_structure_tool = saved_structure_tool;
        inventory.IN_CREATIVE = saved_creative;
    }

    const PendingInstallation = struct {
        fn blockAt(_: *const @This(), _: world.Coordinate, _: u4, by: u4) ?memory.Block {
            return .makeBasicBlock(if (by == 4) .portal else .stone, 0);
        }
    };

    pickaxe_type = .stone;
    has_structure_tool = false;
    inventory.IN_CREATIVE = false;
    const installation = PendingInstallation{};
    const coord: world.Coordinate = .{ .suffix = .{ 1, 1 }, .quadrant = 0 };
    const support = memory.Block.makeBasicBlock(.stone, 0);

    try std.testing.expect(!canBreakWithLookup(
        &installation,
        PendingInstallation.blockAt,
        coord,
        6,
        5,
        support,
    ));

    has_structure_tool = true;
    try std.testing.expect(canBreakWithLookup(
        &installation,
        PendingInstallation.blockAt,
        coord,
        6,
        5,
        support,
    ));
}

test "canBreakWithLookup honors the active tool tier" {
    const saved_pickaxe = pickaxe_type;
    const saved_structure_tool = has_structure_tool;
    const saved_creative = inventory.IN_CREATIVE;
    defer {
        pickaxe_type = saved_pickaxe;
        has_structure_tool = saved_structure_tool;
        inventory.IN_CREATIVE = saved_creative;
    }

    const NoInstallation = struct {
        fn blockAt(_: *const @This(), _: world.Coordinate, _: u4, _: u4) ?memory.Block {
            return .empty;
        }
    };

    has_structure_tool = false;
    inventory.IN_CREATIVE = false;
    const lookup = NoInstallation{};
    const coord: world.Coordinate = .{ .suffix = .{ 1, 1 }, .quadrant = 0 };
    const amethyst = memory.Block.makeBasicBlock(.amethyst, 0);

    pickaxe_type = .stone;
    try std.testing.expect(!canBreakWithLookup(
        &lookup,
        NoInstallation.blockAt,
        coord,
        6,
        5,
        amethyst,
    ));

    pickaxe_type = .bronze;
    try std.testing.expect(canBreakWithLookup(
        &lookup,
        NoInstallation.blockAt,
        coord,
        6,
        5,
        amethyst,
    ));
}

test "canBreakWithLookup rejects missing support data" {
    const saved_pickaxe = pickaxe_type;
    const saved_structure_tool = has_structure_tool;
    const saved_creative = inventory.IN_CREATIVE;
    defer {
        pickaxe_type = saved_pickaxe;
        has_structure_tool = saved_structure_tool;
        inventory.IN_CREATIVE = saved_creative;
    }

    const Missing = struct {
        fn blockAt(_: *const @This(), _: world.Coordinate, _: u4, _: u4) ?memory.Block {
            return null;
        }
    };

    pickaxe_type = .stone;
    has_structure_tool = false;
    inventory.IN_CREATIVE = false;
    const missing = Missing{};
    const coord: world.Coordinate = .{ .suffix = .{ 1, 1 }, .quadrant = 0 };
    const stone = memory.Block.makeBasicBlock(.stone, 0);

    try std.testing.expect(!canBreakWithLookup(
        &missing,
        Missing.blockAt,
        coord,
        6,
        5,
        stone,
    ));
}

comptime {
    for (@typeInfo(Sprite).@"enum".fields) |field| {
        const field_sprite: Sprite = @enumFromInt(field.value);
        if (std.mem.eql(u8, field.name, "_") or
            std.mem.eql(u8, field.name, "unselected")) continue;

        // If it's a valid, solid block, it MUST have a defined mining strength.
        if (field_sprite.isInWorld() and field_sprite.isFoundation()) {
            if (getSpriteStrength(field_sprite) == null) {
                @compileError("Sprite is valid and foundation but has strength value of 0 in get_sprite_strength: " ++ field.name);
            }
        }
    }
}
