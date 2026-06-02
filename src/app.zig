const std = @import("std");
const analyzer = @import("analyzer.zig");
const compat = @import("compat.zig");
const guardian_config = @import("config.zig");
const config_resolver = @import("config_resolver.zig");
const reporting = @import("reporting.zig");
const source_files = @import("source_files.zig");
const test_config = @import("test_config.zig");
const types = @import("types.zig");

const Language = types.Language;
const AnalysisResult = analyzer.AnalysisResult;

pub const FileInput = struct {
    file_path: []const u8,
    source: []const u8,
};

pub const BatchResult = struct {
    results: []AnalysisResult,
    file_count: u32,
    error_count: u32,
    warn_count: u32,
    pass: bool,

    pub fn deinit(self: *BatchResult, allocator: std.mem.Allocator) void {
        for (self.results) |result| {
            analyzer.freeResult(allocator, result);
        }
        allocator.free(self.results);
    }
};

pub const AnalyzeFolderError = source_files.FolderError;

pub fn analyzeInput(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    source: []const u8,
    cfg: guardian_config.Config,
) !AnalysisResult {
    const lang = Language.fromExtension(std.fs.path.extension(file_path)) orelse return error.UnsupportedFileExtension;
    return analyzer.analyze(allocator, file_path, source, lang, cfg.resolvedForPath(file_path));
}

pub fn analyzeFilePath(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    cfg: guardian_config.Config,
) !AnalysisResult {
    const source = try source_files.readFileAlloc(allocator, file_path);
    defer allocator.free(source);
    return analyzeInput(allocator, file_path, source, cfg);
}

pub fn analyzeBatchInputs(
    allocator: std.mem.Allocator,
    inputs: []const FileInput,
    cfg: guardian_config.Config,
) !BatchResult {
    var results = std.array_list.Managed(AnalysisResult).init(allocator);
    errdefer {
        for (results.items) |result| {
            analyzer.freeResult(allocator, result);
        }
        results.deinit();
    }

    var total_errors: u32 = 0;
    var total_warns: u32 = 0;

    for (inputs) |input| {
        const result = try analyzeInput(allocator, input.file_path, input.source, cfg);
        total_errors += result.error_count;
        total_warns += result.warn_count;
        try results.append(result);
    }

    return .{
        .results = try results.toOwnedSlice(),
        .file_count = try narrowCount(inputs.len),
        .error_count = total_errors,
        .warn_count = total_warns,
        .pass = total_errors == 0,
    };
}

pub fn analyzeBatchInputsResolved(
    allocator: std.mem.Allocator,
    inputs: []const FileInput,
    explicit_config_path: ?[]const u8,
) !BatchResult {
    var resolver = config_resolver.Resolver.init(allocator, explicit_config_path);
    defer resolver.deinit();

    var results = std.array_list.Managed(AnalysisResult).init(allocator);
    errdefer {
        for (results.items) |result| {
            analyzer.freeResult(allocator, result);
        }
        results.deinit();
    }

    var total_errors: u32 = 0;
    var total_warns: u32 = 0;

    for (inputs) |input| {
        const cfg = try resolver.resolve(input.file_path);
        const result = try analyzeInput(allocator, input.file_path, input.source, cfg);
        total_errors += result.error_count;
        total_warns += result.warn_count;
        try results.append(result);
    }

    return .{
        .results = try results.toOwnedSlice(),
        .file_count = try narrowCount(inputs.len),
        .error_count = total_errors,
        .warn_count = total_warns,
        .pass = total_errors == 0,
    };
}

pub fn analyzeFilePaths(
    allocator: std.mem.Allocator,
    file_paths: []const []const u8,
    cfg: guardian_config.Config,
) !BatchResult {
    var results = std.array_list.Managed(AnalysisResult).init(allocator);
    errdefer {
        for (results.items) |result| {
            analyzer.freeResult(allocator, result);
        }
        results.deinit();
    }

    var total_errors: u32 = 0;
    var total_warns: u32 = 0;

    for (file_paths) |file_path| {
        const result = try analyzeFilePath(allocator, file_path, cfg);
        total_errors += result.error_count;
        total_warns += result.warn_count;
        try results.append(result);
    }

    return .{
        .results = try results.toOwnedSlice(),
        .file_count = try narrowCount(file_paths.len),
        .error_count = total_errors,
        .warn_count = total_warns,
        .pass = total_errors == 0,
    };
}

