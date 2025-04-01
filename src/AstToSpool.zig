const std = @import("std");
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;
const Tokens = Tokenizer.Tokens;
const Ast = @import("Ast.zig");
const Node = Ast.Node;
const NoteSpool = @import("NoteSpool.zig");
const Note = NoteSpool.Note;
const assert = std.debug.assert;

const FirToSpool = @This();

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

const EquaveExponent = enum(i8) { _ };
const NoteLengthModifier = enum(u8) { _ };

pub fn astToSpool(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: *const Tokens,
    ast: *const Ast,
    sample_rate: f32,
) !NoteSpool {
    var fts = FirToSpool{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .ast = ast,
        .sample_rate = sample_rate,
    };
    try fts.scale_ratios.ensureTotalCapacity(allocator, 1024);
    defer {
        fts.scale_ratios.deinit(allocator);
    }

    for (0..12) |index| {
        fts.scale_ratios.appendAssumeCapacity(std.math.pow(f32, 2, @as(f32, @floatFromInt(index)) / 12));
    }

    try fts.firToSpoolInternal();

    return .{
        .notes = fts.notes.toOwnedSlice(),
        .sample_rate = sample_rate,
    };
}

fn fractionOrIntegerToFloat(fts: *FirToSpool, node: Node.Index) !f32 {
    return switch (fts.ast.nodeData(node)) {
        .integer => @floatFromInt(try fts.parseIntFromToken(fts.ast.nodeMainToken(node).?)),
        .fraction => |info| blk: {
            const numerator: f32 = @floatFromInt(try fts.parseIntFromToken(fts.ast.nodeMainToken(node).?));
            const denominator: f32 = @floatFromInt(try fts.parseIntFromToken(info.denominator));
            break :blk numerator / denominator;
        },
        else => unreachable,
    };
}

fn noteRatio(
    fts: *FirToSpool,
    main_token: ?Token.Index,
    data: Node.Data,
    equave_exponent: EquaveExponent,
) !f32 {
    return switch (data) {
        .degree => blk: {
            assert(fts.scale_ratios.items.len != 0);
            const degree = try fts.parseIntFromToken(main_token.?);
            break :blk fts.scale_ratios.items[degree % fts.scale_ratios.items.len] *
                std.math.pow(
                    f32,
                    fts.equave,
                    @as(f32, @floatFromInt(degree / fts.scale_ratios.items.len)),
                );
        },
        .ratio => |info| blk: {
            const numerator: f32 = @floatFromInt(try fts.parseIntFromToken(main_token.?));
            const denominator: f32 = @floatFromInt(try fts.parseIntFromToken(info.extra.denominator));
            if (denominator == 0) {
                return error.SpoolError;
            }
            break :blk numerator / denominator;
        },
        .cents => |info| blk: {
            const cents = try fts.parseFloatFromTokens(main_token.?, info.extra.fractional_part);
            break :blk @exp2(cents / 1200);
        },
        .edostep => |info| blk: {
            const edostep: f32 = @floatFromInt(try fts.parseIntFromToken(main_token.?));
            const divisions: f32 = @floatFromInt(try fts.parseIntFromToken(info.extra.divisions));
            if (divisions == 0) {
                return error.SpoolError;
            }
            break :blk std.math.pow(f32, 2, edostep / divisions);
        },
        .edxstep => |info| blk: {
            const edostep: f32 = @floatFromInt(try fts.parseIntFromToken(main_token.?));
            const divisions: f32 = @floatFromInt(try fts.parseIntFromToken(info.extra.divisions));
            if (divisions == 0) {
                return error.SpoolError;
            }
            const equave: f32 = try fts.fractionOrIntegerToFloat(info.extra.equave);
            break :blk std.math.pow(f32, equave, edostep / divisions);
        },
        else => unreachable,
    } * std.math.pow(f32, fts.equave, @floatFromInt(@intFromEnum(equave_exponent)));
}

fn noteFrequency(
    fts: *FirToSpool,
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
        => fts.root_frequency * try fts.noteRatio(main_token, data, equave_exponent),
        .hz => |info| try fts.parseFloatFromTokens(main_token.?, info.extra.fractional_part) *
            std.math.pow(f32, fts.equave, @floatFromInt(@intFromEnum(equave_exponent))),
        else => unreachable,
    };
}

