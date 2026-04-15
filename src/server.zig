const std = @import("std");
const analyzer = @import("analyzer.zig");
const app = @import("app.zig");
const guardian_config = @import("config.zig");
const jsonrpc = @import("jsonrpc.zig");
const protocol_parse = @import("protocol_parse.zig");

const JsonValue = jsonrpc.JsonValue;

const ResponseMode = enum {
    direct,
    tool,
};

const TransportMode = enum {
    framed,
    raw_line,
};

const Message = struct {
    payload: []u8,
    transport: TransportMode,
};

const Method = protocol_parse.Method;

pub fn run(allocator: std.mem.Allocator) !void {
    const stdin = std.fs.File.stdin().deprecatedReader();
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    while (true) {
        const message = try readMessagePayload(allocator, stdin);
        if (message == null) {
            break;
        }
        defer allocator.free(message.?.payload);

        const response = handleMessage(allocator, message.?.payload) catch |err| {
            try stderr.print("code-guardian-mcp: request failed: {}\n", .{err});
            const error_response = try jsonrpc.formatError(allocator, null, -32603, "internal server error");
            defer allocator.free(error_response);
            try writeMessage(stdout, error_response, message.?.transport);
            continue;
        };

        if (response) |json| {
            defer allocator.free(json);
            try writeMessage(stdout, json, message.?.transport);
        }
    }
}

pub fn processInput(allocator: std.mem.Allocator, input: []const u8) !?[]u8 {
    var stream = std.io.fixedBufferStream(input);
    const message = (try readMessagePayload(allocator, stream.reader())) orelse return null;
    defer allocator.free(message.payload);

    const response = try handleMessage(allocator, message.payload);
    if (response == null) {
        return null;
    }
    defer allocator.free(response.?);

    return switch (message.transport) {
        .framed => try jsonrpc.frameMessage(allocator, response.?),
        .raw_line => try std.fmt.allocPrint(allocator, "{s}\n", .{response.?}),
    };
}

fn readMessagePayload(allocator: std.mem.Allocator, reader: anytype) !?Message {
    var line_buf: [16 * 1024]u8 = undefined;
    const first_line = (try readNextSignificantLine(reader, &line_buf)) orelse return null;

    if (!jsonrpc.startsWithIgnoreCase(first_line, "Content-Length:")) {
        return Message{
            .payload = try allocator.dupe(u8, first_line),
            .transport = .raw_line,
        };
    }

    const content_length = try parseContentLength(first_line);
    try consumeHeaders(reader, &line_buf);
    return Message{
        .payload = try readPayloadBytes(allocator, reader, content_length),
        .transport = .framed,
    };
}

fn writeMessage(writer: anytype, payload: []const u8, transport: TransportMode) !void {
    switch (transport) {
        .framed => {
            try writer.print("Content-Length: {d}\r\n\r\n", .{payload.len});
            try writer.writeAll(payload);
        },
        .raw_line => {
            try writer.writeAll(payload);
            try writer.writeByte('\n');
        },
    }
}

fn readNextSignificantLine(reader: anytype, line_buf: []u8) !?[]const u8 {
    while (true) {
        const maybe_line = try reader.readUntilDelimiterOrEof(line_buf, '\n');
        if (maybe_line == null) {
            return null;
        }

        const line = std.mem.trimRight(u8, maybe_line.?, "\r");
        if (line.len != 0) {
            return line;
        }
    }
}

fn parseContentLength(line: []const u8) !usize {
    const length_text = std.mem.trim(u8, line["Content-Length:".len..], " \t");
    return std.fmt.parseInt(usize, length_text, 10);
}

fn consumeHeaders(reader: anytype, line_buf: []u8) !void {
    while (true) {
        const maybe_header = try reader.readUntilDelimiterOrEof(line_buf, '\n');
        if (maybe_header == null) {
            return error.UnexpectedEof;
        }

        const header = std.mem.trimRight(u8, maybe_header.?, "\r");
        if (header.len == 0) {
            return;
        }
    }
}

