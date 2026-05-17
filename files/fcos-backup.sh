#!/bin/bash
set -euo pipefail

SRC=/var/srv/immich/data/backups
DST=/mnt/wasabi-immich-backup
DATE=$(date +%F)
WEEK=$(date +%G-W%V)
DOW=$(date +%u)

mountpoint -q "$DST" || { echo "backup mount not ready: $DST" >&2; exit 1; }

mkdir -p "$DST/db/daily" "$DST/db/weekly" "$DST/config"

LATEST=$(ls -t "$SRC"/immich-db-backup-*.sql.gz 2>/dev/null | head -1 || true)
if [ -z "$LATEST" ]; then
  echo "no Immich DB dump found in $SRC" >&2
  exit 1
fi

AGE_HOURS=$(( ( $(date +%s) - $(stat -c %Y "$LATEST") ) / 3600 ))
if [ "$AGE_HOURS" -gt 25 ]; then
  echo "WARNING: latest dump is ${AGE_HOURS}h old, Immich nightly may be broken" >&2
fi

cp -f "$LATEST" "$DST/db/daily/${DATE}.sql.gz.tmp"
mv -f "$DST/db/daily/${DATE}.sql.gz.tmp" "$DST/db/daily/${DATE}.sql.gz"

if [ "$DOW" = "7" ]; then
  cp -f "$LATEST" "$DST/db/weekly/${WEEK}.sql.gz.tmp"
  mv -f "$DST/db/weekly/${WEEK}.sql.gz.tmp" "$DST/db/weekly/${WEEK}.sql.gz"
fi

tar -czf "$DST/config/${DATE}.tar.gz.tmp" \
  -C / etc/immich etc/rclone etc/containers/systemd
mv -f "$DST/config/${DATE}.tar.gz.tmp" "$DST/config/${DATE}.tar.gz"

prune_keep_newest() {
  local dir=$1 keep=$2
  ls -1 "$dir" 2>/dev/null | grep -v '\.tmp$' | sort -r | tail -n +"$((keep+1))" | \
    while read -r f; do rm -f "$dir/$f"; done
}

prune_keep_newest "$DST/db/daily"  7
prune_keep_newest "$DST/db/weekly" 4
prune_keep_newest "$DST/config"    7

# Mirror DB + config tree to Storj as second offsite (storj:immich/backup/)
/usr/bin/podman run --rm \
  --name fcos-backup-storj \
  -v /etc/rclone:/config:Z,ro \
  -v "$DST":/src:ro,Z \
  docker.io/rclone/rclone:latest \
  sync /src storj:immich/backup \
  --config /config/rclone.conf \
  --fast-list --size-only --no-update-modtime \
  --transfers 8 --checkers 16 \
  --stats 60s --stats-one-line \
  --log-level INFO || echo "WARNING: Storj backup mirror failed" >&2

echo "backup ok: ${DATE} (dump age ${AGE_HOURS}h)"
