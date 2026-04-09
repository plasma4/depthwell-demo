import * as Zig from "./enums";
import * as Seeding from "./seeding";
import { GameEngine } from "./engine";

/** The URL for the WebAssembly code (compiled from zig build). */
import WASM_URL from "./main.wasm?url";
/** The URL for the WebGPU shader code. ADD ?raw FOR DEBUGGING SHADER. */
import SHADER_SOURCE from "./shader.wgsl?raw"; // TODO remove ?raw for prod
/** The URL for the sprite sheet. */
import SPRITE_SHEET_URL from "./assets/main.png?url";

/** Creates a new GameEngine, sets up WebGPU shaders, and calls init() from Zig. */
export async function create(
    canvas?: HTMLCanvasElement | string,
    options?: Zig.EngineOptions,
): Promise<GameEngine> {
    const config = { highPerformance: false, ...options };

    const adapter = await navigator.gpu.requestAdapter({
        powerPreference: config.highPerformance
            ? "high-performance"
            : "low-power",
    });
    if (!adapter)
        throw new DOMException(
            "Couldn't request WebGPU adapter.",
            "NotSupportedError",
        );

    const device = await adapter.requestDevice();
    let engine: GameEngine | null = null;
    device.addEventListener("uncapturederror", (e) => {
        const error = e.error;
        if (engine === null) {
            if (globalThis.reportError as Function | undefined) {
                reportError(error);
            } else {
                throw error;
            }
        } else if (!engine.destroyed) {
            engine.destroy("fatal WebGPU error", error);
            return;
        }
    });

    device.lost.then((info) =>
        console.error(`WebGPU Device lost: ${info.message}`),
    );

    if (canvas === undefined) {
        canvas = document.getElementsByTagName("canvas")[0];
        if (canvas === undefined) {
            throw Error(
                "No canvas element or ID string provided, and no canvas was not found in the HTML.",
            );
        }
        // Using the first HTML canvas element to create the GameEngine here.
    } else if (typeof canvas === "string") {
        const elem = document.getElementById(canvas);
        if (!(elem instanceof HTMLCanvasElement)) {
            throw Error(`Element with ID "${canvas}" is not a canvas element.`);
        }
        canvas = elem;
    }
    const context = canvas.getContext("webgpu");
    if (!context) {
        throw Error("Could not get WebGPU context from canvas.");
    }

    // Firefox is silly and doesn't support the rgba16float texture format for whatever reason
    const format = device.features.has("canvas-rgba16float-support")
        ? "rgba16float"
        : "bgra8unorm";
    context.configure({
        device,
        format: format, // Must match the pipeline target below
        alphaMode: "opaque",
    });

    // Fetch WASM
    const engineModule = await WebAssembly.instantiateStreaming(
        fetch(WASM_URL),
        {
            env: {
                // See how logging works in logger.zig. Logging is guaranteed to return valid arguments.
                js_message: (
                    ptr: Zig.Pointer,
                    len: Zig.LengthLike,
                    category: number,
                ) => {
                    let str = new TextDecoder().decode(
                        new Uint8Array(memory.buffer, Number(ptr), Number(len)),
                    );
                    if (str.charAt(0) !== "]") {
                        str = "[" + (engine?.LOGGING_PREFIX || "") + str;
                    } else {
                        str = str.slice(1);
                    }
                    if (category === 1) {
                        console.info("%c" + str, "font-weight: 600");
                    } else {
                        [
                            console.log,
                            console.info,
                            console.warn,
                            console.error,
                        ][category](str);
                    }
                },
                js_write_text: (
                    id: number,
                    ptr: Zig.Pointer,
                    len: Zig.Pointer,
                ) => {
                    const bytes = new Uint8Array(
                        memory.buffer,
                        Number(ptr),
                        Number(len),
                    );
                    const str = new TextDecoder().decode(bytes);

                    const el = document.getElementById(
                        `text${id + 1}`,
                    ) as HTMLSpanElement;
                    el.textContent = str;
                },
                js_get_time: () => performance.now(),
                js_handle_visible_chunks: (opacity: number) =>
                    engine?.handleVisibleChunks(opacity),
            },
        },
    );
    const exports = engineModule.instance.exports as Zig.EngineExports;
    const memory = exports.memory as WebAssembly.Memory;

    // Make the shader!
    const shaderModule = device.createShaderModule({
        label: "Main shader",
        // constant patching, basically override keyword in WGSL
        code: SHADER_SOURCE.replace(
            "/* TILES_PER_ROW */ 1.0 /* TILES_PER_ROW */",
            "" + exports.get_tiles_per_row(),
        ).replace(
            "/* TILES_PER_COLUMN */ 1.0 /* TILES_PER_COLUMN */",
            "" + exports.get_tiles_per_column(),
        ),
    });

    const bindGroupLayout = device.createBindGroupLayout({
        label: "Main bind group layout",
        entries: [
            {
                binding: 0,
                visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
                buffer: { type: "uniform" },
            }, // SceneUniforms
            {
                binding: 1,
                visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
                buffer: { type: "read-only-storage" },
            }, // tiles
            { binding: 2, visibility: GPUShaderStage.FRAGMENT, texture: {} }, // atlas
            { binding: 3, visibility: GPUShaderStage.FRAGMENT, sampler: {} }, // sampler
        ],
    });

    const pipelineLayout = device.createPipelineLayout({
        label: "Shared Pipeline Layout",
        bindGroupLayouts: [bindGroupLayout],
    });

    // Create pipeline
    const pipeline = device.createRenderPipeline({
        label: "Tilemap pipeline",
        layout: pipelineLayout,
        vertex: {
            module: shaderModule,
            entryPoint: "vs_main",
        },
        fragment: {
            module: shaderModule,
            entryPoint: "fs_main",
            targets: [
                {
                    format: format,
                    blend: {
                        color: {
                            srcFactor: "src-alpha",
                            dstFactor: "one-minus-src-alpha",
                        },
                        alpha: {
                            srcFactor: "one",
                            dstFactor: "one-minus-src-alpha",
                        },
                    },
                },
            ],
        },
        primitive: {
            topology: "triangle-list",
            cullMode: "none",
        },
        // depthStencil: {
        //     depthWriteEnabled: true,
        //     depthCompare: "less-equal",
        //     format: "depth24plus",
        // },
    });

    const bgPipeline = device.createRenderPipeline({
        label: "Background pipeline",
        layout: pipelineLayout,
        vertex: {
            module: shaderModule,
            entryPoint: "vs_background",
        },
        fragment: {
            module: shaderModule,
            entryPoint: "fs_background",
            targets: [{ format: format }],
        },
        primitive: {
            topology: "triangle-list",
        },
        // depthStencil: {
        //     depthWriteEnabled: false, // Background doesn't need to write to depth
        //     depthCompare: "less-equal", // Only draw where Z is 1.0 (empty space)
        //     format: "depth24plus",
        // },
    });

    engine = new GameEngine(
        canvas,
        adapter,
        device,
        context,
        engineModule,
        pipeline,
        bgPipeline,
    );
    engine.exports.setup();
    await engine.setSeed(Seeding.makeSeed(100));
    engine.exports.init();

    const resizeObserver = new ResizeObserver(engine.onResize);
    (engine as any).resizeObserver = resizeObserver;
    engine.updateCanvasStyle();

    try {
        // Attempt the high-precision physical pixel observer
        engine.resizeObserver.observe(canvas, {
            box: "device-pixel-content-box",
        });
    } catch (e) {
        // Fallback for Safari or older browsers ):
        console.log(
            "ResizeObserver property device-pixel-content-box not supported, falling back to content-box.",
        );
        engine.resizeObserver.observe(canvas, { box: "content-box" });
    }

    engine.onResize([
        {
            contentRect: {
                width: canvas.clientWidth,
                height: canvas.clientHeight,
            } as DOMRectReadOnly,
        } as ResizeObserverEntry,
    ]);

    // Start working on WebGPU stuff
    const atlasTexture = await GameEngine.loadTexture(device, SPRITE_SHEET_URL);

    // Create sampler (nearest neighbor for pixel art)
    const pixelSampler = device.createSampler({
        magFilter: "nearest",
        minFilter: "nearest",
        addressModeU: "clamp-to-edge",
        addressModeV: "clamp-to-edge",
    });

    engine.atlasTextureView = atlasTexture.createView();
    engine.pixelSampler = pixelSampler;

    const uniformBuffer = device.createBuffer({
        label: "SceneUniforms",
        size: 56, // see setSceneData() in engine.ts OR SceneUniforms in shader.wgsl to understand this
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    });
    engine.uniformBuffer = uniformBuffer;

    // engine.uploadVisibleChunks();
    // engine.handleVisibleChunks();

    // Upload initial tile data
    // device.queue.writeBuffer(engine.tileBuffer, 0, tileMap.data.buffer);
    // device.queue.writeBuffer(
    //     mapSizeBuffer,
    //     0,
    //     new Uint32Array([tileMap.width, tileMap.height]),
    // );

    return engine;
}
