const std = @import("std");

/// Generates a struct where each field is a `usize` representing
/// the offset of that field in the provided `T`.
pub fn GenerateOffsets(comptime T: type) type {
    const info = @typeInfo(T).@"struct";
    inline for (info.fields) |field| {
        if (field.type == usize) {
            @compileError("Field '" ++ field.name ++ "' in struct '" ++ @typeName(T) ++
                "' uses 'usize'. Use 'u32' or 'u64' for cross-platform consistency.");
        }
    }
    const field_count = info.fields.len;
    var names: [field_count][]const u8 = undefined;
    var field_types: [field_count]type = undefined;
    var field_attrs: [field_count]std.builtin.Type.StructField.Attributes = undefined;

    inline for (info.fields, 0..) |field, i| {
        names[i] = field.name;
        field_types[i] = u64;
        const offset_val: u64 = @offsetOf(T, field.name);
        field_attrs[i] = .{
            .@"align" = @alignOf(u64), // Changed from .alignment
            .@"comptime" = false,
            .default_value_ptr = @as(?*const anyopaque, @ptrCast(&offset_val)),
        };
    }

    return @Struct(
        .auto,
        null,
        &names,
        &field_types,
        &field_attrs,
    );
}
