const std = @import("std");
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;
const Tokens = Tokenizer.Tokens;
const Ast = @import("Ast.zig");
const Node = Ast.Node;
const NoteSpool = @import("NoteSpool.zig");
const Note = NoteSpool.Note;
const assert = std.debug.assert;

const AstToSpool = @This();

allocator: std.mem.Allocator,
source: []const u8,
tokens: *const Tokens,
ast: *const Ast,
sample_rate: f32,
notes: std.MultiArrayList(Note) = .{},

bpm: f32 = 120,
beat_division: f32 = 2,

root_frequency: f32 = 220,
scale_ratios: std.ArrayListUnmanaged(f32) = .{},
equave: f32 = 2,

sample_offset: u32 = 0,

const EquaveExponent = enum(i32) { _ };
const LengthModifier = enum(u32) { _ };

pub fn astToSpool(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: *const Tokens,
    ast: *const Ast,
    sample_rate: f32,
) !NoteSpool {
    var ast_to_spool = AstToSpool{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .ast = ast,
        .sample_rate = sample_rate,
    };
    try ast_to_spool.scale_ratios.ensureTotalCapacity(allocator, 1024);
    defer {
        ast_to_spool.scale_ratios.deinit(allocator);
    }

    for (0..12) |index| {
        ast_to_spool.scale_ratios.appendAssumeCapacity(std.math.pow(f32, 2, @as(f32, @floatFromInt(index)) / 12));
    }

    try ast_to_spool.astToSpoolInternal();

    return .{
        .notes = ast_to_spool.notes.toOwnedSlice(),
        .sample_rate = sample_rate,
    };
}

fn fractionOrIntegerToFloat(ast_to_spool: *AstToSpool, node: Node.Index) !f32 {
    return switch (ast_to_spool.ast.nodeData(node)) {
        .integer => @floatFromInt(try ast_to_spool.parseIntFromToken(ast_to_spool.ast.nodeMainToken(node).?)),
        .fraction => |info| blk: {
            const numerator: f32 = @floatFromInt(try ast_to_spool.parseIntFromToken(ast_to_spool.ast.nodeMainToken(node).?));
            const denominator: f32 = @floatFromInt(try ast_to_spool.parseIntFromToken(info.denominator));
            break :blk numerator / denominator;
        },
        else => unreachable,
    };
}

fn noteRatio(
    ast_to_spool: *AstToSpool,
    main_token: ?Token.Index,
    data: Node.Data,
    equave_exponent: EquaveExponent,
) !f32 {
    return switch (data) {
        .degree => blk: {
            assert(ast_to_spool.scale_ratios.items.len != 0);
            const degree = try ast_to_spool.parseIntFromToken(main_token.?);
            break :blk ast_to_spool.scale_ratios.items[degree % ast_to_spool.scale_ratios.items.len] *
                std.math.pow(
                    f32,
                    ast_to_spool.equave,
                    @as(f32, @floatFromInt(degree / ast_to_spool.scale_ratios.items.len)),
                );
        },
        .ratio => |info| blk: {
            const numerator: f32 = @floatFromInt(try ast_to_spool.parseIntFromToken(main_token.?));
            const denominator: f32 = @floatFromInt(try ast_to_spool.parseIntFromToken(info.denominator));
            if (denominator == 0) {
                return error.SpoolError;
            }
            break :blk numerator / denominator;
        },
        .cents => |info| blk: {
            const cents = try ast_to_spool.parseFloatFromTokens(main_token.?, info.fractional_part.unwrap());
            break :blk @exp2(cents / 1200);
        },
        .edostep => |info| blk: {
            const edostep: f32 = @floatFromInt(try ast_to_spool.parseIntFromToken(main_token.?));
            const divisions: f32 = @floatFromInt(try ast_to_spool.parseIntFromToken(info.divisions));
            if (divisions == 0) {
                return error.SpoolError;
            }
            break :blk std.math.pow(f32, 2, edostep / divisions);
        },
        .edxstep => |info| blk: {
            const edostep: f32 = @floatFromInt(try ast_to_spool.parseIntFromToken(main_token.?));
            const divisions: f32 = @floatFromInt(try ast_to_spool.parseIntFromToken(info.divisions));
            if (divisions == 0) {
                return error.SpoolError;
            }
            const equave: f32 = try ast_to_spool.fractionOrIntegerToFloat(info.equave);
            break :blk std.math.pow(f32, equave, edostep / divisions);
        },
        else => unreachable,
    } * std.math.pow(f32, ast_to_spool.equave, @floatFromInt(@intFromEnum(equave_exponent)));
}

