#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"; need aws; load_state
: "${IMAGE_URI:?Run 02-push-image.sh first}"
SERVICE_NAME="${PREFIX}-service"; TASK_FAMILY="${PREFIX}-task"; TG_NAME="${PREFIX//_/}-tg"; TG_NAME="${TG_NAME:0:32}"
TG_ARN="$(aws elbv2 describe-target-groups --names "$TG_NAME" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)"
if [[ -z "$TG_ARN" || "$TG_ARN" == "None" ]]; then TG_ARN="$(aws elbv2 create-target-group --name "$TG_NAME" --protocol HTTP --port 8080 --vpc-id "$VPC_ID" --target-type ip --health-check-path /health --health-check-interval-seconds 10 --healthy-threshold-count 2 --unhealthy-threshold-count 2 --query 'TargetGroups[0].TargetGroupArn' --output text)"; fi
LISTENER_ARN="$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'Listeners[?Port==`8080`].ListenerArn | [0]' --output text)"
if [[ "$LISTENER_ARN" == "None" ]]; then LISTENER_ARN="$(aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 8080 --default-actions Type=forward,TargetGroupArn="$TG_ARN" --query 'Listeners[0].ListenerArn' --output text)"; fi
cat > /tmp/taskdef.json <<JSON
{"family":"$TASK_FAMILY","networkMode":"awsvpc","requiresCompatibilities":["FARGATE"],"cpu":"256","memory":"512","executionRoleArn":"$EXEC_ROLE_ARN","containerDefinitions":[{"name":"worker","image":"$IMAGE_URI","essential":true,"portMappings":[{"containerPort":8080,"protocol":"tcp"}],"logConfiguration":{"logDriver":"awslogs","options":{"awslogs-group":"$LOG_GROUP","awslogs-region":"$AWS_REGION","awslogs-stream-prefix":"worker"}}}]}
JSON
TASK_DEF_ARN="$(aws ecs register-task-definition --cli-input-json file:///tmp/taskdef.json --query 'taskDefinition.taskDefinitionArn' --output text)"
if aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" --query 'services[0].status' --output text 2>/dev/null | grep -q ACTIVE; then
 aws ecs update-service --cluster "$CLUSTER_NAME" --service "$SERVICE_NAME" --task-definition "$TASK_DEF_ARN" --desired-count 1 --force-new-deployment >/dev/null
else
 aws ecs create-service --cluster "$CLUSTER_NAME" --service-name "$SERVICE_NAME" --task-definition "$TASK_DEF_ARN" --desired-count 1 --launch-type FARGATE --platform-version LATEST --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1,$SUBNET_2],securityGroups=[$TASK_SG],assignPublicIp=ENABLED}" --load-balancers "targetGroupArn=$TG_ARN,containerName=worker,containerPort=8080" --health-check-grace-period-seconds 30 >/dev/null
fi
put_state SERVICE_NAME "$SERVICE_NAME"; put_state TASK_FAMILY "$TASK_FAMILY"; put_state TG_NAME "$TG_NAME"; put_state TG_ARN "$TG_ARN"; put_state LISTENER_ARN "$LISTENER_ARN"
echo 'Waiting for the first task to become stable...'; aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" || true
echo "Deployed. Private target: http://$ALB_DNS:8080"
