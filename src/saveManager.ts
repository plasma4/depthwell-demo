"use strict";
import type { GameEngine } from "./engine";

const SAVE_DIR = "saves";
const MAIN = "world.dw";
const BAK = "world.bak";

// (gzip stream headers (RFC 1952) used to detect a compressed blob on load)
const GZIP_MAGIC0 = 0x1f;
const GZIP_MAGIC1 = 0x8b;

/**
 * Handles atomic saving budgeting logic, OPFS, and tab lock.
 * See `zig/state/save.zig` for integration details.
 */
export class SaveManager {
    private readonly engine: GameEngine;
    private hasActiveLock = false;
    private lockResolver?: () => void;
    /** Tracks the active save execution to allow escalation or waiting. */
    private activeSavePromise: Promise<void> | null = null;
    /** Triggers immediate synchronous completion of an in-flight budgeted save. */
    private forceSyncCompletion = false;
    /** Allows immediately resolving the pending frame-yield promise. */
    private activeYieldResolver: (() => void) | null = null;
    /** Worker holding a pre-opened synchronous handle to the emergency slot (see saveWorker.ts). */
    private worker: Worker | null = null;
    /** Whether the worker has acquired the emergency-slot lock (false = fall back to async saves). */
    private workerReady = false;
    /** In-flight emergency-slot read requests, keyed by request id. */
    private readonly pendingReads = new Map<
        number,
        (bytes: Uint8Array | null) => void
    >();
    private nextReadId = 1;

    public constructor(engine: GameEngine) {
        this.engine = engine;
        // Ask the browser not to evict our saves under storage pressure (best-effort).
        void navigator.storage?.persist?.();

        try {
            this.worker = new Worker(
                new URL("./saveWorker.ts", import.meta.url),
                { type: "module" },
            );
            this.worker.onmessage = (e) => this.onWorkerMessage(e.data);
            this.worker.onerror = (e) => {
                console.warn("Save worker failed:", e);
                this.worker = null;
                this.workerReady = false;
            };
        } catch (err) {
            console.warn("Save worker unavailable:", err);
            this.worker = null;
        }
    }

    private onWorkerMessage(msg: {
        kind: string;
        ok?: boolean;
        id?: number;
        buf?: ArrayBuffer | null;
    }): void {
        if (msg.kind === "ready") {
            this.workerReady = msg.ok === true;
            if (!this.workerReady) {
                console.warn(
                    "Emergency save slot unavailable (another tab may hold it); page-close saves will be best-effort.",
                );
            }
        } else if (msg.kind === "read" && msg.id !== undefined) {
            const resolve = this.pendingReads.get(msg.id);
            if (resolve) {
                this.pendingReads.delete(msg.id);
                resolve(msg.buf ? new Uint8Array(msg.buf) : null);
            }
        }
    }

    /** Acquires a tab lock: returns true if successful and false if another tab with lock is open. */
    public tryAcquireTabExclusiveLock(): Promise<boolean> {
        return new Promise<boolean>((resolveResult) => {
            void navigator.locks
                .request(
                    "depthwell-game",
                    { ifAvailable: true }, // fail immediately instead of queueing
                    async (lock) => {
                        if (!lock) {
                            // Lock is already held by another tab!
                            this.hasActiveLock = false;
                            resolveResult(false); // unblock the caller with false
                            return; // exit immediately
                        }

                        this.hasActiveLock = true;

                        // Signal success to the caller immediately so the game can proceed.
                        resolveResult(true);

                        // Keep this callback suspended indefinitely to maintain lock ownership.
                        await new Promise<void>((resolveLock) => {
                            this.lockResolver = resolveLock;
                        });
                    },
                )
                .catch((err) => {
                    console.warn("Failed to request lock:", err);
                    this.hasActiveLock = false;
                    resolveResult(false);
                });
        });
    }

    /**
     * Attempts to acquire the lock repeatedly until it succeeds.
     */
    public async acquireLockWithRetry(intervalMs: number = 500): Promise<void> {
        while (true) {
            console.log("Attempting to acquire exclusive tab lock...");
            const success = await this.tryAcquireTabExclusiveLock();

            if (success) {
                console.log("Successfully acquired lock!");
                return; // exit the loop to continue init
            }

            console.log(`Lock busy. Retrying in ${intervalMs}ms...`);
            await this.delay(intervalMs); // wait before trying again
        }
    }

    private delay(ms: number): Promise<void> {
        return new Promise((resolve) => setTimeout(resolve, ms));
    }

