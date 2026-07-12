import { defineConfig } from "vite";
import glsl from "vite-plugin-glsl";

export default defineConfig(({ command }) => {
    // check if we are in production build mode for shader compression
    const isBuild = command === "build";

    return {
        base: "",
        server: {
            watch: {
                // ignore Jujutsu VCS directory
                ignored: ["**/.jj/**"],
            },
        },
        plugins: [
            glsl({
                minify: isBuild,
            }),
            {
                name: "watch-wasm",
                configureServer(server) {
                    server.watcher.add("main.wasm");

                    // trigger a full page reload when a watched wasm file changes
                    server.watcher.on("change", (file) => {
                        if (file.endsWith(".wasm")) {
                            server.ws.send({
                                type: "full-reload",
                                path: "*",
                            });
                        }
                    });
                },
            },
        ],
    };
});
