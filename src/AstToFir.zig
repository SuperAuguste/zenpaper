const std = @import("std");
const Fir = @import("Fir.zig");
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;
const Tokens = Tokenizer.Tokens;
const Ast = @import("Ast.zig");
const Node = Ast.Node;
const assert = std.debug.assert;
const Instruction = Fir.Instruction;
const Tone = Fir.Tone;
const EquaveExponent = Fir.EquaveExponent;
const LengthModifier = Fir.LengthModifier;

const AstToFir = @This();

allocator: std.mem.Allocator,
source: []const u8,
tokens: *const Tokens,
ast: *const Ast,

instructions: std.MultiArrayList(Instruction),
tones: std.MultiArrayList(Tone),
extra: std.ArrayListUnmanaged(u32),

root_frequency: Tone.Index,
equave: Tone.Index,
scale: Instruction.Index,

tones_started: bool,

pub fn astToFir(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: *const Tokens,
    ast: *const Ast,
) !Fir {
    assert(ast.errors.len == 0);

    var ast_to_fir = AstToFir{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .ast = ast,

        .instructions = .empty,
        .tones = .empty,
        .extra = .empty,

        .root_frequency = @enumFromInt(1 + 12),
        .equave = @enumFromInt(0),
        .scale = @enumFromInt(0),

        .tones_started = false,
    };

    // Initialize default equave and scale.

    // Raw append as equave is missing so appendTone cannot be used yet.
    const equave: Tone.Index = blk: {
        try ast_to_fir.tones.append(ast_to_fir.allocator, .{
            .tag = .ratio,
            .untagged_data = try .fromTagged(ast_to_fir.allocator, &ast_to_fir.extra, .{
                .ratio = .{
                    .equave_exponent = @enumFromInt(0),
                    .ratio = .{
                        .numerator = 2,
                        .denominator = 1,
                    },
                },
            }),
            .src_node = .none,
            .instruction = @enumFromInt(0),
            .value = 2,
        });
        break :blk @enumFromInt(ast_to_fir.tones.len - 1);
    };
    assert(equave == ast_to_fir.equave);

    const scale_tones_start = ast_to_fir.startTones();

    for (0..12) |index| {
        _ = try ast_to_fir.appendTone(.{
            .edostep = .{
                .equave_exponent = @enumFromInt(0),
                .edostep = @intCast(index),
                .divisions = 12,
            },
        }, .{
            .value_kind = .ratio,
            .instruction_equave_exponent = @enumFromInt(0),
            .src_node = null,
        });
    }

    const scale_tones = ast_to_fir.endTones(scale_tones_start);

    const scale = try ast_to_fir.appendInstruction(.{
        .scale = .{
            .equave_exponent = @enumFromInt(0),
            .tones = scale_tones,
            .equave = .wrap(equave),
        },
    }, null);
    assert(scale == ast_to_fir.scale);

    // Initialize default root frequency.

    const root_frequency = try ast_to_fir.appendTone(.{
        .hz = .{
            .equave_exponent = @enumFromInt(0),
            .frequency = 220,
        },
    }, .{
        .value_kind = .frequency,
        .instruction_equave_exponent = @enumFromInt(0),
        .src_node = null,
    });
    assert(root_frequency == ast_to_fir.root_frequency);

    _ = try ast_to_fir.appendInstruction(.{
        .root_frequency = .{
            .equave_exponent = @enumFromInt(0),
            // Self-referential but not problematic as hz values do not depend on root_frequency.
            .root_frequency = root_frequency,
            .tone = root_frequency,
        },
    }, null);

    try ast_to_fir.astToFirInternal();

    return .{
        .instructions = ast_to_fir.instructions.toOwnedSlice(),
        .tones = ast_to_fir.tones.toOwnedSlice(),
        .extra = try ast_to_fir.extra.toOwnedSlice(allocator),
    };
}

