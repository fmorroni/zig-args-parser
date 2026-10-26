const std = @import("std");

const Debug = @import("debug.zig");

/// How a field of the user's args struct is parsed. Fields default to `.{ .flag = .{} }`.
pub const Arg = union(enum) {
    flag: Flag,
    /// Positionals are assigned in field declaration order.
    positional: Positional,

    pub const Flag = struct {
        short_name: ?u8 = null,
        help: ?[]const u8 = null,
    };

    pub const Positional = struct {
        help: ?[]const u8 = null,
    };
};

/// Type of the `args` declaration of the user's struct: one `Arg` per field.
/// Example usage:
/// ```zig
/// const MyArgs = struct {
///     verbose: bool,
///     count: u8,
///     max_retries: ?u8,
///
///     positional_1: u32,
///     positional_2: []const u8,
///     positional_3: ?f32,
///
///     pub const args: ArgsInfo(@This()) = .{
///         .count = .{ .flag = .{ .short_name = 'c', .help = "Number of whatevers" } },
///         .max_retries = .{ .flag = .{ .short_name = 'r' } },
///         .positional_1 = .{ .positional = .{ .help = "This does something" } },
///         .positional_2 = .{ .positional = .{ .help = "This does other thing" } },
///         .positional_3 = .{ .positional = .{ .help = "This does other other thing" } },
///     };
/// };
/// ```
pub fn ArgsInfo(comptime T: type) type {
    const default: Arg = .{ .flag = .{} };
    return @Struct(.auto, null, std.meta.fieldNames(T), &@splat(Arg), &@splat(.{ .default_value_ptr = &default }));
}

/// Everything the parser needs to know about one field.
const ArgSpec = struct {
    field_name: []const u8,
    long_name: []const u8,
    type: type,
    info: Arg,
};

