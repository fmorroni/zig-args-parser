const std = @import("std");

const arg_parser = @import("arg_parser.zig");
pub const ArgsParser = arg_parser.ArgsParser;
pub const ArgsInfo = arg_parser.ArgsInfo;
pub const Arg = arg_parser.Arg;
pub const Diagnostics = arg_parser.Diagnostics;

test {
    std.testing.refAllDecls(arg_parser);
}
