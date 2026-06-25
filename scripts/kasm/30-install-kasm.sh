#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 30-install-kasm.sh — install the Kasm Workspaces control plane.
#
# Run this ON the host/VM that will be your Kasm manager (Ubuntu/Debian, 4 vCPU
# / 8 GB+). It is NOT run over SSH to Proxmox — the control plane is a separate
# box (commonly itself a Proxmox VM, but a static one, not an autoscaled agent).
#
# It downloads the official Kasm release tarball and runs the bundled installer.
# A single-server install co-locates db/api/manager/agent/proxy — perfect for a
# test node. For production split roles (see docs/ARCHITECTURE.md).
#
# Usage (on the Kasm host):
#   KASM_VERSION=1.16.1 ./30-install-kasm.sh
#   ./30-install-kasm.sh --swap-size 0      # pass extra installer flags after --
# -----------------------------------------------------------------------------
source "$(dirname "$0")/../../lib/common.sh"
load_env
require_env KASM_VERSION

need_cmd curl
[[ "$(id -u)" -eq 0 ]] || die "Run as root (the Kasm installer needs root)."

WORKDIR="/tmp/kasm-install"
TARBALL="kasm_release_${KASM_VERSION}.tar.gz"
URL="https://kasm-static-content.s3.amazonaws.com/${TARBALL}"

mkdir -p "$WORKDIR"; cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

if [[ ! -f "$TARBALL" ]]; then
  log "Downloading $URL"
  curl -fL -o "$TARBALL" "$URL" || die "Download failed — check KASM_VERSION ($KASM_VERSION) and the URL."
fi
ok "Have $TARBALL"

log "Extracting..."
tar -xf "$TARBALL"
[[ -x kasm_release/install.sh ]] || die "install.sh not found in tarball — version mismatch?"

log "Running the Kasm installer (single-server)."
warn "The installer prints the admin password and URL at the end — SAVE THEM."
# Anything after `--` on our command line is forwarded to the Kasm installer.
EXTRA_ARGS=()
if [[ "${1:-}" == "--" ]]; then shift; EXTRA_ARGS=("$@"); fi
bash kasm_release/install.sh "${EXTRA_ARGS[@]}"

echo
ok "Kasm installed."
cat <<'NEXT'

Next steps:
  1. Log in to the Kasm UI (URL/password were printed above).
  2. Admin -> Settings -> Developer: create an API key. Put the key + secret in
     your .env (KASM_API_KEY / KASM_API_KEY_SECRET) on your workstation.
  3. Run scripts/kasm/40-configure-autoscale.sh for the VM Provider + Autoscale
     config values, then finish the wiring in the UI.
NEXT
