const std = @import("std");
const guardian_config = @import("../config.zig");
const test_config = @import("../test_config.zig");
const types = @import("../types.zig");

const Violation = types.Violation;
const Language = types.Language;
const Rule = types.Rule;
const ViolationList = std.array_list.Managed(Violation);

pub fn analyzeCohesion(
    allocator: std.mem.Allocator,
    raw_lines: []const []const u8,
    masked_lines: []const []const u8,
    lang: Language,
    cfg: guardian_config.Config,
) ![]Violation {
    var violations = ViolationList.init(allocator);

    var import_count: u32 = 0;
    var function_count: u32 = 0;
    var in_go_import_block = false;

    var func_start: ?u32 = null;
    var func_name: []const u8 = "";
    var brace_depth: i32 = 0;
    var func_base: i32 = 0;

    for (masked_lines, 0..) |line, line_idx| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        const raw_trimmed = if (line_idx < raw_lines.len)
            std.mem.trimLeft(u8, raw_lines[line_idx], " \t")
        else
            trimmed;

        if (lang == .go) {
            if (in_go_import_block) {
                if (raw_trimmed.len == 0) {
                    if (trimmed.len == 0) continue;
                } else if (std.mem.eql(u8, raw_trimmed, ")")) {
                    in_go_import_block = false;
                } else {
                    import_count += 1;
                    if (trimmed.len == 0) continue;
                }
            } else if (std.mem.eql(u8, raw_trimmed, "import (")) {
                in_go_import_block = true;
            } else if (std.mem.startsWith(u8, raw_trimmed, "import ")) {
                import_count += 1;
            }
        } else if (raw_trimmed.len > 0 and isImportLine(raw_trimmed, lang)) {
            import_count += 1;
        }

        if (trimmed.len == 0) continue;

        if (lang == .python) {
            const is_def = std.mem.startsWith(u8, trimmed, "def ") or
                std.mem.startsWith(u8, trimmed, "async def ");
            if (is_def) {
                if (func_start) |fs| {
                    const end_line = try types.usizeToU32(line_idx);
                    const length = end_line - fs;
                    if (length > cfg.limits.max_function_lines) {
                        try appendFunctionLengthViolation(allocator, &violations, fs + 1, end_line, func_name, length, cfg);
                    }
                }
                func_start = try types.usizeToU32(line_idx);
                func_name = extractName(trimmed, lang);
                function_count += 1;
            }
            continue;
        }

        const is_func = isFuncDef(trimmed, lang);
        if (is_func) {
            function_count += 1;
        }

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
                            try appendFunctionLengthViolation(allocator, &violations, fs + 1, end_line, func_name, length, cfg);
                        }
                        func_start = null;
                    }
                }
                brace_depth -= 1;
                if (brace_depth < 0) brace_depth = 0;
            }
        }
    }

    if (lang == .python) {
        if (func_start) |fs| {
            const end_line = try types.usizeToU32(masked_lines.len);
            const length = end_line - fs;
            if (length > cfg.limits.max_function_lines) {
                try appendFunctionLengthViolation(allocator, &violations, fs + 1, end_line, func_name, length, cfg);
            }
        }
    }

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
            .end_line = try types.usizeToU32(masked_lines.len),
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