fn astToFirInternal(ast_to_fir: *AstToFir) !void {
    for (ast_to_fir.ast.nodeData(.root).root.children) |root_child_held| {
        const root_child_equave_shifted, const root_child_length_modifier = ast_to_fir.extractHeld(root_child_held);
        const root_child, const root_child_equave_exponent = ast_to_fir.extractEquaveShifted(root_child_equave_shifted);
        const root_child_main_token = ast_to_fir.ast.nodeMainToken(root_child);
        const root_child_data = ast_to_fir.ast.nodeData(root_child);

        switch (root_child_data) {
            .degree, .ratio, .cents, .edostep, .edxstep, .hz => {
                _ = try ast_to_fir.appendInstruction(.{
                    .note = .{
                        .root_frequency = ast_to_fir.root_frequency,
                        .tone = try ast_to_fir.nodeToTone(
                            root_child_main_token,
                            root_child_data,
                            root_child_equave_exponent,
                            .{
                                .value_kind = .frequency,
                                .instruction_equave_exponent = @enumFromInt(0),
                                .src_node = root_child_held,
                            },
                        ),
                        .length_modifier = root_child_length_modifier,
                    },
                }, root_child);
            },
            .chord => |info| {
                const chord_tones_start = ast_to_fir.startTones();

                for (info.children) |chord_child_equave_shifted| {
                    const chord_child, const chord_child_equave_shift = ast_to_fir.extractEquaveShifted(chord_child_equave_shifted);
                    const chord_child_main_token = ast_to_fir.ast.nodeMainToken(chord_child);
                    const chord_child_data = ast_to_fir.ast.nodeData(chord_child);

                    _ = try ast_to_fir.nodeToTone(
                        chord_child_main_token,
                        chord_child_data,
                        chord_child_equave_shift,
                        .{
                            .value_kind = .frequency,
                            .instruction_equave_exponent = root_child_equave_exponent,
                            .src_node = chord_child_equave_shifted,
                        },
                    );
                }

                const tones = ast_to_fir.endTones(chord_tones_start);

                assert(tones.len() > 0);

                ast_to_fir.scale = try ast_to_fir.appendInstruction(.{
                    .chord = .{
                        .equave_exponent = root_child_equave_exponent,
                        .root_frequency = ast_to_fir.root_frequency,
                        .tones = tones,
                        .length_modifier = root_child_length_modifier,
                    },
                }, root_child);
            },
            .scale => |info| {
                assert(@intFromEnum(root_child_length_modifier) == 0);

                const scale_tones_start = ast_to_fir.startTones();

                for (info.children) |scale_child_equave_shifted| {
                    const scale_child, const scale_child_equave_shift = ast_to_fir.extractEquaveShifted(scale_child_equave_shifted);
                    const scale_child_main_token = ast_to_fir.ast.nodeMainToken(scale_child);
                    const scale_child_data = ast_to_fir.ast.nodeData(scale_child);

                    _ = try ast_to_fir.nodeToTone(
                        scale_child_main_token,
                        scale_child_data,
                        scale_child_equave_shift,
                        .{
                            .value_kind = .ratio,
                            .instruction_equave_exponent = root_child_equave_exponent,
                            .src_node = scale_child_equave_shifted,
                        },
                    );
                }

                const tones = ast_to_fir.endTones(scale_tones_start);

                assert(tones.len() > 0);

                const equave: ?Fir.Tone.Index = if (info.equave.unwrap()) |equave_equave_shifted| blk: {
                    const equave, const equave_equave_shift = ast_to_fir.extractEquaveShifted(equave_equave_shifted);
                    const equave_main_token = ast_to_fir.ast.nodeMainToken(equave);
                    const equave_data = ast_to_fir.ast.nodeData(equave);

                    const equave_tone = try ast_to_fir.nodeToTone(
                        equave_main_token,
                        equave_data,
                        equave_equave_shift,
                        .{
                            .value_kind = .ratio,
                            .instruction_equave_exponent = root_child_equave_exponent,
                            .src_node = equave_equave_shifted,
                        },
                    );
                    ast_to_fir.equave = equave_tone;
                    break :blk equave_tone;
                } else null;

                ast_to_fir.scale = try ast_to_fir.appendInstruction(.{
                    .scale = .{
                        .equave_exponent = root_child_equave_exponent,
                        .tones = tones,
                        .equave = .wrap(equave),
                    },
                }, root_child);
            },
            else => @panic("TODO"),
        }
    }
}

fn extractHeld(
    ast_to_fir: *AstToFir,
    node: Node.Index,
) struct { Ast.Node.Index, LengthModifier } {
    return switch (ast_to_fir.ast.nodeData(node)) {
        .held => |held_info| .{
            held_info.child,
            @enumFromInt(held_info.holds),
        },
        else => .{ node, @enumFromInt(0) },
    };
}

fn extractEquaveShifted(
    ast_to_fir: *AstToFir,
    node: Node.Index,
) struct { Ast.Node.Index, EquaveExponent } {
    return switch (ast_to_fir.ast.nodeData(node)) {
        .equave_shifted => |equave_shifted_info| .{
            equave_shifted_info.child,
            @enumFromInt(equave_shifted_info.equave_shift),
        },
        else => .{ node, @enumFromInt(0) },
    };
}

