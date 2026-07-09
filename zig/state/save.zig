//! NOTE: This game is pre-demo so all saves may break at any time due to core logic changes!Forward-compatibility is never planned, only back.
//! Serializes the full game state to a versioned, self-describing binary blob for the OPFS host.
//! This file is the format engine: framing, primitives, the sprite-name remap table, and the per-section (de)serialization.
//! The atomic OPFS write and per-frame budgeting are handled by the JS host.
//!
//! Sprite and tool identities are stored by name, never by enum ordinal, so adding or reordering sprites never invalidates a save.
//! `SPRITE_TABLE` maps the raw ids embedded in `MOD_STORE` blocks back to names,
//! which the loader resolves against the running build's `Sprite` (unknown names degrade to `.none`).
//!
//! Format (little-endian):
//! - magic "DWSV" | `VERSION` u32
//! - sections, repeated: tag u16 enum | section_version u16 | byte_len u64 | payload[byte_len]
//! - end marker: tag `.end` (also u16, 0)
//! - BLAKE3 32-byte hash over every preceding byte
//!
//!
//! For importing process:
//! - `beginSnapshot()` writes the header and every small section (all captured at start), opens the MOD_STORE section,
//!   and freezes a plan (the key + history index of each modified chunk).
//! - `writeBatch()` then encodes up to N chunks per call. To keep the save atomic (handled partially by JS OPFS operations),
//!   whenever the game mutates a planned chunk before it has been encoded,
//!  `shadowChunkForSave()` first copies that chunk's start-of-snapshot contents into a side map,and the batch encodes from the shadow.
//! - A wipe of `mod_store` mid-snapshot (new game / load) bumps its generation and aborts.
const std = @import("std");
const dw = @import("../root.zig");

const memory = dw.memory;
const logger = dw.logger;
const world = dw.world;
const sprite = dw.sprite;
const inventory = dw.inventory;
const mining = dw.mining;
const furnace = @import("../menus/furnace.zig");

const Sprite = dw.Sprite;
const Block = memory.Block;
const Chunk = memory.Chunk;
const DepthCoordinate = world.DepthCoordinate;

/// Magic 4-byte header.
const MAGIC = "DWSV";

/// Current version of the game.
pub const VERSION: u32 = parseVersion("0.0.0");

/// Packs `a.b.c`-formatted version string into a u32 at comptime: `a` (major, range 0-255) in the high byte,
/// then `b` (minor, range 0-255) in the next byte, and `c` (patch, range 0-65535) in the lowest two bytes.
/// Compile-errors on a malformed string or an out-of-range component.
fn parseVersion(comptime s: []const u8) u32 {
    var parts: [3]u32 = .{ 0, 0, 0 };
    var idx: usize = 0;
    for (s) |ch| {
        if (ch == '.') {
            idx += 1;
            if (idx >= parts.len) @compileError("version must be \"a.b.c\": " ++ s);
        } else if (ch >= '0' and ch <= '9') {
            parts[idx] = parts[idx] * 10 + @as(u32, ch - '0');
        } else @compileError("invalid character in version string: " ++ s);
    }
    if (idx != 2) @compileError("version must be \"a.b.c\": " ++ s);
    if (parts[0] >= 256) @compileError("major version must be < 256: " ++ s);
    if (parts[1] >= 256) @compileError("minor version must be < 256: " ++ s);
    if (parts[2] >= 65536) @compileError("patch version must be < 65536: " ++ s);
    return (parts[0] << 24) | (parts[1] << 16) | parts[2];
}

/// Persistent allocator for the export/import scratch buffers
/// (survives across frames, unlike the render scratch buffer which is reused every frame).
const save_alloc = memory.page_allocator;

/// Section identifiers. NEVER renumber or repurpose a value; append new ones only.
const SectionTag = enum(u16) {
    end,
    sprite_table,
    header_core,
    quadcache,
    inventory,
    menus,
    tools,
    misc,
    mod_store,
};

fn sectionTagFromInt(raw: u16) ?SectionTag {
    inline for (@typeInfo(SectionTag).@"enum".fields) |f| {
        if (f.value == raw) return @enumFromInt(raw);
    }
    return null;
}

