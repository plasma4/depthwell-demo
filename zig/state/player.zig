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
const Vec2f32 = dw.utils.Vec2f32;
const Vec4f32 = dw.utils.Vec4f32;
const palette = @import("../render/sprite_colors.zig");

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
/// Inside it, with the jump key held, gravity is scaled by `GRAVITY_MULT_APEX`.
pub var REDUCED_GRAVITY_RANGE: f64 = 0.50;
/// Decay rate of player movement (vertical), multiplies Y speed by (1.0 - this value).
pub var DECAY_RATE_Y: f64 = 0.03;
/// Decay rate of player movement (vertical) while the player slides down a wall.
/// Held above `DECAY_RATE_Y` so a slide settles slower than a free fall.
/// A damped fall settles at `GRAVITY * (1 - rate) / rate`.
/// So a bigger rate is a slower slide.
pub var DECAY_RATE_Y_SLIDE: f64 = 0.14;

// Gravity multipliers, one per phase of the jump arc.
// See the block that reads them in move().

/// Gravity near the apex with the jump key still down.
/// Under 1 to buy hang time over the top.
pub var GRAVITY_MULT_APEX: f64 = 0.60;
/// Gravity everywhere the arc needs no shaping.
/// Exactly 1, so it must stay the neutral value.
pub const GRAVITY_MULT_BASE: f64 = 1.00;
/// Gravity on a slow fall after the jump key came up.
/// Over 1 for a snappier drop.
pub var GRAVITY_MULT_FALL_SNAP: f64 = 1.20;
/// Gravity while still rising after the jump key came up.
/// The main brake that ends a short jump.
pub var GRAVITY_MULT_RISE_CUT: f64 = 1.80;

/// Fall speed above which `GRAVITY_MULT_FALL_SNAP` stops applying.
/// In world pixels per 60 FPS frame.
/// Past it the fall is already fast enough that a snap would only read as a lurch.
pub var VELOCITY_FALL_SNAP_MAX: f64 = 3.00;
/// Speed cut taken off an upward velocity per 60 FPS frame once the jump key comes up.
/// `GRAVITY_MULT_RISE_CUT` scales with the current speed, so this is the floor under it.
pub var DECAY_Y_LINEAR: f64 = 0.20;
/// Terminal fall speed in world pixels per 60 FPS frame, about 28 blocks per second.
/// Decay alone settles just under it, quite intentionally!
pub var VELOCITY_FALL_MAX: f64 = 7.50;

comptime {
    if (GRAVITY_MULT_BASE != 1.00)
        @compileError("`GRAVITY_MULT_BASE` is the unshaped case and must leave gravity alone.");
}

// ----
// Movement limits.
//
// world.SimBuffer.precacheChunks() sizes its per-tick budget from these,
// so they must stay true when a tuning slider moves.
// That is why they are functions and not constants:
// with dev_menu off every knob below is a const and each one folds to a literal anyway.
//
// Every value is in world pixels per 60 FPS FRAME, the same unit as game.player_velocity,
// and none of them depends on logic_speed. move() integrates the decay in closed form,
// so its steady state is a fixed point of that map and one tick at speed 2 lands where two ticks at speed 1 do.
// ----

/// Fastest the player can ever travel horizontally.
///
/// `move()` is a damped linear system (fancy!): v = v * (1 - r) + input * (1 - r)`.
/// Its fixed point is `input * (1 - r) / r`, so the top speed moves when either
/// `PLAYER_ACCEL` or `DECAY_RATE_ACCEL_X` does.
///
/// Ghost mode feeds the SAME equation a `GHOST_SPEED_MULT` times larger input,
/// so it sets the ceiling wherever the debug menu is compiled in.
pub inline fn horizontalMovementMax() f64 {
    const input = PLAYER_ACCEL * (if (dw.dev_menu) GHOST_SPEED_MULT else 1.0);
    return input * (1.0 - DECAY_RATE_ACCEL_X) / DECAY_RATE_ACCEL_X;
}

/// Fastest the player can ever travel vertically.
///
/// Falling is capped outright by `VELOCITY_FALL_MAX`.
/// Rising is NOT a steady state: a jump assigns `-JUMP_FORCE` in one tick, so the rise is
/// bounded by the jump itself rather than by any decay.
/// A ghost flies on the X constants (see `move()`), so it reuses that bound here.
pub inline fn verticalMovementMax() f64 {
    const flight = if (dw.dev_menu) horizontalMovementMax() else 0.0;
    return @max(@max(VELOCITY_FALL_MAX, JUMP_FORCE), flight);
}

/// Why the prefetch cannot budget from the LIVE velocity, only from the two bounds above.
///
/// X reverses in about three ticks, so it is at least predictable.
/// Y is not: a jump ASSIGNS `-JUMP_FORCE` in one tick rather than accelerating into it, and a
/// grounded player at rest is always one keypress from that. So the worst case for the next
/// tick is the global bound whatever the player is doing right now, and there is nothing to
/// gain by scaling the budget down when they happen to be standing still.
/// The live velocity does still pick the DIRECTION to prefetch first.
/// The size of the player's width. The player is assumed to be centered at the bottom as a rectangle.
pub const PLAYER_HITBOX_WIDTH = 128;
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
///
/// `moveSwept()` tests the ground once, after both axes have moved.
/// So the tick that walks off a ledge already reads as airborne.
/// The older axis-at-a-time order tested it mid-move and gave one extra forgiving tick.
/// This value carries that tick instead.
const COYOTE_FRAMES: u8 = 6;
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