fn noteFrequency(
    ast_to_spool: *AstToSpool,
    main_token: ?Token.Index,
    data: Node.Data,
    equave_exponent: EquaveExponent,
) !f32 {
    return switch (data) {
        .degree,
        .ratio,
        .cents,
        .edostep,
        .edxstep,
        => ast_to_spool.root_frequency * try ast_to_spool.noteRatio(main_token, data, equave_exponent),
        .hz => |info| try ast_to_spool.parseFloatFromTokens(main_token.?, info.fractional_part.unwrap()) *
            std.math.pow(f32, ast_to_spool.equave, @floatFromInt(@intFromEnum(equave_exponent))),
        else => unreachable,
    };
}

fn iterateMultiRatio(
    ast_to_spool: *const AstToSpool,
    main_token: Token.Index,
    data: anytype,
    context: anytype,
    callback: anytype,
) !void {
    const base = try ast_to_spool.parseIntFromToken(main_token);

    if (base == 0) {
        return error.SpoolError;
    }

    try callback(context, 1);

    var previous = base;
    for (data.children) |part| {
        switch (ast_to_spool.ast.nodeTag(part)) {
            .single_colon_multi_ratio_part => {
                const numerator = try ast_to_spool.parseIntFromToken(ast_to_spool.ast.nodeMainToken(part).?);
                previous = numerator;
                try callback(context, @as(f32, @floatFromInt(numerator)) / @as(f32, @floatFromInt(base)));
            },
            .double_colon_multi_ratio_part => {
                const end = try ast_to_spool.parseIntFromToken(ast_to_spool.ast.nodeMainToken(part).?);
                defer previous = end;

                if (previous < end) {
                    for (previous..end) |numerator_minus_one| {
                        try callback(context, @as(f32, @floatFromInt(numerator_minus_one + 1)) / @as(f32, @floatFromInt(base)));
                    }
                } else {
                    var numerator = previous - 1;
                    while (numerator >= end) : (numerator -= 1) {
                        try callback(context, @as(f32, @floatFromInt(numerator)) / @as(f32, @floatFromInt(base)));
                    }
                }
            },
            else => unreachable,
        }
    }
}

fn noteDurationInSamples(ast_to_spool: *const AstToSpool, length_modifier: LengthModifier) u32 {
    const modifier: f32 = @floatFromInt(@intFromEnum(length_modifier));
    return @intFromFloat((1 + modifier) * ast_to_spool.sample_rate / (ast_to_spool.bpm / 60) / ast_to_spool.beat_division);
}

fn noteStartEndInSamples(ast_to_spool: *AstToSpool, length_modifier: LengthModifier) struct { u32, u32 } {
    const duration = ast_to_spool.noteDurationInSamples(length_modifier);
    defer ast_to_spool.sample_offset += duration;
    return .{ ast_to_spool.sample_offset, ast_to_spool.sample_offset + duration };
}

