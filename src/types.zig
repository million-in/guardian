const std = @import("std");

pub const Language = enum {
    go,
    typescript,
    python,
    zig_lang,

    pub fn fromExtension(ext: []const u8) ?Language {
        if (std.mem.eql(u8, ext, ".go")) return .go;
        if (std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".tsx")) return .typescript;
        if (std.mem.eql(u8, ext, ".py")) return .python;
        if (std.mem.eql(u8, ext, ".zig")) return .zig_lang;
        return null;
    }
};

pub const Severity = enum {
    @"error",
    warn,
    info,

    pub fn toString(self: Severity) []const u8 {
        return switch (self) {
            .@"error" => "error",
            .warn => "warn",
            .info => "info",
        };
    }
};

pub const Rule = enum {
    nesting_depth,
    cyclomatic_complexity,
    banned_type,
    generic_usage,
    low_cohesion,
    high_coupling,
    too_many_arguments,
    too_many_fields,
    hidden_coupling,
    temporal_coupling,
    boolean_state_machine,
    ambiguous_lifecycle_ownership,
    inconsistent_indent,
    line_too_long,
    trailing_whitespace,
    mixed_indent,
    function_too_long,

    pub fn toString(self: Rule) []const u8 {
        return switch (self) {
            .nesting_depth => "nesting_depth",
            .cyclomatic_complexity => "cyclomatic_complexity",
            .banned_type => "banned_type",
            .generic_usage => "generic_usage",
            .low_cohesion => "low_cohesion",
            .high_coupling => "high_coupling",
            .too_many_arguments => "too_many_arguments",
            .too_many_fields => "too_many_fields",
            .hidden_coupling => "hidden_coupling",
            .temporal_coupling => "temporal_coupling",
            .boolean_state_machine => "boolean_state_machine",
            .ambiguous_lifecycle_ownership => "ambiguous_lifecycle_ownership",
            .inconsistent_indent => "inconsistent_indent",
            .line_too_long => "line_too_long",
            .trailing_whitespace => "trailing_whitespace",
            .mixed_indent => "mixed_indent",
            .function_too_long => "function_too_long",
        };
    }
};

pub const Violation = struct {
    line: u32,
    column: u32,
    end_line: u32,
    rule: Rule,
    severity: Severity,
    message: []const u8,
    message_owned: bool = false,
    excerpt: []const u8 = "",
    excerpt_owned: bool = false,
};

pub const FunctionSpan = struct {
    name: []const u8,
    start_line: u32,
    end_line: u32,
    brace_depth_at_start: u32,
};

pub fn freeViolations(allocator: std.mem.Allocator, violations: []Violation) void {
    for (violations) |violation| {
        if (violation.message_owned) {
            allocator.free(violation.message);
        }
        if (violation.excerpt_owned) {
            allocator.free(violation.excerpt);
        }
    }
    allocator.free(violations);
}

/// Splits source into lines. Caller owns returned slice (allocated from allocator).
pub fn splitLines(allocator: std.mem.Allocator, source: []const u8) ![]const []const u8 {
    var lines = std.array_list.Managed([]const u8).init(allocator);
    var iter = std.mem.splitScalar(u8, source, '\n');
    while (iter.next()) |line| {
        try lines.append(line);
    }
    return lines.toOwnedSlice();
}

/// Count leading whitespace characters.
pub fn leadingWhitespace(line: []const u8) u32 {
    var count: u32 = 0;
    for (line) |ch| {
        if (ch == ' ' or ch == '\t') {
            count += 1;
        } else break;
    }
    return count;
}

/// Trim trailing whitespace from a line.
pub fn trimRight(line: []const u8) []const u8 {
    var end = line.len;
    while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t' or line[end - 1] == '\r')) {
        end -= 1;
    }
    return line[0..end];
}

pub fn usizeToU32(value: usize) !u32 {
    return std.math.cast(u32, value) orelse error.Overflow;
}

