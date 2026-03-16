# Depthwell

Depthwell is a procedurally generated fractal mining incremental roguelite. How deep can you mine? Minimal demo releasing August 1st.

Current `README` is **incomplete**; more details will be added in the future. Read the code for specific implementation details.

### Building

Run `zig build` for the main build of Zig code, `zig test "zig/root.zig"` to run (all) tests, and `zig build --Dgen-enums` to simultaneously build and generate `enums.ts` if changes were made.

When building for production with Vite (`npm run build` instead of `npm run dev`), edit `SHADER_SOURCE` in `engine.ts` to `"./shader.wgsl"` temporarily (without the `?raw` property) to actually compress `shader.wgsl`.

With a clear-screen command that uses ANSI-escape codes, you can clear the screen every time after building:

```bash
cls && zig build --Dgen-enums
```

(Replace `cls` with `printf "\033c"` for Bash, or create a custom command in `$PATH`.)

### Architecture explanation

Chunk seeding is based on a `u4` "scale path", eliminating "repetitive" outcomes (since the entirety the "coordinate" is used for seeding a chunk). Individual blocks are seeded with the scale path plus the depth, X, and Y mixed in.

There are chunks of 16x16 blocks. Each block has 16x16 pixels. There are 16x16 places that a player can be within each pixel, meaning that X and Y of the player should be from 0-4096, but stored as i64 to allow for modulos. (See `zig/memory.zig`.)

The player can only zoom in DEEPER (hence the game's name)! This creates a neat optimization: the world can store FOUR copies of a "scale path" at any given time. The game should _error_ if the player enters a location that is not stored in a cached scale stack. To provide additional explanation:

The player is always stored as a position from 0-4095, plus an "edge array" (or "active suffix"). (See `zig/player.zig`.)

Consider an example where the maximum active suffix length is 4. Now, the "raw coordinate" of the player might be `([9, 15, 15, 15, 15, 15], [3, 0, 0, 0, 0, 0])`, plus an X/Y from 0-4096 representing where the player is in that chunk. However, the array part of this coordinate is stored as:

- Cached X: `[9, 15]`, `[10, 0]` (9, 15 "carried" to 10, 0).
- Cached Y: `[3, 0]`, `[2, 15]` (same carrying here, notice how the carrying is to the left because `[0, 0, 0, 0]` is "below average" while `[15, 15, 15, 15]` is "above average").
- Player X: false (boolean representing which cached value to use) and `[15, 15, 15, 15]`
- Player Y: boolean representing `[3, 0]`, and `[0, 0, 0, 0]`.

When zooming in, a new value is pushed to either the cache (if `current_depth` is at least 16) or it's just added to each of the quad-caches if not. The game starts out with the `current_depth` at 3. World/quad-cache implementation in `zig/world.zig`.

### Known issues

- Individual block seeding algorithm mismatch with architecture explanation
- Architecture of quad-cache not fully implemented properly

### Next steps

- Fix issues
- Implement `ModificationStore` and changing chunk cache to ask as well as a basic mousedown-to-change-block-type implementation
- Fully verify depth stack functionality, making sure it works past 16 values, making sure seeding works with it (goal is to not touch again after graphics/water work)
- Implement basic physics collision and movement, as well as nice features like coyote time
- Test perlin noise and pixel erosion
