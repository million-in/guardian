# Guardian

A fast static analysis engine for enforcing engineering discipline across polyglot codebases. Guardian is written in Zig and is intentionally exposed only through:

- `gd` — the standalone CLI for single-file, batch, and folder scans
- `libguardian` + `include/guardian.h` — the C ABI for host applications

Guardian analyzes **Go**, **TypeScript**, **Python**, **Rust**, and **Zig** source files with configurable checks for nesting depth, cyclomatic complexity, type-safety footguns, cohesion, formatting, and cross-language design smells.

## Requirements

- Zig `>= 0.16.0`
- `jq` for shell end-to-end tests

## Build

```sh
zig build
```

Artifacts:

| Artifact | Purpose |
|---|---|
| `zig-out/bin/gd` | CLI for single-file, batch, and folder analysis |
| `zig-out/lib/libguardian.*` | C ABI library for C, C++, Go/cgo, and other FFI callers |
| `zig-out/include/guardian.h` | Header for the C ABI |

Development shell:

```sh
nix develop -c zig build ci
```

## CLI Usage

```text
gd analyze <file> [--json] [--raw-json] [--config path]
gd batch <file> <file> [...] [--json] [--raw-json] [--config path]
gd folder <dir> [--json] [--raw-json] [--config path]
```

Examples:

```sh
./zig-out/bin/gd analyze samples/rs_bad.rs
./zig-out/bin/gd batch samples/go_bad.go samples/rs_clean.rs --json | jq .
./zig-out/bin/gd folder samples --raw-json | jq .
```

On a terminal, `--json` keeps human-readable colored output; when piped, it emits machine-readable JSON. Use `--raw-json` to force JSON in a terminal.

## Library API

The Zig root module exposes JSON-returning helpers:

- `analyzeSourceJson`
- `analyzeFileJson`
- `analyzeBatchJson`
- `analyzeFolderJson`

The installed C ABI returns owned JSON strings:

```c
char *guardian_analyze_file_json(const char *file_path, const char *config_path, int severity_filter);
char *guardian_analyze_folder_json(const char *folder_path, const char *config_path, int severity_filter);
char *guardian_analyze_source_json(const char *file_path, const char *source, const char *config_path, int severity_filter);
void guardian_free_string(char *value);
```

Use `GUARDIAN_SEVERITY_ALL`, `GUARDIAN_SEVERITY_ERRORS_ONLY`, `GUARDIAN_SEVERITY_WARNINGS_ONLY`, or `GUARDIAN_SEVERITY_CLEAR_ERRORS` from `guardian.h`.

## Analysis Rules

### Nesting Depth

Tracks brace depth for Go, TypeScript, Rust, and Zig, and indentation depth for Python. Reports `error` when a function exceeds `max_nesting`.

### Cyclomatic Complexity

Counts branch constructs per function. Common constructs include `if`, `else if`/`elif`, loops, boolean operators, `case`/`match`, `catch`/`except`, Zig `orelse`, Rust `?`, and TypeScript ternaries.

### Type Safety

Language-specific defaults:

| Language | Banned or warned patterns |
|---|---|
| Go | `interface{}`, `map[string]interface{}`, unchecked type assertions, configurable generics |
| TypeScript | `any`, `as any`, `@ts-ignore`, `@ts-expect-error` warnings |
| Python | `Any`, `# type: ignore`, bare `dict`/`list`, missing public return annotation |
| Rust | `unsafe`, `.unwrap()`, `.expect()`, `todo!()`, `unimplemented!()` warnings |
| Zig | `anytype` in public signatures, `@ptrCast`, `@intCast` warnings |

Extra banned patterns can be configured per language and are checked after comment/string masking.

### Cohesion and Coupling

- Import count (`max_imports`)
- Function count per file (`max_functions_per_file`)
- Function length (`max_function_lines`)

### Design Rules

Guardian builds a lightweight symbol model to report:

- Too many function arguments
- Too many fields on structs/classes/interfaces/object-shape types/enums
- Hidden coupling through undeclared external touches
- Temporal coupling through boolean lifecycle guards
- Boolean state machines that should be one explicit state
- Ambiguous lifecycle ownership when multiple functions clean the same resource

### Formatting

- Line length
- Mixed tabs/spaces on one line
- Inconsistent file indent style
- Trailing whitespace

## Configuration

Guardian discovers `guardian.config.yaml` by walking up from the target path. If no target config exists, it falls back to a packaged config next to the executable. Legacy `guardian.config.json` remains readable.

Key defaults:

```yaml
limits:
  max_nesting: 3
  cyclomatic_complexity_warn: 6
  cyclomatic_complexity_error: 8
  max_imports: 15
  max_functions_per_file: 16
  max_function_lines: 80
  max_function_arguments: 3
  max_type_fields: 12
scan:
  extensions: [".go", ".ts", ".tsx", ".py", ".rs", ".zig"]
  ignored_dirs: [".git", ".zig-cache", "zig-out", "node_modules", "vendor", "dist", "build", "__pycache__"]
rust:
  warn_unsafe: true
  warn_unwrap: true
  warn_expect: true
  warn_todo: true
```

Per-path overrides can match `path_prefixes`, `path_suffixes`, `path_contains`, `extensions`, and detected `roles` (`test`, `fixture`, `sample`, `generated`). Later overrides win.

## Output Formats

Single-file JSON:

```json
{
  "file_path": "samples/rs_bad.rs",
  "language": "rust",
  "line_count": 44,
  "error_count": 2,
  "warn_count": 5,
  "pass": false,
  "violations": [
    {
      "line": 17,
      "column": 0,
      "end_line": 29,
      "rule": "too_many_arguments",
      "severity": "error",
      "message": "function 'start' has 4 arguments (max 3)",
      "excerpt": "pub fn start(&mut self, client: Client, cache: Cache, metrics: Metrics, audit: Audit) {"
    }
  ]
}
```

Batch/folder JSON wraps results with aggregate counts.

## Tests and Checks

```sh
zig build fmt
zig build test
zig build e2e
zig build ci
```

`ci` runs formatting, Zig unit tests, CLI end-to-end checks, and release packaging checks.

## Release Archive

Create a local release package:

```sh
bash ./scripts/package-release.sh
```

Release archives contain `bin/gd`, `lib/libguardian.*`, `include/guardian.h`, `guardian.config.yaml`, `README.md`, `SPEC.md`, `DELTA.md`, and `LICENSE`.

Guardian does not ship MCP servers, plugins, or skills. Use it through `gd` or the ABI.

## Project Structure

```text
src/
  main.zig              # Entry point; routes all args to CLI
  cli.zig               # CLI parsing and output mode selection
  app.zig               # File I/O, batch/folder orchestration, output rendering
  analyzer.zig          # Runs analyzer passes and serializes JSON
  config*.zig           # Config schema, loading, discovery, overrides, resolver cache
  source_files.zig      # Folder traversal and source collection
  symbol_model.zig      # Lightweight language-aware model for design rules
  types.zig             # Shared types, source masking, JSON escaping
  c_api.zig             # C ABI exports
  analyzers/            # Nesting, complexity, type, cohesion, design, formatting checks
samples/                # Fixture files for supported languages
scripts/                # CLI and release end-to-end checks, package builder
```
