const std = @import("std");
const assert = std.debug.assert;
const Tokenizer = @import("Tokenizer.zig");
const Parser = @import("Parser.zig");

const State = enum {
    start,
    document_update,
};
const allocator = std.heap.wasm_allocator;

var state: State = .start;
var document: std.ArrayListUnmanaged(u8) = .{};
var highlights: std.ArrayListUnmanaged(Highlight) = .{};

extern fn consoleLog(ptr: [*]const u8, len: u32) void;

pub const std_options = std.Options{
    .logFn = log,
};

fn log(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    var buffer: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    const writer = fbs.writer();

    writer.print(level_txt ++ prefix2 ++ format, args) catch return;

    consoleLog(fbs.buffer.ptr, fbs.pos);
}

fn documentSlice() [:0]u8 {
    return document.items[0 .. document.items.len - 1 :0];
}

/// returns ptr to null terminated string.
export fn startDocumentUpdate(len: u32) [*:0]u8 {
    errdefer |err| @panic(@errorName(err));

    assert(state == .start);
    state = .document_update;

    try document.resize(allocator, len + 1);
    document.items[document.items.len - 1] = 0;

    return documentSlice();
}

const Highlight = extern struct {
    const Tag = enum(u8) {
        amogus = 0,
    };

    tag: Tag align(1),
    start: u32 align(1),
    end: u32 align(1),
};

const DocumentUpdateResult = extern struct {
    highlights: [*]Highlight align(1),
    highlights_len: u32 align(1),
};

var dur: DocumentUpdateResult = undefined;

export fn endDocumentUpdate() *DocumentUpdateResult {
    errdefer |err| @panic(@errorName(err));

    assert(state == .document_update);
    state = .start;

    const source = documentSlice();

    var tokens = try Tokenizer.tokenize(allocator, source);
    defer tokens.deinit(allocator);

    var ast = try Parser.parse(allocator, &tokens);
    defer ast.deinit(allocator);

    if (ast.errors.len > 0) {
        return &dur;
    }

    highlights.clearRetainingCapacity();

    try highlights.append(allocator, .{
        .tag = .amogus,
        .start = 0,
        .end = 10,
    });
    try highlights.append(allocator, .{
        .tag = .amogus,
        .start = 20,
        .end = 30,
    });

    dur = .{
        .highlights = highlights.items.ptr,
        .highlights_len = highlights.items.len,
    };
    return &dur;
}
