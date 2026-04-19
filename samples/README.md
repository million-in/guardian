# Samples

These files are test fixtures for the guardian MCP engine.

- `go_clean.go`: should pass or produce no `error` violations.
- `go_bad.go`: should fail on banned Go surface types, unchecked assertion, and deep nesting.
- `go_design_bad.go`: should fail on design rules such as too many arguments, too many fields, and hidden coupling.
- `ts_clean.ts`: should pass or produce no `error` violations.
- `ts_bad.ts`: should fail on `any`, `as any`, `@ts-ignore`, and deep nesting.
- `py_clean.py`: should pass or produce no `error` violations.
- `py_bad.py`: should fail on `Any`, bare `dict` and `list`, missing return type, and deep nesting.
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
./zig-out/bin/gd analyze samples/zig_bad.zig --json --config guardian.config.json | jq .
```

The CLI auto-loads `guardian.config.json` from the target path upward. The release packages also ship a `guardian.config.json` fallback next to the binaries. Use `guardian.config.json` as the starting point for your own config. On a terminal, `gd ... --json` still shows the pretty colored report; when piped to `jq`, it emits raw JSON. Use `--raw-json` to force JSON directly in the terminal.

Quick MCP single-file test:

```zsh
./scripts/guardian-check.sh analyze samples/go_bad.go | jq .
```

Quick MCP batch test:

```zsh
./scripts/guardian-check.sh batch samples/go_bad.go samples/py_clean.py | jq .
```

Quick MCP folder test:

```zsh
./scripts/guardian-check.sh folder samples | jq .
```

If you want to send raw requests yourself, compute the header with byte length, not character count:

```zsh
SRC=$(jq -Rs . < samples/go_bad.go)
BODY=$(printf '{"jsonrpc":"2.0","id":1,"method":"analyze","params":{"file_path":"samples/go_bad.go","source":%s}}' "$SRC")
LEN=$(printf '%s' "$BODY" | wc -c | tr -d ' ')
printf 'Content-Length: %s\r\n\r\n%s' "$LEN" "$BODY" | ./zig-out/bin/guardian-mcp
```
