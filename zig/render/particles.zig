//! Fixed-capacity particle system rendered with the square `.particle` sprite.
//!
//! Colors come from `particle_colors.zig`, generated at build time from the sprite atlases by `zig/generate_pixel_data.zig`,
//! so each sprite tile exposes its unique texel colors as OKLCH tints.
//! Particles live in a simple circular buffer that overrides the oldest particle.
//!
//! Spawn from elsewhere via `addParticle()` or `spawnBurst()`/`spawnSpriteBurst()`/`maybeSpawnSpriteBurst()`.
const std = @import("std");
const dw = @import("../root.zig");
const palette = @import("sprite_colors.zig");

const Sprite = dw.Sprite;
const Vec2f32 = dw.utils.Vec2f32;
const Vec4f32 = dw.utils.Vec4f32;

/// Random seed used for particle spawning. Seeded in `startup.init()`.
pub var seed: dw.seeding.ChaCha12 = undefined;

/// Circular buffer capacity. Must be a power of two so the write index wraps with a mask.
pub const MAX_PARTICLES = 8192;
/// Maximum opacity of any particle (lerped based on lifetime).
const MAX_OPACITY = 0.8;
/// Render frames a particle fades in over, so dense emitters build instead of popping on.
const FADE_IN_FRAMES: f32 = 3.0;
/// Floor on the distance used to aim `Particle.pull`,
/// so a particle sitting exactly on its attractor gets an actual direction.
const MIN_PULL_DISTANCE: f32 = 0.5;

/// Softening length of the attraction, in viewport pixels: the `s` in `pull / (d^2 + s^2)`.
///
/// A bare inverse square goes singular at the center, so the few particles that pass closest take an
/// unbounded kick in a single tick and leave the screen. Softening bounds the acceleration at
/// `pull / s^2` while leaving the falloff alone past a few pixels, which is where the motion reads.
const PULL_SOFTENING: f32 = 3.0;

comptime {
    if (!std.math.isPowerOfTwo(MAX_PARTICLES))
        @compileError("MAX_PARTICLES must be a power of two for mask-based index wrapping!");
}

/// One live (or dead) particle. All units are internal-viewport pixels and render frames.
pub const Particle = struct {
    /// Center position in viewport pixels.
    position: Vec2f32 = .{ 0.0, 0.0 },
    /// Velocity in viewport pixels per render frame.
    velocity: Vec2f32 = .{ 0.0, 0.0 },
    /// Current rotation (radians).
    rotation: f32 = 0.0,
    /// Rotation applied each render frame (radians).
    spin: f32 = 0.0,
    /// Square edge length in viewport pixels.
    size: f32 = 2.0,
    /// Point this particle accelerates toward, in viewport pixels. Only read when `pull` is non-zero.
    attractor: Vec2f32 = .{ 0.0, 0.0 },
    /// Strength of that attraction, as the numerator of a softened inverse square:
    /// the acceleration at distance `d` is `pull / (d^2 + PULL_SOFTENING^2)`, in viewport pixels
    /// per render frame squared. 0 leaves the particle travelling in a straight line.
    ///
    /// Inverse square rather than a flat magnitude because it is the falloff that sells the swirl:
    /// angular speed climbs as the mouth nears, so a particle visibly whips around it
    /// instead of coasting in at one rate.
    /// `orbitPull()` derives the value that holds a given circle.
    pull: f32 = 0.0,
    /// Base OKLCH+alpha tint; the alpha component is additionally faded to 0 across the lifetime.
    lcha: Vec4f32 = .{ 1.0, 0.0, 0.0, 1.0 },
    /// Render frames remaining; 0 means the slot is dead/free.
    frames_left: u16 = 0,
    /// Total lifetime in render frames, used to interpolate opacity. Must be >= frames_left.
    lifetime: u16 = 1,
};

