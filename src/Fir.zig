const std = @import("std");
const Ast = @import("Ast.zig");

const Fir = @This();

pub const ExtraIndex = enum(u32) { _ };

pub const EquaveExponent = enum(i32) { _ };

pub const Tone = struct {
    pub const Index = enum(u32) { _ };

    pub const Tag = std.meta.Tag(Data);
    pub const Data = union(enum(u8)) {
        degree: struct {
            equave_exponent: EquaveExponent,
            root_frequency: Tone.Index,
            scale: Instruction.Index,
            degree: u32,
        },
        ratio: struct {
            equave_exponent: EquaveExponent,
            root_frequency: Tone.Index,
            numerator: u32,
            denominator: u32,
        },
        cents: struct {
            equave_exponent: EquaveExponent,
            root_frequency: Tone.Index,
            cents: f32,
        },
        edostep: struct {
            equave_exponent: EquaveExponent,
            root_frequency: Tone.Index,
            edostep: u32,
            divisions: u32,
        },
        edxstep: struct {
            equave_exponent: EquaveExponent,
            root_frequency: Tone.Index,
            edostep: u32,
            divisions: u32,
            equave: struct {
                numerator: u32,
                denominator: u32,
            },
        },
        hz: struct {
            equave_exponent: EquaveExponent,
        },

        fn MoveOversizedToExtra(comptime T: type) type {
            return switch (@typeInfo(T)) {
                .@"struct" => |_| {
                    return if (@bitSizeOf(T) > 32)
                        ExtraIndex
                    else
                        T;
                },
                else => T,
            };
        }

        pub const Untagged = blk: {
            const src_fields = @typeInfo(Data).@"union".fields;
            var dst_fields: [src_fields.len]std.builtin.Type.UnionField = src_fields[0..src_fields.len].*;

            for (&dst_fields) |*field| {
                field.type = MoveOversizedToExtra(field.type);
                std.debug.assert(@bitSizeOf(field.type) <= 32);
            }

            break :blk @Type(.{
                .@"union" = .{
                    .layout = .auto,
                    .tag_type = null,
                    .fields = &dst_fields,
                    .decls = &.{},
                },
            });
        };
    };

    tag: Tag,
    untagged_data: Data.Untagged,

    src_node: Ast.Node.Index,
    instruction: Instruction.OptionalIndex,

    /// "Final" frequency or ratio - all equave shifts already applied (e.g. for '['0], the Tone
    /// for `0` will consider both equave shifts). Frequency when parent is note or chord, ratio
    /// when parent is a scale.
    value: f32,
};

pub const Instruction = struct {
    pub const Index = enum(u32) { _ };
    pub const OptionalIndex = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn wrap(maybe_index: ?Index) OptionalIndex {
            if (maybe_index) |index| {
                const optional: OptionalIndex = @enumFromInt(@intFromEnum(index));
                std.debug.assert(optional != .none);
                return optional;
            } else {
                return .none;
            }
        }

        pub fn unwrap(optional: OptionalIndex) ?Index {
            return switch (optional) {
                .none => null,
                _ => |value| @enumFromInt(@intFromEnum(value)),
            };
        }
    };

    pub const Tag = std.meta.Tag(Data);
    pub const Data = union(enum(u8)) {
        note: struct {
            tone: Tone.Index,
            held: u32,
        },
        chord: struct {
            equave_shifted: i32,
            tone_start: Tone.Index,
            tone_end: Tone.Index,
            held: u32,
        },
        scale: struct {
            equave_shifted: i32,
            tone_start: Tone.Index,
            tone_end: Tone.Index,
        },
    };

    tag: Tag,
    src_node: Ast.Node.Index,
    data: Data,
};

instructions: std.MultiArrayList(Instruction).Slice,
tones: std.MultiArrayList(Tone).Slice,
extra: []const u32,

pub fn deinit(fir: *Fir, allocator: std.mem.Allocator) void {
    fir.instructions.deinit(allocator);
    fir.tones.deinit(allocator);
    allocator.free(fir.extra);
    fir.* = undefined;
}

pub fn toneTag(ast: *const Ast, tone: Tone.Index) Tone.Tag {
    return ast.tones.items(.tag)[@intFromEnum(tone)];
}

pub fn toneSrcNode(ast: *const Ast, tone: Tone.Index) Ast.Node.Index {
    return ast.tones.items(.src_node)[@intFromEnum(tone)];
}

pub fn toneInstruction(ast: *const Ast, tone: Tone.Index) Instruction.Index {
    return ast.tones.items(.instruction)[@intFromEnum(tone)];
}

pub fn toneUntaggedData(ast: *const Ast, tone: Tone.Index) Tone.Data.Untagged {
    return ast.tones.items(.untagged_data)[@intFromEnum(tone)];
}

pub fn toneDataFromUntagged(ast: *const Ast, tag: Tone.Tag, untagged: Tone.Data.Untagged) Tone.Data {
    return switch (tag) {
        inline else => |actual_tag| {
            const untagged_data = @field(untagged, @tagName(actual_tag));
            const Untagged = @TypeOf(untagged_data);
            const Tagged = @FieldType(Tone.Data, @tagName(actual_tag));

            if (Untagged != ExtraIndex) {
                return @unionInit(Tone.Data, @tagName(actual_tag), untagged_data);
            } else {
                var index: u32 = 0;
                const slice = ast.extra[@intFromEnum(untagged_data.start)..@intFromEnum(untagged_data.end)];

                var data: Tagged = undefined;

                inline for (std.meta.fields(Tagged)) |field| {
                    switch (field.type) {
                        Tone.Index => {
                            @field(data, field.name) = @enumFromInt(slice[index]);
                            index += 1;
                        },
                        []const Tone.Index => {
                            const len = slice[index];
                            index += 1;
                            @field(data, field.name) = @ptrCast(slice[index..][0..len]);
                            index += len;
                        },
                        else => @compileError("TODO: " ++ @typeName(field.type)),
                    }
                }

                return @unionInit(Tone.Data, @tagName(actual_tag), data);
            }
        },
    };
}

pub fn toneData(ast: *const Ast, tone: Tone.Index) Tone.Data {
    return ast.toneDataFromUntagged(ast.toneTag(tone), ast.toneUntaggedData(tone));
}
