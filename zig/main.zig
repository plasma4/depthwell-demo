//! Contains important functions and imports other files. See root.zig for exporting these functions (and others) to WASM.
const memory = @import("memory.zig");
const std = @import("std");
const logger = @import("logger.zig");
const seeding = @import("seeding.zig");
const world = @import("world.zig");
const World = world.World;

const SPAN = memory.SPAN;
const SPAN_SQ = memory.SPAN_SQ;
const SPAN_FLOAT = memory.SPAN_FLOAT;
const SUBPIXELS_IN_CHUNK = memory.SUBPIXELS_IN_CHUNK;
const SCREEN_WIDTH = 480;
const SCREEN_HEIGHT = 270;
const SCREEN_WIDTH_HALF = SCREEN_WIDTH / 2;
const SCREEN_HEIGHT_HALF = SCREEN_HEIGHT / 2;
pub var world_state: ?World = null;

/// Initializes the game.
pub fn init() void {
    world_state = World.init(memory.allocator, memory.game.seed);
    logger.log(@src(), "Hello from Zig!", .{});
}

/// Processes data for renderFrame in TypeScript.
pub fn prepare_visible_chunks(time_interpolated: f64, canvas_w: f64, canvas_h: f64) void {
    _ = canvas_h;
    const w = if (world_state) |*ws| ws else return;
    const game = &memory.game;

    // this variable allows for super smooth frame interpolation :)
    const dt = time_interpolated - 1.0;

    // calculate effective zoom
    const resolution_scale = canvas_w / @as(f64, SCREEN_WIDTH);
    // since effective does not influence logic, std.math.pow can be non-deterministic
    const effective_zoom = game.camera_scale * std.math.pow(f64, game.camera_scale_change, dt) * resolution_scale;

    // now do the chunk bound logic
    // Convert the camera's world position into "Block Units" (this finds the tile where the camera is centered on!)
    const cam_bx: i32 = @intCast(@divFloor(game.camera_pos[0], SPAN_SQ));
    const cam_by: i32 = @intCast(@divFloor(game.camera_pos[1], SPAN_SQ));

    // Now, calculate half the width/height of the screen in world units. This adjusts for camera zoom!
    const half_w: i32 = @intFromFloat(@divFloor((SCREEN_WIDTH_HALF / SPAN), game.camera_scale));
    const half_h: i32 = @intFromFloat(@divFloor((SCREEN_HEIGHT_HALF / SPAN), game.camera_scale));

    // Find the chunk indices that end up covering the screen, adding a "buffer" of 1
    const min_cx: i32 = @divFloor(cam_bx - half_w, SPAN) - 1;
    const min_cy: i32 = @divFloor(cam_by - half_h, SPAN) - 1;
    const max_cx: i32 = @divFloor(cam_bx + half_w, SPAN) + 1;
    const max_cy: i32 = @divFloor(cam_by + half_h, SPAN) + 1;

    // Determine the dimensions of the grid to render (cw/ch is how many chunks wide/high the current render-window is)
    const cw: u32 = @intCast(max_cx - min_cx + 1);
    const ch: u32 = @intCast(max_cy - min_cy + 1);

    // How many render tiles on each side?
    const wb = cw * SPAN;
    const hb = ch * SPAN;

    const moved_chunk = game.active_chunk[0] != game.last_active_chunk_x or game.active_chunk[1] != game.last_active_chunk_y;
    if (!game.grid_dirty and !moved_chunk and game.last_grid_min_bx == @as(u32, @bitCast(min_cx))) {
        update_render_properties(game, wb, hb, min_cx, min_cy, dt, effective_zoom);
        return;
    }

    game.last_active_chunk_x = game.active_chunk[0];
    game.last_active_chunk_y = game.active_chunk[1];

    memory.scratch_reset();
    const out = memory.scratch_alloc_slice(memory.Block, wb * hb) orelse return;

    // TODO look at this and determine if it works properly with higher depths
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

            // Check the unsigned magnitude against the limit
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
    update_render_properties(game, wb, hb, min_cx, min_cy, dt, effective_zoom);
}

/// Sets scratch properties containing information to TypeScript for renderFrame.
inline fn update_render_properties(game: *memory.GameState, wb: u32, hb: u32, min_cx: i32, min_cy: i32, dt: f64, effective_zoom: f64) void {
    // Calculate the interpolated camera
    const cam_vel_x = game.camera_pos[0] - game.last_camera_pos[0];
    const cam_vel_y = game.camera_pos[1] - game.last_camera_pos[1];

    const interp_cam_x = @as(f64, @floatFromInt(game.camera_pos[0])) + (@as(f64, @floatFromInt(cam_vel_x)) * dt);
    const interp_cam_y = @as(f64, @floatFromInt(game.camera_pos[1])) + (@as(f64, @floatFromInt(cam_vel_y)) * dt);

    // Calculate the camera position relative to the tile grid origin
    const grid_origin_sub_x = @as(f64, @floatFromInt(min_cx)) * @as(f64, @floatFromInt(memory.SUBPIXELS_IN_CHUNK));
    const grid_origin_sub_y = @as(f64, @floatFromInt(min_cy)) * @as(f64, @floatFromInt(memory.SUBPIXELS_IN_CHUNK));

    // Final camera position (in pixels this time, relative to the grid)
    const cam_x_shader = (interp_cam_x - grid_origin_sub_x) / SPAN_FLOAT;
    const cam_y_shader = (interp_cam_y - grid_origin_sub_y) / SPAN_FLOAT;

    // Find the player's position, interpolated with dt
    const player_vel_x = game.player_pos[0] - game.last_player_pos[0];
    const player_vel_y = game.player_pos[1] - game.last_player_pos[1];
    const player_interpolated_x = @as(f64, @floatFromInt(game.player_pos[0])) + @as(f64, @floatFromInt(player_vel_x)) * dt;
    const player_interpolated_y = @as(f64, @floatFromInt(game.player_pos[1])) + @as(f64, @floatFromInt(player_vel_y)) * dt;

    // Position player in the middle of the screen plus their offset from the camera center
    const player_render_x = (player_interpolated_x - grid_origin_sub_x) / SPAN_FLOAT;
    const player_render_y = (player_interpolated_y - grid_origin_sub_y) / SPAN_FLOAT;

    // Update scratch properties that TS reads
    memory.set_scratch_prop(0, wb);
    memory.set_scratch_prop(1, hb);
    memory.set_scratch_prop(2, cam_x_shader);
    memory.set_scratch_prop(3, cam_y_shader);
    memory.set_scratch_prop(4, effective_zoom);
    memory.set_scratch_prop(5, player_render_x);
    memory.set_scratch_prop(6, player_render_y);

    logger.clear(0);
    logger.write(0, .{ "{h}Camera actual", game.camera_pos });
    logger.write(0, .{ "{h}Camera interpolated shader position", @Vector(2, f64){ cam_x_shader, cam_y_shader } });
    logger.write(0, .{ "{h}Zoom (scaled based on canvas resolution)", effective_zoom });

    logger.clear(1);
    logger.write(1, .{ "{h}dt", dt });
    logger.write(1, .{ "{h}Render tiles for each axis", @Vector(2, u32){ wb, hb } });

    logger.clear(2);
    logger.write(2, .{ "{h}Player actual position", game.player_pos });
    logger.write(2, .{ "{h}Player interpolated shader position", @Vector(2, f64){ player_render_x, player_render_y } });
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
