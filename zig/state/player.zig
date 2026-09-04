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

// ----
// NOTE: for consistency and simplicity's sake, this specific file puts the units or qualifiers last, sorted by descending significance, so that the variable starts with the most significant word, and ends with the least significant word.
// This rule is inspired by TigerBeetle's style guide, so things will be named DECAY_MS_MAX instead of MAX_DECAY_MS.
// The rules are a lot lax elsewhere because X/Y are typically scoped locally and style consistency's benefits are a lot lesser.
// ----

/// Minimum camera zoom/scale allowed. This is strategically calculated to make sure the default render distance is safe.
/// The `SimBuffer` size automatically adjusts when setting this to a very small value.
///
/// Setting this to a very small value is useful for testing cache validity or overall performance, however.
pub const CAMERA_ZOOM_MIN = if (dw.dev_menu) 0.05 else 0.5;
/// Maximum camera zoom/scale allowed. This is strategically calculated to make sure the player always remains in the viewport.
/// Any more and it would look weird, and camera deadzone would start to no longer work.
pub const CAMERA_ZOOM_MAX = 1.5; // 150%
/// Camera scale the game starts at.
pub const STARTING_CAMERA_SCALE = 1.0; // 100%

/// How much faster the player moves in ghost mode. Applies to all four directions.
pub var GHOST_SPEED_MULT: f64 = 3.0;

/// The base (X-axis) acceleration value of the player.
/// Top speed is `PLAYER_ACCEL * (1 - DECAY_RATE_ACCEL_X) / DECAY_RATE_ACCEL_X`,
/// so changing either one moves the top speed.
pub var PLAYER_ACCEL: f64 = 2.00;
/// Decay rate of player movement (horizontal), multiplies X speed by (1.0 - this value).
/// When horizontal movement keys are lifted, the `DECEL` variant is used instead.
pub var DECAY_RATE_ACCEL_X: f64 = 0.500;
/// Decay rate of player movement (horizontal), multiplies X speed by (1.0 - this value).
/// When horizontal movement keys are held, the `ACCEL` variant is used instead.
pub var DECAY_RATE_DECEL_X: f64 = 0.200;

/// How strong the gravity is.
pub var GRAVITY: f64 = 0.24;
/// Controls how strong the jump is.
pub var JUMP_FORCE: f64 = 6.00;
/// Size of the apex window, in velocity units.
/// Inside it, with the jump key held, gravity is multiplied by 60%.
pub var REDUCED_GRAVITY_RANGE: f64 = 0.50;
/// Decay rate of player movement (vertical), multiplies Y speed by (1.0 - this value).
pub var DECAY_RATE_Y: f64 = 0.03;

/// The size of the player's width. The player is assumed to be centered at the bottom as a rectangle.
pub const PLAYER_HITBOX_WIDTH = 160;
/// The size of the player's height. The player is assumed to be centered at the bottom as a rectangle.
pub const PLAYER_HITBOX_HEIGHT = 200;
/// Prevent block-skipping with collisions when travelling quickly.
/// One block per step. `moveAxis()` needs this to be no smaller than the hitbox,
/// or a sweep could straddle a solid block without any corner landing inside it.
const CCD_STEP_SIZE = CHUNK_SIZE_SQ;

comptime {
    if (PLAYER_HITBOX_WIDTH > CCD_STEP_SIZE or PLAYER_HITBOX_HEIGHT > CCD_STEP_SIZE)
        @compileError("The hitbox must not be larger than one CCD_STEP_SIZE sweep step.");
}

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

// These values are floats because logic_speed-as-a-float "taints" this component.
// Given logic_speed is typically 1.0 this is just fine. Frames represent logical frames at 60FPS.
// The CAPITALIZED_VARIANTS are the tuned values, while the lowercase_variants are for live state decrementing.

/// A value of 1 = only one jump, 2 = player can double jump, and so on.
const MAX_JUMPS: u8 = 1;
/// How many frames the player can still jump after leaving a ledge.
const COYOTE_FRAMES: u8 = 5;
/// How many frames a jump button press is kept as soon as the ground is hit.
const JUMP_LENIENCY_FRAMES: u8 = 10;

/// Jumps left before the player must touch the ground again. Refilled by `is_grounded`.
var jumps_left: u8 = MAX_JUMPS;
/// Frames remaining for coyote time jump.
var coyote_frames: f64 = 0;
/// Leniency frames.
var jump_leniency_frames: f64 = 0;

