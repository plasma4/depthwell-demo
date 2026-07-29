const std = @import("std");
const dw = @import("../root.zig");

const is_debug = dw.is_debug;
const memory = dw.memory;
const procedural = dw.procedural;

const Coordinate = dw.world.Coordinate;

// Drop resolution lives in `state/drops.zig`.
const DropConfig = dw.drops.DropConfig;
const DropHandlers = dw.drops.DropHandlers;

/// Sentinel `strength` marking a block as unmineable by a normal pickaxe (see `getSpriteStrength()`).
/// Distinct from strength 0, which means "unset" basically (see `mining.has_structure_tool`).
/// Chosen as the max so the existing "never reaches strength" mining path already treats it as unmineable.
pub const UNMINEABLE_STRENGTH: u64 = std.math.maxInt(u64);

/// Index where stone-like sprites begin.
pub const STONE_START = 12;
/// Index where stone-like sprites end.
const STONE_END = STONE_START + 18;

/// Index where smelted bar sprites begin.
const BAR_START = STONE_END + 4;

/// Index where ore sprites begin.
pub const ORE_START = BAR_START + 6;

/// Index where gem sprites begin.
pub const GEM_START = ORE_START + 6;

/// Number of gem types.
pub const GEM_COUNT = 7;

/// Index where gem masks (not gem sprites) begin.
pub const MASK_START = GEM_START + GEM_COUNT * 2;
/// Index after the HP mask ends, and decorations begin.
const DECOR_START = MASK_START + 24;

/// Number of fruit sprites.
const FRUIT_COUNT = 10;
/// ID for `Sprite.gear`, which is after a list of fruit.
const GEAR_ID = DECOR_START + 5 + FRUIT_COUNT;
/// ID for `Sprite.bush`, which is after cornflower.
const BUSH_ID = GEAR_ID + 22;
/// ID for `Sprite.basic_core`, which is after furnaces.
const CORE_ID = BUSH_ID + 14;

/// Index where inventory slot sprites start.
pub const INVENTORY_START = CORE_ID + 22;
/// Index where numbers (0-9) start.
pub const NUMBER_START = INVENTORY_START + 4;
/// ID for `Sprite.particle`, which is after a bunch of character glyphs.
pub const PARTICLE_START = NUMBER_START + 10 + 94;

comptime {
    // modify this value manually, simple sanity check
    if (max_sprite_value != 292) {
        var buf: [64]u8 = undefined;
        @compileError("Max sprite value of " ++
            (std.fmt.bufPrint(&buf, "{d}", .{max_sprite_value}) catch unreachable) ++
            " unexpected!");
    }
}

