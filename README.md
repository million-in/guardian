# Guardian

A static analysis engine for enforcing engineering discipline across polyglot codebases. Written in Zig, Guardian ships as both a standalone CLI (`gd`) and an MCP (Model Context Protocol) server (`guardian-mcp`) that AI coding assistants can call to validate code before presenting it to the user.

Guardian analyzes **Go**, **TypeScript**, **Python**, and **Zig** source files against a configurable set of rules covering nesting depth, cyclomatic complexity, type safety, cohesion, and formatting.

## Requirements

- Zig `>= 0.15.2`

## Build

```sh
zig build
```

## Development Shell

Use the Nix flake when you want the same toolchain locally and in CI:

```sh
nix develop -c zig build ci
```

This produces two binaries in `zig-out/bin/`:

| Binary | Purpose |
|---|---|
| `gd` | CLI for single-file, batch, and folder analysis |
| `guardian-mcp` | MCP server communicating over stdin/stdout via JSON-RPC with Content-Length framing |

## CLI Usage

```
gd analyze <file> [--json] [--raw-json] [--config path]
gd batch <file> <file> [...] [--json] [--raw-json] [--config path]
gd folder <dir> [--json] [--raw-json] [--config path]
gd serve                          # start MCP server mode
```

**Analyze a single file:**

```sh
./zig-out/bin/gd analyze samples/go_bad.go
```

**Batch analyze multiple files:**

```sh
./zig-out/bin/gd batch samples/go_bad.go samples/py_clean.py --json | jq .
```

**Recursively analyze a folder:**

```sh
./zig-out/bin/gd folder samples --json | jq .
```

On a terminal, `gd` shows human-readable ANSI-colored output by default, including when `--json` is present. When `--json` is piped, `gd` emits machine-readable JSON. Use `--raw-json` to force JSON directly in the terminal.

## MCP Server

