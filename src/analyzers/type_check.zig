const std = @import("std");
const guardian_config = @import("../config.zig");
const types = @import("../types.zig");

const Violation = types.Violation;
const Language = types.Language;
const Severity = types.Severity;
const Rule = types.Rule;
const ViolationList = std.array_list.Managed(Violation);

pub fn analyzeTypes(
    allocator: std.mem.Allocator,
    raw_lines: []const []const u8,
    masked_lines: []const []const u8,
    lang: Language,
    cfg: guardian_config.Config,
) ![]Violation {
    var violations = ViolationList.init(allocator);

    switch (lang) {
        .go => {
            try analyzeGoTypes(masked_lines, &violations, cfg);
            try checkGoTypeAssertions(masked_lines, &violations, cfg);
            try appendConfiguredPatterns(masked_lines, cfg.go.extra_banned_patterns, &violations);
        },
        .typescript => {
            try analyzeTypescriptTypes(raw_lines, masked_lines, &violations, cfg);
            try appendConfiguredPatterns(masked_lines, cfg.typescript.extra_banned_patterns, &violations);
        },
        .python => {
            try analyzePythonTypes(allocator, raw_lines, masked_lines, &violations, cfg);
            try appendConfiguredPatterns(masked_lines, cfg.python.extra_banned_patterns, &violations);
        },
        .zig_lang => {
            try analyzeZigTypes(masked_lines, &violations, cfg);
            try appendConfiguredPatterns(masked_lines, cfg.zig.extra_banned_patterns, &violations);
        },
    }

    return violations.toOwnedSlice();
}

fn analyzeGoTypes(
    masked_lines: []const []const u8,
    violations: *ViolationList,
    cfg: guardian_config.Config,
) !void {
    var brace_depth: i32 = 0;
    var in_signature = false;
    var signature_should_check = false;
    var pending_struct_public: ?bool = null;
    var active_struct_depth: ?i32 = null;
    var active_struct_public = false;

    for (masked_lines, 0..) |line, line_idx| {
        const line_no = @as(u32, @intCast(line_idx)) + 1;
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        const starts_signature = std.mem.startsWith(u8, trimmed, "func ");
        const starts_struct = std.mem.startsWith(u8, trimmed, "type ") and
            std.mem.indexOf(u8, trimmed, "struct") != null;

        if (starts_signature) {
            const is_public = isGoExportedName(extractGoFuncName(trimmed));
            signature_should_check = shouldCheckScope(cfg.go.surface_scope, is_public);

            if (cfg.go.ban_generics and shouldCheckScope(cfg.go.generic_scope, is_public) and isGoGenericDeclaration(trimmed)) {
                try appendStaticViolation(
                    violations,
                    line_no,
                    0,
                    .generic_usage,
                    .@"error",
                    "Go generics are banned by config for this codebase",
                );
            }
        }

        if ((starts_signature and signature_should_check) or (in_signature and signature_should_check)) {
            try appendGoSurfaceViolations(line, line_no, violations, cfg);
        }

        if (starts_struct) {
            const is_public = isGoExportedName(extractGoTypeName(trimmed));
            pending_struct_public = is_public;

            if (cfg.go.ban_generics and shouldCheckScope(cfg.go.generic_scope, is_public) and isGoGenericDeclaration(trimmed)) {
                try appendStaticViolation(
                    violations,
                    line_no,
                    0,
                    .generic_usage,
                    .@"error",
                    "Go generics are banned by config for this codebase",
                );
            }
        }

        if (active_struct_depth) |struct_depth| {
            if (brace_depth == struct_depth and shouldCheckGoStructField(cfg.go.surface_scope, active_struct_public, trimmed)) {
                try appendGoSurfaceViolations(line, line_no, violations, cfg);
            }
        }

        if (starts_signature) {
            in_signature = std.mem.indexOfScalar(u8, line, '{') == null;
        } else if (in_signature and std.mem.indexOfScalar(u8, line, '{') != null) {
            in_signature = false;
        }

        for (line) |ch| {
            if (ch == '{') {
                brace_depth += 1;
                if (pending_struct_public) |is_public| {
                    active_struct_depth = brace_depth;
                    active_struct_public = is_public;
                    pending_struct_public = null;
                }
            } else if (ch == '}') {
                if (active_struct_depth) |struct_depth| {
                    if (brace_depth == struct_depth) {
                        active_struct_depth = null;
                        active_struct_public = false;
                    }
                }
                brace_depth -= 1;
                if (brace_depth < 0) {
                    brace_depth = 0;
                }
            }
        }
    }
}