/// Sprite IDs with numbers based on their location in the sprite sheet.
pub const Sprite = enum(u16) {
    /// Empty (air) sprite.
    none = 0,
    /// Sprite of the player (4 variations).
    player = 1,
    player_walk1,
    player_walk2,
    player_walk3,
    player_walk4,

    /// Edge stone (2 variations).
    edge_stone = 6,

    wood = 8,
    black_plate,
    white_plate,
    leaves,

    // stone types!
    blue_strange_stone = STONE_START,
    purple_strange_stone,
    blue_stone,
    deep_blue_stone,
    pink_stone,
    purple_stone,
    red_stone,
    bright_red_stone,
    lava_stone,
    mossy_stone,
    seagreen_stone,
    green_stone,
    lime_stone,
    gray_stone,
    ancient_stone,
    sulfuric_stone,
    basalt,
    diorite,
    /// "Plain" stone type, with 2x2 variations to prevent an overly tiling look.
    stone = STONE_END,

    // smelted bars! (item-only product of smelting ore; parallel to the ore range below)
    copper_bar = BAR_START,
    iron_bar,
    silver_bar,
    gold_bar,
    nickel_bar,
    cobalt_bar,

    // ores!
    copper = ORE_START, // notice how these constants help with fixing gaps/misplacements
    iron,
    silver,
    gold,
    nickel,
    cobalt,

    // gems!
    quartz = GEM_START,
    amethyst,
    sapphire,
    emerald,
    ruby,
    aquashard,
    electrit,

    // Internal assets (not valid for placement/foundation)
    gem_mask = MASK_START, // 8 masks
    hp_mask = MASK_START + 8, // 16 masks

    // Decor (THIS IS COUPLED TO WGSL CODE)
    small_tree = DECOR_START,
    /// Left half of the 2x1 big tree; each half is stored as its own block ID and requires its pair beside it
    /// (see the `requires` rules below). The pair always breaks as a unit.
    moss_shrub1,
    /// Right half of `moss_shrub1`; only ever valid directly right of it.
    moss_shrub1_right,
    moss_shrub2,
    /// Right half of `moss_shrub2`; only ever valid directly right of it.
    moss_shrub2_right,
    blemon_fruit = GEAR_ID - FRUIT_COUNT,
    teal_lemon_fruit,
    splittyfruit,
    ruby_candy,
    copperfruit,
    ploopus1,
    ploopus2,
    divato,
    circuspin,
    bacon,
    gear = GEAR_ID,
    gear2,
    digging_stick,
    lathe,
    rock_visual,
    rock, // 2 variations
    purple_rock = GEAR_ID + 7,
    flint,
    flint_visual,
    fiberstone,
    clay,
    cordage,
    plant_haft,
    stone_haft,
    flint_hatchet,
    greenstone_hatchet,
    twinklemoss,
    spiralvine,
    plant_stem,
    cornflower = GEAR_ID + 20, // 2 variations
    bush = BUSH_ID, // 2 variations
    ceiling_flower = BUSH_ID + 2, // 4 variations
    mushroom = BUSH_ID + 6, // 3 variations
    big_mushroom = BUSH_ID + 9, // 3 variations
    forest_furnace = BUSH_ID + 12,
    lava_furnace,
    basic_core = CORE_ID,
    core1 = CORE_ID + 2,
    core2 = CORE_ID + 4,
    core3 = CORE_ID + 6,
    core4 = CORE_ID + 8,
    campfire = CORE_ID + 10, // 4 variations + 4 water variations, 8 total
    campfire_water = CORE_ID + 10 + 4,
    chest = CORE_ID + 10 + 8,
    invportal,
    portal,
    portal_visual = CORE_ID + 10 + 11, // indicator visual variant

    /// Unselected inventory sprite. Looks like a blue rounded rectangle.
    inventory = INVENTORY_START,
    /// Selected (currently used) inventory sprite.
    inventory_selected,
    /// Orange (currently used) inventory sprite to indicate the item inside can be dragged/used.
    inventory_selected_orange,
    /// Wooden-textured rounded rectangle.
    wood_frame,

    text_0 = NUMBER_START, // sprite with text 0

    /// Sprite for a particle; a full white rectangle but with corner pixels cut off.
    particle = PARTICLE_START,
    /// Full rectangle sprite; no corner pixels cut off.
    rectangle,
    /// Simple up-arrow icon.
    arrow,

    /// Quarter portion of a center part of the progress bar that is unfilled.
    progress_small_unfilled = PARTICLE_START + 3,
    /// Quarter portion of a center part of the progress bar that is unfilled.
    progress_small_filled,
    /// Leftmost part of the progress bar.
    progress_left = PARTICLE_START + 5,
    /// Center part of the progress bar.
    progress_center = PARTICLE_START + 10,
    /// Right part of the progress bar.
    progress_right = PARTICLE_START + 15,

    /// Crafting icon.
    craft = PARTICLE_START + 20,

    /// Pickaxe icon.
    pickaxe = PARTICLE_START + 21,
    /// Generic water block (filled). Default internal water type; after all pickaxes.
    water = PARTICLE_START + 21 + (@as(u16, @intCast(@intFromEnum(dw.mining.Tools.gold))) + 1),
    water_icon,

    /// A special type used for mining/inventory logic purposes. Doesn't exist as an actual sprite.
    unselected = 65535,
    _, // non-exhaustive for debugging heatmaps

    /// Gets the readable name of the sprite (pre-computed at compile-time).
    /// Precondition: sprite must be valid with an explicit name in the enum.
    pub inline fn getName(self: Sprite) []const u8 {
        const val = @intFromEnum(self);
        if (val < MAX_SPRITE_ID) return dense_names_table[val];
        if (self == .unselected) return unselected_name;
        unreachable;
    }

    /// Retrieves the fully compile-time property data for this sprite.
    pub inline fn props(self: Sprite) SpriteFlags {
        const val = @intFromEnum(self);
        if (val < MAX_SPRITE_ID) return dense_flags_table[val];
        if (self == .unselected) return unselected_flags;
        return .{};
    }

    /// Determines if the sprite's type is one that should interact with the edge flags and procedural generation.
    /// This returns false for edge stone, unlike `isSolid()`. Assumes invalid block types are impossible.
    pub inline fn isFoundation(self: Sprite) bool {
        return self.props().foundation;
    }

    /// Determines if the sprite's type is a valid block that could exist in any chunk.
    /// Separate from `isItem()`. Includes the empty block, and excludes entities.
    ///
    /// If properties are wrong here, invalid (or unnamed) enums may appear and wreak havoc.
    pub inline fn isInWorld(self: Sprite) bool {
        return self.props().in_world;
    }

    /// Determines if the sprite's type is something that could be in the player's inventory.
    pub inline fn isItem(self: Sprite) bool {
        return self.props().item;
    }

    /// Determines if the sprite's type is considered solid, and should interact with the physics, player, and edge flags.
    /// This returns true for edge stone, unlike `isSolid()`.
    pub inline fn isSolid(self: Sprite) bool {
        return self.props().solid;
    }

    /// Determines if the sprite's type is a liquid (such as water).
    pub inline fn isLiquid(self: Sprite) bool {
        return self.props().liquid;
    }

    /// Determines if the sprite's type is `none` (air/void).
    pub inline fn isEmpty(self: Sprite) bool {
        return self == .none;
    }

    /// Determines if the sprite is stone (or a variation). Excludes edge stone.
    pub inline fn isStone(self: Sprite) bool {
        return self.props().stone;
    }

    /// Determines if the sprite is an ore.
    pub inline fn isOre(self: Sprite) bool {
        return self.props().ore;
    }

    /// Maps an ore sprite to its smelted bar form.
    /// The bar range is parallel to and sits directly before the ore range,
    /// so the mapping is a constant offset. Precondition: `self.isOre()`.
    pub inline fn oreToBar(self: Sprite) Sprite {
        return @enumFromInt(@intFromEnum(self) - (ORE_START - BAR_START));
    }

    /// Determines if the sprite is a gem.
    pub inline fn isGem(self: Sprite) bool {
        return self.props().gem;
    }

    /// True for ore/gem overlay sprites since those composited over a `base_id` stone underlay.
    /// Ores and gems form one contiguous ID range, so this is a single bounds test rather than two `props()` lookups
    /// (`isOre() or isGem()`); a comptime check tries to keep the ranges in sync.
    pub inline fn isOverlay(self: Sprite) bool {
        const id = @intFromEnum(self);
        return id >= ORE_START and id < GEM_START + GEM_COUNT;
    }

    /// Returns the cascade anchoring rules for this sprite.
    pub inline fn anchor(self: Sprite) AnchorKind {
        return self.props().anchor;
    }

    /// Returns every neighbor cell this sprite requires to stay in the world: its `anchor` constraint
    /// followed by any extra `SpriteProps.requires` entries, flattened into one list at compile-time.
    /// The cascade in `state/world.zig` clears the block as soon as one entry fails.
    pub inline fn supports(self: Sprite) []const Support {
        const val = @intFromEnum(self);
        if (val < MAX_SPRITE_ID) return dense_supports_table[val];
        return &.{};
    }

    /// Returns the broad `Category` classification for this sprite.
    pub inline fn category(self: Sprite) Category {
        return self.props().category;
    }

    /// Determines if the sprite is a heatmap (between types 65000-65256).
    pub inline fn isHeatmap(self: Sprite) bool {
        const id = @intFromEnum(self);
        return is_debug and id >= 65000 and id <= 65256;
    }

    /// Extracts the evolved form of this sprite at compile-time.
    /// If it doesn't evolve, returns itself!
    pub inline fn evolvesTo(self: Sprite) Sprite {
        const val = @intFromEnum(self);
        if (val < MAX_SPRITE_ID) {
            if (dense_props_table[val].evolves_to) |evolution| {
                return evolution;
            }
        }
        return self;
    }

    /// Returns whether a block is empty (air), a liquid, or a waterloggable block (decor/crafter).
    /// Precondition: the sprite is valid.
    pub inline fn isFlowable(self: Sprite) bool {
        return self.isEmpty() or self.isLiquid() or self.isWaterloggable();
    }

    /// Returns whether a sprite is a decoration block.
    /// Precondition: the sprite is valid.
    pub inline fn isDecor(self: Sprite) bool {
        return self.props().category == .decor;
    }

    /// Returns whether a sprite lets water flow through/around it and stores directional waterlogging
    /// (both decor and crafter installations); non-solid placeables that never block liquid.
    /// Precondition: the sprite is valid.
    pub inline fn isWaterloggable(self: Sprite) bool {
        const c = self.props().category;
        return c == .decor or c == .interactive;
    }

    /// Returns whether a sprite is mined instantly like decor despite being solid (such as leaves).
    /// Reads the off-hot-path `SpriteProps` since `instant_mine` is absent from `SpriteFlags`.
    /// Precondition: the sprite is valid.
    pub inline fn isInstantMine(self: Sprite) bool {
        return getSpriteProps(self).instant_mine;
    }

    /// Converts a sprite into an entity ID, handling atlas ID remaps.
    pub inline fn asEntity(self: Sprite) u16 {
        const id = @intFromEnum(self);
        return if (id >= GEM_START and id < GEM_START + GEM_COUNT)
            id + GEM_COUNT
        else if (self == .rock)
            @intFromEnum(Sprite.rock_visual)
        else if (self == .flint)
            @intFromEnum(Sprite.flint_visual)
        else if (self == .portal)
            @intFromEnum(Sprite.portal_visual)
        else if (self.isLiquid())
            id + 1
        else
            // default to the original!
            id;
    }
};

