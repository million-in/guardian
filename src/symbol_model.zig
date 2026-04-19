const std = @import("std");
const types = @import("types.zig");

const Language = types.Language;

pub const LifecycleActionKind = enum {
    start,
    cleanup,
};

pub const LifecycleAction = struct {
    kind: LifecycleActionKind,
    target: []const u8,
    verb: []const u8,
    line: u32,
};

pub const FieldInfo = struct {
    name: []const u8,
    is_bool: bool,
    is_lifecycle: bool,
};

pub const FunctionInfo = struct {
    name: []const u8,
    owner_type: []const u8 = "",
    receiver_name: []const u8 = "",
    start_line: u32,
    body_start_line: u32,
    end_line: u32,
    is_public: bool,
    argument_count: u32,
    declared: []const []const u8 = &.{},
    touched: []const []const u8 = &.{},
    bool_reads: []const []const u8 = &.{},
    lifecycle_actions: []const LifecycleAction = &.{},
    has_explicit_scope_cleanup: bool = false,
};

pub const TypeKind = enum {
    go_struct,
    typescript_class,
    typescript_interface,
    typescript_object,
    python_class,
    zig_struct,
};

pub const TypeInfo = struct {
    name: []const u8,
    kind: TypeKind,
    start_line: u32,
    end_line: u32,
    is_public: bool,
    field_count: u32,
    fields: []const FieldInfo = &.{},
    lifecycle_bool_fields: []const []const u8 = &.{},
    has_explicit_state: bool = false,
};

pub const Model = struct {
    functions: []const FunctionInfo,
    types: []const TypeInfo,
};

pub fn build(
    allocator: std.mem.Allocator,
    raw_lines: []const []const u8,
    masked_lines: []const []const u8,
    lang: Language,
) !Model {
    return switch (lang) {
        .go => buildGoModel(allocator, raw_lines, masked_lines),
        .typescript => buildTypeScriptModel(allocator, raw_lines, masked_lines),
        .python => buildPythonModel(allocator, raw_lines, masked_lines),
        .zig_lang => buildZigModel(allocator, raw_lines, masked_lines),
    };
}

const TypeBuilder = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    kind: TypeKind,
    start_line: u32,
    end_line: u32,
    is_public: bool,
    fields: std.array_list.Managed(FieldInfo),
    lifecycle_bool_fields: std.array_list.Managed([]const u8),
    has_explicit_state: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        kind: TypeKind,
        start_line: u32,
        end_line: u32,
        is_public: bool,
    ) TypeBuilder {
        return .{
            .allocator = allocator,
            .name = name,
            .kind = kind,
            .start_line = start_line,
            .end_line = end_line,
            .is_public = is_public,
            .fields = std.array_list.Managed(FieldInfo).init(allocator),
            .lifecycle_bool_fields = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    fn addField(self: *TypeBuilder, name: []const u8, is_bool: bool) !void {
        if (name.len == 0) {
            return;
        }

        for (self.fields.items) |*field| {
            if (!std.mem.eql(u8, field.name, name)) {
                continue;
            }

            field.is_bool = field.is_bool or is_bool;
            field.is_lifecycle = field.is_lifecycle or (is_bool and isLifecycleFlagName(name));
            if (field.is_lifecycle) {
                try addUniqueString(&self.lifecycle_bool_fields, field.name);
            }
            return;
        }

        const lifecycle = is_bool and isLifecycleFlagName(name);
        try self.fields.append(.{
            .name = name,
            .is_bool = is_bool,
            .is_lifecycle = lifecycle,
        });
        if (lifecycle) {
            try addUniqueString(&self.lifecycle_bool_fields, name);
        }
    }

    fn finish(self: *TypeBuilder) !TypeInfo {
        return .{
            .name = self.name,
            .kind = self.kind,
            .start_line = self.start_line,
            .end_line = self.end_line,
            .is_public = self.is_public,
            .field_count = try types.usizeToU32(self.fields.items.len),
            .fields = try self.fields.toOwnedSlice(),
            .lifecycle_bool_fields = try self.lifecycle_bool_fields.toOwnedSlice(),
            .has_explicit_state = self.has_explicit_state,
        };
    }
};

const BodyBuilder = struct {
    allocator: std.mem.Allocator,
    declared: std.array_list.Managed([]const u8),
    touched: std.array_list.Managed([]const u8),
    bool_reads: std.array_list.Managed([]const u8),
    lifecycle_actions: std.array_list.Managed(LifecycleAction),
    has_explicit_scope_cleanup: bool = false,

    fn init(allocator: std.mem.Allocator) BodyBuilder {
        return .{
            .allocator = allocator,
            .declared = std.array_list.Managed([]const u8).init(allocator),
            .touched = std.array_list.Managed([]const u8).init(allocator),
            .bool_reads = std.array_list.Managed([]const u8).init(allocator),
            .lifecycle_actions = std.array_list.Managed(LifecycleAction).init(allocator),
        };
    }

    fn finish(self: *BodyBuilder) !BodySummary {
        return .{
            .declared = try self.declared.toOwnedSlice(),
            .touched = try self.touched.toOwnedSlice(),
            .bool_reads = try self.bool_reads.toOwnedSlice(),
            .lifecycle_actions = try self.lifecycle_actions.toOwnedSlice(),
            .has_explicit_scope_cleanup = self.has_explicit_scope_cleanup,
        };
    }
};

const BodySummary = struct {
    declared: []const []const u8,
    touched: []const []const u8,
    bool_reads: []const []const u8,
    lifecycle_actions: []const LifecycleAction,
    has_explicit_scope_cleanup: bool,
};

const SignatureBlock = struct {
    text: []const u8,
    open_line_idx: usize,
    end_line_idx: usize,
};

fn buildGoModel(
    allocator: std.mem.Allocator,
    raw_lines: []const []const u8,
    masked_lines: []const []const u8,
) !Model {
    var functions = std.array_list.Managed(FunctionInfo).init(allocator);
    var type_infos = std.array_list.Managed(TypeInfo).init(allocator);
    const scope_names = try collectGoScopeNames(allocator, raw_lines, masked_lines);

    var idx: usize = 0;
    while (idx < masked_lines.len) {
        const trimmed = std.mem.trimLeft(u8, masked_lines[idx], " \t");

        if (std.mem.startsWith(u8, trimmed, "type ") and std.mem.indexOf(u8, trimmed, "struct") != null) {
            const block = try collectBraceBlock(allocator, masked_lines, idx);
            const name = extractGoTypeName(block.text);
            if (name.len > 0) {
                var builder = TypeBuilder.init(
                    allocator,
                    name,
                    .go_struct,
                    try lineNumber(idx),
                    try lineNumber(block.end_line_idx),
                    isExportedName(name),
                );
                try scanGoStructFields(&builder, masked_lines, block.open_line_idx + 1, block.end_line_idx);
                try type_infos.append(try builder.finish());
            }
            idx = block.end_line_idx + 1;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "func ")) {
            const block = try collectBraceBlock(allocator, masked_lines, idx);
            const parsed = try parseGoFunctionSignature(allocator, block.text);
            if (parsed.name.len > 0) {
                const summary = try analyzeGoBody(
                    allocator,
                    masked_lines,
                    block.open_line_idx + 1,
                    block.end_line_idx,
                    parsed.receiver_name,
                    parsed.param_names,
                    scope_names,
                );
                try functions.append(.{
                    .name = parsed.name,
                    .owner_type = parsed.owner_type,
                    .receiver_name = parsed.receiver_name,
                    .start_line = try lineNumber(idx),
                    .body_start_line = if (block.open_line_idx + 1 < masked_lines.len) try lineNumber(block.open_line_idx + 1) else try lineNumber(idx),
                    .end_line = try lineNumber(block.end_line_idx),
                    .is_public = isExportedName(parsed.name),
                    .argument_count = parsed.argument_count,
                    .declared = summary.declared,
                    .touched = summary.touched,
                    .bool_reads = summary.bool_reads,
                    .lifecycle_actions = summary.lifecycle_actions,
                    .has_explicit_scope_cleanup = summary.has_explicit_scope_cleanup,
                });
            }
            idx = block.end_line_idx + 1;
            continue;
        }

        idx += 1;
    }

    return .{
        .functions = try functions.toOwnedSlice(),
        .types = try type_infos.toOwnedSlice(),
    };
}

fn buildTypeScriptModel(
    allocator: std.mem.Allocator,
    raw_lines: []const []const u8,
    masked_lines: []const []const u8,
) !Model {
    var functions = std.array_list.Managed(FunctionInfo).init(allocator);
    var type_infos = std.array_list.Managed(TypeInfo).init(allocator);
    const scope_names = try collectTypeScriptScopeNames(allocator, raw_lines, masked_lines);

    var idx: usize = 0;
    while (idx < masked_lines.len) {
        const trimmed = std.mem.trimLeft(u8, masked_lines[idx], " \t");

        if (looksLikeTsClassDecl(trimmed)) {
            const block = try collectBraceBlock(allocator, masked_lines, idx);
            const name = extractTsNamedDeclName(block.text, "class");
            if (name.len > 0) {
                var builder = TypeBuilder.init(
                    allocator,
                    name,
                    .typescript_class,
                    try lineNumber(idx),
                    try lineNumber(block.end_line_idx),
                    std.mem.startsWith(u8, trimmed, "export "),
                );
                try scanTypeScriptClass(
                    allocator,
                    masked_lines,
                    masked_lines,
                    block.open_line_idx + 1,
                    block.end_line_idx,
                    name,
                    scope_names,
                    &builder,
                    &functions,
                );
                try type_infos.append(try builder.finish());
            }
            idx = block.end_line_idx + 1;
            continue;
        }

        if (looksLikeTsInterfaceDecl(trimmed)) {
            const block = try collectBraceBlock(allocator, masked_lines, idx);
            const name = extractTsNamedDeclName(block.text, "interface");
            if (name.len > 0) {
                var builder = TypeBuilder.init(
                    allocator,
                    name,
                    .typescript_interface,
                    try lineNumber(idx),
                    try lineNumber(block.end_line_idx),
                    std.mem.startsWith(u8, trimmed, "export "),
                );
                try scanTypeScriptShapeFields(&builder, masked_lines, block.open_line_idx + 1, block.end_line_idx);
                try type_infos.append(try builder.finish());
            }
            idx = block.end_line_idx + 1;
            continue;
        }

        if (looksLikeTsObjectTypeDecl(trimmed)) {
            const block = try collectBraceBlock(allocator, masked_lines, idx);
            const name = extractTsTypeAliasName(block.text);
            if (name.len > 0) {
                var builder = TypeBuilder.init(
                    allocator,
                    name,
                    .typescript_object,
                    try lineNumber(idx),
                    try lineNumber(block.end_line_idx),
                    std.mem.startsWith(u8, trimmed, "export "),
                );
                try scanTypeScriptShapeFields(&builder, masked_lines, block.open_line_idx + 1, block.end_line_idx);
                try type_infos.append(try builder.finish());
            }
            idx = block.end_line_idx + 1;
            continue;
        }

        if (looksLikeTsFunctionDecl(trimmed)) {
            const block = try collectBraceBlock(allocator, masked_lines, idx);
            const parsed = try parseTsFunctionSignature(allocator, block.text, false, "");
            if (parsed.name.len > 0) {
                const summary = try analyzeTypeScriptBody(
                    allocator,
                    masked_lines,
                    block.open_line_idx + 1,
                    block.end_line_idx,
                    "",
                    parsed.param_names,
                    scope_names,
                );
                try functions.append(.{
                    .name = parsed.name,
                    .start_line = try lineNumber(idx),
                    .body_start_line = if (block.open_line_idx + 1 < masked_lines.len) try lineNumber(block.open_line_idx + 1) else try lineNumber(idx),
                    .end_line = try lineNumber(block.end_line_idx),
                    .is_public = parsed.is_public,
                    .argument_count = parsed.argument_count,
                    .declared = summary.declared,
                    .touched = summary.touched,
                    .bool_reads = summary.bool_reads,
                    .lifecycle_actions = summary.lifecycle_actions,
                    .has_explicit_scope_cleanup = summary.has_explicit_scope_cleanup,
                });
            }
            idx = block.end_line_idx + 1;
            continue;
        }

        idx += 1;
    }

    return .{
        .functions = try functions.toOwnedSlice(),
        .types = try type_infos.toOwnedSlice(),
    };
}

