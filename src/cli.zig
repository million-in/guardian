const std = @import("std");
const analyzer = @import("analyzer.zig");
const app = @import("app.zig");
const guardian_config = @import("config.zig");
const server = @import("server.zig");

const CliOptions = struct {
    json_output: bool = false,
    raw_json_output: bool = false,
    config_path: ?[]const u8 = null,
};

const Command = enum {
    analyze,
    batch,
    folder,
    serve,
    help,
};

pub fn run(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    const stdout_file = std.fs.File.stdout();
    const stdout = stdout_file.deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();
    const command = parseCommand(args[0]) orelse {
        try writeUsage(stderr);
        return error.InvalidArguments;
    };

    switch (command) {
        .serve => return server.run(allocator),
        .help => return writeUsage(stdout),
        .analyze, .batch, .folder => {},
    }

    const parsed = try parseCliOptions(allocator, args[1..]);
    defer parsed.positionals.deinit();

    const output_mode = resolveOutputMode(stdout_file, parsed.options);

    switch (command) {
        .analyze => try runAnalyzeCommand(allocator, stdout, stderr, parsed, output_mode),
        .batch => try runBatchCommand(allocator, stdout, stderr, parsed, output_mode),
        .folder => try runFolderCommand(allocator, stdout, stderr, parsed, output_mode),
        .serve, .help => unreachable,
    }
}

fn writeUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage:
        \\  gd analyze <file> [--json] [--raw-json] [--config path]
        \\  gd batch <file> <file> [...] [--json] [--raw-json] [--config path]
        \\  gd folder <dir> [--json] [--raw-json] [--config path]
        \\  gd serve
        \\
        \\Config:
        \\  Auto-loads `guardian.config.json` from the target path upward.
        \\  Use `--config path` to force a specific config file.
        \\  `--json` keeps human output on a terminal, but emits JSON when piped.
        \\  `--raw-json` always emits JSON.
        \\
    );
}

pub fn writeCliError(err: anyerror) !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();

    switch (err) {
        error.InvalidArguments => {},
        error.UnsupportedFileExtension => try stderr.writeAll(
            "error: unsupported file extension for analyze/batch input\n",
        ),
        error.FileNotFound => try stderr.writeAll("error: file or config path not found\n"),
        error.NotDirectory => try stderr.writeAll("error: folder command expects a directory path\n"),
        error.NoSupportedSourceFiles => try stderr.writeAll("error: folder does not contain supported source files\n"),
        else => try stderr.print("error: {}\n", .{err}),
    }
}

fn runAnalyzeCommand(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    parsed: ParsedCli,
    output_mode: OutputMode,
) !void {
    if (parsed.positionals.items.len != 1) {
        try writeUsage(stderr);
        return error.InvalidArguments;
    }

    const file_path = parsed.positionals.items[0];
    var loaded_cfg = try guardian_config.loadForTarget(allocator, file_path, parsed.options.config_path);
    defer loaded_cfg.deinit();

    const result = try app.analyzeFilePath(allocator, file_path, loaded_cfg.value);
    defer analyzer.freeResult(allocator, result);

    const output = if (output_mode == .json)
        try analyzer.resultToJson(allocator, result)
    else
        try app.resultToPretty(allocator, result);
    defer allocator.free(output);

    try writeOutput(stdout, output, output_mode);
}

fn runBatchCommand(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    parsed: ParsedCli,
    output_mode: OutputMode,
) !void {
    if (parsed.positionals.items.len == 0) {
        try writeUsage(stderr);
        return error.InvalidArguments;
    }

    var batch = try app.analyzeFilePathsResolved(allocator, parsed.positionals.items, parsed.options.config_path);
    defer batch.deinit(allocator);

    const output = if (output_mode == .json)
        try app.batchToJson(allocator, batch)
    else
        try app.batchToPretty(allocator, batch);
    defer allocator.free(output);

    try writeOutput(stdout, output, output_mode);
}

fn runFolderCommand(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    parsed: ParsedCli,
    output_mode: OutputMode,
) !void {
    if (parsed.positionals.items.len != 1) {
        try writeUsage(stderr);
        return error.InvalidArguments;
    }

    const folder_path = parsed.positionals.items[0];
    var batch = try app.analyzeFolderResolved(allocator, folder_path, parsed.options.config_path);
    defer batch.deinit(allocator);

    const output = if (output_mode == .json)
        try app.batchToJson(allocator, batch)
    else
        try app.batchToPretty(allocator, batch);
    defer allocator.free(output);

    try writeOutput(stdout, output, output_mode);
}

const OutputMode = enum {
    pretty,
    json,
};

fn writeOutput(writer: anytype, output: []const u8, mode: OutputMode) !void {
    try writer.writeAll(output);
    if (mode == .pretty) {
        try writer.writeByte('\n');
    }
}

fn resolveOutputMode(stdout_file: std.fs.File, options: CliOptions) OutputMode {
    if (options.raw_json_output) {
        return .json;
    }
    if (options.json_output and !stdout_file.isTty()) {
        return .json;
    }
    return .pretty;
}

const ParsedCli = struct {
    options: CliOptions,
    positionals: std.array_list.Managed([]const u8),
};

fn parseCliOptions(allocator: std.mem.Allocator, args: []const [:0]u8) !ParsedCli {
    var options = CliOptions{};
    var positionals = std.array_list.Managed([]const u8).init(allocator);
    errdefer positionals.deinit();

    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--json")) {
            options.json_output = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--raw-json")) {
            options.raw_json_output = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--config")) {
            idx += 1;
            if (idx >= args.len) {
                return error.InvalidArguments;
            }
            options.config_path = args[idx];
            continue;
        }
        try positionals.append(arg);
    }

    return .{
        .options = options,
        .positionals = positionals,
    };
}

fn parseCommand(arg: []const u8) ?Command {
    if (std.mem.eql(u8, arg, "analyze")) return .analyze;
    if (std.mem.eql(u8, arg, "batch")) return .batch;
    if (std.mem.eql(u8, arg, "folder")) return .folder;
    if (std.mem.eql(u8, arg, "serve")) return .serve;
    if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help")) return .help;
    return null;
}