/// Centralized database describing all sprite properties.
/// Rules are checked in order, with later rules overriding earlier ones.
const rules = [_]SpriteRule{
    // Non-stone solid blocks
    .{
        .{ .list = &[_]Sprite{
            .wood,
            .black_plate,
            .white_plate,
        } },
        .{
            .in_world = true,
            .item = true,
            .solid = true,
            .foundation = true,
            .strength = 40,
        },
    },
    // Non-stone solid blocks
    .{
        .{ .single = .leaves },
        .{
            .in_world = true,
            .item = true,
            .solid = true,
            .foundation = true,
            .instant_mine = true,
        },
    },

    // Stone blocks
    .{
        .{ .range = .{ .blue_strange_stone, .stone } },
        .{
            .in_world = true,
            .item = true,
            .solid = true,
            .foundation = true,
            .stone = true,
            .category = .stone,
            .strength = 15,
        },
    },
    // Smelted bars (inventory items only; not placeable in the world)
    .{
        .{ .range = .{ .copper_bar, .cobalt_bar } },
        .{ .item = true, .category = .bar },
    },
    // Edge stone
    .{
        .{ .single = .edge_stone },
        .{ .in_world = true, .solid = true },
    },
    // Liquids
    .{
        .{ .single = .water },
        .{
            .in_world = true,
            .item = true,
            .liquid = true,
        },
    },
    // empty block
    .{
        .{ .single = .none },
        .{ .in_world = true },
    },

    // Fruits and drop overrides
    .{
        .{
            .range = .{ .blemon_fruit, .bacon },
        },
        .{ .item = true },
    },
    .{
        .{ .single = .bush },
        .{
            .strength = 1,
            .drops = .{
                .strategy = .dynamic,
                .dynamic_fn = &DropHandlers.bushDrop,
            },
        },
    },

    // Ores
    .{
        .{ .range = .{ .copper, .cobalt } },
        .{
            .in_world = true,
            .item = true,
            .solid = true,
            .foundation = true,
            .ore = true,
            .category = .ore,
            .strength = 30,
        },
    },
    // Gems
    .{
        .{ .range = .{ .quartz, .electrit } },
        .{
            .in_world = true,
            .item = true,
            .solid = true,
            .foundation = true,
            .gem = true,
            .category = .gem,
            .strength = 15,
        },
    },

    // Ore/gem strengths & capability requirements
    .{
        .{ .single = .copper },
        .{ .required_capabilities = .t0 },
    },
    .{
        .{ .single = .iron },
        .{ .strength = 35, .required_capabilities = .t1 },
    },
    .{
        .{ .single = .silver },
        .{ .strength = 45, .required_capabilities = .t1 },
    },
    .{
        .{ .single = .gold },
        .{ .strength = 60, .required_capabilities = .t2 },
    },
    .{
        .{ .single = .nickel },
        .{ .strength = 70, .required_capabilities = .t2 },
    },
    .{
        .{ .single = .cobalt },
        .{ .strength = 90, .required_capabilities = .t3 },
    },
    .{
        .{ .single = .quartz },
        .{ .required_capabilities = .t1 },
    },
    .{
        .{ .single = .amethyst },
        .{ .strength = 75, .required_capabilities = .t2 },
    },
    .{
        .{ .single = .sapphire },
        .{ .strength = 85, .required_capabilities = .t2 },
    },
    .{
        .{ .single = .emerald },
        .{ .strength = 95, .required_capabilities = .t2 },
    },
    .{
        .{ .single = .ruby },
        .{ .strength = 100, .required_capabilities = .t2 },
    },
    .{
        .{ .single = .aquashard },
        .{ .strength = 120, .required_capabilities = .t3 },
    },
    .{
        .{ .single = .electrit },
        .{ .strength = 130, .required_capabilities = .t3 },
    },

    // Evolution rules on depth increase
    .{
        .{ .single = .mushroom },
        .{ .hitbox = .small_bottom_decor },
    },
    .{
        .{ .single = .mossy_stone },
        .{ .evolves_to = .spiralvine },
    },
    .{
        .{ .single = .purple_strange_stone },
        .{ .evolves_to = .red_stone },
    },
    .{
        .{ .single = .red_stone },
        .{ .evolves_to = .bright_red_stone },
    },
    .{
        .{ .single = .bright_red_stone },
        .{ .evolves_to = .lava_stone },
    },

    // 2x1 big trees. Each half pins the other through `requires`, so the cascade breaks the pair as a unit
    // whichever half goes first; only the base half drops, keeping one `small_tree` per tree.
    .{
        .{ .list = &[_]Sprite{
            .moss_shrub1,
            .moss_shrub2,
        } },
        .{
            .in_world = true,
            .drops = .{
                .strategy = .static,
                .static_items = &[_]Sprite{.small_tree},
            },
        },
    },
    .{
        .{ .list = &[_]Sprite{
            .moss_shrub1_right,
            .moss_shrub2_right,
        } },
        .{
            .in_world = true,
            .drops = .{ .strategy = .none },
        },
    },
    .{
        .{ .single = .moss_shrub1 },
        .{ .requires = &.{.{ .dx = 1, .kind = .exact, .sprite = .moss_shrub1_right }} },
    },
    .{
        .{ .single = .moss_shrub1_right },
        .{ .requires = &.{.{ .dx = -1, .kind = .exact, .sprite = .moss_shrub1 }} },
    },
    .{
        .{ .single = .moss_shrub2 },
        .{ .requires = &.{.{ .dx = 1, .kind = .exact, .sprite = .moss_shrub2_right }} },
    },
    .{
        .{ .single = .moss_shrub2_right },
        .{ .requires = &.{.{ .dx = -1, .kind = .exact, .sprite = .moss_shrub2 }} },
    },

    // Plant with base connection
    .{
        .{ .single = .plant_stem },
        // rests on solid ground OR another `plant_base` directly below it (a self-stacking shaft)
        .{ .requires = &.{.{ .dy = 1, .kind = .solid_or_self }} },
    },
    .{
        .{ .single = .cornflower },
        // the flowering tip: only ever valid directly above a `plant_base`
        .{ .requires = &.{.{ .dy = 1, .kind = .exact, .sprite = .plant_stem }} },
    },

    // Anchor rules!
    // Floor-anchored decorations/interactables
    .{
        .{ .list = &[_]Sprite{
            .rock,
            .purple_rock,
            .flint,
            .bush,
            .mushroom,
            .big_mushroom,
            .small_tree,

            .campfire,
            .forest_furnace,
            .lava_furnace,
            .basic_core,
            .core1,
            .core2,
            .core3,
            .core4,
            .chest,
            .lathe,
            .portal,
        } },
        .{
            .anchor = .floor,
            .in_world = true,
        },
    },

    // Ceiling-anchored items!
    .{
        .{ .list = &[_]Sprite{
            .ceiling_flower,
            .invportal,
        } },
        .{
            .anchor = .ceiling,
            .in_world = true,
        },
    },

    // Unmineable-by-default items. Unmineable by a normal pickaxe and waterloggable
    // Floor anchor rule requirement above
    .{
        .{ .list = &[_]Sprite{
            .campfire,
            .forest_furnace,
            .lava_furnace,
            .basic_core,
            .core1,
            .core2,
            .core3,
            .core4,
            .chest,
            .lathe,
            .invportal,
            .portal,
        } },
        .{
            .category = .interactive,
            .strength = UNMINEABLE_STRENGTH,
        },
    },
    // Normal decor!
    .{
        .{ .list = &[_]Sprite{
            .rock,
            .purple_rock,
            .flint,
            .bush,
            .small_tree,
            .spiralvine,
            .twinklemoss,
            .cornflower,
            .plant_stem,
            .ceiling_flower,
            .mushroom,
            .big_mushroom,
        } },
        .{
            .in_world = true,
            .item = true,
            .category = .decor,
        },
    },
    // Non-item decor: a tree is picked up as the `small_tree` it drops, never as its own halves.
    .{
        .{ .list = &[_]Sprite{
            .moss_shrub1,
            .moss_shrub2,
            .moss_shrub1_right,
            .moss_shrub2_right,
        } },
        .{
            .anchor = .floor,
            .in_world = true,
            .category = .decor,
        },
    },

    // Suspended anchor (like ceiling, but can be directly below itself too)
    .{
        .{ .single = .spiralvine },
        .{ .anchor = .suspended },
    },
    .{
        .{ .single = .twinklemoss },
        .{ .anchor = .suspended },
    },
};

