#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 22-build-windows-template.sh — scaffold a Windows desktop-pool template on
# Proxmox for Kasm Server autoscaling (the Horizon-style "one full Windows VM
# per user" model).
#
# Windows can't be cloud-init'd like Linux, so this is semi-automated:
#
#   (default)    Build phase:
#       - render windows/autounattend.xml from .env,
#       - build an "answer ISO" (autounattend.xml + bootstrap.ps1 + Cloudbase
#         configs) on the node,
#       - create the VM with the correct hardware (OVMF/TPM/virtio/q35),
#       - attach the Windows ISO + virtio ISO + answer ISO and start it.
#     Windows then installs unattended, runs bootstrap.ps1 (virtio guest agent,
#     Cloudbase-Init, RDP), and waits at the desktop.
#
#   --finalize   Seal phase (run after you sysprep + shut down — see below):
#       - detach the install ISOs, add a cloud-init drive,
#       - convert the VM to a Proxmox template in the autoscale pool.
#
# Manual step in between (documented in docs/WINDOWS-DESKTOP-POOL.md):
#   RDP/console into the VM, confirm qemu-guest-agent is running, then run
#   sysprep /generalize /oobe /shutdown /unattend:...Unattend.xml
#
# You must provide the ISOs yourself (Windows licensing). Put them under the ISO
# storage's template/iso directory and name them in .env.
# -----------------------------------------------------------------------------
source "$(dirname "$0")/../../lib/common.sh"
load_env
require_env PROXMOX_NODE WIN_TEMPLATE_VMID WIN_TEMPLATE_NAME TEMPLATE_STORAGE \
            TEMPLATE_BRIDGE PROXMOX_POOL WIN_OSTYPE WIN_ISO_STORAGE WIN_ISO \
            WIN_VIRTIO_ISO WIN_ADMIN_USER WIN_ADMIN_PASSWORD

VMID="$WIN_TEMPLATE_VMID"
ISO_DIR_REMOTE="/var/lib/vz/template/iso"   # default path for the 'local' iso store
ANSWER_ISO="kasm-win-answer-${VMID}.iso"
NET="virtio,bridge=${TEMPLATE_BRIDGE}"
[[ -n "${TEMPLATE_VLAN:-}" ]] && NET="${NET},tag=${TEMPLATE_VLAN}"

# --------------------------------------------------------------------------- #
# --finalize: seal the (already sysprepped + powered-off) VM into a template   #
# --------------------------------------------------------------------------- #
if [[ "${1:-}" == "--finalize" ]]; then
  pve_ssh "qm status $VMID" >/dev/null 2>&1 || die "VM $VMID not found."
  state="$(pve_ssh "qm status $VMID" | awk '{print $2}')"
  [[ "$state" == "stopped" ]] || die "VM $VMID is '$state'. Sysprep with /shutdown first, then re-run --finalize."
  log "Detaching install media and adding a cloud-init drive for Cloudbase-Init."
  pve_ssh "qm set $VMID --delete ide0 2>/dev/null; qm set $VMID --delete ide3 2>/dev/null; qm set $VMID --delete ide2 2>/dev/null" || true
  pve_ssh "qm set $VMID --ide2 ${TEMPLATE_STORAGE}:cloudinit"
  pve_ssh "qm set $VMID --ciuser '${WIN_ADMIN_USER}' --ipconfig0 ip=dhcp"
  pve_ssh "qm set $VMID --boot 'order=scsi0'"
  log "Converting VM $VMID to a template."
  pve_ssh "qm template $VMID"
  ok "Windows template '$WIN_TEMPLATE_NAME' (VMID $VMID) sealed in pool '$PROXMOX_POOL'."
  echo
  log "In Kasm: create a Server-pool autoscale config cloning VMID $VMID, with an"
  log "RDP connection (port 3389, user '${WIN_ADMIN_USER}'). See docs/WINDOWS-DESKTOP-POOL.md."
  exit 0
fi

