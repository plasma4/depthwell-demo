# Bugs

One line per bug, with a priority.

- low: mining chips, the chest burst, and the water placement burst are screen-space particles, so they slide with the camera instead of staying on the block; each needs `.anchored = true` and a `particles.anchorScreenPx()` origin.
- low: a horizontal or vertical decay rate tuned to exactly 0 divides by zero in `player.move()`; none is exposed as a slider today.
- low: a teleport shorter than one chunk slips past the particle anchor's teleport guard, so anchored dust slides once before it expires.
- low: `QuadCache.getQuadrantEdgeDetails()` has no callers, so `most_left`/`most_right`/`most_top`/`most_bottom` are folded, saved, and replayed but never reach generation.
- low: a preview install leaves D+1 entries in the seed cache after `restoreLayer()`; harmless while a descent always runs to `portal.finish()`, but a cancel path would need `clearCaches()`.
- low: a save written before the first-rebase clamp, with the player standing at depth 32 in quadrant 1, trips the window assert in `computeLayer()`; only a world that descended into the far quarter at depth 32 and came back up can be in that state.
