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

const AstToFir = @This();

allocator: std.mem.Allocator,
source: []const u8,
tokens: *const Tokens,
ast: *const Ast,

instructions: std.MultiArrayList(Instruction),
tones: std.MultiArrayList(Tone),
extra: std.ArrayListUnmanaged(u32),

current_equave: Fir.Fraction,
current_scale: Instruction.Index,

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

        .current_equave = .{ .numerator = 2, .denominator = 1 },
        .current_scale = undefined,
    };

    const root_frequency = try ast_to_fir.appendInstruction(.{
        .root_frequency = .{
            .tone = try ast_to_fir.appendTone(.{
                .hz = .{
                    .equave_exponent = @enumFromInt(0),
                    .frequency = 220,
                },
            }, null),
        },
    }, null);

    for (0..12) |index| {
        _ = try ast_to_fir.appendTone(.{
            .edostep = .{
                .equave_exponent = @enumFromInt(0),
                .root_frequency = root_frequency,
                .edostep = @intCast(index),
                .divisions = 12,
            },
        }, null);
    }

    ast_to_fir.current_scale = try ast_to_fir.appendInstruction(.{
        .scale = .{
            .equave_exponent = @enumFromInt(0),
            .tones_start = @enumFromInt(1 + 0),
            .tones_end = @enumFromInt(1 + 12),
        },
    }, null);

    // try ast_to_fir.astToFirInternal();

    return .{
        .instructions = ast_to_fir.instructions.toOwnedSlice(),
        .tones = ast_to_fir.tones.toOwnedSlice(),
        .extra = try ast_to_fir.extra.toOwnedSlice(allocator),
    };
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
        .equave = ast_to_fir.current_equave,
    });
    return @enumFromInt(ast_to_fir.instructions.len - 1);
}

fn appendTone(
    ast_to_fir: *AstToFir,
    data: Tone.Data,
    src_node: ?Ast.Node.Index,
) !Tone.Index {
    try ast_to_fir.tones.append(ast_to_fir.allocator, .{
        .tag = data,
        .untagged_data = try .fromTagged(ast_to_fir.allocator, &ast_to_fir.extra, data),
        .src_node = .wrap(src_node),
        .instruction = @enumFromInt(ast_to_fir.instructions.len),
        .value = 0,
    });
    return @enumFromInt(ast_to_fir.tones.len - 1);
}
