const std = @import("std");
const State = @import("wasm_agent/State.zig");

const types = .{
    .{ State.DocumentUpdated, "DocumentUpdated" },
    .{ State.Highlight, "Highlight" },
    .{ State.Highlight.Tag, "HighlightTag" },
    .{ State.HighlightsUpdated, "HighlightsUpdated" },
};

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    std.debug.assert(args.skip());

    const destination_path = args.next() orelse {
        std.log.err("missing destination path", .{});
        return;
    };

    const file = try std.fs.cwd().createFile(destination_path, .{});
    defer file.close();

    var buffered_writer = std.io.bufferedWriter(file.writer());
    const writer = buffered_writer.writer();

    inline for (types) |row| {
        const T, const name = row;

        try generateType(T, name, writer);
    }

    try buffered_writer.flush();
}

fn generateType(comptime T: type, name: []const u8, writer: anytype) !void {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (info.layout != .@"extern") @compileError("");
            try writer.print(
                \\export class {[name]s}OnePtr {{
                \\    constructor(public buffer: ArrayBuffer, public address: number) {{}}
                \\
                \\    public deref(): {[name]s} {{
                \\        return {[name]s}.read(this.buffer, this.address);
                \\    }}
                \\}}
                \\
                \\export class {[name]s}OptionalOnePtr {{
                \\    constructor(public buffer: ArrayBuffer, public address: number) {{}}
                \\
                \\    public unwrap(): {[name]s}OnePtr | null {{
                \\        return this.address == 0 ? null : new {[name]s}OnePtr(this.buffer, this.address);
                \\    }}
                \\}}
                \\
                \\export class {[name]s}ManyPtr {{
                \\    public constructor(public buffer: ArrayBuffer, public address: number) {{}}
                \\
                \\    public deref(index: number): {[name]s} {{
                \\        return {[name]s}.read(this.buffer, this.address + index * {[name]s}.size);
                \\    }}
                \\
                \\    public* slice(start: number, end: number) {{
                \\        for (let index = start; index < end; index += 1) {{
                \\            yield this.deref(index);
                \\        }}
                \\    }}
                \\}}
                \\
                \\export class {[name]s}OptionalManyPtr {{
                \\    constructor(public buffer: ArrayBuffer, public address: number) {{}}
                \\
                \\    public unwrap(): {[name]s}ManyPtr | null {{
                \\        return this.address == 0 ? null : new {[name]s}ManyPtr(this.buffer, this.address);
                \\    }}
                \\}}
                \\
            , .{ .name = name });

            try writer.print(
                \\export class {[name]s} {{
                \\    public static size = {[size]d};
                \\
            , .{ .name = name, .size = wasmSizeOf(T) });

            inline for (info.fields) |field| {
                if (field.alignment != 1) @compileError("");
                try writer.print("    public {s}: ", .{field.name});
                switch (@typeInfo(field.type)) {
                    .int => try writer.writeAll("number"),
                    .pointer => |ptr_info| {
                        switch (ptr_info.size) {
                            .one => try writer.print("{s}OnePtr", .{typeToName(ptr_info.child)}),
                            .many => try writer.print("{s}ManyPtr", .{typeToName(ptr_info.child)}),
                            else => @compileError(""),
                        }
                    },
                    .@"struct", .@"enum" => try writer.writeAll(typeToName(field.type)),
                    .optional => |optional_info| {
                        switch (@typeInfo(optional_info.child)) {
                            .pointer => |ptr_info| {
                                switch (ptr_info.size) {
                                    .one => try writer.print("{s}OptionalOnePtr", .{typeToName(ptr_info.child)}),
                                    .many => try writer.print("{s}OptionalManyPtr", .{typeToName(ptr_info.child)}),
                                    else => @compileError(""),
                                }
                            },
                            else => @compileError("unsupported: " ++ @typeName(field.type)),
                        }
                    },
                    else => @compileError("unsupported: " ++ @typeName(field.type)),
                }
                try writer.writeAll(";\n");
            }

            try writer.print(
                \\
                \\    public static read(buffer: ArrayBuffer, address: number) {{
                \\        let result = new {[name]s}();
                \\        const dataView = new DataView(buffer);
                \\
            , .{ .name = name });

            comptime var offset: usize = 0;
            inline for (info.fields) |field| {
                if (field.alignment != 1) @compileError("");
                try writer.print("        result.{s} = ", .{field.name});
                switch (@typeInfo(field.type)) {
                    .int => |int_info| {
                        if (field.type == u8) {
                            try writer.print("dataView.getUint8(address + {d})", .{offset});
                        } else if (int_info.signedness == .unsigned) {
                            try writer.print("dataView.getUint{d}(address + {d}, true)", .{ int_info.bits, offset });
                        } else {
                            @compileError("");
                        }
                    },
                    .pointer => |ptr_info| {
                        switch (ptr_info.size) {
                            .one => try writer.print(
                                "new {s}OnePtr(buffer, dataView.getUint32(address + {d}, true))",
                                .{ typeToName(ptr_info.child), offset },
                            ),
                            .many => try writer.print(
                                "new {s}ManyPtr(buffer, dataView.getUint32(address + {d}, true))",
                                .{ typeToName(ptr_info.child), offset },
                            ),
                            else => @compileError(""),
                        }
                    },
                    .@"struct" => {
                        try writer.print(
                            "{s}.read(buffer, address + {d})",
                            .{ typeToName(field.type), offset },
                        );
                    },
                    .@"enum" => |enum_info| {
                        if (enum_info.tag_type == u8) {
                            try writer.print("dataView.getUint8(address + {d})", .{offset});
                        } else if (@typeInfo(enum_info.tag_type).int.signedness == .unsigned) {
                            try writer.print("dataView.getUint{d}(address + {d}, true)", .{ @typeInfo(enum_info.tag_type).int.bits, offset });
                        } else {
                            @compileError("");
                        }
                    },
                    .optional => |optional_info| {
                        switch (@typeInfo(optional_info.child)) {
                            .pointer => |ptr_info| {
                                switch (ptr_info.size) {
                                    .one => try writer.print(
                                        "new {s}OptionalOnePtr(buffer, dataView.getUint32(address + {d}, true))",
                                        .{ typeToName(ptr_info.child), offset },
                                    ),
                                    .many => try writer.print(
                                        "new {s}OptionalManyPtr(buffer, dataView.getUint32(address + {d}, true))",
                                        .{ typeToName(ptr_info.child), offset },
                                    ),
                                    else => @compileError(""),
                                }
                            },
                            else => @compileError("unsupported: " ++ @typeName(field.type)),
                        }
                    },
                    else => @compileError("unsupported: " ++ @typeName(field.type)),
                }
                try writer.writeAll(";\n");

                offset += comptime wasmSizeOf(field.type);
            }

            try writer.writeAll(
                \\        return result;
                \\    }
                \\
            );

            try writer.writeAll("}\n\n");
        },
        .@"enum" => |info| {
            try writer.print(
                \\export enum {[name]s} {{
                \\
            , .{ .name = name });
            inline for (info.fields) |field| {
                try writer.print("    {s} = {d},\n", .{ field.name, field.value });
            }
            try writer.writeAll(
                \\}
                \\
                \\
            );
        },
        else => @compileError("unsupported: " ++ @typeName(T)),
    }
}

fn wasmSizeOf(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .int => @sizeOf(T),
        .@"enum" => |info| wasmSizeOf(info.tag_type),
        .@"struct" => |info| {
            comptime var size: usize = 0;
            inline for (info.fields) |field| {
                size += comptime wasmSizeOf(field.type);
            }
            return size;
        },
        .pointer => @sizeOf(u32),
        .optional => |optional_info| {
            comptime std.debug.assert(@typeInfo(optional_info.child) == .pointer);
            return @sizeOf(u32);
        },
        else => @compileError("unsupported: " ++ @typeName(T)),
    };
}

fn typeToName(comptime T: type) []const u8 {
    inline for (types) |row| {
        if (row[0] == T) {
            return row[1];
        }
    }

    @compileError("no name for type: " ++ @typeName(T));
}
