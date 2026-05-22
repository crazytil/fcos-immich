# Deploying to Oracle Cloud (A1.Flex aarch64)

Walkthrough for `oci-deploy.sh`. Aim: a free-tier eligible A1.Flex instance running the same Butane config you'd boot locally.

## Why A1.Flex

- aarch64 (Ampere Altra) — matches the local-dev target so the same Butane image works.
- Free-tier covers up to 4 OCPU + 24 GB RAM and 200 GB block storage across one or more A1.Flex instances.
- `oci-deploy.sh` provisions 1 OCPU / 6 GB / 50 GB by default; bump if you have headroom.

## One-time prerequisites

### 1. Install and authenticate oci-cli

```bash
brew install oci-cli                            # macOS; see docs for Linux
oci session authenticate --profile-name DEFAULT # opens browser, picks tenancy + region
```

The deploy script uses `OCI_CLI_AUTH=security_token` + `OCI_CLI_PROFILE=DEFAULT`. Change those env exports in `oci-deploy.sh` if you use a different auth flow (resource principal, instance principal).

### 2. Make sure you have a VCN with a subnet

Console → Networking → Virtual Cloud Networks → **Start VCN Wizard** → *Create VCN with Internet Connectivity*. Accept defaults — this is enough for a single public-IP host.

The script picks `data[0].id` from `oci network subnet list -c $COMP`, i.e. the first subnet in the compartment. If you have multiple, narrow the query.

### 3. Upload the FCOS image to Object Storage

```bash
# Download the OCI-flavoured qcow2 (NOT the qemu one)
coreos-installer download -p oraclecloud -f qcow2.xz --decompress -a aarch64

# Create a bucket called "fcos" in your default compartment (Console or CLI)
oci os bucket create -c $(oci iam compartment list --query 'data[0]."compartment-id"' --raw-output) --name fcos

# Upload, naming the object "fcos-latest.qcow2" (the script looks for this exact name)
oci os object put -bn fcos --file fedora-coreos-*-oraclecloud.aarch64.qcow2 --name fcos-latest.qcow2
```

You only need to redo this when you want to track a newer base image — Zincati handles ongoing OS updates on a running instance.

## Deploy

```bash
./oci-deploy.sh
```

What the script does (idempotent — safe to re-run):

1. Sources `env.sh` and regenerates `config.ign` from `config.bu`.
2. Resolves OCIDs: compartment (root by default), availability domain (first AD), subnet (first in compartment), object storage namespace.
3. Imports the qcow2 from `oci://<ns>/fcos/fcos-latest.qcow2` as a custom image named `fcos-aarch64`, mode `NATIVE` / `UEFI_64`, OS = "Fedora CoreOS" / stable. Skipped if the image already exists.
4. Adds A1.Flex shape compatibility (1–4 OCPU, 6–24 GB) to the custom image. Skipped if already present.
5. Base64-encodes `config.ign` into a metadata file and launches an instance named `immich-fcos` with `VM.Standard.A1.Flex` shape, 1 OCPU / 6 GB / 50 GB boot, public IP, the Ignition payload as `user_data`.
6. Waits for state RUNNING, prints the instance OCID + public IP.

Boot to "Immich responding on :2283" takes 2–5 min after RUNNING (container pulls).

```bash
ssh core@<public-ip>
journalctl -u immich-server -f
```

## Network: open the right ports

By default the script does not edit the VCN security list. `:2283` is **not reachable** until you open it. Two options:

- **Quick & dirty (lab)**: Console → VCN → default security list → add an Ingress rule for `0.0.0.0/0` TCP `2283`. Cleartext over the public Internet — only acceptable while you bring TLS up.
- **Recommended**: keep `:2283` closed, terminate TLS in front. Either Caddy as another Quadlet inside the VM (ACME via DNS-01), or use the Pangolin/newt tunnel that's already wired up (`files/newt.container` + `files/newt.env`).

## Customising

| Variable | Default | What |
|----------|---------|------|
| `COMPARTMENT_NAME` | `root` | OCI compartment for image + instance |
| `BUCKET` / `OBJECT` | `fcos` / `fcos-latest.qcow2` | Object storage source of the qcow2 |
| `IMAGE_NAME` | `fcos-aarch64` | Custom image display name |
| `INSTANCE_NAME` | `immich-fcos` | Instance display name |
| `SHAPE` | `VM.Standard.A1.Flex` | Compute shape |
| `OCPUS` / `MEMORY_GB` / `BOOT_GB` | `1` / `6` / `50` | Shape config |

Edit the variables block at the top of `oci-deploy.sh`.

## Update an existing instance

Ignition runs **once per disk**. Changing `config.bu` and re-running `oci-deploy.sh` does not re-apply config to a running host — it only takes effect on the next instance you create.

For day-2 changes:

1. **Drift-aware hot patch** — write the new Quadlet to `/etc/containers/systemd/<name>.container`, `daemon-reload`, `restart`. Edit the Butane source in this repo too so the next provisioned instance picks it up.
2. **Full rebuild** — terminate the instance, re-run `oci-deploy.sh`. Boot volume is wiped (so DB is wiped). Restore from `/mnt/immich-backup/db/daily/*.sql.gz` after first boot.

The hot-patch route is what `CLAUDE.md` recommends for routine changes. Rebuild only when the host has drifted past comprehension or you want a clean baseline.

## Adapting to other clouds

`oci-deploy.sh` is just a wrapper around "build Ignition → upload it as instance metadata". The same Butane works on:

- **AWS EC2**: `aws ec2 run-instances --user-data file://config.ign` (Nitro arm64 instance type, FCOS AMI from CoreOS image stream)
- **GCP**: instance metadata key `user-data`, value = `config.ign` contents
- **Hetzner**: `hcloud server create --user-data-from-file config.ign`
- **Anywhere with cloud-init/Ignition**: same payload, different delivery
