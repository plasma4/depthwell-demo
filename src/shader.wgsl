// ----
// Main shader for Depthwell. Currently does not support Mach Engine.
// ----

// These are sprite sheet constants.
// Sprites are saved as a .png in a sprite sheet 128 pixels wide, and each asset is 16x16.
// See zig/state/world.zig's Sprite definitions for sprite type list.

// #CONSTANT REGION, DO NOT MODIFY MANUALLY#
// Auto-generated from zig/types/sprite.zig by zig/generate_shader.zig (runs during `zig build`).
// Do NOT edit values between the markers by hand; edit the Sprite enum instead.
const TILES_PER_ROW: f32 = 16.0;
const TILES_PER_COLUMN: f32 = 20.0;
const STONE_START: u32 = 20u;
const ORE_START: u32 = 53u;
const GEM_START: u32 = 59u;
const GEM_MASK_START: u32 = 73u;
const WATER_START: u32 = 304u;
// #CONSTANT REGION END#

const PI = radians(180.0);
const TAU = radians(360.0);

const TILES_PER_ROW_U: u32 = u32(TILES_PER_ROW);
const HP_SAMPLE_START: u32 = GEM_MASK_START + 8u; // there are 8 gem masks and 16 HP masks
const DECOR_START: u32 = HP_SAMPLE_START + 16u;

const TILE_SIZE: f32 = 16.0;
const PIXEL_UV_SIZE: f32 = 1.0 / TILE_SIZE;
const ATLAS_WIDTH: f32 = TILE_SIZE * TILES_PER_ROW;
const ATLAS_HEIGHT: f32 = TILE_SIZE * TILES_PER_COLUMN;
const SPRITE_W: f32 = TILE_SIZE / ATLAS_WIDTH;
const SPRITE_H: f32 = TILE_SIZE / ATLAS_HEIGHT;
const TEXTURE_BLEEDING_EPSILON = 0.5 / TILE_SIZE;

// See EdgeFlags in zig/types/types.zig.
const EDGE_TOP: u32 = 0x02u;
const EDGE_BOTTOM: u32 = 0x40u;
const EDGE_LEFT: u32 = 0x08u;
const EDGE_RIGHT: u32 = 0x10u;
const EDGE_TOP_LEFT: u32 = 0x01u;
const EDGE_TOP_RIGHT: u32 = 0x04u;
const EDGE_BOTTOM_LEFT: u32 = 0x20u;
const EDGE_BOTTOM_RIGHT: u32 = 0x80u;

// Uniforms are cached on the GPU. This is updated once per frame by Zig.
struct SceneUniforms {
    camera: vec2f,
    viewport_size: vec2f,
    time: f32,
    zoom: f32,
    wireframe_opacity: f32,
    chunk_opacity: f32,
    player_screen_pos: vec2f,
    map_size: vec2u,
    flags: vec4u, // .a: is_p3; .b: is_8bit (.b is unused)
    grid_origin: vec4f, // absolute position of min_cx/min_cy in tiles (.xy used)
    // Per-frame warp of the tile layers: .xy screen offset in canvas pixels, .z rotation in radians,
    // .w uniform scale. Identity is (0, 0, 0, 1).
    // Both layers of a portal descent are handed the same value
    // (so they shake as one image rather than sliding apart).
    warp: vec4f,
    _extra_padding: array<vec4u, 10>, // pad to 256 bytes for dynamic offsets
};

@group(0) @binding(0) var<uniform> scene: SceneUniforms;
@group(0) @binding(1) var<storage, read> tiles: array<TileData>;
@group(0) @binding(2) var sprite_atlas: texture_2d<f32>;
@group(0) @binding(3) var sprite_atlas_mask: texture_2d<f32>;
@group(0) @binding(4) var pixel_sampler: sampler;
@group(0) @binding(5) var<storage, read> entities: array<WGSLEntity>;

/*
    ----
    TILES
    ----
*/

// Data passed from the Vertex step (per-corner) to the Fragment step (per-pixel)
struct TileOutput {
    @builtin(position) position: vec4f,
    // Local UV (0.0 to 1.0) across the surface of the specific tile.
    @location(0) local_uv: vec2f,
    // Where on the chunk a tile is
    // @interpolate(flat) tells the GPU NOT to blend these values between the 4 corners of the quad.
    @location(1) @interpolate(flat) tile_coords: vec2u, // X and Y of the tile
    @location(2) @interpolate(flat) sprite_uv_origin: vec2f, // base UV of the sprite
    @location(3) @interpolate(flat) sprite_id: u32, // do note that an extra u16 id is injected to the top half of bits with gems
    @location(4) @interpolate(flat) edge_flags: u32,
    @location(5) @interpolate(flat) light: f32,
    @location(6) @interpolate(flat) hp: u32,
    // seed0: raw seed data and HP mixed
    // seed1: murmurmix32'ed from seed0
    // seed2: murmurmix32'ed from seed1
    // seed3: murmurmix32'ed from seed2
    @location(7) @interpolate(flat) seeds: vec4u,
    @location(8) @interpolate(flat) lighting_color: u32,
    @location(9) @interpolate(flat) waterlogged: u32,
    // base_id in bits 0-15, id_edge_flags (same-sprite edge flags) in bits 16-23
    @location(10) @interpolate(flat) base_data: u32,
};

struct TileData {
    word0: u32,
    word1: u32,
    word2: u32,
    word3: u32,
};

// Unpacked definition of tile (also see Block in zig/memory.zig)
struct UnpackedTile {
    sprite_id: u32,
    light: f32,
    hp: u32,
    seeds: vec4u,
    edge_flags: u32,
    base_id: u32,
    id_edge_flags: u32,
    lighting_color: u32,
    waterlogged: u32,
};

// Unpacks 128-bit tile data into various properties.
// Said properties are arranged and explained in more detail in zig/memory.zig's Block struct.
fn unpack_tile(data: TileData) -> UnpackedTile {
    var out: UnpackedTile;

    out.sprite_id = extractBits(data.word0, 0u, 16u);
    out.edge_flags = extractBits(data.word0, 16u, 8u);
    // out.edge_flags = 0u; // override test example
    out.light = f32(extractBits(data.word0, 24u, 8u)) / 255.0;

    // The HP is automatically folded into the 28-bit seed by accessing just this word!
    out.hp = extractBits(data.word1, 0u, 4u);
    let s0 = data.word1;
    let s1 = murmurmix32(s0);
    let s2 = murmurmix32(s1);
    let s3 = murmurmix32(s2);
    out.seeds = vec4u(s0, s1, s2, s3);

    out.base_id = extractBits(data.word2, 0u, 16u);
    out.id_edge_flags = extractBits(data.word2, 16u, 8u);
    out.lighting_color = extractBits(data.word2, 24u, 8u);

    out.waterlogged = extractBits(data.word3, 0u, 12u);
    // remaining 20 bits unused
    return out;
}

// Main vertex shader for tiles.
// Rotates and scales a screen position about the middle of the viewport, then shifts it.
// (Identity warp leaves the position untouched.)
fn apply_warp(p: vec2f) -> vec2f {
    let center = scene.viewport_size * 0.5;
    let d = p - center;
    let c = cos(scene.warp.z);
    let s = sin(scene.warp.z);
    let spun = vec2f(d.x * c - d.y * s, d.x * s + d.y * c);
    return center + spun * scene.warp.w + scene.warp.xy;
}

