const std = @import("std");
const analyzer = @import("analyzer.zig");
const app = @import("app.zig");
const guardian_config = @import("config.zig");

pub const AnalysisResult = analyzer.AnalysisResult;
pub const BatchResult = app.BatchResult;
pub const Config = guardian_config.Config;
pub const FileInput = app.FileInput;
pub const JsonOptions = analyzer.JsonOptions;
pub const SeverityFilter = analyzer.SeverityFilter;

pub fn analyzeSourceJson(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    source: []const u8,
    config_path: ?[]const u8,
    options: JsonOptions,
) ![]u8 {
    var loaded_cfg = try guardian_config.loadForTarget(allocator, file_path, config_path);
    defer loaded_cfg.deinit();

    const result = try app.analyzeInput(allocator, file_path, source, loaded_cfg.value);
    defer analyzer.freeResult(allocator, result);

    return analyzer.resultToJsonWithOptions(allocator, result, options);
}

pub fn analyzeFileJson(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    config_path: ?[]const u8,
    options: JsonOptions,
) ![]u8 {
    var loaded_cfg = try guardian_config.loadForTarget(allocator, file_path, config_path);
    defer loaded_cfg.deinit();

    const result = try app.analyzeFilePath(allocator, file_path, loaded_cfg.value);
    defer analyzer.freeResult(allocator, result);

    return analyzer.resultToJsonWithOptions(allocator, result, options);
}

pub fn analyzeBatchJson(
    allocator: std.mem.Allocator,
    inputs: []const FileInput,
    config_path: ?[]const u8,
    options: JsonOptions,
) ![]u8 {
    var batch = try app.analyzeBatchInputsResolved(allocator, inputs, config_path);
    defer batch.deinit(allocator);

    return app.batchToJsonWithOptions(allocator, batch, options);
}

pub fn analyzeFolderJson(
    allocator: std.mem.Allocator,
    folder_path: []const u8,
    config_path: ?[]const u8,
    options: JsonOptions,
) ![]u8 {
    var batch = try app.analyzeFolderResolved(allocator, folder_path, config_path);
    defer batch.deinit(allocator);

    return app.batchToJsonWithOptions(allocator, batch, options);
}

pub export fn guardian_analyze_source_json(
    file_path: [*:0]const u8,
    source: [*:0]const u8,
    config_path: ?[*:0]const u8,
    severity_filter: c_int,
) ?[*:0]u8 {
    const options = jsonOptionsFromC(severity_filter);
    const json = analyzeSourceJson(
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
    const json = analyzeFileJson(
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
    const json = analyzeFolderJson(
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

fn jsonOptionsFromC(severity_filter: c_int) JsonOptions {
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

const testing = std.testing;

test "library: source json can return warnings only" {
    const source = "export const logValue = (): void => { console.log(1); }\n";
    const json = try analyzeSourceJson(testing.allocator, "warn.ts", source, null, .{
        .severity_filter = .warnings_only,
    });
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"error_count\":0") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"severity\":\"warn\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"severity\":\"error\"") == null);
}
