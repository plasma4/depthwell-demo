/*
 * Main shader for the program.
 */
// Sprite sheet constants. Sprites are saved as a .png, and each asset is 16x16.
// Current sprites: [void, stone, stone2, yellowstone, stoneores, greenstone, pinkore, torch, torchwall, player]
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

fn linear_srgb_to_oklab(c: vec3f) -> vec3f {
    let l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
    let m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
    let s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;

    let l_ = pow(l, 1.0 / 3.0);
    let m_ = pow(m, 1.0 / 3.0);
    let s_ = pow(s, 1.0 / 3.0);

    return vec3f(
        0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086758031 * s_
    );
}

fn oklab_to_linear_srgb(c: vec3f) -> vec3f {
    let l_ = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
    let m_ = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
    let s_ = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;

    let l = l_ * l_ * l_;
    let m = m_ * m_ * m_;
    let s = s_ * s_ * s_;

    return vec3f(
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
       -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
       -0.0041960863 * l - 0.7034186147 * m + 1.7076127010 * s
    );
}


@group(0) @binding(0) var<uniform> scene: SceneUniforms;
@group(0) @binding(1) var<storage, read> tiles: array<TileData>;
@group(0) @binding(2) var sprite_atlas: texture_2d<f32>;
@group(0) @binding(3) var pixel_sampler: sampler;
@group(0) @binding(4) var<uniform> map_size: vec2u;

// Extracts the specific bit ranges defined in the Zig `packed struct(u64)`.
fn unpack_tile(data: TileData) -> UnpackedTile {
    var out: UnpackedTile;

    // Word 0: [0..19] id, [20..27] light, [28..31] hp
    out.sprite_id = extractBits(data.word0, 0u, 20u);
    let light_u = extractBits(data.word0, 20u, 8u);
    out.light = f32(light_u) / 255.0;
    out.hp = extractBits(data.word0, 28u, 4u);

    // Word 1: [0..23] seed, [24..31] edge_flags
    out.seed = extractBits(data.word1, 0u, 24u);
    out.edge_flags = extractBits(data.word1, 24u, 8u);

    return out;
}

// Data passed from the Vertex step (per-corner) to the Fragment step (per-pixel)
struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,

    // @interpolate(flat) tells the GPU NOT to blend these values between the 4 corners of the quad.
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
        out.position = vec4f(2.0, 2.0, 2.0, 1.0); // ideal outcode
        return out;
    }

    let world_pos = vec2f(f32(tile_x), f32(tile_y)) * TILE_SIZE + local_pos * TILE_SIZE;
    let screen_pos = (world_pos - scene.camera) * scene.zoom;

    // normalize
    let ndc = vec2f(
        (screen_pos.x / scene.viewport_size.x) * 2.0 - 1.0,
        1.0 - (screen_pos.y / scene.viewport_size.y) * 2.0
    );

    // Calculate which sprite in the atlas to sample
    let sprite_col = f32(tile.sprite_id % u32(TILES_PER_ROW));
    let sprite_row = f32(tile.sprite_id / u32(TILES_PER_ROW));

    // Prevent "texture bleeding"
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

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    var tex_color = textureSample(sprite_atlas, pixel_sampler, in.uv);
    if (scene.wireframe_opacity > 0.0) {
        // render wireframe due to being at the edge?
        let pixel_size_uv = 1.1 / (TILE_SIZE * scene.zoom);
        if (in.local_uv.x < pixel_size_uv || in.local_uv.x > 1.0 - pixel_size_uv ||
            in.local_uv.y < pixel_size_uv || in.local_uv.y > 1.0 - pixel_size_uv) {
            return vec4f(1.0, 0.0, 0.0, scene.wireframe_opacity);
        }
    }

    // too transparent?
    if (tex_color.a < 0.01) { discard; }

    // convert to oklab and nudge values with seed
    var lab = linear_srgb_to_oklab(tex_color.rgb);

    // we use 10 out of the 24 seed bits here
    let l_nudge = f32(extractBits(in.seed, 0u, 4u)) / 15.0;
    let a_nudge = f32(extractBits(in.seed, 4u, 3u)) / 7.0;
    let b_nudge = f32(extractBits(in.seed, 7u, 3u)) / 7.0;

    // shift lightness
    lab.x += (l_nudge - 0.5) * 0.1;
    // shift hue/chroma
    lab.y += (a_nudge - 0.5) * 0.04;
    lab.z += (b_nudge - 0.5) * 0.04;

    // add the edge darkening and base light value, giving the func 6 bits of seeding
    let darkening = calculate_edge_darkening(in.local_uv, in.edge_flags, in.seed);
    lab.x *= (1.0 - darkening) * in.light;

    let final_rgb = oklab_to_linear_srgb(lab);
    return vec4f(final_rgb, tex_color.a);
}

// Calculates edge darkening procedurally based on flags calculated in Zig.
fn calculate_edge_darkening(local_uv: vec2f, edge_flags: u32, seed: u32) -> f32 {
    var darkening = 0.0;
    let edge_width = 0.125 + (f32(extractBits(seed, 10u, 3u)) / 32.0);
    let edge_strength = 0.03 + f32(extractBits(seed, 13u, 3u)) / 50.0;

    // Curvy shadow gradient
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