fn astToSpoolInternal(ast_to_spool: *AstToSpool) !void {
    for (ast_to_spool.ast.nodeData(.root).root.children) |root_child_modified| {
        const root_child_modifiers, const root_child = ast_to_spool.extractModifiers(root_child_modified);

        const root_child_main_token = ast_to_spool.ast.nodeMainToken(root_child);
        const root_child_data = ast_to_spool.ast.nodeData(root_child);

        switch (root_child_data) {
            .degree, .ratio, .cents, .edostep, .edxstep, .hz => {
                const frequency = try ast_to_spool.noteFrequency(
                    root_child_main_token,
                    root_child_data,
                    root_child_modifiers.equave_exponent,
                );
                const start, const end = ast_to_spool.noteStartEndInSamples(root_child_modifiers.length_modifier);

                try ast_to_spool.notes.append(ast_to_spool.allocator, .{
                    .frequency = frequency,
                    .start = start,
                    .end = end,
                });
            },
            .chord => |info| {
                const start, const end = ast_to_spool.noteStartEndInSamples(root_child_modifiers.length_modifier);

                for (info.children) |chord_child_modified| {
                    const chord_child_modifiers, const chord_child = ast_to_spool.extractModifiers(chord_child_modified);
                    const chord_child_main_token = ast_to_spool.ast.nodeMainToken(chord_child);
                    const chord_child_data = ast_to_spool.ast.nodeData(chord_child);

                    assert(@intFromEnum(chord_child_modifiers.length_modifier) == 0);

                    const frequency = try ast_to_spool.noteFrequency(
                        chord_child_main_token,
                        chord_child_data,
                        @enumFromInt(@intFromEnum(chord_child_modifiers.equave_exponent) +
                            @intFromEnum(root_child_modifiers.equave_exponent)),
                    );

                    try ast_to_spool.notes.append(ast_to_spool.allocator, .{
                        .frequency = frequency,
                        .start = start,
                        .end = end,
                    });
                }
            },
            .chord_multi_ratio => |info| {
                const start, const end = ast_to_spool.noteStartEndInSamples(root_child_modifiers.length_modifier);

                const Context = struct {
                    ast_to_spool: *AstToSpool,
                    equave_exponent: EquaveExponent,
                    start: u32,
                    end: u32,

                    fn callback(context: @This(), ratio: f32) !void {
                        try context.ast_to_spool.notes.append(context.ast_to_spool.allocator, .{
                            .frequency = context.ast_to_spool.root_frequency *
                                ratio *
                                std.math.pow(f32, context.ast_to_spool.equave, @floatFromInt(@intFromEnum(context.equave_exponent))),
                            .start = context.start,
                            .end = context.end,
                        });
                    }
                };

                try ast_to_spool.iterateMultiRatio(
                    root_child_main_token.?,
                    info,
                    Context{
                        .ast_to_spool = ast_to_spool,
                        .equave_exponent = root_child_modifiers.equave_exponent,
                        .start = start,
                        .end = end,
                    },
                    Context.callback,
                );
            },
            .scale => |info| {
                assert(@intFromEnum(root_child_modifiers.length_modifier) == 0);

                // TODO: Smarter scale ratios memory management
                // Maybe a two buffer technique?
                var new_scale_ratios = try std.ArrayListUnmanaged(f32).initCapacity(
                    ast_to_spool.allocator,
                    info.children.len,
                );
                errdefer new_scale_ratios.deinit(ast_to_spool.allocator);

                const equave = if (info.equave.unwrap()) |equave|
                    try ast_to_spool.noteRatio(
                        ast_to_spool.ast.nodeMainToken(equave),
                        ast_to_spool.ast.nodeData(equave),
                        root_child_modifiers.equave_exponent,
                    )
                else
                    ast_to_spool.equave;

                for (info.children) |scale_child_modified| {
                    const scale_child_modifiers, const scale_child = ast_to_spool.extractModifiers(scale_child_modified);
                    const scale_child_main_token = ast_to_spool.ast.nodeMainToken(scale_child);
                    const scale_child_data = ast_to_spool.ast.nodeData(scale_child);

                    assert(@intFromEnum(scale_child_modifiers.length_modifier) == 0);

                    const ratio = try ast_to_spool.noteRatio(
                        scale_child_main_token,
                        scale_child_data,
                        @enumFromInt(@intFromEnum(scale_child_modifiers.equave_exponent) +
                            @intFromEnum(root_child_modifiers.equave_exponent)),
                    );

                    new_scale_ratios.appendAssumeCapacity(ratio);
                }

                ast_to_spool.scale_ratios.deinit(ast_to_spool.allocator);
                ast_to_spool.scale_ratios = new_scale_ratios;
                ast_to_spool.equave = equave;
            },
            .scale_multi_ratio => |info| {
                assert(@intFromEnum(root_child_modifiers.length_modifier) == 0);

                const Context = struct {
                    ast_to_spool: *AstToSpool,
                    equave_exponent: EquaveExponent,
                    new_scale_ratios: *std.ArrayListUnmanaged(f32),

                    fn callback(context: @This(), ratio: f32) !void {
                        try context.new_scale_ratios.append(
                            context.ast_to_spool.allocator,
                            ratio * std.math.pow(
                                f32,
                                context.ast_to_spool.equave,
                                @floatFromInt(@intFromEnum(context.equave_exponent)),
                            ),
                        );
                    }
                };

                var new_scale_ratios = try std.ArrayListUnmanaged(f32).initCapacity(
                    ast_to_spool.allocator,
                    info.children.len,
                );
                errdefer new_scale_ratios.deinit(ast_to_spool.allocator);

                try ast_to_spool.iterateMultiRatio(
                    root_child_main_token.?,
                    info,
                    Context{
                        .ast_to_spool = ast_to_spool,
                        .equave_exponent = root_child_modifiers.equave_exponent,
                        .new_scale_ratios = &new_scale_ratios,
                    },
                    Context.callback,
                );

                ast_to_spool.scale_ratios.deinit(ast_to_spool.allocator);
                ast_to_spool.scale_ratios = new_scale_ratios;
            },
            .scale_edo => {
                assert(@intFromEnum(root_child_modifiers.length_modifier) == 0);

                ast_to_spool.equave = 2;

                const divisions = try ast_to_spool.parseIntFromToken(root_child_main_token.?);

                ast_to_spool.scale_ratios.clearRetainingCapacity();
                try ast_to_spool.scale_ratios.ensureTotalCapacity(ast_to_spool.allocator, divisions);

                for (0..divisions) |index| {
                    ast_to_spool.scale_ratios.appendAssumeCapacity(@exp2(
                        @as(f32, @floatFromInt(@intFromEnum(root_child_modifiers.equave_exponent))) +
                            @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(divisions)),
                    ));
                }
            },
            .scale_edx => |info| {
                assert(@intFromEnum(root_child_modifiers.length_modifier) == 0);

                ast_to_spool.equave = try ast_to_spool.fractionOrIntegerToFloat(info.equave);

                const divisions = try ast_to_spool.parseIntFromToken(root_child_main_token.?);

                ast_to_spool.scale_ratios.clearRetainingCapacity();
                try ast_to_spool.scale_ratios.ensureTotalCapacity(ast_to_spool.allocator, divisions);

                for (0..divisions) |index| {
                    ast_to_spool.scale_ratios.appendAssumeCapacity(std.math.pow(
                        f32,
                        ast_to_spool.equave,
                        @as(f32, @floatFromInt(@intFromEnum(root_child_modifiers.equave_exponent))) +
                            @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(divisions)),
                    ));
                }
            },
            .root_frequency => |info| {
                assert(@intFromEnum(root_child_modifiers.length_modifier) == 0);

                const note_modifiers, const note = ast_to_spool.extractModifiers(info.child);
                const note_main_token = ast_to_spool.ast.nodeMainToken(note);
                const note_data = ast_to_spool.ast.nodeData(note);

                assert(@intFromEnum(note_modifiers.length_modifier) == 0);

                ast_to_spool.root_frequency = try ast_to_spool.noteFrequency(
                    note_main_token,
                    note_data,
                    @enumFromInt(@intFromEnum(root_child_modifiers.equave_exponent) +
                        @intFromEnum(note_modifiers.equave_exponent)),
                );
            },
            .rest => {
                ast_to_spool.sample_offset += ast_to_spool.noteDurationInSamples(@enumFromInt(0));
            },
            else => @panic("TODO"),
        }
    }
}

