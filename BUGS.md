# Bugs

One line per bug, with a priority.

- low: `readHeaderCore()` copies the stored `GameState` in by length alone, so a save from a build whose field ORDER differs loads garbage; needs a more resilient ordered storage method in the future
- low: nothing re-centers `quad_cache.ancestor_materials` on the player, so drift past about 4 blocks at H (only a debug teleport reaches this) is `panicUnresolvedAncestor()` rather than a re-derived window
- low: `HorizonTrace.source_quadrant` is written by `traceHorizon()` and read by nothing since the window origin fix; drop it whenever the save format next breaks