/// Hitbox geometry variants for various block shapes.
pub const HitboxKind = enum(u3) {
    full,
    small_bottom_decor,
    large_bottom_decor,
    ceiling_decor,
    thin_strip,
};

/// Strategy to resolve whether a block was placed in a valid position.
/// Works for all (valid) sprite types.
pub const AnchorKind = enum(u2) {
    /// No requirements: this sprite type can be placed anywhere.
    none = 0,
    /// The sprite type must be directly above a solid block.
    floor = 1,
    /// The sprite type must be directly below a solid block.
    ceiling = 2,
    /// This sprite type must be directly below a solid block or itself.
    suspended = 3,
};

/// What a `Support` entry demands of the neighbor cell it points at.
pub const SupportKind = enum(u2) {
    /// The neighbor must be solid.
    solid,
    /// The neighbor must be solid, or another copy of the sprite being checked (self-stacking chains, like vines).
    solid_or_self,
    /// The neighbor must hold exactly `Support.sprite`.
    exact,
};

/// One neighbor cell a sprite needs in order to stay in the world.
/// - `dx`/`dy` are tile offsets from the block itself: +x is right, +y is DOWN (screen order, like `Coordinate.move()`).
/// - `sprite` is only read for `SupportKind.exact`.
pub const Support = struct {
    dx: i2 = 0,
    dy: i2 = 0,
    kind: SupportKind,
    sprite: Sprite = .none,
};

