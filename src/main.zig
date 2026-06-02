const std = @import("std");
const cli = @import("cli.zig");
const server = @import("server.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();

    var args = std.array_list.Managed([:0]u8).init(allocator);
    defer {
        for (args.items) |arg| {
            allocator.free(arg[0 .. arg.len + 1]);
        }
        args.deinit();
    }

    while (args_iter.next()) |arg| {
        try args.append(try allocator.dupeZ(u8, arg));
    }

    if (args.items.len <= 1) {
        try server.run(allocator);
        return;
    }

    cli.run(allocator, args.items[1..]) catch |err| {
        try cli.writeCliError(err);
        std.process.exit(1);
    };
}

test {
    _ = @import("app.zig");
    _ = @import("cli.zig");
    _ = @import("config.zig");
    _ = @import("root.zig");
    _ = @import("server.zig");
}
