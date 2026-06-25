#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 20-build-agent-template.sh — build the Linux "Docker agent" VM template that
# Kasm clones to scale out. Runs entirely over SSH against the Proxmox node.
#
# The template is an Ubuntu cloud image plus:
#   - qemu-guest-agent  (Kasm/Proxmox need this to read VM IP + lifecycle)
#   - Docker engine
#   - the Kasm release tarball staged locally (fast agent install at clone time)
#   - pre-pulled workspace images (sessions start instantly, no cold pull)
#   - machine-id cleared so every clone gets a fresh identity
#
# Provisioning is driven by a cloud-init *vendor-data* snippet that runs once on
# first boot and then powers the VM off. The host waits for that, then converts
# the VM to a template.  No inbound SSH to the VM is required — but the VM DOES
# need outbound network (DHCP on the bridge) to reach apt + Docker Hub.
#
# Usage:  20-build-agent-template.sh [--force]
#   --force   destroy an existing VM/template at TEMPLATE_VMID first
# -----------------------------------------------------------------------------
source "$(dirname "$0")/../../lib/common.sh"
load_env
require_env PROXMOX_NODE TEMPLATE_VMID TEMPLATE_NAME TEMPLATE_STORAGE \
            TEMPLATE_BRIDGE CLOUD_IMAGE_URL PROXMOX_POOL KASM_VERSION

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

VMID="$TEMPLATE_VMID"
SNIP_STORE="${TEMPLATE_SNIPPET_STORAGE:-local}"
SNIPPET_PATH="/var/lib/vz/snippets/kasm-agent-vendor-${VMID}.yaml"
IMG_PATH="/var/lib/vz/template/iso/$(basename "$CLOUD_IMAGE_URL")"
NET="virtio,bridge=${TEMPLATE_BRIDGE}"
[[ -n "${TEMPLATE_VLAN:-}" ]] && NET="${NET},tag=${TEMPLATE_VLAN}"

# --- handle an existing VMID -------------------------------------------------
if pve_ssh "qm status $VMID" >/dev/null 2>&1; then
  if (( FORCE )); then
    warn "VM $VMID exists — destroying (--force)."
    pve_ssh "qm stop $VMID --skiplock 1 2>/dev/null; sleep 2; qm destroy $VMID --purge 1 --destroy-unreferenced-disks 1"
  else
    die "VM $VMID already exists. Re-run with --force to rebuild it."
  fi
fi

# --- 1. fetch the cloud image on the node ------------------------------------
log "Ensuring cloud image present on node: $IMG_PATH"
pve_ssh "test -f '$IMG_PATH' || wget -q -O '$IMG_PATH' '$CLOUD_IMAGE_URL'"
ok "Cloud image ready."

# --- 2. write the cloud-init vendor-data snippet -----------------------------
log "Writing vendor-data snippet -> $SNIPPET_PATH"
PREPULL_BLOCK=""
for img in ${KASM_PREPULL_IMAGES:-}; do
  PREPULL_BLOCK+="  - docker pull ${img} || true"$'\n'
done

# This heredoc is expanded locally (so $KASM_VERSION etc. are filled in), then
# the resulting YAML is written to the node. Anything that must survive to the
# guest is hard-coded; nothing here references host-only paths.
read -r -d '' VENDOR_YAML <<EOF || true
#cloud-config
package_update: true
package_upgrade: false
packages:
  - qemu-guest-agent
  - ca-certificates
  - curl
  - gnupg
write_files:
  - path: /etc/kasm/BUILD_INFO
    content: |
      Built by dyanicscalingvdi/20-build-agent-template.sh
      Kasm version: ${KASM_VERSION}
runcmd:
  # qemu-guest-agent — required for Proxmox/Kasm to track the VM
  - systemctl enable --now qemu-guest-agent
  # Docker engine (official convenience script)
  - curl -fsSL https://get.docker.com | sh
  - systemctl enable --now docker
  # Stage the Kasm release so agent install at clone time is fast/offline
  - mkdir -p /opt/kasm-release
  - curl -fsSL "https://kasm-static-content.s3.amazonaws.com/kasm_release_${KASM_VERSION}.tar.gz" -o /tmp/kasm_release.tar.gz || true
  - tar -xf /tmp/kasm_release.tar.gz -C /opt/kasm-release --strip-components=1 || true
  # Pre-pull workspace images so user sessions start instantly
