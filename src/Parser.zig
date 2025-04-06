const std = @import("std");
const Ast = @import("Ast.zig");
const Node = Ast.Node;
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;
const Tokens = Tokenizer.Tokens;

const Parser = @This();

allocator: std.mem.Allocator,
tokens: *const Tokens,

token_index: Token.Index = @enumFromInt(0),

nodes: std.MultiArrayList(Node) = .{},
extra: std.ArrayListUnmanaged(u32) = .{},
scratch: std.ArrayListUnmanaged(u32) = .{},

pub fn parse(
    allocator: std.mem.Allocator,
    tokens: *const Tokens,
) !Ast {
    var parser = Parser{
        .allocator = allocator,
        .tokens = tokens,
    };
    defer {
        parser.scratch.deinit(allocator);
    }

    try parser.parseInternal();
    std.debug.assert(parser.scratch.items.len == 0);

    return .{
        .nodes = parser.nodes.toOwnedSlice(),
        .extra = try parser.extra.toOwnedSlice(allocator),
    };
}

fn parseInternal(parser: *Parser) !void {
    const root = try parser.appendNode(.{
        .root = .{
            .extra = .{
                .children = &.{},
            },
        },
    }, null);
    std.debug.assert(root == .root);

    const scratch_start = parser.pushScratch();
    try parser.scratch.append(parser.allocator, 0);

    while (try parser.parseRootChild()) |node| {
        try parser.appendNodeToScratch(node);
    }

    const extra_start = parser.extra.items.len;

    const popped_scratch = parser.popScratch(scratch_start);
    popped_scratch[0] = @intCast(popped_scratch.len - 1);
    try parser.extra.appendSlice(parser.allocator, popped_scratch);
    parser.nodes.items(.untagged_data)[@intFromEnum(root)] = .{
        .root = .{
            .start = @enumFromInt(extra_start),
            .end = @enumFromInt(parser.extra.items.len),
        },
    };
}

fn parseRootChild(parser: *Parser) !?Node.Index {
    parser.skipWhitespace();

    const start_equave_shifted_optional = try parser.startEquaveShifted();

    switch (parser.peekTag(0)) {
        .period => return try parser.parseRest(),
        .left_square => {
            return try parser.couldHold(
                try parser.couldHaveEquaveShifted(
                    start_equave_shifted_optional,
                    try parser.parseChord(),
                ),
            );
        },
        .left_curly => switch (parser.peekTag(1)) {
            .keyword_r => {
                return try parser.couldHaveEquaveShifted(
                    start_equave_shifted_optional,
                    try parser.parseRootFrequency(),
                );
            },
            else => {
                return try parser.couldHaveEquaveShifted(
                    start_equave_shifted_optional,
                    try parser.parseScale(),
                );
            },
        },
        .integer => switch (parser.peekTag(1)) {
            .colon, .colon_colon => {
                return try parser.couldHold(try parser.couldHaveEquaveShifted(
                    start_equave_shifted_optional,
                    try parser.parseMultiRatio(.raw_chord),
                ));
            },
            else => {},
        },
        .eof => {
            return if (start_equave_shifted_optional) |_|
                error.ParseError
            else
                null;
        },
        else => {},
    }

    return try parser.couldHold(
        try parser.couldHaveEquaveShifted(
            start_equave_shifted_optional,
            try parser.parseNote(.absolute_allowed) orelse return error.ParseError,
        ),
    );
}

fn parseChord(parser: *Parser) !Node.Index {
    const scratch_start = parser.pushScratch();
    const left_square = parser.assertToken(.left_square);
    parser.skipWhitespace();

    switch (parser.peekTag(0)) {
        .integer => switch (parser.peekTag(1)) {
            .colon, .colon_colon => {
                return try parser.parseMultiRatio(.chord);
            },
            else => {},
        },
        else => {},
    }

    while (try parser.parseChordChild()) |node| {
        try parser.appendNodeToScratch(node);
    }

    _ = try parser.expectToken(.right_square);

    return parser.appendNode(.{
        .chord = .{
            .extra = .{
                .children = @ptrCast(parser.popScratch(scratch_start)),
            },
        },
    }, left_square);
}

