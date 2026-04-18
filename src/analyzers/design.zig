const std = @import("std");
const guardian_config = @import("../config.zig");
const symbol_model = @import("../symbol_model.zig");
const types = @import("../types.zig");

const Language = types.Language;
const LifecycleActionKind = symbol_model.LifecycleActionKind;
const Rule = types.Rule;
const Violation = types.Violation;
const ViolationList = std.array_list.Managed(Violation);

pub fn analyzeDesign(
    allocator: std.mem.Allocator,
    raw_lines: []const []const u8,
    masked_lines: []const []const u8,
    lang: Language,
    cfg: guardian_config.Config,
) ![]Violation {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const model = try symbol_model.build(arena.allocator(), raw_lines, masked_lines, lang);
    var violations = ViolationList.init(allocator);

    try appendArgumentViolations(allocator, &violations, model, cfg);
    try appendFieldViolations(allocator, &violations, model, cfg);
    try appendHiddenCouplingViolations(allocator, &violations, model, cfg);
    try appendTemporalCouplingViolations(allocator, &violations, model);
    try appendBooleanStateViolations(allocator, &violations, model, cfg);
    try appendOwnershipViolations(allocator, &violations, model);

    return violations.toOwnedSlice();
}

fn appendArgumentViolations(
    allocator: std.mem.Allocator,
    violations: *ViolationList,
    model: symbol_model.Model,
    cfg: guardian_config.Config,
) !void {
    for (model.functions) |func| {
        if (func.argument_count <= cfg.limits.max_function_arguments) {
            continue;
        }
        try violations.append(.{
            .line = func.start_line,
            .column = 0,
            .end_line = func.end_line,
            .rule = .too_many_arguments,
            .severity = .@"error",
            .message = try std.fmt.allocPrint(
                allocator,
                "function '{s}' has {d} arguments (max {d})",
                .{ func.name, func.argument_count, cfg.limits.max_function_arguments },
            ),
            .message_owned = true,
        });
    }
}

fn appendFieldViolations(
    allocator: std.mem.Allocator,
    violations: *ViolationList,
    model: symbol_model.Model,
    cfg: guardian_config.Config,
) !void {
    for (model.types) |info| {
        if (info.field_count <= cfg.limits.max_type_fields) {
            continue;
        }
        try violations.append(.{
            .line = info.start_line,
            .column = 0,
            .end_line = info.end_line,
            .rule = .too_many_fields,
            .severity = .@"error",
            .message = try std.fmt.allocPrint(
                allocator,
                "type '{s}' has {d} fields (max {d})",
                .{ info.name, info.field_count, cfg.limits.max_type_fields },
            ),
            .message_owned = true,
        });
    }
}

fn appendHiddenCouplingViolations(
    allocator: std.mem.Allocator,
    violations: *ViolationList,
    model: symbol_model.Model,
    cfg: guardian_config.Config,
) !void {
    for (model.functions) |func| {
        const max_touch_count = func.declared.len + cfg.limits.max_hidden_touch_excess;
        if (func.touched.len <= max_touch_count) {
            continue;
        }
        try violations.append(.{
            .line = func.start_line,
            .column = 0,
            .end_line = func.end_line,
            .rule = .hidden_coupling,
            .severity = .warn,
            .message = try std.fmt.allocPrint(
                allocator,
                "function '{s}' touches {d} external dependencies with {d} declarations (max excess {d})",
                .{ func.name, func.touched.len, func.declared.len, cfg.limits.max_hidden_touch_excess },
            ),
            .message_owned = true,
        });
    }
}

fn appendTemporalCouplingViolations(
    allocator: std.mem.Allocator,
    violations: *ViolationList,
    model: symbol_model.Model,
) !void {
    for (model.types) |info| {
        if (info.has_explicit_state or info.lifecycle_bool_fields.len == 0) {
            continue;
        }

        var start_method: ?symbol_model.FunctionInfo = null;
        var cleanup_method: ?symbol_model.FunctionInfo = null;
        var reads_lifecycle_flag = false;

        for (model.functions) |func| {
            if (!std.mem.eql(u8, func.owner_type, info.name)) {
                continue;
            }

            if (classifyLifecycleName(func.name) == .start and start_method == null) {
                start_method = func;
            } else if (classifyLifecycleName(func.name) == .cleanup and cleanup_method == null) {
                cleanup_method = func;
            }

            if (!reads_lifecycle_flag and countSharedNames(func.bool_reads, info.lifecycle_bool_fields) > 0) {
                reads_lifecycle_flag = true;
            }
        }

        if (start_method == null or cleanup_method == null or !reads_lifecycle_flag) {
            continue;
        }

        try violations.append(.{
            .line = info.start_line,
            .column = 0,
            .end_line = info.end_line,
            .rule = .temporal_coupling,
            .severity = .@"error",
            .message = try std.fmt.allocPrint(
                allocator,
                "type '{s}' exposes ordered lifecycle methods '{s}' and '{s}' guarded by booleans without an explicit state enum",
                .{ info.name, start_method.?.name, cleanup_method.?.name },
            ),
            .message_owned = true,
        });
    }
}