/// The jump key state from the previous tick, for finding the press edge.
/// `keys_pressed_mask` cannot do this: `src/engine.ts` writes it once per render frame,
/// and `handleTick()` can run several ticks inside one frame.
var up_was_held: bool = false;

/// Whether the player flies and goes through blocks.
pub inline fn isGhost() bool {
    return dw.inventory.isInCreative();
}

/// The X acceleration input for this tick. Not a speed: see `PLAYER_ACCEL`.
inline fn currentSpeed() f64 {
    return if (isGhost()) PLAYER_ACCEL * GHOST_SPEED_MULT else PLAYER_ACCEL;
}

/// Drops the airborne/jump bookkeeping, for teleports that skip `move()` entirely.
/// A portal descent freezes movement for its whole length,
/// so without this the coyote window from before the descent survives it.
pub fn resetMotionState() void {
    is_grounded = false;
    coyote_frames = 0;
    subpixel_accum = .{ 0.0, 0.0 };
    jumps_left = MAX_JUMPS;
    jump_leniency_frames = 0;
}

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
        // The portal changes size, while a softlock correction changes opacity.
        .size = if (facing_right) dw.chunks.player_screen_size else -dw.chunks.player_screen_size,
        .lcha = .{ 1.0, 0.0, 0.0, (if (ghost) GHOST_ALPHA else 1.0) * softlockFadeOpacity() },
    });
}

