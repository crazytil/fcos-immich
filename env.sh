# Source me: `source /path/to/fcos/env.sh`
# Provides: butane, coreos-installer (via docker, session-scoped)

export FCOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

butane() {
  docker run --rm -i \
    -v "$PWD:/pwd" -w /pwd \
    quay.io/coreos/butane:release --files-dir /pwd "$@"
}

coreos-installer() {
  local tty=""
  [ -t 0 ] && [ -t 1 ] && tty="-t"
  docker run --rm -i $tty \
    -v "$PWD:/data" -w /data \
    quay.io/coreos/coreos-installer:release "$@"
}

fcos-deploy() {
  butane --pretty --strict < "$FCOS_DIR/config.bu" > "$FCOS_DIR/config.ign" \
    && echo "wrote $FCOS_DIR/config.ign"
}

fcos-boot() {
  sudo "$FCOS_DIR/launch.sh"
}

fcos-reset() {
  [[ -f "$FCOS_DIR/pristine.qcow2" ]] || { echo "Missing $FCOS_DIR/pristine.qcow2"; return 1; }
  local size="${FCOS_DISK_SIZE:-40G}"
  rm -f "$FCOS_DIR"/fedora-coreos-*-qemu.aarch64.qcow2 "$FCOS_DIR/efi_vars.fd"
  cp "$FCOS_DIR/pristine.qcow2" "$FCOS_DIR/fedora-coreos-reset-qemu.aarch64.qcow2"
  qemu-img resize -q "$FCOS_DIR/fedora-coreos-reset-qemu.aarch64.qcow2" "$size" \
    && echo "VM reset, disk grown to $size. Run: fcos-deploy && fcos-boot"
}

fcos-boot-user() {
  FCOS_NET=user "$FCOS_DIR/launch.sh"
}

fcos-ssh() {
  # arg 1 = IP. omit for user-mode (forwarded localhost:2222)
  local host="${1:-localhost}"
  local port="22"
  [[ "$host" == "localhost" ]] && port="2222"
  ssh -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null core@"$host"
}

fcos-help() {
  cat <<EOF
FCOS session commands (FCOS_DIR=$FCOS_DIR):
  butane --pretty --strict < config.bu > config.ign     # transpile
  fcos-deploy                                           # butane -> config.ign
  fcos-boot                                             # launch QEMU (Ctrl-A X to quit)
  fcos-ssh                                              # ssh core@localhost:2222
  coreos-installer download -s stable -p qemu -f qcow2.xz --decompress [-a aarch64]
Unload: unset -f butane coreos-installer fcos-help fcos-deploy fcos-boot fcos-ssh
EOF
}

echo "FCOS env loaded (FCOS_DIR=$FCOS_DIR). Run: fcos-help"
