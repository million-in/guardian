const std = @import("std");
const analyzer = @import("analyzer.zig");
const types = @import("types.zig");

const AnalysisResult = analyzer.AnalysisResult;

pub const BatchView = struct {
    results: []const AnalysisResult,
    file_count: u32,
    error_count: u32,
    warn_count: u32,
    pass: bool,
};

const ansi = struct {
    const reset = "\x1b[0m";
    const red = "\x1b[31m";
    const gray = "\x1b[90m";
};

const TextMode = enum {
    cli,
    tool,
};

const StatusText = struct {
    color: []const u8,
    label: []const u8,
};

pub fn resultToPretty(allocator: std.mem.Allocator, result: AnalysisResult) ![]u8 {
    return renderResultText(allocator, result, .cli);
}

pub fn resultToToolText(allocator: std.mem.Allocator, result: AnalysisResult) ![]u8 {
    return renderResultText(allocator, result, .tool);
}

pub fn batchToPretty(allocator: std.mem.Allocator, batch: BatchView) ![]u8 {
    return renderBatchText(allocator, batch, .cli);
}

pub fn batchToToolText(allocator: std.mem.Allocator, batch: BatchView) ![]u8 {
    return renderBatchText(allocator, batch, .tool);
}

fn renderResultText(
    allocator: std.mem.Allocator,
    result: AnalysisResult,
    mode: TextMode,
) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    const writer = buf.writer();

    try writeResultHeader(writer, result, mode);

    if (result.violations.len == 0) {
        try writer.print("  {s}no violations{s}\n", .{ ansi.gray, ansi.reset });
        return buf.toOwnedSlice();
    }

    for (result.violations, 0..) |violation, idx| {
        if (idx > 0) {
            try writer.writeByte('\n');
        }
        try writeViolation(writer, violation, mode);
    }

    return buf.toOwnedSlice();
}

fn renderBatchText(
    allocator: std.mem.Allocator,
    batch: BatchView,
    mode: TextMode,
) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    const writer = buf.writer();

    try writeBatchHeader(writer, batch, mode);

    for (batch.results, 0..) |result, idx| {
        if (idx > 0) {
            switch (mode) {
                .cli => try writer.print("{s}--{s}\n\n", .{ ansi.gray, ansi.reset }),
                .tool => try writer.writeByte('\n'),
            }
        }
        const text = try renderResultText(allocator, result, mode);
        defer allocator.free(text);
        try writer.writeAll(text);
    }

    return buf.toOwnedSlice();
}

fn writeBatchHeader(writer: anytype, batch: BatchView, mode: TextMode) !void {
    const pass_status = batchStatus(batch.pass);
    const error_color = errorCountColor(batch.error_count);

    switch (mode) {
        .cli => try writeCliBatchHeader(writer, batch, error_color, pass_status),
        .tool => try writeToolBatchHeader(writer, batch, error_color, pass_status),
    }
}

fn writeResultHeader(writer: anytype, result: AnalysisResult, mode: TextMode) !void {
    const status = resultStatus(result);
    const error_color = errorCountColor(result.error_count);

    switch (mode) {
        .cli => try writeCliResultHeader(writer, result, error_color, status),
        .tool => try writeToolResultHeader(writer, result, status),
    }
}

fn writeCliBatchHeader(
    writer: anytype,
    batch: BatchView,
    error_color: []const u8,
    pass_status: StatusText,
) !void {
    try writer.print(
        "{s}Scanned{s} {d} files  {s}{d} errors{s}  {s}{d} warns{s}  {s}{s}{s}\n",
        .{
            ansi.gray,
            ansi.reset,
            batch.file_count,
            error_color,
            batch.error_count,
            ansi.reset,
            ansi.gray,
            batch.warn_count,
            ansi.reset,
            pass_status.color,
            pass_status.label,
            ansi.reset,
        },
    );
    try writer.print("{s}--{s}\n\n", .{ ansi.gray, ansi.reset });
}

fn writeToolBatchHeader(
    writer: anytype,
    batch: BatchView,
    error_color: []const u8,
    pass_status: StatusText,
) !void {
    try writer.print(
        "{s}Scanned{s} {d} files: {s}{d} errors{s}, {s}{d} warns{s}, {s}{s}{s}\n\n",
        .{
            ansi.gray,
            ansi.reset,
            batch.file_count,
            error_color,
            batch.error_count,
            ansi.reset,
            ansi.gray,
            batch.warn_count,
            ansi.reset,
            pass_status.color,
            pass_status.label,
            ansi.reset,
        },
    );
}

fn writeCliResultHeader(
    writer: anytype,
    result: AnalysisResult,
    error_color: []const u8,
    status: StatusText,
) !void {
    try writer.print(
        "{s}{s}{s}  {s}{s}{s}  {s}{d} errors{s}, {s}{d} warns{s}\n",
        .{
            ansi.gray,
            result.file_path,
            ansi.reset,
            status.color,
            status.label,
            ansi.reset,
            error_color,
            result.error_count,
            ansi.reset,
            ansi.gray,
            result.warn_count,
            ansi.reset,
        },
    );
}

