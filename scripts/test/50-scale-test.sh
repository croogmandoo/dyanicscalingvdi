#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 50-scale-test.sh — prove autoscaling works end to end.
#
# It does two things:
#   * OBSERVE  — polls Proxmox for VMs in the autoscale pool and prints how the
#     count changes over time (this is the reliable signal that Kasm is
#     cloning/destroying agents).
#   * DRIVE (optional) — if Kasm API creds are set, it launches TEST_SESSIONS
#     concurrent sessions to create demand, waits, then expires them so you can
#     watch scale-up and (after the downscale backoff) scale-down.
#
# Usage:
#   ./50-scale-test.sh            # observe + drive (if Kasm creds present)
#   ./50-scale-test.sh --observe  # only watch the pool, create no sessions
# -----------------------------------------------------------------------------
source "$(dirname "$0")/../../lib/common.sh"
load_env
require_env PROXMOX_POOL

need_cmd jq
OBSERVE_ONLY=0
[[ "${1:-}" == "--observe" ]] && OBSERVE_ONLY=1

POLL="${TEST_POLL_SECONDS:-10}"
DURATION="${TEST_DURATION_SECONDS:-300}"

# --- how many VMs are in the pool right now, and how many are running? --------
pool_counts() {
  # Prefer the API token (what Kasm uses); fall back to SSH.
  if [[ -n "${PROXMOX_API_TOKEN_SECRET:-}" ]]; then
    local members
    members="$(pve_api GET "/pools/${PROXMOX_POOL}" 2>/dev/null \
      | jq -r '.data.members[]? | select(.type=="qemu") | "\(.vmid) \(.status) \(.template // 0)"')"
    local total running
    total="$(echo "$members" | grep -c . || true)"
    running="$(echo "$members" | awk '$3!=1 && $2=="running"' | grep -c . || true)"
    # subtract the template (template==1) from "total provisionable"
    local templates
    templates="$(echo "$members" | awk '$3==1' | grep -c . || true)"
    echo "$(( total - templates )) $running"
  else
    # SSH fallback: list VMs whose name suggests an autoscale clone is harder,
    # so just count non-template VMs in the pool via pvesh.
    local json
    json="$(pve_ssh "pvesh get /pools/${PROXMOX_POOL} --output-format json" 2>/dev/null || echo '{}')"
    local total running
    total="$(echo "$json" | jq -r '[.members[]? | select(.type=="qemu" and (.template//0)!=1)] | length')"
    running="$(echo "$json" | jq -r '[.members[]? | select(.type=="qemu" and (.template//0)!=1 and .status=="running")] | length')"
    echo "${total:-0} ${running:-0}"
  fi
}

snapshot() {
  read -r total running < <(pool_counts)
  printf '%(%H:%M:%S)T  pool=%-3s running=%-3s  %s\n' -1 "$total" "$running" "$1"
}

# --- optional: drive demand through the Kasm public API ----------------------
SESSION_IDS=()
launch_sessions() {
  require_env KASM_HOST KASM_API_KEY KASM_API_KEY_SECRET
  local n="${TEST_SESSIONS:-3}"
  log "Resolving Kasm image + user for session launch..."
  local image_id user_id
  image_id="$(kasm_api /api/public/get_images | jq -r \
    --arg n "${TEST_IMAGE_NAME:-}" \
    '.images[] | select(.friendly_name==$n or .name==$n) | .image_id' | head -n1)"
  [[ -z "$image_id" ]] && image_id="$(kasm_api /api/public/get_images | jq -r '.images[0].image_id')"
  user_id="$(kasm_api /api/public/get_users | jq -r '.users[0].user_id')"
  [[ -z "$image_id" || -z "$user_id" ]] && die "Could not resolve image_id/user_id from Kasm API."
  log "Launching $n sessions (image=$image_id user=$user_id)"
  local i
  for ((i=1; i<=n; i++)); do
    local resp kid
    resp="$(kasm_api /api/public/request_kasm \
      "$(jq -cn --arg u "$user_id" --arg im "$image_id" \
            '{user_id:$u, image_id:$im, enable_sharing:false}')" || true)"
    kid="$(echo "$resp" | jq -r '.kasm_id // empty')"
    if [[ -n "$kid" ]]; then SESSION_IDS+=("$kid"); ok "  session $i -> $kid"; else
      warn "  session $i failed: $(echo "$resp" | jq -rc '.error_message // .' 2>/dev/null)"
    fi
  done
}

expire_sessions() {
  [[ ${#SESSION_IDS[@]} -eq 0 ]] && return 0
  local user_id
  user_id="$(kasm_api /api/public/get_users | jq -r '.users[0].user_id')"
  log "Expiring ${#SESSION_IDS[@]} sessions to trigger scale-down..."
  local kid
  for kid in "${SESSION_IDS[@]}"; do
    kasm_api /api/public/destroy_kasm \
      "$(jq -cn --arg u "$user_id" --arg k "$kid" '{user_id:$u, kasm_id:$k}')" >/dev/null 2>&1 \
      && ok "  destroyed $kid" || warn "  could not destroy $kid"
  done
}

# --- run ---------------------------------------------------------------------
echo "Watching pool '$PROXMOX_POOL' every ${POLL}s for ${DURATION}s."
echo "(If 'pool' never moves, Kasm isn't cloning — check 40-configure-autoscale.sh output.)"
echo
snapshot "baseline"

CAN_DRIVE=0
if [[ "$OBSERVE_ONLY" -eq 0 && -n "${KASM_API_KEY:-}" && -n "${KASM_API_KEY_SECRET:-}" ]]; then
  CAN_DRIVE=1
  launch_sessions
  snapshot "sessions requested -> expect pool to grow"
else
  log "Observe-only (no Kasm creds). Now manually launch sessions in the Kasm UI."
fi

end=$(( $(date +%s) + DURATION ))
half_done=0
while (( $(date +%s) < end )); do
  sleep "$POLL"
  snapshot ""
  # Halfway through a driven test, expire sessions to watch scale-down.
  if (( CAN_DRIVE )) && (( half_done == 0 )) && (( $(date +%s) > end - DURATION/2 )); then
    expire_sessions
    half_done=1
    snapshot "sessions expired -> expect scale-down after backoff (${AUTOSCALE_DOWNSCALE_BACKOFF:-600}s)"
  fi
done

(( CAN_DRIVE )) && (( half_done == 0 )) && expire_sessions
echo
ok "Test window finished. Review the pool/running timeline above."
log "Scale-down lags by the downscale backoff; watch a bit longer if needed."
