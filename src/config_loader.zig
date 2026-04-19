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

pub const default_config_name = "guardian.config.json";

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

    const path = config_path orelse return error.FileNotFound;
    const bytes = try readFileAllocAbsolute(arena_allocator, path, max_config_bytes);
    var value = try std.json.parseFromSliceLeaky(config_schema.Config, arena_allocator, bytes, .{});
    value.root_path = std.fs.path.dirname(path) orelse "";

    return .{
        .arena = arena,
        .value = value,
        .source_path = path,
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

    return (try discoverConfigPath(allocator, target_path)) orelse error.FileNotFound;
}

const max_config_bytes = 1024 * 1024;

fn resolveExplicitConfigPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return try std.fs.realpathAlloc(allocator, path);
}

fn discoverConfigPath(allocator: std.mem.Allocator, target_path: ?[]const u8) !?[]const u8 {
    const target_root = try resolveSearchRoot(allocator, resolveStartDir(target_path));
    defer allocator.free(target_root);
    if (try findConfigFromRoot(allocator, target_root)) |config_path| {
        return config_path;
    }

    const cwd_root = try resolveSearchRoot(allocator, ".");
    defer allocator.free(cwd_root);
    if (!std.mem.eql(u8, target_root, cwd_root)) {
        if (try findConfigFromRoot(allocator, cwd_root)) |config_path| {
            return config_path;
        }
    }

    return discoverConfigNearExecutable(allocator, target_root, cwd_root);
}

fn resolveSearchRoot(allocator: std.mem.Allocator, start_dir: []const u8) ![]const u8 {
    return std.fs.realpathAlloc(allocator, start_dir) catch try std.fs.realpathAlloc(allocator, ".");
}

fn discoverConfigNearExecutable(
    allocator: std.mem.Allocator,
    target_root: []const u8,
    cwd_root: []const u8,
) !?[]const u8 {
    const exe_path = std.fs.selfExePathAlloc(allocator) catch return null;
    defer allocator.free(exe_path);

    const exe_dir = std.fs.path.dirname(exe_path) orelse return null;
    const exe_root = try resolveSearchRoot(allocator, exe_dir);
    defer allocator.free(exe_root);

    if (std.mem.eql(u8, exe_root, target_root) or std.mem.eql(u8, exe_root, cwd_root)) {
        return null;
    }

    return findConfigFromRoot(allocator, exe_root);
}

