#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ACK_FLAG="--i-understand-that-this-will-be-running-without-the-usual-guardrails"
TARGET_FILE="$SCRIPT_DIR/.symphony_target_path"

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

command -v mise >/dev/null 2>&1 || die "'mise' must be installed and on PATH."
[[ -f "$TARGET_FILE" ]] || die "No configured Symphony root found. Run ./setup.sh once first."

target_path="$(tr -d '\r\n' < "$TARGET_FILE")"
[[ -n "$target_path" ]] || die "Stored Symphony root is empty. Re-run ./setup.sh."

cd "$SCRIPT_DIR"
exec mise exec -- ./bin/symphony "$ACK_FLAG" "$target_path"