fn parseChordChild(parser: *Parser) !?Node.Index {
    parser.skipWhitespace();

    const start_equave_shifted_optional = try parser.startEquaveShifted();

    if (try parser.parseNote(.absolute_allowed)) |node| {
        return try parser.couldHaveEquaveShifted(start_equave_shifted_optional, node);
    }

    return switch (parser.peekTag(0)) {
        .right_square => null,
        else => return error.ParseError,
    };
}

fn parseScale(parser: *Parser) !Node.Index {
    const scratch_start = parser.pushScratch();
    const left_curly = parser.assertToken(.left_curly);
    parser.skipWhitespace();

    switch (parser.peekTag(0)) {
        .integer => switch (parser.peekTag(1)) {
            .keyword_edo => return try parser.parseScaleEdo(),
            .colon, .colon_colon => return try parser.parseMultiRatio(.scale),
            else => {},
        },
        else => {},
    }

    while (try parser.parseScaleChild()) |node| {
        try parser.appendNodeToScratch(node);
    }

    const children: []const Node.Index = @ptrCast(parser.popScratch(scratch_start));

    if (children.len == 0) {
        return error.ParseError;
    }

    _ = try parser.expectToken(.right_curly);

    return parser.appendNode(.{
        .scale = .{
            .extra = .{
                .children = children,
            },
        },
    }, left_curly);
}

fn parseScaleChild(parser: *Parser) !?Node.Index {
    parser.skipWhitespace();

    const start_equave_shifted_optional = try parser.startEquaveShifted();

    if (try parser.parseNote(.relative_only)) |node| {
        return try parser.couldHaveEquaveShifted(start_equave_shifted_optional, node);
    }

    return switch (parser.peekTag(0)) {
        .right_curly => return null,
        else => return error.ParseError,
    };
}

fn parseScaleEdo(parser: *Parser) !Node.Index {
    const divisions_token = parser.assertToken(.integer);
    _ = parser.assertToken(.keyword_edo);
    parser.skipWhitespace();
    _ = try parser.expectToken(.right_curly);

    return try parser.appendNode(.scale_edo, divisions_token);
}

fn parseRootFrequency(parser: *Parser) !Node.Index {
    const left_curly = parser.assertToken(.left_curly);
    _ = parser.assertToken(.keyword_r);

    const start_equave_shifted_optional = try parser.startEquaveShifted();

    const child = try parser.couldHaveEquaveShifted(
        start_equave_shifted_optional,
        try parser.parseNote(.absolute_allowed) orelse return error.ParseError,
    );
    parser.skipWhitespace();

    _ = try parser.expectToken(.right_curly);

    return try parser.appendNode(.{
        .root_frequency = .{
            .child = child,
        },
    }, left_curly);
}

fn parseNote(
    parser: *Parser,
    comptime mode: enum { absolute_allowed, relative_only },
) !?Node.Index {
    return switch (parser.peekTag(0)) {
        .integer => switch (parser.peekTag(1)) {
            .slash => switch (parser.peekTag(2)) {
                .integer => try parser.parseRatio(),
                else => return error.ParseError,
            },
            .backslash => switch (parser.peekTag(2)) {
                .integer => switch (parser.peekTag(3)) {
                    .keyword_o => switch (parser.peekTag(4)) {
                        .integer => switch (parser.peekTag(5)) {
                            .slash => switch (parser.peekTag(6)) {
                                .integer => try parser.parseEdxstepFractionalEquave(),
                                else => return error.ParseError,
                            },
                            else => try parser.parseEdxstepWholeEquave(),
                        },
                        else => return error.ParseError,
                    },
                    else => try parser.parseEdostep(),
                },
                else => return error.ParseError,
            },
            .keyword_c => try parser.parseWholeCents(),
            .keyword_hz => switch (mode) {
                .relative_only => return error.ParseError,
                else => try parser.parseWholeHertz(),
            },
            .period => switch (parser.peekTag(2)) {
                .integer => switch (parser.peekTag(3)) {
                    .keyword_c => try parser.parseFractionalCents(),
                    .keyword_hz => switch (mode) {
                        .relative_only => return error.ParseError,
                        else => try parser.parseFractionalHertz(),
                    },
                    else => try parser.parseDegree(),
                },
                else => try parser.parseDegree(),
            },
            else => try parser.parseDegree(),
        },
        else => null,
    };
}

