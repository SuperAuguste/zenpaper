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
const Error = Fir.Error;

const AstToFir = @This();

allocator: std.mem.Allocator,
source: []const u8,
tokens: *const Tokens,
ast: *const Ast,

instructions: std.MultiArrayList(Instruction),
tones: std.MultiArrayList(Tone),
extra: std.ArrayListUnmanaged(u32),
errors: std.ArrayListUnmanaged(Error),

root_frequency: Tone.Index,
equave: Tone.Index,
scale: Instruction.Index,

started_instruction: ?StartInstruction,
tones_started: bool,

pub fn astToFir(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: *const Tokens,
    ast: *const Ast,
) error{OutOfMemory}!Fir {
    assert(ast.errors.len == 0);

    var ast_to_fir = AstToFir{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .ast = ast,

        .instructions = .empty,
        .tones = .empty,
        .extra = .empty,
        .errors = .empty,

        .root_frequency = @enumFromInt(1 + 12),
        .equave = @enumFromInt(0),
        .scale = @enumFromInt(0),

        .started_instruction = null,
        .tones_started = false,
    };

    // Initialize default equave and scale.
    ast_to_fir.startInstruction(.{
        .scale = .{
            .equave_exponent = @enumFromInt(0),
        },
    });

    // Raw append as equave is missing so appendTone cannot be used yet.
    const equave = try ast_to_fir.appendToneRaw(.{
        .ratio = .{
            .equave_exponent = @enumFromInt(0),
            .ratio = .{
                .numerator = 2,
                .denominator = 1,
            },
        },
    }, @enumFromInt(0), 2, null);
    assert(equave == ast_to_fir.equave);

    const scale_tones_start = ast_to_fir.startTones();
    for (0..12) |index| {
        _ = try ast_to_fir.appendTone(.{
            .edostep = .{
                .equave_exponent = @enumFromInt(0),
                .edostep = @intCast(index),
                .divisions = 12,
            },
        }, null);
    }
    const scale_tones = ast_to_fir.endTones(scale_tones_start);

    const scale = try ast_to_fir.endInstruction(.{
        .scale = .{
            .tones = scale_tones,
            .equave = .wrap(equave),
        },
    }, null);
    assert(scale == ast_to_fir.scale);

    // Initialize default root frequency.
    ast_to_fir.startInstruction(.root_frequency);

    const root_frequency = try ast_to_fir.appendTone(.{
        .hz = .{
            .equave_exponent = @enumFromInt(0),
            .frequency = 220,
        },
    }, null);
    assert(root_frequency == ast_to_fir.root_frequency);

    _ = try ast_to_fir.endInstruction(.{
        .root_frequency = .{
            .tone = root_frequency,
        },
    }, null);

    ast_to_fir.astToFirInternal() catch |err| switch (err) {
        error.AstToFirError => {
            std.debug.assert(ast_to_fir.errors.items.len > 0);
            return .{
                .instructions = ast_to_fir.instructions.toOwnedSlice(),
                .tones = ast_to_fir.tones.toOwnedSlice(),
                .extra = try ast_to_fir.extra.toOwnedSlice(allocator),
                .errors = try ast_to_fir.errors.toOwnedSlice(allocator),
            };
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    std.debug.assert(ast_to_fir.errors.items.len == 0);
    std.debug.assert(ast_to_fir.started_instruction == null);
    std.debug.assert(!ast_to_fir.tones_started);

    return .{
        .instructions = ast_to_fir.instructions.toOwnedSlice(),
        .tones = ast_to_fir.tones.toOwnedSlice(),
        .extra = try ast_to_fir.extra.toOwnedSlice(allocator),
        .errors = try ast_to_fir.errors.toOwnedSlice(allocator),
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
                ast_to_fir.startInstruction(.{
                    .note = .{
                        .length_modifier = root_child_length_modifier,
                    },
                });
                _ = try ast_to_fir.endInstruction(.{
                    .note = .{
                        .tone = try ast_to_fir.nodeToTone(root_child_equave_shifted),
                    },
                }, root_child_held);
            },
            .chord => |info| {
                ast_to_fir.startInstruction(.{
                    .chord = .{
                        .equave_exponent = root_child_equave_exponent,
                        .length_modifier = root_child_length_modifier,
                    },
                });

                const chord_tones_start = ast_to_fir.startTones();
                for (info.children) |chord_child_equave_shifted| {
                    _ = try ast_to_fir.nodeToTone(chord_child_equave_shifted);
                }
                const tones = ast_to_fir.endTones(chord_tones_start);
                assert(tones.len() > 0);

                _ = try ast_to_fir.endInstruction(.{
                    .chord = .{
                        .tones = tones,
                    },
                }, root_child_held);
            },
            .scale => |info| {
                assert(@intFromEnum(root_child_length_modifier) == 0);

                ast_to_fir.startInstruction(.{
                    .scale = .{
                        .equave_exponent = root_child_equave_exponent,
                    },
                });

                const scale_tones_start = ast_to_fir.startTones();
                for (info.children) |scale_child_equave_shifted| {
                    _ = try ast_to_fir.nodeToTone(scale_child_equave_shifted);
                }
                const tones = ast_to_fir.endTones(scale_tones_start);
                assert(tones.len() > 0);

                const equave: ?Fir.Tone.Index = if (info.equave.unwrap()) |equave_equave_shifted|
                    try ast_to_fir.nodeToTone(equave_equave_shifted)
                else
                    null;

                ast_to_fir.scale = try ast_to_fir.endInstruction(.{
                    .scale = .{
                        .tones = tones,
                        .equave = .wrap(equave),
                    },
                }, root_child_equave_shifted);
                if (equave) |e| {
                    ast_to_fir.equave = e;
                }
            },
            .scale_edo => {
                assert(@intFromEnum(root_child_length_modifier) == 0);
                assert(@intFromEnum(root_child_equave_exponent) == 0);

                ast_to_fir.startInstruction(.{
                    .scale = .{
                        .equave_exponent = @enumFromInt(0),
                    },
                });

                const divisions = try ast_to_fir.parseIntFromToken(root_child_main_token.?);
                if (divisions == 0) {
                    try ast_to_fir.errors.append(ast_to_fir.allocator, .{
                        .tag = .denominator_zero,
                        .data = .{ .token = root_child_main_token.? },
                    });
                    return error.AstToFirError;
                }

                const tones_start = ast_to_fir.startTones();
                for (0..12) |index| {
                    _ = try ast_to_fir.appendTone(.{
                        .edostep = .{
                            .equave_exponent = @enumFromInt(0),
                            .edostep = @intCast(index),
                            .divisions = divisions,
                        },
                    }, null);
                }
                const tones = ast_to_fir.endTones(tones_start);
                assert(tones.len() > 0);

                ast_to_fir.equave = try ast_to_fir.appendTone(.{
                    .ratio = .{
                        .equave_exponent = @enumFromInt(0),
                        .ratio = .{
                            .numerator = 2,
                            .denominator = 1,
                        },
                    },
                }, null);
                ast_to_fir.scale = try ast_to_fir.endInstruction(.{
                    .scale = .{
                        .tones = tones,
                        .equave = .wrap(ast_to_fir.equave),
                    },
                }, root_child);
            },
            .scale_edx => |info| {
                assert(@intFromEnum(root_child_length_modifier) == 0);
                assert(@intFromEnum(root_child_equave_exponent) == 0);

                ast_to_fir.startInstruction(.{
                    .scale = .{
                        .equave_exponent = @enumFromInt(0),
                    },
                });

                const divisions = try ast_to_fir.parseIntFromToken(root_child_main_token.?);
                if (divisions == 0) {
                    try ast_to_fir.errors.append(ast_to_fir.allocator, .{
                        .tag = .denominator_zero,
                        .data = .{ .token = root_child_main_token.? },
                    });
                    return error.AstToFirError;
                }

                const equave = try ast_to_fir.parseFractionFromNode(info.equave);

                const tones_start = ast_to_fir.startTones();
                for (0..12) |index| {
                    _ = try ast_to_fir.appendTone(.{
                        .edxstep = .{
                            .equave_exponent = @enumFromInt(0),
                            .edostep = @intCast(index),
                            .divisions = divisions,
                            .equave = equave,
                        },
                    }, null);
                }
                const tones = ast_to_fir.endTones(tones_start);
                assert(tones.len() > 0);

                ast_to_fir.equave = try ast_to_fir.appendTone(.{
                    .ratio = .{
                        .equave_exponent = @enumFromInt(0),
                        .ratio = equave,
                    },
                }, null);
                ast_to_fir.scale = try ast_to_fir.endInstruction(.{
                    .scale = .{
                        .tones = tones,
                        .equave = .wrap(ast_to_fir.equave),
                    },
                }, root_child);
            },
            .scale_mode => |info| {
                assert(@intFromEnum(root_child_length_modifier) == 0);
                assert(@intFromEnum(root_child_equave_exponent) == 0);

                ast_to_fir.startInstruction(.{
                    .scale = .{
                        .equave_exponent = @enumFromInt(0),
                    },
                });

                const tones_start = ast_to_fir.startTones();
                var degree: u32 = 0;
                _ = try ast_to_fir.appendTone(.{
                    .degree = .{
                        .equave_exponent = @enumFromInt(0),
                        .scale = ast_to_fir.scale,
                        .degree = degree,
                    },
                }, null);
                for (info.children[0 .. info.children.len - 1]) |scale_mode_child| {
                    degree = std.math.add(
                        u32,
                        degree,
                        try ast_to_fir.parseIntFromToken(
                            ast_to_fir.ast.nodeMainToken(scale_mode_child).?,
                        ),
                    ) catch {
                        try ast_to_fir.errors.append(ast_to_fir.allocator, .{
                            .tag = .mode_overflow,
                            .data = .{ .token = ast_to_fir.ast.nodeMainToken(scale_mode_child).? },
                        });
                        return error.AstToFirError;
                    };

                    _ = try ast_to_fir.appendTone(.{
                        .degree = .{
                            .equave_exponent = @enumFromInt(0),
                            .scale = ast_to_fir.scale,
                            .degree = degree,
                        },
                    }, null);
                }
                const tones = ast_to_fir.endTones(tones_start);
                assert(tones.len() > 0);

                ast_to_fir.scale = try ast_to_fir.endInstruction(.{
                    .scale = .{
                        .tones = tones,
                        .equave = .wrap(ast_to_fir.equave),
                    },
                }, root_child);
            },
            .root_frequency => |info| {
                assert(@intFromEnum(root_child_length_modifier) == 0);
                assert(@intFromEnum(root_child_equave_exponent) == 0);

                ast_to_fir.startInstruction(.root_frequency);
                ast_to_fir.root_frequency = try ast_to_fir.nodeToTone(info.child);
                ast_to_fir.scale = try ast_to_fir.endInstruction(.{
                    .root_frequency = .{
                        .tone = ast_to_fir.root_frequency,
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

fn nodeToTone(ast_to_fir: *AstToFir, node_equave_shifted: Node.Index) !Tone.Index {
    const node, const equave_exponent = ast_to_fir.extractEquaveShifted(node_equave_shifted);
    const main_token = ast_to_fir.ast.nodeMainToken(node);
    const data = ast_to_fir.ast.nodeData(node);

    return try ast_to_fir.appendTone(switch (data) {
        .degree => .{
            .degree = .{
                .equave_exponent = equave_exponent,
                .scale = ast_to_fir.scale,
                .degree = try ast_to_fir.parseIntFromToken(main_token.?),
            },
        },
        .ratio => |info| blk: {
            const numerator = try ast_to_fir.parseIntFromToken(main_token.?);
            const denominator = try ast_to_fir.parseIntFromToken(info.denominator);

            if (denominator == 0) {
                try ast_to_fir.errors.append(ast_to_fir.allocator, .{
                    .tag = .denominator_zero,
                    .data = .{ .token = info.denominator },
                });
                return error.AstToFirError;
            }

            break :blk .{
                .ratio = .{
                    .equave_exponent = equave_exponent,
                    .ratio = .{
                        .numerator = numerator,
                        .denominator = denominator,
                    },
                },
            };
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
                try ast_to_fir.errors.append(ast_to_fir.allocator, .{
                    .tag = .denominator_zero,
                    .data = .{ .token = info.divisions },
                });
                return error.AstToFirError;
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
                try ast_to_fir.errors.append(ast_to_fir.allocator, .{
                    .tag = .denominator_zero,
                    .data = .{ .token = info.divisions },
                });
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
    }, node_equave_shifted);
}

fn parseIntFromToken(ast_to_fir: *AstToFir, token: Token.Index) !u32 {
    return std.fmt.parseInt(
        u32,
        ast_to_fir.tokens.sliceSource(ast_to_fir.source, token),
        10,
    ) catch {
        try ast_to_fir.errors.append(ast_to_fir.allocator, .{
            .tag = .invalid_integer,
            .data = .{ .token = token },
        });
        return error.AstToFirError;
    };
}

fn parseFloatFromTokens(
    ast_to_fir: *AstToFir,
    whole_part: Token.Index,
    fractional_part: ?Token.Index,
) !f32 {
    const start = ast_to_fir.tokens.range(whole_part).start;
    const end = ast_to_fir.tokens.range(fractional_part orelse whole_part).end;
    return std.fmt.parseFloat(f32, ast_to_fir.source[start..end]) catch {
        try ast_to_fir.errors.append(ast_to_fir.allocator, .{
            .tag = .invalid_float,
            .data = .{ .token = whole_part },
        });
        return error.AstToFirError;
    };
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
                try ast_to_fir.errors.append(ast_to_fir.allocator, .{
                    .tag = .denominator_zero,
                    .data = .{ .token = info.denominator },
                });
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

const StartInstruction = union(Instruction.Tag) {
    root_frequency,
    note: struct {
        length_modifier: LengthModifier,
    },
    chord: struct {
        equave_exponent: EquaveExponent,
        length_modifier: LengthModifier,
    },
    scale: struct {
        equave_exponent: EquaveExponent,
    },
};
fn startInstruction(ast_to_fir: *AstToFir, start: StartInstruction) void {
    assert(ast_to_fir.started_instruction == null);
    ast_to_fir.started_instruction = start;
}

const EndInstruction = union(Instruction.Tag) {
    root_frequency: struct {
        tone: Tone.Index,
    },
    note: struct {
        tone: Tone.Index,
    },
    chord: struct {
        tones: Tone.Range,
    },
    scale: struct {
        tones: Tone.Range,
        equave: Tone.OptionalIndex,
    },
};
fn endInstruction(
    ast_to_fir: *AstToFir,
    end: EndInstruction,
    src_node: ?Ast.Node.Index,
) !Instruction.Index {
    assert(std.meta.activeTag(ast_to_fir.started_instruction.?) == std.meta.activeTag(end));
    defer ast_to_fir.started_instruction = null;

    const start = ast_to_fir.started_instruction.?;

    const data: Fir.Instruction.Data = sw: switch (end) {
        .root_frequency => |end_info| {
            const start_info = start.root_frequency;
            _ = start_info; // autofix
            break :sw .{
                .root_frequency = .{
                    .root_frequency = ast_to_fir.root_frequency,
                    .tone = end_info.tone,
                },
            };
        },
        .note => |end_info| {
            const start_info = start.note;
            break :sw .{
                .note = .{
                    .root_frequency = ast_to_fir.root_frequency,
                    .tone = end_info.tone,
                    .length_modifier = start_info.length_modifier,
                },
            };
        },
        .chord => |end_info| {
            const start_info = start.chord;
            break :sw .{
                .chord = .{
                    .equave_exponent = start_info.equave_exponent,
                    .root_frequency = ast_to_fir.root_frequency,
                    .tones = end_info.tones,
                    .length_modifier = start_info.length_modifier,
                },
            };
        },
        .scale => |end_info| {
            const start_info = start.scale;
            break :sw .{
                .scale = .{
                    .equave_exponent = start_info.equave_exponent,
                    .tones = end_info.tones,
                    .equave = end_info.equave,
                },
            };
        },
    };

    return try ast_to_fir.appendInstructionRaw(data, ast_to_fir.equave, src_node);
}

fn appendTone(ast_to_fir: *AstToFir, data: Fir.Tone.Data, src_node: ?Ast.Node.Index) !Tone.Index {
    assert(ast_to_fir.started_instruction != null);

    const kind: enum { frequency, ratio } = switch (ast_to_fir.started_instruction.?) {
        .scale => .ratio,
        else => .frequency,
    };
    const instruction_equave_exponent: Fir.EquaveExponent = switch (ast_to_fir.started_instruction.?) {
        .root_frequency, .note => @enumFromInt(0),
        inline else => |info| @field(info, "equave_exponent"),
    };

    return try ast_to_fir.appendToneRaw(
        data,
        @enumFromInt(ast_to_fir.instructions.len),
        switch (kind) {
            .frequency => ast_to_fir.toneFrequency(data, instruction_equave_exponent),
            .ratio => ast_to_fir.toneRatio(data, instruction_equave_exponent),
        },
        src_node,
    );
}

fn appendInstructionRaw(
    ast_to_fir: *AstToFir,
    data: Instruction.Data,
    equave: Tone.Index,
    src_node: ?Ast.Node.Index,
) !Instruction.Index {
    try ast_to_fir.instructions.append(ast_to_fir.allocator, .{
        .tag = data,
        .src_node = .wrap(src_node),
        .untagged_data = try .fromTagged(ast_to_fir.allocator, &ast_to_fir.extra, data),
        .equave = equave,
    });
    return @enumFromInt(ast_to_fir.instructions.len - 1);
}

fn appendToneRaw(
    ast_to_fir: *AstToFir,
    data: Tone.Data,
    instruction: Instruction.Index,
    value: f32,
    src_node: ?Ast.Node.Index,
) !Tone.Index {
    try ast_to_fir.tones.append(ast_to_fir.allocator, .{
        .tag = data,
        .untagged_data = try .fromTagged(ast_to_fir.allocator, &ast_to_fir.extra, data),
        .src_node = .wrap(src_node),
        .instruction = instruction,
        .value = value,
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
