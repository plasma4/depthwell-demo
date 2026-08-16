import * as Zig from "./enums";
import { SaveManager } from "./saveManager";
import * as Seeding from "./seeding";
import { MAX_DRAW_CALLS, GameEngine } from "./engine";

/** The URL for the WebAssembly code (compiled from zig build). */
import WASM_URL from "/main.wasm?url";
/**
 * The URL for the WebGPU shader code.
 */
import SHADER_SOURCE from "./shader.wgsl";
/** The URL for the sprite sheet. */
import SPRITE_SHEET_URL from "/assets/main.png?url";
/** The URL for the sprite sheet. */
import SPRITE_SHEET_MASK_URL from "/assets/mainMasked.png?url";
import { CONFIG } from "./main";

/** Creates a new `GameEngine`, sets up WebGPU shaders, and calls `init()` from Zig. */
export async function create(
    canvas?: HTMLCanvasElement | string,
    options?: Zig.EngineOptions,
): Promise<GameEngine> {
    const adapter = await navigator.gpu.requestAdapter({
        powerPreference:
            options && options.highPerformance
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
            throw TypeError(
                "No canvas element or ID string provided, and no canvas was not found in the HTML.",
            );
        }
        // Using the first HTML canvas element to create the GameEngine here
    } else if (typeof canvas === "string") {
        const elem = document.getElementById(canvas);
        if (!(elem instanceof HTMLCanvasElement)) {
            throw TypeError(
                `Element with ID "${canvas}" is not a canvas element.`,
            );
        }
        canvas = elem;
    }
    const context = canvas.getContext("webgpu");
    if (!context) {
        throw Error("Could not get WebGPU context from canvas.");
    }

    // Firefox is silly and doesn't always support the rgba16float texture format for whatever reason
    // so we just fall back to "bgra8unorm"
    var format: GPUTextureFormat = "rgba16float";
    let supportsP3 = window.matchMedia("(color-gamut: p3)").matches;
    let chosenColorSpace: PredefinedColorSpace = supportsP3
        ? "display-p3"
        : "srgb";

    try {
        context.configure({
            device,
            format: format,
            colorSpace: chosenColorSpace,
            alphaMode: "opaque",
        });
    } catch (e) {
        format = "bgra8unorm";
        chosenColorSpace = "srgb"; // Force sRGB for 8-bit fallback
        context.configure({
            device,
            format: format,
            colorSpace: chosenColorSpace,
            alphaMode: "opaque",
        });
    }

    // Fetch WASM
    const textElems: HTMLSpanElement[] = [
        document.getElementById("text1") as any,
        document.getElementById("text2"),
        document.getElementById("text3"),
        document.getElementById("text4"),
    ];
    const mem = new WebAssembly.Memory({
        initial: 128, // start with 8 MiB in WASM memory
    }) as WebAssembly.Memory;
    const engineModule = await WebAssembly.instantiateStreaming(
        fetch(WASM_URL),
        {
            env: {
                memory: mem,
                // See how logging works in logger.zig; logging always returns valid arguments
                jsMessage: (
                    ptr: Zig.Pointer,
                    len: Zig.LengthLike,
                    category: number,
                ) => {
                    let str = new TextDecoder().decode(
                        new Uint8Array(memory.buffer, Number(ptr), Number(len)),
                    );
                    if (str.charAt(0) !== "]") {
                        str = "[" + (engine!.LOGGING_PREFIX || "") + str;
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
                jsWriteText: (
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
                    const el = textElems[id];
                    if (bytes.length == 0) el.style.display = "none"; // hide elem entirely
                    el.removeAttribute("style"); // unhide if needed
                    el.textContent = str;
                },
                jsGetTime: () => performance.now(),
                jsHandleVisibleChunks: (
                    opacity: number,
                    wireframeBrightness: number,
                ) => engine!.handleVisibleChunks(opacity, wireframeBrightness),
                jsHandleVisibleEntities: () => engine!.handleVisibleEntities(),
                jsDrawBackground: (opacity: number) =>
                    engine!.drawBackground(opacity),
                jsSetMouseType: (type: number) => engine!.setMouseType(type),
                jsPlaySound: (id: number, volume: number, pitch: number) =>
                    engine!.playSound(id, volume, pitch),
            },
        },
    );
    const exports = engineModule.instance.exports as Zig.EngineExports;
    const memory = exports.memory as WebAssembly.Memory;

    // Make the shader!
    if (CONFIG.verbose) {
        console.log(
            `Tile size: ${exports.getTilesPerRow()}x${exports.getTilesPerColumn()}`,
        );
    }
    const shaderModule = device.createShaderModule({
        label: "Main shader",
        code: SHADER_SOURCE, // already pre-processed
    });

    const bindGroupLayout = device.createBindGroupLayout({
        label: "Main bind group layout",
        entries: [
            {
                binding: 0,
                visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
                buffer: { type: "uniform", hasDynamicOffset: true }, // can be swapped live
            }, // SceneUniforms

            {
                binding: 1,
                visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
                buffer: { type: "read-only-storage" },
            }, // tiles
            { binding: 2, visibility: GPUShaderStage.FRAGMENT, texture: {} }, // atlas (main)
            { binding: 3, visibility: GPUShaderStage.FRAGMENT, texture: {} }, // atlas (masks)
            { binding: 4, visibility: GPUShaderStage.FRAGMENT, sampler: {} }, // sampler

            {
                binding: 5,
                visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
                buffer: { type: "read-only-storage" },
            }, // entities
        ],
    });

    const pipelineLayout = device.createPipelineLayout({
        label: "Shared Pipeline Layout",
        bindGroupLayouts: [bindGroupLayout],
    });

    // Create pipelines
    const tilePipeline = device.createRenderPipeline({
        label: "Tilemap pipeline",
        layout: pipelineLayout,
        vertex: {
            module: shaderModule,
            entryPoint: "vs_tile",
        },
        fragment: {
            module: shaderModule,
            entryPoint: "fs_tile",
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
            targets: [
                {
                    format: format,
                    // fs_background returns premultiplied color (rgb * opacity, opacity), so the
                    // background cross-dissolves during a portal descent, where the D+1 background
                    // is drawn over D's
                    blend: {
                        color: {
                            srcFactor: "one",
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
            // One strip is one background cell quad, so 4 vertices instead of the 6 a list needs
            // The noise runs once per vertex, so this is a third of the work for the same image
            topology: "triangle-strip",
        },
        // depthStencil: {
        //     depthWriteEnabled: false, // Background doesn't need to write to depth
        //     depthCompare: "less-equal", // Only draw where Z is 1.0 (empty space)
        //     format: "depth24plus",
        // },
    });

    const entityPipeline = device.createRenderPipeline({
        label: "Entity pipeline",
        layout: pipelineLayout,
        vertex: {
            module: shaderModule,
            entryPoint: "vs_entity",
        },
        fragment: {
            module: shaderModule,
            entryPoint: "fs_entity",
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
        },
    });

    engine = new GameEngine(
        canvas,
        adapter,
        device,
        context,
        engineModule,
        tilePipeline,
        bgPipeline,
        entityPipeline,
    );

    const saveManager = new SaveManager(engine);
    engine.saveManager = saveManager;
    const acquired = await saveManager.tryAcquireTabExclusiveLock();
    if (!acquired) {
        alert(
            "Game is open in another tab! Please use that tab or close it to continue.",
        );
        window.onerror = null;
        await saveManager.acquireLockWithRetry();
    }

    engine.exports.main();

    const loaded = await engine.saveManager.load();
    if (!loaded) {
        engine.start();
    }

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
    const atlasTextureMask = await GameEngine.loadTexture(
        device,
        SPRITE_SHEET_MASK_URL,
        "rgba8unorm",
    );

    // Create sampler (nearest neighbor for pixel art)
    const pixelSampler = device.createSampler({
        magFilter: "nearest",
        minFilter: "nearest",
        addressModeU: "clamp-to-edge",
        addressModeV: "clamp-to-edge",
    });

    engine.atlasTextureView = atlasTexture.createView();
    engine.atlasTextureMaskView = atlasTextureMask.createView();
    engine.pixelSampler = pixelSampler;

    engine.uniformBuffer = device.createBuffer({
        label: "SceneUniforms",
        size: 256 * MAX_DRAW_CALLS, // see setSceneData() in engine.ts OR SceneUniforms in shader.wgsl to understand this
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    });
    engine.entityBuffer = engine.device.createBuffer({
        label: "Entities",
        size: 2400, // starting value, 50 entities here
        usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
    });

    // engine.uploadVisibleChunks();
    // engine.handleVisibleChunks();

    // Upload initial tile data
    // device.queue.writeBuffer(engine.tileBuffer, 0, tileMap.data.buffer);
    // device.queue.writeBuffer(
    //     mapSizeBuffer,
    //     0,
    //     new Uint32Array([tileMap.width, tileMap.height]),
    // );

    // Do some media monitoring
    engine.isP3 = supportsP3 && format === "rgba16float";
    engine.is8Bit = format === "bgra8unorm";

    // Monitor gamut changes (e.g. dragging window to a different monitor)
    engine.gamutMediaQuery = window.matchMedia("(color-gamut: p3)");
    engine.gamutMediaQuery.addEventListener("change", (e) => {
        const nowP3 = e.matches && format === "rgba16float";
        if (nowP3 !== engine!.isP3) {
            engine!.isP3 = nowP3;
            context.configure({
                device,
                format: format,
                colorSpace: nowP3 ? "display-p3" : "srgb",
                alphaMode: "opaque",
            });
        }
    });

    return engine;
}