pub fn i32ToU32(value: i32) !u32 {
    return std.math.cast(u32, value) orelse error.Overflow;
}

pub fn indexToLineNumber(index: usize) !u32 {
    const base = try usizeToU32(index);
    return std.math.add(u32, base, 1);
}

pub fn maskSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: Language,
) ![]u8 {
    const masked = try allocator.dupe(u8, source);

    switch (lang) {
        .go => maskBraceStyleSource(source, masked, .{
            .allow_block_comments = true,
            .allow_single_quotes = true,
            .backtick_mode = .raw,
        }),
        .typescript => maskBraceStyleSource(source, masked, .{
            .allow_block_comments = true,
            .allow_single_quotes = true,
            .backtick_mode = .template,
        }),
        .zig_lang => maskBraceStyleSource(source, masked, .{
            .allow_block_comments = false,
            .allow_single_quotes = true,
            .backtick_mode = .none,
            .mask_line_literals = true,
        }),
        .python => maskPythonSource(source, masked),
    }

    return masked;
}

const BacktickMode = enum {
    none,
    raw,
    template,
};

const BraceMaskOptions = struct {
    allow_block_comments: bool,
    allow_single_quotes: bool,
    backtick_mode: BacktickMode,
    mask_line_literals: bool = false,
};

fn maskBraceStyleSource(source: []const u8, masked: []u8, options: BraceMaskOptions) void {
    const Mode = enum {
        code,
        line_comment,
        block_comment,
        single_quote,
        double_quote,
        backtick_raw,
        template_raw,
        template_expr,
        template_expr_line_comment,
        template_expr_block_comment,
        template_expr_single_quote,
        template_expr_double_quote,
    };

    var mode: Mode = .code;
    var escaped = false;
    var template_depth: u32 = 0;
    var i: usize = 0;

    while (i < source.len) : (i += 1) {
        const ch = source[i];

        switch (mode) {
            .line_comment => {
                if (ch != '\n') {
                    masked[i] = ' ';
                } else {
                    mode = .code;
                }
            },
            .block_comment => {
                if (ch != '\n') {
                    masked[i] = ' ';
                }
                if (ch == '*' and i + 1 < source.len and source[i + 1] == '/') {
                    masked[i + 1] = ' ';
                    i += 1;
                    mode = .code;
                }
            },
            .single_quote => {
                if (ch != '\n') {
                    masked[i] = ' ';
                }
                if (escaped) {
                    escaped = false;
                    continue;
                }
                if (ch == '\\') {
                    escaped = true;
                    continue;
                }
                if (ch == '\'' or ch == '\n') {
                    mode = .code;
                }
            },
            .double_quote => {
                if (ch != '\n') {
                    masked[i] = ' ';
                }
                if (escaped) {
                    escaped = false;
                    continue;
                }
                if (ch == '\\') {
                    escaped = true;
                    continue;
                }
                if (ch == '"' or ch == '\n') {
                    mode = .code;
                }
            },
            .backtick_raw => {
                if (ch != '\n') {
                    masked[i] = ' ';
                }
                if (ch == '`') {
                    mode = .code;
                }
            },
            .template_raw => {
                if (ch != '\n') {
                    masked[i] = ' ';
                }
                if (ch == '`') {
                    mode = .code;
                    continue;
                }
                if (ch == '$' and i + 1 < source.len and source[i + 1] == '{') {
                    masked[i + 1] = ' ';
                    template_depth = 1;
                    mode = .template_expr;
                    i += 1;
                }
            },
            .template_expr => {
                if (ch != '\n') {
                    masked[i] = ' ';
                }
                if (ch == '/' and i + 1 < source.len and source[i + 1] == '/') {
                    masked[i + 1] = ' ';
                    mode = .template_expr_line_comment;
                    i += 1;
                    continue;
                }
                if (options.allow_block_comments and ch == '/' and i + 1 < source.len and source[i + 1] == '*') {
                    masked[i + 1] = ' ';
                    mode = .template_expr_block_comment;
                    i += 1;
                    continue;
                }
                if (options.allow_single_quotes and ch == '\'') {
                    escaped = false;
                    mode = .template_expr_single_quote;
                    continue;
                }
                if (ch == '"') {
                    escaped = false;
                    mode = .template_expr_double_quote;
                    continue;
                }
                if (ch == '{') {
                    template_depth += 1;
                    continue;
                }
                if (ch == '}') {
                    template_depth -= 1;
                    if (template_depth == 0) {
                        mode = .template_raw;
                    }
                }
            },
            .template_expr_line_comment => {
                if (ch != '\n') {
                    masked[i] = ' ';
                } else {
                    mode = .template_expr;
                }
            },
            .template_expr_block_comment => {
                if (ch != '\n') {
                    masked[i] = ' ';
                }
                if (ch == '*' and i + 1 < source.len and source[i + 1] == '/') {
                    masked[i + 1] = ' ';
                    i += 1;
                    mode = .template_expr;
                }
            },
            .template_expr_single_quote => {
                if (ch != '\n') {
                    masked[i] = ' ';
                }
                if (escaped) {
                    escaped = false;
                    continue;
                }
                if (ch == '\\') {
                    escaped = true;
                    continue;
                }
                if (ch == '\'' or ch == '\n') {
                    mode = .template_expr;
                }
            },
            .template_expr_double_quote => {
                if (ch != '\n') {
                    masked[i] = ' ';
                }
                if (escaped) {
                    escaped = false;
                    continue;
                }
                if (ch == '\\') {
                    escaped = true;
                    continue;
                }
                if (ch == '"' or ch == '\n') {
                    mode = .template_expr;
                }
            },
            .code => {
                if (ch == '/' and i + 1 < source.len and source[i + 1] == '/') {
                    masked[i] = ' ';
                    masked[i + 1] = ' ';
                    mode = .line_comment;
                    i += 1;
                    continue;
                }

                if (options.allow_block_comments and ch == '/' and i + 1 < source.len and source[i + 1] == '*') {
                    masked[i] = ' ';
                    masked[i + 1] = ' ';
                    mode = .block_comment;
                    i += 1;
                    continue;
                }

                if (options.mask_line_literals and
                    ch == '\\' and
                    i + 1 < source.len and
                    source[i + 1] == '\\' and
                    isLineOnlyWhitespaceBefore(source, i))
                {
                    masked[i] = ' ';
                    masked[i + 1] = ' ';
                    mode = .line_comment;
                    i += 1;
                    continue;
                }

                if (options.allow_single_quotes and ch == '\'') {
                    masked[i] = ' ';
                    escaped = false;
                    mode = .single_quote;
                    continue;
                }

                if (ch == '"') {
                    masked[i] = ' ';
                    escaped = false;
                    mode = .double_quote;
                    continue;
                }

                if (ch == '`') {
                    masked[i] = ' ';
                    mode = switch (options.backtick_mode) {
                        .none => .code,
                        .raw => .backtick_raw,
                        .template => .template_raw,
                    };
                }
            },
        }
    }
}

