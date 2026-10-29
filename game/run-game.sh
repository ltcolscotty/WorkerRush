#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# In the game container there is no scripts/ directory or .workshop.env; settings arrive as environment variables.
if [[ -f "$ROOT/scripts/common.sh" ]]; then source "$ROOT/scripts/common.sh"; load_state; fi
: "${MAX_TASKS:=4}"
MODE="${1:-practice}"; [[ "$MODE" == practice || "$MODE" == scored ]] || { echo 'Usage: run-game.sh practice|scored'; exit 1; }
fail(){ echo "ERROR: $*" >&2; exit 1; }
command -v k6 >/dev/null || fail 'k6 is required. Normally the game runs in its container via scripts/06-run-game.sh.'
for v in ALB_DNS CLUSTER_NAME SERVICE_NAME TG_ARN; do [[ -n "${!v:-}" ]] || fail "$v is not set. Run bootstrap and deploy first."; done
export CLUSTER_NAME SERVICE_NAME TG_ARN MAX_TASKS

# Fail now, with the AWS error visible, rather than playing a round whose monitor cannot see the service.
SVC_STATUS="$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" --query 'services[0].status' --output text)" \
  || fail 'Cannot read the worker service. Check the game task role permissions.'
[[ "$SVC_STATUS" == ACTIVE ]] || fail "Worker service $SERVICE_NAME is not active (status: $SVC_STATUS). Run ./scripts/03-deploy-ecs.sh first."
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" >/dev/null || fail 'Cannot read target health. Check the game task role permissions.'

TARGET_URL="http://$ALB_DNS:8080"; rm -f /tmp/k6-summary.json /tmp/game-monitor.json /tmp/game-schedule.json
GAME_SEED="${GAME_SEED:-$RANDOM$RANDOM}"
[[ "$MODE" == scored ]] && echo "Round seed: $GAME_SEED (replay with GAME_SEED=$GAME_SEED)"
python3 "$ROOT/game/round_plan.py" "$MODE" "$GAME_SEED"

MON=""; K6=""
# Runs on normal exit, error, Ctrl-C and ECS stop-task (SIGTERM): stop the load, and never leave a scored round's workers running.
cleanup(){
  local rc=$?; trap - EXIT INT TERM
  [[ -z "$K6" ]] || kill "$K6" 2>/dev/null || true
  [[ -z "$MON" ]] || kill "$MON" 2>/dev/null || true
  if [[ "$MODE" == scored ]]; then
    aws ecs update-service --cluster "$CLUSTER_NAME" --service "$SERVICE_NAME" --desired-count 0 >/dev/null 2>&1 \
      || echo "WARNING: could not scale the worker service to 0. Run ./scripts/04-scale.sh 0" >&2
  fi
  exit "$rc"
}
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM

python3 "$ROOT/game/monitor.py" "$MODE" & MON=$!
# k6 runs in the background and we wait on it, so SIGTERM is handled promptly instead of after k6 exits.
GAME_MODE="$MODE" TARGET_URL="$TARGET_URL" k6 run --quiet "$ROOT/game/game.js" & K6=$!
set +e
wait "$K6"; K6_RC=$?; K6=""
wait "$MON"; MON_RC=$?; MON=""
set -e

[[ -s /tmp/k6-summary.json ]] || fail "k6 produced no results (exit code $K6_RC), so there is no score."
[[ $MON_RC -eq 0 ]] || fail "The monitor stopped with an error (exit code $MON_RC), so there is no score."
python3 "$ROOT/game/score.py"
[[ $K6_RC -eq 0 ]] || echo 'Note: k6 threshold returned non-zero; the score above still uses collected results.'
