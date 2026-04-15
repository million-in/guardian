#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/guardian-check.sh analyze <file> [--config path]
  ./scripts/guardian-check.sh batch <file> <file> [...] [--config path]
  ./scripts/guardian-check.sh folder <dir> [--config path]

Examples:
  ./scripts/guardian-check.sh analyze samples/go_bad.go | jq .
  ./scripts/guardian-check.sh batch samples/go_bad.go samples/py_clean.py | jq .
  ./scripts/guardian-check.sh folder samples | jq .
EOF
}

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

mode="$1"
shift

config_path=""
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      if [[ $# -lt 2 ]]; then
        usage
        exit 1
      fi
      config_path="$2"
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
set -- "${args[@]}"

binary="./zig-out/bin/guardian-mcp"
if [[ ! -x "$binary" ]]; then
  echo "guardian-mcp binary not found at $binary" >&2
  echo "Run: zig build" >&2
  exit 1
fi

make_payload() {
  local body="$1"
  local len
  len=$(printf '%s' "$body" | wc -c | tr -d ' ')
  printf 'Content-Length: %s\r\n\r\n%s' "$len" "$body"
}

case "$mode" in
  analyze)
    if [[ $# -ne 1 ]]; then
      usage
      exit 1
    fi

    file="$1"
    src=$(jq -Rs . < "$file")
    body=$(jq -nc \
      --arg file_path "$file" \
      --argjson source "$src" \
      --arg config_path "$config_path" \
      '{
        jsonrpc: "2.0",
        id: "cli-analyze",
        method: "analyze",
        params: (
          {file_path: $file_path, source: $source}
          + (if $config_path == "" then {} else {config_path: $config_path} end)
        )
      }')
    make_payload "$body" | "$binary" 2>/dev/null | tr -d '\r' | awk 'body{print} /^$/{body=1}'
    ;;
  batch)
    if [[ $# -eq 0 ]]; then
      usage
      exit 1
    fi

    files_json=$(for file in "$@"; do
      src=$(jq -Rs . < "$file")
      jq -nc --arg file_path "$file" --argjson source "$src" '{file_path:$file_path,source:$source}'
    done | jq -s .)
    body=$(jq -nc \
      --argjson files "$files_json" \
      --arg config_path "$config_path" \
      '{
        jsonrpc: "2.0",
        id: "cli-batch",
        method: "analyze_batch",
        params: (
          {files: $files}
          + (if $config_path == "" then {} else {config_path: $config_path} end)
        )
      }')
    make_payload "$body" | "$binary" 2>/dev/null | tr -d '\r' | awk 'body{print} /^$/{body=1}'
    ;;
  folder)
    if [[ $# -ne 1 ]]; then
      usage
      exit 1
    fi

    body=$(jq -nc \
      --arg path "$1" \
      --arg config_path "$config_path" \
      '{
        jsonrpc: "2.0",
        id: "cli-folder",
        method: "analyze_folder",
        params: (
          {path: $path}
          + (if $config_path == "" then {} else {config_path: $config_path} end)
        )
      }')
    make_payload "$body" | "$binary" 2>/dev/null | tr -d '\r' | awk 'body{print} /^$/{body=1}'
    ;;
  *)
    usage
    exit 1
    ;;
esac
