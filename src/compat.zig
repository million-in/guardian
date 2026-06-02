const std = @import("std");

pub const io = std.Options.debug_io;

pub fn realpathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const sentinel_path = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.realPathFileAbsoluteAlloc(io, path, allocator)
    else
        try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
    return unsentinelAlloc(allocator, sentinel_path);
}

pub fn accessAbsolute(path: []const u8, options: std.Io.Dir.AccessOptions) !void {
    return std.Io.Dir.accessAbsolute(io, path, options);
}

pub fn openFileAbsolute(path: []const u8, options: std.Io.Dir.OpenFileOptions) !std.Io.File {
    return std.Io.Dir.openFileAbsolute(io, path, options);
}

pub fn executablePathAlloc(allocator: std.mem.Allocator) ![]u8 {
    const sentinel_path = try std.process.executablePathAlloc(io, allocator);
    return unsentinelAlloc(allocator, sentinel_path);
}

pub fn readFileAllocAbsolute(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
}

pub fn readFileAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
}

pub fn openDirAbsolute(path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    return std.Io.Dir.openDirAbsolute(io, path, options);
}

pub fn makeDirAbsolute(path: []const u8) !void {
    return std.Io.Dir.createDirAbsolute(io, path, .default_dir);
}

pub fn deleteTreeAbsolute(path: []const u8) !void {
    return std.Io.Dir.cwd().deleteTree(io, path);
}

pub fn writeFileAbsolute(path: []const u8, data: []const u8) !void {
    return std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = data,
    });
}

pub fn dirMakePath(dir: std.Io.Dir, sub_path: []const u8) !void {
    return dir.createDirPath(io, sub_path);
}

pub fn dirWriteFile(dir: std.Io.Dir, sub_path: []const u8, data: []const u8) !void {
    return dir.writeFile(io, .{
        .sub_path = sub_path,
        .data = data,
    });
}

pub fn dirRealpathAlloc(
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    sub_path: []const u8,
) ![]u8 {
    const sentinel_path = try dir.realPathFileAlloc(io, sub_path, allocator);
    return unsentinelAlloc(allocator, sentinel_path);
}

fn unsentinelAlloc(allocator: std.mem.Allocator, value: [:0]u8) ![]u8 {
    defer allocator.free(value[0 .. value.len + 1]);
    return allocator.dupe(u8, value);
}
