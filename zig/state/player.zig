//! Handles the main player movement and camera logic.
const std = @import("std");
const dw = @import("../root.zig");
const mining = dw.mining;
const memory = dw.memory;
const logger = dw.logger;
const KeyBits = dw.KeyBits;
const main = dw.startup;
const world = dw.world;
const CHUNK_SIZE = dw.CHUNK_SIZE;
const CHUNK_SIZE_SQ = dw.CHUNK_SIZE_SQ;
const SUBPIXELS_IN_CHUNK = dw.SUBPIXELS_IN_CHUNK;

const Vec2i = dw.utils.Vec2i;
const Vec2f = dw.utils.Vec2f;

/// Minimum camera zoom/scale allowed. This is strategically calculated to make sure the default render distance is safe.
/// The `SimBuffer` size automatically adjusts when setting this to a very small value.
///
/// Setting this to a very small value is useful for testing cache validity or overall performance, however.
pub const CAMERA_MIN_ZOOM = if (dw.dev_menu) 0.05 else 0.5;
/// Maximum camera zoom/scale allowed. This is strategically calculated to make sure the player always remains in the viewport.
/// Any more and it would look weird, and camera deadzone would start to no longer work.
pub const CAMERA_MAX_ZOOM = 1.5; // 150%
/// Camera scale the game starts at.
pub const STARTING_CAMERA_SCALE = 1.0; // 100%

/// The base speed of the player.
pub var PLAYER_BASE_SPEED: f64 = 0.60;
/// How much faster the player moves in ghost mode. Applies to all four directions.
pub var GHOST_SPEED_MULT: f64 = 3.0;

/// Whether the player flies and goes through blocks.
pub inline fn isGhost() bool {
    return dw.inventory.isInCreative();
}

/// The speed the player moves at this tick, in subpixels.
inline fn currentSpeed() f64 {
    return if (isGhost()) PLAYER_BASE_SPEED * GHOST_SPEED_MULT else PLAYER_BASE_SPEED;
}
/// How strong the gravity is.
pub var GRAVITY: f64 = 0.25;
/// How high the player jumps.
pub var JUMP_FORCE: f64 = 5.00;
/// Friction of player movement (horizontal).
pub var FRICTION_X: f64 = 0.200;
/// Friction of player movement (vertical).
pub var FRICTION_Y: f64 = 0.025;
/// How many frames the player can still jump after leaving a ledge.
const COYOTE_TIME_FRAMES: u8 = 3;

/// The size of the player's width. The player is assumed to be centered at the bottom as a rectangle.
pub const PLAYER_HITBOX_WIDTH = 160;
/// The size of the player's height. The player is assumed to be centered at the bottom as a rectangle.
pub const PLAYER_HITBOX_HEIGHT = 200;
/// Prevent block-skipping with collisions when travelling quickly.
const CCD_STEP_SIZE = CHUNK_SIZE_SQ;

/// The zoom in/out keys change the zoom multiplier this fast per frame.
const CAMERA_CHANGE_SPEED = if (dw.dev_menu) 1.04 else 1.025;
/// How fast the camera should adjust per frame to the new position. Larger means faster.
const CAMERA_SMOOTHING = 0.25;

/// How far the player has to move before actually panning the camera in sub-pixels (x-axis).
const CAMERA_DEADZONE_X = 10 * dw.CHUNK_SIZE_SQ; // dw.CHUNK_SIZE_SQ means 1 block, basically
/// How far the player has to move before actually panning the camera in sub-pixels (y-axis).
const CAMERA_DEADZONE_Y = 3 * dw.CHUNK_SIZE_SQ;

const pixel_mult: Vec2f = @splat(@floatFromInt(CHUNK_SIZE));
pub var subpixel_accum: Vec2f = .{ 0.0, 0.0 }; // note that vectors are smartly aligned already

/// Determines if the player is on the ground.
var is_grounded: bool = false;

/// Drops the airborne/jump bookkeeping, for teleports that skip `move()` entirely.
/// A portal descent freezes movement for its whole length,
/// so without this the coyote window from before the descent survives it.
pub fn resetMotionState() void {
    is_grounded = false;
    coyote_frames = 0;
    subpixel_accum = .{ 0.0, 0.0 };
}

/// Frames remaining for coyote time jump.
var coyote_frames: u8 = 0;

const Sprite = dw.Sprite;

