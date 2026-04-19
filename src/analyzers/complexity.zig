const std = @import("std");
const guardian_config = @import("../config.zig");
const test_config = @import("../test_config.zig");
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
    var in_block_comment = false;

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

        // Runs on masked input; strings and comments are already blanked.
        for (line, 0..) |ch, ci| {
            _ = ci;
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
            current_func.?.complexity += countBraceComplexityLine(trimmed, lang);
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
            complexity += countPythonComplexityLine(trimmed);
        }
    }

    // Last function
    if (func_indent != null) {
        try emitPythonViolation(allocator, &violations, func_name, func_start, try types.usizeToU32(lines.len), complexity, cfg);
    }

    return violations.toOwnedSlice();
}

fn countBraceComplexityLine(trimmed: []const u8, lang: Language) u32 {
    var count: u32 = 0;

    switch (lang) {
        .go => {
            count += countIfBranches(trimmed);
            count += countWord(trimmed, "case");
            count += countWord(trimmed, "for");
            count += countOperator(trimmed, "&&");
            count += countOperator(trimmed, "||");
        },
        .typescript => {
            count += countIfBranches(trimmed);
            count += countWord(trimmed, "case");
            count += countWord(trimmed, "for");
            count += countWord(trimmed, "while");
            count += countWord(trimmed, "catch");
            count += countOperator(trimmed, "&&");
            count += countOperator(trimmed, "||");
            count += countTernaryOperators(trimmed);
        },
        .zig_lang => {
            count += countIfBranches(trimmed);
            count += countWord(trimmed, "for");
            count += countWord(trimmed, "while");
            count += countWord(trimmed, "switch");
            count += countWord(trimmed, "catch");
            count += countWord(trimmed, "orelse");
        },
        .python => unreachable,
    }

    return count;
}

fn countIfBranches(line: []const u8) u32 {
    var count: u32 = 0;
    var idx: usize = 0;

    while (idx < line.len) : (idx += 1) {
        if (idx + "else if".len <= line.len and
            std.mem.eql(u8, line[idx .. idx + "else if".len], "else if") and
            hasWordBoundary(line, idx, "else if".len))
        {
            count += 1;
            idx += "else if".len - 1;
            continue;
        }

        if (idx + "if".len <= line.len and
            std.mem.eql(u8, line[idx .. idx + "if".len], "if") and
            hasWordBoundary(line, idx, "if".len))
        {
            count += 1;
            idx += "if".len - 1;
        }
    }

    return count;
}

fn countPythonComplexityLine(trimmed: []const u8) u32 {
    return countWord(trimmed, "elif") +
        countWord(trimmed, "if") +
        countWord(trimmed, "for") +
        countWord(trimmed, "while") +
        countWord(trimmed, "except") +
        countWord(trimmed, "and") +
        countWord(trimmed, "or");
}

fn countWord(line: []const u8, word: []const u8) u32 {
    var count: u32 = 0;
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, line, search_pos, word)) |pos| {
        if (hasWordBoundary(line, pos, word.len)) {
            count += 1;
        }
        search_pos = pos + word.len;
    }
    return count;
}

fn hasWordBoundary(line: []const u8, start: usize, len: usize) bool {
    if (start > 0 and isIdentifierChar(line[start - 1])) {
        return false;
    }

    const end = start + len;
    if (end < line.len and isIdentifierChar(line[end])) {
        return false;
    }

    return true;
}

fn countOperator(line: []const u8, op: []const u8) u32 {
    var count: u32 = 0;
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, line, search_pos, op)) |pos| {
        count += 1;
        search_pos = pos + op.len;
    }
    return count;
}

fn countTernaryOperators(line: []const u8) u32 {
    var count: u32 = 0;
    for (line, 0..) |ch, idx| {
        if (ch != '?') {
            continue;
        }
        if (idx + 1 < line.len and (line[idx + 1] == '?' or line[idx + 1] == '.')) {
            continue;
        }
        if (idx > 0 and line[idx - 1] == '?') {
            continue;
        }
        count += 1;
    }
    return count;
}

fn isIdentifierChar(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or std.ascii.isDigit(ch) or ch == '_';
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
        .typescript => looksLikeTsFunctionLine(trimmed),
        .zig_lang => std.mem.startsWith(u8, trimmed, "fn ") or
            std.mem.startsWith(u8, trimmed, "pub fn ") or
            std.mem.startsWith(u8, trimmed, "export fn ") or
            std.mem.startsWith(u8, trimmed, "test "),
        .python => unreachable,
    };
}

fn extractFuncName(trimmed: []const u8, lang: Language) []const u8 {
    return switch (lang) {
        .go => extractGoFuncName(trimmed),
        .typescript => extractTsFunctionName(trimmed),
        .zig_lang => extractNamedSymbol(trimmed, &[_][]const u8{
            "pub fn ",
            "export fn ",
            "fn ",
            "test ",
        }),
        .python => unreachable,
    };
}

