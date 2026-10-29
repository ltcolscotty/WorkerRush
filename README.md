# ECS Worker Rush — independent AWS workshop bundle

Each attendee deploys a private worker service in their own AWS account. The workshop focuses on **Kiro -> Docker -> ECR -> ECS/Fargate -> manual scaling**. IAM, networking, logging, and ALB plumbing are scripted. To see what each script does and why, read [SCRIPTS.md](SCRIPTS.md).

## Attendee quick path

1. **Your machine:** clone the project and open it in Kiro.
   ```bash
   git clone https://github.com/ltcolscotty/WorkerRush.git
   ```
2. **CloudShell** (AWS console, top bar): clone the same project, which gives you the scripts.
   ```bash
   git clone https://github.com/ltcolscotty/WorkerRush.git && cd WorkerRush
   ```
3. **CloudShell:** `./scripts/00-bootstrap.sh`, then `./scripts/01-create-ecr.sh`.
4. **Your machine:** ask Kiro for the Dockerfile, then build and test the image (section 2).
5. **CloudShell:** `./scripts/02-local-push-commands.sh v1 worker-rush:latest`. Paste the commands it prints on your machine to push the image.
6. **CloudShell:** `./scripts/03-deploy-ecs.sh v1`.
7. **CloudShell, two tabs:** play with `./scripts/06-run-game.sh practice|scored` in one and `./scripts/04-scale.sh N` in the other.
8. **CloudShell:** `./scripts/99-cleanup.sh` when you are done.

