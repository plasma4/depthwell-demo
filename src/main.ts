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
        "WebGPU is not supported by your browser; try installing a more modern one.",
    );
}

const adapter = await navigator.gpu.requestAdapter();
if (!adapter) {
    alert("WebGPU is supported, but no compatible GPU was found.");
}

import { GameEngine, CONFIG } from "./engine";

declare module "./engine" {
    interface GameEngine {
        /** True if Zig is in -Doptimize=Debug mode. */
        isDebug: boolean;
        /** Main render loop. */
        renderLoop: (time: number) => void;
        /** Main logic loop. */
        logicLoop: () => void;
    }
}

declare global {
    interface Window {
        engine?: GameEngine;
    }
    // If you use globalThis specifically:
    var engine: GameEngine | undefined;
}

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

        if (globalThis.engine?.destroyedError) {
            errorMessage += `\nDetails: ${globalThis.engine.destroyedError}`;
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

let timestamp = 0;
let engine = await GameEngine.create();
let time = performance.now(),
    frame = 0;
if (CONFIG.exportEngine) (globalThis as any).engine = engine;
if (CONFIG.verbose) {
    console.log("Engine initialized successfully:", engine);
    console.log("Exported functions and memory:", engine.exports);
}

// Add custom properties into the engine object (not handled by TypeScript)
engine.isDebug = !!engine.exports.isDebug(); // This function is only true if Doptimize=Debug (default with zig build).
engine.renderLoop = function (time: number) {
    // Difference between frames
    let timeDifference = time - timestamp;
    timestamp = time;
    engine.renderFrame(timeDifference);
    requestAnimationFrame(engine.renderLoop);
};

engine.logicLoop = function () {
    const startTime = time;
    time = performance.now();
    engine.tick();
    setTimeout(
        engine.logicLoop,
        (frame++ % 3 == 2 ? 16 : 17) - time + startTime,
    );
};

if (engine.isDebug) {
    console.log(
        "Zig code is in debug mode. Use engine.exports to see its functions, variables, and memory, such as engine.exports.test_logs.",
    );
} else if (CONFIG.verbose) {
    console.log(
        'Note: engine is in verbose mode, but Zig code is not in -Doptimize=Debug; either run just "zig build" or add that flag to enable additional testing features and safety checks.',
    );
}

// Begin the logic
engine.renderLoop(0);
setTimeout(engine.logicLoop, 17);
