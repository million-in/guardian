const std = @import("std");
const guardian_config = @import("../config.zig");
const types = @import("../types.zig");

const Violation = types.Violation;
const Language = types.Language;
const Rule = types.Rule;
const ViolationList = std.array_list.Managed(Violation);

pub fn analyzeCohesion(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    lang: Language,
    cfg: guardian_config.Config,
) ![]Violation {
    var violations = ViolationList.init(allocator);

    var import_count: u32 = 0;
    var function_count: u32 = 0;

    // Track function lengths (brace languages)
    var func_start: ?u32 = null;
    var func_name: []const u8 = "";
    var brace_depth: i32 = 0;
    var func_base: i32 = 0;

    for (lines, 0..) |line, line_idx| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0) continue;

        // Count imports
        if (isImportLine(trimmed, lang)) {
            import_count += 1;
        }

        if (lang == .python) {
            // Python: track function length by indent
            const is_def = std.mem.startsWith(u8, trimmed, "def ") or
                std.mem.startsWith(u8, trimmed, "async def ");
            if (is_def) {
                if (func_start) |fs| {
                    const end_line = try types.usizeToU32(line_idx);
                    const length = end_line - fs;
                    if (length > cfg.limits.max_function_lines) {
                        try violations.append(.{
                            .line = fs + 1,
                            .column = 0,
                            .end_line = end_line,
                            .rule = .function_too_long,
                            .severity = .warn,
                            .message = try std.fmt.allocPrint(
                                allocator,
                                "function '{s}' is {d} lines (max {d})",
                                .{ func_name, length, cfg.limits.max_function_lines },
                            ),
                            .message_owned = true,
                        });
                    }
                }
                func_start = try types.usizeToU32(line_idx);
                func_name = extractName(trimmed, lang);
                function_count += 1;
            }
        } else {
            // Brace languages
            const is_func = isFuncDef(trimmed, lang);
            if (is_func) function_count += 1;

            for (line) |ch| {
                if (ch == '{') {
                    brace_depth += 1;
                    if (is_func and func_start == null) {
                        func_start = try types.usizeToU32(line_idx);
                        func_base = brace_depth;
                        func_name = extractName(trimmed, lang);
                    }
                } else if (ch == '}') {
                    if (func_start) |fs| {
                        if (brace_depth == func_base) {
                            const end_line = try types.indexToLineNumber(line_idx);
                            const length = end_line - (fs + 1);
                            if (length > cfg.limits.max_function_lines) {
                                try violations.append(.{
                                    .line = fs + 1,
                                    .column = 0,
                                    .end_line = end_line,
                                    .rule = .function_too_long,
                                    .severity = .warn,
                                    .message = try std.fmt.allocPrint(
                                        allocator,
                                        "function '{s}' is {d} lines (max {d})",
                                        .{ func_name, length, cfg.limits.max_function_lines },
                                    ),
                                    .message_owned = true,
                                });
                            }
                            func_start = null;
                        }
                    }
                    brace_depth -= 1;
                    if (brace_depth < 0) brace_depth = 0;
                }
            }
        }
    }

    // Handle last Python function
    if (lang == .python) {
        if (func_start) |fs| {
            const end_line = try types.usizeToU32(lines.len);
            const length = end_line - fs;
            if (length > cfg.limits.max_function_lines) {
                try violations.append(.{
                    .line = fs + 1,
                    .column = 0,
                    .end_line = end_line,
                    .rule = .function_too_long,
                    .severity = .warn,
                    .message = try std.fmt.allocPrint(
                        allocator,
                        "function '{s}' is {d} lines (max {d})",
                        .{ func_name, length, cfg.limits.max_function_lines },
                    ),
                    .message_owned = true,
                });
            }
        }
    }

    // File-level violations
    if (import_count > cfg.limits.max_imports) {
        try violations.append(.{
            .line = 1,
            .column = 0,
            .end_line = 1,
            .rule = .high_coupling,
            .severity = .@"error",
            .message = try std.fmt.allocPrint(
                allocator,
                "file has {d} imports (max {d}) — high coupling, consider splitting",
                .{ import_count, cfg.limits.max_imports },
            ),
            .message_owned = true,
        });
    }

    if (function_count > cfg.limits.max_functions_per_file) {
        try violations.append(.{
            .line = 1,
            .column = 0,
            .end_line = try types.usizeToU32(lines.len),
            .rule = .low_cohesion,
            .severity = .@"error",
            .message = try std.fmt.allocPrint(
                allocator,
                "file has {d} functions (max {d}) — low cohesion, split into focused modules",
                .{ function_count, cfg.limits.max_functions_per_file },
            ),
            .message_owned = true,
        });
    }

    return violations.toOwnedSlice();
}

