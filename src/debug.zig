const std = @import("std");

/// Prints a comptime-only value (e.g. `@typeInfo(T)`) at runtime. Unlike `{any}`, strings are
/// printed as strings. The output is valid Zig, formatted with `zig fmt` rules.
pub fn dumpComptime(comptime value: anytype) void {
    const s = comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var buf: [16 * 1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        dumpValue(&w, value) catch unreachable;
        buf[w.end] = 0;
        break :blk buf[0 .. w.end + 1].*;
    };
    const source = s[0 .. s.len - 1 :0];

    // Formatting isn't possible at comptime, so let `zig fmt`'s renderer do it now. Fall back to
    // the raw single line if anything goes wrong.
    const gpa = std.heap.page_allocator;
    var tree = std.zig.Ast.parse(gpa, source, .zon) catch return std.debug.print("{s}\n", .{source});
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return std.debug.print("{s}\n", .{source});
    const formatted = tree.renderAlloc(gpa) catch return std.debug.print("{s}\n", .{source});
    defer gpa.free(formatted);
    std.debug.print("{s}", .{formatted});
}

/// Writes `value` as a Zig expression. Structs always get a trailing comma so `zig fmt` puts each
/// field on its own line; slices only when they have more than one element.
fn dumpValue(w: *std.Io.Writer, comptime value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (info.fields.len == 0) return w.writeAll(".{}");
            try w.writeAll(".{ ");
            inline for (info.fields) |f| {
                try w.print(".{f} = ", .{std.zig.fmtIdP(f.name)});
                try dumpValue(w, @field(value, f.name));
                try w.writeAll(", ");
            }
            try w.writeAll("}");
        },
        .@"union" => |info| {
            if (info.tag_type == null) return w.writeAll("undefined");
            try w.print(".{{ .{f} = ", .{std.zig.fmtIdP(@tagName(value))});
            switch (value) {
                inline else => |payload| try dumpValue(w, payload),
            }
            try w.writeAll(", }");
        },
        .pointer => |info| if (info.size == .slice and info.child == u8) {
            try w.print("\"{f}\"", .{std.zig.fmtString(value)});
        } else if (info.size == .slice) {
            try dumpElems(w, value);
        } else {
            // Addresses don't exist at comptime, so only the pointer
            try w.writeAll(@typeName(T));
        },
        .array => try dumpElems(w, value),
        .optional => if (value) |payload| try dumpValue(w, payload) else try w.writeAll("null"),
        .type => try w.writeAll(@typeName(value)),
        else => try w.printValue("any", .{}, value, 1),
    }
}

fn dumpElems(w: *std.Io.Writer, comptime value: anytype) !void {
    if (value.len == 0) return w.writeAll(".{}");
    try w.writeAll(".{ ");
    inline for (value, 0..) |elem, i| {
        if (i != 0) try w.writeAll(", ");
        try dumpValue(w, elem);
    }
    try w.writeAll(if (value.len > 1) ", }" else " }");
}