fn buildPythonModel(
    allocator: std.mem.Allocator,
    raw_lines: []const []const u8,
    masked_lines: []const []const u8,
) !Model {
    var functions = std.array_list.Managed(FunctionInfo).init(allocator);
    var type_infos = std.array_list.Managed(TypeInfo).init(allocator);
    const scope_names = try collectPythonScopeNames(allocator, raw_lines);

    var idx: usize = 0;
    while (idx < masked_lines.len) {
        const trimmed = std.mem.trimLeft(u8, masked_lines[idx], " \t");

        if (std.mem.startsWith(u8, trimmed, "class ")) {
            const class_end = findPythonBlockEnd(masked_lines, idx);
            const class_name = extractPythonClassName(trimmed);
            if (class_name.len > 0) {
                var builder = TypeBuilder.init(
                    allocator,
                    class_name,
                    .python_class,
                    try lineNumber(idx),
                    try lineNumber(class_end),
                    !isPrivatePythonName(class_name),
                );
                try scanPythonClass(
                    allocator,
                    raw_lines,
                    masked_lines,
                    masked_lines,
                    idx,
                    class_end,
                    class_name,
                    scope_names,
                    &builder,
                    &functions,
                );
                try type_infos.append(try builder.finish());
            }
            idx = class_end + 1;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "def ") or std.mem.startsWith(u8, trimmed, "async def ")) {
            const signature = try collectPythonSignature(allocator, masked_lines, idx);
            const func_end = findPythonBlockEnd(masked_lines, idx);
            const parsed = try parsePythonFunctionSignature(allocator, signature.text, false, "");
            if (parsed.name.len > 0) {
                const summary = try analyzePythonBody(
                    allocator,
                    masked_lines,
                    idx + 1,
                    func_end + 1,
                    "",
                    parsed.param_names,
                    scope_names,
                );
                try functions.append(.{
                    .name = parsed.name,
                    .start_line = try lineNumber(idx),
                    .body_start_line = if (idx + 1 < masked_lines.len) try lineNumber(idx + 1) else try lineNumber(idx),
                    .end_line = try lineNumber(func_end),
                    .is_public = parsed.is_public,
                    .argument_count = parsed.argument_count,
                    .declared = summary.declared,
                    .touched = summary.touched,
                    .bool_reads = summary.bool_reads,
                    .lifecycle_actions = summary.lifecycle_actions,
                    .has_explicit_scope_cleanup = summary.has_explicit_scope_cleanup,
                });
            }
            idx = func_end + 1;
            continue;
        }

        idx += 1;
    }

    return .{
        .functions = try functions.toOwnedSlice(),
        .types = try type_infos.toOwnedSlice(),
    };
}

fn buildZigModel(
    allocator: std.mem.Allocator,
    raw_lines: []const []const u8,
    masked_lines: []const []const u8,
) !Model {
    var functions = std.array_list.Managed(FunctionInfo).init(allocator);
    var type_infos = std.array_list.Managed(TypeInfo).init(allocator);
    const scope_names = try collectZigScopeNames(allocator, raw_lines, masked_lines);

    var idx: usize = 0;
    while (idx < masked_lines.len) {
        const trimmed = std.mem.trimLeft(u8, masked_lines[idx], " \t");

        if (looksLikeZigStructDecl(trimmed)) {
            const block = try collectBraceBlock(allocator, masked_lines, idx);
            const name = extractZigStructName(trimmed);
            if (name.len > 0) {
                var builder = TypeBuilder.init(
                    allocator,
                    name,
                    .zig_struct,
                    try lineNumber(idx),
                    try lineNumber(block.end_line_idx),
                    std.mem.startsWith(u8, trimmed, "pub const "),
                );
                try scanZigStruct(
                    allocator,
                    masked_lines,
                    masked_lines,
                    block.open_line_idx + 1,
                    block.end_line_idx,
                    name,
                    scope_names,
                    &builder,
                    &functions,
                );
                try type_infos.append(try builder.finish());
            }
            idx = block.end_line_idx + 1;
            continue;
        }

        if (looksLikeZigFunctionDecl(trimmed)) {
            const block = try collectBraceBlock(allocator, masked_lines, idx);
            const signature_text = if (std.mem.startsWith(u8, trimmed, "test "))
                std.mem.trim(u8, raw_lines[idx], " \t")
            else
                block.text;
            const parsed = try parseZigFunctionSignature(allocator, signature_text, "");
            if (parsed.name.len > 0) {
                const summary = try analyzeZigBody(
                    allocator,
                    masked_lines,
                    block.open_line_idx + 1,
                    block.end_line_idx,
                    parsed.receiver_name,
                    parsed.param_names,
                    scope_names,
                );
                try functions.append(.{
                    .name = parsed.name,
                    .owner_type = parsed.owner_type,
                    .receiver_name = parsed.receiver_name,
                    .start_line = try lineNumber(idx),
                    .body_start_line = if (block.open_line_idx + 1 < masked_lines.len) try lineNumber(block.open_line_idx + 1) else try lineNumber(idx),
                    .end_line = try lineNumber(block.end_line_idx),
                    .is_public = parsed.is_public,
                    .argument_count = parsed.argument_count,
                    .declared = summary.declared,
                    .touched = summary.touched,
                    .bool_reads = summary.bool_reads,
                    .lifecycle_actions = summary.lifecycle_actions,
                    .has_explicit_scope_cleanup = summary.has_explicit_scope_cleanup,
                });
            }
            idx = block.end_line_idx + 1;
            continue;
        }

        idx += 1;
    }

    return .{
        .functions = try functions.toOwnedSlice(),
        .types = try type_infos.toOwnedSlice(),
    };
}

const ParsedFunction = struct {
    name: []const u8,
    owner_type: []const u8 = "",
    receiver_name: []const u8 = "",
    argument_count: u32,
    is_public: bool,
    param_names: []const []const u8 = &.{},
};

fn parseGoFunctionSignature(allocator: std.mem.Allocator, signature: []const u8) !ParsedFunction {
    if (!std.mem.startsWith(u8, signature, "func ")) {
        return .{ .name = "", .argument_count = 0, .is_public = false };
    }

    var rest = std.mem.trimLeft(u8, signature["func ".len..], " \t");
    var receiver_name: []const u8 = "";
    var owner_type: []const u8 = "";

    if (rest.len > 0 and rest[0] == '(') {
        const receiver_end = findMatchingForward(rest, 0, '(', ')') orelse return .{ .name = "", .argument_count = 0, .is_public = false };
        const receiver_segment = std.mem.trim(u8, rest[1..receiver_end], " \t");
        receiver_name = firstIdentifier(receiver_segment);
        owner_type = lastTypeIdentifier(receiver_segment);
        rest = std.mem.trimLeft(u8, rest[receiver_end + 1 ..], " \t");
    }

    const name = firstIdentifier(rest);
    if (name.len == 0) {
        return .{ .name = "", .argument_count = 0, .is_public = false };
    }

    const name_end = scanIdentifier(rest, 0);
    const params_open = std.mem.indexOfScalarPos(u8, rest, name_end, '(') orelse return .{ .name = "", .argument_count = 0, .is_public = false };
    const params_close = findMatchingForward(rest, params_open, '(', ')') orelse return .{ .name = "", .argument_count = 0, .is_public = false };
    const param_segment = rest[params_open + 1 .. params_close];

    const param_names = try parseGoParamNames(allocator, param_segment);
    return .{
        .name = name,
        .owner_type = owner_type,
        .receiver_name = receiver_name,
        .argument_count = try types.usizeToU32(param_names.len),
        .is_public = isExportedName(name),
        .param_names = param_names,
    };
}

fn parseTsFunctionSignature(
    allocator: std.mem.Allocator,
    signature: []const u8,
    is_method: bool,
    owner_type: []const u8,
) !ParsedFunction {
    var text = std.mem.trim(u8, signature, " \t");
    var is_public = std.mem.startsWith(u8, text, "export ");
    var name: []const u8 = "";

    if (std.mem.indexOf(u8, text, "function ")) |pos| {
        const after = text[pos + "function ".len ..];
        name = firstIdentifier(after);
    } else if (std.mem.indexOf(u8, text, "=>")) |_| {
        const eq_pos = std.mem.indexOfScalar(u8, text, '=') orelse return .{ .name = "", .argument_count = 0, .is_public = false };
        name = lastTypeIdentifier(text[0..eq_pos]);
    } else if (is_method) {
        name = extractTsMethodName(text);
        if (name.len > 0 and !startsWithAny(text, &[_][]const u8{ "private ", "protected ", "#" })) {
            is_public = true;
        }
    }

    if (name.len == 0) {
        return .{ .name = "", .argument_count = 0, .is_public = false };
    }

    const params_open = std.mem.indexOfScalar(u8, text, '(') orelse return .{ .name = "", .argument_count = 0, .is_public = false };
    const params_close = findMatchingForward(text, params_open, '(', ')') orelse return .{ .name = "", .argument_count = 0, .is_public = false };
    const param_segment = text[params_open + 1 .. params_close];
    const param_names = try parseTypeScriptParamNames(allocator, param_segment, is_method);

    return .{
        .name = name,
        .owner_type = owner_type,
        .receiver_name = if (is_method) "this" else "",
        .argument_count = try types.usizeToU32(param_names.len),
        .is_public = if (is_method) !startsWithAny(text, &[_][]const u8{ "private ", "protected ", "#" }) else is_public,
        .param_names = param_names,
    };
}

fn parsePythonFunctionSignature(
    allocator: std.mem.Allocator,
    signature: []const u8,
    is_method: bool,
    owner_type: []const u8,
) !ParsedFunction {
    var text = std.mem.trim(u8, signature, " \t");
    if (std.mem.startsWith(u8, text, "async def ")) {
        text = text["async def ".len..];
    } else if (std.mem.startsWith(u8, text, "def ")) {
        text = text["def ".len..];
    }

    const name = firstIdentifier(text);
    if (name.len == 0) {
        return .{ .name = "", .argument_count = 0, .is_public = false };
    }

    const params_open = std.mem.indexOfScalar(u8, text, '(') orelse return .{ .name = "", .argument_count = 0, .is_public = false };
    const params_close = findMatchingForward(text, params_open, '(', ')') orelse return .{ .name = "", .argument_count = 0, .is_public = false };
    const param_segment = text[params_open + 1 .. params_close];
    const param_names = try parsePythonParamNames(allocator, param_segment, is_method);

    return .{
        .name = name,
        .owner_type = owner_type,
        .receiver_name = if (is_method) "self" else "",
        .argument_count = try types.usizeToU32(param_names.len),
        .is_public = !isPrivatePythonName(name),
        .param_names = param_names,
    };
}