/// Moves the player, handling camera changes.
/// `logic_speed` should be 1 at a 60FPS default and is unrelated to frame drop correction.
pub fn move(logic_speed: f64) void {
    const game = &memory.game;

    // handle camera zoom (.pow is safe here despite being inconsistent on different devices)
    const old_camera_scale = game.camera_scale;
    if (KeyBits.isSet(KeyBits.plus, game.keys_held_mask)) {
        game.camera_scale = @min(game.camera_scale * std.math.pow(f64, CAMERA_CHANGE_SPEED, logic_speed), CAMERA_ZOOM_MAX);
    }
    if (KeyBits.isSet(KeyBits.minus, game.keys_held_mask)) {
        game.camera_scale = @max(game.camera_scale / std.math.pow(f64, CAMERA_CHANGE_SPEED, logic_speed), CAMERA_ZOOM_MIN);
    }
    game.camera_scale_change = game.camera_scale / old_camera_scale;

    // Analytical velocity (basic damped linear system)
    const speed = currentSpeed();
    var move_input: f64 = 0;
    const left_key_held = KeyBits.isSet(KeyBits.left, game.keys_held_mask);
    const right_key_held = KeyBits.isSet(KeyBits.right, game.keys_held_mask);
    if (left_key_held) move_input -= speed;
    if (right_key_held) move_input += speed;

    const decay_rate_x = if (left_key_held or right_key_held) DECAY_RATE_ACCEL_X else DECAY_RATE_DECEL_X;
    const x_mult = 1.0 - decay_rate_x;
    const y_mult = 1.0 - DECAY_RATE_Y;
    const pow_fx = std.math.pow(f64, x_mult, logic_speed);
    const pow_fy = std.math.pow(f64, y_mult, logic_speed);

    // Update X-velocity
    game.player_velocity[0] = game.player_velocity[0] * pow_fx;
    game.player_velocity[0] += move_input * x_mult * (1.0 - pow_fx) / decay_rate_x;

    const up_key_held = KeyBits.isSet(KeyBits.up, game.keys_held_mask);
    const up_key_pressed = up_key_held and !up_was_held; // see up_was_held definition for reasoning
    defer up_was_held = up_key_held;

    const jump_requested = up_key_pressed or jump_leniency_frames > 0;
    const can_ground_jump = coyote_frames > 0 and jumps_left > 0;
    const can_air_jump = jumps_left < MAX_JUMPS and jumps_left > 0;

    var jumped_this_frame = false;

    // Update Y velocity with gravity.
    //
    // Ghost mode flies instead, with isColliding() giving way below.
    // Vertical flight uses the X friction constants on purpose: the Y ones model falling.
    if (isGhost()) {
        // standard ghost "flying" movement
        var lift: f64 = 0;
        if (KeyBits.isSet(KeyBits.up, game.keys_held_mask)) lift -= speed;
        if (KeyBits.isSet(KeyBits.down, game.keys_held_mask)) lift += speed;
        game.player_velocity[1] = game.player_velocity[1] * pow_fx;
        game.player_velocity[1] += if (DECAY_RATE_ACCEL_X < 1e-4)
            lift * x_mult
        else
            (lift * x_mult * (1.0 - pow_fx) / DECAY_RATE_ACCEL_X);
    } else if (jump_requested and (can_ground_jump or can_air_jump)) {
        // normal jump
        game.player_velocity[1] = -JUMP_FORCE;
        jumps_left -= 1;

        jump_leniency_frames = 0;
        jumped_this_frame = true;

        // prevent the same ground/coyote window from being reused
        coyote_frames = 0;
    } else {
        // No jump this tick, so gravity runs. Negative y velocity is UP, positive is DOWN.
        //
        // Jump height follows how long the key stays down, about 1.3 blocks for a tap
        // and about 3.0 blocks for a full hold. Two brakes do that, and both are off while
        // the key is held: a gravity multiplier, and a constant cut taken off upward speed.

        // Decay first, then gravity. The (1 - pow_fy) / DECAY_RATE_Y factor integrates a constant
        // acceleration under that decay, so one tick at logic_speed 2 lands where two ticks at 1 do.
        var y_vel = game.player_velocity[1] * pow_fy;

        // Gravity strength by arc phase:
        // - near the apex, key down    0.60  hang time over the top of the jump.
        // - near the apex, key up      1.00  no brake through the turn, so the arc has no kink.
        // - rising, key up             1.80  ends the rise early, which is the short jump.
        // - falling under 3.0, key up  1.20  a snappier drop back to the ground.
        // - everything else            1.00  key still down, or already falling fast.
        const gravity_mult: f64 = if (@abs(y_vel) < REDUCED_GRAVITY_RANGE)
            (if (up_key_held) 0.6 else 1.0)
        else if (up_key_held or y_vel > 3.0)
            1.0
        else if (y_vel >= 0)
            1.20
        else
            1.8;
        y_vel += (GRAVITY * y_mult * (1.0 - pow_fy) / DECAY_RATE_Y) * gravity_mult;

        // The second brake on a released jump. The multiplier above scales with current speed,
        // so additional linear logic helps keep a "baseline" that forces the player to fall faster.
        const LINEAR_Y_DECAY = 0.2 * logic_speed;
        if (y_vel <= -LINEAR_Y_DECAY and !up_key_held) {
            y_vel += LINEAR_Y_DECAY;
        }

        // Terminal velocity, about 28 blocks per second.
        // Decay alone would settle at ~7.76, so this cap only trims the last of that creep.
        y_vel = @min(y_vel, 7.5);

        game.player_velocity[1] = y_vel;
    }

    // Physics displacement using average velocity!
    const displacement = game.player_velocity * @as(Vec2f, @splat(logic_speed * dw.CHUNK_SIZE_FLOAT));
    subpixel_accum += displacement;

    const total_move: Vec2i = @intFromFloat(@floor(subpixel_accum));
    subpixel_accum -= @as(Vec2f, @floatFromInt(total_move));

    game.last_player_pos = game.player_pos;

    // Vertical first, then horizontal, with the ground test between them.
    // So a player who walks off a ledge is still grounded for the tick that leaves it,
    // and coyote time starts on the tick after.
    moveAxis(1, total_move[1]);

    is_grounded = isColliding(game.player_pos[0], game.player_pos[1] + 1);

    if (is_grounded) {
        coyote_frames = COYOTE_FRAMES;
        jumps_left = MAX_JUMPS;
    } else if (coyote_frames > 0) {
        coyote_frames -= logic_speed; // this CAN be negative!
    }

    std.debug.assert(jumps_left >= 0); // sanity check
    if (up_key_pressed and !jumped_this_frame) {
        jump_leniency_frames = JUMP_LENIENCY_FRAMES;
    } else if (jump_leniency_frames > 0) {
        jump_leniency_frames -= logic_speed; // this CAN be negative!
    }

    moveAxis(0, total_move[0]);

    // Finally, tell SimBuffer and the camera to update.
    world.SimBuffer.sync(game.getPlayerCoord());
    updateCamera(logic_speed);
}

/// Returns whether the player hitbox collides after one axis moves by `delta` subpixels.
inline fn isCollidingOffset(comptime axis: u1, delta: i64) bool {
    const game = &memory.game;
    return if (axis == 0)
        isColliding(game.player_pos[0] + delta, game.player_pos[1])
    else
        isColliding(game.player_pos[0], game.player_pos[1] + delta);
}