pub fn analyzeFilePathsResolved(
    allocator: std.mem.Allocator,
    file_paths: []const []const u8,
    explicit_config_path: ?[]const u8,
) !BatchResult {
    var resolver = config_resolver.Resolver.init(allocator, explicit_config_path);
    defer resolver.deinit();

    var results = std.array_list.Managed(AnalysisResult).init(allocator);
    errdefer {
        for (results.items) |result| {
            analyzer.freeResult(allocator, result);
        }
        results.deinit();
    }

    var total_errors: u32 = 0;
    var total_warns: u32 = 0;

    for (file_paths) |file_path| {
        const cfg = try resolver.resolve(file_path);
        const result = try analyzeFilePath(allocator, file_path, cfg);
        total_errors += result.error_count;
        total_warns += result.warn_count;
        try results.append(result);
    }

    return .{
        .results = try results.toOwnedSlice(),
        .file_count = try narrowCount(file_paths.len),
        .error_count = total_errors,
        .warn_count = total_warns,
        .pass = total_errors == 0,
    };
}

pub fn analyzeFolder(
    allocator: std.mem.Allocator,
    folder_path: []const u8,
    cfg: guardian_config.Config,
) !BatchResult {
    const paths = try source_files.collectSourceFiles(allocator, folder_path, cfg);
    defer source_files.freeOwnedStrings(allocator, paths);

    return analyzeFilePaths(allocator, paths, cfg);
}

pub fn analyzeFolderResolved(
    allocator: std.mem.Allocator,
    folder_path: []const u8,
    explicit_config_path: ?[]const u8,
) !BatchResult {
    var root_loaded = try guardian_config.loadForTarget(allocator, folder_path, explicit_config_path);
    defer root_loaded.deinit();

    const paths = try source_files.collectSourceFiles(allocator, folder_path, root_loaded.value);
    defer source_files.freeOwnedStrings(allocator, paths);

    return analyzeFilePathsResolved(allocator, paths, explicit_config_path);
}

pub fn batchToJson(allocator: std.mem.Allocator, batch: BatchResult) ![]u8 {
    return batchToJsonWithOptions(allocator, batch, .{});
}

pub fn batchToJsonWithOptions(
    allocator: std.mem.Allocator,
    batch: BatchResult,
    options: analyzer.JsonOptions,
) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    const writer = &buf.writer;
    const counts = countIncludedBatchViolations(batch, options.severity_filter);

    try writer.writeAll("{");
    try writer.print("\"file_count\":{d},", .{batch.file_count});
    try writer.print("\"error_count\":{d},", .{counts.errors});
    try writer.print("\"warn_count\":{d},", .{counts.warns});
    try writer.print("\"pass\":{},", .{counts.errors == 0});
    try writer.writeAll("\"results\":[");
    for (batch.results, 0..) |result, idx| {
        if (idx > 0) {
            try writer.writeAll(",");
        }
        const json = try analyzer.resultToJsonWithOptions(allocator, result, options);
        defer allocator.free(json);
        try writer.writeAll(json);
    }
    try writer.writeAll("]}");
    return buf.toOwnedSlice();
}

fn countIncludedBatchViolations(
    batch: BatchResult,
    severity_filter: analyzer.SeverityFilter,
) analyzer.SeverityCounts {
    var counts = analyzer.SeverityCounts{};
    for (batch.results) |result| {
        const result_counts = analyzer.countIncludedViolations(result, severity_filter);
        counts.errors += result_counts.errors;
        counts.warns += result_counts.warns;
    }
    return counts;
}

pub fn resultToPretty(allocator: std.mem.Allocator, result: AnalysisResult) ![]u8 {
    return reporting.resultToPretty(allocator, result);
}

pub fn resultToToolText(allocator: std.mem.Allocator, result: AnalysisResult) ![]u8 {
    return reporting.resultToToolText(allocator, result);
}

pub fn batchToPretty(allocator: std.mem.Allocator, batch: BatchResult) ![]u8 {
    return reporting.batchToPretty(allocator, .{
        .results = batch.results,
        .file_count = batch.file_count,
        .error_count = batch.error_count,
        .warn_count = batch.warn_count,
        .pass = batch.pass,
    });
}