/// Which way the player is currently facing. Drives the horizontal sprite mirror.
/// Updated from horizontal velocity in `tickAnimation()`; held across idle frames.
pub var facing_right: bool = true;
/// High-level animation states the player can be in. Pick the clip for each in `clips`.
pub const AnimState = enum { idle, walk, jump, fall };

/// Per-state clips. Tune `frame_ticks` to extend the animation duration.
const clips: std.EnumArray(AnimState, Clip) = .init(.{
    .idle = .{
        .frames = &.{
            // peak hacky gamedev code right here
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player_blink,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player,
            .player_blink,
        },
        .frame_ticks = 4,
    },
    .walk = .{ .frames = &.{
        .player_walk1,
        .player_walk2,
        .player_walk3,
        .player_walk4,
    }, .frame_ticks = 6 },
    .jump = .{ .frames = &.{
        .player_jump1,
        .player_jump2,
        .player_jump3,
        .player_jump4,
    }, .frame_ticks = 3, .loop = true },
    .fall = .{ .frames = &.{.player}, .frame_ticks = 4, .loop = false },
});

/// A single animation clip: an ordered list of sprite frames, each shown for `frame_ticks` logic ticks.
/// `loop` repeats the clip; otherwise it holds on the final frame.
pub const Clip = struct {
    frames: []const Sprite,
    /// Logic ticks each frame is held (animation runs on the 60Hz logic tick, not the render frame).
    frame_ticks: u16,
    loop: bool = true,
};

/// Velocity (subpixels/tick) below which the player is considered horizontally still (in terms of animations).
const WALK_VELOCITY_THRESHOLD: f64 = 0.05;

var anim_state: AnimState = .idle;
var anim_frame: usize = 0;
var anim_timer: u16 = 0;

/// Derives the animation state the player should be in from the current physics state.
fn desiredAnimState() AnimState {
    if (!is_grounded) {
        return if (memory.game.player_velocity[1] < 0) .jump else .fall;
    }
    return if (@abs(memory.game.player_velocity[0]) > WALK_VELOCITY_THRESHOLD) .walk else .idle;
}

/// Advances the player's animation by one logic tick and updates facing. Call once per logic tick.
pub fn tickAnimation() void {
    const vx = memory.game.player_velocity[0];
    if (vx > 0) {
        facing_right = true;
    } else if (vx < 0) {
        facing_right = false;
    }

    const next_state = desiredAnimState();
    if (next_state != anim_state) {
        anim_state = next_state;
        anim_frame = 0;
        anim_timer = 0;
    }

    const clip = clips.get(anim_state);
    anim_timer += 1;
    if (anim_timer >= clip.frame_ticks) {
        anim_timer = 0;
        if (anim_frame + 1 < clip.frames.len) {
            anim_frame += 1;
        } else if (clip.loop) {
            anim_frame = 0;
        }
    }
}

/// The sprite frame to render for the player this frame.
pub fn currentSprite() Sprite {
    if (isGhost()) return .player;
    const clip = clips.get(anim_state);
    return clip.frames[@min(anim_frame, clip.frames.len - 1)];
}

/// Adds the player as a render entity at the grid-aligned screen position computed in `render/chunk.zig`.
/// Mirrored horizontally to match `facing_right`. Should only be called from `entity.updateEntities`.
/// Alpha the player is drawn at in ghost mode, so flying through solid rock reads as intended
/// rather than as a collision bug.
const GHOST_ALPHA: f32 = 0.8;

/// Frames that the correction fades the world out.
const SOFTLOCK_FADE_OUT_FRAMES: u8 = 8;
/// Frames that the correction fades the world back in.
const SOFTLOCK_FADE_IN_FRAMES: u8 = 16;
const SOFTLOCK_FADE_TOTAL_FRAMES = SOFTLOCK_FADE_OUT_FRAMES + SOFTLOCK_FADE_IN_FRAMES;

comptime {
    if (SOFTLOCK_FADE_OUT_FRAMES == 0 or SOFTLOCK_FADE_IN_FRAMES == 0)
        @compileError("The softlock fade needs an out and an in phase.");
}

// This is render-only state. It is intentionally not saved.
var softlock_fade_frame: u8 = 0;

/// Starts the visible correction pulse after a portal escape correction.
pub fn startSoftlockFade() void {
    softlock_fade_frame = 1;
}