fn parseZigFunctionSignature(
    allocator: std.mem.Allocator,
    signature: []const u8,
    owner_hint: []const u8,
) !ParsedFunction {
    const text = std.mem.trim(u8, signature, " \t");
    if (std.mem.startsWith(u8, text, "test ")) {
        return .{
            .name = extractZigTestName(text),
            .owner_type = owner_hint,
            .argument_count = 0,
            .is_public = false,
        };
    }
    if (!looksLikeZigFunctionDecl(text)) {
        return .{ .name = "", .argument_count = 0, .is_public = false };
    }

    const fn_pos = std.mem.indexOf(u8, text, "fn ") orelse return .{ .name = "", .argument_count = 0, .is_public = false };
    const after = text[fn_pos + "fn ".len ..];
    const name = firstIdentifier(after);
    if (name.len == 0) {
        return .{ .name = "", .argument_count = 0, .is_public = false };
    }

    const name_end = scanIdentifier(after, 0);
    const params_open = std.mem.indexOfScalarPos(u8, after, name_end, '(') orelse return .{ .name = "", .argument_count = 0, .is_public = false };
    const params_close = findMatchingForward(after, params_open, '(', ')') orelse return .{ .name = "", .argument_count = 0, .is_public = false };
    const param_segment = after[params_open + 1 .. params_close];
    const parsed_params = try parseZigParams(allocator, param_segment, owner_hint);

    return .{
        .name = name,
        .owner_type = parsed_params.owner_type,
        .receiver_name = parsed_params.receiver_name,
        .argument_count = try types.usizeToU32(parsed_params.param_names.len),
        .is_public = std.mem.startsWith(u8, text, "pub fn ") or std.mem.startsWith(u8, text, "export fn "),
        .param_names = parsed_params.param_names,
    };
}

const ZigParamParse = struct {
    owner_type: []const u8,
    receiver_name: []const u8,
    param_names: []const []const u8,
};

fn parseZigParams(allocator: std.mem.Allocator, params: []const u8, owner_hint: []const u8) !ZigParamParse {
    const segments = try topLevelSegments(allocator, params);
    var names = std.array_list.Managed([]const u8).init(allocator);
    var receiver_name: []const u8 = "";
    var owner_type = owner_hint;

    for (segments, 0..) |segment, idx| {
        const trimmed = std.mem.trim(u8, segment, " \t");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "...")) {
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const name = std.mem.trim(u8, trimmed[0..colon], " \t");
        const type_part = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");

        if (idx == 0 and (std.mem.eql(u8, name, "self") or std.mem.eql(u8, name, "this"))) {
            receiver_name = name;
            if (owner_type.len == 0) {
                owner_type = lastTypeIdentifier(type_part);
            }
            continue;
        }

        if (name.len > 0 and !std.mem.eql(u8, name, "_")) {
            try addUniqueString(&names, name);
        }
    }

    return .{
        .owner_type = owner_type,
        .receiver_name = receiver_name,
        .param_names = try names.toOwnedSlice(),
    };
}

fn scanGoStructFields(
    builder: *TypeBuilder,
    lines: []const []const u8,
    start_idx: usize,
    end_idx: usize,
) !void {
    var depth: i32 = 0;
    var idx = start_idx;
    while (idx < end_idx) : (idx += 1) {
        const trimmed = std.mem.trimLeft(u8, lines[idx], " \t");
        if (trimmed.len == 0) {
            continue;
        }
        if (depth == 0) {
            const field_name = extractGoStructFieldName(trimmed);
            if (field_name.len > 0) {
                const is_bool = std.mem.indexOf(u8, trimmed, " bool") != null or std.mem.endsWith(u8, trimmed, "bool");
                try builder.addField(field_name, is_bool);
                if (isExplicitStateField(field_name, trimmed, is_bool)) {
                    builder.has_explicit_state = true;
                }
            }
        }
        depth += braceDelta(trimmed);
    }
}

fn scanTypeScriptClass(
    allocator: std.mem.Allocator,
    body_lines: []const []const u8,
    masked_lines: []const []const u8,
    start_idx: usize,
    end_idx: usize,
    class_name: []const u8,
    scope_names: []const []const u8,
    builder: *TypeBuilder,
    functions: *std.array_list.Managed(FunctionInfo),
) !void {
    var idx = start_idx;
    while (idx < end_idx) {
        const trimmed = std.mem.trimLeft(u8, masked_lines[idx], " \t");
        if (trimmed.len == 0) {
            idx += 1;
            continue;
        }

        if (looksLikeTsMethodDecl(trimmed)) {
            const block = try collectBraceBlock(allocator, masked_lines, idx);
            if (block.end_line_idx > end_idx) {
                break;
            }
            const parsed = try parseTsFunctionSignature(allocator, block.text, true, class_name);
            if (parsed.name.len > 0) {
                const summary = try analyzeTypeScriptBody(
                    allocator,
                    body_lines,
                    block.open_line_idx + 1,
                    block.end_line_idx,
                    "this",
                    parsed.param_names,
                    scope_names,
                );
                try functions.append(.{
                    .name = parsed.name,
                    .owner_type = class_name,
                    .receiver_name = "this",
                    .start_line = try lineNumber(idx),
                    .body_start_line = if (block.open_line_idx + 1 < masked_lines.len) try lineNumber(block.open_line_idx + 1) else try lineNumber(idx),
                    .end_line = try lineNumber(block.end_line_idx),
                    .is_public = parsed.is_public,
                    .argument_count = parsed.argument_count,
                    .declared = summary.declared,
                    .touched = summary.touched,
                    .bool_reads = summary.bool_reads,
                    .lifecycle_actions = summary.lifecycle_actions,
                    .has_explicit_scope_cleanup = summary.has_explicit_scope_cleanup,
                });
            }
            idx = block.end_line_idx + 1;
            continue;
        }

        const field_name = extractTsClassFieldName(trimmed);
        if (field_name.len > 0) {
            const is_bool = std.mem.indexOf(u8, trimmed, ": boolean") != null or
                std.mem.indexOf(u8, trimmed, "= true") != null or
                std.mem.indexOf(u8, trimmed, "= false") != null;
            try builder.addField(field_name, is_bool);
            if (isExplicitStateField(field_name, trimmed, is_bool)) {
                builder.has_explicit_state = true;
            }
        }

        idx += 1;
    }
}

fn scanTypeScriptShapeFields(
    builder: *TypeBuilder,
    lines: []const []const u8,
    start_idx: usize,
    end_idx: usize,
) !void {
    var idx = start_idx;
    while (idx < end_idx) : (idx += 1) {
        const trimmed = std.mem.trimLeft(u8, lines[idx], " \t");
        if (trimmed.len == 0) {
            continue;
        }

        const field_name = extractTsShapeFieldName(trimmed);
        if (field_name.len == 0) {
            continue;
        }

        const is_bool = std.mem.indexOf(u8, trimmed, ": boolean") != null;
        try builder.addField(field_name, is_bool);
        if (isExplicitStateField(field_name, trimmed, is_bool)) {
            builder.has_explicit_state = true;
        }
    }
}

fn scanPythonClass(
    allocator: std.mem.Allocator,
    raw_lines: []const []const u8,
    body_lines: []const []const u8,
    masked_lines: []const []const u8,
    class_idx: usize,
    class_end: usize,
    class_name: []const u8,
    scope_names: []const []const u8,
    builder: *TypeBuilder,
    functions: *std.array_list.Managed(FunctionInfo),
) !void {
    const class_indent = types.leadingWhitespace(masked_lines[class_idx]);
    var idx = class_idx + 1;
    while (idx <= class_end) {
        const trimmed = std.mem.trimLeft(u8, masked_lines[idx], " \t");
        const ws = types.leadingWhitespace(masked_lines[idx]);
        if (trimmed.len == 0 or ws <= class_indent) {
            idx += 1;
            continue;
        }

        if (ws == class_indent + 4 and looksLikePythonFieldLine(trimmed)) {
            const field_name = firstIdentifier(trimmed);
            const is_bool = std.mem.indexOf(u8, trimmed, ": bool") != null or
                std.mem.indexOf(u8, trimmed, "= True") != null or
                std.mem.indexOf(u8, trimmed, "= False") != null;
            try builder.addField(field_name, is_bool);
            if (isExplicitStateField(field_name, trimmed, is_bool)) {
                builder.has_explicit_state = true;
            }
            idx += 1;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "def ") or std.mem.startsWith(u8, trimmed, "async def ")) {
            const signature = try collectPythonSignature(allocator, masked_lines, idx);
            const func_end = findPythonBlockEnd(masked_lines, idx);
            const parsed = try parsePythonFunctionSignature(allocator, signature.text, true, class_name);
            if (parsed.name.len > 0) {
                const summary = try analyzePythonBody(
                    allocator,
                    body_lines,
                    idx + 1,
                    func_end + 1,
                    "self",
                    parsed.param_names,
                    scope_names,
                );
                try functions.append(.{
                    .name = parsed.name,
                    .owner_type = class_name,
                    .receiver_name = "self",
                    .start_line = try lineNumber(idx),
                    .body_start_line = if (idx + 1 < masked_lines.len) try lineNumber(idx + 1) else try lineNumber(idx),
                    .end_line = try lineNumber(func_end),
                    .is_public = parsed.is_public,
                    .argument_count = parsed.argument_count,
                    .declared = summary.declared,
                    .touched = summary.touched,
                    .bool_reads = summary.bool_reads,
                    .lifecycle_actions = summary.lifecycle_actions,
                    .has_explicit_scope_cleanup = summary.has_explicit_scope_cleanup,
                });
                if (std.mem.eql(u8, parsed.name, "__init__")) {
                    try collectPythonInitFields(builder, raw_lines, idx + 1, func_end + 1);
                }
            }
            idx = func_end + 1;
            continue;
        }

        idx += 1;
    }
}

fn collectPythonInitFields(
    builder: *TypeBuilder,
    raw_lines: []const []const u8,
    start_idx: usize,
    end_idx: usize,
) !void {
    var idx = start_idx;
    while (idx < end_idx) : (idx += 1) {
        const line = raw_lines[idx];
        if (std.mem.indexOf(u8, line, "self.")) |pos| {
            const after = line[pos + "self.".len ..];
            const name = firstIdentifier(after);
            if (name.len == 0) {
                continue;
            }
            const eq_pos = std.mem.indexOfScalar(u8, after, '=') orelse continue;
            const rhs = std.mem.trim(u8, after[eq_pos + 1 ..], " \t");
            const is_bool = std.mem.startsWith(u8, rhs, "True") or std.mem.startsWith(u8, rhs, "False");
            try builder.addField(name, is_bool);
            if (isExplicitStateField(name, rhs, is_bool)) {
                builder.has_explicit_state = true;
            }
        }
    }
}

