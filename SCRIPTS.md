# How the workshop scripts work

This guide is for attendees who want to know what the scripts in `scripts/` and `game/` actually do. It explains why each step exists and what AWS resources it creates. It doesn't go through the scripts line by line. To follow the workshop itself, use the [README](README.md).

## Shared patterns

All scripts follow a few common conventions:

- **`scripts/common.sh`** is loaded by every script. It provides:
  - `load_state` / `put_state`: these read and write `.workshop.env`, a small file in the project root that stores IDs from earlier steps (VPC, subnets, ALB address, ECR repository URI, and so on). This is how `03-deploy-ecs.sh` knows which load balancer `00-bootstrap.sh` created without you copying IDs by hand.
  - `need`: stops with a clear message if a required tool (such as `aws` or `docker`) is missing.
  - `MAX_TASKS=4`: the workshop's hard limit on how many containers can run, which protects your credit.
- **Safe to re-run.** Most scripts look for a resource before creating it (`describe-…` first, `create-…` only if nothing was found). If a step fails partway through, fix the problem and run the same script again.
- **Strict mode.** `set -euo pipefail` makes a script stop at the first failed command instead of carrying on with missing values.

---

## `00-bootstrap.sh`: supporting infrastructure

This creates everything around your container. You don't build any of it by hand because the workshop is about containers, not networking or IAM.

| What it creates | Why |
|---|---|
| **Region / account lookup** | Uses your CLI's configured region (default `us-east-1`) and finds your account ID with `sts get-caller-identity`. The account ID is part of your ECR address. |
| **Default VPC + two public subnets** | Gives your containers a network to run in. An ALB must span at least two subnets in different Availability Zones. |
| **ECS cluster** (`ecs-worker-rush-cluster`) | A named group that your ECS service and tasks belong to. With Fargate, a cluster is just a label, so there are no servers to manage. |
| **CloudWatch log group** (`/workshop/ecs-worker-rush`) | Where your container's output (stdout/stderr) goes, so you can read logs without connecting to a machine. |
| **Task execution IAM role** | ECS assumes this role to pull your image from ECR and write logs to CloudWatch. It uses the AWS-managed `AmazonECSTaskExecutionRolePolicy`. The short `sleep` gives IAM time to finish creating the role before anything uses it. |
| **Two security groups** | *ALB SG*: allows port 8080 only from resources in the same group, which is why your game shell must be attached to it. *Task SG*: allows port 8080 only from the ALB. Your containers can't be reached directly, only through the load balancer. |
| **Internal Application Load Balancer** | A single, stable address that spreads requests across however many containers are running. It's `internal`, so it can't be reached from the internet. |

At the end, every ID is saved to `.workshop.env`, and the script prints the ALB's DNS name.

## `01-create-ecr.sh`: container registry

This creates a private **Amazon ECR repository** (`ecs-worker-rush-worker`) to store your Docker image. ECS can't pull an image from your laptop or CloudShell. It needs a registry it can reach.

- `scanOnPush=true` makes ECR scan each pushed image for known vulnerabilities, which is free and a good habit.
- It saves the repository URI (`<account>.dkr.ecr.<region>.amazonaws.com/<repo>`) to `.workshop.env`.

## `02-push-image.sh`: upload your image

Usage: `./scripts/02-push-image.sh [tag] [local-image]` (defaults: `v1`, `worker-rush:latest`).

1. **Log in:** `aws ecr get-login-password` gets a temporary token, which is passed to `docker login`. This lets Docker push to your private registry without storing long-lived credentials.
2. **Tag:** `docker tag` gives your local image its full ECR name plus a version tag (for example `…/ecs-worker-rush-worker:v1`). Docker uses the image's name to decide which registry to push to.
3. **Push:** `docker push` uploads the image layers.
4. Saves the full `IMAGE_URI` so the deploy step knows exactly which version to run.

Use a new tag for each change (`v2`, `v3`, …) so it's always clear which version ECS is running.

## `03-deploy-ecs.sh`: run it on Fargate

This connects the image to the load balancer and starts it.

