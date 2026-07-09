"use strict";
/// <reference types="@webgpu/types" />
import * as Zig from "./enums";
import * as Seeding from "./seeding";
import * as InputManager from "./inputManager";
import * as EngineMaker from "./engineMaker";
import { SaveManager } from "./saveManager";

/** Typed array types mapped to integers. */
export enum WasmTypeCode {
    Uint8 = 8,
    Uint16 = 16,
    Uint32 = 32,
    Uint64 = 64,

    Int8 = -8,
    Int16 = -16,
    Int32 = -32,
    Int64 = -64,

    Uint8Clamped = 1,
    Float32 = 2,
    Float64 = 4,
}

globalThis.WasmTypeCode = WasmTypeCode;

/** Typed array integer identifiers from `WasmTypeCode` mapped back into typed arrays. */
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

/**
 * The maximum number of WebGPU buffers necessary to render everything.
 * This is set to 4 because it is guaranteed that only 2 backgrounds and 2 batches of tiles need to be drawn per frame.
 */
export const MAX_DRAW_CALLS = 4;

// Note: constants where most of the game logic resides are in Zig. These are currently unused in JS.
// /* The main number (as an integer) representing the number of blocks in a chunk, number of pixels in a block, and number of subpixels in a pixel. */
// const CHUNK_SIZE = 16;

// /** The logical internal width (scaled with WebGPU). */
// const INTERNAL_WIDTH = 480;
// /** The logical internal height (scaled with WebGPU). */
// const INTERNAL_HEIGHT = 270;

export class GameEngine {
    /** The engine module automatically generated from Emscripten. */
    public readonly engineModule: WebAssembly.WebAssemblyInstantiatedSource;
    /** The exported functions from the engineModule. */
    public readonly exports: Zig.EngineExports;
    /** The memory from the engineModule. */
    public readonly memory: WebAssembly.Memory;
    /** Gives the pointer that describes the memory layout. */
    public LAYOUT_PTR: Zig.PointerLike;
    /** Gives the pointer to the game state. */
    public readonly GAME_STATE_PTR: Zig.PointerLike;
    /** Save manager instance that handles budgeting logic, OPFS, and tab lock. */
    public saveManager!: SaveManager;

    /** The mouse type that the canvas element is. */
    public mouseType!: number;
    /** The canvas where rendering is presented. */
    public readonly canvas: HTMLCanvasElement;
    /** The WebGPU adapter for the system. */
    public readonly adapter: GPUAdapter;
    /** The logical WebGPU device. */
    public readonly device: GPUDevice;
    /** The WebGPU context for the canvas. */
    public readonly context: GPUCanvasContext;

    /** The array of bind groups for WebGPU. */
    public bindGroups: GPUBindGroup[] = Array(MAX_DRAW_CALLS);
    /** The current GPU buffer for uniform data. */
    public uniformBuffer!: GPUBuffer;
    /** The array of tile buffers for WebGPU. */
    public tileBuffers: GPUBuffer[] = Array(MAX_DRAW_CALLS);
    /** The array of entity buffers for WebGPU. There is only one buffer. */
    public entityBuffer!: GPUBuffer;
    /** Determines if the tile buffer is dirty. */
    public tileBufferDirty: boolean = false;
    /** The cached texture view for the sprite atlas. */
    public atlasTextureView!: GPUTextureView;
    /** The cached texture view for item masks of the sprite atlas. */
    public atlasTextureMaskView!: GPUTextureView;
    /** The cached nearest-neighbor sampler. */
    public pixelSampler!: GPUSampler;

    /** WGSL pipeline for tiles. */
    public readonly tilePipeline: GPURenderPipeline;
    /** WGSL pipeline for backgrounds. */
    public readonly bgPipeline: GPURenderPipeline;
    /** WGSL pipeline for entities. */
    public readonly entityPipeline: GPURenderPipeline;

    /** Represents the current render pass. */
    private renderPass: GPURenderPassEncoder | null = null;
    /** Internal encoder to track the current frame's encoding. */
    private currentEncoder: GPUCommandEncoder | null = null;
    /** Internal texture view for just the current frame. */
    private currentTextureView: GPUTextureView | null = null;
    /** Temporary variable to represent the number of times handleVisibleChunks() is called per render request. */
    private renderCallId: number = 0;