fn scanZigStruct(
    allocator: std.mem.Allocator,
    body_lines: []const []const u8,
    masked_lines: []const []const u8,
    start_idx: usize,
    end_idx: usize,
    struct_name: []const u8,
    scope_names: []const []const u8,
    builder: *TypeBuilder,
    functions: *std.array_list.Managed(FunctionInfo),
) !void {
    var idx = start_idx;
    while (idx < end_idx) {
        const trimmed = std.mem.trimLeft(u8, masked_lines[idx], " \t");
        if (trimmed.len == 0) {
            idx += 1;
            continue;
        }

        if (looksLikeZigFunctionDecl(trimmed)) {
            const block = try collectBraceBlock(allocator, masked_lines, idx);
            if (block.end_line_idx > end_idx) {
                break;
            }
            const parsed = try parseZigFunctionSignature(allocator, block.text, struct_name);
            if (parsed.name.len > 0) {
                const summary = try analyzeZigBody(
                    allocator,
                    body_lines,
                    block.open_line_idx + 1,
                    block.end_line_idx,
                    parsed.receiver_name,
                    parsed.param_names,
                    scope_names,
                );
                try functions.append(.{
                    .name = parsed.name,
                    .owner_type = parsed.owner_type,
                    .receiver_name = parsed.receiver_name,
                    .start_line = try lineNumber(idx),
                    .body_start_line = if (block.open_line_idx + 1 < masked_lines.len) try lineNumber(block.open_line_idx + 1) else try lineNumber(idx),
                    .end_line = try lineNumber(block.end_line_idx),
                    .is_public = parsed.is_public,
                    .argument_count = parsed.argument_count,
                    .declared = summary.declared,
                    .touched = summary.touched,
                    .bool_reads = summary.bool_reads,
                    .lifecycle_actions = summary.lifecycle_actions,
                    .has_explicit_scope_cleanup = summary.has_explicit_scope_cleanup,
                });
            }
            idx = block.end_line_idx + 1;
            continue;
        }

        const field_name = extractZigStructFieldName(trimmed);
        if (field_name.len > 0) {
            const is_bool = std.mem.indexOf(u8, trimmed, ": bool") != null or std.mem.indexOf(u8, trimmed, ":bool") != null;
            try builder.addField(field_name, is_bool);
            if (isExplicitStateField(field_name, trimmed, is_bool)) {
                builder.has_explicit_state = true;
            }
        }

        idx += 1;
    }
}

fn analyzeGoBody(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    start_idx: usize,
    end_idx: usize,
    receiver_name: []const u8,
    param_names: []const []const u8,
    scope_names: []const []const u8,
) !BodySummary {
    var body = BodyBuilder.init(allocator);
    try seedDeclaredNames(&body.declared, param_names);
    if (receiver_name.len > 0) {
        try addUniqueString(&body.declared, receiver_name);
    }

    var idx = start_idx;
    while (idx < end_idx and idx < lines.len) : (idx += 1) {
        const line = lines[idx];
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0) {
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "defer ")) {
            body.has_explicit_scope_cleanup = true;
            continue;
        }

        try appendGoDeclarations(&body.declared, trimmed);
        try appendCommonTouches(&body, trimmed, receiver_name, &go_keywords, scope_names, &go_builtins);
        try appendLifecycleActions(&body.lifecycle_actions, allocator, trimmed, try lineNumber(idx));
    }

    return body.finish();
}

fn analyzeTypeScriptBody(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    start_idx: usize,
    end_idx: usize,
    receiver_name: []const u8,
    param_names: []const []const u8,
    scope_names: []const []const u8,
) !BodySummary {
    var body = BodyBuilder.init(allocator);
    try seedDeclaredNames(&body.declared, param_names);

    var idx = start_idx;
    while (idx < end_idx and idx < lines.len) : (idx += 1) {
        const line = lines[idx];
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0) {
            continue;
        }

        try appendTypeScriptDeclarations(&body.declared, trimmed);
        try appendCommonTouches(&body, trimmed, receiver_name, &typescript_keywords, scope_names, &typescript_builtins);
        try appendLifecycleActions(&body.lifecycle_actions, allocator, trimmed, try lineNumber(idx));
    }

    return body.finish();
}

fn analyzePythonBody(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    start_idx: usize,
    end_idx: usize,
    receiver_name: []const u8,
    param_names: []const []const u8,
    scope_names: []const []const u8,
) !BodySummary {
    var body = BodyBuilder.init(allocator);
    try seedDeclaredNames(&body.declared, param_names);

    var idx = start_idx;
    while (idx < end_idx and idx < lines.len) : (idx += 1) {
        const line = lines[idx];
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0) {
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "with ") or std.mem.startsWith(u8, trimmed, "finally:")) {
            body.has_explicit_scope_cleanup = true;
        }

        try appendPythonDeclarations(&body.declared, trimmed);
        try appendCommonTouches(&body, trimmed, receiver_name, &python_keywords, scope_names, &python_builtins);
        try appendLifecycleActions(&body.lifecycle_actions, allocator, trimmed, try lineNumber(idx));
    }

    return body.finish();
}

fn analyzeZigBody(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    start_idx: usize,
    end_idx: usize,
    receiver_name: []const u8,
    param_names: []const []const u8,
    scope_names: []const []const u8,
) !BodySummary {
    var body = BodyBuilder.init(allocator);
    try seedDeclaredNames(&body.declared, param_names);
    if (receiver_name.len > 0) {
        try addUniqueString(&body.declared, receiver_name);
    }

    var idx = start_idx;
    while (idx < end_idx and idx < lines.len) : (idx += 1) {
        const line = lines[idx];
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0) {
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "defer ") or std.mem.startsWith(u8, trimmed, "errdefer ")) {
            body.has_explicit_scope_cleanup = true;
        }

        try appendZigDeclarations(&body.declared, trimmed);
        try appendCommonTouches(&body, trimmed, receiver_name, &zig_keywords, scope_names, &zig_builtins);
        try appendLifecycleActions(&body.lifecycle_actions, allocator, trimmed, try lineNumber(idx));
    }

    return body.finish();
}

fn appendCommonTouches(
    body: *BodyBuilder,
    line: []const u8,
    receiver_name: []const u8,
    keywords: []const []const u8,
    scope_names: []const []const u8,
    builtins: []const []const u8,
) !void {
    try appendReceiverTouches(body.allocator, &body.touched, &body.bool_reads, line, receiver_name);
    try appendDottedRootTouches(&body.touched, &body.declared, line, receiver_name, keywords, scope_names, builtins);
    try appendFreeCallTouches(&body.touched, &body.declared, line, keywords, scope_names, builtins);
}

fn collectGoScopeNames(
    allocator: std.mem.Allocator,
    raw_lines: []const []const u8,
    masked_lines: []const []const u8,
) ![]const []const u8 {
    var names = std.array_list.Managed([]const u8).init(allocator);
    var depth: i32 = 0;
    var in_import_block = false;

    for (raw_lines, masked_lines) |raw_line, masked_line| {
        const raw_trimmed = std.mem.trimLeft(u8, raw_line, " \t");
        const masked_trimmed = std.mem.trimLeft(u8, masked_line, " \t");

        if (depth == 0) {
            if (in_import_block) {
                if (std.mem.eql(u8, raw_trimmed, ")")) {
                    in_import_block = false;
                } else if (extractGoImportName(raw_trimmed)) |import_name| {
                    try addUniqueString(&names, import_name);
                }
            } else if (std.mem.eql(u8, raw_trimmed, "import (")) {
                in_import_block = true;
            } else if (std.mem.startsWith(u8, raw_trimmed, "import ")) {
                if (extractGoImportName(raw_trimmed["import ".len..])) |import_name| {
                    try addUniqueString(&names, import_name);
                }
            } else if (std.mem.startsWith(u8, masked_trimmed, "func ")) {
                try addUniqueString(&names, extractGoScopeFunctionName(masked_trimmed));
            } else if (std.mem.startsWith(u8, masked_trimmed, "type ")) {
                try addUniqueString(&names, extractGoTypeName(masked_trimmed));
            } else if (std.mem.startsWith(u8, masked_trimmed, "var ") or std.mem.startsWith(u8, masked_trimmed, "const ")) {
                const rest = if (std.mem.startsWith(u8, masked_trimmed, "var ")) masked_trimmed["var ".len..] else masked_trimmed["const ".len..];
                try appendDelimitedNames(&names, rest);
            }
        }

        depth += braceDelta(masked_trimmed);
    }

    return names.toOwnedSlice();
}

fn collectTypeScriptScopeNames(
    allocator: std.mem.Allocator,
    raw_lines: []const []const u8,
    masked_lines: []const []const u8,
) ![]const []const u8 {
    var names = std.array_list.Managed([]const u8).init(allocator);
    var depth: i32 = 0;
    var in_named_import_block = false;

    for (raw_lines, masked_lines) |raw_line, masked_line| {
        const raw_trimmed = std.mem.trimLeft(u8, raw_line, " \t");
        const masked_trimmed = std.mem.trimLeft(u8, masked_line, " \t");

        if (depth == 0) {
            if (in_named_import_block) {
                try appendTypeScriptNamedImportItems(&names, masked_trimmed);
                if (std.mem.indexOfScalar(u8, masked_trimmed, '}') != null) {
                    in_named_import_block = false;
                }
            } else if (std.mem.startsWith(u8, masked_trimmed, "import ")) {
                try appendTypeScriptImportBindings(&names, raw_trimmed, masked_trimmed, &in_named_import_block);
            } else if (looksLikeTsClassDecl(masked_trimmed)) {
                try addUniqueString(&names, extractTsNamedDeclName(masked_trimmed, "class"));
            } else if (looksLikeTsInterfaceDecl(masked_trimmed)) {
                try addUniqueString(&names, extractTsNamedDeclName(masked_trimmed, "interface"));
            } else if (looksLikeTsObjectTypeDecl(masked_trimmed)) {
                try addUniqueString(&names, extractTsTypeAliasName(masked_trimmed));
            } else if (looksLikeTsFunctionDecl(masked_trimmed)) {
                try addUniqueString(&names, extractTypeScriptScopeFunctionName(masked_trimmed));
            } else if (startsWithAny(masked_trimmed, &[_][]const u8{ "const ", "let ", "var ", "export const ", "export let ", "export var " })) {
                if (std.mem.indexOfScalar(u8, masked_trimmed, '=')) |eq| {
                    try appendDelimitedNames(&names, extractTypeScriptBindingPrefix(masked_trimmed[0..eq]));
                }
            }
        }

        depth += braceDelta(masked_trimmed);
    }

    return names.toOwnedSlice();
}

fn collectPythonScopeNames(
    allocator: std.mem.Allocator,
    raw_lines: []const []const u8,
) ![]const []const u8 {
    var names = std.array_list.Managed([]const u8).init(allocator);

    for (raw_lines) |line| {
        if (types.leadingWhitespace(line) != 0) {
            continue;
        }

        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0) {
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "import ")) {
            try appendPythonImportNames(&names, trimmed["import ".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "from ")) {
            if (std.mem.indexOf(u8, trimmed, " import ")) |pos| {
                try appendPythonFromImportNames(&names, trimmed[pos + " import ".len ..]);
            }
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "def ") or std.mem.startsWith(u8, trimmed, "async def ")) {
            try addUniqueString(&names, extractPythonScopeFunctionName(trimmed));
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "class ")) {
            try addUniqueString(&names, extractPythonClassName(trimmed));
            continue;
        }
        if (findPythonAssignmentOperator(trimmed)) |pos| {
            try appendDelimitedNames(&names, trimmed[0..pos]);
        }
    }

    return names.toOwnedSlice();
}

