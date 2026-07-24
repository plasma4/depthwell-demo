//! NOTE: This game is pre-demo so all saves can break at any time from core logic changes!
//! Forward-compatibility is never planned, only back.
//!
//! Serializes the full game state to a versioned, self-describing binary blob for the OPFS/generic file-system host.
//! The atomic OPFS write and per-frame budgeting are handled by JS.
//!
//! Sprite and tool identities are stored by name, never by enum ordinal, so adding or reordering sprites never invalidates a save.
//! `SPRITE_TABLE` maps the raw IDs embedded in `MOD_STORE` cells back to names,
//! which the loader resolves against the current game's `Sprite` (unknown names degrade to `.none`).
//! (This means versions don't need to be incremented at all after modifying `Sprite`.)
//!
//! `MOD_STORE` holds only the cells the player modified, not whole chunks: everything else in a chunk is regenerated on load
//! (see `world.materializeChunk()`). A record is therefore variable-length.
//!
//! Little-endian format:
//! - magic "DWSV" | `VERSION` u32
//! - sections, repeated: tag u16 enum | section_version u16 | byte_len u64 | payload[byte_len]
//! - end marker: tag `.end` (also u16, 0)
//! - BLAKE3 32-byte hash over every preceding byte
//!
//!
//! Process for importing:
//! - `beginSnapshot()` writes the header and every small section (all captured at start), opens the MOD_STORE section,
//!   and freezes a plan (the key + entry index of each modified chunk).
//! - `writeBatch()` then encodes up to N chunks per call. To keep the save atomic (handled partially by JS OPFS operations),
//!   whenever the game mutates a planned entry before it has been encoded,
//!   `shadowEntryForSave()` first serializes that entry's start-of-snapshot payload into a side map.
//! - A wipe of `mod_store` mid-snapshot (from new game or load) bumps its generation and aborts.
comptime {
    if (@import("builtin").cpu.arch.endian() != .little) {
        @compileError("Depthwell only works in little-endian architectures");
    }
}

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
const DepthCoordinate = world.DepthCoordinate;

/// Magic 4-byte header.
const MAGIC = "DWSV";

/// Current version of the game.
/// NOTE: since the game is pre-demo, arbitrary changes can be made to the save logic.
/// Version should be kept at 0.0.0, and back-compat can be disregarded!
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
    ascent_stack,
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

/// Category of the most recent failed import, for the host to show the player once.
/// 0 means the last import succeeded. This mapping is mirrored by `IMPORT_ERROR_LABELS` in `saveManager.ts`;
/// keep the two in sync when adding a `SaveError`.
var last_import_error: u32 = 0;

fn setImportError(err: anyerror) void {
    last_import_error = switch (err) {
        error.Truncated => 1,
        error.BadMagic => 2,
        error.UnsupportedVersion => 3,
        error.InvalidTag => 4,
        error.BadData => 5,
        error.OutOfMemory => 6,
        else => 0,
    };
}

/// The category code of the most recent import failure (0 = none),
/// This is read by the host after a failed load.
pub fn lastImportError() u32 {
    return last_import_error;
}

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
    if (id_remap.get(old_id)) |s| return s;
    return .none;
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
    for (0..@intCast(n)) |_| {
        const old_id = try r.int(u16);
        const name = try r.str();
        if (spriteFromName(name)) |s| {
            try id_remap.put(save_alloc, old_id, s);
        }
    }
    if (id_remap.count() == 0) return SaveError.BadData;
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

/// Section version for the quad cache. Bumped when `QuadCache.ANCESTOR_GRID` changed the size of
/// `ancestor_materials`, since the payload is written as raw bytes and carries no shape of its own.
/// v3 appends `materials_path` (what each depth's horizon window is recovered from).
const QUADCACHE_VERSION = 3;

/// Tag for the `materials_mode` the save was written under, so a blob from a build with the other
/// strategy is refused rather than read as garbage: the two store different types in the same slot.
fn materialsModeTag() u8 {
    return @intFromEnum(world.materials_mode);
}

/// Exports quad cache (fractal descent state; raw internal fields + the path lists)
fn writeQuadCache(w: *Writer) !void {
    const at = try w.beginSection(.quadcache, QUADCACHE_VERSION);
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

    std.debug.assert(qc.left_path.len == qc.top_path.len);
    const len = qc.left_path.len;
    try w.varint(len);
    for (0..len) |i| try w.int(u64, qc.left_path.at(i).*);
    for (0..len) |i| try w.int(u64, qc.top_path.at(i).*);

    try w.int(u8, materialsModeTag());
    const materials_len = qc.materials_path.len;
    try w.varint(materials_len);
    for (0..materials_len) |i| try w.bytes(std.mem.asBytes(qc.materials_path.at(i)));

    w.endSection(at);
}

