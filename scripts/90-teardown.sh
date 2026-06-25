#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 90-teardown.sh — undo what this repo created on the Proxmox node, so you can
# re-run from a clean slate. Does NOT touch the Kasm control plane (uninstall
# that with the Kasm-provided scripts) and does NOT delete VMs Kasm created that
# are still running — stop autoscaling in the Kasm UI first.
#
# Removes (with confirmation): the agent + server templates, the API token,
# user, role, and the resource pool.
#
# Usage:  90-teardown.sh            (prompts for each step)
#         FORCE=1 90-teardown.sh    (no prompts)
# -----------------------------------------------------------------------------
source "$(dirname "$0")/../lib/common.sh"
load_env
require_env PROXMOX_API_USER PROXMOX_API_TOKEN_NAME PROXMOX_API_ROLE PROXMOX_POOL

warn "This removes Kasm autoscaling objects from Proxmox node '$PROXMOX_NODE'."
warn "Make sure autoscaling is DISABLED in Kasm and no agent clones are running."
confirm "Continue?" || die "Aborted."

destroy_template() {
  local vmid="$1" label="$2"
  [[ -z "$vmid" ]] && return 0
  if pve_ssh "qm status $vmid" >/dev/null 2>&1; then
    if confirm "Destroy $label template VMID $vmid?"; then
      pve_ssh "qm stop $vmid --skiplock 1 2>/dev/null; sleep 2; qm destroy $vmid --purge 1 --destroy-unreferenced-disks 1" \
        && ok "Destroyed VMID $vmid" || warn "Could not destroy VMID $vmid"
    fi
  else
    log "$label template VMID $vmid not present — skipping."
  fi
}

destroy_template "${TEMPLATE_VMID:-}" "agent"
destroy_template "${SERVER_TEMPLATE_VMID:-}" "server"

if confirm "Remove API token ${PROXMOX_API_USER}!${PROXMOX_API_TOKEN_NAME}?"; then
  pve_ssh "pveum user token remove '$PROXMOX_API_USER' '$PROXMOX_API_TOKEN_NAME'" 2>/dev/null \
    && ok "Token removed" || warn "Token not present"
fi

if confirm "Remove resource pool '$PROXMOX_POOL'? (must be empty)"; then
  pve_ssh "pveum pool delete '$PROXMOX_POOL'" 2>/dev/null \
    && ok "Pool removed" || warn "Pool not empty or not present"
fi

if confirm "Remove user '$PROXMOX_API_USER'?"; then
  pve_ssh "pveum user delete '$PROXMOX_API_USER'" 2>/dev/null \
    && ok "User removed" || warn "User not present"
fi

if confirm "Remove role '$PROXMOX_API_ROLE'?"; then
  pve_ssh "pveum role delete '$PROXMOX_API_ROLE'" 2>/dev/null \
    && ok "Role removed" || warn "Role not present"
fi

echo
ok "Teardown complete."
