//! Contains initialization and render update functions. See root.zig for exporting these functions (and others) to WASM.
const memory = @import("memory.zig");
const std = @import("std");
const logger = @import("logger.zig");
const seeding = @import("seeding.zig");
const world = @import("world.zig");

const SPAN = memory.SPAN;
const SPAN_SQ = memory.SPAN_SQ;
const SPAN_FLOAT = memory.SPAN_FLOAT;
const SUBPIXELS_IN_CHUNK = memory.SUBPIXELS_IN_CHUNK;
const SCREEN_WIDTH = 480;
const SCREEN_HEIGHT = 270;
const SCREEN_WIDTH_HALF = SCREEN_WIDTH / 2;
const SCREEN_HEIGHT_HALF = SCREEN_HEIGHT / 2;
pub var world_state: ?world.World = null;

/// External function that makes a call to `engine.handleVisibleChunks()`.
extern "env" fn js_handle_visible_chunks() void;

/// Makes a call to `engine.handleVisibleChunks()` in JS.
pub inline fn handle_visible_chunks() void {
    if (memory.is_wasm) {
        return js_handle_visible_chunks();
    } else {
        return;
    }
}

/// Initializes the game.
pub fn init() void {
    world_state = world.World.init(memory.allocator);
    const player_pos = memory.game.player_pos;
    world.World.push_layer(
        &world_state.?,
        world.Sprite.none,
        .{ .quadrant = 0, .suffix = .{ 0, 0 } },
        @intCast(@divTrunc(player_pos[0], memory.SPAN_SQ)), // convert a subpixel (0-4095) in a chunk to a block in a chunk (0-15)
        @intCast(@divTrunc(player_pos[0], memory.SPAN_SQ)),
    );
    logger.log(@src(), "Hello from Zig!", .{});
}