fn appendBooleanStateViolations(
    allocator: std.mem.Allocator,
    violations: *ViolationList,
    model: symbol_model.Model,
    cfg: guardian_config.Config,
) !void {
    for (model.types) |info| {
        if (info.has_explicit_state or info.lifecycle_bool_fields.len <= cfg.limits.max_lifecycle_flags) {
            continue;
        }

        var found_branching_reader = false;
        for (model.functions) |func| {
            if (!std.mem.eql(u8, func.owner_type, info.name)) {
                continue;
            }
            if (countSharedNames(func.bool_reads, info.lifecycle_bool_fields) >= 2) {
                found_branching_reader = true;
                break;
            }
        }

        if (!found_branching_reader) {
            continue;
        }

        try violations.append(.{
            .line = info.start_line,
            .column = 0,
            .end_line = info.end_line,
            .rule = .boolean_state_machine,
            .severity = .@"error",
            .message = try std.fmt.allocPrint(
                allocator,
                "type '{s}' has {d} lifecycle booleans (max {d}); use a single state enum with explicit transitions",
                .{ info.name, info.lifecycle_bool_fields.len, cfg.limits.max_lifecycle_flags },
            ),
            .message_owned = true,
        });
    }
}

fn appendOwnershipViolations(
    allocator: std.mem.Allocator,
    violations: *ViolationList,
    model: symbol_model.Model,
) !void {
    var reported = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (reported.items) |key| {
            allocator.free(key);
        }
        reported.deinit();
    }

    for (model.functions, 0..) |left, left_idx| {
        if (left.has_explicit_scope_cleanup) {
            continue;
        }
        for (left.lifecycle_actions) |left_action| {
            if (left_action.kind != .cleanup) {
                continue;
            }
            var right_idx = left_idx + 1;
            while (right_idx < model.functions.len) : (right_idx += 1) {
                const right = model.functions[right_idx];
                if (right.has_explicit_scope_cleanup) {
                    continue;
                }
                if (!sameOwnershipFamily(left.owner_type, right.owner_type)) {
                    continue;
                }
                for (right.lifecycle_actions) |right_action| {
                    if (right_action.kind != .cleanup or !std.mem.eql(u8, left_action.target, right_action.target)) {
                        continue;
                    }

                    const key = try std.fmt.allocPrint(
                        allocator,
                        "{s}|{s}|{s}",
                        .{ if (left.owner_type.len > 0) left.owner_type else "<file>", left_action.target, left.name },
                    );
                    if (containsString(reported.items, key)) {
                        allocator.free(key);
                        continue;
                    }
                    try reported.append(key);

                    try violations.append(.{
                        .line = left.start_line,
                        .column = 0,
                        .end_line = right.end_line,
                        .rule = .ambiguous_lifecycle_ownership,
                        .severity = .@"error",
                        .message = try std.fmt.allocPrint(
                            allocator,
                            "resource '{s}' is cleaned in both '{s}' and '{s}' — ownership is ambiguous",
                            .{ left_action.target, left.name, right.name },
                        ),
                        .message_owned = true,
                    });
                    break;
                }
            }
        }
    }
}

fn classifyLifecycleName(name: []const u8) ?LifecycleActionKind {
    return symbol_model.classifyLifecycleVerb(name);
}

fn countSharedNames(left: []const []const u8, right: []const []const u8) usize {
    var count: usize = 0;
    for (left) |item| {
        if (containsString(right, item)) {
            count += 1;
        }
    }
    return count;
}

fn sameOwnershipFamily(left: []const u8, right: []const u8) bool {
    if (left.len == 0 and right.len == 0) {
        return true;
    }
    return std.mem.eql(u8, left, right);
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) {
            return true;
        }
    }
    return false;
}

const testing = std.testing;

