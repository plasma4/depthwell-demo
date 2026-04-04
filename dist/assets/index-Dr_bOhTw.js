(function(){const t=document.createElement("link").relList;if(t&&t.supports&&t.supports("modulepreload"))return;for(const e of document.querySelectorAll('link[rel="modulepreload"]'))i(e);new MutationObserver(e=>{for(const s of e)if(s.type==="childList")for(const a of s.addedNodes)a.tagName==="LINK"&&a.rel==="modulepreload"&&i(a)}).observe(document,{childList:!0,subtree:!0});function r(e){const s={};return e.integrity&&(s.integrity=e.integrity),e.referrerPolicy&&(s.referrerPolicy=e.referrerPolicy),e.crossOrigin==="use-credentials"?s.credentials="include":e.crossOrigin==="anonymous"?s.credentials="omit":s.credentials="same-origin",s}function i(e){if(e.ep)return;e.ep=!0;const s=r(e);fetch(e.href,s)}})();const o={zoom:131072,drop:262144,minus:32768,plus:65536,up:2048,left:4096,down:8192,right:16384,k0:1,k1:2,k2:4,k3:8,k4:16,k5:32,k6:64,k7:128,k8:256,k9:512},S={player_pos:0,last_player_pos:16,player_chunk:32,player_velocity:48,camera_pos:64,last_camera_pos:80,camera_scale:96,camera_scale_change:104,depth:112,player_quadrant:120,player_screen_offset:128,keys_pressed_mask:136,keys_held_mask:140,seed:144},M="abcdefghijklmnopqrstuvwxyz",w=26n;function z(n=100){if(n<=0)return"";const t=new Uint8Array(72);crypto.getRandomValues(t);let r=0n;const i=new DataView(t.buffer);for(let a=0;a<t.length;a+=8)r=r<<64n|i.getBigUint64(a);let e="",s=r%w**BigInt(n);for(;s>=0n&&(e+=M[Number(s%w)],s=s/w-1n,!(s<0n)););return e}function F(n){let t=0n;for(let r=0;r<n.length;r++){const i=BigInt(n.charCodeAt(r)-97);t=t*w+(i+1n)}return t}async function V(n,t){const r=F(n),i=new DataView(new ArrayBuffer(64));for(let c=0;c<8;c++)i.setBigUint64(c*8,r>>BigInt((7-c)*64)&0xffffffffffffffffn);let e=new Uint8Array(i.buffer,0,32),s=new Uint8Array(i.buffer,32,32);const a=await Promise.all([0,1,2,3].map(c=>crypto.subtle.importKey("raw",new Uint8Array([c]),{name:"HMAC",hash:"SHA-256"},!1,["sign"])));for(const c of a){const m=new Uint8Array(await crypto.subtle.sign("HMAC",c,s)),p=new Uint8Array(32);for(let h=0;h<32;h++)p[h]=e[h]^m[h];e=s,s=p}const u=new Uint8Array(64);return u.set(e,0),u.set(s,32),t.set(new BigUint64Array(u.buffer)),t}const B={Minus:o.minus,Equal:o.plus,KeyZ:o.zoom,KeyQ:o.drop,ArrowUp:o.up,KeyW:o.up,ArrowLeft:o.left,KeyA:o.left,ArrowDown:o.down,KeyS:o.down,ArrowRight:o.right,KeyD:o.right,Digit0:o.k0,Digit1:o.k1,Digit2:o.k2,Digit3:o.k3,Digit4:o.k4,Digit5:o.k5,Digit6:o.k6,Digit7:o.k7,Digit8:o.k8,Digit9:o.k9};function q(){const n={},t={heldMask:0,keysHeld:0,keysPressed:0,currentlyHeld:0,horizontalPriority:0,verticalPriority:0,plusMinusPriority:0};function r(){t.horizontalPriority=0,t.verticalPriority=0,t.plusMinusPriority=0,t.currentlyHeld=0,t.heldMask=0,t.keysPressed=0}return window.addEventListener("keydown",i=>{if((i.altKey||i.shiftKey||i.ctrlKey||i.metaKey)&&r(),i.repeat||i.ctrlKey||i.metaKey)return;const e=B[i.code];e&&(t.heldMask|=e,n[e]=(n[e]||0)+1,e&(o.left|o.right)&&(t.horizontalPriority=e),e&(o.up|o.down)&&(t.verticalPriority=e),e&(o.plus|o.minus)&&(t.plusMinusPriority=e))}),window.addEventListener("keyup",i=>{const e=B[i.code];e&&(n[e]=Math.max(0,(n[e]||0)-1),n[e]===0&&(t.heldMask&=~e,e===t.horizontalPriority&&(t.horizontalPriority=t.heldMask&o.left||t.heldMask&o.right||0),e===t.verticalPriority&&(t.verticalPriority=t.heldMask&o.up||t.heldMask&o.down||0),e===t.plusMinusPriority&&(t.plusMinusPriority=t.heldMask&o.plus||t.heldMask&o.minus||0)))}),window.addEventListener("blur",r),t}function N(n){const t=o.up|o.down|o.left|o.right;let r=n.heldMask&~t;r|=n.horizontalPriority,r|=n.verticalPriority,r|=n.plusMinusPriority,n.keysPressed=r&~n.keysHeld,n.currentlyHeld=r,n.keysHeld=r}const C=""+new URL("main-DRMRp5mq.wasm",import.meta.url).href,H=`/*
 * Main shader for Depthwell. IMPORTANT: ADD ?raw FOR DEBUGGING SHADER TO THE END OF engineMaker.ts's SHADER_SOURCE VARIABLE.
 */
// Sprite sheet constants. Sprites are saved as a .png, and each asset is 16x16. See zig/world.zig's Sprite definitions for what these all are.
const TILES_PER_ROW: f32 = 14.0;
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
@group(0) @binding(4) var<uniform> map_size: vec4u;

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

    if (out.sprite_id == 7 && (extractBits(out.seed, 16u, 2u) == 0)) { // extract bits 16-18 for random modifications
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

    let total_tiles = map_size.x * map_size.y;

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

    let tile_x = instance_index % map_size.x;
    let tile_y = instance_index / map_size.x;
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
    var final_a = tex_color.a * scene.chunk_opacity;

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
                lch.x *= 0.8 + extracted_l * 0.01; // lower lightness
                lch.y *= 1.3 + extracted_a * 0.04; // increase chroma
            }
        }
    }
    lab = oklch_to_oklab(lch);
    final_rgb = max(oklab_to_linear_srgb(lab), vec3f(0.0));
    final_a = tex_color.a * scene.chunk_opacity;

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



// FBM vs and fs logic
struct BackgroundOutput {
    @builtin(position) position: vec4f,
    @location(0) world_uv: vec2f,
};

@vertex
fn vs_background(@builtin(vertex_index) vertex_index: u32) -> BackgroundOutput {
    let x = f32(i32(vertex_index & 1u) << 2u) - 1.0;
    let y = f32(i32(vertex_index & 2u) << 1u) - 1.0;
    
    var out: BackgroundOutput;
    out.position = vec4f(x, y, 1.0, 1.0);

    // 1. Convert NDC to Screen UV (0 to 1 range)
    let screen_uv = vec2f(x, -y) * 0.5 + 0.5;
    
    // 2. Map Screen UV to World Space
    // We remove the TILE_SIZE division and the floor() function.
    // This gives us a continuous coordinate that scales with zoom and moves with the camera.
    out.world_uv = (screen_uv * scene.viewport_size) / scene.zoom + scene.camera;
    
    return out;
}

@fragment
fn fs_background(in: BackgroundOutput) -> @location(0) vec4f {
    // 1. Setup Time and Looping
    let time_ms = scene.time;
    let t = time_ms / 128.0;
    
    // Zig-zag wrapping for colors
    var t_wrap = (t / 30.0) % 2.0;
    if (t_wrap > 1.0) { t_wrap = 2.0 - t_wrap; }
    
    var t_wrap_2 = (8.0 + t / 95.0) % 20.0;
    if (t_wrap_2 > 1.0) { t_wrap_2 = 2.0 - t_wrap_2; }

    let parallax_offset = scene.camera * 0.02;
    let st = (in.world_uv + parallax_offset) * 0.005 * 3.0; 

    // FBM domain warping
    var q = vec2f(0.0);
    q.x = fbm(st + 0.00 * t);
    q.y = fbm(st + vec2f(1.0));

    var r = vec2f(0.0);
    r.x = fbm(st + 1.0 * q + vec2f(1.7, 9.2) + 0.15 * t);
    r.y = fbm(st + 1.0 * q + vec2f(8.3, 2.8) + 0.126 * t);

    let f = fbm(st + r);

    var color = mix( // mix in colors
        vec3f(0.101961, 0.619608, mix(0.0, 0.966667, t_wrap)),
        vec3f(0.666667, 0.666667, 0.798039),
        clamp((f * f) * 4.0, 0.0, 1.0)
    );

    color = mix(
        color,
        vec3f(mix(0.0, 0.8, t_wrap_2), mix(0.0, 0.4, t_wrap), 0.864706),
        clamp(length(q), 0.0, 1.0)
    );

    color = mix(
        color,
        vec3f(0.666667, 1.0, 1.0),
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
    let lms_ = vec3f(fast_cbrt(lms.x), fast_cbrt(lms.y), fast_cbrt(lms.z));

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

fn fast_cbrt(x: f32) -> f32 {
    // Handle the zero case to avoid division by zero later
    if (x == 0.0) { return 0.0; }
    var y = bitcast<f32>(bitcast<u32>(x) / 3u + 0x2a517d3cu); // bitcast approximation
    const two_thirds = 2.0 / 3.0; // Newton's method
    y = two_thirds * y + x / (3.0 * y * y);

    return y;
}

fn oklab_to_oklch(lab: vec3f) -> vec3f {
    let chroma = length(lab.yz);
    let hue = atan2(lab.z, lab.y);
    return vec3f(lab.x, chroma, hue);
}

fn oklch_to_oklab(lch: vec3f) -> vec3f {
    return vec3f(lch.x, lch.y * cos(lch.z), lch.y * sin(lch.z));
}
`,Z="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAOAAAAAQCAMAAAA4YYPKAAAAAXNSR0IArs4c6QAAAPxQTFRFbOPjUsC6f8rLTKuFAAAAAAAAsrKyRkZGAAAAAAAAAAAAAAAAncj8f7DgZY29YHqoNF9pAAAA5NzWzaWGjGVQb29vPC0tSj8zxdXtoae+n6uucHV9RlFTXGl1gntmw6aFfXFmp6eCPDo1REI9TeTecvG0L+R/LKQbWZtZAAAA/6PBzjU12bXbt4q732HBLKQbK06VJ4nNeGTGnIvbiqH2ydT9kFK8Qr/oSUGCRXLjAAAAAAAAEl83HZc5HkxKO4+QWaOlWMCXisevLWOGI61tIrIrAAAAAAAA1UMP7os+95Ag98ggd0IaqmIqdzwOmlglTSUHZzoZAAAAAAAAfhN1FwAAAFR0Uk5T/////wD///////////////////////////////////////////////////////////////////////////////////////////////+q4fb/////CWH/6gAABAJJREFUSIm9l2lv20YQhu3o8BdxueDe9wWZhOsYcdMTiFsnbYE2URL7//+ZYKjYlmnStpAiA4EiVxJWD+Z9Z2YP5k/EYhAY4wrXCKNVhWuMMRdiyRhpGBWCcsatc0tjlDTaOW2NzaUsUwo+xVJiTnl8l+N1d3/h5cun/tgz42A/wKMF0AFajVCFV1XFOaWMNA1hTSOYENZqbZSUykjpjHM5x5iC9yF5X1Ipo5u08/W959Ozk/bk7PsCLm8yCIQIrjVGCFVNwymlhDBCmoZzJqXVWitllJLSWuN9jjGGkELwPuc0vkt7D/D09GTezk9OvyvgrUQRACK8wv07Ik3DKCFUNIQwTomS0miltJNKGatV8D7FEGLxIaQcw8Q263aH7+wEkvr/ED4L8GgHENIHPgTIukaYEEYFpYJwwhmnVCmjndZOWWWN1TqEFEuMJeSQU45xCnB+Z0LQZgvA3+zDf/+bApzNZrM7wFsDAmCNV6ja6hSqDGSPCN5wxhkRnEL2lLPSGmuUsxqyF0r2OeUUSp4CPB4UmXbie4+gjMT7DxOAsxcvDg9nu4DLW4lupQl1Buoo4oxSzknTUEao4Nwara1VUmqjtLM2pxhzDt7HFGLJE1W0PR4u7An4/sPY6ubjJODhAPA2emkCIK4wYDJOGXiPCAFS5cZqA95TzoFUbcoxgfdCKSDVccB2PgBs2z0JNx/HVq8/PQNweR+wrqFHrBBG8KqwEAISSBkTnDMqnHOQQG2Ms9ZoV0qBBMaUSs4pjreJhxn8YT8+QBmLzdUE4OG9DN4yLheLuu+DvU5xjVaYM0EJI1wQJgQ0euO0Mso6ZZyDRp9KDCnkElIpk41+fbyvJgfxaTO6/HnzLMCdGrPYOrDqKygUHNZA7aRgRSCkRkLt1GBFINTJQ+2MYEUgnCoy828k/DwBeL0H4DaqbfuDVrHCGCFKekIBPhRNQ7XqCR340EmpY+gJC/iweD8F2A01ui/g9fj6I4AHY4BHi233w6iqqhVeYSRoQ0GgnHMmGBFOSw0CtdYaZ5Qr0UcQaM45lRQmPLgetomHcf7j65vbiz8vh59eTQBOFZkB4NGdD/vkrSrc6xQhDJMoFzDPCEEaRmAStQ7mGeeUNAom0Vxgnikl+BTmfUff4uxADYftB2ivzn/6+Zft85uLt+/+GmBeTf14EvBgNIMwycAICnUGGj3CDaMwygAhp6Sh0mgYZYDQaiW1TxFGGSDMMfjYtd22CXRd291RrYeN4i62aK9+O3/9+1fAPy4u/56/uXz77kEinws4Psl8bRP1zTBawyhD4ZgEhIRSTgjRcEwCQqW1VUpFOCYBYYgxhxC6to+u62+6m9KyfsyDv+5c+/hn5/pEfAGd7qbZvat0ZQAAAABJRU5ErkJggg==";async function Y(n,t){const r={highPerformance:!1,...t},i=await navigator.gpu.requestAdapter({powerPreference:r.highPerformance?"high-performance":"low-power"});if(!i)throw new DOMException("Couldn't request WebGPU adapter.","NotSupportedError");const e=await i.requestDevice();let s=null;if(e.addEventListener("uncapturederror",d=>{const g=d.error;if(s===null)if(globalThis.reportError)reportError(g);else throw g;else if(!s.destroyed){s.destroy("fatal WebGPU error",g);return}}),e.lost.then(d=>console.error(`WebGPU Device lost: ${d.message}`)),n===void 0){if(n=document.getElementsByTagName("canvas")[0],n===void 0)throw Error("No canvas element or ID string provided, and no canvas was not found in the HTML.")}else if(typeof n=="string"){const d=document.getElementById(n);if(!(d instanceof HTMLCanvasElement))throw Error(`Element with ID "${n}" is not a canvas element.`);n=d}const a=n.getContext("webgpu");if(!a)throw Error("Could not get WebGPU context from canvas.");const u=e.features.has("canvas-rgba16float-support")?"rgba16float":"bgra8unorm";a.configure({device:e,format:u,alphaMode:"opaque"});const c=e.createShaderModule({label:"Main shader",code:H}),m=await WebAssembly.instantiateStreaming(fetch(C),{env:{js_message:(d,g,b)=>{let _=new TextDecoder().decode(new Uint8Array(p.buffer,Number(d),Number(g)));_.charAt(0)!=="]"?_="["+(s?.LOGGING_PREFIX||"")+_:_=_.slice(1),b===1?console.info("%c"+_,"font-weight: 600"):[console.log,console.info,console.warn,console.error][b](_)},js_write_text:(d,g,b)=>{const _=new Uint8Array(p.buffer,Number(g),Number(b)),O=new TextDecoder().decode(_),L=document.getElementById(`text${d+1}`);L.textContent=O},js_get_time:()=>performance.now(),js_handle_visible_chunks:()=>s?.handleVisibleChunks()}}),p=m.instance.exports.memory,h=e.createBindGroupLayout({label:"Main Bind Group Layout",entries:[{binding:0,visibility:GPUShaderStage.VERTEX|GPUShaderStage.FRAGMENT,buffer:{type:"uniform"}},{binding:1,visibility:GPUShaderStage.VERTEX|GPUShaderStage.FRAGMENT,buffer:{type:"read-only-storage"}},{binding:2,visibility:GPUShaderStage.FRAGMENT,texture:{}},{binding:3,visibility:GPUShaderStage.FRAGMENT,sampler:{}},{binding:4,visibility:GPUShaderStage.VERTEX,buffer:{type:"uniform"}}]}),y=e.createPipelineLayout({label:"Shared Pipeline Layout",bindGroupLayouts:[h]}),E=e.createRenderPipeline({label:"Tilemap pipeline",layout:y,vertex:{module:c,entryPoint:"vs_main"},fragment:{module:c,entryPoint:"fs_main",targets:[{format:u,blend:{color:{srcFactor:"src-alpha",dstFactor:"one-minus-src-alpha"},alpha:{srcFactor:"one",dstFactor:"one-minus-src-alpha"}}}]},primitive:{topology:"triangle-strip",cullMode:"none"},depthStencil:{depthWriteEnabled:!0,depthCompare:"less",format:"depth24plus"}}),A=e.createRenderPipeline({label:"Background pipeline",layout:y,vertex:{module:c,entryPoint:"vs_background"},fragment:{module:c,entryPoint:"fs_background",targets:[{format:u}]},primitive:{topology:"triangle-list"},depthStencil:{depthWriteEnabled:!1,depthCompare:"less-equal",format:"depth24plus"}});s=new k(n,i,e,a,m,E,A),s.exports.setup(),await s.setSeed(z(100)),s.exports.init();const f=new ResizeObserver(s.onResize);s.resizeObserver=f,s.updateCanvasStyle();try{s.resizeObserver.observe(n,{box:"device-pixel-content-box"})}catch{console.log("ResizeObserver property device-pixel-content-box not supported, falling back to content-box."),s.resizeObserver.observe(n,{box:"content-box"})}s.onResize([{contentRect:{width:n.clientWidth,height:n.clientHeight}}]);const T=await k.loadTexture(e,Z),D=e.createSampler({magFilter:"nearest",minFilter:"nearest",addressModeU:"clamp-to-edge",addressModeV:"clamp-to-edge"});s.atlasTextureView=T.createView(),s.pixelSampler=D;const U=e.createBuffer({label:"SceneUniforms",size:48,usage:GPUBufferUsage.UNIFORM|GPUBufferUsage.COPY_DST});s.uniformBuffer=U;const I=e.createBuffer({label:"Map size",size:16,usage:GPUBufferUsage.UNIFORM|GPUBufferUsage.COPY_DST});s.mapSizeBuffer=I;const R={width:0,height:0,data:new Uint32Array(0)};return s.tileMap=R,s}var G=(n=>(n[n.Uint8=8]="Uint8",n[n.Uint16=16]="Uint16",n[n.Uint32=32]="Uint32",n[n.Uint64=64]="Uint64",n[n.Int8=-8]="Int8",n[n.Int16=-16]="Int16",n[n.Int32=-32]="Int32",n[n.Int64=-64]="Int64",n[n.Uint8Clamped=-80]="Uint8Clamped",n[n.Float32=-320]="Float32",n[n.Float64=-640]="Float64",n))(G||{});globalThis.WasmTypeCode=G;const P={8:Uint8Array,16:Uint16Array,32:Uint32Array,64:BigUint64Array,[-8]:Int8Array,[-16]:Int16Array,[-32]:Int32Array,[-64]:BigInt64Array,[-80]:Uint8ClampedArray,[-320]:Float32Array,[-640]:Float64Array};class k{engineModule;exports;memory;canvas;adapter;device;context;resizeObserver;inputState;isVisibleDataNew=!0;tileMap;bindGroup;tileBufferDirty=!1;destroyed=!1;uniformBuffer;tileBuffer;mapSizeBuffer;atlasTextureView;pixelSampler;startTime=performance.now();LAYOUT_PTR;GAME_STATE_PTR;seed="";destroyedError=null;wireframeOpacity=0;forceAspectRatio=!0;previousForceAspectRatio=null;currentEncoder=null;currentTextureView=null;depthTexture;depthTextureView=null;renderPipeline;bgPipeline;encoder=new TextEncoder;decoder=new TextDecoder;LOGGING_PREFIX="";constructor(t,r,i,e,s,a,u){this.canvas=t,this.adapter=r,this.device=i,this.context=e,this.engineModule=s,this.renderPipeline=a,this.bgPipeline=u,this.exports=s.instance.exports,this.memory=s.instance.exports.memory,this.LAYOUT_PTR=Number(this.exports.get_memory_layout_ptr()),this.GAME_STATE_PTR=Number(this.getScratchView()[3]),this.inputState=q()}static async create(t,r){return await Y(t,r)}destroy(t="unknown reason",r=null){this.resizeObserver.disconnect(),this.destroyed=t,this.destroyedError=r}static async loadTexture(t,r){const e=await(await fetch(r)).blob(),s=await createImageBitmap(e),a=t.createTexture({label:`Texture from  ${r}`,size:[s.width,s.height],format:t.features.has("canvas-rgba16float-support")?"rgba16float":"bgra8unorm",usage:GPUTextureUsage.TEXTURE_BINDING|GPUTextureUsage.COPY_DST|GPUTextureUsage.RENDER_ATTACHMENT});return t.queue.copyExternalImageToTexture({source:s},{texture:a},[s.width,s.height]),a}uploadVisibleChunks(t=1){this.exports.prepare_visible_chunks(t,this.canvas.width,this.canvas.height)}handleVisibleChunks(){if(!this.currentEncoder||!this.currentTextureView)return;const t=this.getScratchPtr();if(this.getScratchLen()===0)return;const i=Number(this.getScratchProperty(0)),e=Number(this.getScratchProperty(1)),s=i*e*2,a=new Uint32Array(this.memory.buffer,t,s),u=s*4;(!this.tileBuffer||this.tileBuffer.size<u)&&(this.tileBuffer=this.device.createBuffer({label:"Tile grid",size:u,usage:GPUBufferUsage.STORAGE|GPUBufferUsage.COPY_DST}),this.bindGroup=this.device.createBindGroup({label:"Tilemap bind group",layout:this.renderPipeline.getBindGroupLayout(0),entries:[{binding:0,resource:{buffer:this.uniformBuffer}},{binding:1,resource:{buffer:this.tileBuffer}},{binding:2,resource:this.atlasTextureView},{binding:3,resource:this.pixelSampler},{binding:4,resource:{buffer:this.mapSizeBuffer}}]}));const c=this.getScratchProperty(2,-640),m=this.getScratchProperty(3,-640),p=this.getScratchProperty(4,-640),h=this.getScratchProperty(5,-640),y=this.getScratchProperty(6,-640),E=new Float32Array([c,m,this.canvas.width,this.canvas.height,(performance.now()-this.startTime)%16777216,p,p<.25?0:this.wireframeOpacity,1,h,y]);this.device.queue.writeBuffer(this.uniformBuffer,0,E),this.device.queue.writeBuffer(this.tileBuffer,0,a),this.device.queue.writeBuffer(this.mapSizeBuffer,0,new Uint32Array([i,e,0,0]));const A=this.isVisibleDataNew?"clear":"load",f=this.currentEncoder.beginRenderPass({colorAttachments:[{view:this.currentTextureView,loadOp:A,clearValue:{r:0,g:0,b:0,a:1},storeOp:"store"}],depthStencilAttachment:{view:this.depthTextureView,depthClearValue:1,depthLoadOp:"clear",depthStoreOp:"store"}});f.setPipeline(this.renderPipeline),f.setBindGroup(0,this.bindGroup),f.setViewport(0,0,this.canvas.width,this.canvas.height,0,1);const T=i*e+1;f.draw(4,T),f.setPipeline(this.bgPipeline),f.setBindGroup(0,this.bindGroup),f.draw(3),f.end(),this.isVisibleDataNew=!1,this.tileMap.width=i,this.tileMap.height=e}getWASMMemoryMB(){return this.memory.buffer.byteLength/1024/1024}getGameView(t,r=0,i){return new P[t](this.memory.buffer,this.GAME_STATE_PTR+r,i)}getRawView(t,r,i){return new P[t](this.memory.buffer,r,i)}_tempScratchView=null;getScratchView(){return(this._tempScratchView===null||this._tempScratchView.buffer!==this.memory.buffer)&&(this._tempScratchView=new BigUint64Array(this.memory.buffer,this.LAYOUT_PTR,24)),this._tempScratchView}getScratchPtr(){return Number(this.getScratchView()[0])}getScratchLen(){return Number(this.getScratchView()[1])}setScratchLen(t){this.getScratchView()[1]=BigInt(t)}getScratchCapacity(){return Number(this.getScratchView()[2])}getScratchProperty(t,r=64){(this._tempScratchView===null||this._tempScratchView.buffer!==this.memory.buffer)&&(this._tempScratchView=new BigUint64Array(this.memory.buffer,this.LAYOUT_PTR,24));let i=this._tempScratchView;return r==-640&&(i=new Float64Array(i.buffer,i.byteOffset,i.length)),Number(i[t+4])}readStr(t=this.getScratchPtr(),r=this.getScratchLen()){const i=new Uint8Array(this.memory.buffer,t,r);return this.decoder.decode(i)}writeStr(t,r=!0){const i=t.length;if(i===0)return null;r&&this.setScratchLen(0);const e=this.exports.scratch_alloc(i);if(e===0n)return null;const s=new Uint8Array(this.memory.buffer,Number(e),i);if(this.encoder.encodeInto(t,s).read<i)throw new RangeError("String truncated with non-ASCII characters detected.");return Number(e)}async setSeed(t){this.seed=t,await V(t,this.getGameView(64,S.seed,8))}updateCanvasStyle(){this.forceAspectRatio!==this.previousForceAspectRatio&&(this.previousForceAspectRatio=this.forceAspectRatio,this.forceAspectRatio?(this.canvas.style.maxWidth=`calc(100vh*${16/9})`,this.canvas.style.maxHeight=`calc(100vw*${9/16})`):(this.canvas.style.maxWidth="none",this.canvas.style.maxHeight="none"))}onResize=t=>{const r=t[0];let i,e;if(r.devicePixelContentBoxSize)i=r.devicePixelContentBoxSize[0].inlineSize,e=r.devicePixelContentBoxSize[0].blockSize;else if(r.contentBoxSize){const s=r.contentBoxSize[0].inlineSize,a=r.contentBoxSize[0].blockSize;i=Math.round(s*devicePixelRatio),e=Math.round(a*devicePixelRatio)}else{const s=r.contentRect.width,a=r.contentRect.height;i=Math.round(s*devicePixelRatio),e=Math.round(a*devicePixelRatio)}(this.canvas.width!==i||this.canvas.height!==e)&&(this.canvas.width=i,this.canvas.height=e,this.depthTexture&&this.depthTexture.destroy(),this.depthTexture=this.device.createTexture({size:[i,e],format:"depth24plus",usage:GPUTextureUsage.RENDER_ATTACHMENT}))};renderFrame(t,r){this.isVisibleDataNew=!0,!this.destroyed&&(this.updateCanvasStyle(),this.currentEncoder=this.device.createCommandEncoder(),this.currentTextureView=this.context.getCurrentTexture().createView(),this.depthTextureView=this.depthTexture.createView(),this.uploadVisibleChunks(t),this.device.queue.submit([this.currentEncoder.finish()]),this.currentEncoder=null,this.currentTextureView=null)}tick(t){const r=this.getGameView(32,S.keys_pressed_mask,2);N(this.inputState),r[0]=this.inputState.keysPressed,r[1]=this.inputState.keysHeld,this.exports.tick(t)}}location.protocol==="file:"&&alert("This game cannot run from a local file:// context; use an online version or test from localhost instead.");isSecureContext||alert("This game cannot run in a non-secure context.");navigator.gpu||alert("WebGPU is not supported by your browser; try playing this on an alternate or more modern browser.");const K=await navigator.gpu.requestAdapter();K||alert("WebGPU is supported, but no compatible GPU was found.");const Q=["text1","text2","text3","text4","logicText","renderText"];document.addEventListener("wheel",function(n){n.ctrlKey},{passive:!1});let l=await k.create();l.getTimeoutLength=function(){return++W%3==2?16:17};l.getFrameRate=function(){return 60};l.baseSpeed=1;let x=performance.now(),v=0,W=0;globalThis.engine=l;console.log("Engine initialized successfully:",l),console.log("Exported functions and memory:",l.exports);window.addEventListener("blur",()=>x=1/0);l.isDebug=!!l.exports.isDebug();l.renderLoop=function(n){let t=performance.now(),r=x===1/0?0:t-x,i=Math.min(r*l.getFrameRate()/1e3,l.getFrameRate());l.logicLoop(Math.floor(v+i)),v=(v+i)%1;let e="#cccccc";if(r>55?e="#e83769":r>30?e="#f39c19":r>20&&(e="#f7ce1a"),l.isDebug){const a=document.getElementById("renderText");a.textContent=`Time since last render and Zig compute time: ${r.toFixed(1)}ms, ${(performance.now()-t).toFixed(1)}ms`,a.style.fontWeight=r>30?r>55?700:600:500,a.style.color=e}let s=Math.min(v-1,0);l.renderFrame(s,x),requestAnimationFrame(l.renderLoop)};l.logicLoop=function(n){const t=performance.now();for(let e=0;e<n;e++)l.tick(60/l.getFrameRate()*l.baseSpeed);x=performance.now();let r=x-t,i="#cccccc";if(r>30?i="#e83769":r>15?i="#f39c19":r>10&&(i="#f7ce1a"),l.isDebug){const e=document.getElementById("logicText");e.textContent=`Logic diff (${n} tick${n==1?"":"s"}): ${r.toFixed(1)}ms
`,e.style.fontWeight=r>30?r>55?700:600:500,e.style.color=i}};globalThis.Zig={KeyBits:o,game_state_offsets:S};l.isDebug?(console.log("Zig code is in debug mode. Use engine.exports to see its functions, variables, and memory, such as engine.exports.test_logs."),Q.forEach(n=>{document.getElementById(n).style.display="inline"})):console.log('Note: engine is in verbose mode, but Zig code is not in -Doptimize=Debug; run just "zig build" to enable additional testing features and safety checks if possible.');setTimeout(function(){l.renderLoop(0)},17);
