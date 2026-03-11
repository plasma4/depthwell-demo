//! Contains dedicated code for JS logging.
const std = @import("std");
const builtin = @import("builtin");
const memory = @import("memory.zig");

const LogCategory = enum(i32) {
    log = 0,
    info = 1,
    warn = 2,
    err = 3,
};

/// Static lgging buffer for messaging JS.
var logging_buffer: [4096]u8 align(memory.MAIN_ALIGN_BYTES) = undefined;

/// Logging bridge between JS and WASM.
extern "env" fn js_message(ptr: [*]const u8, len: usize, message_type: LogCategory) void;

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
    const cutoff = "... [rest of log cut off]";

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

    // Test truncation by taking a test hex string and making it longer than 4,096 bytes
    const long_data = ("0123456789abcdef" ** (5000 / 16 + 1))[0..5000];
    logger.log(@src(), "{s}", .{long_data});
}

/// Quickly logs a message for testing. Use .log() with proper arguments for non-temporary logging.
pub inline fn quick(args: anytype) void {
    const ArgsType = @TypeOf(args);
    const args_type_info = @typeInfo(ArgsType);

    var stream = std.io.fixedBufferStream(&logging_buffer);
    const writer = stream.writer();
    writer.print(if (memory.is_wasm) "]" else "", .{}) catch {};

    // Use an inline switch to handle types at compile-time
    switch (args_type_info) {
        .@"struct" => |struct_info| {
            inline for (struct_info.fields, 0..) |field, i| {
                if (i > 0) writer.print(" | ", .{}) catch {};
                const val = @field(args, field.name);
                writeValue(writer, val);
            }
        },
        // Handle every other type as a single value
        else => {
            writeValue(writer, args);
        },
    }

    const written = stream.pos;
    message(&logging_buffer, written, .log);
}

/// Quickly warns a message for testing. Use .log() with proper arguments for non-temporary logging.
pub inline fn quickWarn(args: anytype) void {
    const ArgsType = @TypeOf(args);
    const args_type_info = @typeInfo(ArgsType);

    var stream = std.io.fixedBufferStream(&logging_buffer);
    const writer = stream.writer();
    writer.print("", .{}) catch {};

    // Use an inline switch to handle types at compile-time
    switch (args_type_info) {
        .@"struct" => |struct_info| {
            inline for (struct_info.fields, 0..) |field, i| {
                if (i > 0) writer.print(" | ", .{}) catch {};
                const val = @field(args, field.name);
                writeValue(writer, val);
            }
        },
        // Handle every other type as a single value
        else => {
            writeValue(writer, args);
        },
    }

    const written = stream.pos;
    message(&logging_buffer, written, .warn);
}

inline fn writeValue(writer: anytype, val: anytype) void {
    const T = @TypeOf(val);
    const type_info = @typeInfo(T);

    switch (type_info) {
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                writer.print("{s}", .{val}) catch {}; // for slices
            } else if (ptr_info.size == .one) {
                switch (@typeInfo(ptr_info.child)) {
                    .array => |arr_info| if (arr_info.child == u8) {
                        writer.print("{s}", .{val}) catch {};
                    },
                    else => {
                        const addr = @intFromPtr(val);
                        writer.print("{s}@{d}", .{ @typeName(T), addr }) catch {};
                    },
                }
            } else {
                // print type and base-10 address
                const addr = @intFromPtr(val);
                writer.print("{s}@{d}", .{ @typeName(T), addr }) catch {};
            }
        },
        .int => |int_info| {
            if (T == usize) {
                // usize: treat as pointer-like, show decimal
                writer.print("usize@{d}", .{val}) catch {};
            } else if (int_info.signedness == .signed) {
                writer.print("{d}", .{val}) catch {};
            } else {
                writer.print("{d}", .{val}) catch {};
            }
        },
        .float => {
            writer.print("{d}", .{val}) catch {};
        },
        .comptime_int, .comptime_float => {
            writer.print("{d}", .{val}) catch {};
        },
        .bool => {
            writer.print("{}", .{val}) catch {};
        },
        .@"enum" => {
            writer.print("{s}", .{@tagName(val)}) catch {};
        },
        .optional => {
            if (val) |unwrapped| {
                writeValue(writer, unwrapped);
            } else {
                writer.print("null", .{}) catch {};
            }
        },
        else => {
            writer.print("{any}", .{val}) catch {};
        },
    }
}

test "native logging output" {
    test_logs(false);
}
