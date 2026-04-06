(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const t of document.querySelectorAll('link[rel="modulepreload"]'))s(t);new MutationObserver(t=>{for(const i of t)if(i.type==="childList")for(const a of i.addedNodes)a.tagName==="LINK"&&a.rel==="modulepreload"&&s(a)}).observe(document,{childList:!0,subtree:!0});function n(t){const i={};return t.integrity&&(i.integrity=t.integrity),t.referrerPolicy&&(i.referrerPolicy=t.referrerPolicy),t.crossOrigin==="use-credentials"?i.credentials="include":t.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(t){if(t.ep)return;t.ep=!0;const i=n(t);fetch(t.href,i)}})();const o={zoom:131072,drop:262144,minus:32768,plus:65536,up:2048,left:4096,down:8192,right:16384,k0:1,k1:2,k2:4,k3:8,k4:16,k5:32,k6:64,k7:128,k8:256,k9:512},w={player_pos:0,last_player_pos:16,player_chunk:32,player_velocity:48,camera_pos:64,last_camera_pos:80,camera_scale:96,camera_scale_change:104,depth:112,player_quadrant:120,player_screen_offset:128,keys_pressed_mask:136,keys_held_mask:140,seed:144},R="abcdefghijklmnopqrstuvwxyz",y=26n;function M(r=100){if(r<=0)return"";const e=new Uint8Array(72);crypto.getRandomValues(e);let n=0n;const s=new DataView(e.buffer);for(let a=0;a<e.length;a+=8)n=n<<64n|s.getBigUint64(a);let t="",i=n%y**BigInt(r);for(;i>=0n&&(t+=R[Number(i%y)],i=i/y-1n,!(i<0n)););return t}function z(r){let e=0n;for(let n=0;n<r.length;n++){const s=BigInt(r.charCodeAt(n)-97);e=e*y+(s+1n)}return e}async function V(r,e){const n=z(r),s=new DataView(new ArrayBuffer(64));for(let c=0;c<8;c++)s.setBigUint64(c*8,n>>BigInt((7-c)*64)&0xffffffffffffffffn);let t=new Uint8Array(s.buffer,0,32),i=new Uint8Array(s.buffer,32,32);const a=await Promise.all([0,1,2,3].map(c=>crypto.subtle.importKey("raw",new Uint8Array([c]),{name:"HMAC",hash:"SHA-256"},!1,["sign"])));for(const c of a){const _=new Uint8Array(await crypto.subtle.sign("HMAC",c,i)),u=new Uint8Array(32);for(let h=0;h<32;h++)u[h]=t[h]^_[h];t=i,i=u}const d=new Uint8Array(64);return d.set(t,0),d.set(i,32),e.set(new BigUint64Array(d.buffer)),e}const A={Minus:o.minus,Equal:o.plus,KeyZ:o.zoom,KeyQ:o.drop,ArrowUp:o.up,KeyW:o.up,ArrowLeft:o.left,KeyA:o.left,ArrowDown:o.down,KeyS:o.down,ArrowRight:o.right,KeyD:o.right,Digit0:o.k0,Digit1:o.k1,Digit2:o.k2,Digit3:o.k3,Digit4:o.k4,Digit5:o.k5,Digit6:o.k6,Digit7:o.k7,Digit8:o.k8,Digit9:o.k9};function q(){let r={};const e={heldMask:0,keysHeld:0,keysPressed:0,currentlyHeld:0,horizontalPriority:0,verticalPriority:0,plusMinusPriority:0};function n(){r={},e.horizontalPriority=0,e.verticalPriority=0,e.plusMinusPriority=0,e.currentlyHeld=0,e.heldMask=0,e.keysPressed=0}return window.addEventListener("keydown",s=>{if(s.repeat)return;const t=A[s.code];t&&(e.heldMask|=t,r[t]=(r[t]||0)+1,t&(o.left|o.right)&&(e.horizontalPriority=t),t&(o.up|o.down)&&(e.verticalPriority=t),t&(o.plus|o.minus)&&(e.plusMinusPriority=t))}),window.addEventListener("keyup",s=>{const t=A[s.code];t&&(r[t]=Math.max(0,(r[t]||0)-1),r[t]===0&&(e.heldMask&=~t,t===e.horizontalPriority&&(e.horizontalPriority=e.heldMask&o.left||e.heldMask&o.right||0),t===e.verticalPriority&&(e.verticalPriority=e.heldMask&o.up||e.heldMask&o.down||0),t===e.plusMinusPriority&&(e.plusMinusPriority=e.heldMask&o.plus||e.heldMask&o.minus||0)))}),window.addEventListener("blur",n),document.addEventListener("visibilitychange",n),window.addEventListener("contextmenu",n),e}function N(r){const e=o.up|o.down|o.left|o.right;let n=r.heldMask&~e;n|=r.horizontalPriority,n|=r.verticalPriority,n|=r.plusMinusPriority,r.keysPressed=n&~r.keysHeld,r.currentlyHeld=n,r.keysHeld=n}const C=""+new URL("main-BXj27y9y.wasm",import.meta.url).href,H=`/*
 * Main shader for Depthwell. IMPORTANT: ADD ?raw FOR DEBUGGING SHADER TO THE END OF engineMaker.ts's SHADER_SOURCE VARIABLE.
 */
// Sprite sheet constants. Sprites are saved as a .png, and each asset is 16x16. See zig/world.zig's Sprite definitions for what these all are.
const TILES_PER_ROW: f32 = 15.0;
const TILES_PER_COLUMN: f32 = 1.0;

const TILE_SIZE: f32 = 16.0;
const PIXEL_UV_SIZE: f32 = 1.0 / TILE_SIZE;
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
    chunk_opacity: f32,
    player_screen_pos: vec2f,
    map_size: vec2u,
    _pad: vec2u,
    // _pad: vec2f, // Padding to ensure struct is 16-byte aligned
    // _extra_padding: array<vec4f, 13>, // Pad to 256 bytes for dynamic offsets
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
    seed2: u32,
    edge_flags: u32,
};

@group(0) @binding(0) var<uniform> scene: SceneUniforms;
@group(0) @binding(1) var<storage, read> tiles: array<TileData>;
@group(0) @binding(2) var sprite_atlas: texture_2d<f32>;
@group(0) @binding(3) var pixel_sampler: sampler;

// Data passed from the Vertex step (per-corner) to the Fragment step (per-pixel)
struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,

    // @interpolate(flat) tells the GPU NOT to blend these values between the 4 corners of the quad.
    @location(1) @interpolate(flat) sprite_id: u32,
    @location(2) @interpolate(flat) edge_flags: u32,
    @location(3) @interpolate(flat) light: f32,
    @location(4) @interpolate(flat) seed: u32, // these bits are used as efficently as possible
    @location(5) @interpolate(flat) seed2: u32, // murmurmix32'ed from seed

    // Local UV (0.0 to 1.0) across the surface of the specific tile.
    @location(6) local_uv: vec2f,
    // Where on the chunk a tile is
    @location(7) @interpolate(flat) tile_coords: vec2u,
};

// Extracts the specific bit ranges in Block (see zig/memory.zig).
fn unpack_tile(data: TileData) -> UnpackedTile {
    var out: UnpackedTile;

    out.sprite_id = extractBits(data.word0, 0u, 20u);
    out.hp = extractBits(data.word0, 20u, 4u);
    out.edge_flags = extractBits(data.word0, 24u, 8u);

    let light_u = extractBits(data.word1, 0u, 8u);
    out.light = f32(light_u) / 3000.0 + 1.0; // allow for (and expect) light > 1, no longer square-rooted

    // Contains light in the first 8 bytes and seed in the next 24, since all 32 bits are technically random we use murmurmix32 to mix these quite simply with decent results!
    out.seed = murmurmix32(data.word1);
    out.seed2 = murmurmix32(out.seed);

    if (out.sprite_id == 12 && (extractBits(out.seed, 16u, 2u) == 0)) { // extract bits 16-18 for random modifications
        out.sprite_id++; // 2 mushroom types
    }

    return out;
}

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

    let total_tiles = scene.map_size.x * scene.map_size.y;

    var out: VertexOutput;
    if (instance_index == total_tiles) {
        // There's intentionally one more instance than the number of tiles to render the player!
        let world_pos = scene.player_screen_pos + local_pos * TILE_SIZE;
        let screen_pos = (world_pos - scene.camera) * scene.zoom + (scene.viewport_size * 0.5);

        let ndc = vec2f(
            (screen_pos.x / scene.viewport_size.x) * 2.0 - 1.0,
            1.0 - (screen_pos.y / scene.viewport_size.y) * 2.0
        );

        // Prevent "texture bleeding"
        let epsilon = 0.5 / ATLAS_WIDTH;
        let safe_local_pos = clamp(local_pos, vec2f(epsilon), vec2f(1.0 - epsilon));

        let atlas_uv = vec2f(
            (1 + safe_local_pos.x) * TILE_SIZE / ATLAS_WIDTH,
            (0 + safe_local_pos.y) * TILE_SIZE / ATLAS_HEIGHT
        );

        out.position = vec4f(ndc, 0.1, 1.0);
        out.uv = atlas_uv;
        out.edge_flags = 255u;
        out.sprite_id = 1u;
        out.light = 255;
        out.local_uv = local_pos;
        return out;
    }

    let tile = unpack_tile(tiles[instance_index]);

    // Cull empty sprite
    if (tile.sprite_id == 0u && scene.wireframe_opacity == 0) {
        out.position = vec4f(2.0, 2.0, 1.0, 1.0); // ideal outcode
        return out;
    }

    let tile_x = instance_index % scene.map_size.x;
    let tile_y = instance_index / scene.map_size.x;
    let world_pixel_pos = vec2f(f32(tile_x), f32(tile_y)) * TILE_SIZE + local_pos * TILE_SIZE;

    // get offset from camera center in world pixels
    let offset_from_cam = world_pixel_pos - scene.camera;
    // scale that offset by zoom, then add the screen center
    let screen_pos = (offset_from_cam * scene.zoom) + (scene.viewport_size * 0.5);

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
        (sprite_col + safe_local_pos.x) * TILE_SIZE / ATLAS_WIDTH,
        (sprite_row + safe_local_pos.y) * TILE_SIZE / ATLAS_HEIGHT
    );

    out.position = vec4f(ndc, 0.2, 1.0);
    out.uv = atlas_uv;
    out.sprite_id = tile.sprite_id;
    out.edge_flags = tile.edge_flags;
    out.tile_coords = vec2u(tile_x, tile_y);
    out.light = tile.light;
    out.seed = tile.seed;
    out.seed2 = tile.seed2;
    out.local_uv = local_pos;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    var tex_color = textureSample(sprite_atlas, pixel_sampler, in.uv);

    var is_wireframe = false;
    var wire_color = vec4f(0.0);

    if (scene.wireframe_opacity > 0.0) {
        // render wireframe due to being at the edge of a block?
        let inv_tile_scale = 1.00001 / (TILE_SIZE * scene.zoom);
        let is_block_edge = any(in.local_uv < vec2f(inv_tile_scale)) || any(in.local_uv > vec2f(1.0 - inv_tile_scale));

        if (is_block_edge) {
            is_wireframe = true;
            let x_mod = in.tile_coords.x & 15u;
            let y_mod = in.tile_coords.y & 15u;

            if (in.sprite_id == 1u) {
                wire_color = vec4f(1.0, 0.5, 0.0, 1.0);
            } else {
                // Is this pixel on the edge of a CHUNK?
                let is_chunk_edge =
                    (x_mod == 0u && in.local_uv.x < inv_tile_scale) ||
                    (x_mod == 15u && in.local_uv.x > (1.0 - inv_tile_scale)) ||
                    (y_mod == 0u && in.local_uv.y < inv_tile_scale) ||
                    (y_mod == 15u && in.local_uv.y > (1.0 - inv_tile_scale));

                if (is_chunk_edge) {
                    wire_color = vec4f(1.0, 1.0, 0.0, min(1, scene.wireframe_opacity * 2.5));
                } else {
                    // wire_color = vec4f(1.0, 0.0, 0.0, scene.wireframe_opacity);

                    // neat-lookin' fancy wireframe coloring
                    let r = f32(x_mod) * 0.0625;
                    let g = f32(y_mod) * 0.0625;
                    let b = 0.5 + f32(x_mod ^ y_mod) * 0.03125;
                    wire_color = vec4f(r, g, b, scene.wireframe_opacity);
                }
            }
        }
    }

    // too transparent? exit early
    if (tex_color.a < 0.005 && !is_wireframe) { discard; }


    // convert to oklab and nudge values with seed
    var lab = linear_srgb_to_oklab(tex_color.rgb);
    var lch = oklab_to_oklch(lab);

    // we use 10 out of the 24 seed bits here
    let extracted_l = f32(extractBits(in.seed, 0u, 4u));
    let extracted_a = f32(extractBits(in.seed, 4u, 3u));
    let l_nudge = extracted_l / 15.0;
    let a_nudge = extracted_a / 7.0;
    let b_nudge = f32(extractBits(in.seed, 7u, 3u)) / 7.0;

    lch.x += (l_nudge - 0.5) * 0.1; // shift lightness (0-1)
    lch.y += a_nudge * 0.01; // shift chroma, which acts similar to saturation (0-1)
    lch.z += (b_nudge - 0.5) * 0.15; // shift hue (in RADIANS)


    var final_rgb = vec3f(0.0);

    // TODO fix this genuinely terrible branching
    if (in.edge_flags != 0xFF) {
        let erode_mask = erosion(in.local_uv, in.edge_flags, in.seed2);
        if (erode_mask == 0u) {
            discard;
        } else {
            // add the edge darkening and base light value, with the function using bits 10-16
            let darkening = calculate_edge_darkening(in.local_uv, in.edge_flags, in.seed);
            lch.x = min(1.0, lch.x * (1.0 - darkening) * in.light);

            if (erode_mask == 2u) {
                lch.x *= 0.6 + extracted_l * 0.01; // lower lightness significantly
                lch.y *= 1.3 + extracted_a * 0.04; // increase chroma
            }
        }
    }
    lab = oklch_to_oklab(lch);
    final_rgb = max(oklab_to_linear_srgb(lab), vec3f(0.0));
    var final_a = tex_color.a * select(scene.chunk_opacity, 1.0, in.sprite_id == 1u); // use chunk_opacity, unless this sprite is for the player

    if (is_wireframe) {
        // Correctly mix the wireframe dynamically depending on whether the block exists below it.
        if (final_a > 0.005) {
            final_rgb = mix(final_rgb, wire_color.rgb, wire_color.a);
            final_a = max(final_a, wire_color.a);
        } else {
            final_rgb = wire_color.rgb;
            final_a = wire_color.a;
        }
    }

    return vec4f(final_rgb, final_a);
}

// Bijective mixer, given 32 bits of data
fn murmurmix32(number: u32) -> u32 {
    var h = number;
    h ^= h >> 16;
    h *= 0x85ebca6b;
    h ^= h >> 13;
    h *= 0xc2b2ae35;
    h ^= h >> 16;
    return h;
}

// Complex logic that returns 0u if a pixel should be TRANSPARENT ("eroded"), NORMAL, or BORDER (darkened).
fn erosion(local_uv: vec2f, edge_flags: u32, seed2: u32) -> u32 {
    let px = u32(local_uv.x * TILE_SIZE);
    let py = u32(local_uv.y * TILE_SIZE);

    let se = seed2;
    let sc = murmurmix32(seed2);

    let has_top    = (edge_flags & EDGE_TOP) != 0u;
    let has_bottom = (edge_flags & EDGE_BOTTOM) != 0u;
    let has_left   = (edge_flags & EDGE_LEFT) != 0u;
    let has_right  = (edge_flags & EDGE_RIGHT) != 0u;
    let has_tl     = (edge_flags & EDGE_TOP_LEFT) != 0u;
    let has_tr     = (edge_flags & EDGE_TOP_RIGHT) != 0u;
    let has_bl     = (edge_flags & EDGE_BOTTOM_LEFT) != 0u;
    let has_br     = (edge_flags & EDGE_BOTTOM_RIGHT) != 0u;

    // Precompute outer corner radii from sc (used by both corner arcs and straight-edge safe zones)
    let r_tl = 2u + extractBits(sc, 0u, 1u);  // top-left: 2 or 3
    let r_tr = 4u + extractBits(sc, 2u, 1u);  // top-right: 4 or 5
    let r_bl = 4u + extractBits(sc, 4u, 1u);  // bottom-left: 4 or 5
    let r_br = 4u + extractBits(sc, 6u, 1u);  // bottom-right: 4 or 5

    // The "center" of the circle is at the corner! Do some pixel-perfect circle edge logic.

    // Top-left outer corner (top AND left both missing)
    if (!has_top && !has_left) {
        let r_sq = r_tl * r_tl;
        let dx = r_tl - px;
        let dy = r_tl - py;
        if (px < r_tl && py < r_tl) {
            let dist_sq = dx * dx + dy * dy;
            if (dist_sq > r_sq) { return 0u; }
            if (dist_sq > r_sq - r_tl) { return 2u; } // darken ring of 1 pixel
        }
    }

    // Top-right outer corner
    if (!has_top && !has_right) {
        let r_sq = r_tr * r_tr;
        let fpx = 15u - px; // flip x
        if (fpx < r_tr && py < r_tr) {
            let dx = r_tr - fpx;
            let dy = r_tr - py;
            let dist_sq = dx * dx + dy * dy;
            if (dist_sq > r_sq) { return 0u; }
            if (dist_sq > r_sq - r_tr) { return 2u; }
        }
    }

    // Bottom-left outer corner
    if (!has_bottom && !has_left) {
        let r_sq = r_bl * r_bl;
        let fpy = 15u - py;
        if (px < r_bl && fpy < r_bl) {
            let dx = r_bl - px;
            let dy = r_bl - fpy;
            let dist_sq = dx * dx + dy * dy;
            if (dist_sq > r_sq) { return 0u; }
            if (dist_sq > r_sq - r_bl) { return 2u; }
        }
    }

    // Bottom-right outer corner
    if (!has_bottom && !has_right) {
        let r_sq = r_br * r_br;
        let fpx = 15u - px;
        let fpy = 15u - py;
        if (fpx < r_br && fpy < r_br) {
            let dx = r_br - fpx;
            let dy = r_br - fpy;
            let dist_sq = dx * dx + dy * dy;
            if (dist_sq > r_sq) { return 0u; }
            if (dist_sq > r_sq - r_br) { return 2u; }
        }
    }

    // Straight edges (8 bits each from se: bits 0-7 top, 8-15 bottom, 16-23 left, 24-31 right)

    // Top edge
    if (!has_top) {
        let base_depth = 1u + extractBits(se, 0u, 1u);
        let notch_pos = extractBits(se, 1u, 4u);
        let notch_dir = extractBits(se, 5u, 1u);
        let notch_width = 2u + extractBits(se, 6u, 2u);

        var depth = base_depth;
        if (px >= notch_pos && px < notch_pos + notch_width) {
            if (notch_dir == 0u) { depth += 1u; } else { depth = max(depth, 1u) - 1u; }
        }

        // Only apply straight edge outside the corner rounding zones
        let left_safe = select(0u, r_tl, !has_left);
        let right_safe = select(16u, 16u - r_tr, !has_right);

        if (px >= left_safe && px < right_safe) {
            if (py < depth) { return 0u; }
            if (py == depth) { return 2u; }
        }
    }

    // Bottom edge
    if (!has_bottom) {
        let base_depth = 1u + extractBits(se, 8u, 1u);
        let notch_pos = extractBits(se, 9u, 4u);
        let notch_dir = extractBits(se, 13u, 1u);
        let notch_width = 2u + extractBits(se, 14u, 2u);

        var depth = base_depth;
        if (px >= notch_pos && px < notch_pos + notch_width) {
            if (notch_dir == 0u) { depth += 1u; } else { depth = max(depth, 1u) - 1u; }
        }

        let left_safe = select(0u, r_bl, !has_left);
        let right_safe = select(16u, 16u - r_br, !has_right);

        if (px >= left_safe && px < right_safe) {
            if (py > 15u - depth) { return 0u; }
            if (py == 15u - depth) { return 2u; }
        }
    }

    // Left edge
    if (!has_left) {
        let base_depth = 1u + extractBits(se, 16u, 1u);
        let notch_pos = extractBits(se, 17u, 4u);
        let notch_dir = extractBits(se, 21u, 1u);
        let notch_width = 2u + extractBits(se, 22u, 2u);

        var depth = base_depth;
        if (py >= notch_pos && py < notch_pos + notch_width) {
            if (notch_dir == 0u) { depth += 1u; } else { depth = max(depth, 1u) - 1u; }
        }

        let top_safe = select(0u, r_tl, !has_top);
        let bottom_safe = select(16u, 16u - r_bl, !has_bottom);

        if (py >= top_safe && py < bottom_safe) {
            if (px < depth) { return 0u; }
            if (px == depth) { return 2u; }
        }
    }

    // Right edge
    if (!has_right) {
        let base_depth = 1u + extractBits(se, 24u, 1u);
        let notch_pos = extractBits(se, 25u, 4u);
        let notch_dir = extractBits(se, 29u, 1u);
        let notch_width = 2u + extractBits(se, 30u, 2u);

        var depth = base_depth;
        if (py >= notch_pos && py < notch_pos + notch_width) {
            if (notch_dir == 0u) { depth += 1u; } else { depth = max(depth, 1u) - 1u; }
        }

        let top_safe = select(0u, r_tr, !has_top);
        let bottom_safe = select(16u, 16u - r_br, !has_bottom);

        if (py >= top_safe && py < bottom_safe) {
            if (px > 15u - depth) { return 0u; }
            if (px == 15u - depth) { return 2u; }
        }
    }

    // Inner corners (no diagonal neighbor)

    if (!has_tl && has_top && has_left) {
        let r = 2u + extractBits(sc, 8u, 1u); // 2 or 3
        if (px < r && py < r) {
            let dx = px + 1u; // +1 so the circle center is at (-0.5, -0.5) effectively
            let dy = py + 1u;
            let dist_sq = dx * dx + dy * dy;
            if (dist_sq <= r * r) { return 0u; }
            if (dist_sq <= (r + 1u) * (r + 1u)) { return 2u; }
        }
    }

    if (!has_tr && has_top && has_right) {
        let r = 2u + extractBits(sc, 10u, 1u);
        let fpx = 15u - px;
        if (fpx < r && py < r) {
            let dx = fpx + 1u;
            let dy = py + 1u;
            let dist_sq = dx * dx + dy * dy;
            if (dist_sq <= r * r) { return 0u; }
            if (dist_sq <= (r + 1u) * (r + 1u)) { return 2u; }
        }
    }

    if (!has_bl && has_bottom && has_left) {
        let r = 2u + extractBits(sc, 12u, 1u);
        let fpy = 15u - py;
        if (px < r && fpy < r) {
            let dx = px + 1u;
            let dy = fpy + 1u;
            let dist_sq = dx * dx + dy * dy;
            if (dist_sq <= r * r) { return 0u; }
            if (dist_sq <= (r + 1u) * (r + 1u)) { return 2u; }
        }
    }

    if (!has_br && has_bottom && has_right) {
        let r = 2u + extractBits(sc, 14u, 1u);
        let fpx = 15u - px;
        let fpy = 15u - py;
        if (fpx < r && fpy < r) {
            let dx = fpx + 1u;
            let dy = fpy + 1u;
            let dist_sq = dx * dx + dy * dy;
            if (dist_sq <= r * r) { return 0u; }
            if (dist_sq <= (r + 1u) * (r + 1u)) { return 2u; }
        }
    }

    return 1u;
}

// Number of 1 bits in a u8 (possibly useful for edge flags, currently unused)
fn popcount8(v: u32) -> u32 {
    var n = v;
    n = n - ((n >> 1u) & 0x55u);
    n = (n & 0x33u) + ((n >> 2u) & 0x33u);
    return ((n + (n >> 4u)) & 0x0Fu);
}

// Calculates edge darkening procedurally based on flags calculated in Zig.
fn calculate_edge_darkening(local_uv: vec2f, edge_flags: u32, seed: u32) -> f32 {
    var darkening = 0.0;
    let edge_width = 0.20 + f32(extractBits(seed, 10u, 3u)) / 32.0;
    let edge_strength = 0.2 + f32(extractBits(seed, 13u, 3u)) / 48.0;
    let corner_width = 0.3;

    // Curvy shadow gradient
    if ((edge_flags & EDGE_TOP) == 0u) {
        darkening = max(darkening, (1.0 - smoothstep(0.0, edge_width, local_uv.y)) * edge_strength);
    }
    if ((edge_flags & EDGE_BOTTOM) == 0u) {
        darkening = max(darkening, (1.0 - smoothstep(0.0, edge_width, 1.0 - local_uv.y)) * edge_strength);
    }
    if ((edge_flags & EDGE_LEFT) == 0u) {
        darkening = max(darkening, (1.0 - smoothstep(0.0, edge_width, local_uv.x)) * edge_strength);
    }
    if ((edge_flags & EDGE_RIGHT) == 0u) {
        darkening = max(darkening, (1.0 - smoothstep(0.0, edge_width, 1.0 - local_uv.x)) * edge_strength);
    }

    if ((edge_flags & EDGE_TOP_LEFT) == 0u || ((edge_flags & EDGE_TOP) == 0u && (edge_flags & EDGE_LEFT) == 0u)) {
        let corner_dist = length(local_uv);
        darkening = max(darkening, (1.0 - smoothstep(0.0, corner_width * 1.414, corner_dist)) * edge_strength * 1.2);
    }
    if ((edge_flags & EDGE_TOP_RIGHT) == 0u || ((edge_flags & EDGE_TOP) == 0u && (edge_flags & EDGE_RIGHT) == 0u)) {
        let corner_dist = length(vec2f(1.0 - local_uv.x, local_uv.y));
        darkening = max(darkening, (1.0 - smoothstep(0.0, corner_width * 1.414, corner_dist)) * edge_strength * 1.2);
    }
    if ((edge_flags & EDGE_BOTTOM_LEFT) == 0u || ((edge_flags & EDGE_BOTTOM) == 0u && (edge_flags & EDGE_LEFT) == 0u)) {
        let corner_dist = length(vec2f(local_uv.x, 1.0 - local_uv.y));
        darkening = max(darkening, (1.0 - smoothstep(0.0, corner_width * 1.414, corner_dist)) * edge_strength * 1.2);
    }
    if ((edge_flags & EDGE_BOTTOM_RIGHT) == 0u || ((edge_flags & EDGE_BOTTOM) == 0u && (edge_flags & EDGE_RIGHT) == 0u)) {
        let corner_dist = length(1.0 - local_uv);
        darkening = max(darkening, (1.0 - smoothstep(0.0, corner_width * 1.414, corner_dist)) * edge_strength * 1.2);
    }

    return darkening;
}



// FBM background logic
struct BackgroundOutput {
    @builtin(position) position: vec4f,
    @location(0) world_uv: vec2f,
    @location(1) time: f32,
    @location(2) time2: f32,
};

@vertex
fn vs_background(@builtin(vertex_index) vertex_index: u32) -> BackgroundOutput {
    let x = f32(i32(vertex_index & 1u) << 2u) - 1.0;
    let y = f32(i32(vertex_index & 2u) << 1u) - 1.0;

    var out: BackgroundOutput;
    out.position = vec4f(x, y, 1.0, 1.0);

    let screen_uv = vec2f(x, -y) * 0.5 + 0.5; // update data for frag shader
    out.world_uv = (screen_uv * scene.viewport_size) / scene.zoom + scene.camera;
    let time_ms = scene.time;
    let t = time_ms / 128.0;

    // Zig-zag wrapping for colors
    var t_wrap = (t / 30.0) % 2.0;
    if (t_wrap > 1.0) { t_wrap = 2.0 - t_wrap; }
    var t_wrap_2 = (8.0 + t / 95.0) % 20.0;
    if (t_wrap_2 > 1.0) { t_wrap_2 = 2.0 - t_wrap_2; }
    out.time = t_wrap;
    out.time2 = t_wrap_2;

    return out;
}

@fragment
fn fs_background(in: BackgroundOutput) -> @location(0) vec4f {
    let parallax_offset = scene.camera * 0.02;
    let st = (in.world_uv + parallax_offset) * 0.015;
    let t = scene.time / 1000.0;
    // FBM domain warping
    var q = vec2f(0.0);
    q.x = fbm(st);
    q.y = fbm(st + vec2f(1.0));

    var r = vec2f(0.0);
    r.x = fbm(st + 1.0 * q + vec2f(1.7, 9.2) + 0.15 * t);
    r.y = fbm(st + 1.0 * q + vec2f(8.3, 2.8) + 0.126 * t);

    let f = fbm(st + r);

    var color = mix( // mix in colors
        vec3f(0.1, 0.6, mix(0.0, 0.94, in.time)),
        vec3f(0.6, 0.7, 0.8),
        clamp((f * f) * 4.0, 0.0, 1.0)
    );

    color = mix(
        color,
        vec3f(mix(0.0, 0.8, in.time2), mix(0.0, 0.4, in.time), 0.85),
        clamp(length(q), 0.0, 1.0)
    );

    color = mix(
        color,
        vec3f(0.6, 1.0, 1.0),
        clamp(abs(r.x), 0.0, 1.0)
    );

    let intensity = f * f * f + 0.6 * f * f + 0.5 * f;
    let final_rgb = intensity * color;

    let opacity = 0.3 * scene.chunk_opacity;
    return vec4f(final_rgb * opacity, opacity);
}

const NUM_OCTAVES = 4u;
fn fbm(st: vec2f) -> f32 {
    var v = 0.0;
    var a = 0.5;
    var p = st;
    for (var i = 0u; i < NUM_OCTAVES; i++) {
        v += a * noise(p);
        p = p * 2.0 + 100.0;
        a *= 0.5;
    }
    return v;
}

fn noise(st: vec2f) -> f32 {
    let i = floor(st);
    let f = fract(st);

    // Four corners in 2D of a tile
    let a = rand2d_pcg(i);
    let b = rand2d_pcg(i + vec2f(1.0, 0.0));
    let c = rand2d_pcg(i + vec2f(0.0, 1.0));
    let d = rand2d_pcg(i + vec2f(1.0, 1.0));

    let u = f * f * (3.0 - 2.0 * f);

    // Standard bilinear interpolation
    return mix(
        mix(a, b, u.x),
        mix(c, d, u.x),
        u.y
    );
}

fn rand2d_pcg(v: vec2f) -> f32 { // TODO see if better ones exist
    var v_u = bitcast<vec2u>(v);
    // Mix the two inputs into a single state
    var state = v_u.x * 1664525u + v_u.y;

    state = state * 747796405u + 2891336453u; // standard PCG
    var word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    let result = (word >> 22u) ^ word;

    // Mantissa trick
    return bitcast<f32>((result >> 9u) | 0x3f800000u) - 1.0;
}


// OKLAB stuff
fn linear_srgb_to_oklab(c: vec3f) -> vec3f {
    let m1 = mat3x3f( // convert to LMS
        0.4122214708, 0.2119034982, 0.0883024619,
        0.5363325363, 0.6806995451, 0.2817188376,
        0.0514459929, 0.1073969566, 0.6299787005
    );
    let lms = max(m1 * c, vec3f(0.0));
    let lms_ = pow(lms, vec3f(1.0 / 3.0));

    let m2 = mat3x3f( // convert to OKLAB
        0.2104542553, 1.9779984951, 0.0259040371,
        0.7936177850, -2.4285922050, 0.7827717662,
        -0.0040720468, 0.4505937099, -0.8086758031
    );
    return m2 * lms_;
}

fn oklab_to_linear_srgb(c: vec3f) -> vec3f {
    let m1 = mat3x3f( // LMS again
        1.0, 1.0, 1.0,
        0.3963377774, -0.1055613458, -0.0894841775,
        0.2158037573, -0.0638541728, -1.2914855480
    );
    let lms_ = m1 * c;
    let lms = lms_ * lms_ * lms_;

    let m2 = mat3x3f( // convert back to normal srgb
        4.0767416621, -1.2684380046, -0.0041960863,
        -3.3077115913, 2.6097574011, -0.7034186147,
        0.2309699292, -0.3413193965, 1.7076127010
    );
    return m2 * lms;
}

fn oklab_to_oklch(lab: vec3f) -> vec3f {
    let chroma = length(lab.yz);
    let hue = atan2(lab.z, lab.y);
    return vec3f(lab.x, chroma, hue);
}

fn oklch_to_oklab(lch: vec3f) -> vec3f {
    return vec3f(lch.x, lch.y * cos(lch.z), lch.y * sin(lch.z));
}
`,F="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAPAAAAAQCAMAAAAfzwIiAAAAAXNSR0IArs4c6QAAASBQTFRFbOPjUsC6f8rLTKuFCAkKAAAAsrKyW1tbRkZGAAAAAAAAAAAAncj8f7DgZY29W3ShL1dgAAAAqduMRqlWP4pXMnpcN3BhFUs95NzWzaWGjGVQb29vPC0tSj8z29vbtLe5kZifbn2CU15oP0hJUnGsQWGfOkh4LUN1GTVOICws9/LQ9d+Z4MBMoYQfW0QdSTUtw//rkvLQUOW3EMaBJJxsBEYtcvG0L+R/LKQba7tr/6PBzjU12bXbt4q732HBLKQbK06VJ4nNeGTGnIvbiqH2ydT9kFK8Qr/oSUGCRXLjAAAAAAAAEl83HZc5HkxKO4+QWaOlWMCXisevLWOGI61tIrIrAAAAAAAAAAAA0EIz95Ag98ggd0IaqmIqdzwOmlgl5GWlnwAAAGB0Uk5TAP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////quH28VkbNAAABbNJREFUSIm1l2tz2zYWhpnak80HieLwAhIgSFwIEiQBkBIlO6qbZpp2d9udSXbTbvuhbdr+/3/ROZSvSpzUbXNGQ0m2P+Dxed9zXnjeB+v0VnleEATLYOUH/mIZrIIgSJMEoSRMkziKUJiGtChwnuMsJ0VBaE65kJwxKZjgXArJB2tMP4zW2sHZwdi2063umka3XadUXb/7DE/PP737g88///DB/2Sd3ikPaAF15fvLYLFchmmaxlGYxlEUoigMKSUkx1mG8ywr8qKQkpVccMkFL6WUwgGxG+E5GGuHWmutVVM3jdaNUu8G3nvnd74/e36xv3j+cXkfX77P/fXhuQp8319GYZokcZQmcRyhOIqyjBJCMM4xzjJKc15yJivGpeRCSFG50Q7WOWfsaHozDHWrtKpV17Zto7VS7z7F/g7ws2cX3t67ePZRgef6x+lp4AOwHyyC+d2P4jRBKAbqGMVxhLMsJxiTIsM4pwRLzpkQnHNRSc5L4ew4DqNxwzgaY6yrtVa6bVTXtS30+p5jnO9v8T6/gKZ/JOJLzuuC9oKPAXq18oM4ilEczsTQ5RjjnBSEFJhimlNChBSi4pIzUZZClGXfO2vdaJ0dnbFDX9dN2zW6UTU0WTf3AXs3JgYt7+Ef8Df6+OTk5OQG+LKezMCrYOEvD7qGqZUmKIrDEMUIoSRJU+guLmhGc5rjghLOq0pUQnLJGPjZmN4569zorLGDNbpRXd01TQNN1s19wE+Phtb+nr+7r3786f28n3zy6NHJbeArC58GBynD3II57YcpiqDSKEQojUKaE0IpzjKSY1JQCrwMBM0YLxnjtjdusHYcnbN2sFY1taq7TmsgbrS+PMG0vcv39OiEDwX+6ecPAD86Ar6uWcoAHCwDwIaZFSVxmMKUjqMopyQH7+KiAGlTISrBWckqwUpeCm6sdc701o3jODhnlVazf1vdqrarW2/abidv2qxvE++9I+D9/oHEb375w8CP7wKvVrCTFn7gw2sZRAkQx8AboySOiqKABpM8LyjNSSE4ryQrWVlxJhiTdhh6WMVmGJ3pB6frRteq67pWt03X6Wm92UzbzWazu0N83OHPHsbr/frr+4Ef3enwNfPj09PVvIdnXQcrfxEkCUqTKE3jOEYQP2heEJxjWuC8KGhOGZei5Aw2kpSCSWd7Y5wxw2gN+LnVqtFK1TCim7Zpobfradqs19vdzYHOnz5Uw8fAbx4CfL2TwMOzg5fzhIYBhhBCKRj4kD/SPIPZTMDKQEw452XJhGCVqCopuOmtNf1gYFZb4wwANwq2cdvprm297bTdnW03m/X2NrH3F4l/+xPAh1oe1i+spkUQ+D4KQwTJIwQ9h2FIcJaDlMHHRZYRxkU5Q5dVJcpSgn+NGZyxDua01XUNOUsDL8RL79Di7W53tpu217L+9FjTDwX+sKSndwE/OT1s38BfLpeLYBH4CQyrJImiCGJHhAqSERA0pTQvclxwwRirOCvlPLzKmdK6wUHqsM6qWinVNU1bt03b1Opg3820nnaznQ8HOj9eS2/Xiy+/uvr46n+vj3/75mHAT258PDd3sQxmXft+AKywg2OE5nQJSZoWkLeKAmc55hVnFZO8kpUQvOSzloceJvRgxsEppXTX1RA8VNNpfWnf3TSt515fnuj48vAW6hcv/vmvfx++v3z17Xf/P8J+v6IBeJreTh5weYCL0ryHAwgefgBKnhU9izpOs5xA1AJiSnBGBJNVKQWYuOKcMQfddabvx3HeTLrWXds0bdupGpbTlX03u7Oz7XZ3ZePz48V0UwfUL7558dV/LoH/++r1997L199+91aj7ye+TlrH18PVanUVplcQtZIEIjRCSRSGCCUpgWshEGNCKMaYC8nKkrOSSwlDaxhg+47GWDOMpu81TCpIHPMarrtL+65303S2uZnU5+/z8Ne3nnP9cOt5VL8DBHXwUVC0Y2sAAAAASUVORK5CYII=";async function K(r,e){const n={highPerformance:!1,...e},s=await navigator.gpu.requestAdapter({powerPreference:n.highPerformance?"high-performance":"low-power"});if(!s)throw new DOMException("Couldn't request WebGPU adapter.","NotSupportedError");const t=await s.requestDevice();let i=null;if(t.addEventListener("uncapturederror",f=>{const g=f.error;if(i===null)if(globalThis.reportError)reportError(g);else throw g;else if(!i.destroyed){i.destroy("fatal WebGPU error",g);return}}),t.lost.then(f=>console.error(`WebGPU Device lost: ${f.message}`)),r===void 0){if(r=document.getElementsByTagName("canvas")[0],r===void 0)throw Error("No canvas element or ID string provided, and no canvas was not found in the HTML.")}else if(typeof r=="string"){const f=document.getElementById(r);if(!(f instanceof HTMLCanvasElement))throw Error(`Element with ID "${r}" is not a canvas element.`);r=f}const a=r.getContext("webgpu");if(!a)throw Error("Could not get WebGPU context from canvas.");const d=t.features.has("canvas-rgba16float-support")?"rgba16float":"bgra8unorm";a.configure({device:t,format:d,alphaMode:"opaque"});const c=t.createShaderModule({label:"Main shader",code:H}),_=await WebAssembly.instantiateStreaming(fetch(C),{env:{js_message:(f,g,x)=>{let p=new TextDecoder().decode(new Uint8Array(u.buffer,Number(f),Number(g)));p.charAt(0)!=="]"?p="["+(i?.LOGGING_PREFIX||"")+p:p=p.slice(1),x===1?console.info("%c"+p,"font-weight: 600"):[console.log,console.info,console.warn,console.error][x](p)},js_write_text:(f,g,x)=>{const p=new Uint8Array(u.buffer,Number(g),Number(x)),L=new TextDecoder().decode(p),D=document.getElementById(`text${f+1}`);D.textContent=L},js_get_time:()=>performance.now(),js_handle_visible_chunks:f=>i?.handleVisibleChunks(f)}}),u=_.instance.exports.memory,h=t.createBindGroupLayout({label:"Main bind group layout",entries:[{binding:0,visibility:GPUShaderStage.VERTEX|GPUShaderStage.FRAGMENT,buffer:{type:"uniform"}},{binding:1,visibility:GPUShaderStage.VERTEX|GPUShaderStage.FRAGMENT,buffer:{type:"read-only-storage"}},{binding:2,visibility:GPUShaderStage.FRAGMENT,texture:{}},{binding:3,visibility:GPUShaderStage.FRAGMENT,sampler:{}}]}),T=t.createPipelineLayout({label:"Shared Pipeline Layout",bindGroupLayouts:[h]}),B=t.createRenderPipeline({label:"Tilemap pipeline",layout:T,vertex:{module:c,entryPoint:"vs_main"},fragment:{module:c,entryPoint:"fs_main",targets:[{format:d,blend:{color:{srcFactor:"src-alpha",dstFactor:"one-minus-src-alpha"},alpha:{srcFactor:"one",dstFactor:"one-minus-src-alpha"}}}]},primitive:{topology:"triangle-strip",cullMode:"none"},depthStencil:{depthWriteEnabled:!0,depthCompare:"less-equal",format:"depth24plus"}}),k=t.createRenderPipeline({label:"Background pipeline",layout:T,vertex:{module:c,entryPoint:"vs_background"},fragment:{module:c,entryPoint:"fs_background",targets:[{format:d}]},primitive:{topology:"triangle-list"},depthStencil:{depthWriteEnabled:!1,depthCompare:"less-equal",format:"depth24plus"}});i=new E(r,s,t,a,_,B,k),i.exports.setup(),await i.setSeed(M(100)),i.exports.init();const G=new ResizeObserver(i.onResize);i.resizeObserver=G,i.updateCanvasStyle();try{i.resizeObserver.observe(r,{box:"device-pixel-content-box"})}catch{console.log("ResizeObserver property device-pixel-content-box not supported, falling back to content-box."),i.resizeObserver.observe(r,{box:"content-box"})}i.onResize([{contentRect:{width:r.clientWidth,height:r.clientHeight}}]);const I=await E.loadTexture(t,F),U=t.createSampler({magFilter:"nearest",minFilter:"nearest",addressModeU:"clamp-to-edge",addressModeV:"clamp-to-edge"});i.atlasTextureView=I.createView(),i.pixelSampler=U;const O=[t.createBuffer({label:"SceneUniforms",size:56,usage:GPUBufferUsage.UNIFORM|GPUBufferUsage.COPY_DST}),t.createBuffer({label:"SceneUniforms",size:56,usage:GPUBufferUsage.UNIFORM|GPUBufferUsage.COPY_DST})];return i.uniformBuffers=O,i}var P=(r=>(r[r.Uint8=8]="Uint8",r[r.Uint16=16]="Uint16",r[r.Uint32=32]="Uint32",r[r.Uint64=64]="Uint64",r[r.Int8=-8]="Int8",r[r.Int16=-16]="Int16",r[r.Int32=-32]="Int32",r[r.Int64=-64]="Int64",r[r.Uint8Clamped=-80]="Uint8Clamped",r[r.Float32=-320]="Float32",r[r.Float64=-640]="Float64",r))(P||{});globalThis.WasmTypeCode=P;const S={8:Uint8Array,16:Uint16Array,32:Uint32Array,64:BigUint64Array,[-8]:Int8Array,[-16]:Int16Array,[-32]:Int32Array,[-64]:BigInt64Array,[-80]:Uint8ClampedArray,[-320]:Float32Array,[-640]:Float64Array},v=2;class E{engineModule;exports;memory;canvas;adapter;device;context;resizeObserver;inputState;isVisibleDataNew=!0;tileMapWidth;tileMapHeight;destroyed=!1;bindGroups=Array(v);uniformBuffers=Array(v);tileBuffers=Array(v);bindGroup;uniformBuffer;tileBuffer;tileBufferDirty=!1;atlasTextureView;pixelSampler;startTime=performance.now();LAYOUT_PTR;GAME_STATE_PTR;seed="";destroyedError=null;wireframeOpacity=0;forceAspectRatio=!0;previousForceAspectRatio=null;renderCallId=0;renderPass=null;currentEncoder=null;currentTextureView=null;depthTexture;depthTextureView=null;renderPipeline;bgPipeline;encoder=new TextEncoder;decoder=new TextDecoder;LOGGING_PREFIX="";constructor(e,n,s,t,i,a,d){this.canvas=e,this.adapter=n,this.device=s,this.context=t,this.engineModule=i,this.renderPipeline=a,this.bgPipeline=d,this.exports=i.instance.exports,this.memory=i.instance.exports.memory,this.LAYOUT_PTR=Number(this.exports.get_memory_layout_ptr()),this.GAME_STATE_PTR=Number(this.getScratchView()[3]),this.inputState=q()}static async create(e,n){return await K(e,n)}destroy(e="unknown reason",n=null){this.resizeObserver.disconnect(),this.destroyed=e,this.destroyedError=n}static async loadTexture(e,n){const t=await(await fetch(n)).blob(),i=await createImageBitmap(t),a=e.createTexture({label:`Texture from  ${n}`,size:[i.width,i.height],format:e.features.has("canvas-rgba16float-support")?"rgba16float":"bgra8unorm",usage:GPUTextureUsage.TEXTURE_BINDING|GPUTextureUsage.COPY_DST|GPUTextureUsage.RENDER_ATTACHMENT});return e.queue.copyExternalImageToTexture({source:i},{texture:a},[i.width,i.height]),a}uploadVisibleChunks(e=1){this.exports.prepare_visible_chunks(e,this.canvas.width,this.canvas.height)}handleVisibleChunks(e){if(!this.currentEncoder||!this.currentTextureView||!this.renderPass)return;const n=this.getScratchPtr();if(this.getScratchLen()===0)return;const t=Number(this.getScratchProperty(0)),i=Number(this.getScratchProperty(1)),a=t*i*2;this.tileMapWidth=t,this.tileMapHeight=i;const d=new Uint32Array(this.memory.buffer,n,a),c=a*4;this.recreateBufferAndBindGroup(c),this.updateBuffersAndBindGroup(this.renderCallId),this.renderPass.setPipeline(this.renderPipeline),this.renderPass.setBindGroup(0,this.bindGroup),this.renderCallId==1&&this.renderPass.setViewport(0,0,this.canvas.width,this.canvas.height,0,1),this.setSceneData(e,t,i),this.device.queue.writeBuffer(this.tileBuffer,0,d);const _=t*i+1;this.renderPass.draw(4,_),this.isVisibleDataNew=!1}setSceneData(e,n,s){const t=this.getScratchProperty(2,-640),i=this.getScratchProperty(3,-640),a=this.getScratchProperty(4,-640),d=this.getScratchProperty(5,-640),c=this.getScratchProperty(6,-640),_=new ArrayBuffer(56),u=new Float32Array(_),h=new Uint32Array(_);u[0]=t,u[1]=i,u[2]=this.canvas.width,u[3]=this.canvas.height,u[4]=(performance.now()-this.startTime)%16777216,u[5]=a,u[6]=a<.25?0:this.wireframeOpacity,u[7]=e,u[8]=d,u[9]=c,h[10]=n,h[11]=s,this.device.queue.writeBuffer(this.uniformBuffer,0,u)}recreateBufferAndBindGroup(e){(!this.tileBuffer||this.tileBuffer.size<e)&&(this.tileBuffers[this.renderCallId]=this.device.createBuffer({label:"Tile grid",size:e,usage:GPUBufferUsage.STORAGE|GPUBufferUsage.COPY_DST}),this.bindGroups[this.renderCallId]=this.device.createBindGroup({label:"Tilemap bind group",layout:this.renderPipeline.getBindGroupLayout(0),entries:[{binding:0,resource:{buffer:this.uniformBuffers[this.renderCallId]}},{binding:1,resource:{buffer:this.tileBuffers[this.renderCallId]}},{binding:2,resource:this.atlasTextureView},{binding:3,resource:this.pixelSampler}]}))}updateBuffersAndBindGroup(e){this.tileBuffer=this.tileBuffers[e],this.uniformBuffer=this.uniformBuffers[e],this.bindGroup=this.bindGroups[e]}getWASMMemoryMB(){return this.memory.buffer.byteLength/1024/1024}getGameView(e,n=0,s){return new S[e](this.memory.buffer,this.GAME_STATE_PTR+n,s)}getRawView(e,n,s){return new S[e](this.memory.buffer,n,s)}_tempScratchView=null;getScratchView(){return(this._tempScratchView===null||this._tempScratchView.buffer!==this.memory.buffer)&&(this._tempScratchView=new BigUint64Array(this.memory.buffer,this.LAYOUT_PTR,24)),this._tempScratchView}getScratchPtr(){return Number(this.getScratchView()[0])}getScratchLen(){return Number(this.getScratchView()[1])}setScratchLen(e){this.getScratchView()[1]=BigInt(e)}getScratchCapacity(){return Number(this.getScratchView()[2])}getScratchProperty(e,n=64){(this._tempScratchView===null||this._tempScratchView.buffer!==this.memory.buffer)&&(this._tempScratchView=new BigUint64Array(this.memory.buffer,this.LAYOUT_PTR,24));let s=this._tempScratchView;return n==-640&&(s=new Float64Array(s.buffer,s.byteOffset,s.length)),Number(s[e+4])}readStr(e=this.getScratchPtr(),n=this.getScratchLen()){const s=new Uint8Array(this.memory.buffer,e,n);return this.decoder.decode(s)}writeStr(e,n=!0){const s=e.length;if(s===0)return null;n&&this.setScratchLen(0);const t=this.exports.scratch_alloc(s);if(t===0n)return null;const i=new Uint8Array(this.memory.buffer,Number(t),s);if(this.encoder.encodeInto(e,i).read<s)throw new RangeError("String truncated with non-ASCII characters detected.");return Number(t)}async setSeed(e){this.seed=e,await V(e,this.getGameView(64,w.seed,8))}updateCanvasStyle(){this.forceAspectRatio!==this.previousForceAspectRatio&&(this.previousForceAspectRatio=this.forceAspectRatio,this.forceAspectRatio?(this.canvas.style.maxWidth=`calc(100vh*${16/9})`,this.canvas.style.maxHeight=`calc(100vw*${9/16})`):(this.canvas.style.maxWidth="none",this.canvas.style.maxHeight="none"))}onResize=e=>{const n=e[0];let s,t;if(n.devicePixelContentBoxSize)s=n.devicePixelContentBoxSize[0].inlineSize,t=n.devicePixelContentBoxSize[0].blockSize;else if(n.contentBoxSize){const i=n.contentBoxSize[0].inlineSize,a=n.contentBoxSize[0].blockSize;s=Math.round(i*devicePixelRatio),t=Math.round(a*devicePixelRatio)}else{const i=n.contentRect.width,a=n.contentRect.height;s=Math.round(i*devicePixelRatio),t=Math.round(a*devicePixelRatio)}(this.canvas.width!==s||this.canvas.height!==t)&&(this.canvas.width=s,this.canvas.height=t,this.depthTexture&&this.depthTexture.destroy(),this.depthTexture=this.device.createTexture({size:[s,t],format:"depth24plus",usage:GPUTextureUsage.RENDER_ATTACHMENT}))};renderFrame(e,n){if(this.renderCallId=0,this.destroyed!==!1)return;this.updateCanvasStyle(),this.currentEncoder=this.device.createCommandEncoder(),this.currentTextureView=this.context.getCurrentTexture().createView(),this.depthTextureView=this.depthTexture.createView();const t=this.currentEncoder.beginRenderPass({colorAttachments:[{view:this.currentTextureView,loadOp:"clear",clearValue:{r:0,g:0,b:0,a:1},storeOp:"store"}],depthStencilAttachment:{view:this.depthTextureView,depthClearValue:1,depthLoadOp:"clear",depthStoreOp:"store"}});this.renderPass=t,this.uploadVisibleChunks(e),this.renderCallId==0&&(this.updateBuffersAndBindGroup(this.renderCallId),this.renderPass.setPipeline(this.bgPipeline),this.renderPass.setBindGroup(0,this.bindGroup),this.renderPass.draw(3)),this.renderPass.end(),this.device.queue.submit([this.currentEncoder.finish()]),this.currentEncoder=null,this.currentTextureView=null}tick(e){const n=this.getGameView(32,w.keys_pressed_mask,2);N(this.inputState),n[0]=this.inputState.keysPressed,n[1]=this.inputState.keysHeld,this.exports.tick(e)}}location.protocol==="file:"&&alert("This game cannot run from a local file:// context; use an online version or test from localhost instead.");isSecureContext||alert("This game cannot run in a non-secure context.");navigator.gpu||alert("WebGPU is not supported by your browser; try playing this on an alternate or more modern browser.");const Z=await navigator.gpu.requestAdapter();Z||alert("WebGPU is supported, but no compatible GPU was found.");const W=["text1","text2","text3","text4","logicText","renderText"];document.addEventListener("wheel",function(r){r.ctrlKey},{passive:!1});let l=await E.create();l.getTimeoutLength=function(){return++X%3==2?16:17};l.getFrameRate=function(){return 60};l.baseSpeed=1;let m=performance.now(),b=0,X=0;globalThis.engine=l;console.log("Engine initialized successfully:",l),console.log("Exported functions and memory:",l.exports);window.addEventListener("blur",()=>m=1/0);l.isDebug=!!l.exports.isDebug();l.renderLoop=function(r){let e=performance.now(),n=m===1/0?0:e-m,s=Math.min(n*l.getFrameRate()/1e3,l.getFrameRate());l.logicLoop(Math.floor(b+s)),b=(b+s)%1;let t="#cccccc";if(n>55?t="#e83769":n>30?t="#f39c19":n>20&&(t="#f7ce1a"),l.isDebug){const a=document.getElementById("renderText");a.textContent=`Time since last render and Zig compute time: ${n.toFixed(1)}ms, ${(performance.now()-e).toFixed(1)}ms`,a.style.fontWeight=n>30?n>55?700:600:500,a.style.color=t}let i=Math.min(b-1,0);l.renderFrame(i,m),requestAnimationFrame(l.renderLoop)};l.logicLoop=function(r){const e=performance.now();for(let t=0;t<r;t++)l.tick(60/l.getFrameRate()*l.baseSpeed);m=performance.now();let n=m-e,s="#cccccc";if(n>30?s="#e83769":n>15?s="#f39c19":n>10&&(s="#f7ce1a"),l.isDebug){const t=document.getElementById("logicText");t.textContent=`Logic diff (${r} tick${r==1?"":"s"}): ${n.toFixed(1)}ms
`,t.style.fontWeight=n>30?n>55?700:600:500,t.style.color=s}};globalThis.Zig={KeyBits:o,game_state_offsets:w};l.isDebug?(console.log("Zig code is in debug mode. Use engine.exports to see its functions, variables, and memory, such as engine.exports.test_logs."),W.forEach(r=>{document.getElementById(r).style.display="inline"})):console.log('Note: engine is in verbose mode, but Zig code is not in -Doptimize=Debug; run just "zig build" to enable additional testing features and safety checks if possible.');setTimeout(function(){l.renderLoop(0)},17);
