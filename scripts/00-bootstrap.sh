#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"; need aws; load_state
REGION="${AWS_REGION:-$(aws_region)}"; REGION="${REGION:-us-east-1}"; export AWS_REGION="$REGION"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
PREFIX="${WORKSHOP_PREFIX:-ecs-worker-rush}"
CLUSTER_NAME="$PREFIX-cluster"; LOG_GROUP="/workshop/$PREFIX"; EXEC_ROLE="$PREFIX-exec-role"
VPC_ID="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
[[ "$VPC_ID" != "None" ]] || { echo 'No default VPC found. For a student lab, pre-provision a VPC or adapt bootstrap.' >&2; exit 1; }
mapfile -t SUBNETS < <(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" --query 'Subnets[?MapPublicIpOnLaunch==`true`].SubnetId' --output text | tr '\t' '\n' | head -2)
[[ ${#SUBNETS[@]} -ge 2 ]] || { echo 'Need two public subnets in the default VPC.' >&2; exit 1; }
aws ecs create-cluster --cluster-name "$CLUSTER_NAME" --tags key=Workshop,value=ECSWorkerRush >/dev/null 2>&1 || true
aws logs create-log-group --log-group-name "$LOG_GROUP" >/dev/null 2>&1 || true
if ! aws iam get-role --role-name "$EXEC_ROLE" >/dev/null 2>&1; then
  cat > /tmp/ecs-trust.json <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
  aws iam create-role --role-name "$EXEC_ROLE" --assume-role-policy-document file:///tmp/ecs-trust.json >/dev/null
  aws iam attach-role-policy --role-name "$EXEC_ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
  sleep 8
fi
EXEC_ROLE_ARN="$(aws iam get-role --role-name "$EXEC_ROLE" --query Role.Arn --output text)"
ALB_SG_NAME="$PREFIX-alb-sg"; TASK_SG_NAME="$PREFIX-task-sg"
ALB_SG="$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$ALB_SG_NAME" --query 'SecurityGroups[0].GroupId' --output text)"
if [[ "$ALB_SG" == "None" ]]; then ALB_SG="$(aws ec2 create-security-group --group-name "$ALB_SG_NAME" --description 'Worker Rush internal ALB' --vpc-id "$VPC_ID" --query GroupId --output text)"; fi
TASK_SG="$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$TASK_SG_NAME" --query 'SecurityGroups[0].GroupId' --output text)"
if [[ "$TASK_SG" == "None" ]]; then TASK_SG="$(aws ec2 create-security-group --group-name "$TASK_SG_NAME" --description 'Worker Rush ECS tasks' --vpc-id "$VPC_ID" --query GroupId --output text)"; fi
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" --protocol tcp --port 8080 --source-group "$ALB_SG" >/dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --group-id "$TASK_SG" --protocol tcp --port 8080 --source-group "$ALB_SG" >/dev/null 2>&1 || true
ALB_NAME="${PREFIX//_/}-alb"; ALB_NAME="${ALB_NAME:0:32}"
ALB_ARN="$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)"
if [[ -z "$ALB_ARN" || "$ALB_ARN" == "None" ]]; then ALB_ARN="$(aws elbv2 create-load-balancer --name "$ALB_NAME" --scheme internal --type application --security-groups "$ALB_SG" --subnets "${SUBNETS[@]}" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"; fi
ALB_DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].DNSName' --output text)"
for kv in AWS_REGION:$REGION ACCOUNT_ID:$ACCOUNT_ID PREFIX:$PREFIX CLUSTER_NAME:$CLUSTER_NAME LOG_GROUP:$LOG_GROUP EXEC_ROLE:$EXEC_ROLE EXEC_ROLE_ARN:$EXEC_ROLE_ARN VPC_ID:$VPC_ID SUBNET_1:${SUBNETS[0]} SUBNET_2:${SUBNETS[1]} ALB_SG:$ALB_SG TASK_SG:$TASK_SG ALB_NAME:$ALB_NAME ALB_ARN:$ALB_ARN ALB_DNS:$ALB_DNS; do put_state "${kv%%:*}" "${kv#*:}"; done
printf 'Bootstrap complete.\nVPC: %s\nCluster: %s\nInternal ALB: %s\n' "$VPC_ID" "$CLUSTER_NAME" "$ALB_DNS"
echo 'Setting up the game runner (builds and pushes the game image)...'
bash "$(dirname "$0")/setup-game.sh"