/// Possible failures when reading the save buffer.
pub const SaveError = error{
    Truncated,
    BadMagic,
    UnsupportedVersion,
    InvalidTag,
    BadData,
    OutOfMemory,
};

const Writer = struct {
    list: *std.ArrayList(u8),

    fn boolean(self: *Writer, v: bool) !void {
        // write as u8
        try self.int(u8, @intFromBool(v));
    }

    fn int(self: *Writer, comptime T: type, v: T) !void {
        // WASM is little-endian, so the native byte layout is the on-disk layout.
        const tmp: [@sizeOf(T)]u8 = @bitCast(v);
        try self.list.appendSlice(save_alloc, &tmp);
    }

    fn varint(self: *Writer, value: u64) !void {
        // LEB128 is super cool and also is what WASM uses!
        // basically, it uses 7 bits to write the data, and the 8th bit to determine whether to continue or stop
        // this makes small numbers take up less size
        var x = value;
        while (true) {
            var b: u8 = @intCast(x & 0x7f);
            x >>= 7;
            if (x != 0) b |= 0x80;
            try self.list.append(save_alloc, b);
            if (x == 0) break;
        }
    }

    fn bytes(self: *Writer, slice: []const u8) !void {
        try self.list.appendSlice(save_alloc, slice);
    }

    /// Length-prefixed (varint) byte string.
    fn str(self: *Writer, slice: []const u8) !void {
        try self.varint(slice.len);
        try self.list.appendSlice(save_alloc, slice);
    }

    fn spriteName(self: *Writer, s: Sprite) !void {
        // .getName() isn't internal so we can't use it
        try self.str(@tagName(s));
    }

    /// Writes a section header and returns the byte offset of its length field for `endSection()`.
    fn beginSection(self: *Writer, tag: SectionTag, section_version: u16) !usize {
        try self.int(u16, @intFromEnum(tag));
        try self.int(u16, section_version);
        const at = self.list.items.len;
        try self.int(u64, 0); // placeholder patched by endSection()
        return at;
    }

    fn endSection(self: *Writer, at: usize) void {
        const payload_len: u64 = @intCast(self.list.items.len - (at + 8));
        self.list.items[at..][0..8].* = @bitCast(payload_len);
    }
};

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn boolean(self: *Reader) !bool {
        return (try self.int(u8)) != 0;
    }

    fn int(self: *Reader, comptime T: type) !T {
        const n = @sizeOf(T);
        if (self.pos + n > self.buf.len) return SaveError.Truncated;
        const tmp: [n]u8 = self.buf[self.pos..][0..n].*;
        self.pos += n;
        return @bitCast(tmp);
    }

    fn varint(self: *Reader) !u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            if (self.pos >= self.buf.len) return SaveError.Truncated;
            const b = self.buf[self.pos];
            self.pos += 1;
            result |= @as(u64, b & 0x7f) << shift;
            if (b & 0x80 == 0) break;
            shift += 7;
        }
        return result;
    }

    fn bytes(self: *Reader, n: usize) ![]const u8 {
        if (self.pos + n > self.buf.len) return SaveError.Truncated;
        const out = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return out;
    }

    fn str(self: *Reader) ![]const u8 {
        const n = try self.varint();
        return self.bytes(@intCast(n));
    }

    /// Reads `n` bytes into `dst` (used for raw fixed-layout blocks such as quad-cache fields).
    fn readInto(self: *Reader, dst: []u8) !void {
        const src = try self.bytes(dst.len);
        @memcpy(dst, src);
    }

    fn skip(self: *Reader, n: usize) !void {
        if (self.pos + n > self.buf.len) return SaveError.Truncated;
        self.pos += n;
    }
};

fn spriteFromName(name: []const u8) ?Sprite {
    return std.meta.stringToEnum(Sprite, name);
}

fn toolFromName(name: []const u8) ?mining.Tools {
    return std.meta.stringToEnum(mining.Tools, name);
}

/// Maps a stored sprite id (as written by the saving build) to this build's `Sprite`.
/// Populated from the `SPRITE_TABLE` section during import; empty (identity-fallback) otherwise.
var id_remap: std.AutoHashMapUnmanaged(u16, Sprite) = .empty;

fn remapSpriteId(old_id: u16) Sprite {
    // No table loaded (e.g. a save without SPRITE_TABLE): assume the ids are this build's own.
    if (id_remap.count() == 0) return @enumFromInt(old_id);
    if (id_remap.get(old_id)) |s| return s;
    return .none;
}