/// The circular particle pool (constant memory; see file docs).
var pool: [MAX_PARTICLES]Particle = @splat(.{});
/// Next slot to write; wraps around, overwriting the oldest particle when full.
var next_slot: usize = 0;

/// Tunable knobs for `spawnBurst()`. Every range is sampled uniformly per particle.
pub const BurstConfig = struct {
    /// How many particles to spawn.
    count: usize = 10,
    /// Speed range in viewport pixels per render frame.
    speed_min: f32 = 0.6,
    speed_max: f32 = 2.0,
    /// Square edge length range in viewport pixels.
    size_min: f32 = 0.8,
    size_max: f32 = 3.0,
    /// Spin magnitude range (radians per render frame); direction is randomized.
    spin_min: f32 = 0.02,
    spin_max: f32 = 0.12,
    /// Lifetime range of each spawned particle, in render frames.
    lifetime_min: u16 = 12,
    lifetime_max: u16 = 28,
};

/// Kills every particle. Called on world restart from `startup.init()`.
pub fn reset() void {
    for (&pool) |*p| p.frames_left = 0;
    next_slot = 0;
}

/// Uniform random float in [min, max) by advancing `seed`.
fn randRange(min: f32, max: f32) f32 {
    return min + (max - min) * seed.float(f32);
}

/// Pushes one particle into the circular buffer, overwriting the oldest slot when full.
pub fn addParticle(particle: Particle) void {
    pool[next_slot] = particle;
    next_slot = (next_slot + 1) & (MAX_PARTICLES - 1);
}

/// Spawns `config.count` particles radiating from `origin` (viewport pixels) in random directions.
/// Each picks a uniformly random color from `colors` (white if empty), a random size within the configured range,
/// and a random starting rotation that keeps spinning until it fades out.
pub fn spawnBurst(origin: Vec2f32, colors: []const Vec4f32, config: BurstConfig) void {
    for (0..config.count) |_| {
        const angle = randRange(0.0, std.math.tau);
        const speed = randRange(config.speed_min, config.speed_max);
        const spin_magnitude = randRange(config.spin_min, config.spin_max);
        const lifetime: u16 = @intFromFloat(randRange(
            @floatFromInt(config.lifetime_min),
            @floatFromInt(config.lifetime_max + 1),
        ));

        addParticle(.{
            .position = origin,
            .velocity = .{ @cos(angle) * speed, @sin(angle) * speed },
            .rotation = randRange(0.0, std.math.tau),
            .spin = if (seed.float(f32) < 0.5) spin_magnitude else -spin_magnitude,
            .size = randRange(config.size_min, config.size_max),
            .lcha = if (colors.len == 0)
                .{ 1.0, 0.0, 0.0, 1.0 } // white fallback
            else
                colors[@intCast(seed.next() % colors.len)] + Vec4f32{ -0.08 + 0.24 * seed.float(f32), 0.01, 0.0, 0.0 },
            .frames_left = lifetime,
            .lifetime = lifetime,
        });
    }
}

