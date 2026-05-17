# Fedora CoreOS lab — Immich on Wasabi S3

Local FCOS aarch64 VM running Immich. Photos stored in Wasabi S3 via rclone FUSE mount. Butane = source of truth.

## Layout

```
fcos-immich/
  README.md            # high-level: what it is, bootstrap, deploy paths
  CLAUDE.md            # this file: operator handbook, quirks, hardening
  .gitignore           # ignores qcow2/.ign/efi_vars/.env/rclone.conf/newt.env
  config.bu            # Butane source — single config of record
  config.ign           # transpiled Ignition (build artifact, gitignored)
  launch.sh            # qemu-system-aarch64 wrapper (local)
  oci-deploy.sh        # one-shot deploy to Oracle Cloud A1.Flex
  env.sh               # shell helpers (source it; portable via $FCOS_DIR)
  pristine.qcow2       # untouched FCOS disk; copied for each reset (gitignored)
  fedora-coreos-reset-qemu.aarch64.qcow2   # working disk (gitignored)
  efi_vars.fd          # UEFI vars (regenerated; gitignored)

  files/               # referenced by config.bu via `local: files/...`
    # --- secrets: REAL values are gitignored; .example variants are committed ---
    db.env / db.env.example                # postgres user + password
    server.env / server.env.example        # Immich DB_PASSWORD + TZ
    rclone.conf / rclone.conf.example      # Wasabi + Storj S3 creds
    newt.env / newt.env.example            # Pangolin/Newt tunnel creds (EnvironmentFile for newt.container)

    # --- container Quadlets ---
    immich.network                         # podman network
    immich-db.container                    # postgres (vectorchord, digest-pinned)
    immich-redis.container                 # valkey:9 (digest-pinned)
    immich-ml.container                    # ML (face/object)
    immich-server.container                # web/API, port 2283
    rclone-wasabi-immich.container         # FUSE mount of wasabi-immich → /mnt/wasabi-immich
    rclone-wasabi-immich-backup.container  # FUSE mount of wasabi-immich-backup
    newt.container                         # Pangolin tunnel (no inline secret; reads /etc/newt/newt.env)

    # --- systemd units / scripts ---
    fcos-backup.{sh,service,timer}         # nightly DB+config snapshot to wasabi-immich-backup, mirror to Storj
    storj-mirror.{sh,service,timer}        # rclone sync library/profile → Storj
    storj-prune.{sh,service,timer}         # delete Storj object versions older than 90d
    zram-setup.service                     # zram0 swap, zstd, 3G
    mkswap-var-swapfile.service            # idempotent 2G swapfile on /var
    var-swapfile.swap                      # mounts /var/swapfile
    swap-sysctl.conf                       # swappiness + vfs_cache_pressure tuning

    # --- misc config ---
    zincati-public.conf                    # tmpfiles fix for zincati socket dir
    disable-updates.toml                   # zincati on/off toggle
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

- FCOS pinned to **43.20260413.3.2** aarch64 stable (44.x had polkit regression)
- Postgres digest-pinned to vectorchord0.4.3
- Valkey digest-pinned to v9
- Immich server/ML use `:release` tag with `AutoUpdate=registry`
- `podman-auto-update.timer` enabled via Butane

Get latest stable: `curl -s https://builds.coreos.fedoraproject.org/streams/stable.json | jq -r '.architectures.aarch64.artifacts.qemu.release'`

## Service graph (boot order)

