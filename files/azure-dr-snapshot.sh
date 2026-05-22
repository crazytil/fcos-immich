#!/bin/bash
set -euo pipefail

# Azure Blob DR snapshot (Cool tier, 3rd copy after R2 primary + Storj mirror).
# copy ONLY — never sync, never delete. Source deletions do NOT propagate.
#   photos: incremental copy to a single prefix. Photos are write-once, so copy
#           skips existing files -> only new uploads -> natural dedup, no churn fees.
#   db:     dated snapshot -> point-in-time for logical-corruption recovery.

DATE="$(date +%Y-%m)"
RCLONE="docker.io/rclone/rclone:latest"

echo ">>> photos -> azure-dr:immich-dr/photos (incremental copy, never deletes)"
/usr/bin/podman run --rm --name azure-dr-photos \
  -v /etc/rclone:/config:Z,ro \
  "$RCLONE" \
  copy s3:photos-immich/library azure-dr:immich-dr/photos \
  --config /config/rclone.conf \
  --fast-list --size-only --no-update-modtime \
  --exclude '.immich' \
  --transfers 16 --checkers 32 \
  --stats 60s --stats-one-line --log-level INFO

echo ">>> db -> azure-dr:immich-dr/db/$DATE (dated snapshot)"
/usr/bin/podman run --rm --name azure-dr-db \
  -v /etc/rclone:/config:Z,ro \
  -v /var/srv/immich/data/backups:/backups:Z,ro \
  "$RCLONE" \
  copy /backups "azure-dr:immich-dr/db/$DATE" \
  --config /config/rclone.conf \
  --fast-list --transfers 4 \
  --stats 60s --stats-one-line --log-level INFO
