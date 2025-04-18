const std = @import("std");
const builtin = @import("builtin");
const Tokenizer = @import("Tokenizer.zig");
const Parser = @import("Parser.zig");
const PortAudio = @import("PortAudio.zig");
const NoteSpool = @import("NoteSpool.zig");
// const AstToSpool = @import("AstToSpool.zig");
const AstToFir = @import("AstToFir.zig");

fn help() void {
    std.log.info(
        \\Usage: zenpaper [subcommand] [options]
        \\
        \\Subcommands:
        \\  play             Play a zenpaper composition
        \\
    , .{});
}

fn helpAndError(comptime fmt: []const u8, args: anytype) u8 {
    help();
    std.log.err(fmt, args);
    return 1;
}

pub fn main() !u8 {
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

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    std.debug.assert(args.skip());

    const subcommand = args.next() orelse {
        return helpAndError("expected subcommand", .{});
    };

    if (std.mem.eql(u8, subcommand, "play")) {
        return play(allocator, &args);
    } else {
        return helpAndError("unexpected subcommand {s}", .{subcommand});
    }
}

fn play(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !u8 {
    const path = args.next() orelse {
        return helpAndError("expected path to zenpaper file", .{});
    };

    const source = std.fs.cwd().readFileAllocOptions(
        allocator,
        path,
        std.math.maxInt(usize),
        null,
        @alignOf(u8),
        0,
    ) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.BadPathName => |e| {
            return helpAndError("failed to open zenpaper file '{s}': {s}", .{ path, @errorName(e) });
        },
        else => |e| return e,
    };
    defer allocator.free(source);

    var tokens = try Tokenizer.tokenize(allocator, source);
    defer tokens.deinit(allocator);

    var ast = try Parser.parse(allocator, &tokens);
    defer ast.deinit(allocator);

    // ast.debugPrintNode(&tokens, .root, 0);

    if (ast.errors.len > 0) {
        for (ast.errors) |@"error"| {
            try @"error".render(&tokens, std.io.getStdErr().writer());
        }
        return 1;
    }

    try PortAudio.init();
    defer PortAudio.deinit();

    const default_output_device_info = PortAudio.getDefaultOutputDeviceInfo() orelse {
        std.log.err("could not obtain default output device", .{});
        return 1;
    };

    if (default_output_device_info.maxOutputChannels < 2) {
        std.log.err("default output device does not support stereo", .{});
        return 1;
    }

    std.log.debug("using default output device '{s}' with sample rate {d}", .{
        default_output_device_info.name,
        default_output_device_info.defaultSampleRate,
    });

    var fir = try AstToFir.astToFir(allocator, source, &tokens, &ast);
    defer fir.deinit(allocator);

    // fir.debugPrintInstruction(&tokens, .root, 0);

    // var note_spool = try AstToSpool.astToSpool(allocator, source, &tokens, &ast, @floatCast(default_output_device_info.defaultSampleRate));
    // defer note_spool.deinit(allocator);

    // note_spool.debugPrint();

    // const stream = try PortAudio.openDefaultStream(
    //     NoteSpool,
    //     .{
    //         .input_channels = 0,
    //         .output_channels = 2,
    //         .sample_format = .f32,
    //     },
    //     realtime,
    //     @floatCast(default_output_device_info.defaultSampleRate),
    //     &note_spool,
    // );
    // try stream.start();

    // while (!@atomicLoad(bool, &note_spool.done, .acquire)) {}

    // try stream.stop();

    return 0;
}

const amplitude_adjustment = std.math.pow(f32, 10, -18.0 / 20.0);

fn realtime(
    input_channels: [0][]const f32,
    output_channels: [2][]f32,
    note_spool: *NoteSpool,
) void {
    _ = input_channels;

    const left, const right = output_channels;

    for (left, right) |*l, *r| {
        const mono = @reduce(.Add, note_spool.tick()) * 0.15;
        l.* = mono;
        r.* = mono;
    }
}
