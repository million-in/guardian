const std = @import("std");
const analyzer = @import("analyzer.zig");
const app = @import("app.zig");
const compat = @import("compat.zig");
const guardian_config = @import("config.zig");
const types = @import("types.zig");

pub const AuditOptions = struct {
    run_proofs: bool = false,
    score_threshold: ?u32 = null,
    extra_proof_reports: []const []const u8 = &.{},
};

pub const CategorySummary = struct {
    category: types.RuleCategory,
    errors: u32 = 0,
    warns: u32 = 0,
    penalty: u32 = 0,
};

pub const HealthScore = struct {
    overall: u32,
    threshold: u32,
    categories: [category_count]CategorySummary,
};

pub const ProofStatus = enum {
    passed,
    failed,
    timed_out,
    skipped,
    not_found,
    malformed,
    not_configured,

    pub fn toString(self: ProofStatus) []const u8 {
        return switch (self) {
            .passed => "passed",
            .failed => "failed",
            .timed_out => "timed_out",
            .skipped => "skipped",
            .not_found => "not_found",
            .malformed => "malformed",
            .not_configured => "not_configured",
        };
    }
};

pub const ProofEvidence = struct {
    name: []const u8,
    kind: []const u8,
    status: ProofStatus,
    summary: []const u8,

    fn deinit(self: ProofEvidence, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.kind);
        allocator.free(self.summary);
    }
};

pub const AuditResult = struct {
    batch: app.BatchResult,
    score: HealthScore,
    proof_status: ProofStatus,
    proofs: []ProofEvidence,
    pass: bool,

    pub fn deinit(self: *AuditResult, allocator: std.mem.Allocator) void {
        self.batch.deinit(allocator);
        for (self.proofs) |proof| proof.deinit(allocator);
        allocator.free(self.proofs);
    }
};

const category_count = std.meta.fieldNames(types.RuleCategory).len;
const category_penalty_cap = 25;

pub fn analyzeFolderAudit(
    allocator: std.mem.Allocator,
    folder_path: []const u8,
    explicit_config_path: ?[]const u8,
    options: AuditOptions,
) !AuditResult {
    var loaded = try guardian_config.loadForTarget(allocator, folder_path, explicit_config_path);
    defer loaded.deinit();

    var batch = try app.analyzeFolderResolved(allocator, folder_path, explicit_config_path);
    errdefer batch.deinit(allocator);

    const proofs = try collectProofEvidence(allocator, loaded.value, options);
    errdefer {
        for (proofs) |proof| proof.deinit(allocator);
        allocator.free(proofs);
    }

    const proof_status = summarizeProofStatus(proofs, loaded.value.proof, options);
    const score = computeScore(batch, proof_status, options.score_threshold orelse loaded.value.audit.score_threshold);
    const pass = batch.error_count == 0 and score.overall >= score.threshold and proof_status != .failed and proof_status != .timed_out;

    return .{
        .batch = batch,
        .score = score,
        .proof_status = proof_status,
        .proofs = proofs,
        .pass = pass,
    };
}

pub fn auditToJson(allocator: std.mem.Allocator, result: AuditResult) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    const writer = &buf.writer;

    try writer.writeAll("{");
    try writer.print("\"pass\":{},", .{result.pass});
    try writer.print("\"score\":{{\"overall\":{d},\"threshold\":{d},\"categories\":[", .{ result.score.overall, result.score.threshold });
    for (result.score.categories, 0..) |category, idx| {
        if (idx > 0) try writer.writeAll(",");
        try writer.print(
            "{{\"category\":\"{s}\",\"errors\":{d},\"warns\":{d},\"penalty\":{d}}}",
            .{ category.category.toString(), category.errors, category.warns, category.penalty },
        );
    }
    try writer.writeAll("]},");
    try writer.print("\"proof_status\":\"{s}\",\"proofs\":[", .{result.proof_status.toString()});
    for (result.proofs, 0..) |proof, idx| {
        if (idx > 0) try writer.writeAll(",");
        try writer.writeAll("{\"name\":\"");
        try types.writeJsonEscaped(writer, proof.name);
        try writer.writeAll("\",\"kind\":\"");
        try types.writeJsonEscaped(writer, proof.kind);
        try writer.print("\",\"status\":\"{s}\",\"summary\":\"", .{proof.status.toString()});
        try types.writeJsonEscaped(writer, proof.summary);
        try writer.writeAll("\"}");
    }
    try writer.writeAll("],\"static\":");
    const batch_json = try app.batchToJson(allocator, result.batch);
    defer allocator.free(batch_json);
    try writer.writeAll(batch_json);
    try writer.writeAll("}");
    return buf.toOwnedSlice();
}

