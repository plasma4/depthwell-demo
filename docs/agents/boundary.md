# Data model and the WASM boundary

Read this before you change `Block`, a packed struct, the save format, an exported
function in `zig/root.zig`, or anything in `src/*.ts` that crosses into WASM.

Trust the code over this file if they disagree.

### Data model

- **Blocks and sprites** — a `Block` is a packed `u128` (`zig/memory.zig`): `id` (a `Sprite`), edge flags, the three OKLCH `light_*` channels, `hp`, seed, `base_id` underlay, the `water` union, and the refinement `tag`. `Sprite` (`zig/types/sprite.zig`) is an enum whose value IS its atlas tile index; the atlas is 8 tiles per row, 16 px tiles. Sprite properties (solid, item, strength, anchor, category, drops, ...) come from a **comptime rule table**, not from per-call logic. Render-only variation (stone tiling, animation, assembly left/right) resolves in `zig/types/variation.zig`; multi-tile assemblies (footprints) in `zig/types/assembly.zig`.
- **World state** — `SimBuffer` holds the active chunks and `mod_store` records block modifications. Procedural generation (`zig/state/procedural.zig`, `structures/`) is **deterministic** from the seeds in `zig/state/seeding.zig`, and position-hashed, so it is stable across chunk borders and across regeneration.
- **Seeds** — `GameState.seed` is the only seed in the save. `memory.hash_seeds` (the per-`SeedType` `FastHash` lanes) is derived from it by `memory.deriveHashSeeds()` at startup and at load, never stored. Read a lane with `memory.getHashSeed(.category)`.

### WASM to TypeScript boundary

- `pub` functions in `zig/root.zig` are exported, and `generate_types.zig` types them into `src/enums.ts`.
- `extern "env" js*` functions call back into TypeScript.
- A WASM call returns one value, so a larger result uses the **scratch buffer protocol**: a pointer and length, plus up to 4 extra slots. See `getScratchProperty` in `src/engine.ts`.
- Pointers are Memory64-sensitive. Prefer to return a `u64` handle.
