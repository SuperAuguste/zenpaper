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
    const scratch_start = parser.pushScratch();
    try parser.parseNotePrefixes();

    if (try parser.parseMultiRatio(scratch_start)) |node| {
        try parser.appendNodeToScratch(node);
        try parser.parseNoteSuffixes();
        return try parser.appendNode(.{
            .chord = .{
                .extra = .{
                    .children = @ptrCast(parser.popScratch(scratch_start)),
                },
            },
        }, null);
    }

    if (try parser.parseNote(.root, scratch_start)) |node| {
        return node;
    }

    return switch (parser.peekTag(0)) {
        .left_square => try parser.parseChord(scratch_start),
        .left_curly => switch (parser.peekTag(1)) {
            .keyword_r => try parser.parseRootFrequency(scratch_start),
            else => try parser.parseScale(scratch_start),
        },
        .period => try parser.parseRest(scratch_start),
        .eof => {
            if (!parser.isScratchEmptyFrom(scratch_start)) {
                return error.ParseError;
            }
            return null;
        },
        else => return error.ParseError,
    };
}

fn parseChord(parser: *Parser, scratch_start: ScratchIndex) !Node.Index {
    const left_square = parser.assertToken(.left_square);

    if (try parser.parseMultiRatio(scratch_start)) |node| {
        try parser.appendNodeToScratch(node);
    } else while (try parser.parseChordChild()) |node| {
        try parser.appendNodeToScratch(node);
    }

    _ = try parser.expectToken(.right_square);
    try parser.parseNoteSuffixes();

    return parser.appendNode(.{
        .chord = .{
            .extra = .{
                .children = @ptrCast(parser.popScratch(scratch_start)),
            },
        },
    }, left_square);
}

fn parseChordChild(parser: *Parser) !?Node.Index {
    const scratch_start = parser.pushScratch();
    try parser.parseNotePrefixes();

    if (try parser.parseNote(.chord, scratch_start)) |node| {
        return node;
    }

    return switch (parser.peekTag(0)) {
        .right_square => {
            if (!parser.isScratchEmptyFrom(scratch_start)) {
                return error.ParseError;
            }
            return null;
        },
        else => return error.ParseError,
    };
}

fn parseRootFrequency(parser: *Parser, scratch_start: ScratchIndex) !Node.Index {
    const left_curly = parser.assertToken(.left_curly);
    _ = parser.assertToken(.keyword_r);

    const note_scratch_start = parser.pushScratch();
    try parser.parseNotePrefixes();

    try parser.appendNodeToScratch(try parser.parseNote(
        .chord,
        note_scratch_start,
    ) orelse return error.ParseError);

    if (parser.peekTag(0) != .right_curly) return error.ParseError;
    _ = parser.nextToken();

    return parser.appendNode(.{
        .root_frequency = .{
            .extra = .{
                .children = @ptrCast(parser.popScratch(scratch_start)),
            },
        },
    }, left_curly);
}