fn readPayloadBytes(allocator: std.mem.Allocator, reader: anytype, content_length: usize) ![]u8 {
    const payload = try allocator.alloc(u8, content_length);
    errdefer allocator.free(payload);
    try reader.readNoEof(payload);
    return payload;
}

fn handleMessage(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(JsonValue, allocator, raw, .{});
    defer parsed.deinit();

    const root_object = switch (parsed.value) {
        .object => |object| object,
        else => return try jsonrpc.formatError(allocator, null, -32600, "invalid request"),
    };

    const id = root_object.get("id");
    const method_name = protocol_parse.getStringField(root_object, "method") orelse {
        return try jsonrpc.formatError(allocator, id, -32600, "missing method");
    };
    const method = protocol_parse.parseMethod(method_name) orelse {
        return try jsonrpc.formatError(allocator, id, -32601, "method not found");
    };

    return dispatchMethod(allocator, id, method, root_object.get("params"));
}

fn dispatchMethod(
    allocator: std.mem.Allocator,
    id: ?JsonValue,
    method: Method,
    params_value: ?JsonValue,
) !?[]u8 {
    switch (method) {
        .initialize => return try handleInitialize(allocator, id, params_value),
        .initialized_notification => return null,
        .ping => return try jsonrpc.formatResponse(allocator, id, "{}"),
        .tools_list => return try jsonrpc.formatResponse(allocator, id, TOOLS_LIST),
        .tools_call => {
            const params_object = protocol_parse.getObjectValue(params_value) orelse {
                return try jsonrpc.formatError(allocator, id, -32602, "missing tool params");
            };
            return try handleToolCall(allocator, id, params_object);
        },
        .analyze,
        .analyze_batch,
        .analyze_folder,
        => return try handleDirectCall(allocator, id, method, params_value),
    }
}

fn handleDirectCall(
    allocator: std.mem.Allocator,
    id: ?JsonValue,
    method: Method,
    params_value: ?JsonValue,
) ![]u8 {
    const params_object = protocol_parse.getObjectValue(params_value) orelse switch (method) {
        .analyze => return jsonrpc.formatError(allocator, id, -32602, "missing analyze params"),
        .analyze_batch => return jsonrpc.formatError(allocator, id, -32602, "missing analyze_batch params"),
        .analyze_folder => return jsonrpc.formatError(allocator, id, -32602, "missing analyze_folder params"),
        else => unreachable,
    };

    return switch (method) {
        .analyze => try handleAnalyze(allocator, id, params_object, .direct),
        .analyze_batch => try handleAnalyzeBatch(allocator, id, params_object, .direct),
        .analyze_folder => try handleAnalyzeFolder(allocator, id, params_object, .direct),
        else => unreachable,
    };
}

fn handleInitialize(
    allocator: std.mem.Allocator,
    id: ?JsonValue,
    params_value: ?JsonValue,
) ![]u8 {
    const protocol_version = selectProtocolVersion(params_value);
    const result = try std.fmt.allocPrint(
        allocator,
        "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"code-guardian\",\"version\":\"0.3.0\"}}}}",
        .{protocol_version},
    );
    defer allocator.free(result);
    return jsonrpc.formatResponse(allocator, id, result);
}

fn selectProtocolVersion(params_value: ?JsonValue) []const u8 {
    const params_object = protocol_parse.getObjectValue(params_value) orelse return SUPPORTED_PROTOCOL_VERSION;
    const requested = protocol_parse.getStringField(params_object, "protocolVersion") orelse return SUPPORTED_PROTOCOL_VERSION;

    inline for (SUPPORTED_PROTOCOL_VERSIONS) |supported| {
        if (std.mem.eql(u8, requested, supported)) {
            return supported;
        }
    }

    return SUPPORTED_PROTOCOL_VERSION;
}

