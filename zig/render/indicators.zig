//! Draws visual indicators above certain block types and routes indicator clicks to their menus.
//!
//! A single block window scan (see `scanIndicators()`) feeds both the per-frame drawing pass hover testing,
//! so the drawn icon and its clickable hitbox can't ever drift apart.
const std = @import("std");
const dw = @import("../root.zig");

const mouse = dw.mouse;
const memory = dw.memory;
const Sprite = dw.Sprite;
const Vec2f = dw.utils.Vec2f;

/// Contains booleans for all possible menus and whether they are open or not.
const MenusList = struct {
    corecraft: bool = false,
    furnace: bool = false,
    loot: bool = false,

    /// Returns true if any menu is enabled and false otherwise.
    pub fn isAnyEnabled(self: @This()) bool {
        // inline for loops are unrolled at compile-time
        inline for (@typeInfo(@This()).@"struct".fields) |field_info| {
            // Ensure we are only checking boolean fields
            if (field_info.type == bool) {
                if (@field(self, field_info.name)) {
                    return true;
                }
            } else {
                @compileError("Unsupported type in menu list!");
            }
        }
        return false;
    }
};

/// List of menus that could be opened.
pub var menus: MenusList = .{};

/// Which core tiers sit within indicator range of the player this frame; refreshed by drawIndicators().
/// Consumed by future corecraft crafting logic to know which cores (if any) back the menu.
pub const NearbyCores = packed struct {
    off: bool = false,
    core1: bool = false,
    core2: bool = false,
    core3: bool = false,
    core4: bool = false,

    /// True if any powered core (core1-core4) is nearby, as opposed to only .core_off (or nothing).
    pub fn anyPowered(self: @This()) bool {
        return self.core1 or self.core2 or self.core3 or self.core4;
    }
};

/// Core tiers near the player, valid for the current frame only. See NearbyCores.
pub var nearby_cores: NearbyCores = .{};

/// Hue shifts, in radians, for the two depth-changing indicators.
///
/// The slot sprite is white, so hue is ADDED onto it rather than replacing anything
/// (see `DEFAULT_ENTITY_LCHA`). These are tuning knobs!
const PORTAL_SLOT_HUE: f32 = -1.9;
const INVPORTAL_SLOT_HUE: f32 = 1.1;

/// Which menu (if any) an in-world block's indicator opens. Extend by adding a variant plus its rows below.
const IndicatorKind = enum {
    furnace,
    corecraft,
    loot,
    portal,
    invportal,

    /// Classifies a stored block type into the indicator it displays, or null for non-indicator blocks.
    /// Block IDs are stored as the base sprite (variation is render-only), so exact matching is valid here.
    fn fromBlock(id: Sprite) ?IndicatorKind {
        return switch (id) {
            .forest_furnace, .lava_furnace => .furnace,
            .basic_core, .core1, .core2, .core3, .core4 => .corecraft,
            .chest => .loot,
            .portal => .portal,
            // at the base depth there is nothing above to ascend into
            .invportal => if (dw.world.canAscend()) .invportal else null,
            else => null,
        };
    }

    /// Sprite drawn inside the indicator slot as a preview of what the block does.
    fn previewSprite(self: IndicatorKind) Sprite {
        return switch (self) {
            .furnace => .gold_bar,
            .corecraft => .craft,
            .loot => .chest,
            .portal => .portal_visual,
            .invportal => .invportal,
        };
    }

    /// Pointer to this indicator's open/close flag in `menus`, or null when it backs no menu.
    /// A menu-backed kind's `MenusList` field name must match the tag name!
    fn menuFlag(self: IndicatorKind) ?*bool {
        return switch (self) {
            // change the depth rather than opening anything, so they own no flag
            .portal, .invportal => null,
            inline else => |k| &@field(menus, @tagName(k)),
        };
    }

    /// Whether clicking this indicator does anything, for the block it sits on this frame.
    ///
    /// Spectating previous depths is read-only, so every mutating (menu-backed) indicator goes dead.
    /// The two depth indicators stay live: `.invportal` keeps going further back, and ANY `.portal` acts as the way down.
    /// The clicked portal is not entered (that would reframe the depth);
    /// it only asks for the recorded route back, which is why every one of them serves equally.
    ///
    /// See `portal.triggerReturn()`.
    fn clickableAt(self: IndicatorKind, ref: BlockRef) bool {
        _ = ref;
        if (dw.world.isSpectating()) return self == .invportal or self == .portal;
        return self == .portal or self == .invportal or self.menuFlag() != null;
    }

    /// How far away (in blocks) this indicator starts showing, and so how far it can be used from.
    fn maxBlockDistance(self: IndicatorKind) f32 {
        return switch (self) {
            .portal, .invportal => 3.25,
            else => 5.0,
        };
    }

    /// Runs what clicking this indicator does, for kinds that act instead of toggling a menu.
    fn activate(self: IndicatorKind, ref: BlockRef) void {
        switch (self) {
            // Above the deepest depth a portal walks the last ascent back instead of entering itself,
            // landing on the spot that ascent was taken from.
            .portal => if (dw.world.isSpectating())
                dw.portal.triggerReturn(ref.coord, ref.bx, ref.by)
            else
                dw.portal.trigger(ref.coord, ref.bx, ref.by),
            .invportal => dw.portal.triggerAscend(ref.coord, ref.bx, ref.by),
            else => {},
        }
    }
};

