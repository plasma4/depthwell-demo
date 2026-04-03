import * as Zig from "./enums";

/** Represents the state of inputs for external use. Priority values allow for "last-win" inputting for inputs that oppose each other (such as left/right or zoom in/out). */
export interface InputState {
    heldMask: number;
    keysHeld: number;
    keysPressed: number;
    currentlyHeld: number;
    plusMinusPriority: number;
    horizontalPriority: number;
    verticalPriority: number;
}

/** An object representing what a keydown/keyup code should map to numerically (as a bit in Zig.KeyBits). */
const keyMap: Record<string, number> = {
    Minus: Zig.KeyBits.minus,
    Equal: Zig.KeyBits.plus,
    KeyZ: Zig.KeyBits.zoom,
    KeyQ: Zig.KeyBits.drop,
    ArrowUp: Zig.KeyBits.up,
    KeyW: Zig.KeyBits.up,
    ArrowLeft: Zig.KeyBits.left,
    KeyA: Zig.KeyBits.left,
    ArrowDown: Zig.KeyBits.down,
    KeyS: Zig.KeyBits.down,
    ArrowRight: Zig.KeyBits.right,
    KeyD: Zig.KeyBits.right,
    Digit0: Zig.KeyBits.k0,
    Digit1: Zig.KeyBits.k1,
    Digit2: Zig.KeyBits.k2,
    Digit3: Zig.KeyBits.k3,
    Digit4: Zig.KeyBits.k4,
    Digit5: Zig.KeyBits.k5,
    Digit6: Zig.KeyBits.k6,
    Digit7: Zig.KeyBits.k7,
    Digit8: Zig.KeyBits.k8,
    Digit9: Zig.KeyBits.k9,
};

/** Creates an initial InputState and creates event listeners. Should be updated with with updateInput() in a logic loop. */
export function initInput(): InputState {
    /** Tracks individual key counts to handle multiple keys mapping to one bit, such as W and KeyUp simulataneously. */
    const keyCounts: Record<number, number> = {};

    const state: InputState = {
        heldMask: 0,
        keysHeld: 0,
        keysPressed: 0,
        currentlyHeld: 0,
        // "Last-win" input priority
        horizontalPriority: 0,
        verticalPriority: 0,
        plusMinusPriority: 0,
    };

    function reset() {
        state.horizontalPriority = 0;
        state.verticalPriority = 0;
        state.plusMinusPriority = 0;
        state.currentlyHeld = 0;
        state.heldMask = 0;
        state.keysPressed = 0;
    }

    window.addEventListener("keydown", (e: KeyboardEvent) => {
        if (e.altKey || e.shiftKey || e.ctrlKey || e.metaKey) {
            reset(); // prevent key-holding shenanigans
        }
        if (e.repeat || e.ctrlKey || e.metaKey) return;
        // console.log(e.code);
        const bit = keyMap[e.code]; // apparently .code is more robust as it's based on physical keyboard locations, which is what we want here
        if (!bit) return;

        state.heldMask |= bit;
        keyCounts[bit] = (keyCounts[bit] || 0) + 1;

        // The most recently pressed key wins!
        if (bit & (Zig.KeyBits.left | Zig.KeyBits.right))
            state.horizontalPriority = bit;
        if (bit & (Zig.KeyBits.up | Zig.KeyBits.down))
            state.verticalPriority = bit;
        if (bit & (Zig.KeyBits.plus | Zig.KeyBits.minus))
            state.plusMinusPriority = bit;
    });

    window.addEventListener("keyup", (e: KeyboardEvent) => {
        const bit = keyMap[e.code];
        if (!bit) return;

        keyCounts[bit] = Math.max(0, (keyCounts[bit] || 0) - 1);

        // Only clear the bit in the mask if ALL keys mapped to it are released
        if (keyCounts[bit] === 0) {
            state.heldMask &= ~bit;

            // If the priority key was released, switch priority to the other key (if held)
            if (bit === state.horizontalPriority) {
                state.horizontalPriority =
                    state.heldMask & Zig.KeyBits.left ||
                    state.heldMask & Zig.KeyBits.right ||
                    0;
            }
            if (bit === state.verticalPriority) {
                state.verticalPriority =
                    state.heldMask & Zig.KeyBits.up ||
                    state.heldMask & Zig.KeyBits.down ||
                    0;
            }
            if (bit === state.plusMinusPriority) {
                state.plusMinusPriority =
                    state.heldMask & Zig.KeyBits.plus ||
                    state.heldMask & Zig.KeyBits.minus ||
                    0;
            }
        }
    });

    window.addEventListener("blur", reset);

    return state;
}

/** Updates the state object. */
export function updateInput(state: InputState) {
    const directionMask =
        Zig.KeyBits.up |
        Zig.KeyBits.down |
        Zig.KeyBits.left |
        Zig.KeyBits.right;

    // Start with non-directional bits (digits)
    let cleanHeld = state.heldMask & ~directionMask;

    // Add only the priority directions
    cleanHeld |= state.horizontalPriority;
    cleanHeld |= state.verticalPriority;
    cleanHeld |= state.plusMinusPriority;

    state.keysPressed = cleanHeld & ~state.keysHeld; // a funny side effect of the logic being like this is that in very low-FPS situations you can lift a key early to cancel its pressed status
    state.currentlyHeld = cleanHeld;
    state.keysHeld = cleanHeld;
}
