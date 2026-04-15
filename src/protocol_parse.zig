const std = @import("std");
const app = @import("app.zig");
const jsonrpc = @import("jsonrpc.zig");

pub const JsonValue = jsonrpc.JsonValue;
pub const JsonObject = @TypeOf(switch (JsonValue{ .object = undefined }) {
    .object => |object| object,
    else => unreachable,
});

pub const Method = enum {
    initialize,
    initialized_notification,
    ping,
    tools_list,
    tools_call,
    analyze,
    analyze_batch,
    analyze_folder,
};

pub fn parseMethod(name: []const u8) ?Method {
    return lookupMethod(name, &direct_methods);
}

pub fn parseToolName(name: []const u8) ?Method {
    return lookupMethod(name, &tool_methods);
}

pub fn parseFileInputs(allocator: std.mem.Allocator, items: []const JsonValue) ![]app.FileInput {
    const inputs = try allocator.alloc(app.FileInput, items.len);
    errdefer allocator.free(inputs);

    for (items, 0..) |item, idx| {
        const object = switch (item) {
            .object => |object| object,
            else => return error.InvalidArguments,
        };

        inputs[idx] = .{
            .file_path = getStringField(object, "file_path") orelse return error.InvalidArguments,
            .source = getStringField(object, "source") orelse return error.InvalidArguments,
        };
    }

    return inputs;
}

pub fn getObjectValue(value: ?JsonValue) ?JsonObject {
    const unwrapped = value orelse return null;
    return switch (unwrapped) {
        .object => |object| object,
        else => null,
    };
}

pub fn getStringField(object: JsonObject, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

pub fn getOptionalStringField(object: JsonObject, name: []const u8) ?[]const u8 {
    return getStringField(object, name);
}

const MethodName = struct {
    name: []const u8,
    method: Method,
};

const direct_methods = [_]MethodName{
    .{ .name = "initialize", .method = .initialize },
    .{ .name = "notifications/initialized", .method = .initialized_notification },
    .{ .name = "ping", .method = .ping },
    .{ .name = "tools/list", .method = .tools_list },
    .{ .name = "tools/call", .method = .tools_call },
    .{ .name = "analyze", .method = .analyze },
    .{ .name = "analyze_batch", .method = .analyze_batch },
    .{ .name = "analyze_folder", .method = .analyze_folder },
};

const tool_methods = [_]MethodName{
    .{ .name = "analyze", .method = .analyze },
    .{ .name = "analyze_batch", .method = .analyze_batch },
    .{ .name = "analyze_folder", .method = .analyze_folder },
};

fn lookupMethod(name: []const u8, table: []const MethodName) ?Method {
    for (table) |entry| {
        if (std.mem.eql(u8, name, entry.name)) {
            return entry.method;
        }
    }
    return null;
}
