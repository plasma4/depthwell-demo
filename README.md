# Depthwell

Depthwell is a procedurally generated fractal mining incremental roguelite. How deep can you mine? Minimal demo releasing August 1st.

### Building

Run `zig build` for the main build of Zig code, `zig test "zig/root.zig"` to run (all) tests, and `zig build --Dgen-enums` to build and generate `enums.ts` dynamically. When building for production with Vite (`npm run build` instead of `npm run dev`), et `SHADER_SOURCE` in `engine.ts` to `"./shader.wgsl"` (without the `?raw` property) to actually compress `shader.wgsl`.

With a custom "clear screen" command (like `cls`) that utilizes ANSI-escape codes, you can use this command to quickly build and not clog the terminal:

```bash
cls && zig build --Dgen-enums
```
