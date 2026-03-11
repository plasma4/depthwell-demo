//! Contains important functions and imports other files. See root.zig for exporting these functions (and others) to WASM.
const memory = @import("memory.zig");
const std = @import("std");
const logger = @import("logger.zig");
const seeding = @import("seeding.zig");
const world = @import("world.zig");
const World = world.World;

const CHUNK_SIZE = memory.CHUNK_SIZE;
const CHUNK_SIZE_FLOAT = memory.CHUNK_SIZE_FLOAT;
const SUBPIXELS_IN_CHUNK = memory.SUBPIXELS_IN_CHUNK;
const SCREEN_WIDTH = 480;
const SCREEN_HEIGHT = 270;
const SCREEN_WIDTH_HALF = SCREEN_WIDTH / 2.0;
const SCREEN_HEIGHT_HALF = SCREEN_HEIGHT / 2.0;
pub var world_state: ?World = null;

/// Initializes the game.
pub fn init() void {
    logger.log(@src(), "init() called: Hello from Zig!", .{});

    world_state = World.init(memory.allocator, memory.game.seed);
    const game = &memory.game;
    game.current_depth = 3;
    game.active_chunk = .{ 0, 0 };
    game.player_pos = .{ 0, 0 };
    game.camera_pos = .{ 0, 0 };
    // game.grid_dirty = true;
}

pub fn prepare_visible_chunks() void {
    const w = if (world_state) |*ws| ws else return;
    const game = &memory.game;

    const cam_bx: i32 = @intFromFloat(game.camera_pos[0] / (CHUNK_SIZE_FLOAT * CHUNK_SIZE_FLOAT));
    const cam_by: i32 = @intFromFloat(game.camera_pos[1] / (CHUNK_SIZE_FLOAT * CHUNK_SIZE_FLOAT));

    const half_w: i32 = @intFromFloat((SCREEN_WIDTH_HALF / CHUNK_SIZE_FLOAT) / game.camera_scale);
    const half_h: i32 = @intFromFloat((SCREEN_HEIGHT_HALF / CHUNK_SIZE_FLOAT) / game.camera_scale);

    const min_cx: i32 = @divFloor(cam_bx - half_w, CHUNK_SIZE);
    const min_cy: i32 = @divFloor(cam_by - half_h, CHUNK_SIZE);
    const max_cx: i32 = @divFloor(cam_bx + half_w, CHUNK_SIZE);
    const max_cy: i32 = @divFloor(cam_by + half_h, CHUNK_SIZE);

    const cw: u32 = @intCast(max_cx - min_cx + 1);
    const ch: u32 = @intCast(max_cy - min_cy + 1);
    const wb = cw * CHUNK_SIZE;
    const hb = ch * CHUNK_SIZE;

    const moved_chunk = game.active_chunk[0] != game.last_active_chunk_x or game.active_chunk[1] != game.last_active_chunk_y;

    if (!game.grid_dirty and !moved_chunk and game.last_grid_min_bx == @as(u32, @bitCast(min_cx))) {
        update_props(game, wb, hb, min_cx, min_cy);
        return;
    }

    game.last_active_chunk_x = game.active_chunk[0];
    game.last_active_chunk_y = game.active_chunk[1];

    memory.scratch_reset();
    const out = memory.scratch_alloc_slice(memory.Block, wb * hb) orelse return;

    const world_limit: u64 = if (game.current_depth < CHUNK_SIZE)
        (@as(u64, 1) << @intCast(game.current_depth * std.math.log2(CHUNK_SIZE)))
    else
        std.math.maxInt(u64);

    for (0..ch) |gy| {
        for (0..cw) |gx| {
            const suffix_x = @as(i64, @bitCast(game.active_chunk[0]));
            const suffix_y = @as(i64, @bitCast(game.active_chunk[1]));

            const abs_cx = suffix_x + @as(i64, @intCast(min_cx)) + @as(i64, @intCast(gx));
            const abs_cy = suffix_y + @as(i64, @intCast(min_cy)) + @as(i64, @intCast(gy));

            // Use @bitCast to check the unsigned magnitude against the limit
            const u_abs_cx: u64 = @bitCast(abs_cx);
            const u_abs_cy: u64 = @bitCast(abs_cy);

            // BOUNDS CHECK:
            // If abs_cx < 0, u_abs_cx will be massive (wrapping), thus > world_limit.
            if (u_abs_cx < world_limit and u_abs_cy < world_limit) {
                const chunk = w.get_chunk(@intCast(abs_cx), @intCast(abs_cy));
                for (0..CHUNK_SIZE) |ly| {
                    @memcpy(out[(gy * CHUNK_SIZE + ly) * wb + gx * CHUNK_SIZE ..][0..CHUNK_SIZE], chunk.blocks[ly * CHUNK_SIZE ..][0..CHUNK_SIZE]);
                }
            } else {
                for (0..CHUNK_SIZE) |ly| {
                    const row_start = (gy * CHUNK_SIZE + ly) * wb + gx * CHUNK_SIZE;
                    @memset(out[row_start .. row_start + CHUNK_SIZE], memory.AIR_BLOCK);
                }
            }
        }
    }
    update_props(game, wb, hb, min_cx, min_cy);
}

inline fn update_props(game: *memory.GameState, wb: u32, hb: u32, min_cx: i32, min_cy: i32) void {
    memory.mem.scratch_properties[0] = @intCast(wb);
    memory.mem.scratch_properties[1] = @intCast(hb);

    const suffix_x = @as(i64, @bitCast(game.active_chunk[0]));
    const suffix_y = @as(i64, @bitCast(game.active_chunk[1]));

    const origin_x = (suffix_x +% @as(i64, min_cx)) *% memory.SUBPIXELS_IN_CHUNK;
    const origin_y = (suffix_y +% @as(i64, min_cy)) *% memory.SUBPIXELS_IN_CHUNK;

    memory.mem.scratch_properties[2] = @bitCast(origin_x);
    memory.mem.scratch_properties[3] = @bitCast(origin_y);

    // scratch_properties[4..] are f64 for smooth interpolation
    memory.mem.scratch_properties[4] = @bitCast(game.camera_pos[0]);
    memory.mem.scratch_properties[5] = @bitCast(game.camera_pos[1]);
    memory.mem.scratch_properties[6] = @bitCast(game.player_velocity[0]);
    memory.mem.scratch_properties[7] = @bitCast(game.player_velocity[1]);
    memory.mem.scratch_properties[8] = @bitCast(game.camera_scale);
}

pub fn portal_zoom_in(bx: u32, by: u32) void {
    const w = if (world_state) |*ws| ws else return;
    const game = &memory.game;

    // Identify parent block before clearing cache
    const chunk = w.get_chunk(game.active_chunk[0], game.active_chunk[1]);
    const parent_id = chunk.blocks[(by % CHUNK_SIZE) * CHUNK_SIZE + (bx % CHUNK_SIZE)].id;

    // Push world coords
    w.push_layer(@intCast(game.active_chunk[0]), @intCast(game.active_chunk[1]), parent_id);

    // The portal block (bx, by) becomes the starting chunk of the new depth.
    // bx and by are 0-15. This is the new Active Suffix.
    game.active_chunk = .{ @intCast(bx), @intCast(by) };

    // TODO player_pos rearrangement logic
    game.current_depth += 1;
    game.grid_dirty = true;
}

/// Resets the game state.
pub fn reset() void {}
