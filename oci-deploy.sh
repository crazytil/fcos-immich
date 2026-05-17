#!/usr/bin/env bash
# Deploy FCOS+Immich to Oracle Cloud (aarch64, A1.Flex).
# Idempotent: re-imports image only if missing, only adds shape compat if missing.
#
# Prereqs (one-time):
#   - oci-cli installed: brew install oci-cli
#   - oci session active: oci session authenticate --profile-name DEFAULT
#   - VCN+subnet exist in target compartment (Console VCN wizard)
#   - FCOS oraclecloud qcow2 uploaded to Object Storage bucket "fcos" as "fcos-latest.qcow2"
#     coreos-installer download -p oraclecloud -f qcow2.xz --decompress -a aarch64 -s stable
#     oci os object put -bn fcos --file fedora-coreos-*-oraclecloud.aarch64.qcow2 --name fcos-latest.qcow2
#
# Usage: ./oci-deploy.sh

set -euo pipefail

export OCI_CLI_AUTH=security_token
export OCI_CLI_PROFILE=DEFAULT

# ---- config ----
COMPARTMENT_NAME="root"           # use tenancy root; change if you want a subcompartment
BUCKET="fcos"
OBJECT="fcos-latest.qcow2"
IMAGE_NAME="fcos-aarch64"
INSTANCE_NAME="immich-fcos"
SHAPE="VM.Standard.A1.Flex"
OCPUS=1
MEMORY_GB=6
BOOT_GB=50
# ----------------

cd "$(dirname "$0")"
source env.sh

echo "==> regenerating Ignition from config.bu"
fcos-deploy

echo "==> resolving OCIDs"
if [[ "$COMPARTMENT_NAME" == "root" ]]; then
  COMP=$(oci iam compartment list --query 'data[0]."compartment-id"' --raw-output)
else
  COMP=$(oci iam compartment list --compartment-id-in-subtree true \
    --query "data[?name=='$COMPARTMENT_NAME'].id | [0]" --raw-output)
fi
[[ -n "$COMP" ]] || { echo "compartment not found"; exit 1; }

AD=$(oci iam availability-domain list -c "$COMP" --query 'data[0].name' --raw-output)
NS=$(oci os ns get --query data --raw-output)
SUBNET=$(oci network subnet list -c "$COMP" --query 'data[0].id' --raw-output)
[[ -n "$SUBNET" ]] || { echo "no subnet in compartment — create VCN first"; exit 1; }

echo "  COMP=$COMP"
echo "  AD=$AD"
echo "  SUBNET=$SUBNET"

echo "==> ensure image exists ($IMAGE_NAME)"
IMG=$(oci compute image list -c "$COMP" --display-name "$IMAGE_NAME" \
  --query 'data[?"lifecycle-state"==`AVAILABLE`].id | [0]' --raw-output)

if [[ -z "$IMG" || "$IMG" == "null" ]]; then
  echo "  importing from os://$NS/$BUCKET/$OBJECT (NATIVE/UEFI_64)"
  IMG=$(oci compute image import from-object \
    --compartment-id "$COMP" \
    --namespace "$NS" --bucket-name "$BUCKET" --name "$OBJECT" \
    --display-name "$IMAGE_NAME" \
    --launch-mode NATIVE \
    --source-image-type QCOW2 \
    --operating-system "Fedora CoreOS" \
    --operating-system-version "stable" \
    --query 'data.id' --raw-output)
  echo "  waiting for image AVAILABLE..."
  while :; do
    STATE=$(oci compute image get --image-id "$IMG" --query 'data."lifecycle-state"' --raw-output)
    [[ "$STATE" == "AVAILABLE" ]] && break
    [[ "$STATE" == "FAILED" ]] && { echo "image import failed"; exit 1; }
    sleep 10
  done
fi
echo "  IMG=$IMG"

echo "==> ensure A1.Flex shape compat"
HAS=$(oci compute image-shape-compatibility-entry list --image-id "$IMG" \
  --query "data[?\"shape\"=='$SHAPE'] | length(@)" --raw-output)
if [[ "$HAS" == "0" ]]; then
  oci compute image-shape-compatibility-entry add \
    --image-id "$IMG" --shape-name "$SHAPE" \
    --memory-constraints '{"minInGBs":6,"maxInGBs":24}' \
    --ocpu-constraints '{"min":1,"max":4}' --force >/dev/null
fi

echo "==> building user_data metadata"
base64 -i config.ign | tr -d '\n' > /tmp/ud.b64
jq -n --arg ud "$(cat /tmp/ud.b64)" '{user_data: $ud}' > /tmp/meta.json

echo "==> launching $INSTANCE_NAME ($SHAPE ${OCPUS}c/${MEMORY_GB}G/${BOOT_GB}G)"
INST=$(oci compute instance launch \
  --compartment-id "$COMP" \
  --availability-domain "$AD" \
  --shape "$SHAPE" \
  --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" \
  --image-id "$IMG" \
  --subnet-id "$SUBNET" \
  --boot-volume-size-in-gbs "$BOOT_GB" \
  --assign-public-ip true \
  --metadata file:///tmp/meta.json \
  --display-name "$INSTANCE_NAME" \
  --wait-for-state RUNNING \
  --query 'data.id' --raw-output)

IP=$(oci compute instance list-vnics --instance-id "$INST" --query 'data[0]."public-ip"' --raw-output)

cat <<EOF

==> done
  INST = $INST
  IP   = $IP

  ssh core@$IP
  Immich: http://$IP:2283

  containers come up over ~2-5 min after boot (image pulls).
  follow: ssh core@$IP 'journalctl -u immich-server -f'
EOF
