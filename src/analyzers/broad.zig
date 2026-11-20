const std = @import("std");
const guardian_config = @import("../config.zig");
const test_config = @import("../test_config.zig");
const types = @import("../types.zig");

const Language = types.Language;
const Rule = types.Rule;
const Violation = types.Violation;
const ViolationList = std.array_list.Managed(Violation);

pub fn analyzeBroadRules(
    allocator: std.mem.Allocator,
    raw_lines: []const []const u8,
    masked_lines: []const []const u8,
    lang: Language,
    cfg: guardian_config.Config,
) ![]Violation {
    var violations = ViolationList.init(allocator);
    switch (lang) {
        .go => try analyzeGo(raw_lines, masked_lines, cfg, &violations),
        .typescript => try analyzeTypeScript(masked_lines, cfg, &violations),
        .python => try analyzePython(masked_lines, cfg, &violations),
        .rust => try analyzeRust(masked_lines, cfg, &violations),
        .zig_lang => try analyzeZig(masked_lines, cfg, &violations),
    }
    return violations.toOwnedSlice();
}

fn analyzeGo(
    raw_lines: []const []const u8,
    masked_lines: []const []const u8,
    cfg: guardian_config.Config,
    violations: *ViolationList,
) !void {
    var loop_depth: u32 = 0;
    for (masked_lines, 0..) |line, line_idx| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (cfg.audit.warn_async_in_loops and startsControl(trimmed, "for ")) loop_depth += 1;

        if (cfg.audit.warn_ignored_errors and startsWithAny(trimmed, &.{ "_ = ", "_, _ = " })) {
            try append(violations, line_idx, .ignored_error, "ignored return value may hide an error");
        }
        if (cfg.audit.warn_panic_paths and containsAny(trimmed, &.{ "panic(", "log.Fatal(", "log.Fatalf(" })) {
            try append(violations, line_idx, .panic_usage, "panic or fatal exit path should be justified and tested");
        }
        if (cfg.audit.warn_risky_conversions and std.mem.indexOf(u8, trimmed, "context.TODO()") != null) {
            try append(violations, line_idx, .risky_conversion, "context.TODO should not escape scaffolding code");
        }
        if (cfg.audit.warn_async_in_loops and loop_depth > 0 and std.mem.startsWith(u8, trimmed, "go ")) {
            try append(violations, line_idx, .async_in_loop, "goroutine launched inside a loop can become unbounded");
        }
        if (cfg.audit.warn_unpaired_locks and containsAny(trimmed, &.{ ".Lock()", ".RLock()" }) and !nearbyContains(raw_lines, line_idx, 5, "defer ")) {
            try append(violations, line_idx, .unpaired_lock, "lock acquisition has no nearby defer unlock guard");
        }
        if (cfg.audit.warn_sql_string_building and looksLikeSqlBuild(trimmed)) {
            try append(violations, line_idx, .sql_string_building, "SQL text appears to be assembled dynamically");
        }
        if (loop_depth > 0 and std.mem.indexOfScalar(u8, trimmed, '}') != null) loop_depth -= 1;
    }
}

fn analyzeTypeScript(
    masked_lines: []const []const u8,
    cfg: guardian_config.Config,
    violations: *ViolationList,
) !void {
    for (masked_lines, 0..) |line, line_idx| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (cfg.audit.warn_eval and containsAny(trimmed, &.{ "eval(", "new Function(" })) {
            try append(violations, line_idx, .eval_usage, "dynamic code execution is a security footgun");
        }
        if (cfg.audit.warn_non_null_assertions and hasNonNullAssertion(trimmed)) {
            try append(violations, line_idx, .non_null_assertion, "non-null assertion bypasses type safety");
        }
        if (cfg.audit.warn_broad_exceptions and containsAny(trimmed, &.{ "catch (", "catch{" })) {
            if (nearbyContains(masked_lines, line_idx, 3, "{}") or nearbyContains(masked_lines, line_idx, 3, "//")) {
                try append(violations, line_idx, .broad_exception, "catch block appears empty or non-actionable");
            }
        }
        if (cfg.audit.warn_risky_conversions and std.mem.indexOf(u8, trimmed, "JSON.parse(") != null and !nearbyBefore(masked_lines, line_idx, 3, "try")) {
            try append(violations, line_idx, .risky_conversion, "JSON.parse without nearby try/catch can throw at runtime");
        }
        if (cfg.audit.warn_floating_promises and looksLikeFloatingPromise(trimmed)) {
            try append(violations, line_idx, .floating_promise, "promise-like call is not awaited or returned");
        }
    }
}

fn analyzePython(
    masked_lines: []const []const u8,
    cfg: guardian_config.Config,
    violations: *ViolationList,
) !void {
    for (masked_lines, 0..) |line, line_idx| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (cfg.audit.warn_eval and startsWithAny(trimmed, &.{ "eval(", "exec(" })) {
            try append(violations, line_idx, .eval_usage, "dynamic code execution is a security footgun");
        }
        if (cfg.audit.warn_shell_execution and std.mem.indexOf(u8, trimmed, "shell=True") != null) {
            try append(violations, line_idx, .shell_execution, "shell=True can turn input into command execution");
        }
        if (cfg.audit.warn_broad_exceptions and (std.mem.eql(u8, trimmed, "except:") or std.mem.startsWith(u8, trimmed, "except Exception"))) {
            try append(violations, line_idx, .broad_exception, "broad exception handling can hide functional failures");
        }
        if (cfg.audit.warn_mutable_defaults and std.mem.startsWith(u8, trimmed, "def ") and containsAny(trimmed, &.{ "=[]", "= {}", "={}", "= []" })) {
            try append(violations, line_idx, .mutable_default_argument, "mutable default argument keeps state across calls");
        }
        if (cfg.audit.warn_unpaired_resources and std.mem.indexOf(u8, trimmed, "open(") != null and !std.mem.startsWith(u8, trimmed, "with ")) {
            try append(violations, line_idx, .unpaired_resource, "open() without with may leak file handles");
        }
        if (cfg.audit.warn_panic_paths and std.mem.startsWith(u8, trimmed, "assert ")) {
            try append(violations, line_idx, .panic_usage, "assert can disappear under optimized Python execution");
        }
    }
}

