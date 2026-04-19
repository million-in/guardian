const std = @import("std");
const config_paths = @import("config_paths.zig");
const types = @import("types.zig");

const Severity = types.Severity;

pub const SurfaceScope = enum {
    all,
    public_only,
};

pub const Pattern = struct {
    pattern: []const u8,
    severity: Severity = .@"error",
    message: []const u8,
};

pub const Limits = struct {
    max_nesting: u32,
    cyclomatic_complexity_warn: u32,
    cyclomatic_complexity_error: u32,
    max_imports: u32,
    max_functions_per_file: u32,
    max_function_lines: u32,
    max_function_arguments: u32,
    max_type_fields: u32,
    max_hidden_touch_excess: u32,
    max_lifecycle_flags: u32,
    max_line_length: u32,
    max_excerpt_lines: u32,
    max_excerpt_chars: u32,
};

pub const LimitsPatch = struct {
    max_nesting: ?u32 = null,
    cyclomatic_complexity_warn: ?u32 = null,
    cyclomatic_complexity_error: ?u32 = null,
    max_imports: ?u32 = null,
    max_functions_per_file: ?u32 = null,
    max_function_lines: ?u32 = null,
    max_function_arguments: ?u32 = null,
    max_type_fields: ?u32 = null,
    max_hidden_touch_excess: ?u32 = null,
    max_lifecycle_flags: ?u32 = null,
    max_line_length: ?u32 = null,
    max_excerpt_lines: ?u32 = null,
    max_excerpt_chars: ?u32 = null,
};

pub const Scan = struct {
    extensions: []const []const u8,
    ignored_dirs: []const []const u8,
};

pub const GoRules = struct {
    ban_interface_empty: bool,
    ban_map_string_interface_empty: bool,
    warn_type_switch: bool,
    ban_unchecked_type_assertions: bool,
    ban_generics: bool,
    surface_scope: SurfaceScope,
    generic_scope: SurfaceScope,
    extra_banned_patterns: []const Pattern,
};

pub const GoRulesPatch = struct {
    ban_interface_empty: ?bool = null,
    ban_map_string_interface_empty: ?bool = null,
    warn_type_switch: ?bool = null,
    ban_unchecked_type_assertions: ?bool = null,
    ban_generics: ?bool = null,
    surface_scope: ?SurfaceScope = null,
    generic_scope: ?SurfaceScope = null,
    extra_banned_patterns: ?[]const Pattern = null,
};

pub const TypeScriptRules = struct {
    ban_any: bool,
    ban_as_any: bool,
    ban_ts_ignore: bool,
    warn_ts_expect_error: bool,
    extra_banned_patterns: []const Pattern,
};

pub const TypeScriptRulesPatch = struct {
    ban_any: ?bool = null,
    ban_as_any: ?bool = null,
    ban_ts_ignore: ?bool = null,
    warn_ts_expect_error: ?bool = null,
    extra_banned_patterns: ?[]const Pattern = null,
};

pub const PythonRules = struct {
    ban_type_ignore: bool,
    warn_import_any: bool,
    ban_any_annotation: bool,
    warn_bare_dict: bool,
    warn_bare_list: bool,
    warn_missing_return_annotation: bool,
    extra_banned_patterns: []const Pattern,
};

pub const PythonRulesPatch = struct {
    ban_type_ignore: ?bool = null,
    warn_import_any: ?bool = null,
    ban_any_annotation: ?bool = null,
    warn_bare_dict: ?bool = null,
    warn_bare_list: ?bool = null,
    warn_missing_return_annotation: ?bool = null,
    extra_banned_patterns: ?[]const Pattern = null,
};

pub const ZigRules = struct {
    warn_ptr_cast: bool,
    warn_int_cast: bool,
    warn_anytype: bool,
    cast_scope: SurfaceScope,
    anytype_scope: SurfaceScope,
    extra_banned_patterns: []const Pattern,
};

pub const ZigRulesPatch = struct {
    warn_ptr_cast: ?bool = null,
    warn_int_cast: ?bool = null,
    warn_anytype: ?bool = null,
    cast_scope: ?SurfaceScope = null,
    anytype_scope: ?SurfaceScope = null,
    extra_banned_patterns: ?[]const Pattern = null,
};

pub const Override = struct {
    path_prefixes: []const []const u8 = &.{},
    path_suffixes: []const []const u8 = &.{},
    path_contains: []const []const u8 = &.{},
    roles: []const []const u8 = &.{},
    extensions: []const []const u8 = &.{},
    limits: LimitsPatch = .{},
    go: GoRulesPatch = .{},
    typescript: TypeScriptRulesPatch = .{},
    python: PythonRulesPatch = .{},
    zig: ZigRulesPatch = .{},

    pub fn matches(self: Override, file_path: []const u8) bool {
        if (self.path_prefixes.len > 0 and !config_paths.matchesAnyPrefix(file_path, self.path_prefixes)) {
            return false;
        }
        if (self.path_suffixes.len > 0 and !config_paths.matchesAnySuffix(file_path, self.path_suffixes)) {
            return false;
        }
        if (self.path_contains.len > 0 and !config_paths.matchesAnyContains(file_path, self.path_contains)) {
            return false;
        }
        if (self.extensions.len > 0 and !config_paths.matchesAnyExtension(file_path, self.extensions)) {
            return false;
        }
        if (self.roles.len > 0 and !config_paths.matchesAnyRole(file_path, self.roles)) {
            return false;
        }
        return true;
    }
};