pub fn auditToPretty(allocator: std.mem.Allocator, result: AuditResult) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    const writer = &buf.writer;

    try writer.print(
        "Audit score {d}/100  threshold {d}  {s}\nStatic: {d} files, {d} errors, {d} warns\nProof: {s}\n\n",
        .{
            result.score.overall,
            result.score.threshold,
            if (result.pass) "PASS" else "FAIL",
            result.batch.file_count,
            result.batch.error_count,
            result.batch.warn_count,
            result.proof_status.toString(),
        },
    );

    try writer.writeAll("Categories:\n");
    for (result.score.categories) |category| {
        if (category.errors == 0 and category.warns == 0 and category.penalty == 0) continue;
        try writer.print(
            "  {s}: {d} errors, {d} warns, -{d}\n",
            .{ category.category.toString(), category.errors, category.warns, category.penalty },
        );
    }

    if (result.proofs.len > 0) {
        try writer.writeAll("\nProof evidence:\n");
        for (result.proofs) |proof| {
            try writer.print("  {s} ({s}): {s} — {s}\n", .{ proof.name, proof.kind, proof.status.toString(), proof.summary });
        }
    }

    try writer.writeAll("\n");
    const static_text = try app.batchToPretty(allocator, result.batch);
    defer allocator.free(static_text);
    try writer.writeAll(static_text);
    return buf.toOwnedSlice();
}

fn computeScore(batch: app.BatchResult, proof_status: ProofStatus, threshold: u32) HealthScore {
    var categories = initialCategories();
    for (batch.results) |result| {
        for (result.violations) |violation| {
            const meta = violation.rule.metadata();
            const idx = categoryIndex(meta.category);
            if (violation.severity == .@"error") {
                categories[idx].errors += 1;
                categories[idx].penalty += @as(u32, meta.weight) * 2;
            } else if (violation.severity == .warn) {
                categories[idx].warns += 1;
                categories[idx].penalty += meta.weight;
            }
            if (categories[idx].penalty > category_penalty_cap) categories[idx].penalty = category_penalty_cap;
        }
    }

    const proof_penalty: u32 = switch (proof_status) {
        .passed => 0,
        .not_configured, .skipped => 4,
        .not_found, .malformed => 8,
        .failed, .timed_out => 20,
    };
    categories[categoryIndex(.testability)].penalty = @min(category_penalty_cap, categories[categoryIndex(.testability)].penalty + proof_penalty);

    var total_penalty: u32 = 0;
    for (categories) |category| total_penalty += category.penalty;
    return .{
        .overall = if (total_penalty >= 100) 0 else 100 - total_penalty,
        .threshold = threshold,
        .categories = categories,
    };
}

fn initialCategories() [category_count]CategorySummary {
    var categories: [category_count]CategorySummary = undefined;
    categories[categoryIndex(.correctness)] = .{ .category = .correctness };
    categories[categoryIndex(.safety)] = .{ .category = .safety };
    categories[categoryIndex(.maintainability)] = .{ .category = .maintainability };
    categories[categoryIndex(.resource_lifecycle)] = .{ .category = .resource_lifecycle };
    categories[categoryIndex(.concurrency)] = .{ .category = .concurrency };
    categories[categoryIndex(.security)] = .{ .category = .security };
    categories[categoryIndex(.testability)] = .{ .category = .testability };
    categories[categoryIndex(.formatting)] = .{ .category = .formatting };
    return categories;
}

fn categoryIndex(category: types.RuleCategory) usize {
    return @backingInt(category);
}

fn collectProofEvidence(
    allocator: std.mem.Allocator,
    cfg: guardian_config.Config,
    options: AuditOptions,
) ![]ProofEvidence {
    var proofs = std.array_list.Managed(ProofEvidence).init(allocator);
    errdefer {
        for (proofs.items) |proof| proof.deinit(allocator);
        proofs.deinit();
    }

    for (cfg.proof.reports) |report| {
        try proofs.append(try readProofReport(allocator, cfg.root_path, report.path, report.kind));
    }
    for (options.extra_proof_reports) |path| {
        try proofs.append(try readProofReport(allocator, cfg.root_path, path, "external"));
    }
    if (options.run_proofs) {
        for (cfg.proof.commands) |command| {
            try proofs.append(try runProofCommand(allocator, cfg.root_path, command));
        }
    }

    return proofs.toOwnedSlice();
}

