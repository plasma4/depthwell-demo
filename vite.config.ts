import { defineConfig } from "vite";
import glsl from "vite-plugin-glsl";
const HEADER = `/*!
Thanks to Zig developers and all OSS contributors for creating the language.
Their contributions are what make Depthwell possible.

The MIT License (Expat)

Copyright (c) Zig contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*/`;
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
        esbuild: {
            legalComments: "inline",
        },
        build: {
            rollupOptions: {
                output: {
                    banner: HEADER,
                },
            },
        },
    };
});
