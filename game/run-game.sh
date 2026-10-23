#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; source "$ROOT/scripts/common.sh"; load_state
MODE="${1:-practice}"; [[ "$MODE" == practice || "$MODE" == scored ]] || { echo 'Usage: run-game.sh practice|scored'; exit 1; }
command -v k6 >/dev/null || { echo 'k6 is required in this shell. See README for installation / VPC CloudShell setup.'; exit 1; }
: "${ALB_DNS:?Run bootstrap/deploy first}"; export CLUSTER_NAME SERVICE_NAME TG_ARN
TARGET_URL="http://$ALB_DNS:8080"; rm -f /tmp/k6-summary.json /tmp/game-monitor.json
python3 "$ROOT/game/monitor.py" "$MODE" & MON=$!
set +e; GAME_MODE="$MODE" TARGET_URL="$TARGET_URL" k6 run --quiet "$ROOT/game/game.js"; K6_RC=$?; set -e
wait "$MON"; python3 "$ROOT/game/score.py"
[[ $K6_RC -eq 0 ]] || echo 'Note: k6 threshold returned non-zero; the score above still uses collected results.'