fn nodeToTone(
    ast_to_fir: *AstToFir,
    main_token: ?Token.Index,
    data: Node.Data,
    equave_exponent: EquaveExponent,
    tone_additional_info: ToneAdditionalInfo,
) !Tone.Index {
    return try ast_to_fir.appendTone(switch (data) {
        .degree => .{
            .degree = .{
                .equave_exponent = equave_exponent,
                .scale = ast_to_fir.scale,
                .degree = try ast_to_fir.parseIntFromToken(main_token.?),
            },
        },
        .ratio => |info| .{
            .ratio = .{
                .equave_exponent = equave_exponent,
                .ratio = .{
                    .numerator = try ast_to_fir.parseIntFromToken(main_token.?),
                    .denominator = try ast_to_fir.parseIntFromToken(info.denominator),
                },
            },
        },
        .cents => |info| .{
            .cents = .{
                .equave_exponent = equave_exponent,
                .cents = try ast_to_fir.parseFloatFromTokens(main_token.?, info.fractional_part.unwrap()),
            },
        },
        .edostep => |info| blk: {
            const edostep = try ast_to_fir.parseIntFromToken(main_token.?);
            const divisions = try ast_to_fir.parseIntFromToken(info.divisions);
            if (divisions == 0) {
                return error.SpoolError;
            }

            break :blk .{
                .edostep = .{
                    .equave_exponent = equave_exponent,
                    .edostep = edostep,
                    .divisions = divisions,
                },
            };
        },
        .edxstep => |info| blk: {
            const edostep = try ast_to_fir.parseIntFromToken(main_token.?);
            const divisions = try ast_to_fir.parseIntFromToken(info.divisions);
            if (divisions == 0) {
                return error.AstToFirError;
            }
            const equave = try ast_to_fir.parseFractionFromNode(info.equave);

            break :blk .{
                .edxstep = .{
                    .equave_exponent = equave_exponent,
                    .edostep = edostep,
                    .divisions = divisions,
                    .equave = equave,
                },
            };
        },
        .hz => |info| .{
            .hz = .{
                .equave_exponent = equave_exponent,
                .frequency = try ast_to_fir.parseFloatFromTokens(main_token.?, info.fractional_part.unwrap()),
            },
        },
        else => unreachable,
    }, tone_additional_info);
}

fn parseIntFromToken(ast_to_fir: *const AstToFir, token: Token.Index) !u32 {
    return std.fmt.parseInt(
        u32,
        ast_to_fir.tokens.sliceSource(ast_to_fir.source, token),
        10,
    );
}

fn parseFloatFromTokens(
    ast_to_fir: *const AstToFir,
    whole_part: Token.Index,
    fractional_part: ?Token.Index,
) !f32 {
    const start = ast_to_fir.tokens.range(whole_part).start;
    const end = ast_to_fir.tokens.range(fractional_part orelse whole_part).end;
    return std.fmt.parseFloat(f32, ast_to_fir.source[start..end]);
}

fn parseFractionFromNode(ast_to_fir: *AstToFir, node: Node.Index) !Fir.Fraction {
    return switch (ast_to_fir.ast.nodeData(node)) {
        .integer => .{
            .numerator = try ast_to_fir.parseIntFromToken(ast_to_fir.ast.nodeMainToken(node).?),
            .denominator = 1,
        },
        .fraction => |info| blk: {
            const numerator = try ast_to_fir.parseIntFromToken(ast_to_fir.ast.nodeMainToken(node).?);
            const denominator = try ast_to_fir.parseIntFromToken(info.denominator);
            if (denominator == 0) {
                return error.AstToFirError;
            }
            break :blk .{
                .numerator = numerator,
                .denominator = denominator,
            };
        },
        else => unreachable,
    };
}

fn startTones(ast_to_fir: *AstToFir) Tone.Index {
    assert(!ast_to_fir.tones_started);
    ast_to_fir.tones_started = true;
    return @enumFromInt(ast_to_fir.tones.len);
}

fn endTones(ast_to_fir: *AstToFir, start: Tone.Index) Tone.Range {
    assert(ast_to_fir.tones_started);
    ast_to_fir.tones_started = false;
    return .{ .start = start, .end = @enumFromInt(ast_to_fir.tones.len) };
}

