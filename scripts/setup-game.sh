#!/usr/bin/env bash
# Builds the game image and registers the ECS task that runs it. Called by 00-bootstrap.sh; safe to re-run.
set -euo pipefail
source "$(dirname "$0")/common.sh"; need aws; need_docker; load_state
require 'Run 00-bootstrap.sh first.' AWS_REGION ACCOUNT_ID PREFIX CLUSTER_NAME EXEC_ROLE_ARN LOG_GROUP
GAME_REPO="${PREFIX}-game"; GAME_ROLE="${PREFIX}-game-role"; GAME_TASK_FAMILY="${PREFIX}-game"
GAME_ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${GAME_REPO}"

aws ecr describe-repositories --repository-names "$GAME_REPO" >/dev/null 2>&1 || aws ecr create-repository --repository-name "$GAME_REPO" >/dev/null
put_state GAME_REPO "$GAME_REPO"; put_state GAME_ECR_URI "$GAME_ECR_URI"

# Task role: lets the game read/scale only the worker service and read target health.
NEW_ROLE=0
if ! aws iam get-role --role-name "$GAME_ROLE" >/dev/null 2>&1; then
  cat > "$TMP/ecs-trust.json" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
  aws iam create-role --role-name "$GAME_ROLE" --assume-role-policy-document "file://$TMP/ecs-trust.json" >/dev/null
  NEW_ROLE=1
fi
put_state GAME_ROLE "$GAME_ROLE"
# The service name must match SERVICE_NAME in 03-deploy-ecs.sh.
cat > "$TMP/game-policy.json" <<JSON
{"Version":"2012-10-17","Statement":[
{"Effect":"Allow","Action":["ecs:DescribeServices","ecs:UpdateService"],"Resource":"arn:aws:ecs:${AWS_REGION}:${ACCOUNT_ID}:service/${CLUSTER_NAME}/${PREFIX}-service"},
{"Effect":"Allow","Action":"elasticloadbalancing:DescribeTargetHealth","Resource":"*"}]}
JSON
aws iam put-role-policy --role-name "$GAME_ROLE" --policy-name game-access --policy-document "file://$TMP/game-policy.json"
if [[ "$NEW_ROLE" == 1 ]]; then sleep 8; fi
GAME_ROLE_ARN="$(aws iam get-role --role-name "$GAME_ROLE" --query Role.Arn --output text)"
put_state GAME_ROLE_ARN "$GAME_ROLE_ARN"

aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "${GAME_ECR_URI%%/*}"
docker build --platform linux/amd64 -t "$GAME_ECR_URI:latest" "$ROOT/game"
docker push "$GAME_ECR_URI:latest"

cat > "$TMP/game-taskdef.json" <<JSON
{"family":"$GAME_TASK_FAMILY","networkMode":"awsvpc","requiresCompatibilities":["FARGATE"],"cpu":"512","memory":"1024","executionRoleArn":"$EXEC_ROLE_ARN","taskRoleArn":"$GAME_ROLE_ARN","containerDefinitions":[{"name":"game","image":"$GAME_ECR_URI:latest","essential":true,"logConfiguration":{"logDriver":"awslogs","options":{"awslogs-group":"$LOG_GROUP","awslogs-region":"$AWS_REGION","awslogs-stream-prefix":"game"}}}]}
JSON
# A freshly created role can take a moment to become usable, so retry.
retry 5 6 aws ecs register-task-definition --cli-input-json "file://$TMP/game-taskdef.json" --query 'taskDefinition.taskDefinitionArn' --output text >/dev/null \
  || die 'Could not register the game task definition (see the error above).'

put_state GAME_TASK_FAMILY "$GAME_TASK_FAMILY"
echo "Game runner ready: $GAME_ECR_URI:latest (run rounds with ./scripts/06-run-game.sh)"
