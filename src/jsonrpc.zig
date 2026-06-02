const std = @import("std");

pub const JsonValue = std.json.Value;

pub fn formatResponse(
    allocator: std.mem.Allocator,
    id: ?JsonValue,
    result_json: []const u8,
) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    const writer = &buf.writer;

    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonId(writer, id);
    try writer.writeAll(",\"result\":");
    try writer.writeAll(result_json);
    try writer.writeAll("}");
    return buf.toOwnedSlice();
}

pub fn formatToolResult(
    allocator: std.mem.Allocator,
    id: ?JsonValue,
    text: []const u8,
    is_error: bool,
) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    const writer = &buf.writer;

    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonId(writer, id);
    try writer.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"");
    try writeJsonEscaped(writer, text);
    try writer.writeAll("\"}],\"isError\":");
    try writer.print("{}", .{is_error});
    try writer.writeAll("}}");
    return buf.toOwnedSlice();
}

pub fn formatError(
    allocator: std.mem.Allocator,
    id: ?JsonValue,
    code: i32,
    message: []const u8,
) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    const writer = &buf.writer;

    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonId(writer, id);
    try writer.print(",\"error\":{{\"code\":{d},\"message\":\"", .{code});
    try writeJsonEscaped(writer, message);
    try writer.writeAll("\"}}}");
    return buf.toOwnedSlice();
}

pub fn writeJsonId(writer: anytype, id: ?JsonValue) !void {
    const value = id orelse {
        try writer.writeAll("null");
        return;
    };

    switch (value) {
        .null => try writer.writeAll("null"),
        .integer => |number| try writer.print("{}", .{number}),
        .float => |number| try writer.print("{}", .{number}),
        .number_string => |number| try writer.writeAll(number),
        .string => |string| {
            try writer.writeByte('"');
            try writeJsonEscaped(writer, string);
            try writer.writeByte('"');
        },
        else => try writer.writeAll("null"),
    }
}

pub fn writeJsonEscaped(writer: anytype, value: []const u8) !void {
    for (value) |ch| {
        try writeEscapedByte(writer, ch);
    }
}

pub fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) {
        return false;
    }

    var idx: usize = 0;
    while (idx < prefix.len) : (idx += 1) {
        if (std.ascii.toLower(haystack[idx]) != std.ascii.toLower(prefix[idx])) {
            return false;
        }
    }
    return true;
}

pub fn frameMessage(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var framed: std.Io.Writer.Allocating = .init(allocator);
    errdefer framed.deinit();
    const writer = &framed.writer;
    try writer.print("Content-Length: {d}\r\n\r\n", .{payload.len});
    try writer.writeAll(payload);
    return framed.toOwnedSlice();
}

fn writeEscapedByte(writer: anytype, ch: u8) !void {
    switch (ch) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writePrintableByte(writer, ch),
    }
}

fn writePrintableByte(writer: anytype, ch: u8) !void {
    if (ch >= 0x20) {
        try writer.writeByte(ch);
        return;
    }

    const hex = "0123456789abcdef";
    try writer.writeAll("\\u00");
    try writer.writeByte(hex[ch >> 4]);
    try writer.writeByte(hex[ch & 0x0f]);
}
