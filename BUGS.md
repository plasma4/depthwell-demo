# Bugs

One line per bug, with a priority. Not a roadmap. A bug that does not block the
current slice goes here and is not fixed now.

- **P3** Migrate to Zig 0.17.0.
- **P3** `shiftWorld()` (`procedural.zig:1281`) wraps a `u128` when a negative domain warp
  reaches past world coordinate 0, so `latticeAxis()` drops bits 96..128 and the ore field
  seams. Measured: 29,242 of 2,496,000 samples underflow over x in 0..24 and y in 0..4000,
  worst negative warp -6 blocks, so it reaches x < 6 and y < 6 only. Cosmetic, at two edges
  of a 2^30-block world, behind the 2-block unmineable border.
- **P2** WebGPU frame rate: below 30 fps on an M1 Air in Low Power Mode, below 60 fps on the
  dev machine in Low Power Mode. Acceptable on a mid-range Chromebook. Untested whether this
  is fill rate or Low Power Mode clock capping; halve `devicePixelRatio` and re-measure to
  separate them.
- **P3** Portal audio effect is incomplete.
- **P3** Material boundaries between sand, stone, and blue stone read as straight block-aligned
  lines against the eroded silhouette. No fix chosen; see `DESIGN.md` parked items.