@vertex
fn vs_tile(
    @builtin(vertex_index) vertex_index: u32,
    @builtin(instance_index) instance_index: u32
) -> TileOutput {
    // A bitmask where bits 1, 4, and 5 are set (0b110010 = 50) and bits 2, 3, and 5 are set (0b101100 = 44)
    let local_pos = vec2f((vec2u(50u, 44u) >> vec2u(vertex_index)) & vec2u(1u));

    var out: TileOutput;

    let tile = unpack_tile(tiles[instance_index]);
    if tile.sprite_id == 0u && scene.wireframe_opacity == 0.0 {
        out.position = vec4f(2.0, 2.0, 2.0, 1.0); // ideal outcode
        return out;
    }

    let tile_coords = vec2u(instance_index % scene.map_size.x, instance_index / scene.map_size.x);
    var id = tile.sprite_id;

    let world_pixel_pos = (vec2f(tile_coords) + local_pos) * TILE_SIZE;
    let screen_pos = apply_warp(((world_pixel_pos - scene.camera) * scene.zoom) + (scene.viewport_size * 0.5));

    // normalize coordinates
    // first, make sure spiral plant and ceiling flower move up (visually) by 2 pixels
    // var vertical_offset = select(
    //     0.0,
    //     2.0 * scene.zoom,
    //     // spiral plant, ceiling flower
    //     id == GEAR_ID + 4u || id == GEAR_ID + 5u
    // );
    // update: this messes with water visually
    const vertical_offset = 0;

    // apply to screen_pos.y before converting to normalized device coordinates
    // subtract from Y because in screen space, lower values are "higher" up
    let adjusted_screen_pos = screen_pos - vec2f(0.0, vertical_offset);
    let ndc = (adjusted_screen_pos / scene.viewport_size) * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0);

    // Calculate which sprite in the atlas to sample
    let origin = vec2f(f32(id % TILES_PER_ROW_U), f32(id / TILES_PER_ROW_U)) * vec2f(SPRITE_W, SPRITE_H);

    out.position = vec4f(ndc, 0.0, 1.0);
    out.sprite_uv_origin = origin;
    let is_gem = id >= GEM_START && id < GEM_MASK_START;
    // if is_gem {
    //     out.sprite_id = extractBits(tiles[instance_index].word0, 0u, 16u) | id;
    // } else {
    //     out.sprite_id = id;
    // }
    out.sprite_id = id;
    out.hp = tile.hp;
    out.seeds = tile.seeds;
    out.edge_flags = tile.edge_flags;
    out.tile_coords = tile_coords;
    out.light = tile.light;
    out.local_uv = local_pos;
    out.lighting_color = tile.lighting_color;
    out.waterlogged = tile.waterlogged;
    out.base_data = tile.base_id | (tile.id_edge_flags << 16u);
    return out;
}