    private sceneDataBuffer = new ArrayBuffer(256); // allow for both f32 and u32 values to be imported to the uniform data
    private sceneDataF32 = new Float32Array(this.sceneDataBuffer);
    private sceneDataU32 = new Uint32Array(this.sceneDataBuffer);

    /** The input state from keyboard events. */
    public readonly inputState: InputManager.InputState;
    /** The resize observer for the canvas. */
    public readonly resizeObserver!: ResizeObserver;
    /** Determines if the Canvas should force a 16:9 aspect ratio. */
    public forceAspectRatio: boolean = true;
    /** Determines the previous state of the 16:9 aspect ratio. Internal use for updating the canvas styling when calling renderFrame(). */
    private previousForceAspectRatio: boolean | null = null;

    /** The width of the sprite tile map. */
    public tileMapWidth!: number;
    /** The height of the sprite tile map. */
    public tileMapHeight!: number;
    /** The last time `prepare_visible_data` was called. */
    public last_upload_visible_chunks_time: number = 0;
    /** Represents how long it took for `prepare_visible_data` to execute, including JS-side `handleVisibleChunks` logic. */
    public prepare_visible_data_time: number = 0;
    /** Determines if visible data is new for this frame or not (allowing for `loadOp` in `GPURenderPassDescriptor` to be changed from `"clear"` to `"load"` as necessary). */
    public isVisibleDataNew: boolean = true;
    /** Determines the opacity of wireframes (not rendered if set to 0). */
    public wireframeOpacity: number = 0.0;

    /** Specifies when the game started. */
    public startTime: number = performance.now();
    /** A random integer between 0-120000 that gets added to `startTime` for animation. */
    public startDelta!: number;
    /** A string representing the game seed (up to 100 characters). */
    public seed: string = "";

    /**
     * Specifies if the `GameEngine` instance has been destroyed (providing a reason string for the error).
     * Is false if not destroyed. Destroyed engines are unusable.
     */
    public destroyed: string | false = false;
    /** Provides an error object if one was passed to destroy(). */
    public destroyedError: any = null;

    public readonly encoder = new TextEncoder();
    public readonly decoder = new TextDecoder();

    /** Determines whether the display uses the P3 color space. */
    public isP3: boolean = false;
    /** Determines whether 8-bit canvas textures are being used. */
    public is8Bit: boolean = false;
    /** Media query to automatically update `isP3`. */
    public gamutMediaQuery: MediaQueryList | null = null;

    /** The prefix used for logging. */
    // public LOGGING_PREFIX = location.origin + "/zig/";
    public LOGGING_PREFIX = "";

    /** The Web Audio API context for sound effects. */
    private audioCtx: AudioContext | null = null;
    /** Cached sound effect audio buffers. */
    private readonly audioBuffers = new Map<number, AudioBuffer>();
    /** Outstanding loading promises for sound effects. */
    private readonly audioLoading = new Map<number, Promise<AudioBuffer>>();

    public constructor(
        canvas: HTMLCanvasElement,
        adapter: GPUAdapter,
        device: GPUDevice,
        context: GPUCanvasContext,
        engineModule: WebAssembly.WebAssemblyInstantiatedSource,
        renderPipeline: GPURenderPipeline,
        bgPipeline: GPURenderPipeline,
        entityPipeline: GPURenderPipeline,
    ) {
        this.canvas = canvas;
        this.adapter = adapter;
        this.device = device;
        this.context = context;
        this.engineModule = engineModule;
        this.tilePipeline = renderPipeline;
        this.bgPipeline = bgPipeline;
        this.entityPipeline = entityPipeline;
        this.exports = engineModule.instance.exports as Zig.EngineExports;
        this.memory = engineModule.instance.exports
            .memory as WebAssembly.Memory;
        this.LAYOUT_PTR = Number(this.exports.getMemoryLayoutPtr());
        this.GAME_STATE_PTR = Number(this.getScratchView()[3]);
        this.inputState = InputManager.initInput();
    }

