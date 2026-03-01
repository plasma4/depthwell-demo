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

import { GameEngine, CONFIG } from "./engine.ts";

if (!CONFIG.noAlertOnError) {
    const handleFatalError = (error, source, lineno, colno) => {
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

        if (globalThis.engine && globalThis.engine.destroyedError) {
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
const engine = await GameEngine.create();
if (CONFIG.exportEngine) globalThis.engine = engine;
if (CONFIG.verbose) {
    console.log("Engine initialized successfully:", engine);
    console.log("Exported functions and memory:", engine.exports);
}
engine.isDebug = !!engine.exports.isDebug(); // This function is only true if Doptimize=Debug (default with zig build). Note that this property is not defined in the TypeScript.
engine.exports.init();
renderLoop(0);
if (engine.isDebug) {
    console.log(
        "Zig code is in debug mode. Use engine.exports to see its functions, variables, and memory, such as engine.exports.testLogs.",
    );
} else if (CONFIG.verbose) {
    console.log(
        'Note: engine is in verbose mode, but Zig code is not in -Doptimize=Debug; either run just "zig build" or add that flag to enable additional testing features and safety checks.',
    );
}

function renderLoop(time) {
    // Difference between frames
    let timeDifference = time - timestamp;
    timestamp = time;
    engine.renderFrame(timeDifference);
    requestAnimationFrame(renderLoop, time);
}
