# Depthwell

Depthwell is a procedural fractal mining incremental. How deep can you explore? Minimal demo release planned to be late 2026/early 2027.

> [!WARNING]
> This game is pre-demo so all saves may break at any time due to core logic changes!
> The current `README` is **incomplete**, as this game is still in the pre-demo stage; more details will be added in the future and details might currently be out of date. Read the code to see specific implementations and TODOs.

### Images

![Basic game screenshot (built with creative debug options)](images/sample.png)

![Sprite sheet](public/assets/main.png)

### How to play

Stuck with how to begin?

- Left-clicking places blocks; click on inventory slots directly to select block types and indicators above certain block types to open menus.
- Select the pickaxe in the inventory to mine and WASD/arrow keys to move around.
- Start by trying to find items with indicators above them: you can smelt ores into bars at a furnace, and upgrade your pickaxe at "cores" with a gray hovering orb...these act like crafting stations!
    - These are different from campfires, which simply emit light in a certain area.
- You can't mine everything! That means that either your pickaxe isn't good enough or that item can't be mined yet.

Use the M key to open or close the debug menu options (and logs); use creative mode from within the menu to test blocks easily.

For inventory hotkeys:

- Use backquote and 0-9 keys to change inventory selection.
- Q moves up a row in the inventory while E moves down a row.

### Building

To build `node_modules`, run `npm install`.

Run `zig build` to build Zig code and automatically detect `main.aseprite` changes, `zig test "zig/root.zig"` to run (all) tests, and `zig build -Dgen-enums` to simultaneously build and generate `enums.ts` if changes were made. (See `build.zig` for details on compiling a final version.)

Useful variables to customize include `CONFIG` in `src/main.ts`, `engine.wireframeOpacity`, `engine.baseSpeed`, and `zig/state/player.zig` config options.

When building for production with Vite (using `npm run build` instead of `npm run dev`), use `zig build -Dgen-enums -Dwasm-opt` (with WASM optimizations from Binaryen).
Alternatively, use and modify `.githooks/pre-commit`.

#### About version control

It is quite helpful to use the Zig Language Server in VSCode/VSCodium and set it to "watch" mode, which automatically builds the WASM while providing highlighting any errors.

Depthwell supports both Git and Jujitsu using `.sh` files. Git VCS is supported by default; to use Jujitsu building for release, simply run `./build.sh` (after `chmod +x ./build.sh`).

You can also easily build for Windows by using a shell script executor, or you can convert the commands to their Windows equivalents very easily.

#### Git building tips

If you're using Git, you'll want to comment out the Jujitsu-intended settings that hide default VSCode/VSCodium behavior.

To auto-build Vite before commit:

```sh
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit
```

### Architecture details

Game is created using Zig and WebGPU, and meant to be web-first. A final product that uses Mach Engine for native building is planned, but _web will always be free and receive updates_. The internal viewport is 480x270 (but it automatically scales with the DPI/base resolution). Functions are exported from `root.zig`.

By using `ChaCha12` and `Blake3` and a seed with 1-100 `a-z` characters, the game can generate over `10^140` possible maps, with each map containing a very large depth limit that allows for near-infinite exploration. Performance-sensitive areas are generated using `FastHash`, which uses 128-bit seed vectors at a time.

#### Coordinates and basics

Here are the basic terms (note that there are, for example, 16 possible subpixels for both the X/Y coordinates for a pixel, so these are for one dimension):

- 1 Pixel = 16 Subpixels
- 1 Block = 16 Pixels
- 1 Chunk = 16 Blocks = 256 Pixels = 4,096 Subpixels
- **Depth**: How "deep" the player is. Depth starts at $4$ (see `STARTING_ZOOM_TIMES`). Each time you enter a portal, the world zooms in by $4\text{x}$, making everything look 4 times larger, and the depth increases by 1.
- **$D$**: Shorthand for the current depth. You can think of depth $D-1$ as the coordinate space you occupied right _before_ entering a portal.
- **The Event Horizon ($H$)**: Shorthand for $D-32$. When you are deep in the fractal ($D \ge 32 + 4$), the game stops tracking individual blocks shallower than 32 levels above you, replacing them with a simplified 4x4 background grid. (This is not necessarily related to game mechanics but instead internal.)

The player starts off at `STARTING_ZOOM_TIMES`, which defaults to 4. So, $D$ starts off as 4 and $D-1$ doesn't exist until $D$ increases further.

The camera and the player work with (integeric) subpixels, while entities are considered in terms of (floating-point) pixels. Seeding of specific blocks in chunks and modifications concern themselves with blocks. Asking something "where" it is involves just chunks (see later).