/// The `Support` list implied by an `AnchorKind`, so that `anchor` and `SpriteProps.requires`
/// collapse into the single list the cascade walks (see `Sprite.supports()`).
fn anchorSupports(a: AnchorKind) []const Support {
    return switch (a) {
        .none => &.{},
        .floor => &.{.{ .dy = 1, .kind = .solid }},
        .ceiling => &.{.{ .dy = -1, .kind = .solid }},
        .suspended => &.{.{ .dy = -1, .kind = .solid_or_self }},
    };
}

/// Broad classification of a sprite, replacing scattered ID-range arithmetic.
/// Add new variants freely; `Category` is `u3`, so up to 8 fit in `SpriteFlags`.
pub const Category = enum(u3) {
    /// No special category (air, masks, UI, water, edge stone, misc solids).
    none = 0,
    stone,
    ore,
    gem,
    /// Smelted bar (inventory-only item).
    bar,
    /// World decoration (non-solid placeable: plants, furniture, interactables).
    /// Assumed to be instantly mineable.
    decor,
    /// Fixed installation (furnace, core, chest, portal).
    /// Unmineable by normal pickaxe and waterloggable like decor (doesn't look like a full block).
    interactive,
};

/// Consolidated properties of each sprite.
pub const SpriteProps = struct {
    /// Backs `Sprite.isInWorld()`: whether this sprite is a valid block that could exist in any chunk.
    in_world: bool = false,
    /// Backs `Sprite.isItem()`: whether this sprite could be in the player's inventory.
    item: bool = false,
    /// Backs `Sprite.isSolid()`: whether this sprite interacts with physics, the player, and edge flags.
    solid: bool = false,
    /// Backs `Sprite.isLiquid()`: whether this sprite is a liquid (such as water).
    liquid: bool = false,
    /// Backs `Sprite.isFoundation()`: whether this sprite interacts with edge flags and procedural generation.
    foundation: bool = false,
    /// Backs `Sprite.isStone()`: whether this sprite is a stone variation. Excludes edge stone.
    stone: bool = false,
    /// Backs `Sprite.isOre()`: whether this sprite is an ore.
    ore: bool = false,
    /// Backs `Sprite.isGem()`: whether this sprite is a gem.
    gem: bool = false,
    /// Backs `Sprite.category()`; see `Category` for what each variant means.
    category: Category = .none,
    /// How much `mining_progress` (see mining.zig) must accumulate before mining hits this block's `hp` once.
    /// 0 means "unset" during rule merging (see `mergeProps()`);
    /// a solid/foundation block left at 0 is treated as unmineable unless `instant_mine` is set.
    strength: u64 = 0,
    /// Pseudo-decor: mined instantly like a `.decor` sprite despite being `solid`/`foundation`.
    /// Only consulted by `mining.getSpriteStrength()`; lives outside `SpriteFlags` since it's off the hot path.
    instant_mine: bool = false,
    /// Backs the entity renderer's hitbox shape lookup; see `HitboxKind`.
    hitbox: HitboxKind = .full,
    /// Backs `Sprite.anchor()`: where this sprite can appear; see `AnchorKind`.
    anchor: AnchorKind = .none,
    /// Neighbor requirements beyond `anchor` (such as the two halves of a 2x1 shrub pinning each other).
    /// Merged with the `anchor` constraint by `Sprite.supports()`; see `Support`.
    requires: []const Support = &.{},
    /// What item(s) this sprite drops when mined; see `DropConfig`.
    drops: DropConfig = .{ .strategy = .self },
    /// If set, the sprite this evolves into at increased depth. See `Sprite.evolvesTo()`.
    evolves_to: ?Sprite = null,
    /// Conditions that must be satisfied to mine this block.
    required_capabilities: dw.mining.MiningCapabilities = .t0,
};

