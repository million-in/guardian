const std = @import("std");
const compat = @import("compat.zig");
const root = @import("root.zig");
const app = @import("app.zig");

const version = "2025-03-26";
const t1 = "{\"name\":\"guardian_analyze\",\"description\":" ++ "\"Analyze one source file and return its JSON report.\"," ++ "\"inputSchema\":{\"type\":\"object\",\"properties\":{" ++ "\"path\":{\"type\":\"string\"},\"config_path\":{\"type\":\"string\"}}," ++ "\"required\":[\"path\"],\"additionalProperties\":false}}";
const t2 = "{\"name\":\"guardian_analyze_source\",\"description\":" ++ "\"Analyze source text not on disk and return its JSON report.\"," ++ "\"inputSchema\":{\"type\":\"object\",\"properties\":{" ++ "\"path\":{\"type\":\"string\"},\"source\":{\"type\":\"string\"}," ++ "\"config_path\":{\"type\":\"string\"}}," ++ "\"required\":[\"path\",\"source\"],\"additionalProperties\":false}}";
const t3 = "{\"name\":\"guardian_batch\",\"description\":" ++ "\"Analyze several files and return the aggregate JSON report.\"," ++ "\"inputSchema\":{\"type\":\"object\",\"properties\":{" ++ "\"paths\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}," ++ "\"config_path\":{\"type\":\"string\"}}," ++ "\"required\":[\"paths\"],\"additionalProperties\":false}}";
const t4 = "{\"name\":\"guardian_folder\",\"description\":" ++ "\"Analyze a directory and return the aggregate JSON report.\"," ++ "\"inputSchema\":{\"type\":\"object\",\"properties\":{" ++ "\"path\":{\"type\":\"string\"},\"config_path\":{\"type\":\"string\"}}," ++ "\"required\":[\"path\"],\"additionalProperties\":false}}";
const t5 = "{\"name\":\"guardian_audit\",\"description\":" ++ "\"Audit a directory (static only, never runs proofs) " ++ "and return score JSON.\"," ++ "\"inputSchema\":{\"type\":\"object\",\"properties\":{" ++ "\"path\":{\"type\":\"string\"},\"config_path\":{\"type\":\"string\"}," ++ "\"score_threshold\":{\"type\":\"integer\"}}," ++ "\"required\":[\"path\"],\"additionalProperties\":false}}";
const tools_json = "[" ++ t1 ++ "," ++ t2 ++ "," ++ t3 ++ "," ++ t4 ++ "," ++ t5 ++ "]";

const Responder = struct {
    allocator: std.mem.Allocator,
    id: ?std.json.Value,

    fn result(self: Responder, raw: []const u8) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(self.allocator);
        try list.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
        try self.writeId(&list);
        try list.appendSlice(self.allocator, ",\"result\":");
        try list.appendSlice(self.allocator, raw);
        try list.append(self.allocator, '}');
        return list.toOwnedSlice(self.allocator);
    }

    fn err(self: Responder, code: i64, message: []const u8) ![]u8 {
        const aw = try stringify(self.allocator, message);
        defer self.allocator.free(aw);
        const raw = try std.fmt.allocPrint(self.allocator, "{{\"code\":{d},\"message\":{s}}}", .{ code, aw });
        defer self.allocator.free(raw);
        const wrapped = try std.fmt.allocPrint(self.allocator, "{{\"error\":{s}}}", .{raw});
        defer self.allocator.free(wrapped);
        // Rebuild with the error object in place of a result object.
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(self.allocator);
        try list.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
        try self.writeId(&list);
        try list.appendSlice(self.allocator, ",");
        try list.appendSlice(self.allocator, wrapped[1 .. wrapped.len - 1]);
        try list.append(self.allocator, '}');
        return list.toOwnedSlice(self.allocator);
    }

    fn tool(self: Responder, text: []const u8, is_error: bool) ![]u8 {
        const aw = try stringify(self.allocator, text);
        defer self.allocator.free(aw);
        const raw = try std.fmt.allocPrint(self.allocator, "{{\"content\":[{{\"type\":\"text\",\"text\":{s}}}]" ++ ",\"isError\":{s}}}", .{ aw, if (is_error) "true" else "false" });
        defer self.allocator.free(raw);
        return self.result(raw);
    }

    fn writeId(self: Responder, list: *std.ArrayList(u8)) !void {
        const id = self.id orelse {
            try list.appendSlice(self.allocator, "null");
            return;
        };
        const aw = try stringify(self.allocator, id);
        defer self.allocator.free(aw);
        try list.appendSlice(self.allocator, aw);
    }
};

