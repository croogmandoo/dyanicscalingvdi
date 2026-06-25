#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 10-proxmox-setup.sh — prepare the Proxmox node for Kasm autoscaling.
#
# Creates, idempotently, over SSH:
#   1. a custom role with exactly the privileges Kasm needs,
#   2. a dedicated API user (PROXMOX_API_USER),
#   3. a resource pool (PROXMOX_POOL) the agent VMs will live in,
#   4. ACLs granting the user the role on the pool + storage,
#   5. an API token (privsep off) — the SECRET is printed ONCE.
#
# Re-running is safe: existing objects are detected and left in place. The
# token secret can only be shown at creation; rotate with --rotate-token.
# -----------------------------------------------------------------------------
source "$(dirname "$0")/../../lib/common.sh"
load_env
require_env PROXMOX_API_USER PROXMOX_API_TOKEN_NAME PROXMOX_API_ROLE PROXMOX_POOL TEMPLATE_STORAGE

ROTATE=0
[[ "${1:-}" == "--rotate-token" ]] && ROTATE=1

# Privileges Kasm's Proxmox provider needs to clone/configure/power agent VMs.
# NOTE: privilege names can shift slightly between Proxmox versions and Kasm
# releases. If a clone/power op is denied, check the Kasm Proxmox autoscale
# docs for your version and add the missing privilege here, then re-run.
ROLE_PRIVS="VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.Cloudinit \
VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory \
VM.Config.Network VM.Config.Options VM.Migrate VM.Monitor VM.PowerMgmt \
Datastore.AllocateSpace Datastore.Audit Pool.Allocate Pool.Audit \
SDN.Use Sys.Audit Sys.Console Sys.Modify"

log "Configuring Proxmox node '$PROXMOX_NODE' for Kasm autoscaling..."

# --- 1. role -----------------------------------------------------------------
if pve_ssh "pveum role list --output-format json | grep -q '\"$PROXMOX_API_ROLE\"'" 2>/dev/null; then
  log "Role '$PROXMOX_API_ROLE' exists — updating privileges."
  pve_ssh "pveum role modify '$PROXMOX_API_ROLE' -privs '$ROLE_PRIVS'"
else
  log "Creating role '$PROXMOX_API_ROLE'."
  pve_ssh "pveum role add '$PROXMOX_API_ROLE' -privs '$ROLE_PRIVS'"
fi
ok "Role ready."

# --- 2. user -----------------------------------------------------------------
if pve_ssh "pveum user list --output-format json | grep -q '\"$PROXMOX_API_USER\"'" 2>/dev/null; then
  log "User '$PROXMOX_API_USER' already exists."
else
  log "Creating user '$PROXMOX_API_USER'."
  pve_ssh "pveum user add '$PROXMOX_API_USER' --comment 'Kasm autoscaling service account'"
fi
ok "User ready."

# --- 3. pool -----------------------------------------------------------------
if pve_ssh "pvesh get /pools --output-format json | grep -q '\"$PROXMOX_POOL\"'" 2>/dev/null; then
  log "Pool '$PROXMOX_POOL' already exists."
else
  log "Creating pool '$PROXMOX_POOL'."
  pve_ssh "pveum pool add '$PROXMOX_POOL' --comment 'Kasm autoscale agent VMs'"
fi
ok "Pool ready."

# --- 4. ACLs -----------------------------------------------------------------
log "Granting '$PROXMOX_API_ROLE' to '$PROXMOX_API_USER' on pool + storage."
pve_ssh "pveum aclmod '/pool/$PROXMOX_POOL'      -user '$PROXMOX_API_USER' -role '$PROXMOX_API_ROLE'"
pve_ssh "pveum aclmod '/storage/$TEMPLATE_STORAGE' -user '$PROXMOX_API_USER' -role '$PROXMOX_API_ROLE'"
# SDN.Use lives under /sdn/zones; harmless if SDN is unused.
pve_ssh "pveum aclmod '/sdn' -user '$PROXMOX_API_USER' -role '$PROXMOX_API_ROLE'" 2>/dev/null || \
  warn "Could not set ACL on /sdn (fine if you don't use SDN)."
ok "ACLs applied."

# --- 5. token ----------------------------------------------------------------
TOKEN_EXISTS=0
pve_ssh "pveum user token list '$PROXMOX_API_USER' --output-format json 2>/dev/null | grep -q '\"$PROXMOX_API_TOKEN_NAME\"'" 2>/dev/null && TOKEN_EXISTS=1

if (( TOKEN_EXISTS )) && (( ROTATE )); then
  log "Rotating token '$PROXMOX_API_TOKEN_NAME'."
  pve_ssh "pveum user token remove '$PROXMOX_API_USER' '$PROXMOX_API_TOKEN_NAME'"
  TOKEN_EXISTS=0
fi

if (( TOKEN_EXISTS )); then
  warn "Token '${PROXMOX_API_USER}!${PROXMOX_API_TOKEN_NAME}' already exists."
  warn "The secret is only shown at creation. Re-run with --rotate-token to mint a new one."
else
  log "Creating API token (privilege separation OFF so it inherits the user's role)."
  # --privsep 0 => token shares the user's permissions; output as JSON to grab the value.
  TOKEN_JSON="$(pve_ssh "pveum user token add '$PROXMOX_API_USER' '$PROXMOX_API_TOKEN_NAME' --privsep 0 --output-format json")"
  SECRET="$(echo "$TOKEN_JSON" | jq -r '.value')"
  echo
  ok  "=============================================================="
  ok  " API token created — copy the secret NOW (shown only once):"
  echo "   Full token id : ${PROXMOX_API_USER}!${PROXMOX_API_TOKEN_NAME}"
  echo "   Secret        : $SECRET"
  ok  "=============================================================="
  echo
  log "Use it in Kasm's VM Provider config, and export for the helper scripts:"
  echo "   export PROXMOX_API_TOKEN_SECRET='$SECRET'"
fi

echo
ok "Proxmox node prepared. Next: scripts/proxmox/20-build-agent-template.sh"