fn iterateMultiRatio(
    fts: *const FirToSpool,
    main_token: Token.Index,
    data: @FieldType(Node.Data, "multi_ratio"),
    context: anytype,
    callback: anytype,
) !void {
    const base = try fts.parseIntFromToken(main_token);

    if (base == 0) {
        return error.SpoolError;
    }

    try callback(context, 1);

    var previous = base;
    for (data.extra.children) |part| {
        switch (fts.ast.nodeTag(part)) {
            .single_colon_multi_ratio_part => {
                const numerator = try fts.parseIntFromToken(fts.ast.nodeMainToken(part).?);
                previous = numerator;
                try callback(context, @as(f32, @floatFromInt(numerator)) / @as(f32, @floatFromInt(base)));
            },
            .double_colon_multi_ratio_part => {
                const end = try fts.parseIntFromToken(fts.ast.nodeMainToken(part).?);
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

fn noteDurationInSamples(fts: *const FirToSpool, note_length_modifier: NoteLengthModifier) u32 {
    const modifier: f32 = @floatFromInt(@intFromEnum(note_length_modifier));
    return @intFromFloat((1 + modifier) * fts.sample_rate / (fts.bpm / 60) / fts.beat_division);
}

fn noteStartEndInSamples(fts: *FirToSpool, note_length_modifier: NoteLengthModifier) struct { u32, u32 } {
    const duration = fts.noteDurationInSamples(note_length_modifier);
    defer fts.sample_offset += duration;
    return .{ fts.sample_offset, fts.sample_offset + duration };
}

fn firToSpoolInternal(fts: *FirToSpool) !void {
    for (fts.ast.nodeData(.root).root.extra.children) |child| {
        const main_token = fts.ast.nodeMainToken(child);
        const data = fts.ast.nodeData(child);

        switch (data) {
            .degree, .ratio, .cents, .edostep, .edxstep, .hz => {
                const child_info = fts.childInfo(data.children().?);
                assert(child_info.other_children.len == 0);

                const frequency = try fts.noteFrequency(main_token, data, child_info.equave_exponent);
                const start, const end = fts.noteStartEndInSamples(child_info.note_length_modifier);

                try fts.notes.append(fts.allocator, .{
                    .frequency = frequency,
                    .start = start,
                    .end = end,
                });
            },
            .chord => |info| {
                const chord_child_info = fts.childInfo(info.extra.children);
                const start, const end = fts.noteStartEndInSamples(chord_child_info.note_length_modifier);

                for (chord_child_info.other_children) |note| {
                    const note_main_token = fts.ast.nodeMainToken(note);
                    const note_data = fts.ast.nodeData(note);

                    if (note_data == .multi_ratio) {
                        assert(chord_child_info.other_children.len == 1);

                        const Context = struct {
                            fts: *FirToSpool,
                            chord_child_info: ChildInfo,
                            start: u32,
                            end: u32,

                            fn callback(context: @This(), ratio: f32) !void {
                                try context.fts.notes.append(context.fts.allocator, .{
                                    .frequency = context.fts.root_frequency *
                                        ratio *
                                        std.math.pow(f32, context.fts.equave, @floatFromInt(@intFromEnum(context.chord_child_info.equave_exponent))),
                                    .start = context.start,
                                    .end = context.end,
                                });
                            }
                        };

                        try fts.iterateMultiRatio(
                            note_main_token.?,
                            note_data.multi_ratio,
                            Context{
                                .fts = fts,
                                .chord_child_info = chord_child_info,
                                .start = start,
                                .end = end,
                            },
                            Context.callback,
                        );

                        break;
                    }

                    const note_child_info = fts.childInfo(note_data.children().?);
                    assert(note_child_info.other_children.len == 0);
                    assert(@intFromEnum(note_child_info.note_length_modifier) == 0);

                    const frequency = try fts.noteFrequency(
                        note_main_token,
                        note_data,
                        @enumFromInt(@intFromEnum(chord_child_info.equave_exponent) +
                            @intFromEnum(note_child_info.equave_exponent)),
                    );

                    try fts.notes.append(fts.allocator, .{
                        .frequency = frequency,
                        .start = start,
                        .end = end,
                    });
                }
            },
            .scale => |info| {
                const scale_child_info = fts.childInfo(info.extra.children);
                assert(@intFromEnum(scale_child_info.note_length_modifier) == 0);

                // TODO: this leaks
                var new_scale_ratios = try std.ArrayListUnmanaged(f32).initCapacity(fts.allocator, scale_child_info.other_children.len);

                for (scale_child_info.other_children) |note| {
                    const note_main_token = fts.ast.nodeMainToken(note);
                    const note_data = fts.ast.nodeData(note);

                    if (note_data == .multi_ratio) {
                        assert(scale_child_info.other_children.len == 1);

                        const Context = struct {
                            fts: *FirToSpool,
                            scale_child_info: ChildInfo,
                            new_scale_ratios: *std.ArrayListUnmanaged(f32),

                            fn callback(context: @This(), ratio: f32) !void {
                                try context.new_scale_ratios.append(
                                    context.fts.allocator,
                                    ratio * std.math.pow(
                                        f32,
                                        context.fts.equave,
                                        @floatFromInt(@intFromEnum(context.scale_child_info.equave_exponent)),
                                    ),
                                );
                            }
                        };

                        try fts.iterateMultiRatio(
                            note_main_token.?,
                            note_data.multi_ratio,
                            Context{
                                .fts = fts,
                                .scale_child_info = scale_child_info,
                                .new_scale_ratios = &new_scale_ratios,
                            },
                            Context.callback,
                        );

                        break;
                    }

                    const note_child_info = fts.childInfo(note_data.children().?);
                    assert(note_child_info.other_children.len == 0);
                    assert(@intFromEnum(note_child_info.note_length_modifier) == 0);

                    const ratio = try fts.noteRatio(
                        note_main_token,
                        note_data,
                        @enumFromInt(@intFromEnum(scale_child_info.equave_exponent) +
                            @intFromEnum(note_child_info.equave_exponent)),
                    );

                    new_scale_ratios.appendAssumeCapacity(ratio);
                }

                // TODO: eww memory management
                fts.scale_ratios.deinit(fts.allocator);
                fts.scale_ratios = new_scale_ratios;
            },
            .scale_edo => {
                const divisions = try fts.parseIntFromToken(main_token.?);

                // TODO: this leaks
                var new_scale_ratios = try std.ArrayListUnmanaged(f32).initCapacity(fts.allocator, divisions);

                for (0..divisions) |index| {
                    new_scale_ratios.appendAssumeCapacity(@exp2(@as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(divisions))));
                }

                fts.scale_ratios = new_scale_ratios;
            },
            .root_frequency => |info| {
                const root_frequency_child_info = fts.childInfo(info.extra.children);
                assert(@intFromEnum(root_frequency_child_info.note_length_modifier) == 0);
                assert(root_frequency_child_info.other_children.len == 1);

                const note = root_frequency_child_info.other_children[0];
                const note_main_token = fts.ast.nodeMainToken(note);
                const note_data = fts.ast.nodeData(note);

                const note_child_info = fts.childInfo(note_data.children().?);
                assert(note_child_info.other_children.len == 0);
                assert(@intFromEnum(note_child_info.note_length_modifier) == 0);

                fts.root_frequency = try fts.noteFrequency(
                    note_main_token,
                    note_data,
                    @enumFromInt(@intFromEnum(root_frequency_child_info.equave_exponent) +
                        @intFromEnum(note_child_info.equave_exponent)),
                );
            },
            .rest => {
                fts.sample_offset += fts.noteDurationInSamples(@enumFromInt(0));
            },

            else => @panic("TODO"),
        }
    }
}

fn parseIntFromToken(fts: *const FirToSpool, token: Token.Index) !u16 {
    return std.fmt.parseInt(
        u16,
        fts.tokens.sliceSource(fts.source, token),
        10,
    );
}

fn parseFloatFromTokens(
    fts: *const FirToSpool,
    whole_part: Token.Index,
    fractional_part: ?Token.Index,
) !f32 {
    const start = fts.tokens.range(whole_part).start;
    const end = fts.tokens.range(fractional_part orelse whole_part).end;
    return std.fmt.parseFloat(f32, fts.source[start..end]);
}

const ChildInfo = struct {
    equave_exponent: EquaveExponent,
    other_children: []const Node.Index,
    note_length_modifier: NoteLengthModifier,
};

fn childInfo(fts: *const FirToSpool, children: []const Node.Index) ChildInfo {
    const State = enum { equave_exponents, other_children, note_length_modifiers };

    var index: usize = 0;
    var state = State.equave_exponents;

    var equave_exponent: i8 = 0;
    var other_children_start: usize = 0;
    var other_children_end: usize = 0;
    var note_length_modifier: u8 = 0;

    while (index < children.len) : (index += 1) {
        const child = children[index];
        const child_tag = fts.ast.nodeTag(child);

        state = state_machine: switch (state) {
            // TODO: Assert up/down unique
            .equave_exponents => switch (child_tag) {
                .equave_up_one => {
                    equave_exponent += 1;
                    break :state_machine .equave_exponents;
                },
                .equave_up_two => {
                    equave_exponent += 2;
                    break :state_machine .equave_exponents;
                },
                .equave_down => {
                    equave_exponent += -1;
                    break :state_machine .equave_exponents;
                },
                else => {
                    other_children_start = index;
                    continue :state_machine .other_children;
                },
            },
            .other_children => switch (child_tag) {
                .equave_up_one, .equave_up_two, .equave_down => unreachable,
                .hold => {
                    other_children_end = index;
                    continue :state_machine .note_length_modifiers;
                },
                else => .other_children,
            },
            .note_length_modifiers => switch (child_tag) {
                else => unreachable,
                .hold => {
                    note_length_modifier += 1;
                    break :state_machine .note_length_modifiers;
                },
            },
        };
    }

    if (state == .other_children) {
        other_children_end = index;
    }

    return .{
        .equave_exponent = @enumFromInt(equave_exponent),
        .other_children = children[other_children_start..other_children_end],
        .note_length_modifier = @enumFromInt(note_length_modifier),
    };
}
