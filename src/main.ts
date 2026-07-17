/// <reference types="vite/client" />
"use strict";
import { GameEngine } from "./engine";
import { KeyBits, game_state_offsets } from "./enums";

// const is_dev = import.meta.env.DEV;
const is_dev = true; // TODO use the other def in production
/**
 * Debug/testing options. Some options are automatically based on the development mode.
 */
export const CONFIG = {
    /** Whether to expose engine to globalThis or not. */
    exportEngine: true,
    /** Whether to use verbose logging or not. */
    verbose: import.meta.env.DEV,
    /**
     * If set to true, disables alerting on error.
     * Error will always show in console regardless of what this value is set to.
     */
    noAlertOnError: import.meta.env.DEV,
};

if ("file:" === location.protocol) {
    alert(
        "This game cannot run from a local file:// context; use an online version or test from localhost instead.",
    );
}
if (!isSecureContext) {
    alert("This game cannot run in a non-secure context.");
}

if (!navigator.gpu) {
    alert(
        "WebGPU is not supported by your browser; try playing this on an alternate or more modern browser.",
    );
}

const adapter = await navigator.gpu.requestAdapter();
if (!adapter) {
    alert(
        "WebGPU is supported by the browser, but no compatible GPU was found. Your GPU may be too old to play this game.",
    );
}

globalThis.Zig = { KeyBits, game_state_offsets };
if (is_dev) {
    console.log(
        "Zig code is in debug mode. Use engine.exports to see its functions, variables, and memory, such as engine.exports.test_logs.",
    );

    document.body.innerHTML += `<div id="textContainer"><div id="text1"></div><div id="text2"></div><div id="text3"></div><div id="text4"></div></div><div id="logicText"></div><div id="renderText"></div><div id="debugContainer"></div>`;
} else {
    // Zig is not in debug mode!
    if (CONFIG.verbose) {
        console.log(
            'Note: engine is in verbose mode, but Zig code is not in -Doptimize=Debug; run just "zig build" to enable additional testing features and safety checks if possible.',
        );
    }
}

declare module "./engine" {
    interface GameEngine {
        /** True if Zig is in -Doptimize=Debug mode. */
        isDebug: boolean;
        /** A multipier for how fast logic speed is. */
        baseSpeed: number;
        /** Main render loop. */
        renderLoop: (time: number) => void;
        /** Main logic loop (called from `renderLoop` to prevent frame drops). */
        logicLoop: (ticks: number) => void;
        /**
         * Returns the timeout time between logic frames in milliseconds. Note that the actual logic accounts for lag.
         * Customize the frame rate and timeout to test frame interpolation with this:
            ```ts
            engine.getTimeoutLength = () => 500;
            engine.getFrameRate = () => 2;
            ```
         */
        getTimeoutLength: () => number;
        /**
         * Returns the target logic frame rate.
         * Customize the frame rate and timeout to test frame interpolation with this:
            ```ts
            engine.getTimeoutLength = () => 500;
            engine.getFrameRate = () => 2;
            ```
         */
        getFrameRate: () => number;
    }
}

declare global {
    interface Window {
        engine?: GameEngine;
    }
    var engine: GameEngine | undefined;
    var WasmTypeCode: object;
    var Zig: object;
}

/*
    These global exports allow you to access stuff like memory views from engine.ts easily from the console:
    engine.getGameView(
        WasmTypeCode.Uint64,
        Zig.game_state_offsets.seed,
        8,
    )
*/

