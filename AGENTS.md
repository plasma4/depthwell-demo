# Depthwell

A **web-only 2D mining/exploration game** (Safari/Firefox/Chromium + WebGPU). Zig compiled to WASM, with a thin TypeScript host.

Cozy gameplay, standard mining-game visuals. The player mines, collects, crafts upgrades, and descends through **portals into a self-similar fractal world**. Each depth increase makes the world 4x larger (`ZOOM_FACTOR`): one block at depth D becomes a 4x4 region at depth D+1. Structures lurk in the water below.

Most mechanics are early or incomplete. Expect to build systems out, not only to tune them.

## A note from Leo (HZ)

Hello, I'm Leo. I enjoy simple, well-optimized systems and simple, obvious code. Please don't keep complexity because it is already there, and do not add machinery because it looks impressive. Find the real constraint first, then build the smallest thing that makes the correct behavior unsurprising.

Channel both "measure twice, cut once" and YAGNI. Fight scope creep. Honor my intent in a minimal and realistic way.

Depthwell is a cozy game. When a change is a judgment call, choose what a player reads as calm and legible on screen over what is technically cleverer. I often say "you decide taste". I mean it, but it is taste inside the constraint, not a license to widen scope.

I am a solo developer and am still learning parts of this domain. When you use a data structure or an algorithm not in the code (a radix heap, a Wang tiling, an SoA layout), explain it in about three lines where you use it, and say what breaks without it. Do not assume I know it. Do not skip it because it looks basic.

Treat this file as good defaults, not hard rules. What I say in the thread overrides anything here.

## Response format

- Lead with the change or the answer. No preamble, no restatement of my request.
- Plain words. Not: elegant, robust, seamless, comprehensive, leverage, nuanced, delve.
- Put uncertainty on its own line as `Unverified: ...`. Do not hedge inside sentences.
- Cite code as `path/file.zig:123` so I can click it.

## Example

Prompt: Think of solutions to buttons being async and triggering multiple calls, thereby causing repeated SimBuffer regeneration and lagging the game for multiple seconds on holding down Teleport/Reset.

DON'T:

> The practical async solution is not to force WebCrypto synchronous—seed mixing inherently awaits `crypto.subtle`. I implemented:
>
> - Engine-level single-flight `start()`: every caller joins the existing start promise.
> - Reset remains focusable; no `.disabled`.
> - Focused-button held Enter/Space repeats are suppressed for both save buttons and debug buttons, including synchronous Teleport.

DO:

> After doing some analysis, the best solution is likely to queue button actions until the next render frame. This keeps logic simple and practical with minimal changes.
>
> Holding off on implementation until your explicit approval: I'd need to know whether only one button's action should be executed per render frame, or multiple (batched sequentially).

When the user asks to think/plan, do not implement yet. When they ask to fix/change, implement within scope and use the performance rules below.

### Before you report done

- Restate every ask for multi-part tasks or reviews in my message as a checklist, questions included. Answer the questions explicitly. Do not answer only the imperatives.
- If you changed one arm of an enum or one branch of a rule table, name the sibling arms you checked and say why they need no change.
- Name the invariant your change could break, and say how you verified it holds.
- Run `npm run lint:comments`. It must exit clean.
- Tell me how to verify the change in the running game. Say this BEFORE you implement, not after.
- For hot, input, render, worldgen, or startup code, state the work bound. Measure first when work scales, adds allocation or iteration, or is uncertain. Otherwise, say why a fixed-cost change needs no measurement. Verify changes players can feel.
- For input/reentry bugs, trace the event source and call graph before adding guards.

### When a fix does not work

After two failed attempts at the same symptom, stop editing.
Write the hypotheses that remain, the evidence for and against each, and the one observation that separates them.
Then ask me. Do not try a third variation of the same guess.

For a worldgen visual bug, translate the screenshot into exact parent and child cells before editing. Identify the parent sprite, its 3×3 neighborhood, `(lx, ly)`, and water volume. Trace every branch that can produce the observed child sprite. Add a regression test for that complete input, not only for the proposed helper.

If you cannot accurately deduce coordinates and probable 4x4 block regions from screenshots, please tell me. I can easily guide you through the details. A failed visual fix invalidates the diagnosis, not only the implementation. Before the next edit, reproduce the observed output at the public generation entry point or identify the exact producing branch with instrumentation. Do not infer a logical sprite from its rendered color or texture. Variation, lighting, water, and overlays can change its appearance.

## Disagreement

This is the default. I should not have to ask for it.

- Tell me when I am wrong, including when I name the cause, the file, or the fix. I am often guessing.
- Do not soften a real objection into a suggestion. Lead with the objection.
- If my request rests on a false premise, say so before doing the work, then do what I actually need.
- Propose the bold version when it is genuinely better, even if it is larger than I asked for.
  Say what it costs. Then do the small version unless I choose the bold one.
