const std = @import("std");
const assert = std.debug.assert;
const Tokenizer = @import("../Tokenizer.zig");
const Parser = @import("../Parser.zig");
const Tokens = Tokenizer.Tokens;
const Ast = @import("../Ast.zig");

const State = @This();

pub const Status = enum {
    init,
    document_update,
};

pub const init = State{
    .status = .init,
    .document = .empty,
    .highlights = .empty,

    .tokens = null,
    .ast = null,
};

status: Status,
document: std.ArrayListUnmanaged(u8),
highlights: std.ArrayListUnmanaged(Highlight),

tokens: ?Tokens,
ast: ?Ast,

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
    highlights_ptr: [*]Highlight align(1),
    highlights_len: u32 align(1),
};
pub fn updateDocument(
    state: *State,
    allocator: std.mem.Allocator,
) error{OutOfMemory}!?*DocumentUpdated {
    assert(state.status == .document_update);
    defer state.status = .init;

    if (state.tokens) |*tokens| tokens.deinit(allocator);
    if (state.ast) |*ast| ast.deinit(allocator);

    const source = state.documentSlice();

    state.tokens = try Tokenizer.tokenize(allocator, source);
    state.ast = try Parser.parse(allocator, &state.tokens.?);

    if (state.ast.?.errors.len > 0) {
        return null;
    }

    try state.updateHighlights(allocator);

    return result(DocumentUpdated{
        .highlights_ptr = state.highlights.items.ptr,
        .highlights_len = state.highlights.items.len,
    });
}

fn updateHighlights(state: *State, allocator: std.mem.Allocator) error{OutOfMemory}!void {
    state.highlights.clearRetainingCapacity();

    const ast = state.ast orelse return;
    if (ast.errors.len > 0) return;

    try state.highlightNode(allocator, .root);
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

pub const Highlight = extern struct {
    pub const Tag = enum(u8) {
        chord = 0,
    };

    tag: Tag align(1),
    start: u32 align(1),
    end: u32 align(1),
};

fn result(value: anytype) *@TypeOf(value) {
    const Tmp = struct {
        var tmp: @TypeOf(value) = undefined;
    };

    Tmp.tmp = value;
    return &Tmp.tmp;
}
