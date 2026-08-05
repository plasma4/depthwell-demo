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

/// Largest tremor the warp can reach, at full intensity.
const SHAKE_MAX_OFFSET: f32 = 3.0; // internal viewport pixels
const SHAKE_MAX_ROTATION: f32 = 2.5 * std.math.pi / 180.0; // 2.5 degrees
const SHAKE_MAX_SCALE: f32 = 0.03; // plus or minus 3%

/// How quickly the warp chases a fresh random target each render frame.
/// Pure white noise strobes at high frame rates, so each frame only closes part of the gap.
const SHAKE_RESPONSE: f32 = 0.45;

/// The per-frame warp handed to both tile layers.
/// Regenerated once per render frame by `updateShake()` and reused for every pass,
/// so the layers of a portal descent shake as one image.
const Warp = struct {
    /// Screen offset in internal viewport pixels; scaled to canvas pixels when published.
    offset: [2]f32 = .{ 0.0, 0.0 },
    rotation: f32 = 0.0,
    /// Uniform scale, where 1 is untouched.
    scale: f32 = 1.0,
};
var warp: Warp = .{};

/// Random source for the warp. Purely cosmetic, so it is never saved and never touches generation.
pub var shake_seed: dw.seeding.ChaCha12 = undefined;

/// Uniform random f32 in [-1, 1).
inline fn shakeSigned() f32 {
    return shake_seed.float(f32) * 2.0 - 1.0;
}

/// Rolls a new warp for this render frame, eased toward from the last one.
/// `intensity` is 0 (still) to 1 (full random tremor).
fn updateShake(intensity: f32) void {
    if (intensity <= 0.0) {
        warp = .{};
        return;
    }

    const target: Warp = .{
        .offset = .{ shakeSigned() * SHAKE_MAX_OFFSET * intensity, shakeSigned() * SHAKE_MAX_OFFSET * intensity },
        .rotation = shakeSigned() * SHAKE_MAX_ROTATION * intensity,
        .scale = 1.0 + shakeSigned() * SHAKE_MAX_SCALE * intensity * intensity,
    };

    warp.offset[0] += (target.offset[0] - warp.offset[0]) * SHAKE_RESPONSE;
    warp.offset[1] += (target.offset[1] - warp.offset[1]) * SHAKE_RESPONSE;
    warp.rotation += (target.rotation - warp.rotation) * SHAKE_RESPONSE;
    warp.scale += (target.scale - warp.scale) * SHAKE_RESPONSE;
}

/// Seamless wrap period (in chunks) for the FBM background camera coordinate.
/// Must match `src/shader.wgsl`; noise "lattice" cycles every 32 units.
/// With base_scale = 1/64, the farthest layer moves 1/16 unit/chunk (needs factor of 512).
/// Warp coefficients (9/20, 17/20) require a factor of 20 to clear denominators.
pub const BG_WRAP_CHUNKS = 512 * 20;
comptime {
    // 512 covers the 1/16 unit/chunk base scale; 20 covers warp-coefficient denominators.
    std.debug.assert(BG_WRAP_CHUNKS % 512 == 0 and BG_WRAP_CHUNKS % 20 == 0);
}

/// One layer of the world to rasterize into the scratch buffer for a single tile draw call.
///
/// Ordinarily there is just the one (the live world at the current depth), but a portal descent draws a second:
/// the D+1 preview, overlaid on D and faded in. Everything that differs between the two lives here,
/// so both go through the exact same rasterizer and can never drift apart.
pub const LayerPass = struct {
    /// Where blocks come from.
    pub const Source = enum {
        /// The live world at the game's current depth.
        live,
        /// The portal descent's generated D+1 buffer (see `state/portal.zig`).
        preview,
    };

    /// Chunk the visible window is measured out from (this layer's "player" chunk).
    origin: world.Coordinate,
    /// Depth this layer's coordinates live at.
    depth: u64,
    /// Largest suffix valid at `depth`; past it lies the world edge.
    max_suffix: u64,
    /// Camera position in subpixels, relative to `origin`'s chunk.
    cam: [2]f64,
    /// Player position in subpixels, relative to `origin`'s chunk. Drives lighting.
    player: [2]f64,
    /// Logical zoom for this layer, portal zoom multiplier already folded in.
    zoom: f64,
    source: Source,
};

