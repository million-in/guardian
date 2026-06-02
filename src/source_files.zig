const std = @import("std");
const compat = @import("compat.zig");
const guardian_config = @import("config.zig");

pub const FolderError = error{
    NotDirectory,
    NoSupportedSourceFiles,
};

pub fn collectSourceFiles(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    cfg: guardian_config.Config,
) ![]const []const u8 {
    try ensureDirectory(root_path);

    var paths = std.array_list.Managed([]const u8).init(allocator);
    errdefer freeOwnedStrings(allocator, paths.items);

    const absolute_root = try resolveRootPath(allocator, root_path);
    defer allocator.free(absolute_root);

    try collectSourceFilesRecursive(allocator, absolute_root, cfg, &paths);
    if (paths.items.len == 0) {
        return FolderError.NoSupportedSourceFiles;
    }
    return paths.toOwnedSlice();
}

pub fn readFileAlloc(allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(file_path)) {
        return compat.readFileAllocAbsolute(allocator, file_path, std.math.maxInt(usize));
    }

    return compat.readFileAlloc(allocator, file_path, std.math.maxInt(usize));
}

pub fn freeOwnedStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| {
        allocator.free(value);
    }
    allocator.free(values);
}

fn ensureDirectory(path: []const u8) !void {
    const stat = statPath(path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return FolderError.NotDirectory,
        else => return err,
    };
    if (stat.kind != .directory) {
        return FolderError.NotDirectory;
    }
}

fn resolveRootPath(allocator: std.mem.Allocator, root_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(root_path)) {
        return allocator.dupe(u8, root_path);
    }
    return compat.realpathAlloc(allocator, root_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return FolderError.NotDirectory,
        else => return err,
    };
}

fn collectSourceFilesRecursive(
    allocator: std.mem.Allocator,
    current_path: []const u8,
    cfg: guardian_config.Config,
    paths: *std.array_list.Managed([]const u8),
) !void {
    var dir = try compat.openDirAbsolute(current_path, .{ .iterate = true });
    defer dir.close(compat.io);

    var iterator = dir.iterate();
    while (try iterator.next(compat.io)) |entry| {
        if (entry.kind == .directory and cfg.isIgnoredDir(entry.name)) {
            continue;
        }

        const child_path = try std.fs.path.join(allocator, &.{ current_path, entry.name });
        errdefer allocator.free(child_path);

        switch (entry.kind) {
            .directory => try collectSourceFilesRecursive(allocator, child_path, cfg, paths),
            .file => {
                if (cfg.isSupportedPath(child_path)) {
                    try paths.append(child_path);
                    continue;
                }
            },
            else => {},
        }

        allocator.free(child_path);
    }
}

fn statPath(path: []const u8) !std.Io.File.Stat {
    if (std.fs.path.isAbsolute(path)) {
        var dir = try compat.openDirAbsolute(path, .{});
        defer dir.close(compat.io);
        return dir.stat(compat.io);
    }

    return std.Io.Dir.cwd().statFile(compat.io, path, .{});
}

const testing = std.testing;
const test_config = @import("test_config.zig");

test "source files: missing folder path is a folder error" {
    var loaded = try test_config.loadDefault(testing.allocator);
    defer loaded.deinit();

    try testing.expectError(
        FolderError.NotDirectory,
        collectSourceFiles(testing.allocator, "clerm_registry", loaded.value),
    );
}

test "source files: relative folder paths resolve before recursion" {
    var loaded = try test_config.loadDefault(testing.allocator);
    defer loaded.deinit();

    const paths = try collectSourceFiles(testing.allocator, "samples", loaded.value);
    defer freeOwnedStrings(testing.allocator, paths);

    try testing.expect(paths.len > 0);
    for (paths) |path| {
        try testing.expect(std.fs.path.isAbsolute(path));
    }
}
