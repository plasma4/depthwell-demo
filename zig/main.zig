//! Contains important functions and imports other files. See root.zig for exporting these functions (and others) to WASM.
const memory = @import("memory.zig");
const std = @import("std");
const logger = @import("logger.zig");
const seeding = @import("seeding.zig");
const world = @import("world.zig");
const World = world.World;

const SPAN = memory.SPAN;
const SPAN_FLOAT = memory.SPAN_FLOAT;
const SUBPIXELS_IN_CHUNK = memory.SUBPIXELS_IN_CHUNK;
const SCREEN_WIDTH = 480;
const SCREEN_HEIGHT = 270;
const SCREEN_WIDTH_HALF = SCREEN_WIDTH / 2.0;
const SCREEN_HEIGHT_HALF = SCREEN_HEIGHT / 2.0;
pub var world_state: ?World = null;

/// Initializes the game.
pub fn init() void {
    world_state = World.init(memory.allocator, memory.game.seed);
    logger.log(@src(), "Hello from Zig!", .{});
}

pub fn prepare_visible_chunks() void {
    const w = if (world_state) |*ws| ws else return;
    const game = &memory.game;

    const cam_bx: i32 = @intFromFloat(game.camera_pos[0] / (SPAN_FLOAT * SPAN_FLOAT));
    const cam_by: i32 = @intFromFloat(game.camera_pos[1] / (SPAN_FLOAT * SPAN_FLOAT));

    const half_w: i32 = @intFromFloat((SCREEN_WIDTH_HALF / SPAN_FLOAT) / game.camera_scale);
    const half_h: i32 = @intFromFloat((SCREEN_HEIGHT_HALF / SPAN_FLOAT) / game.camera_scale);

    const min_cx: i32 = @divFloor(cam_bx - half_w, SPAN) - 1;
    const min_cy: i32 = @divFloor(cam_by - half_h, SPAN) - 1;
    const max_cx: i32 = @divFloor(cam_bx + half_w, SPAN) + 1;
    const max_cy: i32 = @divFloor(cam_by + half_h, SPAN) + 1;

    const cw: u32 = @intCast(max_cx - min_cx + 1);
    const ch: u32 = @intCast(max_cy - min_cy + 1);
    const wb = cw * SPAN;
    const hb = ch * SPAN;

    const moved_chunk = game.active_chunk[0] != game.last_active_chunk_x or game.active_chunk[1] != game.last_active_chunk_y;
    if (!game.grid_dirty and !moved_chunk and game.last_grid_min_bx == @as(u32, @bitCast(min_cx))) {
        update_render_properties(game, wb, hb, min_cx, min_cy);
        return;
    }

    game.last_active_chunk_x = game.active_chunk[0];
    game.last_active_chunk_y = game.active_chunk[1];

    memory.scratch_reset();
    const out = memory.scratch_alloc_slice(memory.Block, wb * hb) orelse return;

    const world_limit: u64 = if (game.current_depth < SPAN)
        (@as(u64, 1) << @intCast(game.current_depth * memory.SPAN_LOG2))
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
                for (0..SPAN) |ly| {
                    @memcpy(out[(gy * SPAN + ly) * wb + gx * SPAN ..][0..SPAN], chunk.blocks[ly * SPAN ..][0..SPAN]);
                }
            } else {
                for (0..SPAN) |ly| {
                    const row_start = (gy * SPAN + ly) * wb + gx * SPAN;
                    @memset(out[row_start .. row_start + SPAN], world.AIR_BLOCK);
                }
            }
        }
    }
    update_render_properties(game, wb, hb, min_cx, min_cy);
}

inline fn update_render_properties(game: *memory.GameState, wb: u32, hb: u32, min_cx: i32, min_cy: i32) void {
    memory.mem.scratch_properties[0] = @intCast(wb);
    memory.mem.scratch_properties[1] = @intCast(hb);

    const suffix_x = @as(i64, @bitCast(game.active_chunk[0]));
    const suffix_y = @as(i64, @bitCast(game.active_chunk[1]));

    // the absolute subpixel coordinate of the top-left of the visible grid
    const origin_x = (suffix_x +% @as(i64, min_cx)) *% memory.SUBPIXELS_IN_CHUNK;
    const origin_y = (suffix_y +% @as(i64, min_cy)) *% memory.SUBPIXELS_IN_CHUNK;

    memory.mem.scratch_properties[2] = @bitCast(origin_x);
    memory.mem.scratch_properties[3] = @bitCast(origin_y);

    // relative offset of player from camera center in pixels
    const screen_px_x = (@as(f64, @floatFromInt(game.player_pos[0])) - game.camera_pos[0]) / 16.0;
    const screen_px_y = (@as(f64, @floatFromInt(game.player_pos[1])) - game.camera_pos[1]) / 16.0;
    memory.mem.scratch_properties[4] = @bitCast(screen_px_x);
    memory.mem.scratch_properties[5] = @bitCast(screen_px_y);
    logger.clear(0);
    logger.write(0, .{ "{h}Camera data", screen_px_x, screen_px_y });

    // current camera "delta" (how much it moved this tick) for interpolation
    memory.mem.scratch_properties[6] = @bitCast(game.camera_pos[0] - game.last_camera_pos[0]);
    memory.mem.scratch_properties[7] = @bitCast(game.camera_pos[1] - game.last_camera_pos[1]);
}

pub fn portal_zoom_in(bx: u32, by: u32) void {
    const w = if (world_state) |*ws| ws else return;
    const game = &memory.game;

    const chunk = w.get_chunk(game.active_chunk[0], game.active_chunk[1]);
    const parent_id = chunk.blocks[(by % SPAN) * SPAN + (bx % SPAN)].id;

    // This is the source of truth. push_layer clears caches and invalidates the Quad-Cache.
    w.push_layer(game.active_chunk[0], game.active_chunk[1], parent_id);

    // Sync the UI-visible depth
    game.current_depth = @intCast(w.path.stack.items.len);

    // TODO player_pos rearrangement logic
    game.active_chunk = .{ 0, 0 };
    game.player_pos = .{ 2048, 2048 };
    game.grid_dirty = true;
}

/// Resets the game state.
pub fn reset() void {}
