//! Generates the `--help` text from the parser's argument specs.

const std = @import("std");

const args_parser = @import("args_parser.zig");
const ArgSpec = args_parser.ArgSpec;
const snakeToKebab = args_parser.snakeToKebab;

/// Everything after "Usage: <program name>".
pub fn generate(comptime flags: []const ArgSpec, comptime positionals: []const ArgSpec) []const u8 {
    var text: []const u8 = "[options]";
    for (positionals) |positional| text = text ++ " " ++ positionalPlaceholder(positional);
    text = text ++ "\n";

    if (positionals.len > 0) {
        var rows: [positionals.len]Row = undefined;
        for (positionals, &rows) |positional, *row| row.* = .{
            .left = positionalPlaceholder(positional),
            .right = annotate(positional.info.positional.help orelse "", &.{
                valueTypeName(positional.type),
                defaultValueNote(positional),
            }),
        };
        text = text ++ "\nArguments:\n" ++ table(&rows);
    }

    var rows: [flags.len + 1]Row = undefined;
    for (flags, rows[0..flags.len]) |flag, *row| {
        var left: []const u8 = if (flag.info.flag.short_name) |c| "-" ++ .{c} ++ ", " else "    ";
        left = left ++ "--" ++ flag.long_name;
        if (flag.expectsValue()) left = left ++ " <" ++ valueTypeName(flag.type) ++ ">";
        const right = annotate(flag.info.flag.help orelse "", &.{
            defaultValueNote(flag),
            if (flag.defaultValue() == null) "required" else null,
        });
        row.* = .{ .left = left, .right = right };
    }
    rows[flags.len] = .{ .left = "-h, --help", .right = "Print this help and exit" };
    text = text ++ "\nOptions:\n" ++ table(&rows);

    return text;
}

/// How a positional is shown in the help: `<name>` if it's required, `[name]` if it isn't.
pub fn positionalPlaceholder(comptime positional: ArgSpec) []const u8 {
    return if (positional.defaultValue() != null)
        "[" ++ positional.long_name ++ "]"
    else
        "<" ++ positional.long_name ++ ">";
}

const Row = struct { left: []const u8, right: []const u8 };

/// Two columns, with the descriptions aligned.
fn table(comptime rows: []const Row) []const u8 {
    var width = 0;
    for (rows) |row| width = @max(width, row.left.len);

    var text: []const u8 = "";
    for (rows) |row| {
        text = text ++ "  " ++ row.left;
        if (row.right.len > 0) text = text ++ @as([width - row.left.len + 2]u8, @splat(' ')) ++ row.right;
        text = text ++ "\n";
    }
    return text;
}

/// Appends the non-null notes to a description as "(a, b, ...)".
fn annotate(comptime description: []const u8, comptime notes: []const ?[]const u8) []const u8 {
    var joined: []const u8 = "";
    for (notes) |maybe_note| {
        const note = maybe_note orelse continue;
        joined = joined ++ (if (joined.len == 0) "" else ", ") ++ note;
    }
    if (joined.len == 0) return description;
    const parenthesized = "(" ++ joined ++ ")";
    return if (description.len == 0) parenthesized else description ++ " " ++ parenthesized;
}

/// "default: ..." for explicit defaults only, or `null` if there's nothing worth showing.
fn defaultValueNote(comptime spec: ArgSpec) ?[]const u8 {
    if (spec.default_value_ptr == null) return null;
    const text = defaultValueText(spec.type, spec.defaultValue().?) orelse return null;
    return "default: " ++ text;
}

/// How a default value is written in the help, or `null` if it isn't worth showing.
fn defaultValueText(comptime T: type, comptime value: T) ?[]const u8 {
    return switch (@typeInfo(T)) {
        .int, .float => std.fmt.comptimePrint("{d}", .{value}),
        .@"enum" => snakeToKebab(@tagName(value)),
        .pointer => "\"" ++ value ++ "\"",
        .optional => |o| if (value) |v| defaultValueText(o.child, v) else null,
        else => null,
    };
}

fn valueTypeName(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .optional => |o| valueTypeName(o.child),
        .pointer => "string",
        .@"enum" => |e| blk: {
            var text: []const u8 = "";
            for (e.fields, 0..) |field, i| {
                text = text ++ (if (i == 0) "" else "|") ++ snakeToKebab(field.name);
            }
            break :blk text;
        },
        else => @typeName(T),
    };
}

fn expectHelp(comptime Args: type, expected: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try args_parser.ArgsParser(Args).printHelp(&w, "prog");
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "flags and positionals" {
    try expectHelp(struct {
        verbose: bool,
        count: u8,
        max_retries: ?u8,
        some_float: ?f32,
        some_enum: ?enum { option_a, option_b },
        optional_with_default: i8 = -3,

        positional_1: u32,
        positional_2: []const u8,
        positional_3: ?f32,

        pub const args: args_parser.ArgsInfo(@This()) = .{
            .count = .{ .flag = .{ .short_name = 'c', .help = "Number of whatevers" } },
            .max_retries = .{ .flag = .{ .short_name = 'r' } },
            .some_float = .{ .flag = .{ .short_name = 'f' } },
            .some_enum = .{ .flag = .{ .short_name = 'e' } },
            .optional_with_default = .{ .flag = .{ .short_name = 'd' } },
            .positional_1 = .{ .positional = .{ .help = "This does something" } },
            .positional_2 = .{ .positional = .{ .help = "This does other thing" } },
            .positional_3 = .{ .positional = .{ .help = "This does other other thing" } },
        };
    },
        \\Usage: prog [options] <positional-1> <positional-2> [positional-3]
        \\
        \\Arguments:
        \\  <positional-1>  This does something (u32)
        \\  <positional-2>  This does other thing (string)
        \\  [positional-3]  This does other other thing (f32)
        \\
        \\Options:
        \\      --verbose
        \\  -c, --count <u8>                     Number of whatevers (required)
        \\  -r, --max-retries <u8>
        \\  -f, --some-float <f32>
        \\  -e, --some-enum <option-a|option-b>
        \\  -d, --optional-with-default <i8>     (default: -3)
        \\  -h, --help                           Print this help and exit
        \\
    );
}

test "positionals show their type and default" {
    try expectHelp(struct {
        input: []const u8,
        limit: u32 = 123,
        mode: enum { fast, slow } = .fast,

        pub const args: args_parser.ArgsInfo(@This()) = .{
            .input = .{ .positional = .{ .help = "File to read" } },
            .limit = .{ .positional = .{ .help = "Stop after this many lines" } },
            .mode = .{ .positional = .{} },
        };
    },
        \\Usage: prog [options] <input> [limit] [mode]
        \\
        \\Arguments:
        \\  <input>  File to read (string)
        \\  [limit]  Stop after this many lines (u32, default: 123)
        \\  [mode]   (fast|slow, default: fast)
        \\
        \\Options:
        \\  -h, --help  Print this help and exit
        \\
    );
}
