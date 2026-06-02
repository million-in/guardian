const std = @import("std");
const guardian = @import("root.zig");

pub export fn guardian_analyze_source_json(
    file_path: [*:0]const u8,
    source: [*:0]const u8,
    config_path: ?[*:0]const u8,
    severity_filter: c_int,
) ?[*:0]u8 {
    const options = jsonOptionsFromC(severity_filter);
    const json = guardian.analyzeSourceJson(
        std.heap.c_allocator,
        std.mem.span(file_path),
        std.mem.span(source),
        optionalSpan(config_path),
        options,
    ) catch |err| return errorCString(err);
    defer std.heap.c_allocator.free(json);

    return ownedCString(json);
}

pub export fn guardian_analyze_file_json(
    file_path: [*:0]const u8,
    config_path: ?[*:0]const u8,
    severity_filter: c_int,
) ?[*:0]u8 {
    const json = guardian.analyzeFileJson(
        std.heap.c_allocator,
        std.mem.span(file_path),
        optionalSpan(config_path),
        jsonOptionsFromC(severity_filter),
    ) catch |err| return errorCString(err);
    defer std.heap.c_allocator.free(json);

    return ownedCString(json);
}

pub export fn guardian_analyze_folder_json(
    folder_path: [*:0]const u8,
    config_path: ?[*:0]const u8,
    severity_filter: c_int,
) ?[*:0]u8 {
    const json = guardian.analyzeFolderJson(
        std.heap.c_allocator,
        std.mem.span(folder_path),
        optionalSpan(config_path),
        jsonOptionsFromC(severity_filter),
    ) catch |err| return errorCString(err);
    defer std.heap.c_allocator.free(json);

    return ownedCString(json);
}

pub export fn guardian_free_string(value: ?[*:0]u8) void {
    const ptr = value orelse return;
    std.heap.c_allocator.free(std.mem.span(ptr));
}

fn jsonOptionsFromC(severity_filter: c_int) guardian.JsonOptions {
    return .{ .severity_filter = switch (severity_filter) {
        1 => .errors_only,
        2 => .warnings_only,
        3 => .clear_errors,
        else => .all,
    } };
}

fn optionalSpan(value: ?[*:0]const u8) ?[]const u8 {
    const ptr = value orelse return null;
    return std.mem.span(ptr);
}

fn ownedCString(json: []const u8) ?[*:0]u8 {
    const copied = std.heap.c_allocator.dupeZ(u8, json) catch return null;
    return copied.ptr;
}

fn errorCString(err: anyerror) ?[*:0]u8 {
    const json = std.fmt.allocPrint(
        std.heap.c_allocator,
        "{{\"ok\":false,\"error\":\"{s}\"}}",
        .{@errorName(err)},
    ) catch return null;
    defer std.heap.c_allocator.free(json);

    return ownedCString(json);
}
