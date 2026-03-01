import glsl from "vite-plugin-glsl";

export default {
    plugins: [
        glsl({
            // IMPORTANT: When building (npm run dev), remove ?raw to SHADER_SOURCE temporarily to actually compress. I have not found a way around this that works for both dev and production.
            minify: true,
        }),
    ],
};
