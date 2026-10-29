#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"; need aws; need_docker; load_state
REGION="${AWS_REGION:-$(aws_region)}"; REGION="${REGION:-us-east-1}"; export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" || die 'AWS credentials are not working. Check that you are logged in (aws sts get-caller-identity).'
PREFIX="${WORKSHOP_PREFIX:-ecs-worker-rush}"
CLUSTER_NAME="$PREFIX-cluster"; LOG_GROUP="/workshop/$PREFIX"; EXEC_ROLE="$PREFIX-exec-role"
# State is saved after every resource, so 99-cleanup.sh can find whatever was created if a later step fails.
put_state AWS_REGION "$REGION"; put_state ACCOUNT_ID "$ACCOUNT_ID"; put_state PREFIX "$PREFIX"

VPC_ID="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
[[ "$VPC_ID" != "None" ]] || die 'No default VPC found. For a student lab, pre-provision a VPC or adapt bootstrap.'
SUBNET_LIST="$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" --query 'Subnets[?MapPublicIpOnLaunch==`true`].SubnetId' --output text)"
read -r SUBNET_1 SUBNET_2 _ <<<"$SUBNET_LIST" || true
[[ -n "${SUBNET_2:-}" ]] || die 'Need two public subnets in the default VPC.'
put_state VPC_ID "$VPC_ID"; put_state SUBNET_1 "$SUBNET_1"; put_state SUBNET_2 "$SUBNET_2"

ignore_exists aws ecs create-cluster --cluster-name "$CLUSTER_NAME" --tags key=Workshop,value=ECSWorkerRush
put_state CLUSTER_NAME "$CLUSTER_NAME"
ignore_exists aws logs create-log-group --log-group-name "$LOG_GROUP"
put_state LOG_GROUP "$LOG_GROUP"

NEW_ROLE=0
if ! aws iam get-role --role-name "$EXEC_ROLE" >/dev/null 2>&1; then
  cat > "$TMP/ecs-trust.json" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
  aws iam create-role --role-name "$EXEC_ROLE" --assume-role-policy-document "file://$TMP/ecs-trust.json" >/dev/null
  NEW_ROLE=1
fi
put_state EXEC_ROLE "$EXEC_ROLE"
# Always attach (it is idempotent), so a role left half-created by an earlier failed run is repaired.
aws iam attach-role-policy --role-name "$EXEC_ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
if [[ "$NEW_ROLE" == 1 ]]; then sleep 8; fi
EXEC_ROLE_ARN="$(aws iam get-role --role-name "$EXEC_ROLE" --query Role.Arn --output text)"
put_state EXEC_ROLE_ARN "$EXEC_ROLE_ARN"

# Sets SG_ID to the security group with this name, creating it if needed.
ensure_sg(){
  SG_ID="$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$1" --query 'SecurityGroups[0].GroupId' --output text)"
  if [[ "$SG_ID" == "None" ]]; then SG_ID="$(aws ec2 create-security-group --group-name "$1" --description "$2" --vpc-id "$VPC_ID" --query GroupId --output text)"; fi
}
ensure_sg "$PREFIX-alb-sg" 'Worker Rush internal ALB'; ALB_SG="$SG_ID"; put_state ALB_SG "$ALB_SG"
ensure_sg "$PREFIX-task-sg" 'Worker Rush ECS tasks'; TASK_SG="$SG_ID"; put_state TASK_SG "$TASK_SG"
ignore_exists aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" --protocol tcp --port 8080 --source-group "$ALB_SG"
ignore_exists aws ec2 authorize-security-group-ingress --group-id "$TASK_SG" --protocol tcp --port 8080 --source-group "$ALB_SG"

ALB_NAME="${PREFIX//_/}-alb"; ALB_NAME="${ALB_NAME:0:32}"
ALB_ARN="$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)"
if [[ -z "$ALB_ARN" || "$ALB_ARN" == "None" ]]; then
  ALB_ARN="$(aws elbv2 create-load-balancer --name "$ALB_NAME" --scheme internal --type application --security-groups "$ALB_SG" --subnets "$SUBNET_1" "$SUBNET_2" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
fi
put_state ALB_NAME "$ALB_NAME"; put_state ALB_ARN "$ALB_ARN"
echo 'Waiting for the load balancer to become available...'
aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"
ALB_DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].DNSName' --output text)"
put_state ALB_DNS "$ALB_DNS"
printf 'Bootstrap complete.\nVPC: %s\nCluster: %s\nInternal ALB: %s\n' "$VPC_ID" "$CLUSTER_NAME" "$ALB_DNS"
echo 'Setting up the game runner (builds and pushes the game image)...'
bash "$(dirname "$0")/setup-game.sh"
