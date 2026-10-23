#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"; need aws; need docker; load_state
: "${ECR_URI:?Run 01-create-ecr.sh first}"
IMAGE_TAG="${1:-v1}"; LOCAL_IMAGE="${2:-worker-rush:latest}"; REGISTRY="${ECR_URI%%/*}"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REGISTRY"
docker tag "$LOCAL_IMAGE" "$ECR_URI:$IMAGE_TAG"; docker push "$ECR_URI:$IMAGE_TAG"
put_state IMAGE_TAG "$IMAGE_TAG"; put_state IMAGE_URI "$ECR_URI:$IMAGE_TAG"; echo "Pushed: $ECR_URI:$IMAGE_TAG"