/// Sweeps the player along one axis by `amount` subpixels and stops at the first contact.
///
/// The sweep steps one block at a time, then one subpixel at a time to close the last gap.
/// It cannot pass through a solid block, because `CCD_STEP_SIZE` is one block
/// and the hitbox is never larger than one block on either axis.
/// A contact takes this axis' velocity and its subpixel remainder,
/// so a player held against a wall does not build speed into it.
fn moveAxis(comptime axis: u1, amount: i64) void {
    const game = &memory.game;
    var remaining = @abs(amount);
    const step: i64 = if (amount > 0) 1 else -1;

    while (remaining > 0) {
        const move_now = @min(remaining, CCD_STEP_SIZE);
        if (!isCollidingOffset(axis, step * move_now)) {
            game.player_pos[axis] += step * move_now;
            if (handleLocalWrap(axis)) break;
            remaining -= move_now;
            continue;
        }

        // Something solid is inside this step. Walk up to it one subpixel at a time.
        var sub_steps = move_now;
        while (sub_steps > 0) : (sub_steps -= 1) {
            if (isCollidingOffset(axis, step)) break;
            game.player_pos[axis] += step;
            if (handleLocalWrap(axis)) break;
        }
        game.player_velocity[axis] = 0;
        subpixel_accum[axis] = 0;
        break;
    }
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
const MAX_ESCAPE_BLOCKS: i64 = 32;
const ESCAPE_DIAMETER: usize = @intCast(2 * MAX_ESCAPE_BLOCKS + 1);
const MAX_ESCAPE_CELLS = ESCAPE_DIAMETER * ESCAPE_DIAMETER;
/// The probe reads one support cell beyond every corrected player corner.
const ESCAPE_BLOCK_RADIUS = MAX_ESCAPE_BLOCKS + 2;
const ESCAPE_BLOCK_DIAMETER: usize = @intCast(2 * ESCAPE_BLOCK_RADIUS + 1);
const MAX_ESCAPE_BLOCK_CELLS = ESCAPE_BLOCK_DIAMETER * ESCAPE_BLOCK_DIAMETER;

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
    if (ESCAPE_BLOCK_RADIUS > std.math.maxInt(i16))
        @compileError("The cached escape block radius must fit `EscapeOffset`.");
}

// Escape scratch supports spawn, portal correction, and placement safety.
// Static scratch avoids a large WASM stack frame.
var escape_queue: [MAX_ESCAPE_CELLS]EscapeOffset = undefined;
var escape_checked: [MAX_ESCAPE_CELLS]bool = undefined;
var escape_block_cache: [MAX_ESCAPE_BLOCK_CELLS]memory.Block = undefined;
var escape_block_state: [MAX_ESCAPE_BLOCK_CELLS]u8 = undefined;
const ESCAPE_BLOCK_UNKNOWN = 0;
const ESCAPE_BLOCK_MISSING = 1;
const ESCAPE_BLOCK_PRESENT = 2;

/// Checks whether a pending placement leaves the player connected to the outside.
///
/// `cells` must list every cell the placement will change.
/// `world.modifyBlockType()` calls this before it changes `mod_store` or a live cache.
/// A placement that changes neither collision nor installation protection cannot close a path.
/// This uses the same bounded search as `escapeSolid()`.
pub fn permitsPlacement(cells: []const PendingPlacement) bool {
    std.debug.assert(cells.len > 0 and cells.len <= 2);

    if (!placementCanChangeEscape(cells)) return true;

    const overlay = EscapeOverlay.init(cells);
    const probe = EscapeProbe.init(&overlay) orelse return false;
    if (!probe.positionIsClear(0, 0)) return false;

    return canReachOutside(&probe, EscapeProbe.canEnter);
}

/// Returns whether a pending placement can change a collision route.
///
/// A protected installation is non-solid, but it can make its support impossible to break.
fn placementCanChangeEscape(cells: []const PendingPlacement) bool {
    for (cells) |cell| {
        if (cell.sprite.isSolid() or mining.protectsSupport(cell.sprite)) return true;
    }
    return false;
}

