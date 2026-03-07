/*
 * Main shader for the program.
 */
// Sprite sheet constants. Sprites are saved as a .png, and each asset is 16x16.
// Current sprites: [Stone, Torch, Player]
const TILES_PER_ROW: f32 = 10.0;
const TILES_PER_COLUMN: f32 = 1.0;


const TILE_SIZE: f32 = 16.0;
const ATLAS_TILE_SIZE: f32 = 16.0;
const ATLAS_WIDTH: f32 = TILE_SIZE * TILES_PER_ROW;
const ATLAS_HEIGHT: f32 = TILE_SIZE * TILES_PER_COLUMN;

// See EdgeFlags in zig/types.zig.
const EDGE_TOP: u32         = 0x02u;
const EDGE_BOTTOM: u32      = 0x40u;
const EDGE_LEFT: u32        = 0x08u;
const EDGE_RIGHT: u32       = 0x10u;
const EDGE_TOP_LEFT: u32    = 0x01u;
const EDGE_TOP_RIGHT: u32   = 0x04u;
const EDGE_BOTTOM_LEFT: u32 = 0x20u;
const EDGE_BOTTOM_RIGHT: u32= 0x80u;

// Uniforms are cached on the GPU. This is updated once per frame by Zig.
struct SceneUniforms {
    camera: vec2f,
    viewport_size: vec2f,
    time: f32,
    zoom: f32,
    wireframe_opacity: f32,
    _padding: f32,
};

struct TileData {
    word0: u32,
    word1: u32,
};

// Unpacked definition of tile (also see Block in zig/memory.zig)
struct UnpackedTile {
    sprite_id: u32,
    light: f32,
    hp: u32,
    seed: u32,
    edge_flags: u32,
};

@group(0) @binding(0) var<uniform> scene: SceneUniforms;
@group(0) @binding(1) var<storage, read> tiles: array<TileData>;
@group(0) @binding(2) var sprite_atlas: texture_2d<f32>;
@group(0) @binding(3) var pixel_sampler: sampler;
@group(0) @binding(4) var<uniform> map_size: vec2u;

// Extracts the specific bit ranges defined in the Zig `packed struct(u64)`.
fn unpack_tile(data: TileData) -> UnpackedTile {
    var out: UnpackedTile;

    // Word 0: [0..19] id, [20..27] light, [28..31] hp
    out.sprite_id = data.word0 & 0xFFFFFu;
    out.light = f32((data.word0 >> 20u) & 0xFFu) / 255.0; // Normalize 0-255 to 0.0-1.0
    out.hp = (data.word0 >> 28u) & 0xFu;

    // Word 1: [0..23] seed,[24..31] edge_flags
    out.seed = data.word1 & 0xFFFFFFu;
    out.edge_flags = (data.word1 >> 24u) & 0xFFu;

    return out;
}

// Data passed from the Vertex step (per-corner) to the Fragment step (per-pixel)
struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,

    // @interpolate(flat) tells the GPU NOT to blend these values between the 4 corners of the quad.
    // This is vital for performance and correctness when passing IDs.
    @location(1) @interpolate(flat) sprite_id: u32,
    @location(2) @interpolate(flat) edge_flags: u32,
    @location(3) @interpolate(flat) light: f32,
    @location(4) @interpolate(flat) seed: u32,

    // Local UV (0.0 to 1.0) across the surface of the specific tile.
    @location(5) local_uv: vec2f,
};

@vertex
fn vs_main(
    @builtin(vertex_index) vertex_index: u32,
    @builtin(instance_index) instance_index: u32
) -> VertexOutput {
    // Generate the 4 corners of a quad using binary arithmetic on the vertex index.
    // 0 -> (0,0), 1 -> (1,0), 2 -> (0,1), 3 -> (1,1)
    let local_pos = vec2f(
        f32(vertex_index & 1u),
        f32((vertex_index >> 1u) & 1u)
    );


    let tile_x = instance_index % map_size.x;
    let tile_y = instance_index / map_size.x;

    let tile = unpack_tile(tiles[instance_index]);

    // Cull empty sprite
    if (tile.sprite_id == 0u) {
        var out: VertexOutput;
        out.position = vec4f(0, 0, 0, 0);
        return out;
    }

    // Apply continuous float positioning and zooming.
    // This allows sub-pixel camera movement (smooth panning).
    let world_pos = vec2f(f32(tile_x), f32(tile_y)) * TILE_SIZE + local_pos * TILE_SIZE;
    let screen_pos = (world_pos - scene.camera) * scene.zoom;

    // Convert to Normalized Device Coordinates (-1.0 to 1.0 mapping for the viewport)
    let ndc = vec2f(
        (screen_pos.x / scene.viewport_size.x) * 2.0 - 1.0,
        1.0 - (screen_pos.y / scene.viewport_size.y) * 2.0
    );

    // Calculate which sprite in the atlas to sample
    let sprite_col = f32(tile.sprite_id % u32(TILES_PER_ROW));
    let sprite_row = f32(tile.sprite_id / u32(TILES_PER_ROW));

    // Epsilon shrinking prevents "texture bleeding" where the GPU accidentally samples
    // a pixel from the neighboring sprite in the atlas due to float precision errors.
    let epsilon = 0.5 / ATLAS_WIDTH;
    let safe_local_pos = clamp(local_pos, vec2f(epsilon), vec2f(1.0 - epsilon));

    let atlas_uv = vec2f(
        (sprite_col + safe_local_pos.x) * ATLAS_TILE_SIZE / ATLAS_WIDTH,
        (sprite_row + safe_local_pos.y) * ATLAS_TILE_SIZE / ATLAS_HEIGHT
    );

    var out: VertexOutput;
    out.position = vec4f(ndc, 0.0, 1.0);
    out.uv = atlas_uv;
    out.sprite_id = tile.sprite_id;
    out.edge_flags = tile.edge_flags;
    out.light = tile.light;
    out.seed = tile.seed;
    out.local_uv = local_pos;

    return out;
}

