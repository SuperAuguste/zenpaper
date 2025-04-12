//! Tokenizer based on info available @ https://github.com/dxinteractive/xenpaper.

const std = @import("std");

pub const Token = struct {
    tag: Tag,
    range: Range,

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

    pub const Slice = struct { start: Token.Index, end: Token.Index };
    pub const OptionalSlice = struct {
        pub const none = OptionalSlice{ .start = .none, .end = .none };

        start: Token.OptionalIndex,
        end: Token.OptionalIndex,

        pub fn wrap(slice: ?Slice) OptionalSlice {
            return if (slice) |s|
                .{ .start = .wrap(s.start), .end = .wrap(s.end) }
            else
                .{ .start = .none, .end = .none };
        }

        pub fn unwrap(optional: OptionalSlice) ?Slice {
            return if (optional.start.unwrap()) |start|
                .{ .start = start, .end = optional.end.unwrap().? }
            else
                null;
        }
    };

    pub const Range = struct {
        start: u32,
        end: u32,
    };

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{
        // .keyword_hz is the only case insensitive keyword.
        .{ "hz", .keyword_hz },
        .{ "Hz", .keyword_hz },
        .{ "hZ", .keyword_hz },
        .{ "HZ", .keyword_hz },

        .{ "c", .keyword_c },
        .{ "edo", .keyword_edo },
        .{ "ed", .keyword_ed },
        .{ "m", .keyword_m },
        .{ "r", .keyword_r },
        .{ "o", .keyword_o },
    });

    pub const Tag = enum {
        invalid,
        whitespace,

        // Tokens fundamental to the language.
        keyword_hz,
        keyword_c,
        keyword_edo,
        keyword_ed,
        keyword_m,
        keyword_r,
        keyword_o,

        /// Higher-level identifiers used in setters like "bpm," "osc," and "env."
        identifier,

        integer,
        dash,
        period,
        slash,
        backslash,
        backtick,
        single_quote,
        double_quote,
        left_square,
        right_square,
        left_curly,
        right_curly,
        left_paren,
        right_paren,
        semicolon,
        colon,
        colon_colon,

        eof,

        comptime {
            std.debug.assert(@sizeOf(Tag) == 1);
        }
    };
};

const Tokenizer = @This();

buffer: [:0]const u8,
index: u32,

pub fn init(buffer: [:0]const u8) Tokenizer {
    // Skip the UTF-8 BOM if present.
    return .{
        .buffer = buffer,
        .index = if (std.mem.startsWith(u8, buffer, "\xEF\xBB\xBF")) 3 else 0,
    };
}

const State = enum {
    start,
    comment,
    whitespace,
    identifier,
    integer,
    colon,
};

