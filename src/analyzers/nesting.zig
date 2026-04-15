const std = @import("std");
const guardian_config = @import("../config.zig");
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

    var brace_depth: i32 = 0;
    var func_base_depth: i32 = 0;
    var in_function = false;
    var func_start_line: u32 = 0;
    var max_seen: u32 = 0;
    var max_seen_line: u32 = 0;
    var in_string = false;
    var in_line_comment = false;
    var in_block_comment = false;

    for (lines, 0..) |line, line_idx| {
        in_line_comment = false;
        var i: usize = 0;

        while (i < line.len) : (i += 1) {
            const ch = line[i];

            // Track block comments
            if (in_block_comment) {
                if (ch == '*' and i + 1 < line.len and line[i + 1] == '/') {
                    in_block_comment = false;
                    i += 1;
                }
                continue;
            }

            // Track line comments
            if (!in_string and ch == '/' and i + 1 < line.len) {
                if (line[i + 1] == '/') {
                    in_line_comment = true;
                    break;
                }
                if (line[i + 1] == '*') {
                    in_block_comment = true;
                    i += 1;
                    continue;
                }
            }

            if (in_line_comment) break;

            // Track strings (basic — doesn't handle raw strings)
            if (ch == '"' and (i == 0 or line[i - 1] != '\\')) {
                in_string = !in_string;
                continue;
            }
            if (in_string) continue;

            // Track braces
            if (ch == '{') {
                brace_depth += 1;

                // Detect function entry: look back for func/fn/function keyword
                if (!in_function) {
                    const trimmed = std.mem.trim(u8, line[0..i], " \t");
                    if (looksLikeFunctionDef(trimmed, lang)) {
                        in_function = true;
                        func_base_depth = brace_depth;
                        func_start_line = try types.usizeToU32(line_idx);
                        max_seen = 0;
                        max_seen_line = try types.usizeToU32(line_idx);
                    }
                }

                if (in_function) {
                    const relative = try types.i32ToU32(@max(0, brace_depth - func_base_depth));
                    if (relative > max_seen) {
                        max_seen = relative;
                        max_seen_line = try types.usizeToU32(line_idx);
                    }
                }
            } else if (ch == '}') {
                if (in_function and brace_depth == func_base_depth) {
                    // Function closed — report if max exceeded
                    if (max_seen > cfg.limits.max_nesting) {
                        try violations.append(.{
                            .line = max_seen_line + 1,
                            .column = 0,
                            .end_line = try types.indexToLineNumber(line_idx),
                            .rule = .nesting_depth,
                            .severity = .@"error",
                            .message = try std.fmt.allocPrint(
                                allocator,
                                "nesting depth {d} exceeds maximum of {d} (function at line {d})",
                                .{ max_seen, cfg.limits.max_nesting, func_start_line + 1 },
                            ),
                            .message_owned = true,
                        });
                    }
                    in_function = false;
                }
                brace_depth -= 1;
                if (brace_depth < 0) brace_depth = 0;
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

                const relative = try types.usizeToU32(indent_stack.items.len - 1);
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

fn looksLikeFunctionDef(before_brace: []const u8, lang: Language) bool {
    const trimmed = std.mem.trim(u8, before_brace, " \t");

    return switch (lang) {
        .go => std.mem.startsWith(u8, trimmed, "func "),
        .typescript => std.mem.startsWith(u8, trimmed, "function ") or
            std.mem.startsWith(u8, trimmed, "export function ") or
            std.mem.startsWith(u8, trimmed, "async function ") or
            std.mem.startsWith(u8, trimmed, "export async function ") or
            (std.mem.indexOf(u8, trimmed, "=>") != null and std.mem.indexOf(u8, trimmed, "=") != null),
        .zig_lang => std.mem.startsWith(u8, trimmed, "fn ") or
            std.mem.startsWith(u8, trimmed, "pub fn ") or
            std.mem.startsWith(u8, trimmed, "export fn "),
        .python => false,
    };
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

    const v = try analyzeBraceNesting(testing.allocator, lines, .go, .{});
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

    const v = try analyzeBraceNesting(testing.allocator, lines, .go, .{});
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

    const v = try analyzePythonNesting(testing.allocator, lines, .{});
    defer types.freeViolations(testing.allocator, v);
    try testing.expectEqual(@as(usize, 0), v.len);
}