/// Advances the visible correction pulse by one logical frame.
pub fn tickSoftlockFade() void {
    if (softlock_fade_frame == 0) return;
    if (softlock_fade_frame >= SOFTLOCK_FADE_TOTAL_FRAMES) {
        softlock_fade_frame = 0;
        return;
    }
    softlock_fade_frame += 1;
}

/// Stops a correction pulse when a game is reset or loaded.
pub fn resetSoftlockFade() void {
    softlock_fade_frame = 0;
}

/// Opacity for chunks and the player during a softlock correction pulse.
pub fn softlockFadeOpacity() f32 {
    if (softlock_fade_frame == 0) return 1.0;

    const frame: f32 = @floatFromInt(softlock_fade_frame);
    if (softlock_fade_frame <= SOFTLOCK_FADE_OUT_FRAMES) {
        const t = frame / @as(f32, @floatFromInt(SOFTLOCK_FADE_OUT_FRAMES));
        return 1.0 - t * t * (3.0 - 2.0 * t);
    }

    const t = (frame - @as(f32, @floatFromInt(SOFTLOCK_FADE_OUT_FRAMES))) /
        @as(f32, @floatFromInt(SOFTLOCK_FADE_IN_FRAMES));
    return t * t * (3.0 - 2.0 * t);
}

pub fn drawPlayerEntity() void {
    // Turns ghostly the moment the ascent starts rather than when it commits, so the fade belongs to
    // the animation instead of popping at the end of it.
    const ghost = isGhost() or dw.portal.isAscending();
    dw.entity.addEntity(.{
        .sprite = currentSprite(),
        .position = dw.chunks.player_screen_pos,
        // A portal descent squeezes this down and back up again (see `portal.playerScale()`); the
        // player stays fully opaque throughout, so nothing blinks out and returns.
        .size = if (facing_right) dw.chunks.player_screen_size else -dw.chunks.player_screen_size,
        .lcha = .{ 1.0, 0.0, 0.0, (if (ghost) GHOST_ALPHA else 1.0) * softlockFadeOpacity() },
    });
}

