const std = @import("std");
const Fir = @import("Fir.zig");
const NoteSpool = @import("NoteSpool.zig");
const Note = NoteSpool.Note;
const assert = std.debug.assert;

pub fn firToSpool(
    allocator: std.mem.Allocator,
    fir: *const Fir,
    sample_rate: f32,
) error{OutOfMemory}!NoteSpool {
    assert(fir.errors.len == 0);

    var notes = std.MultiArrayList(Note){};
    // A good approximation; always larger than the actual count
    try notes.ensureTotalCapacity(allocator, fir.tones.capacity);

    const tags = fir.instructions.items(.tag);
    const untagged_datas = fir.instructions.items(.untagged_data);
    const values = fir.tones.items(.value);

    for (tags, untagged_datas) |tag, untagged_data| {
        const data = fir.instructionDataFromUntagged(tag, untagged_data);
        switch (data) {
            .note => |info| {
                notes.appendAssumeCapacity(.{
                    .start = @intFromFloat(sample_rate * info.timing.start_seconds),
                    .end = @intFromFloat(sample_rate * info.timing.end_seconds),
                    .frequency = values[@intFromEnum(info.tone)],
                });
            },
            .chord => |info| {
                for (values[@intFromEnum(info.tones.start)..@intFromEnum(info.tones.end)]) |value| {
                    notes.appendAssumeCapacity(.{
                        .start = @intFromFloat(sample_rate * info.timing.start_seconds),
                        .end = @intFromFloat(sample_rate * info.timing.end_seconds),
                        .frequency = value,
                    });
                }
            },
            else => {},
        }
    }

    return .{
        .sample_rate = sample_rate,
        .notes = notes.toOwnedSlice(),
    };
}
