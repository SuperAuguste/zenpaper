const std = @import("std");
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;
const Extra = @import("Extra.zig");

const Ast = @This();

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
        root: struct { children: []const Node.Index },

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

        /// main_token is left_square
        /// can contain degree, ratio, cents, edostep, edxstep, hz, equave_up/down, multi_ratio
        chord: struct {
            right_square: Token.Index,
            children: []const Node.Index,
        },

        /// main_token is the ratio base
        /// can contain single_colon_multi_ratio_part, double_colon_multi_ratio_part
        chord_multi_ratio: struct { children: []const Node.Index },

        /// main_token is integer
        single_colon_multi_ratio_part,
        /// main_token is integer
        double_colon_multi_ratio_part,

        /// main_token is left_curly
        /// can contain degree, ratio, cents, edostep, edxstep, equave_up/down
        scale: struct {
            right_curly: Token.Index,
            equave: Node.OptionalIndex,
            children: []const Node.Index,
        },

        /// main_token is the ratio base
        /// can contain single_colon_multi_ratio_part, double_colon_multi_ratio_part
        scale_multi_ratio: struct { children: []const Node.Index },
        /// main_token is the number of divisions
        scale_edo,
        /// main_token is the number of divisions
        /// equave is an integer or a fraction
        scale_edx: struct { equave: Node.Index },
        /// main_token is keyword_m
        /// children are integers
        scale_mode: struct { children: []const Node.Index },

        /// main_token is keyword_r
        root_frequency: struct { child: Node.Index },

        pub const Untagged = Extra.Untagged(Data);
    };

    tag: Tag,
    main_token: Token.OptionalIndex,
    untagged_data: Data.Untagged,
};

pub const Error = struct {
    pub const Tag = enum(u8) {
        expected_tag,
        expected_tags_2,
    };

    pub const Data = union {
        none: void,
        expected_tag: Token.Tag,
        expected_tags_2: [2]Token.Tag,
    };

    tag: Tag,
    token: Token.Index,
    data: Data,

    pub fn render(
        @"error": Error,
        tokens: *const Tokenizer.Tokens,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        switch (@"error".tag) {
            .expected_tag => {
                try writer.print("expected {s}, found {s}\n", .{
                    @tagName(@"error".data.expected_tag), @tagName(tokens.tag(@"error".token)),
                });
            },
            inline .expected_tags_2 => |tag| {
                const data = @field(@"error".data, @tagName(tag));

                try writer.writeAll("expected ");

                for (data[0 .. data.len - 2]) |data_tag| {
                    try writer.print("{s} ", .{@tagName(data_tag)});
                }

                try writer.print("{s} or {s}, found {s}\n", .{
                    @tagName(data[data.len - 2]),
                    @tagName(data[data.len - 1]),
                    @tagName(tokens.tag(@"error".token)),
                });
            },
        }
    }
};

nodes: std.MultiArrayList(Node).Slice,
extra: []const u32,
errors: []const Error,

pub fn deinit(ast: *Ast, allocator: std.mem.Allocator) void {
    ast.nodes.deinit(allocator);
    allocator.free(ast.extra);
    allocator.free(ast.errors);
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
    return untagged.toTagged(ast.extra, tag);
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

    std.debug.print("{s}", .{@tagName(data)});

    if (ast.nodeMainToken(node)) |main_token| {
        const range = tokens.range(main_token);
        std.debug.print(" {d}..{d}\n", .{ range.start, range.end });
    } else {
        std.debug.print("\n", .{});
    }

    switch (data) {
        inline else => |value| {
            const T = @TypeOf(value);

            if (@typeInfo(T) == .@"struct") {
                inline for (std.meta.fields(T)) |field| {
                    switch (field.type) {
                        Node.Index => {
                            const child = @field(value, field.name);
                            for (0..indent + 1) |_| std.debug.print("  ", .{});
                            std.debug.print("{s}:\n", .{field.name});
                            ast.debugPrintNode(tokens, child, indent + 2);
                        },
                        Node.OptionalIndex => {
                            if (@field(value, field.name).unwrap()) |child| {
                                for (0..indent + 1) |_| std.debug.print("  ", .{});
                                std.debug.print("{s}:\n", .{field.name});
                                ast.debugPrintNode(tokens, child, indent + 2);
                            }
                        },
                        []const Node.Index => {
                            const children = @field(value, field.name);
                            for (0..indent + 1) |_| std.debug.print("  ", .{});
                            std.debug.print("{s} ({d}):\n", .{ field.name, children.len });
                            for (children) |child| {
                                ast.debugPrintNode(tokens, child, indent + 2);
                            }
                        },
                        else => {},
                    }
                }
            }
        },
    }
}
