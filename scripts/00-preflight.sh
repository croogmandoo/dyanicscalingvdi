#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 00-preflight.sh — verify your workstation, .env, SSH to Proxmox, and (if a
# token secret is exported) Proxmox API reachability. Run this first; it makes
# no changes.
# -----------------------------------------------------------------------------
source "$(dirname "$0")/../lib/common.sh"
load_env

fail=0
section() { printf '\n=== %s ===\n' "$1"; }

section "Local tooling"
for c in ssh scp curl jq; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c present"; else warn "$c MISSING"; fail=1; fi
done

section "Required .env values"
for v in PROXMOX_HOST PROXMOX_SSH_USER PROXMOX_NODE PROXMOX_API_HOST \
         PROXMOX_API_USER PROXMOX_POOL TEMPLATE_VMID TEMPLATE_STORAGE \
         TEMPLATE_BRIDGE CLOUD_IMAGE_URL KASM_HOST; do
  if [[ -n "${!v:-}" ]]; then ok "$v=${!v}"; else warn "$v is empty"; fail=1; fi
done

section "SSH public key"
pk="$(expand_path "${SSH_PUBKEY_FILE:-}")"
if [[ -n "$pk" && -f "$pk" ]]; then ok "found $pk"; else warn "SSH_PUBKEY_FILE not found ($pk)"; fail=1; fi

section "SSH to Proxmox node"
if pve_ssh 'echo connected; pveversion; qm list >/dev/null 2>&1 && echo qm-ok' 2>/dev/null | sed 's/^/    /'; then
  ok "SSH + qm reachable on $PROXMOX_HOST"
else
  warn "Could not SSH to ${PROXMOX_SSH_USER}@${PROXMOX_HOST}:${PROXMOX_SSH_PORT} or run qm"
  fail=1
fi

section "Proxmox storage / bridge sanity"
if pve_ssh "pvesm status | awk 'NR>1{print \$1}' | grep -qx '$TEMPLATE_STORAGE'" 2>/dev/null; then
  ok "storage '$TEMPLATE_STORAGE' exists"
else
  warn "storage '$TEMPLATE_STORAGE' not found on node (check 'pvesm status')"; fail=1
fi
if pve_ssh "test -e /sys/class/net/$TEMPLATE_BRIDGE" 2>/dev/null; then
  ok "bridge '$TEMPLATE_BRIDGE' exists"
else
  warn "bridge '$TEMPLATE_BRIDGE' not found (check 'ip link')"; fail=1
fi

section "Proxmox API token (optional)"
if [[ -n "${PROXMOX_API_TOKEN_SECRET:-}" ]]; then
  if pve_api GET "/version" >/dev/null 2>&1; then
    ok "API token works against $PROXMOX_API_HOST"
  else
    warn "API token set but request failed — check role/ACL and PROXMOX_VERIFY_TLS"; fail=1
  fi
else
  log "PROXMOX_API_TOKEN_SECRET not exported — skipping (set after 10-proxmox-setup.sh)"
fi

section "Kasm reachability (optional)"
insecure=(); [[ "${KASM_VERIFY_TLS:-false}" == "false" ]] && insecure=(-k)
if curl -fsS "${insecure[@]}" -o /dev/null "${KASM_HOST}/api/__healthcheck" 2>/dev/null; then
  ok "Kasm healthcheck OK at $KASM_HOST"
else
  log "Kasm not reachable yet (expected before 30-install-kasm.sh)"
fi

echo
if (( fail )); then
  die "Preflight found problems — fix the items above before continuing."
else
  ok "Preflight passed."
fi
