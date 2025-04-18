const std = @import("std");
const Ast = @import("Ast.zig");
const Extra = @import("Extra.zig");

const Fir = @This();

pub const EquaveExponent = enum(i32) { _ };
pub const LengthModifier = enum(u32) { _ };
pub const Fraction = struct {
    numerator: u32,
    denominator: u32,
};

pub const Tone = struct {
    pub const Index = enum(u32) { _ };

    // TODO: Equave exponent should also be an instruction

    pub const Tag = std.meta.Tag(Data);
    pub const Data = union(enum(u8)) {
        degree: struct {
            equave_exponent: EquaveExponent,
            root_frequency: Instruction.Index,
            scale: Instruction.Index,
            degree: u32,
        },
        ratio: struct {
            equave_exponent: EquaveExponent,
            root_frequency: Instruction.Index,
            numerator: u32,
            denominator: u32,
        },
        cents: struct {
            equave_exponent: EquaveExponent,
            root_frequency: Instruction.Index,
            cents: f32,
        },
        edostep: struct {
            equave_exponent: EquaveExponent,
            root_frequency: Instruction.Index,
            edostep: u32,
            divisions: u32,
        },
        edxstep: struct {
            equave_exponent: EquaveExponent,
            root_frequency: Instruction.Index,
            edostep: u32,
            divisions: u32,
            equave: Fraction,
        },
        hz: struct {
            equave_exponent: EquaveExponent,
            // TODO: Technically this field is redundant but it makes AstToFir simpler.
            frequency: f32,
        },

        pub const Untagged = Extra.Untagged(Data);
    };

    tag: Tag,
    untagged_data: Data.Untagged,

    src_node: Ast.Node.OptionalIndex,
    instruction: Instruction.Index,

    /// "Final" frequency or ratio - all equave shifts already applied (e.g. for '['0], the Tone
    /// for `0` will consider both equave shifts). Frequency when parent is note or chord, ratio
    /// when parent is a scale.
    value: f32,
};

pub const Instruction = struct {
    pub const Index = enum(u32) { _ };

    pub const Tag = std.meta.Tag(Data);
    pub const Data = union(enum(u8)) {
        root_frequency: struct {
            tone: Tone.Index,
        },
        note: struct {
            tone: Tone.Index,
            held: u32,
        },
        chord: struct {
            equave_exponent: EquaveExponent,
            tones_start: Tone.Index,
            tones_end: Tone.Index,
            held: u32,
        },
        scale: struct {
            equave_exponent: EquaveExponent,
            tones_start: Tone.Index,
            tones_end: Tone.Index,
        },

        pub const Untagged = Extra.Untagged(Data);
    };

    tag: Tag,
    src_node: Ast.Node.OptionalIndex,
    untagged_data: Data.Untagged,
    equave: Fraction,
};

instructions: std.MultiArrayList(Instruction).Slice,
tones: std.MultiArrayList(Tone).Slice,
extra: []const u32,

pub fn deinit(fir: *Fir, allocator: std.mem.Allocator) void {
    fir.instructions.deinit(allocator);
    fir.tones.deinit(allocator);
    allocator.free(fir.extra);
    fir.* = undefined;
}

pub fn instructionDataFromUntagged(
    fir: *const Fir,
    tag: Instruction.Tag,
    untagged: Instruction.Data.Untagged,
) Instruction.Data {
    return untagged.toTagged(fir.extra, tag);
}

pub fn toneDataFromUntagged(
    fir: *const Fir,
    tag: Tone.Tag,
    untagged: Tone.Data.Untagged,
) Tone.Data {
    return untagged.toTagged(fir.extra, tag);
}

pub fn debugPrint(fir: *const Fir) void {
    const tone_tags = fir.tones.items(.tag);
    const tone_untagged_datas = fir.tones.items(.untagged_data);

    for (
        0..,
        fir.instructions.items(.tag),
        fir.instructions.items(.untagged_data),
    ) |
        index,
        tag,
        untagged_data,
    | {
        const data = fir.instructionDataFromUntagged(tag, untagged_data);
        std.debug.print("instruction {d}: ", .{index});

        switch (data) {
            .root_frequency => {
                std.debug.print("root frequency\n", .{});
            },
            .scale => |info| {
                std.debug.print("scale\n", .{});

                for (
                    @intFromEnum(info.tones_start)..@intFromEnum(info.tones_end),
                    tone_tags[@intFromEnum(info.tones_start)..@intFromEnum(info.tones_end)],
                    tone_untagged_datas[@intFromEnum(info.tones_start)..@intFromEnum(info.tones_end)],
                ) |tone_index, tone_tag, tone_untagged_data| {
                    const tone_data = fir.toneDataFromUntagged(tone_tag, tone_untagged_data);
                    std.debug.print("  tone {d}: {any}\n", .{ tone_index, tone_data });
                }
            },
            else => @panic("TODO"),
        }
    }
}
