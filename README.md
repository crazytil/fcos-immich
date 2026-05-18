# fcos-immich

Reproducible Fedora CoreOS + Immich appliance. Photos live in **Wasabi S3** via rclone FUSE; second offsite mirror to **Storj**. Postgres + config back up nightly. Same Butane config boots locally under QEMU (Apple Silicon, aarch64) or on Oracle Cloud A1.Flex — only the Ignition delivery differs.

```
                 ┌──────────────────────────────────────────────────────┐
                 │  Fedora CoreOS VM (aarch64, 6 GB RAM, 40 GB root)    │
                 │                                                      │
                 │  podman Quadlets, started by systemd:                │
                 │    immich-db (postgres + vectorchord, digest-pinned) │
                 │    immich-redis (valkey, digest-pinned)              │
                 │    immich-ml (face/object recognition)               │
                 │    immich-server  ── publishes :2283 ──►  LAN        │
                 │    rclone-wasabi-immich         FUSE → /data         │
                 │    rclone-wasabi-immich-backup  FUSE → DB backup     │
                 │    newt (Pangolin tunnel)                            │
                 │                                                      │
                 │  Timers: podman-auto-update, fcos-backup,            │
                 │          storj-mirror, storj-prune                   │
                 └──────────────────────────────────────────────────────┘
                          │                      │
                          ▼                      ▼
                   Wasabi S3 (primary)    Storj S3 (offsite mirror)
```

## Layout

| Path | Purpose |
|------|---------|
| `config.bu`                 | Butane source — single config of record |
| `env.sh`                    | Shell helpers (`fcos-deploy`, `fcos-boot`, `fcos-reset`, `fcos-ssh`). `source` it. |
| `launch.sh`                 | `qemu-system-aarch64` wrapper (vmnet-bridged, vmnet-shared, or SLIRP) |
| `oci-deploy.sh`             | One-shot deploy to Oracle Cloud A1.Flex |
| `files/*.container`         | podman Quadlets (db, redis, ML, server, rclone mounts, newt) |
| `files/*.service`, `*.timer`| systemd units for backups, swap, zram |
| `files/*.sh`                | Backup + Storj mirror/prune scripts |
| `files/*.env.example`       | Templates — copy + fill in real secrets before `fcos-deploy` |
| `files/rclone.conf.example` | Same — rclone remotes for Wasabi + Storj |
| `CLAUDE.md`                 | Operator handbook: quirks, networking, daily ops, hardening checklist |

## Prerequisites

| Tool | Why | Install |
|------|-----|---------|
| Docker (or compat)    | Runs Butane + coreos-installer containers | https://docs.docker.com/get-docker/ |
| QEMU (`qemu-system-aarch64`) | Local VM. macOS: `brew install qemu` + entitlements (see CLAUDE.md). Linux: distro package. | — |
| `jq`, `curl`          | Used by helpers | — |
| `oci-cli` (optional)  | Needed only for `oci-deploy.sh` | `brew install oci-cli` |

You also need an **SSH key** added to `config.bu` (`passwd.users[0].ssh_authorized_keys`). The repo ships with a key — replace it with yours before first boot.

## Bootstrap (fresh clone)

```bash
git clone git@github.com:crazytil/fcos-immich.git
cd fcos-immich

# 1. Fill in secrets (the *.example variants are committed; real ones are gitignored)
cp files/db.env.example      files/db.env
cp files/server.env.example  files/server.env
cp files/rclone.conf.example files/rclone.conf
cp files/newt.env.example    files/newt.env

# Edit each — match POSTGRES_PASSWORD in db.env with DB_PASSWORD in server.env.

# 2. Replace SSH key in config.bu (passwd.users[0].ssh_authorized_keys)

# 3. Download the FCOS aarch64 stable QEMU image
#    (Zincati is enabled in the Butane config and will auto-upgrade past this
#     base image on a 03:00 + 120-min window. See CLAUDE.md for the 44.x
#     aarch64 polkit caveat — verify the current stable boots cleanly.)
source env.sh
coreos-installer download -s stable -p qemu -f qcow2.xz --decompress -a aarch64
mv fedora-coreos-*-qemu.aarch64.qcow2 pristine.qcow2
```

