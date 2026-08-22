# Aider instructions for Depthwell

This file is the small coding-agent subset of the larger workspace guidance;
the repository's `README.md` remains the source of truth for project behavior.

- This is a Zig/WASM project. Read the build notes in `README.md` before changing build behavior.
- Run `zig test zig/root.zig` for the test suite and to see compiler errors. `build.zig` does not define a `test` step, so do not run `zig build test`.
- Check formatting with `zig fmt --check .` and keep generated outputs consistent with their source generators.
- Don't run non-Zig commands or shell files without asking for explicit permission.
- Preserve the existing project architecture and make the smallest change that fixes the requested behavior.
