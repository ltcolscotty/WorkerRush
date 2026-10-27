#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# In the game container there is no scripts/ directory or .workshop.env; settings arrive as environment variables.
if [[ -f "$ROOT/scripts/common.sh" ]]; then source "$ROOT/scripts/common.sh"; load_state; fi
MAX_TASKS="${MAX_TASKS:-4}"
MODE="${1:-practice}"; [[ "$MODE" == practice || "$MODE" == scored ]] || { echo 'Usage: run-game.sh practice|scored'; exit 1; }
command -v k6 >/dev/null || { echo 'k6 is required. Normally the game runs in its container via scripts/06-run-game.sh.'; exit 1; }
: "${ALB_DNS:?Run bootstrap/deploy first}"; export CLUSTER_NAME SERVICE_NAME TG_ARN MAX_TASKS
TARGET_URL="http://$ALB_DNS:8080"; rm -f /tmp/k6-summary.json /tmp/game-monitor.json /tmp/game-schedule.json
GAME_SEED="${GAME_SEED:-$RANDOM$RANDOM}"
[[ "$MODE" == scored ]] && echo "Round seed: $GAME_SEED (replay with GAME_SEED=$GAME_SEED)"
python3 "$ROOT/game/round_plan.py" "$MODE" "$GAME_SEED"
python3 "$ROOT/game/monitor.py" "$MODE" & MON=$!
set +e; GAME_MODE="$MODE" TARGET_URL="$TARGET_URL" k6 run --quiet "$ROOT/game/game.js"; K6_RC=$?; set -e
wait "$MON"; python3 "$ROOT/game/score.py"
[[ $K6_RC -eq 0 ]] || echo 'Note: k6 threshold returned non-zero; the score above still uses collected results.'