## Run locally (Apple Silicon / aarch64)

```bash
source env.sh
fcos-deploy   # config.bu  ->  config.ign
fcos-reset    # clone pristine.qcow2, grow disk to 40 G
fcos-boot     # sudo qemu, vmnet-bridged on en0

# Find the VM IP from inside the serial console:
ip -br a

# Then on the host:
fcos-ssh <vm-ip>
open http://<vm-ip>:2283
```

Container pulls add ~2–5 min to first boot. `journalctl -u immich-server -f` to watch.

### Fallback networking

```bash
FCOS_NET=user sudo ./launch.sh         # SLIRP, slow, host port 2222 -> 22
FCOS_IFNAME=en1 sudo ./launch.sh        # bridge a different interface
```

## Deploy to Oracle Cloud (A1.Flex aarch64, free tier)

```bash
# One-time prep (Console + CLI):
#  1. brew install oci-cli && oci session authenticate
#  2. Create a VCN + subnet in your compartment (Console "VCN Wizard")
#  3. Download the OCI-flavoured qcow2 and upload it to a bucket:
coreos-installer download -p oraclecloud -f qcow2.xz --decompress -a aarch64
oci os object put -bn fcos --file fedora-coreos-*-oraclecloud.aarch64.qcow2 \
                  --name fcos-latest.qcow2

# Then:
./oci-deploy.sh
```

The script regenerates Ignition from `config.bu`, imports the qcow2 as a custom image (idempotent), launches a 1-OCPU / 6-GB / 50-GB A1.Flex instance, and prints the public IP. Same Butane works unchanged on AWS (EC2 user-data), GCP (instance metadata), Hetzner (`--user-data-from-file`).

⚠️ The instance comes up with a public IP and Immich on `:2283` cleartext. Lock the security list to your IP, or put TLS in front (see “Harden before prod” in `CLAUDE.md`) before opening it up.

## Day-2 ops

| Task | How |
|------|-----|
| Update OS                  | Zincati enabled, `strategy=periodic` 03:00 + 120-min window (`files/zincati-updates.toml`). Watch for the 44.x polkit regression on aarch64 — see `CLAUDE.md`. |
| Update containers          | `podman-auto-update.timer` runs nightly. `:release`-tagged images update silently. |
| Force update check         | `sudo systemctl restart zincati` |
| Inspect FUSE mount         | `mount \| grep wasabi` &nbsp;·&nbsp; `sudo podman exec immich-server ls -la /data` |
| Reload rclone              | `sudo systemctl restart rclone-wasabi-immich && sleep 5 && sudo systemctl restart immich-server` |
| Re-apply config changes    | Ignition runs **once per disk**. `fcos-deploy && fcos-reset && fcos-boot` |
| Daily backup target        | `/mnt/wasabi-immich-backup/db/daily/YYYY-MM-DD.sql.gz`, weekly archive on Sundays |
| Storj mirror cadence       | `storj-mirror.timer` (library + profile), `storj-prune.timer` (90-day version retention) |

Detailed quirks, networking caveats, and image-pin rationale: see [`CLAUDE.md`](CLAUDE.md).

## Adapting it

- **Different photo backend**: replace `[wasabi]` in `rclone.conf` with any rclone-supported provider; only the `Exec=mount` line in `files/rclone-wasabi-immich.container` references it by remote name.
- **Different host**: swap `launch.sh` for any cloud-init/Ignition delivery (`oci-deploy.sh` is one example).
- **More photos**: bump `--vfs-cache-max-size 20G` in `rclone-wasabi-immich.container` and the host disk size (`FCOS_DISK_SIZE=80G fcos-reset`).
- **Behind TLS**: drop a `caddy.container` Quadlet + ACME DNS challenge in front of `immich-server`; remove the `PublishPort=2283:2283` line and have Caddy be the only exposed port.

## Status

Personal lab — not yet hardened for prod. Open items tracked in `CLAUDE.md` → "Things to harden before prod" (secret encryption, TLS, resource limits, digest-pinning of `:release` tags, observability).
