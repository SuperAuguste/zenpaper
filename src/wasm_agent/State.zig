const std = @import("std");
const assert = std.debug.assert;
const Tokenizer = @import("../Tokenizer.zig");
const Parser = @import("../Parser.zig");

const State = @This();

pub const Status = enum {
    init,
    document_update,
};

pub const init = State{
    .status = .init,
    .document = .empty,
    .highlights = .empty,
};

status: Status,
document: std.ArrayListUnmanaged(u8),
highlights: std.ArrayListUnmanaged(Highlight),

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

    const source = state.documentSlice();

    var tokens = try Tokenizer.tokenize(allocator, source);
    defer tokens.deinit(allocator);

    var ast = try Parser.parse(allocator, &tokens);
    defer ast.deinit(allocator);

    if (ast.errors.len > 0) {
        return null;
    }

    state.highlights.clearRetainingCapacity();

    try state.highlights.append(allocator, .{
        .tag = .amogus,
        .start = 0,
        .end = 10,
    });
    try state.highlights.append(allocator, .{
        .tag = .amogus,
        .start = 20,
        .end = 30,
    });

    return result(DocumentUpdated{
        .highlights_ptr = state.highlights.items.ptr,
        .highlights_len = state.highlights.items.len,
    });
}

pub const Highlight = extern struct {
    pub const Tag = enum(u8) {
        amogus = 0,
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
