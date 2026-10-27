---
inclusion: always
---
# Workshop context
This is a beginner containerization workshop focused on Docker, Amazon ECR, and Amazon ECS/Fargate. Networking, IAM, and load-generation infrastructure are supporting details. Preserve the /health and /job API contracts and keep the worker stateless.

- The Dockerfile goes at worker/Dockerfile. Do not modify worker/app.py, scripts/, or game/.
- The local image must be tagged worker-rush:latest, because scripts/02-push-image.sh expects that name.
- Verify with:
  - `docker build --platform linux/amd64 -t worker-rush:latest ./worker`
  - `docker run --rm -p 8080:8080 worker-rush:latest`, then GET http://localhost:8080/health
- Explain the important Dockerfile instructions in beginner-friendly terms after creating it.
