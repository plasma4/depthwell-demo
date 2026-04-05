"use strict";
/// <reference types="@webgpu/types" />
import * as Zig from "./enums";
import * as Seeding from "./seeding";
import * as InputManager from "./inputManager";
import * as EngineMaker from "./engineMaker";

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

/** The maximum number of WebGPU buffers necessary to render everything. This is set to 2 because it is guaranteed that only 2 backgrounds and 2 batches of tiles need to be drawn per frame. */
const MAX_WEBGPU_BUFFERS = 2;

// Note: constants where most of the game logic resides are in Zig. These are currently unused in JS.
// /* The main number (as an integer) representing the number of blocks in a chunk, number of pixels in a block, and number of subpixels in a pixel. */
// const SPAN = 16;

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
    /** The canvas where rendering is presented. */
    public readonly canvas: HTMLCanvasElement;
    /** The WebGPU adapter for the system. */
    public readonly adapter: GPUAdapter;
    /** The logical WebGPU device. */
    public readonly device: GPUDevice;
    /** The WebGPU context for the canvas. */
    public readonly context: GPUCanvasContext;
    /** The resize observer for the canvas. */
    public readonly resizeObserver!: ResizeObserver;
    /** The input state from keyboard events. */
    public readonly inputState: InputManager.InputState;
    /** Determines if visible data is new for this frame or not (allowing for `loadOp` in `GPURenderPassDescriptor` to be changed from `"clear"` to `"load"` as necessary). */
    public isVisibleDataNew: boolean = true;
    /** The width of the sprite tile map. */
    public tileMapWidth!: number;
    /** The height of the sprite tile map. */
    public tileMapHeight!: number;
    /** Specifies if the GameEngine instance is destroyed (providing a reason string for the error). Is `false` if not destroyed. */
    public destroyed: string | false = false;
    /** Provides the bind groups for WebGPU. */
    public bindGroups: GPUBindGroup[] = Array(MAX_WEBGPU_BUFFERS);
    /** Provides the bind groups for WebGPU. */
    public uniformBuffers: GPUBuffer[] = Array(MAX_WEBGPU_BUFFERS);
    /** The GPU buffers for tile data. */
    public tileBuffers: GPUBuffer[] = Array(MAX_WEBGPU_BUFFERS);
    /** The current bind group for WebGPU. */
    public bindGroup!: GPUBindGroup;
    /** The current GPU buffer for uniform data. */
    public uniformBuffer!: GPUBuffer;
    /** The current GPU buffer for tile data. */
    public tileBuffer!: GPUBuffer;
    /** Determines if the tile buffer is dirty. */
    public tileBufferDirty: boolean = false;
    /** The cached texture view for the sprite atlas. */
    public atlasTextureView!: GPUTextureView;
    /** The cached nearest-neighbor sampler. */
    public pixelSampler!: GPUSampler;
    /** Specifies when the game started. */
    public startTime: number = performance.now();
    /** Gives the pointer that describes the memory layout. */
    public LAYOUT_PTR: Zig.PointerLike;
    /** Gives the pointer to the game state. */
    public readonly GAME_STATE_PTR: Zig.PointerLike;
    /** A string representing the game seed (up to 100 characters). */
    public seed: string = "";
    /** Provides an error object if one was passed to destroy(). */
    public destroyedError: any = null;
    /** Determines the opacity of wireframes (not rendered if set to 0). */
    public wireframeOpacity: number = 0.0;
    /** Determines if the Canvas should force a 16:9 aspect ratio. */
    public forceAspectRatio: boolean = true;
    /** Determines the previous state of the 16:9 aspect ratio. Internal use for updating the canvas styling when calling renderFrame(). */
    private previousForceAspectRatio: boolean | null = null;

    /** Temporary variable to represent the number of times handleVisibleChunks() is called per render request. */
    private renderCallId: number = 0;
    /** Represents the current render pass. */
    private renderPass: GPURenderPassEncoder | null = null;
    /** Internal encoder to track the current frame's encoding. */
    private currentEncoder: GPUCommandEncoder | null = null;
    /** Internal texture view for just the current frame. */
    private currentTextureView: GPUTextureView | null = null;
    /** The depth texture for discarding. */
    public depthTexture!: GPUTexture;
    /** Internal texture view for just the depth texture. */
    private depthTextureView: GPUTextureView | null = null;

    public readonly renderPipeline: GPURenderPipeline;
    public readonly bgPipeline: GPURenderPipeline;
    public readonly encoder = new TextEncoder();
    public readonly decoder = new TextDecoder();

    /** The prefix used for logging. */
    // public LOGGING_PREFIX = location.origin + "/zig/";
    public LOGGING_PREFIX = "";

    public constructor(
        canvas: HTMLCanvasElement,
        adapter: GPUAdapter,
        device: GPUDevice,
        context: GPUCanvasContext,
        engineModule: WebAssembly.WebAssemblyInstantiatedSource,
        renderPipeline: GPURenderPipeline,
        bgPipeline: GPURenderPipeline,
    ) {
        this.canvas = canvas;
        this.adapter = adapter;
        this.device = device;
        this.context = context;
        this.engineModule = engineModule;
        this.renderPipeline = renderPipeline;
        this.bgPipeline = bgPipeline;
        this.exports = engineModule.instance.exports as Zig.EngineExports;
        this.memory = engineModule.instance.exports
            .memory as WebAssembly.Memory;
        this.LAYOUT_PTR = Number(this.exports.get_memory_layout_ptr());
        this.GAME_STATE_PTR = Number(this.getScratchView()[3]);
        this.inputState = InputManager.initInput();
    }

    /** Creates a new GameEngine instance (code in engineConfig.ts). */
    public static async create(
        canvas?: HTMLCanvasElement | string,
        options?: Zig.EngineOptions,
    ): Promise<GameEngine> {
        return await EngineMaker.create(canvas, options);
    }

    public destroy(reason = "unknown reason", error: any = null) {
        this.resizeObserver.disconnect();
        this.destroyed = reason;
        this.destroyedError = error;
    }

    // -----
    // GPU Textures/Tilemaps
    // -----

    public static async loadTexture(
        device: GPUDevice,
        url: string,
    ): Promise<GPUTexture> {
        const response = await fetch(url);
        const blob = await response.blob();
        const imageBitmap = await createImageBitmap(blob);

        const texture = device.createTexture({
            label: `Texture from  ${url}`,
            size: [imageBitmap.width, imageBitmap.height],
            format: device.features.has("canvas-rgba16float-support")
                ? "rgba16float"
                : "bgra8unorm",
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
        this.exports.prepare_visible_chunks(
            timeInterpolated,
            this.canvas.width,
            this.canvas.height,
        );
    }

    /** Function called from Zig (using the `js_handle_visible_chunks` function in `env`) that actually draws the chunks. */
    public handleVisibleChunks(opacity: number) {
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

        // Read metadata from scratch_properties, matching from prepare_visible_chunks
        const tileDataWidth = Number(this.getScratchProperty(0));
        const tileDataHeight = Number(this.getScratchProperty(1));
        const u32Count = tileDataWidth * tileDataHeight * 2;
        this.tileMapWidth = tileDataWidth;
        this.tileMapHeight = tileDataHeight;

        const wasmView = new Uint32Array(
            this.memory.buffer,
            scratchPtr,
            u32Count,
        );

        const neededBytes = u32Count * 4;
        this.recreateBufferAndBindGroup(neededBytes);
        this.updateBuffersAndBindGroup(this.renderCallId);
        this.renderPass.setPipeline(this.renderPipeline);
        this.renderPass.setBindGroup(0, this.bindGroup);

        if (this.renderCallId == 1) {
            this.renderPass.setViewport(
                0,
                0,
                this.canvas.width,
                this.canvas.height,
                0,
                1,
            );
        }

        this.setSceneData(opacity, tileDataWidth, tileDataHeight);
        this.device.queue.writeBuffer(this.tileBuffer, 0, wasmView);

        // Draw all tiles as instances. Uses a triangle-strip so vertexCount is 4 instead of 6.
        const instanceCount = tileDataWidth * tileDataHeight + 1; // 1 extra instance to draw the player
        this.renderPass.draw(4, instanceCount);
        this.isVisibleDataNew = false;
    }

    /** Configures the data in the `scene` used by WGSL. */
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

        const buffer = new ArrayBuffer(56); // allow for both f32 and u32 values to be imported to the uniform data
        const f32 = new Float32Array(buffer);
        const u32 = new Uint32Array(buffer);

        f32[0] = camX; // camera pos
        f32[1] = camY;
        f32[2] = this.canvas.width; // canvas res
        f32[3] = this.canvas.height;
        f32[4] = (performance.now() - this.startTime) % 16777216; // time for animations
        f32[5] = effectiveZoom; // zoom to scale with
        f32[6] = effectiveZoom < 0.25 ? 0 : this.wireframeOpacity; // wireframe opacity: hidden if zoom is too small
        f32[7] = opacity; // opacity all tiles/sprites when rendering
        f32[8] = playerX; // player pos
        f32[9] = playerY;

        u32[10] = tileDataWidth; // map size
        u32[11] = tileDataHeight;

        this.device.queue.writeBuffer(this.uniformBuffer, 0, f32);
    }

    /** Creates a new buffer and bind group, if none exists or `tileBuffer`'s size is greater or equal to `neededBytes`. */
    private recreateBufferAndBindGroup(neededBytes: number) {
        if (!this.tileBuffer || this.tileBuffer.size < neededBytes) {
            this.tileBuffers[this.renderCallId] = this.device.createBuffer({
                label: "Tile grid",
                size: neededBytes,
                usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
            });
            // Rebuild bind group with new buffer
            this.bindGroups[this.renderCallId] = this.device.createBindGroup({
                label: "Tilemap bind group",
                layout: this.renderPipeline.getBindGroupLayout(0),
                entries: [
                    {
                        binding: 0,
                        resource: {
                            buffer: this.uniformBuffers[this.renderCallId],
                        },
                    },
                    {
                        binding: 1,
                        resource: {
                            buffer: this.tileBuffers[this.renderCallId],
                        },
                    },
                    { binding: 2, resource: this.atlasTextureView },
                    { binding: 3, resource: this.pixelSampler },
                ],
            });
        }
    }

    /** Updates the current `tileBuffer`, `uniformBuffer`, and `bindGroup`. */
    private updateBuffersAndBindGroup(elementId: number) {
        this.tileBuffer = this.tileBuffers[elementId];
        this.uniformBuffer = this.uniformBuffers[elementId];
        this.bindGroup = this.bindGroups[elementId];
    }

    // -----
    // Memory Management
    // -----

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
                24,
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
    public getScratchProperty(
        index: number,
        asType:
            | WasmTypeCode.Uint64
            | WasmTypeCode.Float64 = WasmTypeCode.Uint64,
    ): number {
        if (
            this._tempScratchView === null ||
            this._tempScratchView.buffer !== this.memory.buffer // old view due to memory growth
        ) {
            this._tempScratchView = new BigUint64Array(
                this.memory.buffer,
                this.LAYOUT_PTR,
                24,
            );
        }

        let view: BigUint64Array | Float64Array = this._tempScratchView;
        if (asType == WasmTypeCode.Float64) {
            view = new Float64Array(view.buffer, view.byteOffset, view.length);
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
        const ptr = this.exports.scratch_alloc(len);
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
    }

    // -----
    // Resize/Rendering
    // -----

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
            if (this.depthTexture) this.depthTexture.destroy();
            this.depthTexture = this.device.createTexture({
                size: [w, h],
                format: "depth24plus",
                usage: GPUTextureUsage.RENDER_ATTACHMENT,
            });
        }
    };

    /** Starts the render logic for a single frame. */
    public renderFrame(timeInterpolated: number, currentTime: number) {
        this.renderCallId = 0;
        if (this.destroyed !== false) return;

        this.updateCanvasStyle(); // in case this was overwritten

        // Initialize the encoder and view for this specific frame
        this.currentEncoder = this.device.createCommandEncoder();
        this.currentTextureView = this.context.getCurrentTexture().createView();
        this.depthTextureView = this.depthTexture.createView(); // Create view for this frame

        // Clear if this is the FIRST time data is being rendered this frame. Otherwise, keep.
        // const loadOp: GPULoadOp = this.isVisibleDataNew ? "clear" : "load";
        const loadOp: GPULoadOp = "clear";

        const renderPass = this.currentEncoder.beginRenderPass({
            colorAttachments: [
                {
                    view: this.currentTextureView,
                    loadOp: loadOp,
                    clearValue: { r: 0.0, g: 0.0, b: 0.0, a: 1.0 },
                    storeOp: "store",
                },
            ],
            depthStencilAttachment: {
                view: this.depthTextureView!,
                depthClearValue: 1.0,
                depthLoadOp: "clear",
                depthStoreOp: "store",
            },
        });
        this.renderPass = renderPass;

        // Trigger Zig logic, which will call handleVisibleChunks() (potentially multiple times)
        this.uploadVisibleChunks(timeInterpolated);

        // Don't have background on depth transition, which draws a second batch of tiles
        if (this.renderCallId == 0) {
            // Draw background (same bind group as chunk drawing)
            this.updateBuffersAndBindGroup(this.renderCallId);
            this.renderPass.setPipeline(this.bgPipeline);
            this.renderPass.setBindGroup(0, this.bindGroup);
            this.renderPass.draw(3); // Draws the large background triangle (not a quad, neat little hack!)
        }
        this.renderPass.end();

        // Finalize the frame
        this.device.queue.submit([this.currentEncoder.finish()]);

        // Clean up the references for the next frame
        this.currentEncoder = null;
        this.currentTextureView = null;
    }

    /** Updates the game's logic state. */
    public tick(logicSpeed: number) {
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
        this.exports.tick(logicSpeed);
    }
}
