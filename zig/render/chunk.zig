const std = @import("std");
const dw = @import("../root.zig");
const memory = dw.memory;
const logger = dw.logger;
const world = dw.world;

const HORIZON_DEPTH = dw.HORIZON_DEPTH;
const CHUNK_SIZE = dw.CHUNK_SIZE;
const CHUNK_SIZE_FLOAT = dw.CHUNK_SIZE_FLOAT;

/// Current interpolation fraction (updated within `updateVisibleChunks()` every render frame).
///
/// This value is in the range -1..0 (NOT 0..1): -1 is the start of the current logic frame, 0 is the end.
/// The world renders position at `camera_pos + cam_vel * current_dt`,
/// which (since `cam_vel = camera_pos - last_camera_pos`) equals `last_camera_pos + cam_vel * (current_dt + 1)`; interpolating from last to current.
///
/// Any other renderer must follow the SAME two curves so it stays locked to the world;
/// the split matters because position and zoom base on different reference values:
/// - Position: base on the previous-frame value (`last_camera_pos`, item's last subpixel, etc.)
///   and use the shifted fraction `current_dt + 1.0` (range 0..1).
///   Basing on the current value with the shifted fraction renders one full frame of velocity ahead of the world.
/// - Zoom: use `camera_scale * pow(camera_scale_change, current_dt)` with the RAW fraction.
///   `camera_scale` is already the current scale and `camera_scale_change = camera_scale / old_scale`,
///   so the negative exponent walks it back toward `old_scale` at -1.
///   Equivalently `old_scale * pow(change, current_dt + 1)`, but the raw form avoids recovering `old_scale`.
pub var current_dt: f64 = 0.0;

/// Grid-aligned player position in logical viewport pixels (480x270, center of the sprite), recomputed every render frame
/// The player is drawn as a render entity so this is shared with the entity pass.
pub var player_screen_pos: dw.utils.Vec2f32 = .{ 0.0, 0.0 };
/// Player sprite size (one world tile) in logical viewport pixels, matching the current zoom.
pub var player_screen_size: f32 = 16.0;

/// Seamless wrap period (in chunks) for the FBM background camera coordinate.
/// Must match `src/shader.wgsl`; noise "lattice" cycles every 32 units.
/// With base_scale = 1/64, the farthest layer moves 1/16 unit/chunk (needs factor of 512).
/// Warp coefficients (9/20, 17/20) require a factor of 20 to clear denominators.
pub const BG_WRAP_CHUNKS = 512 * 20;
comptime {
    // 512 covers the 1/16 unit/chunk base scale; 20 covers warp-coefficient denominators.
    std.debug.assert(BG_WRAP_CHUNKS % 512 == 0 and BG_WRAP_CHUNKS % 20 == 0);
}