@fragment
fn fs_tile(in: TileOutput) -> @location(0) vec4f {
    var erode_mask: u32 = 1u;
    let id = in.sprite_id /* & 65535 */;
    let is_decor = id >= DECOR_START;

    // instead of doing alpha blending the wireframe brightness has been lazily chucked here, since we rarely use it
    if scene.wireframe_opacity != 0.0 {
        // render wireframe due to being at the edge of a block?
        let inv_tile_scale = 0.5001 / (TILE_SIZE * scene.zoom);
        let is_block_edge = any(in.local_uv < vec2f(inv_tile_scale)) || any(in.local_uv > vec2f(1.0 - inv_tile_scale));

        if is_block_edge {
            let mods = in.tile_coords & vec2u(15u);

            // Is this pixel on the edge of a CHUNK?
            let is_chunk_edge = any((mods == vec2u(0u)) & (in.local_uv < vec2f(inv_tile_scale))) ||
                any((mods == vec2u(15u)) & (in.local_uv > vec2f(1.0 - inv_tile_scale)));

            var wire_color = vec4f(0.0);
            if is_chunk_edge {
                wire_color = vec4f(1.0, 1.0, 0.0, min(1.0, scene.wireframe_opacity * 2.5));
            } else {
                // neat-lookin' fancy wireframe coloring
                let rg = vec2f(mods) * 0.0625;
                let b = 0.5 + f32(mods.x ^ mods.y) * 0.03125;
                wire_color = vec4f(rg.x, rg.y, b, scene.wireframe_opacity);
            }
            return wire_color;
        } else if erode_mask == 0u {
            discard;
        }
    }

    if id == WATER_START || id == WATER_START + 1u {
        let has_liquid_above = (in.waterlogged & 1u) != 0u;
        let has_solid_above = ((in.edge_flags & EDGE_TOP) != 0u) && !has_liquid_above;
        let has_top = has_liquid_above || (has_solid_above && (in.hp == 15u));

        if !has_top {
            // This is the top surface of the water body!
            let t = scene.time;
            let world_pos = wrap_water_coords((vec2f(in.tile_coords) + scene.grid_origin.xy) * TILE_SIZE + in.local_uv * TILE_SIZE);

            // Smooth the surface across neighbors (adjacent volumes in bits 3-6 / 7-10).
            // Each tile edge sits at the midpoint between this cell and its neighbor,
            // so adjacent tiles agree on the shared edge height and the surface reads as continuous instead of stepped.
            // A dry side keeps the block's own level so the surface doesn't dip at the water's edge.
            let left_vol = extractBits(in.waterlogged, 3u, 4u);
            let right_vol = extractBits(in.waterlogged, 7u, 4u);
            let self_h = f32(in.hp);
            let left_edge_h = select(self_h, 0.5 * (self_h + f32(left_vol)), left_vol > 0u);
            let right_edge_h = select(self_h, 0.5 * (self_h + f32(right_vol)), right_vol > 0u);

            // Sine-wave ripple effect at the surface (frequency is periodic over 65536.0 pixels)
            let base_height = mix(left_edge_h, right_edge_h, in.local_uv.x) * 0.06 + 0.10;
            let ripple_freq = 4172.0 * TAU / 65536.0;
            let ripple = sin(world_pos.x * ripple_freq + t * 5.0) * 0.05;
            var current_height = base_height + ripple;

            // If the pixel is above the water surface, discard it
            if in.local_uv.y < (1.0 - current_height) {
                discard;
            }
        }
        return water_body(in);
    }

    if in.sprite_id >= 65000u && in.sprite_id <= 65256u {
        // Heatmap logic!
        let color = (f32(in.sprite_id - 65000u)) / 256.0;
        var lch = vec3f(0.2 + color * 0.8, 0.2, 1.0); // lightness, chroma, and hue
        let lab = oklch_to_oklab(lch);
        let final_rgb = oklab_to_linear_srgb(lab);
        return vec4f(final_rgb, 1.0);
    }

    // Determine waterlogged decoration state
    let is_waterlogged_decor = is_decor && in.hp > 0u;
    var is_decor_pixel_underwater = false;
    if is_waterlogged_decor {
        let wl_top = (in.waterlogged & 1u) != 0u;
        let wl_ripple = (in.waterlogged & 4u) != 0u;
        let has_top = wl_top || (((in.edge_flags & EDGE_TOP) != 0u) && in.hp == 15u);
        var current_height = 1.0;
        if !has_top {
            let base_height = f32(in.hp) * 0.06 + 0.10;
            let t = scene.time;
            let world_pos = wrap_water_coords((vec2f(in.tile_coords) + scene.grid_origin.xy) * TILE_SIZE + in.local_uv * TILE_SIZE);
            let ripple_freq = 4172.0 * TAU / 65536.0;
            let ripple = sin(world_pos.x * ripple_freq + t * 5.0) * 0.05;
            current_height = base_height + ripple;
        }
        if in.local_uv.y >= (1.0 - current_height) {
            is_decor_pixel_underwater = true;
        }
    }

    let safe_local_uv = clamp(in.local_uv, vec2f(TEXTURE_BLEEDING_EPSILON), vec2f(1.0 - TEXTURE_BLEEDING_EPSILON));

    if in.edge_flags != 0xFFu && !is_decor {
        erode_mask = erosion(in.local_uv, in.edge_flags, in.seeds[2], in.seeds[3], 0u);
        if erode_mask == 0u {
            if in.waterlogged != 0u {
                let is_water_top = (in.waterlogged & 1u) != 0u;
                let is_water_bottom = (in.waterlogged & 2u) != 0u;
                let apply_ripple = (in.waterlogged & 4u) != 0u;
                // Left/right presence is implied by a nonzero adjacent volume (bits 3-6 / 7-10).
                let left_vol = extractBits(in.waterlogged, 3u, 4u);
                let right_vol = extractBits(in.waterlogged, 7u, 4u);
                let is_water_left = left_vol > 0u;
                let is_water_right = right_vol > 0u;

                var is_water_pixel = false;
                if is_water_top {
                    // Water of any depth above fully submerges the block: fill it entirely,
                    // with no exposed surface to carve.
                    is_water_pixel = true;
                } else {
                    if is_water_bottom && in.local_uv.y >= 0.5 {
                        is_water_pixel = true;
                    }
                    if is_water_left && in.local_uv.x < 0.5 {
                        is_water_pixel = true;
                    }
                    if is_water_right && in.local_uv.x >= 0.5 {
                        is_water_pixel = true;
                    }

                    if is_water_pixel && apply_ripple {
                        let t = scene.time;
                        let world_pos = wrap_water_coords((vec2f(in.tile_coords) + scene.grid_origin.xy) * TILE_SIZE + in.local_uv * TILE_SIZE);

                        // Surface height follows the adjacent water's actual volume rather than a
                        // fixed full block, smoothly interpolated across the tile from the left
                        // neighbor's level to the right neighbor's level. A side with no water
                        // borrows the other side's level so the surface stays flat instead of
                        // sloping down to zero.
                        let hl = select(f32(right_vol), f32(left_vol), is_water_left);
                        let hr = select(f32(left_vol), f32(right_vol), is_water_right);
                        let vol_at_x = mix(hl, hr, in.local_uv.x);
                        let base_height = vol_at_x * 0.06 + 0.10;
                        let ripple_freq = 4172.0 * TAU / 65536.0;
                        let ripple = sin(world_pos.x * ripple_freq + t * 5.0) * 0.05;
                        let current_height = base_height + ripple;

                        if in.local_uv.y < (1.0 - current_height) {
                            is_water_pixel = false;
                        }
                    }
                }

                if is_water_pixel { return water_body(in); }
            }
            discard; // discard early
        }
    }

    let seed = in.seeds[1];
    let is_gem = id >= GEM_START && id < GEM_MASK_START;
    let is_ore = id >= ORE_START && id < GEM_START;

    var final_uv = in.sprite_uv_origin + safe_local_uv * vec2f(SPRITE_W, SPRITE_H);

    // Apply 0-15 pixel shift for gems using bits 16-23 of seed3
    if is_gem {
        let shift_bits = extractBits(in.seeds[3], 16u, 8u);
        let shift = vec2f(vec2u(shift_bits & 0xFu, shift_bits >> 4u)) / 16.0;
        let wrapped_local = fract(in.local_uv + shift);
        let safe_wrapped = clamp(wrapped_local, vec2f(TEXTURE_BLEEDING_EPSILON), vec2f(1.0 - TEXTURE_BLEEDING_EPSILON));
        final_uv = in.sprite_uv_origin + safe_wrapped * vec2f(SPRITE_W, SPRITE_H);
    }

    // Avoid HP mask texture sample for undamaged tiles or decor sprites
    var hp_darkness_mult = 1.0;
    if in.hp > 0u && !is_decor {
        let hp_id = HP_SAMPLE_START + in.hp;
        let hp_grid = vec2f(f32(hp_id % TILES_PER_ROW_U), f32(hp_id / TILES_PER_ROW_U));
        let hp_uv = (hp_grid + safe_local_uv) * vec2f(SPRITE_W, SPRITE_H);
        hp_darkness_mult = textureSampleLevel(sprite_atlas, pixel_sampler, hp_uv, 0.0).r;
    }

    var tex_color = textureSampleLevel(sprite_atlas, pixel_sampler, final_uv, 0.0);
    tex_color = vec4f(srgb_to_linear(tex_color.rgb) * hp_darkness_mult, tex_color.a);

    let base_id = extractBits(in.base_data, 0u, 16u);
    let id_edge_flags = extractBits(in.base_data, 16u, 8u);

    // gem sampling pixel logic
    if is_gem {
        // 8 masks, OLD: first 4 for gems, second 4 for ore, NEW: all 8 for gems only
        // let mask_variation = extractBits(seed, 15u, 2u) + select(4u, 0u, is_gem);

        // First 4 bits in seeds[0] are for HP, do NOT trust
        let mask_variation = extractBits(in.seeds[0], 4u, 3u);
        let mask_id = GEM_MASK_START + mask_variation;

        let flip = vec2f(vec2u(extractBits(in.seeds[0], 7u, 1u), extractBits(in.seeds[0], 8u, 1u)));

        let flipped_uv = mix(in.local_uv, 1.0 - in.local_uv, flip);
        // Background is the block's real underlay so fall back to the old 2x2 plain-stone parity for gems with no base_id.
        // TODO: do we force a base ID?
        let bg_id = select(STONE_START + (((in.tile_coords.y & 1u) << 1u) | (in.tile_coords.x & 1u)), base_id, base_id != 0u);

        // Calculate UVs for the background stone
        let bg_grid = vec2f(f32(bg_id % TILES_PER_ROW_U), f32(bg_id / TILES_PER_ROW_U));
        let stone_uv = (bg_grid + safe_local_uv) * vec2f(SPRITE_W, SPRITE_H);

        // Calculate UVs for the mask (using the UNSHIFTED uv)
        let safe_flipped_uv = clamp(flipped_uv, vec2f(TEXTURE_BLEEDING_EPSILON), vec2f(1.0 - TEXTURE_BLEEDING_EPSILON));
        let mask_grid = vec2f(f32(mask_id % TILES_PER_ROW_U), f32(mask_id / TILES_PER_ROW_U));
        let mask_uv = (mask_grid + safe_flipped_uv) * vec2f(SPRITE_W, SPRITE_H);

        let tex_stone = textureSampleLevel(sprite_atlas, pixel_sampler, stone_uv, 0.0);
        let tex_mask = textureSampleLevel(sprite_atlas, pixel_sampler, mask_uv, 0.0);

        let abs_dist = abs(in.local_uv - 0.5); // higher value means closer to EDGES
        let u_dist = 0.5 - max(abs_dist.x, abs_dist.y); // higher value means closer to CENTER

        // with linear RGB: r component of mask determines brightness, vary ore brightness, multiply stone brightness based on dist
        let final_rgb_ore = mix(
             // stone pixels near center become darker based on HP
            srgb_to_linear(tex_stone.rgb) * vec3f(1.2 - 0.22 * f32(in.hp + 1) * u_dist), 
            // gem pixels near center become brighter
            tex_color.rgb * vec3f(tex_mask.r + 0.3 * u_dist),
            tex_mask.a + u_dist
        );
        tex_color = vec4f(final_rgb_ore, tex_stone.a);
    }

    var ore_darkening: f32 = 0.0;
    var ore_chroma_mult: f32 = 1.0;
    var ore_light_mult: f32 = 1.0;
    var base_brightening: f32 = 0.0;

    if is_ore && base_id != 0u {
        // Pass in increased shrink to shrink the edges/corners and increase border radius!
        var ore_mask = erosion(in.local_uv, id_edge_flags, in.seeds[2], in.seeds[3], 2u);

        if ore_mask == 0u {
            // Rebuild tex_color from the base tile directly before OKLCH conversion
            let base_grid = vec2f(f32(base_id % TILES_PER_ROW_U), f32(base_id / TILES_PER_ROW_U));
            let base_uv = (base_grid + safe_local_uv) * vec2f(SPRITE_W, SPRITE_H);
            let tex_base = textureSampleLevel(sprite_atlas, pixel_sampler, base_uv, 0.0);
            tex_color = vec4f(srgb_to_linear(tex_base.rgb) * hp_darkness_mult, tex_base.a);

            // Now, calculate proximity to the unconnected tile edges, or the ore boundary
            let width_bonus = -0.22 + f32(extractBits(in.seeds[3], 24u, 3u)) / 128.0;
            let ore_edge_proximity = calculate_edge_darkening(in.local_uv, id_edge_flags, in.seeds[2], width_bonus, 0.1);
            base_brightening = ore_edge_proximity * 0.15; // subtle rim-light highlight on the base sprite near the ore boundary
        } else {
            // Also add edge darkening effect (fairly weak)
            let width_bonus = -0.22 + f32(extractBits(in.seeds[3], 24u, 3u)) / 128.0;
            ore_darkening = calculate_edge_darkening(in.local_uv, id_edge_flags, in.seeds[2], width_bonus, 0.12);
            ore_light_mult = (1.0 - ore_darkening) * select(1.0, 0.7, ore_mask == 2u) * 1.1; // 1.1: brighter interior by default
            ore_chroma_mult = (1.0 + ore_darkening * 0.15) * select(1.0, 1.1, ore_mask == 2u);
        }
    }

    // Convert to oklab and nudge values with seed
    var lab = linear_srgb_to_oklab(tex_color.rgb);
    var lch = oklab_to_oklch(lab);

    // Apply pre-calculated ore modifications to OKLCH
    if is_ore && base_id != 0u {
        lch.x *= ore_light_mult * (1.0 + base_brightening);
        lch.y *= ore_chroma_mult;
    }

    // We use 9 out of the 28 seed bits here
    let lab_nudge_bits = vec3u(
        extractBits(seed, 0u, 3u), // shift lightness (0-1)
        extractBits(seed, 3u, 3u), // shift chroma, which acts similar to saturation (in practice, between 0-0.4)
        extractBits(seed, 6u, 3u)// shift hue (in RADIANS, red isn't exactly 0)
    );
    let nudges = vec3f(lab_nudge_bits) / 7.0;

    // Scale chroma with light intensity to prevent high-chroma lighting leakage in the dark
    let chroma_light_scale = max(0.0, in.light);

    // Apply light and nudges (Chroma y is scaled by the light level)
    lch *= vec3f(
        in.light + nudges.x * 0.02,
        (0.9 + nudges.y * 0.3) * chroma_light_scale,
        1.0 + nudges.z * 0.06
    );

    var final_rgb = vec3f(0.0);
    if in.edge_flags != 0xFFu {
        // Add the edge darkening and base light value, with the function using bits 10-16
        let darkening = calculate_edge_darkening(in.local_uv, in.edge_flags, seed, 0.0, 0.0);
        lch.x *= (1.0 - darkening);

        if erode_mask == 2u {
            lch *= vec3f(0.6 + f32(lab_nudge_bits.x) * 0.01, 1.3 + f32(lab_nudge_bits.y) * 0.04, 1.0);
        }
    }

    // Convert OKLCH result to OKLAB, then finally back to float-based RGB
    lab = oklch_to_oklab(lch);
    if (in.lighting_color & 1) == 1 {
        // warmth color shift
        lab.y += 0.024; // +a channel (more red/magenta)
        lab.z += 0.06; // +b channel (more yellow)

        // slightly boost brightness
        // lab.x *= 1.05;
    }
    final_rgb = oklab_to_linear_srgb(lab);

    var final_a = tex_color.a * scene.chunk_opacity; // the player is now an entity, so all tiles use chunk_opacity

    // Overlay semi-transparent water body if this decoration pixel is underwater
    if is_decor_pixel_underwater {
        let water_col = water_body_linear(in);

        // Blending curve: maps original alpha to water weight
        let weight = 1.0 - 0.5 * pow(tex_color.a, 7.0);

        final_rgb = oklab_water(final_rgb, water_col.rgb, weight);
        final_a = mix(water_col.a, 1.0, tex_color.a);
    }

    return vec4f(apply_color_management(final_rgb), final_a);
}