/// Reads a `Block` stored verbatim (all 16 bytes), remapping its `id`/`base_id` through the sprite table.
/// This way, save made by a build with different sprite ordinals still resolves to the right sprites.
fn readBlock(r: *Reader) !Block {
    var b: Block = undefined;
    try r.readInto(std.mem.asBytes(&b));
    b.id = remapSpriteId(@intFromEnum(b.id));
    b.base_id = remapSpriteId(@intFromEnum(b.base_id));
    return b;
}

fn writeSpriteTable(w: *Writer) !void {
    const at = try w.beginSection(.sprite_table, 1);
    try w.varint(sprite.possible_item_sprites.len);
    for (sprite.possible_item_sprites) |s| {
        try w.int(u16, @intFromEnum(s));
        try w.spriteName(s);
    }
    w.endSection(at);
}

fn readSpriteTable(r: *Reader) !void {
    id_remap.clearRetainingCapacity();
    const n = try r.varint();
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const old_id = try r.int(u16);
        const name = try r.str();
        if (spriteFromName(name)) |s| {
            try id_remap.put(save_alloc, old_id, s);
        }
    }
}

/// Right after sprite logic: exports the `GameState` as one huge hunk.
fn writeHeaderCore(w: *Writer) !void {
    const at = try w.beginSection(.header_core, 1);
    const g = &memory.game;
    try w.bytes(std.mem.asBytes(g));
    w.endSection(at);
}

fn readHeaderCore(r: *Reader, section_len: usize) !void {
    // object already reset by importAll() before section dispatch
    const g = &memory.game;

    // safely read either the full stored payload or the max capacity of the current build
    const dest_slice = std.mem.asBytes(g);
    const copy_len = @min(section_len, dest_slice.len);
    try r.readInto(dest_slice[0..copy_len]);

    if (section_len != copy_len or memory.game.depth < dw.startup.STARTING_ZOOM_TIMES) {
        return SaveError.BadData;
    }

    g.keys_pressed_mask = 0;
    g.keys_held_mask = 0;
}

/// Exports quad cache (fractal descent state; raw internal fields + the two path lists)
fn writeQuadCache(w: *Writer) !void {
    const at = try w.beginSection(.quadcache, 1);
    const qc = &world.quad_cache;
    try w.bytes(std.mem.asBytes(&qc.path_hashes));
    try w.bytes(std.mem.asBytes(&qc.origins_x));
    try w.bytes(std.mem.asBytes(&qc.origins_y));
    try w.bytes(std.mem.asBytes(&qc.historical_seeds));
    try w.bytes(std.mem.asBytes(&qc.ancestor_materials));
    try w.int(u8, @as(u8, @intFromBool(qc.most_top)) |
        (@as(u8, @intFromBool(qc.most_bottom)) << 1) |
        (@as(u8, @intFromBool(qc.most_left)) << 2) |
        (@as(u8, @intFromBool(qc.most_right)) << 3));

    try w.varint(qc.left_path.len);
    for (0..qc.left_path.len) |i| try w.int(u64, qc.left_path.at(i).*);
    try w.varint(qc.top_path.len);
    for (0..qc.top_path.len) |i| try w.int(u64, qc.top_path.at(i).*);
    w.endSection(at);
}

fn readQuadCache(r: *Reader) !void {
    const qc = &world.quad_cache;
    try r.readInto(std.mem.asBytes(&qc.path_hashes));
    try r.readInto(std.mem.asBytes(&qc.origins_x));
    try r.readInto(std.mem.asBytes(&qc.origins_y));
    try r.readInto(std.mem.asBytes(&qc.historical_seeds));
    try r.readInto(std.mem.asBytes(&qc.ancestor_materials));
    const edges = try r.int(u8);
    qc.most_top = (edges & 1) != 0;
    qc.most_bottom = (edges & 2) != 0;
    qc.most_left = (edges & 4) != 0;
    qc.most_right = (edges & 8) != 0;

    const left_n = try r.varint();
    var i: u64 = 0;
    while (i < left_n) : (i += 1) try qc.left_path.append(world.alloc, try r.int(u64));

    const top_n = try r.varint();
    i = 0;
    while (i < top_n) : (i += 1) try qc.top_path.append(world.alloc, try r.int(u64));
}