pub fn batchToToolText(allocator: std.mem.Allocator, batch: BatchResult) ![]u8 {
    return reporting.batchToToolText(allocator, .{
        .results = batch.results,
        .file_count = batch.file_count,
        .error_count = batch.error_count,
        .warn_count = batch.warn_count,
        .pass = batch.pass,
    });
}

fn narrowCount(value: usize) !u32 {
    return std.math.cast(u32, value) orelse error.Overflow;
}

const testing = std.testing;

test "app: batch resolved configs support mixed monorepos" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "pkg_a");
    try compat.dirMakePath(tmp.dir, "pkg_b");

    var loaded_default = try test_config.loadDefault(testing.allocator);
    defer loaded_default.deinit();

    var pkg_a_cfg = loaded_default.value;
    pkg_a_cfg.go.ban_generics = true;
    const pkg_a_json = try test_config.stringify(testing.allocator, pkg_a_cfg);
    defer testing.allocator.free(pkg_a_json);

    try compat.dirWriteFile(tmp.dir, "pkg_a/guardian.config.json", pkg_a_json);

    var pkg_b_cfg = loaded_default.value;
    pkg_b_cfg.go.ban_generics = false;
    const pkg_b_json = try test_config.stringify(testing.allocator, pkg_b_cfg);
    defer testing.allocator.free(pkg_b_json);

    try compat.dirWriteFile(tmp.dir, "pkg_b/guardian.config.json", pkg_b_json);

    try compat.dirWriteFile(
        tmp.dir,
        "pkg_a/a.go",
        \\func Map[T any](items []T) []T {
        \\    return items
        \\}
        ,
    );
    try compat.dirWriteFile(
        tmp.dir,
        "pkg_b/b.go",
        \\func Map[T any](items []T) []T {
        \\    return items
        \\}
        ,
    );

    const file_a = try compat.dirRealpathAlloc(tmp.dir, testing.allocator, "pkg_a/a.go");
    defer testing.allocator.free(file_a);
    const file_b = try compat.dirRealpathAlloc(tmp.dir, testing.allocator, "pkg_b/b.go");
    defer testing.allocator.free(file_b);

    const paths = [_][]const u8{ file_a, file_b };
    var batch = try analyzeFilePathsResolved(testing.allocator, &paths, null);
    defer batch.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 2), batch.file_count);
    try testing.expectEqual(@as(u32, 1), batch.error_count);

    for (batch.results) |result| {
        if (std.mem.endsWith(u8, result.file_path, "pkg_a/a.go")) {
            try testing.expectEqual(@as(u32, 1), result.error_count);
        } else if (std.mem.endsWith(u8, result.file_path, "pkg_b/b.go")) {
            try testing.expectEqual(@as(u32, 0), result.error_count);
        }
    }
}

test "app: batch resolved explicit absolute config path can be reused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var loaded_default = try test_config.loadDefault(testing.allocator);
    defer loaded_default.deinit();

    var cfg = loaded_default.value;
    cfg.go.ban_generics = false;
    const config_json = try test_config.stringify(testing.allocator, cfg);
    defer testing.allocator.free(config_json);

    try compat.dirWriteFile(tmp.dir, "guardian.config.json", config_json);
    try compat.dirWriteFile(
        tmp.dir,
        "a.go",
        \\func Map[T any](items []T) []T {
        \\    return items
        \\}
        ,
    );
    try compat.dirWriteFile(
        tmp.dir,
        "b.go",
        \\func Reduce[T any](items []T) []T {
        \\    return items
        \\}
        ,
    );

    const absolute_config = try compat.dirRealpathAlloc(tmp.dir, testing.allocator, "guardian.config.json");
    defer testing.allocator.free(absolute_config);
    const file_a = try compat.dirRealpathAlloc(tmp.dir, testing.allocator, "a.go");
    defer testing.allocator.free(file_a);
    const file_b = try compat.dirRealpathAlloc(tmp.dir, testing.allocator, "b.go");
    defer testing.allocator.free(file_b);

    const paths = [_][]const u8{ file_a, file_b };
    var batch = try analyzeFilePathsResolved(testing.allocator, &paths, absolute_config);
    defer batch.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 2), batch.file_count);
    try testing.expectEqual(@as(u32, 0), batch.error_count);
    try testing.expect(batch.pass);
}

