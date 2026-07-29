"use strict";
/**
 * TL;DR: this worker attempts to force a synchronous save on tab close/hide with verification.
 * Dedicated worker that owns a permanently open synchronous OPFS handle to the emergency export slot,
 * run on `pagehide`/`visibilitychange`.
 *
 * `FileSystemSyncAccessHandle` is worker-only, but it is the one storage API whose writes need no further event-loop turns:
 * - once a message arrives, truncate+write+flush complete synchronously
 * - a save transferred during `pagehide` survives
 *   (even though the page and worker are forced to shut down in a short time window)
 *
 * A torn write fails BLAKE3 validation and the loader falls back to `MAIN`/`BAK`
 * (this way we can easily verify validity if a device crash occurs or similar)!
 */
interface FileSystemSyncAccessHandle {
    getSize(): number;
    read(buffer: ArrayBufferView, options?: { at?: number }): number;
    write(buffer: ArrayBufferView, options?: { at?: number }): number;
    truncate(newSize: number): void;
    flush(): void;
    close(): void;
}

// The handle is acquired once at startup and held for the whole session,
// and the lock forces the main thread to read the slot through this worker as well.

// The slot is cleared after every committed normal save,
// so a non-empty slot is always newer than the committed `MAIN` save.
declare global {
    interface FileSystemFileHandle {
        createSyncAccessHandle(): Promise<FileSystemSyncAccessHandle>;
    }
}

/** Must match `SAVE_DIR` in saveManager.ts (both address the same OPFS directory). */
const SAVE_DIR = "saves";
const EMERGENCY = "world.em";

/** Lock-acquisition retries: a closing previous tab's worker may briefly still hold the slot. */
const ACQUIRE_ATTEMPTS = 5;
const ACQUIRE_RETRY_MS = 300;

type InMsg =
    | { kind: "write"; buf: ArrayBuffer }
    | { kind: "clear" }
    | { kind: "read"; id: number };
type OutMsg =
    | { kind: "ready"; ok: boolean }
    | { kind: "read"; id: number; buf: ArrayBuffer | null };

// self type, but recasted to contain function signatures
const ctx = self as unknown as {
    onmessage: ((e: MessageEvent<InMsg>) => void) | null;
    postMessage(msg: OutMsg, transfer?: Transferable[]): void;
};

let handle: FileSystemSyncAccessHandle | null = null;
/** Messages that arrived before the handle finished opening (replayed in order). */
let queued: InMsg[] = [];

ctx.onmessage = (e: MessageEvent<InMsg>) => {
    if (handle) {
        process(e.data);
    } else {
        queued.push(e.data);
    }
};

function process(msg: InMsg): void {
    const h = handle!;
    switch (msg.kind) {
        case "write": {
            // Fully synchronous: nothing after this point can be lost to page teardown.
            h.truncate(0);
            h.write(new Uint8Array(msg.buf), { at: 0 });
            h.flush();
            break;
        }
        case "clear": {
            h.truncate(0);
            h.flush();
            break;
        }
        case "read": {
            const size = h.getSize();
            if (size === 0) {
                ctx.postMessage({ kind: "read", id: msg.id, buf: null });
                break;
            }
            const buf = new ArrayBuffer(size);
            h.read(new Uint8Array(buf), { at: 0 });
            ctx.postMessage({ kind: "read", id: msg.id, buf }, [buf]);
            break;
        }
    }
}

async function init(): Promise<void> {
    try {
        const root = await navigator.storage.getDirectory();
        const dir = await root.getDirectoryHandle(SAVE_DIR, { create: true });
        const fh = await dir.getFileHandle(EMERGENCY, { create: true });
        for (let attempt = 1; ; attempt++) {
            try {
                // acquire read/write access
                handle = await fh.createSyncAccessHandle();
                break;
            } catch (err) {
                if (attempt >= ACQUIRE_ATTEMPTS) throw err;
                await new Promise((r) => setTimeout(r, ACQUIRE_RETRY_MS));
            }
        }
    } catch (err) {
        console.warn("Save worker could not lock the emergency slot:", err);
        ctx.postMessage({ kind: "ready", ok: false });
        return;
    }

    for (const m of queued) process(m);
    queued = [];
    ctx.postMessage({ kind: "ready", ok: true });
}
void init();

export {};