fn readProofReport(allocator: std.mem.Allocator, root_path: []const u8, path: []const u8, kind: []const u8) !ProofEvidence {
    const full_path = try resolveConfigPath(allocator, root_path, path);
    defer allocator.free(full_path);

    const contents = compat.readFileAllocAbsolute(allocator, full_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return makeProof(allocator, path, kind, .not_found, "configured proof report was not found"),
        else => return err,
    };
    defer allocator.free(contents);

    const status: ProofStatus = if (reportLooksFailed(contents)) .failed else .passed;
    const summary = if (status == .passed) "proof report contains no obvious failures" else "proof report contains failures/errors";
    return makeProof(allocator, path, kind, status, summary);
}

fn runProofCommand(allocator: std.mem.Allocator, root_path: []const u8, command: guardian_config.ProofCommand) !ProofEvidence {
    if (command.argv.len == 0) {
        return makeProof(allocator, command.name, "command", .malformed, "proof command argv is empty");
    }

    const run_result = std.process.run(allocator, compat.io, .{
        .argv = command.argv,
        .stdout_limit = .limited(command.max_output_bytes),
        .stderr_limit = .limited(command.max_output_bytes),
        .cwd = if (root_path.len == 0) .inherit else .{ .path = root_path },
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(command.timeout_ms),
            .clock = .awake,
        } },
    }) catch |err| switch (err) {
        error.Timeout => return makeProof(allocator, command.name, "command", .timed_out, "proof command timed out"),
        error.StreamTooLong => return makeProof(allocator, command.name, "command", .failed, "proof command output exceeded max_output_bytes"),
        error.FileNotFound => return makeProof(allocator, command.name, "command", .not_found, "proof command executable was not found"),
        else => return err,
    };
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    const passed = switch (run_result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    const summary = if (passed) "proof command exited successfully" else "proof command exited with failure";
    return makeProof(allocator, command.name, "command", if (passed) .passed else .failed, summary);
}

fn summarizeProofStatus(proofs: []const ProofEvidence, proof_config: guardian_config.ProofConfig, options: AuditOptions) ProofStatus {
    if (proofs.len == 0) {
        return if (proof_config.commands.len == 0 and proof_config.reports.len == 0 and options.extra_proof_reports.len == 0)
            .not_configured
        else
            .skipped;
    }

    var saw_passed = false;
    var saw_missing = false;
    var saw_malformed = false;
    for (proofs) |proof| switch (proof.status) {
        .failed => return .failed,
        .timed_out => return .timed_out,
        .passed => saw_passed = true,
        .not_found => saw_missing = true,
        .malformed => saw_malformed = true,
        .skipped, .not_configured => {},
    };
    if (saw_malformed) return .malformed;
    if (saw_missing) return .not_found;
    return if (saw_passed) .passed else .skipped;
}

fn resolveConfigPath(allocator: std.mem.Allocator, root_path: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path) or root_path.len == 0) return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &.{ root_path, path });
}

fn reportLooksFailed(contents: []const u8) bool {
    return std.mem.indexOf(u8, contents, "failures=\"0\"") == null and std.mem.indexOf(u8, contents, "<failure") != null or
        std.mem.indexOf(u8, contents, "errors=\"0\"") == null and std.mem.indexOf(u8, contents, "<error") != null or
        std.mem.indexOf(u8, contents, "DA:0,0") != null or
        std.mem.indexOf(u8, contents, "\"failed\":true") != null;
}

fn makeProof(
    allocator: std.mem.Allocator,
    name: []const u8,
    kind: []const u8,
    status: ProofStatus,
    summary: []const u8,
) !ProofEvidence {
    return .{
        .name = try allocator.dupe(u8, name),
        .kind = try allocator.dupe(u8, kind),
        .status = status,
        .summary = try allocator.dupe(u8, summary),
    };
}

test "audit scoring caps category penalties" {
    const violations = try std.testing.allocator.alloc(types.Violation, 20);
    defer std.testing.allocator.free(violations);
    for (violations) |*violation| violation.* = .{
        .line = 1,
        .column = 0,
        .end_line = 1,
        .rule = .eval_usage,
        .severity = .warn,
        .message = "eval",
    };
    const result = analyzer.AnalysisResult{
        .violations = violations,
        .file_path = "a.ts",
        .language = .typescript,
        .line_count = 1,
        .error_count = 0,
        .warn_count = 20,
    };
    const batch = app.BatchResult{
        .results = @constCast(&[_]analyzer.AnalysisResult{result}),
        .file_count = 1,
        .error_count = 0,
        .warn_count = 20,
        .pass = true,
    };

    const score = computeScore(batch, .not_configured, 70);
    try std.testing.expectEqual(@as(u32, category_penalty_cap), score.categories[categoryIndex(.security)].penalty);
}
