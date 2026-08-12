const std = @import("std");
const dw = @import("../root.zig");
const memory = dw.memory;
const world = dw.world;
const entity = dw.entity;
const chunks = dw.chunks;
const sprite = dw.sprite;
const logger = dw.logger;

/// Brightness of chunk wireframes.
pub var WIREFRAME_BRIGHTNESS: f64 = 0.0;

const CHUNK_SIZE = dw.CHUNK_SIZE;
const CHUNK_SIZE_FLOAT = dw.CHUNK_SIZE_FLOAT;

/// Makes a call to `engine.handleVisibleChunks()` in JS.
pub inline fn handleVisibleChunks(opacity: f64, wireframeBrightness: f64) void {
    if (dw.is_wasm) {
        return dw.jsHandleVisibleChunks(opacity, wireframeBrightness);
    } else {
        return; // no native impl yet
    }
}

/// Makes a call to `engine.drawBackground()` in JS, using whatever scene the last chunk pass published.
pub inline fn drawBackground(opacity: f64) void {
    if (dw.is_wasm) {
        return dw.jsDrawBackground(opacity);
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
///
/// Draw order is painter's order, and JS consumes the scratch buffer synchronously on each call back,
/// so one scratch fill can serve both the background and the tiles of a layer before the next fill.
///
/// A portal descent adds a second layer on top: the D+1 preview, faded in over D (see `state/portal.zig`)!
pub fn prepareVisibleData(dt: f64, time_diff: f64, canvas_w: f64, canvas_h: f64) void {
    if (dw.chunks.updateVisibleChunks(dt, canvas_w, canvas_h)) {
        const world_opacity = dw.portal.worldOpacity();
        const chunk_opacity = world_opacity * @as(f64, dw.player.softlockFadeOpacity());
        drawBackground(world_opacity);
        handleVisibleChunks(chunk_opacity, WIREFRAME_BRIGHTNESS);
    }

    if (dw.portal.isActive()) {
        const opacity = dw.portal.overlayOpacity();
        if (opacity > 0.0) {
            dw.chunks.updateOverlayChunks(canvas_w, canvas_h);
            drawBackground(opacity);
            handleVisibleChunks(opacity, WIREFRAME_BRIGHTNESS);
        }
    }

    entity.updateEntities(time_diff);
    handleVisibleEntities();
}