// Bijective mixer for 32-bit integers
fn murmurmix32(number: u32) -> u32 {
    var h = max(number, 1u);
    h ^= h >> 16;
    h *= 0x85ebca6b;
    h ^= h >> 13;
    h *= 0xc2b2ae35;
    h ^= h >> 16;
    return h;
}

// Complex logic that returns 0u if a pixel should be TRANSPARENT ("eroded"), 1u for NORMAL, or 2u for BORDER (darkened).
// Border radius is increased if shrink equals 1.
fn erosion(local_uv: vec2f, edge_flags: u32, seed2: u32, seed3: u32, shrink: u32) -> u32 { // uv of sprite, edge flags, mixed seeds, and erosion shrink amount
    let px = u32(clamp(local_uv.x, 0.0, 0.9999) * TILE_SIZE);
    let py = u32(clamp(local_uv.y, 0.0, 0.9999) * TILE_SIZE);

    let has_top = (edge_flags & EDGE_TOP) != 0u;
    let has_bottom = (edge_flags & EDGE_BOTTOM) != 0u;
    let has_left = (edge_flags & EDGE_LEFT) != 0u;
    let has_right = (edge_flags & EDGE_RIGHT) != 0u;
    let has_tl = (edge_flags & EDGE_TOP_LEFT) != 0u;
    let has_tr = (edge_flags & EDGE_TOP_RIGHT) != 0u;
    let has_bl = (edge_flags & EDGE_BOTTOM_LEFT) != 0u;
    let has_br = (edge_flags & EDGE_BOTTOM_RIGHT) != 0u;

    // Precompute outer corner radii from sc (used by both corner arcs and straight-edge safe zones)
    let r_tl = select(4u, 6u, shrink == 2u) + extractBits(seed3, 0u, 2u);
    let r_tr = select(4u, 6u, shrink == 2u) + extractBits(seed3, 2u, 2u);
    let r_bl = select(4u, 6u, shrink == 2u) + extractBits(seed3, 4u, 2u);
    let r_br = select(4u, 6u, shrink == 2u) + extractBits(seed3, 6u, 2u);

    // The "center" of the circle is at the corner! Do some pixel-perfect circle edge logic.

    // Top-left outer corner (top AND left both missing)
    if !has_top && !has_left {
        let r_sq = r_tl * r_tl;
        let dx = r_tl - px;
        let dy = r_tl - py;
        if px < r_tl && py < r_tl {
            let dist_sq = dx * dx + dy * dy;
            if dist_sq > r_sq { return 0u; }
            if dist_sq > r_sq - r_tl { return 2u; } // darken ring of 1 pixel
        }
    }

    // Top-right outer corner
    if !has_top && !has_right {
        let r_sq = r_tr * r_tr;
        let fpx = 15u - px; // flip x
        if fpx < r_tr && py < r_tr {
            let dx = r_tr - fpx;
            let dy = r_tr - py;
            let dist_sq = dx * dx + dy * dy;
            if dist_sq > r_sq { return 0u; }
            if dist_sq > r_sq - r_tr { return 2u; }
        }
    }

    // Bottom-left outer corner
    if !has_bottom && !has_left {
        let r_sq = r_bl * r_bl;
        let fpy = 15u - py;
        if px < r_bl && fpy < r_bl {
            let dx = r_bl - px;
            let dy = r_bl - fpy;
            let dist_sq = dx * dx + dy * dy;
            if dist_sq > r_sq { return 0u; }
            if dist_sq > r_sq - r_bl { return 2u; }
        }
    }

    // Bottom-right outer corner
    if !has_bottom && !has_right {
        let r_sq = r_br * r_br;
        let fpx = 15u - px;
        let fpy = 15u - py;
        if fpx < r_br && fpy < r_br {
            let dx = r_br - fpx;
            let dy = r_br - fpy;
            let dist_sq = dx * dx + dy * dy;
            if dist_sq > r_sq { return 0u; }
            if dist_sq > r_sq - r_br { return 2u; }
        }
    }

    // Straight edges (8 bits each from se: bits 0-7 top, 8-15 bottom, 16-23 left, 24-31 right)

    // Top edge
    if !has_top {
        let base_depth = extractBits(seed2, 0u, 1u); // 0 or 1 pixels inward for each edge
        let notch_pos = extractBits(seed2, 1u, 4u);
        let notch_dir = extractBits(seed2, 5u, 1u);
        let notch_width = 2u + extractBits(seed2, 6u, 2u);

        var depth = base_depth;
        if px >= notch_pos && px < notch_pos + notch_width {
            if notch_dir == 0u { depth += 1u; } else { depth = max(depth, 1u) - 1u; }
        }
        depth += shrink;

        // Only apply straight edge outside the corner rounding zones
        let left_safe = select(0u, r_tl, !has_left);
        let right_safe = select(16u, 16u - r_tr, !has_right);

        if px >= left_safe && px < right_safe {
            if py < depth { return 0u; }
            if py == depth { return 2u; }
        }
    }

    // Bottom edge
    if !has_bottom {
        let base_depth = extractBits(seed2, 8u, 1u);
        let notch_pos = extractBits(seed2, 9u, 4u);
        let notch_dir = extractBits(seed2, 13u, 1u);
        let notch_width = 2u + extractBits(seed2, 14u, 2u);

        var depth = base_depth;
        if px >= notch_pos && px < notch_pos + notch_width {
            if notch_dir == 0u { depth += 1u; } else { depth = max(depth, 1u) - 1u; }
        }
        depth += shrink;

        let left_safe = select(0u, r_bl, !has_left);
        let right_safe = select(16u, 16u - r_br, !has_right);

        if px >= left_safe && px < right_safe {
            if py > 15u - depth { return 0u; }
            if py == 15u - depth { return 2u; }
        }
    }

    // Left edge
    if !has_left {
        let base_depth = extractBits(seed2, 16u, 1u);
        let notch_pos = extractBits(seed2, 17u, 4u);
        let notch_dir = extractBits(seed2, 21u, 1u);
        let notch_width = 2u + extractBits(seed2, 22u, 2u);

        var depth = base_depth;
        if py >= notch_pos && py < notch_pos + notch_width {
            if notch_dir == 0u { depth += 1u; } else { depth = max(depth, 1u) - 1u; }
        }
        depth += shrink;

        let top_safe = select(0u, r_tl, !has_top);
        let bottom_safe = select(16u, 16u - r_bl, !has_bottom);

        if py >= top_safe && py < bottom_safe {
            if px < depth { return 0u; }
            if px == depth { return 2u; }
        }
    }

    // Right edge
    if !has_right {
        let base_depth = extractBits(seed2, 24u, 1u);
        let notch_pos = extractBits(seed2, 25u, 4u);
        let notch_dir = extractBits(seed2, 29u, 1u);
        let notch_width = 2u + extractBits(seed2, 30u, 2u);

        var depth = base_depth;
        if py >= notch_pos && py < notch_pos + notch_width {
            if notch_dir == 0u { depth += 1u; } else { depth = max(depth, 1u) - 1u; }
        }
        depth += shrink;

        let top_safe = select(0u, r_tr, !has_top);
        let bottom_safe = select(16u, 16u - r_br, !has_bottom);

        if py >= top_safe && py < bottom_safe {
            if px > 15u - depth { return 0u; }
            if px == 15u - depth { return 2u; }
        }
    }

    // Inner corners (no diagonal neighbor)

    if !has_tl && has_top && has_left {
        let r = 1u + extractBits(seed3, 8u, 2u); // 1-4 pixel radius (shrink not added)
        if px < r && py < r {
            let dx = px + 1u; // +1, so the circle center is at (-0.5, -0.5) effectively
            let dy = py + 1u;
            let dist_sq = dx * dx + dy * dy;
            if dist_sq <= r * r { return 0u; }
            if dist_sq <= (r + 1u) * (r + 1u) { return 2u; }
        }
    }

    if !has_tr && has_top && has_right {
        let r = 1u + extractBits(seed3, 10u, 2u);
        let fpx = 15u - px;
        if fpx < r && py < r {
            let dx = fpx + 1u;
            let dy = py + 1u;
            let dist_sq = dx * dx + dy * dy;
            if dist_sq <= r * r { return 0u; }
            if dist_sq <= (r + 1u) * (r + 1u) { return 2u; }
        }
    }

    if !has_bl && has_bottom && has_left {
        let r = 1u + extractBits(seed3, 12u, 2u);
        let fpy = 15u - py;
        if px < r && fpy < r {
            let dx = px + 1u;
            let dy = fpy + 1u;
            let dist_sq = dx * dx + dy * dy;
            if dist_sq <= r * r { return 0u; }
            if dist_sq <= (r + 1u) * (r + 1u) { return 2u; }
        }
    }

    if !has_br && has_bottom && has_right {
        let r = 1u + extractBits(seed3, 14u, 2u);
        let fpx = 15u - px;
        let fpy = 15u - py;
        if fpx < r && fpy < r {
            let dx = fpx + 1u;
            let dy = fpy + 1u;
            let dist_sq = dx * dx + dy * dy;
            if dist_sq <= r * r { return 0u; }
            if dist_sq <= (r + 1u) * (r + 1u) { return 2u; }
        }
    }

    return 1u;
}

