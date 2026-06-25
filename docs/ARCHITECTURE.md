# Architecture

```
        ┌──────────────────────────────────────────────────────────┐
        │                     Kasm control plane                      │
        │   (static host/VM:  proxy · api · manager · db · redis)     │
        │                                                            │
        │   Autoscale Config ──► VM Provider (Proxmox API token)      │
        └───────────────┬────────────────────────────────────────────┘
                        │  Proxmox REST API (clone / start / stop / destroy)
                        ▼
        ┌──────────────────────────────────────────────────────────┐
        │                       Proxmox node                          │
        │                                                            │
        │   pool: kasm-autoscale                                      │
        │     ├── template 9000  (kasm-agent-template)  ◄── golden    │
        │     ├── clone 1001  (Docker agent)  ── containers: sessions │
        │     ├── clone 1002  (Docker agent)  ── containers: sessions │
        │     └── ...          created/destroyed on demand            │
        └──────────────────────────────────────────────────────────┘
```

## Components

**Control plane** — A static Kasm install (`30-install-kasm.sh`). It brokers
connections, authenticates users, and runs the autoscaler loop. It does *not*
run user workloads in production; keep it off the autoscale pool.

**VM Provider** — Stored credentials + endpoint for one infrastructure backend.
Here it's the Proxmox API host plus the token from `10-proxmox-setup.sh`. Kasm
uses it to enumerate templates and clone/power/destroy VMs.

**Autoscale Config** — The policy: which template to clone, the target
*standby* capacity (warm headroom kept ready), per-agent CPU/RAM overrides, and
the *downscale backoff* (how long an agent must be idle before it's destroyed).
Attach it to a deployment zone.

**Template** — A Proxmox template VM. Two flavors in this repo:

| | Docker agent (`20-…`) | Server pool (`21-…`) |
|---|---|---|
| Unit of scale | One VM hosts **many** container sessions | One VM **per** user |
| Workload | Containerized browser/app/desktop images | Full OS desktop (RDP) |
| Density / cost | High | Low |
| Closest Horizon analog | RDSH / published apps | Instant-clone desktops |
| Boot-to-ready | Seconds (image pre-pulled) | Tens of seconds–minutes |

## The Docker-agent template build (`20-build-agent-template.sh`)

1. Download an Ubuntu cloud image onto the node.
2. `qm create` a VM, import the disk (`import-from`), attach a cloud-init drive.
3. Inject a **cloud-init vendor-data** snippet that, on first boot:
   - installs `qemu-guest-agent` (Kasm/Proxmox read the VM's IP + lifecycle through it),
   - installs Docker,
   - stages the Kasm release tarball (fast agent install at clone time),
   - pre-pulls workspace images (sessions start instantly — no cold pull),
   - clears `/etc/machine-id` so every clone is unique,
   - `poweroff`s itself to signal completion.
4. The host waits for power-off, then `qm template` converts it.

Why vendor-data + self-poweroff? It needs **no inbound SSH** to the VM and gives
the host a clean "provisioning done" signal. The only requirement is **outbound**
network on the bridge during the one-time build.

## Why `qemu-guest-agent` is non-negotiable

Kasm's Proxmox provider reads the clone's IP address and confirms it's alive via
the guest agent. Without it, clones come up but Kasm can never reach them and the
agent never registers. Both template builders install and enable it.

## Least-privilege token

`10-proxmox-setup.sh` creates a dedicated role and user, scopes ACLs to the
`kasm-autoscale` pool + the chosen storage, and mints a token with privilege
separation **off** (so it inherits the user's role). Kasm gets exactly the rights
to manage VMs in that pool and nothing else — not full root on the node.

## Windows server pool

The most common Horizon workload is Windows desktops. Kasm autoscales Windows
servers the same way; the template build is semi-automated by
`scripts/proxmox/22-build-windows-template.sh` (Windows can't be cloud-init'd, so
it uses an `autounattend.xml` answer file + Cloudbase-Init instead). The flow:

1. `22-build-windows-template.sh` — unattended Windows install, then `bootstrap.ps1`
   installs `qemu-guest-agent` (from the virtio-win ISO) + Cloudbase-Init and
   enables RDP.
2. `sysprep /generalize /shutdown` from inside the VM (the one manual step).
3. `22-build-windows-template.sh --finalize` — detaches ISOs, adds a cloud-init
   drive, and `qm template`s it into the `kasm-autoscale` pool.
4. In Kasm, create a **Server-pool autoscale config** pointing at that template,
   with an RDP connection (port 3389) and credentials.

The Proxmox-side prep (`10-proxmox-setup.sh`) is identical. Full walkthrough:
[`WINDOWS-DESKTOP-POOL.md`](WINDOWS-DESKTOP-POOL.md).

## Production hardening (beyond this test rig)

- Split control-plane roles (db/api/manager/proxy) across hosts; multiple agents.
- TLS with a real cert; set `*_VERIFY_TLS=true`.
- A dedicated VLAN + DHCP scope for the agent pool.
- Persistent profiles / home-volume mapping if users need state between sessions.
- GPU passthrough on the node + `standby_gpus` for accelerated workspaces.
