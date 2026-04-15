const std = @import("std");
const guardian_config = @import("../config.zig");
const types = @import("../types.zig");

const Violation = types.Violation;
const Language = types.Language;
const Rule = types.Rule;
const ViolationList = std.array_list.Managed(Violation);

const FuncInfo = struct {
    name: []const u8,
    start_line: u32,
    complexity: u32,
    base_depth: i32,
};

/// Cyclomatic complexity for brace-delimited languages.
/// Counts: if, else if, case, for, while, &&, ||, catch, ternary ?.
pub fn analyzeBraceComplexity(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    lang: Language,
    cfg: guardian_config.Config,
) ![]Violation {
    var violations = ViolationList.init(allocator);

    var current_func: ?FuncInfo = null;
    var brace_depth: i32 = 0;
    var in_string = false;
    var in_block_comment = false;

    const branch_keywords = switch (lang) {
        .go => &[_][]const u8{ "if ", "else if ", "case ", "for ", "&&", "||" },
        .typescript => &[_][]const u8{ "if ", "else if ", "case ", "for ", "while ", "&&", "||", "catch ", "? " },
        .zig_lang => &[_][]const u8{ "if ", "else if ", "for ", "while ", "orelse", "catch ", "switch " },
        .python => unreachable,
    };

    for (lines, 0..) |line, line_idx| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0) continue;

        // Skip comments
        if (in_block_comment) {
            if (std.mem.indexOf(u8, trimmed, "*/") != null) {
                in_block_comment = false;
            }
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        if (std.mem.startsWith(u8, trimmed, "/*")) {
            in_block_comment = true;
            if (std.mem.indexOf(u8, trimmed, "*/") != null) in_block_comment = false;
            continue;
        }

        // Function detection
        const is_func = isFunctionLine(trimmed, lang);
        if (is_func) {
            // Emit previous function
            if (current_func) |func| {
                try emitIfViolation(allocator, &violations, func, try types.usizeToU32(line_idx), cfg);
            }
        }

        // Track braces
        in_string = false;
        for (line, 0..) |ch, ci| {
            _ = ci;
            if (ch == '"' and !in_string) {
                in_string = true;
            } else if (ch == '"' and in_string) {
                in_string = false;
            }
            if (in_string) continue;

            if (ch == '{') {
                brace_depth += 1;
                if (is_func and current_func == null) {
                    current_func = .{
                        .name = extractFuncName(trimmed, lang),
                        .start_line = try types.usizeToU32(line_idx),
                        .complexity = 1, // base complexity
                        .base_depth = brace_depth,
                    };
                } else if (is_func) {
                    current_func = .{
                        .name = extractFuncName(trimmed, lang),
                        .start_line = try types.usizeToU32(line_idx),
                        .complexity = 1,
                        .base_depth = brace_depth,
                    };
                }
            } else if (ch == '}') {
                if (current_func) |func| {
                    if (brace_depth == func.base_depth) {
                        try emitIfViolation(allocator, &violations, func, try types.indexToLineNumber(line_idx), cfg);
                        current_func = null;
                    }
                }
                brace_depth -= 1;
                if (brace_depth < 0) brace_depth = 0;
            }
        }

        // Count branch keywords in current function
        if (current_func != null) {
            for (branch_keywords) |kw| {
                var search_pos: usize = 0;
                while (std.mem.indexOfPos(u8, trimmed, search_pos, kw)) |pos| {
                    current_func.?.complexity += 1;
                    search_pos = pos + kw.len;
                }
            }
        }
    }

    // Emit last function
    if (current_func) |func| {
        try emitIfViolation(allocator, &violations, func, try types.usizeToU32(lines.len), cfg);
    }

    return violations.toOwnedSlice();
}