    /** Shuts down the tab lock and let another tab take over. */
    public releaseTabExclusiveLock(): void {
        if (this.lockResolver) {
            this.lockResolver();
            this.hasActiveLock = false;
        }
    }

    /*
        ----
        WASM Boundary
        ----
    */

    /** Serializes the full game state and copies it out of WASM memory into a standalone buffer. */
    private exportBytes(): Uint8Array {
        const len = Number(this.engine.exports.saveExportAll());
        if (len === 0)
            throw new Error("saveExportAll returned 0 (serialization failed)");
        const ptr = Number(this.engine.exports.saveGetExportPtr());

        // On single-core builds, the WASM heap is a normal ArrayBuffer, so a direct slice is enough.
        return new Uint8Array(this.engine.memory.buffer, ptr, len).slice();
    }

    /**
     * Serializes coherently but spread across frames:
     * Zig captures the small sections up front and copy-on-writes any modified chunk the game touches mid-save,
     * so the blob is a single instant even though it drains over many frames.
     * Yields a frame between batches so the game keeps running.
     */
    private async serializeBudgeted(): Promise<Uint8Array> {
        const total = Number(this.engine.exports.saveBeginSnapshot());
        if (total < 0) throw new Error("saveBeginSnapshot failed");

        const startTime = performance.now();
        const TARGET_SAVE_TIME_MS = 11500; // target save duration within the 12-second limit
        // ~1MB of memcpy + incremental BLAKE3 per batch: <5ms per frame on mid-end devices
        const SAFE_LOWER_BOUND = 256;

        let remaining = total;
        while (remaining > 0) {
            // If escalated mid-save, process all remaining chunks immediately without yielding
            if (this.forceSyncCompletion) {
                remaining = Number(
                    this.engine.exports.saveWriteBatch(BigInt(remaining)),
                );
                if (remaining < 0) {
                    throw new Error("save aborted (world was reset mid-save)");
                }
                break;
            }

            const elapsed = performance.now() - startTime;
            const remainingTime = Math.max(10, TARGET_SAVE_TIME_MS - elapsed);

            // estimate remaining frames assuming a pessimistic 30fps under load (ms -> frames)
            const estimatedRemainingFrames = remainingTime * (30 / 1000);
            const requiredChunksPerFrame = Math.ceil(
                remaining / estimatedRemainingFrames,
            );

            const maxChunks = Math.max(
                SAFE_LOWER_BOUND,
                requiredChunksPerFrame,
            );

            remaining = Number(
                this.engine.exports.saveWriteBatch(BigInt(maxChunks)),
            );
            if (remaining < 0) {
                throw new Error("save aborted (world was reset mid-save)");
            }
            if (remaining === 0) break;

            if (this.forceSyncCompletion) {
                continue;
            }

            // Yield control back to the browser, storing the resolver in case we need to escalate immediately.
            // (In a hidden tab requestAnimationFrame() never fires so fall back to setTimeout there to avoid stalling forever)
            await new Promise<void>((resolve) => {
                this.activeYieldResolver = resolve;
                const settle = () => {
                    if (this.activeYieldResolver === resolve) {
                        this.activeYieldResolver = null;
                        resolve();
                    }
                };
                if (document.visibilityState === "hidden") {
                    setTimeout(settle, 0);
                } else {
                    requestAnimationFrame(settle);
                }
            });
        }
        const len = Number(this.engine.exports.saveGetExportLen());
        const ptr = Number(this.engine.exports.saveGetExportPtr());

        const ab = new ArrayBuffer(len);
        const copy = new Uint8Array(ab);
        copy.set(new Uint8Array(this.engine.memory.buffer, ptr, len));
        return copy;
    }

    /*
        ----
        Compression
        ----
    */

    private async gzip(bytes: Uint8Array): Promise<Uint8Array> {
        const stream = new Blob([bytes as any]) // typescript funny
            .stream()
            .pipeThrough(new CompressionStream("gzip"));
        return new Uint8Array(await new Response(stream).arrayBuffer());
    }

    private async gunzip(bytes: Uint8Array): Promise<Uint8Array> {
        const stream = new Blob([bytes as any])
            .stream()
            .pipeThrough(new DecompressionStream("gzip"));
        return new Uint8Array(await new Response(stream).arrayBuffer());
    }

    private isGzip(b: Uint8Array): boolean {
        return b.length >= 2 && b[0] === GZIP_MAGIC0 && b[1] === GZIP_MAGIC1;
    }

    /*
        ----
        OPFS Handling
        ----
    */

