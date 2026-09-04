# Depthwell

Depthwell is a procedural fractal mining incremental, focused around a strange, quiet world where you dig deeper and deeper into the earth. A minimal demo release is planned for late 2026 or early 2027; unimplemented features include gardening, hammerstone/pre-lathe gameplay, and a slew of other content!

> [!WARNING]
> This game is pre-demo, so any save can and WILL break at any time when core logic changes.
> Please also note this readme is **incomplete** and you'd probably want to consult the code for specifics.

### Images

![Basic game screenshot (built with creative debug options)](images/sample.png)

![Sprite sheet](public/assets/main.png)

## How to play

Stuck on how to begin?

- Left-click places blocks. Click an inventory slot to pick a block type and press the indicator above (interactable) blocks to open its menu.
- Select the pickaxe in the inventory to mine. Use WASD or the arrow keys to move.
- Look for items with an indicator above them; a furnace smelts ore into bars and there are also "cores" that allow you to upgrade your pickaxe and craft some items.
- You can't mine everything; either your pickaxe is too weak, or that block is just not mine-able. Or you're too far from that block!
    - Tip on mining distance: it simulates just the player emitting its light source to determine if you're close enough. So if another light source makes some blocks visible that doesn't indicate mineability, necessarily; a different sound is played if you're trying to mine a solid block too far away.
- You can test the portal logic wherever you want by pressing M, turning on creative, and placing a portal. Similarly you may decrease the depth through the backwards-looking, green inverted portal once you've already used the normal purple portal once!
    - Each depth is treated as its own world once you've "created" it by entering it with the portal for the first time. That means that only modifications in the highest depth affect later depths, with nothing the other way around.
    - Use the Z/X keys to skip the animation; this also ignores softlocking rules.

Press M to open or close the debug menu and the logs. Creative mode lives in that menu and makes testing simpler (and allows you to move into solid blocks)!

Inventory hotkeys:

- Backquote and 0-9 change the selected slot.
- Q moves up one row. E moves down one row.

## Building

Run `npm install` first to get `node_modules`.

Then:

- `zig build` builds the Zig code. It detects `main.aseprite` changes on its own.
- `zig build -Dgen-enums` builds and also regenerates `enums.ts` (if relavant files were changed).
- `zig test zig/root.zig` runs all tests.

