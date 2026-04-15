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