- "You decide taste" does not mean agree with me. It means choose, and defend the choice.
- Never agree to be agreeable. State low confidence as a number or a range.
- Report what you verified and what you assumed. A test you did not run is not a pass.

## Performance baseline

Target hardware is a decent Chromebook or any laptop with a 2020-or-later integrated GPU.
The goal is 60 fps at least 70-80% of the time on that machine, not on mine.

- Per-pixel shader cost scales with NATIVE resolution, not the 480x270 camera. `devicePixelRatio` alone can make it 4x.
- The game is single-core bound on the JS side. A main-thread stall shows as a dropped frame.
- Debug-build assertions in worldgen inner loops cost real time, and Debug is where I profile.
- Say which hardware and which build mode your measurement came from. "Fast on my machine" is not a result.

## Rules

1. **Never touch `dist/` or `public/`.** They are build output, and I build them myself. Never write outside this repository, with Zig or otherwise. If a task seems to need that, stop and ask.
2. **Use Jujutsu for version-control work.** Do not use Git to create, amend, restore, reset, stage, commit, or otherwise alter repository history or contents. Use `jj new` before a large task and `jj describe -m "..."` to record it. `jj undo` or `jj undo abcdef01` restores.
3. **Stop me immediately when the request is unclear.** Quickly bail from thinking, instead of guessing, and ask: "To clarify, are you asking me to implement X feature/should I modify Y thing?"
4. **Ask early when a change moves game logic into TypeScript, changes a WASM boundary, changes shader or sprite visuals, adds persistent UI/state, or changes scope.** For local host wiring, clear bug fixes, and objectively specified behavior, use best judgment. Ask about `.aseprite` edits and unclear scope at the start of a task, not at the end.
5. **Propose, do not perform, a large refactor.** Large means any ONE of these: it adds cross-frame state, it adds or removes a cache layer, it moves ownership between systems, it adds a queue or a loading state, or it changes more than one gameplay system. Anything smaller, just do. Describe a large one in prose and wait for approval.
6. **New sprites need permission.** They need `*_START` range edits in `zig/types/sprite.zig`, possibly a new `SpriteRule`, and manual Aseprite work.
7. **Assert argument preconditions at the top of a function.** Check what the caller must have got right (range, alignment, "power of two", non-empty), not what the body computes. State the constraint by name, not by value: `assert(isPowerOfTwo(width))`, not `assert(width > 0)`.
8. **Document a contract where it is OWNED, and only for shared ones.** A cross-file invariant or a public precondition belongs in the doc comment of the function that owns it, enforced with `comptime` or `assert` there. Do not repeat it at every call site, and do not assert inside a hot loop that a caller already guarded: that hides the real contract and costs Debug time.
9. **Explain the new invariants** at the end of a significant refactor or logic change: what must stay true for the new code to be correct.
10. **Trailing commas control the formatter.** A trailing comma makes `zig fmt` go multiline. Always use one in a parameter list of more than 5 arguments.
11. **Leave nothing running and nothing temporary behind.** Remove debug logging, `std.debug.print`, timing probes, and scratch files you added. Kill any process or server you started. Never kill `npm run dev`: it is mine and it is always running. If you must leave something in, say so in your final message.
12. **Keep a reference file true.** If you change behavior that `docs/agents/*.md` describes, update that file in the same change. Never edit `AGENTS.md` or `CLAUDE.md`; propose the wording to me instead.

### Comment style

- **Always follow ASD-STE100 Simplified Technical English**, semi-strict: short sentences, plain words, minimal prose. Ignore the all-caps rules.
- Doc comments (`///`, `//!`): wrap with semantic line breaks, about one idea per line. **Always** backticks around identifiers, and always parens after a function name — `` `variable` ``, `` `myFn()` ``.
- Normal comments (`//`): **never** use backticks.
- Comment rot is the main risk in this repository. Keep comments true; delete stale ones.
- `npm run lint:comments` checks these rules on the lines you changed. Run it before you report done and fix _just your own comments_. `npm run lint:comments:all` scans the whole tree, which still has legacy findings; do not bulk-fix them unless I ask.

## Commands

| Command                   | When                                    |
| ------------------------- | --------------------------------------- |
| `zig build`               | Only to confirm that the code compiles. |
| `zig test "zig/root.zig"` | Only after you add or change a test.    |
| `npm run lint:comments`   | Before you report done, every time.     |