/// Clears one kind's open flag along with whatever state that menu hangs off it.
/// A no-op for the kinds that back no menu.
fn closeMenu(comptime kind: IndicatorKind) void {
    const flag = kind.menuFlag() orelse return;
    flag.* = false;
    if (kind == .loot) @import("../menus/loot.zig").close();
}

/// Shuts every menu at once. Needed when a depth transition begins (see `portal.beginTransition()`).
pub fn closeAllMenus() void {
    inline for (@typeInfo(IndicatorKind).@"enum".fields) |field| {
        closeMenu(@enumFromInt(field.value));
    }
}

/// A specific block cell in the world: its chunk plus the block position within it.
/// Handed to indicator visitors (and menus like loot) so a menu can act on the exact block that opened it.
pub const BlockRef = struct { coord: dw.world.Coordinate, bx: u4, by: u4 };

/// Per-frame camera interpolation shared by every indicator, matching the world's position/zoom curves.
const CameraView = struct {
    zoom: f64,
    cam_x: f64,
    cam_y: f64,
    mouse_px: Vec2f,
};

/// On-screen placement and mouse-hit data for one indicator icon, all in viewport pixels.
const IndicatorGeom = struct {
    screen_x: f32,
    screen_y: f32,
    slot_size: f32,
    opacity: f32,
    dx_mouse: f32,
    dy_mouse: f32,
    hitbox: dw.geometry.Shape,
};

/// Computes the shared camera interpolation for this frame.
fn cameraView() CameraView {
    const game = &memory.game;

    // Zoom uses the raw fraction; position uses the +1.0-shifted fraction. See dw.chunks.current_dt.
    const interpolated_zoom = game.camera_scale *
        std.math.pow(f64, game.camera_scale_change, dw.chunks.current_dt);
    const cam_dt = dw.chunks.current_dt + 1.0;

    // Interpolate last_camera_pos toward camera_pos, matching the world's position curve
    const cam_vel_x = game.camera_pos[0] - game.last_camera_pos[0];
    const cam_vel_y = game.camera_pos[1] - game.last_camera_pos[1];

    return .{
        .zoom = interpolated_zoom,
        .cam_x = @as(f64, @floatFromInt(game.last_camera_pos[0])) + (@as(f64, @floatFromInt(cam_vel_x)) * cam_dt),
        .cam_y = @as(f64, @floatFromInt(game.last_camera_pos[1])) + (@as(f64, @floatFromInt(cam_vel_y)) * cam_dt),
        .mouse_px = mouse.uv_position * Vec2f{ dw.SCREEN_WIDTH, dw.SCREEN_HEIGHT },
    };
}

