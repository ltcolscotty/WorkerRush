#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"; load_state
COUNT="${1:-}"; [[ "$COUNT" =~ ^[0-4]$ ]] || { echo 'Usage: 04-scale.sh <0-4>'; exit 1; }
aws ecs update-service --cluster "$CLUSTER_NAME" --service "$SERVICE_NAME" --desired-count "$COUNT" --query 'service.{desired:desiredCount,running:runningCount,pending:pendingCount}' --output table
