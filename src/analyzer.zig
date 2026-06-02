const std = @import("std");
const guardian_config = @import("config.zig");
const jsonrpc = @import("jsonrpc.zig");
const types = @import("types.zig");
const nesting = @import("analyzers/nesting.zig");
const complexity = @import("analyzers/complexity.zig");
const type_check = @import("analyzers/type_check.zig");
const cohesion = @import("analyzers/cohesion.zig");
const design = @import("analyzers/design.zig");
const formatting = @import("analyzers/formatting.zig");

const Language = types.Language;
const Violation = types.Violation;

pub const SeverityFilter = enum {
    all,
    errors_only,
    warnings_only,
    clear_errors,

    pub fn includes(self: SeverityFilter, severity: types.Severity) bool {
        return switch (self) {
            .all => true,
            .errors_only => severity == .@"error",
            .warnings_only, .clear_errors => severity == .warn,
        };
    }

    pub fn fromString(value: []const u8) ?SeverityFilter {
        if (std.mem.eql(u8, value, "all")) return .all;
        if (std.mem.eql(u8, value, "errors_only")) return .errors_only;
        if (std.mem.eql(u8, value, "warnings_only")) return .warnings_only;
        if (std.mem.eql(u8, value, "warns_only")) return .warnings_only;
        if (std.mem.eql(u8, value, "clear_errors")) return .clear_errors;
        return null;
    }
};

pub const JsonOptions = struct {
    severity_filter: SeverityFilter = .all,
};

pub const SeverityCounts = struct {
    errors: u32 = 0,
    warns: u32 = 0,
};

pub const AnalysisResult = struct {
    violations: []Violation,
    file_path: []const u8,
    language: Language,
    line_count: u32,
    error_count: u32,
    warn_count: u32,
};

/// Run all analyzers on a source file. Returns aggregated violations sorted by line.
pub fn analyze(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    source: []const u8,
    lang: Language,
    cfg: guardian_config.Config,
) !AnalysisResult {
    const raw_lines = try types.splitLines(allocator, source);
    defer allocator.free(raw_lines);
    const masked_source = try types.maskSource(allocator, source, lang);
    defer allocator.free(masked_source);
    const masked_lines = try types.splitLines(allocator, masked_source);
    defer allocator.free(masked_lines);

    var all = std.array_list.Managed(Violation).init(allocator);

    // ── Nesting ──
    const nesting_v = if (lang == .python)
        try nesting.analyzePythonNesting(allocator, masked_lines, cfg)
    else
        try nesting.analyzeBraceNesting(allocator, masked_lines, lang, cfg);
    try all.appendSlice(nesting_v);
    allocator.free(nesting_v);

    // ── Cyclomatic complexity ──
    const complexity_v = if (lang == .python)
        try complexity.analyzePythonComplexity(allocator, masked_lines, cfg)
    else
        try complexity.analyzeBraceComplexity(allocator, masked_lines, lang, cfg);
    try all.appendSlice(complexity_v);
    allocator.free(complexity_v);

    // ── Type safety ──
    const type_v = try type_check.analyzeTypes(allocator, raw_lines, masked_lines, lang, cfg);
    try all.appendSlice(type_v);
    allocator.free(type_v);

    // ── Cohesion/coupling ──
    const cohesion_v = try cohesion.analyzeCohesion(allocator, raw_lines, masked_lines, lang, cfg);
    try all.appendSlice(cohesion_v);
    allocator.free(cohesion_v);

    // ── Cross-language design rules ──
    const design_v = try design.analyzeDesign(allocator, raw_lines, masked_lines, lang, cfg);
    try all.appendSlice(design_v);
    allocator.free(design_v);

    // ── Formatting ──
    const fmt_v = try formatting.analyzeFormatting(allocator, raw_lines, lang, cfg);
    try all.appendSlice(fmt_v);
    allocator.free(fmt_v);

    const violations = try all.toOwnedSlice();
    try attachExcerpts(allocator, raw_lines, violations, cfg);

    // Sort by line number
    std.mem.sort(Violation, violations, {}, struct {
        fn lessThan(_: void, a: Violation, b: Violation) bool {
            return a.line < b.line;
        }
    }.lessThan);

    // Count severities
    var errors: u32 = 0;
    var warns: u32 = 0;
    for (violations) |v| {
        switch (v.severity) {
            .@"error" => errors += 1,
            .warn => warns += 1,
            .info => {},
        }
    }

    return .{
        .violations = violations,
        .file_path = try allocator.dupe(u8, file_path),
        .language = lang,
        .line_count = @intCast(raw_lines.len),
        .error_count = errors,
        .warn_count = warns,
    };
}

pub fn freeResult(allocator: std.mem.Allocator, result: AnalysisResult) void {
    allocator.free(result.file_path);
    types.freeViolations(allocator, result.violations);
}

/// Serialize analysis result to JSON.
pub fn resultToJson(allocator: std.mem.Allocator, result: AnalysisResult) ![]u8 {
    return resultToJsonWithOptions(allocator, result, .{});
}