const StartEquaveShifted = struct {
    equave_shift: i32,
    first_shift_token: Token.Index,
};
fn startEquaveShifted(parser: *Parser) !?StartEquaveShifted {
    var equave_shift: i32 = 0;
    var first_shift_token: ?Token.Index = null;

    switch (parser.peekTag(0)) {
        .whitespace => unreachable,
        .single_quote, .double_quote => {
            equave_shift += switch (parser.peekTag(0)) {
                .single_quote => 1,
                .double_quote => 2,
                else => unreachable,
            };
            first_shift_token = parser.nextToken();

            while (true) {
                switch (parser.peekTag(0)) {
                    .single_quote => equave_shift += 1,
                    .double_quote => equave_shift += 2,
                    .backtick => return error.ParseError,
                    else => break,
                }
                _ = parser.nextToken();
            }
        },
        .backtick => {
            equave_shift -= 1;
            first_shift_token = parser.nextToken();

            while (true) {
                switch (parser.peekTag(0)) {
                    .backtick => equave_shift -= 1,
                    .single_quote, .double_quote => return error.ParseError,
                    else => break,
                }
                _ = parser.nextToken();
            }
        },
        else => return null,
    }

    return .{
        .equave_shift = equave_shift,
        .first_shift_token = first_shift_token.?,
    };
}

fn endEquaveShifted(
    parser: *Parser,
    start_equave_shifted: StartEquaveShifted,
    child: Node.Index,
) !Node.Index {
    return try parser.appendNode(.{
        .equave_shifted = .{
            .equave_shift = start_equave_shifted.equave_shift,
            .child = child,
        },
    }, start_equave_shifted.first_shift_token);
}

fn parseHeld(parser: *Parser, child: Node.Index) !?Node.Index {
    var holds: u32 = 1;
    const dash_token = parser.eatToken(.dash) orelse return null;

    while (parser.eatToken(.dash)) |_| {
        holds += 1;
    }

    return try parser.appendNode(.{
        .held = .{
            .holds = holds,
            .child = child,
        },
    }, dash_token);
}

fn couldHaveEquaveShifted(
    parser: *Parser,
    start_equave_shifted_optional: ?StartEquaveShifted,
    child: Node.Index,
) !Node.Index {
    return if (start_equave_shifted_optional) |start_equave_shifted|
        try parser.endEquaveShifted(start_equave_shifted, child)
    else
        child;
}

fn couldHold(parser: *Parser, child: Node.Index) !Node.Index {
    return if (try parser.parseHeld(child)) |held|
        held
    else
        child;
}

fn parseDegree(parser: *Parser) !Node.Index {
    const degree_token = parser.assertToken(.integer);
    return parser.appendNode(.degree, degree_token);
}

fn parseRatio(parser: *Parser) !Node.Index {
    const numerator_token = parser.assertToken(.integer);
    _ = parser.assertToken(.slash);
    const denominator_token = parser.assertToken(.integer);

    return parser.appendNode(.{
        .ratio = .{
            .denominator = denominator_token,
        },
    }, numerator_token);
}

fn parseWholeCents(parser: *Parser) !Node.Index {
    const whole_part_token = parser.assertToken(.integer);
    _ = parser.assertToken(.keyword_c);

    return parser.appendNode(.{
        .cents = .{
            .fractional_part = .none,
        },
    }, whole_part_token);
}

fn parseFractionalCents(parser: *Parser) !Node.Index {
    const whole_part_token = parser.assertToken(.integer);
    _ = parser.assertToken(.period);
    const fractional_part_token = parser.assertToken(.integer);
    _ = parser.assertToken(.keyword_c);

    return parser.appendNode(.{
        .cents = .{
            .fractional_part = .wrap(fractional_part_token),
        },
    }, whole_part_token);
}