// Number of 1 bits in a u8 (possibly useful for edge flags, currently unused).
fn popcount8(v: u32) -> u32 {
    var n = v;
    n = n - ((n >> 1u) & 0x55u);
    n = (n & 0x33u) + ((n >> 2u) & 0x33u);
    return ((n + (n >> 4u)) & 0x0Fu);
}

// Calculates edge darkening procedurally based on flags calculated in Zig.
// `width_bonus` widens the darkening band inward and `strength_bonus` deepens the peak darkening
// (both 0.0 for normal terrain); ores pass seed-derived values. See ORE_EDGE_WIDTH/STRENGTH_BONUS.
fn calculate_edge_darkening(local_uv: vec2f, edge_flags: u32, seed: u32, width_bonus: f32, strength_bonus: f32) -> f32 {
    let edge_width = 0.40 + f32(extractBits(seed, 9u, 3u)) / 32.0 + width_bonus;
    let edge_strength = 0.4 + f32(extractBits(seed, 12u, 3u)) / 32.0 + strength_bonus;

    let dists = vec4f(local_uv.y, 1.0 - local_uv.y, local_uv.x, 1.0 - local_uv.x);
    let edge_masks = vec4u(edge_flags) & vec4u(EDGE_TOP, EDGE_BOTTOM, EDGE_LEFT, EDGE_RIGHT);
    let is_edge = edge_masks == vec4u(0u);

    let edge_darkenings = select(
        vec4f(0.0),
        (1.0 - smoothstep(vec4f(0.0), vec4f(edge_width), dists)) * edge_strength,
        is_edge
    );

    return max(max(edge_darkenings.x, edge_darkenings.y), max(edge_darkenings.z, edge_darkenings.w));
}

/*
    ----
    WATER
    ----
*/

