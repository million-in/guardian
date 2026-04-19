#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/guardian-mcp.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT INT TERM
absolute_config="$ROOT/guardian.config.json"

./scripts/guardian-check.sh analyze samples/go_bad.go > "$tmp_dir/analyze.json"
jq -e '.result.pass == false' "$tmp_dir/analyze.json" >/dev/null
jq -e 'any(.result.violations[]; .rule == "banned_type")' "$tmp_dir/analyze.json" >/dev/null

./scripts/guardian-check.sh analyze samples/go_design_bad.go > "$tmp_dir/design.json"
jq -e '.result.pass == false' "$tmp_dir/design.json" >/dev/null
jq -e 'any(.result.violations[]; .rule == "too_many_arguments")' "$tmp_dir/design.json" >/dev/null
jq -e 'any(.result.violations[]; .rule == "hidden_coupling")' "$tmp_dir/design.json" >/dev/null

./scripts/guardian-check.sh batch src/types.zig src/server.zig --config "$absolute_config" > "$tmp_dir/batch.json"
jq -e '.result.file_count == 2 and .result.pass == true' "$tmp_dir/batch.json" >/dev/null

./scripts/guardian-check.sh folder src --config "$absolute_config" > "$tmp_dir/folder.json"
jq -e '.result.file_count > 0 and .result.pass == true' "$tmp_dir/folder.json" >/dev/null

make_payload() {
  local body="$1"
  local len
  len="$(printf '%s' "$body" | wc -c | tr -d ' ')"
  printf 'Content-Length: %s\r\n\r\n%s' "$len" "$body"
}

sample_source="$(jq -Rs . < samples/go_bad.go)"
tool_body="$(jq -nc \
  --arg file_path "samples/go_bad.go" \
  --argjson source "$sample_source" \
  '{
    jsonrpc: "2.0",
    id: "tool-e2e",
    method: "tools/call",
    params: {
      name: "analyze",
      arguments: {
        file_path: $file_path,
        source: $source
      }
    }
  }')"

make_payload "$tool_body" \
  | ./zig-out/bin/guardian-mcp 2>/dev/null \
  | tr -d '\r' \
  | awk 'body{print} /^$/{body=1}' \
  > "$tmp_dir/tool.json"

jq -e '.result.content[0].text | contains("banned_type") and contains("\u001b[31m")' "$tmp_dir/tool.json" >/dev/null

tool_folder_body="$(jq -nc \
  --arg path "$ROOT/src" \
  --arg config_path "$absolute_config" \
  '{
    jsonrpc: "2.0",
    id: "tool-folder-e2e",
    method: "tools/call",
    params: {
      name: "analyze_folder",
      arguments: {
        path: $path,
        config_path: $config_path
      }
    }
  }')"

make_payload "$tool_folder_body" \
  | ./zig-out/bin/guardian-mcp 2>/dev/null \
  | tr -d '\r' \
  | awk 'body{print} /^$/{body=1}' \
  > "$tmp_dir/tool-folder.json"

jq -e '.result.content[0].text | contains("Scanned") and contains("PASS")' "$tmp_dir/tool-folder.json" >/dev/null