/// Computes an indicator's on-screen geometry for a block at the given chunk-relative cell.
/// Returns null when the block is too far away (>= 5 blocks) to display an icon.
fn indicatorGeom(
    view: CameraView,
    kind: IndicatorKind,
    chunk_dx: i32,
    chunk_dy: i32,
    local_bx: u4,
    local_by: u4,
) ?IndicatorGeom {
    const game = &memory.game;

    // Center subpixels relative to player coordinates
    const block_sub_x = chunk_dx * 4096 + @as(i64, local_bx) * 256 + 128;
    const block_sub_y = chunk_dy * 4096 + @as(i64, local_by) * 256 + 128;

    const dx_sub = block_sub_x - game.player_pos[0];
    const dy_sub = block_sub_y - game.player_pos[1];
    const dist_sq = dx_sub * dx_sub + dy_sub * dy_sub;
    const distance = @sqrt(@as(f64, @floatFromInt(dist_sq)));

    const max_dist = kind.maxBlockDistance() * 256.0; // start showing this many blocks away
    const min_dist = @min(1.5 * 256.0, max_dist * 0.5); // fully scaled close up, never past the cutoff
    if (distance >= max_dist) return null;

    const t: f32 = @floatCast(if (distance <= min_dist) 1.0 else (max_dist - distance) / (max_dist - min_dist));
    const slot_size: f32 = @floatCast((10.0 + 5.0 * t) * game.camera_scale);

    // Position slightly above the physical block (-200 subpixels)
    const delta_x_sp = @as(f64, @floatFromInt(block_sub_x)) - view.cam_x;
    const delta_y_sp = @as(f64, @floatFromInt(block_sub_y - 200)) - view.cam_y;
    const screen_x: f32 = @floatCast(@as(f64, dw.SCREEN_WIDTH_HALF) + delta_x_sp * (view.zoom / 16.0));
    const screen_y: f32 = @floatCast(@as(f64, dw.SCREEN_HEIGHT_HALF) + delta_y_sp * (view.zoom / 16.0));

    return .{
        .screen_x = screen_x,
        .screen_y = screen_y,
        .slot_size = slot_size,
        .opacity = t * 0.9 + 0.1,
        .dx_mouse = @as(f32, @floatCast(view.mouse_px[0])) - screen_x,
        .dy_mouse = @as(f32, @floatCast(view.mouse_px[1])) - screen_y,
        .hitbox = dw.geometry.Shape.roundSquare(
            .{ -slot_size / 2.0, -slot_size / 2.0 },
            slot_size,
            0.2,
        ),
    };
}

/// Scans a local 33x33 block window centered on the player and visits every in-range indicator.
/// `visitor.visit(id, kind, geom, ref)` runs once per displayed indicator; returning true stops the scan early.
fn scanIndicators(view: CameraView, visitor: anytype) void {
    const game = &memory.game;
    const player_coord = game.getPlayerCoord();
    const player_bx = game.getBlockXInChunk();
    const player_by = game.getBlockYInChunk();

    var dy: i32 = -16;
    while (dy <= 16) : (dy += 1) {
        var dx: i32 = -16;
        while (dx <= 16) : (dx += 1) {
            const target_bx = @as(i32, player_bx) + dx;
            const target_by = @as(i32, player_by) + dy;

            const chunk_dx = @divFloor(target_bx, 16);
            const chunk_dy = @divFloor(target_by, 16);
            const local_bx: u4 = @intCast(@mod(target_bx, 16));
            const local_by: u4 = @intCast(@mod(target_by, 16));

            const target_coord = player_coord.move(.{ chunk_dx, chunk_dy }) orelse continue;
            const chunk = dw.world.SimBuffer.get(target_coord) orelse continue;
            const block = chunk.getBlock(local_bx, local_by);

            const kind = IndicatorKind.fromBlock(block.id) orelse continue;
            const geom = indicatorGeom(
                view,
                kind,
                chunk_dx,
                chunk_dy,
                local_bx,
                local_by,
            ) orelse continue;
            const ref: BlockRef = .{ .coord = target_coord, .bx = local_bx, .by = local_by };
            if (visitor.visit(block.id, kind, geom, ref)) return;
        }
    }
}

