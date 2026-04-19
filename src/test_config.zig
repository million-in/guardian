const std = @import("std");
const guardian_config = @import("config.zig");

pub fn loadDefault(allocator: std.mem.Allocator) !guardian_config.LoadedConfig {
    return guardian_config.loadForTarget(allocator, null, null);
}

pub fn stringify(allocator: std.mem.Allocator, cfg: guardian_config.Config) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(cfg, .{})});
}
