const std = @import("std");

pub const Index = enum(u32) { _ };

pub fn write(
    allocator: std.mem.Allocator,
    extra: *std.ArrayListUnmanaged(u32),
    value: anytype,
) error{OutOfMemory}!Index {
    const T = @TypeOf(value);

    const start: Index = @enumFromInt(extra.items.len);

    inline for (std.meta.fields(T)) |field| {
        const field_value = @field(value, field.name);

        switch (@typeInfo(field.type)) {
            .int => try extra.append(allocator, @bitCast(field_value)),
            .@"enum" => try extra.append(allocator, @intFromEnum(field_value)),
            .pointer => {
                try extra.append(allocator, @intCast(field_value.len));
                try extra.appendSlice(allocator, @ptrCast(field_value));
            },
            else => @compileError("TODO: " ++ @typeName(field.type)),
        }
    }

    return start;
}

pub fn read(
    comptime T: type,
    extra: []const u32,
    start: Index,
) T {
    var value: T = undefined;

    var index = @intFromEnum(start);
    inline for (std.meta.fields(T)) |field| {
        const field_ptr = &@field(value, field.name);

        switch (@typeInfo(field.type)) {
            .int => {
                field_ptr.* = @bitCast(extra[index]);
                index += 1;
            },
            .@"enum" => {
                field_ptr.* = @enumFromInt(extra[index]);
                index += 1;
            },
            .pointer => {
                const len = extra[index];
                index += 1;
                @field(value, field.name) = @ptrCast(extra[index..][0..len]);
                index += len;
            },
            else => @compileError("TODO: " ++ @typeName(field.type)),
        }
    }

    return value;
}

fn MoveOversizedToExtra(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .@"struct" => |_| {
            return if (@bitSizeOf(T) > 32)
                Index
            else
                T;
        },
        else => T,
    };
}

pub fn Untagged(comptime Tagged: type) type {
    const src_fields = @typeInfo(Tagged).@"union".fields;
    var dst_fields: [src_fields.len]std.builtin.Type.UnionField = src_fields[0..src_fields.len].*;

    for (&dst_fields) |*field| {
        field.type = MoveOversizedToExtra(field.type);
    }

    const Internal = @Type(.{
        .@"union" = .{
            .layout = .auto,
            .tag_type = null,
            .fields = &dst_fields,
            .decls = &.{},
        },
    });

    if (!std.debug.runtime_safety) {
        std.debug.assert(@bitSizeOf(Internal) == 32);
    }

    return struct {
        internal: Internal,

        pub fn fromTagged(
            allocator: std.mem.Allocator,
            extra: *std.ArrayListUnmanaged(u32),
            tagged: Tagged,
        ) error{OutOfMemory}!@This() {
            switch (tagged) {
                inline else => |value, tag| {
                    const T = @TypeOf(value);

                    return .{
                        .internal = @unionInit(
                            Internal,
                            @tagName(tag),
                            if (@bitSizeOf(T) <= 32)
                                value
                            else
                                try write(allocator, extra, value),
                        ),
                    };
                },
            }
        }

        pub fn toTagged(untagged: @This(), extra: []const u32, tag: std.meta.Tag(Tagged)) Tagged {
            return switch (tag) {
                inline else => |actual_tag| {
                    const untagged_data = @field(untagged.internal, @tagName(actual_tag));

                    return @unionInit(
                        Tagged,
                        @tagName(actual_tag),
                        if (@FieldType(Internal, @tagName(actual_tag)) != Index)
                            untagged_data
                        else
                            read(@FieldType(Tagged, @tagName(actual_tag)), extra, untagged_data),
                    );
                },
            };
        }
    };
}
