const std = @import("std");

const args_parser = @import("args_parser.zig");
pub const ArgsParser = args_parser.ArgsParser;
pub const ArgsInfo = args_parser.ArgsInfo;
pub const Arg = args_parser.Arg;
pub const Diagnostics = args_parser.Diagnostics;

test {
    std.testing.refAllDecls(args_parser);
}
