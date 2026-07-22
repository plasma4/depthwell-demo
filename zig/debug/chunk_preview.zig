const std = @import("std");
const dw = @import("../root.zig");
const memory = dw.memory;
const Entity = memory.Entity;

const CHUNK_SIZE = dw.CHUNK_SIZE;
const MAX_HP = memory.Block.MAX_HP;
const Vec2f32 = dw.utils.Vec2f32;
const EdgeFlags = dw.types.EdgeFlags;
const addEntity = dw.entity.addEntity;

/// Draws previews for the chunk based on the `entity.preview_tile_size` variable.
/// Only called if `dw.is_debug` is true.
pub fn drawChunkPreview() void {
    // draw a rectangle background for preview, and then the chunk inside!
    const tile_size: f32 = @floatCast(dw.entity.preview_tile_size);
    const preview_x_origin: f32 = 30.0;
    const preview_y_origin: f32 = 50.0;
    const background_margin: f32 = 1.0;

    const player_coord = memory.game.getPlayerCoord();
    const chunk = dw.world.getChunk(player_coord);
    const depth = memory.game.depth;

    var bg: Entity = .{
        .sprite = .particle,
        .position = .{
            preview_x_origin + tile_size * CHUNK_SIZE / 2 - tile_size / 2,
            preview_y_origin + tile_size * CHUNK_SIZE / 2 - tile_size / 2,
        },
        .size = tile_size * (background_margin + CHUNK_SIZE + 2.0),
        .lcha = .{ 0.84, 0.35, 3.0, 0.6 }, // green!
    };
    addEntity(bg);

    bg.size *= 1.01; // a tad larger! this second entity acts as the border visually
    // dark green if this chunk was NOT modified, dark blue if WAS modified
    bg.lcha = if (dw.world.mod_store.contains(player_coord.asDepthCoordinate(depth)))
        .{ 0.32, 0.35, 4.0, 0.4 }
    else
        .{ 0.32, 0.35, 3.0, 0.4 };
    addEntity(bg);

    // for D-1/D-2 preview: reset to purple
    bg.lcha = .{ 0.32, 0.35, 5.0, 0.7 };

    // Fetch neighbor chunks for border flag visualization
    const neighbors = blk: {
        var n: [8]?dw.memory.Chunk = @splat(null);
        const offsets = [8]dw.utils.Vec2i{
            .{ 0, -1 }, .{ 0, 1 }, .{ -1, 0 }, .{ 1, 0 }, // N, S, W, E
            .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 }, // NW, NE, SW, SE
        };
        for (offsets, 0..) |off, i| {
            if (player_coord.moveAtDepth(off, depth)) |nc| {
                n[i] = dw.world.getChunk(nc);
            }
        }
        break :blk n;
    };

    const thick = tile_size * 0.08;
    const line_len = tile_size;
    const diag_size = tile_size * 0.2;
    const half = tile_size * 0.5;

    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            const block = chunk.getBlock(@intCast(x), @intCast(y));
            const block_pos: Vec2f32 = .{
                preview_x_origin + @as(f32, @floatFromInt(x)) * tile_size,
                preview_y_origin + @as(f32, @floatFromInt(y)) * tile_size,
            };

            // Draw base block
            if (block.isHeatmap()) {
                addEntity(.{
                    .sprite = .rectangle,
                    .position = block_pos,
                    .size = tile_size,
                    .lcha = .{
                        (@as(f32, @intFromEnum(block.id)) - 65000.0) / 256.0,
                        0.0,
                        0.0,
                        1.0,
                    },
                });
            } else {
                addEntity(.{
                    .sprite = block.id,
                    .position = block_pos,
                    .size = tile_size,
                });
            }

            if (block.isFoundation()) {
                const edge_flags = block.edge_flags;

                // first handle non-diagonal directions
                for ([4]u8{ 1, 6, 3, 4 }) |bit| {
                    if ((edge_flags & (@as(u8, 1) << @intCast(bit))) == 0) {
                        var ent: Entity = .{ .sprite = .rectangle, .position = block_pos };
                        switch (bit) {
                            1 => { // N
                                ent.position[1] -= half - thick * 0.5;
                                ent.size = line_len;
                                ent.lcha = .{ 0.8, 0.35, 0.4, 1.0 };
                                addLine(ent, line_len, thick);
                            },
                            6 => { // S
                                ent.position[1] += half - thick * 0.5;
                                ent.lcha = .{ 0.8, 0.35, 4.2, 1.0 };
                                addLine(ent, line_len, thick);
                            },
                            3 => { // W
                                ent.position[0] -= half - thick * 0.5;
                                ent.lcha = .{ 0.8, 0.35, 0.4, 1.0 };
                                addLine(ent, thick, line_len);
                            },
                            4 => { // E
                                ent.position[0] += half - thick * 0.5;
                                ent.lcha = .{ 0.8, 0.35, 4.2, 1.0 };
                                addLine(ent, thick, line_len);
                            },
                            else => unreachable,
                        }
                    }
                }

                // process diagonals!
                for ([4]u8{ 0, 2, 5, 7 }) |bit| {
                    if ((edge_flags & (@as(u8, 1) << @intCast(bit))) == 0) {
                        const dx = if (bit == 0 or bit == 5) -half + diag_size * 0.5 else half - diag_size * 0.5;
                        const dy = if (bit == 0 or bit == 2) -half + diag_size * 0.5 else half - diag_size * 0.5;
                        const c_idx =
                            if (bit == 0) @as(usize, 0) else if (bit == 2) @as(usize, 1) else if (bit == 5) @as(usize, 2) else @as(usize, 3);
                        addEntity(.{
                            .sprite = .rectangle,
                            .position = block_pos + Vec2f32{ dx, dy },
                            .size = diag_size,
                            // different purples/pinks
                            .lcha = .{
                                0.4 + 0.2 * @as(f32, @floatFromInt(c_idx)),
                                0.3,
                                5.4,
                                1.0,
                            },
                        });
                    }
                }
            }

            // neighbor boundary flag injection (visualize flags pointing INTO the chunk)
            if (x == 0) if (neighbors[2]) |n| drawNeighborFlag(
                &dw.entity.entity_count,
                n.getBlock(15, @intCast(y)),
                block_pos,
                .W,
                tile_size,
                thick,
            );
            if (x == MAX_HP) if (neighbors[3]) |n| drawNeighborFlag(
                &dw.entity.entity_count,
                n.getBlock(0, @intCast(y)),
                block_pos,
                .E,
                tile_size,
                thick,
            );
            if (y == 0) if (neighbors[0]) |n| drawNeighborFlag(
                &dw.entity.entity_count,
                n.getBlock(@intCast(x), MAX_HP),
                block_pos,
                .N,
                tile_size,
                thick,
            );
            if (y == MAX_HP) if (neighbors[1]) |n| drawNeighborFlag(
                &dw.entity.entity_count,
                n.getBlock(@intCast(x), 0),
                block_pos,
                .S,
                tile_size,
                thick,
            );
        }
    }

    // Draw D-1 and D-2 previews to the right of the main chunk
    const start_zoom = dw.startup.STARTING_ZOOM_TIMES;
    const bx_idx = memory.game.getBlockXInChunk();
    const by_idx = memory.game.getBlockYInChunk();
    const deeper_preview_x = preview_x_origin + background_margin + 18.5 * tile_size;
    if (dw.isDebug() and !dw.procedural.USE_BASE_HEATMAP and !dw.procedural.USE_ORE_HEATMAP and depth > start_zoom) {
        // Draw background for D-1 (teal background)
        bg.position[0] = deeper_preview_x + tile_size * 2.5;
        bg.position[1] = preview_y_origin + tile_size * 2.5;
        bg.size = tile_size * (6.0 + background_margin);
        bg.sprite = .rectangle;
        bg.lcha = .{ 0.84, 0.35, 3.5, 0.6 };
        addEntity(bg);

        // Draw border for D-1 (teal border; bluer hue if modified)
        var border_bg = bg;
        border_bg.size *= 1.02;
        const key_d1 = player_coord.asDepthCoordinate(depth).getParent();
        border_bg.lcha = if (dw.world.mod_store.contains(key_d1))
            .{ 0.32, 0.35, 4.0, 0.4 } // dark blue if WAS modified
        else
            .{ 0.32, 0.35, 3.2, 0.4 }; // dark teal if NOT modified
        addEntity(border_bg);

        const neighborhood_d1 = dw.ancestor.getAncestorNeighborhood(player_coord.asDepthCoordinate(depth));

        for (0..6) |py| {
            for (0..6) |px| {
                addEntity(.{
                    .sprite = neighborhood_d1[py][px].id,
                    .position = .{
                        deeper_preview_x + @as(f32, @floatFromInt(px)) * tile_size,
                        preview_y_origin + @as(f32, @floatFromInt(py)) * tile_size,
                    },
                    .size = tile_size,
                    .lcha = if (px == 0 or px == 5 or py == 0 or py == 5)
                        .{ 0.6, 0.0, 0.0, 1.0 }
                    else
                        memory.DEFAULT_ENTITY_LCHA,
                });
            }
        }

        // Render approximate player indicator in D-1
        const p_sub_x = @as(f32, @floatFromInt(bx_idx % 4)) / 4.0;
        const p_sub_y = @as(f32, @floatFromInt(by_idx % 4)) / 4.0;
        const player_entity: Entity = .{
            .sprite = .player,
            .position = .{
                deeper_preview_x + (1.0 + @as(f32, @floatFromInt(bx_idx / 4)) + p_sub_x - 0.5) * tile_size,
                preview_y_origin + (1.0 + @as(f32, @floatFromInt(by_idx / 4)) + p_sub_y - 0.5) * tile_size,
            },
            .size = tile_size * 0.8,
            .lcha = .{ 1.0, 0.1, -0.2, 1.0 },
        };
        var player_entity_bg = player_entity;

        // make a sort of larger border/shadow
        player_entity_bg.lcha[0] *= 0.6;
        player_entity_bg.position -= .{ tile_size / 8.0, tile_size / 8.0 };
        addEntity(player_entity_bg);
        addEntity(player_entity);

        if (depth > start_zoom + 1) {
            const p_info = dw.ancestor.getParentInfo(
                player_coord.asDepthCoordinate(depth),
                bx_idx,
                by_idx,
            );
            const preview_y_d2 = preview_y_origin + 7.5 * tile_size;
            const gp_info = dw.ancestor.getParentInfo(
                p_info.coord.asDepthCoordinate(depth - 1),
                p_info.bx,
                p_info.by,
            );

            // Draw background for D-2 (teal background)
            bg.position = .{ deeper_preview_x + tile_size * 1.0, preview_y_d2 + tile_size * 1.0 };
            bg.size = tile_size * (3.0 + background_margin);
            bg.lcha = .{ 0.84, 0.35, 3.5, 0.6 };
            addEntity(bg);

            // Draw border for D-2 (teal border; more blue if modified)
            border_bg = bg;
            border_bg.size *= 1.02;
            const key_d2 = key_d1.getParent();
            border_bg.lcha = if (dw.world.mod_store.contains(key_d2))
                .{ 0.32, 0.35, 4.0, 0.4 } // dark blue if WAS modified
            else
                .{ 0.32, 0.35, 3.2, 0.4 }; // dark teal if NOT modified
            addEntity(border_bg);

            var gpy: i32 = -1;
            while (gpy <= 1) : (gpy += 1) {
                var gpx: i32 = -1;
                while (gpx <= 1) : (gpx += 1) {
                    const target_bx = @as(i32, gp_info.bx) + gpx;
                    const target_by = @as(i32, gp_info.by) + gpy;

                    const target_nc = gp_info.coord.moveAtDepth(
                        .{ @divFloor(target_bx, 16), @divFloor(target_by, 16) },
                        depth - 2,
                    ) orelse continue;

                    // truncate it to prevent crashes!
                    const lx: u4 = @truncate(@as(u32, @bitCast(target_bx)));
                    const ly: u4 = @truncate(@as(u32, @bitCast(target_by)));

                    addEntity(.{
                        .sprite = dw.world.getBlockAt(target_nc, lx, ly, depth - 2).id,
                        .position = .{
                            deeper_preview_x + @as(f32, @floatFromInt(gpx + 1)) * tile_size,
                            preview_y_d2 + @as(f32, @floatFromInt(gpy + 1)) * tile_size,
                        },
                        .size = tile_size,
                        .lcha = if (gpx == 0 and gpy == 0) memory.DEFAULT_ENTITY_LCHA else .{ 0.7, 0.0, 0.0, 1.0 },
                    });
                }
            }

            // player indicator (poor guy is stuck in-place, since that's the current chunk)
            addEntity(.{
                .sprite = .player,
                .position = .{ deeper_preview_x + 1.0 * tile_size, preview_y_d2 + 1.0 * tile_size },
                .size = tile_size * 0.8,
                .lcha = .{ 1.0, 0.1, 0.0, 0.7 },
            });
        }
    }

    if (depth >= dw.HORIZON_DEPTH + start_zoom) {
        const preview_y_ancestor = preview_y_origin + 12.0 * tile_size; // Put it below D-2

        bg.position = .{ deeper_preview_x + tile_size * 1.5, preview_y_ancestor + tile_size * 1.5 };
        bg.size = tile_size * (4.0 + background_margin);
        bg.lcha = .{ 0.8, 0.2, 0.4, 1.0 };
        addEntity(bg);

        // The window is much wider than this now; show the active quadrants and their immediate ring.
        const first = dw.world.QuadCache.ANCESTOR_CENTER - 1;
        for (0..4) |y| {
            for (0..4) |x| {
                addEntity(.{
                    .sprite = dw.world.quad_cache.ancestor_materials[first + y][first + x].id,
                    .position = .{
                        deeper_preview_x + @as(f32, @floatFromInt(x)) * tile_size,
                        preview_y_ancestor + @as(f32, @floatFromInt(y)) * tile_size,
                    },
                    .size = tile_size,
                });
            }
        }

        // Render approximate player indicator in the active quadrant
        const qx = memory.game.player_quadrant % 2;
        const qy = memory.game.player_quadrant / 2;
        addEntity(.{
            .sprite = .player,
            .position = .{
                deeper_preview_x + @as(f32, @floatFromInt(qx + 1)) * tile_size,
                preview_y_ancestor + @as(f32, @floatFromInt(qy + 1)) * tile_size,
            },
            .size = tile_size * 0.8,
            .lcha = .{ 1.0, 0.1, 0.0, 0.7 },
        });
    }

    // render the player now!
    const center_offset: dw.utils.Vec2i = @splat(dw.CHUNK_SIZE_SQ / 2);
    const relative_pos = memory.game.player_pos - center_offset;

    const scale = tile_size / dw.CHUNK_SIZE_SQ;
    const origin: Vec2f32 = .{ preview_x_origin, preview_y_origin };

    const player_entity: Entity = .{
        .sprite = .player,
        .position = origin + @as(Vec2f32, @floatFromInt(relative_pos)) * @as(Vec2f32, @splat(scale)),
        .size = tile_size,
    };
    var player_entity_bg = player_entity;

    player_entity_bg.position -= .{ tile_size / 8.0, tile_size / 8.0 };
    player_entity_bg.lcha = .{ 0.5, 0.0, 0.0, 0.8 };
    addEntity(player_entity_bg);
    addEntity(player_entity);
}

