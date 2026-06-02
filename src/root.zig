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