/// Corrects a bounded softlock with an orthogonal reachability search.
/// This exists because the player can potentially access placeable but un-mineable materials,
/// such as items from a chest.
/// The player can place these items to create a "malicious" softlock;
/// separate to this, there is a tiny probability an unlucky spawn softlocks the player.
///
/// Each node is the player hitbox moved a whole number of blocks from the current position.
/// A node is passable when the active tool can break every solid block the hitbox touches.
/// The search starts at the player and proves escape when it reaches the `MAX_ESCAPE_BLOCKS` ring.
/// A diagonal does not connect, because the player cannot pass through a shared corner.
/// When trapped, the player moves to the landing that `nearestExteriorLanding()` picks.
///
/// The square is a bounded check, not a proof about the whole world.
/// It finds every enclosure that fits inside the square, including player-made ones.
/// A larger enclosure escapes it.
/// The light-limited placement rule keeps player-built cages smaller than the square.
/// Call only after the `SimBuffer` holds the current depth.
///
/// Returns `true` only when it moved the player.
pub fn escapeSolid() bool {
    if (isGhost()) return false;

    const overlay = EscapeOverlay{};
    const probe = EscapeProbe.init(&overlay) orelse return false;
    if (canReachOutside(&probe, EscapeProbe.canEnter)) return false;

    const target = correctionLanding(&probe) orelse return false;
    moveToEscapablePosition(target);
    return true;
}

/// Maps an offset in the escape square to scratch storage. Call only inside its fixed range.
inline fn escapeIndex(dx: i64, dy: i64) usize {
    std.debug.assert(@abs(dx) <= MAX_ESCAPE_BLOCKS and @abs(dy) <= MAX_ESCAPE_BLOCKS);
    return @as(usize, @intCast(dy + MAX_ESCAPE_BLOCKS)) * ESCAPE_DIAMETER +
        @as(usize, @intCast(dx + MAX_ESCAPE_BLOCKS));
}

/// Searches the player's component for a path to the edge of the bounded escape square.
///
/// `can_enter()` must reject positions whose hitbox crosses an unbreakable block.
/// It is intentionally generic so the graph rule has a direct unit test.
fn canReachOutside(context: anytype, comptime can_enter: anytype) bool {
    @memset(&escape_checked, false);
    var write: usize = 0;
    enqueueEscapeNode(context, can_enter, 0, 0, &write);

    while (write != 0) {
        write -= 1;
        const current = escape_queue[write];
        if (@abs(current.x) == MAX_ESCAPE_BLOCKS or @abs(current.y) == MAX_ESCAPE_BLOCKS) return true;

        for (ESCAPE_STEPS) |step| {
            const next_x = @as(i64, current.x) + step.x;
            const next_y = @as(i64, current.y) + step.y;
            if (@abs(next_x) > MAX_ESCAPE_BLOCKS or @abs(next_y) > MAX_ESCAPE_BLOCKS) continue;
            enqueueEscapeNode(context, can_enter, next_x, next_y, &write);
        }
    }
    return false;
}

/// Adds one passable node to the search, once.
fn enqueueEscapeNode(context: anytype, comptime can_enter: anytype, dx: i64, dy: i64, write: *usize) void {
    const index = escapeIndex(dx, dy);
    if (escape_checked[index]) return;
    escape_checked[index] = true;
    if (!can_enter(context, dx, dy)) return;

    std.debug.assert(write.* < escape_queue.len);
    escape_queue[write.*] = .{ .x = @intCast(dx), .y = @intCast(dy) };
    write.* += 1;
}

/// Returns the world position the correction moves the player to, in subpixels.
///
/// A standable landing is snapped down onto its floor block, the same rest position
/// `startup.findSafeSpawn()` uses, so the player arrives standing and not falling.
/// The snap only shrinks the blocks the hitbox covers, so a clear landing stays clear.
fn correctionLanding(probe: *const EscapeProbe) ?Vec2i {
    const offset = nearestExteriorLanding(
        probe,
        EscapeProbe.canEnter,
        EscapeProbe.positionIsClear,
        EscapeProbe.positionIsGrounded,
    ) orelse return null;

    const game = &memory.game;
    const x = game.player_pos[0] + @as(i64, offset.x) * dw.CHUNK_SIZE_SQ;
    var y = game.player_pos[1] + @as(i64, offset.y) * dw.CHUNK_SIZE_SQ;

    if (probe.positionIsGrounded(offset.x, offset.y)) {
        // Put the feet on the last subpixel row of the block they already stand in.
        const feet = y + dw.CHUNK_SIZE_SQ / 2;
        y = @divFloor(feet, dw.CHUNK_SIZE_SQ) * dw.CHUNK_SIZE_SQ + dw.CHUNK_SIZE_SQ / 2 - 1;
    }
    return .{ x, y };
}

