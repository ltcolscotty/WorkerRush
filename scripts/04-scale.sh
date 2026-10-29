#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"; need aws; load_state
COUNT="${1:-}"; [[ "$COUNT" =~ ^[0-9]+$ ]] && (( 10#$COUNT <= MAX_TASKS )) || die "Usage: 04-scale.sh <0-$MAX_TASKS> (workshop cap is $MAX_TASKS tasks)"
require 'Run 03-deploy-ecs.sh first.' CLUSTER_NAME SERVICE_NAME
aws ecs update-service --cluster "$CLUSTER_NAME" --service "$SERVICE_NAME" --desired-count "$((10#$COUNT))" --query 'service.{desired:desiredCount,running:runningCount,pending:pendingCount}' --output table