fn appendGoSurfaceViolations(
    line: []const u8,
    line_no: u32,
    violations: *ViolationList,
    cfg: guardian_config.Config,
) !void {
    if (cfg.go.ban_map_string_interface_empty) {
        var search_pos: usize = 0;
        while (std.mem.indexOfPos(u8, line, search_pos, "map[string]interface{}")) |col| {
            try appendStaticViolation(
                violations,
                line_no,
                @intCast(col),
                .banned_type,
                .@"error",
                "use a typed struct instead of map[string]interface{}",
            );
            search_pos = col + "map[string]interface{}".len;
        }
    }

    if (cfg.go.ban_interface_empty) {
        var search_pos: usize = 0;
        while (std.mem.indexOfPos(u8, line, search_pos, "interface{}")) |col| {
            if (col >= "map[string]".len and std.mem.eql(u8, line[col - "map[string]".len .. col], "map[string]")) {
                search_pos = col + "interface{}".len;
                continue;
            }

            try appendStaticViolation(
                violations,
                line_no,
                @intCast(col),
                .banned_type,
                .@"error",
                "use concrete type or typed interface instead of interface{}",
            );
            search_pos = col + "interface{}".len;
        }
    }
}

fn analyzeTypescriptTypes(
    raw_lines: []const []const u8,
    masked_lines: []const []const u8,
    violations: *ViolationList,
    cfg: guardian_config.Config,
) !void {
    for (masked_lines, 0..) |line, line_idx| {
        const line_no = @as(u32, @intCast(line_idx)) + 1;

        if (cfg.typescript.ban_any) {
            if (std.mem.indexOf(u8, line, ": any")) |col| {
                try appendStaticViolation(
                    violations,
                    line_no,
                    @intCast(col),
                    .banned_type,
                    .@"error",
                    "explicit 'any' type — use a concrete type",
                );
            }
            if (std.mem.indexOf(u8, line, ":any")) |col| {
                try appendStaticViolation(
                    violations,
                    line_no,
                    @intCast(col),
                    .banned_type,
                    .@"error",
                    "explicit 'any' type — use a concrete type",
                );
            }
            if (std.mem.indexOf(u8, line, "<any>")) |col| {
                try appendStaticViolation(
                    violations,
                    line_no,
                    @intCast(col),
                    .banned_type,
                    .@"error",
                    "generic 'any' cast — use a concrete type",
                );
            }
        }
        if (cfg.typescript.ban_as_any) {
            if (std.mem.indexOf(u8, line, " as any")) |col| {
                try appendStaticViolation(
                    violations,
                    line_no,
                    @intCast(col),
                    .banned_type,
                    .@"error",
                    "'as any' cast — use proper type narrowing",
                );
            }
        }

        const raw_line = raw_lines[line_idx];
        if (cfg.typescript.ban_ts_ignore) {
            if (std.mem.indexOf(u8, raw_line, "@ts-ignore")) |col| {
                try appendStaticViolation(
                    violations,
                    line_no,
                    @intCast(col),
                    .banned_type,
                    .@"error",
                    "@ts-ignore suppresses type errors — fix the underlying issue",
                );
            }
        }
        if (cfg.typescript.warn_ts_expect_error) {
            if (std.mem.indexOf(u8, raw_line, "@ts-expect-error")) |col| {
                try appendStaticViolation(
                    violations,
                    line_no,
                    @intCast(col),
                    .banned_type,
                    .warn,
                    "@ts-expect-error — document why this is necessary",
                );
            }
        }
    }
}