    private async dir(): Promise<FileSystemDirectoryHandle> {
        const root = await navigator.storage.getDirectory();
        return root.getDirectoryHandle(SAVE_DIR, { create: true });
    }

    private async fileExists(
        dir: FileSystemDirectoryHandle,
        name: string,
    ): Promise<boolean> {
        try {
            await dir.getFileHandle(name);
            return true;
        } catch {
            return false;
        }
    }

    private async readFile(
        dir: FileSystemDirectoryHandle,
        name: string,
    ): Promise<Uint8Array | null> {
        try {
            const fh = await dir.getFileHandle(name);
            const file = await fh.getFile();
            return new Uint8Array(await file.arrayBuffer());
        } catch {
            return null;
        }
    }

    /** Writes `bytes` to `name` atomically: `createWritable()` swaps the file in only on `close()`. */
    private async writeFileAtomic(
        dir: FileSystemDirectoryHandle,
        name: string,
        bytes: Uint8Array,
    ): Promise<void> {
        const fh = await dir.getFileHandle(name, { create: true });
        const writable = await fh.createWritable({ keepExistingData: false });
        await writable.write(bytes as BufferSource);
        await writable.close();
    }

    /*
        ----
        Public API
        ----
    */

    /**
     * Serializes and commits the current game state to OPFS. Budgeted (frame-spread) by default;
     * set `budgeted` to false for a synchronous single-shot save
     * (such as on page unload, where there are no future frames to spread across).
     */
    public async save(compress = true, budgeted = true): Promise<void> {
        // A save is already in flight: an urgent (non-budgeted) request escalates it to finish immediately instead of waiting on rAF yields,
        // which never fire in a hidden tab.
        if (this.activeSavePromise) {
            if (!budgeted) {
                this.forceSyncCompletion = true;
                const resume = this.activeYieldResolver;
                this.activeYieldResolver = null;
                resume?.();
            }
            await this.activeSavePromise;
            return;
        }

        this.activeSavePromise = this.runSave(compress, budgeted);
        try {
            await this.activeSavePromise;
        } finally {
            this.activeSavePromise = null;
            this.forceSyncCompletion = false;
        }
    }

    private async runSave(compress: boolean, budgeted: boolean): Promise<void> {
        const raw = budgeted
            ? await this.serializeBudgeted()
            : this.exportBytes();

        // An unload/escalated save skips every optional async hop (gzip, BAK rotation):
        // each await after pagehide risks the page dying first, and load() reads uncompressed blobs fine.
        const urgent = !budgeted || this.forceSyncCompletion;
        const out = compress && !urgent ? await this.gzip(raw) : raw;
        const dir = await this.dir();

        // Rotate the current MAIN save into BAK atomically (skipped when urgent; BAK then lags one generation).
        if (!urgent) {
            const existingMain = await this.readFile(dir, MAIN);
            if (existingMain) {
                await this.writeFileAtomic(dir, BAK, existingMain);
            }
        }

        // Write the new save directly to MAIN atomically.
        await this.writeFileAtomic(dir, MAIN, out);

        // MAIN is now at least as new as any emergency snapshot: retire the slot.
        // (postMessage ordering guarantees this can't clear a *later* emergency write.)
        if (this.workerReady) this.worker?.postMessage({ kind: "clear" });
    }

    /**
     * Page-teardown save: serializes synchronously (aborting any in-flight budgeted snapshot) and transfers the blob zero-copy to the save worker,
     * whose pre-opened synchronous OPFS handle writes it without touching the dying page's event loop.
     * This seems to reliably survive `pagehide`; without the worker it degrades to a best-effort async save.
     */
    public emergencySaveSync(): void {
        try {
            if (!this.worker || !this.workerReady) {
                void this.save(false, false).catch((err) =>
                    console.warn("Fallback emergency save failed:", err),
                );
                return;
            }
            const raw = this.exportBytes(); // standalone copy, so its buffer is transferable
            this.worker.postMessage({ kind: "write", buf: raw.buffer }, [
                raw.buffer as ArrayBuffer,
            ]);
        } catch (err) {
            console.warn("Emergency save failed:", err);
        }
    }

    /** Reads the emergency slot through the worker (its lock blocks direct main-thread reads). */
    private readEmergency(): Promise<Uint8Array | null> {
        if (!this.worker) return Promise.resolve(null);
        return new Promise((resolve) => {
            const id = this.nextReadId++;
            this.pendingReads.set(id, resolve);
            this.worker!.postMessage({ kind: "read", id });
            // If the worker never acquired its handle (or died), don't hang the load forever.
            setTimeout(() => {
                if (this.pendingReads.delete(id)) resolve(null);
            }, 2000);
        });
    }