# --------------------------------------------------------------------------- #
# Build phase                                                                  #
# --------------------------------------------------------------------------- #
if pve_ssh "qm status $VMID" >/dev/null 2>&1; then
  if [[ "${1:-}" == "--force" ]]; then
    warn "VM $VMID exists — destroying (--force)."
    pve_ssh "qm stop $VMID --skiplock 1 2>/dev/null; sleep 2; qm destroy $VMID --purge 1 --destroy-unreferenced-disks 1"
  else
    die "VM $VMID already exists. Use --force to rebuild, or --finalize to seal it."
  fi
fi

# --- 0. sanity: ISOs present on the node -------------------------------------
log "Checking ISOs exist under ${ISO_DIR_REMOTE} on the node..."
pve_ssh "test -f '${ISO_DIR_REMOTE}/${WIN_ISO}'"     || die "Windows ISO not found: ${ISO_DIR_REMOTE}/${WIN_ISO}"
pve_ssh "test -f '${ISO_DIR_REMOTE}/${WIN_VIRTIO_ISO}'" || die "virtio-win ISO not found: ${ISO_DIR_REMOTE}/${WIN_VIRTIO_ISO}"
ok "ISOs present."

# --- 1. render autounattend.xml from the template ----------------------------
log "Rendering autounattend.xml from .env values."
SRC="$REPO_ROOT/windows"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/kasm-win.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# virtio driver dir name depends on guest OS (e.g. w11, w10, 2k22, 2k19).
case "$WIN_OSTYPE" in
  win11)  VIRTIO_DIR="w11" ; WIN_EDITION_DEFAULT="Windows 11 Pro" ;;
  win10)  VIRTIO_DIR="w10" ; WIN_EDITION_DEFAULT="Windows 10 Pro" ;;
  win2k22)VIRTIO_DIR="2k22"; WIN_EDITION_DEFAULT="Windows Server 2022 SERVERSTANDARD" ;;
  win2k19)VIRTIO_DIR="2k19"; WIN_EDITION_DEFAULT="Windows Server 2019 SERVERSTANDARD" ;;
  *) die "Unsupported WIN_OSTYPE '$WIN_OSTYPE' (use win11|win10|win2k22|win2k19)";;
esac
WIN_EDITION="${WIN_EDITION:-$WIN_EDITION_DEFAULT}"

if [[ -n "${WIN_PRODUCT_KEY:-}" ]]; then
  PRODUCT_KEY_BLOCK="<ProductKey><Key>${WIN_PRODUCT_KEY}</Key></ProductKey>"
else
  PRODUCT_KEY_BLOCK="<!-- no product key supplied -->"
fi

sed -e "s|@@LOCALE@@|${WIN_LOCALE:-en-US}|g" \
    -e "s|@@TIMEZONE@@|${WIN_TIMEZONE:-UTC}|g" \
    -e "s|@@ADMIN_USER@@|${WIN_ADMIN_USER}|g" \
    -e "s|@@ADMIN_PASSWORD@@|${WIN_ADMIN_PASSWORD}|g" \
    -e "s|@@VIRTIO_DIR@@|${VIRTIO_DIR}|g" \
    -e "s|@@WIN_EDITION@@|${WIN_EDITION}|g" \
    -e "s|@@PRODUCT_KEY_BLOCK@@|${PRODUCT_KEY_BLOCK}|g" \
    "$SRC/autounattend.xml" > "$TMP/autounattend.xml"

cp "$SRC/bootstrap.ps1" "$TMP/bootstrap.ps1"
cp "$SRC/cloudbase-init/cloudbase-init.conf" "$TMP/"
cp "$SRC/cloudbase-init/cloudbase-init-unattend.conf" "$TMP/"
cp "$SRC/cloudbase-init/Unattend.xml" "$TMP/"
ok "Answer files prepared (edition: $WIN_EDITION, virtio dir: $VIRTIO_DIR)."

