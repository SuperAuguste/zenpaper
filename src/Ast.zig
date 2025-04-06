const std = @import("std");
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;

const Ast = @This();

pub const ExtraIndex = enum(u32) { _ };
pub const ExtraSlice = struct {
    start: ExtraIndex,
    end: ExtraIndex,
};

pub const Node = struct {
    pub const Index = enum(u32) { root, _ };
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
        /// main_token is none
        root: struct { extra: struct {
            children: []const Node.Index,
        } },

        /// main_token is an integer
        /// semantically distinct from degree
        integer,
        /// main_token is the numerator
        /// semantically distinct from ratio
        fraction: struct { denominator: Token.Index },

        /// main_token is the degree
        degree,
        /// main_token is the numerator
        ratio: struct { denominator: Token.Index },
        /// main_token is the whole part
        cents: struct { fractional_part: Token.OptionalIndex },
        /// main_token is the edostep
        edostep: struct { divisions: Token.Index },
        /// main_token is the edostep
        /// equave is an integer or a fraction
        edxstep: struct { divisions: Token.Index, equave: Node.Index },
        /// main_token is the whole part
        hz: struct { fractional_part: Token.OptionalIndex },

        /// main_token is first equave shift
        /// child may be a note, chord, or scale
        equave_shifted: struct { equave_shift: i32, child: Node.Index },
        /// main_token is first dash
        /// child may be a note, chord, or equave_shifted
        held: struct { holds: u32, child: Node.Index },

        /// main_token is period
        rest,

        /// main_token is left_square or none in the case of an unwrapped multi_ratio
        /// can contain degree, ratio, cents, edostep, edxstep, hz, equave_up/down, multi_ratio
        chord: struct { extra: struct {
            children: []const Node.Index,
        } },

        /// main_token is the ratio base
        /// can contain single_colon_multi_ratio_part, double_colon_multi_ratio_part
        chord_multi_ratio: struct { extra: struct {
            children: []const Node.Index,
        } },

        /// main_token is integer
        single_colon_multi_ratio_part,
        /// main_token is integer
        double_colon_multi_ratio_part,

        /// main_token is left_curly
        /// can contain degree, ratio, cents, edostep, edxstep, equave_up/down
        scale: struct { extra: struct {
            children: []const Node.Index,
        } },

        /// main_token is the ratio base
        /// can contain single_colon_multi_ratio_part, double_colon_multi_ratio_part
        scale_multi_ratio: struct { extra: struct {
            children: []const Node.Index,
        } },
        /// main_token is the number of divisions
        scale_edo,
        /// main_token is the number of divisions
        /// equave is an integer or a fraction
        scale_edx: struct { equave: Node.Index },

        /// main_token is keyword_r
        root_frequency: struct { child: Node.Index },

        // TODO: Currently wasteful as we store start and end + lengths within extra.
        // We could make things more flexible or switch to start only with a 32-bit .untagged_data.
        fn ExtraToExtraSlice(comptime T: type) type {
            return switch (@typeInfo(T)) {
                .@"struct" => |info| {
                    if (!@hasField(T, "extra")) return T;
                    comptime std.debug.assert(info.fields.len == 1);
                    return ExtraSlice;
                },
                else => T,
            };
        }

        pub const Untagged = blk: {
            const src_fields = @typeInfo(Data).@"union".fields;
            var dst_fields: [src_fields.len]std.builtin.Type.UnionField = src_fields[0..src_fields.len].*;

            for (&dst_fields) |*field| {
                field.type = ExtraToExtraSlice(field.type);
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

        pub fn children(data: *const Node.Data, buffer: *[1]Node.Index) ?[]const Node.Index {
            switch (data.*) {
                inline else => |*value| {
                    const T = @TypeOf(value.*);

                    if (@typeInfo(T) == .@"struct") {
                        if (@hasField(T, "extra")) {
                            return value.extra.children;
                        } else if (@hasField(T, "child")) {
                            buffer[0] = value.child;
                            return buffer;
                        }
                    }

                    return null;
                },
            }
        }
    };

    comptime {
        if (!std.debug.runtime_safety) {
            std.debug.assert(@bitSizeOf(Data.Untagged) == 64);
        }
    }

    tag: Tag,
    main_token: Token.OptionalIndex,
    untagged_data: Data.Untagged,
};

nodes: std.MultiArrayList(Node).Slice,
extra: []const u32,

pub fn deinit(ast: *Ast, allocator: std.mem.Allocator) void {
    ast.nodes.deinit(allocator);
    allocator.free(ast.extra);
    ast.* = undefined;
}

pub fn nodeTag(ast: *const Ast, node: Node.Index) Node.Tag {
    return ast.nodes.items(.tag)[@intFromEnum(node)];
}

pub fn nodeMainToken(ast: *const Ast, node: Node.Index) ?Token.Index {
    return ast.nodes.items(.main_token)[@intFromEnum(node)].unwrap();
}

pub fn nodeUntaggedData(ast: *const Ast, node: Node.Index) Node.Data.Untagged {
    return ast.nodes.items(.untagged_data)[@intFromEnum(node)];
}

pub fn nodeDataFromUntagged(ast: *const Ast, tag: Node.Tag, untagged: Node.Data.Untagged) Node.Data {
    return switch (tag) {
        inline else => |actual_tag| {
            const data = @field(untagged, @tagName(actual_tag));
            const T = @TypeOf(data);

            if (T != ExtraSlice) {
                return @unionInit(Node.Data, @tagName(actual_tag), data);
            } else {
                var extra: @TypeOf(@field(@field(@as(Node.Data, undefined), @tagName(actual_tag)), "extra")) = undefined;

                var index: u32 = 0;
                const slice = ast.extra[@intFromEnum(data.start)..@intFromEnum(data.end)];

                inline for (std.meta.fields(@TypeOf(extra))) |field| {
                    switch (field.type) {
                        Token.Index, Node.Index, Token.OptionalIndex => {
                            @field(extra, field.name) = @enumFromInt(slice[index]);
                            index += 1;
                        },
                        []const Node.Index => {
                            const len = slice[index];
                            index += 1;
                            @field(extra, field.name) = @ptrCast(slice[index..][0..len]);
                            index += len;
                        },
                        else => @compileError("TODO: " ++ @typeName(field.type)),
                    }
                }

                return @unionInit(Node.Data, @tagName(actual_tag), .{ .extra = extra });
            }
        },
    };
}

pub fn nodeData(ast: *const Ast, node: Node.Index) Node.Data {
    return ast.nodeDataFromUntagged(ast.nodeTag(node), ast.nodeUntaggedData(node));
}

pub fn debugPrintNode(
    ast: *const Ast,
    tokens: *const Tokenizer.Tokens,
    node: Node.Index,
    indent: usize,
) void {
    for (0..indent) |_| std.debug.print("  ", .{});

    const data = ast.nodeData(node);
    var child_buffer: [1]Node.Index = undefined;
    const maybe_children = data.children(&child_buffer);

    std.debug.print("{s}", .{@tagName(data)});

    if (ast.nodeMainToken(node)) |main_token| {
        const range = tokens.range(main_token);
        std.debug.print(" {d}..{d}", .{ range.start, range.end });
    }

    if (maybe_children) |children| {
        std.debug.print(" ({d} children)\n", .{children.len});
        for (children) |child| {
            ast.debugPrintNode(tokens, child, indent + 1);
        }
    } else {
        std.debug.print("\n", .{});
    }
}
