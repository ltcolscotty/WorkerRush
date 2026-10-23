#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"; need aws; load_state
: "${AWS_REGION:?Run 00-bootstrap.sh first}"; REPO_NAME="${PREFIX}-worker"
aws ecr describe-repositories --repository-names "$REPO_NAME" >/dev/null 2>&1 || aws ecr create-repository --repository-name "$REPO_NAME" --image-scanning-configuration scanOnPush=true >/dev/null
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${REPO_NAME}"; put_state REPO_NAME "$REPO_NAME"; put_state ECR_URI "$ECR_URI"
echo "ECR repository: $ECR_URI"
