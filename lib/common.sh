#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# lib/common.sh — shared helpers sourced by every script in this repo.
#
#   source "$(dirname "$0")/../lib/common.sh"   # adjust depth per script
#
# Provides: logging, .env loading + validation, an SSH wrapper for the Proxmox
# node, a Proxmox REST helper, and a Kasm public-API helper.
# -----------------------------------------------------------------------------
set -euo pipefail

# --- locate repo root regardless of where the caller lives -------------------
COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$COMMON_SH_DIR/.." && pwd)"
export REPO_ROOT

# --- colours (disabled when not a tty) ---------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_RST=""
fi

log()   { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()    { printf '%s[ok]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()   { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

confirm() {
  # confirm "Prompt" -> returns 0 on yes. Honour FORCE=1 to skip.
  [[ "${FORCE:-0}" == "1" ]] && return 0
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# --- .env loading ------------------------------------------------------------
load_env() {
  local env_file="${ENV_FILE:-$REPO_ROOT/.env}"
  if [[ ! -f "$env_file" ]]; then
    die ".env not found at $env_file — copy .env.example to .env and edit it."
  fi
  set -a
  # shellcheck source=/dev/null
  source "$env_file"
  set +a
}

# require_env VAR1 VAR2 ... — fail if any are empty.
require_env() {
  local missing=()
  local v
  for v in "$@"; do
    [[ -z "${!v:-}" ]] && missing+=("$v")
  done
  if (( ${#missing[@]} )); then
    die "Missing required .env values: ${missing[*]}"
  fi
}

# --- SSH to the Proxmox node -------------------------------------------------
# pve_ssh "command string"   — runs the command on the node, returns its output.
pve_ssh() {
  require_env PROXMOX_HOST PROXMOX_SSH_USER PROXMOX_SSH_PORT
  local key_opt=()
  [[ -n "${PROXMOX_SSH_KEY:-}" && -f "${PROXMOX_SSH_KEY/#\~/$HOME}" ]] && \
    key_opt=(-i "${PROXMOX_SSH_KEY/#\~/$HOME}")
  ssh -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 \
      -p "$PROXMOX_SSH_PORT" \
      "${key_opt[@]}" \
      "${PROXMOX_SSH_USER}@${PROXMOX_HOST}" "$@"
}

# pve_scp <local> <remote>  — copy a file to the node.
pve_scp() {
  require_env PROXMOX_HOST PROXMOX_SSH_USER PROXMOX_SSH_PORT
  local key_opt=()
  [[ -n "${PROXMOX_SSH_KEY:-}" && -f "${PROXMOX_SSH_KEY/#\~/$HOME}" ]] && \
    key_opt=(-i "${PROXMOX_SSH_KEY/#\~/$HOME}")
  scp -o StrictHostKeyChecking=accept-new \
      -P "$PROXMOX_SSH_PORT" \
      "${key_opt[@]}" \
      "$1" "${PROXMOX_SSH_USER}@${PROXMOX_HOST}:$2"
}

# --- Proxmox REST API (token auth) ------------------------------------------
# pve_api GET /nodes/pve/qemu          — returns JSON .data
pve_api() {
  require_env PROXMOX_API_HOST PROXMOX_API_USER PROXMOX_API_TOKEN_NAME
  local method="$1"; shift
  local path="$1"; shift
  local token_secret="${PROXMOX_API_TOKEN_SECRET:-}"
  [[ -z "$token_secret" ]] && die "PROXMOX_API_TOKEN_SECRET not set (export it; setup script prints it once)."
  local insecure=()
  [[ "${PROXMOX_VERIFY_TLS:-false}" == "false" ]] && insecure=(-k)
  curl -fsS "${insecure[@]}" \
    -H "Authorization: PVEAPIToken=${PROXMOX_API_USER}!${PROXMOX_API_TOKEN_NAME}=${token_secret}" \
    -X "$method" "$@" \
    "${PROXMOX_API_HOST}/api2/json${path}"
}

# --- Kasm public API ---------------------------------------------------------
# kasm_api /api/public/get_users '{"extra":"json"}'
# api_key + api_key_secret are merged into the body automatically.
kasm_api() {
  require_env KASM_HOST KASM_API_KEY KASM_API_KEY_SECRET
  local path="$1"; shift
  local extra="${1:-{\}}"
  local insecure=()
  [[ "${KASM_VERIFY_TLS:-false}" == "false" ]] && insecure=(-k)
  local body
  body="$(jq -cn --arg k "$KASM_API_KEY" --arg s "$KASM_API_KEY_SECRET" \
              --argjson extra "$extra" \
              '{api_key:$k, api_key_secret:$s} + $extra')"
  curl -fsS "${insecure[@]}" \
    -H 'Content-Type: application/json' \
    -X POST -d "$body" \
    "${KASM_HOST}${path}"
}

# --- misc --------------------------------------------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

# Expand a leading ~ in a path.
expand_path() { echo "${1/#\~/$HOME}"; }