fn appendFunctionLengthViolation(
    allocator: std.mem.Allocator,
    violations: *ViolationList,
    start_line: u32,
    end_line: u32,
    func_name: []const u8,
    length: u32,
    cfg: guardian_config.Config,
) !void {
    try violations.append(.{
        .line = start_line,
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

fn isImportLine(trimmed: []const u8, lang: Language) bool {
    return switch (lang) {
        .go => std.mem.startsWith(u8, trimmed, "import "),
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
        .typescript => looksLikeTsFunctionDecl(trimmed),
        .zig_lang => std.mem.startsWith(u8, trimmed, "fn ") or
            std.mem.startsWith(u8, trimmed, "pub fn ") or
            std.mem.startsWith(u8, trimmed, "export fn ") or
            std.mem.startsWith(u8, trimmed, "test "),
        .python => std.mem.startsWith(u8, trimmed, "def ") or
            std.mem.startsWith(u8, trimmed, "async def "),
    };
}

fn extractName(trimmed: []const u8, lang: Language) []const u8 {
    return switch (lang) {
        .go => extractGoFuncName(trimmed),
        .typescript => extractTsFunctionName(trimmed),
        .zig_lang => extractNamedSymbol(trimmed, &[_][]const u8{
            "pub fn ",
            "export fn ",
            "fn ",
            "test ",
        }),
        .python => extractNamedSymbol(trimmed, &[_][]const u8{
            "async def ",
            "def ",
        }),
    };
}

fn extractTsFunctionName(trimmed: []const u8) []const u8 {
    const named = extractNamedSymbol(trimmed, &[_][]const u8{
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
    if (!std.mem.eql(u8, named, "<unknown>")) {
        return named;
    }

    if (looksLikeTsMethodDecl(trimmed)) {
        const method = stripTsMethodModifiers(trimmed);
        return trimIdentifier(method);
    }

    return "<unknown>";
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

        const search = if (isBindingPrefix(prefix)) extractBindingTarget(after, "<unknown>") else after;

        const candidate = trimIdentifier(search);
        if (!std.mem.eql(u8, candidate, "<unknown>")) {
            return candidate;
        }
    }

    return "<unknown>";
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

    return trimIdentifier(after);
}

fn trimIdentifier(search: []const u8) []const u8 {
    var end: usize = 0;
    while (end < search.len and
        search[end] != '(' and
        search[end] != ' ' and
        search[end] != '<' and
        search[end] != '=' and
        search[end] != '?' and
        search[end] != ':')
    {
        end += 1;
    }
    if (end == 0) {
        return "<unknown>";
    }
    return search[0..end];
}

fn looksLikeTsFunctionDecl(trimmed: []const u8) bool {
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

    if (looksLikeTsArrowDeclaration(trimmed)) {
        return true;
    }

    return looksLikeTsMethodDecl(trimmed);
}

fn looksLikeTsArrowDeclaration(trimmed: []const u8) bool {
    if (std.mem.indexOf(u8, trimmed, "=>") == null) {
        return false;
    }
    return startsWithAny(trimmed, &[_][]const u8{
        "const ",
        "let ",
        "var ",
        "export const ",
        "export let ",
        "export var ",
        "public ",
        "private ",
        "protected ",
        "static ",
        "readonly ",
        "async ",
    });
}

fn looksLikeTsMethodDecl(trimmed: []const u8) bool {
    if (startsWithAny(trimmed, &[_][]const u8{
        "if ",
        "else",
        "for ",
        "while ",
        "switch ",
        "catch ",
        "try",
        "finally",
        "return ",
        "const ",
        "let ",
        "var ",
        "export ",
    })) {
        return false;
    }
    return std.mem.indexOfScalar(u8, trimmed, '(') != null and
        std.mem.indexOfScalar(u8, trimmed, '{') != null;
}

fn stripTsMethodModifiers(trimmed: []const u8) []const u8 {
    var text = trimmed;
    var changed = true;
    while (changed) {
        changed = false;
        inline for (&[_][]const u8{
            "public ",
            "private ",
            "protected ",
            "static ",
            "readonly ",
            "async ",
            "get ",
            "set ",
        }) |prefix| {
            if (std.mem.startsWith(u8, text, prefix)) {
                text = std.mem.trimLeft(u8, text[prefix.len..], " \t");
                changed = true;
            }
        }
    }
    if (text.len > 0 and text[0] == '#') {
        return text[1..];
    }
    return text;
}

fn startsWithAny(text: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) {
            return true;
        }
    }
    return false;
}

const testing = std.testing;

test "cohesion: Go import blocks count each entry" {
    const src =
        \\package sample
        \\
        \\import (
        \\    "fmt"
        \\    "context"
        \\    "net/http"
        \\)
        \\
        \\func run() {
        \\    fmt.Println(context.Background(), http.MethodGet)
        \\}
    ;
    const raw_lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(raw_lines);
    const masked = try types.maskSource(testing.allocator, src, .go);
    defer testing.allocator.free(masked);
    const masked_lines = try types.splitLines(testing.allocator, masked);
    defer testing.allocator.free(masked_lines);

    var loaded = try test_config.loadDefault(testing.allocator);
    defer loaded.deinit();

    var cfg = loaded.value;
    cfg.limits.max_imports = 2;

    const violations = try analyzeCohesion(testing.allocator, raw_lines, masked_lines, .go, cfg);
    defer types.freeViolations(testing.allocator, violations);

    try testing.expect(containsRule(violations, .high_coupling));
}

test "cohesion: TypeScript counts arrow declarations and export default functions" {
    const src =
        \\export default function main() {
        \\    return 1;
        \\}
        \\
        \\const build = () => {
        \\    return 2;
        \\};
    ;
    const raw_lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(raw_lines);
    const masked = try types.maskSource(testing.allocator, src, .typescript);
    defer testing.allocator.free(masked);
    const masked_lines = try types.splitLines(testing.allocator, masked);
    defer testing.allocator.free(masked_lines);

    var loaded = try test_config.loadDefault(testing.allocator);
    defer loaded.deinit();

    var cfg = loaded.value;
    cfg.limits.max_functions_per_file = 1;

    const violations = try analyzeCohesion(testing.allocator, raw_lines, masked_lines, .typescript, cfg);
    defer types.freeViolations(testing.allocator, violations);

    try testing.expect(containsRule(violations, .low_cohesion));
}

fn containsRule(violations: []const Violation, rule: Rule) bool {
    for (violations) |violation| {
        if (violation.rule == rule) {
            return true;
        }
    }
    return false;
}
