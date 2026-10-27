---
inclusion: always
---
# Container requirements
Create worker/Dockerfile for worker/app.py suitable for Amazon ECS on AWS Fargate.
- Use Python 3.13 slim.
- Build for Linux/amd64. `FROM --platform=linux/amd64` is acceptable; Fargate runs X86_64 here, so an arm64 image (for example from Apple Silicon) will fail.
- The build context will be the worker directory, so COPY paths are relative to it. Use WORKDIR /app.
- Order layers for caching: COPY requirements.txt and install it first, then COPY app.py.
- Copy only requirements.txt and app.py. Do not copy the whole repo, game/, or scripts/.
- Install worker/requirements.txt with `pip install --no-cache-dir`. Wheels are available, so do not install apt packages or build tools.
- Set PYTHONUNBUFFERED=1 and PYTHONDONTWRITEBYTECODE=1 (logs go to CloudWatch via awslogs).
- Run as a non-root user with a numeric UID (for example 10001). Switch with USER after installing and copying.
- Listen on TCP port 8080 (EXPOSE 8080).
- Start with the exec (JSON array) form so uvicorn receives SIGTERM when ECS stops the task: ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
- Do not add a Docker HEALTHCHECK. The load balancer checks /health, and the slim image has no curl.
- Do not hardcode MAX_CONCURRENCY or WORK_MS; they are optional runtime settings with defaults in app.py.
- Keep the image small and do not place credentials or AWS configuration in the image.
- Also create worker/.dockerignore excluding __pycache__, *.pyc, and .env.
