#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 21-build-server-template.sh — build a full-desktop Linux VM template for
# Kasm's "Server pool" autoscaling. This is the closest analog to Omnissa
# Horizon instant-clone desktops: each user gets a whole VM, brokered by Kasm
# over RDP, instead of a container.
#
# Template = Ubuntu + XFCE + xrdp + qemu-guest-agent. Kasm clones it, reads the
# IP via the guest agent, and registers it as a Server with an RDP connection.
#
# For WINDOWS desktops (the most common Horizon workload) build the template by
# hand in Proxmox — see docs/ARCHITECTURE.md "Windows server pool". The Proxmox
# side (pool, token, role) from 10-proxmox-setup.sh is identical.
#
# Usage:  21-build-server-template.sh [--force]
# -----------------------------------------------------------------------------
source "$(dirname "$0")/../../lib/common.sh"
load_env
require_env PROXMOX_NODE SERVER_TEMPLATE_VMID SERVER_TEMPLATE_NAME \
            TEMPLATE_STORAGE TEMPLATE_BRIDGE CLOUD_IMAGE_URL PROXMOX_POOL

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

VMID="$SERVER_TEMPLATE_VMID"
SNIP_STORE="${TEMPLATE_SNIPPET_STORAGE:-local}"
SNIPPET_PATH="/var/lib/vz/snippets/kasm-desktop-vendor-${VMID}.yaml"
IMG_PATH="/var/lib/vz/template/iso/$(basename "$CLOUD_IMAGE_URL")"
NET="virtio,bridge=${TEMPLATE_BRIDGE}"
[[ -n "${TEMPLATE_VLAN:-}" ]] && NET="${NET},tag=${TEMPLATE_VLAN}"

# A login user the RDP session uses. Kasm can override credentials per-provision;
# this is the baked-in default for testing.
DESKTOP_USER="${CLOUD_INIT_USER:-kasm}"
DESKTOP_PASS="${SERVER_TEMPLATE_PASSWORD:-kasmvdi}"

if pve_ssh "qm status $VMID" >/dev/null 2>&1; then
  if (( FORCE )); then
    warn "VM $VMID exists — destroying (--force)."
    pve_ssh "qm stop $VMID --skiplock 1 2>/dev/null; sleep 2; qm destroy $VMID --purge 1 --destroy-unreferenced-disks 1"
  else
    die "VM $VMID already exists. Re-run with --force to rebuild it."
  fi
fi

log "Ensuring cloud image present on node: $IMG_PATH"
pve_ssh "test -f '$IMG_PATH' || wget -q -O '$IMG_PATH' '$CLOUD_IMAGE_URL'"

log "Writing desktop vendor-data snippet -> $SNIPPET_PATH"
read -r -d '' VENDOR_YAML <<EOF || true
#cloud-config
package_update: true
packages:
  - qemu-guest-agent
  - xfce4
  - xfce4-goodies
  - xorgxrdp
  - xrdp
  - dbus-x11
runcmd:
  - systemctl enable --now qemu-guest-agent
  # Desktop login user
  - useradd -m -s /bin/bash ${DESKTOP_USER} || true
  - echo '${DESKTOP_USER}:${DESKTOP_PASS}' | chpasswd
  - adduser ${DESKTOP_USER} sudo || true
  # Point xrdp sessions at XFCE
  - bash -c 'echo "xfce4-session" > /home/${DESKTOP_USER}/.xsession'
  - chown ${DESKTOP_USER}:${DESKTOP_USER} /home/${DESKTOP_USER}/.xsession
  - adduser xrdp ssl-cert || true
  - systemctl enable --now xrdp
  # Generalise for templating
  - cloud-init clean --logs || true
  - truncate -s 0 /etc/machine-id
  - rm -f /var/lib/dbus/machine-id
  - ln -sf /etc/machine-id /var/lib/dbus/machine-id
  - touch /etc/kasm-desktop-provisioned
  - poweroff
EOF

pve_ssh "mkdir -p /var/lib/vz/snippets"
printf '%s' "$VENDOR_YAML" | base64 | pve_ssh "base64 -d > '$SNIPPET_PATH'"
ok "Snippet written."

log "Creating VM $VMID ($SERVER_TEMPLATE_NAME)"
pve_ssh "qm create $VMID \
  --name '$SERVER_TEMPLATE_NAME' \
  --memory ${SERVER_TEMPLATE_MEMORY_MB:-4096} \
  --cores ${SERVER_TEMPLATE_CORES:-2} \
  --cpu host \
  --machine q35 \
  --ostype l26 \
  --scsihw virtio-scsi-single \
  --net0 '$NET' \
  --agent enabled=1 \
  --pool '$PROXMOX_POOL'"

pve_ssh "qm set $VMID --scsi0 ${TEMPLATE_STORAGE}:0,import-from='$IMG_PATH',discard=on,ssd=1"
pve_ssh "qm set $VMID --ide2 ${TEMPLATE_STORAGE}:cloudinit"
pve_ssh "qm set $VMID --boot 'order=scsi0'"
pve_ssh "qm set $VMID --serial0 socket --vga serial0"
pve_ssh "qm disk resize $VMID scsi0 ${SERVER_TEMPLATE_DISK_GB:-40}G"
pve_ssh "qm set $VMID --ciuser '${DESKTOP_USER}' --ipconfig0 ip=dhcp"
pve_ssh "qm set $VMID --cicustom 'vendor=${SNIP_STORE}:snippets/$(basename "$SNIPPET_PATH")'"
ok "VM created."

log "Starting VM to provision the desktop (installs XFCE + xrdp; may take a while)..."
pve_ssh "qm start $VMID"

log "Waiting for self-poweroff (up to 40 min)..."
deadline=$(( $(date +%s) + 2400 ))
while true; do
  status="$(pve_ssh "qm status $VMID" 2>/dev/null | awk '{print $2}')"
  [[ "$status" == "stopped" ]] && { ok "Desktop provisioning complete."; break; }
  if (( $(date +%s) > deadline )); then
    pve_ssh "qm stop $VMID --skiplock 1" || true
    die "Timed out. Inspect via the Proxmox console for VM $VMID."
  fi
  sleep 20
done

log "Converting VM $VMID to a template."
pve_ssh "qm template $VMID"
ok "Server-pool template '$SERVER_TEMPLATE_NAME' (VMID $VMID) ready."
echo
log "In Kasm: create a Server-pool autoscale config that clones this template"
log "and registers each clone as an RDP Server (port 3389, user '${DESKTOP_USER}')."