/// Adds visible chunk data to the scratch buffer, as well as properties.
/// This is used in `render.prepareVisibleData()`.
pub fn updateVisibleChunks(dt: f64, canvas_w: f64, canvas_h: f64) void {
    current_dt = dt;
    _ = canvas_h;
    const game = &memory.game;
    // calculate effective zoom
    const resolution_scale = canvas_w / @as(f64, dw.SCREEN_WIDTH);
    // since interpolated doesn't really influence logic, std.math.pow can be non-deterministic
    // dt allows for super smooth frame interpolation
    const interpolated_zoom = game.camera_scale * std.math.pow(f64, game.camera_scale_change, dt);
    const effective_zoom = interpolated_zoom * resolution_scale;

    // calculate the screen's half-extents in world sub-pixels (as floats to preserve zoom precision)
    const subpixels_per_chunk: f64 = @floatFromInt(dw.SUBPIXELS_IN_CHUNK);
    const half_w_sp = (@as(f64, dw.SCREEN_WIDTH_HALF) / interpolated_zoom) * CHUNK_SIZE;
    const half_h_sp = (@as(f64, dw.SCREEN_HEIGHT_HALF) / interpolated_zoom) * CHUNK_SIZE;

    // calculate the interpolated camera loc.
    // NOTE: this uses the raw -1..0 `dt`, so `camera_pos + vel * dt` is correct here (it equals `last_camera_pos + vel * (dt + 1)`).
    // Renderers that use the shifted 0..1 dt must instead base on `last_camera_pos`. See the `current_dt` doc comment above.
    const cam_vel_x = game.camera_pos[0] - game.last_camera_pos[0];
    const cam_vel_y = game.camera_pos[1] - game.last_camera_pos[1];

    const interp_cam_x = @as(f64, @floatFromInt(game.camera_pos[0])) + (@as(f64, @floatFromInt(cam_vel_x)) * dt);
    const interp_cam_y = @as(f64, @floatFromInt(game.camera_pos[1])) + (@as(f64, @floatFromInt(cam_vel_y)) * dt);

    // find the world's sub-pixel edges
    const edge_left = interp_cam_x - half_w_sp;
    const edge_top = interp_cam_y - half_h_sp;
    const edge_right = interp_cam_x + half_w_sp;
    const edge_bottom = interp_cam_y + half_h_sp;

    // find the chunk indices that end up covering the screen, padded on every side by the lighting
    // margin so off-screen light sources that can bleed onscreen are present during the flood. The
    // margin is shared from `lighting` (>= 1, so it also supplies the far-edge rounding pad the old
    // hard-coded `+ 1` provided). See `lighting.CHUNK_MARGIN`.
    const margin: i32 = @intCast(dw.lighting.CHUNK_MARGIN);
    const min_cx = @as(i32, @intFromFloat(@floor(edge_left / subpixels_per_chunk))) - margin;
    const min_cy = @as(i32, @intFromFloat(@floor(edge_top / subpixels_per_chunk))) - margin;
    const max_cx = @as(i32, @intFromFloat(@floor(edge_right / subpixels_per_chunk))) + margin;
    const max_cy = @as(i32, @intFromFloat(@floor(edge_bottom / subpixels_per_chunk))) + margin;

    // determine the dimensions of the grid to render (cw/ch is how many chunks wide/high the current render-window is)
    const cw: u32 = @intCast(max_cx - min_cx + 1);
    const ch: u32 = @intCast(max_cy - min_cy + 1);

    // how many render tiles on each side?
    const wb = cw * CHUNK_SIZE;
    const hb = ch * CHUNK_SIZE;

    memory.scratchReset(); // scratch allocator always needs to be reset!
    const out = memory.scratchAllocSlice(memory.Block, wb * hb);
    const player_coord = game.getPlayerCoord();

    var chunk: memory.Chunk align(memory.MAIN_ALIGN_BYTES) = undefined;
    for (0..ch) |gy| {
        const offset_y = @as(i64, @intCast(min_cy)) + @as(i64, @intCast(gy));

        for (0..cw) |gx| {
            const offset_x = @as(i64, @intCast(min_cx)) + @as(i64, @intCast(gx));

            if (player_coord.move(.{ offset_x, offset_y })) |target_coord| {
                if (game.depth <= dw.HORIZON_DEPTH) {
                    if (target_coord.suffix[0] > world.max_possible_suffix or target_coord.suffix[1] > world.max_possible_suffix) {
                        for (0..CHUNK_SIZE) |ly| {
                            const row_start = (gy * CHUNK_SIZE + ly) * wb + gx * CHUNK_SIZE;
                            @memset(out[row_start .. row_start + CHUNK_SIZE], memory.Block.empty);
                        }
                        continue;
                    }
                }

                world.writeChunk(&chunk, target_coord);
                for (0..CHUNK_SIZE) |ly| {
                    const row_start = (gy * CHUNK_SIZE + ly) * wb + gx * CHUNK_SIZE;
                    const chunk_row_start = ly * CHUNK_SIZE;

                    // Iterate through each block in the row instead of doing a blind @memcpy
                    for (0..CHUNK_SIZE) |lx| {
                        var block = chunk.blocks[chunk_row_start + lx];

                        if (!block.isFoundation() and !block.isLiquid()) {
                            // since decor aren't foundation/liquid blocks, they don't get edge flags
                            block.edge_flags = 0xFF;
                            block.id_edge_flags = 0xFF;
                        }
                        // Sprite variation (2x2 stone, liquid surfaces, seed picks, campfire animation)
                        // is applied AFTER lighting; see `applyVariation` below. Lighting queries sprite
                        // properties by ID, so it must run on the base (unvaried) IDs first.
                        out[row_start + lx] = block;
                    }
                }
            } else {
                for (0..CHUNK_SIZE) |ly| {
                    const row_start = (gy * CHUNK_SIZE + ly) * wb + gx * CHUNK_SIZE;
                    @memset(out[row_start .. row_start + CHUNK_SIZE], memory.Block.empty);
                }
            }
        }
    }

    // Compute frame lighting using continuous, dt-interpolated player positions (in subpixels)
    // relative to the visible chunk buffer, preventing light-snapping between blocks (bad!).
    const player_vel_x = game.player_pos[0] - game.last_player_pos[0];
    const player_vel_y = game.player_pos[1] - game.last_player_pos[1];
    const player_interp_x = @as(f64, @floatFromInt(game.player_pos[0])) + @as(f64, @floatFromInt(player_vel_x)) * dt;
    const player_interp_y = @as(f64, @floatFromInt(game.player_pos[1])) + @as(f64, @floatFromInt(player_vel_y)) * dt;
    const subpixels_per_block: f64 = @floatFromInt(dw.CHUNK_SIZE_SQ);
    const player_bx: f32 = @floatCast(@as(f64, @floatFromInt(-min_cx * CHUNK_SIZE)) + player_interp_x / subpixels_per_block);
    const player_by: f32 = @floatCast(@as(f64, @floatFromInt(-min_cy * CHUNK_SIZE)) + player_interp_y / subpixels_per_block);
    dw.lighting.applyLighting(out, wb, hb, player_bx, player_by);

    applyVariation(out, wb, game.frame);

    updateRenderProperties(game, interp_cam_x, interp_cam_y, wb, hb, min_cx, min_cy, dt, effective_zoom, interpolated_zoom);
}

