const std = @import("std");

const Debug = @import("debug.zig");
const help = @import("help.zig");

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
pub const ArgSpec = struct {
    field_name: []const u8,
    long_name: []const u8,
    type: type,
    default_value_ptr: ?*const anyopaque,
    info: Arg,

    /// The value used when the argument isn't given, or `null` if it's required. Without an explicit
    /// default, optionals default to `null` and bools to `false`.
    pub fn defaultValue(comptime spec: ArgSpec) ?spec.type {
        if (spec.default_value_ptr) |ptr| return @as(*const spec.type, @ptrCast(@alignCast(ptr))).*;
        return switch (@typeInfo(spec.type)) {
            .optional => @as(spec.type, null),
            .bool => false,
            else => null,
        };
    }

    /// Whether a flag takes a value. Bool flags don't: their presence means `true`.
    pub fn expectsValue(comptime spec: ArgSpec) bool {
        return spec.type != bool;
    }
};

/// `max_retries` -> `max-retries`, for flag names and enum values.
pub fn snakeToKebab(comptime field_name: []const u8) []const u8 {
    // Need comptime so the result is stored as binary rodata.
    return comptime blk: {
        var buf: [field_name.len]u8 = field_name[0..field_name.len].*;
        std.mem.replaceScalar(u8, &buf, '_', '-');
        const final = buf;
        break :blk &final;
    };
}

/// Extra information about a `parse` call.
pub const Diagnostics = struct {
    /// `argv[0]`.
    program_name: []const u8 = "",
    /// What caused the error. Unchanged by `HelpRequested`.
    cause: Cause = .{},

    /// | Error                               | `argument`                              | `input`                  |
    /// | ----------------------------------- | --------------------------------------- | ------------------------ |
    /// | `InvalidFlag`                       | `null`                                  | The unknown flag         |
    /// | `TooManyArguments`                  | `null`                                  | The first extra argument |
    /// | `MissingFlag`                       | Both names, e.g. `-o, --output`         | `null`                   |
    /// | `MissingPositional`                 | As shown in the help, e.g. `<input>`    | `null`                   |
    /// | `MissingValue`                      | The flag as given, e.g. `-o`            | `null`                   |
    /// | `InvalidValue`                      | The flag as given, or the positional    | The value                |
    /// | `InvalidCharacter`, `Overflow`, ... | The flag as given, or the positional    | The value                |
    pub const Cause = struct {
        /// The argument the error is about, or `null` if the input didn't match any argument.
        argument: ?[]const u8 = null,
        /// The command-line text that caused the error, or `null` if the error is about something
        /// missing.
        input: ?[]const u8 = null,
    };
};

