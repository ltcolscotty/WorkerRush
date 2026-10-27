#!/usr/bin/env bash
# Runs one game round as a Fargate task inside the VPC and streams its output here.
set -euo pipefail
source "$(dirname "$0")/common.sh"; need aws; load_state
MODE="${1:-practice}"; [[ "$MODE" == practice || "$MODE" == scored ]] || { echo 'Usage: 06-run-game.sh practice|scored'; exit 1; }
: "${GAME_TASK_FAMILY:?Run 00-bootstrap.sh first}"; : "${SERVICE_NAME:?Run 03-deploy-ecs.sh first}"; : "${TG_ARN:?Run 03-deploy-ecs.sh first}"

RUNNING="$(aws ecs list-tasks --cluster "$CLUSTER_NAME" --family "$GAME_TASK_FAMILY" --desired-status RUNNING --query 'taskArns[0]' --output text)"
[[ "$RUNNING" == "None" ]] || { echo "A round is already running: ${RUNNING##*/}"; exit 1; }

# Optional replay of an earlier scored round: GAME_SEED=<seed> ./scripts/06-run-game.sh scored
SEED_ENV=""
if [[ -n "${GAME_SEED:-}" ]]; then
  [[ "$GAME_SEED" =~ ^[A-Za-z0-9]+$ ]] || { echo 'GAME_SEED must be letters and digits only.'; exit 1; }
  SEED_ENV=",{\"name\":\"GAME_SEED\",\"value\":\"$GAME_SEED\"}"
fi
cat > /tmp/game-overrides.json <<JSON
{"containerOverrides":[{"name":"game","command":["$MODE"],"environment":[{"name":"CLUSTER_NAME","value":"$CLUSTER_NAME"},{"name":"SERVICE_NAME","value":"$SERVICE_NAME"},{"name":"TG_ARN","value":"$TG_ARN"},{"name":"ALB_DNS","value":"$ALB_DNS"},{"name":"MAX_TASKS","value":"$MAX_TASKS"},{"name":"AWS_DEFAULT_REGION","value":"$AWS_REGION"}$SEED_ENV]}]}
JSON

TASK_ARN="$(aws ecs run-task --cluster "$CLUSTER_NAME" --task-definition "$GAME_TASK_FAMILY" --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1,$SUBNET_2],securityGroups=[$ALB_SG],assignPublicIp=ENABLED}" \
  --overrides file:///tmp/game-overrides.json --query 'tasks[0].taskArn' --output text)"
[[ -n "$TASK_ARN" && "$TASK_ARN" != "None" ]] || { echo 'The game task could not be started.' >&2; exit 1; }
TASK_ID="${TASK_ARN##*/}"
echo "Starting $MODE round (task $TASK_ID). The game container takes about a minute to start..."

aws logs tail "$LOG_GROUP" --log-stream-name-prefix "game/game/$TASK_ID" --follow --format short & TAIL=$!
trap 'kill $TAIL 2>/dev/null || true; echo; echo "Stopped watching. The round keeps running; end it with: aws ecs stop-task --cluster $CLUSTER_NAME --task $TASK_ID"; exit 130' INT

while :; do
  STATUS="$(aws ecs describe-tasks --cluster "$CLUSTER_NAME" --tasks "$TASK_ARN" --query 'tasks[0].lastStatus' --output text)"
  [[ "$STATUS" == "STOPPED" ]] && break
  sleep 5
done
sleep 8; kill "$TAIL" 2>/dev/null || true
aws ecs describe-tasks --cluster "$CLUSTER_NAME" --tasks "$TASK_ARN" --query 'tasks[0].{Exit:containers[0].exitCode,Reason:stoppedReason}' --output text