/// Finds the best landing that connects to the boundary of the escape square.
///
/// A point merely near the player is not enough. It can be a second sealed pocket.
/// The flood starts on the boundary ring, so every point it visits reaches the outside.
///
/// Landings come in three tiers.
/// Standable is best, then clear but unsupported, then a spot the player must mine out of.
/// The closest point in the best occupied tier wins!
/// Standable comes first because a trapped player has no blocks to build with.
/// From the other two tiers the player falls, with no proof of where the fall stops.
///
/// `can_enter()` defines the breakable movement graph.
/// The fixed square makes this another bounded `O(MAX_ESCAPE_CELLS)` scan.
fn nearestExteriorLanding(
    context: anytype,
    comptime can_enter: anytype,
    comptime is_clear: anytype,
    comptime is_standable: anytype,
) ?EscapeOffset {
    @memset(&escape_checked, false);
    var write: usize = 0;

    // Seed the exterior component from the complete boundary ring.
    var edge: i64 = -MAX_ESCAPE_BLOCKS;
    while (edge <= MAX_ESCAPE_BLOCKS) : (edge += 1) {
        enqueueEscapeNode(context, can_enter, edge, -MAX_ESCAPE_BLOCKS, &write);
        enqueueEscapeNode(context, can_enter, edge, MAX_ESCAPE_BLOCKS, &write);
        enqueueEscapeNode(context, can_enter, -MAX_ESCAPE_BLOCKS, edge, &write);
        enqueueEscapeNode(context, can_enter, MAX_ESCAPE_BLOCKS, edge, &write);
    }

    var standable: ?EscapeOffset = null;
    var clear: ?EscapeOffset = null;
    var excavatable: ?EscapeOffset = null;
    while (write != 0) {
        write -= 1;
        const current = escape_queue[write];
        if (!is_clear(context, current.x, current.y)) {
            if (isCloserLanding(current, excavatable)) excavatable = current;
        } else {
            if (isCloserLanding(current, clear)) clear = current;
            if (is_standable(context, current.x, current.y) and isCloserLanding(current, standable))
                standable = current;
        }

        for (ESCAPE_STEPS) |step| {
            const next_x = @as(i64, current.x) + step.x;
            const next_y = @as(i64, current.y) + step.y;
            if (@abs(next_x) > MAX_ESCAPE_BLOCKS or @abs(next_y) > MAX_ESCAPE_BLOCKS) continue;
            enqueueEscapeNode(context, can_enter, next_x, next_y, &write);
        }
    }

    return standable orelse clear orelse excavatable;
}

/// Returns whether `candidate` is a nearer exterior landing than `previous`.
fn isCloserLanding(candidate: EscapeOffset, previous: ?EscapeOffset) bool {
    const prior = previous orelse return true;
    const candidate_distance = @abs(@as(i64, candidate.x)) + @abs(@as(i64, candidate.y));
    const prior_distance = @abs(@as(i64, prior.x)) + @abs(@as(i64, prior.y));
    if (candidate_distance != prior_distance) return candidate_distance < prior_distance;

    // Keep exact ties stable so a seed always gets the same correction point.
    if (candidate.y != prior.y) return candidate.y < prior.y;
    return candidate.x < prior.x;
}

const PlayerCornerAddress = struct {
    coord: world.Coordinate,
    bx: u4,
    by: u4,
};

/// Maps one player hitbox corner to its current-depth block address.
fn playerCornerAddress(corner: [2]i64) ?PlayerCornerAddress {
    const game = &memory.game;
    const cx_shift = @divFloor(corner[0], SUBPIXELS_IN_CHUNK);
    const cy_shift = @divFloor(corner[1], SUBPIXELS_IN_CHUNK);
    const coord = game.getPlayerCoord().move(.{ cx_shift, cy_shift }) orelse return null;

    const bx: u4 = @intCast(@mod(@divFloor(corner[0], dw.CHUNK_SIZE_SQ), @as(i64, CHUNK_SIZE)));
    const by: u4 = @intCast(@mod(@divFloor(corner[1], dw.CHUNK_SIZE_SQ), @as(i64, CHUNK_SIZE)));
    return .{ .coord = coord, .bx = bx, .by = by };
}

