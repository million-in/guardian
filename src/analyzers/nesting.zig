const std = @import("std");
const guardian_config = @import("../config.zig");
const test_config = @import("../test_config.zig");
const types = @import("../types.zig");

const Language = types.Language;
const Violation = types.Violation;
const Rule = types.Rule;
const ViolationList = std.array_list.Managed(Violation);

/// Analyze nesting depth for brace-delimited languages (Go, TS, Zig).
/// Tracks depth per function. Reports when any block exceeds max_nesting.
pub fn analyzeBraceNesting(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    lang: Language,
    cfg: guardian_config.Config,
) ![]Violation {
    var violations = ViolationList.init(allocator);

    var brace_stack = std.array_list.Managed(BraceKind).init(allocator);
    defer brace_stack.deinit();

    var function_stack = std.array_list.Managed(FunctionFrame).init(allocator);
    defer function_stack.deinit();

    var control_depth: u32 = 0;

    for (lines, 0..) |line, line_idx| {
        // Runs on masked input; strings and comments are already blanked.
        for (line, 0..) |ch, idx| {
            switch (ch) {
                '{' => {
                    const before_brace = std.mem.trim(u8, line[0..idx], " \t");
                    const kind = classifyBraceOpen(before_brace, lang);
                    try brace_stack.append(kind);

                    switch (kind) {
                        .function_block => {
                            try function_stack.append(.{
                                .func_start_line = try types.usizeToU32(line_idx),
                                .max_seen = 0,
                                .max_seen_line = try types.usizeToU32(line_idx),
                                .base_control_depth = control_depth,
                            });
                        },
                        .control_block => {
                            control_depth += 1;
                            if (function_stack.items.len > 0) {
                                const current = &function_stack.items[function_stack.items.len - 1];
                                const relative = control_depth - current.base_control_depth;
                                if (relative > current.max_seen) {
                                    current.max_seen = relative;
                                    current.max_seen_line = try types.usizeToU32(line_idx);
                                }
                            }
                        },
                        .literal_block => {},
                    }
                },
                '}' => {
                    if (brace_stack.items.len == 0) {
                        continue;
                    }

                    const kind = brace_stack.pop().?;
                    switch (kind) {
                        .function_block => {
                            if (function_stack.items.len == 0) {
                                continue;
                            }
                            const frame = function_stack.pop().?;
                            try emitBraceViolation(
                                allocator,
                                &violations,
                                frame.func_start_line,
                                frame.max_seen_line,
                                frame.max_seen,
                                try types.indexToLineNumber(line_idx),
                                cfg,
                            );
                        },
                        .control_block => {
                            if (control_depth > 0) {
                                control_depth -= 1;
                            }
                        },
                        .literal_block => {},
                    }
                },
                else => {},
            }
        }
    }

    return violations.toOwnedSlice();
}

/// Analyze nesting depth for Python (indent-based).
/// Uses indent level changes to track nesting within functions.
pub fn analyzePythonNesting(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    cfg: guardian_config.Config,
) ![]Violation {
    var violations = ViolationList.init(allocator);
    var indent_stack = std.array_list.Managed(u32).init(allocator);
    defer indent_stack.deinit();

    var func_indent: ?u32 = null;
    var func_start_line: u32 = 0;
    var max_depth: u32 = 0;
    var max_depth_line: u32 = 0;

    for (lines, 0..) |line, line_idx| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0) continue;

        const ws = types.leadingWhitespace(line);

        // Detect function/method def
        if (std.mem.startsWith(u8, trimmed, "def ") or
            std.mem.startsWith(u8, trimmed, "async def "))
        {
            try emitPythonViolation(allocator, &violations, func_start_line, max_depth_line, max_depth, try types.usizeToU32(line_idx), cfg);
            func_indent = ws;
            func_start_line = try types.usizeToU32(line_idx);
            max_depth = 0;
            max_depth_line = try types.usizeToU32(line_idx);
            try indent_stack.resize(0);
            try indent_stack.append(ws);
            continue;
        }

        if (func_indent) |fi| {
            if (ws <= fi) {
                // Exited function
                try emitPythonViolation(allocator, &violations, func_start_line, max_depth_line, max_depth, try types.usizeToU32(line_idx), cfg);
                func_indent = null;
                try indent_stack.resize(0);
            } else {
                while (indent_stack.items.len > 0 and ws < indent_stack.items[indent_stack.items.len - 1]) {
                    _ = indent_stack.pop();
                }

                if (indent_stack.items.len == 0) {
                    try indent_stack.append(fi);
                }

                if (ws > indent_stack.items[indent_stack.items.len - 1]) {
                    try indent_stack.append(ws);
                }

                const relative = if (indent_stack.items.len >= 2)
                    try types.usizeToU32(indent_stack.items.len - 2)
                else
                    0;
                if (relative > max_depth) {
                    max_depth = relative;
                    max_depth_line = try types.usizeToU32(line_idx);
                }
            }
        }
    }

    // Handle last function in file
    if (func_indent != null) {
        try emitPythonViolation(allocator, &violations, func_start_line, max_depth_line, max_depth, try types.usizeToU32(lines.len), cfg);
    }

    return violations.toOwnedSlice();
}

