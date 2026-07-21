//! ASCII-art layout tables for structures with DELIBERATE, fixed shapes.
//!
//! A structure draws its footprint as a multiline string and hands over a legend mapping each character to what it places.
//! The whole thing is parsed and validated at compile-time!
//!
//! This is for shapes where placement is intentional (a room, a vestibule, a chest alcove).
//! Organic or size-varying shapes (a geode's rolled disc) stay as math in `generate()`; the two coexist.
//!
//! Conventions:
//! - A space is GUARANTEED AIR by default unless there's an override `legend`.
//! - Every other character in the `art` must be defined in the `legend`.
//! - Rows must all be the same length (this means space padding is needed).
//! - `resolve()` returning null can mean the the structure's fallback/terrain falls through depending on usage.
const std = @import("std");
const dw = @import("../root.zig");
const structures = @import("structures.zig");
const Sprite = dw.Sprite;
const StructureResult = structures.StructureResult;

/// What one character places. Kept deliberately small; correlated/random cells can layer on later.
pub const Cell = union(enum) {
    /// Not part of the structure: `resolve()` yields null so the fallback or terrain shows through.
    skip,
    /// Place this sprite, letting `base_id` fall back to the terrain it replaced.
    block: Sprite,
    /// Place a fully specified result (sprite + explicit `base` underlay + starting `water_volume`).
    full: StructureResult,
};

/// One legend row: the character `ch` places `cell`.
pub const Entry = struct { ch: u8, cell: Cell };

/// The default for a space when the legend does not mention it: guaranteed air.
const DEFAULT_SPACE: Cell = .{ .block = .none };

/// Builds a compile-time layout table from `art` and `legend`.
///
/// Returns a type exposing `width`, `height`, `covers()`, and `resolve()`.
/// A structure's `generate()` converts world coordinates to template-local ones and calls `resolve()`.
pub fn Template(comptime art: []const u8, comptime legend: []const Entry) type {
    const parsed = comptime parse(art, legend);

    return struct {
        /// Footprint width in blocks (every row is this long).
        pub const width: i32 = parsed.width;
        /// Footprint height in blocks (number of rows).
        pub const height: i32 = parsed.height;

        /// The `Cell` at template-local (`lx`, `ly`), or null when outside the grid.
        pub inline fn at(lx: i32, ly: i32) ?Cell {
            if (lx < 0 or ly < 0 or lx >= width or ly >= height) return null;
            const ch = parsed.grid[@intCast(ly * width + lx)];
            // legend is comptime and tiny, so this lowers to a jump table.
            inline for (parsed.entries) |e| {
                if (ch == e.ch) return e.cell;
            }
            unreachable; // parse() proved every grid character is in the legend
        }

        /// True when (`lx`, `ly`) is a block the structure OCCUPIES (in bounds and not `skip`).
        /// This is the shape predicate `Encase` and shell logic want, derived straight from the art.
        pub inline fn covers(lx: i32, ly: i32) bool {
            const cell = at(lx, ly) orelse return false;
            return cell != .skip;
        }

        /// The `StructureResult` for template-local (`lx`, `ly`), or null to defer to the fallback/terrain.
        pub inline fn resolve(lx: i32, ly: i32) ?StructureResult {
            const cell = at(lx, ly) orelse return null;
            return switch (cell) {
                .skip => null,
                .block => |s| .{ .id = s },
                .full => |r| r,
            };
        }
    };
}

/// Comptime parse result: the normalized grid and the resolved legend (space default folded in).
const Parsed = struct {
    width: i32,
    height: i32,
    grid: []const u8,
    entries: []const Entry,
};

