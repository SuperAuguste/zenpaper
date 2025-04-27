const std = @import("std");
const assert = std.debug.assert;
const State = @import("wasm_agent/State.zig");

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

const allocator = std.heap.wasm_allocator;

extern fn consoleLog(ptr: [*]const u8, len: u32) void;

var state: State = .init;

/// returns ptr to null terminated string.
export fn startDocumentUpdate(len: u32) [*:0]u8 {
    errdefer |err| @panic(@errorName(err));
    try state.allocateDocument(allocator, len);
    return state.documentSlice();
}

export fn endDocumentUpdate() ?*State.DocumentUpdated {
    errdefer |err| @panic(@errorName(err));
    return try state.updateDocument(allocator);
}
