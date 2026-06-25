# Dynamically scaling VDI — Kasm Workspaces + Proxmox

Scripts to stand up and **test a dynamically scaling VDI on a real Proxmox node**
using [Kasm Workspaces](https://www.kasm.com/) native Proxmox autoscaling. Built
to answer one question: *can Kasm + Proxmox get close to what we get from Omnissa
(VMware) Horizon?*

Kasm and Proxmox shipped an official integration: Kasm talks to the Proxmox API,
clones a VM template on demand, registers it as a worker (a Docker "agent" host,
or a full desktop "server"), and destroys it again when idle. That's the same
elastic-pool idea as Horizon instant clones — just self-hosted and free of
per-seat licensing.

> See [`docs/HORIZON-COMPARISON.md`](docs/HORIZON-COMPARISON.md) for an honest
> feature/performance comparison before you invest time.

## What's here

| Path | What it does |
|------|--------------|
| `scripts/00-preflight.sh` | Validates your workstation, `.env`, SSH + Proxmox reachability. Read-only. |
| `scripts/proxmox/10-proxmox-setup.sh` | Creates the role, API user, resource pool, ACLs and API **token** on the node. |
| `scripts/proxmox/20-build-agent-template.sh` | Builds the **Docker-agent** VM template (dense, containerized workspaces). |
| `scripts/proxmox/21-build-server-template.sh` | Builds a **full-desktop Linux** VM template (Horizon-style, one VM per user, over RDP). |
| `scripts/proxmox/22-build-windows-template.sh` | Builds a **Windows desktop-pool** template (the closest Horizon analog). See [`docs/WINDOWS-DESKTOP-POOL.md`](docs/WINDOWS-DESKTOP-POOL.md). |
| `scripts/kasm/30-install-kasm.sh` | Installs the Kasm control plane (run on the Kasm host). |
| `scripts/kasm/40-configure-autoscale.sh` | Validates the Proxmox token/pool/template and prints the exact Kasm config. |
| `scripts/test/50-scale-test.sh` | Drives demand and watches VMs appear/drain on Proxmox. |
| `scripts/90-teardown.sh` | Removes the templates/token/pool/role to reset. |
| `docs/` | Architecture, Horizon comparison, testing, troubleshooting. |
| `.forgejo/workflows/ci.yml` | shellcheck + syntax CI (ready for your self-hosted Forgejo runners). |

## Prerequisites

- A reachable **Proxmox VE node** (7.2+ — the template build uses `import-from`)
  with: SSH access, a storage pool, a bridge with **DHCP + internet** (the
  template needs to reach apt + Docker Hub during its one-time build).
- A separate host/VM for the **Kasm control plane** (Ubuntu/Debian, 4 vCPU /
  8 GB+). It can itself be a *static* Proxmox VM.
- Your workstation needs: `bash`, `ssh`, `scp`, `curl`, `jq`.

## Quickstart

```bash
cp .env.example .env
$EDITOR .env                      # fill in Proxmox + Kasm details

./scripts/00-preflight.sh         # everything green before continuing

# --- Proxmox side ---
./scripts/proxmox/10-proxmox-setup.sh      # SAVE the token secret it prints
export PROXMOX_API_TOKEN_SECRET='...'      # paste the secret
./scripts/proxmox/20-build-agent-template.sh   # ~10-20 min (downloads + pulls)

# --- Kasm side (on the Kasm host) ---
sudo KASM_VERSION=1.16.1 ./scripts/kasm/30-install-kasm.sh   # save admin pw/URL

# --- Wire them together ---
./scripts/kasm/40-configure-autoscale.sh   # validates + prints UI values
#   ...enter the VM Provider + Autoscale Config in the Kasm admin UI...

# --- Prove it scales ---
./scripts/test/50-scale-test.sh
```

Everything is driven by `.env`; nothing is hardcoded. Scripts are idempotent —
re-running detects existing objects. `make help` lists the same steps as targets.

## How it works (one paragraph)

`10-proxmox-setup.sh` gives Kasm a least-privilege API token scoped to a
dedicated pool. `20-build-agent-template.sh` builds a golden image (Ubuntu +
`qemu-guest-agent` + Docker + pre-pulled workspace images) and converts it to a
Proxmox template. In the Kasm UI you add a **VM Provider** (the Proxmox token)
and an **Autoscale Config** (which template, how much standby capacity, how long
to wait before destroying idle agents). From then on Kasm clones the template
when sessions are requested and destroys the clones after the downscale backoff.
`50-scale-test.sh` makes that visible by polling the pool while it launches and
expires sessions. Full detail in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## A note on accuracy

This was written against Kasm's native Proxmox autoscaling design. Exact field
labels in the admin UI and the precise Proxmox **privilege names** can shift
between versions — `40-configure-autoscale.sh` validates the token end-to-end and
the scripts flag where to double-check your version's docs. The
[Kasm Proxmox autoscale guide](https://docs.kasm.com/docs/latest/how-to/autoscale/autoscale_providers/proxmox/index.html)
is the authoritative reference.

## Migrating to Forgejo

The CI under `.forgejo/workflows/` runs as-is once you register a runner on your
self-hosted Forgejo. It's GitHub-Actions-syntax compatible, so copy it to
`.github/workflows/` if you want it here too. See `docs/TESTING.md`.

## Sources

- [Kasm: Proxmox AutoScale guide](https://docs.kasm.com/docs/latest/how-to/autoscale/autoscale_providers/proxmox/index.html)
- [Kasm: AutoScale overview](https://www.kasmweb.com/docs/develop/how_to/infrastructure_components/autoscale.html)
- [LearnLinuxTV: Kasm VDI on Proxmox](https://www.learnlinux.tv/kasm-vdi-on-proxmox-autoscaling-virtual-desktops-made-easy/)