fn isImportLine(trimmed: []const u8, lang: Language) bool {
    return switch (lang) {
        .go => std.mem.startsWith(u8, trimmed, "import ") or
            (std.mem.eql(u8, trimmed, "import (")) or
            (trimmed[0] == '"' and std.mem.endsWith(u8, types.trimRight(trimmed), "\"")),
        .typescript => std.mem.startsWith(u8, trimmed, "import "),
        .python => std.mem.startsWith(u8, trimmed, "import ") or
            std.mem.startsWith(u8, trimmed, "from "),
        .zig_lang => std.mem.startsWith(u8, trimmed, "const ") and
            std.mem.indexOf(u8, trimmed, "@import") != null,
    };
}

fn isFuncDef(trimmed: []const u8, lang: Language) bool {
    return switch (lang) {
        .go => std.mem.startsWith(u8, trimmed, "func "),
        .typescript => std.mem.startsWith(u8, trimmed, "function ") or
            std.mem.startsWith(u8, trimmed, "export function ") or
            std.mem.startsWith(u8, trimmed, "async function ") or
            std.mem.startsWith(u8, trimmed, "export async function "),
        .zig_lang => std.mem.startsWith(u8, trimmed, "fn ") or
            std.mem.startsWith(u8, trimmed, "pub fn ") or
            std.mem.startsWith(u8, trimmed, "export fn "),
        .python => std.mem.startsWith(u8, trimmed, "def ") or
            std.mem.startsWith(u8, trimmed, "async def "),
    };
}

fn extractName(trimmed: []const u8, lang: Language) []const u8 {
    return switch (lang) {
        .go => extractGoFuncName(trimmed),
        .typescript => extractNamedSymbol(trimmed, &[_][]const u8{
            "export async function ",
            "async function ",
            "export function ",
            "function ",
        }),
        .zig_lang => extractNamedSymbol(trimmed, &[_][]const u8{
            "pub fn ",
            "export fn ",
            "fn ",
        }),
        .python => extractNamedSymbol(trimmed, &[_][]const u8{
            "async def ",
            "def ",
        }),
    };
}

fn extractNamedSymbol(trimmed: []const u8, prefixes: []const []const u8) []const u8 {
    for (prefixes) |prefix| {
        if (!std.mem.startsWith(u8, trimmed, prefix)) {
            continue;
        }

        const after = trimmed[prefix.len..];
        var end: usize = 0;
        while (end < after.len and after[end] != '(' and after[end] != ' ' and after[end] != '<' and after[end] != '=') {
            end += 1;
        }
        if (end > 0) {
            return after[0..end];
        }
    }

    return "<unknown>";
}

fn extractGoFuncName(trimmed: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, trimmed, "func ")) {
        return "<unknown>";
    }

    var after = std.mem.trimLeft(u8, trimmed["func ".len..], " \t");
    if (after.len == 0) {
        return "<unknown>";
    }

    if (after[0] == '(') {
        const receiver_end = std.mem.indexOfScalar(u8, after, ')') orelse return "<unknown>";
        after = std.mem.trimLeft(u8, after[receiver_end + 1 ..], " \t");
    }

    return extractNamedSymbol(after, &[_][]const u8{""});
}
