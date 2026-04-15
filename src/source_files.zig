const std = @import("std");
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

    const absolute_root = if (std.fs.path.isAbsolute(root_path))
        try allocator.dupe(u8, root_path)
    else
        try std.fs.realpathAlloc(allocator, root_path);
    defer allocator.free(absolute_root);

    try collectSourceFilesRecursive(allocator, absolute_root, cfg, &paths);
    if (paths.items.len == 0) {
        return FolderError.NoSupportedSourceFiles;
    }
    return paths.toOwnedSlice();
}

pub fn readFileAlloc(allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(file_path)) {
        const file = try std.fs.openFileAbsolute(file_path, .{});
        defer file.close();
        return file.readToEndAlloc(allocator, std.math.maxInt(usize));
    }

    return std.fs.cwd().readFileAlloc(allocator, file_path, std.math.maxInt(usize));
}

pub fn freeOwnedStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| {
        allocator.free(value);
    }
    allocator.free(values);
}

fn ensureDirectory(path: []const u8) !void {
    const stat = try statPath(path);
    if (stat.kind != .directory) {
        return FolderError.NotDirectory;
    }
}

fn collectSourceFilesRecursive(
    allocator: std.mem.Allocator,
    current_path: []const u8,
    cfg: guardian_config.Config,
    paths: *std.array_list.Managed([]const u8),
) !void {
    var dir = try std.fs.openDirAbsolute(current_path, .{ .iterate = true });
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
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

fn statPath(path: []const u8) !std.fs.File.Stat {
    if (std.fs.path.isAbsolute(path)) {
        var dir = try std.fs.openDirAbsolute(path, .{});
        defer dir.close();
        return dir.stat();
    }

    return std.fs.cwd().statFile(path);
}
