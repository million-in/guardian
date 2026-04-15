const std = @import("std");
const guardian_config = @import("config.zig");
const types = @import("types.zig");
const nesting = @import("analyzers/nesting.zig");
const complexity = @import("analyzers/complexity.zig");
const type_check = @import("analyzers/type_check.zig");
const cohesion = @import("analyzers/cohesion.zig");
const formatting = @import("analyzers/formatting.zig");

const Language = types.Language;
const Violation = types.Violation;

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
    const cohesion_v = try cohesion.analyzeCohesion(allocator, masked_lines, lang, cfg);
    try all.appendSlice(cohesion_v);
    allocator.free(cohesion_v);

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
    var buf = std.array_list.Managed(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("{\"file_path\":\"");
    try writeJsonEscaped(writer, result.file_path);
    try writer.writeAll("\",\"language\":\"");
    try writeJsonEscaped(writer, @tagName(result.language));
    try std.fmt.format(writer, "\",\"line_count\":{d},", .{result.line_count});
    try std.fmt.format(writer, "\"error_count\":{d},", .{result.error_count});
    try std.fmt.format(writer, "\"warn_count\":{d},", .{result.warn_count});
    try std.fmt.format(writer, "\"pass\":{},", .{result.error_count == 0});
    try writer.writeAll("\"violations\":[");

    for (result.violations, 0..) |v, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("{");
        try std.fmt.format(writer, "\"line\":{d},", .{v.line});
        try std.fmt.format(writer, "\"column\":{d},", .{v.column});
        try std.fmt.format(writer, "\"end_line\":{d},", .{v.end_line});
        try std.fmt.format(writer, "\"rule\":\"{s}\",", .{v.rule.toString()});
        try std.fmt.format(writer, "\"severity\":\"{s}\",", .{v.severity.toString()});
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

    var buf = std.array_list.Managed(u8).init(allocator);
    const writer = buf.writer();

    var idx = start_idx;
    while (idx < capped_end) : (idx += 1) {
        const current = types.trimRight(raw_lines[idx]);
        if (buf.items.len > 0) {
            try writer.writeByte('\n');
        }
        if (buf.items.len + current.len > max_chars) {
            const remaining = max_chars - @as(u32, @intCast(buf.items.len));
            if (remaining > 0) {
                const slice_len: usize = @intCast(@min(current.len, remaining));
                try writer.writeAll(current[0..slice_len]);
            }
            break;
        }
        try writer.writeAll(current);
    }

    if (requested_end > capped_end or buf.items.len >= max_chars) {
        if (buf.items.len > 0 and buf.items[buf.items.len - 1] != '\n') {
            try writer.writeByte('\n');
        }
        try writer.writeAll("...");
    }

    return buf.toOwnedSlice();
}

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(ch),
        }
    }
}
