# Samples

These files are test fixtures for the Guardian CLI and ABI engine.

- `go_clean.go`: should pass or produce no `error` violations.
- `go_bad.go`: should fail on banned Go surface types, unchecked assertion, and deep nesting.
- `go_design_bad.go`: should fail on design rules such as too many arguments, too many fields, and hidden coupling.
- `ts_clean.ts`: should pass or produce no `error` violations.
- `ts_bad.ts`: should fail on `any`, `as any`, `@ts-ignore`, and deep nesting.
- `py_clean.py`: should pass or produce no `error` violations.
- `py_bad.py`: should fail on `Any`, bare `dict` and `list`, missing return type, and deep nesting.
- `rs_clean.rs`: should pass or produce no `error` violations.
- `rs_bad.rs`: should fail design limits and warn on `unsafe`, `unwrap`, `expect`, and `todo!`.
- `zig_clean.zig`: should pass or produce no `error` violations.
- `zig_bad.zig`: should fail on deep nesting and warn on `anytype` and `@intCast`.

Build the binaries:

```zsh
zig build
```

Quick CLI single-file test:

```zsh
./zig-out/bin/gd analyze samples/go_bad.go
```

Quick CLI batch test:

```zsh
./zig-out/bin/gd batch samples/go_bad.go samples/py_clean.py --json | jq .
```

Quick CLI folder test:

```zsh
./zig-out/bin/gd folder samples --json | jq .
```

Config override example:

```zsh
./zig-out/bin/gd analyze samples/zig_bad.zig --json --config guardian.config.yaml | jq .
```

The CLI auto-loads `guardian.config.yaml` from the target path upward. The release packages also ship a `guardian.config.yaml` fallback next to the binaries. Use `guardian.config.yaml` as the starting point for your own config. On a terminal, `gd ... --json` still shows the pretty colored report; when piped to `jq`, it emits raw JSON. Use `--raw-json` to force JSON directly in the terminal.

Guardian intentionally has no MCP/plugin/skill path; use `gd` or the C ABI.
