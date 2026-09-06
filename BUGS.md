# Bugs

One line per bug, with a priority.

- low: `readHeaderCore()` copies the stored `GameState` in by length alone, so a save from a build whose field ORDER differs loads as garbage instead of a rejected import; the section carries no layout hash.