/// Tightly packed 16-bit struct for high-performance, cache-friendly lookups.
/// Mirrors the boolean/enum fields of `SpriteProps` (see those doc comments),
/// minus `strength`, `instant_mine`, `drops`, and `evolves_to`, which are only needed off the hot path.
pub const SpriteFlags = packed struct(u16) {
    in_world: bool = false,
    item: bool = false,
    solid: bool = false,
    liquid: bool = false,
    foundation: bool = false,
    stone: bool = false,
    ore: bool = false,
    gem: bool = false,
    hitbox: HitboxKind = .full, // 3 bits
    anchor: AnchorKind = .none, // 2 bits
    category: Category = .none, // 3 bits (fills the former padding, keeping the struct 16-bit)
};

/// Targeting selector for assigning properties at compile-time.
const Target = union(enum) {
    single: Sprite,
    range: [2]Sprite,
    list: []const Sprite,
};

/// Contains targets describing what to select and what `SpriteProps` to apply to them.
const SpriteRule = struct {
    Target, // unnamed tuples are cool
    SpriteProps,
};

/// Helper function to match target variants at compile-time.
fn matchesTarget(s: Sprite, target: Target) bool {
    switch (target) {
        .single => |t| return s == t,
        .range => |ra| {
            const val = @intFromEnum(s);
            const min_val = @min(@intFromEnum(ra[0]), @intFromEnum(ra[1]));
            const max_val = @max(@intFromEnum(ra[0]), @intFromEnum(ra[1]));
            return val >= min_val and val <= max_val;
        },
        .list => |list| {
            for (list) |t| {
                if (s == t) return true;
            }
            return false;
        },
    }
}

/// Recursively merges specified properties from `src` into the default/destination struct `dest`.
fn mergeProps(dest: *SpriteProps, src: SpriteProps) void {
    if (src.in_world) dest.in_world = src.in_world;
    if (src.item) dest.item = src.item;
    if (src.solid) dest.solid = src.solid;
    if (src.liquid) dest.liquid = src.liquid;
    if (src.foundation) dest.foundation = src.foundation;
    if (src.stone) dest.stone = src.stone;
    if (src.ore) dest.ore = src.ore;
    if (src.gem) dest.gem = src.gem;
    if (src.category != .none) dest.category = src.category;
    if (src.strength != 0) dest.strength = src.strength;
    if (src.instant_mine) dest.instant_mine = src.instant_mine;
    if (src.hitbox != .full) dest.hitbox = src.hitbox;
    if (src.anchor != .none) dest.anchor = src.anchor;
    if (src.requires.len != 0) dest.requires = src.requires;
    if (src.drops.strategy != .self or src.drops.static_items.len != 0 or src.drops.dynamic_fn != null) {
        dest.drops = src.drops;
    }
    if (src.evolves_to != null) dest.evolves_to = src.evolves_to;

    // Merge required capabilities if they deviate from the default (.t0)
    const default_caps: dw.mining.MiningCapabilities = .t0;
    if (!std.meta.eql(src.required_capabilities, default_caps)) {
        dest.required_capabilities = src.required_capabilities;
    }
}