fn parseEdostep(parser: *Parser) !Node.Index {
    const edostep_token = parser.assertToken(.integer);
    _ = parser.assertToken(.backslash);
    const divisions_token = parser.assertToken(.integer);

    return parser.appendNode(.{
        .edostep = .{
            .divisions = divisions_token,
        },
    }, edostep_token);
}

fn parseInteger(parser: *Parser) !Node.Index {
    return parser.appendNode(.integer, parser.assertToken(.integer));
}

fn parseEdxstepWholeEquave(parser: *Parser) !Node.Index {
    const edostep_token = parser.assertToken(.integer);
    _ = parser.assertToken(.backslash);
    const divisions_token = parser.assertToken(.integer);
    _ = parser.assertToken(.keyword_o);
    const equave = try parser.parseInteger();

    return parser.appendNode(.{
        .edxstep = .{
            .divisions = divisions_token,
            .equave = equave,
        },
    }, edostep_token);
}

fn parseFraction(parser: *Parser) !Node.Index {
    const numerator_token = parser.assertToken(.integer);
    _ = parser.assertToken(.slash);
    const denominator_token = parser.assertToken(.integer);

    return parser.appendNode(.{
        .fraction = .{
            .denominator = denominator_token,
        },
    }, numerator_token);
}

fn parseEdxstepFractionalEquave(parser: *Parser) !Node.Index {
    const edostep_token = parser.assertToken(.integer);
    _ = parser.assertToken(.backslash);
    const divisions_token = parser.assertToken(.integer);
    _ = parser.assertToken(.keyword_o);
    const equave = try parser.parseFraction();

    return parser.appendNode(.{
        .edxstep = .{
            .divisions = divisions_token,
            .equave = equave,
        },
    }, edostep_token);
}

fn parseWholeHertz(parser: *Parser) !Node.Index {
    const whole_part_token = parser.assertToken(.integer);
    _ = parser.assertToken(.keyword_hz);

    return parser.appendNode(.{
        .hz = .{
            .fractional_part = .none,
        },
    }, whole_part_token);
}

fn parseFractionalHertz(
    parser: *Parser,
) !Node.Index {
    const whole_part_token = parser.assertToken(.integer);
    _ = parser.assertToken(.period);
    const fractional_part_token = parser.assertToken(.integer);
    _ = parser.assertToken(.keyword_hz);

    return parser.appendNode(.{
        .hz = .{
            .fractional_part = .wrap(fractional_part_token),
        },
    }, whole_part_token);
}

fn parseRest(parser: *Parser) !Node.Index {
    const period_token = parser.assertToken(.period);
    return parser.appendNode(.rest, period_token);
}

fn parseMultiRatio(parser: *Parser, comptime mode: enum { raw_chord, chord, scale }) !Node.Index {
    const scratch_start = parser.pushScratch();

    const base_token = parser.assertToken(.integer);
    std.debug.assert(switch (parser.peekTag(0)) {
        .colon, .colon_colon => true,
        else => false,
    });

    while (try parser.parseMultiRatioPart()) |part| {
        try parser.appendNodeToScratch(part);
    }

    parser.skipWhitespace();

    switch (mode) {
        .raw_chord => {},
        .chord => _ = try parser.expectToken(.right_square),
        .scale => _ = try parser.expectToken(.right_curly),
    }

    return try parser.appendNode(@unionInit(
        Node.Data,
        switch (mode) {
            .raw_chord, .chord => "chord_multi_ratio",
            .scale => "scale_multi_ratio",
        },
        .{
            .extra = .{
                .children = @ptrCast(parser.popScratch(scratch_start)),
            },
        },
    ), base_token);
}