/// Writes inventory data (sparse, and with names rather than IDs)
fn writeInventory(w: *Writer) !void {
    const at = try w.beginSection(.inventory, 1);
    try w.spriteName(inventory.selected_sprite);
    try w.int(u16, inventory.selected_row);

    var nonzero: u64 = 0;
    for (inventory.inventory_counts) |c| {
        if (c != 0) nonzero += 1;
    }
    try w.varint(nonzero);
    for (inventory.inventory_counts, 0..) |c, idx| {
        if (c == 0) continue;
        const s: Sprite = @enumFromInt(@as(u16, @intCast(idx)));
        try w.spriteName(s);
        try w.varint(c);
    }
    w.endSection(at);
}

fn readInventory(r: *Reader) !void {
    inventory.inventory_counts = @splat(0);
    const selected_name = try r.str();
    inventory.selected_sprite = spriteFromName(selected_name) orelse .none;
    inventory.selected_row = try r.int(u16);

    const n = try r.varint();
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const name = try r.str();
        const count = try r.varint();
        if (spriteFromName(name)) |s| {
            const idx = @intFromEnum(s);
            if (idx < inventory.inventory_counts.len) inventory.inventory_counts[idx] = count;
        } else {
            logger.log(@src(), "Saved sprite {s} doesn't exist in this version!", .{name});
        }
        // it's possible this sprite name no longer exists, that's okay
    }
}

/// Writes which menus are open.
fn writeMenus(w: *Writer) !void {
    const at = try w.beginSection(.menus, 1);
    // TODO: waste less bits and create generic menu exporter
    try w.boolean(dw.indicators.menus.corecraft);
    try w.boolean(dw.indicators.menus.furnace);
    w.endSection(at);
}

fn readMenus(r: *Reader) !void {
    dw.indicators.menus.corecraft = try r.boolean();
    dw.indicators.menus.furnace = try r.boolean();
}

/// Writes tool data! Designed to handle multiple owned pickaxes and potential future properties (usage TODO)
fn writeTools(w: *Writer) !void {
    const at = try w.beginSection(.tools, 1);
    try w.boolean(mining.has_structure_tool);
    try w.varint(0); // equipped index (single pickaxe for now)
    try w.varint(1); // owned tool count
    // per-tool record: name + a reserved length-prefixed property blob (future upgrades)
    try w.str(@tagName(mining.pickaxe_type));
    try w.varint(0); // property blob length
    w.endSection(at);
}

fn readTools(r: *Reader) !void {
    mining.has_structure_tool = try r.boolean();
    const equipped = try r.varint();
    const owned = try r.varint();

    var picked: mining.Tools = .stone;
    var i: u64 = 0;
    while (i < owned) : (i += 1) {
        const name = try r.str();
        const prop_len = try r.varint();
        try r.skip(@intCast(prop_len)); // reserved property blob (unknown fields skipped)
        if (i == equipped) {
            if (toolFromName(name)) |t| picked = t;
        }
    }

    mining.pickaxe_type = picked;
    const props = mining.pickaxe_table.get(picked);
    mining.mining_speed = props.speed;
    mining.mining_strength = props.strength;
}

/// Handles misc data:
/// - furnace menu logic (stores sprite fields by name, plus progress)
/// - direction the player is facing
fn writeMisc(w: *Writer) !void {
    const at = try w.beginSection(.misc, 1);

    const s = furnace.getSaveState();
    try w.spriteName(s.loaded_ore);
    try w.varint(s.loaded_count);
    try w.spriteName(s.output_bar);
    try w.varint(s.output_count);
    try w.int(u16, s.smelting_progress);
    try w.boolean(dw.player.facing_right);

    w.endSection(at);
}

fn readMisc(r: *Reader) !void {
    const loaded_ore = spriteFromName(try r.str()) orelse .none;
    const loaded_count: u32 = @intCast(try r.varint());
    const output_bar = spriteFromName(try r.str()) orelse .none;
    const output_count: u32 = @intCast(try r.varint());
    const smelting_progress = try r.int(u16);
    furnace.setSaveState(.{
        .loaded_ore = loaded_ore,
        .loaded_count = loaded_count,
        .output_bar = output_bar,
        .output_count = output_count,
        .smelting_progress = smelting_progress,
    });

    dw.player.facing_right = try r.boolean();
}