/// Tunable knobs for `spawnOrbitRing()`.
pub const OrbitConfig = struct {
    /// How many particles to spawn.
    count: usize = 6,
    /// Ring radius particles are laid out against, in viewport pixels.
    radius_min: f32 = 24.0,
    radius_max: f32 = 44.0,
    /// Square edge length range in viewport pixels.
    size_min: f32 = 0.8,
    size_max: f32 = 2.4,
    /// Spin magnitude range (radians per render frame); direction is randomized.
    spin_min: f32 = 0.02,
    spin_max: f32 = 0.10,
    /// Frames a particle lives for, and the span its radial speed is set from.
    /// Only the opening approach takes that long: the attraction keeps building on the way in,
    /// so an inward particle reaches the mouth early and spends its remaining frames whipping
    /// around it, which is the behaviour the lifetime is really covering.
    travel_min: u16 = 14,
    travel_max: u16 = 26,
    /// Tangential speed as a multiple of the radial speed.
    /// 0 falls straight in; around 1 the particle circles about as fast as it falls,
    /// which is what turns the fall into a visible spiral.
    swirl: f32 = 1.0,
    /// Fraction of the ring thrown back out from near the mouth instead of drawn in,
    /// so the portal reads as an exchange rather than a drain. 0 is all inward, 1 all outward.
    outward_ratio: f32 = 0.0,
    /// Number of streams the spawn angles are gathered into, or 0 to scatter them evenly.
    /// A handful of arms is what separates a flowing intake from a uniform ring of noise:
    /// the eye follows a stream, but averages a full circle out into a static band.
    arms: u32 = 0,
    /// Rotation of the arm pattern in radians. Advancing it a little per call is what makes the arms
    /// sweep, so successive spawns lay down a continuous spiral rather than a set of fixed spokes.
    arm_phase: f32 = 0.0,
    /// Half-width of an arm in radians. Wide enough reads as a ring again, so keep it well under
    /// half the arm spacing (`tau / arms / 2`).
    arm_spread: f32 = 0.22,
};

/// Radius an outward particle starts at, as a fraction of the ring radius it is aimed at.
/// Non-zero so it already has a lever arm to orbit on rather than shooting out on a straight line.
const OUTWARD_START_FRACTION: f32 = 0.3;

/// What an outward particle keeps of the attraction that holds the inward ones, and how much extra
/// radial speed it leaves with. Ejecta, not a captured orbit: at full strength it would be pulled
/// straight back down within its lifetime, which reads as the portal coughing rather than throwing.
/// Together these leave it climbing for most of its life and only arcing over near the end.
const OUTWARD_PULL_FRACTION: f32 = 0.35;
const OUTWARD_SPEED_GAIN: f32 = 1.6;

/// The `Particle.pull` that holds a circular orbit of `radius` at tangential speed `speed`.
///
/// From `speed^2 / radius = pull / (radius^2 + PULL_SOFTENING^2)`,
/// which is the centripetal requirement written against the softened falloff `accelOf()` applies.
/// Solving with the softening included (rather than assuming `radius` swamps it) is what keeps the
/// ring honest when it is spawned tight around a portal mouth only a few pixels across.
fn orbitPull(radius: f32, speed: f32) f32 {
    const r = @max(radius, MIN_PULL_DISTANCE);
    return speed * speed * (r * r + PULL_SOFTENING * PULL_SOFTENING) / r;
}