fn parseIntFromToken(ast_to_spool: *const AstToSpool, token: Token.Index) !u32 {
    return std.fmt.parseInt(
        u32,
        ast_to_spool.tokens.sliceSource(ast_to_spool.source, token),
        10,
    );
}

fn parseFloatFromTokens(
    ast_to_spool: *const AstToSpool,
    whole_part: Token.Index,
    fractional_part: ?Token.Index,
) !f32 {
    const start = ast_to_spool.tokens.range(whole_part).start;
    const end = ast_to_spool.tokens.range(fractional_part orelse whole_part).end;
    return std.fmt.parseFloat(f32, ast_to_spool.source[start..end]);
}

const Modifiers = struct {
    length_modifier: LengthModifier = @enumFromInt(0),
    equave_exponent: EquaveExponent = @enumFromInt(0),
};

fn extractModifiers(ast_to_spool: *const AstToSpool, node: Node.Index) struct { Modifiers, Node.Index } {
    return switch (ast_to_spool.ast.nodeData(node)) {
        .held => |held_info| switch (ast_to_spool.ast.nodeData(held_info.child)) {
            .equave_shifted => |equave_shifted_info| .{
                .{
                    .length_modifier = @enumFromInt(held_info.holds),
                    .equave_exponent = @enumFromInt(equave_shifted_info.equave_shift),
                },
                equave_shifted_info.child,
            },
            else => .{
                .{
                    .length_modifier = @enumFromInt(held_info.holds),
                },
                held_info.child,
            },
        },
        .equave_shifted => |equave_shifted_info| .{
            .{
                .equave_exponent = @enumFromInt(equave_shifted_info.equave_shift),
            },
            equave_shifted_info.child,
        },
        else => .{ .{}, node },
    };
}