/// `-h`/`--help` is built in: `parse` returns `error.HelpRequested`, and `printHelp` prints the help.
pub fn ArgsParser(comptime ExpectedArgs: type) type {
    return struct {
        pub const Errors = error{
            HelpRequested,
            MissingFlag,
            MissingPositional,
            MissingValue,
            TooManyArguments,
            InvalidFlag,
            InvalidValue,
        } || std.fmt.ParseIntError || std.fmt.ParseFloatError;

        const args_info: ArgsInfo(ExpectedArgs) = if (@hasDecl(ExpectedArgs, "args")) ExpectedArgs.args else .{};

        const flags = specsOfKind(.flag);
        const positionals = specsOfKind(.positional);
        const help_text = help.generate(&flags, &positionals);

        comptime {
            validateShortNames(&flags);
            validatePositionals(&positionals);
        }

        /// Expects the full argument list, including the program name (`argv[0]`) first. Pass a
        /// `Diagnostics` to find out the program name and which argument caused an error.
        pub fn parse(
            iter: anytype,
            diag: ?*Diagnostics,
        ) Errors!ExpectedArgs {
            var result: ExpectedArgs = undefined;
            var seen_flags: [flags.len]bool = @splat(false);
            var positional_count: usize = 0;
            // Set by `--`, after which everything is positional, even if it starts with '-'.
            var only_positionals = false;

            // `iter` is user defined and could be empty.
            const program_name = iter.next() orelse "";
            if (diag) |d| d.program_name = program_name;

            args: while (iter.next()) |arg| {
                if (!only_positionals and std.mem.eql(u8, arg, "--")) {
                    only_positionals = true;
                    continue;
                }

                // A lone "-" is a positional, conventionally meaning stdin.
                if (!only_positionals and arg.len > 1 and arg[0] == '-') {
                    if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return Errors.HelpRequested;
                    inline for (flags, 0..) |flag, i| {
                        if (matches(flag, arg)) {
                            if (comptime flag.expectsValue()) {
                                const value = iter.next() orelse return fail(diag, Errors.MissingValue, .{ .argument = arg });
                                @field(result, flag.field_name) = parseValue(flag.type, value) catch |err|
                                    return fail(diag, err, .{ .argument = arg, .input = value });
                            } else {
                                @field(result, flag.field_name) = true;
                            }
                            seen_flags[i] = true;
                            continue :args;
                        }
                    }
                    return fail(diag, Errors.InvalidFlag, .{ .input = arg });
                }

                inline for (positionals, 0..) |positional, i| {
                    if (positional_count == i) {
                        @field(result, positional.field_name) = parseValue(positional.type, arg) catch |err|
                            return fail(diag, err, .{ .argument = help.positionalPlaceholder(positional), .input = arg });
                        positional_count += 1;
                        continue :args;
                    }
                }
                return fail(diag, Errors.TooManyArguments, .{ .input = arg });
            }

            inline for (flags, 0..) |flag, i| {
                if (!seen_flags[i]) {
                    if (comptime flag.defaultValue()) |default| {
                        @field(result, flag.field_name) = default;
                    } else return fail(diag, Errors.MissingFlag, .{ .argument = help.flagNames(flag) });
                }
            }

            inline for (positionals, 0..) |positional, i| {
                if (i >= positional_count) {
                    if (comptime positional.defaultValue()) |default| {
                        @field(result, positional.field_name) = default;
                    } else return fail(diag, Errors.MissingPositional, .{ .argument = help.positionalPlaceholder(positional) });
                }
            }

            return result;
        }

        /// Records what caused `err` and returns `err`.
        fn fail(diag: ?*Diagnostics, err: Errors, cause: Diagnostics.Cause) Errors {
            if (diag) |d| d.cause = cause;
            return err;
        }

        fn specsOfKind(comptime kind: std.meta.Tag(Arg)) [countOfKind(kind)]ArgSpec {
            var specs: [countOfKind(kind)]ArgSpec = undefined;
            var i = 0;
            const type_info = @typeInfo(ExpectedArgs).@"struct";
            for (type_info.field_names, type_info.field_types, type_info.field_attrs) |field_name, field_type, field_attr| {
                const info = @field(args_info, field_name);
                if (info != kind) continue;
                specs[i] = .{
                    .field_name = field_name,
                    .long_name = snakeToKebab(field_name),
                    .type = field_type,
                    .default_value_ptr = field_attr.default_value_ptr,
                    .info = info,
                };
                i += 1;
            }
            return specs;
        }

        fn countOfKind(comptime kind: std.meta.Tag(Arg)) usize {
            var count = 0;
            for (@typeInfo(ExpectedArgs).@"struct".field_names) |field_name| {
                if (@field(args_info, field_name) == kind) count += 1;
            }
            return count;
        }

        /// Writes the help text.
        pub fn printHelp(w: *std.Io.Writer, program_name: []const u8) std.Io.Writer.Error!void {
            try w.print("Usage: {s} {s}", .{ program_name, help_text });
        }

        fn matches(comptime flag: ArgSpec, arg: []const u8) bool {
            if (std.mem.startsWith(u8, arg, "--")) return std.mem.eql(u8, arg[2..], flag.long_name);
            const c = flag.info.flag.short_name orelse return false;
            return arg.len == 2 and arg[0] == '-' and arg[1] == c;
        }

        fn parseValue(comptime T: type, s: []const u8) Errors!T {
            return switch (@typeInfo(T)) {
                .int => std.fmt.parseInt(T, s, 10),
                .float => std.fmt.parseFloat(T, s),
                .optional => |o| try parseValue(o.child, s),
                .bool => unreachable,
                .pointer => if (T == []const u8) s else @compileError("unsupported arg type " ++ @typeName(T)),
                .@"enum" => parseEnum(T, s),
                else => @compileError("unsupported arg type " ++ @typeName(T)),
            };
        }

        /// Matches the kebab-case tag names, like flag names.
        fn parseEnum(comptime T: type, s: []const u8) Errors!T {
            inline for (@typeInfo(T).@"enum".field_names) |field_name| {
                if (std.mem.eql(u8, snakeToKebab(field_name), s)) return @field(T, field_name);
            }
            return Errors.InvalidValue;
        }

        fn validateShortNames(comptime flag_specs: []const ArgSpec) void {
            var seen: [256]?[]const u8 = @splat(null);
            seen['h'] = "help";
            for (flag_specs) |flag| {
                if (std.mem.eql(u8, flag.long_name, "help")) @compileError("`--help` is reserved");
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
                if (positional.type == bool) {
                    @compileError("positional `" ++ positional.field_name ++ "` can't be a bool");
                }
                if (positional.defaultValue() != null) {
                    if (first_optional == null) first_optional = positional.field_name;
                } else if (first_optional) |optional| @compileError(
                    "required positional `" ++ positional.field_name ++
                        "` comes after optional positional `" ++ optional ++ "`",
                );
            }
        }
    };
}

