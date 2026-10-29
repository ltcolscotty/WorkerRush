#!/usr/bin/env bash
# Best-effort teardown: every step is reported, and .workshop.env is only removed if every step succeeded.
# Resource names are derived from PREFIX, so this also works after a bootstrap that failed part-way.
set -uo pipefail
source "$(dirname "$0")/common.sh"; need aws; load_state
set +e; trap - ERR

PREFIX="${PREFIX:-${WORKSHOP_PREFIX:-ecs-worker-rush}}"
AWS_REGION="${AWS_REGION:-$(aws_region)}"; AWS_REGION="${AWS_REGION:-us-east-1}"; export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
CLUSTER_NAME="${CLUSTER_NAME:-$PREFIX-cluster}"; SERVICE_NAME="${SERVICE_NAME:-$PREFIX-service}"
LOG_GROUP="${LOG_GROUP:-/workshop/$PREFIX}"; EXEC_ROLE="${EXEC_ROLE:-$PREFIX-exec-role}"
REPO_NAME="${REPO_NAME:-$PREFIX-worker}"; GAME_REPO="${GAME_REPO:-$PREFIX-game}"; GAME_ROLE="${GAME_ROLE:-$PREFIX-game-role}"
GAME_TASK_FAMILY="${GAME_TASK_FAMILY:-$PREFIX-game}"
DEFAULT_ALB_NAME="${PREFIX//_/}-alb"; ALB_NAME="${ALB_NAME:-${DEFAULT_ALB_NAME:0:32}}"
DEFAULT_TG_NAME="${PREFIX//_/}-tg"; TG_NAME="${TG_NAME:-${DEFAULT_TG_NAME:0:32}}"

FAILED=0
ABSENT_RE='NotFound|NoSuchEntity|does not exist|not found|NotActive|ResourceNotFound'
BUSY_RE='DependencyViolation|ResourceInUse|in use|ClusterContainsTasks|ClusterContainsServices|ClusterContainsContainerInstances|DeleteConflict'
# run_step LABEL TRIES DELAY cmd... : run, retry while AWS says the resource is still in use, report the result.
run_step(){
  local label="$1" tries="$2" delay="$3" out i; shift 3
  for ((i=1; i<=tries; i++)); do
    if out="$("$@" 2>&1)"; then echo "  ok      $label"; return 0; fi
    if grep -Eq "$ABSENT_RE" <<<"$out"; then echo "  absent  $label"; return 0; fi
    if (( i < tries )) && grep -Eq "$BUSY_RE" <<<"$out"; then sleep "$delay"; continue; fi
    echo "  FAILED  $label"; sed 's/^/          /' <<<"$out"; FAILED=1; return 0
  done
}
lookup(){ local v; v="$("$@" 2>/dev/null)"; [[ "$v" == None ]] && v=""; echo "$v"; }

echo "Cleaning up workshop resources (prefix: $PREFIX, region: $AWS_REGION)"
VPC_ID="${VPC_ID:-$(lookup aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)}"
ALB_ARN="${ALB_ARN:-$(lookup aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text)}"
TG_ARN="${TG_ARN:-$(lookup aws elbv2 describe-target-groups --names "$TG_NAME" --query 'TargetGroups[0].TargetGroupArn' --output text)}"
sg_lookup(){ [[ -n "$VPC_ID" ]] && lookup aws ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$1" --query 'SecurityGroups[0].GroupId' --output text; }
TASK_SG="${TASK_SG:-$(sg_lookup "$PREFIX-task-sg")}"; ALB_SG="${ALB_SG:-$(sg_lookup "$PREFIX-alb-sg")}"

# Game rounds and the worker service first, so nothing holds the load balancer or security groups.
for t in $(aws ecs list-tasks --cluster "$CLUSTER_NAME" --family "$GAME_TASK_FAMILY" --query 'taskArns[]' --output text 2>/dev/null); do
  run_step "stop game task ${t##*/}" 1 0 aws ecs stop-task --cluster "$CLUSTER_NAME" --task "$t"
done
SVC_STATUS="$(lookup aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" --query 'services[0].status' --output text)"
if [[ "$SVC_STATUS" == ACTIVE ]]; then run_step "delete ECS service" 1 0 aws ecs delete-service --cluster "$CLUSTER_NAME" --service "$SERVICE_NAME" --force; fi
if [[ "$SVC_STATUS" == ACTIVE || "$SVC_STATUS" == DRAINING ]]; then run_step "wait for ECS service to drain" 1 0 aws ecs wait services-inactive --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME"; fi

# Deleting the load balancer also deletes its listeners.
if [[ -n "$ALB_ARN" ]]; then
  run_step "delete load balancer" 1 0 aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
  run_step "wait for load balancer deletion" 1 0 aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN"
fi
[[ -z "$TG_ARN" ]] || run_step "delete target group" 12 10 aws elbv2 delete-target-group --target-group-arn "$TG_ARN"
# Network interfaces from tasks and the load balancer can take a few minutes to release.
[[ -z "$TASK_SG" ]] || run_step "delete task security group" 18 10 aws ec2 delete-security-group --group-id "$TASK_SG"
[[ -z "$ALB_SG" ]] || run_step "delete ALB security group" 18 10 aws ec2 delete-security-group --group-id "$ALB_SG"
run_step "delete ECS cluster" 12 10 aws ecs delete-cluster --cluster "$CLUSTER_NAME"
run_step "delete log group" 1 0 aws logs delete-log-group --log-group-name "$LOG_GROUP"
run_step "delete worker ECR repository" 1 0 aws ecr delete-repository --repository-name "$REPO_NAME" --force
run_step "delete game ECR repository" 1 0 aws ecr delete-repository --repository-name "$GAME_REPO" --force
run_step "remove game role policy" 1 0 aws iam delete-role-policy --role-name "$GAME_ROLE" --policy-name game-access
run_step "delete game role" 1 0 aws iam delete-role --role-name "$GAME_ROLE"
run_step "detach execution role policy" 1 0 aws iam detach-role-policy --role-name "$EXEC_ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
run_step "delete execution role" 1 0 aws iam delete-role --role-name "$EXEC_ROLE"

if (( FAILED == 0 )); then
  rm -f "$STATE"; echo 'Cleanup complete. Your default VPC and subnets were not touched.'
else
  echo 'Some steps FAILED (see above). .workshop.env was kept; fix the cause and run ./scripts/99-cleanup.sh again.' >&2
  exit 1
fi