/// Moves the player, handling camera changes.
pub fn move(logic_speed: f64) void {
    const game = &memory.game;
    const dt = logic_speed;

    // handle camera zoom (.pow is safe here despite being inconsistent on different devices)
    const old_camera_scale = game.camera_scale;
    if (KeyBits.isSet(KeyBits.plus, game.keys_held_mask)) {
        game.camera_scale = @min(game.camera_scale * std.math.pow(f64, CAMERA_CHANGE_SPEED, dt), CAMERA_MAX_ZOOM);
    }
    if (KeyBits.isSet(KeyBits.minus, game.keys_held_mask)) {
        game.camera_scale = @max(game.camera_scale / std.math.pow(f64, CAMERA_CHANGE_SPEED, dt), CAMERA_MIN_ZOOM);
    }
    game.camera_scale_change = game.camera_scale / old_camera_scale;

    // Analytical velocity (basic damped linear system)
    const speed = currentSpeed();
    var move_input: f64 = 0;
    if (KeyBits.isSet(KeyBits.left, game.keys_held_mask)) move_input -= speed;
    if (KeyBits.isSet(KeyBits.right, game.keys_held_mask)) move_input += speed;

    const x_mult = 1.0 - FRICTION_X;
    const y_mult = 1.0 - FRICTION_Y;
    const pow_fx = std.math.pow(f64, x_mult, dt);
    const pow_fy = std.math.pow(f64, y_mult, dt);

    // Update x-velocity
    game.player_velocity[0] = game.player_velocity[0] * pow_fx;
    if (FRICTION_X < 1e-4) {
        // acts like a frictionless surface
        game.player_velocity[0] +=
            move_input * x_mult;
    } else {
        game.player_velocity[0] +=
            (move_input * x_mult * (1.0 - pow_fx) / FRICTION_X);
    }

    // Update y velocity with gravity.
    //
    // Ghost mode flies instead, with `isColliding()` giving way below.
    // Vertical flight uses the X friction constants on purpose: the Y ones model falling.
    if (isGhost()) {
        var lift: f64 = 0;
        if (KeyBits.isSet(KeyBits.up, game.keys_held_mask)) lift -= speed;
        if (KeyBits.isSet(KeyBits.down, game.keys_held_mask)) lift += speed;
        game.player_velocity[1] = game.player_velocity[1] * pow_fx;
        game.player_velocity[1] += if (FRICTION_X < 1e-4)
            lift * x_mult
        else
            (lift * x_mult * (1.0 - pow_fx) / FRICTION_X);
    } else if (coyote_frames > 0 and KeyBits.isSet(KeyBits.up, game.keys_held_mask)) {
        game.player_velocity[1] = -JUMP_FORCE;
        is_grounded = false;
        coyote_frames = 0;
    } else {
        game.player_velocity[1] = game.player_velocity[1] * pow_fy;
        game.player_velocity[1] += if (FRICTION_Y < 1e-4) GRAVITY * y_mult else ((GRAVITY * y_mult * (1.0 - pow_fy) / FRICTION_Y));
    }

    // Physics displacement using average velocity!
    const displacement = game.player_velocity * @as(Vec2f, @splat(dt * dw.CHUNK_SIZE_FLOAT));
    subpixel_accum += displacement;

    const total_move: Vec2i = @intFromFloat(@floor(subpixel_accum));
    subpixel_accum -= @as(Vec2f, @floatFromInt(total_move));

    game.last_player_pos = game.player_pos;

    // vertical CCD
    is_grounded = false;
    var rem_y = @abs(total_move[1]);
    const step_y = if (total_move[1] > 0) @as(i64, 1) else -1;
    while (rem_y > 0) {
        const move_now = @min(rem_y, CCD_STEP_SIZE);
        if (!isColliding(game.player_pos[0], game.player_pos[1] + (step_y * move_now))) {
            game.player_pos[1] += step_y * move_now;
            if (handleLocalWrap(1)) break;
            rem_y -= move_now;
        } else {
            // Perfect snap: Move 1 pixel at a time until contact
            var sub_steps = move_now;
            while (sub_steps > 0) : (sub_steps -= 1) {
                if (!isColliding(game.player_pos[0], game.player_pos[1] + step_y)) {
                    game.player_pos[1] += step_y;
                    if (handleLocalWrap(1)) break;
                } else break;
            }
            if (step_y > 0) is_grounded = true;
            game.player_velocity[1] = 0;
            subpixel_accum[1] = 0;
            break;
        }
    }

    if (is_grounded) {
        coyote_frames = COYOTE_TIME_FRAMES;
    } else if (coyote_frames > 0) {
        coyote_frames -= 1;
    }

    // Now do horizontal CCD
    var rem_x = @abs(total_move[0]);
    const step_x = if (total_move[0] > 0) @as(i64, 1) else -1;
    while (rem_x > 0) {
        const move_now = @min(rem_x, CCD_STEP_SIZE);
        if (!isColliding(game.player_pos[0] + (step_x * move_now), game.player_pos[1])) {
            game.player_pos[0] += step_x * move_now;
            if (handleLocalWrap(0)) break;
            rem_x -= move_now;
        } else {
            var sub_steps = move_now;
            while (sub_steps > 0) : (sub_steps -= 1) {
                if (!isColliding(game.player_pos[0] + step_x, game.player_pos[1])) {
                    game.player_pos[0] += step_x;
                    if (handleLocalWrap(0)) break;
                } else break;
            }
            game.player_velocity[0] = 0;
            subpixel_accum[0] = 0;
            break;
        }
    }

    // Finally, tell SimBuffer and the camera to update.
    world.SimBuffer.sync(game.getPlayerCoord());
    updateCamera(dt);
}

/// Carries `game.player_pos` into the neighboring chunk once it leaves `[0, SUBPIXELS_IN_CHUNK)`,
/// keeping the position normalized and the fractal quadrant up to date.
///
/// Returns whether the world edge refused the carry.
/// The edge is a wall like any other, so the momentum that ran into it dies here:
/// leaving it alive lets a player pinned against the edge keep accelerating into it,
/// which costs a full CCD sweep every tick and never moves them anywhere.
fn handleLocalWrap(comptime axis: u1) bool {
    const game = &memory.game;
    const val = game.player_pos[axis];
    if (val < 0 or val >= dw.SUBPIXELS_IN_CHUNK) {
        const carry = @divFloor(val, dw.SUBPIXELS_IN_CHUNK);
        const current_coord = game.getPlayerCoord();

        const new_coord = if (axis == 0)
            current_coord.moveX(carry)
        else
            current_coord.moveY(carry);

        if (new_coord) |c| {
            game.player_quadrant = c.quadrant;
            game.player_chunk = c.suffix;
            game.player_pos[axis] = @mod(val, dw.SUBPIXELS_IN_CHUNK);

            // Adjust last_player_pos and camera so interpolation doesn't snap
            const subpixel_offset = carry * dw.SUBPIXELS_IN_CHUNK;
            game.last_player_pos[axis] -= subpixel_offset;
            game.camera_pos[axis] -= subpixel_offset;
            return false;
        } else {
            // World edge was hit! snap back, and drop the momentum that was carrying us into it
            game.player_pos[axis] = if (val < 0) 0 else dw.SUBPIXELS_IN_CHUNK - 1;
            game.player_velocity[axis] = 0;
            subpixel_accum[axis] = 0;
            return true;
        }
    }
    return false;
}

