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
test -f "$package_root/guardian.config.yaml"
test -f "$package_root/SPEC.md"
test -f "$package_root/DELTA.md"
test -f "$package_root/include/guardian.h"
test -n "$(find "$package_root/lib" -maxdepth 1 -name 'libguardian.*' -type f -print -quit)"

# Verify local-only files are NOT shipped
! test -f "$package_root/.mcp.json"
! test -d "$package_root/.claude"
! test -d "$package_root/.codex"
! test -x "$package_root/bin/guardian-mcp"
! test -f "$package_root/plugin.mcp.json"
! test -d "$package_root/.claude-plugin"
! test -d "$package_root/.codex-plugin"
! test -d "$package_root/skills"