// Modification section that stores DepthCoordinate (suffix [2]u64 | depth u64 | quadrant u32) + 256 full blocks (4 KiB).

/// Serializes every chunk the player has modified, keyed by its `DepthCoordinate`.
/// Reads the index/history live (non-budgeted).
fn writeModStore(w: *Writer) !void {
    const at = try w.beginSection(.mod_store, 1);
    try w.varint(world.mod_store.index.count());

    var it = world.mod_store.index.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const chunk = world.mod_store.history.at(entry.value_ptr.*);
        try w.int(u64, key.suffix[0]);
        try w.int(u64, key.suffix[1]);
        try w.int(u64, key.depth);
        try w.int(u32, key.quadrant);
        try w.bytes(std.mem.sliceAsBytes(chunk.blocks[0..]));
    }
    w.endSection(at);
}

/// Rebuilds `mod_store` from the saved chunk records: clears it, then re-appends each chunk to the history and re-keys the index.
/// Sprite IDs inside each block are remapped by `readBlock()`.
fn readModStore(r: *Reader) !void {
    // we do NOT need to reset the mod store because importAll() resets before section dispatch
    const n = try r.varint();
    var e: u64 = 0;
    while (e < n) : (e += 1) {
        const key: DepthCoordinate = .{
            .suffix = .{ try r.int(u64), try r.int(u64) },
            .depth = try r.int(u64),
            .quadrant = try r.int(u32),
        };
        var chunk: Chunk = undefined;
        for (&chunk.blocks) |*b| b.* = try readBlock(r);

        const slot = world.mod_store.history.len;
        try world.mod_store.history.append(world.alloc, chunk);
        try world.mod_store.index.put(key, slot);
    }
}

/// Accumulates the finished save blob; handed to JS (which copies it out to OPFS).
var save_buf: std.ArrayList(u8) = .empty;
/// Staging buffer JS writes a save into before `importAll()`.
var load_buf: std.ArrayList(u8) = .empty;

/// Writes the whole save: the fixed header, every section in a stable order (`SPRITE_TABLE` first so the loader can remap `MOD_STORE` block ids),
/// the end marker, and a trailing BLAKE3 hash over everything.
fn serialize(w: *Writer) !void {
    try w.bytes(MAGIC);
    try w.int(u32, VERSION);

    try writeSpriteTable(w);
    try writeHeaderCore(w);
    try writeQuadCache(w);
    try writeInventory(w);
    try writeMenus(w);
    try writeTools(w);
    try writeMisc(w);
    try writeModStore(w);

    try w.int(u16, @intFromEnum(SectionTag.end));

    var hash_buf: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(w.list.items, &hash_buf, .{});
    try w.bytes(&hash_buf);
}

/// Serializes the entire game state into `save_buf`. Returns the byte length, or 0 on failure.
pub fn exportAll() usize {
    snapshot_active = false; // reuses save_buf, so an in-flight budgeted snapshot must abort
    save_buf.clearRetainingCapacity();
    var w: Writer = .{ .list = &save_buf };
    serialize(&w) catch |err| {
        logger.err(@src(), "Save export failed: {s}", .{@errorName(err)});
        return 0;
    };
    return save_buf.items.len;
}

/// Pointer to the finished save buffer (valid until the next `exportAll()`).
pub fn getExportPtr() usize {
    return @intFromPtr(save_buf.items.ptr);
}

/// Reserves `len` bytes in the load staging buffer and returns a pointer for JS to write into.
pub fn prepareImport(len: usize) usize {
    load_buf.clearRetainingCapacity();
    load_buf.resize(save_alloc, len) catch {
        logger.err(@src(), "Allocation failed while preparing for import!", .{});
        return 0;
    };
    return @intFromPtr(load_buf.items.ptr);
}

