const std = @import("std");

const NoteSpool = @This();

const spool_voices = 16;

pub const Note = struct {
    start: u32,
    end: u32,
    frequency: f32,
};

sample_rate: f32,

sin: Sin(spool_voices) = .{},
adsr: Adsr(spool_voices) = .{},
notes: std.MultiArrayList(Note).Slice,

playing: u32 = 0,
sample: u32 = 0,

gates: [spool_voices]bool = @splat(false),
frequencies: [spool_voices]f32 = @splat(0),

done: bool = false,

pub fn deinit(note_spool: *NoteSpool, allocator: std.mem.Allocator) void {
    note_spool.notes.deinit(allocator);
    note_spool.* = undefined;
}

pub fn debugPrint(note_spool: *const NoteSpool) void {
    for (
        note_spool.notes.items(.start),
        note_spool.notes.items(.end),
        note_spool.notes.items(.frequency),
    ) |start, end, frequency| {
        std.debug.print("{d}..{d}: {d}hz\n", .{ start, end, frequency });
    }
}

pub fn tick(note_spool: *NoteSpool) @Vector(spool_voices, f32) {
    defer note_spool.sample += 1;

    if (note_spool.playing >= note_spool.notes.len and
        @reduce(.And, note_spool.adsr.envelopes < @as(@Vector(spool_voices, f32), @splat(0.001))))
    {
        @atomicStore(bool, &note_spool.done, true, .release);
    }

    const slice_start = note_spool.playing;
    const slice_end = note_spool.playing + @min(spool_voices, note_spool.notes.len - note_spool.playing);

    for (
        note_spool.notes.items(.frequency)[slice_start..slice_end],
        note_spool.notes.items(.start)[slice_start..slice_end],
        note_spool.notes.items(.end)[slice_start..slice_end],
        slice_start..,
    ) |frequency, start, end, index| {
        const done = end <= note_spool.sample;
        note_spool.playing += @intFromBool(done);

        if (note_spool.sample < start) break;

        note_spool.gates[index % spool_voices] = !done;
        note_spool.frequencies[index % spool_voices] = frequency;
    }

    return note_spool.sin.tick(
        note_spool.sample_rate,
        note_spool.frequencies,
    ) * note_spool.adsr.tick(
        note_spool.sample_rate,
        .{
            .attack_seconds = @splat(0.01),
            .decay_seconds = @splat(0.001),
            .sustain_amps = @splat(0.8),
            .release_seconds = @splat(0.01),
            .gates = note_spool.gates,
        },
    );
}

pub fn Sin(comptime voices: u16) type {
    return struct {
        phases: @Vector(voices, f32) = @splat(0),

        pub fn tick(
            sin: *@This(),
            sample_rate: f32,
            frequencies: @Vector(voices, f32),
        ) @Vector(voices, f32) {
            const outputs = @sin(@as(@Vector(voices, f32), @splat(2 * std.math.pi)) * sin.phases);

            const delta_phases = frequencies / @as(@Vector(voices, f32), @splat(sample_rate));
            sin.phases += delta_phases;
            sin.phases -= @floor(sin.phases);

            return outputs;
        }
    };
}

fn boolFromInt(comptime voices: u16, x: @Vector(voices, u1)) @Vector(voices, bool) {
    return x != @as(@Vector(voices, u1), @splat(0));
}

pub fn Adsr(comptime voices: u16) type {
    return struct {
        const Params = struct {
            attack_seconds: @Vector(voices, f32),
            decay_seconds: @Vector(voices, f32),
            sustain_amps: @Vector(voices, f32),
            release_seconds: @Vector(voices, f32),
            gates: @Vector(voices, bool),
        };

        old_gates: @Vector(voices, bool) = @splat(false),
        attacking: @Vector(voices, bool) = @splat(false),
        envelopes: @Vector(voices, f32) = @splat(0),

        pub fn tick(
            adsr: *@This(),
            sample_rate: f32,
            params: Params,
        ) @Vector(voices, f32) {
            defer adsr.old_gates = params.gates;

            adsr.attacking = boolFromInt(
                voices,
                @intFromBool(adsr.attacking) |
                    (@intFromBool(params.gates) & ~@intFromBool(adsr.old_gates)),
            );

            adsr.attacking = boolFromInt(voices, @intFromBool(adsr.attacking) & @intFromBool(params.gates));

            const targets = @select(
                f32,
                adsr.attacking,
                @as(@Vector(voices, f32), @splat(1.2)),
                @select(
                    f32,
                    params.gates,
                    params.sustain_amps,
                    @as(@Vector(voices, f32), @splat(0)),
                ),
            );

            const times = @select(
                f32,
                adsr.attacking,
                params.attack_seconds,
                @select(
                    f32,
                    params.gates,
                    params.decay_seconds,
                    params.release_seconds,
                ),
            );

            // NOTE: from https://www.music.mcgill.ca/~gary/307/week1/node22.html
            // don't feel too confident about this one but most of the sources I found were equally
            // as questionable

            const a = @exp(-@as(@Vector(voices, f32), @splat(2 / sample_rate)) / times);
            adsr.envelopes = a * adsr.envelopes + (@as(@Vector(voices, f32), @splat(1)) - a) * targets;

            adsr.attacking = boolFromInt(voices, @intFromBool(adsr.attacking) & @intFromBool(adsr.envelopes < @as(@Vector(voices, f32), @splat(1))));

            return adsr.envelopes;
        }
    };
}