    /** Creates a new `GameEngine` instance (code in engineConfig.ts). */
    public static async create(
        canvas?: HTMLCanvasElement | string,
        options?: Zig.EngineOptions,
    ): Promise<GameEngine> {
        return await EngineMaker.create(canvas, options);
    }

    public async start() {
        await this.setSeed(Seeding.makeSeed(100));
        this.exports.init();
    }

    public destroy(reason = "unknown reason", error: any = null) {
        this.resizeObserver.disconnect();
        this.destroyed = reason;
        this.destroyedError = error;
    }

    /*
        ----
        GPU Textures/Tilemaps
        ----
    */

    /** Loads the image URL to the WGSL device as a texture. */
    public static async loadTexture(
        device: GPUDevice,
        url: string,
        format?: GPUTextureFormat, // Add optional format argument
    ): Promise<GPUTexture> {
        const response = await fetch(url);
        const blob = await response.blob();
        const imageBitmap = await createImageBitmap(blob);

        // Fallback to canvas support defaults if no format is provided
        const targetFormat =
            format ||
            (device.features.has("canvas-rgba16float-support")
                ? "rgba16float"
                : "bgra8unorm");

        const texture = device.createTexture({
            label: `Texture from ${url}`,
            size: [imageBitmap.width, imageBitmap.height],
            format: targetFormat,
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

    /** Processes all chunks from Zig and uploads them to WGSL. */
    public uploadVisibleChunks(timeInterpolated: number = 1.0): void {
        const start_time = performance.now();
        this.exports.prepareVisibleData(
            timeInterpolated,
            start_time - this.last_upload_visible_chunks_time,
            this.canvas.width,
            this.canvas.height,
        );
        this.last_upload_visible_chunks_time = start_time;
        this.prepare_visible_data_time = performance.now() - start_time;
    }

    /** Function called from Zig (using the `js_handle_visible_chunks` function in `env`) that actually draws the chunks. */
    public handleVisibleChunks(opacity: number, wireframeOpacity: number) {
        this.wireframeOpacity = wireframeOpacity;
        // Ensure we have an active encoder from renderFrame to satisfy TS
        if (
            !this.currentEncoder ||
            !this.currentTextureView ||
            !this.renderPass
        )
            return;

        const scratchPtr = this.getScratchPtr();
        const scratchLen = this.getScratchLen();
        if (scratchLen === 0) return;

        // Read metadata from scratch_properties, matching from prepare_visible_data
        const tileDataWidth = Number(this.getScratchProperty(0));
        const tileDataHeight = Number(this.getScratchProperty(1));
        // 4 u32 words per tile (128-bit Block; see zig/memory.zig)
        const u32Count = tileDataWidth * tileDataHeight * 4;
        this.tileMapWidth = tileDataWidth;
        this.tileMapHeight = tileDataHeight;

        const wasmView = new Uint32Array(
            this.memory.buffer,
            scratchPtr,
            u32Count,
        );

        this.recreateBufferAndBindGroup(u32Count * 4);
        this.renderPass.setPipeline(this.tilePipeline);
        this.renderPass.setBindGroup(0, this.bindGroups[this.renderCallId], [
            this.renderCallId * 256,
        ]);

        this.renderPass.setViewport(
            0,
            0,
            this.canvas.width,
            this.canvas.height,
            0,
            1,
        );

        this.setSceneData(opacity, tileDataWidth, tileDataHeight);
        this.device.queue.writeBuffer(
            this.tileBuffers[this.renderCallId],
            0, // no offset
            wasmView,
        );

        // Draw all tiles as instances. Draws tiles as quads so we have vertexCount as 6.
        // The player is no longer an extra tile instance; it renders through the entity pipeline.
        const instanceCount = tileDataWidth * tileDataHeight;
        this.renderPass.draw(6, instanceCount);
        this.renderCallId++;
    }

    /** Function called from Zig (using the `js_handle_visible_entities` function in `env`) that renders entities. */
    public handleVisibleEntities() {
        // setting color space flags not needed, piggybacking off of previous calls for color space
        this.renderCallId = 0;
        const scratchPtr = this.getScratchPtr();
        const entityBytes = this.getScratchProperty(0) * 48; // can't trust length as it's a multiple of 64
        if (entityBytes === 0 || !this.renderPass) return;

        if (this.entityBuffer.size < entityBytes) {
            this.entityBuffer = this.device.createBuffer({
                label: "Entities",
                size: entityBytes,
                usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
            });
            this.recreateBufferAndBindGroup(0);
        }

        const wasmView = new Uint8Array(
            this.memory.buffer,
            scratchPtr,
            entityBytes,
        );
        this.device.queue.writeBuffer(this.entityBuffer, 0, wasmView);

        this.renderPass!.setPipeline(this.entityPipeline);
        this.renderPass!.setBindGroup(0, this.bindGroups[0], [0]);
        this.renderPass!.draw(8, entityBytes / 48); // entity size is 48 bytes a piece
    }

    public setMouseType(type: number) {
        if (type == 0) {
            if (this.mouseType != 0) {
                (this.canvas.style.cursor as any) = null;
            }
        } else if (type == 1 && this.mouseType != 1) {
            if (this.mouseType != 1) {
                this.canvas.style.cursor = "pointer";
            }
        } else if (type == 2) {
            if (this.mouseType != 2) {
                this.canvas.style.cursor = "grab";
            }
        } else if (type == 3) {
            if (this.mouseType != 3) {
                this.canvas.style.cursor = "grabbing";
            }
        }
        this.mouseType = type;
    }

    /** Configures the data in the `SceneUniforms` scene used by WGSL. */
    private setSceneData(
        opacity: number,
        tileDataWidth: number,
        tileDataHeight: number,
    ) {
        // Read calculated values directly from Zig.
        const camX = this.getScratchProperty(2, WasmTypeCode.Float64);
        const camY = this.getScratchProperty(3, WasmTypeCode.Float64);
        const effectiveZoom = this.getScratchProperty(4, WasmTypeCode.Float64);
        const playerX = this.getScratchProperty(5, WasmTypeCode.Float64);
        const playerY = this.getScratchProperty(6, WasmTypeCode.Float64);
        const gridOriginX = this.getScratchProperty(7, WasmTypeCode.Float64);
        const gridOriginY = this.getScratchProperty(8, WasmTypeCode.Float64);
        const absCamX = this.getScratchProperty(9, WasmTypeCode.Float64);
        const absCamY = this.getScratchProperty(10, WasmTypeCode.Float64);

        this.sceneDataF32[0] = camX; // camera pos
        this.sceneDataF32[1] = camY;
        this.sceneDataF32[2] = this.canvas.width; // canvas res
        this.sceneDataF32[3] = this.canvas.height;

        // Some cycling logic for animations: 32-bit floating point can become imprecise otherwise
        // const cycleLength = 120000;
        // const elapsed = performance.now() - this.startTime + this.startDelta;
        // const cyclePos = elapsed % (cycleLength * 2);

        // let shaderTime;
        // if (cyclePos < cycleLength) {
        //     // Going forward
        //     shaderTime = cyclePos / 1000.0;
        // } else {
        //     // Going backward (smoothly reverses "wind" direction)
        //     shaderTime = (cycleLength - (cyclePos - cycleLength)) / 1000.0;
        // }

        this.sceneDataF32[4] =
            ((performance.now() - this.startTime + this.startDelta) %
                (3600 * 1000)) /
            1000; // time value for animating (cycles every hour)

        this.sceneDataF32[5] = effectiveZoom; // zoom to scale with
        this.sceneDataF32[6] = effectiveZoom < 0.25 ? 0 : this.wireframeOpacity; // wireframe opacity: hidden if zoom is too small
        this.sceneDataF32[7] = opacity; // opacity all tiles/sprites when rendering
        this.sceneDataF32[8] = playerX; // player pos
        this.sceneDataF32[9] = playerY;

        this.sceneDataU32[10] = tileDataWidth; // map size
        this.sceneDataU32[11] = tileDataHeight;
        this.sceneDataU32[12] = this.isP3 ? 1 : 0; // color space properties
        this.sceneDataU32[13] = this.is8Bit ? 1 : 0; // (unused currently)

        // this.sceneDataU32[14] = 0;
        // this.sceneDataU32[15] = 0;

        this.sceneDataF32[16] = gridOriginX; // grid origin x (water, modulo 256 chunks)
        this.sceneDataF32[17] = gridOriginY; // grid origin y (water, modulo 256 chunks)
        this.sceneDataF32[18] = absCamX; // grid origin z (absolute camera x, modulo BG_WRAP_CHUNKS)
        this.sceneDataF32[19] = absCamY; // grid origin w (absolute camera y, modulo BG_WRAP_CHUNKS)

        this.device.queue.writeBuffer(
            this.uniformBuffer,
            this.renderCallId * 256,
            this.sceneDataF32,
        );
    }

    /**
     * Creates a new buffer and bind group, if none exists or `tileBuffer`'s size is greater or equal to `neededBytes`.
     * Forces re-creation of bind groups (ignoring tile buffers) if `neededBytes` is 0.
     */
    private recreateBufferAndBindGroup(neededBytes: number) {
        const id = this.renderCallId;
        if (
            neededBytes === 0 ||
            !this.tileBuffers[id] ||
            this.tileBuffers[id]!.size < neededBytes
        ) {
            this.tileBuffers[id] = this.device.createBuffer({
                label: `Tile grid slot ${id}`,
                size: Math.max(neededBytes, 256 * MAX_DRAW_CALLS),
                usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
            });

            // Rebuild the bind group because the tileBuffer reference changed
            this.bindGroups[id] = this.device.createBindGroup({
                label: `Bind group slot ${id}`,
                layout: this.tilePipeline.getBindGroupLayout(0),
                entries: [
                    {
                        binding: 0,
                        resource: {
                            buffer: this.uniformBuffer,
                            offset: 0, // Base offset is 0, 256 byte multiple needed for bind groups
                            size: 256,
                        },
                    },
                    {
                        binding: 1,
                        resource: {
                            buffer: this.tileBuffers[id]!,
                        },
                    },
                    { binding: 2, resource: this.atlasTextureView },
                    { binding: 3, resource: this.atlasTextureMaskView },
                    { binding: 4, resource: this.pixelSampler },
                    {
                        binding: 5,
                        resource: {
                            buffer: this.entityBuffer,
                        },
                    },
                ],
            });
        }
    }

    /*
        ----
        SFX
        ----
    */

    /**
     * Resolves and caches the `AudioBuffer` for a given sound effect ID.
     */
    private async getAudioBuffer(id: number): Promise<AudioBuffer> {
        if (this.audioLoading.has(id)) {
            return this.audioLoading.get(id)!;
        }

        // Lazy initialize context safely
        if (!this.audioCtx) {
            this.audioCtx = new (
                window.AudioContext || (window as any).webkitAudioContext
            )();
        }
        const ctx = this.audioCtx;

        const loadPromise = (async () => {
            try {
                const response = await fetch(
                    [
                        ``,
                        `assets/mining1.mp3`,
                        `assets/mining2.mp3`,
                        `assets/mining3.mp3`,
                        `assets/grass1.mp3`,
                        `assets/grass2.mp3`,
                        `assets/place.mp3`,
                        `assets/furnace.mp3`,
                        `assets/unmineable.mp3`,
                    ][id],
                );

                if (!response.ok) {
                    // standard error handling
                    throw new Error(`HTTP error! status: ${response.status}`);
                }

                const arrayBuffer = await response.arrayBuffer();
                const audioBuffer = await ctx.decodeAudioData(arrayBuffer);

                this.audioBuffers.set(id, audioBuffer);
                return audioBuffer;
            } catch (error) {
                // cleanup!
                this.audioLoading.delete(id);
                throw error;
            } finally {
                this.audioLoading.delete(id);
            }
        })();

        this.audioLoading.set(id, loadPromise);
        return loadPromise;
    }

    /** Plays a cached audio buffer immediately. */
    private playAudioBuffer(
        buffer: AudioBuffer,
        volume: number,
        pitch: number,
    ): void {
        const ctx = this.audioCtx!;
        const source = ctx.createBufferSource();
        source.buffer = buffer;
        const gainNode = ctx.createGain();

        gainNode.gain.setValueAtTime(volume, ctx.currentTime);
        source.playbackRate.setValueAtTime(pitch, ctx.currentTime);

        source.connect(gainNode);
        gainNode.connect(ctx.destination);
        source.start(0);
    }

    /** Plays a sound effect with pitch and volume variation. */
    public playSound(id: number, volume: number, pitch: number): void {
        if (this.audioCtx && this.audioCtx.state === "suspended") {
            this.audioCtx.resume();
        }

        // The sound is cached! Play directly.
        const cachedBuffer = this.audioBuffers.get(id);
        if (cachedBuffer) {
            this.playAudioBuffer(cachedBuffer, volume, pitch);
            return;
        }

        // Load asynchronously on first use
        this.getAudioBuffer(id)
            .then((buffer) => {
                this.playAudioBuffer(buffer, volume, pitch);
            })
            .catch((err) => {
                console.warn(`Could not play sound ${id}:`, err);
            });
    }

    /*
        ----
        Memory Management
        ----
    */

    /** Returns the number of MB (fractional) that the memory's buffer is for WASM. */
    public getWASMMemoryMB() {
        return this.memory.buffer.byteLength / 1024 / 1024;
    }

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

    /** Internal property for a temporary access of the scratch view (unsigned ints). Value 0 is the pointer, value 1 is the length, value 2 is the max capacity, value 3 is pointer to the GameState, and values 4-7 are custom properties (as WASM can only return 1 value, this provides 4 extra temporary "slots" to return things). */
    private _tempScratchViewU64: BigUint64Array | null = null;
    /** Internal property for a temporary access of the scratch view (floats). Value 0 is the pointer, value 1 is the length, value 2 is the max capacity, value 3 is pointer to the GameState, and values 4-7 are custom properties (as WASM can only return 1 value, this provides 4 extra temporary "slots" to return things). */
    private _tempScratchViewF64: Float64Array | null = null;
    /** Returns 8 values in the scratch buffer; (zero-indexed) value 0 is the pointer, value 1 is the length, value 2 is the max capacity, and values 3-7 are custom properties when necessary. */
    public getScratchView(): BigUint64Array {
        // Check if we need to (re)create the view
        if (
            this._tempScratchViewU64 === null ||
            this._tempScratchViewU64.buffer !== this.memory.buffer // old view due to memory growth
        ) {
            this._tempScratchViewU64 = new BigUint64Array(
                this.memory.buffer,
                this.LAYOUT_PTR,
                24,
            );
        }
        return this._tempScratchViewU64;
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
    public getScratchProperty(
        index: number,
        asType:
            | WasmTypeCode.Uint64
            | WasmTypeCode.Float64 = WasmTypeCode.Uint64,
    ): number {
        if (
            this._tempScratchViewU64 === null ||
            this._tempScratchViewU64.buffer !== this.memory.buffer // old view due to memory growth
        ) {
            this._tempScratchViewU64 = new BigUint64Array(
                this.memory.buffer,
                this.LAYOUT_PTR,
                24,
            );
        }

        let view: BigUint64Array | Float64Array = this._tempScratchViewU64;
        if (asType == WasmTypeCode.Float64) {
            if (
                this._tempScratchViewF64 === null ||
                this._tempScratchViewF64.buffer !== this.memory.buffer // old view due to memory growth
            ) {
                this._tempScratchViewF64 = new Float64Array(
                    view.buffer,
                    view.byteOffset,
                    view.length,
                );
            }
            view = this._tempScratchViewF64;
        }
        return Number(view[index + 4]);
    }

    /**
     * Reads a UTF-8 string from WASM memory. Pass in/request a custom offset by doing something like this:
     * ```ts
        let str1 = "hello", str2 = "hi"
        // In practice, you would either do the reading or writing from Zig. You would pass the string pointers and lengths to Zig through arguments if you're reading from Zig, and return pointers/lengths with getScratchProperty or some agreed-upon format.

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
        const ptr = this.exports.scratchAlloc(len);
        if (ptr === 0n) return null;

        const bytes = new Uint8Array(this.memory.buffer, Number(ptr), len);
        const result = this.encoder.encodeInto(str, bytes);

        // If result.read < len, the string contained non-ASCII characters.
        if (result.read < len) {
            throw new RangeError(
                "String truncated with non-ASCII characters detected.",
            );
        }

        return Number(ptr);
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

        // use a random seed mixing value here: mixSeed is ONLY dependent on memory.game.seed being valid
        this.startDelta = Number(this.exports.mixSeed(60n) % 120000n);
    }

    /*
        ----
        Resizing/Rendering
        ----
    */

    /** Updates the canvas CSS style. */
    public updateCanvasStyle() {
        if (this.forceAspectRatio === this.previousForceAspectRatio) return;
        this.previousForceAspectRatio = this.forceAspectRatio;
        if (this.forceAspectRatio) {
            this.canvas.style.maxWidth = `calc(100vh*${16 / 9})`;
            this.canvas.style.maxHeight = `calc(100vw*${9 / 16})`;
        } else {
            this.canvas.style.maxWidth = "none";
            this.canvas.style.maxHeight = "none";
        }
    }

    /** Handles resizing of canvas automatically. */
    public onResize = (entries: ResizeObserverEntry[]) => {
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

    /** Starts the render logic for a single frame. */
    public renderFrame(timeInterpolated: number, currentTime: number) {
        this.renderCallId = 0; // set to 0 here, as it would otherwise require a (probably non-existent) bind group
        if (this.destroyed !== false) return;

        this.updateCanvasStyle(); // in case this was overwritten

        // Initialize the encoder and view for this specific frame
        this.currentEncoder = this.device.createCommandEncoder();
        this.currentTextureView = this.context.getCurrentTexture().createView();

        const renderPass = this.currentEncoder.beginRenderPass({
            colorAttachments: [
                {
                    view: this.currentTextureView,
                    loadOp: "clear",
                    clearValue: { r: 0.0, g: 0.0, b: 0.0, a: 1.0 },
                    storeOp: "store",
                },
            ],
        });
        this.renderPass = renderPass;

        // Draw background (same bind group as chunk drawing)
        this.recreateBufferAndBindGroup(256 * MAX_DRAW_CALLS); // start off with a minimum byte size
        this.sceneDataF32[7] = 1.0; // set opacity of BG to 1.0
        this.sceneDataU32[12] = this.isP3 ? 1 : 0; // color space properties
        this.sceneDataU32[13] = this.is8Bit ? 1 : 0;

        this.device.queue.writeBuffer(
            this.uniformBuffer,
            this.renderCallId * 256,
            this.sceneDataF32,
        );

        this.renderPass.setPipeline(this.bgPipeline);
        this.renderPass.setBindGroup(0, this.bindGroups[this.renderCallId], [
            this.renderCallId++ * 256, // Critically, we increment here!
        ]);
        this.renderPass.draw(3); // Draws the background triangle (not a quad, neat little hack!)

        // Trigger Zig logic, which will call handleVisibleChunks() (potentially multiple times)
        this.uploadVisibleChunks(timeInterpolated);

        this.renderPass.end();

        // Finalize the frame
        this.device.queue.submit([this.currentEncoder.finish()]);

        // Clean up the references for the next frame
        this.currentEncoder = null;
        this.currentTextureView = null;
    }

    /** Updates the game's logic state. */
    public tick(logicSpeed: number, iterations: number) {
        // Internally, key pressing data goes `keys_pressed_mask`, then `keys_held_mask`.
        const inputView = this.getGameView(
            WasmTypeCode.Uint32,
            Zig.game_state_offsets.keys_pressed_mask,
            2,
        );
        InputManager.updateInput(this.inputState);
        inputView[0] = this.inputState.keysPressed;
        inputView[1] = this.inputState.keysHeld;
        // console.log("Keys pressed down this frame: " + inputView[0] + "\nKeys held down: " + inputView[1]);
        this.exports.tick(logicSpeed, iterations);
    }
}