fn analyzePythonTypes(
    allocator: std.mem.Allocator,
    raw_lines: []const []const u8,
    masked_lines: []const []const u8,
    violations: *ViolationList,
    cfg: guardian_config.Config,
) !void {
    for (raw_lines, 0..) |line, line_idx| {
        if (cfg.python.ban_type_ignore) {
            if (std.mem.indexOf(u8, line, "# type: ignore")) |col| {
                try appendStaticViolation(
                    violations,
                    @as(u32, @intCast(line_idx)) + 1,
                    @intCast(col),
                    .banned_type,
                    .@"error",
                    "type: ignore suppresses type checking — fix the type",
                );
            }
        }
    }

    for (masked_lines, 0..) |line, line_idx| {
        const line_no = @as(u32, @intCast(line_idx)) + 1;
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0) {
            continue;
        }

        if (cfg.python.warn_import_any) {
            if (std.mem.indexOf(u8, trimmed, "from typing import Any")) |col| {
                try appendStaticViolation(
                    violations,
                    line_no,
                    @intCast(col),
                    .banned_type,
                    .warn,
                    "importing Any — prefer concrete types",
                );
            }
        }

        if (looksLikeAnnotatedAssignment(trimmed)) {
            const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
            const after = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
            const annotation_end = std.mem.indexOfScalar(u8, after, '=') orelse after.len;
            try appendPythonAnnotationViolations(after[0..annotation_end], line_no, @intCast(colon + 1), violations, cfg);
        }
    }

    try checkPythonFunctionAnnotations(allocator, masked_lines, violations, cfg);
}

fn analyzeZigTypes(
    masked_lines: []const []const u8,
    violations: *ViolationList,
    cfg: guardian_config.Config,
) !void {
    var brace_depth: i32 = 0;
    var pending_function_public: ?bool = null;
    var active_function_depth: ?i32 = null;
    var active_function_public = false;

    for (masked_lines, 0..) |line, line_idx| {
        const line_no = @as(u32, @intCast(line_idx)) + 1;
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        const is_function_line = std.mem.startsWith(u8, trimmed, "fn ") or
            std.mem.startsWith(u8, trimmed, "pub fn ") or
            std.mem.startsWith(u8, trimmed, "export fn ");
        const is_public_function = std.mem.startsWith(u8, trimmed, "pub fn ") or
            std.mem.startsWith(u8, trimmed, "export fn ");

        if (is_function_line) {
            pending_function_public = is_public_function;
        }

        if (cfg.zig.warn_ptr_cast and shouldCheckScope(cfg.zig.cast_scope, active_function_public)) {
            if (std.mem.indexOf(u8, line, "@ptrCast")) |col| {
                try appendStaticViolation(
                    violations,
                    line_no,
                    @intCast(col),
                    .banned_type,
                    .warn,
                    "@ptrCast — ensure this is bounds-checked and necessary",
                );
            }
        }
        if (cfg.zig.warn_int_cast and shouldCheckScope(cfg.zig.cast_scope, active_function_public)) {
            if (std.mem.indexOf(u8, line, "@intCast")) |col| {
                try appendStaticViolation(
                    violations,
                    line_no,
                    @intCast(col),
                    .banned_type,
                    .warn,
                    "@intCast — verify value fits target type, prefer math.cast",
                );
            }
        }
        if (cfg.zig.warn_anytype) {
            if (std.mem.indexOf(u8, line, "anytype")) |col| {
                if (is_function_line and shouldCheckScope(cfg.zig.anytype_scope, is_public_function)) {
                    try appendStaticViolation(
                        violations,
                        line_no,
                        @intCast(col),
                        .banned_type,
                        .warn,
                        "anytype in public signatures should be justified and minimal",
                    );
                }
            }
        }

        for (line) |ch| {
            if (ch == '{') {
                brace_depth += 1;
                if (pending_function_public) |is_public| {
                    active_function_depth = brace_depth;
                    active_function_public = is_public;
                    pending_function_public = null;
                }
            } else if (ch == '}') {
                if (active_function_depth) |depth| {
                    if (brace_depth == depth) {
                        active_function_depth = null;
                        active_function_public = false;
                    }
                }
                brace_depth -= 1;
                if (brace_depth < 0) {
                    brace_depth = 0;
                }
            }
        }
    }
}

