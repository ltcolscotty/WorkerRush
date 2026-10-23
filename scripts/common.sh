#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT/.workshop.env"
load_state(){ [[ -f "$STATE" ]] && source "$STATE"; }
need(){ command -v "$1" >/dev/null || { echo "Missing required command: $1" >&2; exit 1; }; }
aws_region(){ aws configure get region 2>/dev/null || true; }
put_state(){ local k="$1" v="$2"; touch "$STATE"; grep -v "^${k}=" "$STATE" > "$STATE.tmp" || true; printf '%s=%q\n' "$k" "$v" >> "$STATE.tmp"; mv "$STATE.tmp" "$STATE"; }
