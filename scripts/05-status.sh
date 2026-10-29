#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"; need aws; load_state
require 'Run 03-deploy-ecs.sh first.' CLUSTER_NAME SERVICE_NAME TG_ARN
aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" --query 'services[0].{Desired:desiredCount,Running:runningCount,Pending:pendingCount,TaskDefinition:taskDefinition}' --output table
echo "Max allowed tasks: $MAX_TASKS"
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --query 'TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State}' --output table