fn checkPythonFunctionAnnotations(
    allocator: std.mem.Allocator,
    masked_lines: []const []const u8,
    violations: *ViolationList,
    cfg: guardian_config.Config,
) !void {
    var signature = std.array_list.Managed(u8).init(allocator);
    defer signature.deinit();

    var collecting = false;
    var signature_start_line: u32 = 0;

    for (masked_lines, 0..) |line, line_idx| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "def ") or
            std.mem.startsWith(u8, trimmed, "async def "))
        {
            collecting = true;
            signature_start_line = @as(u32, @intCast(line_idx)) + 1;
            try signature.resize(0);
            try signature.appendSlice(trimmed);

            if (std.mem.indexOfScalar(u8, trimmed, ':') != null) {
                try finalizePythonSignature(signature.items, signature_start_line, violations, cfg);
                collecting = false;
            }
            continue;
        }

        if (!collecting) {
            continue;
        }

        try signature.append(' ');
        try signature.appendSlice(trimmed);
        if (std.mem.indexOfScalar(u8, trimmed, ':') != null) {
            try finalizePythonSignature(signature.items, signature_start_line, violations, cfg);
            collecting = false;
        }
    }

    if (collecting) {
        try finalizePythonSignature(signature.items, signature_start_line, violations, cfg);
    }
}

fn finalizePythonSignature(
    signature: []const u8,
    line_no: u32,
    violations: *ViolationList,
    cfg: guardian_config.Config,
) !void {
    const func_name = extractPythonFuncName(signature);
    if (func_name.len == 0) {
        return;
    }

    try appendPythonAnnotationViolations(signature, line_no, 0, violations, cfg);

    if (cfg.python.warn_missing_return_annotation and func_name[0] != '_' and std.mem.indexOf(u8, signature, "->") == null) {
        try appendStaticViolation(
            violations,
            line_no,
            0,
            .banned_type,
            .warn,
            "public function missing return type annotation",
        );
    }
}

fn appendPythonAnnotationViolations(
    annotation: []const u8,
    line_no: u32,
    column_base: u32,
    violations: *ViolationList,
    cfg: guardian_config.Config,
) !void {
    if (cfg.python.ban_any_annotation) {
        if (std.mem.indexOf(u8, annotation, "Any")) |col| {
            if (isPythonAnyBoundary(annotation, col)) {
                try appendStaticViolation(
                    violations,
                    line_no,
                    column_base + @as(u32, @intCast(col)),
                    .banned_type,
                    .@"error",
                    "Any type annotation — use a concrete type or Protocol",
                );
            }
        }
    }

    if (cfg.python.warn_bare_dict) {
        if (findBarePythonContainer(annotation, "dict")) |col| {
            try appendStaticViolation(
                violations,
                line_no,
                column_base + @as(u32, @intCast(col)),
                .banned_type,
                .warn,
                "bare dict without type params — use dict[K, V] or TypedDict",
            );
        }
    }

    if (cfg.python.warn_bare_list) {
        if (findBarePythonContainer(annotation, "list")) |col| {
            try appendStaticViolation(
                violations,
                line_no,
                column_base + @as(u32, @intCast(col)),
                .banned_type,
                .warn,
                "bare list without type params — use list[T]",
            );
        }
    }
}

fn isPythonAnyBoundary(annotation: []const u8, col: usize) bool {
    if (col == 0) {
        return true;
    }

    const prev = annotation[col - 1];
    return prev == ':' or
        prev == ' ' or
        prev == '-' or
        prev == ',' or
        prev == '(';
}

