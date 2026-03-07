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
            return zigTypeToTs(opt.child); // Simplified for this example
        },

        .error_set => return "ErrorSet",
        .@"enum" => return "number",
        else => return "unknown",
    }
}

/// Generates a struct where each field is a `usize` representing
/// the offset of that field in the provided `T`.
pub fn GenerateOffsets(comptime T: type) type {
    const info = @typeInfo(T).@"struct";
    var fields: [info.fields.len]std.builtin.Type.StructField = undefined;

    inline for (info.fields, 0..) |field, i| {
        //Make comptime constant of type usize to give the value a layout
        const offset_value: usize = @offsetOf(T, field.name);

        fields[i] = .{
            .name = field.name,
            .type = usize,
            .default_value_ptr = &offset_value,
            .is_comptime = false,
            .alignment = @alignOf(usize),
        };
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        },
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var bw = std.io.Writer.Allocating.init(allocator);
    defer bw.deinit();
    var writer = &bw.writer;

    // Write static TypeScript headers and configurations
    try writer.print(
        \\// This is a dynamically generated file from generate_types.zig for use in engine.ts and should not be manually modified. See types.zig for where type definitions come from.
        \\
        \\/**
        \\ * A pointer in the WASM memory. Equals 0/0n to represent a null value.
        \\ */
        \\export type Pointer = number | bigint;
        \\
        \\/**
        \\ * Represents a length.
        \\ */
        \\export type LengthLike = number | bigint;
        \\
        \\/**
        \\ * A pointer in the WASM memory (converted to number).
        \\ */
        \\export type PointerLike = number;
        \\
        \\/**
        \\ * Represents a set of errors from Zig.
        \\ */
        \\export type ErrorSet = number;
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
    inline for (root_info.@"struct".decls) |struct_declaration| {
        const T = @TypeOf(@field(root, struct_declaration.name));

        // Extract all functions from root.zig. (ALL functions from root.zig should be marked as "pub".)
        if (@typeInfo(T) == .@"fn") {
            const fn_info = @typeInfo(T).@"fn";
            if (!std.mem.eql(u8, struct_declaration.name, "panic")) {
                try writer.print("\n    readonly {s}: (", .{struct_declaration.name});

                inline for (fn_info.params, 0..) |param, i| {
                    // Log argument numbers from params
                    if (i > 0) try writer.print(", ", .{});
                    try writer.print("arg{d}: {s}", .{ i, zigTypeToTs(param.type.?) });
                }

                try writer.print(") => {s};", .{zigTypeToTs(fn_info.return_type.?)});
            }
        }
    }

    try writer.print("\n}}\n\n// Generated enum and struct data from types.zig:", .{});

    const type_info = @typeInfo(types);
    inline for (type_info.@"struct".decls) |decl| {
        const value = @field(types, decl.name);
        const ValueType = @TypeOf(value);

        if (ValueType == type) {
            const inner_info = @typeInfo(value);
            if (inner_info == .@"enum") {
                try writer.print("\nexport enum {s} {{\n", .{decl.name});

                inline for (inner_info.@"enum".fields) |field| {
                    try writer.print("    {s} = {d},\n", .{ field.name, field.value });
                }

                try writer.print("}}\n", .{});
            } else if (inner_info == .@"struct") {
                // Handle types like KeyBits that contain constants
                try writer.print("\nexport const {s} = {{\n", .{decl.name});
                inline for (inner_info.@"struct".decls) |struct_decl| {
                    const field_value = @field(value, struct_decl.name);
                    // Only export it if it's a number (skips functions like mask())
                    if (@TypeOf(field_value) == comptime_int or @TypeOf(field_value) == u32) {
                        try writer.print("    {s}: {d},\n", .{ struct_decl.name, field_value });
                    }
                }
                try writer.print("}} as const;\n", .{});
            }
        } else {
            const inner_info = @typeInfo(ValueType);
            if (inner_info == .@"struct") {
                try writer.print("\nexport const {s} = {{\n", .{decl.name});

                inline for (inner_info.@"struct".fields) |field| {
                    const field_value = @field(value, field.name);
                    try writer.print("    {s}: {d},\n", .{ field.name, field_value });
                }

                try writer.print("}} as const;\n", .{});
            }
        }
    }

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(bw.written());
}
