#!/bin/bash
set -euo pipefail

run_sync() {
  local src=$1 dst=$2 name=$3
  shift 3
  echo ">>> mirror $src -> $dst"
  /usr/bin/podman run --rm \
    --name "storj-mirror-run-$name" \
    -v /etc/rclone:/config:Z,ro \
    docker.io/rclone/rclone:latest \
    sync "$src" "$dst" \
    --config /config/rclone.conf \
    --fast-list \
    --size-only \
    --no-update-modtime \
    --exclude '.immich' \
    --transfers 16 \
    --checkers 32 \
    --stats 60s --stats-one-line \
    --log-level INFO \
    "$@"
}

# library/ mirrors to bucket ROOT (Lana/, Tilian/, ...). Must exclude sibling
# top-level prefixes that other jobs manage, or sync will wipe them.
run_sync s3:photos-immich/library storj:immich library \
  --exclude '/backup/**' \
  --exclude '/profile/**'

run_sync s3:photos-immich/profile storj:immich/profile profile