/// Spawns particles orbiting `origin`, spiralling in toward it (or back out from its mouth).
///
/// The counterpart to `spawnBurst()`: every particle is given a tangential velocity plus the
/// centripetal `pull` that would hold it in a circle at its spawn radius,
/// then biased radially so the circle opens into an inward or outward spiral.
/// Used for the portal's intake effect.
///
/// `colors` must run coolest-and-dimmest first to hottest last, because the pick is made by spawn
/// radius rather than at random: the rim draws from the front of the slice and the mouth from the
/// back. That is what gives the swirl a legible focal point instead of an even scatter of every
/// color at every radius. A single-entry slice is fine and ignores all of this.
pub fn spawnOrbitRing(origin: Vec2f32, colors: []const Vec4f32, config: OrbitConfig) void {
    std.debug.assert(colors.len != 0);
    for (0..config.count) |_| {
        const angle = if (config.arms == 0) randRange(0.0, std.math.tau) else blk: {
            const arm: f32 = @floatFromInt(seed.next() % config.arms);
            break :blk config.arm_phase + arm * (std.math.tau / @as(f32, @floatFromInt(config.arms))) +
                randRange(-config.arm_spread, config.arm_spread);
        };
        // Squared so the ring crowds toward its inner edge. Spread evenly, most of a disc's area
        // (and so most of its particles) lands out at the rim, which leaves the mouth itself bare.
        const u = seed.float(f32);
        const radius = config.radius_min + (config.radius_max - config.radius_min) * u * u;
        const travel: u16 = @intFromFloat(randRange(
            @floatFromInt(config.travel_min),
            @floatFromInt(config.travel_max + 1),
        ));
        const spin_magnitude = randRange(config.spin_min, config.spin_max);
        const outward = seed.float(f32) < config.outward_ratio;

        const dir: Vec2f32 = .{ @cos(angle), @sin(angle) };
        // Every particle circles the same way, so the ring reads as one rotating body
        // rather than as noise crossing itself.
        const tangent: Vec2f32 = .{ -dir[1], dir[0] };

        const radial_speed = radius / @as(f32, @floatFromInt(travel));
        const tangential_speed = radial_speed * config.swirl;
        const start_radius = if (outward) radius * OUTWARD_START_FRACTION else radius;
        const radial: f32 = if (outward) OUTWARD_SPEED_GAIN else -1.0;

        // Hottest at the mouth, coolest at the rim. Jittered by about an entry so the palette reads
        // as a gradient rather than as concentric bands of flat color.
        const heat = (1.0 - u) * @as(f32, @floatFromInt(colors.len)) + randRange(-0.8, 0.8);
        const index: usize = @intFromFloat(std.math.clamp(heat, 0.0, @as(f32, @floatFromInt(colors.len - 1))));

        addParticle(.{
            .position = origin + dir * @as(Vec2f32, @splat(start_radius)),
            .velocity = dir * @as(Vec2f32, @splat(radial_speed * radial)) +
                tangent * @as(Vec2f32, @splat(tangential_speed)),
            .attractor = origin,
            // Holds a circle at the ring radius exactly; the radial bias above is what makes it a spiral.
            .pull = orbitPull(radius, tangential_speed) *
                (if (outward) OUTWARD_PULL_FRACTION else 1.0),
            .rotation = randRange(0.0, std.math.tau),
            .spin = if (seed.float(f32) < 0.5) spin_magnitude else -spin_magnitude,
            .size = randRange(config.size_min, config.size_max),
            .lcha = colors[index] + Vec4f32{
                -0.05 + 0.10 * seed.float(f32),
                -0.02 + 0.04 * seed.float(f32),
                0.0,
                0.0,
            },
            .frames_left = travel,
            .lifetime = travel,
        });
    }
}

test "orbit ring spirals both ways" {
    seed = dw.seeding.ChaCha12.init(&dw.seeding.Seed{ .value = @splat(7) });
    const origin: Vec2f32 = .{ 100.0, 100.0 };
    const colors = [_]Vec4f32{.{ 1.0, 0.0, 0.0, 1.0 }};

    for ([_]f32{ 0.0, 1.0 }) |ratio| {
        reset();
        spawnOrbitRing(origin, &colors, .{ .count = 32, .outward_ratio = ratio, .travel_min = 20, .travel_max = 20 });

        var before: f32 = 0.0;
        var after: f32 = 0.0;
        for (&pool) |*p| {
            if (p.frames_left == 0) continue;
            before += @reduce(.Add, (p.position - origin) * (p.position - origin));
        }
        // Half a travel in: far enough to see where the spiral is heading, short of anything expiring.
        for (0..10) |_| tick(1);
        for (&pool) |*p| {
            if (p.frames_left == 0) continue;
            after += @reduce(.Add, (p.position - origin) * (p.position - origin));
        }

        if (ratio == 0.0) try std.testing.expect(after < before) else try std.testing.expect(after > before);
    }
    reset();
}

/// Spawns a burst colored from the given sprite's atlas tile (see `colorsOf()`).
pub fn spawnSpriteBurst(s: Sprite, origin: Vec2f32, config: BurstConfig) void {
    spawnBurst(origin, palette.colorsOf(s), config);
}