// water field is periodic over 256 chunks
const WATER_PERIOD = 65536.0;
// radians per cycle-unit of a wave vector
const WATER_CYCLE = TAU / WATER_PERIOD;

fn wrap_water_coords(coords: vec2f) -> vec2f {
    return coords - floor(coords / WATER_PERIOD) * WATER_PERIOD;
}

// One plane wave of the field, in [0, 1]. `cycles` is the wave vector (see above, integers only)
// and `speed` is its drift along that vector, in cycles per second.
fn water_wave(coord: vec2f, cycles: vec2f, speed: f32, t: f32) -> f32 {
    return sin(dot(coord, cycles) * WATER_CYCLE + t * speed * TAU) * 0.5 + 0.5;
}

// World-space pixel coordinate of this fragment (floating point, any value)
fn water_world(in: TileOutput) -> vec2f {
    return (vec2f(in.tile_coords) + scene.grid_origin.xy) * TILE_SIZE + in.local_uv * TILE_SIZE;
}

// Shared base LCH that cycles hue between teal and blue.
fn water_base_lch(t: f32) -> vec3f {
    let H = 3.8 + sin(t * (TAU / 3600.0)) * 0.34;
    return vec3f(0.42, 0.12, H);
}

// The caustic field. Returns:
//   .x the additive caustic brightness
//   .y: a broad swell in [0, 1] the body uses for its lightness gradient, no extra trig
fn water_effect(coord: vec2f, t: f32) -> vec2f {
    // A product of two low, near-incommensurate waves: neither's own period reads as the beat's.
    let swell = water_wave(coord, vec2f(37.0, 23.0), 0.011, t) *
        water_wave(coord, vec2f(-29.0, 41.0), -0.008, t);
    let swell_bias = 0.30 + 1.40 * swell;

    // Coarse warp, so the streaks bend rather than run straight across the screen.
    let warp_val = (water_wave(coord, vec2f(0.0, 512.0), 0.0056, t) - 0.5) * 11.0 +
        (water_wave(coord, vec2f(768.0, 0.0), -0.0033, t) - 0.5) * 8.0;

    let world = coord + vec2f(warp_val, -warp_val);
    let world2 = coord - vec2f(warp_val, -warp_val);

    // Layer A: the long bright ribbons. Two near-parallel waves beating against each other.
    let a1 = water_wave(world, vec2f(1349.0, -630.0), 0.341, t);
    let a2 = water_wave(world, vec2f(1707.0, -797.0), 0.374, t);
    let band_a = a1 * a2;

    // Crests of A only, sharpened thru math!
    let s2 = band_a * band_a;
    let sparkle = s2 * s2 * s2 * 0.4;

    // Layer B: fine cross-hatched ripple, riding the two warped frames against each other.
    let d_b = vec2f(world2.x, world.y);
    let b1 = water_wave(d_b, vec2f(4215.0, 5021.0), 0.125, t);
    let b2 = water_wave(d_b, vec2f(6322.0, 7531.0), 0.194, t);
    let temp_b = b1 * b2;
    let band_b = temp_b * temp_b * 0.03;

    // Layer C: a hard-edged sheet along A's direction, squared into thin bright lines.
    let band_c = max(0.0, water_wave(vec2f(world.x, world2.y), vec2f(1349.0, 630.0), 0.341, t) * 2.0 - 1.0);

    // Layer E: A's perpendicular, coarser; inverted vs. swell_bias.
    let e1 = water_wave(world2, vec2f(396.0, 848.0), -0.09, t);
    let e2 = water_wave(world2, vec2f(533.0, 1142.0), 0.13, t);
    let temp_e = e1 * e2;
    let band_e = temp_e * temp_e * e2 * 0.30;

    // Now a warp for the curvy streak, kept separate from the coarse one so it can be much tighter.
    let warp = (water_wave(world, vec2f(0.0, 1043.0), 0.048, t) - 0.5) * 8.0 +
        (water_wave(world, vec2f(834.0, 0.0), -0.048, t) - 0.5) * 8.0;

    let curvy = vec2f(world.x + warp, world.y - warp);
    let c1 = water_wave(curvy, vec2f(656.0, 1135.0), 0.024, t);
    let c2 = water_wave(curvy, vec2f(936.0, 1621.0), -0.010, t);
    let temp_c = c1 * c2;
    let temp_c2 = temp_c * temp_c;
    let curvy_streak = temp_c2 * temp_c2 * temp_c2 * 0.3;

    let toward_a = clamp(swell_bias, 0.0, 1.0);
    let caustic = (band_a * 0.24 + band_c * band_c * 0.2 + sparkle) * (0.45 + 0.55 * toward_a) +
        band_e * (1.0 - toward_a) +
        band_b +
        curvy_streak * (0.35 + 0.65 * toward_a);

    return vec2f(caustic, toward_a);
}

// Procedural effect for lighting (linear sRGB)
fn water_body_linear(in: TileOutput) -> vec4f {
    let light_val = max(0.0, in.light);

    // Performance shortcut: skip expensive caustic/wave calculations if the pixel is dark
    if light_val <= 0.005 {
        return vec4f(vec3f(0.0), 0.5);
    }

    let world = water_world(in);
    let t = scene.time;

    var lch = water_base_lch(t);

    let effect = water_effect(world, t);
    let caustic = effect.x;

    // Broad open/deep gradient. This rides the caustic field's own swell rather than absolute world y:
    // a raw world.y ramp only means anything within the first screens of the wrap window and steps at its boundary,
    // whereas the swell is periodic over the same window as everything else here.
    lch.x = mix(0.34, 0.52, effect.y); // lighter in the open water between the streak patches
    lch.y = mix(0.14, 0.10, effect.y); // slightly more saturated in the darker stretches

    // Horizontal color band (depth striping). 2731 cycles over the period holds the ~24px spacing.
    let band_t = water_wave(world, vec2f(0.0, 2731.0), 0.064, t);
    lch.x += band_t * 0.04;

    lch.x = clamp(lch.x + caustic, 0.26, 0.90);
    lch.y = clamp(lch.y + caustic * 0.10, 0.04, 0.28);

    // Apply light multiplier to both lightness and chroma to prevent light leakage in the dark
    lch.x *= light_val;
    lch.y *= light_val;

    var lab = oklch_to_oklab(lch);

    // Apply campfire warmth color shift (scaled by light intensity)
    if (in.lighting_color & 1u) == 1u {
        lab.y += 0.015 * light_val; // +a channel (more red/magenta)
        lab.z += 0.04 * light_val;  // +b channel (more yellow)
    }

    let rgb = oklab_to_linear_srgb(lab);
    return vec4f(rgb, 0.5);
}

// Procedural effect for all but the top water sprite (backwards compatible, returns color-managed sRGB)
fn water_body(in: TileOutput) -> vec4f {
    let water_col = water_body_linear(in);
    return vec4f(apply_color_management(water_col.rgb), water_col.a);
}

// Perceptually blends sprite color with water in OKLAB space.
fn oklab_water(sprite_rgb: vec3f, water_rgb: vec3f, weight: f32) -> vec3f {
    let lab_sprite = linear_srgb_to_oklab(sprite_rgb);
    let lab_water = linear_srgb_to_oklab(water_rgb);
    let lab_mixed = mix(lab_sprite, lab_water, weight);
    return oklab_to_linear_srgb(lab_mixed);
}

/*
    ----
    BACKGROUND
    ----
*/

// FBM background logic

// How strongly the background tracks camera zoom. 1.0 = locked 1:1 to the world;
// lower values make the background zoom slower than the camera for a parallax-depth feel, pivoting at zoom 1.0.
// Kept < 1 so far-out custom camera modes barely zoom the background.
const BG_ZOOM_PARALLAX: f32 = 0.35;