fn stringify(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(value, .{}, &aw.writer);
    return allocator.dupe(u8, aw.written());
}

pub fn run(allocator: std.mem.Allocator) !void {
    var in_buf: [4096]u8 = undefined;
    var out_buf: [16 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(compat.io, &in_buf);
    var stdout = std.Io.File.stdout()
        .writerStreaming(compat.io, &out_buf);
    defer stdout.interface.flush() catch {};
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    while (true) {
        const byte = stdin.interface.takeByte() catch break;
        if (byte != '\n') {
            try line.append(allocator, byte);
            continue;
        }
        try emit(allocator, &stdout.interface, line.items);
        line.clearRetainingCapacity();
    }
    try emit(allocator, &stdout.interface, line.items);
}

fn emit(allocator: std.mem.Allocator, out: anytype, line: []const u8) !void {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return;
    const response = try handle(allocator, trimmed);
    const r = response orelse return;
    defer allocator.free(r);
    try out.writeAll(r);
    try out.writeByte('\n');
    try out.flush();
}

fn handle(allocator: std.mem.Allocator, line: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        const r = Responder{ .allocator = allocator, .id = null };
        return try r.err(-32700, "parse error");
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            const r = Responder{ .allocator = allocator, .id = null };
            return try r.err(-32600, "invalid request");
        },
    };
    const r = Responder{ .allocator = allocator, .id = obj.get("id") };
    const method = str(obj.get("method")) orelse
        return try r.err(-32600, "missing method");
    if (std.mem.startsWith(u8, method, "notifications/")) return null;
    return route(.{ .allocator = allocator, .r = r, .obj = obj, .method = method });
}

const Route = struct {
    allocator: std.mem.Allocator,
    r: Responder,
    obj: std.json.ObjectMap,
    method: []const u8,
};

fn route(rt: Route) !?[]u8 {
    const allocator = rt.allocator;
    const r = rt.r;
    const obj = rt.obj;
    const method = rt.method;
    if (std.mem.eql(u8, method, "initialize")) {
        return try r.result("{\"protocolVersion\":\"" ++ version ++ "\",\"capabilities\":{\"tools\":{}},\"serverInfo\":" ++ "{\"name\":\"guardian\",\"version\":\"0.5.1\"}}");
    }
    if (std.mem.eql(u8, method, "ping")) return try r.result("{}");
    if (std.mem.eql(u8, method, "tools/list")) {
        return try r.result("{\"tools\":" ++ tools_json ++ "}");
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        return handleCall(allocator, r, obj);
    }
    return try r.err(-32601, "method not found");
}

fn handleCall(allocator: std.mem.Allocator, r: Responder, obj: std.json.ObjectMap) !?[]u8 {
    const params = switch (obj.get("params") orelse
        return try r.err(-32602, "missing params")) {
        .object => |o| o,
        else => return try r.err(-32602, "invalid params"),
    };
    const name = str(params.get("name")) orelse
        return try r.err(-32602, "missing tool name");
    const args: std.json.ObjectMap = switch (params.get("arguments") orelse .null) {
        .object => |o| o,
        else => .empty,
    };
    const json = callTool(allocator, name, args) catch |e| {
        const msg = try std.fmt.allocPrint(allocator, "guardian error: {s}", .{@errorName(e)});
        defer allocator.free(msg);
        return try r.tool(msg, true);
    };
    defer allocator.free(json);
    // Never emit a line approaching the client's 16 MiB stdio cap: that
    // kills the connection for every later call. Fail this call only.
    if (json.len > 4 * 1024 * 1024) {
        const msg = try std.fmt.allocPrint(allocator, "guardian error: result too large ({d} bytes); audit a smaller directory or fewer files", .{json.len});
        defer allocator.free(msg);
        return try r.tool(msg, true);
    }
    return try r.tool(json, false);
}