Each step is explained below, and [See it in the console](#see-it-in-the-console) shows where to watch each one in the AWS dashboards. Everything after step 2 runs from the `WorkerRush` folder in CloudShell. The project and your `.workshop.env` live in your CloudShell home directory, which survives session timeouts. If the session is reset, `cd WorkerRush` and carry on.

## Important assumptions

- AWS CloudShell has the AWS CLI v2 and Docker (the bootstrap builds the game image there). Attendees' own machines need only Docker for the worker image.
- The account has a default VPC with at least two public subnets. This starter deliberately uses those subnets and public IPs for Fargate **egress** so tasks can pull from ECR; inbound worker traffic is still restricted to the internal ALB security group.
- The attendee/lab role can create ECS, ECR, ELBv2, EC2 security groups, CloudWatch Logs, and the ECS task execution IAM role. If student roles cannot create IAM roles, an instructor/lab administrator should pre-create the execution role and adapt `00-bootstrap.sh`.
- The game load generator runs as a Fargate task inside the VPC (it has to reach the **internal** ALB), so attendees need no VPC CloudShell, k6, or game setup. Standard CloudShell is enough.
- The attendee/lab role also needs to create the game's IAM task role (it can only describe/scale the worker service and read target health).

## Where each step runs

Everything AWS-related runs in **AWS CloudShell**: bootstrap, ECR creation, deploy, scaling, game rounds and cleanup. Your own machine only needs **Docker** (plus Kiro): you build, test and push the worker image there, with no AWS CLI and no AWS credentials. The two sides share no files: CloudShell prints the push commands, and deploy reads the image from ECR.

## 1. Bootstrap supporting AWS resources

Run this **in CloudShell**:

```bash
./scripts/00-bootstrap.sh
```

This creates/reuses the ECS cluster, task execution role, log group, security groups, and internal ALB. It also builds and pushes the **game runner image** (`game/Dockerfile`) to its own ECR repository and registers its ECS task, so attendees only work with the worker image. Generated IDs are stored in `.workshop.env`. Docker is required for this step.

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

Create the repository **in CloudShell**:

```bash
./scripts/01-create-ecr.sh
```

Then get the image into ECR **without installing the AWS CLI on your own machine**. In CloudShell, run:

```bash
./scripts/02-local-push-commands.sh v1 worker-rush:latest
```

It prints a short list of `docker` commands (a Fargate-architecture check, `docker login` with a 12-hour ECR token, `docker tag`, and `docker push`). Paste them into a terminal on the machine where you built the image. They work in bash, PowerShell and cmd, and only need Docker. Treat the token like a password.

If you do have the AWS CLI and credentials on that machine, `./scripts/02-push-image.sh v1 worker-rush:latest` does the same push in one step. It needs the same account and region as CloudShell.

## 4. ECS/Fargate

Back **in CloudShell**, deploy the tag you pushed (it is checked against ECR first):

```bash
./scripts/03-deploy-ecs.sh v1
./scripts/05-status.sh
```

The task definition uses 0.25 vCPU / 0.5 GB, port 8080, `awsvpc`, Fargate, CloudWatch logs, and the ECR image. The ECS service begins at desired count 1 and registers task ENIs in an `ip` target group behind the internal ALB.

## 5. Practice and scored rounds

The game runs as a task in your VPC and streams its status line back to your terminal. A healthy worker must be registered before you start. Keep one shell for the game:

```bash
./scripts/06-run-game.sh practice
```

The game container takes about a minute to start. To replay an earlier scored round: `GAME_SEED=<seed> ./scripts/06-run-game.sh scored`. Only one round can run at a time. Press Ctrl-C to stop watching; the round keeps running.

Use another shell to scale:

```bash
./scripts/04-scale.sh 1
./scripts/04-scale.sh 3
./scripts/04-scale.sh 4
./scripts/04-scale.sh 2
```

Maximum: 4 tasks. The cap is enforced by `04-scale.sh` (via `MAX_TASKS` in `scripts/common.sh`), and while a round is running the monitor scales any service above 4 back down to 4. After a scored round the monitor scales the service to 0 so idle tasks don't keep spending credit.

Instructor note: ECS has no built-in limit on desired count, so the monitor only enforces the cap during a round. To enforce it at the account level, lower the Fargate On-Demand vCPU Service Quota (or use an SCP) in student accounts.

Then:

```bash
./scripts/06-run-game.sh scored
```

The scored profile is ~10 minutes. The output shows time, desired/running/healthy capacity, and remaining **game credits**. The final score is revealed after the round. Credits are simulated game currency and have no relationship to AWS billing.

## Game model

- Workers deliberately process one request at a time by default and return `503` when busy.
- k6 uses an arrival-rate workload, so demand continues independently of worker speed.
- More healthy tasks increase successful throughput.
- Running tasks continuously consume game credits.
- Completed requests increase score; missed requests hurt score; remaining credits provide an efficiency bonus.
- Students therefore manually right-size desired count between 0 and 4.
- Each scored round varies a little: spike timing and height are jittered per run from a seed, while total load and the overall shape stay the same. The seed is printed; `GAME_SEED=<seed> ./scripts/06-run-game.sh scored` replays a round.
- The monitor line shows demand forecasts (for example "Heavy demand predicted soon") about 45 s before each change, so players have time to scale.
- The final summary includes a theoretical max score (perfect instant scaling) and an **efficiency %**. Use the efficiency % to compare players across different seeds.

Tune the stages and jitter in `game/round_plan.py`, `WORK_MS`, and `BURN_PER_TASK_PER_SEC` after rehearsal. Do not treat the included balance as final until tested with real Fargate startup/ALB health-check timing.

## Status

```bash
./scripts/05-status.sh
```

This intentionally shows both ECS service counts and ALB target health so students can see that desired, running, and load-balancer-ready capacity are different states.

## See it in the console

The scripts do the work, but everything they create is visible in the AWS console. Open these as you go, with the console's **region set to the same region as CloudShell** (top right). The names below assume the default `ecs-worker-rush` prefix.

| After this step | Where to look | What you'll see |
|---|---|---|
| `00-bootstrap.sh` | **ECS → Clusters → `ecs-worker-rush-cluster`** | An empty cluster. With Fargate it is only a label for your tasks. |
| | **EC2 → Load Balancers → `ecs-worker-rush-alb`** | An *internal* load balancer with a listener on port 8080 (it gets its forwarding rule after the deploy). |
| | **EC2 → Security Groups** (`ecs-worker-rush-alb-sg`, `ecs-worker-rush-task-sg`) | The inbound rules that let only the load balancer reach your containers. |
| | **IAM → Roles** (`ecs-worker-rush-exec-role`, `ecs-worker-rush-game-role`) | The role ECS uses to pull images and write logs, and the game's limited role. |
| `01-create-ecr.sh` and your push | **ECR → Private repositories → `ecs-worker-rush-worker`** | Your image and its tag (`v1`), size, push time, and the vulnerability scan results. |
| `03-deploy-ecs.sh` | **ECS → Task definitions → `ecs-worker-rush-task`** | The blueprint: image, 0.25 vCPU / 0.5 GB, port 8080, log settings. Each deploy adds a revision. |
| | **ECS → Clusters → … → Services → `ecs-worker-rush-service`** | The **Tasks** tab (running containers and their IPs), **Deployments**, **Events** (a plain-language log of what ECS is doing), and **Health and metrics** (CPU and memory). |
| | **EC2 → Target Groups → `ecs-worker-rush-tg` → Targets** | Each task's health: `initial`, then `healthy`. This is the same data as `05-status.sh`. |
| `04-scale.sh` and the game | The service's **Tasks** tab | Tasks appear as you scale up and go away as you scale down. Filter by **Stopped** to see why a task stopped. |
| | **ECS → Clusters → … → Tasks** | The game's own task (`ecs-worker-rush-game`) while a round is running. |
| Any time | **CloudWatch → Logs → Log groups → `/workshop/ecs-worker-rush`** | One stream per container: `worker/worker/<task-id>` for workers and `game/game/<task-id>` for game rounds. This is where `print` and `uvicorn` output ends up. |

Things worth trying: scale to 3 and watch the target group while the new tasks go from `initial` to `healthy`; open a worker's log stream while the game runs and watch the `POST /job` requests arrive; look at the service's **Events** tab after a deploy.

After `99-cleanup.sh`, refresh the same pages to see the resources disappear. The load balancer and security groups can take a few minutes to go.

## Cleanup

```bash
./scripts/99-cleanup.sh
```

Cleanup removes workshop ECR/ECS/ALB/log/IAM/security-group resources (including the game runner) but does not delete the account's default VPC/subnets.

## Production/lab caveats

This is workshop infrastructure, not a production reference architecture. Before the event, test it against the exact student account permissions, quotas, region, CloudShell environment, and available package installation mechanism. If the student environment blocks IAM creation or CloudShell VPC environments, pre-provision those pieces at the lab/platform layer rather than expanding the attendee lesson.
