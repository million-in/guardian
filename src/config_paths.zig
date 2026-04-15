const std = @import("std");

pub fn matchesAnyPrefix(path: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.startsWith(u8, path, candidate)) {
            return true;
        }
    }
    return false;
}

pub fn matchesAnySuffix(path: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.endsWith(u8, path, candidate)) {
            return true;
        }
    }
    return false;
}

pub fn matchesAnyContains(path: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.indexOf(u8, path, candidate) != null) {
            return true;
        }
    }
    return false;
}

pub fn matchesAnyExtension(path: []const u8, candidates: []const []const u8) bool {
    const ext = std.fs.path.extension(path);
    for (candidates) |candidate| {
        if (std.mem.eql(u8, ext, candidate)) {
            return true;
        }
    }
    return false;
}

pub fn matchesAnyRole(path: []const u8, roles: []const []const u8) bool {
    for (roles) |role| {
        if (hasRole(path, role)) {
            return true;
        }
    }
    return false;
}

fn hasRole(path: []const u8, role: []const u8) bool {
    if (std.mem.eql(u8, role, "test")) {
        return isTestPath(path);
    }
    if (std.mem.eql(u8, role, "generated")) {
        return isGeneratedPath(path);
    }
    if (std.mem.eql(u8, role, "fixture")) {
        return isFixturePath(path);
    }
    if (std.mem.eql(u8, role, "sample")) {
        return isSamplePath(path);
    }
    return false;
}

fn isTestPath(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    return std.mem.indexOf(u8, path, "/test/") != null or
        std.mem.indexOf(u8, path, "/tests/") != null or
        std.mem.indexOf(u8, path, "/__tests__/") != null or
        std.mem.endsWith(u8, base, "_test.go") or
        std.mem.indexOf(u8, base, ".test.") != null or
        std.mem.indexOf(u8, base, "_spec.") != null or
        std.mem.indexOf(u8, base, ".spec.") != null;
}

fn isGeneratedPath(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    return std.mem.indexOf(u8, path, "/generated/") != null or
        std.mem.indexOf(u8, path, "/gen/") != null or
        std.mem.endsWith(u8, base, ".pb.go") or
        std.mem.indexOf(u8, base, ".generated.") != null or
        std.mem.indexOf(u8, base, ".gen.") != null or
        std.mem.indexOf(u8, base, "_generated.") != null;
}

fn isFixturePath(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "/fixture/") != null or
        std.mem.indexOf(u8, path, "/fixtures/") != null;
}

fn isSamplePath(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "/sample/") != null or
        std.mem.indexOf(u8, path, "/samples/") != null;
}