/// Records that the given core block sits within indicator range this frame.
fn markNearbyCore(id: Sprite) void {
    switch (id) {
        .basic_core => nearby_cores.off = true,
        .core1 => nearby_cores.core1 = true,
        .core2 => nearby_cores.core2 = true,
        .core3 => nearby_cores.core3 = true,
        .core4 => nearby_cores.core4 = true,
        else => {},
    }
}

/// Draws each indicator, routes indicator clicks to menu toggles, and records which menus/cores are live.
const DrawVisitor = struct {
    /// Indicator kinds seen in range this frame; menus without a live indicator autoclose.
    seen: std.EnumSet(IndicatorKind) = std.EnumSet(IndicatorKind).initEmpty(),
    /// Guards against a single click toggling two overlapping indicators at once.
    click_used: bool = false,

    fn visit(self: *DrawVisitor, id: Sprite, kind: IndicatorKind, geom: IndicatorGeom, ref: BlockRef) bool {
        self.seen.insert(kind);
        if (kind == .corecraft) markNearbyCore(id);

        const flag = kind.menuFlag();
        const is_open = if (flag) |f| f.* else false;
        // undo camera scale mult (slot_size is scale-relative)
        const rel_size: f32 = @floatCast(geom.slot_size / @as(f32, @floatCast(memory.game.camera_scale)));

        // Only clickable indicators react; display-only ones (tree) just draw.
        if (kind.clickableAt(ref) and geom.hitbox.contains(.{ geom.dx_mouse, geom.dy_mouse })) {
            // Down-capture for .indicator is claimed centrally in mouse.processDownCaptures()
            // (via isHoveringIndicator), so this frame's click_focus is already settled.

            // Only change mouse appearance if current focus permits UI actions
            if (mouse.click_focus.permits(.indicator)) mouse.requestCursorType(.pointer);

            // Toggle safely when a click both starts and ends on this indicator
            if (!self.click_used and mouse.isClicked(.indicator, true)) {
                self.click_used = true;
                if (flag) |f| {
                    f.* = !f.*;
                    // The loot menu is per-chest: tell it which block backs it (or that it lost one).
                    if (kind == .loot) {
                        const loot = @import("../menus/loot.zig");
                        if (f.*) loot.open(ref) else loot.close();
                    }
                } else kind.activate(ref);
            }
        }

        // Background inventory slot (color shifts while its menu is open)
        dw.entity.addEntity(.{
            // this creates an interesting style, just go with it
            .sprite = if (kind == .furnace or kind == .portal or kind == .invportal) .wood_frame else .wood,
            .position = .{ geom.screen_x, geom.screen_y },
            .size = geom.slot_size,
            .lcha = if (kind == .portal or kind == .invportal)
                // Brightens as the player closes in, to read as "this takes you somewhere";
                // the hue is what separates going down from going up.
                .{
                    0.85 + 0.15 * geom.opacity,
                    0.06 + rel_size * 0.006,
                    if (kind == .portal) PORTAL_SLOT_HUE else INVPORTAL_SLOT_HUE,
                    geom.opacity,
                }
            else if (kind == .furnace)
                // wood style if furnace
                if (is_open)
                    .{ 1.0, rel_size * 0.007, 0.3, geom.opacity }
                else
                    .{ 0.8, -0.1 + rel_size * 0.005, 0.0, geom.opacity }
            else
            // red/pink-ish vibe color instead
            if (is_open)
                .{ 1.0, 0.03 + rel_size * 0.01, -0.9, geom.opacity }
            else
                .{ 0.7, -0.014 + rel_size * 0.005, -0.78, geom.opacity },
        });

        // Mini preview centered inside the container slot
        dw.entity.addEntity(.{
            .sprite = kind.previewSprite(),
            .position = .{ geom.screen_x, geom.screen_y },
            .size = geom.slot_size * 0.8,
            .lcha = .{ if (is_open) 1.0 else 0.8, 0.0, 0.0, geom.opacity },
        });

        return false; // keep scanning; multiple indicators can be on screen
    }
};