struct BackgroundOutput {
    @builtin(position) position: vec4f,
    @location(0) screen_offset: vec2f,
    @location(1) time: f32,
    @location(2) time2: f32,
};

// Main vertex shader for rendering the fancy background.
@vertex
fn vs_background(@builtin(vertex_index) vertex_index: u32) -> BackgroundOutput {
    // Full-screen triangle to draw: [(-1, -1), (3, -1), (-1, 3)]
    let x = f32((i32(vertex_index & 1u) << 2u) - 1);
    let y = f32((i32(vertex_index & 2u) << 1u) - 1);

    var out: BackgroundOutput;
    out.position = vec4f(x, y, 0.0, 1.0);

    let screen_uv = vec2f(x, -y) * 0.5 + 0.5;

    // Center the scale pivot to the screen center (camera and player viewport center). The zoom is
    // compressed so the background scales slower than the camera (parallax depth); see BG_ZOOM_PARALLAX.
    let bg_zoom = pow(max(scene.zoom, 1e-8), BG_ZOOM_PARALLAX); // reasonable min zoom
    out.screen_offset = ((screen_uv - 0.5) * scene.viewport_size) / bg_zoom;

    // Zig-zag wrapping for colors
    var t_wrap = (scene.time * 0.3) % 2.0;
    if t_wrap > 1.0 { t_wrap = 2.0 - t_wrap; }

    var t_wrap_2 = (3.0 + scene.time * 0.072) % 2.0;
    if t_wrap_2 > 1.0 { t_wrap_2 = 2.0 - t_wrap_2; }

    out.time = t_wrap;
    out.time2 = t_wrap_2;

    return out;
}

@fragment
fn fs_background(in: BackgroundOutput) -> @location(0) vec4f {
    const base_scale = 0.015625; // Exactly 1.0 / 64.0; see `BG_WRAP_CHUNKS` (chunk.zig) for the seamless-wrap contract
    let absolute_camera = scene.grid_origin.zw;
    let t = scene.time;

    // Scale down coordinates by 0.5 to make the background appear twice as large.
    let screen_offset_scaled = in.screen_offset * 0.5;
    let absolute_camera_scaled = absolute_camera * 0.5;

    // The farthest background layer (64x "slower")
    let st1 = (screen_offset_scaled + absolute_camera_scaled * 0.015625) * base_scale;
    let angle1 = (t / 600.0) * TAU; // 10-minute cycle!
    let drift1 = vec2f(cos(angle1), sin(angle1)) * 0.5;

    let q1 = noise(st1 * 0.45 + drift1);
    let f1 = noise(st1 * 0.85 + q1 * 1.5);

    let color1 = mix(
        vec3f(0.12, 0.22, 0.05),
        vec3f(0.12, 0.11, 0.03),
        f1
    );

    let layer1_intensity = clamp(f1 * f1 * 0.4, 0.1, 1.0);
    let layer1_rgb = layer1_intensity * color1;

    // Far background layer (32x "slower")
    let st2 = (screen_offset_scaled + absolute_camera_scaled * 0.03125) * base_scale;
    let angle2 = (t / 180.0) * TAU; // 3-minute cycle
    let drift2_x = vec2f(cos(angle2), sin(angle2)) * 1.0;
    let drift2_y = vec2f(sin(angle2), -cos(angle2)) * 0.8;

    var q2 = vec2f(0.0);
    q2.x = noise(st2 * 0.3 + drift2_x * 0.1);
    q2.y = noise(st2 * 0.3 + vec2f(1.0, 0.3) + drift2_y * 0.1);

    let f2 = fbm_3(st2 * 0.5 + 2.0 * q2);

    let mix_blue = mix(0.0, 0.4, in.time);
    let color2 = mix(
        vec3f(0.0, 0.005, mix_blue * mix_blue * 0.5),
        vec3f(0.05, 0.15, 0.25),
        clamp(f2 * f2 * 3.0, 0.0, 1.0)
    );
    let layer2_intensity = max(f2 * f2 * sqrt(f2) * 1.5 - 0.1, 0.0);
    let layer2_rgb = layer2_intensity * color2;

    // Middle background layer (8x "slower")
    let st3 = (screen_offset_scaled + absolute_camera_scaled * 0.125) * base_scale;
    let angle3 = (t / 60.0) * TAU; // only 60s
    let drift3_x = vec2f(cos(angle3), sin(angle3)) * 1.8;
    let drift3_y = vec2f(sin(angle3), -cos(angle3)) * 1.5;

    var q3 = vec2f(0.0);
    q3.x = noise(st3 * 0.6 + drift3_x * 0.2);
    q3.y = noise(st3 * 0.6 + vec2f(2.4, 1.1) + drift3_y * 0.2);

    var r3 = vec2f(0.0);
    r3.x = fbm_2(st3 * 1.8 + 3.0 * q3 + drift3_x);
    r3.y = fbm_2(st3 * 1.8 + 3.0 * q3 + drift3_y);

    let f3 = fbm_4(st3 * 1.2 + 2.5 * r3);

    let mix_red = mix(0.0, 0.3, in.time + in.time2);
    let mix_green = mix(0.0, 0.6, in.time2);
    let color3 = mix(
        vec3f(0.01, 0.05, 0.1),
        vec3f(mix_red * mix_red, mix_green * mix_green, 0.5),
        clamp(length(q3 * r3), 0.0, 1.0)
    );
    let layer3_intensity = max(f3 * f3 * f3 * 2.5 - 0.2, 0.0);
    let layer3_rgb = layer3_intensity * color3;

    // Additive screen blend of both seamless layers
    let final_rgb = layer1_rgb + layer2_rgb + layer3_rgb;

    let opacity = scene.chunk_opacity;
    return vec4f(final_rgb * opacity, opacity);
}

fn noise(st: vec2f) -> f32 {
    let i = vec2u(vec2i(floor(st)));
    let f = fract(st);

    // Make the grid noise perfectly periodic with a period of 32 units
    let ix = (i.x + vec4u(0u, 1u, 0u, 1u)) % vec4u(32u);
    let iy = (i.y + vec4u(0u, 0u, 1u, 1u)) % vec4u(32u);

    let h = hash_2d(ix, iy);

    // Quintic interpolation for smoother gradients
    let u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);

    return mix(
        mix(h.x, h.y, u.x), // Mix bottom
        mix(h.z, h.w, u.x), // Mix top
        u.y
    );
}

fn fbm_2(p: vec2f) -> f32 { // simple fractal brownian motion algorithm
    var v = 0.0;
    var a = 0.5;
    var shift = vec2f(100.0);
    var pos = p;
    for (var i = 0; i < 2; i++) {
        v += a * noise(pos);
        pos = pos * 2.0 + shift;
        a *= 0.5;
    }
    return v;
}

fn fbm_3(p: vec2f) -> f32 { // same as above but 3 iters
    var v = 0.0;
    var a = 0.5;
    var shift = vec2f(100.0);
    var pos = p;
    for (var i = 0; i < 3; i++) {
        v += a * noise(pos);
        pos = pos * 2.0 + shift;
        a *= 0.5;
    }
    return v;
}

fn fbm_4(p: vec2f) -> f32 { // same as above but 4 iters (wow, who could have guessed!)
    var v = 0.0;
    var a = 0.5;
    var shift = vec2f(100.0);
    var pos = p;
    for (var i = 0; i < 4; i++) {
        v += a * noise(pos);
        pos = pos * 2.0 + shift;
        a *= 0.5;
    }
    return v;
}

