//! Contains dedicated code for logging. Use quickWarn to quickly create warnings when testing (using ZLS or native zig test command), and quick to quickly log values to JS. Use the write()/clear() function to write to the 4 corners of the screen with the canvas for JS.
const std = @import("std");
const builtin = @import("builtin");
const memory = @import("memory.zig");

const LogCategory = enum(i32) {
    log = 0,
    info = 1,
    warn = 2,
    err = 3,
};

/// Static logging buffer for messaging JS.
var logging_buffer: [4096]u8 align(memory.MAIN_ALIGN_BYTES) = undefined;

/// Logging buffer for HTML text elements; split into four parts.
var text_buffer: [4096]u8 align(memory.MAIN_ALIGN_BYTES) = undefined;
const text_1 = text_buffer[0..1024];
const text_2 = text_buffer[1024..2048];
const text_3 = text_buffer[2048..3072];
const text_4 = text_buffer[3072..4096];
/// Represents the lengths of the strings in each text buffer (rendered to HTML elements).
var text_lengths: [4]usize = .{ 0, 0, 0, 0 };

/// Logging bridge between JS and WASM.
extern "env" fn js_message(ptr: [*]const u8, len: usize, message_type: LogCategory) void;

/// Logging bridge between JS and WASM for writing to specific text elements.
extern "env" fn js_write_text(id: u8, ptr: [*]const u8, len: usize) void;

/// Returns the current time (calling `performance.now()` in TS)
extern "env" fn js_get_time() f64;

/// Gets a time in milliseconds. Time is not guaranteed to start from 0 or standard UNIX timestamp when program execution begins.
pub inline fn get_time() f64 {
    if (memory.is_wasm) {
        return js_get_time();
    } else {
        const ns = std.time.nanoTimestamp();
        return @as(f64, @floatFromInt(ns)) / 1_000_000.0; // wow, fancy _ symbol!
    }
}

