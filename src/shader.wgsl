// Sprite saved below. Sprites are saved as a .png and each asset is 16.16
// Current sprites: [Stone, Torch, Player]

const TILE_SIZE: f32 = 16.0;
const ATLAS_TILE_SIZE: f32 = 16.0;
const TILES_PER_ROW: f32 = 3.0;
const TILES_PER_COLUMN: f32 = 1.0;
const ATLAS_WIDTH: f32 = TILE_SIZE * TILES_PER_ROW;
const ATLAS_HEIGHT: f32 = TILE_SIZE * TILES_PER_COLUMN;

// Edge flag bit positions (neighbors in reading order, skipping center)
// 0: top-left,    1: top,    2: top-right
// 3: left,                   4: right
// 5: bottom-left, 6: bottom, 7: bottom-right
const EDGE_TOP: u32         = 0x02u;
const EDGE_BOTTOM: u32      = 0x40u;
const EDGE_LEFT: u32        = 0x08u;
const EDGE_RIGHT: u32       = 0x10u;
const EDGE_TOP_LEFT: u32    = 0x01u;
const EDGE_TOP_RIGHT: u32   = 0x04u;
const EDGE_BOTTOM_LEFT: u32 = 0x20u;
const EDGE_BOTTOM_RIGHT: u32= 0x80u;

struct SceneUniforms {                     // offset  size
    camera: vec2f,                         //  0       8
    viewport_size: vec2f,                  //  8       8
    time: f32,                             // 16       4
    zoom: f32,                             // 20       4
    _padding: vec2f,                       // 24       8
};                                         // total:  32 bytes (aligned to 16)

// TODO these other features
// struct SceneUniforms {                     // offset  size
//     camera: vec2f,                         //  0       8
//     viewport_size: vec2f,                  //  8       8
//     time: f32,                             // 16       4
//     zoom: f32,                             // 20       4
//     player_offset: vec2f,                  // 24       8   (relative to camera)
//     zone_hue_shift: f32,                   // 32       4
//     zone_saturation: f32,                  // 36       4
//     ambient_light: f32,                    // 40       4
//     portal_zoom_progress: f32,             // 44       4   (0..1 animation)
//     depth_level: u32,                      // 48       4
//     flags: u32,                            // 52       4   (bitfield for toggles)
//     _padding: vec2f,                       // 56       8
// };                                         // total:  64 bytes (aligned to 16)

struct TileData {
    // Packed: spriteId (8) | edgeFlags (8) | light (8) | variation (8)
    packed: u32,
};

@group(0) @binding(0) var<uniform> scene: SceneUniforms;
@group(0) @binding(1) var<storage, read> tiles: array<TileData>;
@group(0) @binding(2) var sprite_atlas: texture_2d<f32>;
@group(0) @binding(3) var pixel_sampler: sampler;
@group(0) @binding(4) var<uniform> map_size: vec2u; // width, height in tiles

struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
    @location(1) @interpolate(flat) sprite_id: u32,
    @location(2) @interpolate(flat) edge_flags: u32,
    @location(3) @interpolate(flat) light: f32,
    @location(4) @interpolate(flat) variation: u32,
    @location(5) local_uv: vec2f, // 0-1 within tile for edge calculations
};

struct Particle {
    position: vec2f,
    d_position: vec2f,
    color: u32,       // Assumes ColorRGBA is a packed u32
    size: f32,
    rotation: f32,
    d_rotation: f32,
    time: i32,
    effect: u32,
};

@vertex
fn vs_main(
    @builtin(vertex_index) vertex_index: u32,
    @builtin(instance_index) instance_index: u32
) -> VertexOutput {
    // Quad vertices (two triangles)
    var positions = array<vec2f, 6>(
        vec2f(0.0, 0.0), vec2f(1.0, 0.0), vec2f(0.0, 1.0),
        vec2f(0.0, 1.0), vec2f(1.0, 0.0), vec2f(1.0, 1.0)
    );

    let local_pos = positions[vertex_index];

    // Calculate tile grid position from instance index
    let tile_x = instance_index % map_size.x;
    let tile_y = instance_index / map_size.x;

    // Unpack tile data
    let packed = tiles[instance_index].packed;
    let sprite_id = packed & 0xFFu;
    let edge_flags = (packed >> 8u) & 0xFFu;
    let light = f32((packed >> 16u) & 0xFFu) / 255.0;
    let variation = (packed >> 24u) & 0xFFu;

    // World position in pixels
    let world_pos = vec2f(f32(tile_x), f32(tile_y)) * TILE_SIZE + local_pos * TILE_SIZE;

    // Apply camera and zoom
    let screen_pos = (world_pos - scene.camera) * scene.zoom;

    // Convert to NDC (-1 to 1), Y flipped for typical screen coords
    let ndc = vec2f(
        (screen_pos.x / scene.viewport_size.x) * 2.0 - 1.0,
        1.0 - (screen_pos.y / scene.viewport_size.y) * 2.0
    );

    // Calculate UV in sprite atlas
    let sprite_col = f32(sprite_id % u32(TILES_PER_ROW));
    let sprite_row = f32(sprite_id / u32(TILES_PER_ROW));

    // Shrink quad slightly to keep UVs away from neighboring tiles
    let epsilon = 0.5 / ATLAS_WIDTH;
    let safe_local_pos = clamp(local_pos, vec2f(epsilon), vec2f(1.0 - epsilon));
    let atlas_uv = vec2f(
        (sprite_col + safe_local_pos.x) * ATLAS_TILE_SIZE / ATLAS_WIDTH,
        (sprite_row + safe_local_pos.y) * ATLAS_TILE_SIZE / ATLAS_HEIGHT
    );

    var out: VertexOutput;
    out.position = vec4f(ndc, 0.0, 1.0);
    out.uv = atlas_uv;
    out.sprite_id = sprite_id;
    out.edge_flags = edge_flags;
    out.light = light;
    out.variation = variation;
    out.local_uv = local_pos;
    return out;
}