fn callTool(allocator: std.mem.Allocator, name: []const u8, args: std.json.ObjectMap) ![]u8 {
    const cfg = str(args.get("config_path"));
    if (std.mem.eql(u8, name, "guardian_analyze")) {
        const path = str(args.get("path")) orelse
            return error.InvalidArguments;
        return root.analyzeFileJson(allocator, path, cfg, .{});
    }
    if (std.mem.eql(u8, name, "guardian_batch")) {
        return callBatch(allocator, args, cfg);
    }
    return callFolderTool(.{ .allocator = allocator, .name = name, .args = args, .cfg = cfg });
}

const FolderCall = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    args: std.json.ObjectMap,
    cfg: ?[]const u8,
};

fn callFolderTool(call: FolderCall) ![]u8 {
    const allocator = call.allocator;
    const name = call.name;
    const args = call.args;
    const cfg = call.cfg;
    const path = str(args.get("path")) orelse
        return error.InvalidArguments;
    if (std.mem.eql(u8, name, "guardian_analyze_source")) {
        const source = str(args.get("source")) orelse
            return error.InvalidArguments;
        return root.analyzeSourceJson(allocator, path, source, cfg, .{});
    }
    if (std.mem.eql(u8, name, "guardian_folder")) {
        return root.analyzeFolderJson(allocator, path, cfg, .{});
    }
    if (std.mem.eql(u8, name, "guardian_audit")) {
        var opts: root.AuditOptions = .{};
        if (args.get("score_threshold")) |v| {
            if (v == .integer) opts.score_threshold =
                @intCast(std.math.clamp(v.integer, 0, 100));
        }
        return root.auditFolderJson(allocator, path, cfg, opts);
    }
    return error.UnknownTool;
}

fn callBatch(allocator: std.mem.Allocator, args: std.json.ObjectMap, cfg: ?[]const u8) ![]u8 {
    const arr = switch (args.get("paths") orelse
        return error.InvalidArguments) {
        .array => |v| v,
        else => return error.InvalidArguments,
    };
    var paths = try allocator.alloc([]const u8, arr.items.len);
    defer allocator.free(paths);
    for (arr.items, 0..) |item, i| {
        paths[i] = str(item) orelse return error.InvalidArguments;
    }
    var batch = try app.analyzeFilePathsResolved(allocator, paths, cfg);
    defer batch.deinit(allocator);
    return app.batchToJson(allocator, batch);
}

fn str(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

test "mcp initialize and tools/list" {
    const testing = std.testing;
    const req1 = "{\"jsonrpc\":\"2.0\",\"id\":1," ++ "\"method\":\"initialize\",\"params\":{}}";
    const r1 = (try handle(testing.allocator, req1)).?;
    defer testing.allocator.free(r1);
    try testing.expect(std.mem.indexOf(u8, r1, "\"name\":\"guardian\"") != null);
    const req2 = "{\"jsonrpc\":\"2.0\",\"id\":2," ++ "\"method\":\"tools/list\"}";
    const r2 = (try handle(testing.allocator, req2)).?;
    defer testing.allocator.free(r2);
    try testing.expect(std.mem.indexOf(u8, r2, "guardian_audit") != null);
    const req3 = "{\"jsonrpc\":\"2.0\"," ++ "\"method\":\"notifications/initialized\"}";
    try testing.expect((try handle(testing.allocator, req3)) == null);
}