/// An eof token will always be returned at the end.
pub fn next(tokenizer: *Tokenizer) Token {
    var result: Token = .{
        .tag = undefined,
        .range = .{
            .start = tokenizer.index,
            .end = undefined,
        },
    };

    // `continue`s change the machine's `State` while `break`s set the result tag.
    result.tag = state_machine: switch (State.start) {
        .start => switch (tokenizer.buffer[tokenizer.index]) {
            0 => {
                if (tokenizer.index == tokenizer.buffer.len) {
                    return .{
                        .tag = .eof,
                        .range = .{
                            .start = tokenizer.index,
                            .end = tokenizer.index,
                        },
                    };
                } else {
                    tokenizer.index += 1;
                    break :state_machine .invalid;
                }
            },
            '#' => {
                continue :state_machine .comment;
            },
            ' ', '\n', '\r', '\t', '|', ',' => {
                continue :state_machine .whitespace;
            },
            'a'...'z', 'A'...'Z' => {
                continue :state_machine .identifier;
            },
            '0'...'9' => {
                continue :state_machine .integer;
            },
            '-' => {
                tokenizer.index += 1;
                break :state_machine .dash;
            },
            '.' => {
                tokenizer.index += 1;
                break :state_machine .period;
            },
            '/' => {
                tokenizer.index += 1;
                break :state_machine .slash;
            },
            '\\' => {
                tokenizer.index += 1;
                break :state_machine .backslash;
            },
            '`' => {
                tokenizer.index += 1;
                break :state_machine .backtick;
            },
            '\'' => {
                tokenizer.index += 1;
                break :state_machine .single_quote;
            },
            '"' => {
                tokenizer.index += 1;
                break :state_machine .double_quote;
            },
            '[' => {
                tokenizer.index += 1;
                break :state_machine .left_square;
            },
            ']' => {
                tokenizer.index += 1;
                break :state_machine .right_square;
            },
            '{' => {
                tokenizer.index += 1;
                break :state_machine .left_curly;
            },
            '}' => {
                tokenizer.index += 1;
                break :state_machine .right_curly;
            },
            '(' => {
                tokenizer.index += 1;
                break :state_machine .left_paren;
            },
            ')' => {
                tokenizer.index += 1;
                break :state_machine .right_paren;
            },
            ';' => {
                tokenizer.index += 1;
                break :state_machine .semicolon;
            },
            ':' => {
                continue :state_machine .colon;
            },
            else => {
                tokenizer.index += 1;
                break :state_machine .invalid;
            },
        },
        .comment => {
            tokenizer.index += 1;
            switch (tokenizer.buffer[tokenizer.index]) {
                '\n' => {
                    tokenizer.index += 1;
                    result.range.start = tokenizer.index;
                    continue :state_machine .start;
                },
                0 => break :state_machine .eof,
                else => continue :state_machine .comment,
            }
        },
        .whitespace => {
            tokenizer.index += 1;
            switch (tokenizer.buffer[tokenizer.index]) {
                ' ', '\n', '\r', '\t', '|', ',' => {
                    continue :state_machine .whitespace;
                },
                else => {
                    break :state_machine .whitespace;
                },
            }
        },
        .identifier => {
            tokenizer.index += 1;
            switch (tokenizer.buffer[tokenizer.index]) {
                'a'...'z', 'A'...'Z' => {
                    continue :state_machine .identifier;
                },
                else => {
                    if (Token.keywords.get(tokenizer.buffer[result.range.start..tokenizer.index])) |tag| {
                        break :state_machine tag;
                    }

                    break :state_machine .identifier;
                },
            }
        },
        .integer => {
            tokenizer.index += 1;
            switch (tokenizer.buffer[tokenizer.index]) {
                '0'...'9' => {
                    continue :state_machine .integer;
                },
                else => {
                    break :state_machine .integer;
                },
            }
        },
        .colon => {
            tokenizer.index += 1;
            switch (tokenizer.buffer[tokenizer.index]) {
                ':' => {
                    tokenizer.index += 1;
                    break :state_machine .colon_colon;
                },
                else => {
                    break :state_machine .colon;
                },
            }
        },
    };

    result.range.end = tokenizer.index;
    return result;
}

pub fn tokenize(
    allocator: std.mem.Allocator,
    buffer: [:0]const u8,
) std.mem.Allocator.Error!Tokens {
    var tokens: std.MultiArrayList(Token) = .{};
    var tokenizer = Tokenizer.init(buffer);
    var token = tokenizer.next();
    while (token.tag != .eof) : (token = tokenizer.next()) {
        try tokens.append(allocator, token);
    }
    try tokens.append(allocator, token);

    return .{
        .slice = tokens.toOwnedSlice(),
    };
}

pub const Tokens = struct {
    slice: std.MultiArrayList(Token).Slice,

    pub fn deinit(tokens: *Tokens, allocator: std.mem.Allocator) void {
        tokens.slice.deinit(allocator);
        tokens.* = undefined;
    }

    pub fn tag(tokens: *const Tokens, token: Token.Index) Token.Tag {
        return tokens.slice.items(.tag)[@intFromEnum(token)];
    }

    pub fn range(tokens: *const Tokens, token: Token.Index) Token.Range {
        return tokens.slice.items(.range)[@intFromEnum(token)];
    }

    pub fn sliceSource(tokens: *const Tokens, source: []const u8, token: Token.Index) []const u8 {
        const token_range = tokens.range(token);
        return source[token_range.start..token_range.end];
    }
};
