# Game runner: k6 load generator + monitor + scorer. Runs as a Fargate task inside the VPC
# so it can reach the internal ALB. Attendees never build or edit this image.
FROM python:3.13-slim

# k6 is a single static binary; copy it from the official image instead of installing apt packages.
COPY --from=grafana/k6:0.54.0 /usr/bin/k6 /usr/local/bin/k6
RUN pip install --no-cache-dir awscli

ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1

# run-game.sh finds its siblings relative to /app, so keep the game/ directory name.
WORKDIR /app/game
COPY --chmod=755 run-game.sh ./
COPY round_plan.py monitor.py score.py game.js ./

RUN useradd --uid 10001 --no-create-home game
USER 10001

# Mode is the container command: practice (default) or scored.
ENTRYPOINT ["/app/game/run-game.sh"]
CMD ["practice"]
