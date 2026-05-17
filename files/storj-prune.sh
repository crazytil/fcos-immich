#!/bin/bash
set -euo pipefail

exec /usr/bin/podman run --rm \
  --name storj-prune-run \
  -v /etc/rclone:/config:Z,ro \
  docker.io/rclone/rclone:latest \
  delete storj:immich \
  --config /config/rclone.conf \
  --s3-versions \
  --min-age 90d \
  --include '*-v????-??-??-??????-???*' \
  --stats 60s --stats-one-line \
  --log-level INFO