/// Validates the staged save and, only if it is structurally sound, resets the game and applies it. Returns whether it succeeded.
/// A blob that fails `validate()` leaves the running game untouched; a section that fails to parse after that can still leave a reset game (the JS host falls back to the backup save).
/// The intended load sequence is `prepareImport()` -> `importAll()` -> `finalizeLoad()`.
pub fn importAll(len: usize) bool {
    const buf = load_buf.items[0..len];
    validate(buf) catch |err| {
        logger.err(@src(), "Save validation failed: {s}", .{@errorName(err)});
        dw.startup.init(true);
        return false;
    };
    dw.startup.init(false);
    deserialize(buf) catch |err| {
        logger.err(@src(), "Save import failed: {s}", .{@errorName(err)});
        dw.startup.init(true);
        return false;
    };
    return true;
}

/// Rebuilds the derived state `importAll()` does not store and repopulates the `SimBuffer`
/// (so the restored world is visible immediately). Call after `importAll()`.
pub fn finalizeLoad() void {
    const g = &memory.game;

    // seed2 and the sound/particle rngs derive from the seed, never saved
    var temp_seed = dw.seeding.ChaCha12.init(&dw.seeding.mixBaseSeed(g.seed, 1));
    inline for (&g.seed2) |*s| s.* = temp_seed.next();
    dw.sound.seed = dw.seeding.ChaCha12.init(&dw.seeding.mixBaseSeed(g.seed, 2));
    dw.particles.seed = dw.seeding.ChaCha12.init(&dw.seeding.mixBaseSeed(g.seed, 3));

    world.max_possible_suffix = world.getMaxSuffixAtDepth(g.depth);

    // repopulate the SimBuffer around the player using the newly loaded state
    world.SimBuffer.sync(g.getPlayerCoord(), .{ 0, 0 });
}

/// Structurally validates a save blob without touching any game state: magic, BLAKE3 hash, format version, and section framing (known tags, in-bounds lengths, end marker reached).
/// `importAll()` runs this before the destructive game reset so a bad blob leaves the running game intact.
fn validate(buf: []const u8) !void {
    // header = magic(4) + format u32 + proc u32 (10 bytes) + trailing BLAKE3 hash (32 bytes)
    if (buf.len < MAGIC.len + 4 + 10 + 32) return SaveError.Truncated;
    if (!std.mem.eql(u8, buf[0..MAGIC.len], MAGIC)) return SaveError.BadMagic;

    // verify BLAKE3 hash over every byte before the trailing checksum
    var calculated_hash: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(buf[0 .. buf.len - 32], &calculated_hash, .{});
    const stored_hash = buf[buf.len - 32 ..];
    if (!std.mem.eql(u8, &calculated_hash, stored_hash)) return SaveError.BadData;

    var r: Reader = .{ .buf = buf, .pos = MAGIC.len };
    const format_version = try r.int(u32);
    // back-compatible only: read this version or older, reject anything newer than we understand
    if (format_version > VERSION) return SaveError.UnsupportedVersion;

    while (true) {
        const tag_raw = try r.int(u16);
        if (tag_raw == @intFromEnum(SectionTag.end)) break;
        _ = try r.int(u16); // section version
        const byte_len = try r.int(u64);
        if (byte_len > buf.len) return SaveError.Truncated; // guard the add below against overflow
        const section_end = r.pos + @as(usize, @intCast(byte_len));
        if (section_end > buf.len) return SaveError.Truncated;
        if (sectionTagFromInt(tag_raw) == null) return SaveError.InvalidTag;
        r.pos = section_end;
    }
}

/// Applies a save blob: walks the sections and dispatches each to its reader.
/// The framing length is trusted so a reader consuming the wrong amount can't desync the stream.
/// Precondition: `validate()` passed on `buf`, and the game has been reset via `startup.init(false)`.
fn deserialize(buf: []const u8) !void {
    // Clean up our temporary remapping table after import finishes.
    defer {
        id_remap.deinit(save_alloc);
        id_remap = .empty;
    }

    var r: Reader = .{ .buf = buf, .pos = MAGIC.len };
    _ = try r.int(u32); // format version, already checked by validate()

    while (true) {
        const tag_raw = try r.int(u16);
        if (tag_raw == @intFromEnum(SectionTag.end)) break;
        const section_version = try r.int(u16);
        _ = section_version; // unused for now
        const byte_len = try r.int(u64);
        const section_end = r.pos + @as(usize, @intCast(byte_len));
        if (section_end > buf.len) return SaveError.Truncated;

        const tag = sectionTagFromInt(tag_raw) orelse {
            return SaveError.InvalidTag;
        };
        switch (tag) {
            .sprite_table => try readSpriteTable(&r),
            .header_core => try readHeaderCore(&r, @intCast(byte_len)),
            .quadcache => try readQuadCache(&r),
            .inventory => try readInventory(&r),
            .menus => try readMenus(&r),
            .tools => try readTools(&r),
            .misc => try readMisc(&r),
            .mod_store => try readModStore(&r),
            .end => unreachable,
        }
        // trust the framing length even if a reader consumed a different amount
        r.pos = section_end;
    }
}

