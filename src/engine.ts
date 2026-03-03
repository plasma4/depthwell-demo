"use strict";
/// <reference types="@webgpu/types" />
import * as Zig from "./enums";
import * as Seeding from "./seeding";
import * as InputManager from "./inputManager";
/* eslint-disable @typescript-eslint/no-explicit-any */

/**
 * Debug/testing options. Set all values to false in production.
 */
export const CONFIG = {
    /** Whether to expose engine to globalThis or not. */
    exportEngine: true,
    /** Whether to use verbose logging or not. */
    verbose: true,
    /** If set to true, disables alerting on error. Error will always show in console regardless of what this value is set to. */
    noAlertOnError: true,
};

export enum WasmTypeCode {
    Uint8 = 8,
    Uint16 = 16,
    Uint32 = 32,
    Uint64 = 64,

    Int8 = -8,
    Int16 = -16,
    Int32 = -32,
    Int64 = -64,

    Uint8Clamped = -80,
    Float32 = -320,
    Float64 = -640,
}

globalThis.WasmTypeCode = WasmTypeCode;

const WasmTypeMap = {
    [WasmTypeCode.Uint8]: Uint8Array,
    [WasmTypeCode.Uint16]: Uint16Array,
    [WasmTypeCode.Uint32]: Uint32Array,
    [WasmTypeCode.Uint64]: BigUint64Array,

    [WasmTypeCode.Int8]: Int8Array,
    [WasmTypeCode.Int16]: Int16Array,
    [WasmTypeCode.Int32]: Int32Array,
    [WasmTypeCode.Int64]: BigInt64Array,

    [WasmTypeCode.Uint8Clamped]: Uint8ClampedArray,
    [WasmTypeCode.Float32]: Float32Array,
    [WasmTypeCode.Float64]: Float64Array,
} as const;

const { random } = Math;

/** The URL for the WebAssembly code (compiled from zig build). */
import WASM_URL from "./main.wasm?url";
/** The URL for the WebGPU shader code. */
import SHADER_SOURCE from "./shader.wgsl?raw";
/** The URL for the sprite sheet. */
import SPRITE_SHEET_URL from "./assets/main.png?url";

/** The texture format for WebGPU. */
const TEXTURE_FORMAT: GPUTextureFormat = "rgba16float";

/** The width for the sprite sheet tilemap. */
const initialMapWidth = 32;
/** The height for the sprite sheet tilemap. */
const initialMapHeight = 32;

/** The logical internal width (scaled with WebGPU). */
const INTERNAL_WIDTH = 480;
/** The logical internal height (scaled with WebGPU). */
const INTERNAL_HEIGHT = 270;

/** Edge flag constants matching shader. */
const EdgeFlags = {
    TOP_LEFT: 0x01,
    TOP: 0x02,
    TOP_RIGHT: 0x04,
    LEFT: 0x08,
    RIGHT: 0x10,
    BOTTOM_LEFT: 0x20,
    BOTTOM: 0x40,
    BOTTOM_RIGHT: 0x80,
} as const;

interface TileMap {
    width: number;
    height: number;
    /** Packed tile data: spriteId | edgeFlags << 8 | light << 16 | variation << 24 */
    data: Uint32Array;
}