// Error-handling logic section!
if (!CONFIG.noAlertOnError) {
    const handleFatalError = (
        error: any,
        source?: any,
        lineno?: any,
        colno?: any,
    ) => {
        const actualError = error || {};
        const message = actualError.message || String(error || "Unknown error");
        let errorMessage = `An error occurred: ${message}`;

        // Safari uses error.line/error.column
        const finalLine = lineno || actualError.line;
        const finalCol = colno || actualError.column;

        if (source || finalLine || finalCol) {
            const fileName = source
                ? source.split("/").pop() || source
                : "unknown";
            errorMessage += `\nSource: ${fileName}:${finalLine || "?"}:${finalCol || "?"}`;
        }

        let err = globalThis.engine?.destroyedError;
        if (globalThis.engine?.destroyedError) {
            errorMessage += `\nDetails: ${err.message || err}`;
        }

        if (actualError.stack) {
            errorMessage += `\n\nStack trace:\n${actualError.stack}`;
        } else if (typeof error === "object" && error !== null) {
            try {
                const json = JSON.stringify(error);
                if (json !== "{}") errorMessage += `\nObject state: ${json}`;
            } catch {
                errorMessage += "\n(Object state hidden: circular reference)";
            }
        }

        alert(errorMessage);
        engine.saveManager?.releaseTabExclusiveLock();
    };

    window.onerror = (message, source, lineno, colno, error) => {
        handleFatalError(error || message, source, lineno, colno);
    };

    window.onunhandledrejection = (e) => {
        handleFatalError(e.reason);
    };

    console.error = (...args) => {
        const error = args.find((arg) => arg instanceof Error) || args[0];
        handleFatalError(error);
    };
}

document.addEventListener(
    "wheel",
    function (e) {
        if (e.ctrlKey) {
            // TODO un-comment out in final version
            // e.preventDefault();
        }
    },
    { passive: false },
);

let engine = await GameEngine.create();

engine.getTimeoutLength = function () {
    return ++frame % 3 == 2 ? 16 : 17;
};

engine.getFrameRate = function () {
    return 60;
};

engine.baseSpeed = 1;

let lastFrameTime = performance.now(),
    accumulator = 0,
    frame = 0;
if (CONFIG.exportEngine) (globalThis as any).engine = engine;

/** Delay in milliseconds between the *completion* of one autosave and the start of the next. */
const AUTOSAVE_INTERVAL_MS = 15000;
void (async () => {
    // use chained loop to prevent autosave stacking
    while (true) {
        await new Promise((resolve) =>
            setTimeout(resolve, AUTOSAVE_INTERVAL_MS),
        );
        await engine.saveManager.autosave();
    }
})();

// Emergency save when the tab is backgrounded or closing.
// On `hidden` the page is still alive: snapshot to the worker's emergency slot instantly,
// then run a normal durable autosave too (a committed save clears the slot again).
document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") {
        engine.saveManager.emergencySaveSync();
        // TODO: is this inefficient?
        engine.saveManager.autosave();
    }
});

window.addEventListener("pagehide", () =>
    // on `pagehide` only the synchronous export + zero-copy worker transfer can be relied upon.
    engine.saveManager.emergencySaveSync(),
);

/** Serializes the current game and prompts a download of the gzipped save file. */
async function downloadSaveFile() {
    const blob = await engine.saveManager.exportToBlob();
    const url = URL.createObjectURL(new Blob([blob as BlobPart]));
    const a = document.createElement("a");
    a.href = url;
    a.download = `depthwell.dat`;
    a.click();
    URL.revokeObjectURL(url);
}

/** Prompts the user for a save file and loads it into the running game. */
function uploadSaveFile() {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = ".dat,application/octet-stream";
    input.onchange = async () => {
        const file = input.files?.[0];
        if (!file) return;
        const bytes = new Uint8Array(await file.arrayBuffer());
        const ok = await engine.saveManager.importFromBytes(bytes);
    };
    input.click();
}

if (CONFIG.verbose) {
    console.log("Engine initialized successfully:", engine);
    console.log("Exported functions and memory:", engine.exports);
}

const past60SlowestLogicLoops = Array(60).fill(0);
const past60SlowestRenders = Array(60).fill(0);
const past60SlowestZigRenders = Array(60).fill(0);