/// Builds the pass for the live world at the current depth, interpolated for this render frame.
fn liveLayer(dt: f64) LayerPass {
    const game = &memory.game;
    // since interpolated doesn't really influence logic, std.math.pow can be non-deterministic
    // dt allows for super smooth frame interpolation
    const interpolated_zoom = game.camera_scale * std.math.pow(f64, game.camera_scale_change, dt);

    // NOTE: this uses the raw -1..0 `dt`, so `camera_pos + vel * dt` is correct here (it equals `last_camera_pos + vel * (dt + 1)`).
    // Renderers that use the shifted 0..1 dt must instead base on `last_camera_pos`. See the `current_dt` doc comment above.
    const cam_vel_x = game.camera_pos[0] - game.last_camera_pos[0];
    const cam_vel_y = game.camera_pos[1] - game.last_camera_pos[1];
    const player_vel_x = game.player_pos[0] - game.last_player_pos[0];
    const player_vel_y = game.player_pos[1] - game.last_player_pos[1];

    // A zoom transition draws the camera and player onto the portal without ever writing their real positions
    // (see portal.cameraOverride()), so the override replaces the interpolation rather than adding to it.
    // A return fade has no such motion and keeps the ordinary interpolation.
    const descending = dw.portal.hasMotionOverride();

    return .{
        .origin = game.getPlayerCoord(),
        .depth = game.depth,
        .max_suffix = world.max_possible_suffix,
        .cam = if (descending) dw.portal.cameraOverride() else .{
            @as(f64, @floatFromInt(game.camera_pos[0])) + (@as(f64, @floatFromInt(cam_vel_x)) * dt),
            @as(f64, @floatFromInt(game.camera_pos[1])) + (@as(f64, @floatFromInt(cam_vel_y)) * dt),
        },
        .player = if (descending) dw.portal.playerOverride() else .{
            @as(f64, @floatFromInt(game.player_pos[0])) + @as(f64, @floatFromInt(player_vel_x)) * dt,
            @as(f64, @floatFromInt(game.player_pos[1])) + @as(f64, @floatFromInt(player_vel_y)) * dt,
        },
        // A descent zooms the whole world in without touching camera_scale,
        // so the committed view (D+1 chunks) is still there to fall back to the moment it ends.
        .zoom = interpolated_zoom * dw.portal.zoomFactor(),
        .source = .live,
    };
}

/// Builds the pass for the transition's preview layer (the depth being entered).
///
/// Drawn at `portal.overlayScale()` of `camera_scale`, which cancels the live layer's zoom on the last
/// frame so the preview lands exactly on the committed view (D+1 chunks).
/// The world is frozen for the whole transition, so nothing here needs interpolating.
fn overlayLayer() LayerPass {
    const t = dw.portal.overlayTransition();
    const cam_x: f64 = @floatFromInt(t.new_pos[0]);
    const cam_y: f64 = @floatFromInt(t.new_pos[1]);

    return .{
        .origin = .{ .suffix = t.player_chunk, .quadrant = t.player_quadrant },
        .depth = t.depth,
        .max_suffix = t.max_possible_suffix,
        .cam = .{ cam_x, cam_y },
        .player = .{ cam_x, cam_y },
        .zoom = memory.game.camera_scale * dw.portal.overlayScale(),
        .source = .preview,
    };
}