- `npm run dev` is **always running**. The WASM and the web bundle automatically rebuild themselves when I'm previewing. Do not start servers.
- Do **not** worry about `-Dgen-enums`; I can regenerate myself. The codegen tool is separate; `src/enums.ts` only holds export signatures.
- I build `dist/` myself with `npm run build`, which compiles the WASM in **ReleaseSafe**. There is no pre-commit hook, and jj does not run git hooks, so nothing rebuilds it for you.
- The target is Chromium. Inspect an attached preview or screenshot first, and read what I described in words: that is usually enough.
  Do not ask for a screenshot before you start, and do not treat one as a gate. Taste needs iteration, so make a defensible choice and tell me exactly what to look at.
  Ask for one only when you are diagnosing a visual bug you cannot reproduce from the description.
- Use `.claude/tmp/` freely for scratch work. For WASM there, read `build.zig` first to match `-Dwasm-opt` and the `std.Target.wasm.Feature` set.
- **Worldgen performance work starts at `.claude/tmp/README.md`.** It has a native benchmark (`bench.zig`) that drives `generateBaseChunk()` and `generateChunk()` without the JS host, plus how to make a baseline and how to count cache misses. Run it before you theorize.
- `zig/native_app.zig` is **unused** (a stub for the future Mach desktop port). Ignore it. Everything else can be refactored.

## Where things are

- **Read whole functions, and their callers, before you edit.** `zig/state/world.zig` is about 5000 lines and `water.zig` about 1000. A 100-line window of one of these is 2% of the file, and most bugs here live in the part you did not open. If a file is too large to read at once, read every function that touches the one you are changing.
- `zig/root.zig` — the code root. It lists almost every Zig file, so use it as the map.
- `README.md` "Architecture details" — datatype reasoning and architecture. Bit and struct layouts there can lag; **trust the code**.
- `//!` headers inside a Zig file explain that file.
- `zig/render/entity.zig` — entity rendering (README "Entities").
- `zig/menus/` — menu and UI state, held globally.

## Core concepts

Trust the code over this section if they disagree.

### `dev_menu` vs `is_debug` (`root.zig`)

Two different questions, and the wrong one is easy to pick.

- `is_debug` = the **build mode** (`builtin.is_test or builtin.mode == .Debug`). It controls assertions and logging.
- `dev_menu` = whether the **debug UI and its support code** are compiled in: tuning sliders, heatmaps, creative mode, depth hotkeys, `audit.zig`, `chunk_preview.zig`, the logger text buffers, `CAMERA_MIN_ZOOM`.
- `dev_menu` is a hand-set constant, independent of the optimize mode. `ReleaseFast` + `dev_menu` is the build to profile.
- Anything the debug panel owns must gate on `dev_menu`, or it disappears from a release profiling build.
- `TuningFloat`/`TuningBool` follow `dev_menu`. With it off they become `const` and every noise scale constant-folds — worth 13-26% of worldgen alone.
- The `isDebug()` WASM export reports `dev_menu`, not the build mode.

### Units and coordinates

- `CHUNK_SIZE = 16` is overloaded: blocks per chunk edge, pixels per block edge, and subpixels per pixel edge. So a chunk edge is 256 px and 4096 subpixels (`SUBPIXELS_IN_CHUNK`).
- Player X/Y are subpixels that wrap in `[0,4095]`. The internal viewport is fixed at 480x270 (`SCREEN_WIDTH`/`SCREEN_HEIGHT`).
- A `Coordinate` is `{ suffix: [2]u64, quadrant: u2 }`, quadrant 0=NW, 1=NE, 2=SW, 3=SE. A `DepthCoordinate` adds `depth`.
- `HORIZON_DEPTH = 32`. `BLOCKS_PER_PARENT = 4` (a 4x4 child-block area maps to one parent block).
- Parent and ancestor lookups are in `zig/state/ancestor.zig`. `Coordinate.move()/moveX()/moveY()` return `null` at a world edge.
- README "Architecture details" explains D (current depth) and H (horizon).

### Reference files

These hold the detail that drifts. Each one says at the top when to read it.
Read the relevant file BEFORE you edit, not after something breaks.

| Read this                 | Before you touch                                                                                                                                                               |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `docs/agents/worldgen.md` | `zig/state/procedural.zig`, `ancestor.zig`, `refine.zig`, `structures.zig`, `decorations.zig`; depth refinement, carving, dispersal, infill, ore placement, cache invalidation |
| `docs/agents/render.md`   | `zig/render/`, `zig/menus/`, `src/shader.wgsl`, sprite variation, lighting, particles, colors                                                                                  |
| `docs/agents/boundary.md` | `Block` or any packed struct, the save format, a `pub` export in `zig/root.zig`, `src/*.ts` WASM calls                                                                         |

If you change behavior a reference file describes, update that file in the same change.
Do NOT edit `AGENTS.md` or `CLAUDE.md`: ask me instead.