    /**
     * Reads and decompresses file bytes asynchronously without touching the WASM game state.
     */
    private async readAndDecompress(
        dir: FileSystemDirectoryHandle,
        name: string,
    ): Promise<Uint8Array | null> {
        try {
            const bytes = await this.readFile(dir, name);
            if (!bytes) return null;
            if (this.isGzip(bytes)) {
                return await this.gunzip(bytes);
            }
            return bytes;
        } catch (err) {
            console.warn(`Failed to read or decompress ${name}:`, err);
            return null;
        }
    }

    /**
     * Applies the decompressed save bytes synchronously.
     * Does not yield to the event loop (preventing data corruption).
     */
    private applyBytesSync(bytes: Uint8Array, sourceName: string): boolean {
        // Copy bytes into WASM heap and parse synchronously
        const ptr = Number(
            this.engine.exports.savePrepareImport(BigInt(bytes.length)),
        );
        if (ptr === 0) {
            alert("Import failed; resetting.");
            this.engine.start();
            return false;
        }
        new Uint8Array(this.engine.memory.buffer, ptr, bytes.length).set(bytes);

        const success = this.engine.exports.saveImportAll(BigInt(bytes.length));
        if (!success) {
            alert("Import failed; resetting.");
            this.engine.start();
            return false;
        }

        // Finalize state derivation synchronously
        this.engine.exports.saveFinalizeLoad();
        this.engine.startDelta = Number(
            this.engine.exports.mixSeed(60n) % 120000n,
        );
        return true;
    }

    /** Loads the committed save (falling back to BAK) and applies it. Returns whether it loaded. */
    public async load(): Promise<boolean> {
        // The emergency slot is only non-empty when it is newer than MAIN (commits clear it),
        // so it takes priority; a torn slot write fails validation and falls through to MAIN.
        const emergency = await this.readEmergency();
        if (emergency && emergency.length > 0) {
            if (this.applyBytesSync(emergency, "emergency slot")) return true;
        }

        const dir = await this.dir();

        // Try MAIN, then BAK: a file that reads and decompresses fine can still fail
        // Zig-side validation (hash/format), so the fallback covers both failure kinds.
        for (const name of [MAIN, BAK]) {
            const bytes = await this.readAndDecompress(dir, name);
            if (!bytes) continue;
            // Commit the bytes synchronously in a single frame execution slice
            if (this.applyBytesSync(bytes, name)) return true;
        }
        return false;
    }

    /** Loads a save from raw file bytes (gzipped or not), as produced by the export button. */
    public async importFromBytes(bytes: Uint8Array): Promise<boolean> {
        let raw = bytes;
        if (this.isGzip(bytes)) {
            raw = await this.gunzip(bytes);
        }
        return this.applyBytesSync(raw, "imported bytes");
    }

    /**
     * Autosave entry point: a budgeted save that swallows and logs errors instead of throwing,
     * so a failed or aborted save never breaks the game loop. No-op if a save is already running.
     */
    public async autosave(): Promise<void> {
        try {
            await this.save();
        } catch (err) {
            console.warn("Autosave failed:", err);
        }
    }

    /** Serializes the current state to a standalone gzipped blob (single-shot; used by the export button). */
    public async exportToBlob(): Promise<Uint8Array> {
        // saveExportAll() reuses the snapshot buffer, so wait out any in-flight save first.
        await this.activeSavePromise?.catch(() => {});
        return this.gzip(this.exportBytes());
    }

    /** Whether a committed save (or its backup, or an emergency snapshot) exists. */
    public async hasSave(): Promise<boolean> {
        const dir = await this.dir();
        if (
            (await this.fileExists(dir, MAIN)) ||
            (await this.fileExists(dir, BAK))
        ) {
            return true;
        }
        const emergency = await this.readEmergency();
        return emergency !== null && emergency.length > 0;
    }

    /** Deletes the save, its backup, and the emergency snapshot. */
    public async deleteSave(): Promise<void> {
        const dir = await this.dir();
        for (const name of [MAIN, BAK]) {
            try {
                await dir.removeEntry(name);
            } catch {
                // already gone
            }
        }
        // The emergency slot is lock-held by the worker; clear it there instead of removeEntry().
        if (this.workerReady) this.worker?.postMessage({ kind: "clear" });
    }
}
