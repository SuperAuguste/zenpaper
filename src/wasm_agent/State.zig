const std = @import("std");
const assert = std.debug.assert;
const Tokenizer = @import("../Tokenizer.zig");
const Parser = @import("../Parser.zig");
const AstToFir = @import("../AstToFir.zig");
const Tokens = Tokenizer.Tokens;
const Ast = @import("../Ast.zig");
const Fir = @import("../Fir.zig");

const State = @This();

pub const Status = enum {
    init,
    document_update,
};

pub const init = State{
    .status = .init,
    .document = .empty,
    .highlights = .empty,
    .cursor_index = 0,

    .tokens = null,
    .ast = null,
    .fir = null,
};

status: Status,
document: std.ArrayListUnmanaged(u8),
highlights: std.ArrayListUnmanaged(Highlight),
cursor_index: u32,

tokens: ?Tokens,
ast: ?Ast,
fir: ?Fir,

pub fn documentSlice(state: *State) [:0]u8 {
    assert(state.status != .init);
    return state.document.items[0 .. state.document.items.len - 1 :0];
}

pub fn allocateDocument(
    state: *State,
    allocator: std.mem.Allocator,
    len: u32,
) error{OutOfMemory}!void {
    assert(state.status == .init);
    defer state.status = .document_update;

    try state.document.resize(allocator, len + 1);
    state.document.items[state.document.items.len - 1] = 0;
}

pub const DocumentUpdated = extern struct {
    highlights_updated: HighlightsUpdated align(1),
};
pub fn updateDocument(
    state: *State,
    allocator: std.mem.Allocator,
) error{OutOfMemory}!DocumentUpdated {
    assert(state.status == .document_update);
    defer state.status = .init;

    if (state.tokens) |*tokens| tokens.deinit(allocator);
    if (state.ast) |*ast| ast.deinit(allocator);

    const source = state.documentSlice();

    state.tokens = try Tokenizer.tokenize(allocator, source);
    state.ast = try Parser.parse(allocator, &state.tokens.?);

    if (state.ast.?.errors.len > 0) {
        std.log.err("ast fail {any}", .{state.ast.?.errors});
        return .{
            .highlights_updated = .empty,
        };
    }

    state.fir = try AstToFir.astToFir(allocator, source, &state.tokens.?, &state.ast.?);

    if (state.fir.?.errors.len > 0) {
        std.log.err("fir fail {any}", .{state.fir.?.errors});
        return .{
            .highlights_updated = .empty,
        };
    }

    return .{
        .highlights_updated = try state.updateHighlights(allocator),
    };
}

pub const HighlightsUpdated = extern struct {
    pub const empty = HighlightsUpdated{ .ptr = null, .len = 0 };

    ptr: ?[*]Highlight align(1),
    len: u32 align(1),
};
pub fn updateHighlights(state: *State, allocator: std.mem.Allocator) error{OutOfMemory}!HighlightsUpdated {
    state.highlights.clearRetainingCapacity();

    const tokens = state.tokens orelse return .empty;
    const ast = state.ast orelse return .empty;
    if (ast.errors.len > 0) return .empty;

    var prev_end: u32 = 0;
    for (tokens.slice.items(.range)) |range| {
        if (prev_end != range.start) {
            try state.highlights.append(allocator, .{
                .tag = .comment,
                .start = prev_end,
                .end = range.start,
            });
        }
        prev_end = range.end;
    }

    try state.highlightNode(allocator, .root);

    if (state.fir) |fir| blk: {
        if (fir.errors.len > 0) break :blk;
        try state.highlightDependencies(allocator);
    }

    std.mem.sort(Highlight, state.highlights.items, {}, Highlight.lessThan);

    return .{
        .ptr = state.highlights.items.ptr,
        .len = state.highlights.items.len,
    };
}

fn highlightNode(
    state: *State,
    allocator: std.mem.Allocator,
    node: Ast.Node.Index,
) error{OutOfMemory}!void {
    const tokens = state.tokens.?;
    const ast = state.ast.?;
    assert(ast.errors.len == 0);

    switch (ast.nodeData(node)) {
        .root => |info| {
            for (info.children) |child| {
                try state.highlightNode(allocator, child);
            }
        },
        .chord => |info| {
            try state.highlights.append(allocator, .{
                .tag = .chord,
                .start = tokens.range(ast.nodeMainToken(node).?).start,
                .end = tokens.range(info.right_square).end,
            });

            for (info.children) |child| {
                try state.highlightNode(allocator, child);
            }
        },
        else => {},
    }
}

fn highlightInstructionDependency(
    state: *State,
    allocator: std.mem.Allocator,
    instruction: Fir.Instruction.Index,
) error{OutOfMemory}!void {
    const tokens = state.tokens.?;
    const ast = state.ast.?;
    const fir = state.fir.?;

    const src_node = fir.instructions.items(.src_node)[@intFromEnum(instruction)].unwrap() orelse return;
    const range = ast.nodeRange(&tokens, src_node).?;

    try state.highlights.append(allocator, .{
        .tag = .dependencies,
        .start = range.start,
        .end = range.end,
    });

    // TODO highlight root freq, equave
}

fn highlightToneDependency(
    state: *State,
    allocator: std.mem.Allocator,
    tone: Fir.Tone.Index,
) error{OutOfMemory}!void {
    const tokens = state.tokens.?;
    const ast = state.ast.?;
    const fir = state.fir.?;

    const src_node = fir.tones.items(.src_node)[@intFromEnum(tone)].unwrap() orelse {
        try state.highlightInstructionDependency(allocator, fir.tones.items(.instruction)[@intFromEnum(tone)]);
        return;
    };
    const range = ast.nodeRange(&tokens, src_node).?;

    try state.highlights.append(allocator, .{
        .tag = .dependencies,
        .start = range.start,
        .end = range.end,
    });

    const data = fir.toneData(tone);
    switch (data) {
        .degree => |info| try state.highlightToneDependency(allocator, info.degree),
        else => {},
    }
}

fn highlightDependencies(state: *State, allocator: std.mem.Allocator) error{OutOfMemory}!void {
    const tokens = state.tokens.?;
    const ast = state.ast.?;
    const fir = state.fir.?;

    for (0.., fir.tones.items(.src_node)) |tone, src_node_optional| {
        if (src_node_optional.unwrap()) |src_node| {
            const range = ast.nodeRange(&tokens, src_node).?;
            if (state.cursor_index >= range.start and state.cursor_index <= range.end) {
                try state.highlightToneDependency(allocator, @enumFromInt(tone));
            }
        }
    }
}

pub const Highlight = extern struct {
    pub const Tag = enum(u8) {
        comment,
        chord,
        dependencies,
    };

    tag: Tag align(1),
    start: u32 align(1),
    end: u32 align(1),

    fn lessThan(context: void, lhs: Highlight, rhs: Highlight) bool {
        _ = context;
        return lhs.start < rhs.start;
    }
};