Now, bear with me here, because you might be freaking out over the fact a code segment just appeared. But don't fret, I'll break things down! This code is just those interested in specific details on what these numbers _could_ mean, because there are a lot of definitions!

Basically, all the code below is doing is declaring some constants in Zig, a fancy low-level language. The `CHUNK_SIZE` variable just represents 16; you don't really need to understand the code blocks so feel free to skip these. From `zig/memory.zig`:

```zig
/// The main number (as an integer) representing the number of blocks in a chunk, number of pixels in a block, and number of subpixels in a pixel. (Note that changing these values WILL break the code!)
pub const CHUNK_SIZE: comptime_int = 16;
// ...
/// An integer representing the number of subpixels in a block, pixels in a chunk, number of blocks in a chunk, number of pixels in a block, and number of possible subpixel positions within a pixel.
pub const CHUNK_SIZE_SQ: comptime_int = CHUNK_SIZE * CHUNK_SIZE;
// ...
/// An integer representing the number of subpixels within a chunk. The player's X and Y coordinate should wrap around such that it is between 0 and this value (inclusive).
pub const SUBPIXELS_IN_CHUNK: comptime_int = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE;
```

Imagine the entire game world as a massive grid. Every time you zoom in, every single grid cell splits into a $2\text{x}2$ layout of $4$ smaller sub-cells.

Your position in the world is essentially a string of directions: _"From the top level, go to cell 2, then go to sub-cell 3, then sub-cell 1..."_ Because every step is a choice between 0, 1, 2, or 3, each step can be represented as a tiny **2-bit number** (a `u2`).

To represent where any chunk is, we use a struct called `Coordinate` composed of three parts:

- The **active suffix (`Coordinate.suffix`)** is an array of two 64-bit unsigned integers (`u64` vectors) representing the X and Y paths of your zoom steps. Because each step is 2 bits, we can pack exactly 32 steps ($32 \times 2 = 64$ bits) into this single number. This is incredibly fast and memory-efficient!
- The `QuadCache` or **prefix stack** is used because if you zoom deeper than 32 levels, we run out of bits in our 64-bit active suffix. The oldest steps at the top of the path "fall off" (overflow) and are pushed to a global prefix stack (`left_path` and `top_path`).
- Finally, a **quadrant ID (`Coordinate.quadrant`)**: stores 2-bit number (0 to 3) identifying which of the 4 parent quadrants of the active zoom path the chunk belongs to.

> [!NOTE]
> Important detail! If your `depth` is at or below 32, the quadrant ID defaults to 0 and the game relies entirely on the 64-bit active suffix.

The reason all this quadrant logic works is because of one essential fact: **_The `depth` can only INCREASE!_** The player can't zoom out **and modify blocks**, which is the main reason this quad-cache rebasing assumption is safe. If this were the case, it would introduce a host of complexities and "exploits" that easily allow block duping.

#### Depths

To make sure we can zoom 10,000 layers deep without significant lag or RAM issues, we pack the historical rebase steps very tightly using a custom bit-packing algorithm.

Suppose you are at $D=6$ (so your path has 6 steps), and your horizontal path is
`[2, 3, 1, 0, 3, 2]`.

Because the zoom factor is $4$, each step acts as a digit in a **base-4** number. Your absolute coordinate on this axis would be calculated as:

$$X = 2 \times 4^5 + 3 \times 4^4 + 1 \times 4^3 + 0 \times 4^2 + 3 \times 4^1 + 2 \times 4^0 = 2958$$

In binary, this is represented as a sequence of 2-bit pairs: `10 11 01 00 11 10`. This fits perfectly inside the 64-bit active suffix!

#### What if $D>32$?

When you zoom past 32 levels, the 64-bit suffix overflows. The oldest 2-bit steps fall off and are converted into 3-bit top-left origin offsets (`left_cell_x` and `top_cell_y`) ranging from `0` to `6`.

To prevent massive RAM overhead, the global prefix stacks (`left_path` and `top_path`) pack these 3-bit steps into 64-bit slots:

- Since $\lfloor 64 / 3 \rfloor = 21$, we pack exactly **21 historical steps** into a single `u64` integer.
- The game uses dynamic division and modulo math (`idx / 21` and `(idx % 21) * 3`) to find and extract these values on the fly.

#### Storing modifications

Of course, to have a fractal _mining_ game, you must store if the player has modified any chunks. This boils down to asking one crucial question for each chunk:

> Does this chunk have any blocks where the player replaced a block of type A with type B?

(Air/empty space is itself a type of block.) If the answer is YES (even if it's just one block in a chunk with 256 blocks that's different), then a modified chunk is recorded within the `ModificationStore` (with a `DepthCoordinate` referencing both location and height).

