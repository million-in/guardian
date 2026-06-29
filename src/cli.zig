const std = @import("std");
const analyzer = @import("analyzer.zig");
const app = @import("app.zig");
const compat = @import("compat.zig");
const guardian_config = @import("config.zig");

const CliOptions = struct {
    json_output: bool = false,
    raw_json_output: bool = false,
    config_path: ?[]const u8 = null,
};

const Command = enum {
    analyze,
    batch,
    folder,
    help,
};

pub fn run(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    const stdout_file = std.Io.File.stdout();
    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stderr_buffer: [16 * 1024]u8 = undefined;
    var stdout = stdout_file.writerStreaming(compat.io, &stdout_buffer);
    var stderr = std.Io.File.stderr().writerStreaming(compat.io, &stderr_buffer);
    defer stdout.interface.flush() catch {};
    defer stderr.interface.flush() catch {};
    if (args.len == 0) {
        try writeUsage(&stderr.interface);
        return error.InvalidArguments;
    }
    const command = parseCommand(args[0]) orelse {
        try writeUsage(&stderr.interface);
        return error.InvalidArguments;
    };

    switch (command) {
        .help => return writeUsage(&stdout.interface),
        .analyze, .batch, .folder => {},
    }

    const parsed = try parseCliOptions(allocator, args[1..]);
    defer parsed.positionals.deinit();

    const output_mode = resolveOutputMode(stdout_file, parsed.options);

    switch (command) {
        .analyze => try runAnalyzeCommand(allocator, &stdout.interface, &stderr.interface, parsed, output_mode),
        .batch => try runBatchCommand(allocator, &stdout.interface, &stderr.interface, parsed, output_mode),
        .folder => try runFolderCommand(allocator, &stdout.interface, &stderr.interface, parsed, output_mode),
        .help => unreachable,
    }
}

fn writeUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage:
        \\  gd analyze <file> [--json] [--raw-json] [--config path]
        \\  gd batch <file> <file> [...] [--json] [--raw-json] [--config path]
        \\  gd folder <dir> [--json] [--raw-json] [--config path]
        \\
        \\Config:
        \\  Auto-loads `guardian.config.yaml` from the target path upward.
        \\  Use `--config path` to force a specific config file.
        \\  `--json` keeps human output on a terminal, but emits JSON when piped.
        \\  `--raw-json` always emits JSON.
        \\
    );
}

pub fn writeCliError(err: anyerror) !void {
    var stderr_buffer: [16 * 1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(compat.io, &stderr_buffer);
    defer stderr.interface.flush() catch {};
    const writer = &stderr.interface;

    switch (err) {
        error.InvalidArguments => {},
        error.UnsupportedFileExtension => try writer.writeAll(
            "error: unsupported file extension for analyze/batch input\n",
        ),
        error.FileNotFound => try writer.writeAll("error: file or config path not found\n"),
        error.InvalidInput => try writer.writeAll("error: invalid input path\n"),
        error.NotDirectory => try writer.writeAll("error: folder command expects a directory path\n"),
        error.NoSupportedSourceFiles => try writer.writeAll("error: folder does not contain supported source files\n"),
        else => try writer.print("error: {}\n", .{err}),
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

fn resolveOutputMode(stdout_file: std.Io.File, options: CliOptions) OutputMode {
    if (options.raw_json_output) {
        return .json;
    }
    if (options.json_output and !(stdout_file.isTty(compat.io) catch false)) {
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
    if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help")) return .help;
    return null;
}
