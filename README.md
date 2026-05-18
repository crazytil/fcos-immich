# fcos-immich

Reproducible **Fedora CoreOS + Immich** appliance. Photos live in S3 (Wasabi) via an rclone FUSE mount; nightly mirror to Storj. One Butane config boots locally under QEMU or on Oracle Cloud A1.Flex unchanged — only the Ignition delivery differs.

```
                 ┌────────────────────── FCOS aarch64 VM ──────────────────────┐
                 │   immich-server :2283  ◄─── newt tunnel (optional)          │
                 │     │                                                        │
                 │     ├─ immich-db  (postgres + vectorchord, digest-pinned)    │
                 │     ├─ immich-redis (valkey)                                 │
                 │     ├─ immich-ml                                             │
                 │     └─ /data ─── rclone FUSE ─── Wasabi S3 (primary)         │
                 │                                                              │
                 │   nightly: pg_dump → wasabi-backup → rclone sync → Storj     │
                 └──────────────────────────────────────────────────────────────┘
```

## Quick start (local QEMU, macOS / Apple Silicon)

```bash
# 1. Clone
git clone https://github.com/crazytil/fcos-immich.git
cd fcos-immich

# 2. Fill in secrets (the *.example files are committed; real ones are gitignored)
for f in db.env server.env rclone.conf newt.env; do
  cp "files/$f.example" "files/$f"
done
# Edit each file. POSTGRES_PASSWORD in db.env must match DB_PASSWORD in server.env.
# newt.env is only needed if you want a Pangolin tunnel; otherwise leave defaults.

# 3. Replace the SSH key in config.bu (passwd.users[0].ssh_authorized_keys)

# 4. Download a base FCOS image and boot
source env.sh
coreos-installer download -s stable -p qemu -f qcow2.xz --decompress -a aarch64
mv fedora-coreos-*-qemu.aarch64.qcow2 pristine.qcow2
fcos-deploy && fcos-reset && fcos-boot
```

Inside the serial console, run `ip -br a` to find the VM IP. Then on the host:

```bash
fcos-ssh <vm-ip>
open http://<vm-ip>:2283
```

Container pulls add 2–5 minutes to the first boot. `journalctl -u immich-server -f` to watch.

## Deploy targets

| Target | How | Doc |
|--------|-----|-----|
| Local QEMU (Apple Silicon / aarch64 Linux) | `launch.sh` (vmnet-bridged, vmnet-shared, or SLIRP) | See above |
| Oracle Cloud A1.Flex (free tier eligible) | `./oci-deploy.sh` | [docs/deploy-oci.md](docs/deploy-oci.md) |
| Other clouds (AWS, GCP, Hetzner, …) | Same Butane → cloud-init / user-data | adapt `oci-deploy.sh` as template |

## Day-2 operations

Full operator handbook is in [`CLAUDE.md`](CLAUDE.md) (host quirks, networking, backup schedule, hardening checklist). Quick reference:

```bash
# Find what's running
sudo systemctl status immich-server rclone-wasabi-immich

# Force an OS update check
sudo systemctl restart zincati

# Hot-patch a Quadlet (config.bu is the source of truth — drift breaks reproducibility)
sudo $EDITOR /etc/containers/systemd/<name>.container
sudo systemctl daemon-reload && sudo systemctl restart <name>

# Restore from backup (manually pull from wasabi-immich-backup/db/{daily,weekly})
```

## Repo layout

| Path | Purpose |
|------|---------|
| `config.bu`              | **Butane source — single config of record.** All system state derives from here. |
| `files/`                 | Container Quadlets, systemd units, scripts, env-file templates |
| `launch.sh`              | `qemu-system-aarch64` wrapper for local boot |
| `oci-deploy.sh`          | Idempotent Oracle Cloud deploy (uploads image, launches instance) |
| `env.sh`                 | `source` for `fcos-deploy`, `fcos-boot`, `fcos-reset`, `fcos-ssh` helpers |
| `docs/`                  | Deployment walkthroughs |
| `CLAUDE.md`              | Operator handbook (also serves as Claude Code project memory) |

## Status

Personal homelab project. Functional but not yet production-hardened. Open items tracked in `CLAUDE.md` → *Things to harden before prod* (secret encryption, TLS termination, resource limits, observability).
