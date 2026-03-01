//! Automatically generates enum data and WASM export signatures for TypeScript.
const std = @import("std");
const types = @import("types.zig");
const root = @import("root.zig");

/// Maps primitive Zig types to TypeScript types.
fn zigTypeToTs(comptime T: type) []const u8 {
    switch (@typeInfo(T)) {
        .void => return "void",
        .bool => return "boolean",
        .int, .float, .comptime_int, .comptime_float => return "number",
        .pointer => return "Pointer",
        .optional => |opt| {
            if (@typeInfo(opt.child) == .pointer) return "Pointer";
            return "unknown";
        },
        else => return "unknown",
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var bw = std.io.Writer.Allocating.init(allocator);
    defer bw.deinit();
    var writer = &bw.writer;

    // Write static TypeScript headers and configurations
    try writer.print(
        \\// This is a dynamically generated file from generate_types.zig for use in engine.ts. See the folders in /zig for more detailed documentation.
        \\
        \\/**
        \\ * A pointer in the WASM memory.
        \\ */
        \\export type Pointer = number;
        \\
        \\/**
        \\ * Configuration options for the GameEngine.
        \\ */
        \\export interface EngineOptions {{
        \\    highPerformance?: boolean;
        \\}}
        \\
        \\// Generated from exported functions (should all be in root.zig):
        \\export interface EngineExports extends WebAssembly.Exports {{
        \\    readonly memory: WebAssembly.Memory;
        \\
    , .{});

    const root_info = @typeInfo(root);
    inline for (root_info.@"struct".decls) |decl| {
        const T = @TypeOf(@field(root, decl.name));

        // Only extract functions
        if (@typeInfo(T) == .@"fn") {
            const fn_info = @typeInfo(T).@"fn";
            try writer.print("\n    readonly {s}: (", .{decl.name});

            // Zig type reflection does not retain parameter names,
            // so we generate generic names: arg0, arg1, etc.
            inline for (fn_info.params, 0..) |param, i| {
                if (i > 0) try writer.print(", ", .{});
                try writer.print("arg{d}: {s}", .{ i, zigTypeToTs(param.type.?) });
            }

            try writer.print(") => {s};", .{zigTypeToTs(fn_info.return_type.?)});
        }
    }

    try writer.print("\n}}\n\n// Enum data from types.zig:", .{});

    const type_info = @typeInfo(types);
    inline for (type_info.@"struct".decls) |decl| {
        const T = @field(types, decl.name);

        if (@TypeOf(T) == type) {
            const inner_info = @typeInfo(T);
            if (inner_info == .@"enum") {
                try writer.print("\nexport enum {s} {{\n", .{decl.name});
                inline for (inner_info.@"enum".fields) |field| {
                    try writer.print("    {s} = {d},\n", .{ field.name, field.value });
                }
                try writer.print("}}\n", .{});
            }
        }
    }

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(bw.written());
}