fn parseMultiRatioPart(parser: *Parser) !?Node.Index {
    return switch (parser.peekTag(0)) {
        .colon => switch (parser.peekTag(1)) {
            .integer => {
                _ = parser.assertToken(.colon);
                return try parser.appendNode(.single_colon_multi_ratio_part, parser.assertToken(.integer));
            },
            else => null,
        },
        .colon_colon => switch (parser.peekTag(1)) {
            .integer => {
                _ = parser.assertToken(.colon_colon);
                return try parser.appendNode(.double_colon_multi_ratio_part, parser.assertToken(.integer));
            },
            else => null,
        },
        else => null,
    };
}

fn nextToken(parser: *Parser) Token.Index {
    const token_index = parser.token_index;
    std.debug.assert(@intFromEnum(token_index) < parser.tokens.slice.len);
    parser.token_index = @enumFromInt(@intFromEnum(token_index) + 1);
    return token_index;
}

/// Assumes that overflows are impossible as a peekTag(0) == .eof
/// will always stop a peekTag(1). Dubious assumption? Perhaps.
fn peekTag(parser: *Parser, n: usize) Token.Tag {
    const index = @intFromEnum(parser.token_index) + n;
    return parser.tokens.tag(@enumFromInt(index));
}

fn eatToken(parser: *Parser, tag: Token.Tag) ?Token.Index {
    return if (parser.peekTag(0) == tag)
        parser.nextToken()
    else
        null;
}

fn expectToken(parser: *Parser, tag: Token.Tag) !Token.Index {
    return if (parser.eatToken(tag)) |token|
        token
    else {
        // try parser.errors.append(parser.allocator, .{
        //     .tag = .expected_tag,
        //     .token = next_token,
        //     .data = .{ .expected_tag = tag },
        // });
        return error.ParseError;
    };
}

fn skipWhitespace(parser: *Parser) void {
    _ = parser.eatToken(.whitespace);
    std.debug.assert(parser.peekTag(0) != .whitespace);
}

fn assertToken(parser: *Parser, tag: Token.Tag) Token.Index {
    const next_token = parser.nextToken();
    std.debug.assert(parser.tokens.tag(next_token) == tag);
    return next_token;
}

const ScratchIndex = enum(u32) { _ };

fn pushScratch(parser: *const Parser) ScratchIndex {
    return @enumFromInt(parser.scratch.items.len);
}

fn popScratch(parser: *Parser, scratch_start: ScratchIndex) []u32 {
    defer parser.scratch.items.len = @intFromEnum(scratch_start);
    return parser.scratch.items[@intFromEnum(scratch_start)..];
}

fn appendNodeToScratch(parser: *Parser, node: Node.Index) !void {
    return parser.scratch.append(parser.allocator, @intFromEnum(node));
}

fn appendNode(parser: *Parser, data: Node.Data, main_token: ?Token.Index) !Node.Index {
    try parser.nodes.append(parser.allocator, .{
        .tag = data,
        .main_token = .wrap(main_token),
        .untagged_data = switch (data) {
            inline else => |value, tag| blk: {
                const T = @TypeOf(value);

                if (@typeInfo(T) != .@"struct" or !@hasField(T, "extra")) {
                    break :blk @unionInit(Node.Data.Untagged, @tagName(tag), value);
                } else {
                    const extra = @field(value, "extra");
                    const start: Ast.ExtraIndex = @enumFromInt(parser.extra.items.len);
                    inline for (std.meta.fields(@TypeOf(extra))) |field| {
                        switch (field.type) {
                            Token.Index, Node.Index, Token.OptionalIndex => try parser.extra.append(
                                parser.allocator,
                                @intFromEnum(@field(extra, field.name)),
                            ),
                            []const Node.Index => {
                                try parser.extra.append(
                                    parser.allocator,
                                    @intCast(@field(extra, field.name).len),
                                );
                                try parser.extra.appendSlice(
                                    parser.allocator,
                                    @ptrCast(@field(extra, field.name)),
                                );
                            },
                            else => @compileError("TODO: " ++ @typeName(field.type)),
                        }
                    }
                    break :blk @unionInit(Node.Data.Untagged, @tagName(tag), .{
                        .start = start,
                        .end = @enumFromInt(parser.extra.items.len),
                    });
                }
            },
        },
    });
    return @enumFromInt(parser.nodes.len - 1);
}