fn collectZigScopeNames(
    allocator: std.mem.Allocator,
    raw_lines: []const []const u8,
    masked_lines: []const []const u8,
) ![]const []const u8 {
    var names = std.array_list.Managed([]const u8).init(allocator);
    var depth: i32 = 0;

    for (raw_lines, masked_lines) |raw_line, masked_line| {
        const raw_trimmed = std.mem.trimLeft(u8, raw_line, " \t");
        const masked_trimmed = std.mem.trimLeft(u8, masked_line, " \t");

        if (depth == 0) {
            if (startsWithAny(masked_trimmed, &[_][]const u8{ "const ", "var ", "pub const ", "pub var " })) {
                if (std.mem.indexOfScalar(u8, masked_trimmed, '=')) |eq| {
                    try appendDelimitedNames(&names, extractZigBindingPrefix(masked_trimmed[0..eq]));
                }
            }
            if (looksLikeZigFunctionDecl(masked_trimmed)) {
                try addUniqueString(&names, extractZigScopeFunctionName(raw_trimmed));
            }
        }

        depth += braceDelta(masked_trimmed);
    }

    return names.toOwnedSlice();
}

fn appendReceiverTouches(
    allocator: std.mem.Allocator,
    touched: *std.array_list.Managed([]const u8),
    bool_reads: *std.array_list.Managed([]const u8),
    line: []const u8,
    receiver_name: []const u8,
) !void {
    if (receiver_name.len == 0) {
        return;
    }

    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, line, search_pos, receiver_name)) |pos| {
        const after_name = pos + receiver_name.len;
        if (after_name >= line.len or line[after_name] != '.') {
            search_pos = after_name;
            continue;
        }
        const field_start = after_name + 1;
        const field_len = scanIdentifier(line, field_start) - field_start;
        if (field_len == 0) {
            search_pos = field_start;
            continue;
        }

        const field = line[field_start .. field_start + field_len];
        const combined = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ receiver_name, field });
        try addUniqueString(touched, combined);
        if (isLifecycleFlagName(field)) {
            try addUniqueString(bool_reads, field);
        }
        search_pos = field_start + field_len;
    }
}

fn appendDottedRootTouches(
    touched: *std.array_list.Managed([]const u8),
    declared: *std.array_list.Managed([]const u8),
    line: []const u8,
    receiver_name: []const u8,
    keywords: []const []const u8,
    scope_names: []const []const u8,
    builtins: []const []const u8,
) !void {
    var idx: usize = 0;
    while (idx < line.len) : (idx += 1) {
        if (line[idx] != '.') {
            continue;
        }
        const root_start = reverseIdentifierStart(line, idx);
        const root = line[root_start..idx];
        if (root.len == 0 or std.mem.eql(u8, root, receiver_name)) {
            continue;
        }
        if (containsString(declared.items, root) or
            isKeyword(root, keywords) or
            containsString(scope_names, root) or
            containsString(builtins, root))
        {
            continue;
        }
        try addUniqueString(touched, root);
    }
}

fn appendFreeCallTouches(
    touched: *std.array_list.Managed([]const u8),
    declared: *std.array_list.Managed([]const u8),
    line: []const u8,
    keywords: []const []const u8,
    scope_names: []const []const u8,
    builtins: []const []const u8,
) !void {
    var idx: usize = 0;
    while (idx < line.len) {
        if (!isIdentifierStart(line[idx])) {
            idx += 1;
            continue;
        }
        const end = scanIdentifier(line, idx);
        const token = line[idx..end];
        if (idx > 0 and line[idx - 1] == '.') {
            idx = end;
            continue;
        }
        if (containsString(declared.items, token) or
            isKeyword(token, keywords) or
            containsString(scope_names, token) or
            containsString(builtins, token))
        {
            idx = end;
            continue;
        }

        var next = end;
        while (next < line.len and std.ascii.isWhitespace(line[next])) : (next += 1) {}
        if (next < line.len and line[next] == '(') {
            try addUniqueString(touched, token);
        }
        idx = end;
    }
}

fn appendLifecycleActions(
    actions: *std.array_list.Managed(LifecycleAction),
    allocator: std.mem.Allocator,
    line: []const u8,
    line_no: u32,
) !void {
    var idx: usize = 0;
    while (idx < line.len) : (idx += 1) {
        if (!isIdentifierStart(line[idx])) {
            continue;
        }
        const end = scanIdentifier(line, idx);
        const token = line[idx..end];
        var next = end;
        while (next < line.len and std.ascii.isWhitespace(line[next])) : (next += 1) {}

        if (next < line.len and line[next] == '.') {
            const verb_start = next + 1;
            const verb_end = scanIdentifier(line, verb_start);
            const verb = line[verb_start..verb_end];
            const kind = classifyLifecycleVerb(verb) orelse {
                idx = end;
                continue;
            };
            if (token.len > 0) {
                const owned_target = try allocator.dupe(u8, token);
                try appendUniqueAction(actions, .{
                    .kind = kind,
                    .target = owned_target,
                    .verb = try allocator.dupe(u8, verb),
                    .line = line_no,
                });
            }
            idx = verb_end;
            continue;
        }

        if (next < line.len and line[next] == '(') {
            const kind = classifyLifecycleVerb(token) orelse {
                idx = end;
                continue;
            };
            const close = findMatchingForward(line, next, '(', ')') orelse {
                idx = end;
                continue;
            };
            const inside = std.mem.trim(u8, line[next + 1 .. close], " \t");
            const first_arg = firstIdentifier(inside);
            if (first_arg.len > 0) {
                try appendUniqueAction(actions, .{
                    .kind = kind,
                    .target = try allocator.dupe(u8, first_arg),
                    .verb = try allocator.dupe(u8, token),
                    .line = line_no,
                });
            }
            idx = close;
        }
    }
}

fn appendUniqueAction(actions: *std.array_list.Managed(LifecycleAction), action: LifecycleAction) !void {
    for (actions.items) |existing| {
        if (existing.kind == action.kind and
            existing.line == action.line and
            std.mem.eql(u8, existing.target, action.target) and
            std.mem.eql(u8, existing.verb, action.verb))
        {
            return;
        }
    }
    try actions.append(action);
}

fn appendGoDeclarations(list: *std.array_list.Managed([]const u8), line: []const u8) !void {
    if (std.mem.startsWith(u8, line, "var ") or std.mem.startsWith(u8, line, "const ")) {
        const rest = if (std.mem.startsWith(u8, line, "var ")) line["var ".len..] else line["const ".len..];
        try appendDelimitedNames(list, rest);
    }
    if (std.mem.indexOf(u8, line, ":=")) |pos| {
        try appendDelimitedNames(list, line[0..pos]);
    }
}

fn appendTypeScriptDeclarations(list: *std.array_list.Managed([]const u8), line: []const u8) !void {
    inline for (&[_][]const u8{ "const ", "let ", "var " }) |keyword| {
        if (std.mem.startsWith(u8, line, keyword)) {
            try appendDelimitedNames(list, line[keyword.len..]);
        }
    }

    if (std.mem.startsWith(u8, line, "for (")) {
        if (std.mem.indexOf(u8, line, "const ")) |pos| {
            try appendDelimitedNames(list, line[pos + "const ".len ..]);
        } else if (std.mem.indexOf(u8, line, "let ")) |pos| {
            try appendDelimitedNames(list, line[pos + "let ".len ..]);
        }
    }

    if (std.mem.startsWith(u8, line, "catch (")) {
        const open = std.mem.indexOfScalar(u8, line, '(') orelse return;
        const close = std.mem.indexOfScalarPos(u8, line, open + 1, ')') orelse return;
        try addUniqueString(list, firstIdentifier(std.mem.trim(u8, line[open + 1 .. close], " \t")));
    }
}

fn appendPythonDeclarations(list: *std.array_list.Managed([]const u8), line: []const u8) !void {
    if (std.mem.startsWith(u8, line, "for ")) {
        if (std.mem.indexOf(u8, line, " in ")) |pos| {
            try appendDelimitedNames(list, line["for ".len..pos]);
        }
    }

    if (std.mem.startsWith(u8, line, "except ") or std.mem.startsWith(u8, line, "except:")) {
        if (std.mem.indexOf(u8, line, " as ")) |pos| {
            const name = std.mem.trimRight(u8, line[pos + " as ".len ..], ":");
            try addUniqueString(list, name);
        }
    }

    if (std.mem.startsWith(u8, line, "with ")) {
        try appendPythonWithBindings(list, line["with ".len..]);
    }

    if (findPythonWalrusOperator(line)) |pos| {
        try addUniqueString(list, identifierBeforeOperator(line, pos));
    }

    if (findPythonAssignmentOperator(line)) |pos| {
        try appendDelimitedNames(list, line[0..pos]);
    }
}

fn appendZigDeclarations(list: *std.array_list.Managed([]const u8), line: []const u8) !void {
    if (std.mem.startsWith(u8, line, "const ") or std.mem.startsWith(u8, line, "var ")) {
        const rest = if (std.mem.startsWith(u8, line, "const ")) line["const ".len..] else line["var ".len..];
        if (std.mem.indexOfScalar(u8, rest, '=')) |pos| {
            try appendDelimitedNames(list, rest[0..pos]);
        }
    }

    var idx: usize = 0;
    while (std.mem.indexOfScalarPos(u8, line, idx, '|')) |open| {
        const close = std.mem.indexOfScalarPos(u8, line, open + 1, '|') orelse break;
        const capture = std.mem.trim(u8, line[open + 1 .. close], " \t");
        if (capture.len > 0 and !std.mem.eql(u8, capture, "_")) {
            try addUniqueString(list, capture);
        }
        idx = close + 1;
    }
}

fn appendDelimitedNames(list: *std.array_list.Managed([]const u8), text: []const u8) !void {
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse text.len;
    const relevant = std.mem.trim(u8, text[0..eq], " \t");
    const segments = try topLevelSegments(list.allocator, relevant);
    for (segments) |segment| {
        const name = firstIdentifier(segment);
        if (name.len == 0 or std.mem.eql(u8, name, "_")) {
            continue;
        }
        try addUniqueString(list, name);
    }
}

const PythonSignatureDepth = struct {
    paren: i32 = 0,
    bracket: i32 = 0,
    brace: i32 = 0,
};

fn pythonSignatureLineComplete(line: []const u8, depth: *PythonSignatureDepth) bool {
    for (line) |ch| {
        switch (ch) {
            '(' => depth.paren += 1,
            ')' => {
                if (depth.paren > 0) {
                    depth.paren -= 1;
                }
            },
            '[' => depth.bracket += 1,
            ']' => {
                if (depth.bracket > 0) {
                    depth.bracket -= 1;
                }
            },
            '{' => depth.brace += 1,
            '}' => {
                if (depth.brace > 0) {
                    depth.brace -= 1;
                }
            },
            ':' => {
                if (depth.paren == 0 and depth.bracket == 0 and depth.brace == 0) {
                    return true;
                }
            },
            else => {},
        }
    }
    return false;
}

fn appendTypeScriptImportBindings(
    list: *std.array_list.Managed([]const u8),
    raw_line: []const u8,
    masked_line: []const u8,
    in_named_import_block: *bool,
) !void {
    var text = std.mem.trim(u8, masked_line["import ".len..], " \t;");
    if (std.mem.startsWith(u8, text, "type ")) {
        text = std.mem.trimLeft(u8, text["type ".len..], " \t");
    }

    if (std.mem.startsWith(u8, text, "* as ")) {
        try addUniqueString(list, firstIdentifier(text["* as ".len..]));
        return;
    }

    if (std.mem.indexOfScalar(u8, text, '{')) |open| {
        const default_part = std.mem.trim(u8, text[0..open], " \t,");
        if (default_part.len > 0) {
            try addUniqueString(list, firstIdentifier(default_part));
        }
        if (std.mem.indexOfScalarPos(u8, text, open + 1, '}')) |close| {
            try appendTypeScriptNamedImportItems(list, text[open + 1 .. close]);
        } else {
            in_named_import_block.* = true;
            try appendTypeScriptNamedImportItems(list, text[open + 1 ..]);
        }
        return;
    }

    if (std.mem.indexOf(u8, text, " from ")) |from_pos| {
        text = std.mem.trim(u8, text[0..from_pos], " \t,");
    } else if (std.mem.indexOf(u8, raw_line, " from ")) |from_pos| {
        const prefix_len = from_pos - "import ".len;
        text = std.mem.trim(u8, text[0..@min(text.len, prefix_len)], " \t,");
    }
    try addUniqueString(list, firstIdentifier(text));
}