/// Validates `art` against `legend` and normalizes it into a rectangular grid.
/// Every failure here is a `@compileError` naming exactly what is wrong and where.
fn parse(comptime art: []const u8, comptime legend: []const Entry) Parsed {
    @setEvalBranchQuota(100000);

    // Reject a duplicate legend character up front: an ambiguous legend is never intended.
    for (legend, 0..) |a, i| {
        for (legend[i + 1 ..]) |b| {
            if (a.ch == b.ch) @compileError("template legend lists '" ++ [_]u8{a.ch} ++ "' twice");
        }
    }

    // Fold in the space default unless the legend already speaks for it.
    const has_space = blk: {
        for (legend) |e| {
            if (e.ch == ' ') break :blk true;
        }
        break :blk false;
    };
    const entries: []const Entry = if (has_space) legend else legend ++ &[_]Entry{.{ .ch = ' ', .cell = DEFAULT_SPACE }};

    // Split into rows, dropping a single trailing newline so `\\...` blocks read naturally.
    const body = if (art.len > 0 and art[art.len - 1] == '\n') art[0 .. art.len - 1] else art;
    var rows: []const []const u8 = &.{};
    var start: usize = 0;
    for (body, 0..) |c, i| {
        if (c == '\n') {
            rows = rows ++ &[_][]const u8{body[start..i]};
            start = i + 1;
        }
    }
    rows = rows ++ &[_][]const u8{body[start..]};
    if (rows.len == 0) @compileError("template art is empty");

    const w = rows[0].len;
    if (w == 0) @compileError("template row 0 is empty");

    // Every row must match row 0's width; a ragged row is a mistake, not padding.
    var grid: []const u8 = &.{};
    for (rows, 0..) |row, ry| {
        if (row.len != w) @compileError(std.fmt.comptimePrint(
            "template row {d} is {d} chars but row 0 is {d}; rows must be equal length",
            .{ ry, row.len, w },
        ));
        for (row, 0..) |ch, rx| {
            var known = false;
            for (entries) |e| {
                if (e.ch == ch) {
                    known = true;
                    break;
                }
            }
            if (!known) @compileError(std.fmt.comptimePrint(
                "template char '{c}' at row {d}, col {d} is not in the legend",
                .{ ch, ry, rx },
            ));
        }
        grid = grid ++ row;
    }

    return .{
        .width = @intCast(w),
        .height = @intCast(rows.len),
        .grid = grid,
        .entries = entries,
    };
}

const testing = std.testing;

test "template parses, resolves, and reports shape" {
    const T = Template(
        \\####
        \\#..#
        \\#P.#
        \\####
    , &.{
        .{ .ch = '#', .cell = .{ .block = .black_plate } },
        .{ .ch = '.', .cell = .skip },
        .{ .ch = 'P', .cell = .{ .block = .portal } },
    });

    try testing.expectEqual(@as(i32, 4), T.width);
    try testing.expectEqual(@as(i32, 4), T.height);

    // Corner is wall.
    try testing.expectEqual(Sprite.black_plate, T.resolve(0, 0).?.id);
    // Interior '.' is skip -> null -> terrain shows through.
    try testing.expectEqual(@as(?StructureResult, null), T.resolve(1, 1));
    // The portal.
    try testing.expectEqual(Sprite.portal, T.resolve(1, 2).?.id);
    // Out of bounds is null.
    try testing.expectEqual(@as(?StructureResult, null), T.resolve(-1, 0));
    try testing.expectEqual(@as(?StructureResult, null), T.resolve(4, 0));

    // covers() is the occupied-shape predicate: walls and portal yes, skip and out-of-bounds no.
    try testing.expect(T.covers(0, 0));
    try testing.expect(T.covers(1, 2));
    try testing.expect(!T.covers(1, 1));
    try testing.expect(!T.covers(-1, 0));
}

test "space defaults to guaranteed air" {
    const T = Template(
        \\# #
        \\###
    , &.{
        .{ .ch = '#', .cell = .{ .block = .black_plate } },
    });
    // The space became .none (guaranteed air), which is placed, not skipped.
    const mid = T.resolve(1, 0);
    try testing.expect(mid != null);
    try testing.expectEqual(Sprite.none, mid.?.id);
    try testing.expect(T.covers(1, 0)); // air is still "occupied" (it actively clears terrain)
}
