const std = @import("std");
const dw = @import("../root.zig");
const memory = dw.memory;
const world = dw.world;
const entity = dw.entity;
const chunks = dw.chunks;
const sprite = dw.sprite;
const logger = dw.logger;

/// Opacity of chunk wireframes.
pub var WIREFRAME_OPACITY: f64 = 0.0;

const CHUNK_SIZE = dw.CHUNK_SIZE;
const CHUNK_SIZE_FLOAT = dw.CHUNK_SIZE_FLOAT;

/// Makes a call to `engine.handleVisibleChunks()` in JS.
pub inline fn handleVisibleChunks(opacity: f64, wireframeOpacity: f64) void {
    if (dw.is_wasm) {
        return dw.jsHandleVisibleChunks(opacity, wireframeOpacity);
    } else {
        return; // no native impl yet
    }
}

/// Makes a call to `engine.handleVisibleChunks()` in JS.
pub inline fn handleVisibleEntities() void {
    if (dw.is_wasm) {
        return dw.jsHandleVisibleEntities();
    } else {
        return; // no native impl yet
    }
}

/// Sets the mouse type of the canvas in JS.
pub inline fn dispatchMouseType() void {
    if (dw.is_wasm) {
        dw.jsSetMouseType(dw.mouse.cursor_type);
    } else {
        return;
    }
}

/// Processes data for renderFrame() in TypeScript to upload to WebGPU.
pub fn prepareVisibleData(dt: f64, time_diff: f64, canvas_w: f64, canvas_h: f64) void {
    dw.chunks.updateVisibleChunks(dt, canvas_w, canvas_h);
    handleVisibleChunks(1.0, WIREFRAME_OPACITY);

    entity.updateEntities(time_diff);

    // no longer using SegmentedList
    // const count = entity.entities.count();

    // const out_ptr: [*]memory.WGSLEntity = @ptrCast(@alignCast(memory.scratchAlloc(count * @sizeOf(memory.WGSLEntity))));
    // const out_slice = out_ptr[0..count];
    // entity.entities.writeToSlice(out_slice, 0);

    handleVisibleEntities();

    // from old SegmentedList code:
    // entity.entities.clearRetainingCapacity(); // clear previous sprites
}