/// Draws a line.
fn addLine(entity: Entity, w: f32, h: f32) void {
    dw.entity.addRawEntity(.{
        .lcha = entity.lcha,
        .position = entity.position / Vec2f32{ dw.SCREEN_WIDTH, dw.SCREEN_HEIGHT },
        .size = .{ w / dw.SCREEN_WIDTH, h / dw.SCREEN_HEIGHT },
        .rotation = entity.rotation,
        .id = @intFromEnum(entity.sprite),
    });
}

fn drawNeighborFlag(ec: *u64, neighbor_block: dw.memory.Block, pos: Vec2f32, side: enum { N, S, E, W }, pts: f32, thick: f32) void {
    if (!neighbor_block.isFoundation()) return;
    const half = pts * 0.5;
    // check the flag of the neighbor that points TOWARDS our chunk
    const target_bit: u8 = switch (side) {
        .N => EdgeFlags.BOTTOM, // Neighbor's South flag
        .S => EdgeFlags.TOP, // Neighbor's North flag
        .W => EdgeFlags.RIGHT, // Neighbor's East flag
        .E => EdgeFlags.LEFT, // Neighbor's West flag
    };
    if ((neighbor_block.edge_flags & target_bit) == 0) {
        ec.* += 1;
        const wgsl = memory.scratchPushEntity();
        var f_pos = pos;
        var size: Vec2f32 = undefined;
        switch (side) {
            .N => {
                f_pos[1] -= half + thick * 0.5;
                size = .{ pts, thick };
            },
            .S => {
                f_pos[1] += half + thick * 0.5;
                size = .{ pts, thick };
            },
            .W => {
                f_pos[0] -= half + thick * 0.5;
                size = .{ thick, pts };
            },
            .E => {
                f_pos[0] += half + thick * 0.5;
                size = .{ thick, pts };
            },
        }
        wgsl.* = .{
            .lcha = .{ 1.0, 0.0, 0.0, 1.0 }, // Bright white/red for neighbor alerts
            .position = f_pos / Vec2f32{ dw.SCREEN_WIDTH, dw.SCREEN_HEIGHT },
            .size = size / Vec2f32{ dw.SCREEN_WIDTH, dw.SCREEN_HEIGHT },
            .rotation = 0,
            .id = @intFromEnum(dw.Sprite.rectangle),
        };
    }
}
