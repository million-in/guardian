const std = @import("std");
const guardian_config = @import("config.zig");

const ConfigCacheEntry = struct {
    key: []const u8,
    loaded: guardian_config.LoadedConfig,
};

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    explicit_config_path: ?[]const u8,
    entries: std.array_list.Managed(ConfigCacheEntry),
    index: std.StringHashMapUnmanaged(usize) = .{},

    pub fn init(allocator: std.mem.Allocator, explicit_config_path: ?[]const u8) Resolver {
        return .{
            .allocator = allocator,
            .explicit_config_path = explicit_config_path,
            .entries = std.array_list.Managed(ConfigCacheEntry).init(allocator),
        };
    }

    pub fn deinit(self: *Resolver) void {
        for (self.entries.items) |*entry| {
            entry.loaded.deinit();
            self.allocator.free(entry.key);
        }
        self.entries.deinit();
        self.index.deinit(self.allocator);
    }

    pub fn resolve(self: *Resolver, target_path: []const u8) !guardian_config.Config {
        const key = try guardian_config.resolveCacheKey(self.allocator, target_path, self.explicit_config_path);
        errdefer self.allocator.free(key);

        if (self.index.get(key)) |idx| {
            self.allocator.free(key);
            return self.entries.items[idx].loaded.value;
        }

        var loaded = try guardian_config.loadForTarget(self.allocator, target_path, self.explicit_config_path);
        errdefer loaded.deinit();

        const idx = self.entries.items.len;
        try self.entries.append(.{
            .key = key,
            .loaded = loaded,
        });
        try self.index.put(self.allocator, key, idx);

        return self.entries.items[idx].loaded.value;
    }
};

const testing = std.testing;

test "config resolver: explicit absolute config path can be reused across files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "guardian.json",
        .data =
        \\{
        \\  "go": {
        \\    "ban_generics": false
        \\  }
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "a.go",
        .data =
        \\func Map[T any](items []T) []T {
        \\    return items
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "b.go",
        .data =
        \\func Reduce[T any](items []T) []T {
        \\    return items
        \\}
        ,
    });

    const absolute_config = try tmp.dir.realpathAlloc(testing.allocator, "guardian.json");
    defer testing.allocator.free(absolute_config);
    const file_a = try tmp.dir.realpathAlloc(testing.allocator, "a.go");
    defer testing.allocator.free(file_a);
    const file_b = try tmp.dir.realpathAlloc(testing.allocator, "b.go");
    defer testing.allocator.free(file_b);

    var resolver = Resolver.init(testing.allocator, absolute_config);
    defer resolver.deinit();

    const cfg_a = try resolver.resolve(file_a);
    const cfg_b = try resolver.resolve(file_b);

    try testing.expectEqual(@as(usize, 1), resolver.entries.items.len);
    try testing.expect(!cfg_a.go.ban_generics);
    try testing.expect(!cfg_b.go.ban_generics);
}
