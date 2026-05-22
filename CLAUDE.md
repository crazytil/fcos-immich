# Fedora CoreOS lab — Immich on Cloudflare R2

> This file is the **operator handbook** — the source of truth for how this lab is wired up, what each piece does, and how to keep it running. It also doubles as project memory for Claude Code (the filename is convention). For a higher-level overview see [`README.md`](README.md); for deploy walkthroughs see [`docs/`](docs/).

Local FCOS aarch64 VM running Immich. Photos stored in Cloudflare R2 (S3-compatible) via rclone FUSE mount. Butane = source of truth.

## Layout

```
fcos-immich/
  README.md            # high-level: what it is, bootstrap, deploy paths
  CLAUDE.md            # this file: operator handbook, quirks, hardening
  LICENSE              # MIT
  .gitignore           # ignores qcow2/.ign/efi_vars/.env/rclone.conf/newt.env
  config.bu            # Butane source — single config of record
  config.ign           # transpiled Ignition (build artifact, gitignored)
  launch.sh            # qemu-system-aarch64 wrapper (local)
  oci-deploy.sh        # one-shot deploy to Oracle Cloud A1.Flex
  env.sh               # shell helpers (source it; portable via $FCOS_DIR)
  pristine.qcow2       # untouched FCOS disk; copied for each reset (gitignored)
  fedora-coreos-reset-qemu.aarch64.qcow2   # working disk (gitignored)
  efi_vars.fd          # UEFI vars (regenerated; gitignored)

  docs/
    deploy-oci.md      # step-by-step Oracle Cloud A1.Flex deploy walkthrough
    troubleshooting.md # known issues + fixes (Ignition, FUSE, db init, zincati, …)

  files/               # referenced by config.bu via `local: files/...`
    # --- secrets: REAL values are gitignored; .example variants are committed ---
    db.env / db.env.example                # postgres user + password
    server.env / server.env.example        # Immich DB_PASSWORD + TZ
    rclone.conf / rclone.conf.example      # Cloudflare R2 + Storj S3 creds
    newt.env / newt.env.example            # Pangolin/Newt tunnel creds (EnvironmentFile for newt.container)
    Caddyfile / Caddyfile.example          # Caddy reverse-proxy config (ACME email + hostname)

    # --- container Quadlets ---
    immich.network                         # podman network
    immich-db.container                    # postgres (vectorchord, digest-pinned)
    immich-redis.container                 # valkey:9 (digest-pinned)
    immich-ml.container                    # ML (face/object)
    immich-server.container                # web/API, 2283 bound to loopback only
    caddy.container                        # reverse proxy :80/:443, Let's Encrypt auto-TLS
    rclone-immich-photos.container         # FUSE mount s3:photos-immich → /mnt/immich-photos
    rclone-immich-backup.container         # FUSE mount s3:backup-immich → /mnt/immich-backup
    newt.container                         # Pangolin tunnel (no inline secret; reads /etc/newt/newt.env)

    # --- systemd units / scripts ---
    fcos-backup.{sh,service,timer}         # nightly DB+config snapshot to immich-backup bucket, mirror to Storj
    storj-mirror.{sh,service,timer}        # rclone sync library/profile → Storj
    storj-prune.{sh,service,timer}         # delete Storj object versions older than 90d
    zram-setup.service                     # zram0 swap, zstd, 3G
    mkswap-var-swapfile.service            # idempotent 2G swapfile on /var
    var-swapfile.swap                      # mounts /var/swapfile
    swap-sysctl.conf                       # swappiness + vfs_cache_pressure tuning

    # --- misc config ---
    zincati-public.conf                    # tmpfiles fix for zincati socket dir
    zincati-updates.toml                   # zincati config: enabled, periodic 03:00 + 120 min
```

## Commands (after `source env.sh`)

| Cmd | What |
|-----|------|
| `butane …`              | docker-wrapped butane v0.27 with `--files-dir /pwd` |
| `coreos-installer …`    | docker-wrapped installer |
| `fcos-deploy`           | transpile config.bu → config.ign |
| `fcos-reset`            | wipe disks, copy pristine, grow to 40G (FCOS_DISK_SIZE override) |
| `fcos-boot`             | sudo launch qemu (vmnet-bridged on en0 by default) |
| `fcos-ssh <ip>`         | SSH as `core`, no host-key check |
| `fcos-help`             | print all of above |

Full cycle:
```
fcos-deploy && fcos-reset && fcos-boot
```

## Networking

`launch.sh` defaults to `FCOS_NET=bridged` on `en0` — VM gets DHCP from LAN router (192.168.1.x). Find IP inside VM with `ip -br a`.

Fallbacks:
- `FCOS_NET=user` — SLIRP, slow ~30 Mbit, host port-forward 2222→22
- `FCOS_NET=shared` — vmnet NAT, broken on macOS 26 due to Parallels bridges holding routes

