#!/usr/bin/env bash
# Launch Fedora CoreOS in standalone QEMU
# Networking:
#   - vmnet-shared (fast, macOS native). Requires sudo OR run via sudo.
#   - Fallback to user-mode by setting FCOS_NET=user
# SSH from host:
#   - vmnet:   ssh core@<vm-ip-on-192.168.64.x>  (inside VM: ip -br a)
#   - user:    ssh -p 2222 core@localhost
set -euo pipefail

cd "$(dirname "$0")"

QCOW2="$(ls -1 fedora-coreos-*-qemu.aarch64.qcow2 2>/dev/null | head -1)"
IGN="$PWD/config.ign"
FW_CODE="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
FW_VARS_TEMPLATE="/opt/homebrew/share/qemu/edk2-arm-vars.fd"
FW_VARS="$PWD/efi_vars.fd"

[[ -f "$QCOW2" ]] || { echo "Missing qcow2 in $PWD"; exit 1; }
[[ -f "$IGN"   ]] || { echo "Missing $IGN — run: fcos-deploy"; exit 1; }
[[ -f "$FW_VARS" ]] || cp "$FW_VARS_TEMPLATE" "$FW_VARS"

NET="${FCOS_NET:-bridged}"
IFNAME="${FCOS_IFNAME:-en0}"
case "$NET" in
  bridged)
    if [[ $EUID -ne 0 ]]; then
      echo "vmnet-bridged needs root. Re-run: sudo $0   (or FCOS_NET=user for SLIRP)"
      exit 1
    fi
    NETDEV_ARGS=(-netdev "vmnet-bridged,id=net0,ifname=$IFNAME" -device "virtio-net-pci,netdev=net0")
    echo "Net: vmnet-bridged on $IFNAME (VM gets DHCP from your LAN; find IP with: ip -br a)"
    ;;
  shared)
    if [[ $EUID -ne 0 ]]; then
      echo "vmnet-shared needs root. Re-run: sudo $0"
      exit 1
    fi
    NETDEV_ARGS=(-netdev "vmnet-shared,id=net0" -device "virtio-net-pci,netdev=net0")
    echo "Net: vmnet-shared (NAT)"
    ;;
  user)
    NETDEV_ARGS=(-netdev "user,id=net0,hostfwd=tcp::2222-:22" -device "virtio-net-pci,netdev=net0")
    echo "Net: user-mode SLIRP (SSH: ssh -p 2222 core@localhost)"
    ;;
  *)
    echo "Unknown FCOS_NET=$NET (use bridged|shared|user)"; exit 1 ;;
esac

exec qemu-system-aarch64 \
  -name fcos-lab \
  -machine virt,accel=hvf,highmem=on \
  -cpu host \
  -smp 2 \
  -m 6144 \
  -drive if=pflash,format=raw,readonly=on,file="$FW_CODE" \
  -drive if=pflash,format=raw,file="$FW_VARS" \
  -drive if=virtio,format=qcow2,file="$QCOW2" \
  "${NETDEV_ARGS[@]}" \
  -fw_cfg name=opt/com.coreos/config,file="$IGN" \
  -nographic
