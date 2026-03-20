# Depthwell

Depthwell is a procedurally generated fractal mining incremental roguelite. How deep can you mine? Minimal demo releasing August 1st.

> [!WARNING]
> The current `README` is **incomplete**, as this game is still in the pre-demo stage; more details will be added in the future and details might currently be out of date. Read the code for specific implementation details.

### Building

Run `zig build` for the main build of Zig code, `zig test "zig/root.zig"` to run (all) tests, and `zig build --Dgen-enums` to simultaneously build and generate `enums.ts` if changes were made.

When building for production with Vite (`npm run build` instead of `npm run dev`), edit `SHADER_SOURCE` in `engine.ts` to `"./shader.wgsl"` temporarily (without the `?raw` property) to actually compress `shader.wgsl`.

With a clear-screen command that uses ANSI-escape codes, you can clear the screen every time after building:

```bash
cls && zig build --Dgen-enums
```

(Replace `cls` with `printf "\033c"` for Bash, or create a custom command in `$PATH`.)

#### Game design philosophy

- **Gameplay** first. Quality and features arise naturally from focusing on gameplay.
- **Quality** is fundamental to a game. Prioritizing a vertical slice means a more interesting game.
- **Polish** is necessary, even for a demo. When implementing the behind-the-scenes gets boring, polish is something else that may be tended to.
- **Art** is a gradual process and comes in many forms: pixel art, backgrounds, shaders. Gameplay design can get tiring and polish/quality through art retains development interest.

### Architecture goal and details

Game is created using Zig and WebGPU, and meant to be web-first. A final product that uses Mach Engine for native building is planned for 2027, but _web will always be free and recieve updates_. The internal viewport is 480x270 and scaled up in WebGPU automatically. Functions are exported from `root.zig`.

By using `Xoshiro512**` and a max seeding of 100 `a-z` characters, the game can generate over `10^140` possible maps, with basically no depth limit (the limit is most likely memory, not performance) that allows for near-infinite exploration.

The architecture _implementation goal_ (TODO finish) for Depthwell is to use a **segmented fractal coordinate system** to manage near-infinite depth and modification persistence across scales without performance degrading.

#### Architecture philosophy
- **Consistency** globally, even for edge cases. The best implementation is one that players cannot notice and (hopefully) cannot break.
- **Performance** is key. Use DoD and make as many math operations fast and constant-time as possible.
- **Extendability**. Architecture should be able to be built upon in the future.

#### Coordinates

Here are the basic terms (note that there are, for example, 16 possible subpixels for both the X/Y coordinates for a pixel, so these are for one dimension):

- 1 Pixel = 16 Subpixels
- 1 Block = 16 Pixels
- 1 Chunk = 16 Blocks = 256 Pixels = 4,096 Subpixels

Things like the camera and the player concern themselves with subpixels. Seeding of specific blocks in chunks and modifications concern themselves with blocks. Asking something "where" it is involves just chunks (see later).

Now, bear with me here, because you might be freaking out over the fact a code segment just appeared. But don't fret, I'll break things down! This code is just those interested in specific details on what these numbers _could_ mean, because there are a lot of definitions

Basically, all the code below is doing is declaring some constants in Zig, a fancy low-level language. The `SPAN` variable just represents 16; you don't really need to understand the code blocks so feel free to skip these. From `zig/memory.zig`:

```zig
/// The main number (as an integer) representing the number of blocks in a chunk, number of pixels in a block, and number of subpixels in a pixel.
pub const SPAN: comptime_int = 16;
// ...
/// An integer representing the number of subpixels in a block, pixels in a chunk, number of blocks in a chunk, number of pixels in a block, and number of possible subpixel positions within a pixel.
pub const SPAN_SQ: comptime_int = SPAN * SPAN;
// ...
/// An integer representing the number of subpixels within a chunk. The player's X and Y coordinate should wrap around such that it is between 0 and this value (inclusive).
pub const SUBPIXELS_IN_CHUNK: comptime_int = SPAN * SPAN * SPAN;
```