${PREPULL_BLOCK}  # Generalise: clear machine-id so each clone is unique
  - cloud-init clean --logs || true
  - truncate -s 0 /etc/machine-id
  - rm -f /var/lib/dbus/machine-id
  - ln -sf /etc/machine-id /var/lib/dbus/machine-id
  - touch /etc/kasm/PROVISIONED
  # Signal completion to the host by powering off
  - poweroff
EOF

# Write the YAML to the node (base64 to avoid any quoting surprises over SSH).
pve_ssh "mkdir -p /var/lib/vz/snippets"
printf '%s' "$VENDOR_YAML" | base64 | pve_ssh "base64 -d > '$SNIPPET_PATH'"
ok "Snippet written."

# --- 3. create the VM --------------------------------------------------------
log "Creating VM $VMID ($TEMPLATE_NAME)"
pve_ssh "qm create $VMID \
  --name '$TEMPLATE_NAME' \
  --memory ${TEMPLATE_MEMORY_MB:-8192} \
  --cores ${TEMPLATE_CORES:-4} \
  --cpu host \
  --machine q35 \
  --ostype l26 \
  --scsihw virtio-scsi-single \
  --net0 '$NET' \
  --agent enabled=1 \
  --pool '$PROXMOX_POOL'"

log "Importing disk from cloud image (import-from requires Proxmox 7.2+)"
pve_ssh "qm set $VMID --scsi0 ${TEMPLATE_STORAGE}:0,import-from='$IMG_PATH',discard=on,ssd=1"
pve_ssh "qm set $VMID --ide2 ${TEMPLATE_STORAGE}:cloudinit"
pve_ssh "qm set $VMID --boot 'order=scsi0'"
pve_ssh "qm set $VMID --serial0 socket --vga serial0"
pve_ssh "qm disk resize $VMID scsi0 ${TEMPLATE_DISK_GB:-60}G"

# cloud-init basics (DHCP + your SSH key for debugging) + the vendor snippet
PUBKEY="$(expand_path "${SSH_PUBKEY_FILE:-}")"
if [[ -n "$PUBKEY" && -f "$PUBKEY" ]]; then
  REMOTE_KEY="/tmp/kasm-build-${VMID}.pub"
  pve_scp "$PUBKEY" "$REMOTE_KEY"
  pve_ssh "qm set $VMID --sshkeys '$REMOTE_KEY'"
fi
pve_ssh "qm set $VMID --ciuser '${CLOUD_INIT_USER:-kasm}' --ipconfig0 ip=dhcp"
pve_ssh "qm set $VMID --cicustom 'vendor=${SNIP_STORE}:snippets/$(basename "$SNIPPET_PATH")'"
ok "VM created and configured."

# --- 4. boot once to provision, wait for self-poweroff -----------------------
log "Starting VM to run provisioning (installs Docker, pulls images)..."
pve_ssh "qm start $VMID"

log "Waiting for the VM to finish and power itself off (up to 30 min)..."
deadline=$(( $(date +%s) + 1800 ))
while true; do
  status="$(pve_ssh "qm status $VMID" 2>/dev/null | awk '{print $2}')"
  if [[ "$status" == "stopped" ]]; then
    ok "Provisioning complete (VM powered off)."
    break
  fi
  if (( $(date +%s) > deadline )); then
    pve_ssh "qm stop $VMID --skiplock 1" || true
    die "Timed out waiting for provisioning. Inspect with: qm terminal $VMID  (or the Proxmox console)."
  fi
  sleep 15
done

# --- 5. convert to template --------------------------------------------------
log "Converting VM $VMID to a template."
pve_ssh "qm template $VMID"
ok "Template '$TEMPLATE_NAME' (VMID $VMID) is ready in pool '$PROXMOX_POOL'."

echo
ok "Next: configure Kasm's VM Provider + Autoscale config:"
echo "   scripts/kasm/40-configure-autoscale.sh"