fn findBarePythonContainer(annotation: []const u8, container: []const u8) ?usize {
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, annotation, search_pos, container)) |col| {
        const after_pos = col + container.len;
        if (after_pos >= annotation.len or annotation[after_pos] != '[') {
            return col;
        }
        search_pos = after_pos;
    }
    return null;
}

fn looksLikeAnnotatedAssignment(trimmed: []const u8) bool {
    if (std.mem.startsWith(u8, trimmed, "def ") or
        std.mem.startsWith(u8, trimmed, "async def ") or
        std.mem.startsWith(u8, trimmed, "class "))
    {
        return false;
    }

    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return false;
    return colon + 1 < trimmed.len and trimmed[trimmed.len - 1] != ':';
}

fn extractPythonFuncName(signature: []const u8) []const u8 {
    var search = signature;
    if (std.mem.startsWith(u8, search, "async def ")) {
        search = search["async def ".len..];
    } else if (std.mem.startsWith(u8, search, "def ")) {
        search = search["def ".len..];
    }

    const end = std.mem.indexOfScalar(u8, search, '(') orelse return "";
    return search[0..end];
}

fn checkGoTypeAssertions(
    masked_lines: []const []const u8,
    violations: *ViolationList,
    cfg: guardian_config.Config,
) !void {
    for (masked_lines, 0..) |line, line_idx| {
        const line_no = @as(u32, @intCast(line_idx)) + 1;
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        if (cfg.go.warn_type_switch) {
            if (std.mem.indexOf(u8, line, ".(type)")) |col| {
                try appendStaticViolation(
                    violations,
                    line_no,
                    @intCast(col),
                    .banned_type,
                    .warn,
                    "type switch — ensure all cases are handled",
                );
                continue;
            }
        }

        if (cfg.go.ban_unchecked_type_assertions) {
            if (std.mem.indexOf(u8, line, ".(")) |col| {
                if (std.mem.startsWith(u8, trimmed, "switch ") or std.mem.startsWith(u8, trimmed, "case ")) {
                    continue;
                }

                const has_comma_ok = std.mem.indexOf(u8, line, ", ok") != null or
                    std.mem.indexOf(u8, line, ",ok") != null or
                    std.mem.indexOf(u8, line, ", _") != null;

                if (!has_comma_ok) {
                    try appendStaticViolation(
                        violations,
                        line_no,
                        @intCast(col),
                        .banned_type,
                        .@"error",
                        "type assertion without comma-ok pattern — use val, ok := x.(T)",
                    );
                }
            }
        }
    }
}

fn appendStaticViolation(
    violations: *ViolationList,
    line_no: u32,
    column: u32,
    rule: Rule,
    severity: Severity,
    message: []const u8,
) !void {
    try violations.append(.{
        .line = line_no,
        .column = column,
        .end_line = line_no,
        .rule = rule,
        .severity = severity,
        .message = message,
    });
}

fn appendConfiguredPatterns(
    masked_lines: []const []const u8,
    patterns: []const guardian_config.Pattern,
    violations: *ViolationList,
) !void {
    for (patterns) |pattern| {
        for (masked_lines, 0..) |line, line_idx| {
            if (std.mem.indexOf(u8, line, pattern.pattern)) |col| {
                try appendStaticViolation(
                    violations,
                    @as(u32, @intCast(line_idx)) + 1,
                    @intCast(col),
                    .banned_type,
                    pattern.severity,
                    pattern.message,
                );
            }
        }
    }
}

fn shouldCheckScope(scope: guardian_config.SurfaceScope, is_public: bool) bool {
    return switch (scope) {
        .all => true,
        .public_only => is_public,
    };
}

fn shouldCheckGoStructField(
    scope: guardian_config.SurfaceScope,
    struct_is_public: bool,
    trimmed: []const u8,
) bool {
    return switch (scope) {
        .all => true,
        .public_only => struct_is_public and isGoExportedStructField(trimmed),
    };
}