test "app: explicit design limits apply through resolved configs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var loaded_default = try test_config.loadDefault(testing.allocator);
    defer loaded_default.deinit();

    var cfg = loaded_default.value;
    cfg.limits.max_function_arguments = 1;
    cfg.limits.max_type_fields = 1;
    cfg.limits.max_hidden_touch_excess = 0;
    const config_json = try test_config.stringify(testing.allocator, cfg);
    defer testing.allocator.free(config_json);

    try compat.dirWriteFile(tmp.dir, "guardian.config.json", config_json);
    try compat.dirWriteFile(
        tmp.dir,
        "design.go",
        \\package sample
        \\
        \\type Session struct {
        \\    Active bool
        \\    Ready bool
        \\}
        \\
        \\func Build(a int, b int) int {
        \\    return run(pkg.Load(), repo.Fetch(), service.Call())
        \\}
        ,
    );

    const absolute_config = try compat.dirRealpathAlloc(tmp.dir, testing.allocator, "guardian.config.json");
    defer testing.allocator.free(absolute_config);
    const file_path = try compat.dirRealpathAlloc(tmp.dir, testing.allocator, "design.go");
    defer testing.allocator.free(file_path);

    const paths = [_][]const u8{file_path};
    var batch = try analyzeFilePathsResolved(testing.allocator, &paths, absolute_config);
    defer batch.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), batch.file_count);
    try testing.expect(batch.results[0].error_count >= 2);
    try testing.expect(resultHasRule(batch.results[0], .too_many_arguments));
    try testing.expect(resultHasRule(batch.results[0], .too_many_fields));
    try testing.expect(resultHasRule(batch.results[0], .hidden_coupling));
}

test "app: folder rendering survives configured pattern messages after resolver teardown" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var loaded_default = try test_config.loadDefault(testing.allocator);
    defer loaded_default.deinit();

    const config_json = try test_config.stringify(testing.allocator, loaded_default.value);
    defer testing.allocator.free(config_json);

    try compat.dirWriteFile(tmp.dir, "guardian.config.json", config_json);
    try compat.dirWriteFile(
        tmp.dir,
        "a.ts",
        \\export const logValue = (): void => {
        \\    console.log(1);
        \\};
        ,
    );

    const folder_path = try compat.dirRealpathAlloc(tmp.dir, testing.allocator, ".");
    defer testing.allocator.free(folder_path);

    var batch = try analyzeFolderResolved(testing.allocator, folder_path, null);
    defer batch.deinit(testing.allocator);

    const pretty = try batchToPretty(testing.allocator, batch);
    defer testing.allocator.free(pretty);
    try testing.expect(std.mem.indexOf(u8, pretty, "remove console logging before submission") != null);

    const json = try batchToJson(testing.allocator, batch);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "remove console logging before submission") != null);
}

test "app: batch json can hide errors or warnings through library options" {
    var loaded_default = try test_config.loadDefault(testing.allocator);
    defer loaded_default.deinit();

    const inputs = [_]FileInput{
        .{
            .file_path = "bad.go",
            .source = "func Process(data interface{}) {}\n",
        },
        .{
            .file_path = "warn.ts",
            .source = "export const logValue = (): void => { console.log(1); }\n",
        },
    };

    var batch = try analyzeBatchInputs(testing.allocator, &inputs, loaded_default.value);
    defer batch.deinit(testing.allocator);

    const warnings_json = try batchToJsonWithOptions(testing.allocator, batch, .{
        .severity_filter = .warnings_only,
    });
    defer testing.allocator.free(warnings_json);
    try testing.expect(std.mem.indexOf(u8, warnings_json, "\"error_count\":0") != null);
    try testing.expect(std.mem.indexOf(u8, warnings_json, "\"severity\":\"error\"") == null);
    try testing.expect(std.mem.indexOf(u8, warnings_json, "\"severity\":\"warn\"") != null);

    const errors_json = try batchToJsonWithOptions(testing.allocator, batch, .{
        .severity_filter = .errors_only,
    });
    defer testing.allocator.free(errors_json);
    try testing.expect(std.mem.indexOf(u8, errors_json, "\"warn_count\":0") != null);
    try testing.expect(std.mem.indexOf(u8, errors_json, "\"severity\":\"warn\"") == null);
    try testing.expect(std.mem.indexOf(u8, errors_json, "\"severity\":\"error\"") != null);
}

fn resultHasRule(result: AnalysisResult, rule: types.Rule) bool {
    for (result.violations) |violation| {
        if (violation.rule == rule) {
            return true;
        }
    }
    return false;
}