fn readQuadCache(r: *Reader, section_version: u16) !void {
    // v1 stored a 4x4 `ancestor_materials`; v2 stores `QuadCache.ANCESTOR_GRID` square. The framing
    // length keeps the stream aligned either way, so a blind read would not fail, it would just fill
    // the descent state with whatever followed. Refuse instead.
    if (section_version != QUADCACHE_VERSION) return SaveError.BadData;

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

    // prealloc-all-at-once pattern
    // we actually do NOT need to clear the old data, if applicable
    // only set the new data
    const path_len: usize = @intCast(try r.varint());
    if (path_len > qc.left_path.prealloc_segment.len) {
        // for some goofy reason there's an assert trigger if path len is 0
        try qc.left_path.growCapacity(world.alloc, path_len);
        try qc.top_path.growCapacity(world.alloc, path_len);
    }

    qc.left_path.len = path_len;
    for (0..path_len) |i| {
        qc.left_path.at(i).* = try r.int(u64);
    }

    qc.top_path.len = path_len;
    for (0..path_len) |i| {
        qc.top_path.at(i).* = try r.int(u64);
    }

    // Refuse a save written by a build using the other materials strategy: the slots below are a
    // different type entirely, and reading them blind would fill the descent state with noise.
    if (try r.int(u8) != materialsModeTag()) return SaveError.BadData;

    const materials_len: usize = @intCast(try r.varint());
    if (materials_len > qc.materials_path.prealloc_segment.len) {
        try qc.materials_path.growCapacity(world.alloc, materials_len);
    }
    qc.materials_path.len = materials_len;
    for (0..materials_len) |i| {
        try r.readInto(std.mem.asBytes(qc.materials_path.at(i)));
    }
}

/// Writes the ascent stack (the blocks the player has ascended past, deepest last).
/// Present but empty when the player is at their deepest depth; its length is what puts the game into
/// read-only spectating mode on load (see `world.isSpectating()`).
fn writeAscentStack(w: *Writer) !void {
    const at = try w.beginSection(.ascent_stack, 1);
    const stack = world.ascent_stack.items;
    try w.varint(stack.len);
    for (stack) |step| {
        try w.int(u64, step.suffix[0]);
        try w.int(u64, step.suffix[1]);
        try w.int(u8, step.quadrant);
        try w.int(i64, step.origin_pos[0]);
        try w.int(i64, step.origin_pos[1]);
    }
    w.endSection(at);
}