/// How far `escapeSolid()` proves a route to the outside, in blocks.
const MAX_ESCAPE_BLOCKS: i64 = 100;
const ESCAPE_DIAMETER: usize = @intCast(2 * MAX_ESCAPE_BLOCKS + 1);
const MAX_ESCAPE_CELLS = ESCAPE_DIAMETER * ESCAPE_DIAMETER;

const EscapeOffset = struct { x: i16, y: i16 };
const ESCAPE_STEPS = [_]EscapeOffset{
    .{ .x = 0, .y = -1 },
    .{ .x = -1, .y = 0 },
    .{ .x = 1, .y = 0 },
    .{ .x = 0, .y = 1 },
};

/// One block type that a pending player placement would replace.
///
/// `world.modifyBlockType()` constructs this from every cell that will persist.
/// The escape probe uses it before the modification writes to the live world.
pub const PendingPlacement = struct {
    coord: world.Coordinate,
    bx: u4,
    by: u4,
    sprite: Sprite,
};

const EscapeOverlay = struct {
    cells: [2]?PendingPlacement = .{ null, null },

    fn init(cells: []const PendingPlacement) EscapeOverlay {
        std.debug.assert(cells.len > 0 and cells.len <= 2);

        var overlay = EscapeOverlay{};
        for (cells, 0..) |cell, i| overlay.cells[i] = cell;
        return overlay;
    }

    fn replacementAt(self: *const EscapeOverlay, coord: world.Coordinate, bx: u4, by: u4) ?Sprite {
        for (self.cells) |pending| {
            const cell = pending orelse continue;
            if (cell.bx == bx and cell.by == by and cell.coord.eql(coord)) return cell.sprite;
        }
        return null;
    }
};

comptime {
    if (MAX_ESCAPE_BLOCKS <= 0)
        @compileError("`MAX_ESCAPE_BLOCKS` must be positive.");
    if (MAX_ESCAPE_BLOCKS > std.math.maxInt(i16))
        @compileError("`MAX_ESCAPE_BLOCKS` must fit `EscapeOffset`.");
}

// Escape runs only during a spawn, a portal correction, or a solid placement.
// Static scratch avoids a large WASM stack frame.
var escape_queue: [MAX_ESCAPE_CELLS]EscapeOffset = undefined;
var escape_seen: [MAX_ESCAPE_CELLS]bool = undefined;

/// Checks whether a pending placement leaves the player connected to the outside.
///
/// `cells` must list every cell the placement will leave solid.
/// `world.modifyBlockType()` calls this before it changes `mod_store` or a live cache.
/// A non-solid placement cannot close a collision path.
pub fn permitsPlacement(cells: []const PendingPlacement) bool {
    std.debug.assert(cells.len > 0 and cells.len <= 2);

    var has_solid = false;
    for (cells) |cell| has_solid = has_solid or cell.sprite.isSolid();
    if (!has_solid) return true;

    const overlay = EscapeOverlay.init(cells);
    const game = &memory.game;
    if (!positionIsClear(game.player_pos[0], game.player_pos[1], &overlay)) return false;

    _ = floodOutside(&overlay, canExcavateOffset);
    return escape_seen[escapeIndex(0, 0)];
}

