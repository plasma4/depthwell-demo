# Depthwell

Depthwell is a procedurally generated fractal mining incremental roguelite. How deep can you mine? Minimal demo releasing August 1st.

### Building

Run `zig build` for the main build of Zig code, `zig build test` to run tests, and `zig build enum` to generate `enums.ts` dynamically. When building for production with Vite (`npm run build` instead of `npm run dev`), et `SHADER_SOURCE` in `engine.ts` to `"./shader.wgsl"` (without the `?raw` property) to actually compress `shader.wgsl`.