But wait, what is a block? Here is `zig/memory.zig`:

```zig
/// Contains a `Sprite` id and various packed properties; ready to be sent to the GPU or stored in caches.
/// Field order keeps every field inside one aligned 32-bit word so the shader (`unpack_tile()` in src/shader.wgsl) extracts each with a single per-word `extractBits()`:
/// - word0: `id` | `edge_flags` | `light`
/// - word1: `hp` | `seed` (the shader reads the whole word as seed0, so `hp` is folded into the seed for free)
/// - word2: `base_id` | `id_edge_flags` | `lighting_color`
/// - word3: `waterlogged` | `_pad`
pub const Block = packed struct(u128) {
    /// A block with an `id` of `none`.
    pub const empty: Block = .makeBasicBlock(.none, 0);

    /// Maximum value for `hp`. `hp` is a `u4` (sharing word1's low bits with `seed`) and MUST stay 0-15:
    /// the atlas has exactly 16 HP masks and the water volume simulation assumes 0-15.
    pub const MAX_HP: u4 = 15;

    /// The primary sprite: the overlay/block itself (such as the ore rather than the block beneath).
    id: Sprite,
    /// Edge flags: explains details for neighbors (for both shader and procedural generation).
    /// Starts from top left, then middle left, and ending at bottom right (skipping itself).
    /// See types/types.zig for more details on correspondence.
    ///
    /// - A 1 bit for a solid block ordinarily indicates an edge with an adjacent solid block.
    /// - A 1 bit for a liquid block means that there is either solid or liquid adjacent.
    /// Edge flags must be reset to 255 for decorations (non-blocks or liquids) after a final decoration pass.
    edge_flags: u8,
    /// The brightness of the tile.
    light: u8,

    /// Dual-purpose field depending on block type (range 0-15, see `MAX_HP`):
    /// - For solid blocks: how "mined" the block is (0 means unmined, 15 is most mined).
    /// - For liquid (water) and decoration blocks: the water volume level from 0 to 15.
    hp: u4,
    /// Per-block seed for procedural variation in the shader.
    /// Any seed value here should be considered poor and insecure.
    seed: u28,

    /// The underlying background tile behind an overlay sprite (e.g. the stone an ore/gem grew inside).
    /// `.none` means "no underlay"; the shader then renders `id` alone (the common case for non-ore/gem blocks).
    base_id: Sprite = .none,
    /// Same-sprite edge flags (same bit order as `edge_flags`): a bit is set when the neighbor's `id` equals this block's `id`.
    /// Drives the ore overlay mask so a vein reads as connected only to itself.
    /// Follows the same 0xFF reset rule as `edge_flags` for decorations/air.
    id_edge_flags: u8 = 0,
    /// Type of color lighting should use.
    /// - 0: default white
    /// - 1: warm orange glow
    lighting_color: u8 = 0,

    /// Dual-purpose directional waterlogging field (bits 0-4 used):
    /// - For liquid blocks: represents adjacent water heights/volumes.
    /// - For non-liquid blocks: bits represent surrounding waterlogged cardinal directions.
    ///   - bit 0: top (liquid block directly above)
    ///   - bit 1: bottom (full liquid block directly below at HP=15)
    ///   - bit 2: whether ripple occurs from the top (top ripple cutoff)
    ///   - bit 3: left (liquid block directly to the left)
    ///   - bit 4: right (liquid block directly to the right)
    waterlogged: u8 = 0,
    /// Unused portion of block data.
    _pad: u24 = 0,
    ...
}
```

Well, now you know what a block contains.

The most complex part of Depthwell's architecture, though, is ensuring that a hole mined at Depth 0 results in an empty 4-by-4 region at Depth 1, 16-by-16 at Depth 2, and so on. This is handled through a neat little **lineage check** during chunk generation.

When the generator builds a chunk at Depth $D$, it iteratively traverses backward through the prefix stack from $D-1$ down to $D-32$. ($D$ is larger the "more zoomed in" the game is, and starts at $4$. It represents how many `u2`s need to represent where a chunk is, to put it another way.)

For each ancestor level, it traces upward and queries `ModificationStore` or evaluates `AncestorCache`: _"Was the parent block at this specific path modified?"_ At $D-32$ (the event horizon limit), chunk-level details are replaced by checking the global `QuadCache` 4x4 material grid. Any properties inherited directly from parents influence chunk structures appropriately.

#### Prefix stack and memoization

You might be wondering how the engine handles a path 10,000 layers deep without lag, and the solution is to **relentlessly use the prefix stack and cache the seed**. In `zig/state/world.zig`, the big prefix path is stored using dynamic array allocations (`SegmentedList`).