/// Adds visible chunk data for the live world to the scratch buffer, as well as properties.
/// This is used in `render.prepareVisibleData()`.
pub fn updateVisibleChunks(dt: f64, canvas_w: f64, canvas_h: f64) void {
    current_dt = dt;
    // rolled once per render frame, before either pass, so both layers are handed the same warp!
    updateShake(dw.portal.shakeIntensity());
    rasterizeLayer(liveLayer(dt), canvas_w, canvas_h);
}

/// Adds the portal descent's D+1 preview to the scratch buffer, ready for a second tile draw call.
/// Asserts that a zoom transition is running (`portal.isZooming()`).
pub fn updateOverlayChunks(canvas_w: f64, canvas_h: f64) void {
    std.debug.assert(dw.portal.isZooming());
    rasterizeLayer(overlayLayer(), canvas_w, canvas_h);
}

/// Rasterizes one layer into the scratch buffer and publishes its render properties.
fn rasterizeLayer(pass: LayerPass, canvas_w: f64, canvas_h: f64) void {
    _ = canvas_h;
    const game = &memory.game;
    // calculate effective zoom
    const resolution_scale = canvas_w / @as(f64, dw.SCREEN_WIDTH);
    const interpolated_zoom = pass.zoom;
    const effective_zoom = interpolated_zoom * resolution_scale;

    // calculate the screen's half-extents in world sub-pixels (as floats to preserve zoom precision)
    const subpixels_per_chunk: f64 = @floatFromInt(dw.SUBPIXELS_IN_CHUNK);
    const half_w_sp = (@as(f64, dw.SCREEN_WIDTH_HALF) / interpolated_zoom) * CHUNK_SIZE;
    const half_h_sp = (@as(f64, dw.SCREEN_HEIGHT_HALF) / interpolated_zoom) * CHUNK_SIZE;

    const interp_cam_x = pass.cam[0];
    const interp_cam_y = pass.cam[1];

    // find the world's sub-pixel edges
    const edge_left = interp_cam_x - half_w_sp;
    const edge_top = interp_cam_y - half_h_sp;
    const edge_right = interp_cam_x + half_w_sp;
    const edge_bottom = interp_cam_y + half_h_sp;

    // find the chunk indices that end up covering the screen, padded on every side by the lighting
    // margin so off-screen light sources that can bleed onscreen are present during the flood.
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
    const player_coord = pass.origin;

    for (0..ch) |gy| {
        const offset_y = @as(i64, @intCast(min_cy)) + @as(i64, @intCast(gy));

        for (0..cw) |gx| {
            const offset_x = @as(i64, @intCast(min_cx)) + @as(i64, @intCast(gx));

            if (player_coord.moveAtDepth(.{ offset_x, offset_y }, pass.depth)) |target_coord| {
                if (pass.depth <= dw.HORIZON_DEPTH) {
                    if (target_coord.suffix[0] > pass.max_suffix or target_coord.suffix[1] > pass.max_suffix) {
                        for (0..CHUNK_SIZE) |ly| {
                            const row_start = (gy * CHUNK_SIZE + ly) * wb + gx * CHUNK_SIZE;
                            @memset(out[row_start .. row_start + CHUNK_SIZE], memory.Block.empty);
                        }
                        continue;
                    }
                }

                // read in-place
                const chunk: *const memory.Chunk = switch (pass.source) {
                    .live => world.getChunkPtr(target_coord),
                    // A preview slot that has not been generated yet reads as empty space. That can only
                    // happen while the overlay is still fully transparent, so it is never visible.
                    .preview => dw.portal.previewChunk(target_coord) orelse {
                        for (0..CHUNK_SIZE) |ly| {
                            const row_start = (gy * CHUNK_SIZE + ly) * wb + gx * CHUNK_SIZE;
                            @memset(out[row_start .. row_start + CHUNK_SIZE], memory.Block.empty);
                        }
                        continue;
                    },
                };

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
                        // sprite variation (2x2 stone, liquid surfaces, seed picks, campfire animation)
                        // is applied AFTER lighting; see applyVariation() below.
                        // Lighting queries sprite properties by ID, so it must run on the base (unvaried) IDs first.
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

    // compute frame lighting using continuous, dt-interpolated player positions (in subpixels)
    // all relative to the visible chunk buffer, preventing light-snapping between blocks (bad!)
    const subpixels_per_block: f64 = @floatFromInt(dw.CHUNK_SIZE_SQ);
    const player_bx: f32 = @floatCast(@as(f64, @floatFromInt(-min_cx * CHUNK_SIZE)) + pass.player[0] / subpixels_per_block);
    const player_by: f32 = @floatCast(@as(f64, @floatFromInt(-min_cy * CHUNK_SIZE)) + pass.player[1] / subpixels_per_block);
    dw.lighting.applyLighting(out, wb, hb, player_bx, player_by);

    applyVariation(out, wb, game.frame);
    updateRenderProperties(pass, interp_cam_x, interp_cam_y, wb, hb, min_cx, min_cy, effective_zoom, interpolated_zoom);
}

/// Applies sprite variation/animation to the final visible buffer, in place, just before it is sent to the GPU.
/// Runs AFTER lighting so the lighting pass sees base (unvaried) sprite IDs.
///
/// Uses grid-relative tile coordinates (`i % wb`, `i / wb`); because the grid origin is chunk-aligned (an even tile offset),
/// their parity matches absolute tile parity, so positional variants (2x2 stone, checkerboard edge stone)
/// are seamless across the world exactly as the old shader was.
fn applyVariation(out: []memory.Block, wb: u32, frame: u32) void {
    // Walked row by row rather than by flat index: the tile coordinates are the only thing the index was ever for,
    // and recovering them per block costs a divide and a modulo on every cell of the screen.
    var row_start: usize = 0;
    var ty: usize = 0;
    while (row_start < out.len) : ({
        row_start += wb;
        ty += 1;
    }) {
        for (out[row_start..][0..wb], 0..) |*block, tx| {
            block.id = dw.variation.resolveVariant(block.*, tx, ty, frame);
            // Underlay sprites (ore/gem backgrounds) get the same variation treatment, so plain stone tiles for example.
            if (block.base_id != .none) {
                block.base_id = dw.variation.resolveSpriteVariant(
                    block.base_id,
                    block.seed,
                    block.edge_flags,
                    tx,
                    ty,
                    frame,
                );
            }
        }
    }
}

/// Sets scratch properties containing information to TypeScript for renderFrame.
fn updateRenderProperties(
    pass: LayerPass,
    interp_cam_x: f64,
    interp_cam_y: f64,
    wb: u32,
    hb: u32,
    min_cx: i32,
    min_cy: i32,
    effective_zoom: f64,
    interpolated_zoom: f64,
) void {
    // Calculate the camera position relative to the tile grid origin
    const grid_origin_sub_x = @as(f64, @floatFromInt(min_cx)) * @as(f64, @floatFromInt(dw.SUBPIXELS_IN_CHUNK));
    const grid_origin_sub_y = @as(f64, @floatFromInt(min_cy)) * @as(f64, @floatFromInt(dw.SUBPIXELS_IN_CHUNK));

    // Final camera position (in pixels this time, relative to the grid)
    const cam_x_shader = (interp_cam_x - grid_origin_sub_x) / CHUNK_SIZE_FLOAT;
    const cam_y_shader = (interp_cam_y - grid_origin_sub_y) / CHUNK_SIZE_FLOAT;

    const player_interpolated_x = pass.player[0];
    const player_interpolated_y = pass.player[1];

    // Player render position for the ENTITY pass (logical 480x270 px, sprite center).
    // This is the same world->screen mapping the tile grid uses (1 px = CHUNK_SIZE subpixels, scaled by zoom),
    // so the player entity stays pixel-aligned with the blocks. interpolated_zoom is the logical(non-resolution-scaled) zoom
    // (matching how other entities are positioned),
    //
    // The overlay pass leaves these alone: the live pass already placed the player,
    // and letting the D+1 layer restate them would move the sprite mid-descent.
    if (pass.source == .live) {
        player_screen_pos = .{
            @floatCast(@as(f64, dw.SCREEN_WIDTH_HALF) + (player_interpolated_x - interp_cam_x) * interpolated_zoom / CHUNK_SIZE_FLOAT),
            @floatCast(@as(f64, dw.SCREEN_HEIGHT_HALF) + (player_interpolated_y - interp_cam_y) * interpolated_zoom / CHUNK_SIZE_FLOAT),
        };
        // A descent zooms the world in by exactly the factor that the next depth shrinks the player by,
        // so the two cancel: holding the sprite at the committed scale keeps it from popping at either
        // end. It shrinks further only as the portal swallows it.
        player_screen_size = @floatCast(CHUNK_SIZE_FLOAT * if (dw.portal.hasMotionOverride())
            memory.game.camera_scale * dw.portal.playerScale()
        else
            interpolated_zoom);
    }

    // Position player in the middle of the screen plus their offset from the camera center
    const player_render_x = (player_interpolated_x - grid_origin_sub_x - CHUNK_SIZE_FLOAT * CHUNK_SIZE_FLOAT / 2) / CHUNK_SIZE_FLOAT;
    const player_render_y = (player_interpolated_y - grid_origin_sub_y - CHUNK_SIZE_FLOAT * CHUNK_SIZE_FLOAT / 2) / CHUNK_SIZE_FLOAT;

    // Modulo every 256 chunks to seamlessly loop water coordinates
    const player_cx_mod = @as(i64, @intCast(pass.origin.suffix[0] % 256));
    const player_cy_mod = @as(i64, @intCast(pass.origin.suffix[1] % 256));
    const abs_grid_cx = @mod(player_cx_mod + min_cx, 256);
    const abs_grid_cy = @mod(player_cy_mod + min_cy, 256);

    const abs_grid_x = @as(f64, @floatFromInt(abs_grid_cx * @as(i32, dw.CHUNK_SIZE)));
    const abs_grid_y = @as(f64, @floatFromInt(abs_grid_cy * @as(i32, dw.CHUNK_SIZE)));

    // Wrap the background's absolute camera every BG_WRAP_CHUNKS chunks so the FBM background loops
    // seamlessly when walking OR zooming across the boundary (see the constant's doc comment for the contract).
    const player_cx_bg_mod = @as(i64, @intCast(pass.origin.suffix[0] % BG_WRAP_CHUNKS));
    const player_cy_bg_mod = @as(i64, @intCast(pass.origin.suffix[1] % BG_WRAP_CHUNKS));
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
    // The background's animation clock. Owned by the simulation rather than the host's wall clock so a
    // portal descent can ease it to a standstill (and so a save captures exactly where it stopped).
    memory.setScratchProp(11, memory.game.bg_time);

    // Per-frame warp of this layer. The offset is authored in internal viewport pixels, so it is scaled
    // into canvas pixels here to match screen_pos in the shader (which is already resolution-scaled).
    const resolution_scale = effective_zoom / interpolated_zoom;
    memory.setScratchProp(12, @as(f64, warp.offset[0]) * resolution_scale);
    memory.setScratchProp(13, @as(f64, warp.offset[1]) * resolution_scale);
    memory.setScratchProp(14, warp.rotation);
    memory.setScratchProp(15, warp.scale);

    // Live pass only. A portal descent rasterizes a second (D+1) layer, and reporting from both would
    // run every format and jsWriteText() twice a frame, which is expensive precisely when the debug
    // panel is on screen (each write dirties a visible element and forces a reflow).
    // It would also be wrong: the overlay would overwrite the readout with the preview's depth.
    if (dw.dev_menu and pass.source == .live) {
        const game = &memory.game;
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
            // we're past D=32, log more detailed info, including quadrant info
            // when D<32 this still would all be boring/default anyway
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