fn isLineOnlyWhitespaceBefore(source: []const u8, idx: usize) bool {
    var cursor = idx;
    while (cursor > 0) {
        cursor -= 1;
        if (source[cursor] == '\n') {
            return true;
        }
        if (source[cursor] != ' ' and source[cursor] != '\t' and source[cursor] != '\r') {
            return false;
        }
    }
    return true;
}

fn maskPythonSource(source: []const u8, masked: []u8) void {
    const Mode = enum {
        code,
        line_comment,
        single_quote,
        double_quote,
        triple_single,
        triple_double,
    };

    var mode: Mode = .code;
    var escaped = false;
    var i: usize = 0;

    while (i < source.len) : (i += 1) {
        const ch = source[i];

        switch (mode) {
            .line_comment => {
                if (ch != '\n') {
                    masked[i] = ' ';
                } else {
                    mode = .code;
                }
            },
            .single_quote => {
                if (ch != '\n') {
                    masked[i] = ' ';
                }
                if (escaped) {
                    escaped = false;
                    continue;
                }
                if (ch == '\\') {
                    escaped = true;
                    continue;
                }
                if (ch == '\'' or ch == '\n') {
                    mode = .code;
                }
            },
            .double_quote => {
                if (ch != '\n') {
                    masked[i] = ' ';
                }
                if (escaped) {
                    escaped = false;
                    continue;
                }
                if (ch == '\\') {
                    escaped = true;
                    continue;
                }
                if (ch == '"' or ch == '\n') {
                    mode = .code;
                }
            },
            .triple_single => {
                if (ch != '\n') {
                    masked[i] = ' ';
                }
                if (ch == '\'' and i + 2 < source.len and source[i + 1] == '\'' and source[i + 2] == '\'') {
                    masked[i + 1] = ' ';
                    masked[i + 2] = ' ';
                    i += 2;
                    mode = .code;
                }
            },
            .triple_double => {
                if (ch != '\n') {
                    masked[i] = ' ';
                }
                if (ch == '"' and i + 2 < source.len and source[i + 1] == '"' and source[i + 2] == '"') {
                    masked[i + 1] = ' ';
                    masked[i + 2] = ' ';
                    i += 2;
                    mode = .code;
                }
            },
            .code => {
                if (ch == '#') {
                    masked[i] = ' ';
                    mode = .line_comment;
                    continue;
                }

                if (ch == '\'') {
                    masked[i] = ' ';
                    if (i + 2 < source.len and source[i + 1] == '\'' and source[i + 2] == '\'') {
                        masked[i + 1] = ' ';
                        masked[i + 2] = ' ';
                        i += 2;
                        mode = .triple_single;
                    } else {
                        escaped = false;
                        mode = .single_quote;
                    }
                    continue;
                }

                if (ch == '"') {
                    masked[i] = ' ';
                    if (i + 2 < source.len and source[i + 1] == '"' and source[i + 2] == '"') {
                        masked[i + 1] = ' ';
                        masked[i + 2] = ' ';
                        i += 2;
                        mode = .triple_double;
                    } else {
                        escaped = false;
                        mode = .double_quote;
                    }
                }
            },
        }
    }
}

