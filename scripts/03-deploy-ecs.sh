#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"; need aws; load_state
require 'Run 00-bootstrap.sh first.' PREFIX AWS_REGION ACCOUNT_ID CLUSTER_NAME VPC_ID ALB_ARN ALB_DNS EXEC_ROLE_ARN LOG_GROUP SUBNET_1 SUBNET_2 TASK_SG
# The image comes from ECR, not local state, because it may have been pushed from a different machine.
# Usage: 03-deploy-ecs.sh [tag]   (default: the last tag pushed from here, else v1)
IMAGE_TAG="${1:-${IMAGE_TAG:-v1}}"; REPO_NAME="${PREFIX}-worker"
aws ecr describe-images --repository-name "$REPO_NAME" --image-ids imageTag="$IMAGE_TAG" >/dev/null 2>&1 || die "Image $REPO_NAME:$IMAGE_TAG is not in ECR ($AWS_REGION). Run 02-local-push-commands.sh $IMAGE_TAG here and paste its commands where you built the image, or pass the tag you did push: 03-deploy-ecs.sh <tag>"
IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${REPO_NAME}:${IMAGE_TAG}"
put_state IMAGE_TAG "$IMAGE_TAG"; put_state IMAGE_URI "$IMAGE_URI"; echo "Deploying $IMAGE_URI"
SERVICE_NAME="${PREFIX}-service"; TASK_FAMILY="${PREFIX}-task"; TG_NAME="${PREFIX//_/}-tg"; TG_NAME="${TG_NAME:0:32}"
# State is saved as soon as each resource exists, so 99-cleanup.sh can find it if a later step fails.
TG_ARN="$(aws elbv2 describe-target-groups --names "$TG_NAME" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)"
if [[ -z "$TG_ARN" || "$TG_ARN" == "None" ]]; then TG_ARN="$(aws elbv2 create-target-group --name "$TG_NAME" --protocol HTTP --port 8080 --vpc-id "$VPC_ID" --target-type ip --health-check-path /health --health-check-interval-seconds 10 --healthy-threshold-count 2 --unhealthy-threshold-count 2 --query 'TargetGroups[0].TargetGroupArn' --output text)"; fi
put_state TG_NAME "$TG_NAME"; put_state TG_ARN "$TG_ARN"
LISTENER_ARN="$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'Listeners[?Port==`8080`].ListenerArn | [0]' --output text)"
if [[ "$LISTENER_ARN" == "None" ]]; then LISTENER_ARN="$(aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 8080 --default-actions Type=forward,TargetGroupArn="$TG_ARN" --query 'Listeners[0].ListenerArn' --output text)"; fi
put_state LISTENER_ARN "$LISTENER_ARN"
cat > "$TMP/taskdef.json" <<JSON
{"family":"$TASK_FAMILY","networkMode":"awsvpc","requiresCompatibilities":["FARGATE"],"cpu":"256","memory":"512","executionRoleArn":"$EXEC_ROLE_ARN","containerDefinitions":[{"name":"worker","image":"$IMAGE_URI","essential":true,"portMappings":[{"containerPort":8080,"protocol":"tcp"}],"logConfiguration":{"logDriver":"awslogs","options":{"awslogs-group":"$LOG_GROUP","awslogs-region":"$AWS_REGION","awslogs-stream-prefix":"worker"}}}]}
JSON
# Deploys always start at 1 task; scaling goes through 04-scale.sh, which enforces MAX_TASKS.
TASK_DEF_ARN="$(aws ecs register-task-definition --cli-input-json "file://$TMP/taskdef.json" --query 'taskDefinition.taskDefinitionArn' --output text)"
# The circuit breaker makes ECS stop retrying a task that keeps failing (crash loop, wrong architecture, ...).
DEPLOY_CONFIG='deploymentCircuitBreaker={enable=true,rollback=false},maximumPercent=200,minimumHealthyPercent=100'
SVC_STATUS="$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" --query 'services[0].status' --output text 2>/dev/null || true)"
case "$SVC_STATUS" in
  ACTIVE)
    aws ecs update-service --cluster "$CLUSTER_NAME" --service "$SERVICE_NAME" --task-definition "$TASK_DEF_ARN" --desired-count 1 --force-new-deployment --deployment-configuration "$DEPLOY_CONFIG" >/dev/null ;;
  DRAINING)
    die "Service $SERVICE_NAME is still being deleted (from a previous cleanup). Wait a minute and re-run this script." ;;
  *)
    aws ecs create-service --cluster "$CLUSTER_NAME" --service-name "$SERVICE_NAME" --task-definition "$TASK_DEF_ARN" --desired-count 1 --launch-type FARGATE --platform-version LATEST --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1,$SUBNET_2],securityGroups=[$TASK_SG],assignPublicIp=ENABLED}" --load-balancers "targetGroupArn=$TG_ARN,containerName=worker,containerPort=8080" --health-check-grace-period-seconds 30 --deployment-configuration "$DEPLOY_CONFIG" >/dev/null ;;
esac
put_state SERVICE_NAME "$SERVICE_NAME"; put_state TASK_FAMILY "$TASK_FAMILY"

report_failure(){
  echo >&2; echo "ERROR: the worker did not become healthy: $1" >&2
  echo 'Recent service events:' >&2
  aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" --query 'services[0].events[:5].message' --output text >&2 || true
  local stopped; stopped="$(aws ecs list-tasks --cluster "$CLUSTER_NAME" --service-name "$SERVICE_NAME" --desired-status STOPPED --query 'taskArns[0]' --output text 2>/dev/null || true)"
  if [[ -n "$stopped" && "$stopped" != None ]]; then
    echo 'Most recently stopped task:' >&2
    aws ecs describe-tasks --cluster "$CLUSTER_NAME" --tasks "$stopped" --query 'tasks[0].{StoppedReason:stoppedReason,ExitCode:containers[0].exitCode,ContainerReason:containers[0].reason}' --output table >&2 || true
  fi
  echo "Check the container output with: aws logs tail $LOG_GROUP --since 15m" >&2
  echo 'Common causes: the app crashes on start, the image is not linux/amd64, or /health does not return 200 on port 8080.' >&2
  exit 1
}

echo 'Waiting for the task to start and pass load balancer health checks (up to 5 minutes)...'
DEADLINE=$((SECONDS + 300))
while :; do
  read -r DESIRED RUNNING <<<"$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" --query 'services[0].[desiredCount,runningCount]' --output text)"
  ROLLOUT="$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" --query 'services[0].deployments[?status==`PRIMARY`] | [0].rolloutState' --output text)"
  HEALTHY="$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)"
  echo "  desired=$DESIRED running=$RUNNING healthy=$HEALTHY rollout=$ROLLOUT"
  [[ "$ROLLOUT" != FAILED ]] || report_failure 'ECS stopped the deployment after repeated task failures.'
  if [[ "$ROLLOUT" == COMPLETED && "$HEALTHY" -ge "$DESIRED" ]]; then break; fi
  (( SECONDS < DEADLINE )) || report_failure 'timed out after 5 minutes.'
  sleep 10
done
echo "Deployed. Private target: http://$ALB_DNS:8080"
