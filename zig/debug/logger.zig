//! Contains dedicated code for logging. Use quickWarn to quickly create warnings when testing (using ZLS or native zig test command), and quick to quickly log values to JS. Use the write()/clear() function to write to the 4 corners of the screen with the canvas for JS.
const std = @import("std");
const dw = @import("../root.zig");
const memory = dw.memory;
const is_wasm = dw.is_wasm;

/// Describes the category/severity of the message being sent.
pub const LogCategory = enum(i32) {
    log = 0,
    info = 1,
    warn = 2,
    err = 3,
};

/// Static logging buffer for messaging JS (4KiB).
var logging_buffer: [4096]u8 align(memory.MAIN_ALIGN_BYTES) = undefined;

/// Logging buffer for HTML text elements; split into four parts (total of 4KiB).
var text_buffer: [4096]u8 align(memory.MAIN_ALIGN_BYTES) = undefined;
/// 1KiB text buffer from the `text_buffer`.
const text_1 = text_buffer[0..1024];
/// 1KiB text buffer from the `text_buffer`.
const text_2 = text_buffer[1024..2048];
/// 1KiB text buffer from the `text_buffer`.
const text_3 = text_buffer[2048..3072];
/// 1KiB text buffer from the `text_buffer`.
const text_4 = text_buffer[3072..4096];
/// Represents the lengths of the current strings in each text buffer (rendered to HTML elements).
var text_lengths: [4]usize = .{ 0, 0, 0, 0 };

/// Gets a time in milliseconds. Time is not guaranteed to start from 0 or standard UNIX timestamp when program execution begins.
pub inline fn getTime() f64 {
    if (dw.is_wasm) {
        return dw.jsGetTime();
    } else {
        const ns = std.time.nanoTimestamp();
        return @as(f64, @floatFromInt(ns)) / 1_000_000.0; // wow, fancy _ symbol!
    }
}

// Sends a message (with pointer and length, as well as a message type) to either std.log with the appropriate category or JS.
inline fn message(ptr: [*]const u8, len: usize, message_type: LogCategory) void {
    if (dw.is_wasm) {
        dw.jsMessage(ptr, len, message_type);
    } else {
        const msg_slice = ptr[0..len];
        switch (message_type) {
            .log => std.log.debug("{s}", .{msg_slice}),
            .info => std.log.info("{s}", .{msg_slice}),
            .warn => std.log.warn("{s}", .{msg_slice}),
            .err => std.log.err("{s}", .{msg_slice}),
        }
    }
}

/// Logs a message in JS.
pub inline fn log(comptime src: std.builtin.SourceLocation, fmt: []const u8, args: anytype) void {
    writeLog(src, fmt, args, .log);
}
/// Logs an info message in JS.
pub inline fn info(comptime src: std.builtin.SourceLocation, fmt: []const u8, args: anytype) void {
    writeLog(src, fmt, args, .info);
}
/// Logs a warning message in JS.
pub inline fn warn(comptime src: std.builtin.SourceLocation, fmt: []const u8, args: anytype) void {
    writeLog(src, fmt, args, .warn);
}
/// Logs an error message in JS.
pub inline fn err(comptime src: std.builtin.SourceLocation, fmt: []const u8, args: anytype) void {
    writeLog(src, fmt, args, .err);
}

inline fn writeLog(comptime src: std.builtin.SourceLocation, fmt: []const u8, args: anytype, log_category: LogCategory) void {
    // Add source as comptime. WASM handles the [...url... part of the string
    const prefix_fmt = if (dw.is_wasm) "{s}:{d}:{d}] " else "[zig/{s}:{d}:{d}] ";
    const prefix = std.fmt.comptimePrint(prefix_fmt, .{ src.file, src.line, src.column });
    const final_fmt = prefix ++ fmt;
    const cutoff = "... [remaining log truncated]";

    if (std.fmt.bufPrint(&logging_buffer, final_fmt, args)) |res| {
        message(res.ptr, res.len, log_category);
    } else |e| {
        // add the cutoff log
        if (e == error.NoSpaceLeft) {
            const safe_ptr = logging_buffer.len - cutoff.len;
            @memcpy(logging_buffer[safe_ptr..], cutoff);
            message(&logging_buffer, logging_buffer.len, log_category);
        }
    }
}

/// A test function for logging, testing all four logging types and truncation.
/// (See `root.zig` for export logic.)
pub inline fn testLogs(skipError: bool) void {
    const logger = @import("logger.zig");
    logger.log(@src(), "This is a {s}.", .{"normal log"});
    logger.info(@src(), "This is an info log.", .{});
    logger.warn(@src(), "This is a warning. You should see this when running tests in Zig, or in the console in JS after running testLogs().", .{});
    if (skipError) {
        logger.err(@src(), "This is an error. Should create an alert() popup if CONFIG.noAlertOnError is false and building for WASM.", .{});
    } else {
        logger.log(@src(), "Skipping error test.", .{});
    }
    var arena = memory.makeArena();
    const allocator = arena.allocator();
    defer arena.deinit();
    var list: std.ArrayList(u8) = .empty;

    list.append(allocator, 'H') catch memory.oom();
    list.append(allocator, 'e') catch memory.oom();
    list.append(allocator, 'l') catch memory.oom();
    list.append(allocator, 'l') catch memory.oom();
    list.append(allocator, 'o') catch memory.oom();
    list.appendSlice(allocator, " World (using ArrayList, within an unnamed struct)!") catch memory.oom();
    logger.quick(.{ "{h}Quick log with header and 3 values", 12.34, "string", .{list} });

    logger.log(@src(), "This log should be multiple lines.\n----\nTesting logging with a truncated string below:", .{});
    // Test truncation by taking a test hex string and making it longer than 4,096 bytes
    const long_data = ("0123456789abcdef" ** (5000 / 16 + 1))[0..5000];
    logger.log(@src(), "{s}", .{long_data});
}

