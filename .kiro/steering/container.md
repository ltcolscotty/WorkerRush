---
inclusion: always
---
# Container requirements
Create a Dockerfile for worker/app.py suitable for Amazon ECS on AWS Fargate.
- Use Python 3.13 slim.
- Build for Linux/amd64.
- Install worker/requirements.txt without pip cache.
- Run as a non-root user.
- Listen on TCP port 8080.
- Start with: uvicorn app:app --host 0.0.0.0 --port 8080
- Keep the image small and do not place credentials or AWS configuration in the image.
- The build context will be the worker directory.