fn parseScale(parser: *Parser, scratch_start: ScratchIndex) !Node.Index {
    const left_curly = parser.assertToken(.left_curly);

    if (try parser.parseMultiRatio(scratch_start)) |node| {
        try parser.appendNodeToScratch(node);
    } else while (try parser.parseScaleChild()) |node| {
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
    const scratch_start = parser.pushScratch();
    try parser.parseNotePrefixes();

    if (try parser.parseNote(.scale, scratch_start)) |node| {
        return node;
    }

    return switch (parser.peekTag(0)) {
        .right_curly => {
            if (!parser.isScratchEmptyFrom(scratch_start)) {
                return error.ParseError;
            }
            return null;
        },
        else => return error.ParseError,
    };
}

fn parseNote(
    parser: *Parser,
    comptime mode: enum { root, chord, scale },
    scratch_start: ScratchIndex,
) !?Node.Index {
    const note_suffix_behavior: NoteSuffixBehavior = switch (mode) {
        .root => .can_hold,
        else => .no_suffix,
    };

    return switch (parser.peekTag(0)) {
        .integer => switch (parser.peekTag(1)) {
            .slash => switch (parser.peekTag(2)) {
                .integer => try parser.parseRatio(scratch_start, note_suffix_behavior),
                else => error.ParseError,
            },
            .backslash => switch (parser.peekTag(2)) {
                .integer => switch (parser.peekTag(3)) {
                    .keyword_o => switch (parser.peekTag(4)) {
                        .integer => switch (parser.peekTag(5)) {
                            .slash => switch (parser.peekTag(6)) {
                                .integer => try parser.parseEdxstepFractionalEquave(scratch_start, note_suffix_behavior),
                                else => error.ParseError,
                            },
                            else => try parser.parseEdxstepWholeEquave(scratch_start, note_suffix_behavior),
                        },
                        else => error.ParseError,
                    },
                    else => try parser.parseEdostep(scratch_start, note_suffix_behavior),
                },
                else => error.ParseError,
            },
            .keyword_c => try parser.parseWholeCents(scratch_start, note_suffix_behavior),
            .keyword_hz => switch (mode) {
                .scale => error.ParseError,
                else => try parser.parseWholeHertz(scratch_start, note_suffix_behavior),
            },
            .period => switch (parser.peekTag(2)) {
                .integer => switch (parser.peekTag(3)) {
                    .keyword_c => try parser.parseFractionalCents(scratch_start, note_suffix_behavior),
                    .keyword_hz => switch (mode) {
                        .scale => error.ParseError,
                        else => try parser.parseFractionalHertz(scratch_start, note_suffix_behavior),
                    },
                    else => try parser.parseDegree(scratch_start, note_suffix_behavior),
                },
                else => try parser.parseDegree(scratch_start, note_suffix_behavior),
            },
            // .colon => switch (parser.peekTag(2)) {
            //     .integer => {
            //         const chord_start = try parser.startChordNoToken();
            //         continue :state_machine .{ .chord_ratio_no_square = .{ .chord_start = chord_start } };
            //     },
            //     else => return error.ParseError,
            // },
            // .colon_colon => switch (parser.peekTag(2)) {
            //     .integer => {
            //         const chord_start = try parser.startChordNoToken();
            //         try parser.parseMultiRatioShorthand();
            //         try parser.endChordNoToken(chord_start);
            //         continue :state_machine .start;
            //     },
            //     else => return error.ParseError,
            // },
            else => try parser.parseDegree(scratch_start, note_suffix_behavior),
        },
        else => null,
    };
}

fn parseNotePrefixes(parser: *Parser) !void {
    const State = enum { start, equave_up_one, equave_up_two, equave_down };
    state_machine: switch (State.start) {
        .start => switch (parser.peekTag(0)) {
            .whitespace => {
                _ = parser.nextToken();
                continue :state_machine .start;
            },
            .single_quote => continue :state_machine .equave_up_one,
            .double_quote => continue :state_machine .equave_up_two,
            .backtick => continue :state_machine .equave_down,
            else => break :state_machine,
        },
        .equave_up_one => {
            try parser.appendNodeToScratch(
                try parser.appendNode(.equave_up_one, parser.assertToken(.single_quote)),
            );

            switch (parser.peekTag(0)) {
                .single_quote => continue :state_machine .equave_up_one,
                .double_quote => continue :state_machine .equave_up_two,
                .backtick => return error.ParseError,
                else => break :state_machine,
            }
        },
        .equave_up_two => {
            try parser.appendNodeToScratch(
                try parser.appendNode(.equave_up_two, parser.assertToken(.double_quote)),
            );

            switch (parser.peekTag(0)) {
                .single_quote => continue :state_machine .equave_up_one,
                .double_quote => continue :state_machine .equave_up_two,
                .backtick => return error.ParseError,
                else => break :state_machine,
            }
        },
        .equave_down => {
            try parser.appendNodeToScratch(
                try parser.appendNode(.equave_down, parser.assertToken(.backtick)),
            );

            switch (parser.peekTag(0)) {
                .backtick => continue :state_machine .equave_down,
                .single_quote, .double_quote => return error.ParseError,
                else => break :state_machine,
            }
        },
    }
}

fn parseNoteSuffixes(parser: *Parser) !void {
    while (parser.peekTag(0) == .dash) {
        try parser.appendNodeToScratch(
            try parser.appendNode(.hold, parser.nextToken()),
        );
    }
}

const NoteSuffixBehavior = enum { no_suffix, can_hold };
fn parseDegree(
    parser: *Parser,
    scratch_start: ScratchIndex,
    comptime note_suffix_behavior: NoteSuffixBehavior,
) !Node.Index {
    const degree_token = parser.assertToken(.integer);

    switch (note_suffix_behavior) {
        .no_suffix => {},
        .can_hold => try parser.parseNoteSuffixes(),
    }

    return parser.appendNode(.{
        .degree = .{
            .extra = .{
                .children = @ptrCast(parser.popScratch(scratch_start)),
            },
        },
    }, degree_token);
}

fn parseRatio(
    parser: *Parser,
    scratch_start: ScratchIndex,
    comptime note_suffix_behavior: NoteSuffixBehavior,
) !Node.Index {
    const numerator_token = parser.assertToken(.integer);
    _ = parser.assertToken(.slash);
    const denominator_token = parser.assertToken(.integer);

    switch (note_suffix_behavior) {
        .no_suffix => {},
        .can_hold => try parser.parseNoteSuffixes(),
    }

    return parser.appendNode(.{
        .ratio = .{
            .extra = .{
                .denominator = denominator_token,
                .children = @ptrCast(parser.popScratch(scratch_start)),
            },
        },
    }, numerator_token);
}

fn parseWholeCents(
    parser: *Parser,
    scratch_start: ScratchIndex,
    comptime note_suffix_behavior: NoteSuffixBehavior,
) !Node.Index {
    const whole_part_token = parser.assertToken(.integer);
    _ = parser.assertToken(.keyword_c);

    switch (note_suffix_behavior) {
        .no_suffix => {},
        .can_hold => try parser.parseNoteSuffixes(),
    }

    return parser.appendNode(.{
        .cents = .{
            .extra = .{
                .fractional_part = null,
                .children = @ptrCast(parser.popScratch(scratch_start)),
            },
        },
    }, whole_part_token);
}

fn parseFractionalCents(
    parser: *Parser,
    scratch_start: ScratchIndex,
    comptime note_suffix_behavior: NoteSuffixBehavior,
) !Node.Index {
    const whole_part_token = parser.assertToken(.integer);
    _ = parser.assertToken(.period);
    const fractional_part_token = parser.assertToken(.integer);
    _ = parser.assertToken(.keyword_c);

    switch (note_suffix_behavior) {
        .no_suffix => {},
        .can_hold => try parser.parseNoteSuffixes(),
    }

    return parser.appendNode(.{
        .cents = .{
            .extra = .{
                .fractional_part = fractional_part_token,
                .children = @ptrCast(parser.popScratch(scratch_start)),
            },
        },
    }, whole_part_token);
}

fn parseEdostep(
    parser: *Parser,
    scratch_start: ScratchIndex,
    comptime note_suffix_behavior: NoteSuffixBehavior,
) !Node.Index {
    const edostep_token = parser.assertToken(.integer);
    _ = parser.assertToken(.backslash);
    const divisions_token = parser.assertToken(.integer);

    switch (note_suffix_behavior) {
        .no_suffix => {},
        .can_hold => try parser.parseNoteSuffixes(),
    }

    return parser.appendNode(.{
        .edostep = .{
            .extra = .{
                .divisions = divisions_token,
                .children = @ptrCast(parser.popScratch(scratch_start)),
            },
        },
    }, edostep_token);
}

fn parseInteger(parser: *Parser) !Node.Index {
    return parser.appendNode(.integer, parser.assertToken(.integer));
}

fn parseEdxstepWholeEquave(
    parser: *Parser,
    scratch_start: ScratchIndex,
    comptime note_suffix_behavior: NoteSuffixBehavior,
) !Node.Index {
    const edostep_token = parser.assertToken(.integer);
    _ = parser.assertToken(.backslash);
    const divisions_token = parser.assertToken(.integer);
    _ = parser.assertToken(.keyword_o);
    const equave = try parser.parseInteger();

    switch (note_suffix_behavior) {
        .no_suffix => {},
        .can_hold => try parser.parseNoteSuffixes(),
    }

    return parser.appendNode(.{
        .edxstep = .{
            .extra = .{
                .divisions = divisions_token,
                .equave = equave,
                .children = @ptrCast(parser.popScratch(scratch_start)),
            },
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

fn parseEdxstepFractionalEquave(
    parser: *Parser,
    scratch_start: ScratchIndex,
    comptime note_suffix_behavior: NoteSuffixBehavior,
) !Node.Index {
    const edostep_token = parser.assertToken(.integer);
    _ = parser.assertToken(.backslash);
    const divisions_token = parser.assertToken(.integer);
    _ = parser.assertToken(.keyword_o);
    const equave = try parser.parseFraction();

    switch (note_suffix_behavior) {
        .no_suffix => {},
        .can_hold => try parser.parseNoteSuffixes(),
    }

    return parser.appendNode(.{
        .edxstep = .{
            .extra = .{
                .divisions = divisions_token,
                .equave = equave,
                .children = @ptrCast(parser.popScratch(scratch_start)),
            },
        },
    }, edostep_token);
}

fn parseWholeHertz(
    parser: *Parser,
    scratch_start: ScratchIndex,
    comptime note_suffix_behavior: NoteSuffixBehavior,
) !Node.Index {
    const whole_part_token = parser.assertToken(.integer);
    _ = parser.assertToken(.keyword_hz);

    switch (note_suffix_behavior) {
        .no_suffix => {},
        .can_hold => try parser.parseNoteSuffixes(),
    }

    return parser.appendNode(.{
        .hz = .{
            .extra = .{
                .fractional_part = null,
                .children = @ptrCast(parser.popScratch(scratch_start)),
            },
        },
    }, whole_part_token);
}

fn parseFractionalHertz(
    parser: *Parser,
    scratch_start: ScratchIndex,
    comptime note_suffix_behavior: NoteSuffixBehavior,
) !Node.Index {
    const whole_part_token = parser.assertToken(.integer);
    _ = parser.assertToken(.period);
    const fractional_part_token = parser.assertToken(.integer);
    _ = parser.assertToken(.keyword_hz);

    switch (note_suffix_behavior) {
        .no_suffix => {},
        .can_hold => try parser.parseNoteSuffixes(),
    }

    return parser.appendNode(.{
        .hz = .{
            .extra = .{
                .fractional_part = fractional_part_token,
                .children = @ptrCast(parser.popScratch(scratch_start)),
            },
        },
    }, whole_part_token);
}

fn parseRest(parser: *Parser, scratch_start: ScratchIndex) !Node.Index {
    if (!parser.isScratchEmptyFrom(scratch_start)) {
        return error.ParseError;
    }

    const period_token = parser.assertToken(.period);
    return parser.appendNode(.rest, period_token);
}

fn parseMultiRatio(parser: *Parser, scratch_start: ScratchIndex) !?Node.Index {
    switch (parser.peekTag(0)) {
        .integer => switch (parser.peekTag(1)) {
            .colon, .colon_colon => {},
            else => return null,
        },
        else => return null,
    }

    const base_token = parser.assertToken(.integer);

    while (try parser.parseMultiRatioPart()) |part| {
        try parser.appendNodeToScratch(part);
    }

    return try parser.appendNode(.{
        .multi_ratio = .{
            .extra = .{
                .children = @ptrCast(parser.popScratch(scratch_start)),
            },
        },
    }, base_token);
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

fn expectToken(parser: *Parser, tag: Token.Tag) !Token.Index {
    const next_token = parser.nextToken();
    return if (parser.tokens.tag(next_token) == tag)
        next_token
    else {
        // try parser.errors.append(parser.allocator, .{
        //     .tag = .expected_tag,
        //     .token = next_token,
        //     .data = .{ .expected_tag = tag },
        // });
        return error.ParseError;
    };
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

fn isScratchEmptyFrom(parser: *const Parser, scratch_start: ScratchIndex) bool {
    return parser.scratch.items.len == @intFromEnum(scratch_start);
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
                            Token.Index, Node.Index => try parser.extra.append(
                                parser.allocator,
                                @intFromEnum(@field(extra, field.name)),
                            ),
                            ?Token.Index => try parser.extra.append(
                                parser.allocator,
                                @intFromEnum(Token.OptionalIndex.wrap(@field(extra, field.name))),
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