/// Rolls `chance` (0-1) and spawns a sprite burst on success.
/// Convenience for per-tick emitters like mining chips, where odds scale with tool power.
pub fn maybeSpawnSpriteBurst(chance: f32, s: Sprite, origin: Vec2f32, config: BurstConfig) void {
    if (seed.float(f32) >= chance) return;
    spawnSpriteBurst(s, origin, config);
}

/// This particle's acceleration toward its attractor, or zero when it has none.
/// Shared by `tick()` and `draw()` so the drawn path is the one actually being simulated.
inline fn accelOf(p: *const Particle) Vec2f32 {
    if (p.pull == 0.0) return .{ 0.0, 0.0 };
    const offset = p.attractor - p.position;
    const distance_sq = offset[0] * offset[0] + offset[1] * offset[1];
    const distance = @max(@sqrt(distance_sq), MIN_PULL_DISTANCE);
    // One factor of distance normalizes `offset` into a direction; the softened square is the falloff.
    return offset * @as(Vec2f32, @splat(p.pull / (distance * (distance_sq + PULL_SOFTENING * PULL_SOFTENING))));
}

/// Where a particle sits `lead` frames from its last simulated state.
///
/// Render frames run ahead of logical ticks, so drawing the raw position stutters whenever the two
/// drift apart. Carrying the acceleration along matters for the tightly orbiting ones:
/// extrapolating on velocity alone throws them off on a tangent, which is visible as a wobble
/// exactly where the paths curve hardest.
inline fn leadPosition(p: *const Particle, lead: f32) Vec2f32 {
    return p.position + (p.velocity + accelOf(p) * @as(Vec2f32, @splat(0.5 * lead))) *
        @as(Vec2f32, @splat(lead));
}

/// Moves every live particle.
pub fn tick(ticks: u32) void {
    @setFloatMode(.optimized);
    const dt: f32 = @floatFromInt(ticks);
    for (&pool) |*p| {
        p.frames_left = @intCast(@as(u32, p.frames_left) -| ticks);
        // Integrated rather than stepped, so a multi-tick catch-up traces the same curve as single ticks.
        const accel = accelOf(p);
        p.position += (p.velocity + accel * @as(Vec2f32, @splat(0.5 * dt))) * @as(Vec2f32, @splat(dt));
        p.velocity += accel * @as(Vec2f32, @splat(dt));
        p.rotation += p.spin * dt;
    }
}

/// Draws every live particle. Called once per render frame from `updateEntities()`.
pub fn draw() void {
    @setFloatMode(.optimized);
    const portal_fade = dw.portal.getDescentFade();

    for (&pool) |*p| {
        if (p.frames_left <= 0) continue;

        // Interpolate opacity linearly down to 0 at the end of the lifetime, with a short ramp up
        // out of nothing at the start so a dense emitter does not pop its particles into existence.
        // Square-rooted rather than linear: an orbiting particle spends its last frames at the center
        // it is being pulled into, and a linear fade has it at its dimmest exactly there.
        // This holds it bright through the approach and drops it over the final frames instead.
        const age: f32 = @floatFromInt(p.lifetime - p.frames_left);
        const fade = @sqrt(@as(f32, @floatFromInt(p.frames_left)) / @as(f32, @floatFromInt(p.lifetime))) *
            @min(age / FADE_IN_FRAMES, 1.0);

        // Both the position and the rotation are carried forward by the render frame's lead over the
        // last tick; the size is fixed for a particle's whole life.
        const lead: f32 = @as(f32, @floatCast(dw.chunks.current_dt)) + 1.0;

        dw.entity.addEntity(.{
            .sprite = .particle,
            .position = leadPosition(p, lead),
            .size = p.size,
            .rotation = p.rotation + p.spin * lead,
            .lcha = .{
                p.lcha[0],
                p.lcha[1],
                p.lcha[2],
                p.lcha[3] * fade * MAX_OPACITY * portal_fade,
            },
        });
    }
}