fn findConfigFromRoot(allocator: std.mem.Allocator, root: []const u8) !?[]const u8 {
    var current: []const u8 = root;
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
    const candidate = try std.fs.path.join(allocator, &.{ dir_path, default_config_name });
    if (std.fs.accessAbsolute(candidate, .{})) |_| {
        return candidate;
    } else |err| switch (err) {
        error.FileNotFound => allocator.free(candidate),
        else => {
            allocator.free(candidate);
            return err;
        },
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
const test_config = @import("test_config.zig");

test "config loader: loads repository guardian.config.json by default" {
    var loaded = try loadForTarget(testing.allocator, null, null);
    defer loaded.deinit();

    try testing.expectEqual(@as(u32, 3), loaded.value.limits.max_nesting);
    try testing.expect(loaded.value.go.ban_generics);
    try testing.expectEqual(@as(usize, 5), loaded.value.scan.extensions.len);
    try testing.expectEqual(config_schema.SurfaceScope.public_only, loaded.value.go.surface_scope);
    try testing.expectEqual(config_schema.SurfaceScope.public_only, loaded.value.zig.cast_scope);
    try testing.expect(loaded.source_path != null);
    try testing.expect(std.mem.endsWith(u8, loaded.source_path.?, default_config_name));
}

test "config loader: loads overrides from discovered file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("pkg");
    var loaded_default = try test_config.loadDefault(testing.allocator);
    defer loaded_default.deinit();

    var cfg = loaded_default.value;
    cfg.scan.extensions = &[_][]const u8{ ".go", ".zig" };
    cfg.scan.ignored_dirs = &[_][]const u8{".git"};
    cfg.limits.max_nesting = 2;
    cfg.limits.max_function_lines = 30;
    cfg.go.ban_generics = false;
    const config_json = try test_config.stringify(testing.allocator, cfg);
    defer testing.allocator.free(config_json);

    try tmp.dir.writeFile(.{
        .sub_path = "guardian.config.json",
        .data = config_json,
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
    try testing.expect(std.mem.endsWith(u8, loaded.source_path.?, default_config_name));
    try testing.expect(loaded.value.root_path.len > 0);
}

test "config loader: resolve cache key uses discovered guardian.config.json" {
    const key = try resolveCacheKey(testing.allocator, null, null);
    defer testing.allocator.free(key);

    try testing.expect(std.mem.endsWith(u8, key, default_config_name));
}

test "config loader: resolve cache key duplicates explicit absolute config path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var loaded_default = try test_config.loadDefault(testing.allocator);
    defer loaded_default.deinit();

    const config_json = try test_config.stringify(testing.allocator, loaded_default.value);
    defer testing.allocator.free(config_json);

    try tmp.dir.writeFile(.{
        .sub_path = "guardian.config.json",
        .data = config_json,
    });

    const absolute_config = try tmp.dir.realpathAlloc(testing.allocator, "guardian.config.json");
    defer testing.allocator.free(absolute_config);

    const key = try resolveCacheKey(testing.allocator, null, absolute_config);
    defer testing.allocator.free(key);

    try testing.expectEqualStrings(absolute_config, key);
    try testing.expect(key.ptr != absolute_config.ptr);
}

test "config loader: rejects unknown fields" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "guardian.config.json",
        .data =
        \\{
        \\  "limits": {
        \\    "max_nesting": 3,
        \\    "cyclomatic_complexity_warn": 6,
        \\    "cyclomatic_complexity_error": 8,
        \\    "max_imports": 15,
        \\    "max_functions_per_file": 15,
        \\    "max_function_lines": 50,
        \\    "max_function_arguments": 3,
        \\    "max_type_fields": 10,
        \\    "max_hidden_touch_excess": 0,
        \\    "max_lifecycle_flags": 2,
        \\    "max_line_length": 120,
        \\    "max_excerpt_lines": 12,
        \\    "max_excerpt_chars": 1600,
        \\    "max_nestign": 4
        \\  },
        \\  "scan": {
        \\    "extensions": [".go"],
        \\    "ignored_dirs": [".git"]
        \\  },
        \\  "go": {
        \\    "ban_interface_empty": true,
        \\    "ban_map_string_interface_empty": true,
        \\    "warn_type_switch": true,
        \\    "ban_unchecked_type_assertions": true,
        \\    "ban_generics": true,
        \\    "surface_scope": "public_only",
        \\    "generic_scope": "public_only",
        \\    "extra_banned_patterns": []
        \\  },
        \\  "typescript": {
        \\    "ban_any": true,
        \\    "ban_as_any": true,
        \\    "ban_ts_ignore": true,
        \\    "warn_ts_expect_error": true,
        \\    "extra_banned_patterns": []
        \\  },
        \\  "python": {
        \\    "ban_type_ignore": true,
        \\    "warn_import_any": true,
        \\    "ban_any_annotation": true,
        \\    "warn_bare_dict": true,
        \\    "warn_bare_list": true,
        \\    "warn_missing_return_annotation": true,
        \\    "extra_banned_patterns": []
        \\  },
        \\  "zig": {
        \\    "warn_ptr_cast": true,
        \\    "warn_int_cast": true,
        \\    "warn_anytype": true,
        \\    "cast_scope": "public_only",
        \\    "anytype_scope": "public_only",
        \\    "extra_banned_patterns": []
        \\  }
        \\}
        ,
    });

    const absolute_config = try tmp.dir.realpathAlloc(testing.allocator, "guardian.config.json");
    defer testing.allocator.free(absolute_config);

    try testing.expectError(error.UnknownField, loadForTarget(testing.allocator, null, absolute_config));
}