fn readAscentStack(r: *Reader) !void {
    world.ascent_stack.clearRetainingCapacity();
    const n = try r.varint();
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        try world.ascent_stack.append(memory.main_allocator, .{
            .suffix = .{ try r.int(u64), try r.int(u64) },
            .quadrant = @intCast(try r.int(u8) & 3),
            .origin_pos = .{ try r.int(i64), try r.int(i64) },
        });
    }
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
    for (0..@intCast(n)) |_| {
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
    for (0..@intCast(owned)) |i| {
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

// MOD_STORE record (section version 3), per modified chunk:
//   key         : suffix[0] u64 | suffix[1] u64 | depth u64 | quadrant u32 (28 bytes)
//   flags       : u8 (bit 0: a `descendants` bitmap follows)
//   descendants : [CHUNK_SIZE_SQ / 64]u64  (32 bytes; only present when the flag bit is set)
//   modified    : [CHUNK_SIZE_SQ / 64]u64  (32 bytes; which cells the player owns)
//   cells       : PackedCell (u32), once per set bit, ascending            (4 bytes each)
// The cell count is the population count of `modified`, so it is never stored twice. Most entries
// carry no descendant markers, so they pay one flag byte rather than a whole empty bitmap.
// Sprite IDs are remapped through SPRITE_TABLE on load based on enum names!

/// `flags` bit marking that a 32-byte `descendants` bitmap follows the flag byte.
const MOD_FLAG_DESCENDANTS: u8 = 1;

/// Bytes one modified cell occupies on disk.
const MOD_CELL_BYTES: u64 = @sizeOf(PackedCell);
/// Bytes of a record's fixed key prefix.
const MOD_KEY_BYTES: u64 = 8 + 8 + 8 + 4;
/// Bytes of a record's `modified` (or `descendants`) bitmap.
const MOD_MODIFIED_BYTES: u64 = @sizeOf(@FieldType(world.ModEntry, "modified"));

/// Whether an entry carries any descendant markers (and so serializes the extra bitmap).
fn hasDescendants(entry: *const world.ModEntry) bool {
    for (entry.descendants) |w| {
        if (w != 0) return true;
    }
    return false;
}

/// Bytes the payload (everything after the key) of one entry serializes to.
fn entryPayloadBytes(entry: *const world.ModEntry) u64 {
    const desc: u64 = if (hasDescendants(entry)) MOD_MODIFIED_BYTES else 0;
    return 1 + desc + MOD_MODIFIED_BYTES + @as(u64, entry.count) * MOD_CELL_BYTES;
}

fn writeEntryKey(w: *Writer, key: DepthCoordinate) !void {
    try w.int(u64, key.suffix[0]);
    try w.int(u64, key.suffix[1]);
    try w.int(u64, key.depth);
    try w.int(u32, key.quadrant);
}

/// Writes an entry's payload: a flag byte, the optional descendants bitmap, the modified bitmap,
/// then each modified cell in ascending block-index order.
fn writeEntryPayload(w: *Writer, entry: *const world.ModEntry) !void {
    const has_desc = hasDescendants(entry);
    try w.int(u8, if (has_desc) MOD_FLAG_DESCENDANTS else 0);
    if (has_desc) try w.bytes(std.mem.asBytes(&entry.descendants));

    try w.bytes(std.mem.asBytes(&entry.modified));

    var packed_cells: [dw.CHUNK_SIZE_SQ]u32 = undefined;
    for (entry.cells[0..entry.count], 0..) |cell, i| {
        const packed_cell: PackedCell = .{
            .id = @intCast(@intFromEnum(cell.id)),
            .base_id = @intCast(@intFromEnum(cell.base_id)),
            .hp = @intCast(cell.hp),
        };
        packed_cells[i] = @bitCast(packed_cell);
    }
    try w.bytes(std.mem.sliceAsBytes(packed_cells[0..entry.count]));
}

/// Serializes every chunk the player has modified, keyed by its `DepthCoordinate`.
/// Reads the index/entries live (non-budgeted).
fn writeModStore(w: *Writer) !void {
    const at = try w.beginSection(.mod_store, 3);
    try w.varint(world.mod_store.index.count());

    var it = world.mod_store.index.iterator();
    while (it.next()) |e| {
        try writeEntryKey(w, e.key_ptr.*);
        try writeEntryPayload(w, world.mod_store.entries.at(e.value_ptr.*));
    }
    w.endSection(at);
}

/// Returns the exact `MOD_STORE` payload size, excluding its section header.
/// This lets callers reserve the final output space before the high-volume entry writes begin.
fn modStorePayloadBytes() u64 {
    var payload_len: u64 = varintLen(world.mod_store.index.count());
    var it = world.mod_store.index.iterator();
    while (it.next()) |entry| {
        payload_len += MOD_KEY_BYTES + entryPayloadBytes(world.mod_store.entries.at(entry.value_ptr.*));
    }
    return payload_len;
}

/// Rebuilds `mod_store` from the saved records.
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

        const flags = try r.int(u8);
        var descendants: @FieldType(world.ModEntry, "descendants") = @splat(0);
        if (flags & MOD_FLAG_DESCENDANTS != 0) {
            for (&descendants) |*word| word.* = try r.int(u64);
        }

        var modified: @FieldType(world.ModEntry, "modified") = undefined;
        var count: usize = 0;
        for (&modified) |*word| {
            word.* = try r.int(u64);
            count += @popCount(word.*);
        }

        var cells: [dw.CHUNK_SIZE_SQ]world.ModCell = undefined;
        for (cells[0..count]) |*cell| {
            const packed_cell: PackedCell = @bitCast(try r.int(u32));
            cell.id = remapSpriteId(@intCast(packed_cell.id));
            cell.base_id = remapSpriteId(@intCast(packed_cell.base_id));
            cell.hp = @intCast(packed_cell.hp);
            if (cell.hp > Block.MAX_HP) return SaveError.BadData;
        }

        try world.mod_store.loadEntry(key, modified, descendants, cells[0..count]);
    }
}

const PackedCell = packed struct(u32) {
    id: u14,
    base_id: u14,
    hp: u4,
};

