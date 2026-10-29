#!/usr/bin/env bash
set -Eeuo pipefail
# Make $(...) honour set -e, so a failing command inside a helper function is not silently ignored.
shopt -s inherit_errexit 2>/dev/null || true
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die(){ echo "ERROR: $*" >&2; exit 1; }
# CloudShell only guarantees write access to $HOME. State normally lives in the project folder, but if that
# folder is read-only (and has no state yet) it falls back to $HOME so every script agrees on the location.
STATE="$ROOT/.workshop.env"
if [[ ! -e "$STATE" && ! -w "$ROOT" ]]; then STATE="$HOME/.workshop.env"; fi
# Hard cap on ECS tasks to protect attendee credit; deliberately not read from the environment.
readonly MAX_TASKS=4

# Scratch directory for generated JSON, kept under $HOME rather than /tmp; removed on exit. A script can
# set EXIT_HOOK to a function that runs first and receives the exit code.
TMP_BASE="${WORKSHOP_TMPDIR:-$HOME/.cache}"
mkdir -p "$TMP_BASE" && TMP="$(mktemp -d "$TMP_BASE/workshop.XXXXXX")" || die "Cannot create a scratch directory under $TMP_BASE. Set WORKSHOP_TMPDIR to a writable folder."
EXIT_HOOK=""
_on_exit(){ local rc=$?; [[ -z "$EXIT_HOOK" ]] || "$EXIT_HOOK" "$rc" || true; rm -rf "$TMP"; return 0; }
trap _on_exit EXIT
# Never fail silently: say which script, line and command failed, and what to do next.
trap 'echo "ERROR: $(basename "$0") line $LINENO: \"$BASH_COMMAND\" failed. Fix the problem and re-run this script (it is safe to re-run), or run ./scripts/99-cleanup.sh to remove everything." >&2' ERR

load_state(){
  if [[ -f "$STATE" ]]; then source "$STATE"; fi
  if [[ -n "${AWS_REGION:-}" ]]; then export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"; fi
}
need(){ command -v "$1" >/dev/null || die "Missing required command: $1"; }
need_docker(){ need docker; docker info >/dev/null 2>&1 || die 'Docker is installed but its daemon is not reachable. Start Docker and try again.'; }
# require "hint" VAR...  : stop with a helpful message if state from an earlier step is missing.
require(){ local hint="$1" v; shift; for v in "$@"; do [[ -n "${!v:-}" ]] || die "$v is not set. $hint"; done; }
aws_region(){ aws configure get region 2>/dev/null || true; }
put_state(){ local k="$1" v="$2"; touch "$STATE"; grep -v "^${k}=" "$STATE" > "$STATE.tmp" || true; printf '%s=%q\n' "$k" "$v" >> "$STATE.tmp"; mv "$STATE.tmp" "$STATE"; }
# Run an AWS command, tolerating only "already exists" errors; anything else is shown and stops the script.
ignore_exists(){
  local out
  if out="$("$@" 2>&1)"; then return 0; fi
  if grep -Eq 'AlreadyExists|Duplicate|already exists' <<<"$out"; then return 0; fi
  echo "$out" >&2; die "Command failed: $*"
}
# retry TRIES DELAY cmd...
retry(){ local n="$1" delay="$2" i; shift 2; for ((i=1; i<=n; i++)); do if "$@"; then return 0; fi; if (( i < n )); then sleep "$delay"; fi; done; return 1; }