/// Holds the resident cells that one bounded escape probe reads.
///
/// The cache is local to a probe because a pending placement changes its answers.
/// A missing resident cell is solid for this check, so the probe cannot generate terrain.
const EscapeProbe = struct {
    overlay: *const EscapeOverlay,
    reference: PlayerCornerAddress,
    corner_offsets: [4]EscapeOffset,

    fn init(overlay: *const EscapeOverlay) ?EscapeProbe {
        const game = &memory.game;
        const corners = playerCorners(game.player_pos[0], game.player_pos[1]);
        const reference = playerCornerAddress(corners[0]) orelse return null;
        const reference_x = @divFloor(corners[0][0], dw.CHUNK_SIZE_SQ);
        const reference_y = @divFloor(corners[0][1], dw.CHUNK_SIZE_SQ);

        var corner_offsets: [4]EscapeOffset = undefined;
        for (corners, 0..) |corner, i| {
            corner_offsets[i] = .{
                .x = @intCast(@divFloor(corner[0], dw.CHUNK_SIZE_SQ) - reference_x),
                .y = @intCast(@divFloor(corner[1], dw.CHUNK_SIZE_SQ) - reference_y),
            };
        }

        @memset(&escape_block_state, ESCAPE_BLOCK_UNKNOWN);
        return .{
            .overlay = overlay,
            .reference = reference,
            .corner_offsets = corner_offsets,
        };
    }

    /// Returns whether the player can enter one offset after breaking every solid corner cell.
    fn canEnter(self: *const EscapeProbe, dx: i64, dy: i64) bool {
        return self.positionCanBeExcavated(dx, dy);
    }

    /// Returns whether every solid cell the player overlaps can be removed with the active tool.
    fn positionCanBeExcavated(self: *const EscapeProbe, dx: i64, dy: i64) bool {
        for (self.corner_offsets) |corner| {
            const cell_x = dx + corner.x;
            const cell_y = dy + corner.y;
            const block = self.blockAtRelative(cell_x, cell_y) orelse return false;
            if (!block.isSolid()) continue;

            const protected = if (mining.has_structure_tool)
                false
            else
                self.restsOnProtectedInstallation(cell_x, cell_y);
            if (!mining.canBreakWithSupport(block, protected)) return false;
        }
        return true;
    }

    /// Returns whether no solid cell overlaps the player at one block offset.
    fn positionIsClear(self: *const EscapeProbe, dx: i64, dy: i64) bool {
        for (self.corner_offsets) |corner| {
            const block = self.blockAtRelative(dx + corner.x, dy + corner.y) orelse return false;
            if (block.isSolid()) return false;
        }
        return true;
    }

    /// Returns whether the player has clear space and a floor under a foot at one block offset.
    ///
    /// `playerCorners()` puts the two feet last, and the cell under a foot is the floor it lands on.
    /// A landing that is only clear leaves the player in the air, where they fall to somewhere unproven.
    fn positionIsGrounded(self: *const EscapeProbe, dx: i64, dy: i64) bool {
        if (!self.positionIsClear(dx, dy)) return false;

        for (self.corner_offsets[2..]) |foot| {
            const floor = self.blockAtRelative(dx + foot.x, dy + foot.y + 1) orelse continue;
            if (floor.isSolid()) return true;
        }
        return false;
    }

    /// Returns whether this cell supports a protected installation.
    fn restsOnProtectedInstallation(self: *const EscapeProbe, dx: i64, dy: i64) ?bool {
        const above = self.blockAtRelative(dx, dy - 1) orelse return null;
        if (above.anchor() == .floor and mining.protectsSupport(above.id)) return true;

        const below = self.blockAtRelative(dx, dy + 1) orelse return null;
        return below.anchor() == .ceiling and mining.protectsSupport(below.id);
    }

    /// Reads a cached resident cell relative to the first player hitbox corner.
    fn blockAtRelative(self: *const EscapeProbe, dx: i64, dy: i64) ?memory.Block {
        const index = escapeBlockIndex(dx, dy);
        switch (escape_block_state[index]) {
            ESCAPE_BLOCK_MISSING => return null,
            ESCAPE_BLOCK_PRESENT => return escape_block_cache[index],
            ESCAPE_BLOCK_UNKNOWN => {},
            else => unreachable,
        }

        const block_x = @as(i64, self.reference.bx) + dx;
        const block_y = @as(i64, self.reference.by) + dy;
        const coord = self.reference.coord.move(.{
            @divFloor(block_x, @as(i64, CHUNK_SIZE)),
            @divFloor(block_y, @as(i64, CHUNK_SIZE)),
        }) orelse {
            escape_block_state[index] = ESCAPE_BLOCK_MISSING;
            return null;
        };
        const chunk = world.SimBuffer.get(coord) orelse {
            escape_block_state[index] = ESCAPE_BLOCK_MISSING;
            return null;
        };
        const bx: u4 = @intCast(@mod(block_x, @as(i64, CHUNK_SIZE)));
        const by: u4 = @intCast(@mod(block_y, @as(i64, CHUNK_SIZE)));
        var block = chunk.blocks[@as(usize, by) * CHUNK_SIZE + @as(usize, bx)];
        if (self.overlay.replacementAt(coord, bx, by)) |replacement| block.id = replacement;

        escape_block_cache[index] = block;
        escape_block_state[index] = ESCAPE_BLOCK_PRESENT;
        return block;
    }
};

