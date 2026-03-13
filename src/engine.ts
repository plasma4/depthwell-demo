"use strict";
/// <reference types="@webgpu/types" />
import * as Zig from "./enums";
import * as Seeding from "./seeding";
import * as InputManager from "./inputManager";
import * as EngineMaker from "./engineConfig";

const SIDE = 16;

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

/** The logical internal width (scaled with WebGPU). */
const INTERNAL_WIDTH = 480;
/** The logical internal height (scaled with WebGPU). */
const INTERNAL_HEIGHT = 270;

interface TileMap {
    width: number;
    height: number;
    /** Packed tile data. */
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
    public readonly resizeObserver!: ResizeObserver;
    /** The input state from keyboard events. */
    public readonly inputState: InputManager.InputState;
    /** The sprite tile map. */
    public tileMap!: TileMap;
    /** Provides the bind group for WebGPU. */
    public bindGroup!: GPUBindGroup;
    /** Determines if the tile buffer is dirty. */
    public tileBufferDirty: boolean = false;
    /** Specifies if the GameEngine instance is destroyed (providing a reason string). */
    public destroyed: string | false = false;
    /** The GPU buffer for uniform data. */
    public uniformBuffer!: GPUBuffer;
    /** The GPU buffer for tile data. */
    public tileBuffer!: GPUBuffer;
    /** The GPU buffer for map size data. */
    public mapSizeBuffer!: GPUBuffer;
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

    public readonly renderPipeline: GPURenderPipeline;
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
        this.LAYOUT_PTR = Number(this.exports.get_memory_layout_ptr());
        this.GAME_STATE_PTR = Number(this.getScratchView()[3]);
        this.inputState = InputManager.initInput();
    }

    /** Creates a new GameEngine, setting up WebGPU shaders and calling init() from Zig. */
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

    /** Processes all chunks from Zig and uploads them to WGSL. */
    public uploadVisibleChunks(): void {
        this.exports.prepare_visible_chunks();

        const scratchPtr = this.getScratchPtr();
        const scratchLen = this.getScratchLen();
        if (scratchLen === 0) return;

        // Access the shared memory layout directly
        const viewU64 = this.getScratchView();
        const viewF64 = new Float64Array(
            viewU64.buffer,
            viewU64.byteOffset,
            viewU64.length,
        );

        // Read metadata from scratch_properties, matching from prepare_visible_chunks
        const widthBlocks = Number(viewU64[0 + 4]);
        const heightBlocks = Number(viewU64[1 + 4]);

        const u32Count = widthBlocks * heightBlocks * 2;
        const wasmView = new Uint32Array(
            this.memory.buffer,
            scratchPtr,
            u32Count,
        );

        const neededBytes = u32Count * 4;
        if (!this.tileBuffer || this.tileBuffer.size < neededBytes) {
            if (this.tileBuffer) this.tileBuffer.destroy();
            this.tileBuffer = this.device.createBuffer({
                label: "Tile grid",
                size: neededBytes,
                usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
            });
            // Rebuild bind group with new buffer
            this.bindGroup = this.device.createBindGroup({
                label: "Tilemap bind group",
                layout: this.renderPipeline.getBindGroupLayout(0),
                entries: [
                    { binding: 0, resource: { buffer: this.uniformBuffer } },
                    { binding: 1, resource: { buffer: this.tileBuffer } },
                    { binding: 2, resource: this.atlasTextureView },
                    { binding: 3, resource: this.pixelSampler },
                    { binding: 4, resource: { buffer: this.mapSizeBuffer } },
                ],
            });
        }

        this.device.queue.writeBuffer(this.tileBuffer, 0, wasmView);
        this.device.queue.writeBuffer(
            this.mapSizeBuffer,
            0,
            new Uint32Array([widthBlocks, heightBlocks, 0, 0]),
        );
        this.tileMap.width = widthBlocks;
        this.tileMap.height = heightBlocks;
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
        if (ptr === 0) return null;

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
        }
    };

    public renderFrame(timeInterpolated: number, currentTime: number) {
        if (this.destroyed) return;

        this.updateCanvasStyle();
        this.uploadVisibleChunks();

        // Access these neat little scratch properties!
        const scratchU64 = this.getScratchView();
        const scratchF64 = new Float64Array(
            scratchU64.buffer,
            scratchU64.byteOffset,
            scratchU64.length,
        );
        const scratchI64 = new BigInt64Array(
            scratchU64.buffer,
            scratchU64.byteOffset,
            scratchU64.length,
        );

        // use game view to get some values
        const camera_pos = this.getGameView(
            WasmTypeCode.Float64,
            Zig.game_state_offsets.camera_pos,
            2,
        );
        const camera_scale_and_change = this.getGameView(
            WasmTypeCode.Float64,
            Zig.game_state_offsets.camera_scale,
            2,
        );

        const resolutionScale = this.canvas.width / INTERNAL_WIDTH;
        const effectiveZoom =
            camera_scale_and_change[0] *
            camera_scale_and_change[1] ** (timeInterpolated - 1) *
            resolutionScale;
        console.log(effectiveZoom);

        // logic-frame camera position
        const baseCamX = camera_pos[0];
        const baseCamY = camera_pos[1];

        // camera's velocity (delta)
        const camVelX = scratchF64[6 + 4];
        const camVelY = scratchF64[7 + 4];

        // interpolated camera
        const interpCamX =
            baseCamX +
            camVelX * (timeInterpolated - 1) -
            (INTERNAL_WIDTH * SIDE) / 2;
        const interpCamY =
            baseCamY +
            camVelY * (timeInterpolated - 1) -
            (INTERNAL_HEIGHT * SIDE) / 2;

        // grid origin in subpixerls
        const originX = scratchI64[2 + 4];
        const originY = scratchI64[3 + 4];

        // Calculated final camera position for the shader
        const camX = Number(BigInt(Math.round(interpCamX)) - originX) / SIDE;
        const camY = Number(BigInt(Math.round(interpCamY)) - originY) / SIDE;

        // Actual player position
        const realPlayerX = scratchF64[4 + 4];
        const realPlayerY = scratchF64[5 + 4];

        // Since the shader centers the camera, the center of the viewport is (Width/2, Height/2)
        // Adjust for sprite size (SIDE=16) to center the sprite on its pivot
        const playerX = INTERNAL_WIDTH / 2 + realPlayerX;
        const playerY = INTERNAL_HEIGHT / 2 + realPlayerY;

        // Send data to WebGPU
        const uniformData = new Float32Array([
            camX,
            camY,
            this.canvas.width,
            this.canvas.height,
            currentTime,
            effectiveZoom,
            this.wireframeOpacity,
            1.0, // chunk opacity
            playerX,
            playerY,
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

        // Draw all tiles as instances. Uses a triangle-strip so 4 vextexCount instead of 6. Also add 1 more instance for the player!
        const instanceCount = this.tileMap.width * this.tileMap.height + 1;
        renderPass.draw(4, instanceCount);

        renderPass.end();
        this.device.queue.submit([commandEncoder.finish()]);
    }

    /** Updates the game's logic state. */
    public tick(logicSpeed: number) {
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
        this.exports.tick(logicSpeed);
    }
}
