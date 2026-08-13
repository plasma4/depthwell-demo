# Rendering reference

Read this before you edit `zig/render/`, `zig/menus/`, `zig/types/variation.zig`,
`zig/types/assembly.zig`, or `src/shader.wgsl`.

Trust the code over this file if they disagree.

### Rendering and UI

- **Color is OKLCH `lcha` (`Vec4f32`)**: `{ L, C, H, A }`. In the shader, **L and A multiply** the sprite's own color, and **C and H (hue in radians) shift additively**. So a white UI sprite is tinted by adding C and H. `DEFAULT_ENTITY_LCHA = {1,0,0,1}` leaves a sprite unchanged. For a subtle drop shadow, draw the sprite or number again at about `+0.6px` offset with a much lower L.
- **Coordinate spaces** — UV (0-1) and viewport pixels (480x270). Check which one an `entity.zig` helper expects before you mix them. `dw.entity.addEntity` takes a **viewport-px** center and px size; `addEntitySized` takes **UV** by default (its `system` field selects the space). Numbers go through `dw.entity.drawNumber`.
- **Menus** (`zig/menus/`) draw every frame from global state and gate on their open flag in `zig/render/indicators.zig`.
- **Input focus** (`zig/input/mouse.zig`) — `ClickFocus` is _which layer owns the current click_ (canvas, inventory, indicator, smelting, crafting), so a drag cannot cross-activate menus. It is claimed once per tick in `processDownCaptures()`, before mining; test it with `permits()`/`isClicked()`. `CursorType` is the separate CSS cursor style, kept in sync with `setMouseType` in `src/engine.ts`.

### Lighting, and what it costs

- Light is three `u6` channels on `Block` (`light_l`, `light_c`, `light_h`), read by `tile_light()` in `src/shader.wgsl`.
- `sample_light()` blends the four tiles nearest a pixel (bilinear), so `tile_light()` runs FOUR times per pixel.
- The canvas renders at NATIVE device resolution, not at the 480x270 camera. `src/engine.ts` sets `canvas.width` from `devicePixelRatio`.
  So anything in `fs_tile()` is multiplied by real pixels, and `devicePixelRatio` alone can make that 4x.
- `LIGHT_HUE_DIR` is a generated table of one unit vector per hue step.
  `zig/update_shader.zig` writes it from `lighting.HUE_STEPS`, so it cannot drift from `LightChannel`.
  Do not hand-edit it, and do not put a `cos()` or a `sin()` back into `tile_light()`.