/// Corrects a bounded softlock with a reverse orthogonal flood.
///
/// Each node is the player hitbox moved one block from the landing point.
/// A node is passable when every solid corner block can be broken by the active tool.
/// The flood starts on the `MAX_ESCAPE_BLOCKS` ring and proves that a node reaches outside.
/// A diagonal does not connect, because the player cannot pass through a shared corner.
///
/// This is deliberately a bounded epsilon check, not a proof about the full procedural world.
/// It catches every immutable enclosure contained in the square, including player-made ones.
/// A larger enclosure can still evade it, but the light-limited placement game cannot make one in normal play.
/// Call only after the `SimBuffer` holds the current depth.
///
/// Returns `true` only when it moved the player to a proven external position.
pub fn escapeSolid() bool {
    if (isGhost()) return false;

    const overlay = EscapeOverlay{};
    const count = floodOutside(&overlay, canExcavateOffset);
    if (landingHasEscape()) return false;

    const target = nearestExternalPosition(&overlay, count) orelse return false;
    moveToEscapablePosition(target);
    return true;
}

/// Maps an offset in the escape square to scratch storage. Call only inside its fixed range.
inline fn escapeIndex(dx: i64, dy: i64) usize {
    std.debug.assert(@abs(dx) <= MAX_ESCAPE_BLOCKS and @abs(dy) <= MAX_ESCAPE_BLOCKS);
    return @as(usize, @intCast(dy + MAX_ESCAPE_BLOCKS)) * ESCAPE_DIAMETER +
        @as(usize, @intCast(dx + MAX_ESCAPE_BLOCKS));
}

/// Floods the component that reaches the edge of the bounded escape square.
///
/// `can_enter()` must reject positions whose hitbox crosses an unbreakable block.
/// It is intentionally generic so the graph rule has a direct unit test.
fn floodOutside(context: anytype, comptime can_enter: anytype) usize {
    @memset(&escape_seen, false);
    var write: usize = 0;

    var edge: i64 = -MAX_ESCAPE_BLOCKS;
    while (edge <= MAX_ESCAPE_BLOCKS) : (edge += 1) {
        enqueueEscapeNode(context, can_enter, -MAX_ESCAPE_BLOCKS, edge, &write);
        enqueueEscapeNode(context, can_enter, MAX_ESCAPE_BLOCKS, edge, &write);
        enqueueEscapeNode(context, can_enter, edge, -MAX_ESCAPE_BLOCKS, &write);
        enqueueEscapeNode(context, can_enter, edge, MAX_ESCAPE_BLOCKS, &write);
    }

    var read: usize = 0;
    while (read < write) : (read += 1) {
        const current = escape_queue[read];
        for (ESCAPE_STEPS) |step| {
            const next_x = @as(i64, current.x) + step.x;
            const next_y = @as(i64, current.y) + step.y;
            if (@abs(next_x) > MAX_ESCAPE_BLOCKS or @abs(next_y) > MAX_ESCAPE_BLOCKS) continue;
            enqueueEscapeNode(context, can_enter, next_x, next_y, &write);
        }
    }
    return write;
}

/// Adds one passable node to the external flood, once.
fn enqueueEscapeNode(context: anytype, comptime can_enter: anytype, dx: i64, dy: i64, write: *usize) void {
    const index = escapeIndex(dx, dy);
    if (escape_seen[index] or !can_enter(context, dx, dy)) return;

    escape_seen[index] = true;
    std.debug.assert(write.* < escape_queue.len);
    escape_queue[write.*] = .{ .x = @intCast(dx), .y = @intCast(dy) };
    write.* += 1;
}

/// Returns whether the landing itself, or an immediate cardinal move from it, reaches outside.
fn landingHasEscape() bool {
    if (escape_seen[escapeIndex(0, 0)]) return true;
    for (ESCAPE_STEPS) |step| {
        if (escape_seen[escapeIndex(step.x, step.y)]) return true;
    }
    return false;
}

/// Returns a closest node in the external component, preferring an already-clear landing.
fn nearestExternalPosition(overlay: *const EscapeOverlay, count: usize) ?Vec2i {
    const game = &memory.game;
    var clear: ?EscapeOffset = null;
    var clear_distance: u64 = std.math.maxInt(u64);
    var excavatable: ?EscapeOffset = null;
    var excavatable_distance: u64 = std.math.maxInt(u64);

    for (escape_queue[0..count]) |offset| {
        const dx: i64 = offset.x;
        const dy: i64 = offset.y;
        const distance = @abs(dx) + @abs(dy);
        if (distance >= excavatable_distance and distance >= clear_distance) continue;

        if (distance < excavatable_distance) {
            excavatable = offset;
            excavatable_distance = distance;
        }

        const px = game.player_pos[0] + dx * dw.CHUNK_SIZE_SQ;
        const py = game.player_pos[1] + dy * dw.CHUNK_SIZE_SQ;
        if (distance < clear_distance and positionIsClear(px, py, overlay)) {
            clear = offset;
            clear_distance = distance;
        }
    }

    const offset = clear orelse excavatable orelse return null;
    return .{
        game.player_pos[0] + @as(i64, offset.x) * dw.CHUNK_SIZE_SQ,
        game.player_pos[1] + @as(i64, offset.y) * dw.CHUNK_SIZE_SQ,
    };
}

