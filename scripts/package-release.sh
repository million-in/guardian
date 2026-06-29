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

platform="${1:-$(detect_platform)}"
archive_root="dist/code-guardian-$platform"
archive_name="code-guardian-$platform.tar.gz"

mkdir -p dist
rm -rf "$archive_root" "$archive_name"

mkdir -p "$archive_root/bin" "$archive_root/include" "$archive_root/lib"

cp zig-out/bin/gd "$archive_root/bin/"
cp zig-out/lib/libguardian.* "$archive_root/lib/"
cp include/guardian.h "$archive_root/include/"
cp README.md SPEC.md DELTA.md guardian.config.yaml LICENSE "$archive_root/"

tar -czf "$archive_name" -C dist "code-guardian-$platform"
