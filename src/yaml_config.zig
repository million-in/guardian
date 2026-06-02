const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");

const Line = struct {
    indent: usize,
    text: []const u8,
};

const Pair = struct {
    key: []const u8,
    value: []const u8,
};

pub fn yamlToJson(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var lines = try collectLines(allocator, source);
    defer lines.deinit();

    if (lines.items.len == 0) {
        return error.InvalidConfig;
    }

    var parser = Parser.init(allocator, lines.items);
    return parser.parse();
}

fn collectLines(
    allocator: std.mem.Allocator,
    source: []const u8,
) !std.array_list.Managed(Line) {
    var lines = std.array_list.Managed(Line).init(allocator);
    var iter = std.mem.splitScalar(u8, source, '\n');

    while (iter.next()) |raw_line| {
        const without_cr = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, stripComment(without_cr), " \t");
        if (trimmed.len == 0) {
            continue;
        }
        try lines.append(.{
            .indent = countIndent(without_cr),
            .text = trimmed,
        });
    }

    return lines;
}

const Parser = struct {
    allocator: std.mem.Allocator,
    lines: []const Line,
    index: usize = 0,
    buf: std.array_list.Managed(u8),

    fn init(allocator: std.mem.Allocator, lines: []const Line) Parser {
        return .{
            .allocator = allocator,
            .lines = lines,
            .buf = std.array_list.Managed(u8).init(allocator),
        };
    }

    fn parse(self: *Parser) anyerror![]u8 {
        try self.writeBlock(self.lines[0].indent);
        if (self.index != self.lines.len) {
            return error.InvalidConfig;
        }
        return self.buf.toOwnedSlice();
    }

    fn writeBlock(self: *Parser, indent: usize) anyerror!void {
        if (self.index >= self.lines.len) {
            return error.InvalidConfig;
        }
        if (self.lines[self.index].indent != indent) {
            return error.InvalidConfig;
        }
        if (isSequenceLine(self.lines[self.index].text)) {
            try self.writeSequence(indent);
            return;
        }
        try self.writeMapping(indent);
    }

    fn writeMapping(self: *Parser, indent: usize) anyerror!void {
        try self.buf.append('{');
        var first = true;
        while (self.index < self.lines.len) {
            const line = self.lines[self.index];
            if (line.indent < indent or isSequenceLine(line.text)) {
                break;
            }
            if (line.indent != indent) {
                return error.InvalidConfig;
            }
            try self.writeField(line.text, indent, &first);
        }
        try self.buf.append('}');
    }

    fn writeSequence(self: *Parser, indent: usize) anyerror!void {
        try self.buf.append('[');
        var first = true;
        while (self.index < self.lines.len) {
            const line = self.lines[self.index];
            if (line.indent < indent or !isSequenceLine(line.text)) {
                break;
            }
            if (line.indent != indent) {
                return error.InvalidConfig;
            }
            if (!first) {
                try self.buf.append(',');
            }
            first = false;
            try self.writeSequenceItem(line.text[2..], indent);
        }
        try self.buf.append(']');
    }

    fn writeSequenceItem(self: *Parser, raw_item: []const u8, indent: usize) anyerror!void {
        const item = std.mem.trim(u8, raw_item, " \t");
        self.index += 1;
        if (item.len == 0) {
            try self.writeNestedValue(indent);
            return;
        }
        const pair = splitPair(item) orelse {
            try self.writeInlineValue(item);
            return;
        };
        try self.writeSequenceObject(pair, indent);
    }

    fn writeSequenceObject(self: *Parser, first_pair: Pair, indent: usize) anyerror!void {
        try self.buf.append('{');
        var first = true;
        try self.writePair(first_pair, indent, &first);

        if (self.index < self.lines.len and self.lines[self.index].indent > indent) {
            const field_indent = self.lines[self.index].indent;
            while (self.index < self.lines.len and self.lines[self.index].indent == field_indent) {
                try self.writeField(self.lines[self.index].text, field_indent, &first);
            }
        }

        try self.buf.append('}');
    }

    fn writeField(self: *Parser, text: []const u8, indent: usize, first: *bool) anyerror!void {
        const pair = splitPair(text) orelse return error.InvalidConfig;
        self.index += 1;
        try self.writePair(pair, indent, first);
    }

    fn writePair(self: *Parser, pair: Pair, indent: usize, first: *bool) anyerror!void {
        if (!first.*) {
            try self.buf.append(',');
        }
        first.* = false;

        try self.buf.append('"');
        try jsonrpc.writeJsonEscaped(self.buf.writer(), pair.key);
        try self.buf.appendSlice("\":");
        if (pair.value.len == 0) {
            try self.writeNestedValue(indent);
            return;
        }
        try self.writeInlineValue(pair.value);
    }

    fn writeNestedValue(self: *Parser, parent_indent: usize) anyerror!void {
        if (self.index >= self.lines.len or self.lines[self.index].indent <= parent_indent) {
            return error.InvalidConfig;
        }
        try self.writeBlock(self.lines[self.index].indent);
    }

    fn writeInlineValue(self: *Parser, raw_value: []const u8) anyerror!void {
        const value = std.mem.trim(u8, raw_value, " \t");
        if (value.len == 0) {
            return error.InvalidConfig;
        }
        if (isInlineJson(value)) {
            try self.buf.appendSlice(value);
            return;
        }
        if (isQuoted(value)) {
            try writeQuotedString(self.buf.writer(), value);
            return;
        }
        if (isJsonLiteral(value)) {
            try self.buf.appendSlice(value);
            return;
        }
        try self.buf.append('"');
        try jsonrpc.writeJsonEscaped(self.buf.writer(), value);
        try self.buf.append('"');
    }
};