/// True while `handleTick()` is executing; set/cleared by `tick()` in `root.zig` and cleared again by `startup.init()`.
/// A panic/trap mid-tick leaves it set, so `exportAll()` and `beginSnapshot()` refuse to serialize the half-applied tick forever
/// (an older intact save beats a torn one; page-close saves hit the same guard).
pub var in_tick: bool = false;

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
    try writeAscentStack(w);

    // Reserve the exact large section plus the end marker and checksum.
    // This avoids repeated ArrayList growth/copying while modified cells are added.
    const mod_store_len = modStorePayloadBytes();
    const reserve_len: usize = @intCast(@as(u64, w.list.items.len) + 12 + mod_store_len + 2 + 32);
    try w.list.ensureTotalCapacity(save_alloc, reserve_len);
    try writeModStore(w);

    try w.int(u16, @intFromEnum(SectionTag.end));

    var hash_buf: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(w.list.items, &hash_buf, .{});
    try w.bytes(&hash_buf);
}

/// Serializes the entire game state into `save_buf`. Returns the byte length, or 0 on failure.
/// Refuses while `in_tick` is set: the state is then not at a tick boundary and must never be persisted.
pub fn exportAll() usize {
    if (in_tick) {
        logger.err(@src(), "Refusing to export: a logical tick never finished (state is torn)!", .{});
        return 0;
    }
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
        setImportError(error.OutOfMemory);
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
        setImportError(err);
        logger.err(@src(), "Save validation failed: {s}", .{@errorName(err)});
        return false;
    };
    dw.startup.init(false);
    deserialize(buf) catch |err| {
        setImportError(err);
        logger.err(@src(), "Save import failed: {s}", .{@errorName(err)});
        return false;
    };
    last_import_error = 0;
    return true;
}

/// Rebuilds the derived state `importAll()` does not store and repopulates the `SimBuffer`
/// (so the restored world is visible immediately). Call after `importAll()`.
pub fn finalizeLoad() void {
    const g = &memory.game;

    // seed2 and the sound/particle rngs derived from the seed are already saved!
    // var temp_seed = dw.seeding.ChaCha12.init(&dw.seeding.mixBaseSeed(g.seed, .seed2_init));
    // inline for (&g.seed2) |*s| s.* = temp_seed.next();
    dw.sound.seed = dw.seeding.ChaCha12.init(&dw.seeding.mixBaseSeed(g.seed, .sound));
    dw.particles.seed = dw.seeding.ChaCha12.init(&dw.seeding.mixBaseSeed(g.seed, .particles));
    dw.chunks.shake_seed = dw.seeding.ChaCha12.init(&dw.seeding.mixBaseSeed(g.seed, .screen_shake));

    world.max_possible_suffix = world.getMaxSuffixAtDepth(g.depth);

    // repopulate the SimBuffer around the player using the newly loaded state
    world.SimBuffer.sync(g.getPlayerCoord(), .{ 0, 0 });

    // A save taken mid-descent stores the world at D plus the frame counter; everything else the
    // animation needs (the D+1 transition and its preview buffer) is derived, so rebuild it here.
    // Must follow the SimBuffer sync: generating D+1 reads the D chunks it descends from.
    dw.portal.restore();

    // A save can land between a water-adjacent block change and the next tick's batched flag recompute
    // (see queueWaterFlags()), baking stale/sentinel edge flags into the stored blocks.
    // So, re-queuing every water chunk so those flags heal on the first tick after a load is needed.
    var cy: usize = 0;
    while (cy < world.SIM_BUFFER_WIDTH) : (cy += 1) {
        var cx: usize = 0;
        while (cx < world.SIM_BUFFER_WIDTH) : (cx += 1) {
            if (world.SimBuffer.has_water.isSet(world.SimBuffer.getIndex(@intCast(cx), @intCast(cy)))) {
                dw.water.queueWaterFlags(@intCast(cx), @intCast(cy));
            }
        }
    }
}

