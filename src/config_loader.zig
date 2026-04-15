const std = @import("std");
const config_schema = @import("config_schema.zig");

pub const LoadedConfig = struct {
    arena: std.heap.ArenaAllocator,
    value: config_schema.Config,
    source_path: ?[]const u8,

    pub fn deinit(self: *LoadedConfig) void {
        self.arena.deinit();
    }
};

pub const default_cache_key = "<default>";

pub fn loadForTarget(
    allocator: std.mem.Allocator,
    target_path: ?[]const u8,
    explicit_config_path: ?[]const u8,
) !LoadedConfig {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const config_path = if (explicit_config_path) |path|
        try resolveExplicitConfigPath(arena_allocator, path)
    else
        try discoverConfigPath(arena_allocator, target_path);

    if (config_path) |path| {
        const bytes = try readFileAllocAbsolute(arena_allocator, path, max_config_bytes);
        var value = try std.json.parseFromSliceLeaky(config_schema.Config, arena_allocator, bytes, .{
            .ignore_unknown_fields = true,
        });
        value.root_path = std.fs.path.dirname(path) orelse "";
        return .{
            .arena = arena,
            .value = value,
            .source_path = path,
        };
    }

    return .{
        .arena = arena,
        .value = .{},
        .source_path = null,
    };
}

pub fn resolveCacheKey(
    allocator: std.mem.Allocator,
    target_path: ?[]const u8,
    explicit_config_path: ?[]const u8,
) ![]const u8 {
    if (explicit_config_path) |path| {
        return resolveExplicitConfigPath(allocator, path);
    }

    if (try discoverConfigPath(allocator, target_path)) |path| {
        return path;
    }

    return allocator.dupe(u8, default_cache_key);
}

pub fn isDefaultCacheKey(key: []const u8) bool {
    return std.mem.eql(u8, key, default_cache_key);
}

const config_names = [_][]const u8{
    ".guardian.json",
    "guardian.json",
};

const max_config_bytes = 1024 * 1024;

fn resolveExplicitConfigPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return try std.fs.realpathAlloc(allocator, path);
}

fn discoverConfigPath(allocator: std.mem.Allocator, target_path: ?[]const u8) !?[]const u8 {
    const start_dir = resolveStartDir(target_path);

    const absolute_start = std.fs.realpathAlloc(allocator, start_dir) catch try std.fs.realpathAlloc(allocator, ".");
    defer allocator.free(absolute_start);

    var current: []const u8 = absolute_start;
    while (true) {
        if (try findConfigInDir(allocator, current)) |config_path| {
            return config_path;
        }

        if (!moveToParent(&current)) {
            break;
        }
    }

    return null;
}

fn resolveStartDir(target_path: ?[]const u8) []const u8 {
    const start_path = target_path orelse ".";
    if (std.fs.path.extension(start_path).len == 0) {
        return start_path;
    }
    return std.fs.path.dirname(start_path) orelse ".";
}

fn moveToParent(current: *[]const u8) bool {
    const parent = std.fs.path.dirname(current.*) orelse return false;
    if (parent.len == current.*.len) {
        return false;
    }
    current.* = parent;
    return true;
}

fn findConfigInDir(allocator: std.mem.Allocator, dir_path: []const u8) !?[]const u8 {
    for (config_names) |name| {
        const candidate = try std.fs.path.join(allocator, &.{ dir_path, name });
        if (std.fs.accessAbsolute(candidate, .{})) |_| {
            return candidate;
        } else |err| switch (err) {
            error.FileNotFound => allocator.free(candidate),
            else => {
                allocator.free(candidate);
                return err;
            },
        }
    }
    return null;
}

fn readFileAllocAbsolute(
    allocator: std.mem.Allocator,
    absolute_path: []const u8,
    max_bytes: usize,
) ![]u8 {
    const file = try std.fs.openFileAbsolute(absolute_path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

const testing = std.testing;

test "config loader: defaults apply when no file exists" {
    var loaded = try loadForTarget(testing.allocator, null, null);
    defer loaded.deinit();

    try testing.expectEqual(@as(u32, 3), loaded.value.limits.max_nesting);
    try testing.expect(loaded.value.go.ban_generics);
    try testing.expectEqual(@as(usize, 5), loaded.value.scan.extensions.len);
    try testing.expectEqual(config_schema.SurfaceScope.public_only, loaded.value.go.surface_scope);
    try testing.expectEqual(config_schema.SurfaceScope.public_only, loaded.value.zig.cast_scope);
}

test "config loader: loads overrides from discovered file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("pkg");
    try tmp.dir.writeFile(.{
        .sub_path = ".guardian.json",
        .data =
        \\{
        \\  "limits": {
        \\    "max_nesting": 2,
        \\    "max_function_lines": 30
        \\  },
        \\  "go": {
        \\    "ban_generics": false
        \\  },
        \\  "scan": {
        \\    "extensions": [".go", ".zig"]
        \\  }
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "pkg/main.go",
        .data = "package main\n",
    });

    const absolute_file = try tmp.dir.realpathAlloc(testing.allocator, "pkg/main.go");
    defer testing.allocator.free(absolute_file);

    var loaded = try loadForTarget(testing.allocator, absolute_file, null);
    defer loaded.deinit();

    try testing.expectEqual(@as(u32, 2), loaded.value.limits.max_nesting);
    try testing.expectEqual(@as(u32, 30), loaded.value.limits.max_function_lines);
    try testing.expect(!loaded.value.go.ban_generics);
    try testing.expectEqual(@as(usize, 2), loaded.value.scan.extensions.len);
    try testing.expect(loaded.source_path != null);
    try testing.expect(std.mem.endsWith(u8, loaded.source_path.?, ".guardian.json"));
    try testing.expect(loaded.value.root_path.len > 0);
}

test "config loader: resolve cache key falls back to default sentinel" {
    const key = try resolveCacheKey(testing.allocator, null, null);
    defer testing.allocator.free(key);

    try testing.expect(isDefaultCacheKey(key));
}

test "config loader: resolve cache key duplicates explicit absolute config path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "guardian.json",
        .data = "{}\n",
    });

    const absolute_config = try tmp.dir.realpathAlloc(testing.allocator, "guardian.json");
    defer testing.allocator.free(absolute_config);

    const key = try resolveCacheKey(testing.allocator, null, absolute_config);
    defer testing.allocator.free(key);

    try testing.expectEqualStrings(absolute_config, key);
    try testing.expect(key.ptr != absolute_config.ptr);
}