# --- 2. build the answer ISO on the node -------------------------------------
log "Building answer ISO on the node (needs genisoimage/mkisofs)."
pve_ssh "command -v genisoimage >/dev/null 2>&1 || command -v mkisofs >/dev/null 2>&1" \
  || die "Install an ISO builder on the node:  apt-get install -y genisoimage"
REMOTE_STAGE="/tmp/kasm-win-answer-${VMID}"
pve_ssh "rm -rf '$REMOTE_STAGE' && mkdir -p '$REMOTE_STAGE'"
for f in autounattend.xml bootstrap.ps1 cloudbase-init.conf cloudbase-init-unattend.conf Unattend.xml; do
  pve_scp "$TMP/$f" "$REMOTE_STAGE/$f"
done
pve_ssh "ISO='${ISO_DIR_REMOTE}/${ANSWER_ISO}'; \
  if command -v genisoimage >/dev/null 2>&1; then BUILDER=genisoimage; else BUILDER=mkisofs; fi; \
  \$BUILDER -quiet -J -r -V KASMANSWER -o \"\$ISO\" '$REMOTE_STAGE'"
ok "Answer ISO created: ${ISO_DIR_REMOTE}/${ANSWER_ISO}"

# --- 3. create the VM with Windows-appropriate hardware ----------------------
log "Creating Windows VM $VMID ($WIN_TEMPLATE_NAME)"
pve_ssh "qm create $VMID \
  --name '$WIN_TEMPLATE_NAME' \
  --ostype '$WIN_OSTYPE' \
  --machine q35 \
  --bios ovmf \
  --cpu host \
  --cores ${WIN_TEMPLATE_CORES:-4} \
  --memory ${WIN_TEMPLATE_MEMORY_MB:-8192} \
  --scsihw virtio-scsi-single \
  --net0 '$NET' \
  --agent enabled=1 \
  --pool '$PROXMOX_POOL'"

# EFI + TPM (TPM required for Windows 11). System disk + the three CD-ROMs.
pve_ssh "qm set $VMID --efidisk0 ${TEMPLATE_STORAGE}:1,efitype=4m,pre-enrolled-keys=1"
if [[ "$WIN_OSTYPE" == "win11" ]]; then
  pve_ssh "qm set $VMID --tpmstate0 ${TEMPLATE_STORAGE}:1,version=v2.0"
fi
pve_ssh "qm set $VMID --scsi0 ${TEMPLATE_STORAGE}:${WIN_TEMPLATE_DISK_GB:-80},discard=on,ssd=1,iothread=1"
pve_ssh "qm set $VMID --ide2 ${WIN_ISO_STORAGE}:iso/${WIN_ISO},media=cdrom"
pve_ssh "qm set $VMID --ide3 ${WIN_ISO_STORAGE}:iso/${WIN_VIRTIO_ISO},media=cdrom"
pve_ssh "qm set $VMID --ide0 ${WIN_ISO_STORAGE}:iso/${ANSWER_ISO},media=cdrom"
pve_ssh "qm set $VMID --boot 'order=ide2;scsi0'"
ok "VM created."

log "Starting VM — Windows will install unattended and run bootstrap.ps1."
pve_ssh "qm start $VMID"

cat <<EOF

$(ok 'Build phase done.') Windows is installing now. Watch via the Proxmox console
(it auto-installs, creates user '${WIN_ADMIN_USER}', enables RDP, installs the
virtio guest agent + Cloudbase-Init, then sits at the desktop).

NEXT (manual seal step):
  1. Console/RDP into the VM; confirm 'QEMU-GA' service is running and
     C:\\kasm-bootstrap.log finished cleanly.
  2. Generalize + shut down:
       cd "C:\\Windows\\System32\\Sysprep"
       .\\sysprep.exe /generalize /oobe /shutdown \\
          /unattend:"C:\\Program Files\\Cloudbase Solutions\\Cloudbase-Init\\conf\\Unattend.xml"
  3. Seal it into a Proxmox template:
       scripts/proxmox/22-build-windows-template.sh --finalize

Full walkthrough + the Kasm Server-pool config: docs/WINDOWS-DESKTOP-POOL.md
EOF
