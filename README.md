# ECS Worker Rush — independent AWS workshop bundle

Each attendee deploys a private worker service in their own AWS account. The workshop focuses on **Kiro -> Docker -> ECR -> ECS/Fargate -> manual scaling**. IAM, networking, logging, and ALB plumbing are scripted.

## Important assumptions

- AWS CLI v2 and Docker are available where image build/push commands run.
- The account has a default VPC with at least two public subnets. This starter deliberately uses those subnets and public IPs for Fargate **egress** so tasks can pull from ECR; inbound worker traffic is still restricted to the internal ALB security group.
- The attendee/lab role can create ECS, ECR, ELBv2, EC2 security groups, CloudWatch Logs, and the ECS task execution IAM role. If student roles cannot create IAM roles, an instructor/lab administrator should pre-create the execution role and adapt `00-bootstrap.sh`.
- The load generator must have VPC reachability to the **internal** ALB. AWS CloudShell supports VPC environments: create one in this VPC/subnet and associate the ALB security group (or a dedicated client SG with an ALB ingress rule). Standard CloudShell is not assumed to reach the internal ALB.
- k6 must be installed in the environment that runs `game/run-game.sh`.

## 1. Bootstrap supporting AWS resources

```bash
./scripts/00-bootstrap.sh
```

This creates/reuses the ECS cluster, task execution role, log group, security groups, and internal ALB. Generated IDs are stored in `.workshop.env`.

## 2. Generate the Dockerfile with Kiro

Open the project in Kiro and ask:

> Create the Dockerfile for the worker application using the project steering files. Explain the important Docker instructions after creating it.

The expected file is `worker/Dockerfile`.

Build and test:

```bash
docker build --platform linux/amd64 -t worker-rush:latest ./worker
docker run --rm -p 8080:8080 worker-rush:latest
```

Test `http://localhost:8080/health`.

## 3. ECR

```bash
./scripts/01-create-ecr.sh
./scripts/02-push-image.sh v1 worker-rush:latest
```

## 4. ECS/Fargate

```bash
./scripts/03-deploy-ecs.sh
./scripts/05-status.sh
```

The task definition uses 0.25 vCPU / 0.5 GB, port 8080, `awsvpc`, Fargate, CloudWatch logs, and the ECR image. The ECS service begins at desired count 1 and registers task ENIs in an `ip` target group behind the internal ALB.

## 5. Prepare the private game shell

In AWS CloudShell, create a **VPC environment** attached to the VPC/subnet from `.workshop.env`. It needs network permission to reach the internal ALB on TCP 8080. Copy/clone this project into that environment and install k6 according to your lab image/package policy.

Verify:

```bash
source .workshop.env
curl "http://$ALB_DNS:8080/health"
```

A 200 response means the load generator can reach the private worker service.

## 6. Practice and scored rounds

Keep one shell for the game:

```bash
./game/run-game.sh practice
```

Use another shell (standard CloudShell is fine for AWS API calls) to scale:

```bash
./scripts/04-scale.sh 1
./scripts/04-scale.sh 3
./scripts/04-scale.sh 4
./scripts/04-scale.sh 2
```

Maximum: 4 tasks.

Then:

```bash
./game/run-game.sh scored
```

The scored profile is ~10 minutes. The terminal shows time, desired/running/healthy capacity, and remaining **game credits**. The final score is revealed after the round. Credits are simulated game currency and have no relationship to AWS billing.

## Game model

- Workers deliberately process one request at a time by default and return `503` when busy.
- k6 uses an arrival-rate workload, so demand continues independently of worker speed.
- More healthy tasks increase successful throughput.
- Running tasks continuously consume game credits.
- Completed requests increase score; missed requests hurt score; remaining credits provide an efficiency bonus.
- Students therefore manually right-size desired count between 0 and 4.

Tune `game/game.js`, `WORK_MS`, and `burn_per_task_per_sec` after rehearsal. Do not treat the included balance as final until tested with real Fargate startup/ALB health-check timing.

## Status

```bash
./scripts/05-status.sh
```

This intentionally shows both ECS service counts and ALB target health so students can see that desired, running, and load-balancer-ready capacity are different states.

## Cleanup

```bash
./scripts/99-cleanup.sh
```

Cleanup removes workshop ECR/ECS/ALB/log/IAM/security-group resources but does not delete the account's default VPC/subnets.

## Production/lab caveats

This is workshop infrastructure, not a production reference architecture. Before the event, test it against the exact student account permissions, quotas, region, CloudShell environment, and available package installation mechanism. If the student environment blocks IAM creation or CloudShell VPC environments, pre-provision those pieces at the lab/platform layer rather than expanding the attendee lesson.