export class GameEngine {
    /** The engine module automatically generated from Emscripten. */
    public readonly engineModule: WebAssembly.WebAssemblyInstantiatedSource;
    /** The exported functions from the engineModule. */
    public readonly exports: Zig.EngineExports;
    /** The memory from the engineModule. */
    public readonly memory: WebAssembly.Memory;
    /** The canvas where rendering is presented. */
    public readonly canvas: HTMLCanvasElement;
    /** The WebGPU adapter for the system. */
    public readonly adapter: GPUAdapter;
    /** The logical WebGPU device. */
    public readonly device: GPUDevice;
    /** The WebGPU context for the canvas. */
    public readonly context: GPUCanvasContext;
    /** The resize observer for the canvas. */
    private readonly resizeObserver!: ResizeObserver;
    /** The input state from keyboard events. */
    public readonly inputState: InputManager.InputState;
    /** The sprite tile map. */
    private tileMap!: TileMap;
    /** Provides the bind group for WebGPU. */
    private bindGroup!: GPUBindGroup;
    /** Determines if the tile buffer is dirty. */
    private tileBufferDirty: boolean = false;
    /** Specifies if the GameEngine instance is destroyed (providing a reason string). */
    private destroyed: string | false = false;
    /** The GPU buffer for uniform data. */
    private uniformBuffer!: GPUBuffer;
    /** The GPU buffer for tile data. */
    private tileBuffer!: GPUBuffer;
    /** The GPU buffer for map size data. */
    private mapSizeBuffer!: GPUBuffer;
    /** Specifies when the game started. */
    public startTime: number = performance.now();
    /** Gives the pointer that describes the memory layout. */
    public LAYOUT_PTR: Zig.Pointer;
    /** Gives the pointer to the game state. */
    private readonly GAME_STATE_PTR: Zig.Pointer;
    /** A string representing the game seed (up to 100 characters). */
    public seed!: string;
    /** Fractional pixels per tile in the internal 480x270 resolution (1:1 by default). */
    public zoom: number = 1;
    /** Provides an error object if one was passed to destroy(). */
    public destroyedError: any = null;
    /** Determines if the Canvas should force a 16:9 aspect ratio. */
    public forceAspectRatio: boolean = true;
    /** Determines the previous state of the 16:9 aspect ratio, internal use for updating the canvas styling when calling renderFrame(). */
    private forceAspectRatio_previous: boolean | null = null;

    private readonly renderPipeline: GPURenderPipeline;
    private readonly encoder = new TextEncoder();
    private readonly decoder = new TextDecoder();

    private constructor(
        canvas: HTMLCanvasElement,
        adapter: GPUAdapter,
        device: GPUDevice,
        context: GPUCanvasContext,
        engineModule: WebAssembly.WebAssemblyInstantiatedSource,
        renderPipeline: GPURenderPipeline,
    ) {
        this.canvas = canvas;
        this.adapter = adapter;
        this.device = device;
        this.context = context;
        this.engineModule = engineModule;
        this.renderPipeline = renderPipeline;
        this.exports = engineModule.instance.exports as Zig.EngineExports;
        this.memory = engineModule.instance.exports
            .memory as WebAssembly.Memory;
        this.exports.init();
        this.LAYOUT_PTR = this.exports.get_memory_layout_ptr();
        this.GAME_STATE_PTR = Number(this.getScratchView()[3]);
        this.inputState = InputManager.initInput();
    }