fn appendTypeScriptNamedImportItems(list: *std.array_list.Managed([]const u8), text: []const u8) !void {
    const segments = try topLevelSegments(list.allocator, std.mem.trim(u8, text, " \t,"));
    for (segments) |segment| {
        var trimmed = std.mem.trim(u8, segment, " \t,");
        if (trimmed.len == 0 or trimmed[0] == '}') {
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "type ")) {
            trimmed = std.mem.trimLeft(u8, trimmed["type ".len..], " \t");
        }
        if (std.mem.indexOf(u8, trimmed, " as ")) |as_pos| {
            try addUniqueString(list, firstIdentifier(trimmed[as_pos + " as ".len ..]));
        } else {
            try addUniqueString(list, firstIdentifier(trimmed));
        }
    }
}

fn appendPythonImportNames(list: *std.array_list.Managed([]const u8), text: []const u8) !void {
    const segments = try topLevelSegments(list.allocator, text);
    for (segments) |segment| {
        const trimmed = std.mem.trim(u8, segment, " \t");
        if (std.mem.indexOf(u8, trimmed, " as ")) |as_pos| {
            try addUniqueString(list, firstIdentifier(trimmed[as_pos + " as ".len ..]));
        } else {
            try addUniqueString(list, firstIdentifier(trimmed));
        }
    }
}

fn appendPythonFromImportNames(list: *std.array_list.Managed([]const u8), text: []const u8) !void {
    const segments = try topLevelSegments(list.allocator, std.mem.trim(u8, text, " \t()"));
    for (segments) |segment| {
        const trimmed = std.mem.trim(u8, segment, " \t,");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "*")) {
            continue;
        }
        if (std.mem.indexOf(u8, trimmed, " as ")) |as_pos| {
            try addUniqueString(list, firstIdentifier(trimmed[as_pos + " as ".len ..]));
        } else {
            try addUniqueString(list, firstIdentifier(trimmed));
        }
    }
}

fn appendPythonWithBindings(list: *std.array_list.Managed([]const u8), text: []const u8) !void {
    const segments = try topLevelSegments(list.allocator, std.mem.trimRight(u8, text, ":"));
    for (segments) |segment| {
        const trimmed = std.mem.trim(u8, segment, " \t");
        if (std.mem.indexOf(u8, trimmed, " as ")) |as_pos| {
            try addUniqueString(list, firstIdentifier(trimmed[as_pos + " as ".len ..]));
        }
    }
}

fn findPythonWalrusOperator(line: []const u8) ?usize {
    return std.mem.indexOf(u8, line, ":=");
}

fn findPythonAssignmentOperator(line: []const u8) ?usize {
    for (line, 0..) |ch, idx| {
        if (ch != '=') {
            continue;
        }
        if (idx > 0) {
            switch (line[idx - 1]) {
                '!', '<', '>', '=', '+', '-', '*', '/', '%', '&', '|', '^', ':' => continue,
                else => {},
            }
        }
        if (idx + 1 < line.len and line[idx + 1] == '=') {
            continue;
        }
        return idx;
    }
    return null;
}

fn identifierBeforeOperator(line: []const u8, op_pos: usize) []const u8 {
    return lastTypeIdentifier(line[0..op_pos]);
}

fn extractGoImportName(text: []const u8) ?[]const u8 {
    var trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, ")")) {
        return null;
    }
    if (std.mem.startsWith(u8, trimmed, "import ")) {
        trimmed = std.mem.trimLeft(u8, trimmed["import ".len..], " \t");
    }
    if (trimmed.len == 0) {
        return null;
    }
    if (trimmed[0] == '.' or trimmed[0] == '_') {
        return null;
    }
    if (trimmed[0] == '"') {
        return extractImportPathBase(trimmed);
    }

    const alias = firstIdentifier(trimmed);
    if (alias.len == 0 or std.mem.eql(u8, alias, "_")) {
        return null;
    }
    return alias;
}

fn extractImportPathBase(text: []const u8) ?[]const u8 {
    const start = std.mem.indexOfScalar(u8, text, '"') orelse return null;
    const end = std.mem.indexOfScalarPos(u8, text, start + 1, '"') orelse return null;
    const path = text[start + 1 .. end];
    const base_start = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[base_start + 1 ..];
}

fn extractTypeScriptScopeFunctionName(text: []const u8) []const u8 {
    if (std.mem.indexOf(u8, text, "function ")) |pos| {
        return firstIdentifier(text[pos + "function ".len ..]);
    }
    if (std.mem.indexOfScalar(u8, text, '=')) |eq| {
        return lastTypeIdentifier(text[0..eq]);
    }
    return "";
}

fn extractGoScopeFunctionName(text: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, text, "func ")) {
        return "";
    }

    var after = std.mem.trimLeft(u8, text["func ".len..], " \t");
    if (after.len > 0 and after[0] == '(') {
        const close = findMatchingForward(after, 0, '(', ')') orelse return "";
        after = std.mem.trimLeft(u8, after[close + 1 ..], " \t");
    }
    return firstIdentifier(after);
}

fn extractPythonScopeFunctionName(text: []const u8) []const u8 {
    if (std.mem.startsWith(u8, text, "async def ")) {
        return firstIdentifier(text["async def ".len..]);
    }
    if (std.mem.startsWith(u8, text, "def ")) {
        return firstIdentifier(text["def ".len..]);
    }
    return "";
}

fn extractTypeScriptBindingPrefix(text: []const u8) []const u8 {
    inline for (&[_][]const u8{ "export const ", "export let ", "export var ", "const ", "let ", "var " }) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) {
            return text[prefix.len..];
        }
    }
    return text;
}

fn extractZigScopeFunctionName(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (std.mem.startsWith(u8, trimmed, "test ")) {
        return extractZigTestName(trimmed);
    }
    const fn_pos = std.mem.indexOf(u8, trimmed, "fn ") orelse return "";
    return firstIdentifier(trimmed[fn_pos + "fn ".len ..]);
}

fn extractZigTestName(text: []const u8) []const u8 {
    const first_quote = std.mem.indexOfScalar(u8, text, '"') orelse return "test";
    const second_quote = std.mem.indexOfScalarPos(u8, text, first_quote + 1, '"') orelse return "test";
    return text[first_quote + 1 .. second_quote];
}

fn extractZigBindingPrefix(text: []const u8) []const u8 {
    inline for (&[_][]const u8{ "pub const ", "pub var ", "const ", "var " }) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) {
            return text[prefix.len..];
        }
    }
    return text;
}

fn parseGoParamNames(allocator: std.mem.Allocator, params: []const u8) ![]const []const u8 {
    const segments = try topLevelSegments(allocator, params);
    var names = std.array_list.Managed([]const u8).init(allocator);
    for (segments) |segment| {
        const name = firstIdentifier(segment);
        if (name.len == 0 or std.mem.eql(u8, name, "_")) {
            continue;
        }
        try addUniqueString(&names, name);
    }
    return names.toOwnedSlice();
}

fn parseTypeScriptParamNames(
    allocator: std.mem.Allocator,
    params: []const u8,
    is_method: bool,
) ![]const []const u8 {
    const segments = try topLevelSegments(allocator, params);
    var names = std.array_list.Managed([]const u8).init(allocator);
    for (segments, 0..) |segment, idx| {
        var trimmed = std.mem.trim(u8, segment, " \t");
        if (trimmed.len == 0) {
            continue;
        }
        if (trimmed[0] == '{' or trimmed[0] == '[') {
            try addUniqueString(&names, trimmed[0..1]);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "...")) {
            trimmed = std.mem.trimLeft(u8, trimmed["...".len..], " \t");
        }
        const name = firstIdentifier(trimmed);
        if (name.len == 0 or (is_method and idx == 0 and std.mem.eql(u8, name, "this"))) {
            continue;
        }
        try addUniqueString(&names, name);
    }
    return names.toOwnedSlice();
}

fn parsePythonParamNames(
    allocator: std.mem.Allocator,
    params: []const u8,
    is_method: bool,
) ![]const []const u8 {
    const segments = try topLevelSegments(allocator, params);
    var names = std.array_list.Managed([]const u8).init(allocator);
    for (segments, 0..) |segment, idx| {
        var trimmed = std.mem.trim(u8, segment, " \t");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "/") or std.mem.eql(u8, trimmed, "*")) {
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "**")) {
            trimmed = trimmed["**".len..];
        } else if (std.mem.startsWith(u8, trimmed, "*")) {
            trimmed = trimmed["*".len..];
        }
        const name = firstIdentifier(trimmed);
        if (name.len == 0 or (is_method and idx == 0 and (std.mem.eql(u8, name, "self") or std.mem.eql(u8, name, "cls")))) {
            continue;
        }
        try addUniqueString(&names, name);
    }
    return names.toOwnedSlice();
}

fn collectBraceBlock(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    start_idx: usize,
) !SignatureBlock {
    var joined = std.array_list.Managed(u8).init(allocator);
    var open_line_idx: ?usize = null;

    var idx = start_idx;
    while (idx < lines.len) : (idx += 1) {
        const trimmed = std.mem.trim(u8, lines[idx], " \t");
        if (joined.items.len > 0) {
            try joined.append(' ');
        }
        try joined.appendSlice(trimmed);
        if (open_line_idx == null and std.mem.indexOfScalar(u8, trimmed, '{') != null) {
            open_line_idx = idx;
            break;
        }
    }

    const open_idx = open_line_idx orelse return error.InvalidInput;
    const end_idx = findBraceBlockEnd(lines, open_idx) orelse return error.InvalidInput;
    return .{
        .text = try joined.toOwnedSlice(),
        .open_line_idx = open_idx,
        .end_line_idx = end_idx,
    };
}

fn collectPythonSignature(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    start_idx: usize,
) !struct { text: []const u8, end_idx: usize } {
    var joined = std.array_list.Managed(u8).init(allocator);
    var depth = PythonSignatureDepth{};
    var idx = start_idx;
    while (idx < lines.len) : (idx += 1) {
        const trimmed = std.mem.trim(u8, lines[idx], " \t");
        if (joined.items.len > 0) {
            try joined.append(' ');
        }
        try joined.appendSlice(trimmed);
        if (pythonSignatureLineComplete(trimmed, &depth)) {
            break;
        }
    }
    return .{
        .text = try joined.toOwnedSlice(),
        .end_idx = idx,
    };
}

fn findBraceBlockEnd(lines: []const []const u8, open_line_idx: usize) ?usize {
    var depth: i32 = 0;
    var idx = open_line_idx;
    while (idx < lines.len) : (idx += 1) {
        const line = lines[idx];
        var line_idx: usize = 0;
        while (line_idx < line.len) : (line_idx += 1) {
            switch (line[line_idx]) {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        return idx;
                    }
                },
                else => {},
            }
        }
    }
    return null;
}