/// Constant-time lookup of precomputed full sprite properties.
pub inline fn getSpriteProps(s: Sprite) SpriteProps {
    const val = @intFromEnum(s);
    if (val < MAX_SPRITE_ID) return dense_props_table[val];
    if (s == .unselected) return unselected_props;
    return SpriteProps{};
}

/// Evaluates compile-time rules to build properties for a specific `Sprite`.
fn getPropsForSprite(comptime s: Sprite) SpriteProps {
    @setEvalBranchQuota(70000);
    var p: SpriteProps = .{};
    for (rules) |rule| {
        if (matchesTarget(s, rule[0])) {
            mergeProps(&p, rule[1]);
        }
    }
    return p;
}

/// Maximum valid sprite ID (exclusive upper bound for dense table).
pub const MAX_SPRITE_ID = blk: {
    @setEvalBranchQuota(1000);
    var max_val: u16 = 0;
    const fields = @typeInfo(Sprite).@"enum".fields;

    for (fields) |field| {
        if (std.mem.eql(u8, field.name, "unselected")) continue;
        if (field.value > max_val) {
            if (field.value >= 60000)
                @compileError("Sprite enum values must not be between the reserved range of 60000-65534.");
            if (field.value >= 16384)
                @compileError("Sprite enum values cannot be greater than 2**14 (save.zig restriction).");
            max_val = @intCast(field.value);
        }
    }
    break :blk max_val + 1; // Make it an exclusive limit
};

/// Constant alias to map perfectly with older reference pointers.
pub const max_sprite_value = MAX_SPRITE_ID - 1;

/// Precomputed full SpriteProps LUT.
const dense_props_table: [MAX_SPRITE_ID]SpriteProps = blk: {
    @setEvalBranchQuota(20000);
    var table: [MAX_SPRITE_ID]SpriteProps = undefined;

    var i: u16 = 0;
    while (i < MAX_SPRITE_ID) : (i += 1) {
        const exists = blk2: {
            const fields = @typeInfo(Sprite).@"enum".fields;
            for (fields) |field| {
                if (field.value == i) break :blk2 true;
            }
            break :blk2 false;
        };

        if (!exists) {
            table[i] = .{};
            continue;
        }

        table[i] = getPropsForSprite(@enumFromInt(i));
    }
    break :blk table;
};

/// Precomputed compact `SpriteFlags` LUT.
const dense_flags_table: [MAX_SPRITE_ID]SpriteFlags = blk: {
    @setEvalBranchQuota(20000);
    var table: [MAX_SPRITE_ID]SpriteFlags = undefined;

    for (0..MAX_SPRITE_ID) |i| {
        const p = dense_props_table[i];
        table[i] = .{
            .in_world = p.in_world,
            .item = p.item,
            .solid = p.solid,
            .liquid = p.liquid,
            .foundation = p.foundation,
            .stone = p.stone,
            .ore = p.ore,
            .gem = p.gem,
            .hitbox = p.hitbox,
            .anchor = p.anchor,
            .category = p.category,
        };
    }
    break :blk table;
};

/// Precomputed `anchor` and `requires` support lists: one flat list per sprite (see `Sprite.supports()`).
const dense_supports_table: [MAX_SPRITE_ID][]const Support = blk: {
    @setEvalBranchQuota(20000);
    var table: [MAX_SPRITE_ID][]const Support = @splat(&.{});

    for (0..MAX_SPRITE_ID) |i| {
        const p = dense_props_table[i];
        const from_anchor = anchorSupports(p.anchor);
        if (p.requires.len == 0) {
            table[i] = from_anchor;
        } else {
            table[i] = from_anchor ++ p.requires;
        }
    }
    break :blk table;
};

/// Cleans a sprite tag name into a human-readable name at compile-time.
fn cleanTagName(comptime raw: []const u8) []const u8 {
    // Calculate the final size first (skipping numbers and " right" suffix)
    var out_len: usize = 0;
    for (raw) |c| {
        if (c >= '0' and c <= '9') continue;
        out_len += 1;
    }

    var temp_buf: [64]u8 = undefined;
    var out_idx: usize = 0;
    for (raw) |c| {
        if (c >= '0' and c <= '9') continue;
        temp_buf[out_idx] = if (c == '_') ' ' else c;
        out_idx += 1;
    }

    const suffix = " right";
    var final_len = out_len;
    if (final_len >= suffix.len and std.mem.eql(u8, temp_buf[final_len - suffix.len .. final_len], suffix)) {
        final_len -= suffix.len;
    }

    // Create the final immutable array inside a comptime block to bypass the boundary
    comptime {
        const final_buf: [final_len]u8 = temp_buf[0..final_len].*;
        return &final_buf;
    }
}

