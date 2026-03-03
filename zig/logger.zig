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
    // Add source as comptime
    const prefix = std.fmt.comptimePrint("[{s}:{d}:{d}] ", .{ src.file, src.line, src.column });
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

test "native logging output" {
    test_logs(false);
}
