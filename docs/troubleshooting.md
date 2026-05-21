# Troubleshooting

Real issues hit while running this config. Quick fixes first, root causes second.

## Boot won't start / Ignition not applied

**Symptom:** VM boots to a stock FCOS prompt with no users, no containers.

`config.ign` wasn't passed to the VM, or the disk was already first-booted (Ignition runs **once per disk** — re-running with the same qcow2 is a no-op).

- Local QEMU: confirm `-fw_cfg name=opt/com.coreos/config,file=$IGN` in `launch.sh` resolves. Run `fcos-reset` to clone `pristine.qcow2` again.
- OCI: confirm `oci-deploy.sh` ran `base64 config.ign | tr -d '\n'` and passed it as `user_data`. Console → Instance → Metadata to verify.

To re-apply Butane changes, you must wipe the boot disk (`fcos-reset` locally; terminate + recreate on OCI).

## `podman-auto-update.service` exits 125 nightly

**Symptom:** `journalctl -u podman-auto-update` shows:

```
checking image updates for container …: Docker references with both a tag and digest are currently not supported
```

A Quadlet `Image=foo:tag@sha256:…` mixes a tag and a digest. podman-auto-update refuses to inspect it and fails the whole run.

Either pin to digest only (drop the tag) or drop `AutoUpdate=registry` from the container (since a digest-only ref can never auto-update anyway — by definition the digest is the version). On this repo we keep `:tag@sha256:…` for human-readability and just omit `AutoUpdate=registry` on db/redis. Floating-tag containers (`:release`, `:latest`) still auto-update.

## rclone FUSE mount won't come up

**Symptom:** `immich-server` errors with "ENOENT /data/…", `mount | grep immich-photos` returns nothing.

Common causes:

1. **Stale mount left by a previous crash.** `rclone-immich-photos.service` has `ExecStartPre=-/usr/bin/umount -lR /mnt/immich-photos` to handle this; if it's missing, `sudo umount -lR /mnt/immich-photos && sudo systemctl restart rclone-immich-photos`.
2. **Missing FUSE caps.** Container needs `AddDevice=/dev/fuse`, `AddCapability=SYS_ADMIN`, `SecurityLabelDisable=true`. Lose any of these and rclone can't mount.
3. **Bad rclone.conf.** `sudo podman exec rclone-immich-photos rclone --config /config/rclone.conf lsd s3:` should list buckets. If it errors, the config or credentials are wrong.
4. **R2 outage or bucket gone.** `journalctl -u rclone-immich-photos -n 50` will say so.

After fixing rclone, restart Immich so it re-sees `/data`:

```bash
sudo systemctl restart rclone-immich-photos
sleep 5
sudo systemctl restart immich-server
```

## Immich DB won't start

**Symptom:** `immich-db` is restarting in a loop; `immich-server` waits forever.

- **Wrong password.** `POSTGRES_PASSWORD` in `db.env` and `DB_PASSWORD` in `server.env` must match exactly. Postgres init also bakes the password into the data dir on first run — if you change the password later, you have to either reset it inside postgres or wipe `/var/srv/immich/db` (destroys data).
- **Data dir owned by wrong user.** `/var/srv/immich/db` must be writable by uid `999` inside the container. Butane creates it `0700` owned by root; postgres `initdb` chowns to its own user on first run. Don't `chmod 777` it — postgres refuses to start.
- **Disk full.** `df -h /var`. If full, prune `podman system prune -a` and rotate logs.

## `zincati` not updating

**Symptom:** `rpm-ostree status` shows an old version, `systemctl status zincati` says "no updates available" forever.

- Verify channel: `cat /etc/zincati/config.d/*.toml`. We set `strategy = "periodic"` with a 03:00 + 120 min window. Outside that window, even a pending update sits idle.
- Force a check: `sudo systemctl restart zincati && journalctl -u zincati -f`.
- Cincinnati graph dead-end: every FCOS release eventually gets superseded; if you're on a "dead-end" release the log says so explicitly. Resolution = re-deploy from a fresh qcow2.
- FCOS 44.x aarch64 had a polkit regression that broke zincati's rpm-ostree D-Bus calls. Fixed upstream by 2026-05; if you hit it again, set `enabled = false` in `zincati-updates.toml` until a known-good release lands.

## newt tunnel down

**Symptom:** Pangolin shows the resource as offline.

Most common: `NEWT_ID` / `NEWT_SECRET` rotated at the Pangolin server but `files/newt.env` wasn't updated.

```bash
# Verify what's actually in effect
sudo cat /etc/newt/newt.env

# Generate new credentials in Pangolin, then:
sudo $EDITOR /etc/newt/newt.env       # update both lines
sudo systemctl restart newt
journalctl -u newt -f                 # expect "Tunnel connection to server established successfully!"
```

If `Network=host` was changed to a bridge, newt loses access to localhost-bound services. Set it back.

## Backup script "WARNING: latest dump is Nh old"

**Symptom:** `fcos-backup.service` runs but logs that the source dump is stale.

The script copies Immich's *internal* nightly DB dump (`/var/srv/immich/data/backups/immich-db-backup-*.sql.gz`). If Immich's backup job is disabled or broken, this warning fires — but the script still exits 0, so the systemd timer looks green.

Check inside Immich: Admin → Backups → ensure "Database Backup" is enabled, schedule is daily. Or, replace the read-then-copy with a real `pg_dump` Quadlet — listed in `CLAUDE.md` → *Things to harden before prod*.

## Container running, can't reach :2283

**Symptom:** `systemctl status immich-server` is active, `curl http://localhost:2283` works on the VM, but the LAN/Internet can't reach it.

- **Local VM:** check `FCOS_NET=` — only `bridged` or `shared` give the VM an LAN-reachable address. `user` (SLIRP) means SSH on host port 2222 and HTTP only via the host.
- **OCI:** Security list. By default the VCN wizard opens only 22. Add an Ingress rule for TCP 2283 (or, better, terminate TLS in front and keep 2283 closed).
- Inside the VM, `sudo ss -tlnp | grep 2283` confirms the container is listening on the host port.

## "command not found: fcos-deploy"

You haven't sourced `env.sh` in this shell. The helpers are functions, not on `$PATH`:

```bash
source env.sh
```

Re-source after editing `env.sh` itself.

## Lost the SSH key

You can't SSH in, but the VM is otherwise fine.

- **Local QEMU:** boot to serial console (`fcos-boot` shows it), `Ctrl-A X` exits. Edit `~core/.ssh/authorized_keys` from the console.
- **OCI:** no serial console by default. Either (a) enable serial console in the instance settings, or (b) terminate + redeploy with a new key in `config.bu`. The DB volume gets wiped — restore from R2 `backup-immich/db/daily/`.

Avoid this by adding a second recovery key to `config.bu` before first boot.
