#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/guardian-release.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT INT TERM

arch="$(uname -m)"
case "$(uname -s)" in
  Linux) platform="linux-$arch" ;;
  Darwin) platform="macos-$arch" ;;
  *) echo "unsupported platform" >&2; exit 1 ;;
esac

bash ./scripts/package-release.sh "$platform"

archive_name="code-guardian-$platform.tar.gz"
extract_root="$tmp_dir/extract"
mkdir -p "$extract_root"
tar -xzf "$archive_name" -C "$extract_root"

package_root="$extract_root/code-guardian-$platform"

# Verify expected files exist
test -x "$package_root/bin/gd"
test -x "$package_root/bin/guardian-mcp"
test -f "$package_root/plugin.mcp.json"
test -f "$package_root/.claude-plugin/plugin.json"
test -f "$package_root/.claude-plugin/claude.plugin"
test -f "$package_root/.claude-plugin/marketplace.json"
test -f "$package_root/.codex-plugin/plugin.json"
test -f "$package_root/skills/code-guardian/guardian.md"
test -f "$package_root/skills/code-guardian/SKILL.md"

# Verify binary paths point to release layout
jq -e '.mcpServers.guardian.command == "./bin/guardian-mcp"' "$package_root/plugin.mcp.json" >/dev/null
jq -e '.mcpServers.guardian.command == "${CLAUDE_PLUGIN_ROOT}/bin/guardian-mcp"' "$package_root/.claude-plugin/plugin.json" >/dev/null
jq -e '.mcpServers == "./plugin.mcp.json"' "$package_root/.codex-plugin/plugin.json" >/dev/null

# Verify local-only files are NOT shipped
! test -f "$package_root/.mcp.json"
! test -d "$package_root/.claude"
! test -d "$package_root/.codex"
