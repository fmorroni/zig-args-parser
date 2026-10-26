const std = @import("std");

const Debug = @import("debug.zig");

pub const Flag = struct {
    short_name: ?u8 = null,
    help: ?[]const u8 = null,
};

const FullFlag = struct {
    field_name: []const u8,
    long_name: []const u8,
    short_name: ?u8,
    help: ?[]const u8,
    expected_type: type,
};

// TODO: implement positional arguments.
pub fn ArgsParser(comptime ExpectedArgs: type) type {
    return struct {
        const Errors = error{ MissingFlag, MissingValue, TooManyArguments, InvalidFlag };

        const flags = blk: {
            const info = @typeInfo(ExpectedArgs);
            var full_flags: [info.@"struct".fields.len]FullFlag = undefined;
            for (info.@"struct".fields, 0..) |field, i| {
                full_flags[i] = .{
                    .field_name = field.name,
                    .long_name = snakeToKebab(field.name),
                    .short_name = @field(ExpectedArgs.flags, field.name).short_name,
                    .help = @field(ExpectedArgs.flags, field.name).help,
                    .expected_type = field.type,
                };
            }
            validateShortNames(&full_flags);
            break :blk full_flags;
        };

        // TODO: may need to make the return a struct with a `.error` field or something to give
        // better error reports like which flag was invalid or missing.
        pub fn parse(
            iter: anytype,
        ) (Errors || std.fmt.ParseIntError || std.fmt.ParseFloatError)!ExpectedArgs {
            var result: ExpectedArgs = undefined;
            var seen: [flags.len]bool = @splat(false);

            args: while (iter.next()) |arg| {
                inline for (flags, 0..) |flag, i| {
                    if (matches(flag, arg)) {
                        if (comptime expectsValue(flag)) {
                            const value = iter.next() orelse return Errors.MissingValue;
                            @field(result, flag.field_name) = try parseValue(flag.expected_type, value);
                        } else {
                            @field(result, flag.field_name) = true;
                        }
                        seen[i] = true;
                        continue :args;
                    }
                }
                return error.InvalidFlag;
            }

            inline for (flags, 0..) |flag, i| {
                if (!seen[i]) {
                    const info = @typeInfo(flag.expected_type);
                    switch (info) {
                        .optional => @field(result, flag.field_name) = null,
                        .bool => @field(result, flag.field_name) = false,
                        else => return Errors.MissingFlag,
                    }
                }
            }

            return result;
        }

        fn matches(comptime flag: FullFlag, arg: []const u8) bool {
            if (std.mem.startsWith(u8, arg, "--")) return std.mem.eql(u8, arg[2..], flag.long_name);
            const c = flag.short_name orelse return false;
            return arg.len == 2 and arg[0] == '-' and arg[1] == c;
        }

        fn expectsValue(comptime flag: FullFlag) bool {
            return switch (@typeInfo(flag.expected_type)) {
                .bool => false,
                else => true,
            };
        }

        fn parseValue(comptime T: type, s: []const u8) !T {
            return switch (@typeInfo(T)) {
                .int => std.fmt.parseInt(T, s, 10),
                .float => std.fmt.parseFloat(T, s),
                .optional => |o| try parseValue(o.child, s),
                .bool => unreachable,
                else => @compileError("unsupported flag type " ++ @typeName(T)),
            };
        }

        fn snakeToKebab(comptime field_name: []const u8) []const u8 {
            var buf: [field_name.len]u8 = field_name[0..field_name.len].*;
            std.mem.replaceScalar(u8, &buf, '_', '-');
            const final = buf;
            return &final;
        }

        fn validateShortNames(comptime full_flags: []const FullFlag) void {
            var seen: [256]?[]const u8 = @splat(null);
            for (full_flags) |flag| {
                const c = flag.short_name orelse continue;
                if (!std.ascii.isAlphanumeric(c)) @compileError(std.fmt.comptimePrint(
                    "short name '{c}' of flag `{s}` is not alphanumeric",
                    .{ c, flag.long_name },
                ));
                if (seen[c]) |other| @compileError(std.fmt.comptimePrint(
                    "short name '{c}' is used by both `{s}` and `{s}`",
                    .{ c, other, flag.long_name },
                ));
                seen[c] = flag.long_name;
            }
        }
    };
}

pub fn FlagInfo(comptime T: type) type {
    const default: Flag = .{};
    return @Struct(.auto, null, std.meta.fieldNames(T), &@splat(Flag), &@splat(.{ .default_value_ptr = &default }));
}

const TestFlags = struct {
    verbose: bool,
    count: u8,
    max_retries: ?u8,
    some_float: ?f32,

    pub const flags: FlagInfo(@This()) = .{
        .count = .{ .short_name = 'c' },
        .max_retries = .{ .short_name = 'r' },
        .some_float = .{ .short_name = 'f' },
    };
};
const TestParser = ArgsParser(TestFlags);

fn testParse(args: []const u8) !TestFlags {
    var tok = std.mem.tokenizeScalar(u8, args, ' ');
    const flags = try TestParser.parse(&tok);
    return flags;
}

test "long and short names are equivalent" {
    const expected: TestFlags = .{ .verbose = true, .count = 3, .max_retries = 5, .some_float = 3.3 };
    try std.testing.expectEqual(expected, try testParse("--verbose --count 3 --max-retries 5 --some-float 3.3"));
    try std.testing.expectEqual(expected, try testParse("--verbose -c 3 -r 5 -f 3.3"));
}

test "flags can come in any order" {
    try std.testing.expectEqual(
        TestFlags{ .verbose = true, .count = 3, .max_retries = 5, .some_float = 3.3 },
        try testParse("-r 5 -f 3.3 --verbose -c 3"),
    );
}

test "omitted optional flag is null" {
    try std.testing.expectEqual(
        TestFlags{ .verbose = true, .count = 3, .max_retries = null, .some_float = null },
        try testParse("--verbose -c 3"),
    );
}

test "omitted boolean flag is false" {
    try std.testing.expectEqual(
        TestFlags{ .verbose = false, .count = 3, .max_retries = null, .some_float = null },
        try testParse("-c 3"),
    );
}

test "long names use kebab-case only" {
    try std.testing.expectError(error.InvalidFlag, testParse("-c 3 --max_retries 5"));
}

test "errors" {
    try std.testing.expectError(error.MissingFlag, testParse("--verbose"));
    try std.testing.expectError(error.MissingValue, testParse("--verbose -c"));
    try std.testing.expectError(error.InvalidFlag, testParse("--verbose -c 3 --unknown"));
    try std.testing.expectError(error.InvalidFlag, testParse("--verbose -c 3 -x"));
    try std.testing.expectError(error.InvalidFlag, testParse("--verbose -c 3 positional"));
    try std.testing.expectError(error.InvalidCharacter, testParse("--verbose -c abc"));
    try std.testing.expectError(error.Overflow, testParse("--verbose -c 256"));
}