fn isGoExportedName(name: []const u8) bool {
    return name.len > 0 and std.ascii.isUpper(name[0]);
}

fn isGoExportedStructField(trimmed: []const u8) bool {
    if (trimmed.len == 0 or trimmed[0] == '}' or trimmed[0] == '{') {
        return false;
    }

    var start: usize = 0;
    if (trimmed[start] == '*') {
        start += 1;
    }

    var token_start = start;
    var idx = start;
    while (idx < trimmed.len and trimmed[idx] != ' ' and trimmed[idx] != '\t' and trimmed[idx] != '`') : (idx += 1) {
        if (trimmed[idx] == '.') {
            token_start = idx + 1;
        }
    }

    if (token_start >= idx) {
        return false;
    }

    return isGoExportedName(trimmed[token_start..idx]);
}

fn extractGoFuncName(trimmed: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, trimmed, "func ")) {
        return "";
    }

    var after = std.mem.trimLeft(u8, trimmed["func ".len..], " \t");
    if (after.len == 0) {
        return "";
    }

    if (after[0] == '(') {
        const receiver_end = findMatchingParen(after) orelse return "";
        after = std.mem.trimLeft(u8, after[receiver_end + 1 ..], " \t");
    }

    const name_end = scanGoIdentifier(after);
    if (name_end == 0) {
        return "";
    }

    return after[0..name_end];
}

fn extractGoTypeName(trimmed: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, trimmed, "type ")) {
        return "";
    }

    const after = std.mem.trimLeft(u8, trimmed["type ".len..], " \t");
    const name_end = scanGoIdentifier(after);
    if (name_end == 0) {
        return "";
    }

    return after[0..name_end];
}

fn isGoGenericDeclaration(trimmed: []const u8) bool {
    if (std.mem.startsWith(u8, trimmed, "func ")) {
        var after = std.mem.trimLeft(u8, trimmed["func ".len..], " \t");
        if (after.len == 0) {
            return false;
        }

        if (after[0] == '(') {
            const receiver_end = findMatchingParen(after) orelse return false;
            after = std.mem.trimLeft(u8, after[receiver_end + 1 ..], " \t");
        }

        const name_end = scanGoIdentifier(after);
        return name_end > 0 and name_end < after.len and after[name_end] == '[';
    }

    if (std.mem.startsWith(u8, trimmed, "type ")) {
        const after = std.mem.trimLeft(u8, trimmed["type ".len..], " \t");
        const name_end = scanGoIdentifier(after);
        return name_end > 0 and name_end < after.len and after[name_end] == '[';
    }

    return false;
}

fn findMatchingParen(value: []const u8) ?usize {
    var depth: i32 = 0;
    for (value, 0..) |ch, idx| {
        if (ch == '(') {
            depth += 1;
        } else if (ch == ')') {
            depth -= 1;
            if (depth == 0) {
                return idx;
            }
        }
    }
    return null;
}

fn scanGoIdentifier(value: []const u8) usize {
    var idx: usize = 0;
    while (idx < value.len) : (idx += 1) {
        const ch = value[idx];
        if (!(std.ascii.isAlphabetic(ch) or std.ascii.isDigit(ch) or ch == '_')) {
            break;
        }
    }
    return idx;
}

// Tests
const testing = std.testing;

test "types: detects interface{} in Go function signatures" {
    const src =
        \\func Process(data interface{}) {
        \\    fmt.Println(data)
        \\}
    ;
    const raw_lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(raw_lines);

    const masked_source = try types.maskSource(testing.allocator, src, .go);
    defer testing.allocator.free(masked_source);
    const masked_lines = try types.splitLines(testing.allocator, masked_source);
    defer testing.allocator.free(masked_lines);

    const v = try analyzeTypes(testing.allocator, raw_lines, masked_lines, .go, .{});
    defer types.freeViolations(testing.allocator, v);
    try testing.expect(v.len > 0);
}