Why memoize and make the logic so complicated? By storing the resulting 512-bit `seed` at every level of the stack, the game no longer needs to spend resources reseeding a bunch for each chunk (while the math working out, as if every chunk was, resulting in high-quality seeding!). We never re-calculate the entire 10,000-level BLAKE3 chain; we only hash the _newest_ nibble added to the stack. This makes procedural chunk generation on depth increase effectively constant-time!

#### Procedural generation

Generating a world that is statistically infinite yet perfectly consistent across billions of chunks requires a multi-pass approach. While the math might look like a bunch of magic numbers, it’s actually a carefully layered sequence of domain warping and noise functions.

#### Hashing function

In the earlier sections, I mentioned `ChaCha12` for its cryptographic strength. However, calling a full ChaCha block 256 times for every single chunk is (who knew) incredibly slow. For the heavy lifting of 2D noise, Depthwell uses a custom **stateless multiply-unrolled-multiply mixer** called `FastHash` that uses some magic numbers from Wyhash.

By using `Vec2f` vectors and bit-folding, `FastHash.hash2d()` provides enough variance for smooth terrain while being significantly faster than a standard PRNG.

#### Terrain and biomes

TODO: complete this with more details and new noise algorithms

The first pass of the terrain logic determines the "flavor" of the chunk. We calculate two main values: **moisture** and **density**.

Instead of standard Perlin noise, there's multiple algorithms being used simultaneously:

- Basic value noise is used for large terrain details.
- Worley noise (or cellular/Voronoi noise) that creates sharp, jagged ("crisp") noise. Specifically, F2-F1 Worley noise is being used.
- To create a more varied texture, the code uses fractal brownian motion (FBM) to warp the input coordinates.

Large cells (scale/cell size of 425.0) determine moisture. Smaller cells (scale of 80.0) determine density. These are mostly arbitrary properties; density determines the cave shape while moisture determines some extra "flavor" details like blue/purple `strange_stone` or different stone block variations.

Based on the moisture and density values, a specific block type is chosen such as normal, blue, or lava stone.

#### Dispersing ores

Once the stone is placed, the generator makes a second pass to seed ores. This pass only triggers for "foundation" blocks (stone variations). We run another Worley pass with much smaller cells to create "veins."

Using the `selectSprite()` helper, we branch the logic:

- First, copper, iron, silver, and gold are dispersed based on the density of the specific Worley cell.
- The amethyst, sapphire, emerald, and ruby gems use a third `FastHash` pass to check against `base_gem_odds`. If the odds hit, a specific gem is selected based on a third Worley value.

#### Decoration pass

The final pass handles the "flavor" of the world. These are things such as mushrooms, spiral plants, and ceiling flowers. Since this pass is less computationally expensive, we switch back to `ChaCha12` for high-quality entropy.

Decorations are context-aware. Mushrooms only spawn if the block below is solid, ceiling flowers if the block above is solid, and spiral plants can grow multiple blocks tall by checking for a spiral plant above on top of a solid-block above generation check.

Critically, the generator finishes by setting the `edge_flags` of these decorations to `0xFF`. This tells the WebGPU shader that it shouldn't have erosion and edge darkening applied to it.

#### Entities

Entities represent a generic type of sprite, with color shifts, rotation, and size changes.

Here is their definition:

```zig
/// Entity data (before being sent to WGSL, using internal viewport).
/// Allows for size, rotation, and OKLCH + alpha (opacity) changes to any chosen sprite.
pub const Entity = struct {
    /// The light, chroma, hue, and opacity components (HSL + alpha).
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

/// Tightly packed data for a entity to be sent directly to WGSL (using UV coordinates).
/// Allows for size, rotation, and OKLCH + alpha (opacity) changes to any chosen sprite.
pub const WGSLEntity = extern struct {
    /// The light, chroma, hue, and opacity components (HSL + alpha).
    /// L (lightness) and alpha components are multiplied by the sprite's color in WebGPU.
    /// H (hue) and C (chroma) are shifted additively in radians.
    lcha: Vec4f32 align(16),

    /// Current center position of the sprite (based on UV, not the internal viewport).
    position: Vec2f32,

    /// The width and height of the entity (based on UV, not the internal viewport).
    size: Vec2f32,

    /// The rotation of the entity (radians).
    rotation: f32,

    /// The ID of the entity (sprite type).
    id: u32,
};
```

These are then passed to WGSL in a large batch. Here is an example of potential usage:

```zig
// basic entity example:
for (0..10) |i| {
    addEntity(.{ // draw shadow of inventory slot by darkening and reducing opacity
        .sprite = if (i == selected_id) .inventory_selected else .inventory,
        .position = getInventoryPos(i) - Vec2f{ 2, 2 },
        .lcha = .{ if (i == 0) 0.8 else 0.7, 0.0, 0.0, 0.9 },
    });
}

for (0..10) |i| {
    addEntity(.{ // draw inventory slot
        .sprite = if (i == selected_id) .inventory_selected else .inventory,
        .position = getInventoryPos(i),
    });
}

// number-drawing example:
// draw selected HP (for testing)
const progress = dw.mining.selected_hp;
const pos: Vec2f = .{ 10, 28 };
const font_size = 10.0;

if (progress != 255 and progress != 0) {
    const value_hue = 0.2 + @as(f32, @floatFromInt(progress)) * (std.math.pi / 8.0);
    // draw shadow of text
    drawNumber(progress, pos - Vec2f{ 1.5, 1.5 }, .{
        .lcha = .{
            0.5, // darken
            0.4,
            value_hue, // hue changing as progress increases!
            0.8,
        },
        .font_size = font_size,
        .ltr = false,
    });

    // draw the actual number now
    drawNumber(progress, pos, .{
        .lcha = .{
            0.75,
            0.4,
            value_hue, // hue changing too
            1.0,
        },
        .font_size = font_size,
        .ltr = false,
    });
}
```

You can see how because the entities are _ordered_, it's easy to add a shadow. Additionally, the usage of white text or masks works perfectly with OKLCH (which stands for lightness, chroma, and hue). This means that not only can entities have various small color shifts, but they can also perfectly be masked with a white sprite (see the sprite sheet up top)!

#### The fractal modification buffer

Depthwell stores modifications with some fancy lineage inheritance: modifications are stored per-layer, and when generating a chunk at Depth $D$, the engine recursively climbs and calculates the history of the `ModificationStore` and its resulting cache properties.

The _goal_ with modifications is to ensure the following:

1. Read _existing_ modifications to extract rectangular groups of chunks: ~1000 reads/second for as long as possible due to potential of requiring 16-32 new chunks in SimBuffer during some frames and camera features in the future.
2. Write a _new_ modification (60fps for as long as possible). In practice, this is very easy with hash maps.
3. Increment the depth (below 3 seconds for as long as possible).
4. Minimize heap fragmentation and "allocation churn."
5. The entire state can be stored inside RAM.

