import * as Zig from "./enums";
import * as Seeding from "./seeding";
import { GameEngine } from "./engine";

/** The URL for the WebAssembly code (compiled from zig build). */
import WASM_URL from "./main.wasm?url";
/** The URL for the WebGPU shader code. */
import SHADER_SOURCE from "./shader.wgsl?raw";
/** The URL for the sprite sheet. */
import SPRITE_SHEET_URL from "./assets/main.png?url";

/** The texture format for WebGPU. */
const TEXTURE_FORMAT: GPUTextureFormat = "rgba16float";

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

    context.configure({
        device,
        format: TEXTURE_FORMAT, // Must match the pipeline target below
        alphaMode: "opaque",
    });

    // Get shader
    const shaderModule = device.createShaderModule({
        label: "Main shader",
        code: SHADER_SOURCE,
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
                js_write_text: (id: number, ptr: number, len: number) => {
                    const bytes = new Uint8Array(memory.buffer, ptr, len);
                    const str = new TextDecoder().decode(bytes);

                    const el = document.getElementById(`text${id + 1}`);
                    if (el) {
                        el.textContent = str;
                    }
                },
            },
        },
    );
    const memory = engineModule.instance.exports.memory as WebAssembly.Memory;

    // Create pipeline
    const pipeline = device.createRenderPipeline({
        label: "Tilemap pipeline",
        layout: "auto",
        vertex: {
            module: shaderModule,
            entryPoint: "vs_main",
        },
        fragment: {
            module: shaderModule,
            entryPoint: "fs_main",
            targets: [
                {
                    format: TEXTURE_FORMAT,
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
            topology: "triangle-strip",
            cullMode: "none",
        },
    });

    engine = new GameEngine(
        canvas,
        adapter,
        device,
        context,
        engineModule,
        pipeline,
    );
    await engine.setSeed(Seeding.makeSeed(12));
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

    // camera: vec2f (8), viewport_size: vec2f (8), time: f32 (4), zoom: f32 (4), padding: vec2u (8)
    const uniformBuffer = device.createBuffer({
        label: "SceneUniforms",
        size: 48,
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    });
    engine.uniformBuffer = uniformBuffer;

    // Create map size buffer
    const mapSizeBuffer = device.createBuffer({
        label: "Map size",
        size: 16, // vec2u, but pad
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    });
    engine.mapSizeBuffer = mapSizeBuffer;

    // Initialize tilemap
    const tileMap = {
        width: 0,
        height: 0,
        data: new Uint32Array(0),
    };
    engine.tileMap = tileMap;

    engine.uploadVisibleChunks();

    // Upload initial tile data
    device.queue.writeBuffer(engine.tileBuffer, 0, tileMap.data.buffer);
    device.queue.writeBuffer(
        mapSizeBuffer,
        0,
        new Uint32Array([tileMap.width, tileMap.height]),
    );

    return engine;
}