fn findPythonBlockEnd(lines: []const []const u8, start_idx: usize) usize {
    const base_indent = types.leadingWhitespace(lines[start_idx]);
    var idx = start_idx + 1;
    var last = start_idx;
    while (idx < lines.len) : (idx += 1) {
        const trimmed = std.mem.trimLeft(u8, lines[idx], " \t");
        if (trimmed.len == 0) {
            continue;
        }
        const ws = types.leadingWhitespace(lines[idx]);
        if (ws <= base_indent) {
            break;
        }
        last = idx;
    }
    return last;
}

fn topLevelSegments(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var segments = std.array_list.Managed([]const u8).init(allocator);
    var start: usize = 0;
    var paren: i32 = 0;
    var bracket: i32 = 0;
    var brace: i32 = 0;
    var angle: i32 = 0;

    for (text, 0..) |ch, idx| {
        switch (ch) {
            '(' => paren += 1,
            ')' => paren -= 1,
            '[' => bracket += 1,
            ']' => bracket -= 1,
            '{' => brace += 1,
            '}' => brace -= 1,
            '<' => angle += 1,
            '>' => {
                if (angle > 0) {
                    angle -= 1;
                }
            },
            ',' => {
                if (paren == 0 and bracket == 0 and brace == 0 and angle == 0) {
                    const segment = std.mem.trim(u8, text[start..idx], " \t");
                    if (segment.len > 0) {
                        try segments.append(segment);
                    }
                    start = idx + 1;
                }
            },
            else => {},
        }
    }

    const tail = std.mem.trim(u8, text[start..], " \t");
    if (tail.len > 0) {
        try segments.append(tail);
    }
    return segments.toOwnedSlice();
}

fn extractGoTypeName(text: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, text, "type ")) {
        return "";
    }
    return firstIdentifier(text["type ".len..]);
}

fn extractGoStructFieldName(trimmed: []const u8) []const u8 {
    if (trimmed.len == 0 or trimmed[0] == '}' or trimmed[0] == '{') {
        return "";
    }
    const field_end = std.mem.indexOfAny(u8, trimmed, " \t`") orelse trimmed.len;
    const field_segment = trimmed[0..field_end];
    if (field_segment.len == 0) {
        return "";
    }
    if (field_segment[0] == '*' or std.mem.indexOfScalar(u8, field_segment, '.') != null) {
        return lastTypeIdentifier(field_segment);
    }
    return firstIdentifier(field_segment);
}

fn extractTsNamedDeclName(text: []const u8, keyword: []const u8) []const u8 {
    const pos = std.mem.indexOf(u8, text, keyword) orelse return "";
    return firstIdentifier(text[pos + keyword.len ..]);
}

fn extractTsTypeAliasName(text: []const u8) []const u8 {
    const pos = std.mem.indexOf(u8, text, "type ") orelse return "";
    return firstIdentifier(text[pos + "type ".len ..]);
}

fn extractTsMethodName(text: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, text, " \t");
    inline for (&[_][]const u8{ "public ", "private ", "protected ", "static ", "async ", "readonly ", "get ", "set " }) |prefix| {
        if (std.mem.startsWith(u8, trimmed, prefix)) {
            trimmed = std.mem.trimLeft(u8, trimmed[prefix.len..], " \t");
        }
    }
    if (trimmed.len > 0 and trimmed[0] == '#') {
        trimmed = trimmed[1..];
    }
    return firstIdentifier(trimmed);
}

fn extractTsClassFieldName(trimmed: []const u8) []const u8 {
    if (looksLikeTsMethodDecl(trimmed)) {
        return "";
    }
    var text = trimmed;
    inline for (&[_][]const u8{ "public ", "private ", "protected ", "readonly ", "static ", "declare " }) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) {
            text = std.mem.trimLeft(u8, text[prefix.len..], " \t");
        }
    }
    if (text.len > 0 and text[0] == '#') {
        text = text[1..];
    }
    if (std.mem.indexOfScalar(u8, text, ':') == null and std.mem.indexOfScalar(u8, text, '=') == null) {
        return "";
    }
    return firstIdentifier(text);
}

fn extractTsShapeFieldName(trimmed: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, trimmed, ':') == null) {
        return "";
    }
    if (std.mem.indexOfScalar(u8, trimmed, '(') != null and std.mem.indexOfScalar(u8, trimmed, '(').? < std.mem.indexOfScalar(u8, trimmed, ':').?) {
        return "";
    }
    return firstIdentifier(trimmed);
}

fn extractPythonClassName(trimmed: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, trimmed, "class ")) {
        return "";
    }
    return firstIdentifier(trimmed["class ".len..]);
}

fn extractZigStructName(trimmed: []const u8) []const u8 {
    if (std.mem.indexOf(u8, trimmed, "const ") == null) {
        return "";
    }
    const pos = std.mem.indexOf(u8, trimmed, "const ") orelse return "";
    return firstIdentifier(trimmed[pos + "const ".len ..]);
}

fn extractZigStructFieldName(trimmed: []const u8) []const u8 {
    if (startsWithAny(trimmed, &[_][]const u8{ "pub fn ", "fn ", "test ", "comptime ", "const ", "pub const ", "usingnamespace " })) {
        return "";
    }
    if (std.mem.indexOfScalar(u8, trimmed, ':') == null) {
        return "";
    }
    return firstIdentifier(trimmed);
}

fn looksLikeTsClassDecl(trimmed: []const u8) bool {
    return startsWithAny(trimmed, &[_][]const u8{
        "class ",
        "export class ",
        "abstract class ",
        "export abstract class ",
    });
}

fn looksLikeTsInterfaceDecl(trimmed: []const u8) bool {
    return startsWithAny(trimmed, &[_][]const u8{
        "interface ",
        "export interface ",
    });
}

fn looksLikeTsObjectTypeDecl(trimmed: []const u8) bool {
    return (std.mem.startsWith(u8, trimmed, "type ") or std.mem.startsWith(u8, trimmed, "export type ")) and
        std.mem.indexOf(u8, trimmed, "= {") != null;
}

fn looksLikeTsFunctionDecl(trimmed: []const u8) bool {
    return startsWithAny(trimmed, &[_][]const u8{
        "function ",
        "export function ",
        "async function ",
        "export async function ",
        "const ",
        "let ",
        "var ",
        "export const ",
        "export let ",
        "export var ",
    }) and std.mem.indexOf(u8, trimmed, "{") != null;
}

fn looksLikeTsMethodDecl(trimmed: []const u8) bool {
    if (startsWithAny(trimmed, &[_][]const u8{ "if ", "for ", "while ", "switch ", "catch ", "return " })) {
        return false;
    }
    return std.mem.indexOf(u8, trimmed, "(") != null and std.mem.indexOf(u8, trimmed, "{") != null;
}

fn looksLikePythonFieldLine(trimmed: []const u8) bool {
    if (startsWithAny(trimmed, &[_][]const u8{ "def ", "async def ", "class ", "@", "if ", "for ", "while " })) {
        return false;
    }
    return std.mem.indexOfScalar(u8, trimmed, ':') != null or std.mem.indexOfScalar(u8, trimmed, '=') != null;
}

fn looksLikeZigStructDecl(trimmed: []const u8) bool {
    return std.mem.indexOf(u8, trimmed, "const ") != null and std.mem.indexOf(u8, trimmed, "= struct") != null;
}

fn looksLikeZigFunctionDecl(trimmed: []const u8) bool {
    return startsWithAny(trimmed, &[_][]const u8{ "fn ", "pub fn ", "export fn ", "test " });
}

fn startsWithAny(text: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) {
            return true;
        }
    }
    return false;
}

fn isExplicitStateField(name: []const u8, line: []const u8, is_bool: bool) bool {
    if (!isStateIndicatorName(name)) {
        return false;
    }
    if (!is_bool) {
        return true;
    }
    return std.mem.indexOf(u8, line, "|") != null or
        std.mem.indexOf(u8, line, "Literal[") != null or
        std.mem.indexOf(u8, line, " enum") != null or
        containsCaseInsensitive(line, "State") or
        containsCaseInsensitive(line, "Status") or
        containsCaseInsensitive(line, "Phase") or
        containsCaseInsensitive(line, "Mode");
}

fn isLifecycleFlagName(name: []const u8) bool {
    return containsCaseInsensitive(name, "active") or
        containsCaseInsensitive(name, "ready") or
        containsCaseInsensitive(name, "started") or
        containsCaseInsensitive(name, "running") or
        containsCaseInsensitive(name, "done") or
        containsCaseInsensitive(name, "open") or
        containsCaseInsensitive(name, "closed") or
        containsCaseInsensitive(name, "initialized") or
        containsCaseInsensitive(name, "connected") or
        containsCaseInsensitive(name, "cancelled") or
        containsCaseInsensitive(name, "canceled") or
        containsCaseInsensitive(name, "disposed");
}

fn isStateIndicatorName(name: []const u8) bool {
    return containsCaseInsensitive(name, "state") or
        containsCaseInsensitive(name, "status") or
        containsCaseInsensitive(name, "phase") or
        containsCaseInsensitive(name, "mode");
}

pub fn classifyLifecycleVerb(name: []const u8) ?LifecycleActionKind {
    for (lifecycle_start_verbs) |verb| {
        if (matchesLifecycleVerb(name, verb)) {
            return .start;
        }
    }
    for (lifecycle_cleanup_verbs) |verb| {
        if (matchesLifecycleVerb(name, verb)) {
            return .cleanup;
        }
    }
    return null;
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) {
            return true;
        }
    }
    return false;
}

fn addUniqueString(list: *std.array_list.Managed([]const u8), value: []const u8) !void {
    if (value.len == 0 or containsString(list.items, value)) {
        return;
    }
    try list.append(value);
}

fn seedDeclaredNames(target: *std.array_list.Managed([]const u8), names: []const []const u8) !void {
    for (names) |name| {
        try addUniqueString(target, name);
    }
}

fn isKeyword(token: []const u8, keywords: []const []const u8) bool {
    for (keywords) |keyword| {
        if (std.mem.eql(u8, token, keyword)) {
            return true;
        }
    }
    return false;
}

fn isIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_' or ch == '$';
}

fn isIdentifierChar(ch: u8) bool {
    return isIdentifierStart(ch) or std.ascii.isDigit(ch);
}

fn scanIdentifier(text: []const u8, start: usize) usize {
    var idx = start;
    while (idx < text.len and isIdentifierChar(text[idx])) : (idx += 1) {}
    return idx;
}

fn reverseIdentifierStart(text: []const u8, end: usize) usize {
    var idx = end;
    while (idx > 0 and isIdentifierChar(text[idx - 1])) : (idx -= 1) {}
    return idx;
}

fn firstIdentifier(text: []const u8) []const u8 {
    var idx: usize = 0;
    while (idx < text.len and !isIdentifierStart(text[idx])) : (idx += 1) {}
    if (idx == text.len) {
        return "";
    }
    return text[idx..scanIdentifier(text, idx)];
}

fn lastTypeIdentifier(text: []const u8) []const u8 {
    var last: []const u8 = "";
    var idx: usize = 0;
    while (idx < text.len) {
        if (!isIdentifierStart(text[idx])) {
            idx += 1;
            continue;
        }
        const end = scanIdentifier(text, idx);
        last = text[idx..end];
        idx = end;
    }
    return last;
}

fn findMatchingForward(text: []const u8, start_idx: usize, open: u8, close: u8) ?usize {
    var depth: i32 = 0;
    var idx = start_idx;
    while (idx < text.len) : (idx += 1) {
        if (text[idx] == open) {
            depth += 1;
        } else if (text[idx] == close) {
            depth -= 1;
            if (depth == 0) {
                return idx;
            }
        }
    }
    return null;
}