/// Cyclomatic complexity for Python (indent-based).
pub fn analyzePythonComplexity(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    cfg: guardian_config.Config,
) ![]Violation {
    var violations = ViolationList.init(allocator);

    const py_keywords = [_][]const u8{
        "if ", "elif ", "for ", "while ", "except ", "except:",
        " and ", " or ", " if ", // inline conditionals
    };

    var func_name: []const u8 = "";
    var func_indent: ?u32 = null;
    var func_start: u32 = 0;
    var complexity: u32 = 1;

    for (lines, 0..) |line, line_idx| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        const ws = types.leadingWhitespace(line);

        // Detect function def
        const is_def = std.mem.startsWith(u8, trimmed, "def ") or
            std.mem.startsWith(u8, trimmed, "async def ");

        if (is_def) {
            // Close previous
            if (func_indent != null) {
                try emitPythonViolation(allocator, &violations, func_name, func_start, try types.usizeToU32(line_idx), complexity, cfg);
            }
            func_indent = ws;
            func_start = try types.usizeToU32(line_idx);
            func_name = extractPythonFuncName(trimmed);
            complexity = 1;
            continue;
        }

        // Check if we left the function
        if (func_indent) |fi| {
            if (ws <= fi and trimmed.len > 0) {
                try emitPythonViolation(allocator, &violations, func_name, func_start, try types.usizeToU32(line_idx), complexity, cfg);
                func_indent = null;
                continue;
            }

            // Count branches
            for (&py_keywords) |kw| {
                if (std.mem.indexOf(u8, trimmed, kw) != null) {
                    complexity += 1;
                    break; // one per line max for keyword matches
                }
            }
        }
    }

    // Last function
    if (func_indent != null) {
        try emitPythonViolation(allocator, &violations, func_name, func_start, try types.usizeToU32(lines.len), complexity, cfg);
    }

    return violations.toOwnedSlice();
}

fn emitIfViolation(
    allocator: std.mem.Allocator,
    violations: *ViolationList,
    func: FuncInfo,
    end_line: u32,
    cfg: guardian_config.Config,
) !void {
    if (func.complexity > cfg.limits.cyclomatic_complexity_error) {
        try violations.append(.{
            .line = func.start_line + 1,
            .column = 0,
            .end_line = end_line,
            .rule = .cyclomatic_complexity,
            .severity = .@"error",
            .message = try std.fmt.allocPrint(
                allocator,
                "function '{s}' has cyclomatic complexity {d} (max {d})",
                .{ func.name, func.complexity, cfg.limits.cyclomatic_complexity_error },
            ),
            .message_owned = true,
        });
    } else if (func.complexity > cfg.limits.cyclomatic_complexity_warn) {
        try violations.append(.{
            .line = func.start_line + 1,
            .column = 0,
            .end_line = end_line,
            .rule = .cyclomatic_complexity,
            .severity = .warn,
            .message = try std.fmt.allocPrint(
                allocator,
                "function '{s}' has cyclomatic complexity {d} (recommended max {d})",
                .{ func.name, func.complexity, cfg.limits.cyclomatic_complexity_warn },
            ),
            .message_owned = true,
        });
    }
}

fn emitPythonViolation(
    allocator: std.mem.Allocator,
    violations: *ViolationList,
    name: []const u8,
    start: u32,
    end: u32,
    complexity: u32,
    cfg: guardian_config.Config,
) !void {
    if (complexity > cfg.limits.cyclomatic_complexity_error) {
        try violations.append(.{
            .line = start + 1,
            .column = 0,
            .end_line = end,
            .rule = .cyclomatic_complexity,
            .severity = .@"error",
            .message = try std.fmt.allocPrint(
                allocator,
                "function '{s}' has cyclomatic complexity {d} (max {d})",
                .{ name, complexity, cfg.limits.cyclomatic_complexity_error },
            ),
            .message_owned = true,
        });
    } else if (complexity > cfg.limits.cyclomatic_complexity_warn) {
        try violations.append(.{
            .line = start + 1,
            .column = 0,
            .end_line = end,
            .rule = .cyclomatic_complexity,
            .severity = .warn,
            .message = try std.fmt.allocPrint(
                allocator,
                "function '{s}' has cyclomatic complexity {d} (recommended max {d})",
                .{ name, complexity, cfg.limits.cyclomatic_complexity_warn },
            ),
            .message_owned = true,
        });
    }
}

fn isFunctionLine(trimmed: []const u8, lang: Language) bool {
    return switch (lang) {
        .go => std.mem.startsWith(u8, trimmed, "func "),
        .typescript => std.mem.startsWith(u8, trimmed, "function ") or
            std.mem.startsWith(u8, trimmed, "export function ") or
            std.mem.startsWith(u8, trimmed, "async function ") or
            std.mem.startsWith(u8, trimmed, "export async function ") or
            (std.mem.indexOf(u8, trimmed, "=>") != null and std.mem.indexOf(u8, trimmed, "const ") != null),
        .zig_lang => std.mem.startsWith(u8, trimmed, "fn ") or
            std.mem.startsWith(u8, trimmed, "pub fn ") or
            std.mem.startsWith(u8, trimmed, "export fn "),
        .python => unreachable,
    };
}