```
network-online.target
  ├─ rclone-wasabi-immich.service         (FUSE /mnt/wasabi-immich → Wasabi photos bucket)
  ├─ rclone-wasabi-immich-backup.service  (FUSE /mnt/wasabi-immich-backup → Wasabi backup bucket)
  ├─ immich-db.service                    (postgres on /var/srv/immich/db)
  ├─ immich-redis.service                 (valkey)
  ├─ immich-ml.service                    (gunicorn :3003)
  ├─ immich-server.service                (publishes 2283, /data = FUSE mount)
  └─ newt.service                         (Pangolin tunnel, host network, uses podman socket)

Timers (one-shot units fired on schedule):
  podman-auto-update.timer  → pulls newer registry digests, restarts updated containers
  fcos-backup.timer         → fcos-backup.sh: snapshot DB+config → wasabi-immich-backup, mirror to Storj
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
| **Stale FUSE mount after restart** | `ExecStartPre=-/usr/bin/umount -lR /mnt/wasabi-immich` before each start. |
| **Zincati `/run/zincati/public` missing** | tmpfiles.d entry creates it (`zincati-public.conf`). Otherwise zincati fails to bind metrics socket. |
| **Polkit on FCOS 44 aarch64** | "Lost the name PolicyKit1" loop kills zincati's rpm-ostree D-Bus calls. Workaround: stay on 43.x stable. |
| **Ignition runs once per disk** | Day-2 Butane changes require `fcos-reset && fcos-boot`. No way to re-run on existing disk. |
| **`/mnt` symlink** | FCOS symlinks `/mnt` → `/var/mnt`. `mount` shows `/var/mnt/wasabi-immich`. Both paths valid. |

## Secrets

`files/db.env`, `files/server.env`, `files/rclone.conf`, `files/newt.env` contain real credentials. These four files are **gitignored**; only their `.example` variants are committed. On a fresh clone:

```bash
for f in db.env server.env rclone.conf newt.env; do
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
| Update OS | Zincati auto (when enabled), `strategy=immediate` reboots when ready |
| Update containers | `podman-auto-update.timer` runs daily, restarts containers with newer registry digest |
| Inspect mount | `mount \| grep wasabi`, `sudo podman exec immich-server ls -la /data` |
| Force update check | `sudo systemctl restart zincati` |
| Skip update | drop `/etc/zincati/config.d/90-disable-updates.toml` with `enabled = false` |
| Force rclone reload | `sudo systemctl restart rclone-wasabi && sleep 5 && sudo systemctl restart immich-server` |
| Reach Immich | `http://<vm-ip>:2283` from LAN |

## Things to harden before prod

1. **Secrets** — current state: gitignored real files + committed `.example` templates. Next: encrypt env files (sops + age), decrypt at boot via systemd-creds. Rotate `NEWT_SECRET` (was committed inline in a previous revision; assume burned).
2. **TLS** — Caddy Quadlet in front, ACME via DNS challenge, drop `PublishPort=2283:2283`. Especially urgent if OCI public IP stays open.
3. **Backup encryption** — `fcos-backup.sh` tars `/etc/immich`, `/etc/rclone`, `/etc/containers/systemd` (incl. `newt.container`) into S3. Encrypt the tarball with `age` before upload.
4. **Backup authority** — own `pg_dump` Quadlet/timer instead of trusting Immich's internal dump (see Service graph note).
5. **Resource limits** — `Memory=` / `CPUQuota=` per container. ML eats ~3 GB of 6 GB host → OOM picks Postgres under pressure.
6. **Image digests** — `immich-server:release`, `immich-machine-learning:release`, `rclone:latest` are floating tags. Renovate-PR new digests; drop `AutoUpdate=registry` on already-pinned images (db, valkey) where it's a no-op.
7. **Storj sync safety** — `storj-mirror.sh` uses `sync` to bucket root with `--exclude` for sibling prefixes. A typo deletes Storj-side. Add `--max-delete 1000` cap.
8. **Observability** — Vector Quadlet → Loki/SigNoz; node_exporter.
9. **Update strategy** — `periodic` window or FleetLock for multi-node. (Zincati currently disabled to avoid FCOS 44 polkit regression.)
10. **Podman socket exposure** — `newt.container` bind-mounts `/run/podman/podman.sock` with `SecurityLabelDisable=true` → newt compromise = host compromise. Verify newt actually needs it, or isolate via rootless podman socket.
