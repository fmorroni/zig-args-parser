const std = @import("std");

pub const ArgsParser = @import("arg_parser.zig");

test {
    std.testing.refAllDecls(@This());
}
