const std = @import("std");
const builtin = @import("builtin");
const Tokenizer = @import("Tokenizer.zig");
const Parser = @import("Parser.zig");
const PortAudio = @import("PortAudio.zig");
const NoteSpool = @import("NoteSpool.zig");
const AstToSpool = @import("AstToSpool.zig");

pub fn main() !void {
    var debug_allocator = switch (builtin.mode) {
        .Debug => std.heap.DebugAllocator(.{}){},
        else => {},
    };
    defer switch (builtin.mode) {
        .Debug => _ = debug_allocator.deinit(),
        else => {},
    };

    const allocator = switch (builtin.mode) {
        .Debug => debug_allocator.allocator(),
        else => std.heap.smp_allocator,
    };

    const buffer = @embedFile("hello.xp");

    var tokens = try Tokenizer.tokenize(allocator, buffer);
    defer tokens.deinit(allocator);

    var ast = try Parser.parse(allocator, &tokens);
    defer ast.deinit(allocator);

    ast.debugPrintNode(&tokens, .root, 0);

    var note_spool = try AstToSpool.astToSpool(allocator, buffer, &tokens, &ast, 48_000);
    defer note_spool.deinit(allocator);

    note_spool.debugPrint();

    try PortAudio.init();
    defer PortAudio.deinit();

    const stream = try PortAudio.openDefaultStream(
        NoteSpool,
        .{
            .input_channels = 0,
            .output_channels = 2,
            .sample_format = .f32,
        },
        realtime,
        48_000,
        &note_spool,
    );
    try stream.start();

    while (true) {}
}

fn realtime(
    input_channels: [0][]const f32,
    output_channels: [2][]f32,
    note_spool: *NoteSpool,
) void {
    _ = input_channels;

    const left, const right = output_channels;

    for (left, right) |*l, *r| {
        const mono = @reduce(.Add, note_spool.tick()) * 0.25;
        l.* = mono;
        r.* = mono;
    }
}