/// Internal helper to format arguments into the logging buffer.
fn quickFmt(args: anytype, prefix: []const u8) usize {
    var writer: std.Io.Writer = .fixed(&logging_buffer);

    writer.print("{s}", .{prefix}) catch {};
    formatArgs(&writer, args) catch {};
    return writer.end;
}

/// Quickly logs a message for testing.
/// Use `logger.log()` with proper arguments for non-temporary/internal test logging.
pub inline fn quick(args: anytype) void {
    const prefix = if (dw.is_wasm) "]" else "";
    const written = quickFmt(args, prefix);
    message(&logging_buffer, written, .log);
}

/// Quickly warns a message for testing.
/// Use `logger.log()` with proper arguments for non-temporary/internal test logging.
pub inline fn quickWarn(args: anytype) void {
    const written = quickFmt(args, "");
    message(&logging_buffer, written, .warn);
}

/// Internal helper to convert an argument of various types to consistent strings.
fn writeValue(writer: anytype, val: anytype) void {
    const T = @TypeOf(val);
    const type_info = @typeInfo(T);

    if (comptime isString(T)) {
        writer.print("{s}", .{val}) catch {};
        return;
    }

    switch (type_info) {
        .int, .comptime_int => {
            writer.print("{d}", .{val}) catch {};
        },
        .float, .comptime_float => {
            writer.print("{d:.3}", .{val}) catch {}; // 3 decimal places
        },
        .bool => {
            writer.print("{}", .{val}) catch {};
        },
        .enum_literal => {
            writer.print("{s}", .{@tagName(val)}) catch {};
        },
        .@"enum" => {
            inline for (type_info.@"enum".fields) |field| {
                if (@intFromEnum(val) == field.value) {
                    writer.print("{s}", .{field.name}) catch {};
                    return;
                }
            }
            writer.print("[Invalid/non-exhaustive enum value {d}]", .{@intFromEnum(val)}) catch {};
        },
        .optional => {
            if (val) |v| {
                writeValue(writer, v);
            } else {
                writer.writeAll("null") catch {};
            }
        },
        .vector => |vector_info| {
            writer.writeAll("(") catch {};
            inline for (0..vector_info.len) |i| {
                if (i > 0) writer.writeAll(", ") catch {};
                writeValue(writer, val[i]);
            }
            writer.writeAll(")") catch {};
        },
        .array => |ptr_info| {
            writer.writeAll("[") catch {};
            for (0..ptr_info.len) |i| {
                if (i > 0) writer.writeAll(", ") catch {};
                writeValue(writer, val[i]);
            }
            writer.writeAll("]") catch {};
        },
        .@"fn" => {
            writer.print("{s}", .{@typeName(T)}) catch {};
        },

        .pointer => |ptr_info| {
            if (ptr_info.size == .one) {
                // De-reference single pointers and try again
                if (@typeInfo(ptr_info.child) == .@"fn") {
                    writer.print("fn {s}@0x{x}", .{ @typeName(ptr_info.child), @intFromPtr(val) }) catch {};
                    return;
                }

                writeValue(writer, val.*);
            } else if (ptr_info.size == .slice) {
                // This handles your resultX[0..d] slices!
                writer.writeAll("[") catch {};
                for (val, 0..) |item, i| {
                    if (i > 0) writer.writeAll(", ") catch {};
                    writeValue(writer, item);
                }
                writer.writeAll("]") catch {};
            } else {
                // Opaque pointers or many-item pointers, generic stuff
                writer.print("{*}", .{val}) catch {};
            }
        },
        .@"struct" => |ptr_info| {
            if (@hasField(T, "items")) {
                const items_val = val.items;
                const ItemsType = @TypeOf(items_val);
                if (comptime isString(ItemsType)) {
                    writer.print("\"{s}\"", .{items_val}) catch {};
                    return;
                } else {
                    // It's an ArrayList of something else:
                    writeValue(writer, items_val);
                    return;
                }
            }

            // for ArrayList
            if (@hasField(T, "prealloc_segment") and @hasField(T, "len")) {
                writer.writeAll("[") catch {};
                for (0..val.len) |i| {
                    if (i > 0) writer.writeAll(", ") catch {};
                    writeValue(writer, val.at(i).*);
                }
                writer.writeAll("]") catch {};
                return;
            }

            // print as a standard struct { .field = value }
            writer.writeAll("{ ") catch {};
            inline for (ptr_info.fields, 0..) |field, i| {
                if (i > 0) writer.writeAll(", ") catch {};
                const is_tuple_index = comptime blk: {
                    _ = std.fmt.parseInt(usize, field.name, 10) catch break :blk false;
                    break :blk true;
                };
                if (!is_tuple_index) writer.print(".{s} = ", .{field.name}) catch {};
                writeValue(writer, @field(val, field.name));
            }
            writer.writeAll(" }") catch {};
        },
        else => { // acts as a fallback for everything else (unions, error sets, etc)
            writer.print("{any}", .{val}) catch {};
        },
    }
}