// Add custom properties into the engine object (not handled by TypeScript)
engine.isDebug = !!engine.exports.isDebug(); // This function is only true if Doptimize=Debug (default with zig build).
engine.renderLoop = function (_t: number) {
    // simulate to a second/tick of logical simulation, whichever is higher (in practice, a tick will be less than a second, so 1 second)
    let tempTime = performance.now();
    let delta = lastFrameTime === Infinity ? 0 : tempTime - lastFrameTime;
    lastFrameTime = tempTime;

    // Convert elapsed time (ms) to logical ticks based on the current target frame rate.
    const tickDurationMs = 1000 / engine.getFrameRate();
    const newTicks = delta / tickDurationMs;

    // Accumulate fractional ticks until we have at least 1 full tick to process.
    const totalAvailableTicks = Math.min(accumulator + newTicks, 5); // no more than 5 frames!
    let ticksToRun = Math.floor(totalAvailableTicks);

    if (ticksToRun > 0) {
        engine.logicLoop(ticksToRun);
        // Subtract only the ticks we actually processed to keep the fractional remainder.
        accumulator = totalAvailableTicks - ticksToRun;
    } else {
        // No ticks run this frame; just update the accumulator.
        accumulator = totalAvailableTicks;
    }

    if (is_dev) {
        past60SlowestRenders.shift();
        past60SlowestRenders.push(delta);
        past60SlowestZigRenders.shift();
        past60SlowestZigRenders.push(engine.prepare_visible_data_time);

        const slowestRender = Math.max.apply(null, past60SlowestRenders);
        const slowestZigRender = Math.max.apply(null, past60SlowestZigRenders);

        // mostly arbitrary color thresholds
        let color = "#cccccc";
        if (slowestRender > 55) {
            color = "#e83769";
        } else if (slowestRender > 30) {
            color = "#f39c19";
        } else if (slowestRender > 20) {
            color = "#f7ce1a";
        }

        const debugElem = document.getElementById(
            "renderText",
        ) as HTMLDivElement;
        debugElem.textContent =
            ((document.getElementById("debugContainer") as HTMLDivElement).style
                .display === "none"
                ? ""
                : `Time since last render/prepare_visible_data call: ${delta.toFixed(1)}ms, ${engine.prepare_visible_data_time.toFixed(1)}ms\n`) +
            `Worst render times (past 60 frames): ${slowestRender.toFixed(1)}ms, ${slowestZigRender.toFixed(1)}ms`;

        debugElem.style.fontWeight = (
            slowestRender > 40 ? (slowestRender > 55 ? 700 : 600) : 500
        ) as any; // gee thanks TypeScript
        debugElem.style.color = color;
    }

    let timeInterpolated = Math.min(accumulator - 1, 0);
    engine.renderFrame(timeInterpolated, lastFrameTime);

    requestAnimationFrame(engine.renderLoop);
    // setTimeout(engine.renderLoop, 100);
};

engine.logicLoop = function (ticks: number) {
    // Interestingly enough, as ticks becomes large enough, the "imprecision" of the camera (16 possible subpixel positions) results in the player panning being all weird!
    // This only happens past 1000 logical FPS though so it's fine.
    const startTime = performance.now();

    // tickSpeed is the logical tick speed (shouldn't change based on frame rate)
    const tickSpeed = (60 / engine.getFrameRate()) * engine.baseSpeed;
    engine.tick(tickSpeed, ticks);
    let delta = performance.now() - startTime;

    if (is_dev) {
        past60SlowestLogicLoops.shift();
        past60SlowestLogicLoops.push(delta);

        const slowestLogicLoop = Math.max.apply(null, past60SlowestLogicLoops);

        // mostly arbitrary color thresholds
        let color = "#cccccc";
        if (slowestLogicLoop > 30) {
            color = "#e83769";
        } else if (slowestLogicLoop > 15) {
            color = "#f39c19";
        } else if (slowestLogicLoop > 10) {
            color = "#f7ce1a";
        }

        const debugElem = document.getElementById(
            "logicText",
        ) as HTMLDivElement;
        debugElem.textContent =
            ((document.getElementById("debugContainer") as HTMLDivElement).style
                .display === "none"
                ? ""
                : `WASM memory buffer: ${(engine.memory.buffer.byteLength / 1000000).toFixed(2)}MB\nLogic diff: ${delta.toFixed(1)}ms for ${ticks} tick${ticks == 1 ? "" : "s"}\n`) +
            `Worst logic tick (past 60 frames): ${slowestLogicLoop.toFixed(1)}ms\n`;
        // new-line in string for copy and paste

        debugElem.style.fontWeight = (
            slowestLogicLoop > 20 ? (slowestLogicLoop > 40 ? 700 : 600) : 500
        ) as any; // gee thanks TypeScript
        debugElem.style.color = color;
    }
};