fn looksLikeTsFunctionLine(trimmed: []const u8) bool {
    if (startsWithAny(trimmed, &[_][]const u8{
        "function ",
        "export function ",
        "async function ",
        "export async function ",
        "export default function ",
        "export default async function ",
    })) {
        return true;
    }

    if (std.mem.indexOf(u8, trimmed, "=>") != null and startsWithAny(trimmed, &[_][]const u8{
        "const ",
        "let ",
        "var ",
        "export const ",
        "export let ",
        "export var ",
    })) {
        return true;
    }

    return false;
}

fn extractTsFunctionName(trimmed: []const u8) []const u8 {
    return extractNamedSymbol(trimmed, &[_][]const u8{
        "export default async function ",
        "export default function ",
        "export async function ",
        "async function ",
        "export function ",
        "function ",
        "export const ",
        "export let ",
        "export var ",
        "const ",
        "let ",
        "var ",
    });
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

    var loaded = try test_config.loadDefault(testing.allocator);
    defer loaded.deinit();

    const v = try analyzeBraceComplexity(testing.allocator, lines, .go, loaded.value);
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

    var loaded = try test_config.loadDefault(testing.allocator);
    defer loaded.deinit();

    const v = try analyzeBraceComplexity(testing.allocator, lines, .go, loaded.value);
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

    var loaded = try test_config.loadDefault(testing.allocator);
    defer loaded.deinit();

    const v = try analyzeBraceComplexity(testing.allocator, masked_lines, .typescript, loaded.value);
    defer types.freeViolations(testing.allocator, v);
    try testing.expectEqual(@as(usize, 0), v.len);
}

test "complexity: Python counts each branch keyword on a line" {
    const src =
        \\def score(flag_a, flag_b, flag_c):
        \\    if flag_a and flag_b or flag_c:
        \\        return 1
        \\    return 0
    ;
    const lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(lines);

    var loaded = try test_config.loadDefault(testing.allocator);
    defer loaded.deinit();

    var cfg = loaded.value;
    cfg.limits.cyclomatic_complexity_warn = 3;
    cfg.limits.cyclomatic_complexity_error = 99;

    const v = try analyzePythonComplexity(testing.allocator, lines, cfg);
    defer types.freeViolations(testing.allocator, v);
    try testing.expect(v.len > 0);
}

test "complexity: else-if chains are not double counted" {
    const src =
        \\func branch(a int) int {
        \\    if a == 0 {
        \\        return 0
        \\    } else if a == 1 {
        \\        return 1
        \\    } else if a == 2 {
        \\        return 2
        \\    }
        \\    return 3
        \\}
    ;
    const lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(lines);

    var loaded = try test_config.loadDefault(testing.allocator);
    defer loaded.deinit();

    var cfg = loaded.value;
    cfg.limits.cyclomatic_complexity_warn = 3;
    cfg.limits.cyclomatic_complexity_error = 99;

    const v = try analyzeBraceComplexity(testing.allocator, lines, .go, cfg);
    defer types.freeViolations(testing.allocator, v);
    try testing.expect(v.len > 0);
    try testing.expect(std.mem.indexOf(u8, v[0].message, "complexity 4") != null);
}

fn extractNamedSymbol(trimmed: []const u8, prefixes: []const []const u8) []const u8 {
    for (prefixes) |prefix| {
        if (!std.mem.startsWith(u8, trimmed, prefix)) {
            continue;
        }

        const after = trimmed[prefix.len..];
        if (std.mem.eql(u8, prefix, "test ")) {
            return extractQuotedSymbol(after, "<test>");
        }

        const search = if (isBindingPrefix(prefix)) extractBindingTarget(after, "<anonymous>") else after;

        return trimIdentifier(search);
    }

    return "<anonymous>";
}

fn extractQuotedSymbol(after: []const u8, fallback: []const u8) []const u8 {
    if (after.len < 2 or after[0] != '"') {
        return fallback;
    }
    const end_quote = std.mem.indexOfScalarPos(u8, after, 1, '"') orelse return fallback;
    return after[1..end_quote];
}

fn isBindingPrefix(prefix: []const u8) bool {
    return std.mem.endsWith(u8, prefix, "const ") or
        std.mem.endsWith(u8, prefix, "let ") or
        std.mem.endsWith(u8, prefix, "var ");
}

fn extractBindingTarget(after: []const u8, fallback: []const u8) []const u8 {
    const eq_pos = std.mem.indexOf(u8, after, "=") orelse return fallback;
    return std.mem.trim(u8, after[0..eq_pos], " \t");
}

fn startsWithAny(text: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) {
            return true;
        }
    }
    return false;
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
