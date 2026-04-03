"use strict";
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
    alert("WebGPU is supported, but no compatible GPU was found.");
}

import { GameEngine } from "./engine";

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

/** Elements that are used in logging and hidden in production. */
const loggingElementIds = [
    "text1",
    "text2",
    "text3",
    "text4",
    "logicText",
    "renderText",
];

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
            e.preventDefault();
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

let time = performance.now(),
    accumulator = 0,
    frame = 0;
if (CONFIG.exportEngine) (globalThis as any).engine = engine;
if (CONFIG.verbose) {
    console.log("Engine initialized successfully:", engine);
    console.log("Exported functions and memory:", engine.exports);
}

window.addEventListener("blur", () => (time = Infinity)); // basically, don't let frames when the tab is hidden cause any simulation.

// Add custom properties into the engine object (not handled by TypeScript)
engine.isDebug = !!engine.exports.isDebug(); // This function is only true if Doptimize=Debug (default with zig build).
engine.renderLoop = function (_t: number) {
    // TODO back-off logic when frames get skipped, maybe? (due to WebGPU being the bottleneck)

    // simulate to a second/tick of logical simulation, whichever is higher (in practice, a tick will be less than a second, so 1 second)
    let tempTime = performance.now();
    let delta = time === Infinity ? 0 : tempTime - time;
    let newTicks = Math.min(
        (delta * engine.getFrameRate()) / 1000,
        engine.getFrameRate(),
    );

    engine.logicLoop(Math.floor(accumulator + newTicks));
    accumulator = (accumulator + newTicks) % 1; // calculate new fractional accumulation of ticks

    // mostly arbitrary color thresholds
    let color = "#dddddd";
    if (delta > 55) {
        color = "#e83769";
    } else if (delta > 30) {
        color = "#f39c19";
    } else if (delta > 20) {
        color = "#f7ce1a";
    }

    if (engine.isDebug) {
        const debugElem = document.getElementById(
            "renderText",
        ) as HTMLDivElement;
        debugElem.textContent = `Time since last render and Zig compute time: ${delta.toFixed(1)}ms, ${(performance.now() - tempTime).toFixed(1)}ms`;
        debugElem.style.fontWeight = (
            delta > 30 ? (delta > 55 ? 700 : 600) : 500
        ) as any; // gee thanks TypeScript
        debugElem.style.color = color;
    }

    let timeInterpolated = Math.min(accumulator - 1, 0);
    engine.renderFrame(timeInterpolated, time);

    requestAnimationFrame(engine.renderLoop);
    // setTimeout(engine.renderLoop, 100);
};

engine.logicLoop = function (ticks: number) {
    // Interestingly enough, as ticks becomes large enough, the "imprecision" of the camera (16 possible subpixel positions) results in the player panning being all weird! This only happens past 1000 logical FPS though.
    const startTime = performance.now();
    for (let i = 0; i < ticks; i++)
        engine.tick((60 / engine.getFrameRate()) * engine.baseSpeed);

    time = performance.now();
    let delta = time - startTime;

    // mostly arbitrary color thresholds
    let color = "#dddddd";
    if (delta > 30) {
        color = "#e83769";
    } else if (delta > 15) {
        color = "#f39c19";
    } else if (delta > 10) {
        color = "#f7ce1a";
    }

    if (engine.isDebug) {
        const debugElem = document.getElementById(
            "logicText",
        ) as HTMLDivElement;
        debugElem.textContent = `Logic diff (${ticks} tick${ticks == 1 ? "" : "s"}): ${delta.toFixed(1)}ms\n`;
        // new-line in string for copy and paste

        debugElem.style.fontWeight = (
            delta > 30 ? (delta > 55 ? 700 : 600) : 500
        ) as any; // gee thanks TypeScript
        debugElem.style.color = color;
    }
};

import { KeyBits, game_state_offsets } from "./enums";
globalThis.Zig = { KeyBits, game_state_offsets };
if (engine.isDebug) {
    console.log(
        "Zig code is in debug mode. Use engine.exports to see its functions, variables, and memory, such as engine.exports.test_logs.",
    );

    engine.wireframeOpacity = 1.0 / 3.0;
    loggingElementIds.forEach((id) => {
        (document.getElementById(id) as HTMLDivElement).style.display =
            "inline";
    });
} else {
    // Zig is not in debug mode!
    if (CONFIG.verbose) {
        console.log(
            'Note: engine is in verbose mode, but Zig code is not in -Doptimize=Debug; run just "zig build" to enable additional testing features and safety checks if possible.',
        );
    }
}

// Begin the logic
setTimeout(function () {
    engine.renderLoop(0);
}, 17);