`FCOS_IFNAME=en1 sudo ./launch.sh` to bridge a different interface.

## VM specs (launch.sh)

- 6144 MB RAM (Immich-ML needs ~3 GB)
- 2 vCPU (HVF accel)
- 40 GB disk (grown from pristine via qemu-img resize)
- UEFI: `/opt/homebrew/share/qemu/edk2-aarch64-code.fd` + per-VM vars file
- Ignition via `-fw_cfg name=opt/com.coreos/config,file=…`
- `-nographic` serial console (Ctrl-A X to quit)

## Image versions

- **FCOS** — tracks `stable` stream. Zincati enabled, periodic 03:00 + 120-min reboot window (`files/zincati-updates.toml`). Earlier 44.x aarch64 stable had a polkit regression that broke zincati's rpm-ostree D-Bus calls; verify the current stable boots cleanly before relying on auto-reboot on production hosts.
- **Postgres** — digest-pinned (vectorchord 0.4.3). No `AutoUpdate=` — bumping the digest is a manual Quadlet edit. Skipping the auto-update line avoids podman-auto-update's "tag and digest both specified" error (see `docs/troubleshooting.md`).
- **Valkey** — digest-pinned, same treatment as Postgres.
- **Immich server / Immich ML / rclone / newt / caddy** — floating tags (`:release`, `:latest`, `:2-alpine`) with `AutoUpdate=registry`. `podman-auto-update.timer` pulls newer registry digests nightly.

Get latest stable: `curl -s https://builds.coreos.fedoraproject.org/streams/stable.json | jq -r '.architectures.aarch64.artifacts.qemu.release'`

## Service graph (boot order)

```
network-online.target
  ├─ rclone-immich-photos.service         (FUSE /mnt/immich-photos → R2 photos-immich bucket)
  ├─ rclone-immich-backup.service         (FUSE /mnt/immich-backup → R2 backup-immich bucket)
  ├─ immich-db.service                    (postgres on /var/srv/immich/db)
  ├─ immich-redis.service                 (valkey)
  ├─ immich-ml.service                    (gunicorn :3003)
  ├─ immich-server.service                (127.0.0.1:2283, /data = /mnt/immich-photos FUSE, trusts RFC1918 proxies)
  ├─ caddy.service                        (reverse proxy :80/:443, ACME via HTTP-01, certs in /var/srv/caddy/data)
  └─ newt.service                         (Pangolin tunnel, host network, uses podman socket)

Timers (one-shot units fired on schedule):
  podman-auto-update.timer  → pulls newer registry digests, restarts updated containers
  fcos-backup.timer         → fcos-backup.sh: snapshot DB+config → R2 backup-immich, mirror to Storj
  storj-mirror.timer        → storj-mirror.sh: rclone sync library + profile to Storj
  storj-prune.timer         → storj-prune.sh: delete Storj object versions older than 90d
```

All units have `StartLimitIntervalSec=0` → retry forever, self-heal first boot.
Server uses `Wants=` (not `Requires=`) so rclone hiccup doesn't permanently fail server.

`fcos-backup.sh` consumes Immich's internal nightly DB dump from `/var/srv/immich/data/backups/immich-db-backup-*.sql.gz`. If Immich's job is disabled or broken, the script logs `WARNING: latest dump is Nh old` but still exits 0 — backup chain appears healthy but isn't. Audit periodically (or replace with an authoritative `pg_dump` Quadlet).

## Known quirks

| Thing | Detail |
|-------|--------|
| **macOS 26 + qemu vmnet** | `com.apple.vm.networking` is restricted entitlement. Adhoc-signed brew qemu can hold it (we re-signed). vmnet-shared broken because of Parallels bridges (`bridge100/101` holding 10.211.55/24 + 10.37.129/24 default routes). vmnet-bridged on en0 works. |
| **UTM sandbox** | App Sandbox blocks reading config.ign from `~/fcos`. Why we use standalone qemu instead. |
| **brew reinstall qemu** | Resets signing — re-add `com.apple.security.hypervisor` only (not vm.networking, which AMFI rejects). |
| **rclone FUSE in container** | Needs `AddDevice=/dev/fuse`, `AddCapability=SYS_ADMIN`, `SecurityLabelDisable=true`, mount as `:rshared`, plus `--allow-non-empty` (bind-mount makes target appear non-empty). |
| **Stale FUSE mount after restart** | `ExecStartPre=-/usr/bin/umount -lR /mnt/immich-photos` before each start. |
| **Zincati `/run/zincati/public` missing** | tmpfiles.d entry creates it (`zincati-public.conf`). Otherwise zincati fails to bind metrics socket. |
| **Polkit on FCOS 44 aarch64** | Earlier 44.x stable had a "Lost the name PolicyKit1" loop that killed zincati's rpm-ostree D-Bus calls. If you see it, set `enabled = false` in `zincati-updates.toml` and pin to a known-good qcow2 until upstream ships a fix. |
| **Ignition runs once per disk** | Day-2 Butane changes require `fcos-reset && fcos-boot`. No way to re-run on existing disk. |
| **`/mnt` symlink** | FCOS symlinks `/mnt` → `/var/mnt`. `mount` shows `/var/mnt/immich-photos`. Both paths valid. |