/// Structurally validates a save blob without touching any game state: magic, BLAKE3 hash, format version, and section framing
/// (known tags, in-bounds lengths, end marker reached).
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
        const byte_len = try r.int(u64);
        const section_end = r.pos + @as(usize, @intCast(byte_len));
        if (section_end > buf.len) return SaveError.Truncated;

        const tag = sectionTagFromInt(tag_raw) orelse {
            return SaveError.InvalidTag;
        };
        switch (tag) {
            .sprite_table => try readSpriteTable(&r),
            .header_core => try readHeaderCore(&r, @intCast(byte_len)),
            .quadcache => try readQuadCache(&r, section_version),
            .inventory => try readInventory(&r),
            .menus => try readMenus(&r),
            .tools => try readTools(&r),
            .misc => try readMisc(&r),
            .mod_store => try readModStore(&r),
            .ascent_stack => try readAscentStack(&r),
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

/// One modified chunk to serialize: its `DepthCoordinate` key and its index into `mod_store.entries`.
const PlanEntry = struct { key: DepthCoordinate, idx: usize };

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

/// `mod_store.entries.len` at `beginSnapshot()`. Entries at indices below this are in the plan;
/// any appended after are new mods excluded from this snapshot and never need shadowing.
var snapshot_entries_len: usize = 0;
/// Copy-on-write side store: `entries` index -> that entry's payload, already serialized, as of snapshot
/// start. Filled by `shadowEntryForSave()` the first time the game touches a still-unencoded planned entry.
///
/// Storing encoded bytes rather than a copy of the entry keeps the preserved size fixed, which is what lets
/// `beginSnapshotInner()` precompute the section length even though entries grow as the player keeps editing.
var shadow: std.AutoHashMapUnmanaged(usize, []u8) = .empty;

/// Drops every preserved payload. `shadow` owns its values, unlike the old whole-`Chunk` map.
fn clearShadow() void {
    var it = shadow.valueIterator();
    while (it.next()) |bytes| save_alloc.free(bytes.*);
    shadow.clearRetainingCapacity();
}

/// Starts a budgeted snapshot: resets `save_buf`, writes the header and small sections, opens MOD_STORE and freezes the modified-chunk plan.
/// Returns the number of chunks to write (feed to `writeBatch()`), or -1 on failure.
/// Refuses while `in_tick` is set (see `exportAll()`).
pub fn beginSnapshot() i64 {
    if (in_tick) {
        logger.err(@src(), "Refusing to snapshot: a logical tick never finished (state is torn)!", .{});
        return -1;
    }
    plan.clearRetainingCapacity();
    clearShadow();
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
    try writeAscentStack(&w);

    snapshot_entries_len = world.mod_store.entries.len;
    var it = world.mod_store.index.iterator();
    while (it.next()) |entry| {
        try plan.append(save_alloc, .{ .key = entry.key_ptr.*, .idx = entry.value_ptr.* });
    }

    // open the MOD_STORE section with its exact length precomputed, no backpatching needed
    var payload_len: u64 = varintLen(plan.items.len);
    for (plan.items) |e| {
        payload_len += MOD_KEY_BYTES + entryPayloadBytes(world.mod_store.entries.at(e.idx));
    }

    const reserve_len: usize = @intCast(@as(u64, save_buf.items.len) + 12 + payload_len + 2 + 32);
    try save_buf.ensureTotalCapacity(save_alloc, reserve_len);

    try w.int(u16, @intFromEnum(SectionTag.mod_store));
    try w.int(u16, 3); // section version
    mod_store_len_off = save_buf.items.len;
    try w.int(u64, payload_len);
    try w.varint(plan.items.len);
    snapshot_gen = world.mod_store.generation;

    snapshot_hasher = std.crypto.hash.Blake3.init(.{});
    snapshot_hasher.update(save_buf.items);
    hashed_upto = save_buf.items.len;
}

/// Preserves a planned entry's snapshot-start payload before the game mutates it, so the in-flight save stays
/// coherent as of the instant it began.
///
/// Do NOT call this directly: `ModificationStore.beginWrite()` is the only way to mutate an entry and it
/// calls this first, so no mutation path can forget to. No-op unless a snapshot is active and the entry is
/// both planned and still unencoded.
pub fn shadowEntryForSave(idx: usize) void {
    if (!snapshot_active) return;
    if (idx >= snapshot_entries_len) return; // appended after the snapshot began; not planned
    if (shadow.contains(idx)) return; // already preserved at its start-of-snapshot state

    const entry = world.mod_store.entries.at(idx);
    const size: usize = @intCast(entryPayloadBytes(entry));

    preserve(idx, entry, size) catch {
        // can't preserve it -> abort rather than emit an incoherent save
        snapshot_active = false;
    };
}

fn preserve(idx: usize, entry: *const world.ModEntry, size: usize) !void {
    var list: std.ArrayList(u8) = try .initCapacity(save_alloc, size);
    errdefer list.deinit(save_alloc);

    var w: Writer = .{ .list = &list };
    try writeEntryPayload(&w, entry);
    // The plan's precomputed section length counted exactly `size` bytes for this entry.
    std.debug.assert(list.items.len == size);

    try shadow.put(save_alloc, idx, try list.toOwnedSlice(save_alloc));
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
        try writeEntryKey(w, e.key);
        // prefer the copy-on-write payload if the game has since touched this entry
        if (shadow.get(e.idx)) |preserved| {
            try w.bytes(preserved);
        } else {
            try writeEntryPayload(w, world.mod_store.entries.at(e.idx));
        }
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

const testing = std.testing;

test "mod_store: encoding/decoding is correct" {
    world.mod_store.init(testing.allocator);
    defer world.mod_store.deinit();

    // dead beef haha
    const key: DepthCoordinate = .{
        .suffix = .{ 0xDEAD, 0xBEEF },
        .depth = 11,
        .quadrant = 2,
    };
    const cells = [_]struct { i: u8, cell: world.ModCell }{
        .{ .i = 0, .cell = .{ .id = .stone, .base_id = .none, .hp = 0 } },
        .{ .i = 77, .cell = .{ .id = .water, .base_id = .none, .hp = 15 } },
        .{ .i = 255, .cell = .{ .id = .none, .base_id = .stone, .hp = 4 } },
    };
    for (cells) |c| world.mod_store.beginWrite(key).setCell(c.i, c.cell);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(save_alloc);
    var w: Writer = .{ .list = &buf };

    const entry = world.mod_store.get(key).?;
    try writeEntryPayload(&w, entry);
    // The precomputed size the snapshot plan budgets must match what the writer actually emits.
    try testing.expectEqual(entryPayloadBytes(entry), buf.items.len);

    // Re-read into a fresh store, exactly as readModStore() does!
    for ([_]Sprite{ .stone, .water, .none }) |s| {
        try id_remap.put(save_alloc, @intFromEnum(s), s);
    }
    defer id_remap.deinit(save_alloc);

    world.mod_store.deinit(); // drop the store we just wrote before re-reading into a fresh one
    world.mod_store.init(testing.allocator);
    var r: Reader = .{ .buf = buf.items };

    const flags = try r.int(u8);
    var descendants: @FieldType(world.ModEntry, "descendants") = @splat(0);
    if (flags & MOD_FLAG_DESCENDANTS != 0) {
        for (&descendants) |*word| word.* = try r.int(u64);
    }

    var modified: @FieldType(world.ModEntry, "modified") = undefined;
    var count: usize = 0;
    for (&modified) |*word| {
        word.* = try r.int(u64);
        count += @popCount(word.*);
    }
    try testing.expectEqual(cells.len, count);

    var decoded: [dw.CHUNK_SIZE_SQ]world.ModCell = undefined;
    for (decoded[0..count]) |*cell| {
        const packed_cell: PackedCell = @bitCast(try r.int(u32));
        cell.id = remapSpriteId(@intCast(packed_cell.id));
        cell.base_id = remapSpriteId(@intCast(packed_cell.base_id));
        cell.hp = @intCast(packed_cell.hp);
    }
    try world.mod_store.loadEntry(key, modified, descendants, decoded[0..count]);

    for (cells) |c| try testing.expectEqual(c.cell, world.mod_store.getCell(key, c.i).?);
    try testing.expectEqual(@as(?world.ModCell, null), world.mod_store.getCell(key, 1));
}

test "mod_store: descendant markers survive an encode/decode round trip" {
    world.mod_store.init(testing.allocator);
    defer world.mod_store.deinit();

    const key: DepthCoordinate = .{ .suffix = .{ 1, 2 }, .depth = 40, .quadrant = 1 };
    world.mod_store.beginWrite(key).setCell(5, .{ .id = .stone, .base_id = .none, .hp = 0 });
    world.mod_store.markDescendant(key, 5);
    world.mod_store.markDescendant(key, 200);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(save_alloc);
    var w: Writer = .{ .list = &buf };
    const entry = world.mod_store.get(key).?;
    try writeEntryPayload(&w, entry);
    try testing.expectEqual(entryPayloadBytes(entry), buf.items.len);

    var r: Reader = .{ .buf = buf.items };
    const flags = try r.int(u8);
    try testing.expect(flags & MOD_FLAG_DESCENDANTS != 0);
    var descendants: @FieldType(world.ModEntry, "descendants") = @splat(0);
    for (&descendants) |*word| word.* = try r.int(u64);
    try testing.expect((descendants[5 >> 6] >> 5) & 1 != 0);
    try testing.expect((descendants[200 >> 6] >> (200 & 63)) & 1 != 0);
}
