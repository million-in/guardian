#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

detect_platform() {
  local runner_os
  local arch

  if [[ -n "${RUNNER_OS:-}" ]]; then
    runner_os="$RUNNER_OS"
  else
    case "$(uname -s)" in
      Linux) runner_os="Linux" ;;
      Darwin) runner_os="macOS" ;;
      *) echo "unsupported runner OS: $(uname -s)" >&2; exit 1 ;;
    esac
  fi

  arch="$(uname -m)"
  case "$runner_os" in
    Linux) printf 'linux-%s' "$arch" ;;
    macOS) printf 'macos-%s' "$arch" ;;
    *) echo "unsupported runner OS: $runner_os" >&2; exit 1 ;;
  esac
}

copy_tree() {
  local source_path="$1"
  local target_path="$2"

  rm -rf "$target_path"
  cp -R "$source_path" "$target_path"
}

platform="${1:-$(detect_platform)}"
archive_root="dist/code-guardian-$platform"
archive_name="code-guardian-$platform.tar.gz"

mkdir -p dist
rm -rf "$archive_root" "$archive_name"

mkdir -p "$archive_root/bin"

cp zig-out/bin/gd "$archive_root/bin/"
cp zig-out/bin/guardian-mcp "$archive_root/bin/"
cp README.md guardian.config.example.json AGENTS.md LICENSE plugin.mcp.json "$archive_root/"

copy_tree skills "$archive_root/skills"
copy_tree .codex-plugin "$archive_root/.codex-plugin"
copy_tree .claude-plugin "$archive_root/.claude-plugin"

tar -czf "$archive_name" -C dist "code-guardian-$platform"
