#!/usr/bin/env bash
# Runs on the machine where you built the image. It needs no .workshop.env: everything is derived from your
# AWS credentials, so it works from a laptop while bootstrap/deploy run in CloudShell.
set -euo pipefail
source "$(dirname "$0")/common.sh"; need aws; need_docker; load_state
IMAGE_TAG="${1:-v1}"; LOCAL_IMAGE="${2:-worker-rush:latest}"
PREFIX="${PREFIX:-${WORKSHOP_PREFIX:-ecs-worker-rush}}"
AWS_REGION="${AWS_REGION:-$(aws_region)}"; AWS_REGION="${AWS_REGION:-us-east-1}"; export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" || die 'AWS credentials are not working on this machine (aws sts get-caller-identity).'
REPO_NAME="${PREFIX}-worker"; ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${REPO_NAME}"; REGISTRY="${ECR_URI%%/*}"
echo "Pushing to account $ACCOUNT_ID, region $AWS_REGION"
aws ecr describe-repositories --repository-names "$REPO_NAME" >/dev/null 2>&1 || die "ECR repository '$REPO_NAME' not found in account $ACCOUNT_ID, region $AWS_REGION. Run 01-create-ecr.sh first, and make sure this machine uses the same account and region as CloudShell (aws configure get region)."
docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1 || die "Local image '$LOCAL_IMAGE' not found. Build it first: docker build --platform linux/amd64 -t worker-rush:latest ./worker"
ARCH="$(docker image inspect --format '{{.Architecture}}' "$LOCAL_IMAGE")"
[[ "$ARCH" == amd64 ]] || die "Image '$LOCAL_IMAGE' is $ARCH, but Fargate runs X86_64 here and would crash-loop it. Rebuild with: docker build --platform linux/amd64 -t worker-rush:latest ./worker"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REGISTRY"
docker tag "$LOCAL_IMAGE" "$ECR_URI:$IMAGE_TAG"; docker push "$ECR_URI:$IMAGE_TAG"
echo "Pushed: $ECR_URI:$IMAGE_TAG"
echo "Next, in CloudShell: ./scripts/03-deploy-ecs.sh $IMAGE_TAG"