When invoked with no arguments (or `gd serve`), Guardian runs as an MCP server over stdin/stdout using the [JSON-RPC 2.0](https://www.jsonrpc.org/specification) protocol with `Content-Length` header framing.

### Exposed Tools

| Tool | Description | Required Params |
|---|---|---|
| `analyze` | Analyze a single source file | `file_path`, `source` |
| `analyze_batch` | Analyze multiple files in one request | `files` (array of `{file_path, source}`) |
| `analyze_folder` | Recursively analyze a directory on disk | `path` |

All tools accept an optional `config_path` parameter to override config discovery.

### Integration with Claude Code

Add Guardian as an MCP server in your Claude Code settings:

```json
{
  "mcpServers": {
    "code-guardian": {
      "command": "/absolute/path/to/zig-out/bin/guardian-mcp"
    }
  }
}
```

The companion skill definition in `skill/SKILL.md` instructs the agent to call the `analyze` tool on every code change and reject results containing `error`-severity violations.

### Raw MCP Example

```sh
SRC=$(jq -Rs . < samples/go_bad.go)
BODY=$(printf '{"jsonrpc":"2.0","id":1,"method":"analyze","params":{"file_path":"samples/go_bad.go","source":%s}}' "$SRC")
LEN=$(printf '%s' "$BODY" | wc -c | tr -d ' ')
printf 'Content-Length: %s\r\n\r\n%s' "$LEN" "$BODY" | ./zig-out/bin/guardian-mcp
```

A convenience script wraps this: `./scripts/guardian-check.sh analyze samples/go_bad.go | jq .`

## Analysis Rules

### Nesting Depth

Tracks brace depth (Go, TypeScript, Zig) or indent level (Python) within each function. Reports `error` when any function exceeds `max_nesting` (default: 3).

### Cyclomatic Complexity

Counts branching constructs per function: `if`, `else if`/`elif`, `case`, `for`, `while`, `&&`/`and`, `||`/`or`, `catch`/`except`, `orelse`, ternary `?`, and `switch` (Zig). Two thresholds:

- `cyclomatic_complexity_warn` (default: 6) -- `warn` severity
- `cyclomatic_complexity_error` (default: 8) -- `error` severity

### Type Safety

Language-specific banned patterns:

| Language | Banned (error) | Warned |
|---|---|---|
| Go | `interface{}`, unchecked type assertions, generics (configurable) | type switches, `map[string]interface{}` |
| TypeScript | `any`, `as any`, `@ts-ignore` | `@ts-expect-error` |
| Python | `Any` annotation, `# type: ignore` | bare `dict`/`list`, missing return annotation, `from typing import Any` |
| Zig | -- | `anytype` in public signatures, `@ptrCast`, `@intCast` |

Scope controls (`public_only` or `all`) determine whether rules apply to internal or exported symbols only. Source masking ensures patterns inside strings and comments are ignored.

### Cohesion and Coupling

- **Import count**: `error` when file exceeds `max_imports` (default: 15)
- **Function count**: `error` when file exceeds `max_functions_per_file` (default: 15)
- **Function length**: `warn` when any function exceeds `max_function_lines` (default: 50)

### Formatting

- **Line length**: `warn` when a line exceeds `max_line_length` (default: 120)
- **Mixed indentation**: `error` for tabs+spaces on the same line
- **Inconsistent indent style**: `error` when a file mixes tab-indented and space-indented lines beyond a threshold (Go expects tabs; others expect spaces)
- **Trailing whitespace**: `warn` with count and first occurrence

## Configuration

Guardian auto-discovers `.guardian.json` or `guardian.json` by walking up from the target file's directory. Use `--config path` to specify an explicit config file.

See `guardian.config.example.json` for a complete reference. Key sections:

```json
{
  "limits": {
    "max_nesting": 3,
    "cyclomatic_complexity_warn": 6,
    "cyclomatic_complexity_error": 8,
    "max_imports": 15,
    "max_functions_per_file": 16,
    "max_function_lines": 80,
    "max_line_length": 120,
    "max_excerpt_lines": 12,
    "max_excerpt_chars": 1600
  },
  "scan": {
    "extensions": [".go", ".ts", ".tsx", ".py", ".zig"],
    "ignored_dirs": [".git", "node_modules", "vendor", "dist", "build"]
  },
  "go": { "ban_generics": true, "surface_scope": "public_only" },
  "typescript": { "extra_banned_patterns": [...] },
  "python": { "warn_missing_return_annotation": true },
  "zig": { "warn_anytype": true, "anytype_scope": "public_only" }
}
```

### Overrides

Per-path overrides let you relax or tighten rules for specific directories, file roles, or extensions:

```json
{
  "overrides": [
    {
      "path_prefixes": ["src/analyzers/"],
      "limits": { "max_function_lines": 120, "max_line_length": 160 }
    },
    {
      "roles": ["test", "fixture", "sample"],
      "limits": { "max_function_lines": 90 },
      "go": { "ban_generics": false }
    }
  ]
}
```

**Override matchers** (all conditions must match when present):

| Field | Match logic |
|---|---|
| `path_prefixes` | Relative path starts with any prefix |
| `path_suffixes` | Path ends with any suffix |
| `path_contains` | Path contains any substring |
| `extensions` | File extension matches any entry |
| `roles` | Detected role: `test`, `fixture`, `sample`, `generated` |

Overrides are applied in order; later overrides take precedence for the same field.

### Monorepo Support

In batch and folder modes, Guardian resolves config independently per file by walking up from each file's directory. This means different subdirectories can have their own `.guardian.json` with distinct rules. Config resolution results are cached per discovered config path to avoid redundant I/O.

## Output Formats

**Pretty (default)**: ANSI-colored terminal output with file header, violation details, and source excerpts with line numbers.

**JSON (`--json` when piped, or `--raw-json`)**: Machine-readable output per file:

```json
{
  "file_path": "samples/go_bad.go",
  "language": "go",
  "line_count": 42,
  "error_count": 2,
  "warn_count": 1,
  "pass": false,
  "violations": [
    {
      "line": 5,
      "column": 20,
      "end_line": 5,
      "rule": "banned_type",
      "severity": "error",
      "message": "use concrete type or typed interface instead of interface{}",
      "excerpt": "func Process(data interface{}) {"
    }
  ]
}
```

Batch JSON wraps results with aggregate counts:

```json
{
  "file_count": 3,
  "error_count": 4,
  "warn_count": 2,
  "pass": false,
  "results": [...]
}
```

## Tests

```sh
zig build test
```

Additional project checks:

```sh
zig build fmt
zig build e2e
zig build ci
```

The `ci` step runs format checks, Zig unit tests, and end-to-end CLI/MCP checks. GitHub Actions runs the same suite on macOS and Linux through `nix develop`.

Tests cover the MCP protocol (framing, initialize handshake, tool dispatch), each analyzer module (nesting, complexity, type checking, cohesion, formatting), config loading and override resolution, source masking for strings/comments, and monorepo config caching.

## Project Structure

```
src/
  main.zig              # Entry point: CLI argument parsing, MCP server loop, JSON-RPC dispatch
  app.zig               # Orchestration: file I/O, batch/folder analysis, output rendering
  analyzer.zig          # Aggregates all analyzer passes, attaches excerpts, produces JSON
  config.zig            # Config types, JSON loading, path-based override resolution, discovery
  types.zig             # Shared types (Language, Severity, Rule, Violation), source masking
  analyzers/
    nesting.zig         # Nesting depth analysis (brace and indent-based)
    complexity.zig      # Cyclomatic complexity analysis
    type_check.zig      # Language-specific type safety checks
    cohesion.zig        # Import count, function count, function length
    formatting.zig      # Line length, indentation consistency, trailing whitespace
samples/                # Test fixtures: clean and bad examples for each language
scripts/
  guardian-check.sh     # Shell wrapper for MCP server requests
skill/
  SKILL.md              # Claude Code skill definition for AI agent integration
```