pub fn ArgsParser(comptime ExpectedArgs: type) type {
    return struct {
        const Errors = error{ MissingFlag, MissingPositional, MissingValue, TooManyArguments, InvalidFlag };

        const args_info: ArgsInfo(ExpectedArgs) = if (@hasDecl(ExpectedArgs, "args")) ExpectedArgs.args else .{};

        const flags = specsOfKind(.flag);
        const positionals = specsOfKind(.positional);

        comptime {
            validateShortNames(&flags);
            validatePositionals(&positionals);
        }

        // TODO: may need to make the return a struct with a `.error` field or something to give
        // better error reports like which flag was invalid or missing.
        pub fn parse(
            iter: anytype,
        ) (Errors || std.fmt.ParseIntError || std.fmt.ParseFloatError)!ExpectedArgs {
            var result: ExpectedArgs = undefined;
            var seen_flags: [flags.len]bool = @splat(false);
            var positional_count: usize = 0;
            // Set by `--`, after which everything is positional, even if it starts with '-'.
            var only_positionals = false;

            args: while (iter.next()) |arg| {
                if (!only_positionals and std.mem.eql(u8, arg, "--")) {
                    only_positionals = true;
                    continue;
                }

                // A lone "-" is a positional, conventionally meaning stdin.
                if (!only_positionals and arg.len > 1 and arg[0] == '-') {
                    inline for (flags, 0..) |flag, i| {
                        if (matches(flag, arg)) {
                            if (comptime expectsValue(flag)) {
                                const value = iter.next() orelse return Errors.MissingValue;
                                @field(result, flag.field_name) = try parseValue(flag.type, value);
                            } else {
                                @field(result, flag.field_name) = true;
                            }
                            seen_flags[i] = true;
                            continue :args;
                        }
                    }
                    return Errors.InvalidFlag;
                }

                inline for (positionals, 0..) |positional, i| {
                    if (positional_count == i) {
                        @field(result, positional.field_name) = try parseValue(positional.type, arg);
                        positional_count += 1;
                        continue :args;
                    }
                }
                return Errors.TooManyArguments;
            }

            inline for (flags, 0..) |flag, i| {
                if (!seen_flags[i]) {
                    switch (@typeInfo(flag.type)) {
                        .optional => @field(result, flag.field_name) = null,
                        .bool => @field(result, flag.field_name) = false,
                        else => return Errors.MissingFlag,
                    }
                }
            }

            inline for (positionals, 0..) |positional, i| {
                if (i >= positional_count) {
                    if (@typeInfo(positional.type) == .optional) {
                        @field(result, positional.field_name) = null;
                    } else return Errors.MissingPositional;
                }
            }

            return result;
        }

        fn specsOfKind(comptime kind: std.meta.Tag(Arg)) [countOfKind(kind)]ArgSpec {
            var specs: [countOfKind(kind)]ArgSpec = undefined;
            var i = 0;
            for (@typeInfo(ExpectedArgs).@"struct".fields) |field| {
                const info = @field(args_info, field.name);
                if (info != kind) continue;
                specs[i] = .{
                    .field_name = field.name,
                    .long_name = snakeToKebab(field.name),
                    .type = field.type,
                    .info = info,
                };
                i += 1;
            }
            return specs;
        }

        fn countOfKind(comptime kind: std.meta.Tag(Arg)) usize {
            var count = 0;
            for (@typeInfo(ExpectedArgs).@"struct".fields) |field| {
                if (@field(args_info, field.name) == kind) count += 1;
            }
            return count;
        }

        fn matches(comptime flag: ArgSpec, arg: []const u8) bool {
            if (std.mem.startsWith(u8, arg, "--")) return std.mem.eql(u8, arg[2..], flag.long_name);
            const c = flag.info.flag.short_name orelse return false;
            return arg.len == 2 and arg[0] == '-' and arg[1] == c;
        }

        fn expectsValue(comptime flag: ArgSpec) bool {
            return switch (@typeInfo(flag.type)) {
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
                .pointer => if (T == []const u8) s else @compileError("unsupported arg type " ++ @typeName(T)),
                else => @compileError("unsupported arg type " ++ @typeName(T)),
            };
        }

        fn snakeToKebab(comptime field_name: []const u8) []const u8 {
            var buf: [field_name.len]u8 = field_name[0..field_name.len].*;
            std.mem.replaceScalar(u8, &buf, '_', '-');
            const final = buf;
            return &final;
        }

        fn validateShortNames(comptime flag_specs: []const ArgSpec) void {
            var seen: [256]?[]const u8 = @splat(null);
            for (flag_specs) |flag| {
                const c = flag.info.flag.short_name orelse continue;
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

        fn validatePositionals(comptime positional_specs: []const ArgSpec) void {
            var first_optional: ?[]const u8 = null;
            for (positional_specs) |positional| {
                switch (@typeInfo(positional.type)) {
                    .bool => @compileError("positional `" ++ positional.field_name ++ "` can't be a bool"),
                    .optional => {
                        if (first_optional == null) first_optional = positional.field_name;
                    },
                    else => if (first_optional) |optional| @compileError(
                        "required positional `" ++ positional.field_name ++
                            "` comes after optional positional `" ++ optional ++ "`",
                    ),
                }
            }
        }
    };
}

const TestArgs = struct {
    verbose: bool,
    count: u8,
    max_retries: ?u8,
    some_float: ?f32,

    positional_1: u32,
    positional_2: []const u8,
    positional_3: ?f32,

    const all_present: @This() = .{
        .verbose = true,
        .count = 3,
        .max_retries = 5,
        .some_float = 3.3,
        .positional_1 = 42,
        .positional_2 = "test string",
        .positional_3 = 5.5,
    };

    const only_required: @This() = .{
        .verbose = false,
        .count = 3,
        .max_retries = null,
        .some_float = null,
        .positional_1 = 42,
        .positional_2 = "test string",
        .positional_3 = null,
    };

    pub const args: ArgsInfo(@This()) = .{
        .count = .{ .flag = .{ .short_name = 'c', .help = "Number of whatevers" } },
        .max_retries = .{ .flag = .{ .short_name = 'r' } },
        .some_float = .{ .flag = .{ .short_name = 'f' } },
        .positional_1 = .{ .positional = .{ .help = "This does something" } },
        .positional_2 = .{ .positional = .{ .help = "This does other thing" } },
        .positional_3 = .{ .positional = .{ .help = "This does other other thing" } },
    };
};
const TestParser = ArgsParser(TestArgs);

const SliceIterator = struct {
    args: []const []const u8,
    index: usize = 0,

    fn next(self: *SliceIterator) ?[]const u8 {
        if (self.index >= self.args.len) return null;
        defer self.index += 1;
        return self.args[self.index];
    }
};

fn testParse(args: []const []const u8) !TestArgs {
    var iter: SliceIterator = .{ .args = args };
    return TestParser.parse(&iter);
}

test "long and short names are equivalent" {
    Debug.dumpComptime(TestParser.args_info);
    try std.testing.expectEqual(TestArgs.all_present, try testParse(&.{
        "42",
        "test string",
        "5.5",
        "--verbose",
        "--count",
        "3",
        "--max-retries",
        "5",
        "--some-float",
        "3.3",
    }));
    try std.testing.expectEqual(TestArgs.all_present, try testParse(&.{
        "42",
        "test string",
        "5.5",
        "--verbose",
        "-c",
        "3",
        "-r",
        "5",
        "-f",
        "3.3",
    }));
}

test "flags can come in any order" {
    try std.testing.expectEqual(TestArgs.all_present, try testParse(&.{
        "42",
        "test string",
        "5.5",
        "-r",
        "5",
        "-f",
        "3.3",
        "--verbose",
        "-c",
        "3",
    }));
}

test "positional arguments must come in the specified order" {
    try std.testing.expectError(error.InvalidCharacter, testParse(&.{ "test string", "42", "-c", "3" }));
}

test "flag values can start with '-'" {
    var expected = TestArgs.only_required;
    expected.some_float = -3.3;
    try std.testing.expectEqual(expected, try testParse(&.{ "42", "test string", "-c", "3", "-f", "-3.3" }));
}

test "everything after `--` is positional" {
    var expected = TestArgs.only_required;
    expected.positional_3 = -5.5;
    try std.testing.expectEqual(expected, try testParse(&.{ "42", "-c", "3", "--", "test string", "-5.5" }));
    try std.testing.expectError(error.InvalidCharacter, testParse(&.{ "42", "test string", "--", "-c", "3" }));
}

test "omitted optional/boolean flags and arguments are null" {
    try std.testing.expectEqual(TestArgs.only_required, try testParse(&.{
        "42",
        "test string",
        "-c",
        "3",
    }));
}

test "long names use kebab-case only" {
    try std.testing.expectError(error.InvalidFlag, testParse(&.{
        "42",
        "test string",
        "-c",
        "3",
        "--max_retries",
        "5",
    }));
}

test "errors" {
    try std.testing.expectError(error.MissingFlag, testParse(&.{ "42", "test string" }));
    try std.testing.expectError(error.MissingPositional, testParse(&.{ "42", "-c", "3" }));
    try std.testing.expectError(error.MissingValue, testParse(&.{ "42", "test string", "-c" }));
    try std.testing.expectError(error.InvalidFlag, testParse(&.{ "42", "test string", "-c", "3", "--unknown" }));
    try std.testing.expectError(error.InvalidFlag, testParse(&.{ "42", "test string", "-c", "3", "-x" }));
    try std.testing.expectError(error.TooManyArguments, testParse(&.{ "42", "test string", "5.5", "extra", "-c", "3" }));
    try std.testing.expectError(error.InvalidCharacter, testParse(&.{ "42", "test string", "-c", "abc" }));
    try std.testing.expectError(error.Overflow, testParse(&.{ "42", "test string", "-c", "256" }));
}