fn handleToolCall(
    allocator: std.mem.Allocator,
    id: ?JsonValue,
    params_object: protocol_parse.JsonObject,
) ![]u8 {
    const tool_name = protocol_parse.getStringField(params_object, "name") orelse {
        return try jsonrpc.formatError(allocator, id, -32602, "missing tool name");
    };
    const arguments_value = params_object.get("arguments");
    const arguments_object = protocol_parse.getObjectValue(arguments_value) orelse {
        return try jsonrpc.formatError(allocator, id, -32602, "missing tool arguments");
    };

    const tool_method = protocol_parse.parseToolName(tool_name) orelse {
        return try jsonrpc.formatError(allocator, id, -32602, "unknown tool");
    };

    return switch (tool_method) {
        .analyze => try handleAnalyze(allocator, id, arguments_object, .tool),
        .analyze_batch => try handleAnalyzeBatch(allocator, id, arguments_object, .tool),
        .analyze_folder => try handleAnalyzeFolder(allocator, id, arguments_object, .tool),
        else => unreachable,
    };
}

fn handleAnalyze(
    allocator: std.mem.Allocator,
    id: ?JsonValue,
    arguments_object: protocol_parse.JsonObject,
    mode: ResponseMode,
) ![]u8 {
    const file_path = protocol_parse.getStringField(arguments_object, "file_path") orelse {
        return try jsonrpc.formatError(allocator, id, -32602, "missing file_path");
    };
    const source = protocol_parse.getStringField(arguments_object, "source") orelse {
        return try jsonrpc.formatError(allocator, id, -32602, "missing source");
    };
    const config_path = protocol_parse.getOptionalStringField(arguments_object, "config_path");

    var loaded_cfg = try guardian_config.loadForTarget(allocator, file_path, config_path);
    defer loaded_cfg.deinit();

    const result = try app.analyzeInput(allocator, file_path, source, loaded_cfg.value);
    defer analyzer.freeResult(allocator, result);

    return switch (mode) {
        .direct => {
            const json = try analyzer.resultToJson(allocator, result);
            defer allocator.free(json);
            return jsonrpc.formatResponse(allocator, id, json);
        },
        .tool => {
            const text = try app.resultToToolText(allocator, result);
            defer allocator.free(text);
            return jsonrpc.formatToolResult(allocator, id, text, false);
        },
    };
}

fn handleAnalyzeBatch(
    allocator: std.mem.Allocator,
    id: ?JsonValue,
    arguments_object: protocol_parse.JsonObject,
    mode: ResponseMode,
) ![]u8 {
    const files_value = arguments_object.get("files") orelse {
        return try jsonrpc.formatError(allocator, id, -32602, "missing files");
    };
    const files = switch (files_value) {
        .array => |array| array,
        else => return try jsonrpc.formatError(allocator, id, -32602, "files must be an array"),
    };
    if (files.items.len == 0) {
        return try jsonrpc.formatError(allocator, id, -32602, "files must not be empty");
    }

    const inputs = try protocol_parse.parseFileInputs(allocator, files.items);
    defer allocator.free(inputs);

    const config_path = protocol_parse.getOptionalStringField(arguments_object, "config_path");
    var batch = try app.analyzeBatchInputsResolved(allocator, inputs, config_path);
    defer batch.deinit(allocator);

    return switch (mode) {
        .direct => {
            const json = try app.batchToJson(allocator, batch);
            defer allocator.free(json);
            return jsonrpc.formatResponse(allocator, id, json);
        },
        .tool => {
            const text = try app.batchToToolText(allocator, batch);
            defer allocator.free(text);
            return jsonrpc.formatToolResult(allocator, id, text, false);
        },
    };
}