/// Processes data for renderFrame in TypeScript.
pub fn prepare_visible_chunks(time_interpolated: f64, canvas_w: f64, canvas_h: f64) void {
    _ = canvas_h;
    const w = world_state.?;
    const game = &memory.game;

    // this variable allows for super smooth frame interpolation :)
    const dt = time_interpolated;

    // calculate effective zoom
    const resolution_scale = canvas_w / @as(f64, SCREEN_WIDTH);
    // since interpolated doesn't really influence logic, std.math.pow can be non-deterministic
    const interpolated_zoom = game.camera_scale * std.math.pow(f64, game.camera_scale_change, dt);
    const effective_zoom = interpolated_zoom * resolution_scale;

    // calculate the screen's half-extents in world sub-pixels (as floats to preserve zoom precision)
    const subpixels_per_pixel: f64 = @as(f64, @floatFromInt(SPAN_SQ)) / @as(f64, @floatFromInt(SPAN));
    const subpixels_per_chunk: f64 = @as(f64, @floatFromInt(SUBPIXELS_IN_CHUNK));
    const half_w_sp = (@as(f64, SCREEN_WIDTH_HALF) / interpolated_zoom) * subpixels_per_pixel;
    const half_h_sp = (@as(f64, SCREEN_HEIGHT_HALF) / interpolated_zoom) * subpixels_per_pixel;

    // calculate the interpolated camera
    const cam_vel_x = game.camera_pos[0] - game.last_camera_pos[0];
    const cam_vel_y = game.camera_pos[1] - game.last_camera_pos[1];

    const interp_cam_x = @as(f64, @floatFromInt(game.camera_pos[0])) + (@as(f64, @floatFromInt(cam_vel_x)) * dt);
    const interp_cam_y = @as(f64, @floatFromInt(game.camera_pos[1])) + (@as(f64, @floatFromInt(cam_vel_y)) * dt);

    // find the world's sub-pixel edges
    const edge_left = interp_cam_x - half_w_sp;
    const edge_top = interp_cam_y - half_h_sp;
    const edge_right = interp_cam_x + half_w_sp;
    const edge_bottom = interp_cam_y + half_h_sp;

    // find the chunk indices that end up covering the screen, with just enough buffer
    const min_cx: i32 = @intFromFloat(@floor(edge_left / subpixels_per_chunk));
    const min_cy: i32 = @intFromFloat(@floor(edge_top / subpixels_per_chunk));
    const max_cx: i32 = @as(i32, @intFromFloat(@floor(edge_right / subpixels_per_chunk))) + 1;
    const max_cy: i32 = @as(i32, @intFromFloat(@floor(edge_bottom / subpixels_per_chunk))) + 1;

    // determine the dimensions of the grid to render (cw/ch is how many chunks wide/high the current render-window is)
    const cw: u32 = @intCast(max_cx - min_cx + 1);
    const ch: u32 = @intCast(max_cy - min_cy + 1);

    // how many render tiles on each side?
    const wb = cw * SPAN;
    const hb = ch * SPAN;

    // const moved_chunk = game.player_chunk[0] != game.last_player_chunk_x or game.player_chunk[1] != game.last_player_chunk_y;
    // if (!game.grid_dirty and !moved_chunk and game.last_grid_min_bx == @as(u32, @bitCast(min_cx))) {
    //     update_render_properties(game, wb, hb, min_cx, min_cy, dt, effective_zoom);
    //     return;
    // }

    // game.last_player_chunk_x = game.player_chunk[0];
    // game.last_player_chunk_y = game.player_chunk[1];

    memory.scratch_reset();
    const out = memory.scratch_alloc_slice(memory.Block, wb * hb) orelse return;

    // TODO look at this and determine if it works properly with higher depths
    const world_limit: u64 = world.get_world_limit();

    for (0..ch) |gy| {
        for (0..cw) |gx| {
            const suffix_x = @as(i64, @bitCast(game.player_chunk[0]));
            const suffix_y = @as(i64, @bitCast(game.player_chunk[1]));

            const abs_cx = suffix_x + @as(i64, @intCast(min_cx)) + @as(i64, @intCast(gx));
            const abs_cy = suffix_y + @as(i64, @intCast(min_cy)) + @as(i64, @intCast(gy));

            // Check the unsigned magnitude against the limit
            const u_abs_cx: u64 = @bitCast(abs_cx);
            const u_abs_cy: u64 = @bitCast(abs_cy);

            // BOUNDS CHECK:
            // If abs_cx < 0, u_abs_cx will be massive (wrapping), thus > world_limit.
            if (u_abs_cx < world_limit and u_abs_cy < world_limit) {
                // TODO figure out the funny quadrant business too
                const chunk = w.get_chunk(.{ .suffix = .{ @intCast(abs_cx), @intCast(abs_cy) }, .quadrant = 0 });
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
    update_render_properties(game, interp_cam_x, interp_cam_y, wb, hb, min_cx, min_cy, dt, effective_zoom);
    handle_visible_chunks();
}

/// Sets scratch properties containing information to TypeScript for renderFrame.
inline fn update_render_properties(game: *memory.GameState, interp_cam_x: f64, interp_cam_y: f64, wb: u32, hb: u32, min_cx: i32, min_cy: i32, dt: f64, effective_zoom: f64) void {
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

    // Update scratch properties that JS reads
    memory.set_scratch_prop(0, wb);
    memory.set_scratch_prop(1, hb);
    memory.set_scratch_prop(2, cam_x_shader);
    memory.set_scratch_prop(3, cam_y_shader);
    memory.set_scratch_prop(4, effective_zoom);
    memory.set_scratch_prop(5, player_render_x);
    memory.set_scratch_prop(6, player_render_y);

    logger.clear(0);
    const qc = world_state.?.quad_cache;
    if (game.depth > 16) {
        logger.write(0, .{ "{h}Chunk X, Y, and active suffix", qc.get_quadrant_path_x(@intCast(game.player_quadrant)), qc.get_quadrant_path_y(@intCast(game.player_quadrant)), game.player_chunk });
    } else {
        logger.write(0, .{ "{h}Chunk active suffix", game.player_chunk });
    }
    logger.write(0, .{ "{h}Depth and position in chunk", game.depth, game.player_pos });
    // logger.write(0, .{ "{h}Player interpolated shader position", @Vector(2, f64){ player_render_x, player_render_y } });

    // logger.clear(1);
    // logger.write(1, .{ "{h}Keys held down and pressed this frame", game.keys_held_mask, game.keys_pressed_mask });
    // logger.write(1, .{ "{h}dt (from -1 to 0)", dt });

    // logger.clear(2);
    // logger.write(2, .{ "{h}Camera actual", game.camera_pos });
    // logger.write(2, .{ "{h}Camera interpolated shader position", @Vector(2, f64){ cam_x_shader, cam_y_shader } });
    // logger.write(2, .{ "{h}Zoom (scaled based on canvas resolution)", effective_zoom });
}

pub fn portal_zoom_in(bx: u32, by: u32) void {
    const w = world_state.?;
    const game = &memory.game;

    const chunk = w.get_chunk(game.player_chunk[0], game.player_chunk[1]);
    const parent_id = chunk.blocks[(by % SPAN) * SPAN + (bx % SPAN)].id;
    w.push_layer(game.player_chunk[0], game.player_chunk[1], parent_id);

    // TODO player_pos rearrangement logic
    game.player_chunk = .{ 0, 0 };
    game.player_pos = .{ 2048 - 128, 2048 - 128 };
    // game.grid_dirty = true;
}

/// Resets the game state.
pub fn reset() void {}