fn emitPythonViolation(
    allocator: std.mem.Allocator,
    violations: *ViolationList,
    func_start_line: u32,
    max_depth_line: u32,
    max_depth: u32,
    end_line: u32,
    cfg: guardian_config.Config,
) !void {
    if (max_depth <= cfg.limits.max_nesting) {
        return;
    }

    try violations.append(.{
        .line = max_depth_line + 1,
        .column = 0,
        .end_line = end_line,
        .rule = .nesting_depth,
        .severity = .@"error",
        .message = try std.fmt.allocPrint(
            allocator,
            "nesting depth {d} exceeds maximum of {d} (function at line {d})",
            .{ max_depth, cfg.limits.max_nesting, func_start_line + 1 },
        ),
        .message_owned = true,
    });
}

const BraceKind = enum {
    function_block,
    control_block,
    literal_block,
};

const FunctionFrame = struct {
    func_start_line: u32,
    max_seen: u32,
    max_seen_line: u32,
    base_control_depth: u32,
};

fn emitBraceViolation(
    allocator: std.mem.Allocator,
    violations: *ViolationList,
    func_start_line: u32,
    max_depth_line: u32,
    max_depth: u32,
    end_line: u32,
    cfg: guardian_config.Config,
) !void {
    if (max_depth <= cfg.limits.max_nesting) {
        return;
    }

    try violations.append(.{
        .line = max_depth_line + 1,
        .column = 0,
        .end_line = end_line,
        .rule = .nesting_depth,
        .severity = .@"error",
        .message = try std.fmt.allocPrint(
            allocator,
            "nesting depth {d} exceeds maximum of {d} (function at line {d})",
            .{ max_depth, cfg.limits.max_nesting, func_start_line + 1 },
        ),
        .message_owned = true,
    });
}

fn classifyBraceOpen(before_brace: []const u8, lang: Language) BraceKind {
    if (looksLikeFunctionDef(before_brace, lang)) {
        return .function_block;
    }
    if (looksLikeControlBlock(before_brace, lang)) {
        return .control_block;
    }
    return .literal_block;
}

fn looksLikeControlBlock(before_brace: []const u8, lang: Language) bool {
    return switch (lang) {
        .go => startsWithAny(before_brace, &[_][]const u8{
            "if ",
            "else if ",
            "else",
            "for ",
            "switch ",
            "select",
        }),
        .typescript => startsWithAny(before_brace, &[_][]const u8{
            "if ",
            "else if ",
            "else",
            "for ",
            "while ",
            "switch ",
            "catch ",
            "try",
            "finally",
            "do",
        }),
        .zig_lang => startsWithAny(before_brace, &[_][]const u8{
            "if ",
            "else if ",
            "else",
            "for ",
            "while ",
            "switch ",
            "catch ",
            "orelse",
        }),
        .python => false,
    };
}

fn looksLikeFunctionDef(before_brace: []const u8, lang: Language) bool {
    const trimmed = std.mem.trim(u8, before_brace, " \t");

    return switch (lang) {
        .go => std.mem.startsWith(u8, trimmed, "func "),
        .typescript => looksLikeTsFunctionBeforeBrace(trimmed),
        .zig_lang => std.mem.startsWith(u8, trimmed, "fn ") or
            std.mem.startsWith(u8, trimmed, "pub fn ") or
            std.mem.startsWith(u8, trimmed, "export fn ") or
            std.mem.startsWith(u8, trimmed, "test "),
        .python => false,
    };
}