fn hash_2d(x: vec4u, y: vec4u) -> vec4f {
    var state = (x * 1597334673u) ^ (y * 3812015487u);

    // 32-bit permutation step, yippee!
    state = state * 747796405u + 2891336453u;
    let shift = (state >> vec4u(28u)) + vec4u(4u);
    let word = ((state >> shift) ^ state) * 277803737u;
    let result = (word >> vec4u(22u)) ^ word;

    // Direct bit-manipulation hack to convert to a float from [0, 1)
    return bitcast<vec4f>((result >> vec4u(9u)) | vec4u(0x3f800000u)) - 1.0;
}

/*
    ----
    ENTITIES
    ----
*/

struct WGSLEntity {
    lcha: vec4f,
    position: vec2f,
    size: vec2f,
    rotation: f32,
    id: u32,
    _pad: vec2u,
}

struct EntityOutput {
    @builtin(position) position: vec4f,
    @location(0) local_uv: vec2f,
    @location(1) @interpolate(flat) lcha: vec4f,
    @location(2) @interpolate(flat) id: u32,
    @location(3) @interpolate(flat) sprite_uv_origin: vec2f,
};

// Main vertex shader for generic entities (uses the mask).
@vertex
fn vs_entity(
    @builtin(vertex_index) vertex_index: u32,
    @builtin(instance_index) instance_index: u32
) -> EntityOutput {
    let entity = entities[instance_index];
    // presume ID 0 is unreasonable
    // var out: EntityOutput;
    // if entity.id == 0u {
    //     out.position = vec4f(2.0, 2.0, 2.0, 1.0); // ideal outcode
    // }

    // A bitmask where bits 1, 4, and 5 are set (0b110010 = 50) and bits 2, 3, and 5 are set (0b101100 = 44)
    let local_pos = vec2f((vec2u(50u, 44u) >> vec2u(vertex_index)) & vec2u(1u));
    let centered_pos = local_pos - 0.5f;

    // Rotate sprite as needed (in radians)
    let c = cos(entity.rotation);
    let s = sin(entity.rotation);
    let rotated_pos = vec2f(
        centered_pos.x * c - centered_pos.y * s,
        centered_pos.x * s + centered_pos.y * c
    );

    let pixel_pos = entity.position + rotated_pos * entity.size;

    // Convert to normalized device coords
    let ndc = pixel_pos * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0);

    // Calculate UV origin
    var origin = vec2f(
        f32(entity.id % TILES_PER_ROW_U),
        f32(entity.id / TILES_PER_ROW_U)
    ) * vec2f(SPRITE_W, SPRITE_H);

    var out: EntityOutput;
    out.position = vec4f(ndc, 0.0, 1.0);
    out.local_uv = local_pos;
    out.lcha = entity.lcha;
    out.id = entity.id;
    out.sprite_uv_origin = origin;
    return out;
}

@fragment
fn fs_entity(in: EntityOutput) -> @location(0) vec4f {
    // Calculate UVs with bleeding protection
    let safe_local_uv = clamp(in.local_uv, vec2f(TEXTURE_BLEEDING_EPSILON), vec2f(1.0 - TEXTURE_BLEEDING_EPSILON));
    let final_uv = in.sprite_uv_origin + safe_local_uv * vec2f(SPRITE_W, SPRITE_H);

    // Both the original sprite and the mask are sampled. The mask is pre-made: for many sprites it is white.
    // For gems, there's a special gem mask, and ores have a rounded rectangular mask with darkening.
    // This is multiplied with RGBA instead of OKLCH for simplicity.

    // in the future we can also make the sample of either change over time for some neat effects
    let raw_tex = textureSampleLevel(sprite_atlas, pixel_sampler, final_uv, 0.0);
    let raw_mask = textureSampleLevel(sprite_atlas_mask, pixel_sampler, final_uv, 0.0);

    // make raw mask stronger
    let tex_rgb = srgb_to_linear(raw_tex.rgb);
    let tex_a = raw_tex.a * raw_mask.a;
    // Early discard if the pixel is fully transparent (maybe)
    if tex_a <= 0.002 {
        discard;
    }
    var lab = linear_srgb_to_oklab(tex_rgb);
    var lch = oklab_to_oklch(lab);

    // Apply modifications from lcha (vec4f: L, C, H, A), see zig/render/entity.zig
    lch.x *= in.lcha.x; // mult light
    lch.y += in.lcha.y; // add chroma
    lch.z += in.lcha.z; // add hue

    lab = oklch_to_oklab(lch);

    // darken using the mask, after OKLCH transformations (non-linear)
    let final_rgb = oklab_to_linear_srgb(lab) * raw_mask.rrr;

    // apply alpha after being back to RGB!
    let final_a = tex_a * in.lcha.w;
    return vec4f(apply_color_management(final_rgb), final_a);
}

/*
    ----
    OKLAB AND COLOR SPACE
    (There are a lot of magic numbers here.)
    ----
*/
fn linear_srgb_to_oklab(c: vec3f) -> vec3f {
    let m1 = mat3x3f( // convert to LMS
        0.4122214708, 0.2119034982, 0.0883024619,
        0.5363325363, 0.6806995451, 0.2817188376,
        0.0514459929, 0.1073969566, 0.6299787005);
    let lms = max(m1 * c, vec3f(0.0));
    let lms_ = pow(lms, vec3f(1.0 / 3.0));

    let m2 = mat3x3f( // convert to OKLAB
        0.2104542553, 1.9779984951, 0.0259040371,
        0.7936177850, -2.4285922050, 0.7827717662,
        -0.0040720468, 0.4505937099, -0.8086758031);
    return m2 * lms_;
}

fn oklab_to_linear_srgb(c: vec3f) -> vec3f {
    let m1 = mat3x3f( // LMS
        1.0, 1.0, 1.0,
        0.3963377774, -0.1055613458, -0.0894841775,
        0.2158037573, -0.0638541728, -1.2914855480);
    let lms_ = m1 * c;
    let lms = lms_ * lms_ * lms_;

    let m2 = mat3x3f( // convert back to normal srgb
        4.0767416621, -1.2684380046, -0.0041960863,
        -3.3077115913, 2.6097574011, -0.7034186147,
        0.2309699292, -0.3413193965, 1.7076127010);
    let result = m2 * lms;
    return max(result, vec3f(0.0)); // prevent out of range values
}

fn oklab_to_oklch(lab: vec3f) -> vec3f {
    let chroma = length(lab.yz);
    var hue = 0.0;
    // prevent invalid numbers with this check
    if chroma > 0.0001 {
        hue = atan2(lab.z, lab.y);
    }
    return vec3f(lab.x, chroma, hue);
}

fn oklch_to_oklab(lch: vec3f) -> vec3f {
    let chroma = max(lch.y, 0.0);
    return vec3f(lch.x, chroma * cos(lch.z), chroma * sin(lch.z));
}

fn srgb_to_linear(c: vec3f) -> vec3f {
    return select(
        c / 12.92,
        pow((c + 0.055) / 1.055, vec3f(2.4)),
        c > vec3f(0.04045)
    );
}

fn linear_to_srgb(c: vec3f) -> vec3f {
    return select(
        12.92 * c,
        1.055 * pow(c, vec3f(1.0 / 2.4)) - 0.055,
        c > vec3f(0.0031308)
    );
}

fn linear_srgb_to_display_p3(rgb: vec3f) -> vec3f {
    let m = mat3x3f(
        0.822462, 0.033194, 0.017083,
        0.177538, 0.966806, 0.072397,
        0.000000, 0.000000, 0.910520
    );
    return max(m * rgb, vec3f(0.0));
}

// Change the final RGB value based on color space info.
fn apply_color_management(linear_rgb: vec3f) -> vec3f {
    var out = linear_rgb;
    // Convert color space while still linear
    if scene.flags.x == 1u { // isP3
        out = linear_srgb_to_display_p3(out);
    }
    return linear_to_srgb(out); // always apply transfer function
}
