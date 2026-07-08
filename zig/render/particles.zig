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
    /// Speed range in viewport pixels per render frame. Kept wide so burst speeds visibly vary.
    speed_min: f32 = 0.6,
    speed_max: f32 = 1.6,
    /// Square edge length range in viewport pixels.
    size_min: f32 = 0.8,
    size_max: f32 = 3.0,
    /// Spin magnitude range (radians per render frame); direction is randomized.
    spin_min: f32 = 0.02,
    spin_max: f32 = 0.12,
    /// Lifetime range of each spawned particle, in render frames; sampled per particle so
    /// individual bits of a burst dissipate at visibly different moments.
    lifetime_min: u16 = 14,
    lifetime_max: u16 = 30,
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
/// Each picks a uniformly random color from `colors` (white if empty), a random size within the
/// configured range, and a random starting rotation that keeps spinning until it fades out.
pub fn spawnBurst(origin: Vec2f32, colors: []const [4]f32, config: BurstConfig) void {
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

/// Advances and draws every live particle. Called once per render frame from `updateEntities()`.
pub fn draw() void {
    @setFloatMode(.optimized);
    for (&pool) |*p| {
        if (p.frames_left == 0) continue;
        p.frames_left -= 1;

        p.position += p.velocity;
        p.rotation += p.spin;

        // Interpolate opacity linearly down to 0 at the end of the lifetime
        const fade = @as(f32, @floatFromInt(p.frames_left)) / @as(f32, @floatFromInt(p.lifetime));

        dw.entity.addEntity(.{
            .sprite = .particle,
            .position = p.position,
            .size = p.size,
            .rotation = p.rotation,
            .lcha = .{ p.lcha[0], p.lcha[1], p.lcha[2], p.lcha[3] * fade * MAX_OPACITY },
        });
    }
}