/// Which way the player ran into a wall on the last sweep: -1 left, +1 right, 0 nothing.
/// `moveSwept()` writes it, and the NEXT tick's gravity reads it, because gravity is
/// resolved before anything moves.
var wall_contact_dir: i8 = 0;
/// Whether the player slid down a wall on this tick.
/// Read by the dust emitter.
var is_wall_sliding: bool = false;

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
///
/// Motion only. Whoever moves the CAMERA re-seats the particle anchor,
/// after the camera lands (see `particles.syncAnchor()`).
pub fn resetMotionState() void {
    is_grounded = false;
    coyote_frames = 0;
    subpixel_accum = .{ 0.0, 0.0 };
    jumps_left = MAX_JUMPS;
    jump_leniency_frames = 0;
    wall_contact_dir = 0;
    is_wall_sliding = false;
    dust_run_travel = 0.0;
    dust_slide_travel = 0.0;
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
        .player_walk5,
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
/// `logic_speed` is how many 60 FPS frames the tick covers,
/// so the walk cycle keeps its speed in SECONDS when the tick rate is lowered.
pub fn tickAnimation(logic_speed: f64) void {
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
    // A slow tick is worth many frames, so the clip can owe more than one step. The loop pays them
    // all, which keeps a 2 Hz tick on the same cycle as a 60 Hz one instead of holding each pose 30x.
    anim_timer += @intFromFloat(@max(1.0, @round(logic_speed)));
    while (anim_timer >= clip.frame_ticks) {
        anim_timer -= clip.frame_ticks;
        if (anim_frame + 1 < clip.frames.len) {
            anim_frame += 1;
        } else if (clip.loop) {
            anim_frame = 0;
        } else {
            anim_timer = 0; // a clip that holds its last frame has nothing left to owe
            break;
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
pub fn tickSoftlockFade(logic_speed: f64) void {
    if (softlock_fade_frame == 0) return;
    if (softlock_fade_frame >= SOFTLOCK_FADE_TOTAL_FRAMES) {
        softlock_fade_frame = 0;
        return;
    }
    // The pulse is 24 frames of fade, so it must stay 24 frames of REAL time at any tick rate.
    softlock_fade_frame +|= @intFromFloat(@max(1.0, @round(logic_speed)));
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
    // Handle camera zoom interpolation!
    const old_camera_scale = game.camera_scale;
    if (KeyBits.isSet(KeyBits.plus, game.keys_held_mask)) {
        // .pow is safe here despite being inconsistent on different devices; it's mainly visual
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

    std.debug.assert(DECAY_RATE_ACCEL_X > 0 and DECAY_RATE_DECEL_X > 0 and DECAY_RATE_Y > 0 and DECAY_RATE_Y_SLIDE > 0);
    const decay_rate_x = if (left_key_held or right_key_held) DECAY_RATE_ACCEL_X else DECAY_RATE_DECEL_X;

    // A wall slide is a heavier vertical damping, nothing else.
    // wall_contact_dir is last tick's, because the sweep that sets it has not run yet.
    // One tick of lag is invisible next to the ten or so ticks a slide lasts.
    is_wall_sliding = !isGhost() and !is_grounded and
        game.player_velocity[1] > 0 and
        ((wall_contact_dir < 0 and left_key_held) or (wall_contact_dir > 0 and right_key_held));
    const decay_rate_y = if (is_wall_sliding) DECAY_RATE_Y_SLIDE else DECAY_RATE_Y;

    const x_mult = 1.0 - decay_rate_x;
    const y_mult = 1.0 - decay_rate_y;
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

        // Decay first, then gravity. The (1 - pow_fy) / decay_rate_y factor integrates a constant
        // acceleration under that decay, so one tick at logic_speed 2 lands where two ticks at 1 do.
        var y_vel = game.player_velocity[1] * pow_fy;

        // Gravity strength by arc phase. Each case names its own multiplier:
        // - near the apex, key down    hang time over the top of the jump.
        // - near the apex, key up      no brake through the turn, so the arc has no kink.
        // - rising, key up             ends the rise early, which is the short jump.
        // - falling slowly, key up     a snappier drop back to the ground.
        // - everything else            key still down, or already falling fast.
        const gravity_mult: f64 = if (@abs(y_vel) < REDUCED_GRAVITY_RANGE)
            (if (up_key_held) GRAVITY_MULT_APEX else GRAVITY_MULT_BASE)
        else if (up_key_held or y_vel > VELOCITY_FALL_SNAP_MAX)
            GRAVITY_MULT_BASE
        else if (y_vel >= 0)
            GRAVITY_MULT_FALL_SNAP
        else
            GRAVITY_MULT_RISE_CUT;
        y_vel += (GRAVITY * y_mult * (1.0 - pow_fy) / decay_rate_y) * gravity_mult;

        // The second brake on a released jump. The multiplier above scales with current speed,
        // so additional linear logic helps keep a "baseline" that forces the player to fall faster.
        if (y_vel < 0 and !up_key_held) {
            y_vel = @min(y_vel + DECAY_Y_LINEAR * logic_speed, 0);
        }

        y_vel = @min(y_vel, VELOCITY_FALL_MAX);

        game.player_velocity[1] = y_vel;
    }

    // Displacement over the tick, taken at the END-of-tick velocity rather than the average.
    // It undershoots slightly while accelerating; the jump arc is tuned around that, so leave it.
    const displacement = game.player_velocity * @as(Vec2f, @splat(logic_speed * dw.CHUNK_SIZE_FLOAT));
    subpixel_accum += displacement;

    const total_move: Vec2i = @intFromFloat(@floor(subpixel_accum));
    subpixel_accum -= @as(Vec2f, @floatFromInt(total_move));

    game.last_player_pos = game.player_pos;

    const was_grounded = is_grounded;
    const impact_velocity = game.player_velocity[1];
    moveSwept(total_move);
    const bumped_ceiling = impact_velocity < -DUST_CEILING_VELOCITY_MIN and
        game.player_velocity[1] == 0 and
        isColliding(game.player_pos[0], game.player_pos[1] - 1);

    is_grounded = isColliding(game.player_pos[0], game.player_pos[1] + 1);

    if (is_grounded) {
        coyote_frames = COYOTE_FRAMES;
        jumps_left = MAX_JUMPS;
    } else if (coyote_frames > 0) {
        coyote_frames -= logic_speed; // this CAN be negative!
    }

    if (up_key_pressed and !jumped_this_frame) {
        jump_leniency_frames = JUMP_LENIENCY_FRAMES;
    } else if (jump_leniency_frames > 0) {
        jump_leniency_frames -= logic_speed; // this CAN be negative!
    }

    // Finally, tell SimBuffer and the camera to update.
    world.SimBuffer.sync(game.getPlayerCoord());
    updateCamera(logic_speed);

    // After the camera, so dust measures against the camera it will be anchored to.
    emitMovementDust(
        is_grounded and !was_grounded,
        jumped_this_frame and was_grounded,
        bumped_ceiling,
        impact_velocity,
    );
}

// ----
// Movement dust.
//
// Near-white puffs, anchored to the world, so the player runs out from under their own trail instead of dragging it along.
// Every emitter spawns per DISTANCE travelled.
//
// A puff has one initial kick and one constant brake.
// The brake cancels that kick exactly at the last frame of its life;
// the puff flies out, coasts, and settles, with no per-frame drag term.
// The particle tick integrates a constant acceleration in closed form.
// That is what keeps the curve identical at any tick rate.
// ----

/// How much of the sampled block's own color survives into a puff.
/// 0 is pure white dust and 1 is the raw block color.
/// In between the puff is that color washed toward white, which reads as pulverized, not chipped.
/// An `f64` only so the debug slider can reach it.
pub var DUST_TINT: f64 = 0.75;
/// Odds a puff takes the block's SECOND most common color instead of its primary.
/// Both come from `sprite_colors.zig`, which counts texels per atlas tile.
pub var DUST_SECONDARY_ODDS: f32 = 0.35;
/// Lightness jitter, as a multiplier on the tinted lightness.
/// This is what keeps a burst off one flat tone.
pub var DUST_LIGHTNESS_MIN: f32 = 0.78;
pub var DUST_LIGHTNESS_MAX: f32 = 1.18;
/// Chroma jitter, as a multiplier on the tinted chroma.
pub var DUST_CHROMA_MIN: f32 = 0.90;
pub var DUST_CHROMA_MAX: f32 = 1.45;
/// Chroma multiplier for dust that borrows a neighboring floor block.
const DUST_ADJACENT_CHROMA_MULT: f32 = 0.60;
/// Opacity band a puff picks from, before the pool's own fade curve.
pub var DUST_ALPHA_MIN: f32 = 0.38;
pub var DUST_ALPHA_MAX: f32 = 0.72;

/// Spin band, in radians per 60 FPS frame.
/// The sign is part of the range, so puffs turn both ways.
const DUST_SPIN_MAX: f32 = 0.06;

/// World pixels of running between two footfall puffs.
const DUST_RUN_SPACING_PX: f64 = 5.0;
/// Horizontal speed under which running raises no dust at all, in world pixels per frame.
const DUST_RUN_VELOCITY_MIN: f64 = 0.60;
/// World pixels of sliding between two wall puffs.
const DUST_SLIDE_SPACING_PX: f64 = 0.6;
/// Fall speed a landing must beat before it puffs, in world pixels per frame.
const DUST_LAND_VELOCITY_MIN: f64 = 1.80;
/// Upward speed a ceiling hit must beat before it puffs, in world pixels per frame.
const DUST_CEILING_VELOCITY_MIN: f64 = 1.00;
/// Smallest possible ceiling bump particle amount; float for easier math.
const DUST_CEILING_COUNT_MIN: f32 = 6;
/// Largest possible ceiling bump particle amount; float for easier math.
const DUST_CEILING_COUNT_MAX: f32 = 18;
/// Sink on a puff thrown off the ground, in viewport pixels per frame squared.
/// Run and slide dust get none: it hangs where it was raised.
const DUST_SINK: f32 = 0.005;

/// Distance run since the last footfall puff, in world pixels.
var dust_run_travel: f64 = 0.0;
/// Distance slid down a wall since the last wall puff, in world pixels.
var dust_slide_travel: f64 = 0.0;

/// Uniform random float in [min, max), off the shared particle stream.
/// Decoration only: nothing here feeds worldgen or the save.
inline fn dustRand(min: f32, max: f32) f32 {
    return min + (max - min) * dw.particles.seed.float(f32);
}

/// The world subpixel point the player passed through, `frac` of the way along this tick's move.
/// `offset` is measured from the player position, which sits half a block above the feet.
fn pathPointSub(frac: f64, offset: Vec2i) Vec2i {
    const game = &memory.game;
    const delta: Vec2f = @floatFromInt(game.player_pos - game.last_player_pos);
    const base: Vec2f = @floatFromInt(game.last_player_pos + offset);
    return @intFromFloat(base + delta * @as(Vec2f, @splat(frac)));
}

/// The block sprite at a world subpixel point in the player's frame.
///
/// `.none` means air or a point past the world edge.
/// The point must be inside or next to the player hitbox, so its chunk is always resident and this generates nothing.
fn blockSpriteAt(point: Vec2i) Sprite {
    const shift: Vec2i = .{
        @divFloor(point[0], SUBPIXELS_IN_CHUNK),
        @divFloor(point[1], SUBPIXELS_IN_CHUNK),
    };
    const coord = memory.game.getPlayerCoord().move(shift) orelse return .none;
    const chunk = world.getChunkPtr(coord);

    // A mod against a positive divisor is never negative, so both indices land inside the chunk.
    const lx: u4 = @intCast(@divFloor(@mod(point[0], SUBPIXELS_IN_CHUNK), CHUNK_SIZE_SQ));
    const ly: u4 = @intCast(@divFloor(@mod(point[1], SUBPIXELS_IN_CHUNK), CHUNK_SIZE_SQ));
    return chunk.blocks[@as(usize, ly) * CHUNK_SIZE + @as(usize, lx)].id;
}

/// The floor block directly under a point on the bottom edge of the hitbox.
///
/// One sample per puff, at the puff's OWN x, mixes two floor materials by area for free.
/// A player half on green stone and half on plain stone throws each color in that ratio.
/// No coverage arithmetic, and no bias toward whichever block the center happens to sit over.
///
/// Sets `adjacent` to `true` when `floorUnder()` uses a neighboring block.
///
/// Precondition: `foot_point` is ON the bottom edge of the hitbox, so the row below it is the floor.
inline fn floorUnder(foot_point: Vec2i, adjacent: *bool) Sprite {
    adjacent.* = false;
    const floor_point = foot_point + Vec2i{ 0, 1 };
    const floor = blockSpriteAt(floor_point);
    if (!floor.isEmpty()) return floor;

    // A burst can sample just past the edge of the floor while another foot is grounded.
    // Keep that puff colored by the nearest material instead of treating air as a material.
    const local_x = @mod(floor_point[0], CHUNK_SIZE_SQ);
    const near_offset: i64 = if (local_x < CHUNK_SIZE_SQ / 2) -CHUNK_SIZE_SQ else CHUNK_SIZE_SQ;
    const near = blockSpriteAt(floor_point + Vec2i{ near_offset, 0 });
    if (!near.isEmpty()) {
        adjacent.* = true;
        return near;
    }

    const far = blockSpriteAt(floor_point + Vec2i{ -near_offset, 0 });
    if (!far.isEmpty()) adjacent.* = true;
    return far;
}

/// The ceiling block directly above a point on the top edge of the hitbox.
inline fn ceilingAbove(head_point: Vec2i, adjacent: *bool) Sprite {
    adjacent.* = false;
    const ceil_point = head_point - Vec2i{ 0, 1 };
    const ceil = blockSpriteAt(ceil_point);
    if (!ceil.isEmpty()) return ceil;

    const local_x = @mod(ceil_point[0], CHUNK_SIZE_SQ);
    const near_offset: i64 = if (local_x < CHUNK_SIZE_SQ / 2) -CHUNK_SIZE_SQ else CHUNK_SIZE_SQ;
    const near = blockSpriteAt(ceil_point + Vec2i{ near_offset, 0 });
    if (!near.isEmpty()) {
        adjacent.* = true;
        return near;
    }

    const far = blockSpriteAt(ceil_point + Vec2i{ -near_offset, 0 });
    if (!far.isEmpty()) adjacent.* = true;
    return far;
}

/// The LCHA one puff draws at, taken from the block it was raised off.
///
/// A block gives up its two most common atlas colors, so a vein of one ore inside another throws dust in both.
/// `DUST_TINT` then washes that color toward white.
/// In OKLCH, washing toward white is a lightness toward 1 with the chroma going to 0.
/// That keeps the block's hue and drops its saturation, unlike a straight blend with white.
fn dustLcha(ground: Sprite, chroma_mult: f32) Vec4f32 {
    const source: Vec4f32 = if (ground.isEmpty())
        .{ 1.0, 0.0, 0.0, 1.0 }
    else if (dw.particles.seed.float(f32) < DUST_SECONDARY_ODDS)
        palette.secondaryColorOf(ground)
    else
        palette.primaryColorOf(ground);

    const tint: f32 = @floatCast(DUST_TINT);
    const lightness = 1.0 - (1.0 - source[0]) * tint;
    const chroma = source[1] * tint * chroma_mult;
    return .{
        lightness * dustRand(DUST_LIGHTNESS_MIN, DUST_LIGHTNESS_MAX),
        chroma * dustRand(DUST_CHROMA_MIN, DUST_CHROMA_MAX),
        source[2],
        dustRand(DUST_ALPHA_MIN, DUST_ALPHA_MAX),
    };
}

/// Adds one puff that coasts to a stop over its own lifetime, colored by `ground`.
///
/// `kick` is in viewport pixels per frame.
/// The brake cancels it on the last frame, so a puff never slides past where it was aimed.
/// `sink` is whatever downward drift survives that.
fn addDust(
    origin: Vec2f32,
    kick: Vec2f32,
    size: f32,
    life: f32,
    sink: f32,
    ground: Sprite,
    ground_chroma_mult: f32,
) void {
    std.debug.assert(life > 0.0); // the brake divides by it
    dw.particles.addParticle(.{
        .position = origin,
        .velocity = kick,
        .accel = .{ -kick[0] / life, -kick[1] / life + sink },
        .rotation = dustRand(0.0, std.math.tau),
        .spin = dustRand(-DUST_SPIN_MAX, DUST_SPIN_MAX),
        .size = size,
        .lcha = dustLcha(ground, ground_chroma_mult),
        .frames_left = life,
        .lifetime = life,
        .anchored = true,
    });
}

/// Emits every movement puff this tick owes. Call after `updateCamera()`,
/// so a spawn is measured against the camera the anchor already holds.
fn emitMovementDust(landed: bool, jumped: bool, bumped_ceiling: bool, impact_velocity: f64) void {
    @setFloatMode(.optimized);
    const game = &memory.game;
    if (isGhost()) {
        // A ghost touches nothing, so nothing it did this tick has a trail to leave.
        dust_run_travel = 0.0;
        dust_slide_travel = 0.0;
        return;
    }

    const zoom: f32 = @floatCast(game.camera_scale);
    const moved: Vec2f = @floatFromInt(game.player_pos - game.last_player_pos);
    const moved_px = moved / @as(Vec2f, @splat(dw.CHUNK_SIZE_FLOAT));

    if (jumped) {
        spawnJumpDust(zoom);
        dust_run_travel = 0.0;
    }
    if (landed and impact_velocity > DUST_LAND_VELOCITY_MIN) spawnLandDust(zoom, impact_velocity);
    if (bumped_ceiling) spawnCeilingDust(zoom, impact_velocity);

    // One puff per fixed distance, placed back along the path!
    if (is_grounded and @abs(game.player_velocity[0]) > DUST_RUN_VELOCITY_MIN) {
        const run_px = @abs(moved_px[0]);
        dust_run_travel += run_px;
        while (dust_run_travel >= DUST_RUN_SPACING_PX) {
            dust_run_travel -= DUST_RUN_SPACING_PX;
            spawnRunDust(zoom, if (run_px > 0.0) 1.0 - @min(dust_run_travel / run_px, 1.0) else 1.0);
        }
    } else {
        dust_run_travel = 0.0;
    }

    if (is_wall_sliding and wall_contact_dir != 0) {
        const slide_px = @abs(moved_px[1]);
        dust_slide_travel += slide_px;
        while (dust_slide_travel >= DUST_SLIDE_SPACING_PX) {
            dust_slide_travel -= DUST_SLIDE_SPACING_PX;
            spawnSlideDust(zoom, if (slide_px > 0.0) 1.0 - @min(dust_slide_travel / slide_px, 1.0) else 1.0);
        }
    } else {
        dust_slide_travel = 0.0;
    }
}

/// One puff off the trailing foot, kicked back along the ground and faster the faster the run is.
fn spawnRunDust(zoom: f32, frac: f64) void {
    const game = &memory.game;
    const dir: f32 = if (game.player_velocity[0] < 0) -1.0 else 1.0;
    const speed: f32 = @floatCast(@abs(game.player_velocity[0]));

    // The foot that just left the ground is behind the center, and the puff starts at ground level.
    const foot: Vec2i = .{ @intFromFloat(@as(f64, -dir) * 44.0), CHUNK_SIZE_SQ / 2 };
    const point = pathPointSub(frac, foot);
    const origin = dw.particles.anchorScreenPx(point) +
        Vec2f32{ dustRand(-1.6, 1.6), dustRand(-1.2, 0.6) } * @as(Vec2f32, @splat(zoom));
    var adjacent_floor = false;
    const ground = floorUnder(point, &adjacent_floor);

    const life = dustRand(24.0, 44.0);
    const kick: Vec2f32 = .{
        -dir * dustRand(0.12, 0.34) * speed,
        -dustRand(0.10, 0.34),
    };
    addDust(
        origin,
        kick * @as(Vec2f32, @splat(zoom)),
        dustRand(0.8, 2.0) * zoom,
        life,
        0.0,
        ground,
        if (adjacent_floor) DUST_ADJACENT_CHROMA_MULT else 1.0,
    );
}

/// A fan under the feet on the frame the jump leaves the ground.
const DUST_JUMP_COUNT: usize = 12;

fn spawnJumpDust(zoom: f32) void {
    // At the START of the tick: the ground the jump pushed off, not where the rise ended.
    const feet: Vec2i = .{ 0, CHUNK_SIZE_SQ / 2 };
    const center = pathPointSub(0.0, feet);

    for (0..DUST_JUMP_COUNT) |_| {
        // Spread across the hitbox width first, so each puff can sample the floor it stands over.
        const spread: i64 = @intFromFloat(dustRand(-PLAYER_HITBOX_WIDTH / 2, PLAYER_HITBOX_WIDTH / 2));
        const point = center + Vec2i{ spread, 0 };
        const origin = dw.particles.anchorScreenPx(point) +
            Vec2f32{ 0.0, dustRand(-1.0, 1.0) * zoom };
        var adjacent_floor = false;
        const ground = floorUnder(point, &adjacent_floor);

        // A downward half circle: the puff is the ground being pushed, not the player rising.
        const angle = dustRand(0.20, std.math.pi - 0.20);
        const speed = dustRand(0.40, 1.15);
        const life = dustRand(20.0, 36.0);
        const kick: Vec2f32 = .{ @cos(angle) * speed, @sin(angle) * speed * 0.5 };
        addDust(
            origin,
            kick * @as(Vec2f32, @splat(zoom)),
            dustRand(0.8, 2.2) * zoom,
            life,
            DUST_SINK * zoom,
            ground,
            if (adjacent_floor) DUST_ADJACENT_CHROMA_MULT else 1.0,
        );
    }
}

/// Smallest possible landing burst particle amount; float for easier math.
const DUST_LAND_COUNT_MIN: f32 = 12;
/// Largest possible landing burst particle amount; float for easier math.
const DUST_LAND_COUNT_MAX: f32 = 40;

/// A burst that splits left and right along the ground, sized by how hard the landing was.
fn spawnLandDust(zoom: f32, impact_velocity: f64) void {
    const strength: f32 = @floatCast(std.math.clamp(
        (impact_velocity - DUST_LAND_VELOCITY_MIN) / (VELOCITY_FALL_MAX - DUST_LAND_VELOCITY_MIN),
        0.0,
        1.0,
    ));
    const count: usize = @intFromFloat(DUST_LAND_COUNT_MIN +
        (DUST_LAND_COUNT_MAX - DUST_LAND_COUNT_MIN) * strength);

    const feet: Vec2i = .{ 0, CHUNK_SIZE_SQ / 2 };
    const center = memory.game.player_pos + feet;

    for (0..count) |i| {
        // Alternating sides rather than a random one, so a small burst still reads as a splash.
        const side: f32 = if (i % 2 == 0) 1.0 else -1.0;
        // Biased outward along its own side, so the splash samples the whole width it landed on.
        const spread: i64 = @intFromFloat(side * dustRand(0.0, PLAYER_HITBOX_WIDTH / 2));
        const point = center + Vec2i{ spread, 0 };
        var adjacent_floor = false;
        const ground = floorUnder(point, &adjacent_floor);

        const life = dustRand(26.0, 50.0);
        const kick: Vec2f32 = .{
            side * dustRand(0.45, 1.05) * (0.6 + strength),
            -dustRand(0.05, 0.45) * (0.4 + strength),
        };
        addDust(
            dw.particles.anchorScreenPx(point) + Vec2f32{ 0.0, dustRand(-1.0, 0.5) * zoom },
            kick * @as(Vec2f32, @splat(zoom)),
            dustRand(0.9, 1.4 + 1.6 * strength) * zoom,
            life,
            DUST_SINK * zoom,
            ground,
            if (adjacent_floor) DUST_ADJACENT_CHROMA_MULT else 1.0,
        );
    }
}

/// One puff scraped off the wall the player is sliding down.
/// It stays where it was scraped, so the falling player visibly outruns it.
fn spawnSlideDust(zoom: f32, frac: f64) void {
    const dir: f32 = @floatFromInt(wall_contact_dir);
    const contact: Vec2i = .{
        @intFromFloat(@as(f64, dir) * (PLAYER_HITBOX_WIDTH / 2)),
        // Anywhere down the body that is touching, not just the feet.
        @intFromFloat(dustRand(CHUNK_SIZE_SQ / 2 - PLAYER_HITBOX_HEIGHT, CHUNK_SIZE_SQ / 2)),
    };
    const point = pathPointSub(frac, contact);
    const origin = dw.particles.anchorScreenPx(point);

    const life = dustRand(22.0, 40.0);
    const kick: Vec2f32 = .{
        -dir * dustRand(0.06, 0.26),
        -dustRand(0.05, 0.22),
    };
    // One subpixel further into the wall, which is the cell this puff was scraped off.
    addDust(
        origin,
        kick * @as(Vec2f32, @splat(zoom)),
        dustRand(0.6, 1.6) * zoom,
        life,
        0.0,
        blockSpriteAt(point + Vec2i{ wall_contact_dir, 0 }),
        1.0,
    );
}

/// A downward shower off the ceiling when the player bumps their head while rising.
fn spawnCeilingDust(zoom: f32, impact_velocity: f64) void {
    const strength: f32 = @floatCast(std.math.clamp(
        (@abs(impact_velocity) - DUST_CEILING_VELOCITY_MIN) / (JUMP_FORCE - DUST_CEILING_VELOCITY_MIN),
        0.0,
        1.0,
    ));
    const count: usize = @intFromFloat(DUST_CEILING_COUNT_MIN +
        (DUST_CEILING_COUNT_MAX - DUST_CEILING_COUNT_MIN) * strength);

    const head_y = CHUNK_SIZE_SQ / 2 - PLAYER_HITBOX_HEIGHT;
    const center = memory.game.player_pos + Vec2i{ 0, head_y };

    for (0..count) |_| {
        const spread: i64 = @intFromFloat(dustRand(-PLAYER_HITBOX_WIDTH / 2, PLAYER_HITBOX_WIDTH / 2));
        const point = center + Vec2i{ spread, 0 };
        var adjacent_ceil = false;
        const ground = ceilingAbove(point, &adjacent_ceil);

        // Downward cone: dislodged particles shower downward and scatter slightly outward
        const angle = dustRand(0.15 * std.math.pi, 0.85 * std.math.pi);
        const speed = dustRand(0.30, 1.10) * (0.6 + strength * 0.5);
        const life = dustRand(18.0, 36.0);
        const kick: Vec2f32 = .{ @cos(angle) * speed, @sin(angle) * speed };
        addDust(
            dw.particles.anchorScreenPx(point) + Vec2f32{ 0.0, dustRand(0.0, 1.5) * zoom },
            kick * @as(Vec2f32, @splat(zoom)),
            dustRand(0.7, 1.2 + 0.8 * strength) * zoom,
            life,
            DUST_SINK * 1.5 * zoom,
            ground,
            if (adjacent_ceil) DUST_ADJACENT_CHROMA_MULT else 1.0,
        );
    }
}

/// Returns whether the player hitbox collides after one axis moves by `delta` subpixels.
inline fn isCollidingOffset(comptime axis: u1, delta: i64) bool {
    const game = &memory.game;
    return if (axis == 0)
        isColliding(game.player_pos[0] + delta, game.player_pos[1])
    else
        isColliding(game.player_pos[0], game.player_pos[1] + delta);
}

/// Moves the player along the tick's whole movement VECTOR and stops at the first contact.
///
/// One axis at a time is not enough.
/// Take a move of 3 blocks down and 1 block left, resolved as all of the fall then all of the walk.
/// It checks neither the cell the diagonal crosses nor the wall standing in it.
/// So at a low tick rate the player lands under a floor they should have hit.
/// This walks the vector in sub-steps of at most one block on EITHER axis.
/// No cell on the path then goes unchecked.
///
/// Inside a sub-step the order is vertical, then horizontal.
/// That is what an ordinary one-block-per-tick move already did.
/// So at 60 FPS an ordinary move is one sub-step and lands exactly where it used to.
/// An axis that makes contact loses its velocity and its subpixel remainder.
/// It also stops for the rest of the tick, so a player held against a wall builds no speed into it.
fn moveSwept(total: Vec2i) void {
    wall_contact_dir = 0;

    const sub_steps = sweepSubStepCount(total);
    if (sub_steps == 0) return;

    var blocked_x = total[0] == 0;
    var blocked_y = total[1] == 0;
    var done: Vec2i = .{ 0, 0 };

    var i: i64 = 1;
    while (i <= sub_steps) : (i += 1) {
        const target = sweepTarget(total, i, sub_steps);

        if (!blocked_y and !stepAxis(1, target[1] - done[1])) blocked_y = true;
        if (!blocked_x and !stepAxis(0, target[0] - done[0])) {
            blocked_x = true;
            wall_contact_dir = if (total[0] < 0) -1 else 1;
        }
        if (blocked_x and blocked_y) break;

        // A blocked axis stops here, so only the axis that moved advances the running total.
        if (!blocked_x) done[0] = target[0];
        if (!blocked_y) done[1] = target[1];
    }
}

/// How many sub-steps `moveSwept()` splits a move into, or 0 when there is nothing to move.
///
/// A ceiling division on the longer axis.
/// That holds every sub-step to one block or less on BOTH axes.
/// It is the whole reason the sweep cannot skip a cell.
fn sweepSubStepCount(total: Vec2i) i64 {
    const span: i64 = @intCast(@max(@abs(total[0]), @abs(total[1])));
    return @divFloor(span + CCD_STEP_SIZE - 1, CCD_STEP_SIZE);
}

/// The offset from the start of the move that `index` of `count` sub-steps has covered.
///
/// Measured from the whole move each time rather than summed per step.
/// Rounding then never loses a subpixel, and the last sub-step lands exactly on `total`.
inline fn sweepTarget(total: Vec2i, index: i64, count: i64) Vec2i {
    std.debug.assert(count > 0 and index >= 1 and index <= count);
    return .{ @divTrunc(total[0] * index, count), @divTrunc(total[1] * index, count) };
}

/// Moves one axis by at most one block and returns whether the whole move fit.
///
/// On a contact it lands the player against the obstacle and returns false.
/// It also drops that axis' velocity and subpixel remainder.
/// A world edge counts as a contact, because `isColliding()` reads past it as solid.
fn stepAxis(comptime axis: u1, delta: i64) bool {
    std.debug.assert(@abs(delta) <= CCD_STEP_SIZE);
    const game = &memory.game;
    if (delta == 0) return true;

    if (!isCollidingOffset(axis, delta)) {
        game.player_pos[axis] += delta;
        // A refused carry is the world edge, which already zeroed the axis.
        return !handleLocalWrap(axis);
    }

    const reach = lastClearOffset(axis, delta);
    if (reach != 0) {
        game.player_pos[axis] += reach;
        _ = handleLocalWrap(axis);
    }
    game.player_velocity[axis] = 0;
    subpixel_accum[axis] = 0;
    return false;
}

/// Returns the largest part of `delta` the player can take on one axis before touching a solid.
///
/// A bisection, not a walk.
/// Inside one block step, collision along the axis only ever turns ON.
/// A corner that entered a solid needs a further whole block of travel to clear its far side.
/// The sweep is at most one block.
/// So the clear offsets are a prefix, and the midpoint test is exact.
/// That is 8 collision tests instead of up to 256.
///
/// A player who starts INSIDE a solid breaks that argument.
/// The bisection can then land them in the first clear pocket along the axis.
/// A walk would crawl the same way and it unsticks them, so it is left alone.
/// `escapeSolid()` owns the real case.
///
/// Precondition: `delta` is inside one `CCD_STEP_SIZE` and the player collides at it.
fn lastClearOffset(comptime axis: u1, delta: i64) i64 {
    std.debug.assert(@abs(delta) <= CCD_STEP_SIZE);

    // Both bounds are magnitudes; the sign goes back on at the end.
    const step: i64 = if (delta > 0) 1 else -1;
    var clear: i64 = 0;
    var blocked: i64 = @intCast(@abs(delta));
    while (blocked - clear > 1) {
        const middle = @divFloor(clear + blocked, 2);
        if (isCollidingOffset(axis, step * middle)) blocked = middle else clear = middle;
    }
    return step * clear;
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
            // The particle anchor lives in the same frame as the camera, so it carries too.
            // Without this, a carry reads as a teleport and every anchored particle jumps a chunk.
            var anchor_shift: Vec2i = .{ 0, 0 };
            anchor_shift[axis] = subpixel_offset;
            dw.particles.rebaseAnchor(anchor_shift);
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
    dw.particles.syncAnchor(); // the camera jumped, so the particle anchor jumps with it
    resetMotionState();
}

/// Performs an AABB check (for the player's position) against the world grid.
pub fn isColliding(px: i64, py: i64) bool {
    // Ghost mode goes through everything (see the lift branch in move()).
    if (isGhost()) return false;

    const game = &memory.game;
    const corners = playerCorners(px, py);

    const player_coord = game.getPlayerCoord();
    var last_coord: ?world.Coordinate = null;
    // Borrowed for the length of this loop only, which generates nothing (see getChunkPtr()).
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

test "a swept move never advances more than one block on either axis" {
    // The bug this guards: a fall of several blocks plus a step sideways, resolved one whole axis at a time,
    // walks around the corner block the diagonal actually crosses.
    // At two logical FPS the player fell past a floor by moving left first.
    // Holding every sub-step to one block on both axes is what makes that impossible,
    // since the hitbox is never wider than a block.
    const cases = [_]Vec2i{
        .{ 0, 0 },
        .{ 1, 0 },
        .{ 0, -1 },
        .{ 255, 255 },
        .{ 256, 256 },
        .{ 257, -3 },
        .{ -256, 768 }, // the reported case: one block left, three blocks down
        .{ 4095, -7 },
        .{ -7000, 7000 },
        .{ 12345, -1 },
    };

    for (cases) |total| {
        const count = sweepSubStepCount(total);
        if (count == 0) {
            try std.testing.expectEqual(Vec2i{ 0, 0 }, total);
            continue;
        }

        var previous: Vec2i = .{ 0, 0 };
        var i: i64 = 1;
        while (i <= count) : (i += 1) {
            const target = sweepTarget(total, i, count);
            const delta = target - previous;
            try std.testing.expect(@abs(delta[0]) <= CCD_STEP_SIZE);
            try std.testing.expect(@abs(delta[1]) <= CCD_STEP_SIZE);
            // No sub-step may overshoot and walk back, or a contact would land behind the player.
            try std.testing.expect(@abs(target[0]) >= @abs(previous[0]));
            try std.testing.expect(@abs(target[1]) >= @abs(previous[1]));
            previous = target;
        }
        // The schedule must spend the whole move, to the subpixel.
        try std.testing.expectEqual(total, previous);
    }
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
