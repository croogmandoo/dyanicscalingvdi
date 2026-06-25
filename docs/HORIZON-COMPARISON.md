# Kasm + Proxmox vs. Omnissa (VMware) Horizon

An honest comparison to set expectations before you spend a weekend on this.
Short version: **for browser/app/Linux-desktop delivery, Kasm+Proxmox is
genuinely competitive and far cheaper. For large fleets of stateful Windows
desktops with rich peripheral redirection, Horizon is still more mature.**

## Where they line up

| Capability | Horizon | Kasm + Proxmox |
|---|---|---|
| Elastic pool of desktops | Instant clones / automated pools | Autoscale config clones a template on demand |
| Broker / connection gateway | Connection Server + UAG | Kasm proxy/gateway (built in) |
| Golden image workflow | Master VM → snapshot → pool | Template VM (`qm template`) → autoscale config |
| Protocol | Blast Extreme / PCoIP | KasmVNC (web), or RDP for server pools |
| Access | Horizon Client / browser | **Browser only — zero client install** |
| Multi-session host | RDSH | Docker-agent pool (many sessions per VM) |

## Where Kasm + Proxmox wins

- **Cost & licensing.** No per-seat/CCU licensing, no vSphere licensing. Proxmox
  + Kasm Community/Cloud-Personal can be $0 for a lab; Kasm's paid tiers are per
  *concurrent* session and modest next to Horizon + vSphere + Omnissa subscriptions.
- **Zero endpoint footprint.** Everything runs in a browser (HTML5). No client to
  package, patch, or support. Great for BYOD/contractors.
- **Density.** A Docker-agent host runs many containerized sessions per VM —
  cheaper per seat than one-VM-per-user for browser/app workloads.
- **Speed to disposable session.** Pre-pulled images mean a non-persistent
  browser/app session is ready in seconds.
- **Self-hostable & open-ish.** Runs entirely on your hardware; no cloud dependency.

## Where Horizon still wins

- **Peripheral & media richness.** Blast/PCoIP have years of investment in USB
  redirection, multi-monitor, webcam/RTAV, printing, smartcards, and codec tuning
  for high-motion/high-latency. KasmVNC is excellent for productivity but is not a
  full PCoIP replacement for, say, CAD over WAN.
- **Stateful Windows desktops at scale.** App Volumes / Dynamic Environment
  Manager / instant-clone tooling for persistent Windows profiles is more mature
  than rolling your own persistent profiles on Kasm.
- **Enterprise ops.** Deep vCenter integration, mature HA, large-scale pool
  management, vendor support SLAs, established compliance posture.
- **Protocol over bad networks.** PCoIP/Blast adapt to lossy/high-latency links
  better than VNC-over-WebSocket today.

## Performance — what to actually test

"Same performance" depends entirely on the workload. Measure these on your node:

1. **Session-ready time** — request → usable session. Pre-pull images for Docker
   agents; keep `standby_cores` > 0 for instant first session.
2. **Scale-up latency** — request when the pool is cold → new VM cloned, booted,
   registered, session served. Proxmox clone speed (storage backend!) dominates.
   Use thin-clone-friendly storage (LVM-thin / ZFS / Ceph) and linked clones if
   your setup supports them.
3. **Per-session interactivity** — frame rate / input latency under typical use.
   Compare KasmVNC vs an RDP server pool for your apps.
4. **Density ceiling** — sessions per host before CPU/RAM/IO saturate.
5. **Scale-down correctness** — idle agents actually destroyed after the backoff.

`scripts/test/50-scale-test.sh` gives you (1), (2), and (5) directly. For (3)/(4),
drive real users/apps and watch node metrics.

## Recommendation

- **Browser/SaaS/Linux-dev/app-publishing, cost-sensitive, BYOD:** Kasm+Proxmox
  is a strong, much cheaper alternative — pilot it.
- **Large stateful Windows estate with heavy peripheral/media needs and existing
  VMware investment:** Horizon remains the safer default; consider Kasm for
  specific use cases (contractors, browser isolation, dev sandboxes) alongside it.

Build the pilot with these scripts, run the five tests above against your real
workloads, and let the numbers decide.