test "types: ignores interface{} in Go strings and comments" {
    const src =
        \\func render() {
        \\    fmt.Println("interface{}")
        \\    // interface{}
        \\}
    ;
    const raw_lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(raw_lines);

    const masked_source = try types.maskSource(testing.allocator, src, .go);
    defer testing.allocator.free(masked_source);
    const masked_lines = try types.splitLines(testing.allocator, masked_source);
    defer testing.allocator.free(masked_lines);

    const v = try analyzeTypes(testing.allocator, raw_lines, masked_lines, .go, .{});
    defer types.freeViolations(testing.allocator, v);
    try testing.expectEqual(@as(usize, 0), v.len);
}

test "types: detects any in TypeScript" {
    const src =
        \\function handle(data: any): void {
        \\    console.log(data);
        \\}
    ;
    const raw_lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(raw_lines);

    const masked_source = try types.maskSource(testing.allocator, src, .typescript);
    defer testing.allocator.free(masked_source);
    const masked_lines = try types.splitLines(testing.allocator, masked_source);
    defer testing.allocator.free(masked_lines);

    const v = try analyzeTypes(testing.allocator, raw_lines, masked_lines, .typescript, .{});
    defer types.freeViolations(testing.allocator, v);
    try testing.expect(v.len > 0);
}

test "types: detects Go generics when banned by config" {
    const src =
        \\func Map[T any](items []T) []T {
        \\    return items
        \\}
    ;
    const raw_lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(raw_lines);

    const masked_source = try types.maskSource(testing.allocator, src, .go);
    defer testing.allocator.free(masked_source);
    const masked_lines = try types.splitLines(testing.allocator, masked_source);
    defer testing.allocator.free(masked_lines);

    const v = try analyzeTypes(testing.allocator, raw_lines, masked_lines, .go, .{});
    defer types.freeViolations(testing.allocator, v);
    try testing.expect(v.len > 0);
    try testing.expectEqual(Rule.generic_usage, v[0].rule);
}

test "types: ignores internal Go generics with public-only scope" {
    const src =
        \\func mapItems[T any](items []T) []T {
        \\    return items
        \\}
    ;
    const raw_lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(raw_lines);

    const masked_source = try types.maskSource(testing.allocator, src, .go);
    defer testing.allocator.free(masked_source);
    const masked_lines = try types.splitLines(testing.allocator, masked_source);
    defer testing.allocator.free(masked_lines);

    const v = try analyzeTypes(testing.allocator, raw_lines, masked_lines, .go, .{});
    defer types.freeViolations(testing.allocator, v);
    try testing.expectEqual(@as(usize, 0), v.len);
}

test "types: ignores internal Zig anytype with public-only scope" {
    const src =
        \\fn helper(value: anytype) void {
        \\    _ = value;
        \\}
    ;
    const raw_lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(raw_lines);

    const masked_source = try types.maskSource(testing.allocator, src, .zig_lang);
    defer testing.allocator.free(masked_source);
    const masked_lines = try types.splitLines(testing.allocator, masked_source);
    defer testing.allocator.free(masked_lines);

    const v = try analyzeTypes(testing.allocator, raw_lines, masked_lines, .zig_lang, .{});
    defer types.freeViolations(testing.allocator, v);
    try testing.expectEqual(@as(usize, 0), v.len);
}

test "types: warns on public Zig anytype with public-only scope" {
    const src =
        \\pub fn helper(value: anytype) void {
        \\    _ = value;
        \\}
    ;
    const raw_lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(raw_lines);

    const masked_source = try types.maskSource(testing.allocator, src, .zig_lang);
    defer testing.allocator.free(masked_source);
    const masked_lines = try types.splitLines(testing.allocator, masked_source);
    defer testing.allocator.free(masked_lines);

    const v = try analyzeTypes(testing.allocator, raw_lines, masked_lines, .zig_lang, .{});
    defer types.freeViolations(testing.allocator, v);
    try testing.expect(v.len > 0);
}
