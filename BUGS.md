# Bugs

One line per bug, with a priority. Not a roadmap. A bug that does not block the
current slice goes here and is not fixed now.

- **P3** Migrate to Zig 0.17.0.
- **P4** `FastHash.hash2d()` combines its two lanes as `(h1 ^ h2) + (h1 >> 32) + (h2 >> 32)`.
  Xor-ing any value under 2^32 into both lanes leaves all three terms unchanged, so a reader
  who knows the seed can compute colliding coordinate pairs directly instead of searching.
  Structureless: the multiply scatters the family, so no line or region can be built from it.
  Not fixed. The combine is the hottest step in worldgen and the payoff of a collision is nil.
- **P2** WebGPU frame rate: below 30 fps on an M1 Air in Low Power Mode, below 60 fps on the
  dev machine in Low Power Mode. Acceptable on a mid-range Chromebook. Untested whether this
  is fill rate or Low Power Mode clock capping; halve `devicePixelRatio` and re-measure to
  separate them.
- **P3** Portal audio effect is incomplete.
- **P3** Material boundaries between sand, stone, and blue stone read as straight block-aligned
  lines against the eroded silhouette. No fix chosen; see `DESIGN.md` parked items.