/// Backward-compatible helper for the older analyzers/tests.
pub fn isLikelyInString(line: []const u8, pos: usize) bool {
    var quote_count: u32 = 0;
    var i: usize = 0;
    while (i < pos and i < line.len) {
        if (line[i] == '"' and (i == 0 or line[i - 1] != '\\')) {
            quote_count += 1;
        }
        i += 1;
    }
    return (quote_count % 2) != 0;
}

const testing = std.testing;

test "maskSource: Zig multiline strings are blanked" {
    const src =
        \\const help =
        \\    \\if you pass { braces }
        \\;
    ;

    const masked = try maskSource(testing.allocator, src, .zig_lang);
    defer testing.allocator.free(masked);

    try testing.expect(std.mem.indexOf(u8, masked, "if you pass") == null);
    try testing.expect(std.mem.indexOf(u8, masked, "{ braces }") == null);
}

test "maskSource: TypeScript template expressions ignore braces inside nested strings" {
    const src =
        \\const s = `result: ${foo("}")}`;
    ;

    const masked = try maskSource(testing.allocator, src, .typescript);
    defer testing.allocator.free(masked);

    try testing.expect(masked.len == src.len);
    try testing.expect(masked[masked.len - 1] == ';');
    try testing.expect(std.mem.indexOf(u8, masked, "\"}\"") == null);
    try testing.expect(std.mem.indexOf(u8, masked, "foo") == null);
}
