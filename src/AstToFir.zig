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

    return .{
        .instructions = ast_to_fir.instructions.toOwnedSlice(),
        .tones = ast_to_fir.tones.toOwnedSlice(),
        .extra = try ast_to_fir.extra.toOwnedSlice(allocator),
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
            .ratio => ast_to_fir.toneRatio(data, tone_additional_info.instruction_equave_exponent),
            .frequency => ast_to_fir.toneFrequency(data, tone_additional_info.instruction_equave_exponent),
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
        // .degree => blk: {
        //     assert(ast_to_fir.scale_ratios.items.len != 0);
        //     const degree = try ast_to_spool.parseIntFromToken(main_token.?);
        //     break :blk ast_to_spool.scale_ratios.items[degree % ast_to_spool.scale_ratios.items.len] *
        //         std.math.pow(
        //             f32,
        //             ast_to_spool.equave,
        //             @as(f32, @floatFromInt(degree / ast_to_spool.scale_ratios.items.len)),
        //         );
        // },
        // .ratio => |info| blk: {
        //     const numerator: f32 = @floatFromInt(try ast_to_spool.parseIntFromToken(main_token.?));
        //     const denominator: f32 = @floatFromInt(try ast_to_spool.parseIntFromToken(info.denominator));
        //     if (denominator == 0) {
        //         return error.SpoolError;
        //     }
        //     break :blk numerator / denominator;
        // },
        // .cents => |info| blk: {
        //     const cents = try ast_to_spool.parseFloatFromTokens(main_token.?, info.fractional_part.unwrap());
        //     break :blk @exp2(cents / 1200);
        // },
        .edostep => |info| {
            const edostep: f32 = @floatFromInt(info.edostep);
            const divisions: f32 = @floatFromInt(info.divisions);
            assert(divisions != 0);

            break :sw std.math.pow(f32, 2, edostep / divisions) *
                std.math.pow(f32, equave, @floatFromInt(@intFromEnum(info.equave_exponent)));
        },
        // .edxstep => |info| blk: {
        //     const edostep: f32 = @floatFromInt(try ast_to_spool.parseIntFromToken(main_token.?));
        //     const divisions: f32 = @floatFromInt(try ast_to_spool.parseIntFromToken(info.divisions));
        //     if (divisions == 0) {
        //         return error.SpoolError;
        //     }
        //     const equave: f32 = try ast_to_spool.fractionOrIntegerToFloat(info.equave);
        //     break :blk std.math.pow(f32, equave, edostep / divisions);
        // },
        else => 0,
        .hz => unreachable,
    } *
        std.math.pow(f32, equave, @floatFromInt(@intFromEnum(instruction_equave_exponent)));
}

fn toneFrequency(
    ast_to_fir: *AstToFir,
    data: Tone.Data,
    instruction_equave_exponent: EquaveExponent,
) f32 {
    const root_frequency = ast_to_fir.tones.items(.value)[@intFromEnum(ast_to_fir.equave)];

    return switch (data) {
        .degree,
        .ratio,
        .cents,
        .edostep,
        .edxstep,
        => root_frequency *
            ast_to_fir.toneRatio(data, instruction_equave_exponent),
        .hz => |info| info.frequency *
            std.math.pow(
                f32,
                ast_to_fir.tones.items(.value)[@intFromEnum(ast_to_fir.equave)],
                @floatFromInt(@intFromEnum(instruction_equave_exponent)),
            ),
    };
}
