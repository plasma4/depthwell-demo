# Bugs

One line per bug, with a priority.

- low: `readHeaderCore()` copies the stored `GameState` in by length alone, so a save from a build whose field ORDER differs loads garbage; needs a more resilient ordered storage method in the future