fn extractFuncName(trimmed: []const u8, lang: Language) []const u8 {
    return switch (lang) {
        .go => extractGoFuncName(trimmed),
        .typescript => extractNamedSymbol(trimmed, &[_][]const u8{
            "export async function ",
            "async function ",
            "export function ",
            "function ",
            "const ",
            "let ",
        }),
        .zig_lang => extractNamedSymbol(trimmed, &[_][]const u8{
            "pub fn ",
            "export fn ",
            "fn ",
        }),
        .python => unreachable,
    };
}

fn extractPythonFuncName(trimmed: []const u8) []const u8 {
    var s = trimmed;
    if (std.mem.startsWith(u8, s, "async def ")) {
        s = s["async def ".len..];
    } else if (std.mem.startsWith(u8, s, "def ")) {
        s = s["def ".len..];
    }
    var end: usize = 0;
    while (end < s.len and s[end] != '(') : (end += 1) {}
    return s[0..end];
}

// Tests
const testing = std.testing;

test "complexity: simple function passes" {
    const src =
        \\func simple() {
        \\    if x > 0 {
        \\        return x
        \\    }
        \\    return 0
        \\}
    ;
    const lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(lines);

    const v = try analyzeBraceComplexity(testing.allocator, lines, .go, .{});
    defer types.freeViolations(testing.allocator, v);
    try testing.expectEqual(@as(usize, 0), v.len);
}

test "complexity: high complexity triggers error" {
    const src =
        \\func complex() {
        \\    if a { }
        \\    if b { }
        \\    if c { }
        \\    if d { }
        \\    if e { }
        \\    if f { }
        \\    if g { }
        \\    if h { }
        \\    if i { }
        \\}
    ;
    const lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(lines);

    const v = try analyzeBraceComplexity(testing.allocator, lines, .go, .{});
    defer types.freeViolations(testing.allocator, v);
    try testing.expect(v.len > 0);
    try testing.expectEqual(Rule.cyclomatic_complexity, v[0].rule);
}

test "complexity: ignores template literal control-flow text" {
    const src =
        \\const tpl = `if broken { still string }`;
        \\function clean() {
        \\    return tpl.length;
        \\}
    ;
    const lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(lines);

    const masked_source = try types.maskSource(testing.allocator, src, .typescript);
    defer testing.allocator.free(masked_source);
    const masked_lines = try types.splitLines(testing.allocator, masked_source);
    defer testing.allocator.free(masked_lines);

    const v = try analyzeBraceComplexity(testing.allocator, masked_lines, .typescript, .{});
    defer types.freeViolations(testing.allocator, v);
    try testing.expectEqual(@as(usize, 0), v.len);
}

fn extractNamedSymbol(trimmed: []const u8, prefixes: []const []const u8) []const u8 {
    for (prefixes) |prefix| {
        if (!std.mem.startsWith(u8, trimmed, prefix)) {
            continue;
        }

        var search = trimmed[prefix.len..];
        if (std.mem.startsWith(u8, prefix, "const ") or std.mem.startsWith(u8, prefix, "let ")) {
            const eq_pos = std.mem.indexOf(u8, search, "=") orelse return "<anonymous>";
            search = std.mem.trim(u8, search[0..eq_pos], " \t");
        }

        return trimIdentifier(search);
    }

    return "<anonymous>";
}

fn extractGoFuncName(trimmed: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, trimmed, "func ")) {
        return "<anonymous>";
    }

    var search = std.mem.trimLeft(u8, trimmed["func ".len..], " \t");
    if (search.len == 0) {
        return "<anonymous>";
    }

    if (search[0] == '(') {
        const receiver_end = std.mem.indexOfScalar(u8, search, ')') orelse return "<anonymous>";
        search = std.mem.trimLeft(u8, search[receiver_end + 1 ..], " \t");
    }

    return trimIdentifier(search);
}

fn trimIdentifier(search: []const u8) []const u8 {
    var end: usize = 0;
    while (end < search.len and search[end] != '(' and search[end] != ' ' and search[end] != '<' and search[end] != '=') {
        end += 1;
    }
    if (end == 0) {
        return "<anonymous>";
    }
    return search[0..end];
}
