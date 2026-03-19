#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ACK_FLAG="--i-understand-that-this-will-be-running-without-the-usual-guardrails"
TARGET_FILE="$SCRIPT_DIR/.symphony_target_path"

usage() {
  cat <<'EOF'
Usage:
  ./setup.sh [path-to-project-root-or-WORKFLOW.md] [--init-only]

Examples:
  ./setup.sh /path/to/your-repo
  ./setup.sh /path/to/your-repo --init-only
  ./setup.sh /path/to/custom/WORKFLOW.md
EOF
}

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

resolve_target_path() {
  local target="$1"

  if [[ -d "$target" ]]; then
    (
      cd -- "$target"
      pwd -P
    )
  else
    (
      cd -- "$(dirname -- "$target")"
      printf '%s/%s\n' "$(pwd -P)" "$(basename -- "$target")"
    )
  fi
}

target_path=""
init_only=0

while (($# > 0)); do
  case "$1" in
    --init-only)
      init_only=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      if [[ -n "$target_path" ]]; then
        die "Only one project root or workflow path may be provided."
      fi

      target_path="$1"
      shift
      ;;
  esac
done

if [[ -z "$target_path" ]]; then
  printf 'Project root to manage: '
  IFS= read -r target_path
fi

[[ -n "$target_path" ]] || die "A project root or workflow path is required."
target_path="$(resolve_target_path "$target_path")"

command -v mise >/dev/null 2>&1 || die "'mise' must be installed and on PATH."

if ! command -v codex >/dev/null 2>&1; then
  printf '%s\n' "Warning: 'codex' is not on PATH yet. Symphony will build, but the final launch will fail until Codex is installed." >&2
fi

cd "$SCRIPT_DIR"

printf '%s\n' "Installing Elixir/Erlang toolchain via mise..."
mise trust
mise install

printf '%s\n' "Fetching Elixir dependencies..."
mise exec -- mix setup

printf '%s\n' "Building Symphony..."
mise exec -- mix build

printf '%s\n' "Running interactive workflow setup..."
mise exec -- ./bin/symphony init "$target_path"
printf '%s\n' "$target_path" > "$TARGET_FILE"

if (( init_only )); then
  printf '%s\n' "Symphony setup initialized for $target_path"
  exit 0
fi

printf '%s\n' "Starting Symphony..."
exec mise exec -- ./bin/symphony "$ACK_FLAG" "$target_path"