// A standard, fast integer hash function for procedural pixel generation.
fn hash(n: u32) -> f32 {
    var x = n;
    x = ((x >> 16u) ^ x) * 0x45d9f3bu;
    x = ((x >> 16u) ^ x) * 0x45d9f3bu;
    x = (x >> 16u) ^ x;
    return f32(x) * (1.0 / 4294967296.0); // Multiplication is faster than division
}

// Calculates edge darkening procedurally based on flags calculated in Zig.
fn calculate_edge_darkening(local_uv: vec2f, edge_flags: u32) -> f32 {
    var darkening = 0.0;
    let edge_width = 0.25;
    let edge_strength = 0.4;

    // Smoothstep creates a curved gradient for the shadows
    if ((edge_flags & EDGE_TOP) != 0u) {
        darkening = max(darkening, (1.0 - smoothstep(0.0, edge_width, local_uv.y)) * edge_strength);
    }
    if ((edge_flags & EDGE_BOTTOM) != 0u) {
        darkening = max(darkening, (1.0 - smoothstep(0.0, edge_width, 1.0 - local_uv.y)) * edge_strength);
    }
    if ((edge_flags & EDGE_LEFT) != 0u) {
        darkening = max(darkening, (1.0 - smoothstep(0.0, edge_width, local_uv.x)) * edge_strength);
    }
    if ((edge_flags & EDGE_RIGHT) != 0u) {
        darkening = max(darkening, (1.0 - smoothstep(0.0, edge_width, 1.0 - local_uv.x)) * edge_strength);
    }

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
    // textureSample is required here because sub-pixel camera movement
    // combined with a non-integer zoom scale means you cannot reliably use integer texel coordinates.
    var color = textureSample(sprite_atlas, pixel_sampler, in.uv);

    if (scene.wireframe_opacity > 0) {
        // Calculate the UV distance of exactly 1 physical screen pixel dynamically 
        // based on the tile size and the current continuous camera zoom
        let pixel_size_uv = 1.0 / (TILE_SIZE * scene.zoom);
        
        // If the coordinate is on the block's outer border, draw solid red
        if (in.local_uv.x < pixel_size_uv || in.local_uv.x > 1.0 - pixel_size_uv ||
            in.local_uv.y < pixel_size_uv || in.local_uv.y > 1.0 - pixel_size_uv) {
            return vec4f(1.0, 0.0, 0.0, scene.wireframe_opacity);
        }
    }

    // Discard blocks rendering execution on this pixel immediately.
    // Useful for non-square objects (like the player sprite or torches).
    if (color.a < 0.01) {
        discard;
    }

    // Procedural color variation to break up tiling artifacts.
    // Uses the isolated `seed` block parameter.
    let var_hash = hash(in.seed);
    let variation_tint = vec3f(
        1.0 + (var_hash - 0.5) * 0.1,
        1.0 + (hash(in.seed + 1u) - 0.5) * 0.1,
        1.0 + (hash(in.seed + 2u) - 0.5) * 0.1
    );
    color = vec4f(color.rgb * variation_tint, color.a);

    // Apply geometric edge darkening (ambient occlusion fake)
    // You should expand this ID check when you have more solid blocks than just ID 0.
    if (in.sprite_id == 0u) {
        color = vec4f(color.rgb * (1.0 - calculate_edge_darkening(in.local_uv, in.edge_flags)), color.a);
    }

    // Apply Lighting
    // Uses an exponential curve (pow 1.5) because human perception of light is non-linear.
    let light_factor = pow(in.light, 1.5);
    let ambient = 0.05;
    let final_light = ambient + light_factor * (1.0 - ambient);
    color = vec4f(color.rgb * final_light, color.a);

    return color;
}