test "design: Go detects too many arguments and hidden coupling" {
    const src =
        \\func Build(a int, b int, c int, d int, e int, f int, g int) int {
        \\    return run(pkg.Load(), repo.Fetch(), service.Call(), config.Read(), metrics.Emit(), clock.Now(), audit.Track(), cache.Hit(), logger.Write())
        \\}
    ;

    const raw_lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(raw_lines);
    const masked = try types.maskSource(testing.allocator, src, .go);
    defer testing.allocator.free(masked);
    const masked_lines = try types.splitLines(testing.allocator, masked);
    defer testing.allocator.free(masked_lines);

    const violations = try analyzeDesign(testing.allocator, raw_lines, masked_lines, .go, .{});
    defer types.freeViolations(testing.allocator, violations);

    try testing.expect(hasRule(violations, .too_many_arguments));
    try testing.expect(hasRule(violations, .hidden_coupling));
}

test "design: TypeScript class reports temporal coupling, boolean state machine, and ownership" {
    const src =
        \\class Session {
        \\  active: boolean = false;
        \\  ready: boolean = false;
        \\  connected: boolean = false;
        \\  conn: Conn;
        \\
        \\  start(client: Client) {
        \\    if (this.active && this.ready) {
        \\      return;
        \\    }
        \\    boot(client);
        \\  }
        \\
        \\  close() {
        \\    this.conn.close();
        \\  }
        \\
        \\  shutdown() {
        \\    this.conn.close();
        \\  }
        \\}
    ;

    const raw_lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(raw_lines);
    const masked = try types.maskSource(testing.allocator, src, .typescript);
    defer testing.allocator.free(masked);
    const masked_lines = try types.splitLines(testing.allocator, masked);
    defer testing.allocator.free(masked_lines);

    const violations = try analyzeDesign(testing.allocator, raw_lines, masked_lines, .typescript, .{});
    defer types.freeViolations(testing.allocator, violations);

    try testing.expect(hasRule(violations, .temporal_coupling));
    try testing.expect(hasRule(violations, .boolean_state_machine));
    try testing.expect(hasRule(violations, .ambiguous_lifecycle_ownership));
}

test "design: Python explicit state suppresses boolean state machine" {
    const src =
        \\class Worker:
        \\    state: str = "new"
        \\    ready: bool = False
        \\    active: bool = False
        \\    closed: bool = False
        \\
        \\    def start(self):
        \\        if self.ready and self.active:
        \\            return
        \\        return None
        \\
        \\    def close(self):
        \\        return None
    ;

    const raw_lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(raw_lines);
    const masked = try types.maskSource(testing.allocator, src, .python);
    defer testing.allocator.free(masked);
    const masked_lines = try types.splitLines(testing.allocator, masked);
    defer testing.allocator.free(masked_lines);

    const violations = try analyzeDesign(testing.allocator, raw_lines, masked_lines, .python, .{});
    defer types.freeViolations(testing.allocator, violations);

    try testing.expect(!hasRule(violations, .boolean_state_machine));
    try testing.expect(!hasRule(violations, .temporal_coupling));
}

test "design: Zig struct field limit and scoped cleanup behavior are handled" {
    const cfg = guardian_config.Config{
        .limits = .{
            .max_nesting = 3,
            .cyclomatic_complexity_warn = 6,
            .cyclomatic_complexity_error = 8,
            .max_imports = 15,
            .max_functions_per_file = 15,
            .max_function_lines = 50,
            .max_function_arguments = 6,
            .max_type_fields = 3,
            .max_hidden_touch_excess = 0,
            .max_lifecycle_flags = 2,
            .max_line_length = 120,
            .max_excerpt_lines = 12,
            .max_excerpt_chars = 1600,
        },
    };

    const src =
        \\const Session = struct {
        \\    active: bool,
        \\    ready: bool,
        \\    closed: bool,
        \\    conn: Conn,
        \\
        \\    pub fn close(self: *Session) void {
        \\        defer self.conn.close();
        \\    }
        \\};
    ;

    const raw_lines = try types.splitLines(testing.allocator, src);
    defer testing.allocator.free(raw_lines);
    const masked = try types.maskSource(testing.allocator, src, .zig_lang);
    defer testing.allocator.free(masked);
    const masked_lines = try types.splitLines(testing.allocator, masked);
    defer testing.allocator.free(masked_lines);

    const violations = try analyzeDesign(testing.allocator, raw_lines, masked_lines, .zig_lang, cfg);
    defer types.freeViolations(testing.allocator, violations);

    try testing.expect(hasRule(violations, .too_many_fields));
    try testing.expect(!hasRule(violations, .ambiguous_lifecycle_ownership));
}

fn hasRule(violations: []const Violation, rule: Rule) bool {
    for (violations) |violation| {
        if (violation.rule == rule) {
            return true;
        }
    }
    return false;
}