Now, we move on to locations (which also has some technical jargon, but I'll explain). Locations (named `Coordinate` internally) are addressed via a struct like this:

- **Prefix stack:** A memoized history of seeds and path-nibbles.
- **Active suffix (`u64`):** The spatial chunk-coordinate at the current depth. (`u64` means 64-bit unsigned integer, allowing $2^{64}$ possible values.) This is really `[16]u4` (16 numbers between 0-15) squashed together.
- **Quadrant ID (`u2`):** Identifies which of the 4 static $2^{64}$-wide quad-caches we are "using" for the prefix stack. Each Quad-Cache (QC) references a specific Prefix Stack.

> [!NOTE]
> Important detail! If the `depth` is at or below 16, the quadrant ID is useless and will defaults to 0. Any processing of the active suffix will first determine the current depth and also "crop" the suffix.

The reason all this quadrant logic works is because of one essential fact: **_The `depth` can only INCREASE!_** The player can't zoom out, which is the main reason this quad-cache assumption is safe.

You can imagine the actual location of something as a "smashed together version" of the specific QC's prefix stack. Consider an example where the maximum active suffix length is 4 (so like `[4]u4`).

To clarify, `[4]u4` isn't some weird Zig magic, it just represents an array (or collection) of 4 values, between 0-15. So, `[1, 2, 3, 4]` would be an example of the `[4]u4` type. Do note that it’s really stored as just one `u64` but it logically represents up to 16 values between 0-15.

Now, the "raw coordinate" of a player (or anything we want to represent, such as the chunk an NPC is in or what chunk has been modified) might be `([9, 15, 15, 15, 15, 15], [3, 0, 0, 0, 1, 1])`, plus an X/Y from 0-4096 representing where the player is in that chunk.

This would actually internally look like this for the caches (the quad-cache is the same for all players/NPCs/enemies):

- Cached X: `[9, 15]`, `[10, 0]` (9, 15 "carried" to 10, 0. Don't worry about carrying details too much for now, I'll explain more later!)
- Cached Y: `[2, 15]`, `[3, 0]` (Same carrying here, notice how the carrying is to the left because `[0, 0, 1, 1]` is "below average" while `[15, 15, 15, 15]` is "above average", basically a midpoint split/weight-adjusted quad-partitioning)
- However, since there are 4 combinations of cached X and Y, there are 4 quad-caches (so combinations $X_1Y_1,X_2Y_1,X_1Y_2,X_2Y_2$ for example), with the seed cached for each combination. Each quad-cache "points" to a combination, so the possible X/Y values aren't stored twice.

And here would be the `Coordinate` (again, assuming that the active suffix is only 4 `u4`s long, when it normally would be 16):

- Coordinate X: `[9, 15, 15, 15]`
- Coordinate Y: `[3, 0, 1, 1]`
- Quadrant ID stuff:
    - Coordinate X: false (boolean representing which cached value to use), for `[2, 5]`.
    - Coordinate Y: true, for`[3, 0]`.
    - What happens is you encode this into a value between 0-3 (hence the `u2`), so if we consider false = 0 and true = 1, then the result is $C_x+2\times C_y$ (where $C_x$ is coordinate X and $C_y$ is coordinate Y). Then you can "extract" the boolean out from this quadrant ID with bitwise logic, for example. (This is internally stored as a `u2`, with the coordinates as a `@Vector`.)

(Note that "expanding" these cached values is invalid in practice. These are really just one larger number, but it helps to separate these out when explaining. Also, this glosses over some details when the prefix stack is empty because the active suffix can successfully represent all possible places the player is in.)

When zooming in, a new value is pushed to either the cache (if `depth` is at least 16) or it's just added to each of the quad-caches if not. The game starts out with the `depth` at 3. You can find specific implementations of the quad-cache in `zig/world.zig`.

This explanation also highlights why we need 4 quad-caches: the player might be juuuust in between two possible prefix stacks for X, and two other possible ones for Y. Of course, the player doesn't have to worry about all this when enjoying the game. But sometimes it's nice to peek behind the curtain!

#### Depths

There's some details the previous explanation glossed over. You might have wondered how exactly that cached X and Y is stored, and it's internally stored as a `u64`, plus a length (`usize`, although the meaning of this isn't important) representing how large the cache is. And going back to this example: `([9, 15, 15, 15, 15, 15], [3, 0, 0, 0, 1, 1])`, the `depth` would equal 6. If the active suffix was a `u16` instead of a `u64`, this would technically be stored as this:

**In the `QuadCache`:**

- \[$9\times 16^1+15\times 16^0$, $10\times 16^1+0\times 16^0$] for the two cached X values.
    - Implied length of $2$, as $6-4=2$. The active suffix can represent 4 `u4` values, so this is where the number comes from.
- \[$2\times 16^1+15\times 16^0$, $3\times 16^1+0\times 16^0$] for cached Y, same implied length
- Recall again these are stored as 4 combinations, each with their own 512-bit seed. However, the cache also stores the "type" of block it represents. So each of the 4 caches would store what block type $X_aY_b$ corresponded to (the block type is used for `ModificationStore`, keep reading for more details).

**In the specific example `Coordinate`:**

- Coordinate X: $9\times 16^3+15\times 16^2+15\times 16^1+15\times 16^0$.
- Coordinate Y: $3\times 16^3+0\times 16^2+1\times 16^1+1\times 16^0$.
- Quadrant ID:
    - Coordinate X: `false` (boolean representing which cached value to use), representing the **first** QC.
    - Coordinate Y: `true`, representing the **second** QC.
    - What happens is you encode this into a value between 0-3 (hence the `u2`), so if we consider false = 0 and true = 1, then the result is $C_x+2\times C_y$ (where $C_x$ is coordinate X and $C_y$ is coordinate Y). Then you can "extract" the boolean out from this quadrant ID with bitwise logic, for example.

#### Deterministic seeding

**This part requires an understanding of PRNGs and is not strictly important for understanding.** To support $O(1)$ seeding generation per chunk at arbitrary depths, Zig maintains four `LayerSeed` constants (512-bit), for each quadrant of the QC. This then gets mixed along with the suffixes with Blake3 (part of Zig natively).

- Again, the QCs are fixed at depth-change. Moving across the $2^{64}$ boundary simply toggles the `u2` quadrant ID.
- `ChunkSeed`, to oversimplify details a whole lot, is `BLAKE3(seed of QC determined by the quadrant ID, SuffixX, SuffixY)`. The seed of the QC itself is determined by the _initial_ seed from the string provided (specific bijective logic is rather complex, but see `src/seeding.ts` for details) and is mixed with the 4 bits of data (a "nibble") that is added to the prefix stack of each quadrant (after depth 16, where the prefix data becomes non-empty).
- Blocks *within* a chunk are generated sequentially via `Xoshiro512**`. Since the order in which the blocks are generated is the same every time (go through X-axis values 0-15, then increment Y, etc.), the PRNG state is can be shifted multiple times (without reseed for each individual block, just a whole chunk) yet produces deterministic outcomes, which makes things simpler.

#### Storing modifications

Of course, to have a fractal _mining_ game, you must store if the player has modified any chunks. This boils down to asking one crucial question for each chunk:

> Does this chunk have any blocks where the player replaced a block of type A with type B?

(Air/empty space is itself a type of block.) If the answer is YES (even if it's just one block in a chunk with 256 blocks that's different), then a `ModificationStore` is created for that chunk (with a `Coordinate` to specify where these modifications are).

But wait, what is a block? Here is `zig/memory.zig`:

```zig
/// A single block within a chunk.
pub const Block = packed struct {
    /// Internal sprite ID
    id: World.Sprite,
    /// The brightness of the tile
    light: u8,
    /// Mining progression for animation
    hp: u4,

    /// Per-block seed for procedural variation in the shader
    seed: u24,
    /// Edge flags: which neighbors are air (for edge-darkening and culling).
    /// Starts from top left, then middle left, and ending at bottom right (skipping itself).
    flags: u8,
};
```

Well, now you know what a block contains.

The most complex part of Depthwell's architecture, though, is ensuring that a hole mined at Depth 0 results in an empty 16x16 chunk at Depth 1, Depth 2, and so on. This is handled through a neat little **lineage check** during chunk generation.

When the generator builds a chunk at Depth $D$, it iterates backward through the prefix stack from $D-1$ down to $0$. ($D$ is larger the "more zoomed in" the game is, and starts at $3$. It represents how many `u4`s need to represent where a chunk is, to put it another way.)

For each ancestor level, it asks the `ModificationStore`: _"Was the portal block at this specific path modified?"_ The `ModificationStore` finds all modifications that _could_ impact this block, starting with higher depths (and it eventually asks a whole quad-cache, which stores a base type). Note that the `ModificationStore` deals with whole chunks (256 `Block`s) at a time.

The engine traverses up depths of the `ModificationStore` (eventually bubbling up to checking the type of a quad-cache if no changes were found). Small detail: portals can only spawn in places where the player is able to enter the new depth, not stuck within a block!

If a parent block was gold for example, the entire are would inherit gold as its ambient background. The game searches for a non-empty (not void/air) block and inherits the QuadCache background if necessary, and these chunk-or-larger size backgrounds get cached in the `SimBuffer` as well. Then, the game processes individual block modifications and renders them.

If any blocks are modified they get modified in the `SimBuffer` as well.

#### Prefix stack and memoization

You might be wondering how the engine handles a path 10,000 layers deep without lag, and the solution is to **relentlessly use the prefix stack and cache the seed**. In `zig/world.zig`, the big prefix path is stored using a dynamic array (specifically a `std.ArrayList(u64)` for efficient performance).

**Why memoize and make the logic so complicated?**

By storing the resulting 512-bit `seed` at every level of the stack, the game no longer needs to spent resources reseeding a bunch for each chunk (while the math working out, as if every chunk was, resulting in high-quality seeding!). We never re-calculate the entire 10,000-level BLAKE3 chain as an extra benefit; we only hash the _newest_ nibble added to the stack.

#### Storing chunks with a simulation distance

The "simulation distance" is 16x16 chunks, so a dedicated buffer of 256 chunks exists at all times (stored in the `SimBuffer`). This buffer basically follows the player around with an algorithm that maximizes the shortest distance the player has to travel in any direction (the "above/below" average algorithm), and if something is in it such as an enemy then it is simulated.

It's possible, however, that the camera might move super fast in a frame and temporarily cause renders outside the standard `SimBuffer` (which is around the player, and the only existing chunk buffer), so the game will first try to find if a chunk is in the array of simulation chunks, and if it isn't then it will dynamically generate it temporarily (which is still fairly fast, since we're using data-oriented design).

Groups of objects such as enemies are stored in a `MultiArrayList` with properties and a `Coordinate` for ideal performance.

#### Procedural generation philosophy

- Be **deterministic** (mostly). Outcomes for an individual chunk should be repeatable (naturally occurs with prefix+suffix implementation, regardless of what path the player takes). The only exception is when the player changes blocks to different types and these start to look different.
- Look **unique**. There should be the ability to generate unique-looking biomes.
- Ensure **consistency between depths.** This can be done with color mixing, background parallaxes, etc.. TODO specific details
- Use **stunning shaders**. TODO figure out and put into demo timeframe
- Be **performant**. Zig and `QuadCache` caching a parent block type this should be reasonable.
- Be **fast to iterate**. Minimize the work necessary to add a new block or generation algorithm or biome.

#### How procedural generation works

TODO, still figuring this out

#### Particles

Particles are small squares with rotation and opacity and organized using a circular buffer`ParticleSystem`. There can be a maximum of 1,000 particles at a time (the circular buffer is greedy and "loops around" to always erase the oldest particles). All data is passed to WebGPU and WebGPU automatically culls expired particles (as this part isn't super performance-strict).

TODO figure how how to deal with those 64 bit values exactly, probably should delegate that opacity job to WebGPU for once-per-instance

```zig
/// Tightly packed data for a square particle to be sent to WebGPU.
const Particle = packed struct {
    /// Current position.
    position: @Vector(2, f32),

    /// Velocity vector for position.
    d_position: @Vector(2, f32),

    /// The color of the particle (alpha is multiplied by time and how long the particle lasts)
    color: ColorRGBA,
    /// The size of the particle
    size: u24,
    /// The opacity of the particle (based on time start/end)
    opacity: u8,

    /// The rotation of the particle (radians)
    rotation: f32,
    /// The rate of change of rotation of the particle (radians)
    d_rotation: f32,

    /// The time at which the particle spawned in from (performance.now()).
    time_start: f64,

    /// The time at which the particle will disappear.
    time_end: f64,
};
```
#### Zoom logic

Entering a portal shifts a bunch of data around, particularly the cache and all coordinate paths:

- The current world-path is pushed to the `PrefixStack`.
- The active suffix/quadrant ID are reset (or "rebased"), in a way that allows for the _maximum_ amount of coverable distance before a crash. Specifically, the logic explaining the coordinate system mentioned the concepts of "below average" and "above average", and the idea is basically to zoom in in such a way that the quad-cache maximizes the amount of distance you'd have to travel in any quadrant before you're out-of-bounds. In practice, this is in the _quintillions of chunks_ precisely because of this rebasing implementation, and the reseeding is entirely $O(1)$ with a bit of extra work.
- The `ActiveSimBuffer` is purged, and the world re-generates at Depth $D+1$.

#### Memory transfer

The interface between the TypeScript engine and the Zig core is managed via a shared WASM buffer:

- The **scratch buffer** is a gigantic, dynamically expanding shared heap used for high-bandwidth data transfers (mainly, drawing lots of chunks).
- There are also **scratch properties**, which is an array with 20 properties of 64-bit integers and floats used for metadata (also used for drawing chunks). This is arguably easier to use than multi-value function returns.

An allocator (see `memory.zig`) and a 256KiB stack size also exist.

### Why WGSL (WebGPU)?

WGSL offers several advantages (despite lower browser support). It lets you explicitly manage memory/data and is more efficient for larger projects. Also, it's the more modern standard, so might as well.

### Next steps

- Implement `ModificationStore` and changing chunk cache to ask as well as a basic mousedown-to-change-block-type implementation
- Fully verify depth stack functionality, making sure it works past 16 values, making sure seeding works with it (goal is to not need to touch again after graphics/water work)
- Test background change that reflects modification correctly
- Implement basic physics collision and movement, as well as nice features like coyote time
- Test perlin noise and pixel erosion
- Start drafting next steps like procedural generation, shaders (water/pixel erosion first), art, gear