fn handleAnalyzeFolder(
    allocator: std.mem.Allocator,
    id: ?JsonValue,
    arguments_object: protocol_parse.JsonObject,
    mode: ResponseMode,
) ![]u8 {
    const folder_path = protocol_parse.getStringField(arguments_object, "path") orelse {
        return try jsonrpc.formatError(allocator, id, -32602, "missing path");
    };
    const config_path = protocol_parse.getOptionalStringField(arguments_object, "config_path");

    var batch = app.analyzeFolderResolved(allocator, folder_path, config_path) catch |err| {
        return handleAnalyzeFolderError(allocator, id, err);
    };
    defer batch.deinit(allocator);

    return switch (mode) {
        .direct => {
            const json = try app.batchToJson(allocator, batch);
            defer allocator.free(json);
            return jsonrpc.formatResponse(allocator, id, json);
        },
        .tool => {
            const text = try app.batchToToolText(allocator, batch);
            defer allocator.free(text);
            return jsonrpc.formatToolResult(allocator, id, text, false);
        },
    };
}

fn handleAnalyzeFolderError(
    allocator: std.mem.Allocator,
    id: ?JsonValue,
    err: anyerror,
) ![]u8 {
    return switch (err) {
        error.NotDirectory => jsonrpc.formatError(
            allocator,
            id,
            -32602,
            "path must be a directory",
        ),
        error.NoSupportedSourceFiles => jsonrpc.formatError(
            allocator,
            id,
            -32602,
            "folder does not contain supported source files",
        ),
        else => err,
    };
}

const SUPPORTED_PROTOCOL_VERSION = "2025-11-25";
const SUPPORTED_PROTOCOL_VERSIONS = [_][]const u8{
    SUPPORTED_PROTOCOL_VERSION,
    "2024-11-05",
};

const ANALYZE_TOOL =
    "{" ++
    "\"name\":\"analyze\"," ++
    "\"description\":\"Analyze one source file for guardian rules.\"," ++
    "\"inputSchema\":{" ++
    "\"type\":\"object\"," ++
    "\"properties\":{" ++
    "\"file_path\":{\"type\":\"string\"}," ++
    "\"source\":{\"type\":\"string\"}," ++
    "\"config_path\":{\"type\":\"string\"}" ++
    "}," ++
    "\"required\":[\"file_path\",\"source\"]" ++
    "}" ++
    "}";

const ANALYZE_BATCH_TOOL =
    "{" ++
    "\"name\":\"analyze_batch\"," ++
    "\"description\":\"Analyze multiple source files in one request.\"," ++
    "\"inputSchema\":{" ++
    "\"type\":\"object\"," ++
    "\"properties\":{" ++
    "\"files\":{" ++
    "\"type\":\"array\"," ++
    "\"items\":{" ++
    "\"type\":\"object\"," ++
    "\"properties\":{" ++
    "\"file_path\":{\"type\":\"string\"}," ++
    "\"source\":{\"type\":\"string\"}" ++
    "}," ++
    "\"required\":[\"file_path\",\"source\"]" ++
    "}" ++
    "}," ++
    "\"config_path\":{\"type\":\"string\"}" ++
    "}," ++
    "\"required\":[\"files\"]" ++
    "}" ++
    "}";

const ANALYZE_FOLDER_TOOL =
    "{" ++
    "\"name\":\"analyze_folder\"," ++
    "\"description\":\"Recursively analyze a folder when it contains supported source files.\"," ++
    "\"inputSchema\":{" ++
    "\"type\":\"object\"," ++
    "\"properties\":{" ++
    "\"path\":{\"type\":\"string\"}," ++
    "\"config_path\":{\"type\":\"string\"}" ++
    "}," ++
    "\"required\":[\"path\"]" ++
    "}" ++
    "}";

const TOOLS_LIST =
    "{" ++
    "\"tools\":[" ++ ANALYZE_TOOL ++ "," ++ ANALYZE_BATCH_TOOL ++ "," ++ ANALYZE_FOLDER_TOOL ++ "]" ++
    "}";

const testing = std.testing;