    /** Creates a new GameEngine, setting up WebGPU shaders and calling init() from Zig. */
    public static async create(
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
                throw Error(
                    `Element with ID "${canvas}" is not a canvas element.`,
                );
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
                        len: number,
                        category: number,
                    ) => {
                        const str = new TextDecoder().decode(
                            new Uint8Array(memory.buffer, ptr, len),
                        );
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
                    // Add other external functions here
                },
            },
        );
        const memory = engineModule.instance.exports
            .memory as WebAssembly.Memory;

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
                topology: "triangle-list",
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
            if (CONFIG.verbose)
                console.log(
                    "device-pixel-content-box not supported, falling back to content-box.",
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
        const atlasTexture = await GameEngine.loadTexture(
            device,
            SPRITE_SHEET_URL,
        );

        // Create sampler (nearest neighbor for pixel art)
        const pixelSampler = device.createSampler({
            magFilter: "nearest",
            minFilter: "nearest",
            addressModeU: "clamp-to-edge",
            addressModeV: "clamp-to-edge",
        });

        // Create uniform buffer (SceneUniforms)
        // camera: vec2f (8), viewport_size: vec2f (8), time: f32 (4), zoom: f32 (4), padding: vec2u (8)
        const uniformBuffer = device.createBuffer({
            label: "SceneUniforms",
            size: 32, // Aligned to 16 bytes
            usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
        });

        // Create map size buffer
        const mapSizeBuffer = device.createBuffer({
            label: "Map size",
            size: 8, // vec2u
            usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
        });

        // Initialize tilemap
        const tileMap: TileMap = {
            width: initialMapWidth,
            height: initialMapHeight,
            data: new Uint32Array(initialMapWidth * initialMapHeight),
        };
        engine.tileMap = tileMap;

        // Fill with test pattern
        GameEngine.generateTestTilemap(tileMap);

        // Create tile storage buffer
        const tileBuffer = device.createBuffer({
            label: "Tile data",
            size: tileMap.data.byteLength,
            usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
        });

        // Upload initial tile data
        device.queue.writeBuffer(tileBuffer, 0, tileMap.data.buffer);
        device.queue.writeBuffer(
            mapSizeBuffer,
            0,
            new Uint32Array([tileMap.width, tileMap.height]),
        );

        // Create bind group
        engine.bindGroup = device.createBindGroup({
            label: "Tilemap bind group",
            layout: pipeline.getBindGroupLayout(0),
            entries: [
                { binding: 0, resource: { buffer: uniformBuffer } },
                { binding: 1, resource: { buffer: tileBuffer } },
                { binding: 2, resource: atlasTexture.createView() },
                { binding: 3, resource: pixelSampler },
                { binding: 4, resource: { buffer: mapSizeBuffer } },
            ],
        });

        engine.uniformBuffer = uniformBuffer;
        engine.tileBuffer = tileBuffer;
        engine.mapSizeBuffer = mapSizeBuffer;
        return engine;
    }

    public destroy(reason = "unknown reason", error: any = null) {
        this.resizeObserver.disconnect();
        this.destroyed = reason;
        this.destroyedError = error;
    }

    // -----
    // GPU Textures/Tilemaps
    // -----

    private static async loadTexture(
        device: GPUDevice,
        url: string,
    ): Promise<GPUTexture> {
        const response = await fetch(url);
        const blob = await response.blob();
        const imageBitmap = await createImageBitmap(blob);

        const texture = device.createTexture({
            label: `Texture from  ${url}`,
            size: [imageBitmap.width, imageBitmap.height],
            format: "rgba8unorm",
            usage:
                GPUTextureUsage.TEXTURE_BINDING |
                GPUTextureUsage.COPY_DST |
                GPUTextureUsage.RENDER_ATTACHMENT,
        });

        device.queue.copyExternalImageToTexture(
            { source: imageBitmap },
            { texture },
            [imageBitmap.width, imageBitmap.height],
        );

        return texture;
    }

    private static generateTestTilemap(tileMap: TileMap): void {
        const { width, height, data } = tileMap;

        for (let y = 0; y < height; y++) {
            for (let x = 0; x < width; x++) {
                const idx = y * width + x;

                // Alternate between sprite 0 and 1 in a checkerboard (0=stone, 1=torch)
                let spriteId = ((x + y) % 2) as 0 | 1;
                if (spriteId == 1 && random() < 0.4) spriteId = 0; //40% of torches become stone!

                // Calculate edge flags (which neighbors are "air"/different)
                let edgeFlags = 0;

                // Check all 8 neighbors
                const neighbors = [
                    [-1, -1, EdgeFlags.TOP_LEFT],
                    [0, -1, EdgeFlags.TOP],
                    [1, -1, EdgeFlags.TOP_RIGHT],
                    [-1, 0, EdgeFlags.LEFT],
                    [1, 0, EdgeFlags.RIGHT],
                    [-1, 1, EdgeFlags.BOTTOM_LEFT],
                    [0, 1, EdgeFlags.BOTTOM],
                    [1, 1, EdgeFlags.BOTTOM_RIGHT],
                ] as const;

                for (const [dx, dy, flag] of neighbors) {
                    const nx = x + dx;
                    const ny = y + dy;

                    // Edge of map or different sprite type = edge
                    if (
                        nx < 0 ||
                        nx >= width ||
                        ny < 0 ||
                        ny >= height ||
                        (nx + ny) % 2 !== spriteId
                    ) {
                        edgeFlags |= flag;
                    }
                }

                // Random light value and variation seed
                const light = Math.floor(128 + Math.random() * 127);
                const variation = Math.floor(Math.random() * 256);
                data[idx] = this.packTileData(
                    spriteId,
                    edgeFlags,
                    light,
                    variation,
                );
            }
        }
    }

    /** Packs tile data into 32 bits of data. */
    public static packTileData(
        spriteId: number,
        edgeFlags: number,
        light: number,
        variation: number,
    ): number {
        return (
            (spriteId & 0xff) |
            ((edgeFlags & 0xff) << 8) |
            ((light & 0xff) << 16) |
            ((variation & 0xff) << 24)
        );
    }

    public setTile(
        x: number,
        y: number,
        spriteId: number,
        edgeFlags?: number,
        light?: number,
        variation?: number,
    ): void {
        if (
            x < 0 ||
            x >= this.tileMap.width ||
            y < 0 ||
            y >= this.tileMap.height
        ) {
            return;
        }

        const idx = y * this.tileMap.width + x;
        const existing = this.tileMap.data[idx];

        // Preserve existing values if not specified
        const newData = GameEngine.packTileData(
            spriteId,
            edgeFlags ?? (existing >> 8) & 0xff,
            light ?? (existing >> 16) & 0xff,
            variation ?? (existing >> 24) & 0xff,
        );

        this.tileMap.data[idx] = newData;
        this.tileBufferDirty = true;
    }

    public setTileLight(x: number, y: number, light: number): void {
        if (
            x < 0 ||
            x >= this.tileMap.width ||
            y < 0 ||
            y >= this.tileMap.height
        ) {
            return;
        }

        const idx = y * this.tileMap.width + x;
        // Clear light bits and set new value
        this.tileMap.data[idx] =
            (this.tileMap.data[idx] & 0xff00ffff) | ((light & 0xff) << 16);
        this.tileBufferDirty = true;
    }

    public getTileData(
        x: number,
        y: number,
    ): {
        spriteId: number;
        edgeFlags: number;
        light: number;
        variation: number;
    } | null {
        if (
            x < 0 ||
            x >= this.tileMap.width ||
            y < 0 ||
            y >= this.tileMap.height
        ) {
            return null;
        }

        const idx = y * this.tileMap.width + x;
        const packed = this.tileMap.data[idx];

        return {
            spriteId: packed & 0xff,
            edgeFlags: (packed >> 8) & 0xff,
            light: (packed >> 16) & 0xff,
            variation: (packed >> 24) & 0xff,
        };
    }

    /** Batch update of tile data. */
    public updateTileRegion(
        startX: number,
        startY: number,
        regionWidth: number,
        regionHeight: number,
        generator: (x: number, y: number) => number, // Returns packed tile data
    ): void {
        for (let y = startY; y < startY + regionHeight; y++) {
            for (let x = startX; x < startX + regionWidth; x++) {
                if (
                    x >= 0 &&
                    x < this.tileMap.width &&
                    y >= 0 &&
                    y < this.tileMap.height
                ) {
                    this.tileMap.data[y * this.tileMap.width + x] = generator(
                        x,
                        y,
                    );
                }
            }
        }
        this.tileBufferDirty = true;
    }

    /** Recalculate edge flags for all tiles based on current sprite IDs */
    public recalculateEdgeFlags(): void {
        const { width, height, data } = this.tileMap;

        for (let y = 0; y < height; y++) {
            for (let x = 0; x < width; x++) {
                const idx = y * width + x;
                const spriteId = data[idx] & 0xff;
                let edgeFlags = 0;

                const neighbors = [
                    [-1, -1, EdgeFlags.TOP_LEFT],
                    [0, -1, EdgeFlags.TOP],
                    [1, -1, EdgeFlags.TOP_RIGHT],
                    [-1, 0, EdgeFlags.LEFT],
                    [1, 0, EdgeFlags.RIGHT],
                    [-1, 1, EdgeFlags.BOTTOM_LEFT],
                    [0, 1, EdgeFlags.BOTTOM],
                    [1, 1, EdgeFlags.BOTTOM_RIGHT],
                ] as const;

                for (const [dx, dy, flag] of neighbors) {
                    const nx = x + dx;
                    const ny = y + dy;

                    if (nx < 0 || nx >= width || ny < 0 || ny >= height) {
                        edgeFlags |= flag; // Map edge = air
                    } else {
                        const neighborSprite = data[ny * width + nx] & 0xff;
                        if (neighborSprite !== spriteId) {
                            edgeFlags |= flag;
                        }
                    }
                }

                // Update edge flags, preserve other data
                data[idx] = (data[idx] & 0xffff00ff) | (edgeFlags << 8);
            }
        }

        this.tileBufferDirty = true;
    }

    // -----
    // Memory Management
    // -----

    /**
     * Accesses memory relative to the start of the GameState (by adding this.GAME_STATE_PTR to the offset). Obtains a TypedArray view into WASM game data.
     */
    public getGameView<T extends WasmTypeCode>(
        typeCode: T,
        offset: number = 0, // Defaults to start of GameState
        size: number,
    ): InstanceType<(typeof WasmTypeMap)[T]> {
        return new WasmTypeMap[typeCode](
            this.memory.buffer,
            this.GAME_STATE_PTR + offset,
            size,
        ) as any;
    }

    /**
     * Accesses TypedArray memory using an absolute WASM pointer.
     * Used for reading the scratch buffer or raw heap allocations.
     */
    public getRawView<T extends WasmTypeCode>(
        typeCode: T,
        ptr: number,
        size: number,
    ): InstanceType<(typeof WasmTypeMap)[T]> {
        return new WasmTypeMap[typeCode](this.memory.buffer, ptr, size) as any;
    }

    /** Internal property for a temporary access of the scratch view. Value 0 is the pointer, value 1 is the length, value 2 is the max capacity, value 3 is pointer to the GameState, and values 4-7 are custom properties (as WASM can only return 1 value, this provides 4 extra temporary "slots" to return things). */
    private _tempScratchView: BigUint64Array | null = null;
    /** Returns 8 values in the scratch buffer; (zero-indexed) value 0 is the pointer, value 1 is the length, value 2 is the max capacity, and values 3-7 are custom properties when necessary. */
    public getScratchView(): BigUint64Array {
        // Check if we need to (re)create the view
        if (
            this._tempScratchView === null ||
            this._tempScratchView.buffer !== this.memory.buffer // old view due to memory growth
        ) {
            this._tempScratchView = new BigUint64Array(
                this.memory.buffer,
                this.LAYOUT_PTR,
                8,
            );
        }
        return this._tempScratchView;
    }

    /**
     * Returns the scratch buffer's location in memory (used for passing strings, commands, and data between JS and WASM).
     */
    public getScratchPtr() {
        return Number(this.getScratchView()[0]);
    }

    /**
     * Returns the scratch buffer's current length of data (not capacity).
     */
    public getScratchLen() {
        return Number(this.getScratchView()[1]);
    }

    /**
     * Sets the scratch buffer's current length of data (not capacity).
     */
    public setScratchLen(length: number) {
        this.getScratchView()[1] = BigInt(length);
    }

    /**
     * Returns the scratch buffer's max capacity.
     */
    public getScratchCapacity() {
        return Number(this.getScratchView()[2]);
    }

    /**
     * Determines the properties of the scratch buffer (6 u64 constants from Zig converted to Number). Returns a number if ID of property is provided (0-4) and number[] of all 5 properties if not.
     */
    public getScratchProperties(
        index:
            | 0
            | 1
            | 2
            | 3
            | 4
            | 5
            | 6
            | 7
            | 8
            | 9
            | 10
            | 11
            | 12
            | 13
            | 14
            | 15
            | 16
            | 17
            | 18
            | 19,
        asType:
            | WasmTypeCode.Uint64
            | WasmTypeCode.Float64 = WasmTypeCode.Uint64,
    ): number {
        let view: BigUint64Array | Float64Array = this.getScratchView();
        if (asType == WasmTypeCode.Float64) {
            view = new Float64Array(view.buffer, view.byteOffset, view.length);
        }
        return Number(view[index - 4]);
    }

    /**
     * Reads a UTF-8 string from WASM memory. Pass in/request a custom offset by doing something like this:
     * ```ts
     * let str1 = "hello", str2 = "hi"
    // In practice, you would either do the reading or writing from Zig. You would pass the string pointers and lengths to Zig through arguments if you're reading from Zig, and return pointers/lengths with getScratchProperties or some agreed-upon format.

    let ptr1 = engine.writeStr(str1); // Write a string, setting the scratch buffer's length to 5.
    let ptr2 = engine.writeStr(str2, false); // Append after hello, don't reset!

    console.log(engine.readStr(ptr1, str1.length)); // "hello"
    console.log(engine.readStr(ptr2, str2.length)); // "hi"
    console.log(engine.readStr(ptr1, str2.length + 64)); // "hello[...59 null bytes, as Zig aligns data to 64 byte chunks with MAIN_ALIGN_BYTES...]hi"
     * ```
     */
    public readStr(
        offset: number = this.getScratchPtr(),
        len: number = this.getScratchLen(),
    ): string {
        const bytes = new Uint8Array(this.memory.buffer, offset, len);
        return this.decoder.decode(bytes);
    }

    /**
     * Writes a JavaScript string into WASM memory.
     * Returns the pointer for where the data begins. See readStr() for more details on usage.
     */
    public writeStr(
        str: string,
        resetScratchBuffer: boolean = true,
    ): number | null {
        const len = str.length;
        if (len === 0) return null;
        if (resetScratchBuffer) this.setScratchLen(0);
        const ptr = this.exports.scratch_alloc(len);
        if (ptr === 0) return null;

        const bytes = new Uint8Array(this.memory.buffer, ptr, len);
        const result = this.encoder.encodeInto(str, bytes);

        // If result.read < len, the string contained non-ASCII characters.
        if (result.read < len && CONFIG.verbose) {
            throw new RangeError(
                "String truncated with non-ASCII characters detected.",
            );
        }

        return ptr;
    }

    public async setSeed(seed: string) {
        this.seed = seed;
        await Seeding.seedToMemory(
            seed,
            this.getGameView(
                WasmTypeCode.Uint64,
                Zig.game_state_offsets.seed,
                8,
            ),
        );
    }

    // -----
    // Resize/Rendering
    // -----

    /** Updates the canvas CSS style. */
    private updateCanvasStyle() {
        if (this.forceAspectRatio === this.forceAspectRatio_previous) return;
        this.forceAspectRatio_previous = this.forceAspectRatio;
        if (this.forceAspectRatio) {
            this.canvas.style.maxWidth = "calc(100vh * (16 / 9))";
            this.canvas.style.maxHeight = "calc(100vw * (9 / 16))";
        } else {
            this.canvas.style.maxWidth = "none";
            this.canvas.style.maxHeight = "none";
        }
    }

    /** Handles resizing of canvas automatically. */
    private onResize = (entries: ResizeObserverEntry[]) => {
        const entry = entries[0];
        let w: number;
        let h: number;

        if (entry.devicePixelContentBoxSize) {
            w = entry.devicePixelContentBoxSize[0].inlineSize;
            h = entry.devicePixelContentBoxSize[0].blockSize;
        } else if (entry.contentBoxSize) {
            // Use the logical CSS size, manually apply devicePixelRatio
            const cssW = entry.contentBoxSize[0].inlineSize;
            const cssH = entry.contentBoxSize[0].blockSize;

            w = Math.round(cssW * devicePixelRatio);
            h = Math.round(cssH * devicePixelRatio);
        } else {
            // final fallback
            const cssW = entry.contentRect.width;
            const cssH = entry.contentRect.height;

            w = Math.round(cssW * devicePixelRatio);
            h = Math.round(cssH * devicePixelRatio);
        }

        // Apply new size only if it has actually changed
        if (this.canvas.width !== w || this.canvas.height !== h) {
            this.canvas.width = w;
            this.canvas.height = h;
        }
    };

    /** Renders a single frame. */
    public renderFrame(perfTime = performance.now()) {
        if (this.destroyed) {
            throw new DOMException(
                "GameEngine instance was destroyed (due to " +
                    this.destroyed +
                    ").",
                "InvalidStateError",
            );
        }

        this.updateCanvasStyle();

        // Calculate the multiplier required to map internal 480p units to physical pixels and the zoom
        const resolutionScale = this.canvas.width / INTERNAL_WIDTH;
        const effectiveZoom = this.zoom * resolutionScale;

        const cameraPos = this.getGameView(
            WasmTypeCode.Float64,
            Zig.game_state_offsets.camera_pos,
            2,
        );
        const time = (perfTime - this.startTime) / 1000.0;
        const uniformData = new Float32Array([
            cameraPos[0], // camera.x
            cameraPos[1], // camera.y
            this.canvas.width, // viewport_size.x
            this.canvas.height, // viewport_size.y
            time, // time
            effectiveZoom, // effective zoom
            0, // padding
            0, // padding
        ]);

        this.device.queue.writeBuffer(this.uniformBuffer, 0, uniformData);

        // Update tile buffer if dirty
        if (this.tileBufferDirty) {
            this.device.queue.writeBuffer(
                this.tileBuffer,
                0,
                this.tileMap.data.buffer,
            );
            this.tileBufferDirty = false;
        }

        const commandEncoder = this.device.createCommandEncoder();
        const textureView = this.context.getCurrentTexture().createView();

        const renderPass = commandEncoder.beginRenderPass({
            colorAttachments: [
                {
                    view: textureView,
                    loadOp: "clear",
                    clearValue: { r: 0.1, g: 0.1, b: 0.15, a: 1.0 },
                    storeOp: "store",
                },
            ],
        });

        renderPass.setPipeline(this.renderPipeline);
        renderPass.setBindGroup(0, this.bindGroup);
        renderPass.setViewport(
            0,
            0,
            this.canvas.width,
            this.canvas.height,
            0,
            1,
        );

        // Draw all tiles as instances
        const instanceCount = this.tileMap.width * this.tileMap.height;
        renderPass.draw(6, instanceCount);

        renderPass.end();
        this.device.queue.submit([commandEncoder.finish()]);
    }

    /** Updates the game's logic state. */
    public tick() {
        // Internally, key pressing data goes keys_pressed_mask, then keys_held_mask.
        const inputView = this.getGameView(
            WasmTypeCode.Uint32,
            Zig.game_state_offsets.keys_pressed_mask,
            2,
        );
        InputManager.updateInput(this.inputState);
        inputView[0] = this.inputState.keysPressed;
        inputView[1] = this.inputState.keysHeld;
        // console.log("Keys pressed down this frame: " + inputView[0] + "\nKeys held down: " + inputView[1]);
        this.exports.tick();
    }
}
