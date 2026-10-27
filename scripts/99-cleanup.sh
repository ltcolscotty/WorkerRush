#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"; load_state
set +e
if [[ -n "${GAME_TASK_FAMILY:-}" && -n "${CLUSTER_NAME:-}" ]]; then
  for t in $(aws ecs list-tasks --cluster "$CLUSTER_NAME" --family "$GAME_TASK_FAMILY" --query 'taskArns[]' --output text 2>/dev/null); do aws ecs stop-task --cluster "$CLUSTER_NAME" --task "$t" >/dev/null 2>&1; done
fi
[[ -n "${SERVICE_NAME:-}" ]] && aws ecs update-service --cluster "$CLUSTER_NAME" --service "$SERVICE_NAME" --desired-count 0 >/dev/null 2>&1
[[ -n "${SERVICE_NAME:-}" ]] && aws ecs delete-service --cluster "$CLUSTER_NAME" --service "$SERVICE_NAME" --force >/dev/null 2>&1
sleep 5
[[ -n "${LISTENER_ARN:-}" ]] && aws elbv2 delete-listener --listener-arn "$LISTENER_ARN" >/dev/null 2>&1
[[ -n "${TG_ARN:-}" ]] && aws elbv2 delete-target-group --target-group-arn "$TG_ARN" >/dev/null 2>&1
[[ -n "${ALB_ARN:-}" ]] && aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" >/dev/null 2>&1
sleep 5
[[ -n "${TASK_SG:-}" ]] && aws ec2 delete-security-group --group-id "$TASK_SG" >/dev/null 2>&1
[[ -n "${ALB_SG:-}" ]] && aws ec2 delete-security-group --group-id "$ALB_SG" >/dev/null 2>&1
[[ -n "${CLUSTER_NAME:-}" ]] && aws ecs delete-cluster --cluster "$CLUSTER_NAME" >/dev/null 2>&1
[[ -n "${LOG_GROUP:-}" ]] && aws logs delete-log-group --log-group-name "$LOG_GROUP" >/dev/null 2>&1
[[ -n "${REPO_NAME:-}" ]] && aws ecr delete-repository --repository-name "$REPO_NAME" --force >/dev/null 2>&1
[[ -n "${GAME_REPO:-}" ]] && aws ecr delete-repository --repository-name "$GAME_REPO" --force >/dev/null 2>&1
[[ -n "${GAME_ROLE:-}" ]] && aws iam delete-role-policy --role-name "$GAME_ROLE" --policy-name game-access >/dev/null 2>&1
[[ -n "${GAME_ROLE:-}" ]] && aws iam delete-role --role-name "$GAME_ROLE" >/dev/null 2>&1
[[ -n "${EXEC_ROLE:-}" ]] && aws iam detach-role-policy --role-name "$EXEC_ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null 2>&1
[[ -n "${EXEC_ROLE:-}" ]] && aws iam delete-role --role-name "$EXEC_ROLE" >/dev/null 2>&1
rm -f "$STATE"; echo 'Cleanup requested. ALB/security-group deletion can take a short time; rerun cleanup if AWS reports dependencies.'