/// Byte length of the finished save buffer (valid after `exportAll()` or a completed snapshot).
pub fn getExportLen() usize {
    return save_buf.items.len;
}

/// One modified chunk to serialize: its `DepthCoordinate` key and its index into `mod_store.history`.
const PlanEntry = struct { key: DepthCoordinate, idx: usize };

/// Byte size of one serialized MOD_STORE chunk record: the `DepthCoordinate` key (u64 x3 + u32) plus every block verbatim.
/// Must match what `writeBatchInner()` emits; `beginSnapshotInner()` precomputes the section length from it so the stream is never backpatched and stays hashable strictly in order.
const CHUNK_RECORD_BYTES: u64 = 8 + 8 + 8 + 4 + @sizeOf(@FieldType(Chunk, "blocks"));

/// Number of bytes `Writer.varint()` emits for `value`.
fn varintLen(value: u64) u64 {
    var x = value;
    var n: u64 = 1;
    while (x >= 0x80) : (x >>= 7) n += 1;
    return n;
}

var plan: std.ArrayList(PlanEntry) = .empty;
var plan_cursor: usize = 0;
/// Offset of the MOD_STORE section's length field in `save_buf` (precomputed; kept only for the finalize assert).
var mod_store_len_off: usize = 0;
/// Incremental BLAKE3 over the snapshot stream, fed batch-by-batch so finalizing never rehashes the whole blob in one frame.
var snapshot_hasher: std.crypto.hash.Blake3 = undefined;
/// Bytes of `save_buf` already fed to `snapshot_hasher`.
var hashed_upto: usize = 0;
/// `mod_store.generation` captured at `beginSnapshot()`; a change aborts the in-flight snapshot.
var snapshot_gen: u64 = 0;
var snapshot_active: bool = false;

/// `mod_store.history.len` at `beginSnapshot()`. Chunks at indices below this are in the plan;
/// any appended after are new mods excluded from this snapshot and never need shadowing.
var snapshot_history_len: usize = 0;
/// Copy-on-write side store: `history` index -> that chunk's contents at snapshot start, filled by
/// `shadowChunkForSave()` the first time the game touches a still-unencoded planned chunk.
var shadow: std.AutoHashMapUnmanaged(usize, Chunk) = .empty;

/// Starts a budgeted snapshot: resets `save_buf`, writes the header and small sections, opens MOD_STORE and freezes the modified-chunk plan.
/// Returns the number of chunks to write (feed to `writeBatch()`), or -1 on failure.
pub fn beginSnapshot() i64 {
    plan.clearRetainingCapacity();
    shadow.clearRetainingCapacity();
    plan_cursor = 0;
    save_buf.clearRetainingCapacity();
    snapshot_active = false;

    beginSnapshotInner() catch |err| {
        logger.err(@src(), "Save snapshot begin failed: {s}", .{@errorName(err)});
        return -1;
    };

    if (plan.items.len == 0) {
        var w: Writer = .{ .list = &save_buf };
        finalizeSnapshot(&w) catch |err| {
            logger.err(@src(), "Save finalize failed: {s}", .{@errorName(err)});
            return -1;
        };
        snapshot_active = false;
    } else {
        snapshot_active = true;
    }

    return @intCast(plan.items.len);
}