// Helper to get normalized coordinates and tell Zig
const dispatch = (e: PointerEvent | null, action: number) => {
    // get canvas position relative to the viewport
    const rect = engine.canvas.getBoundingClientRect();
    if (e == null) {
        engine.exports.handleMouse(-1.0, -1.0, 5);
        return;
    }
    const x = (e.clientX - rect.left) / rect.width;
    const y = (e.clientY - rect.top) / rect.height;
    if (x >= 0 && x <= 1 && y >= 0 && y <= 1) {
        // only allow if within canvas bounds
        engine.exports.handleMouse(x, y, action);
    } else {
        engine.exports.handleMouse(-1.0, -1.0, action);
    }
};

window.addEventListener("blur", () => {
    lastFrameTime = Infinity;
    dispatch(null, 0);
}); // basically, don't let frames when the tab is hidden cause any simulation.

document.addEventListener("pointermove", (e) => {
    dispatch(e, 0);
});

document.addEventListener("pointerdown", (e) => {
    const target = e.target as HTMLElement;

    if (
        is_dev &&
        (!target || document.getElementById("debugContainer")!.contains(target))
    ) {
        return;
    }

    const action = e.button === 2 ? 3 : 1; // see zig/mouse.zig for what these actions mean
    dispatch(e, action);
});

document.addEventListener("pointerup", (e) => {
    const action = e.button === 2 ? 4 : 2;
    dispatch(e, action);
});

engine.canvas.style.touchAction = "none"; // prevent touch gesture interception

// Prevent context menu on right-click
document.addEventListener("contextmenu", (e) => e.preventDefault());

// Build the fancy debug UI in the corner!
if (is_dev && engine.isDebug) {
    // Populate scratch buffer with JSON data about the debug UI, and parse it!
    (engine.exports.debugBuildUiMetadata as () => void)();
    const jsonStr = engine.readStr();

    const meta = JSON.parse(jsonStr);
    if (CONFIG.verbose)
        console.log("Auto-generated buttons and slider data:", meta);

    const container: HTMLDivElement = document.getElementById(
        "debugContainer",
    ) as any;
    const textContainer: HTMLDivElement = document.getElementById(
        "textContainer",
    ) as any;
    container.style.display = "none";
    textContainer.style.display = "none";
    document.addEventListener("keydown", function (e) {
        if (e.code === "KeyM") {
            if (container.style.display === "none") {
                container.removeAttribute("style");
                textContainer.removeAttribute("style");
            } else {
                container.style.display = "none";
                textContainer.style.display = "none";
            }
        }
    });

    meta.buttons.forEach((b: any) => {
        const btn = document.createElement("button");
        btn.textContent = b.name;
        btn.onclick = () =>
            (engine.exports.clickDebugUiButton as (id: number) => void)(b.id);
        container.appendChild(btn);
    });

    meta.sliders.forEach((s: any) => {
        const wrapper = document.createElement("div");
        wrapper.style.display = "flex";
        wrapper.style.flexDirection = "column";

        const label = document.createElement("label");
        label.textContent = `${s.name}: ${s.val.toFixed(2)}`;
        label.style.fontSize = "12px";

        const input = document.createElement("input");
        input.type = "range";
        input.min = s.min;
        input.max = s.max;
        input.step = ((s.max - s.min) / 1000).toString();
        input.value = s.val;

        input.oninput = (e) => {
            const val = parseFloat((e.target as HTMLInputElement).value);
            label.textContent = `${s.name}: ${val.toFixed(2)}`;
            (
                engine.exports.changeDebugUiSlider as (
                    id: number,
                    val: number,
                ) => void
            )(s.id, val);
        };

        wrapper.appendChild(label);
        wrapper.appendChild(input);
        container.appendChild(wrapper);
    });

    // Save-system debug controls.
    const addSaveButton = (name: string, onClick: () => void) => {
        const btn = document.createElement("button");
        btn.textContent = name;
        btn.onclick = onClick;
        container.appendChild(btn);
    };
    addSaveButton("Force save", () => engine.saveManager.save());
    addSaveButton("Force load", async () => await engine.saveManager.load());
    addSaveButton("Reset", async () => {
        engine.start();
    });
    addSaveButton("Export file", () => downloadSaveFile());
    addSaveButton("Import file", () => uploadSaveFile());

    document.body.appendChild(container);
}

// Begin the logic
setTimeout(function () {
    engine.renderLoop(0);
}, 17);