test "protocol: initialize over content-length framing" {
    const request =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    ;
    const framed_request = try jsonrpc.frameMessage(testing.allocator, request);
    defer testing.allocator.free(framed_request);

    const response = try processInput(testing.allocator, framed_request);
    try testing.expect(response != null);
    defer testing.allocator.free(response.?);

    try testing.expect(std.mem.indexOf(u8, response.?, "Content-Length:") != null);
    try testing.expect(std.mem.indexOf(u8, response.?, "protocolVersion") != null);
}

test "protocol: initialize over raw stdio json line" {
    const request =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}
    ;

    const response = try processInput(testing.allocator, request);
    try testing.expect(response != null);
    defer testing.allocator.free(response.?);

    try testing.expect(std.mem.indexOf(u8, response.?, "Content-Length:") == null);
    try testing.expect(std.mem.endsWith(u8, response.?, "\n"));
    try testing.expect(std.mem.indexOf(u8, response.?, "\"protocolVersion\":\"2025-11-25\"") != null);
}

test "protocol: tools/list over raw stdio json line" {
    const request =
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    ;

    const response = try processInput(testing.allocator, request);
    try testing.expect(response != null);
    defer testing.allocator.free(response.?);

    try testing.expect(std.mem.indexOf(u8, response.?, "\"name\":\"analyze\"") != null);
    try testing.expect(std.mem.indexOf(u8, response.?, "\"name\":\"analyze_batch\"") != null);
    try testing.expect(std.mem.indexOf(u8, response.?, "\"name\":\"analyze_folder\"") != null);
}

test "protocol: analyze request returns file report with excerpt" {
    const request =
        \\{
        \\  "jsonrpc":"2.0",
        \\  "id":2,
        \\  "method":"tools/call",
        \\  "params":{
        \\    "name":"analyze",
        \\    "arguments":{
        \\      "file_path":"sample.go",
        \\      "source":"func Process(data interface{}) {\n    return\n}"
        \\    }
        \\  }
        \\}
    ;
    const framed_request = try jsonrpc.frameMessage(testing.allocator, request);
    defer testing.allocator.free(framed_request);

    const response = try processInput(testing.allocator, framed_request);
    try testing.expect(response != null);
    defer testing.allocator.free(response.?);

    try testing.expect(std.mem.indexOf(u8, response.?, "sample.go") != null);
    try testing.expect(std.mem.indexOf(u8, response.?, "interface{}") != null);
    try testing.expect(std.mem.indexOf(u8, response.?, "\\u001b[31m") != null);
    try testing.expect(std.mem.indexOf(u8, response.?, "banned_type") != null);
}

test "protocol: analyze_batch aggregates results" {
    const request =
        \\{
        \\  "jsonrpc":"2.0",
        \\  "id":"batch-1",
        \\  "method":"tools/call",
        \\  "params":{
        \\    "name":"analyze_batch",
        \\    "arguments":{
        \\      "files":[
        \\        {
        \\          "file_path":"a.go",
        \\          "source":"func A(data interface{}) {\n    return\n}"
        \\        },
        \\        {
        \\          "file_path":"b.py",
        \\          "source":"def ok() -> int:\n    return 1\n"
        \\        }
        \\      ]
        \\    }
        \\  }
        \\}
    ;
    const framed_request = try jsonrpc.frameMessage(testing.allocator, request);
    defer testing.allocator.free(framed_request);

    const response = try processInput(testing.allocator, framed_request);
    try testing.expect(response != null);
    defer testing.allocator.free(response.?);

    try testing.expect(std.mem.indexOf(u8, response.?, "Scanned") != null);
    try testing.expect(std.mem.indexOf(u8, response.?, "a.go") != null);
    try testing.expect(std.mem.indexOf(u8, response.?, "b.py") != null);
    try testing.expect(std.mem.indexOf(u8, response.?, "\\u001b[90m") != null);
}