const TestArgs = struct {
    verbose: bool,
    count: u8,
    max_retries: ?u8,
    some_float: ?f32,
    some_enum: ?enum { option_a, option_b },
    optional_with_default: i8 = -3,

    positional_1: u32,
    positional_2: []const u8,
    positional_3: ?f32,

    const all_present: @This() = .{
        .verbose = true,
        .count = 3,
        .max_retries = 5,
        .some_float = 3.3,
        .some_enum = .option_a,
        .optional_with_default = 3,
        .positional_1 = 42,
        .positional_2 = "test string",
        .positional_3 = 5.5,
    };

    const only_required: @This() = .{
        .verbose = false,
        .count = 3,
        .max_retries = null,
        .some_float = null,
        .some_enum = null,
        .optional_with_default = -3,
        .positional_1 = 42,
        .positional_2 = "test string",
        .positional_3 = null,
    };

    pub const args: ArgsInfo(@This()) = .{
        .count = .{ .flag = .{ .short_name = 'c', .help = "Number of whatevers" } },
        .max_retries = .{ .flag = .{ .short_name = 'r' } },
        .some_float = .{ .flag = .{ .short_name = 'f' } },
        .some_enum = .{ .flag = .{ .short_name = 'e' } },
        .optional_with_default = .{ .flag = .{ .short_name = 'd' } },
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

/// Prepends the program name, so tests only list the actual arguments.
fn testParse(comptime args: []const []const u8) !TestArgs {
    var iter: SliceIterator = .{ .args = &([_][]const u8{"prog"} ++ args[0..args.len].*) };
    return TestParser.parse(&iter, null);
}

test "long and short names are equivalent" {
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
        "--some-enum",
        "option-a",
        "--optional-with-default",
        "3",
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
        "-e",
        "option-a",
        "-d",
        "3",
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
        "-e",
        "option-a",
        "-c",
        "3",
        "-d",
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

test "enum flag/argument rejects values not in enum set" {
    try std.testing.expectError(error.InvalidValue, testParse(&.{ "42", "test string", "-c", "3", "-e", "not-an-enum-value" }));
    // Like flag names, values are kebab-case only.
    try std.testing.expectError(error.InvalidValue, testParse(&.{ "42", "test string", "-c", "3", "-e", "option_a" }));
}

test "argument with default value gets that value if not passed explicitely" {
    var args = try testParse(&.{ "42", "-c", "3", "--", "test string", "-5.5" });
    try std.testing.expectEqual(TestArgs.only_required.optional_with_default, args.optional_with_default);
    args = try testParse(&.{ "42", "-c", "3", "--optional-with-default", "3", "--", "test string", "-5.5" });
    try std.testing.expectEqual(3, args.optional_with_default);
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

test "-h and --help return HelpRequested" {
    try std.testing.expectError(error.HelpRequested, testParse(&.{"--help"}));
    try std.testing.expectError(error.HelpRequested, testParse(&.{ "42", "-h" }));
}

test "diagnostics" {
    var diag: Diagnostics = .{};
    var iter: SliceIterator = .{ .args = &.{ "prog", "42", "test string", "-c", "abc" } };
    try std.testing.expectError(error.InvalidCharacter, TestParser.parse(&iter, &diag));
    try std.testing.expectEqualStrings("prog", diag.program_name);
    try expectCause(diag, "-c", "abc");

    iter = .{ .args = &.{ "prog", "42asdf", "test string", "-c", "3" } };
    try std.testing.expectError(error.InvalidCharacter, TestParser.parse(&iter, &diag));
    try expectCause(diag, "<positional-1>", "42asdf");

    iter = .{ .args = &.{ "prog", "42", "test string", "--count" } };
    try std.testing.expectError(error.MissingValue, TestParser.parse(&iter, &diag));
    try expectCause(diag, "--count", null);

    iter = .{ .args = &.{ "prog", "42" } };
    try std.testing.expectError(error.MissingFlag, TestParser.parse(&iter, &diag));
    try expectCause(diag, "-c, --count", null);

    iter = .{ .args = &.{ "prog", "42", "-c", "3" } };
    try std.testing.expectError(error.MissingPositional, TestParser.parse(&iter, &diag));
    try expectCause(diag, "<positional-2>", null);

    iter = .{ .args = &.{ "prog", "42", "test string", "-c", "3", "--unknown" } };
    try std.testing.expectError(error.InvalidFlag, TestParser.parse(&iter, &diag));
    try expectCause(diag, null, "--unknown");

    iter = .{ .args = &.{ "prog", "42", "test string", "1.5", "extra" } };
    try std.testing.expectError(error.TooManyArguments, TestParser.parse(&iter, &diag));
    try expectCause(diag, null, "extra");
}

fn expectCause(diag: Diagnostics, argument: ?[]const u8, input: ?[]const u8) !void {
    try expectOptionalString(argument, diag.cause.argument);
    try expectOptionalString(input, diag.cause.input);
}

fn expectOptionalString(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected) |e| {
        try std.testing.expect(actual != null);
        try std.testing.expectEqualStrings(e, actual.?);
    } else try std.testing.expectEqual(null, actual);
}