pub const Config = struct {
    root_path: []const u8 = "",
    limits: Limits,
    scan: Scan,
    go: GoRules,
    typescript: TypeScriptRules,
    python: PythonRules,
    zig: ZigRules,
    overrides: []const Override = &.{},

    pub fn isSupportedPath(self: Config, path: []const u8) bool {
        return config_paths.matchesAnyExtension(path, self.scan.extensions);
    }

    pub fn isIgnoredDir(self: Config, name: []const u8) bool {
        for (self.scan.ignored_dirs) |dir_name| {
            if (std.mem.eql(u8, name, dir_name)) {
                return true;
            }
        }
        return false;
    }

    pub fn resolvedForPath(self: Config, file_path: []const u8) Config {
        var resolved = self;
        resolved.overrides = &.{};

        const match_path = self.relativePathForMatch(file_path);
        for (self.overrides) |override_cfg| {
            if (!override_cfg.matches(match_path)) {
                continue;
            }
            applyLimitsPatch(&resolved.limits, override_cfg.limits);
            applyGoPatch(&resolved.go, override_cfg.go);
            applyTypeScriptPatch(&resolved.typescript, override_cfg.typescript);
            applyPythonPatch(&resolved.python, override_cfg.python);
            applyZigPatch(&resolved.zig, override_cfg.zig);
        }

        return resolved;
    }

    fn relativePathForMatch(self: Config, file_path: []const u8) []const u8 {
        if (self.root_path.len == 0 or !std.fs.path.isAbsolute(file_path)) {
            return file_path;
        }
        if (!std.mem.startsWith(u8, file_path, self.root_path)) {
            return file_path;
        }

        var relative = file_path[self.root_path.len..];
        while (relative.len > 0 and (relative[0] == '/' or relative[0] == '\\')) {
            relative = relative[1..];
        }
        return if (relative.len == 0) "." else relative;
    }
};

fn applyLimitsPatch(target: *Limits, patch: LimitsPatch) void {
    inline for (.{
        "max_nesting",
        "cyclomatic_complexity_warn",
        "cyclomatic_complexity_error",
        "max_imports",
        "max_functions_per_file",
        "max_function_lines",
        "max_function_arguments",
        "max_type_fields",
        "max_hidden_touch_excess",
        "max_lifecycle_flags",
        "max_line_length",
        "max_excerpt_lines",
        "max_excerpt_chars",
    }) |field_name| {
        applyOptionalField(Limits, LimitsPatch, target, patch, field_name);
    }
}

fn applyGoPatch(target: *GoRules, patch: GoRulesPatch) void {
    inline for (.{
        "ban_interface_empty",
        "ban_map_string_interface_empty",
        "warn_type_switch",
        "ban_unchecked_type_assertions",
        "ban_generics",
        "surface_scope",
        "generic_scope",
        "extra_banned_patterns",
    }) |field_name| {
        applyOptionalField(GoRules, GoRulesPatch, target, patch, field_name);
    }
}

fn applyTypeScriptPatch(target: *TypeScriptRules, patch: TypeScriptRulesPatch) void {
    inline for (.{
        "ban_any",
        "ban_as_any",
        "ban_ts_ignore",
        "warn_ts_expect_error",
        "extra_banned_patterns",
    }) |field_name| {
        applyOptionalField(TypeScriptRules, TypeScriptRulesPatch, target, patch, field_name);
    }
}

fn applyPythonPatch(target: *PythonRules, patch: PythonRulesPatch) void {
    inline for (.{
        "ban_type_ignore",
        "warn_import_any",
        "ban_any_annotation",
        "warn_bare_dict",
        "warn_bare_list",
        "warn_missing_return_annotation",
        "extra_banned_patterns",
    }) |field_name| {
        applyOptionalField(PythonRules, PythonRulesPatch, target, patch, field_name);
    }
}

fn applyZigPatch(target: *ZigRules, patch: ZigRulesPatch) void {
    inline for (.{
        "warn_ptr_cast",
        "warn_int_cast",
        "warn_anytype",
        "cast_scope",
        "anytype_scope",
        "extra_banned_patterns",
    }) |field_name| {
        applyOptionalField(ZigRules, ZigRulesPatch, target, patch, field_name);
    }
}

fn applyOptionalField(
    comptime Target: type,
    comptime Patch: type,
    target: *Target,
    patch: Patch,
    comptime field_name: []const u8,
) void {
    if (@field(patch, field_name)) |value| {
        @field(target, field_name) = value;
    }
}

const testing = std.testing;
const test_config = @import("test_config.zig");

test "config schema: applies path and role overrides" {
    var loaded = try test_config.loadDefault(testing.allocator);
    defer loaded.deinit();

    var base = loaded.value;
    base.root_path = "/repo";
    base.overrides = &[_]Override{
        .{
            .path_prefixes = &[_][]const u8{"src/analyzers/"},
            .limits = .{
                .max_function_lines = 120,
                .max_line_length = 160,
                .max_function_arguments = 8,
            },
        },
        .{
            .roles = &[_][]const u8{"test"},
            .go = .{
                .ban_generics = false,
            },
        },
    };

    const analyzer_cfg = base.resolvedForPath("/repo/src/analyzers/type_check.zig");
    try testing.expectEqual(@as(u32, 120), analyzer_cfg.limits.max_function_lines);
    try testing.expectEqual(@as(u32, 160), analyzer_cfg.limits.max_line_length);
    try testing.expectEqual(@as(u32, 8), analyzer_cfg.limits.max_function_arguments);

    const test_cfg = base.resolvedForPath("/repo/pkg/user_test.go");
    try testing.expect(!test_cfg.go.ban_generics);
}