pub fn resultToJsonWithOptions(
    allocator: std.mem.Allocator,
    result: AnalysisResult,
    options: JsonOptions,
) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    const writer = &buf.writer;
    const counts = countIncludedViolations(result, options.severity_filter);

    try writer.writeAll("{\"file_path\":\"");
    try writeJsonEscaped(writer, result.file_path);
    try writer.writeAll("\",\"language\":\"");
    try writeJsonEscaped(writer, @tagName(result.language));
    try writer.print("\",\"line_count\":{d},", .{result.line_count});
    try writer.print("\"error_count\":{d},", .{counts.errors});
    try writer.print("\"warn_count\":{d},", .{counts.warns});
    try writer.print("\"pass\":{},", .{counts.errors == 0});
    try writer.writeAll("\"violations\":[");

    var written: usize = 0;
    for (result.violations, 0..) |v, i| {
        _ = i;
        if (!options.severity_filter.includes(v.severity)) {
            continue;
        }
        if (written > 0) try writer.writeAll(",");
        written += 1;
        try writer.writeAll("{");
        try writer.print("\"line\":{d},", .{v.line});
        try writer.print("\"column\":{d},", .{v.column});
        try writer.print("\"end_line\":{d},", .{v.end_line});
        try writer.print("\"rule\":\"{s}\",", .{v.rule.toString()});
        try writer.print("\"severity\":\"{s}\",", .{v.severity.toString()});
        // Escape message for JSON
        try writer.writeAll("\"message\":\"");
        try writeJsonEscaped(writer, v.message);
        try writer.writeAll("\",\"excerpt\":\"");
        try writeJsonEscaped(writer, v.excerpt);
        try writer.writeAll("\"}");
    }

    try writer.writeAll("]}");
    return buf.toOwnedSlice();
}

pub fn countIncludedViolations(
    result: AnalysisResult,
    severity_filter: SeverityFilter,
) SeverityCounts {
    var counts = SeverityCounts{};
    for (result.violations) |violation| {
        if (!severity_filter.includes(violation.severity)) {
            continue;
        }
        switch (violation.severity) {
            .@"error" => counts.errors += 1,
            .warn => counts.warns += 1,
            .info => {},
        }
    }
    return counts;
}

fn attachExcerpts(
    allocator: std.mem.Allocator,
    raw_lines: []const []const u8,
    violations: []Violation,
    cfg: guardian_config.Config,
) !void {
    for (violations) |*violation| {
        const excerpt = try buildExcerpt(
            allocator,
            raw_lines,
            violation.line,
            violation.end_line,
            cfg.limits.max_excerpt_lines,
            cfg.limits.max_excerpt_chars,
        );
        violation.excerpt = excerpt;
        violation.excerpt_owned = true;
    }
}

fn buildExcerpt(
    allocator: std.mem.Allocator,
    raw_lines: []const []const u8,
    line: u32,
    end_line: u32,
    max_lines: u32,
    max_chars: u32,
) ![]u8 {
    if (raw_lines.len == 0) {
        return allocator.dupe(u8, "");
    }

    const start_idx: usize = if (line > 0 and line - 1 < raw_lines.len) line - 1 else 0;
    const requested_end: usize = if (end_line > 0 and end_line <= raw_lines.len) end_line else raw_lines.len;
    const capped_end = @min(requested_end, start_idx + @as(usize, max_lines));
    const max_chars_usize = @as(usize, max_chars);

    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    const writer = &buf.writer;
    var truncated = false;

    var idx = start_idx;
    while (idx < capped_end) : (idx += 1) {
        const current = types.trimRight(raw_lines[idx]);
        if (buf.written().len > 0) {
            if (buf.written().len >= max_chars_usize) {
                truncated = true;
                break;
            }
            try writer.writeByte('\n');
        }
        if (buf.written().len >= max_chars_usize) {
            truncated = true;
            break;
        }
        const remaining = max_chars_usize - buf.written().len;
        if (current.len > remaining) {
            if (remaining > 0) {
                try writer.writeAll(current[0..remaining]);
            }
            truncated = true;
            break;
        }
        try writer.writeAll(current);
    }

    if (requested_end > capped_end or truncated) {
        const written = buf.written();
        if (written.len > 0 and written[written.len - 1] != '\n') {
            try writer.writeByte('\n');
        }
        try writer.writeAll("...");
    }

    return buf.toOwnedSlice();
}

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    try jsonrpc.writeJsonEscaped(writer, s);
}

const testing = std.testing;

test "analyzer: excerpts clamp without underflow when newline uses remaining budget" {
    const lines = [_][]const u8{
        "abc",
        "def",
    };

    const excerpt = try buildExcerpt(testing.allocator, &lines, 1, 2, 2, 3);
    defer testing.allocator.free(excerpt);

    try testing.expectEqualStrings("abc\n...", excerpt);
}

test "analyzer: result json escapes control bytes" {
    const violations = try testing.allocator.alloc(Violation, 1);
    defer testing.allocator.free(violations);
    violations[0] = .{
        .line = 1,
        .column = 0,
        .end_line = 1,
        .rule = .banned_type,
        .severity = .@"error",
        .message = "bad\x01value",
        .excerpt = "line\x02text",
    };

    const result = AnalysisResult{
        .violations = violations,
        .file_path = "sample\x03.go",
        .language = .go,
        .line_count = 1,
        .error_count = 1,
        .warn_count = 0,
    };

    const json = try resultToJson(testing.allocator, result);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\\u0001") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\\u0002") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\\u0003") != null);
}