/// Precomputed clean sprite names LUT.
const dense_names_table: [MAX_SPRITE_ID][]const u8 = blk: {
    @setEvalBranchQuota(200000000);
    var table: [MAX_SPRITE_ID][]const u8 = @splat("");

    var i: u16 = 0;
    while (i < MAX_SPRITE_ID) : (i += 1) {
        if (std.enums.tagName(Sprite, @enumFromInt(i))) |str| {
            table[i] = cleanTagName(str);
        }
    }
    break :blk table;
};

/// Sparse fallback value for `.unselected` (65535)
const unselected_name = cleanTagName(@tagName(Sprite.unselected));

/// Sparse fallback values for `.unselected` (65535)
const unselected_props = getPropsForSprite(.unselected);
const unselected_flags: SpriteFlags = .{
    .in_world = unselected_props.in_world,
    .item = unselected_props.item,
    .solid = unselected_props.solid,
    .liquid = unselected_props.liquid,
    .foundation = unselected_props.foundation,
    .stone = unselected_props.stone,
    .ore = unselected_props.ore,
    .gem = unselected_props.gem,
    .hitbox = unselected_props.hitbox,
    .anchor = unselected_props.anchor,
    .category = unselected_props.category,
};

/// The total number of valid sprites that are considered valid items.
pub const item_sprite_count: usize = blk: {
    @setEvalBranchQuota(1e6);
    var count: usize = 0;
    for (0..MAX_SPRITE_ID) |i| {
        if (dense_flags_table[i].in_world or dense_flags_table[i].item) count += 1;
    }
    if (unselected_flags.item) count += 1;
    break :blk count;
};

/// An array of all `Sprite` values that could be items using lookups.
/// Returns a list of sprites that are either `in_world` or `item` tagged.
pub const possible_item_sprites = blk: {
    @setEvalBranchQuota(1e6);
    const fields = @typeInfo(Sprite).@"enum".fields;
    var result: [item_sprite_count]Sprite = undefined;
    var index: usize = 0;

    for (fields) |field| {
        const sprite: Sprite = @enumFromInt(field.value);
        if (sprite.isInWorld() or sprite.isItem()) {
            result[index] = sprite;
            index += 1;
        }
    }
    break :blk result;
};

// Comptime sanity validation check
comptime {
    @setEvalBranchQuota(1e6);
    if ((@as(Sprite, @enumFromInt(65535))).isInWorld())
        @compileError("isInWorld() returned true for the unselected type! Ranges are wrong.");

    // `oreToBar()` relies on the bar range sitting directly before the ore range with the same
    // length, so the mapping is a constant offset. Enforce that here.
    if (ORE_START - BAR_START != GEM_START - ORE_START)
        @compileError("Bar range is not parallel to the ore range; oreToBar() would be wrong.");

    // Equal-length ranges are not enough: the two must also line up name-for-name, or a reordered ore
    // would smelt into someone else's bar. Cheap to check, and it catches an insertion into either range.
    for (ORE_START..GEM_START) |ore_id| {
        const ore: Sprite = @enumFromInt(ore_id);
        if (!std.mem.eql(u8, @tagName(ore.oreToBar()), @tagName(ore) ++ "_bar"))
            @compileError("Ore `" ++ @tagName(ore) ++ "` smelts into `" ++ @tagName(ore.oreToBar()) ++ "`; the bar range drifted out of order.");
    }

    // GEM_COUNT positions MASK_START (and bounds `isOverlay()`), so it must match the actual gem span.
    if (@intFromEnum(Sprite.electrit) - GEM_START + 1 != GEM_COUNT)
        @compileError("GEM_COUNT does not match the quartz..electrit range.");

    // isOverlay() bounds-tests one contiguous ore+gem range; verify it matches the props table exactly.
    var o: u16 = 0;
    while (o < MAX_SPRITE_ID) : (o += 1) {
        const s: Sprite = @enumFromInt(o);
        if (s.isOverlay() != (s.isOre() or s.isGem()))
            @compileError("isOverlay() range drifted from ore/gem props; fix ORE_START/GEM_START/GEM_COUNT.");
    }

    var i: u16 = 0;
    var wentToHeatmap = false;
    while (i < 65535) : (i += 1) {
        if (!wentToHeatmap and i == max_sprite_value + 256) {
            i = 60000;
            wentToHeatmap = true;
        }
        const s: Sprite = @enumFromInt(i);
        if (s.isInWorld()) {
            var is_mapped = false;
            for (@typeInfo(Sprite).@"enum".fields) |field| {
                if (field.value == i) {
                    is_mapped = true;
                    break;
                }
            }
            if (!is_mapped) {
                @compileError("isInWorld() returned true for an unmapped sprite ID! Ranges are wrong.");
            }
        }
    }
}