/// Maps a cached resident block offset to scratch storage. Call only inside the cache range.
inline fn escapeBlockIndex(dx: i64, dy: i64) usize {
    std.debug.assert(@abs(dx) <= ESCAPE_BLOCK_RADIUS and @abs(dy) <= ESCAPE_BLOCK_RADIUS);
    return @as(usize, @intCast(dy + ESCAPE_BLOCK_RADIUS)) * ESCAPE_BLOCK_DIAMETER +
        @as(usize, @intCast(dx + ESCAPE_BLOCK_RADIUS));
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

test "bounded escape probe rejects diagonal-only routes" {
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
    try std.testing.expect(canReachOutside(&open, Open.canEnter));

    const sealed = Sealed{};
    try std.testing.expect(!canReachOutside(&sealed, Sealed.canEnter));
}

test "bounded escape probe accepts a one-cell corridor and rejects its closed gate" {
    const Corridor = struct {
        fn canEnter(_: *const @This(), dx: i64, dy: i64) bool {
            return dy == 0 and dx >= 0;
        }
    };
    const ClosedGate = struct {
        fn canEnter(_: *const @This(), dx: i64, dy: i64) bool {
            return dy == 0 and dx >= 0 and dx != 1;
        }
    };

    const corridor = Corridor{};
    try std.testing.expect(canReachOutside(&corridor, Corridor.canEnter));

    const closed_gate = ClosedGate{};
    try std.testing.expect(!canReachOutside(&closed_gate, ClosedGate.canEnter));
}

test "softlock correction chooses the closest exterior pocket" {
    const Ring = struct {
        fn canEnter(_: *const @This(), dx: i64, dy: i64) bool {
            return !((@abs(dx) == 1 and dy == 0) or (@abs(dy) == 1 and dx == 0));
        }

        fn isClear(_: *const @This(), _: i64, _: i64) bool {
            return true;
        }

        // Open air everywhere, so the correction has to fall back to the closest clear point.
        fn isStandable(_: *const @This(), _: i64, _: i64) bool {
            return false;
        }
    };

    const ring = Ring{};
    try std.testing.expect(!canReachOutside(&ring, Ring.canEnter));

    const landing = nearestExteriorLanding(&ring, Ring.canEnter, Ring.isClear, Ring.isStandable) orelse unreachable;
    const distance = @abs(@as(i64, landing.x)) + @abs(@as(i64, landing.y));
    try std.testing.expectEqual(@as(u64, 2), distance);
}

test "softlock correction prefers a farther landing that stands on a floor" {
    // The player is sealed in a 3x3 box of unbreakable ore, with one ledge to the east.
    const Box = struct {
        fn canEnter(_: *const @This(), dx: i64, dy: i64) bool {
            return @max(@abs(dx), @abs(dy)) != 1;
        }

        fn isClear(_: *const @This(), dx: i64, dy: i64) bool {
            return @max(@abs(dx), @abs(dy)) != 1;
        }

        fn isStandable(_: *const @This(), dx: i64, dy: i64) bool {
            return dx == 3 and dy == 0;
        }
    };

    const box = Box{};
    try std.testing.expect(!canReachOutside(&box, Box.canEnter));

    // Four clear points sit two blocks away, but only the ledge keeps the player off a fall.
    const landing = nearestExteriorLanding(&box, Box.canEnter, Box.isClear, Box.isStandable) orelse unreachable;
    try std.testing.expectEqual(@as(i16, 3), landing.x);
    try std.testing.expectEqual(@as(i16, 0), landing.y);
}
