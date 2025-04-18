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

instructions: std.MultiArrayList(Instruction) = .empty,
tones: std.MultiArrayList(Tone) = .empty,
extra: std.ArrayListUnmanaged(u32) = .empty,

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
    };
    // try ast_to_spool.scale_ratios.ensureTotalCapacity(allocator, 1024);
    // defer {
    //     ast_to_spool.scale_ratios.deinit(allocator);
    // }

    // for (0..12) |index| {
    //     ast_to_spool.scale_ratios.appendAssumeCapacity(std.math.pow(f32, 2, @as(f32, @floatFromInt(index)) / 12));
    // }

    // try ast_to_spool.astToSpoolInternal();

    return .{
        .instructions = ast_to_fir.instructions.toOwnedSlice(),
        .tones = ast_to_fir.tones.toOwnedSlice(),
        .extra = try ast_to_fir.extra.toOwnedSlice(allocator),
    };
}