fn appendInstruction(
    ast_to_fir: *AstToFir,
    data: Instruction.Data,
    src_node: ?Ast.Node.Index,
) !Instruction.Index {
    try ast_to_fir.instructions.append(ast_to_fir.allocator, .{
        .tag = data,
        .src_node = .wrap(src_node),
        .untagged_data = try .fromTagged(ast_to_fir.allocator, &ast_to_fir.extra, data),
        .equave = ast_to_fir.equave,
    });
    return @enumFromInt(ast_to_fir.instructions.len - 1);
}

const ToneAdditionalInfo = struct {
    value_kind: enum { frequency, ratio },
    instruction_equave_exponent: EquaveExponent,
    src_node: ?Ast.Node.Index,
};

fn appendTone(
    ast_to_fir: *AstToFir,
    data: Tone.Data,
    tone_additional_info: ToneAdditionalInfo,
) !Tone.Index {
    try ast_to_fir.tones.append(ast_to_fir.allocator, .{
        .tag = data,
        .untagged_data = try .fromTagged(ast_to_fir.allocator, &ast_to_fir.extra, data),
        .src_node = .wrap(tone_additional_info.src_node),
        .instruction = @enumFromInt(ast_to_fir.instructions.len),
        .value = switch (tone_additional_info.value_kind) {
            .frequency => ast_to_fir.toneFrequency(data, tone_additional_info.instruction_equave_exponent),
            .ratio => ast_to_fir.toneRatio(data, tone_additional_info.instruction_equave_exponent),
        },
    });
    return @enumFromInt(ast_to_fir.tones.len - 1);
}

fn toneRatio(
    ast_to_fir: *AstToFir,
    data: Tone.Data,
    instruction_equave_exponent: EquaveExponent,
) f32 {
    const equave = ast_to_fir.tones.items(.value)[@intFromEnum(ast_to_fir.equave)];

    return sw: switch (data) {
        .degree => |info| {
            const scale_info =
                ast_to_fir.instructions.items(.untagged_data)[@intFromEnum(ast_to_fir.scale)].toTagged(
                    ast_to_fir.extra.items,
                    .scale,
                ).scale;
            const scale_len = @intFromEnum(scale_info.tones.end) - @intFromEnum(scale_info.tones.start);
            break :sw ast_to_fir.tones.items(.value)[@intFromEnum(scale_info.tones.start) + info.degree % scale_len] *
                std.math.pow(
                    f32,
                    equave,
                    @as(f32, @floatFromInt(info.degree / scale_len)),
                ) *
                std.math.pow(f32, equave, @floatFromInt(@intFromEnum(info.equave_exponent)));
        },
        .ratio => |info| info.ratio.float() *
            std.math.pow(f32, equave, @floatFromInt(@intFromEnum(info.equave_exponent))),
        .cents => |info| @exp2(info.cents / 1200) *
            std.math.pow(f32, equave, @floatFromInt(@intFromEnum(info.equave_exponent))),
        .edostep => |info| {
            const edostep: f32 = @floatFromInt(info.edostep);
            const divisions: f32 = @floatFromInt(info.divisions);
            assert(divisions != 0);

            break :sw std.math.pow(f32, 2, edostep / divisions) *
                std.math.pow(f32, equave, @floatFromInt(@intFromEnum(info.equave_exponent)));
        },
        .edxstep => |info| {
            const edostep: f32 = @floatFromInt(info.edostep);
            const divisions: f32 = @floatFromInt(info.divisions);
            assert(divisions != 0);
            const edx_equave = info.equave.float();

            break :sw std.math.pow(f32, edx_equave, edostep / divisions) *
                std.math.pow(f32, equave, @floatFromInt(@intFromEnum(info.equave_exponent)));
        },
        .hz => unreachable,
    } *
        std.math.pow(f32, equave, @floatFromInt(@intFromEnum(instruction_equave_exponent)));
}

fn toneFrequency(
    ast_to_fir: *AstToFir,
    data: Tone.Data,
    instruction_equave_exponent: EquaveExponent,
) f32 {
    return switch (data) {
        .degree,
        .ratio,
        .cents,
        .edostep,
        .edxstep,
        => ast_to_fir.tones.items(.value)[@intFromEnum(ast_to_fir.root_frequency)] *
            ast_to_fir.toneRatio(data, instruction_equave_exponent),
        .hz => |info| info.frequency *
            std.math.pow(
                f32,
                ast_to_fir.tones.items(.value)[@intFromEnum(ast_to_fir.equave)],
                @floatFromInt(@intFromEnum(info.equave_exponent) + @intFromEnum(instruction_equave_exponent)),
            ),
    };
}
