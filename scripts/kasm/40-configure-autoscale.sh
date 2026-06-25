#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 40-configure-autoscale.sh — validate everything Kasm needs for Proxmox
# autoscaling, then emit the exact VM-Provider + Autoscale-config values to
# enter in the Kasm admin UI.
#
# Why not fully automate it? Kasm creates VM Providers and Autoscale Configs in
# the admin UI (Admin -> Infrastructure). There is no stable, version-independent
# public API to create those objects, so this script does the parts a script
# does well — verify the Proxmox token actually works, confirm the pool/template
# exist, compute the right values — and hands you a precise checklist for the
# two clicks that remain. It writes the values to out/autoscale-config.json too.
#
# Requires PROXMOX_API_TOKEN_SECRET exported (printed by 10-proxmox-setup.sh).
# -----------------------------------------------------------------------------
source "$(dirname "$0")/../../lib/common.sh"
load_env
require_env PROXMOX_API_HOST PROXMOX_API_USER PROXMOX_API_TOKEN_NAME \
            PROXMOX_NODE PROXMOX_POOL TEMPLATE_VMID

need_cmd curl; need_cmd jq
[[ -n "${PROXMOX_API_TOKEN_SECRET:-}" ]] || \
  die "Export PROXMOX_API_TOKEN_SECRET first (10-proxmox-setup.sh printed it)."

fail=0

log "1/4  Testing the Proxmox API token Kasm will use..."
if pve_api GET "/version" >/dev/null 2>&1; then
  ver="$(pve_api GET "/version" | jq -r '.data.version')"
  ok "Token authenticates. Proxmox version: $ver"
else
  warn "Token request to $PROXMOX_API_HOST failed — Kasm won't be able to scale."
  warn "Check the role/ACL (re-run 10-proxmox-setup.sh) and PROXMOX_VERIFY_TLS."
  fail=1
fi

log "2/4  Checking the autoscale pool '$PROXMOX_POOL' is visible to the token..."
if pve_api GET "/pools/${PROXMOX_POOL}" >/dev/null 2>&1; then
  ok "Pool reachable."
else
  warn "Pool '$PROXMOX_POOL' not visible to the token. Did 10-proxmox-setup.sh run?"
  fail=1
fi

log "3/4  Confirming template VMID $TEMPLATE_VMID exists and is a template..."
tmpl_json="$(pve_api GET "/nodes/${PROXMOX_NODE}/qemu/${TEMPLATE_VMID}/config" 2>/dev/null || true)"
if [[ -n "$tmpl_json" ]] && echo "$tmpl_json" | jq -e '.data.template == 1' >/dev/null 2>&1; then
  tmpl_name="$(echo "$tmpl_json" | jq -r '.data.name')"
  ok "Template found: $tmpl_name (VMID $TEMPLATE_VMID)"
elif [[ -n "$tmpl_json" ]]; then
  warn "VMID $TEMPLATE_VMID exists but is NOT a template. Run 20-build-agent-template.sh."
  fail=1
else
  warn "VMID $TEMPLATE_VMID not found via API. Build it with 20-build-agent-template.sh."
  fail=1
fi

log "4/4  Writing computed config to out/autoscale-config.json"
mkdir -p "$REPO_ROOT/out"
jq -n \
  --arg host    "$PROXMOX_API_HOST" \
  --arg tokuser "$PROXMOX_API_USER" \
  --arg tokname "$PROXMOX_API_TOKEN_NAME" \
  --arg node    "$PROXMOX_NODE" \
  --arg pool    "$PROXMOX_POOL" \
  --arg store   "$TEMPLATE_STORAGE" \
  --arg bridge  "$TEMPLATE_BRIDGE" \
  --argjson vmid "${TEMPLATE_VMID}" \
  --argjson stbycores "${AUTOSCALE_STANDBY_CORES:-0}" \
  --argjson stbymem   "${AUTOSCALE_STANDBY_MEM_GB:-0}" \
  --argjson backoff   "${AUTOSCALE_DOWNSCALE_BACKOFF:-600}" \
  --argjson agcores   "${AUTOSCALE_AGENT_CORES_OVERRIDE:-4}" \
  --argjson agmem     "${AUTOSCALE_AGENT_MEM_OVERRIDE:-8}" \
  '{
     vm_provider: {
       type: "Proxmox",
       api_host: $host,
       token_id: ($tokuser + "!" + $tokname),
       proxmox_node: $node,
       resource_pool: $pool,
       storage: $store,
       network_bridge: $bridge,
       template_vmid: $vmid,
       verify_tls: false
     },
     autoscale_config: {
       autoscale_type: "Agent (Docker)",
       standby_cores: $stbycores,
       standby_memory_gb: $stbymem,
       downscale_backoff_seconds: $backoff,
       agent_cores_override: $agcores,
       agent_memory_gb_override: $agmem
     }
   }' | tee "$REPO_ROOT/out/autoscale-config.json"

echo
ok "Validation done. Now finish in the Kasm admin UI:"
cat <<EOF

  A) VM Provider  (Admin -> Infrastructure -> VM Providers -> Add)
       Provider Type      : Proxmox
       API Host           : ${PROXMOX_API_HOST}
       API Token ID       : ${PROXMOX_API_USER}!${PROXMOX_API_TOKEN_NAME}
       API Token Secret   : <the secret from 10-proxmox-setup.sh>
       Node               : ${PROXMOX_NODE}
       Resource Pool      : ${PROXMOX_POOL}
       Storage            : ${TEMPLATE_STORAGE}
       Network Bridge     : ${TEMPLATE_BRIDGE}
       Verify TLS         : off (self-signed lab cert)

  B) Autoscale Config  (Admin -> Infrastructure -> Autoscale Configs -> Add)
       Type               : Agent / Docker Agent
       VM Provider        : (the one from step A)
       Template / VMID    : ${TEMPLATE_VMID}
       Standby Cores      : ${AUTOSCALE_STANDBY_CORES:-0}
       Standby Memory(GB) : ${AUTOSCALE_STANDBY_MEM_GB:-0}
       Downscale Backoff  : ${AUTOSCALE_DOWNSCALE_BACKOFF:-600}s
       Agent Cores ovr.   : ${AUTOSCALE_AGENT_CORES_OVERRIDE:-4}
       Agent Memory ovr.  : ${AUTOSCALE_AGENT_MEM_OVERRIDE:-8} GB

  C) Attach the autoscale config to your default deployment zone, then run
     scripts/test/50-scale-test.sh to watch VMs appear on Proxmox.

  Field labels vary slightly by Kasm version; match by meaning. Verify against
  the Proxmox autoscale page in your version's Kasm docs.
EOF

(( fail )) && die "One or more checks failed — fix them before relying on autoscale."
ok "All preconditions satisfied."
