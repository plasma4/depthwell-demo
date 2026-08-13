# Worldgen reference

Read this before you edit `zig/state/procedural.zig`, `ancestor.zig`, `refine.zig`,
`structures.zig`, `decorations.zig`, or the worldgen parts of `world.zig`.

Trust the code over this file if they disagree.

### Depths, and the integer type each one uses

`STARTING_ZOOM_TIMES = 13` (`zig/startup.zig`) is the **base depth**: the shallowest depth that exists, the only one generated from noise instead of inherited, and the only one with a finite size. Depth counts UP as you descend.

There are three regimes. Mixing up their integer types is the most common way to write a subtly broken function here.

| Regime    | Depth                      | Size                                                     | Coordinate type                                                        | Owner                                                 |
| --------- | -------------------------- | -------------------------------------------------------- | ---------------------------------------------------------------------- | ----------------------------------------------------- |
| Base      | `== STARTING_ZOOM_TIMES`   | closed square, `2^13` chunks per axis, `edge_stone` wall | `u32` world block, or `i32` when a probe can go out of bounds          | `procedural.zig`, `structures.zig`, `decorations.zig` |
| Recursive | `> STARTING_ZOOM_TIMES`    | 4x per depth, unbounded in practice                      | `WorldCoord` (full-width fixed point, `seeding.WORLD_COORD_BITS = 69`) | `ancestor.zig`, `refine.zig`                          |
| Horizon   | `depth + 32 == game.depth` | not tracked as coordinates at all                        | `HorizonWindow`, a 16x16 block grid                                    | `world.QuadCache`                                     |

- **`i32` means base depth.** `structures.MAX_WORLD_BLOCK` is an `i32`, and `STARTING_ZOOM_TIMES > 13` overflows it (a `@compileError` catches this). Structures use signed coordinates on purpose: probing outside the world is routine (a seat scan below the box, an `Encase` halo, `isBeaten()` resolving `cx - 1`). `i32` turns an unsigned wrap into an easy bounds check, and `baseSolid()` is the gate that rejects them.
- **`WorldCoord` means any depth.** Recursive depths have no bound, so everything below base depth is fixed point end to end. `procedural.latticeAxis()` shows why: it puts a full-width coordinate on the noise lattice with a split multiply instead of a float, because past ~2^19 blocks an `f32` coordinate quantizes and the terrain visibly bands. **Never** round-trip a `WorldCoord` through `f32`/`f64`.
- **`worldBlock()` (`ancestor.zig`) is the bridge**: `(quadrant_bit, chunk_suffix, block)` becomes one `WorldCoord` axis. Use it instead of writing the arithmetic by hand.
- **"World coord" is ambiguous in conversation.** In code it is one of: a `WorldCoord` (block index at some depth), a base-depth `u32`/`i32` block index, a chunk `suffix`, or a subpixel player position. Read the parameter name:
    - `wx`/`wy` — block indices
    - `cx`/`cy` — chunks, or structure grid cells in `structures.zig`
    - `bx`/`by` — blocks within a chunk (`u4`)
    - `lx`/`ly` — cells within a parent region (`u4`, `0..BLOCKS_PER_PARENT`)

### Worldgen vocabulary

- **Materialize vs generate** — `generateChunk()` is pure procedure. `materializeChunk()` is that plus every `mod_store` edit replayed plus a flag recompute. It is the only supported way to turn a `mod_store` entry into a `Chunk`.
- **Foundation vs solid** — `isSolid()` includes `edge_stone` (the world border); `isFoundation()` excludes it. Reading the border as air makes terrain erode toward it, so the carve uses `isSolid()` and material inheritance uses `isFoundation()`.
- **Overlay / underlay** — an ore or gem is an overlay drawn over a `base_id` stone underlay.
- **Refine** (`refine.zig`) — what a non-terrain parent block does at the next depth. A bush states a PLAN for its 4x4 child region instead of filling it, so one bush does not become sixteen.
- **Carve** — `ancestor.carvesSlope()` deleting a child cell to make a parent silhouette sloped instead of blocky. A parent with a solid neighbor keeps its center 2x2 core, so connected terrain has floor to land on. An unsupported solid parent disappears instead of becoming a floating 2x2 island.
- **Dispersal** — `procedural.disperseOre()` applying the comptime ore palette. It runs at base depth and at every recursive depth.

### Worldgen caches

There are eight, and they invalidate differently. README "The cache layers" explains what each one holds.

| Cache                           | Keyed by                                     | Dropped by                     |
| ------------------------------- | -------------------------------------------- | ------------------------------ |
| `procedural.base_terrain_cache` | world block, tiled                           | `terrainGeneration()` mismatch |
| `world.foundation_cache`        | world block, tiled                           | `terrainGeneration()` mismatch |
| `structures.struct_cache`       | grid cell + struct seed + generation         | per-entry check                |
| `structures.chunk_ctx`          | chunk + struct seed + generation             | per-entry check                |
| `ancestor.ancestor_cache`       | `DepthCoordinate`, tiered by distance from D | `world.clearCaches(true)`      |
| `ancestor.parent_hood_cache`    | parent cell                                  | `world.clearCaches()`          |
| `ancestor.chunk_noise`          | `DepthCoordinate`, one entry                 | `world.clearCaches()`          |
| `world.QuadCache.seed_cache`    | `DepthCoordinate`                            | `world.clearCaches()`          |

- **Every one of these memoizes PROCEDURAL output only.** Player edits stay an overlay that `materializeChunk()` replays on top, so an edit never invalidates any of them. A cache that broke this rule would need its own store-write counter; do not add one without stating why the overlay is not enough.
- `ModificationStore.generation` counts whole-store WIPES, for the save system. It is not an edit counter.
- `procedural.terrainGeneration()` is the shared identity: the world seed XORed, plus a `tuning_epoch` that only debug can bump.
- **Every debug slider or button that changes terrain must set `regen = true`.** That routes through `world.clearCaches()`, which bumps the epoch. A terrain-affecting control without it serves stale cached samples.
