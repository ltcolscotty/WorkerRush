#!/usr/bin/env bash
# Runs one game round as a Fargate task inside the VPC and streams its output here.
set -euo pipefail
source "$(dirname "$0")/common.sh"; need aws; load_state
MODE="${1:-practice}"; [[ "$MODE" == practice || "$MODE" == scored ]] || die 'Usage: 06-run-game.sh practice|scored'
require 'Run 00-bootstrap.sh first.' GAME_TASK_FAMILY CLUSTER_NAME SUBNET_1 SUBNET_2 ALB_SG ALB_DNS LOG_GROUP AWS_REGION
require 'Run 03-deploy-ecs.sh first.' SERVICE_NAME TG_ARN

TASK_ARN=""; TAIL_PID=""
cleanup_round(){
  local rc="$1"
  if [[ -n "$TAIL_PID" ]]; then kill "$TAIL_PID" 2>/dev/null || true; fi
  if (( rc != 0 )) && [[ -n "$TASK_ARN" ]]; then
    echo "The round may still be running. Stop it with: aws ecs stop-task --cluster $CLUSTER_NAME --task ${TASK_ARN##*/}" >&2
  fi
}
EXIT_HOOK=cleanup_round
trap 'exit 130' INT TERM

RUNNING="$(aws ecs list-tasks --cluster "$CLUSTER_NAME" --family "$GAME_TASK_FAMILY" --desired-status RUNNING --query 'taskArns[0]' --output text)"
[[ "$RUNNING" == "None" ]] || die "A round is already running (task ${RUNNING##*/}). Wait for it to finish or stop it with: aws ecs stop-task --cluster $CLUSTER_NAME --task ${RUNNING##*/}"

# Optional replay of an earlier scored round: GAME_SEED=<seed> ./scripts/06-run-game.sh scored
SEED_ENV=""
if [[ -n "${GAME_SEED:-}" ]]; then
  [[ "$GAME_SEED" =~ ^[A-Za-z0-9]+$ ]] || die 'GAME_SEED must be letters and digits only.'
  SEED_ENV=",{\"name\":\"GAME_SEED\",\"value\":\"$GAME_SEED\"}"
fi
cat > "$TMP/game-overrides.json" <<JSON
{"containerOverrides":[{"name":"game","command":["$MODE"],"environment":[{"name":"CLUSTER_NAME","value":"$CLUSTER_NAME"},{"name":"SERVICE_NAME","value":"$SERVICE_NAME"},{"name":"TG_ARN","value":"$TG_ARN"},{"name":"ALB_DNS","value":"$ALB_DNS"},{"name":"MAX_TASKS","value":"$MAX_TASKS"},{"name":"AWS_DEFAULT_REGION","value":"$AWS_REGION"}$SEED_ENV]}]}
JSON

read -r TASK_ARN FAIL_REASON <<<"$(aws ecs run-task --cluster "$CLUSTER_NAME" --task-definition "$GAME_TASK_FAMILY" --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1,$SUBNET_2],securityGroups=[$ALB_SG],assignPublicIp=ENABLED}" \
  --overrides "file://$TMP/game-overrides.json" --query '[tasks[0].taskArn, failures[0].reason]' --output text)"
if [[ -z "$TASK_ARN" || "$TASK_ARN" == None ]]; then TASK_ARN=""; die "The game task could not be started: ${FAIL_REASON:-unknown reason}"; fi
TASK_ID="${TASK_ARN##*/}"
echo "Starting $MODE round (task $TASK_ID). The game container takes about a minute to start..."

aws logs tail "$LOG_GROUP" --log-stream-name-prefix "game/game/$TASK_ID" --follow --format short & TAIL_PID=$!

# A scored round is ~10 minutes; give up (and stop the task) if it takes far longer than that.
DEADLINE=$((SECONDS + 1500))
while :; do
  STATUS="$(aws ecs describe-tasks --cluster "$CLUSTER_NAME" --tasks "$TASK_ARN" --query 'tasks[0].lastStatus' --output text 2>/dev/null || echo UNKNOWN)"
  [[ "$STATUS" != STOPPED ]] || break
  if (( SECONDS > DEADLINE )); then
    aws ecs stop-task --cluster "$CLUSTER_NAME" --task "$TASK_ID" >/dev/null || true; TASK_ARN=""
    die 'The round did not finish within 25 minutes; the game task was stopped.'
  fi
  sleep 5
done
sleep 15; kill "$TAIL_PID" 2>/dev/null || true; TAIL_PID=""

read -r EXIT_CODE STOP_REASON <<<"$(aws ecs describe-tasks --cluster "$CLUSTER_NAME" --tasks "$TASK_ARN" --query '[tasks[0].containers[0].exitCode, tasks[0].stoppedReason]' --output text)"
TASK_ARN=""
if [[ "$EXIT_CODE" != 0 ]]; then die "The game task failed (exit code: $EXIT_CODE; reason: ${STOP_REASON:-unknown}). See the output above."; fi
echo 'Round finished.'
