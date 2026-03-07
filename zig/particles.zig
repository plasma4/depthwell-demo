const std = @import("std");
const memory = @import("memory.zig");
const Particle = memory.Particle;

/// Custom circular buffer system for particles that doesn't require CPU-side culling.
pub const ParticleSystem = struct {
    list: std.MultiArrayList(Particle) = .{},
    max_particles: usize,

    pub fn init(allocator: std.mem.Allocator, max: usize) !ParticleSystem {
        var sys = ParticleSystem{ .max_particles = max };
        try sys.list.ensureTotalCapacity(allocator, max);
        return sys;
    }

    pub fn spawn(self: *ParticleSystem, particle: Particle) void {
        if (self.list.len < self.max_particles) {
            self.list.appendAssumeCapacity(particle);
        }
    }

    /// Updates physics and culls dead particles using Swap-and-Pop
    pub fn updateAndCull(self: *ParticleSystem, dt: f32) void {
        const times = self.list.items(.time);
        const positions = self.list.items(.position);
        const d_positions = self.list.items(.d_position);
        const rotations = self.list.items(.rotation);
        const d_rotations = self.list.items(.d_rotation);

        var i: usize = 0;
        while (i < self.list.len) {
            times[i] -= @intFromFloat(dt * 1000.0);

            if (times[i] <= 0) {
                // Dead: Swap with the last element and pop.
                self.list.swapRemove(i);
            } else {
                // Alive: Update physics
                const dt_splat: @Vector(2, f32) = @splat(dt);
                positions[i] += d_positions[i] * dt_splat;
                rotations[i] += d_rotations[i] * dt;

                i += 1;
            }
        }
    }

    /// Packs the SoA data into AoS format in the scratch buffer for WebGPU. Overwrites data in scratch buffer, disregarding pre-existing data.
    pub fn exportToScratch(self: *ParticleSystem) void {
        const total_bytes = self.list.len * @sizeOf(Particle);
        memory.scratch_reset();

        if (total_bytes > memory.mem.scratch_capacity) {
            @branchHint(.cold);
            memory.scratch_alloc(total_bytes);
        }

        // Cast scratch memory to a slice of Particles
        const dest_buffer = @as([*]Particle, @ptrFromInt(memory.mem.scratch_ptr));

        // Copy active particles
        for (0..self.list.len) |i| {
            dest_buffer[i] = self.list.get(i);
        }

        // Tell JS exactly how many bytes to read
        memory.mem.scratch_len = total_bytes;
    }
};