// Simple hash for procedural variation
fn hash(n: u32) -> f32 {
    var x = n;
    x = ((x >> 16u) ^ x) * 0x45d9f3bu;
    x = ((x >> 16u) ^ x) * 0x45d9f3bu;
    x = (x >> 16u) ^ x;
    return f32(x) / f32(0xFFFFFFFFu);
}

fn calculate_edge_darkening(local_uv: vec2f, edge_flags: u32) -> f32 {
    var darkening = 0.0;
    let edge_width = 0.25; // How far into the tile the darkening extends
    let edge_strength = 0.4; // Maximum darkening amount

    // Check each edge and apply smooth darkening
    // Top edge
    if ((edge_flags & EDGE_TOP) != 0u) {
        darkening = max(darkening, (1.0 - smoothstep(0.0, edge_width, local_uv.y)) * edge_strength);
    }
    // Bottom edge
    if ((edge_flags & EDGE_BOTTOM) != 0u) {
        darkening = max(darkening, (1.0 - smoothstep(0.0, edge_width, 1.0 - local_uv.y)) * edge_strength);
    }
    // Left edge
    if ((edge_flags & EDGE_LEFT) != 0u) {
        darkening = max(darkening, (1.0 - smoothstep(0.0, edge_width, local_uv.x)) * edge_strength);
    }
    // Right edge
    if ((edge_flags & EDGE_RIGHT) != 0u) {
        darkening = max(darkening, (1.0 - smoothstep(0.0, edge_width, 1.0 - local_uv.x)) * edge_strength);
    }

    // Corner darkening (stronger when two edges meet)
    let corner_width = 0.15;

    if ((edge_flags & EDGE_TOP_LEFT) != 0u || ((edge_flags & EDGE_TOP) != 0u && (edge_flags & EDGE_LEFT) != 0u)) {
        let corner_dist = length(local_uv);
        darkening = max(darkening, (1.0 - smoothstep(0.0, corner_width * 1.414, corner_dist)) * edge_strength * 1.2);
    }
    if ((edge_flags & EDGE_TOP_RIGHT) != 0u || ((edge_flags & EDGE_TOP) != 0u && (edge_flags & EDGE_RIGHT) != 0u)) {
        let corner_dist = length(vec2f(1.0 - local_uv.x, local_uv.y));
        darkening = max(darkening, (1.0 - smoothstep(0.0, corner_width * 1.414, corner_dist)) * edge_strength * 1.2);
    }
    if ((edge_flags & EDGE_BOTTOM_LEFT) != 0u || ((edge_flags & EDGE_BOTTOM) != 0u && (edge_flags & EDGE_LEFT) != 0u)) {
        let corner_dist = length(vec2f(local_uv.x, 1.0 - local_uv.y));
        darkening = max(darkening, (1.0 - smoothstep(0.0, corner_width * 1.414, corner_dist)) * edge_strength * 1.2);
    }
    if ((edge_flags & EDGE_BOTTOM_RIGHT) != 0u || ((edge_flags & EDGE_BOTTOM) != 0u && (edge_flags & EDGE_RIGHT) != 0u)) {
        let corner_dist = length(1.0 - local_uv);
        darkening = max(darkening, (1.0 - smoothstep(0.0, corner_width * 1.414, corner_dist)) * edge_strength * 1.2);
    }

    return darkening;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    // Sample the sprite atlas with nearest-neighbor filtering
    var color = textureSample(sprite_atlas, pixel_sampler, in.uv);

    // Discard fully transparent pixels (for proper blending/depth)
    if (color.a < 0.01) {
        discard;
    }

    // Apply procedural variation (subtle color shift based on variation seed)
    let var_hash = hash(in.variation);
    let variation_tint = vec3f(
        1.0 + (var_hash - 0.5) * 0.1,
        1.0 + (hash(in.variation + 1u) - 0.5) * 0.1,
        1.0 + (hash(in.variation + 2u) - 0.5) * 0.1
    );
    color = vec4f(color.rgb * variation_tint, color.a);

    // Apply edge darkening
    if (in.sprite_id == 0) {
        color = vec4f(color.rgb * (1.0 - calculate_edge_darkening(in.local_uv, in.edge_flags)), color.a);
    }

    // Apply lighting
    // Light value is 0-1, where 0 is dark and 1 is fully lit
    // Using a non-linear curve for more natural falloff
    let light_factor = pow(in.light, 1.5);
    let ambient = 0.05; // Minimum visibility
    let final_light = ambient + light_factor * (1.0 - ambient);
    color = vec4f(color.rgb * final_light, color.a);

    // TODO maybe shimmer
    // if (in.sprite_id == WATER_SPRITE_ID) {
    //     let shimmer = sin(scene.time * 3.0 + in.local_uv.x * 10.0) * 0.05 + 0.05;
    //     color = vec4f(color.rgb + shimmer, color.a);
    // }

    return color;
}

// This would be in a separate pipeline for per-frame light updates
// @compute @workgroup_size(8, 8)
// fn propagate_light(@builtin(global_invocation_id) gid: vec3u) {
//     // Flood-fill style light propagation
//     // Read neighbor lights, compute max - falloff, write if higher
// }