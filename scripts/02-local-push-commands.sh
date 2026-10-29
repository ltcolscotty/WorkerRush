#!/usr/bin/env bash
# Run in CloudShell. Prints the docker commands to paste on the machine where you built the image, so that
# machine needs only Docker: no AWS CLI, no AWS credentials, no copy of this repo's scripts.
set -euo pipefail
source "$(dirname "$0")/common.sh"; need aws; load_state
require 'Run 01-create-ecr.sh first.' ECR_URI AWS_REGION
IMAGE_TAG="${1:-v1}"; LOCAL_IMAGE="${2:-worker-rush:latest}"
# These end up in commands the user pastes, so keep them to harmless characters.
[[ "$IMAGE_TAG" =~ ^[A-Za-z0-9_.-]+$ ]] || die 'The tag may only contain letters, digits, underscore, dot and dash.'
[[ "$LOCAL_IMAGE" =~ ^[A-Za-z0-9_./:-]+$ ]] || die 'The local image name may only contain letters, digits and _ . / : -'
REGISTRY="${ECR_URI%%/*}"
TOKEN="$(aws ecr get-login-password --region "$AWS_REGION")" || die 'Could not get an ECR login token. Check your CloudShell credentials and permissions.'

cat <<EOF
Paste these on the machine where you built the image. It needs Docker only. They work in bash, PowerShell and cmd.

1) Check the image is built for Fargate. This must print: amd64
   (If it doesn't, rebuild with: docker build --platform linux/amd64 -t worker-rush:latest ./worker)

docker image inspect --format "{{.Architecture}}" $LOCAL_IMAGE

2) Log in to your ECR registry. The token is a password valid for 12 hours: don't share it or paste it into chat.

echo $TOKEN | docker login --username AWS --password-stdin $REGISTRY

3) Tag and push.

docker tag $LOCAL_IMAGE $ECR_URI:$IMAGE_TAG
docker push $ECR_URI:$IMAGE_TAG

4) Back here in CloudShell:

./scripts/03-deploy-ecs.sh $IMAGE_TAG
EOF
