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
pub var mining_speed: u64 = 8;

/// How much `hp` the tool takes off the block every time `mining_progress` reaches the block's strength.
/// Mining progress accumulates by `mining_speed` every logical.
pub var mining_strength: u4 = 1;

/// Current selected block's HP. Should be from 0-15 normally, and 255 if block is empty.
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
    /// Mining progress accumulates by `mining_speed` every logical.
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

/// Whether the player holds a special tool that can remove otherwise-unmineable installations
/// (crafters, strength `UNMINEABLE_STRENGTH`) and the block structures rest on.
///
/// TODO: I'll have to decide, do we make a pickaxe-strong-enough or hybrid upgrade system instead.
pub var has_structure_tool: bool = false;
const STRUCTURE_STRENGTH = 1000;

/// Updates mining and placing blocks. Should be called from `handleTick()`.
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

        // Is this a structure? do NOT let either the structure or the anchor of the structure (usually the block below) be broken
        if (!inventory.isInCreative() and !has_structure_tool and !block.isEmpty() and
            restsOnProtectedInstallation(
                mouse.mouse_chunk_coord.?,
                mouse.mouse_block_x,
                mouse.mouse_block_y,
            ))
        {
            selected_hp = 255;
            mining_progress = 0;
            return;
        }

        // Are we breaking something, or placing into empty air?
        if (sprite_type.isEmpty() or !block.isEmpty()) {
            // mining or replacing case
            mining_progress += if (logic_speed == 1.0)
                mining_speed
            else
                @as(u64, @intFromFloat(@as(f64, @floatFromInt(mining_speed)) * logic_speed));
            const in_creative = inventory.isInCreative();

            const can_mine_block = in_creative or canMine(pickaxe_type, block.id);

            var strength = getSpriteStrength(block.id) orelse std.math.maxInt(u64);
            if (has_structure_tool and isToolBreakable(block.id)) strength = STRUCTURE_STRENGTH;

            // If the pickaxe lacks the qualifications to mine the block, make it unmineable.
            if (!can_mine_block) {
                strength = std.math.maxInt(u64);
            }

            const unmineable = !in_creative and strength == std.math.maxInt(u64);

            // Chip particles and play sounds while actively mining
            if (!block.isEmpty() and strength > 0) {
                {
                    if (mouse.getMouseBlockCenterPx()) |center| {
                        const power: f32 = @floatFromInt(@intFromEnum(pickaxe_type));
                        // better pickaxes chip more often and in bigger "clusters" in terms of particle FX!
                        dw.particles.maybeSpawnSpriteBurst(
                            0.15 + 0.06 * power,
                            block.id,
                            center,
                            .{
                                .count = if (unmineable)
                                    1
                                else
                                    5 + @as(usize, @intFromEnum(pickaxe_type)) * 2,
                            },
                        );
                    }
                }

                {
                    // Sound effects time!
                    // Instant-mine blocks (such as leaves) collect like decor, so route them to the soft
                    // grassy sound below instead of the repeating pickaxe mining sound despite being foundation.
                    if (block.isFoundation() and !block.isInstantMine()) {
                        @setFloatMode(.optimized);
                        const FRAMES_PER_SOUND = if (in_creative)
                            3
                        else
                            std.math.clamp(240 / (mining_speed - 1) + 1, 4, 30);
                        not_mining_frame = 0;
                        // create a mining sound every so often!
                        if (in_creative or mining_frame % FRAMES_PER_SOUND == 0)
                            dw.sound.playSound(
                                // play 3 possible mining sounds, OR the "can't mine" sound otherwise
                                if (unmineable) 8 else @intCast((mining_frame / FRAMES_PER_SOUND) % 3 + 1),
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
                    // instantly mine (0 value special-case in modifyBlockHp) if block type has no strength
                    if (!in_creative and strength > 0) mining_strength else 0,
                );

                if (was_deleted) {
                    if (!block.isEmpty()) {
                        {
                            // block was deleted, reset not-mining-timer and play a sound if it was decor!
                            not_mining_frame = 0;
                            if (strength == 0) {
                                dw.sound.playSound(
                                    4 + (memory.game.frame % 2),
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
                            if (inventory.removeFromInventory(sprite_type)) { // make sure it's possible to use
                                if (world.modifyBlockType(
                                    mouse.mouse_chunk_coord.?, // mouse block successful already
                                    mouse.mouse_block_x,
                                    mouse.mouse_block_y,
                                    sprite_type,
                                    block, // pre-mined block seeds the ore's underlay/base
                                )) {
                                    // If TRUE, then the block was NOT successfully modified, so revert the selection.
                                    // This fixes funny issues involving de-selection due to invalid placement.
                                    inventory.selected_sprite = sprite_type;
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
        } else if (block.isEmpty() and sprite_type.isInWorld()) {
            // placing into empty air!
            if (inventory.removeFromInventory(sprite_type)) {
                if (world.modifyBlockType(
                    mouse.mouse_chunk_coord.?,
                    mouse.mouse_block_x,
                    mouse.mouse_block_y,
                    sprite_type,
                    block, // empty here (placing into air), so ores fall back to a plain-stone underlay
                )) {
                    // If TRUE, then the block was NOT successfully modified. Revert selection if so.
                    // This fixes funny issues involving instant deselection with invalid placement
                    // (for example: placing your last ceiling flower in an invalid spot would deselect without this)
                    inventory.selected_sprite = sprite_type;
                } else {
                    dw.sound.playSound(
                        6,
                        if (sprite_type.isFoundation()) 0.75 else 0.2,
                        0.1,
                        0.2,
                    );
                }
                selected_hp = 0;
                mining_progress = 0;
            }
        }
    }
}

/// Returns how "strong" a `Sprite` is; how much mining_progress must be contributed to increase `hp` of a block.
inline fn getSpriteStrength(s: Sprite) ?u64 {
    const props = sprite.getSpriteProps(s);
    if (!props.in_world) return null;
    // Unmineable installations (crafters) are honored BEFORE the solidity check so a non-solid
    // crafter is not misread as instant-mineable. A future tool may still remove these (see mineSite).
    if (props.strength == sprite.UNMINEABLE_STRENGTH) return sprite.UNMINEABLE_STRENGTH;
    if (!props.solid or props.instant_mine) return 0;
    if (props.strength == 0) return null;
    return props.strength;
}

/// Whether a block is only removable with the structure tool: an installation flagged
/// `UNMINEABLE_STRENGTH`, as opposed to a permanently unmineable block (edge stone, returns null above).
inline fn isToolBreakable(s: Sprite) bool {
    return sprite.getSpriteProps(s).strength == sprite.UNMINEABLE_STRENGTH;
}

/// Whether the cell at (bx, by) supports a protected installation and so cannot be dug out without the structure tool:
/// an unmineable floor-anchored block resting on it from above,
/// or an unmineable ceiling-anchored one hanging from it below.
/// Either way, breaking the support would cascade the installation out
/// (see `Sprite.supports()`), which the structure tool exists to gate.
fn restsOnProtectedInstallation(coord: world.Coordinate, bx: u4, by: u4) bool {
    const above = if (by > 0)
        world.getBlockAt(coord, bx, by - 1, memory.game.depth)
    else
        world.getBlockAt(coord.moveY(-1) orelse return false, bx, dw.CHUNK_SIZE - 1, memory.game.depth);
    if (above.anchor() == .floor and isToolBreakable(above.id)) return true;

    const below = if (by < dw.CHUNK_SIZE - 1)
        world.getBlockAt(coord, bx, by + 1, memory.game.depth)
    else
        world.getBlockAt(coord.moveY(1) orelse return false, bx, 0, memory.game.depth);
    return below.anchor() == .ceiling and isToolBreakable(below.id);
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