## Secrets

`files/db.env`, `files/server.env`, `files/rclone.conf`, `files/newt.env`, `files/Caddyfile` contain environment-specific values. These files are **gitignored**; only their `.example` variants are committed. `Caddyfile` is not strictly a secret but pins the public hostname + ACME email so it stays out of git. On a fresh clone:

```bash
for f in db.env server.env rclone.conf newt.env Caddyfile; do
  cp "files/$f.example" "files/$f"
done
# edit each one, then:
fcos-deploy && fcos-reset && fcos-boot
```

`POSTGRES_PASSWORD` in `db.env` must match `DB_PASSWORD` in `server.env`. `newt.env` is consumed via `EnvironmentFile=/etc/newt/newt.env` in `newt.container` — do not put the secret back inline.

Real prod path: sops-encrypted in git, decrypt via systemd-creds at boot. Or rotate to Pangolin-managed secrets / OCI Vault.

## Cloud port (Oracle Cloud target)

To deploy on OCI:
1. `coreos-installer download -p oraclecloud -f qcow2.xz --decompress -a aarch64`
2. Upload to OCI Object Storage
3. `oci compute image import from-object` → custom image
4. Launch `VM.Standard.A1.Flex` with `user_data = base64(config.ign)`
5. Same Butane works unchanged — only ignition delivery differs

Same Butane → AWS via EC2 user-data, GCP via instance metadata, Hetzner via `--user-data-from-file`.

## Daily ops

| Task | How |
|------|-----|
| Update OS | Zincati enabled, `strategy=periodic` — reboots inside 03:00 + 120-min window (`files/zincati-updates.toml`) |
| Update containers | `podman-auto-update.timer` runs daily, restarts containers with newer registry digest |
| Inspect mount | `mount \| grep immich-photos`, `sudo podman exec immich-server ls -la /data` |
| Force update check | `sudo systemctl restart zincati` |
| Pause OS updates | edit `/etc/zincati/config.d/90-zincati-updates.toml` → `enabled = false`, `sudo systemctl restart zincati` |
| Force rclone reload | `sudo systemctl restart rclone-immich-photos && sleep 5 && sudo systemctl restart immich-server` |
| Reach Immich | `http://<vm-ip>:2283` from LAN |

## Things to harden before prod

1. **Secrets** — current state: gitignored real files + committed `.example` templates. Next: encrypt env files (sops + age), decrypt at boot via systemd-creds. Rotate `NEWT_SECRET` (was committed inline in a previous revision; assume burned).
2. **TLS** — done: Caddy Quadlet terminates TLS on :443, HTTP-01 ACME via Let's Encrypt. `immich-server` published only to `127.0.0.1:2283` so loopback (newt) + the immich podman network (caddy) can reach it; external direct hits to :2283 blocked at the host. To harden further: switch to DNS-01 challenge so port 80 can be closed.
3. **Backup encryption** — `fcos-backup.sh` tars `/etc/immich`, `/etc/rclone`, `/etc/containers/systemd` (incl. `newt.container`) into S3. Encrypt the tarball with `age` before upload.
4. **Backup authority** — own `pg_dump` Quadlet/timer instead of trusting Immich's internal dump (see Service graph note).
5. **Resource limits** — `Memory=` / `CPUQuota=` per container. ML eats ~3 GB of 6 GB host → OOM picks Postgres under pressure.
6. **Image digests** — `immich-server:release`, `immich-machine-learning:release`, `rclone:latest`, `newt:latest` are floating tags. Renovate-PR them to digests when stability matters more than fresh patches. db + valkey already digest-pinned, `AutoUpdate=registry` dropped to silence the "tag+digest unsupported" auto-update error.
7. **Storj sync safety** — `storj-mirror.sh` uses `sync` to bucket root with `--exclude` for sibling prefixes. A typo deletes Storj-side. Add `--max-delete 1000` cap.
8. **Observability** — Vector Quadlet → Loki/SigNoz; node_exporter.
9. **Update strategy** — currently Zincati `periodic` window 03:00 + 120 min, single-node. For multi-node, switch to FleetLock so peers don't reboot together.
10. **Podman socket exposure** — `newt.container` bind-mounts `/run/podman/podman.sock` with `SecurityLabelDisable=true` → newt compromise = host compromise. Verify newt actually needs it, or isolate via rootless podman socket.