Every build keeps DWARF except `-Dwasm-opt` (wasm-opt doesn't support DWARF 5 anyway).

For a production build with Vite, use `npm run build` together with `zig build -Dgen-enums -Dwasm-opt`. You can also copy what `.githooks/pre-commit` does.

See `build.zig` for the other options. The Zig Language Server in VSCode or VSCodium helps a lot (or suitable alternatives in other IDEs); set it to "watch" mode to automatically build when you apply changes. It then rebuilds the WASM for you and gives easy errors/highlighting."Go to Definition" help.

Useful things to change: `CONFIG` in `src/main.ts`, `engine.wireframeBrightness`, `engine.baseSpeed`, and the config options in `zig/state/player.zig`.

### Version control

VCS is something that's scary to a lot of people, but it shouldn't be! I partially blame Git for that (although Git works by default in this project). `.vscode/settings.json` controls whether diffs are shown.

The alternative VCS that I use is Jujitsu, which is just as complicated but **stores an irreversible local copy in case you screw up**. Sweet, right? Run `jj git init` and `jj bookmark track main --remote=origin` after you clone. To build for release, run `chmod +x ./build.sh` and then `./build.sh`. To commit to main, run `chmod +x ./push.sh` and then `./push.sh`. The Windows equivalents are a direct translation.

To auto-build Vite before each commit with Git:

```sh
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit
```

## Architecture

Game is created using Zig and WebGPU, and meant to be web-first. A final product that uses Mach Engine for native building is planned, but _web will always be free and receive updates_. The internal viewport is 480x270 (but it automatically scales with the DPI/base resolution). Functions are exported from `root.zig`.

By using `ChaCha12` and `Blake3` and a seed with 1-100 `a-z` characters, the game can generate over `10^140` possible maps, with depth and chunk sizes only practically bound by storage/RAM limits! Performance-sensitive areas are use `FastHash` (explained a lot more comprehensively in later procedural sections).

### Sizes and terms

There are 16 subpixels in a pixel, on each axis. The same 16 repeats at every level:

- 1 pixel = 16 subpixels
- 1 block = 16 pixels
- 1 chunk = 16 blocks = 256 pixels = 4,096 subpixels
- Increasing a depth by 1 would be called D+1; decreasing D-1.
    - Deeper and descend mean increasing the depth, typically by 1
    - Shallower and ascend mean decreasing the depth, also typically by 1
    - When describing physical position within a depth, standard relative terms like "above/below" or "rise/fall/climb" are used to prevent confusion with depth-related terminology.

`CHUNK_SIZE` in `zig/root.zig` is that shared 16. `CHUNK_SIZE_SQ` is 256 and `SUBPIXELS_IN_CHUNK` is 4,096. Player X and Y are subpixels and wrap inside `[0, 4095]`.

The camera and the player use integer subpixels. Entities use floating-point pixels. Generation and modifications work in blocks. To ask _where_ something is, you use chunks.

**Depth** is how deep the player is. Depth starts at 13 (`STARTING_ZOOM_TIMES` in `zig/startup.zig`). Each portal zooms the world in by 4 on each axis and adds 1 to the depth. One block becomes a 4x4 region, so 16 times the area. Deeper means a larger number.

- **D** is shorthand for the current depth. D-1 is the space you were in just before the last portal.
- **H**, the event horizon, is shorthand for D-32. Once D reaches 45 or more, the game stops tracking single blocks above H. A block at H is `2^64` times wider than a block at D, so the recursion can stop there.

Depth 13 is the **base depth**. It's the only depth built from noise instead of inherited from a parent, and the only one with a finite size.

(Interesting tidbit: at the base depth, there's a width-2 unmine-able edge stone area for the border of the world. You can easily see this when `STARTING_ZOOM_TIMES` is 0 or a small value, which is a case handled by the code.)

### Where a chunk is

Think of the world as one huge grid. Every zoom splits each cell into 4x4 smaller cells. Your position is a list of directions, one list per axis: from the top level, go to column 2, then sub-column 3, then sub-column 1, and so on. Each step is a choice of 0, 1, 2, or 3, so each step is 2 bits.

A `Coordinate` names a chunk with three parts:

- The **suffix** (`Coordinate.suffix`) holds the X and Y paths as two `u64` values. Each step is 2 bits, so one `u64` holds exactly 32 steps.
- The **prefix stack** in the `QuadCache` holds the older steps. Past 32 levels the oldest steps fall off the top of the suffix and go into `left_path` and `top_path`.
- The **quadrant** (`Coordinate.quadrant`) is a 2-bit id: 0 is NW, 1 is NE, 2 is SW, 3 is SE.

> [!NOTE]
> At depth 32 or less, the quadrant ID is always 0 and the (64-bit) suffix alone says everything.

Let's examine a specific example! At D=6 your horizontal path could be `[2, 3, 1, 0, 3, 2]`. The zoom factor is 4, so each step is one base-4 digit:

$$X = 2 \times 4^5 + 3 \times 4^4 + 1 \times 4^3 + 0 \times 4^2 + 3 \times 4^1 + 2 \times 4^0 = 2958$$

In binary that would be `10 11 01 00 11 10`, which fits the suffix.

#### What if $D>32$?

Past 32 levels the suffix overflows. Each extra depth triggers a **rebase**. The player is re-centered inside the 64-bit range and the oldest 2 bits leave the suffix. They become 3-bit origin offsets (`left_cell_x` and `top_cell_y`) in the range 0 to 6, stored in the prefix stack.

Why the odd choice of 21?

- Since $\lfloor 64 / 3 \rfloor = 21$, we pack exactly **21 historical steps** into a single `u64` integer.
- The game uses dynamic division and modulo math (`idx / 21` and `(idx % 21) * 3`) to find and extract these values on the fly.

The rebase picks the new center so that a player can travel as far as possible in any quadrant before the coordinate runs out (although in practice that is quintillions of chunks and NEVER reachable in practice, unless the debug "Teleport randomly" option gets real unlucky). If the game ever asks for a chunk that no quadrant can name, it crashes on purpose rather than showing the wrong world.

One quadrant covers exactly `2^64` chunks at the current depth. A lookback of exactly 32 levels therefore covers the whole addressable space, which is why H sits at D-32. Anything older than that is summarized in `ancestor_materials`, a 16x16 block window whose center 2x2 is the four live quadrants.

All of this holds because **the depth can only increase**. A player cannot zoom out and edit blocks. Without that rule, the rebase would open the door to block duplication.

Entering a portal does three things. It pushes the current path onto the prefix stack. It rebases the suffix and the quadrant. It clears the `SimBuffer` and regenerates the world at D+1 from the portal block's own inherited state. `pushLayer()` carries the full details.

### How a chunk comes to life

Every chunk runs the same pipeline. Every stage is a pure function of the seed and the chunk position, so a chunk regenerates the same way whether it streams in for the first time, comes back from a cache, or is rebuilt on load. A later stage only reads what an earlier one wrote. That is what keeps chunk borders consistent.

1. **Base terrain!** Each cell samples noise and picks a foundation block: a stone variation, lava stone, or air for a cave.
2. **Ores and gems.** A second noise pass lays a vein over the terrain. The overlay records the stone under it in `base_id`.
3. **Structures.** Chambers, pillars, geodes, trees, and sand or clay deposits get placed by a planner that resolves collisions. This decides _whether and where_ a structure exists.
4. **Decorations.** Plants such as mushrooms, flowers, vines, and shrubs get stamped. They only read local terrain, such as whether the block below is solid.
5. **Modifications.** Player edits and water-sim changes replay over the fresh chunk from the `ModificationStore`. This is the only stage that is not procedural, and it always wins.
6. **Later derived passes.** Edge flags and waterlogging get recomputed from the settled block ids. Lighting runs last, right before the data goes to the GPU. None of this is stored, because all of it can be rebuilt.

Steps 1 to 4 run at the base depth only. Every deeper copy is inherited, not re-rolled. See "Going one depth deeper".

When the player edits the world, the game first checks whether the tool can mine that block. It then removes adjacent blocks by the support rules described under "Multi-block groups".

### What a block holds

A `Block` is a packed 128-bit value in `zig/memory.zig`:

```zig
/// Contains a `Sprite` id and various packed properties; ready to be sent to the GPU or stored in caches.
/// Field order keeps every field inside one aligned 32-bit word so the shader (`unpack_tile()` in src/shader.wgsl) extracts each with a single per-word `extractBits()`:
/// - word0: `id` | `edge_flags` | `light_l`
/// - word1: `hp` | `seed` (the shader reads the whole word as seed0, so `hp` is folded into the seed for free)
/// - word2: `base_id` | `id_edge_flags` | `light_c`
/// - word3: `water` | `tag` | `light_h` (the shader reads `water` and `light_h`, never `tag`)
```

- `hp` means two things, and never both at once. On a solid block it is mining progress. On a liquid or a waterlogged block it is the water volume, 0 to 15.
- `water` is a packed union, not a plain bitfield. A liquid block only needs to know whether more liquid sits directly above it. A solid block needs the whole picture of the water beside and below it, for the shader's surface fill. (Later on plants will use these bits!) The block's `id` picks which view is live. All three views agree on bit 0, so any code can ask "is this cell submerged?" without knowing the kind.
- `seed` is 28 cosmetic bits. The shader and `resolveVariant()` use it, and nothing else does. It is never saved or used procedurally.
- `tag` is the block's origin once its own sprite stops saying so. See "Going one depth deeper".

#### Edge flags

`edge_flags` and `id_edge_flags` are both 8-bit "who are my neighbors" masks. The bit order reads top-left, top, top-right, left, right, bottom-left, bottom, bottom-right. **There is no center bit.** `zig/types/types.zig` names one bit per direction, from `EdgeFlags.TOP_LEFT = 0x01` to `BOTTOM_RIGHT = 0x80`. `EdgeFlags.getFlagBit(dx, dy)` maps an offset back to its bit.

The two masks answer different questions:

- `edge_flags` asks whether a neighbor is the **same kind of surface**. For a solid block, a set bit means a solid neighbor. For a liquid, it means a solid or liquid neighbor. The shader's erosion pass reads this to decide which corners to round and which edges to notch. It is what makes a wall read as one mass instead of a grid of squares.
- `id_edge_flags` is stricter. A bit is set only when the neighbor's `id` is exactly this block's `id`. It drives the ore overlay mask, so a copper vein connects to copper and not to the stone around it.

One convention matters. Decorations, air, and anything that must not erode get **both** masks forced to `0xFF` after the final generation pass. A fully surrounded block has no exposed edge, so the shader skips erosion and edge darkening. Any code that recomputes flags after mining, placing, or a water change must reapply this reset before the chunk reaches the shader.

#### Multi-block groups

There is no "multi-tile object" type. A group is just sprites that require each other. `SpriteProps.requires` and `AnchorKind` state what a sprite needs, and `Sprite.supports()` flattens that into a list.

The tall flower is the standard example. A `cornflower` cap requires a `plant_base` directly below it. A `plant_base` requires solid ground **or** another `plant_base`, so the shaft stacks itself. When the modification cascade finds a block whose required neighbor is gone, it breaks that block too. Mining the base of a plant therefore drops the whole plant. Breaking one half of a shrub drops the other half the same way.

### Procedural generation

Everything below the modification stage is a pure function of world position and seed. Nothing depends on the order chunks arrive in.

#### Hashing

`ChaCha12` is strong but slow. Calling a full ChaCha block 256 times per chunk is far too expensive, and so is `Blake3`. For 2D noise, Depthwell uses `FastHash`, a stateless multiply-mix hasher built on constants from Wyhash and SplitMix64. `FastHash.hash2d()` gives enough variance for smooth terrain and costs a fraction of a normal PRNG. `ChaCha12` still fills each base-depth block's cosmetic `seed`, in block order.

#### Terrain

The first pass picks the block type from up to six noise values. A larger cell size means the value changes more slowly:

- **Density** drives caves and wall cutouts (medium cells).
- **Cutoff** multiplies density to widen or narrow a cave mouth (small cells). It sometimes stands in for secondary density.
- **Moisture** selects the macro biome (largest cells).
- **Weirdness** controls rare stone biomes such as lava and molten stone.
- **Secondary density** varies the stone type.
- **Ore density** spreads ores and gems over the host stone.

These names are mostly arbitrary. Density determines whether a block starts off stone or simply becomes air! Some fields use FBM with tuned Worley noise, some use FBM with Perlin, and some use billow noise. The mix of cell sizes and algorithms is what makes the output varied but still visually related.

Each of those six values costs a full noise evaluation, and most blocks need only the first three. So the rules never run against a filled-in record. They run against a `TerrainSampler`, which draws density, cutoff, and moisture up front and everything else on first use. `classifyTerrain()` holds the rules as one ordered list. Each group of rules sits right after the sample it is the first to need, so the rule order is also the cost order.

- Density and cutoff alone say whether a block is stone or air.
- Only a stone block goes on to weirdness, secondary density, the ore field, and the island probe.
- The island tag, which leaves sand or clay, costs a **second** warped Worley sample a rows above the block. A block cannot answer "am I near a surface?" from its own density.

The Worley pass searches the 3x3 cells around a sample for the two nearest feature points. The gap between those two distances draws the cell edge. All nine taps are measured before any of them is compared, because measuring vectorizes and the "keep the best two" reduction does not. Each tap unpacks its feature offset and its cell weight as three 21-bit fractions out of one hash, so nine hashes buy twenty-seven values.

`zig/state/procedural.zig` holds the constants and the comptime logic.

#### Ores and gems

`ORE_DISPERSALS` is a rule palette, evaluated mostly at compile time. The name covers gems too. The compiler bakes the noise parameters and the rule limits straight into the generated WASM, so nothing walks a rule table at runtime.

An ore or a gem is an **overlay** drawn over a `base_id` stone **underlay**. Dispersal runs at the base depth and again at every deeper depth.

#### Structures

Trees, geodes, pillars, portal rooms, and chambers are structures. Each kind declares a `spawn_area` that is a power of two, and the world is tiled into cells of that size. One cell gets one placement, resolved in four stages that a kind can turn on or off:

- An initial **roll** `target_chance` decides whether the cell tries at all. It is a roll and not a density, because the stages below throw most rolls away.
- **Anchor** attempts with the structure bounding box jitters to anywhere in the cell, overhang included. Drawing the origin from the cell interior instead would leave a blank band along every cell edge and make the spawn grid visible.
- **Seating** the structure happens next: the box tries to slide down onto the terrain surface. Seating cannot be a rule. A rule tests a box that is already final, and seating is the step that decides where the box belongs.
- The structure can also simply provide custom **gate** for acceptance/rejection.

Anchor, seat, and gate retry together up to `attempts` times before the cell gives up.

The terrain rules are kept reasonably simple and not per-structure: `solid` and `empty` over a region, `level` for flat ground under a footprint, `encase` for "walled in by rock, to this degree", and `custom` as the escape hatch. (Read the `Encase` and `Region` doc comments first!)

Structures live in `zig/state/structures/` and use PascalCase file names, because they generally act more like a class than a struct! See `structures/Example.zig` for a fully commented walkthrough.

Structure coordinates are `i32` on purpose. Probing outside the world is normal here: a seat scan reaches below the box, an `encase` halo reaches around it, and `isBeaten()` resolves the cell at `cx - 1`. Signed coordinates turn an unsigned wrap into a plain bounds check in `baseSolid()`. (Do note: the use of `i32` is also primarily what caps `STARTING_ZOOM_TIMES` at 13 instead of 14 or 30.)

Anything small enough to need no collision handling belongs in the decoration pass instead, which is far cheaper.

#### Decorations

Decorations are the flavor of the world: mushrooms, spiral plants, ceiling flowers, bushes, and shrubs. They live in `zig/state/decorations.zig` and come in two shapes:

- A **point** decoration (`points`) has a fixed `size_x` by `size_y` footprint that grows right and down from its anchor. A list of terrain `constraints` gates it, using the same cheapest-first vocabulary the structures use. The list runs in priority order, so a taller kind claims its base before a shorter one can take the cell. A multi-cell kind must own its **whole** footprint, or it would draw as a fragment, such as a `moss_shrub1` with no `moss_shrub1_right`. If a higher-priority decoration claims any cell it overlaps, the lower one declines through `beatenByHigher()`. That is the decoration version of `structures.isBeaten()`. Two rivals of the same kind inside one footprint settle with an up-and-to-the-left tie-break.
- A **column** feature (`columns`), such as a spiral plant, is a chain of variable length. It anchors on a surface and grows one cell at a time in one direction until it misses a roll or reaches `max_length`. `computeColumnSeeds()` seeds the state entering each column across the chunk border, so a chain stays seamless.

Decorations read local terrain only. A mushroom needs a solid block below. A ceiling flower needs a solid block above.

The pass finishes by setting `edge_flags` on every decoration to `0xFF`, so the shader applies no erosion or edge darkening to them.

### Going one depth deeper

The real initial blocker for this game is figuring out an algorithm that makes blocks and structures at D _visually consistent_ at D+1, scaling things by $4\times$, and doing this recursively!

`zig/state/ancestor.zig` and `zig/state/refine.zig` are the files that handle this deeper-depth behavior. To build a chunk at D, the generator walks up through the parents from D-1 toward H. At each level it asks the `ModificationStore` and the `AncestorCache` whether the parent block was modified. At H it stops asking about chunks and reads the `QuadCache` material grid instead.

**Materialize is not the same as generate.** `generateChunk()` is pure procedure that ignores user modifications. `materializeChunk()` is that plus every `mod_store` edit replayed plus a flag recompute. It is the only supported way to turn a store entry into a `Chunk`!

Once a parent block is known, `applyAncestorLogic()` decides what each of its 16 children holds through a few methods:

- **Carving!** A solid parent does not become a solid 4x4 square. `carvesSlope()` deletes edge cells so the parent's silhouette reads as a slope. The center 2x2 **core** is never carved, so a descent always has floor to land on.
- **Warp!** `warpedMaterial()` can pull a neighbor's material a short distance into this region, so a material border is ragged instead of square.
- **Refine!** A decoration is not terrain. Filling all 16 cells with a bush gives 16 bushes. So each such sprite states a _plan_ for its region and `refineChild()` answers one cell of it. A plan is `single` (one copy, such as a chest or a portal landing), `scatter` (1 to a few copies along the anchor row), `chain` (a hanging vine, deduplicated and length-capped), or `stamp` (a hard-coded shape, such as the little tree a 2x1 shrub becomes). Every plan keeps at least one copy, so a decoration never disappears as the player descends.
- **Ore/gem inheritance.**
    - An inherited **ore** keeps a cell based on how much of the same ore surrounds its parent. `overlaySupport()` reads the parent's 3x3 neighborhood as a coarse density field and samples it per child cell, so a vein grows along itself and a lone nugget frays into a ragged clump. A parent buried in its own ore keeps every cell.
    - **Gems** keep about `GEM_COPIES_MEAN` cells out of 16 instead. Both kinds always keep at least one of its ore/gem at D+1.
- **Disperse.** Fresh ore also gets dispersed at the new depth, exactly as it does at the base depth.

`RefinedTag` also handles the "memory" of each`Block` that recos where the block came from once its own sprite no longer says so; for example, this is used for a cell of a hanging chain and how far below the ceiling it sits, or growing moss shrubs into solid blocks (and blocking ores from spawning in said solid blocks)! Note that this can be re-derived from `ancestor_materials` and caches.

### Storing modifications

To have a fractal _mining_ game, the world has to remember player edits. That reduces to one question per chunk:

> Does this chunk hold any block the player replaced?

Air counts as a block type. If the answer is yes, the chunk gets an entry in the `ModificationStore`, keyed by a `DepthCoordinate`. A `DepthCoordinate` is a `Coordinate` plus a depth.

The design targets were:

1. Be able to read existing modifications for a rectangle of chunks, about 1000 reads per second. Some frames need 16 to 32 new chunks in the `SimBuffer`.
2. Write a new modification at 60fps, handling adjacent edge flag updates as well!
3. Increase the depth in under 3 seconds.
4. Keep heap fragmentation and allocation churn low.
5. Hold the whole state in RAM.

Because of this, a modification is **sparse**. Instead of a 4 KiB `Chunk`, a `ModEntry` holds a `modified` bitmap with one bit per block, plus a packed `ModCell` array in ascending block-index order. A chunk with 30 mined blocks costs a few hundred bytes, not 4 KiB.

A `ModCell` holds only the three fields that regeneration cannot recover:

```zig
/// One modified cell: the only `Block` fields that cannot be recovered by regenerating the chunk.
pub const ModCell = extern struct { id: Sprite, base_id: Sprite, hp: u8 };
```

`base_id` is there because the player can place a solid block and then replace it with an ore, which sets the underlay to the placed block.

Everything else is derived and gets rebuilt by `materializeChunk()`. `edge_flags`, the light channels, `water`, and `tag` all come from the flag and lighting passes. `seed` comes from the chunk's own seed lane, and a replayed cell takes a fresh one, because the cell under it may have generated as air.

`ModEntry` also carries a `descendants` bitmap with the same layout. A set bit means the block's descendant region holds a modification at some deeper depth. `markDescendantsFromChild()` grows it one depth per ascent and never clears it.

The store itself maps a `DepthCoordinate` to an index into an append-only `SegmentedList` of entries. Indices stay valid for the life of the store, which the budgeted save depends on. Removing a chunk's edits recycles its slot, but the list never shrinks. `beginWrite()` is the only way to mutate the store.

Cost:

- Reading is amortized O(1), because only depths D-32 to D matter.
- Writing is amortized O(1), because it is a hash map write.
- Increasing the depth is O(1). Nothing is culled, which also allows a spectator view on death.
- Space is O(n) in modified **cells**, not chunks. A `ModCell` is 6 bytes.

### Chunk streaming

The `SimBuffer` is a fixed 16x16 chunk window, 256 chunks, that always exists. It follows the player and holds everything the game simulates.

The camera can outrun it. A fast frame can ask for a chunk outside the buffer, so the game first looks in the `SimBuffer`, then in the `ChunkCache`, and only then generates the chunk on the spot.

Generation is actually quite expensive! Each block needs several FBM and Worley passes, so the engine generates only **two** chunks per frame, or four when the player moves quickly. Startup and a depth change use different logic. Every frame, the game engine does this:

1. Read the player velocity to find the leading edge, and prefer chunks directly ahead over chunks to the side.
2. Fill a 68-chunk ring just outside the visible screen, so a chunk is ready before the player walks into it.
3. Put every finished chunk the renderer touches, and every chunk generated for the `SimBuffer`, into the `ChunkCache`. Reading a chunk _out_ of the `SimBuffer` does not touch the cache.

This removes frame spikes (and still provides a pretty large buffer). Without it, a single frame could owe the `SimBuffer` 16 chunks. It changes no logic: a player can still teleport trillions of chunks away (at a flat cost of regenerating 256 chunks), and the old chunks simply age out of the cache. Plus, water simulation can easily stay confined to just work within the SimBuffer!

#### How fast is fast enough?

A good rule of thumb: can a teleport to a random place, or a world reset, finish in under one second on a mid-range laptop? Both force the `SimBuffer` to build all 256 chunks.

The budget is 4 chunks per frame, so one chunk must take about 4 ms. That gives $4\text{ ms} \times 4 \text{ chunks} \times 60 \text{ fps} \approx 1 \text{ second}$. The debug UI shows the worst frame every second which makes it really easy to test this out visually by spamming Reset or Teleport.

Single-core speed and thermal throttling both matter, so check the device, not only the math. The "mid-tier mobile" throttle in DevTools is a reasonable proxy. Mobile is not a target. Test in ReleaseSafe, or ReleaseFast (`wasm-opt` optionally; doesn't give huge gains). Depthwell currently has plenty of headroom.

### Scary specifics on caches

Worldgen is a pure function, so the same coordinate always gives the same block. Even the base depth holds about $2^{60}$ blocks so there's no way to store everything upfront!

Caching whole chunks is not enough on its own. The Worley and FBM work per block dominates. Remember the "one second for 256 chunks" target.

Every cache sits in static WASM memory with a fixed budget, so nothing grows without bound and nothing fragments the heap.

**The access pattern decides the shape of a cache, and nearly every pattern here is a sweep.** A sweep visits a rectangle of cells in order and then visits the same rectangle again: the generator walking a chunk, the halo walking its border, the renderer redrawing the window each frame. Total capacity is the wrong thing to measure for a sweep. What matters is whether two cells that are live at the same time can land in the same slot.

That is why most caches are **direct-mapped and tiled** through `dw.utils.tileIndex()` (rather than a multi-associative cache or similar). A cell's slot is its position wrapped into a power-of-two tile, never a hash. Two cells share a slot only when they sit a whole tile apart. So as long as the tile is bigger than the sweep, the sweep has **zero** conflicts by construction. A chunk and its halo cannot evict each other.

Invalidation splits them into two families. Some **self-invalidate**: each entry stores the identity it was computed under, and a read that does not match recomputes. The rest get **dropped** by `world.clearCaches()`, which runs on a depth change or a reseed. The main hazard is here: any debug slider that moves terrain must set `regen = true`, or the slider moves and the cached samples do not.

From shallowest to deepest:

| Cache name                      | Holds                                                                                                                | Shape                                                                                                                       | How do I clear this cache?                  |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- |
| `procedural.base_terrain_cache` | The raw terrain sample at one base-depth block: which stone, and `ore_density` value.                                | Tiled 256 blocks across by 128 down. 32768 entries of 16 bytes, 512 KiB.                                                    | Self-cleared, against `terrainGeneration()` |
| `world.foundation_cache`        | The finished base-depth block: terrain+ores+structures.                                                              | The same tile as above, on purpose, because one sweep reads both.                                                           | Self-cleared, against `terrainGeneration()` |
| `structures.struct_cache`       | One cache per structure kind, holding the box in each cell of that kind's spawn grid with the terrain rules applied. | Tiled 32 by 32 grid cells. A cell is `spawn_area` blocks wide.                                                              | Self-cleared, against seed and generation   |
| `structures.chunk_ctx`          | Every structure that can reach into one chunk, resolved once per chunk instead of once per block.                    | Tiled 16 chunks across by 4 down.                                                                                           | Self-cleared, against seed and generation   |
| `QuadCache.seed_cache`          | The four seeds of one chunk, mixed from its quadrant seed, suffix, and depth. Cheap, but asked for constantly.       | 4-way hash, 256 entries.                                                                                                    | `clearCaches()`                             |
| `ancestor.chunk_noise`          | The two seed streams every cell of one chunk shares.                                                                 | Exactly one entry.                                                                                                          | `clearCaches()`                             |
| `ancestor.ancestor_cache`       | Whole materialized chunks at parent depths. This is what recursive generation reads.                                 | 8-way with CLOCK eviction, indexed by _distance_ from D. The two nearest depths get 128 slots, the rest get 8. About 2 MiB. | `clearCaches(true)`                         |
| `ancestor.parent_hood_cache`    | A parent block and its eight neighbors. 64 sets of 4.                                                                | The other deliberate hash.                                                                                                  | `clearCaches()`                             |
| `world.chunk_cache`             | Finished chunks at D. The only cache the renderer reads.                                                             | Tiled to the widest window the camera can ask for (see notes below).                                                        | Replaced in place                           |

Additional notes on the caches:

- **Caches only memoize/cache parts of procedural output**: before `ModStore`. Player edits stay a separate overlay that `materializeChunk()` replays on top.
- For `world.chunk_cache`, the dev build (which has the minimum camera zoom 10 times smaller than normal!) has 64x32 chunks, 2048 slots, 8 MiB.
- `foundation_cache` shares a tile with `base_terrain_cache` because the chunk generator and its edge-flag halo both come through it. That is how an ore vein stays connected across a chunk border instead of being cut in half.
- `struct_cache` matters because the same cell is constantly re-derived by every block inside the footprint AND collision scans.
- `parent_hood_cache` is a hash on purpose. All 16 child cells of a region share one parent cell, and each used to walk the same nine lookups, so this turns 144 resolutions into 9. Tiling would be actively wrong: the nine cells of a neighborhood are **adjacent**, so a tile would have them evict each other on the very next child cell. The victim is plain round-robin, because a sweep gets nothing from recency.
- `chunk_cache` is what also what the camera falls back to whenever it outruns the `SimBuffer`, whether the player moved fast or zoomed out; it's automatically sized to handle large camera values at compile-time in practice.
- The prefix stack follows the same idea one level up. Each level of the stack stores its own 512-bit seed, so the game never re-hashes a 10,000-level BLAKE3 chain. It hashes only the newest step. That makes a depth change effectively constant time.

#### What they cost, and what a small tile does

Every cache is a fixed-size static array, so its worst case is its only case!

| Cache variable name  | Bytes                                          |
| -------------------- | ---------------------------------------------- |
| `ancestor_cache`     | 2 MiB                                          |
| `chunk_pool`         | 1 MiB (9 MiB with dev menu camera cap)         |
| `base_terrain_cache` | 512 KiB                                        |
| `foundation_cache`   | 512 KiB                                        |
| `struct_cache`       | 512 KiB                                        |
| `parent_hood_cache`  | 192 KiB (wide margin to reduce collision odds) |
| `chunk_ctx`          | 111 KiB                                        |
| `quad_cache`         | 115 KiB                                        |
| `chunk_cache` keys   | 96 KiB                                         |
| `chunk_noise`        | 32 B                                           |

Some dynamic allocations sit near these and **do** scale with the camera. The visible block buffer is 16 bytes a block, or 5 MiB at the widest dev window. Lighting adds a cost grid and three lanes over the same area. A portal descent's preview buffer is sized for the overlay's widest footprint, which is tens of MiB at full dev zoom-out. None of them is a cache.

Note that a tile that is too small never returns the wrong block, so caches are **always safe**. Every cache compares the full key it stored, and the tile index is total, so every coordinate has exactly one slot and there is no "outside the cache" to fall off. A collision produces a miss and a recompute. A wrong tile is merely a performance bug, never a correctness one!

What it costs depends on the intrusion:

- **A stray far read**, such as a debug jump or a probe outside the camera, costs exactly one eviction. Whatever it displaced comes back on its next miss. A direct-mapped slot has nothing to spill into, so there is no cascade.
    - (Keep in mind all per-frame logic, such as water, should naturally remain in the confines of the `SimBuffer`!)
- **A sweep wider than its tile** wraps onto itself. A sweep touches each cell once, so this costs nothing within a pass. It only means the next pass cannot reuse what the last one left. That is what a portal ascent does, and why `chunk_cache` does not size for it.
- **Alternating between two cells a whole tile apart** is the one genuinely bad pattern, and it misses every time. No loop in the engine does this. Keeping it that way means keeping each tile at least as large as the sweep it serves, and each cache has a `comptime` check that states its sweep.

One ordering rule falls out of direct mapping and is easy to miss: **caches entries should be claimed after filling, never before.** The slot is fixed by position, so a nested fill of anything a tile away lands on the same slot. A key written up front would still be sitting there, naming a chunk whose blocks the outer fill has since overwritten. Every cache writes its key and its value in one assignment at the end, `ChunkCache.fill()` included.

### Light system

`zig/render/lighting.zig` computes light on the CPU every frame, after the visible block buffer is built and before it goes to the GPU. Every block gets a full **OKLCH color** packed into three 6-bit channels: `light_l`, `light_c`, and `light_h`.

The shader multiplies the block's own OKLAB lightness by `light_l`, so 0 is pitch black. It **adds** the chroma, so a violet lamp tints a block without replacing its material. Stone under a violet lamp is still recognizably stone.

A second, player-only flood also limits how far the player can reach to modify blocks.

Depthwell propagates light with an inverted **Dijkstra flood** over a radix heap, not with an additive light map or a FIFO queue. Light is represented as decay, so a bright cell has low decay. The heap pops cells from lowest decay to highest, which finalizes each cell at its brightest value on the first visit.

How much light one step loses depends on what it passes through:

- **Air** loses the least (`AIR_FALLOFF = 12`), so light carries far through open space.
- **Solid** loses the most (`SOLID_FALLOFF = 28`), scaled by `hp`. A nearly broken block passes almost as much light as air.
- **Liquid** sits between them (`LIQUID_FALLOFF`, 12 below solid). A waterlogged block is capped so it never blocks more light than water would.

A diagonal step costs `sqrt(2)` orthogonal steps, in integer math. An 8-neighbor grid can only draw an octagon, and `sqrt(2)` is already the ratio that fits a circle best. A real circle needs a 16-neighbor chamfer, which roughly doubles the flood and lets light jump one-block walls, so it is not worth it.

The sources are the player, campfires and furnaces (warm orange), portals (violet), aquashard and electrit (cyan and gold), twinklemoss (green), and glowing plates (white). The player light is seeded from their continuous subpixel position across the 2x2 blocks they overlap. `blockEmission()` is the whole table.

A source just off-screen can still spill onto visible blocks, so the block buffer is padded by `CHUNK_MARGIN`. That value is computed at compile time from the furthest reachable bleed.

#### How color survives a shortest-path flood

Dijkstra finalizes a cell once, at its brightest value. A second, dimmer light of a different hue never gets to contribute, which is exactly the mixing you want. The old system used two channels and a hard "which is brighter" test per block, and the line where that answer flipped was visible.

The way out is that **falloff belongs to the medium, not to the light's color**. Air, stone, and water cost what they cost no matter what shines through them. So one colorless cost grid serves every color, and the only per-color quantity is how much light arrives.

Light therefore splits into three **lanes**, at fixed hues spaced evenly around the OKLAB hue circle. A source states a hue and a saturation. `laneWeights()` turns that into one weight per lane, scaled so the strongest lane always carries the full brightness. A white lamp lights all three lanes equally. A violet lamp lights mostly one. Each lane floods over the shared cost grid, and `resolveCell()` reads the color back from how the three lanes compare: the strongest lane is the brightness, and the other two say which way the hue leans.

Three results fall out of that scaling, and they are the whole reason for it:

- A violet lamp lights **exactly the same shape** as a white lamp of the same strength, because the dominant lane always carries the full value. Color never changes reach.
- Every lane's field is continuous, so their ratio is continuous, so the hue varies smoothly. Two lamps of different colors blend through every hue between them, with no seam.
- A lane costs only the ground its own light covers. A mostly warm scene costs barely more than the two channels it replaced.

Two limits are worth knowing. A lane cannot go negative, so three lanes can only state the colors inside a hexagon. `CHROMA_GAMUT` clamps to its inscribed circle, so saturation means the same thing at every hue. And because falloff is subtractive, the weak lanes of a saturated source reach zero before the strong one does, so a lamp gets a little more saturated toward its fringe. `CHROMA_WHITE_MIX` caps that drift by pulling every source slightly toward white before the split.

The player-only flood behind `miningLightAt()` stays colorless on purpose. Mining reach is a gameplay quantity, so it runs one lane at the player's full strength.

#### From block light to pixel color

Lighting solves one value per block, so reading a tile's own value gives a 16-pixel mosaic. The fragment shader instead blends the four tiles nearest each pixel, sampling on tile centers (`sample_light()` in `src/shader.wgsl`). Lightness and tint both become gradients. It costs three extra tile loads per pixel.

The tint travels through that blend as an OKLAB (a, b) vector, not as a chroma and hue pair. A hue is an angle, and blending two angles walks the hue circle through colors that no light in the scene ever had.

Two shader constants exist because OKLAB lightness is not brightness:

- `TINT_LUMA_GAIN` gives lightness back in proportion to the warm tint added. At a fixed L, a warm color renders with less luminance than a gray one. Without the correction, the band where a lamp's color takes over from white light reads as a dark ring.
- `MATERIAL_CHROMA_FLOOR` is the share of its own chroma a block keeps where no light reaches it. Draining it all the way to zero turns every dim block gray, and a gray band beside a colored one also reads as a dark ring.

## Rendering

### Why WGSL

WGSL has less browser support than WebGL 2, but it lets the engine manage GPU memory directly and it is the more modern standard. It is also far faster than `drawImage()` and can do much more (such as the background effect).

Zig holds as much state as possible. Zig generates the data, pans it, converts it to `f32` so WebGPU hits no precision problems, and writes it into the scratch buffer. The shader simply reads from their and its job is to go fast.

### Memory transfer

The TypeScript host and the Zig core share a planned memory layout:

- The **scratch buffer** is a large, growing shared heap for high-bandwidth transfers, mostly chunk drawing.
- The **scratch properties** are an array of 20 64-bit slots for metadata, also used for chunk drawing.

A WASM call returns one value, so a larger result uses the scratch buffer plus up to 4 extra property slots. `getScratchProperty()` in `src/engine.ts` is the host side. Pointers are Memory64-sensitive, so prefer returning a `u64` handle.

### Entities

An entity is a generic sprite draw with a color shift, a rotation, and a size:

```zig
/// Entity data (before being sent to WGSL, using internal viewport).
/// Allows for size, rotation, and OKLCH + alpha (opacity) changes to any chosen sprite.
pub const Entity = struct {
    /// The light, chroma, hue, and opacity components.
    /// L (lightness) and alpha components are multiplied by the sprite's color in WebGPU.
    /// H (hue, in radians) and C (chroma) are shifted additively.
    lcha: Vec4f32 = DEFAULT_ENTITY_LCHA,
    /// Current center position of the sprite (based on internal viewport).
    position: Vec2f32,
    /// The size of the entity (based on internal viewport).
    size: f32 = 16.0,
    /// The rotation of the entity (radians).
    rotation: f32 = 0.0,
    /// The sprite type of the entity to use.
    sprite: Sprite = .none,
};
```

`WGSLEntity` in `zig/render/entity.zig` is the packed form sent to the GPU. It carries the same fields in UV space instead of viewport pixels, plus the sprite ID.

Entities draw in order, so a shadow is just the same sprite drawn first, offset and darkened:

```zig
for (0..10) |i| {
    addEntity(.{ // draw the shadow of the inventory slot
        .sprite = if (i == selected_id) .inventory_selected else .inventory,
        .position = getInventoryPos(i) - Vec2f{ 2, 2 },
        .lcha = .{ if (i == 0) 0.8 else 0.7, 0.0, 0.0, 0.9 },
    });
}

for (0..10) |i| {
    addEntity(.{ // draw the slot itself
        .sprite = if (i == selected_id) .inventory_selected else .inventory,
        .position = getInventoryPos(i),
    });
}
```

(Note that `addEntity()` takes a viewport-pixel center and a pixel size. `addEntitySized()` takes UV by default, and its `system` field selects the space.)

Number use `drawNumber()`, which takes the same `lcha`. Because L and alpha multiply while C and H add, a white sprite works as a mask: give it a chroma and a hue and it takes that color exactly! This is the sneaky trick particles/rectangles/text uses: all the pixels are pure white so it basically becomes an OKLCH selector.

### Sprite variation

A `Block.id` is only the **base** tile. `resolveVariant()` in `zig/types/variation.zig` resolves the tile that is actually drawn, once per visible block per frame, on the CPU after lighting and before upload. (Most sprites resolve to themselves; keep in mind visual variation doesn't change the internal `Sprite` type; that's a render-only thing.)

It is a data-driven table. Each sprite maps to at most one `VariantRule`, and every variant frame sits at a consecutive atlas id, which a comptime check enforces. The kinds are:

- `grid_2x2` and `checkerboard` tile by tile-coordinate parity, so plain stone reads like a 32x32 texture instead of an obvious grid.
- `x_parity` and `y_parity` alternate along one axis.
- `random` picks a frame from the block's `seed`, biased toward the base frame. This gives mushrooms and bushes quiet variety.
- `animate` cycles frames on a fixed `period_frames` cadence, for campfires and hovering cores.

A rule can also carry `edge_rules`, which match a 3x3 neighbor pattern first and then choose a kind. Dirt uses this to pick a top, middle, or lone tile.

Variation is visual only, and it is seeded per block. Multi-tile features are **not** variation. They are separate sprites glued by the support rules under "Multi-block groups".

Ore and gem rendering is more involved and uses image masks, described below.

### Shader tricks

The shader is where the visual detail comes from. Several effects look expensive and are not.

#### Seeding

The shader takes the block's 28 seed bits together with its 4 `hp` bits as `seed0`. It runs `murmurmix32` three more times to get `seed1` through `seed3`, so every block on screen has four independent streams. The last two drive erosion and edge flags. (This was kept faithful with old WGSL code so Mach Engine/future logic can be re-GPU-ified.)

#### OKLAB

RGB lighting looks muddy or gray when darkened or desaturated. Depthwell does all color work in **OKLAB** and **OKLCH**, except for the background effect.

When the shader samples a tile from the atlas, it converts it from linear sRGB to OKLAB right away. It then nudges lightness, chroma, and hue from the block's seed. Two stone blocks of the same type therefore differ slightly by position.

#### Procedural erosion

Instead of thousands of hand-drawn wall sprites, Depthwell draws one foundation sprite and erodes it. This also means far fewer sprites to draw by hand.

The fragment shader reads `edge_flags` to find pixels near an air neighbor, then uses `seed2` and `seed3` to:

1. Round the corners with pixel-perfect arcs, for both outer and inner corners.
2. Notch straight edges in or out by 1 to 2 pixels.
3. Darken the edge with a curved shadow gradient, which gives the world depth with no hand-drawn shading.

#### Gems and ores

Ores and gems are rendered using a multi-texture "masking" trick to save atlas space. For a gem block:

1. The shader samples the background stone based on the block's world coordinates (preserving the 2x2 tiling).
2. It calculates a shifted UV for the gem itself using 8 bits of the seed, allowing the gem to appear at any of 256 sub-pixel offsets within the block.
3. It samples a gem mask and mixes the stone and gem colors based on the mask's red channel.
4. Finally, it applies a random horizontal/vertical flip to the mask, ensuring that even gems with the same offset look distinct.

#### Background and water

The background is not simply a static image looping, but instead uses multi-octave fractal brownian motion! The octave count is low for performance; three layers parallax at 8x, 32x, and 64x slower than the camera: for every 64 pixels the player moves, they move 8, 2, and 1 pixels. Every layer has its own colors and it intentionally uses RGB mixing, not OKLAB, for simplicity. (This additive/composition effect is actually quite wanted here!)

The background are now evaluated once per background pixel, not once per canvas pixel. A background pixel is one world pixel, the grid a block sprite's texels sit on, drawn as one instanced quad with a flat color, so the cost follows the camera zoom instead of the resolution. `publishBackgroundGrid()` in `zig/render/chunk.zig` sizes that grid.

Think of the sample position as `(chunk id + sub-chunk position) modulo 512`, with coordinate warping and a trig-based light at the end.

Water uses the same kind of wrapping, based on the chunk and subpixel position, modulo 256 instead of 512. `zig/render/chunk.zig` covers the export side.

### Water simulation

Water is a cellular automaton in `zig/state/water.zig`, run over the loaded `SimBuffer`. There is no separate water grid. A cell's volume, 0 to 15, lives in the block's `hp`. On a solid block `hp` is mining progress instead, so the two never coexist (they're "exclusive" properties).

Water exists both as full `water` blocks and as **waterlogging** inside decorations and crafters, meaning anything that answers `isWaterloggable()`. That lets a pool soak through a bush without deleting it.

The core rule is **mass conservation**. `tickWater()` only moves volume between cells inside the `SimBuffer`. It never creates or destroys volume. The debug flag `VERIFY_WATER_MASS` asserts the total is stable each tick.

A tick runs in phases:

1. Collect chunks that hold water and have not settled. If there are none, skip the whole tick.
2. Sweep active chunks bottom-up, so falling water moves one cell per tick and is not moved twice. The `water_updated` bitset guards this. Then spread sideways, tracked by `lateral_received`. Record every changed cell in `cells_changed`.
3. Mark chunks that saw no movement as settled. Future ticks skip them until something disturbs them.
4. Recompute `edge_flags` and the waterlogged masks for every chunk touched this tick, plus any chunk queued by `queueWaterFlags()`. This keeps the shader's surface fill, ripples, and left-right interpolation correct.

Volume travels between blocks whose neighbors can live in an adjacent chunk, so both the sweep and the flag pass reach across chunk borders inside the `SimBuffer`. Only cells the sim actually moved get persisted. A large calm ocean therefore costs almost nothing per tick, and a settled body drops out of the active set.

## Saving and loading

`zig/state/save.zig` serializes the whole game state into one versioned, self-describing binary blob. Zig builds the blob in a persistent buffer. The atomic write to OPFS, and the per-frame budgeting that drives it, live on the JS side.

The layout is little-endian:

- The magic `"DWSV"`, then a `VERSION` u32 packed from `parseVersion()`.
- A run of **sections**, each `tag u16 | section_version u16 | byte_len u64 | payload`. The tags are `sprite_table`, `header_core`, `quadcache`, `inventory`, `menus`, `tools`, `misc`, and `mod_store`. Tag numbers are never renumbered or reused. New tags only append.
- An `.end` marker with tag 0, then a 32-byte **BLAKE3** hash over every preceding byte. A truncated or corrupted file is rejected on load.

Two ideas keep saves cheap and robust:

- **Sprite ids are stored by name, not by enum ordinal.** The `sprite_table` section is written first, so the loader can map the raw ids in `mod_store` cells back to names and resolve those against the running build's `Sprite` enum. Adding or reordering sprites therefore never invalidates a save. A name the current build does not know degrades to `.none`.
- **`mod_store` stores only modified cells**, exactly like the in-memory `ModEntry`. Everything else is regenerated on load through `world.materializeChunk()`. Each chunk record is variable-length.

A big save cannot block a frame, so `mod_store` is written **budgeted** over many frames:

1. `beginSnapshot()` writes the header and every small section, all captured at that instant. It opens the `mod_store` section and freezes a _plan_: the key and entries index of each modified chunk.
2. `writeBatch(n)` encodes up to `n` chunks per call until the plan is drained.
3. The store is copy-on-write against the plan, so the multi-frame snapshot stays atomic while the player keeps mining. When the game is about to mutate a planned but not yet encoded entry, `shadowEntryForSave()` stashes that entry's start-of-snapshot payload in a side map, and the batch encodes from the shadow. The blob therefore shows the world exactly as it was at `beginSnapshot()`.
4. A hard wipe of `mod_store` mid-snapshot, from a new game or a load, bumps its `generation`. The snapshot compares against that and aborts.

One guard sits above all of this. `in_tick` is set while a simulation tick is mid-flight, and both `exportAll()` and `beginSnapshot()` refuse to serialize while it is set. A half-applied tick can be invalid, and aborting beats saving something wrong.

## Copyright

Copyright (c) 2026 Leo Zhang. All rights reserved. Distribution of any portion of the code or raw assets without explicit written permission is strictly prohibited.