/// Determines if type can be considered a string.
fn isString(comptime T: type) bool {
    const type_info = @typeInfo(T);
    if (type_info != .pointer) return false;
    const p = type_info.pointer;
    if (p.size == .slice) return p.child == u8;
    if (p.size == .one) {
        const c_info = @typeInfo(p.child);
        return c_info == .array and c_info.array.child == u8;
    }
    return false;
}

/// Internal helper to format arguments. Contains logic for {h} and {mh} headers.
fn formatArgs(writer: anytype, args: anytype) !void {
    const ArgsType = @TypeOf(args);
    const type_info = @typeInfo(ArgsType);

    if (type_info != .@"struct") {
        writeValue(writer, args);
        return;
    }

    var has_header = false;
    var multi_line = false;
    var first_item = true; // Track if we are at the very start of the output

    inline for (type_info.@"struct".fields, 0..) |field, i| {
        _ = i;
        const val = @field(args, field.name);
        var is_new_header = false;

        // Check if this specific field is a header tag
        if (comptime isString(@TypeOf(val))) {
            const str: []const u8 = val;
            if (str.len >= 3 and std.mem.startsWith(u8, str, "{h}")) {
                has_header = true;
                multi_line = false; // Override multi-line back to standard
                is_new_header = true;
                if (!first_item) try writer.writeAll(" | "); // Separate from previous block
                try writer.writeAll(str[3..]);
            } else if (str.len >= 4 and std.mem.startsWith(u8, str, "{mh}")) {
                has_header = true;
                multi_line = true;
                is_new_header = true;
                if (!first_item) try writer.writeAll("\n"); // Separate from previous block
                try writer.writeAll(str[4..]);
            }
        }

        if (!is_new_header) {
            if (!first_item) {
                // If we just had a header, use ": ".
                // Otherwise, use the current mode's separator.
                const sep = if (has_header) ": " else (if (multi_line) "\n" else " | ");
                try writer.writeAll(sep);
            }
            writeValue(writer, val);

            // Once a value is written, it's no longer "immediately after a header"
            has_header = false;
        }

        first_item = false;
    }
}

/// Writes formatted text to one of the four UI text buffers. No-op without `dw.dev_tools`.
/// Argument can be a simple literal, complex nested struct, and most other things.
pub inline fn write(buffer_id: u2, args: anytype) void {
    if (!dw.dev_tools) return;

    const targets = [4][]u8{ text_1, text_2, text_3, text_4 };
    const buf = targets[buffer_id];
    var writer: std.Io.Writer = .fixed(buf);

    // Resume from previous length
    writer.end = text_lengths[buffer_id];

    // Attempt to write. If it fails, clear and try again.
    if (attemptWrite(&writer, args)) {
        text_lengths[buffer_id] = writer.end;
    } else {
        // Overflow! Clear the buffer and write a single line.
        writer.end = 0;
        _ = writer.writeAll("[BUFFER CLEARED]\n") catch {};

        if (attemptWrite(&writer, args)) {
            text_lengths[buffer_id] = writer.end;
        } else {
            // Truncate to fit this extremely long line
            writer.end = 0;
            _ = writerTruncate(&writer, args);
            text_lengths[buffer_id] = writer.end;
        }
    }

    if (dw.is_wasm) {
        dw.jsWriteText(@intCast(buffer_id), buf.ptr, text_lengths[buffer_id]);
    }
}

/// Same as write(), but clears the buffer beforehand.
pub inline fn writeOnce(buffer_id: u2, args: anytype) void {
    clear(buffer_id);
    write(buffer_id, args);
}

fn attemptWrite(writer: *std.Io.Writer, args: anytype) bool {
    formatArgs(writer, args) catch return false;
    writer.writeByte('\n') catch return false;
    return true;
}

/// Fallback for large logs by truncating.
fn writerTruncate(writer: *std.Io.Writer, args: anytype) bool {
    formatArgs(writer, args) catch {};
    _ = writer.writeAll("... [remaining log truncated]\n") catch {};
    return true;
}

/// Clears the text from a specific UI buffer (id 0-3). No-op without `dw.dev_tools`.
pub fn clear(id: u2) void {
    if (!dw.dev_tools) return;
    text_lengths[id] = 0;
    if (dw.is_wasm) {
        const targets = [4][]u8{ text_1, text_2, text_3, text_4 };
        dw.jsWriteText(@intCast(id), targets[id].ptr, 0);
    }
}

test "native logging output" {
    testLogs(false);
}