fn looksLikeTsFunctionBeforeBrace(trimmed: []const u8) bool {
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

    if (std.mem.indexOf(u8, trimmed, "=>") != null) {
        return true;
    }

    if (looksLikeControlBlock(trimmed, .typescript)) {
        return false;
    }

    return std.mem.indexOfScalar(u8, trimmed, '(') != null and
        !startsWithAny(trimmed, &[_][]const u8{
            "return ",
            "const ",
            "let ",
            "var ",
            "export ",
        });
}

fn startsWithAny(text: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) {
            return true;
        }
    }
    return false;
}

// Tests
const testing = std.testing;

test "brace nesting: clean function passes" {
    const src =
        \\func process(items []int) {
        \\    for _, item := range items {
        \\        if item > 0 {
        \\            handle(item)
        \\        }
        \\    }
        \\}
    ;
    const lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(lines);

    var loaded = try test_config.loadDefault(testing.allocator);
    defer loaded.deinit();

    const v = try analyzeBraceNesting(testing.allocator, lines, .go, loaded.value);
    defer types.freeViolations(testing.allocator, v);
    try testing.expectEqual(@as(usize, 0), v.len);
}

test "brace nesting: depth 4 triggers violation" {
    const src =
        \\func bad() {
        \\    if true {
        \\        if true {
        \\            if true {
        \\                if true {
        \\                    deep()
        \\                }
        \\            }
        \\        }
        \\    }
        \\}
    ;
    const lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(lines);

    var loaded = try test_config.loadDefault(testing.allocator);
    defer loaded.deinit();

    const v = try analyzeBraceNesting(testing.allocator, lines, .go, loaded.value);
    defer types.freeViolations(testing.allocator, v);
    try testing.expect(v.len > 0);
    try testing.expectEqual(Rule.nesting_depth, v[0].rule);
}

test "python nesting: irregular indentation tracks logical depth" {
    const src =
        \\def clean():
        \\  if ready:
        \\      if enabled:
        \\          run()
    ;
    const lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(lines);

    var loaded = try test_config.loadDefault(testing.allocator);
    defer loaded.deinit();

    const v = try analyzePythonNesting(testing.allocator, lines, loaded.value);
    defer types.freeViolations(testing.allocator, v);
    try testing.expectEqual(@as(usize, 0), v.len);
}

test "brace nesting: object literals do not count as control-flow nesting" {
    const src =
        \\export function build(): Config {
        \\    return {
        \\        inner: {
        \\            deep: {
        \\                value: 42,
        \\            },
        \\        },
        \\    };
        \\}
    ;
    const lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(lines);

    var loaded = try test_config.loadDefault(testing.allocator);
    defer loaded.deinit();

    const v = try analyzeBraceNesting(testing.allocator, lines, .typescript, loaded.value);
    defer types.freeViolations(testing.allocator, v);
    try testing.expectEqual(@as(usize, 0), v.len);
}

test "brace nesting: TypeScript arrow functions are tracked independently" {
    const src =
        \\export const build = () => {
        \\    if (ready) {
        \\        return list.filter((value) => {
        \\            if (value.ok) {
        \\                return true;
        \\            }
        \\            return false;
        \\        });
        \\    }
        \\    return [];
        \\};
    ;
    const lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(lines);

    var loaded = try test_config.loadDefault(testing.allocator);
    defer loaded.deinit();

    const v = try analyzeBraceNesting(testing.allocator, lines, .typescript, loaded.value);
    defer types.freeViolations(testing.allocator, v);
    try testing.expectEqual(@as(usize, 0), v.len);
}

test "brace nesting: Zig test blocks are analyzed as functions" {
    const src =
        \\test "deep" {
        \\    if (a) {
        \\        if (b) {
        \\            if (c) {
        \\                if (d) {
        \\                    return;
        \\                }
        \\            }
        \\        }
        \\    }
        \\}
    ;
    const lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(lines);

    var loaded = try test_config.loadDefault(testing.allocator);
    defer loaded.deinit();

    const v = try analyzeBraceNesting(testing.allocator, lines, .zig_lang, loaded.value);
    defer types.freeViolations(testing.allocator, v);
    try testing.expect(v.len > 0);
}
