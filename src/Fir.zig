const std = @import("std");
const Ast = @import("Ast.zig");
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;
const Extra = @import("Extra.zig");

const Fir = @This();

pub const EquaveExponent = enum(i32) { _ };
pub const LengthModifier = enum(u32) { _ };
pub const Fraction = struct {
    numerator: u32,
    denominator: u32,

    pub fn float(fraction: Fraction) f32 {
        std.debug.assert(fraction.denominator != 0);
        return @as(f32, @floatFromInt(fraction.numerator)) /
            @as(f32, @floatFromInt(fraction.denominator));
    }
};

pub const Tone = struct {
    pub const Index = enum(u32) { _ };
    pub const OptionalIndex = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn wrap(maybe_index: ?Index) OptionalIndex {
            if (maybe_index) |index| {
                const optional: OptionalIndex = @enumFromInt(@intFromEnum(index));
                std.debug.assert(optional != .none);
                return optional;
            } else {
                return .none;
            }
        }

        pub fn unwrap(optional: OptionalIndex) ?Index {
            return switch (optional) {
                .none => null,
                _ => |value| @enumFromInt(@intFromEnum(value)),
            };
        }
    };
    pub const Range = struct {
        start: Tone.Index,
        end: Tone.Index,

        pub fn len(range: Range) u32 {
            return @intFromEnum(range.end) - @intFromEnum(range.start);
        }
    };

    pub const Tag = std.meta.Tag(Data);
    pub const Data = union(enum(u8)) {
        degree: struct {
            equave_exponent: EquaveExponent,
            scale: Instruction.Index,
            degree: u32,
        },
        ratio: struct {
            equave_exponent: EquaveExponent,
            ratio: Fraction,
        },
        cents: struct {
            equave_exponent: EquaveExponent,
            cents: f32,
        },
        edostep: struct {
            equave_exponent: EquaveExponent,
            edostep: u32,
            divisions: u32,
        },
        edxstep: struct {
            equave_exponent: EquaveExponent,
            edostep: u32,
            divisions: u32,
            equave: Fraction,
        },
        hz: struct {
            equave_exponent: EquaveExponent,
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
            equave_exponent: EquaveExponent,
            root_frequency: Tone.Index,
            tone: Tone.Index,
        },
        note: struct {
            root_frequency: Tone.Index,
            tone: Tone.Index,
            length_modifier: LengthModifier,
        },
        chord: struct {
            equave_exponent: EquaveExponent,
            root_frequency: Tone.Index,
            tones: Tone.Range,
            length_modifier: LengthModifier,
        },
        scale: struct {
            equave_exponent: EquaveExponent,
            tones: Tone.Range,
            equave: Tone.OptionalIndex,
        },

        pub const Untagged = Extra.Untagged(Data);
    };

    tag: Tag,
    src_node: Ast.Node.OptionalIndex,
    untagged_data: Data.Untagged,

    equave: Tone.Index,
};

pub const Error = struct {
    pub const Tag = enum(u8) {
        /// token
        invalid_integer,
        /// token
        invalid_float,
        /// token
        denominator_zero,
    };

    pub const Data = union {
        token: Token.Index,
    };

    tag: Tag,
    data: Data,

    pub fn render(@"error": Error, writer: anytype) @TypeOf(writer).Error!void {
        switch (@"error".tag) {
            .invalid_integer => {
                try writer.print("invalid integer\n", .{});
            },
            .invalid_float => {
                try writer.print("invalid float\n", .{});
            },
            .denominator_zero => {
                try writer.print("denominator cannot be zero\n", .{});
            },
        }
    }
};

instructions: std.MultiArrayList(Instruction).Slice,
tones: std.MultiArrayList(Tone).Slice,
extra: []const u32,
errors: []const Error,

pub fn deinit(fir: *Fir, allocator: std.mem.Allocator) void {
    fir.instructions.deinit(allocator);
    fir.tones.deinit(allocator);
    allocator.free(fir.extra);
    allocator.free(fir.errors);
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

fn debugPrintTone(fir: *const Fir, tone: Tone.Index) void {
    const tag = fir.tones.items(.tag)[@intFromEnum(tone)];
    const untagged_data = fir.tones.items(.untagged_data)[@intFromEnum(tone)];
    const value = fir.tones.items(.value)[@intFromEnum(tone)];
    const src_node = fir.tones.items(.src_node)[@intFromEnum(tone)];
    const data = fir.toneDataFromUntagged(tag, untagged_data);

    std.debug.print("tone {d}: {s} - value {d} - ", .{ @intFromEnum(tone), @tagName(data), value });

    switch (data) {
        .degree => |info| {
            std.debug.print("{d}", .{info.degree});
        },
        .ratio => |info| {
            std.debug.print("{d}/{d}", .{ info.ratio.numerator, info.ratio.denominator });
        },
        .cents => |info| {
            std.debug.print("{d}c", .{info.cents});
        },
        .edostep => |info| {
            std.debug.print("{d}\\{d}", .{ info.edostep, info.divisions });
        },
        .edxstep => |info| {
            std.debug.print("{d}\\{d}o{d}/{d}", .{ info.edostep, info.divisions, info.equave.numerator, info.equave.denominator });
        },
        .hz => |info| {
            std.debug.print("{d}hz", .{info.frequency});
        },
    }

    if (src_node.unwrap() == null) {
        std.debug.print(" (implicit)", .{});
    }
}

pub fn debugPrint(fir: *const Fir) void {
    for (
        0..,
        fir.instructions.items(.tag),
        fir.instructions.items(.src_node),
        fir.instructions.items(.untagged_data),
    ) |
        index,
        tag,
        src_node,
        untagged_data,
    | {
        const data = fir.instructionDataFromUntagged(tag, untagged_data);

        std.debug.print("instruction {d}: {s}", .{ index, @tagName(data) });
        if (src_node.unwrap() == null) {
            std.debug.print(" (implicit)", .{});
        }
        std.debug.print("\n", .{});

        switch (data) {
            .root_frequency => |info| {
                std.debug.print("  equave exponent {d}\n  ", .{@intFromEnum(info.equave_exponent)});
                fir.debugPrintTone(info.tone);
                std.debug.print("\n", .{});
            },
            .note => |info| {
                std.debug.print("  ", .{});
                fir.debugPrintTone(info.tone);
                std.debug.print("\n", .{});
            },
            .chord => |info| {
                std.debug.print("  children:\n", .{});
                for (@intFromEnum(info.tones.start)..@intFromEnum(info.tones.end)) |tone_index| {
                    std.debug.print("    ", .{});
                    fir.debugPrintTone(@enumFromInt(tone_index));
                    std.debug.print("\n", .{});
                }
            },
            .scale => |info| {
                std.debug.print("  equave exponent {d}\n", .{@intFromEnum(info.equave_exponent)});
                std.debug.print("  children:\n", .{});
                for (@intFromEnum(info.tones.start)..@intFromEnum(info.tones.end)) |tone_index| {
                    std.debug.print("    ", .{});
                    fir.debugPrintTone(@enumFromInt(tone_index));
                    std.debug.print("\n", .{});
                }
                if (info.equave.unwrap()) |equave| {
                    std.debug.print("  equave:\n    ", .{});
                    fir.debugPrintTone(equave);
                    std.debug.print("\n", .{});
                }
            },
        }
    }
}
