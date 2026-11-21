#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/guardian-cli.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT INT TERM

red="$(printf '\033[31m')"
gray="$(printf '\033[90m')"
absolute_config="$ROOT/guardian.config.yaml"

./zig-out/bin/gd analyze samples/go_bad.go > "$tmp_dir/analyze.pretty"
grep -F "samples/go_bad.go" "$tmp_dir/analyze.pretty" >/dev/null
grep -F "banned_type" "$tmp_dir/analyze.pretty" >/dev/null
grep -F "interface{}" "$tmp_dir/analyze.pretty" >/dev/null
grep -F "$red" "$tmp_dir/analyze.pretty" >/dev/null

./zig-out/bin/gd analyze samples/go_design_bad.go > "$tmp_dir/design.pretty"
grep -F "too_many_arguments" "$tmp_dir/design.pretty" >/dev/null
grep -F "hidden_coupling" "$tmp_dir/design.pretty" >/dev/null

./zig-out/bin/gd batch src/types.zig src/cli.zig --json --config "$absolute_config" > "$tmp_dir/batch.json"
jq -e '.file_count == 2 and .pass == true' "$tmp_dir/batch.json" >/dev/null

./zig-out/bin/gd analyze samples/rs_bad.rs --raw-json --config "$absolute_config" > "$tmp_dir/rust.json"
jq -e '.language == "rust" and .warn_count > 0 and .error_count > 0 and .pass == false' "$tmp_dir/rust.json" >/dev/null

./zig-out/bin/gd folder src --json --config "$absolute_config" > "$tmp_dir/folder.json"
jq -e '.file_count > 0 and .pass == true' "$tmp_dir/folder.json" >/dev/null

./zig-out/bin/gd folder src --config "$absolute_config" > "$tmp_dir/folder.pretty"
grep -F "Scanned" "$tmp_dir/folder.pretty" >/dev/null
grep -F "$gray" "$tmp_dir/folder.pretty" >/dev/null

./zig-out/bin/gd audit samples --raw-json --config "$absolute_config" > "$tmp_dir/audit.json"
jq -e '.score.overall >= 0 and .score.threshold == 70 and .proof_status == "skipped" and .static.file_count > 0' "$tmp_dir/audit.json" >/dev/null

./zig-out/bin/gd audit samples --config "$absolute_config" > "$tmp_dir/audit.pretty"
grep -F "Audit score" "$tmp_dir/audit.pretty" >/dev/null
grep -F "Categories:" "$tmp_dir/audit.pretty" >/dev/null

mkdir -p "$tmp_dir/config-hit"
cp guardian.config.yaml "$tmp_dir/config-hit/guardian.config.yaml"
printf 'export const x = (): void => { console.log(1); }\n' > "$tmp_dir/config-hit/a.ts"

./zig-out/bin/gd folder "$tmp_dir/config-hit" > "$tmp_dir/config-hit.pretty"
grep -F "remove console logging before submission" "$tmp_dir/config-hit.pretty" >/dev/null

./zig-out/bin/gd folder "$tmp_dir/config-hit" --raw-json > "$tmp_dir/config-hit.json"
grep -F "remove console logging before submission" "$tmp_dir/config-hit.json" >/dev/null

# MCP server (gd mcp): initialize, tools/list, tools/call over stdio
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"guardian_analyze","arguments":{"path":"samples/rs_bad.rs"}}}' \
  | ./zig-out/bin/gd mcp > "$tmp_dir/mcp.jsonl"
jq -e -s '.[0].result.serverInfo.name == "guardian" and (.[1].result.tools | length) == 5' "$tmp_dir/mcp.jsonl" >/dev/null
jq -e -s '.[2].result.content[0].text | fromjson | .pass == false' "$tmp_dir/mcp.jsonl" >/dev/null