/// Applies sprite variation/animation to the final visible buffer, in place, just before it is sent to the GPU.
/// Runs AFTER lighting so the lighting pass sees base (unvaried) sprite IDs.
///
/// Uses grid-relative tile coordinates (`i % wb`, `i / wb`); because the grid origin is chunk-aligned (an even tile offset),
/// their parity matches absolute tile parity, so positional variants (2x2 stone, checkerboard edge stone)
/// are seamless across the world exactly as the old shader was.
inline fn applyVariation(out: []memory.Block, wb: u32, frame: u32) void {
    for (out, 0..) |*block, i| {
        block.id = dw.variation.resolveVariant(block.*, i % wb, i / wb, frame);
        // Underlay sprites (ore/gem backgrounds) get the same variation treatment, so plain stone tiles for example.
        if (block.base_id != .none) {
            block.base_id = dw.variation.resolveSpriteVariant(block.base_id, block.seed, block.edge_flags, i % wb, i / wb, frame);
        }
    }
}

/// Sets scratch properties containing information to TypeScript for renderFrame.
inline fn updateRenderProperties(
    game: *memory.GameState,
    interp_cam_x: f64,
    interp_cam_y: f64,
    wb: u32,
    hb: u32,
    min_cx: i32,
    min_cy: i32,
    dt: f64,
    effective_zoom: f64,
    interpolated_zoom: f64,
) void {
    // Calculate the camera position relative to the tile grid origin
    const grid_origin_sub_x = @as(f64, @floatFromInt(min_cx)) * @as(f64, @floatFromInt(dw.SUBPIXELS_IN_CHUNK));
    const grid_origin_sub_y = @as(f64, @floatFromInt(min_cy)) * @as(f64, @floatFromInt(dw.SUBPIXELS_IN_CHUNK));

    // Final camera position (in pixels this time, relative to the grid)
    const cam_x_shader = (interp_cam_x - grid_origin_sub_x) / CHUNK_SIZE_FLOAT;
    const cam_y_shader = (interp_cam_y - grid_origin_sub_y) / CHUNK_SIZE_FLOAT;

    // Find the player's position, interpolated with dt
    const player_vel_x = game.player_pos[0] - game.last_player_pos[0];
    const player_vel_y = game.player_pos[1] - game.last_player_pos[1];
    const player_interpolated_x = @as(f64, @floatFromInt(game.player_pos[0])) + @as(f64, @floatFromInt(player_vel_x)) * dt;
    const player_interpolated_y = @as(f64, @floatFromInt(game.player_pos[1])) + @as(f64, @floatFromInt(player_vel_y)) * dt;

    // Player render position for the ENTITY pass (logical 480x270 px, sprite center). This is the same
    // world->screen mapping the tile grid uses (1 px = CHUNK_SIZE subpixels, scaled by zoom), so the
    // player entity stays pixel-aligned with the blocks. `interpolated_zoom` is the logical (non-resolution-
    // scaled) zoom, matching how other entities are positioned.
    player_screen_pos = .{
        @floatCast(@as(f64, dw.SCREEN_WIDTH_HALF) + (player_interpolated_x - interp_cam_x) * interpolated_zoom / CHUNK_SIZE_FLOAT),
        @floatCast(@as(f64, dw.SCREEN_HEIGHT_HALF) + (player_interpolated_y - interp_cam_y) * interpolated_zoom / CHUNK_SIZE_FLOAT),
    };
    player_screen_size = @floatCast(CHUNK_SIZE_FLOAT * interpolated_zoom);

    // Position player in the middle of the screen plus their offset from the camera center
    const player_render_x = (player_interpolated_x - grid_origin_sub_x - CHUNK_SIZE_FLOAT * CHUNK_SIZE_FLOAT / 2) / CHUNK_SIZE_FLOAT;
    const player_render_y = (player_interpolated_y - grid_origin_sub_y - CHUNK_SIZE_FLOAT * CHUNK_SIZE_FLOAT / 2) / CHUNK_SIZE_FLOAT;

    // Modulo every 256 chunks to seamlessly loop water coordinates
    const player_cx_mod = @as(i64, @intCast(game.player_chunk[0] % 256));
    const player_cy_mod = @as(i64, @intCast(game.player_chunk[1] % 256));
    const abs_grid_cx = @mod(player_cx_mod + min_cx, 256);
    const abs_grid_cy = @mod(player_cy_mod + min_cy, 256);

    const abs_grid_x = @as(f64, @floatFromInt(abs_grid_cx * @as(i32, dw.CHUNK_SIZE)));
    const abs_grid_y = @as(f64, @floatFromInt(abs_grid_cy * @as(i32, dw.CHUNK_SIZE)));

    // Wrap the background's absolute camera every `BG_WRAP_CHUNKS` chunks so the FBM background loops
    // seamlessly when walking OR zooming across the boundary (see the constant's doc comment for the contract).
    const player_cx_bg_mod = @as(i64, @intCast(game.player_chunk[0] % BG_WRAP_CHUNKS));
    const player_cy_bg_mod = @as(i64, @intCast(game.player_chunk[1] % BG_WRAP_CHUNKS));
    const abs_grid_bg_cx = @mod(player_cx_bg_mod + min_cx, BG_WRAP_CHUNKS);
    const abs_grid_bg_cy = @mod(player_cy_bg_mod + min_cy, BG_WRAP_CHUNKS);

    const abs_grid_bg_x = @as(f64, @floatFromInt(abs_grid_bg_cx * @as(i32, dw.CHUNK_SIZE)));
    const abs_grid_bg_y = @as(f64, @floatFromInt(abs_grid_bg_cy * @as(i32, dw.CHUNK_SIZE)));

    const abs_cam_x = cam_x_shader + (abs_grid_bg_x * 16.0);
    const abs_cam_y = cam_y_shader + (abs_grid_bg_y * 16.0);

    // Update scratch properties that JS reads
    memory.setScratchProp(0, wb);
    memory.setScratchProp(1, hb);
    memory.setScratchProp(2, cam_x_shader);
    memory.setScratchProp(3, cam_y_shader);
    memory.setScratchProp(4, effective_zoom);
    memory.setScratchProp(5, player_render_x);
    memory.setScratchProp(6, player_render_y);
    memory.setScratchProp(7, abs_grid_x);
    memory.setScratchProp(8, abs_grid_y);
    memory.setScratchProp(9, abs_cam_x);
    memory.setScratchProp(10, abs_cam_y);

    if (dw.is_debug) {
        const qc = world.quad_cache;
        const d: u64 = @intCast(memory.game.depth);

        const log_limit = @min(d, HORIZON_DEPTH);
        var suffix_array_x: [HORIZON_DEPTH]u64 = undefined;
        var suffix_array_y: [HORIZON_DEPTH]u64 = undefined;

        for (0..log_limit) |i| {
            suffix_array_x[log_limit - 1 - i] = (game.player_chunk[0] >> @intCast(dw.ZOOM_LOG2 * i)) % dw.ZOOM_FACTOR;
            suffix_array_y[log_limit - 1 - i] = (game.player_chunk[1] >> @intCast(dw.ZOOM_LOG2 * i)) % dw.ZOOM_FACTOR;
        }

        if (game.depth > HORIZON_DEPTH) {
            logger.writeOnce(2, .{
                "{mh}Left quadrant path (compacted)",
                qc.left_path,
                "{mh}X suffix array",
                suffix_array_x,
            });
            logger.writeOnce(3, .{
                "{mh}Top quadrant path (compacted)",
                qc.top_path,
                "{mh}Y suffix array",
                suffix_array_y,
            });

            const quadrant_name = ([_][]const u8{
                "top left quadrant (0)",
                "top right quadrant (1)",
                "bottom left quadrant (2)",
                "bottom right quadrant (3)",
            })[game.player_quadrant];
            logger.writeOnce(0, .{
                "{h}Quadrant name",
                quadrant_name,
            });
        } else {
            logger.writeOnce(0, .{
                "{h}Chunk active suffix X/Y",
                suffix_array_x[0..log_limit], // Use log_limit to avoid overflow if D > 32
                suffix_array_y[0..log_limit],
            });
        }

        logger.write(0, .{
            "{h}Depth/position",
            .{ game.depth, game.player_pos },
        });

        logger.writeOnce(1, .{
            "{mh}Velocity",
            game.player_velocity,
            "{mh}Rendered entity count",
            dw.entity.entity_count,
        });

        // logger.clear(1);
        // logger.write(1, .{ "{h}Keys held down", game.keys_held_mask });

        // logger.clear(2);
        // logger.write(2, .{ "{h}Player interpolated shader position", @Vector(2, f64){ player_render_x, player_render_y } });
        // logger.write(2, .{ "{h}Camera interpolated shader position", @Vector(2, f64){ cam_x_shader, cam_y_shader } });
        // logger.write(2, .{ "{h}Camera actual location (relative to player)", game.camera_pos });
        // logger.write(2, .{ "{h}Zoom (scaled based on canvas resolution)", effective_zoom });
    }
}