fn writeToolResultHeader(
    writer: anytype,
    result: AnalysisResult,
    status: StatusText,
) !void {
    try writer.print(
        "{s}{s}{s}: {s}{s}{s} ({d} errors, {d} warns)\n",
        .{
            ansi.gray,
            result.file_path,
            ansi.reset,
            status.color,
            status.label,
            ansi.reset,
            result.error_count,
            result.warn_count,
        },
    );
}

fn batchStatus(pass: bool) StatusText {
    return if (pass)
        .{ .color = ansi.gray, .label = "PASS" }
    else
        .{ .color = ansi.red, .label = "FAIL" };
}

fn resultStatus(result: AnalysisResult) StatusText {
    return batchStatus(result.error_count == 0);
}

fn errorCountColor(error_count: u32) []const u8 {
    return if (error_count > 0) ansi.red else ansi.gray;
}

fn writeViolation(writer: anytype, violation: types.Violation, mode: TextMode) !void {
    const color = switch (violation.severity) {
        .@"error" => ansi.red,
        .warn, .info => ansi.gray,
    };

    switch (mode) {
        .cli => {
            try writer.writeAll("  ");
            try writer.print("{s}{s}{s}  {s}{s}{s}  {s}", .{
                color,
                violation.severity.toString(),
                ansi.reset,
                ansi.gray,
                violation.rule.toString(),
                ansi.reset,
                ansi.gray,
            });
            try writeLineSpan(writer, violation);
            try writer.print("{s}\n", .{ansi.reset});
            try writer.print("  {s}{s}{s}\n", .{ color, violation.message, ansi.reset });
        },
        .tool => {
            try writer.writeAll("  ");
            try writer.print("{s}{s}{s} {s}{s}{s} {s}", .{
                color,
                violation.severity.toString(),
                ansi.reset,
                ansi.gray,
                violation.rule.toString(),
                ansi.reset,
                ansi.gray,
            });
            try writeLineSpan(writer, violation);
            try writer.print("{s}: {s}{s}{s}\n", .{ ansi.reset, color, violation.message, ansi.reset });
        },
    }

    if (violation.excerpt.len > 0) {
        try writeExcerpt(writer, violation, mode);
    }
}

fn writeLineSpan(writer: anytype, violation: types.Violation) !void {
    if (violation.end_line > violation.line) {
        try writer.print("lines {d}-{d}", .{ violation.line, violation.end_line });
        return;
    }
    try writer.print("line {d}", .{violation.line});
}

fn writeExcerpt(writer: anytype, violation: types.Violation, mode: TextMode) !void {
    if (mode == .cli) {
        try writer.print("  {s}code:{s}\n", .{ ansi.gray, ansi.reset });
    }

    const excerpt = std.mem.trimRight(u8, violation.excerpt, "\n");
    if (excerpt.len == 0) {
        return;
    }

    var line_no = violation.line;
    const width = lineNumberWidth(violation.end_line);
    var iter = std.mem.splitScalar(u8, excerpt, '\n');
    while (iter.next()) |line| {
        if (std.mem.eql(u8, line, "...")) {
            try writeExcerptLine(writer, line, line_no, width, mode, true);
            continue;
        }

        try writeExcerptLine(writer, line, line_no, width, mode, false);
        line_no += 1;
    }
}

fn writeExcerptLine(
    writer: anytype,
    line: []const u8,
    line_no: u32,
    width: usize,
    mode: TextMode,
    is_gap: bool,
) !void {
    if (is_gap) {
        switch (mode) {
            .cli => try writer.print("  {s}{s}{s}\n", .{ ansi.gray, line, ansi.reset }),
            .tool => try writer.print("    {s}{s}{s}\n", .{ ansi.gray, line, ansi.reset }),
        }
        return;
    }

    switch (mode) {
        .cli => try writer.writeAll("  "),
        .tool => try writer.writeAll("    "),
    }

    try writer.writeAll(ansi.gray);
    try writePaddedLineNumber(writer, line_no, width);
    try writer.writeAll(" | ");
    try writer.writeAll(line);
    try writer.writeAll(ansi.reset);
    try writer.writeByte('\n');
}

fn writePaddedLineNumber(writer: anytype, line_no: u32, width: usize) !void {
    const digits = lineNumberWidth(line_no);
    if (width > digits) {
        try writer.writeByteNTimes(' ', width - digits);
    }
    try writer.print("{d}", .{line_no});
}

fn lineNumberWidth(line_no: u32) usize {
    var value = if (line_no == 0) @as(u32, 1) else line_no;
    var digits: usize = 0;
    while (value > 0) : (value /= 10) {
        digits += 1;
    }
    return digits;
}