fn splitPair(text: []const u8) ?Pair {
    const colon_idx = findUnquotedColon(text) orelse return null;
    const key = std.mem.trim(u8, text[0..colon_idx], " \t");
    if (key.len == 0) {
        return null;
    }
    return .{
        .key = unquoteKey(key),
        .value = std.mem.trim(u8, text[colon_idx + 1 ..], " \t"),
    };
}

fn findUnquotedColon(text: []const u8) ?usize {
    var quote: u8 = 0;
    var idx: usize = 0;
    while (idx < text.len) : (idx += 1) {
        const ch = text[idx];
        if (quote != 0) {
            if (ch == quote) quote = 0;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        if (ch == ':') {
            return idx;
        }
    }
    return null;
}

fn stripComment(line: []const u8) []const u8 {
    var quote: u8 = 0;
    for (line, 0..) |ch, idx| {
        if (quote != 0) {
            if (ch == quote) quote = 0;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        if (ch == '#') {
            return line[0..idx];
        }
    }
    return line;
}

fn countIndent(line: []const u8) usize {
    var indent: usize = 0;
    while (indent < line.len and line[indent] == ' ') {
        indent += 1;
    }
    return indent;
}

fn isSequenceLine(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "- ");
}

fn isInlineJson(value: []const u8) bool {
    return (std.mem.startsWith(u8, value, "[") and std.mem.endsWith(u8, value, "]")) or
        (std.mem.startsWith(u8, value, "{") and std.mem.endsWith(u8, value, "}"));
}

fn isQuoted(value: []const u8) bool {
    if (value.len < 2) {
        return false;
    }
    return (value[0] == '"' and value[value.len - 1] == '"') or
        (value[0] == '\'' and value[value.len - 1] == '\'');
}

fn isJsonLiteral(value: []const u8) bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return true;
    if (std.mem.eql(u8, value, "null")) return true;
    return isInteger(value);
}

fn isInteger(value: []const u8) bool {
    if (value.len == 0) {
        return false;
    }
    const start: usize = if (value[0] == '-') 1 else 0;
    if (start == value.len) {
        return false;
    }
    for (value[start..]) |ch| {
        if (!std.ascii.isDigit(ch)) {
            return false;
        }
    }
    return true;
}

fn unquoteKey(key: []const u8) []const u8 {
    if (!isQuoted(key)) {
        return key;
    }
    return key[1 .. key.len - 1];
}

fn writeQuotedString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    try jsonrpc.writeJsonEscaped(writer, value[1 .. value.len - 1]);
    try writer.writeByte('"');
}

const testing = std.testing;

test "yaml config: converts nested maps and sequences into json" {
    const source =
        \\limits:
        \\  max_nesting: 3
        \\scan:
        \\  extensions: [".go", ".zig"]
        \\overrides:
        \\  - path_prefixes: ["src/"]
        \\    limits:
        \\      max_function_lines: 120
    ;

    const json = try yamlToJson(testing.allocator, source);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"limits\":{\"max_nesting\":3}") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"extensions\":[\".go\", \".zig\"]") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"max_function_lines\":120") != null);
}