1. **Target group:** the list of container IPs that the ALB sends traffic to. It's type `ip` because each Fargate task gets its own network interface and IP address. It checks `GET /health` every 10 s, and a container gets traffic only after two successful checks in a row.
2. **Listener:** tells the ALB to accept traffic on port 8080 and forward it to the target group.
3. **Task definition:** the blueprint for your container: which image, 0.25 vCPU / 0.5 GB memory, port 8080, `awsvpc` networking, the execution role, and where to send logs. Each run registers a new *revision*, so earlier versions are kept.
4. **Service:** keeps the requested number of copies (*tasks*) of the task definition running, replaces any that crash, and registers each task with the target group. The first run creates the service. Later runs update it to the new revision and force a fresh rollout. Deploys always start at **1 task**.
   - The tasks get public IPs only so they can download the image from ECR. Inbound traffic is still limited to the ALB by the task security group.
   - The 30 s health-check grace period gives a new container time to start before failed checks count against it.
5. Waits until the service is stable, meaning the requested number of tasks are running.

## `04-scale.sh`: change capacity by hand

Usage: `./scripts/04-scale.sh <0-4>`

This changes the service's **desired count**, the number of tasks ECS should keep running. ECS then starts or stops tasks to match. During the game, this is your main control.

- The value is checked against `MAX_TASKS` (4). Anything higher is rejected before AWS is called.
- New tasks aren't usable straight away. Each one has to be scheduled, pull the image, start, and pass two health checks before the ALB sends it traffic. Planning around that delay is the core skill in the game.

## `05-status.sh`: see what's really running

This prints two views of your service:

- **ECS view:** *desired* (what you asked for), *running* (containers started), *pending* (still starting), and the active task definition.
- **ALB view:** each target's health (`initial`, `healthy`, `draining`, …).

These numbers often differ, and that's the point. A task can be *running* in ECS but not yet *healthy* in the ALB, and only healthy tasks get requests.

## `99-cleanup.sh`: tear it all down

This deletes the workshop resources in reverse order of their dependencies. The service is scaled to 0 and deleted first, then the listener, target group and ALB, then the security groups (which can't be deleted while the ALB uses them), then the cluster, log group, ECR repository (including images) and IAM role. Finally it deletes `.workshop.env`.

Errors are ignored so cleanup always finishes as much as it can. AWS takes a short time to release some resources, so if a security group reports a "dependency" error, wait a minute and run the script again. Your default VPC and subnets are never touched.

---

## The game (`game/`)

### `run-game.sh`: runs a round

Usage: `./game/run-game.sh practice|scored`

1. Picks a random **seed** and prints it in scored mode. Running `GAME_SEED=<seed> ./game/run-game.sh scored` replays the same round.
2. Runs `round_plan.py` to write this round's load schedule.
3. Starts `monitor.py` in the background and **k6** in the foreground. Both run for the same length of time.
4. When both finish, runs `score.py`.

### `round_plan.py`: the round's schedule

This is the single source of truth for a round:

- The **load schedule**: how many requests per second to send, and when. Scored rounds are lightly randomised from the seed. Spike timing and height shift a little, but total load and overall shape stay the same, so no attendee gets an easier round.
- The **demand forecasts** shown by the monitor.
- The **theoretical max score** (what perfect, instant scaling would achieve).

### `game.js`: the load generator (k6)

This reads the schedule and sends `POST /job` requests through the ALB at the planned rate. It uses an *arrival-rate* pattern: requests keep arriving on schedule whether or not your workers keep up, just like real users. A worker that's busy replies `503`, which counts as a missed job.

### `monitor.py`: the live status line

Every 2 seconds, this:

- Calls ECS and the ALB to show **desired / running / healthy** counts (the same data as `05-status.sh`).
- Deducts **game credits** for each running task. These are game points, not AWS billing.
- Shows a **forecast** about 45 s before demand changes, so you have time to scale.
- **Enforces the cap:** if the service is ever set above 4 tasks (from the console or a raw CLI command, for example), the monitor sets it back to 4.
- After a **scored** round, scales the service to 0 so idle containers don't keep spending your AWS credit.

### `score.py`: the result

Combines k6's results with the monitor's credits:

```
score = completed jobs + 5 × credits left − missed jobs
```

It also prints the theoretical max and your **efficiency %**. Because each scored round is slightly different, compare efficiency % with other players rather than raw scores.
