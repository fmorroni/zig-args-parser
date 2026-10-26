# zig-args-parser

A command line argument parser for Zig, driven by a plain struct.

You describe your arguments as a struct, and `parse` returns that struct filled in. Field names become
flag names, field types decide how values are parsed, and everything about the parser (flag
lookup, validation, help text) is generated at compile time.

```zig
const Args = struct {
    verbose: bool,
    jobs: ?u32,
    output: []const u8,
    input: []const u8,

    pub const args: argp.ArgsInfo(@This()) = .{
        .verbose = .{ .flag = .{ .short_name = 'v', .help = "Print more details" } },
        .output = .{ .flag = .{ .short_name = 'o', .help = "Where to write the result" } },
        .input = .{ .positional = .{ .help = "File to read" } },
    };
};
```

## Installation

Requires Zig 0.16.0 or later.

```sh
zig fetch --save git+https://github.com/fmorroni/zig-args-parser
```

Then in your `build.zig`:

```zig
const args_parser = b.dependency("zig_args_parser", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zig_args_parser", args_parser.module("zig_args_parser"));
```

## Usage

```zig
const std = @import("std");
const argp = @import("zig_args_parser");

const Args = struct {
    verbose: bool,
    jobs: ?u32,
    output: []const u8,

    input: []const u8,
    limit: ?u64,

    pub const args: argp.ArgsInfo(@This()) = .{
        .verbose = .{ .flag = .{ .short_name = 'v', .help = "Print more details" } },
        .jobs = .{ .flag = .{ .short_name = 'j', .help = "Number of worker threads" } },
        .output = .{ .flag = .{ .short_name = 'o', .help = "Where to write the result" } },
        .input = .{ .positional = .{ .help = "File to read" } },
        .limit = .{ .positional = .{ .help = "Stop after this many lines" } },
    };
};

pub fn main(init: std.process.Init) !void {
    const Parser = argp.ArgsParser(Args);

    var it = init.minimal.args.iterate();
    defer it.deinit();

    var diag: argp.Diagnostics = .{};
    const args = Parser.parse(&it, &diag) catch |err| switch (err) {
        error.HelpRequested => {
            var buf: [4096]u8 = undefined;
            var stdout = std.Io.File.stdout().writer(init.io, &buf);
            try Parser.printHelp(&stdout.interface, diag.program_name);
            return stdout.interface.flush();
        },
        else => {
            std.debug.print("{s}: {t}: '{s}'\n", .{ diag.program_name, err, diag.arg orelse "" });
            std.process.exit(1);
        },
    };

    std.debug.print("input={s} output={s} jobs={?} limit={?} verbose={}\n", .{
        args.input, args.output, args.jobs, args.limit, args.verbose,
    });
}
```

```
$ example -o out.txt in.txt 10 -v
input=in.txt output=out.txt jobs=null limit=10 verbose=true

$ example in.txt
example: MissingFlag: '--output'

$ example -o out.txt in.txt --jobz 3
example: InvalidFlag: '--jobz'

$ example --help
Usage: example [options] <input> [limit]

Arguments:
  <input>  File to read
  [limit]  Stop after this many lines

Options:
  -v, --verbose          Print more details
  -j, --jobs <u32>       Number of worker threads
  -o, --output <string>  Where to write the result (required)
  -h, --help             Print this help and exit
```

## Defining arguments

Every field of your struct is one argument. By default it's a flag whose long name is the field name
in kebab-case: `max_retries` becomes `--max-retries`.

The optional `args` declaration adds details. Its type, `ArgsInfo(@This())`, has one field per field
of your struct, so a misspelled name is a compile error. Fields you leave out stay plain flags.

```zig
pub const args: argp.ArgsInfo(@This()) = .{
    .count = .{ .flag = .{ .short_name = 'c', .help = "How many" } },
    .input = .{ .positional = .{ .help = "File to read" } },
};
```

| Option | Applies to | Meaning |
|---|---|---|
| `short_name` | flags | Single-character alias, e.g. `'c'` for `-c` |
| `help` | flags, positionals | Description shown by `--help` |

### Flags

| Field type | Behavior |
|---|---|
| `bool` | Takes no value. `true` when given, `false` otherwise |
| `?T` | Optional. `null` when not given |
| `T` | Required. Missing it is `error.MissingFlag` |

Flags can appear anywhere on the command line, in any order. A flag's value is always the next
argument, even if it starts with `-`, so `--offset -5` works.

### Positionals

Positionals are filled in the order their fields are declared. `?T` positionals are optional and must
come after all required ones; this is checked at compile time. `bool` positionals aren't allowed.

Everything after `--` is treated as a positional, which lets you pass values that start with `-`:

```
$ example -o out.txt -- -weird-name.txt
```

A lone `-` is also a positional, since it conventionally means stdin.

### Supported value types

- `bool` (only for flags)
- Integers (`u8`, `i64`, ...), parsed in base 10
- Floats (`f32`, `f64`, ...)
- `[]const u8`, which points into the argument strings without copying them
- Optionals of the above

### Compile-time checks

- No two flags share a short name
- Short names are alphanumeric
- `-h` and `--help` are reserved
- Required positionals don't come after optional ones

## Help

`-h` and `--help` are built in. When either is given, `parse` returns `error.HelpRequested` right away,
even if required arguments are missing. Call `printHelp` to print the help. It takes the program
name, which `parse` stores in `Diagnostics`:

```zig
try Parser.printHelp(writer, diag.program_name);
```

The help text is generated at compile time. Only the program name is added at runtime.

## Errors

`parse` expects the full argument list, with the program name first, as returned by
`std.process.Args.iterate()`. It accepts any iterator with a `next()` method that returns
`?[]const u8` or `?[:0]const u8`:

```zig
var it = std.mem.tokenizeScalar(u8, "prog -o out.txt in.txt", ' ');
const args = try Parser.parse(&it, null);
```

Pass a `*Diagnostics` to learn what went wrong, or `null` if you don't need it. After a call,
`diag.program_name` holds the program name. On error, `diag.arg` holds the cause:

| Error | `diag.arg` |
|---|---|
| `HelpRequested` | unchanged |
| `InvalidFlag` | The unknown flag, e.g. `--jobz` |
| `MissingValue` | The flag that's missing its value |
| `TooManyArguments` | The first extra positional |
| `MissingFlag` | The missing flag's long name, e.g. `--output` |
| `MissingPositional` | The missing positional as shown in the help, e.g. `<input>` |
| `InvalidCharacter`, `Overflow`, ... | The value that failed to parse |