fn analyzeRust(
    masked_lines: []const []const u8,
    cfg: guardian_config.Config,
    violations: *ViolationList,
) !void {
    for (masked_lines, 0..) |line, line_idx| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (cfg.audit.warn_ignored_errors and std.mem.startsWith(u8, trimmed, "let _ =")) {
            try append(violations, line_idx, .ignored_error, "ignored Result-like value should be handled or documented");
        }
        // panic!/unreachable!/dbg! and clone are hard bans in the Rust
        // type-safety pass (ban_dangerous_macros / ban_clone), not audit warns.
        if (cfg.audit.warn_debug_output and containsAny(trimmed, &.{ "println!(", "eprintln!(" })) {
            try append(violations, line_idx, .debug_output, "debug output should not remain in production paths");
        }
        if (cfg.audit.warn_unpaired_resources and std.mem.indexOf(u8, trimmed, "std::mem::forget") != null) {
            try append(violations, line_idx, .unpaired_resource, "mem::forget bypasses normal drop cleanup");
        }
    }
}

fn analyzeZig(
    masked_lines: []const []const u8,
    cfg: guardian_config.Config,
    violations: *ViolationList,
) !void {
    for (masked_lines, 0..) |line, line_idx| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (cfg.audit.warn_panic_paths and containsAny(trimmed, &.{ "@panic(", "catch unreachable", "unreachable;" })) {
            try append(violations, line_idx, .panic_usage, "panic/unreachable path should be rare and justified");
        }
        if (cfg.audit.warn_debug_output and std.mem.indexOf(u8, trimmed, "std.debug.print") != null) {
            try append(violations, line_idx, .debug_output, "debug output should not remain in production paths");
        }
        if (cfg.audit.warn_unpaired_resources and hasZigAllocation(trimmed) and !nearbyContains(masked_lines, line_idx, 6, "defer ")) {
            try append(violations, line_idx, .unpaired_resource, "allocator acquisition has no nearby defer cleanup");
        }
        if (cfg.audit.warn_unpaired_locks and std.mem.indexOf(u8, trimmed, ".lock()") != null and !nearbyContains(masked_lines, line_idx, 5, "defer ")) {
            try append(violations, line_idx, .unpaired_lock, "lock acquisition has no nearby defer unlock guard");
        }
    }
}

fn append(violations: *ViolationList, line_idx: usize, rule: Rule, message: []const u8) !void {
    const line = try types.indexToLineNumber(line_idx);
    try violations.append(.{
        .line = line,
        .column = 0,
        .end_line = line,
        .rule = rule,
        .severity = .warn,
        .message = message,
    });
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

fn startsWithAny(value: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, value, prefix)) return true;
    }
    return false;
}

fn startsControl(value: []const u8, keyword: []const u8) bool {
    return std.mem.startsWith(u8, value, keyword) or std.mem.eql(u8, value, std.mem.trimEnd(u8, keyword, " "));
}

fn nearbyContains(lines: []const []const u8, center: usize, radius: usize, needle: []const u8) bool {
    const end = @min(lines.len, center + radius + 1);
    var idx = center;
    while (idx < end) : (idx += 1) {
        if (std.mem.indexOf(u8, lines[idx], needle) != null) return true;
    }
    return false;
}

fn nearbyBefore(lines: []const []const u8, center: usize, radius: usize, needle: []const u8) bool {
    const start = center - @min(center, radius);
    var idx = start;
    while (idx <= center) : (idx += 1) {
        if (std.mem.indexOf(u8, lines[idx], needle) != null) return true;
    }
    return false;
}

fn hasNonNullAssertion(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "!.") != null or std.mem.indexOf(u8, line, "!;") != null;
}

fn looksLikeFloatingPromise(line: []const u8) bool {
    if (startsWithAny(line, &.{ "await ", "return ", "throw ", "const ", "let ", "var " })) return false;
    return containsAny(line, &.{ "fetch(", "axios.", ".then(", ".catch(" });
}

fn looksLikeSqlBuild(line: []const u8) bool {
    return containsAny(line, &.{ "SELECT ", "INSERT ", "UPDATE ", "DELETE " }) and containsAny(line, &.{ "+", "fmt.Sprintf" });
}

fn hasZigAllocation(line: []const u8) bool {
    return containsAny(line, &.{ ".alloc(", ".create(", ".dupe(", ".dupeZ(" });
}

test "broad analyzer: flags practical runtime footguns" {
    var loaded = try test_config.loadDefault(std.testing.allocator);
    defer loaded.deinit();

    const lines = [_][]const u8{
        "func Run(mu *sync.Mutex) {",
        "    mu.Lock()",
        "    panic(\"boom\")",
        "}",
    };
    const violations = try analyzeBroadRules(std.testing.allocator, &lines, &lines, .go, loaded.value);
    defer types.freeViolations(std.testing.allocator, violations);

    try std.testing.expect(violations.len >= 2);
}
