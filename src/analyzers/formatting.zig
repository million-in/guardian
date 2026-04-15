const std = @import("std");
const guardian_config = @import("../config.zig");
const types = @import("../types.zig");

const Violation = types.Violation;
const Language = types.Language;
const Rule = types.Rule;
const ViolationList = std.array_list.Managed(Violation);

pub fn analyzeFormatting(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    lang: Language,
    cfg: guardian_config.Config,
) ![]Violation {
    var violations = ViolationList.init(allocator);

    var tab_lines: u32 = 0;
    var space_lines: u32 = 0;
    var trailing_ws_count: u32 = 0;
    var first_trailing_ws: u32 = 0;
    var indent_widths = [_]u32{0} ** 16; // histogram of indent widths

    for (lines, 0..) |line, line_idx| {
        if (line.len == 0) continue;

        // ── Line length ──
        if (line.len > cfg.limits.max_line_length) {
            const line_number = try types.indexToLineNumber(line_idx);
            try violations.append(.{
                .line = line_number,
                .column = cfg.limits.max_line_length,
                .end_line = line_number,
                .rule = .line_too_long,
                .severity = .warn,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "line is {d} chars (max {d})",
                    .{ line.len, cfg.limits.max_line_length },
                ),
                .message_owned = true,
            });
        }

        // ── Trailing whitespace ──
        const trimmed = types.trimRight(line);
        if (trimmed.len < line.len and trimmed.len > 0) {
            trailing_ws_count += 1;
            if (trailing_ws_count == 1) {
                first_trailing_ws = try types.indexToLineNumber(line_idx);
            }
        }

        // ── Indent analysis ──
        const ws = types.leadingWhitespace(line);
        if (ws == 0) continue;

        // Check for mixed tabs and spaces in same line
        var has_tab = false;
        var has_space = false;
        for (line[0..ws]) |ch| {
            if (ch == '\t') has_tab = true;
            if (ch == ' ') has_space = true;
        }

        if (has_tab and has_space) {
            const line_number = try types.indexToLineNumber(line_idx);
            try violations.append(.{
                .line = line_number,
                .column = 0,
                .end_line = line_number,
                .rule = .mixed_indent,
                .severity = .@"error",
                .message = "mixed tabs and spaces in indentation",
            });
        }

        if (has_tab) tab_lines += 1;
        if (has_space and !has_tab) {
            space_lines += 1;
            if (ws < indent_widths.len) {
                indent_widths[ws] += 1;
            }
        }
    }

    // ── File-level: mixed indent style ──
    if (tab_lines > 0 and space_lines > 0) {
        // Go uses tabs, others use spaces. Flag mismatch.
        const expected_tabs = (lang == .go);
        if (expected_tabs and space_lines > tab_lines / 4) {
            try violations.append(.{
                .line = 1,
                .column = 0,
                .end_line = try types.usizeToU32(lines.len),
                .rule = .inconsistent_indent,
                .severity = .@"error",
                .message = "Go files should use tabs — found significant space-indented lines",
            });
        } else if (!expected_tabs and tab_lines > space_lines / 4) {
            try violations.append(.{
                .line = 1,
                .column = 0,
                .end_line = try types.usizeToU32(lines.len),
                .rule = .inconsistent_indent,
                .severity = .@"error",
                .message = try std.fmt.allocPrint(
                    allocator,
                    "{s} files should use spaces — found significant tab-indented lines",
                    .{@tagName(lang)},
                ),
                .message_owned = true,
            });
        }
    }

    // ── Trailing whitespace summary ──
    if (trailing_ws_count > 0) {
        try violations.append(.{
            .line = first_trailing_ws,
            .column = 0,
            .end_line = first_trailing_ws,
            .rule = .trailing_whitespace,
            .severity = .warn,
            .message = try std.fmt.allocPrint(
                allocator,
                "{d} lines have trailing whitespace (first at line {d})",
                .{ trailing_ws_count, first_trailing_ws },
            ),
            .message_owned = true,
        });
    }

    return violations.toOwnedSlice();
}

// Tests
const testing = std.testing;

test "formatting: detects long lines" {
    var buf: [150]u8 = undefined;
    @memset(&buf, 'x');
    const long_line = buf[0..];

    const lines_arr = [_][]const u8{long_line};
    const v = try analyzeFormatting(testing.allocator, &lines_arr, .go, .{});
    defer types.freeViolations(testing.allocator, v);
    try testing.expect(v.len > 0);
}