/// Returns whether the player can enter the offset after breaking every solid corner block.
fn canExcavateOffset(overlay: *const EscapeOverlay, dx: i64, dy: i64) bool {
    const game = &memory.game;
    return positionCanBeExcavated(
        game.player_pos[0] + dx * dw.CHUNK_SIZE_SQ,
        game.player_pos[1] + dy * dw.CHUNK_SIZE_SQ,
        overlay,
    );
}

/// Returns whether every solid cell the player overlaps can be removed with the active tool.
fn positionCanBeExcavated(px: i64, py: i64, overlay: *const EscapeOverlay) bool {
    for (playerCorners(px, py)) |corner| {
        const cell = blockAtPlayerCorner(corner, overlay) orelse return false;
        if (cell.block.isSolid() and !mining.canBreak(cell.coord, cell.bx, cell.by, cell.block)) return false;
    }
    return true;
}

/// Returns whether no solid cell overlaps the player at this position.
fn positionIsClear(px: i64, py: i64, overlay: *const EscapeOverlay) bool {
    for (playerCorners(px, py)) |corner| {
        const cell = blockAtPlayerCorner(corner, overlay) orelse return false;
        if (cell.block.isSolid()) return false;
    }
    return true;
}

const PlayerCornerBlock = struct {
    coord: world.Coordinate,
    bx: u4,
    by: u4,
    block: memory.Block,
};

/// Reads one player hitbox corner, including an uncommitted placement overlay.
fn blockAtPlayerCorner(corner: [2]i64, overlay: *const EscapeOverlay) ?PlayerCornerBlock {
    const game = &memory.game;
    const cx_shift = @divFloor(corner[0], SUBPIXELS_IN_CHUNK);
    const cy_shift = @divFloor(corner[1], SUBPIXELS_IN_CHUNK);
    const coord = game.getPlayerCoord().move(.{ cx_shift, cy_shift }) orelse return null;

    const bx: u4 = @intCast(@as(u64, @bitCast(@divFloor(@mod(corner[0], SUBPIXELS_IN_CHUNK), dw.CHUNK_SIZE_SQ))));
    const by: u4 = @intCast(@as(u64, @bitCast(@divFloor(@mod(corner[1], SUBPIXELS_IN_CHUNK), dw.CHUNK_SIZE_SQ))));
    var block = world.getChunkPtr(coord).blocks[@as(usize, by) * CHUNK_SIZE + @as(usize, bx)];
    if (overlay.replacementAt(coord, bx, by)) |replacement| block.id = replacement;
    return .{ .coord = coord, .bx = bx, .by = by, .block = block };
}

/// Places the player at a proven external position and clears motion state.
fn moveToEscapablePosition(pos: Vec2i) void {
    const game = &memory.game;
    game.player_pos = pos;
    // The offset can cross a chunk edge, and the world edge can refuse it.
    _ = handleLocalWrap(0);
    _ = handleLocalWrap(1);
    game.last_player_pos = game.player_pos;
    game.camera_pos = game.player_pos;
    game.last_camera_pos = game.player_pos;
    game.player_velocity = .{ 0.0, 0.0 };
    resetMotionState();
}