test "protocol: analyze_folder scans supported files recursively" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("pkg/nested");
    try tmp.dir.writeFile(.{
        .sub_path = "pkg/nested/main.go",
        .data =
        \\func Process(data interface{}) {
        \\    _ = data
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "pkg/nested/notes.txt",
        .data = "ignore me\n",
    });

    const absolute_folder = try tmp.dir.realpathAlloc(testing.allocator, "pkg");
    defer testing.allocator.free(absolute_folder);

    const request = try buildAnalyzeFolderRequest(testing.allocator, absolute_folder);
    defer testing.allocator.free(request);

    const framed_request = try jsonrpc.frameMessage(testing.allocator, request);
    defer testing.allocator.free(framed_request);

    const response = try processInput(testing.allocator, framed_request);
    try testing.expect(response != null);
    defer testing.allocator.free(response.?);

    try testing.expect(std.mem.indexOf(u8, response.?, "\"file_count\":1") != null);
    try testing.expect(std.mem.indexOf(u8, response.?, "main.go") != null);
    try testing.expect(std.mem.indexOf(u8, response.?, "interface{}") != null);
}

test "protocol: analyze_folder supports explicit absolute config path via tools/call" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "guardian.json",
        .data =
        \\{
        \\  "go": {
        \\    "ban_generics": false
        \\  }
        \\}
        ,
    });
    try tmp.dir.makePath("pkg/nested");
    try tmp.dir.writeFile(.{
        .sub_path = "pkg/nested/a.go",
        .data =
        \\func Map[T any](items []T) []T {
        \\    return items
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "pkg/nested/b.go",
        .data =
        \\func Reduce[T any](items []T) []T {
        \\    return items
        \\}
        ,
    });

    const absolute_folder = try tmp.dir.realpathAlloc(testing.allocator, "pkg");
    defer testing.allocator.free(absolute_folder);
    const absolute_config = try tmp.dir.realpathAlloc(testing.allocator, "guardian.json");
    defer testing.allocator.free(absolute_config);

    const request = try buildAnalyzeFolderToolCallRequest(
        testing.allocator,
        absolute_folder,
        absolute_config,
    );
    defer testing.allocator.free(request);

    const framed_request = try jsonrpc.frameMessage(testing.allocator, request);
    defer testing.allocator.free(framed_request);

    const response = try processInput(testing.allocator, framed_request);
    try testing.expect(response != null);
    defer testing.allocator.free(response.?);

    try testing.expect(std.mem.indexOf(u8, response.?, "\"isError\":false") != null);
    try testing.expect(std.mem.indexOf(u8, response.?, "Scanned") != null);
    try testing.expect(std.mem.indexOf(u8, response.?, "a.go") != null);
    try testing.expect(std.mem.indexOf(u8, response.?, "b.go") != null);
    try testing.expect(std.mem.indexOf(u8, response.?, "PASS") != null);
}

fn buildAnalyzeFolderRequest(allocator: std.mem.Allocator, folder_path: []const u8) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("{\"jsonrpc\":\"2.0\",");
    try writer.writeAll("\"id\":\"folder-1\",");
    try writer.writeAll("\"method\":\"analyze_folder\",");
    try writer.writeAll("\"params\":{\"path\":\"");
    try jsonrpc.writeJsonEscaped(writer, folder_path);
    try writer.writeAll("\"}}");
    return buf.toOwnedSlice();
}

fn buildAnalyzeFolderToolCallRequest(
    allocator: std.mem.Allocator,
    folder_path: []const u8,
    config_path: []const u8,
) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("{\"jsonrpc\":\"2.0\",");
    try writer.writeAll("\"id\":\"folder-tool-1\",");
    try writer.writeAll("\"method\":\"tools/call\",");
    try writer.writeAll("\"params\":{\"name\":\"analyze_folder\",\"arguments\":{");
    try writer.writeAll("\"path\":\"");
    try jsonrpc.writeJsonEscaped(writer, folder_path);
    try writer.writeAll("\",\"config_path\":\"");
    try jsonrpc.writeJsonEscaped(writer, config_path);
    try writer.writeAll("\"}}}");
    return buf.toOwnedSlice();
}