/// Iterates active chunks looking for icons to put above blocks and overlays contextual UI indicators.
pub fn drawIndicators() void {
    @setFloatMode(.optimized);
    // A portal anim owns the screen!
    if (dw.portal.isActive()) {
        nearby_cores = .{};
        return;
    }
    const view = cameraView();

    nearby_cores = .{};
    var drawer: DrawVisitor = .{};
    scanIndicators(view, &drawer);

    // A menu whose indicator drifted out of range (or vanished) autocloses.
    // A depth change closes every one of them up front instead (see `closeAllMenus()`).
    const spectating = dw.world.isSpectating();
    inline for (@typeInfo(IndicatorKind).@"enum".fields) |field| {
        const kind: IndicatorKind = @enumFromInt(field.value);
        if (kind.menuFlag()) |flag| {
            if (flag.* and (spectating or !drawer.seen.contains(kind))) closeMenu(kind);
        }
    }
}

/// Screen-space center of a block, in viewport pixels, using this frame's interpolated camera
/// (same position math as `indicatorGeom()`, without the icon's upward offset).
pub fn blockScreenPx(coord: dw.world.Coordinate, bx: u4, by: u4) dw.utils.Vec2f32 {
    const view = cameraView();
    const player_coord = memory.game.getPlayerCoord();
    const chunk_dx: i64 = @bitCast(coord.suffix[0] -% player_coord.suffix[0]);
    const chunk_dy: i64 = @bitCast(coord.suffix[1] -% player_coord.suffix[1]);
    const block_sub_x = chunk_dx * dw.SUBPIXELS_IN_CHUNK + @as(i64, bx) * 256 + 128;
    const block_sub_y = chunk_dy * dw.SUBPIXELS_IN_CHUNK + @as(i64, by) * 256 + 128;
    const zoom_px = view.zoom / 16.0;
    return .{
        @floatCast(@as(f64, dw.SCREEN_WIDTH_HALF) + (@as(f64, @floatFromInt(block_sub_x)) - view.cam_x) * zoom_px),
        @floatCast(@as(f64, dw.SCREEN_HEIGHT_HALF) + (@as(f64, @floatFromInt(block_sub_y)) - view.cam_y) * zoom_px),
    };
}

/// Accumulates whether the cursor is over any active indicator icon.
const HoverVisitor = struct {
    found: bool = false,

    fn visit(self: *HoverVisitor, id: Sprite, kind: IndicatorKind, geom: IndicatorGeom, ref: BlockRef) bool {
        _ = id;
        // Display-only indicators are not clickable, so they never claim indicator focus.
        if (!kind.clickableAt(ref)) return false;
        if (geom.hitbox.contains(.{ geom.dx_mouse, geom.dy_mouse })) {
            self.found = true;
            return true; // stop scanning at the first hit
        }
        return false;
    }
};

/// Checks if the mouse is currently hovering over any active in-world indicator (furnace, core, etc.).
/// Used by `mouse.processDownCaptures()` to claim the `.indicator` click focus.
pub fn isHoveringIndicator() bool {
    @setFloatMode(.optimized);
    if (dw.portal.isActive()) return false;
    var hover: HoverVisitor = .{};
    scanIndicators(cameraView(), &hover);
    return hover.found;
}

const testing = std.testing;

test "the inverted portal indicator appears exactly when there is a depth to ascend into" {
    const saved_depth = memory.game.depth;
    defer memory.game.depth = saved_depth;

    // A freshly spawned player should see no (.invportal) indicator until they have descended at least once.
    memory.game.depth = dw.startup.STARTING_ZOOM_TIMES;
    try testing.expectEqual(@as(?IndicatorKind, null), IndicatorKind.fromBlock(.invportal));

    memory.game.depth = dw.startup.STARTING_ZOOM_TIMES + 1;
    try testing.expectEqual(@as(?IndicatorKind, .invportal), IndicatorKind.fromBlock(.invportal));
    // The portal is unaffected by the floor: descending is always available.
    try testing.expectEqual(@as(?IndicatorKind, .portal), IndicatorKind.fromBlock(.portal));
}
