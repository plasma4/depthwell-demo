import * as Zig from "./enums";

/** Represents the state of inputs for external use. */
export interface InputState {
    heldMask: number;
    keysHeld: number;
    keysPressed: number;
    currentlyHeld: number;
    horizontalPriority: number;
    verticalPriority: number;
}

/** An object representing what a keydown/keyup code should map to numerically (as a bit in Zig.KeyBits). */
const keyMap: Record<string, number> = {
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
    // Track individual key counts to handle multiple keys mapping to one bit, such as W and KeyUp simulataneously.
    const keyCounts: Record<number, number> = {};

    const state: InputState = {
        heldMask: 0,
        keysHeld: 0,
        keysPressed: 0,
        currentlyHeld: 0,
        // "Last-win" input priority
        horizontalPriority: 0,
        verticalPriority: 0,
    };

    window.addEventListener("keydown", (e: KeyboardEvent) => {
        if (e.repeat) return;
        const bit = keyMap[e.code]; // apparently .code is more robust as it's based on physical keyboard locations, which is what we want here
        if (!bit) return;

        state.heldMask |= bit;
        keyCounts[bit] = (keyCounts[bit] || 0) + 1;

        // The most recently pressed key wins!
        if (bit & (Zig.KeyBits.left | Zig.KeyBits.right))
            state.horizontalPriority = bit;
        if (bit & (Zig.KeyBits.up | Zig.KeyBits.down))
            state.verticalPriority = bit;
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
        }
    });

    window.addEventListener("blur", () => {
        state.horizontalPriority = 0;
        state.verticalPriority = 0;
        state.currentlyHeld = 0;
        state.heldMask = 0;
        state.keysPressed = 0;
    });

    return state;
}

/** Updates the state object. */
export function updateInput(state: InputState) {
    const dirMask =
        Zig.KeyBits.up |
        Zig.KeyBits.down |
        Zig.KeyBits.left |
        Zig.KeyBits.right;

    // Start with non-directional bits (digits)
    let cleanHeld = state.heldMask & ~dirMask;

    // Add only the priority directions
    cleanHeld |= state.horizontalPriority;
    cleanHeld |= state.verticalPriority;

    state.keysPressed = cleanHeld & ~state.keysHeld;
    state.currentlyHeld = cleanHeld;
    state.keysHeld = cleanHeld;
}