// Sends a message (with pointer and length, as well as a message type) to either std.log with the appropriate category or JS.
inline fn message(ptr: [*]const u8, len: usize, message_type: LogCategory) void {
    if (memory.is_wasm) {
        js_message(ptr, len, message_type);
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
    write_log(src, fmt, args, .log);
}
/// Logs an info message in JS.
pub inline fn info(comptime src: std.builtin.SourceLocation, fmt: []const u8, args: anytype) void {
    write_log(src, fmt, args, .info);
}
/// Logs a warning message in JS.
pub inline fn warn(comptime src: std.builtin.SourceLocation, fmt: []const u8, args: anytype) void {
    write_log(src, fmt, args, .warn);
}
/// Logs an error message in JS.
pub inline fn err(comptime src: std.builtin.SourceLocation, fmt: []const u8, args: anytype) void {
    write_log(src, fmt, args, .err);
}

inline fn write_log(comptime src: std.builtin.SourceLocation, fmt: []const u8, args: anytype, log_category: LogCategory) void {
    // Add source as comptime. WASM handles the [...url... part of the string
    const prefix_fmt = if (memory.is_wasm) "{s}:{d}:{d}] " else "[zig/{s}:{d}:{d}] ";
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

/// A test function for logging, testing all four logging types and truncation. (See root.zig for export logic.)
pub inline fn test_logs(skipError: bool) void {
    const logger = @import("logger.zig");
    logger.log(@src(), "This is a {s}.", .{"normal log"});
    logger.info(@src(), "This is an info log.", .{});
    logger.warn(@src(), "This is a warning. You should see this when running tests in Zig, or in the console in JS.", .{});
    if (skipError) {
        logger.err(@src(), "This is an error. Should create an alert() popup if CONFIG.noAlertOnError is false and building for WASM.", .{});
    } else {
        logger.log(@src(), "Skipping error test.", .{});
    }
    logger.log(@src(), "This log should be multiple lines.\n-----\nTesting logging with a truncated string below:", .{});
    const allocator = memory.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    list.append(allocator, 'H') catch {};
    list.append(allocator, 'e') catch {};
    list.append(allocator, 'l') catch {};
    list.append(allocator, 'l') catch {};
    list.append(allocator, 'o') catch {};
    list.appendSlice(allocator, " World!") catch {};

    logger.quick(.{ "{h}Quick log with header and 3 values", 12.34, "string", list });
    // Test truncation by taking a test hex string and making it longer than 4,096 bytes
    const long_data = ("0123456789abcdef" ** (5000 / 16 + 1))[0..5000];
    logger.log(@src(), "{s}", .{long_data});
}

/// Internal helper to format arguments into the logging buffer.
fn quickFmt(args: anytype, prefix: []const u8) usize {
    var stream = std.io.fixedBufferStream(&logging_buffer);
    const writer = stream.writer();

    writer.print("{s}", .{prefix}) catch {};
    format_args(writer, args) catch {};
    return stream.pos;
}

/// Quickly logs a message for testing. Use .log() with proper arguments for non-temporary logging.
pub inline fn quick(args: anytype) void {
    const prefix = if (memory.is_wasm) "]" else "";
    const written = quickFmt(args, prefix);
    message(&logging_buffer, written, .log);
}

/// Quickly warns a message for testing. Use .log() with proper arguments for non-temporary logging.
pub inline fn quick_warn(args: anytype) void {
    const written = quickFmt(args, "");
    message(&logging_buffer, written, .warn);
}

/// Internal helper to convert an argument of various types to consistent strings.
fn write_value(writer: anytype, val: anytype) void {
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
            writer.print("{d:.5}", .{val}) catch {}; // 5 decimal places
        },
        .bool => {
            writer.print("{}", .{val}) catch {};
        },
        .enum_literal, .@"enum" => {
            writer.print("{s}", .{@tagName(val)}) catch {};
        },
        .optional => {
            if (val) |v| {
                write_value(writer, v);
            } else {
                writer.writeAll("null") catch {};
            }
        },
        .vector => |ptr_info| {
            writer.writeAll("(") catch {};

            // Vectors have a fixed length known at compile-time
            comptime var i: usize = 0;
            inline while (i < ptr_info.len) : (i += 1) {
                if (i > 0) writer.writeAll(", ") catch {};

                // Recursively call write_value for each element
                write_value(writer, val[i]);
            }

            writer.writeAll(")") catch {};
        },
        .array => |ptr_info| {
            writer.writeAll("[") catch {};
            inline for (0..ptr_info.len) |i| {
                if (i > 0) writer.writeAll(", ") catch {};
                write_value(writer, val[i]);
            }
            writer.writeAll("]") catch {};
        },
        .pointer => |ptr_info| {
            if (ptr_info.size == .one) {
                // De-reference single pointers and try again
                write_value(writer, val.*);
            } else if (ptr_info.size == .slice) {
                // This handles your resultX[0..d] slices!
                writer.writeAll("[") catch {};
                for (val, 0..) |item, i| {
                    if (i > 0) writer.writeAll(", ") catch {};
                    write_value(writer, item);
                }
                writer.writeAll("]") catch {};
            } else {
                // Opaque pointers or many-item pointers, generic stuff
                writer.print("{*}", .{val}) catch {};
            }
        },
        .@"struct" => |ptr_info| {
            if (@hasField(T, "items") and comptime isString(@TypeOf(val.items))) {
                writer.print("{s}", .{val.items}) catch {};
            } else {
                writer.writeAll("{ ") catch {};
                inline for (ptr_info.fields, 0..) |field, i| {
                    if (i > 0) writer.writeAll(", ") catch {};
                    writer.print(".{s} = ", .{field.name}) catch {};
                    write_value(writer, @field(val, field.name));
                }

                writer.writeAll(" }") catch {};
            }
        }, // Fallback for everything else (unions, error sets, etc)
        else => {
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

/// Internal helper to format arguments. Contains some of the logic to deal with {h} headers.
fn format_args(writer: anytype, args: anytype) !void {
    const ArgsType = @TypeOf(args);
    const type_info = @typeInfo(ArgsType);

    if (type_info != .@"struct") {
        write_value(writer, args);
        return;
    }

    var has_header = false;
    inline for (type_info.@"struct".fields, 0..) |field, i| {
        const val = @field(args, field.name);
        var skip_val = false;

        // Header logic on the first field
        if (i == 0 and comptime isString(@TypeOf(val))) {
            const str: []const u8 = val;
            if (str.len >= 3 and std.mem.startsWith(u8, str, "{h}")) {
                has_header = true;
                skip_val = true;
                try writer.writeAll(str[3..]);
            }
        }

        if (!skip_val) {
            if (i > 0) {
                const sep = if (i == 1 and has_header) ": " else " | ";
                try writer.writeAll(sep);
            }
            write_value(writer, val);
        }
    }
}

/// Writes formatted text to one of the four UI text buffers. No-op in release modes. Argument can be a simple literal, complex nested struct, and most other things.
pub inline fn write(buffer_id: u2, args: anytype) void {
    if (builtin.mode != .Debug) return;

    const targets = [4][]u8{ text_1, text_2, text_3, text_4 };
    const buf = targets[buffer_id];
    var stream = std.io.fixedBufferStream(buf);

    // Resume from previous length
    stream.pos = text_lengths[buffer_id];

    // Attempt to write. If it fails, clear and try again.
    if (attempt_write(&stream, args)) {
        text_lengths[buffer_id] = stream.pos;
    } else {
        // Overflow! Clear the buffer and write a single line.
        stream.pos = 0;
        _ = stream.writer().writeAll("[BUFFER CLEARED]\n") catch {};

        if (attempt_write(&stream, args)) {
            text_lengths[buffer_id] = stream.pos;
        } else {
            // Truncate to fit this extremely long line
            stream.pos = 0;
            _ = writer_truncate(&stream, args);
            text_lengths[buffer_id] = stream.pos;
        }
    }

    if (memory.is_wasm) {
        js_write_text(@intCast(buffer_id), buf.ptr, text_lengths[buffer_id]);
    }
}

/// Same as write(), but clears the buffer beforehand.
pub inline fn write_once(buffer_id: u2, args: anytype) void {
    clear(buffer_id);
    write(buffer_id, args);
}

fn attempt_write(stream: anytype, args: anytype) bool {
    const writer = stream.writer();
    format_args(writer, args) catch return false;
    writer.writeByte('\n') catch return false;
    return true;
}

/// Fallback for large logs by truncating.
fn writer_truncate(stream: anytype, args: anytype) bool {
    const writer = stream.writer();
    // Use a small local limit to prevent infinite recursion if format_args fails
    format_args(writer, args) catch {};
    _ = writer.writeAll("... [remaining log truncated]\n") catch {};
    return true;
}

/// Clears the text from a specific UI buffer (id 0-3). No-op in release modes.
pub inline fn clear(id: u2) void {
    if (builtin.mode != .Debug) return;
    text_lengths[id] = 0;
    if (memory.is_wasm) {
        const targets = [4][]u8{ text_1, text_2, text_3, text_4 };
        js_write_text(@intCast(id), targets[id].ptr, 0);
    }
}

test "native logging output" {
    test_logs(false);
}
