const std = @import("std");
const cli = @import("cli.zig");
const server = @import("server.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len <= 1) {
        try server.run(allocator);
        return;
    }

    cli.run(allocator, args[1..]) catch |err| {
        try cli.writeCliError(err);
        std.process.exit(1);
    };
}

test {
    _ = @import("app.zig");
    _ = @import("cli.zig");
    _ = @import("config.zig");
    _ = @import("server.zig");
}