fn braceDelta(text: []const u8) i32 {
    var delta: i32 = 0;
    for (text) |ch| {
        if (ch == '{') delta += 1;
        if (ch == '}') delta -= 1;
    }
    return delta;
}

fn lineNumber(idx: usize) !u32 {
    return types.indexToLineNumber(idx);
}

fn isExportedName(name: []const u8) bool {
    return name.len > 0 and std.ascii.isUpper(name[0]);
}

fn isPrivatePythonName(name: []const u8) bool {
    return name.len > 0 and name[0] == '_' and !std.mem.eql(u8, name, "__init__");
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) {
        return false;
    }
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (startsWithInsensitive(haystack[start..], needle)) {
            return true;
        }
    }
    return false;
}

fn startsWithInsensitive(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) {
        return false;
    }
    for (prefix, 0..) |ch, idx| {
        if (std.ascii.toLower(text[idx]) != std.ascii.toLower(ch)) {
            return false;
        }
    }
    return true;
}

fn matchesLifecycleVerb(name: []const u8, verb: []const u8) bool {
    if (!startsWithInsensitive(name, verb)) {
        return false;
    }
    if (name.len == verb.len) {
        return true;
    }
    return !std.ascii.isLower(name[verb.len]);
}

const lifecycle_start_verbs = [_][]const u8{
    "init",
    "start",
    "open",
    "connect",
    "begin",
    "create",
    "acquire",
};

const lifecycle_cleanup_verbs = [_][]const u8{
    "close",
    "stop",
    "disconnect",
    "deinit",
    "destroy",
    "free",
    "release",
    "cancel",
    "dispose",
};

const go_keywords = [_][]const u8{
    "break",  "case",   "chan",   "const",  "continue", "default",   "defer", "else",    "fallthrough",
    "for",    "func",   "go",     "if",     "import",   "interface", "map",   "package", "range",
    "return", "select", "struct", "switch", "type",     "var",       "nil",   "true",    "false",
};

const typescript_keywords = [_][]const u8{
    "break",  "case",   "catch",    "class", "const",  "continue",  "default", "else", "export",
    "false",  "for",    "function", "if",    "import", "interface", "let",     "new",  "null",
    "return", "switch", "this",     "throw", "true",   "try",       "type",    "var",  "while",
};

const python_keywords = [_][]const u8{
    "and",   "as",      "assert", "break", "class", "continue", "def",   "elif", "else", "except",
    "False", "finally", "for",    "from",  "if",    "import",   "in",    "None", "or",   "pass",
    "raise", "return",  "True",   "try",   "while", "with",     "yield",
};

const zig_keywords = [_][]const u8{
    "anytype",  "asm",   "break", "catch", "comptime", "const", "continue", "defer", "else",
    "errdefer", "false", "fn",    "for",   "if",       "null",  "orelse",   "pub",   "return",
    "switch",   "test",  "true",  "try",   "var",      "while",
};

const go_builtins = [_][]const u8{
    "append",  "cap",  "close", "complex", "copy",  "delete",  "imag",
    "len",     "make", "new",   "panic",   "print", "println", "real",
    "recover",
};

const typescript_builtins = [_][]const u8{
    "console", "Promise", "Array",   "Object",   "Number",     "String", "Boolean",
    "JSON",    "Math",    "Date",    "RegExp",   "Error",      "Symbol", "Map",
    "Set",     "WeakMap", "WeakSet", "parseInt", "parseFloat", "isNaN",  "isFinite",
};

const python_builtins = [_][]const u8{
    "len",     "range",     "print", "str",   "int",        "float",   "bool",
    "list",    "dict",      "set",   "tuple", "isinstance", "hasattr", "getattr",
    "setattr", "enumerate", "zip",   "map",   "filter",     "sorted",  "reversed",
    "all",     "any",       "abs",   "min",   "max",        "sum",     "type",
    "id",      "open",      "input", "exit",  "repr",       "iter",    "next",
    "vars",    "dir",
};

const zig_builtins = [_][]const u8{};

const testing = std.testing;

test "symbol model: Go methods and struct fields are extracted" {
    const src =
        \\type Service struct {
        \\    started bool
        \\    ready bool
        \\    client *Client
        \\}
        \\
        \\func (s *Service) Start(ctx context.Context, retries int, delay time.Duration) error {
        \\    if s.started {
        \\        return nil
        \\    }
        \\    return connect(client)
        \\}
    ;

    const raw_lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(raw_lines);
    const masked = try types.maskSource(testing.allocator, src, .go);
    defer testing.allocator.free(masked);
    const masked_lines = try types.splitLines(testing.allocator, masked);
    defer testing.allocator.free(masked_lines);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const model = try build(arena.allocator(), raw_lines, masked_lines, .go);
    try testing.expectEqual(@as(usize, 1), model.types.len);
    try testing.expectEqual(@as(u32, 3), model.types[0].field_count);
    try testing.expectEqual(@as(usize, 1), model.functions.len);
    try testing.expectEqualStrings("Service", model.functions[0].owner_type);
    try testing.expectEqual(@as(u32, 3), model.functions[0].argument_count);
}

test "symbol model: TypeScript class extraction finds fields and methods" {
    const src =
        \\export class Session {
        \\  active: boolean = false;
        \\  ready: boolean = false;
        \\  state: "open" | "closed" = "open";
        \\
        \\  start(client: Client, opts: Options) {
        \\    if (this.active) {
        \\      return;
        \\    }
        \\    boot(client);
        \\  }
        \\}
    ;

    const raw_lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(raw_lines);
    const masked = try types.maskSource(testing.allocator, src, .typescript);
    defer testing.allocator.free(masked);
    const masked_lines = try types.splitLines(testing.allocator, masked);
    defer testing.allocator.free(masked_lines);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const model = try build(arena.allocator(), raw_lines, masked_lines, .typescript);
    try testing.expectEqual(@as(usize, 1), model.types.len);
    try testing.expect(model.types[0].has_explicit_state);
    try testing.expectEqual(@as(usize, 1), model.functions.len);
    try testing.expectEqualStrings("Session", model.functions[0].owner_type);
    try testing.expectEqual(@as(u32, 2), model.functions[0].argument_count);
}

test "symbol model: Python class init fields are inferred" {
    const src =
        \\class Worker:
        \\    started: bool = False
        \\
        \\    def __init__(self, client, retries):
        \\        self.ready = False
        \\        self.client = client
        \\
        \\    def run(self, task):
        \\        if self.ready:
        \\            return execute(task)
        \\        return None
    ;

    const raw_lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(raw_lines);
    const masked = try types.maskSource(testing.allocator, src, .python);
    defer testing.allocator.free(masked);
    const masked_lines = try types.splitLines(testing.allocator, masked);
    defer testing.allocator.free(masked_lines);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const model = try build(arena.allocator(), raw_lines, masked_lines, .python);
    try testing.expectEqual(@as(usize, 1), model.types.len);
    try testing.expectEqual(@as(u32, 3), model.types[0].field_count);
    try testing.expectEqual(@as(usize, 2), model.functions.len);
}

test "symbol model: Zig struct methods bind self to owner type" {
    const src =
        \\const Session = struct {
        \\    active: bool,
        \\    ready: bool,
        \\
        \\    pub fn start(self: *Session, client: *Client, opts: Options) void {
        \\        if (self.active) {
        \\            return;
        \\        }
        \\        boot(client);
        \\    }
        \\};
    ;

    const raw_lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(raw_lines);
    const masked = try types.maskSource(testing.allocator, src, .zig_lang);
    defer testing.allocator.free(masked);
    const masked_lines = try types.splitLines(testing.allocator, masked);
    defer testing.allocator.free(masked_lines);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const model = try build(arena.allocator(), raw_lines, masked_lines, .zig_lang);
    try testing.expectEqual(@as(usize, 1), model.types.len);
    try testing.expectEqual(@as(usize, 1), model.functions.len);
    try testing.expectEqualStrings("Session", model.functions[0].owner_type);
    try testing.expectEqual(@as(u32, 2), model.functions[0].argument_count);
}

test "symbol model: Python multiline signatures are modeled" {
    const src =
        \\def build(
        \\    client: Client,
        \\    retries: int,
        \\) -> Result:
        \\    return run(client, retries)
    ;

    const raw_lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(raw_lines);
    const masked = try types.maskSource(testing.allocator, src, .python);
    defer testing.allocator.free(masked);
    const masked_lines = try types.splitLines(testing.allocator, masked);
    defer testing.allocator.free(masked_lines);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const model = try build(arena.allocator(), raw_lines, masked_lines, .python);
    try testing.expectEqual(@as(usize, 1), model.functions.len);
    try testing.expectEqualStrings("build", model.functions[0].name);
    try testing.expectEqual(@as(u32, 2), model.functions[0].argument_count);
}

test "symbol model: Python declarations handle with bindings and walrus without polluting comparisons" {
    const src =
        \\def process(items):
        \\    if items == []:
        \\        return None
        \\    with open("a") as left, open("b") as right:
        \\        if (count := len(items)) > 1:
        \\            return left, right, count
        \\    return None
    ;

    const raw_lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(raw_lines);
    const masked = try types.maskSource(testing.allocator, src, .python);
    defer testing.allocator.free(masked);
    const masked_lines = try types.splitLines(testing.allocator, masked);
    defer testing.allocator.free(masked_lines);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const model = try build(arena.allocator(), raw_lines, masked_lines, .python);
    try testing.expectEqual(@as(usize, 1), model.functions.len);
    try testing.expect(containsString(model.functions[0].declared, "left"));
    try testing.expect(containsString(model.functions[0].declared, "right"));
    try testing.expect(containsString(model.functions[0].declared, "count"));
    try testing.expect(!containsString(model.functions[0].declared, "if"));
}

test "symbol model: lifecycle verbs require a word boundary" {
    try testing.expect(classifyLifecycleVerb("close") == .cleanup);
    try testing.expect(classifyLifecycleVerb("closeConn") == .cleanup);
    try testing.expect(classifyLifecycleVerb("closestPoint") == null);
    try testing.expect(classifyLifecycleVerb("starterPack") == null);
}

test "symbol model: Go embedded fields keep the type name" {
    const src =
        \\type Outer struct {
        \\    sync.Mutex
        \\    *pkg.Something
        \\}
    ;

    const raw_lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(raw_lines);
    const masked = try types.maskSource(testing.allocator, src, .go);
    defer testing.allocator.free(masked);
    const masked_lines = try types.splitLines(testing.allocator, masked);
    defer testing.allocator.free(masked_lines);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const model = try build(arena.allocator(), raw_lines, masked_lines, .go);
    try testing.expectEqual(@as(usize, 1), model.types.len);
    try testing.expectEqualStrings("Mutex", model.types[0].fields[0].name);
    try testing.expectEqualStrings("Something", model.types[0].fields[1].name);
}

test "symbol model: Zig test blocks are analyzed as functions" {
    const src =
        \\test "runs setup" {
        \\    try helper();
        \\}
    ;

    const raw_lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(raw_lines);
    const masked = try types.maskSource(testing.allocator, src, .zig_lang);
    defer testing.allocator.free(masked);
    const masked_lines = try types.splitLines(testing.allocator, masked);
    defer testing.allocator.free(masked_lines);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const model = try build(arena.allocator(), raw_lines, masked_lines, .zig_lang);
    try testing.expectEqual(@as(usize, 1), model.functions.len);
    try testing.expectEqualStrings("runs setup", model.functions[0].name);
}