fn beginSnapshotInner() !void {
    var w: Writer = .{ .list = &save_buf };
    try w.bytes(MAGIC);
    try w.int(u32, VERSION);

    try writeSpriteTable(&w);
    try writeHeaderCore(&w);
    try writeQuadCache(&w);
    try writeInventory(&w);
    try writeMenus(&w);
    try writeTools(&w);
    try writeMisc(&w);

    snapshot_history_len = world.mod_store.history.len;
    var it = world.mod_store.index.iterator();
    while (it.next()) |entry| {
        try plan.append(save_alloc, .{ .key = entry.key_ptr.*, .idx = entry.value_ptr.* });
    }

    // open the MOD_STORE section with its exact length precomputed from the fixed record size,
    // so nothing needs backpatching and the stream can be hashed strictly in order
    try w.int(u16, @intFromEnum(SectionTag.mod_store));
    try w.int(u16, 1); // section version
    mod_store_len_off = save_buf.items.len;
    try w.int(u64, varintLen(plan.items.len) + plan.items.len * CHUNK_RECORD_BYTES);
    try w.varint(plan.items.len);
    snapshot_gen = world.mod_store.generation;

    snapshot_hasher = std.crypto.hash.Blake3.init(.{});
    snapshot_hasher.update(save_buf.items);
    hashed_upto = save_buf.items.len;
}

/// NOTE: MUST BE CALLED WHEN MOD_STORE IS MUTATED THROUGH `.at()` ACCESS BEFORE MODIFICATION!
/// Preserves a planned chunk's snapshot-start contents before the game mutates it, so the in-flight save stays coherent at start-time.
/// Called from the world's block-mutation paths with the chunk's `history` index; no-op unless a snapshot is active and the chunk is still unencoded.
pub fn shadowChunkForSave(idx: usize) void {
    if (!snapshot_active) return;
    if (idx >= snapshot_history_len) return; // appended after the snapshot began; not planned
    if (shadow.contains(idx)) return; // already preserved at its start-of-snapshot state
    const preserved = world.mod_store.history.at(idx).*;
    shadow.put(save_alloc, idx, preserved) catch {
        // can't preserve it -> abort rather than emit an incoherent save
        snapshot_active = false;
    };
}

/// Encodes more chunks of the frozen plan into `save_buf`.
/// Returns the number of chunks still remaining (0 once the snapshot is finalized and ready to read),
/// or -1 on abort/error. Safe to call once per frame until it returns 0.
pub fn writeBatch(max_chunks: usize) i64 {
    if (!snapshot_active) return -1;
    if (world.mod_store.generation != snapshot_gen) {
        snapshot_active = false;
        return -1;
    }

    var w: Writer = .{ .list = &save_buf };
    writeBatchInner(&w, max_chunks) catch |err| {
        logger.err(@src(), "Save batch failed: {s}", .{@errorName(err)});
        snapshot_active = false;
        return -1;
    };
    snapshot_hasher.update(save_buf.items[hashed_upto..]);
    hashed_upto = save_buf.items.len;

    const remaining = plan.items.len - plan_cursor;
    if (remaining == 0) {
        finalizeSnapshot(&w) catch |err| {
            logger.err(@src(), "Save finalize failed: {s}", .{@errorName(err)});
            snapshot_active = false;
            return -1;
        };
        snapshot_active = false;
    }
    return @intCast(remaining);
}

fn writeBatchInner(w: *Writer, max_chunks: usize) !void {
    const end = @min(plan_cursor + max_chunks, plan.items.len);
    while (plan_cursor < end) : (plan_cursor += 1) {
        const e = plan.items[plan_cursor];
        // prefer the copy-on-write snapshot if the game has since touched this chunk
        const chunk: *const Chunk = if (shadow.getPtr(e.idx)) |c| c else world.mod_store.history.at(e.idx);
        try w.int(u64, e.key.suffix[0]);
        try w.int(u64, e.key.suffix[1]);
        try w.int(u64, e.key.depth);
        try w.int(u32, e.key.quadrant);
        try w.bytes(std.mem.sliceAsBytes(chunk.blocks[0..]));
    }
}

fn finalizeSnapshot(w: *Writer) !void {
    // the section length was precomputed in beginSnapshotInner(); verify the batches wrote exactly that
    const stored_len: u64 = @bitCast(save_buf.items[mod_store_len_off..][0..8].*);
    std.debug.assert(stored_len == save_buf.items.len - (mod_store_len_off + 8));

    try w.int(u16, @intFromEnum(SectionTag.end));
    snapshot_hasher.update(save_buf.items[hashed_upto..]);
    var hash_buf: [32]u8 = undefined;
    snapshot_hasher.final(&hash_buf);
    try w.bytes(&hash_buf);
}