Therefore, the current solution is to hash a `DepthCoordinate` using `std.hash.autoHash`. A `std.HashMap` stores these hashes and indexes a dynamically allocated array of `Chunk`s (the dense data representing a chunk's entire modifications) utilizing a segmented list storage setup. See some definitions and more details:

```zig
/// Stores and handles modifications of chunks. Functions across depths.
pub const ModificationStore = struct {
    /// `HashMap`-based system to store indexes to `history`.
    index: std.HashMap(
        DepthCoordinate,
        usize,
        DepthCoordinateContext,
        std.hash_map.default_max_load_percentage,
    ),
    /// Expandable list that stores modified `Chunk` data (256KiB pre-allocation).
    history: SegmentedList(Chunk, 128) = .{},

    pub fn init(allocator: std.mem.Allocator) ModificationStore {
        return .{
            .index = std.HashMap(
                DepthCoordinate,
                usize,
                DepthCoordinateContext,
                std.hash_map.default_max_load_percentage,
            ).init(allocator),
        };
    }

    /// Gets an existing modification for reading.
    pub fn get(self: *const @This(), key: DepthCoordinate) ?*const Chunk {
        const id = self.index.get(key) orelse return null;
        return self.history.at(id);
    }

    /// Completely wipes all user modifications. Should be followed by `world.clearCaches(true)`.
    pub fn clear(self: *@This()) void {
        self.index.clearRetainingCapacity();
        self.history.clearRetainingCapacity();
    }
};

/// Stores and handles modifications of chunks across various depths.
pub var mod_store: ModificationStore = undefined;

/// Stores what location a modification with an active suffix and quadrant, as well as its depth, to easily identify it.
pub const DepthCoordinate = struct {
    /// Represents an invalid `DepthCoordinate`, which has `depth` equal to 0.
    /// Semantically equivalent to null.
    pub const invalid: @This() = .{
        .depth = 0,
        .quadrant = undefined,
        .suffix = undefined,
    };

    /// Active suffix (stored as a vector). Should not be set manually; must call `getParent()` to decrease the depth for depths beyond `HORIZON_DEPTH`.
    /// Most likely, a "path" of accessing D->D-1->D-2->...->H will occur.
    /// You can think of the active suffix like 32 `u2` values packed together for the X and Y coordinate.
    /// This coordinate can then be merged with the correct `QuadCache` quadrant to go all the way to H.
    /// See `README.md` for more details on what D/H mean.
    suffix: Vec2u,
    /// The depth of the modification.
    depth: u64,
    /// Quadrant ID (00: NW, 1: NE, 2: SW, 3: SE).
    quadrant: u32,
    ...
}
```

```zig
/// A static 2x2 grid of seeds only updated when depth increases or game startup. See `README.md` for a more detailed and intuitive explanation for what this does.
pub const QuadCache = struct {
    pub const PATH_PREALLOC_SIZE = 256;

    /// The 512-bit hashes for the 4 active quadrants (sequentially from D to D-31).
    /// (0: NW, 1: NE, 2: SW, 3: SE)
    path_hashes: ChunkSeeds align(memory.MAIN_ALIGN_BYTES),
    /// The 4-by-4 material grid representing the "event horizon" at D-32.
    /// The inner 2-by-2 (indices [1..2][1..2]) corresponds to the active quadrants.
    ancestor_materials: [4][4]Block,
    /// A list representing the prefix stack of the top left quadrant's X-coordinate.
    left_path: SegmentedList(u64, PATH_PREALLOC_SIZE),
    /// A list representing the prefix stack of the top left quadrant's Y-coordinate.
    top_path: SegmentedList(u64, PATH_PREALLOC_SIZE),

    // These 4 properties are used to determine if a QuadCache is at the very edge of the world for chunk gen/zooming in.
    most_top: bool = true,
    most_bottom: bool = true,
    most_left: bool = true,
    most_right: bool = true,
    ...
```

#### Zoom logic

Entering a portal shifts a bunch of data around, particularly the cache and all coordinate paths:

- The current world-path is pushed to the prefix data.
- The active suffix/quadrant ID are reset (or "rebased"), in a way that allows for the _maximum_ amount of coverable distance before a crash. If the player ever travels to a coordinate or the game accesses a chunk that cannot be represented with either of the four quadrants, the **game will crash**. Specifically, the logic explaining the coordinate system mentioned the concepts of "below average" and "above average", and the idea is basically to zoom in in such a way that the quad-cache maximizes the amount of distance you'd have to travel in any quadrant before you're out-of-bounds. In practice, this is in the _quintillions of chunks_ precisely because of this rebasing implementation.
- The `SimBuffer` is purged, and the world re-generates at Depth $D+1$ using the inherited properties of the portal block.

See the big chunk of comments in `pushLayer()` for specific details on zoom logic. Since the game has hard bounds, instead of looping, there's quite a bit of extra logic here than you might expect.

#### More rebasing explanation

Because the coordinate tracking suffix uses a 64-bit integer, and each depth traversal consumes exactly 2 bits, a player can natively traverse exactly 32 depths ($2^{64}$ chunks) without exceeding standard integer bounds.

To manage near-infinite zoom, Depthwell stores seeds for each quadrant in `path_hashes` (4 because the code generates 4 BLAKE3 hashes for various parts of seeding, from terrain to WGSL decoration).

Once increasing the depth past 32, the engine executes a "rebase" each time. The player is re-centered inside the 64-bit bounds, and the highest 2 bits (the overflow nibble) "fall off" the top of the suffix into the `QuadCache` history arrays.

Because a quadrant's spatial area precisely covers $2^{64}$ chunks at the current depth, looking back _exactly_ 32 levels guarantees full coverage of the current addressable space. If a modification occurred at Depth $D-33$, that chunk will be 16x larger than a whole quadrant. Therefore, a fixed 32-length lookback is ideal here, and `ancestor_materials` acts as a "collapsed" summary of all modifications and base seeds explicitly at exactly $D-32$.

Modifications of "higher" $D$-values are prioritized, and lower $D$-values are used for backgrounds/procedural generation; at any depth $D$, individual blocks are still individual blocks. To assist in lineage checks, `AncestorCache` caches chunk requests spanning through these depths to ease generational processing.

- Reading performance is an amortized O(1) due to only needing to consider block sizes between depth $D-32$ to $D$.
- Writing performance is an amortized O(1) due to needing to modify a `HashMap`.
- Increasing depth is, surprisingly, an O(1) operation due to a lack of modification culling (to allow for a "spectator view" on death), and storing where things are with a 256-bit `DepthCoordinate` and assuming that collisions are impossible.
- Space complexity is O(n) based on the number of modified chunks. Even if all modifications are reversed, each modified chunk still takes up 2KiB in history. However, this is stored as a `SegmentedList` to prevent large unused gaps in WASM memory.

#### Storing chunks with a simulation distance

The "simulation distance" is 16-by-16 chunks, and is a dedicated buffer of 256 chunks that exists at all times (stored in the `SimBuffer`). This buffer basically follows the player around with an algorithm that maximizes the distance (the "above/below" average algorithm), and if something is in it such as an enemy then it is simulated.

It's possible, however, that the camera might move super fast in a frame and temporarily cause renders outside the standard `SimBuffer` (which is around the player, and the only existing chunk buffer), so the game will first try to find if a chunk is in the array of simulation chunks, and if it isn't then it will dynamically generate it temporarily (which is still fairly fast, since we're using data-oriented design).

#### Smart chunk loading

Despite the fact that chunks are procedural and written in Zig (you'd think that means blazing fast), there's a lot of heavy computation internally due to needing to calculate several FBM+Worley passes, _per block_. This optimization improves performance by 8 times in practice.

That's why the code tries as hard as possible to only generate two chunks per frame (except on startup or depth increase, as that will use different logic). By doing this, the code can easily extract these chunks from `ChunkCache` lazily when the player moves in a way that requires the `SimBuffer` to pull chunks near the edge.

The algorithm does this each frame (with a default budget of 2; budget increases to 4 if the player's velocity is high):

1. The player's current velocity creates a "leading edge." This algorithm tracks your player's current speed and direction. It prioritizes generating chunks immediately in front of you (your "leading edge") before looking at side or diagonal directions.
2. The engine quietly spends its frame budget generating a 68-chunk "ring" just outside your visible screen. By the time you walk or fall into a new area, the chunks are already generated and waiting in memory.
3. Finally, the `ChunkCache` provides a "second chance" that stores recently visited chunks. This uses a 4-way set-associative cache (which is effectively $O(1)$ in more cases than a `HashMap`); implementation details can be seen in `zig/state/world.zig`.
    - Technical info: if a chunk has been accessed recently, its reference bit is kept.
    - If the cache fills up, older chunks with cleared reference bits are evicted, eliminating memory allocation or garbage collection overhead.

This system prevents frame spikes (as you may normally have to generate a whole 16 chunks/frame to keep `SimBuffer` happy)! Note that this logic doesn't at all change the _logic_: the player could still teleport trillions of chunks away in a frame: these would just get gradually neglected by the `ChunkCache` naturally.

Chunks that get accessed from the `SimBuffer` do not update the `ChunkCache`, although chunks generated for the purpose of being placed into `SimBuffer` _do_ get placed into the cache.

#### Light system

Lighting is computed on the CPU every frame in `zig/render/lighting.zig`, right after the visible block buffer is assembled and before it is handed to the GPU. Every block receives a `light` value from 0 to 255, and the WGSL shader multiplies that block's OKLAB lightness by `light / 255` (so 0 is pitch black and 255 is full brightness). A companion field, `lighting_color`, records whether the "winning" (strongest) light is warm/orange (fire) or neutral white.

Instead of an additive light map or a naive FIFO queue, Depthwell uses **Dial's algorithm (bucketed Dijkstra)** to propagate light. The system maintains a "gravity shelf" of bucket lists, one for each possible brightness level from the maximum source strength (320) down to ambient (0).
By processing these buckets in strictly descending order (brightest to dimmest), the flood guarantees that each cell is finalized at its brightest possible value on its first visit.

How much light is lost per step (the "falloff") depends on what it passes through:

- **Air** loses the least (`AIR_FALLOFF = 10`), so light carries far through open space.
- **Solid** blocks lose the most (`SOLID_FALLOFF = 26`), but the cost scales with how mined the block is (its `hp`): a nearly-broken block lets through almost as much light as air.
- **Liquid** sits in between (`LIQUID_FALLOFF = 18`), and a waterlogged block is capped so it never blocks light more than water would.

A diagonal step costs `sqrt(2)` times the orthogonal falloff (approximated with integer math), turning the square 8-neighbor grid into a mostly circular-looking falloff.

Light sources include the player (a bright, moving source seeded from their continuous sub-pixel position across the 2x2 blocks they overlap), campfires and furnaces (warm/orange), and glowing plates.

Because a source just off-screen can still spill onto visible blocks, the block buffer is padded by `CHUNK_MARGIN` (calculated at compile-time) so that the BFS flood is exactly wide enough to catch the furthest reachable bleed.

Internally, the flood tracks warm and neutral light as two channels packed into one `u32`, so an orange campfire glow and a white plate glow can coexist and mix correctly; the final `lighting_color` is simply whichever channel wins at that block.

#### Memory transfer

The interface between the TypeScript engine and the Zig core is managed via a pre-planned memory layout:

- The **scratch buffer** is a gigantic, dynamically expanding shared heap used for high-bandwidth data transfers (mainly, drawing chunks).
- There's also **scratch properties**, which are an array with 20 properties of 64-bit integers and floats used for metadata (also used for drawing chunks).

### Why WGSL (WebGPU)?

WGSL offers several advantages (despite lower browser support). It lets you explicitly manage browser memory and is more efficient. Also, it's the more "modern" standard compared to things like WebGL 2, so might as well. Unlike using something naive like `drawImage()` it's also a lot faster and we can do a lot more with it! (See the entity system section.)

The goal with using WGSL is to make sure that Zig handles as much of the state as possible, and Zig is the one that generates the data and places it into the scratch buffer. Then, this data is sent to WGSL and processed; Zig pre-processes the data, panning and converting to `f32` (so WebGPU doesn't encounter precision issues).

Compared to using something like the native JS canvas manipulation, the use of GPU shaders blows that out of the water. `drawImage` is a good lazy way to do this, but it doesn't scale.

### Optimization/effects of WGSL

While Zig handles the logic, the visual fidelity of Depthwell is achieved through high-precision WGSL shaders. To maintain high performance on integrated GPUs while allowing for infinite variety, the shader employs several "expensive-looking" tricks that are actually quite cheap.

#### Seeding logic

There are 28 bits from the seed that are used combined with 4 bits from the `hp` of the block. It is passed through a `murmurmix32` function initially (and mixed with `hp`), then three more times to generate `seed1`-`seed3`, providing four independent streams of entropy for every single block on screen (with the last two seeds being used in erosion and edge flags).

#### OKLAB

Traditional RGB lighting often looks "muddy" or "gray" when desaturated or darkened. Depthwell performs all color manipulations in the **OKLAB** and **OKLCH** color spaces, excluding the shader-based background effect.

When a tile is sampled from the atlas, it is immediately converted from linear sRGB to OKLAB. Using the block's 28-bit seed, the shader applies subtle nudges to the **L**ightness, **C**hroma, and **H**ue. Blocks of the same type (e.g., stone) have slightly different color tints based on their position.

(OKLAB is just awesome!)

#### Procedural erosion

Instead of using thousands of unique sprites for different wall shapes, Depthwell uses a single "foundation" sprite and a procedural erosion algorithm. (This also means less work in terms of drawing sprites.)

Using the `edge_flags` calculated in Zig, the fragment shader determines if a pixel is near an "air" neighbor. If it is, it uses `seed2` and `seed3` to:

1. Round the corners by calculating pixel-perfect arcs for outer and inner corners.
2. Notch straight edges through an algorithm to indent or protrude the edge by 1-2 pixels.
3. Darken the edges by applying a curvy shadow gradient to "foundation" blocks, giving the world depth without requiring hand-drawn lighting.

#### Gems and ores

Ores and gems are rendered using a multi-texture "masking" trick to save atlas space. For a gem block:

1. The shader samples the background stone based on the block's world coordinates (preserving the 2x2 tiling).
2. It calculates a shifted UV for the gem itself using 8 bits of the seed, allowing the gem to appear at any of 256 sub-pixel offsets within the block.
3. It samples a gem mask and mixes the stone and gem colors based on the mask's red channel.
4. Finally, it applies a random horizontal/vertical flip to the mask, ensuring that even gems with the same offset look distinct.

#### Background and water

The background isn't simply a static image. Instead it's created with a custom multi-octave fractal brownian motion (FBM) implementation!

It uses a 2D noise function (FBM, which you can find in The Book of Shaders webpage) and this is applied multiple times. For performance reasons the number of octaves is heavily toned down, and there's a subtle parallax effect with 8x, 32x, and 64x "slower" layers versus the camera's movement.
(As in, for every 64 pixels the players move, the 3 layers would move 8, 2, and 1 pixels respectively. These layers also have different RGB color choices and looks!)

You can imagine the specific position as effectively being `(chunk ID + sub-chunk location) modulo 512`, with a coordinate warping system, and basic trig-based lighting at the end.

For the water, there's similar complicated modulo wrapping logic; however, this is based on the chunk's and subpixel position and is easier to reason about. (For water, it's modulo 256 instead of 512.)

(There are a lot more details within `zig/render/chunk.zig` as to how this is exported. For the water, see `zig/state/water.zig` for update calculations.)

### Copyright

Copyright (c) 2026 Leo Zhang. All rights reserved. Distribution of any portions of code or raw assets without explicit permission is strictly prohibited.
