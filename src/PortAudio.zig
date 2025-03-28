const std = @import("std");
const portaudio = @cImport({
    @cInclude("portaudio.h");
});

const PortAudio = @This();

const Options = struct {
    const SampleFormat = enum {
        f32,

        fn Type(comptime format: SampleFormat) type {
            return switch (format) {
                .f32 => f32,
            };
        }
    };

    input_channels: u16,
    output_channels: u16,
    sample_format: SampleFormat,
};

pub fn init() !void {
    if (portaudio.Pa_Initialize() != portaudio.paNoError) return error.InitFailed;
}

pub fn deinit() void {
    _ = portaudio.Pa_Terminate();
}

pub const Stream = opaque {
    pub fn start(stream: *Stream) !void {
        const err = portaudio.Pa_StartStream(@ptrCast(stream));
        if (err != portaudio.paNoError) {
            return error.StartFailed;
        }
    }

    pub fn stop(stream: *Stream) !void {
        const err = portaudio.Pa_StopStream(@ptrCast(stream));
        if (err != portaudio.paNoError) {
            return error.StopFailed;
        }
    }
};

pub fn openDefaultStream(
    comptime UserData: type,
    comptime options: Options,
    callback: fn (
        input_channels: [options.input_channels][]const options.sample_format.Type(),
        output_channels: [options.output_channels][]options.sample_format.Type(),
        user_data: *UserData,
    ) void,
    sample_rate: f32,
    user_data: *UserData,
) !*Stream {
    const Sample = options.sample_format.Type();

    var stream: ?*portaudio.PaStream = null;
    const err = portaudio.Pa_OpenDefaultStream(
        &stream,
        options.input_channels,
        options.output_channels,
        portaudio.paFloat32 | portaudio.paNonInterleaved,
        sample_rate,
        portaudio.paFramesPerBufferUnspecified,
        struct {
            fn cb(
                input_raw: ?*const anyopaque,
                output_raw: ?*anyopaque,
                frame_count: c_ulong,
                time_info: [*c]const portaudio.PaStreamCallbackTimeInfo,
                status_flags: portaudio.PaStreamCallbackFlags,
                user_data_raw: ?*anyopaque,
            ) callconv(.C) c_int {
                _ = time_info;
                _ = status_flags;

                const input: *const [options.input_channels][*]const Sample = if (options.input_channels == 0)
                    &.{}
                else
                    @alignCast(@ptrCast(input_raw.?));
                var input_channels: [options.input_channels][]const Sample = undefined;

                for (input, &input_channels) |interleaved_buf, *channel| {
                    channel.* = interleaved_buf[0..frame_count];
                }

                const output: *const [options.output_channels][*]Sample = if (options.output_channels == 0)
                    &.{}
                else
                    @alignCast(@ptrCast(output_raw.?));
                var output_channels: [options.output_channels][]Sample = undefined;

                for (output, &output_channels) |interleaved_buf, *channel| {
                    channel.* = interleaved_buf[0..frame_count];
                }

                const user_data_maybe: ?*UserData = @alignCast(@ptrCast(user_data_raw));

                callback(
                    input_channels,
                    output_channels,
                    user_data_maybe.?,
                );

                return 0;
            }
        }.cb,
        user_data,
    );

    if (err != portaudio.paNoError) {
        std.debug.print("{s}", .{portaudio.Pa_GetErrorText(err)});
        return error.OpenFailed;
    }

    return @ptrCast(stream.?);
}
