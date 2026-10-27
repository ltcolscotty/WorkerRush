#!/usr/bin/env bash
# Builds the game image and registers the ECS task that runs it. Called by 00-bootstrap.sh; safe to re-run.
set -euo pipefail
source "$(dirname "$0")/common.sh"; need aws; need docker; load_state
: "${AWS_REGION:?Run 00-bootstrap.sh first}"; : "${EXEC_ROLE_ARN:?Run 00-bootstrap.sh first}"
GAME_REPO="${PREFIX}-game"; GAME_ROLE="${PREFIX}-game-role"; GAME_TASK_FAMILY="${PREFIX}-game"
GAME_ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${GAME_REPO}"

aws ecr describe-repositories --repository-names "$GAME_REPO" >/dev/null 2>&1 || aws ecr create-repository --repository-name "$GAME_REPO" >/dev/null

# Task role: lets the game read/scale only the worker service and read target health.
if ! aws iam get-role --role-name "$GAME_ROLE" >/dev/null 2>&1; then
  cat > /tmp/ecs-trust.json <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
  aws iam create-role --role-name "$GAME_ROLE" --assume-role-policy-document file:///tmp/ecs-trust.json >/dev/null
  sleep 8
fi
cat > /tmp/game-policy.json <<JSON
{"Version":"2012-10-17","Statement":[
{"Effect":"Allow","Action":["ecs:DescribeServices","ecs:UpdateService"],"Resource":"arn:aws:ecs:${AWS_REGION}:${ACCOUNT_ID}:service/${CLUSTER_NAME}/${PREFIX}-service"},
{"Effect":"Allow","Action":"elasticloadbalancing:DescribeTargetHealth","Resource":"*"}]}
JSON
aws iam put-role-policy --role-name "$GAME_ROLE" --policy-name game-access --policy-document file:///tmp/game-policy.json
GAME_ROLE_ARN="$(aws iam get-role --role-name "$GAME_ROLE" --query Role.Arn --output text)"

aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "${GAME_ECR_URI%%/*}"
docker build --platform linux/amd64 -t "$GAME_ECR_URI:latest" "$ROOT/game"
docker push "$GAME_ECR_URI:latest"

cat > /tmp/game-taskdef.json <<JSON
{"family":"$GAME_TASK_FAMILY","networkMode":"awsvpc","requiresCompatibilities":["FARGATE"],"cpu":"512","memory":"1024","executionRoleArn":"$EXEC_ROLE_ARN","taskRoleArn":"$GAME_ROLE_ARN","containerDefinitions":[{"name":"game","image":"$GAME_ECR_URI:latest","essential":true,"logConfiguration":{"logDriver":"awslogs","options":{"awslogs-group":"$LOG_GROUP","awslogs-region":"$AWS_REGION","awslogs-stream-prefix":"game"}}}]}
JSON
aws ecs register-task-definition --cli-input-json file:///tmp/game-taskdef.json >/dev/null

for kv in GAME_REPO:$GAME_REPO GAME_ECR_URI:$GAME_ECR_URI GAME_ROLE:$GAME_ROLE GAME_ROLE_ARN:$GAME_ROLE_ARN GAME_TASK_FAMILY:$GAME_TASK_FAMILY; do put_state "${kv%%:*}" "${kv#*:}"; done
echo "Game runner ready: $GAME_ECR_URI:latest (run rounds with ./scripts/06-run-game.sh)"