/// Performs an AABB check (for the player's position) against the world grid.
pub fn isColliding(px: i64, py: i64) bool {
    // Ghost mode goes through everything (see the lift branch in `move()`).
    if (isGhost()) return false;

    const game = &memory.game;
    const corners = playerCorners(px, py);

    const player_coord = game.getPlayerCoord();
    var last_coord: ?world.Coordinate = null;
    // Borrowed for the length of this loop only, which generates nothing (see `getChunkPtr()`).
    var chunk: *const memory.Chunk = undefined;

    for (corners) |c| {
        const cx_shift = @divFloor(c[0], SUBPIXELS_IN_CHUNK);
        const cy_shift = @divFloor(c[1], SUBPIXELS_IN_CHUNK);
        // Past the world edge reads as solid: there is nothing there to walk into.
        const target_coord = player_coord.move(.{ cx_shift, cy_shift }) orelse return true;

        // The four corners nearly always share a chunk, and a hitbox can only ever span two;
        // holding the pointer keeps this to one lookup and no chunk copy at all.
        if (last_coord == null or !target_coord.eql(last_coord.?)) {
            chunk = world.getChunkPtr(target_coord);
            last_coord = target_coord;
        }

        const lx: u4 = @intCast(@as(u64, @bitCast(@divFloor(@mod(c[0], SUBPIXELS_IN_CHUNK), dw.CHUNK_SIZE_SQ))));
        const ly: u4 = @intCast(@as(u64, @bitCast(@divFloor(@mod(c[1], SUBPIXELS_IN_CHUNK), dw.CHUNK_SIZE_SQ))));
        if (chunk.blocks[@as(usize, ly) * CHUNK_SIZE + @as(usize, lx)].isSolid()) return true;
    }
    return false;
}

/// Returns the four world points that define the player's collision box.
inline fn playerCorners(px: i64, py: i64) [4][2]i64 {
    return .{
        .{ px - PLAYER_HITBOX_WIDTH / 2, py + CHUNK_SIZE_SQ / 2 - PLAYER_HITBOX_HEIGHT },
        .{ px + PLAYER_HITBOX_WIDTH / 2 - 1, py + CHUNK_SIZE_SQ / 2 - PLAYER_HITBOX_HEIGHT },
        .{ px - PLAYER_HITBOX_WIDTH / 2, py + CHUNK_SIZE_SQ / 2 },
        .{ px + PLAYER_HITBOX_WIDTH / 2 - 1, py + CHUNK_SIZE_SQ / 2 },
    };
}

/// Updates the camera, handling deadzone and gradual panning.
fn updateCamera(logic_speed: f64) void {
    const game = &memory.game;
    game.last_camera_pos = game.camera_pos;

    const x_deadzone: i64 = @intFromFloat(CAMERA_DEADZONE_X / game.camera_scale);
    const y_deadzone: i64 = @intFromFloat(CAMERA_DEADZONE_Y / game.camera_scale);

    var shift_x: i64 = 0;
    var shift_y: i64 = 0;

    if (game.player_pos[0] < game.camera_pos[0] - x_deadzone) {
        shift_x = game.player_pos[0] - (game.camera_pos[0] - x_deadzone);
    } else if (game.player_pos[0] > game.camera_pos[0] + x_deadzone) {
        shift_x = game.player_pos[0] - (game.camera_pos[0] + x_deadzone);
    }

    if (game.player_pos[1] < game.camera_pos[1] - y_deadzone) {
        shift_y = game.player_pos[1] - (game.camera_pos[1] - y_deadzone);
    } else if (game.player_pos[1] > game.camera_pos[1] + y_deadzone) {
        shift_y = game.player_pos[1] - (game.camera_pos[1] + y_deadzone);
    }

    const smooth_speed = 1.0 - std.math.pow(f64, 1.0 - CAMERA_SMOOTHING, logic_speed);
    game.camera_pos[0] += @intFromFloat(@as(f64, @floatFromInt(shift_x)) * smooth_speed);
    game.camera_pos[1] += @intFromFloat(@as(f64, @floatFromInt(shift_y)) * smooth_speed);
}

test "bounded escape flood requires a cardinal route to the outside" {
    const Open = struct {
        fn canEnter(_: *const @This(), _: i64, _: i64) bool {
            return true;
        }
    };
    const Sealed = struct {
        fn canEnter(_: *const @This(), dx: i64, dy: i64) bool {
            return !((@abs(dx) == 1 and dy == 0) or (@abs(dy) == 1 and dx == 0));
        }
    };

    const open = Open{};
    _ = floodOutside(&open, Open.canEnter);
    try std.testing.expect(escape_seen[escapeIndex(0, 0)]);

    const sealed = Sealed{};
    _ = floodOutside(&sealed, Sealed.canEnter);
    try std.testing.expect(!escape_seen[escapeIndex(0, 0)]);
    for (ESCAPE_STEPS) |step| {
        try std.testing.expect(!escape_seen[escapeIndex(step.x, step.y)]);
    }
}
